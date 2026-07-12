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
    /// How long a successful fetch is served from cache before a *periodic*
    /// (non-forced) refresh hits the network again. By explicit design this is
    /// kept exactly equal to the user's configured Settings refresh interval —
    /// see `updateCacheTTL(_:)` — so "1 minute" in Settings really means a real
    /// network check every 1 minute, not a display-only tick with a longer,
    /// invisible cache behind it. A manual/Save & Refresh force always bypasses
    /// this immediately (subject only to `minForceFetchInterval`).
    private var cacheTTL: TimeInterval
    /// Client-side floor on how often a *forced* (manual) refresh may actually
    /// hit the network. Forced fetches bypass the normal `cacheTTL`, but never
    /// fetch more than once per this interval — spamming the refresh button
    /// then serves cache instead of hammering the API, which is what prevents
    /// self-inflicted 429s (and the multi-minute lock they trigger).
    private let minForceFetchInterval: TimeInterval
    private var cache: [UUID: CacheEntry] = [:]
    private var retryAfter: [UUID: Date] = [:]
    /// Consecutive 429s per profile, driving an exponential backoff so a
    /// persistent rate-limit isn't retried every interval (which would keep
    /// tripping it and re-surfacing the error). Reset on any successful fetch.
    private var rateLimitStreak: [UUID: Int] = [:]

    // Diagnostic fetch log: a human-readable, last-100-line ring buffer written
    // to `logURL` (when set). Records every usage fetch decision — cache hit,
    // real network GET with the interval since the last one, 429 + backoff,
    // block-while-locked — plus free-form `note(_:)` lines (refresh triggers).
    private let logURL: URL?
    private var logLines: [String] = []
    private var logLoaded = false
    private static let logLimit = 100

    /// Fallback used only when a caller never calls `updateCacheTTL(_:)` (e.g.
    /// direct/test construction). The running app always syncs this to the
    /// configured refresh interval right after construction and on every
    /// Settings apply, so this value is never actually in effect there.
    public static let defaultCacheTTL: TimeInterval = 60

    public init(
        store: any ClaudeCredentialStoring = KeychainClaudeCredentialStore(),
        transport: any HTTPTransporting = URLSessionHTTPTransport(),
        cacheTTL: TimeInterval = ClaudeOAuthUsageService.defaultCacheTTL,
        minForceFetchInterval: TimeInterval = 10,
        logURL: URL? = nil
    ) {
        self.store = store
        self.transport = transport
        self.cacheTTL = cacheTTL
        self.minForceFetchInterval = minForceFetchInterval
        self.logURL = logURL
    }

    /// Append a free-form diagnostic line (e.g. the code trigger of a refresh
    /// cycle) to the same fetch log, so triggers and fetch outcomes interleave
    /// in one timeline.
    public func note(_ line: String) {
        logEvent(line)
    }

    private func logEvent(_ line: String) {
        guard let logURL else { return }
        if !logLoaded {
            if let existing = try? String(contentsOf: logURL, encoding: .utf8) {
                logLines = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            }
            logLoaded = true
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        logLines.append("\(formatter.string(from: Date()))  \(line)")
        if logLines.count > Self.logLimit {
            logLines.removeFirst(logLines.count - Self.logLimit)
        }
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (logLines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: logURL, options: .atomic)
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    public func fetch(profileID: UUID, force: Bool = false) async throws -> ClaudeUsageResult {
        let now = Date()
        let mode = force ? "forced  " : "periodic"
        let tag = Self.shortID(profileID)
        let sinceLast = cache[profileID].map { Int(now.timeIntervalSince($0.storedAt).rounded()) }
        // A forced (manual) refresh bypasses most of the cache TTL, but still
        // honours `minForceFetchInterval` as a hard floor — so rapid button
        // presses are served from cache rather than each firing a request.
        if let cached = cache[profileID] {
            let threshold = force ? minForceFetchInterval : cacheTTL
            if now.timeIntervalSince(cached.storedAt) < threshold {
                logEvent("usage \(tag) \(mode) -> cache-hit (age \(sinceLast ?? -1)s < ttl \(Int(threshold))s)")
                return cached.result
            }
        }
        if let retryDate = retryAfter[profileID], retryDate > now {
            // Surface the lock as an error rather than quietly returning the
            // frozen cached value as a fresh success — the monitor restores the
            // last-known numbers per field and the status bar greys them, so the
            // rate-limit is actually visible instead of looking up to date.
            logEvent("usage \(tag) \(mode) -> BLOCKED (rate-limited, \(Int(retryDate.timeIntervalSince(now).rounded()))s left)")
            throw ClaudeOAuthUsageError.rateLimited(retryDate)
        }

        guard var credentials = try store.load(profileID: profileID) else {
            logEvent("usage \(tag) \(mode) -> ERROR: no credentials")
            throw ClaudeOAuthUsageError.authenticationRequired
        }
        if credentials.needsRefresh(), credentials.refreshToken != nil {
            logEvent("usage \(tag) \(mode) -> token refresh (near expiry)")
            credentials = try await refresh(credentials, profileID: profileID)
        }

        logEvent("usage \(tag) \(mode) -> NETWORK GET (since last real fetch: \(sinceLast.map { "\($0)s" } ?? "n/a"))")
        var response = try await usageResponse(accessToken: credentials.accessToken)
        if response.statusCode == 401 || response.statusCode == 403 {
            guard credentials.refreshToken != nil else {
                logEvent("usage \(tag) \(mode) -> \(response.statusCode), no refresh token")
                throw ClaudeOAuthUsageError.authenticationRequired
            }
            logEvent("usage \(tag) \(mode) -> \(response.statusCode), token refresh + retry")
            credentials = try await refresh(credentials, profileID: profileID)
            response = try await usageResponse(accessToken: credentials.accessToken)
        }

        if response.statusCode == 429 {
            // Exponential backoff on consecutive 429s: 60s, 120s, 240s, ... capped
            // at 15 minutes, so a persistent limit isn't retried every interval
            // (which just keeps tripping it). A server-provided Retry-After still
            // wins when it asks for longer.
            let attempts = (rateLimitStreak[profileID] ?? 0) + 1
            rateLimitStreak[profileID] = attempts
            let serverDelay = response.headers["retry-after"].flatMap(Double.init) ?? 0
            let backoff = Self.backoffSeconds(streak: attempts, serverRetryAfter: serverDelay)
            let date = now.addingTimeInterval(backoff)
            retryAfter[profileID] = date
            logEvent("usage \(tag) \(mode) -> 429 RATE-LIMITED, backoff \(Int(backoff))s (streak \(attempts), server retry-after \(serverDelay > 0 ? "\(Int(serverDelay))s" : "none"))")
            throw ClaudeOAuthUsageError.rateLimited(date)
        }
        guard response.statusCode == 200 else {
            logEvent("usage \(tag) \(mode) -> HTTP \(response.statusCode)")
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ClaudeOAuthUsageError.authenticationRequired
            }
            throw ClaudeOAuthUsageError.requestFailed(response.statusCode)
        }

        let result = try Self.parseUsageResponse(response.data)
        cache[profileID] = CacheEntry(result: result, storedAt: now)
        retryAfter[profileID] = nil
        rateLimitStreak[profileID] = Self.decayedStreak(rateLimitStreak[profileID])
        logEvent("usage \(tag) \(mode) -> 200 OK")
        return result
    }

    /// Exponential backoff for the Nth consecutive 429: 60s, 120s, 240s, ...
    /// capped at 15 minutes. A server-provided Retry-After still wins when it
    /// asks for longer than the computed exponential wait.
    public static func backoffSeconds(streak: Int, serverRetryAfter: TimeInterval) -> TimeInterval {
        let exponential = min(900, 60 * pow(2, Double(max(1, streak) - 1)))
        return max(exponential, serverRetryAfter)
    }

    /// Decays the consecutive-429 streak by one step on a success, rather than
    /// snapping it to zero. Live data showed a persistently tight server-side
    /// limit where a single success is often immediately followed by another
    /// 429 — a hard reset kept dropping the backoff straight back to its 60s
    /// floor every time, so the app just kept re-tripping the same limit. A
    /// one-off success still recovers over a couple of clean fetches, but a
    /// limit that's still actually tight keeps getting a growing wait.
    public static func decayedStreak(_ previous: Int?) -> Int? {
        guard let previous, previous > 1 else { return nil }
        return previous - 1
    }

    public func clearCache(profileID: UUID) {
        cache[profileID] = nil
        retryAfter[profileID] = nil
        rateLimitStreak[profileID] = nil
    }

    /// Keeps the periodic cache TTL exactly equal to the user's configured
    /// Settings refresh interval — called right after construction and again
    /// on every Settings apply, so changing the interval takes effect
    /// immediately without discarding the cache or any active rate-limit
    /// backoff (unlike rebuilding the service from scratch).
    public func updateCacheTTL(_ ttl: TimeInterval) {
        cacheTTL = ttl
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
        return ClaudeUsageResult(session: session, weekly: weekly, extra: extraWindows(from: payload.limits))
    }

    // Model-scoped extra limits (e.g. a "Fable" weekly cap) show up as generic
    // entries in the `limits` array rather than named top-level fields — any
    // entry with `scope.model.display_name` set is one of these, keyed by
    // that display name so newly added models pick up automatically.
    private static func extraWindows(from limits: [LimitPayload]?) -> [String: ProviderUsageWindow] {
        guard let limits else { return [:] }
        var result: [String: ProviderUsageWindow] = [:]
        for limit in limits {
            guard let name = limit.scope?.model?.displayName?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty,
                  let percent = limit.percent else { continue }
            let resetsAt = parseISODate(limit.resetsAt)
            result[name] = ProviderUsageWindow(
                percentUsed: percent,
                resetDescription: resetDescription(resetsAt),
                resetsAt: resetsAt
            )
        }
        return result
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
        let resetsAt = parseISODate(payload.resetsAt)
        return ProviderUsageWindow(
            percentUsed: percent,
            resetDescription: resetDescription(resetsAt),
            resetsAt: resetsAt
        )
    }

    // The API returns exact ISO 8601 instants — parse those directly rather
    // than formatting to locale text and re-parsing it back (which silently
    // failed on any non-English-month locale, since the text parser only
    // understands English month abbreviations).
    private static func parseISODate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return fractional.date(from: raw) ?? basic.date(from: raw)
    }

    private static func resetDescription(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
        formatter.timeStyle = .short
        return "Resets \(formatter.string(from: date))"
    }
}

public struct ClaudeOAuthUsageProbe: ForceRefreshableUsageProbing {
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
        await readUsage(force: false)
    }

    public func readUsage(force: Bool) async -> UsageSnapshot {
        guard enabled else {
            return UsageSnapshot(sourceID: sourceID, label: label, enabled: false, percentUsed: nil, status: .disabled, updatedAt: Date(), errorMessage: nil)
        }
        guard let profile else { return failure("Import a Claude Code account in Settings") }

        do {
            let result = try await service.fetch(profileID: profile.id, force: force)
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
                oneWeek: result.weekly,
                extraWindows: result.extra
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
    let limits: [LimitPayload]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }
}

// A generic entry from the `limits` array. Most entries are the plain
// session/weekly_all windows already covered by five_hour/seven_day; entries
// with a `scope.model` are model-specific extras (e.g. "Fable").
private struct LimitPayload: Decodable {
    let percent: Int?
    let resetsAt: String?
    let scope: LimitScopePayload?

    enum CodingKeys: String, CodingKey {
        case percent
        case resetsAt = "resets_at"
        case scope
    }
}

private struct LimitScopePayload: Decodable {
    let model: LimitModelScopePayload?
}

private struct LimitModelScopePayload: Decodable {
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
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
