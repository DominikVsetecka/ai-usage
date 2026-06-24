import Foundation

public struct HTTPResult: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }
}

public protocol HTTPTransporting: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

public struct URLSessionHTTPTransport: HTTPTransporting, Sendable {
    public init() {}

    public func send(_ request: URLRequest) async throws -> HTTPResult {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeOAuthUsageError.invalidResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return HTTPResult(data: data, statusCode: http.statusCode, headers: headers)
    }
}

public actor ClaudeOAuthUsageService {
    public static let shared = ClaudeOAuthUsageService()

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let scopes = "user:profile user:inference user:sessions:claude_code"

    private struct CacheEntry {
        let result: ClaudeUsageResult
        let storedAt: Date
    }

    private let store: any ClaudeCredentialStoring
    private let transport: any HTTPTransporting
    private let cacheTTL: TimeInterval
    private var cache: [UUID: CacheEntry] = [:]
    private var retryAfter: [UUID: Date] = [:]

    public init(
        store: any ClaudeCredentialStoring = KeychainClaudeCredentialStore(),
        transport: any HTTPTransporting = URLSessionHTTPTransport(),
        cacheTTL: TimeInterval = 15 * 60
    ) {
        self.store = store
        self.transport = transport
        self.cacheTTL = cacheTTL
    }

    public func fetch(profileID: UUID, force: Bool = false) async throws -> ClaudeUsageResult {
        let now = Date()
        if !force, let cached = cache[profileID], now.timeIntervalSince(cached.storedAt) < cacheTTL {
            return cached.result
        }
        if let retryDate = retryAfter[profileID], retryDate > now {
            if let cached = cache[profileID] { return cached.result }
            throw ClaudeOAuthUsageError.rateLimited(retryDate)
        }

        guard var credentials = try store.load(profileID: profileID) else {
            throw ClaudeOAuthUsageError.authenticationRequired
        }
        if credentials.needsRefresh(), credentials.refreshToken != nil {
            credentials = try await refresh(credentials, profileID: profileID)
        }

        var response = try await usageResponse(accessToken: credentials.accessToken)
        if response.statusCode == 401 || response.statusCode == 403 {
            guard credentials.refreshToken != nil else {
                throw ClaudeOAuthUsageError.authenticationRequired
            }
            credentials = try await refresh(credentials, profileID: profileID)
            response = try await usageResponse(accessToken: credentials.accessToken)
        }

        if response.statusCode == 429 {
            let delay = TimeInterval(response.headers["retry-after"].flatMap(Double.init) ?? 300)
            let date = now.addingTimeInterval(max(30, delay))
            retryAfter[profileID] = date
            if let cached = cache[profileID] { return cached.result }
            throw ClaudeOAuthUsageError.rateLimited(date)
        }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ClaudeOAuthUsageError.authenticationRequired
            }
            throw ClaudeOAuthUsageError.requestFailed(response.statusCode)
        }

        let result = try Self.parseUsageResponse(response.data)
        cache[profileID] = CacheEntry(result: result, storedAt: now)
        retryAfter[profileID] = nil
        return result
    }

    public func clearCache(profileID: UUID) {
        cache[profileID] = nil
        retryAfter[profileID] = nil
    }

    public static func parseUsageResponse(_ data: Data) throws -> ClaudeUsageResult {
        let payload: UsagePayload
        do {
            payload = try JSONDecoder().decode(UsagePayload.self, from: data)
        } catch {
            throw ClaudeOAuthUsageError.invalidResponse
        }

        let session = payload.fiveHour.flatMap(makeWindow)
        let weekly = payload.sevenDay.flatMap(makeWindow)
        guard session != nil || weekly != nil else {
            throw ClaudeOAuthUsageError.invalidResponse
        }
        return ClaudeUsageResult(session: session, weekly: weekly)
    }

    private func usageResponse(accessToken: String) async throws -> HTTPResult {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("AIUsage/1.0", forHTTPHeaderField: "User-Agent")
        do {
            return try await transport.send(request)
        } catch let error as ClaudeOAuthUsageError {
            throw error
        } catch {
            throw ClaudeOAuthUsageError.networkUnavailable
        }
    }

    private func refresh(_ credentials: ClaudeOAuthCredentials, profileID: UUID) async throws -> ClaudeOAuthCredentials {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw ClaudeOAuthUsageError.authenticationRequired
        }

        var request = URLRequest(url: Self.refreshURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("AIUsage/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": Self.scopes
        ])

        let response: HTTPResult
        do {
            response = try await transport.send(request)
        } catch {
            throw ClaudeOAuthUsageError.networkUnavailable
        }
        if response.statusCode == 400 || response.statusCode == 401 {
            throw ClaudeOAuthUsageError.sessionExpired
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ClaudeOAuthUsageError.requestFailed(response.statusCode)
        }

        let payload: RefreshPayload
        do {
            payload = try JSONDecoder().decode(RefreshPayload.self, from: response.data)
        } catch {
            throw ClaudeOAuthUsageError.invalidResponse
        }
        guard let accessToken = payload.accessToken, !accessToken.isEmpty else {
            throw ClaudeOAuthUsageError.invalidResponse
        }

        var updated = credentials
        updated.accessToken = accessToken
        if let newRefreshToken = payload.refreshToken, !newRefreshToken.isEmpty {
            updated.refreshToken = newRefreshToken
        }
        if let expiresIn = payload.expiresIn {
            updated.expiresAtMilliseconds = (Date().timeIntervalSince1970 + expiresIn) * 1_000
        }
        try store.save(updated, profileID: profileID)
        return updated
    }

    private static func makeWindow(_ payload: UsageWindowPayload) -> ProviderUsageWindow? {
        guard let utilization = payload.utilization else { return nil }
        let percent = min(100, max(0, Int(utilization.rounded())))
        return ProviderUsageWindow(
            percentUsed: percent,
            resetDescription: resetDescription(payload.resetsAt)
        )
    }

    private static func resetDescription(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: raw) ?? basic.date(from: raw) else { return nil }

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
        formatter.timeStyle = .short
        return "Resets \(formatter.string(from: date))"
    }
}

