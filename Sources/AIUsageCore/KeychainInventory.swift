import Foundation
import Security

/// A Keychain item owned by AI Usage, described without exposing secrets:
/// the token itself never leaves this type, only its last four characters.
public struct KeychainItemInfo: Equatable, Identifiable, Sendable {
    public let service: String
    public let account: String
    public let created: Date?
    public let modified: Date?
    public let fingerprint: String?
    public let expiresAt: Date?
    public let scopes: [String]

    public init(service: String, account: String, created: Date?, modified: Date?, fingerprint: String?, expiresAt: Date?, scopes: [String]) {
        self.service = service
        self.account = account
        self.created = created
        self.modified = modified
        self.fingerprint = fingerprint
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    public var id: String { "\(service)|\(account)" }
    public var profileID: UUID? { UUID(uuidString: account) }
}

public enum KeychainInventory {
    /// All `app.ai-usage.claude-profile` items, including orphans that no
    /// account points to any more. Only items in `detailsFor` are decrypted
    /// (for fingerprint and expiry); everything else is listed from its
    /// attributes alone, which never triggers a Keychain prompt.
    public static func appItems(
        detailsFor profileIDs: Set<UUID>,
        store: KeychainClaudeCredentialStore = KeychainClaudeCredentialStore()
    ) -> [KeychainItemInfo] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainClaudeCredentialStore.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }

        return items.compactMap { attributes -> KeychainItemInfo? in
            guard let account = attributes[kSecAttrAccount as String] as? String else { return nil }
            let credentials = UUID(uuidString: account)
                .flatMap { profileIDs.contains($0) ? try? store.load(profileID: $0) : nil }
            return KeychainItemInfo(
                service: KeychainClaudeCredentialStore.service,
                account: account,
                created: attributes[kSecAttrCreationDate as String] as? Date,
                modified: attributes[kSecAttrModificationDate as String] as? Date,
                fingerprint: credentials.map { fingerprint(of: $0.accessToken) },
                expiresAt: credentials?.expiresAtMilliseconds.map { Date(timeIntervalSince1970: $0 / 1_000) },
                scopes: credentials?.scopes ?? []
            )
        }
        .sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
    }

    /// Made-up items for demo mode, one per secure Claude profile.
    public static func demoItems(for sources: [SourceConfig], now: Date = Date()) -> [KeychainItemInfo] {
        let fingerprints = ["…7Qa2", "…kP9x", "…m3Rt", "…Zw41"]
        return sources.filter { $0.mode == .claudeOAuth }.compactMap(\.claudeProfile).enumerated().map { index, profile in
            KeychainItemInfo(
                service: KeychainClaudeCredentialStore.service,
                account: profile.id.uuidString,
                created: now.addingTimeInterval(-Double(12 + index) * 86_400),
                modified: now.addingTimeInterval(-Double(2 + index) * 3_600),
                fingerprint: fingerprints[index % fingerprints.count],
                expiresAt: now.addingTimeInterval(6 * 3_600),
                scopes: ["user:profile", "user:inference"]
            )
        }
    }

    public static func fingerprint(of token: String) -> String {
        "…" + String(token.suffix(4))
    }
}
