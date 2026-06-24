import Foundation

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
        for service in claudeCodeKeychainServices() {
            if let data = readKeychainData(service: service),
               let credentials = try? Self.parseCredentials(data) {
                return (credentials, "Claude Code Keychain")
            }
        }

        let credentialURLs = [
            homeDirectory.appendingPathComponent(".claude/.credentials.json"),
            homeDirectory.appendingPathComponent(".claude/credentials.json")
        ]

        for url in credentialURLs where FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let credentials = try? Self.parseCredentials(data) {
                return (credentials, "Claude Code credentials file")
            }
        }

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

    private func readKeychainData(service: String) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        guard finished.wait(timeout: .now() + 3) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }
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

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "No authenticated Claude Code account was found. Log in with Claude Code, then retry."
        case .invalidCredentials:
            "Claude Code credentials could not be read"
        }
    }
}
