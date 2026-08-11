import Foundation
import Security

public struct ClaudeCodeCredentialImporter: Sendable {
    private let store: any ClaudeCredentialStoring
    private let homeDirectory: URL

    public init(
        store: any ClaudeCredentialStoring = KeychainClaudeCredentialStore(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.store = store
        self.homeDirectory = homeDirectory
    }

    /// Read-only look at which Claude Code account an import would pick up right
    /// now, without writing anything to the Keychain or touching a profile.
    /// The import has exactly one source — whichever account Claude Code is
    /// signed in with at that moment — so Settings shows this up front instead
    /// of letting the user find out afterwards that both connections ended up
    /// on the same account.
    public func detectCurrentAccount() throws -> ClaudeCodeAccountPreview {
        let imported = try readCurrentCredentials()
        let metadata = readAccountMetadata()
        return ClaudeCodeAccountPreview(
            label: metadata.label,
            identifier: metadata.identifier,
            credentialSourceDescription: imported.source
        )
    }

    public func importCurrentAccount(profileID: UUID? = nil, preferredName: String) throws -> ImportedClaudeProfile {
        let imported = try readCurrentCredentials()
        let metadata = readAccountMetadata()
        let id = profileID ?? UUID()
        try store.save(imported.credentials, profileID: id)

        let cleanName = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ClaudeProfile(
            id: id,
            name: cleanName.isEmpty ? (metadata.label ?? "Claude Account") : cleanName,
            accountLabel: metadata.label,
            accountIdentifier: metadata.identifier,
            importedAt: Date()
        )
        return ImportedClaudeProfile(profile: profile, credentialSourceDescription: imported.source)
    }

    public static func parseCredentials(_ data: Data) throws -> ClaudeOAuthCredentials {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let rawAccessToken = oauth["accessToken"] as? String else {
            throw ClaudeCredentialImportError.invalidCredentials
        }

        let accessToken = rawAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            throw ClaudeCredentialImportError.invalidCredentials
        }

        let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue
        return ClaudeOAuthCredentials(
            accessToken: accessToken,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAtMilliseconds: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            scopes: oauth["scopes"] as? [String] ?? []
        )
    }

    private func readCurrentCredentials() throws -> (credentials: ClaudeOAuthCredentials, source: String) {
        var keychainError: Error?
        var foundInvalidCredentials = false
        for service in claudeCodeKeychainServices() {
            do {
                if let data = try readKeychainData(service: service) {
                    do {
                        return (try Self.parseCredentials(data), "Claude Code Keychain")
                    } catch {
                        foundInvalidCredentials = true
                    }
                }
            } catch {
                keychainError = error
            }
        }

        let credentialURLs = [
            homeDirectory.appendingPathComponent(".claude/.credentials.json"),
            homeDirectory.appendingPathComponent(".claude/credentials.json")
        ]

        for url in credentialURLs where FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url) {
                do {
                    return (try Self.parseCredentials(data), "Claude Code credentials file")
                } catch {
                    foundInvalidCredentials = true
                }
            }
        }

        if let keychainError { throw keychainError }
        if foundInvalidCredentials { throw ClaudeCredentialImportError.invalidCredentials }
        throw ClaudeCredentialImportError.notFound
    }

    private func claudeCodeKeychainServices() -> [String] {
        var services = ["Claude Code-credentials"]
        if let override = ProcessInfo.processInfo.environment["AI_USAGE_CLAUDE_KEYCHAIN_SERVICE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           override.hasPrefix("Claude Code-credentials"),
           !services.contains(override) {
            services.insert(override, at: 0)
        }
        return services
    }

    private func readKeychainData(service: String) throws -> Data? {
        // Use the Security framework directly. Spawning `/usr/bin/security`
        // made account detection depend on a child process, its own Keychain
        // ACL identity and a hard three-second timeout. A slow unlock prompt
        // therefore looked exactly like "not signed in" even when Claude Code
        // had a valid credential. This is still a targeted lookup for the one
        // known Claude Code service; it never enumerates the user's Keychain.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw ClaudeCredentialImportError.keychainAccessFailed(status)
        }
        guard let data = item as? Data, !data.isEmpty else {
            throw ClaudeCredentialImportError.invalidCredentials
        }
        return data
    }

    private func readAccountMetadata() -> (label: String?, identifier: String?) {
        let url = homeDirectory.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any] else {
            return (nil, nil)
        }
        let label = (account["emailAddress"] as? String) ?? (account["organizationName"] as? String)
        let identifier = (account["accountUuid"] as? String) ?? (account["organizationUuid"] as? String)
        return (label, identifier)
    }
}

public enum ClaudeCredentialImportError: LocalizedError {
    case notFound
    case invalidCredentials
    case keychainAccessFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "No authenticated Claude Code account was found. Log in with Claude Code, then retry."
        case .invalidCredentials:
            "Claude Code credentials could not be read"
        case .keychainAccessFailed(let status):
            "Claude Code Keychain access failed (\(Self.statusMessage(status)), OSStatus \(status))"
        }
    }

    private static func statusMessage(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "unknown Keychain error"
    }
}
