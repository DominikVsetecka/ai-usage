import Foundation
import Security

public protocol ClaudeCredentialStoring: Sendable {
    func load(profileID: UUID) throws -> ClaudeOAuthCredentials?
    func save(_ credentials: ClaudeOAuthCredentials, profileID: UUID) throws
    func delete(profileID: UUID) throws
}

public struct KeychainClaudeCredentialStore: ClaudeCredentialStoring, Sendable {
    public static let service = "app.ai-usage.claude-profile"

    public init() {}

    public func load(profileID: UUID) throws -> ClaudeOAuthCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ClaudeCredentialStoreError.operationFailed(status)
        }

        do {
            return try JSONDecoder().decode(ClaudeOAuthCredentials.self, from: data)
        } catch {
            throw ClaudeCredentialStoreError.invalidCredentialData
        }
    }

    public func save(_ credentials: ClaudeOAuthCredentials, profileID: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: profileID.uuidString
        ]
        let updates: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ClaudeCredentialStoreError.operationFailed(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw ClaudeCredentialStoreError.operationFailed(updateStatus)
        }
    }

    public func delete(profileID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: profileID.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClaudeCredentialStoreError.operationFailed(status)
        }
    }
}

public enum ClaudeCredentialStoreError: LocalizedError {
    case operationFailed(OSStatus)
    case invalidCredentialData

    public var errorDescription: String? {
        switch self {
        case .operationFailed:
            "Could not access the AI Usage Keychain item"
        case .invalidCredentialData:
            "The AI Usage Keychain item is not valid"
        }
    }
}