public struct ClaudeOAuthUsageProbe: UsageProbing {
    public let sourceID: String
    public let label: String
    public let enabled: Bool

    private let profile: ClaudeProfile?
    private let quota: QuotaSelection
    private let service: ClaudeOAuthUsageService

    public init(
        sourceID: String,
        label: String,
        enabled: Bool,
        profile: ClaudeProfile?,
        quota: QuotaSelection,
        service: ClaudeOAuthUsageService = .shared
    ) {
        self.sourceID = sourceID
        self.label = label
        self.enabled = enabled
        self.profile = profile
        self.quota = quota
        self.service = service
    }

    public func readUsage() async -> UsageSnapshot {
        guard enabled else {
            return UsageSnapshot(sourceID: sourceID, label: label, enabled: false, percentUsed: nil, status: .disabled, updatedAt: Date(), errorMessage: nil)
        }
        guard let profile else { return failure("Import a Claude Code account in Settings") }

        do {
            let result = try await service.fetch(profileID: profile.id)
            let selected = quota == .weekly ? result.weekly : result.session
            guard let selected else { return failure("Claude did not report \(quota.displayName.lowercased()) usage") }
            return UsageSnapshot(
                sourceID: sourceID,
                label: label,
                enabled: true,
                percentUsed: selected.percentUsed,
                status: .ok,
                updatedAt: Date(),
                resetDescription: selected.resetDescription,
                errorMessage: nil,
                fiveHour: result.session,
                oneWeek: result.weekly
            )
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private func failure(_ message: String) -> UsageSnapshot {
        UsageSnapshot(sourceID: sourceID, label: label, enabled: enabled, percentUsed: nil, status: .failed, updatedAt: Date(), errorMessage: message)
    }
}

public enum ClaudeOAuthUsageError: LocalizedError, Equatable {
    case authenticationRequired
    case sessionExpired
    case networkUnavailable
    case rateLimited(Date)
    case requestFailed(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            "Claude account credentials are missing or no longer valid"
        case .sessionExpired:
            "Claude session expired. Log in with Claude Code and import this profile again."
        case .networkUnavailable:
            "Claude usage could not be reached"
        case .rateLimited(let date):
            "Claude usage is rate-limited until \(date.formatted(date: .omitted, time: .shortened))"
        case .requestFailed(let status):
            "Claude usage request failed (HTTP \(status))"
        case .invalidResponse:
            "Claude returned an unsupported usage response"
        }
    }
}

private struct UsagePayload: Decodable {
    let fiveHour: UsageWindowPayload?
    let sevenDay: UsageWindowPayload?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct UsageWindowPayload: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

private struct RefreshPayload: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
