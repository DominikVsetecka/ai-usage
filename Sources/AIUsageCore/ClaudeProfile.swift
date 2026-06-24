import Foundation

public struct ClaudeProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var accountLabel: String?
    public var accountIdentifier: String?
    public var importedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        accountLabel: String? = nil,
        accountIdentifier: String? = nil,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.accountLabel = accountLabel
        self.accountIdentifier = accountIdentifier
        self.importedAt = importedAt
    }
}

public struct ClaudeOAuthCredentials: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAtMilliseconds: Double?
    public var subscriptionType: String?
    public var scopes: [String]

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAtMilliseconds: Double? = nil,
        subscriptionType: String? = nil,
        scopes: [String] = []
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.subscriptionType = subscriptionType
        self.scopes = scopes
    }

    public func needsRefresh(now: Date = Date(), buffer: TimeInterval = 300) -> Bool {
        guard let expiresAtMilliseconds else { return false }
        let expiry = Date(timeIntervalSince1970: expiresAtMilliseconds / 1_000)
        return expiry <= now.addingTimeInterval(buffer)
    }
}

public struct ImportedClaudeProfile: Sendable {
    public let profile: ClaudeProfile
    public let credentialSourceDescription: String
}
