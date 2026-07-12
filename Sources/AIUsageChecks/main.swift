import AIUsageCore
import Foundation

final class MemoryClaudeCredentialStore: ClaudeCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: ClaudeOAuthCredentials] = [:]

    func load(profileID: UUID) throws -> ClaudeOAuthCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return values[profileID]
    }

    func save(_ credentials: ClaudeOAuthCredentials, profileID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        values[profileID] = credentials
    }

    func delete(profileID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        values[profileID] = nil
    }
}

actor QueueHTTPTransport: HTTPTransporting {
    private var responses: [HTTPResult]
    private(set) var requests: [URLRequest] = []

    init(responses: [HTTPResult]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        guard !responses.isEmpty else {
            throw ClaudeOAuthUsageError.invalidResponse
        }
        return responses.removeFirst()
    }
}

@discardableResult
func check(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if condition() {
        return true
    }

    fputs("Check failed: \(message)\n", stderr)
    exit(1)
}

let config = AppConfig.default
check(config.refreshIntervalSeconds == 30, "default refresh should be 30s")
check(config.showsRemainingCountdown == false, "remaining countdown should default off")
check(config.resolvedVisualHistoryStyle == .bars, "history style should default to bars")
check(config.sources.map(\.label) == ["C1", "C2", "GPT"], "default labels should be C1/C2/GPT")
check(config.sources[0].mode == .claudeCLI, "Claude 1 should default to CLI mode")
check(config.sources[1].enabled == false, "Claude 2 should default disabled until a second account path is configured")
check(config.sources[2].mode == .codexRPC, "Codex should default to RPC mode")

let overriddenURL = AppConfig.defaultConfigURL(environment: [
    "AI_USAGE_CONFIG": "/tmp/ai-usage-test.json",
    "HOME": "/tmp/ai-usage-example-home"
])
check(overriddenURL?.path == "/tmp/ai-usage-test.json", "AI_USAGE_CONFIG should override config path")

let temporaryConfigURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("ai-usage-check-config.json")
var countdownConfig = config
countdownConfig.remainingCountdownEnabled = true
countdownConfig.visualHistoryStyle = .line
try countdownConfig.save(to: temporaryConfigURL)
let reloadedConfig = try AppConfig.load(from: temporaryConfigURL)
check(reloadedConfig == countdownConfig, "saved settings should load without changes")
check(reloadedConfig.showsRemainingCountdown, "countdown setting should persist")
check(reloadedConfig.resolvedVisualHistoryStyle == .line, "history style should persist")
try? FileManager.default.removeItem(at: temporaryConfigURL)

let snapshots = [
    UsageSnapshot(sourceID: "claude1", label: "C1", enabled: true, percentUsed: 43, status: .ok, updatedAt: nil, errorMessage: nil),
    UsageSnapshot(sourceID: "claude2", label: "C2", enabled: true, percentUsed: 71, status: .ok, updatedAt: nil, errorMessage: nil),
    UsageSnapshot(sourceID: "codex", label: "GPT", enabled: true, percentUsed: 12, status: .ok, updatedAt: nil, errorMessage: nil)
]
check(UsageFormatter.menuBarTitle(for: snapshots) == "C1 43%  C2 71%  GPT 12%", "menu title should format side-by-side percentages")
check(
    UsageFormatter.menuBarTitle(for: snapshots, remainingCountdown: true) == "C1 57%  C2 29%  GPT 88%",
    "remaining countdown should invert used percentages"
)
check(UsageFormatter.displayPercent(percentUsed: 0, remainingCountdown: true) == 100, "no usage should display 100% remaining")
check(UsageFormatter.displayPercent(percentUsed: 100, remainingCountdown: true) == 0, "full usage should display 0% remaining")

let failedSnapshot = [
    UsageSnapshot(sourceID: "claude1", label: "C1", enabled: true, percentUsed: nil, status: .failed, updatedAt: nil, errorMessage: "No data")
]
check(UsageFormatter.menuBarTitle(for: failedSnapshot) == "C1 --%", "failed source should show placeholder")

let unlimitedSnapshot = [
    UsageSnapshot(sourceID: "codex", label: "GPT", enabled: true, percentUsed: nil, displayValue: "∞", status: .ok, updatedAt: nil, errorMessage: nil)
]
check(UsageFormatter.menuBarTitle(for: unlimitedSnapshot) == "GPT ∞", "unlimited source should show display value")

check(UsageParser.parsePercentUsed(from: "Usage: 43% used") == 43, "parser should read labeled usage")
check(UsageParser.parsePercentUsed(from: "session remaining 88%") == 88, "parser should read fallback percent")
check(UsageParser.parsePercentUsed(from: "quota 143%") == 100, "parser should clamp high percentages")
check(UsageParser.parsePercentUsed(from: "no quota data") == nil, "parser should return nil without percent")

let claudeOutput = """
Usage
Current session
████████ 22% used
Resets in 3h 14m
Current week (all models)
████████ 61% used
Resets Jun 30
"""
let claudeResult = try ClaudeCLIUsageProbe.parse(claudeOutput)
check(claudeResult.session?.percentUsed == 22, "Claude parser should read current session percent used")
check(claudeResult.weekly?.percentUsed == 61, "Claude parser should read weekly percent used")

// Two-window snapshot: both windows preserved in UsageSnapshot
let twoWindowSnapshot = UsageSnapshot(
    sourceID: "claude1", label: "C1", enabled: true,
    percentUsed: 22, status: .ok, updatedAt: nil, errorMessage: nil,
    fiveHour: ProviderUsageWindow(percentUsed: 22, resetDescription: "Resets in 3h"),
    oneWeek: ProviderUsageWindow(percentUsed: 61, resetDescription: "Resets Jun 30")
)
check(twoWindowSnapshot.fiveHour?.percentUsed == 22, "snapshot fiveHour should carry session window")
check(twoWindowSnapshot.oneWeek?.percentUsed == 61, "snapshot oneWeek should carry weekly window")
check(twoWindowSnapshot.percentUsed == 22, "snapshot percentUsed should reflect selected window for menu bar")

// Stale preservation: fiveHour and oneWeek are preserved on failure
let freshSnapshot = UsageSnapshot(
    sourceID: "claude1", label: "C1", enabled: true,
    percentUsed: 30, status: .ok, updatedAt: nil, errorMessage: nil,
    fiveHour: ProviderUsageWindow(percentUsed: 30, resetDescription: "Resets in 2h"),
    oneWeek: ProviderUsageWindow(percentUsed: 55, resetDescription: "Resets Mon")
)
let staleFailedSnapshot = UsageSnapshot(
    sourceID: "claude1", label: "C1", enabled: true,
    percentUsed: nil, status: .failed, updatedAt: nil, errorMessage: "timeout",
    fiveHour: nil, oneWeek: nil
)
// Simulate monitor merge: on failure, carry over previous values
var merged = staleFailedSnapshot
if merged.percentUsed == nil { merged.percentUsed = freshSnapshot.percentUsed }
if merged.resetDescription == nil { merged.resetDescription = freshSnapshot.resetDescription }
if merged.fiveHour == nil { merged.fiveHour = freshSnapshot.fiveHour }
if merged.oneWeek == nil { merged.oneWeek = freshSnapshot.oneWeek }
check(merged.percentUsed == 30, "stale monitor merge should preserve percentUsed from previous snapshot")
check(merged.fiveHour?.percentUsed == 30, "stale monitor merge should preserve fiveHour from previous snapshot")
check(merged.oneWeek?.percentUsed == 55, "stale monitor merge should preserve oneWeek from previous snapshot")
check(merged.status == .failed, "stale monitor merge should keep failed status")

// Partial-success preservation: a probe reporting overall `.ok` but missing
// just one window (e.g. a Claude CLI /usage redraw glitch that only garbles
// one section) must not blank that window out — it should keep the
// last-known-good value, exactly like a hard failure would.
actor SequencedFakeProbe: UsageProbing {
    let sourceID = "claude1"
    let label = "C1"
    let enabled = true
    private var callCount = 0

    func readUsage() async -> UsageSnapshot {
        callCount += 1
        if callCount == 1 {
            return UsageSnapshot(
                sourceID: sourceID, label: label, enabled: true,
                percentUsed: 22, status: .ok, updatedAt: nil, errorMessage: nil,
                fiveHour: ProviderUsageWindow(percentUsed: 22, resetDescription: "Resets in 3h"),
                oneWeek: ProviderUsageWindow(percentUsed: 61, resetDescription: "Resets Jun 30")
            )
        }
        // Second cycle: overall status is still `.ok`, but this time only
        // fiveHour parsed — oneWeek came back nil despite no reported failure.
        return UsageSnapshot(
            sourceID: sourceID, label: label, enabled: true,
            percentUsed: 25, status: .ok, updatedAt: nil, errorMessage: nil,
            fiveHour: ProviderUsageWindow(percentUsed: 25, resetDescription: "Resets in 2h45m"),
            oneWeek: nil
        )
    }
}
let sequencedMonitorSource = SourceConfig(
    id: "claude1", label: "C1", enabled: true, mode: .fixture, command: nil
)
let sequencedMonitor = UsageMonitor(
    config: AppConfig(refreshIntervalSeconds: 30, sources: [sequencedMonitorSource]),
    probes: [SequencedFakeProbe()]
)
_ = await sequencedMonitor.refresh()
let partialSuccessSnapshots = await sequencedMonitor.refresh()
let partialSuccessSnapshot = partialSuccessSnapshots.first { $0.sourceID == "claude1" }
check(partialSuccessSnapshot?.status == .ok, "partial-success refresh should keep reporting .ok")
check(partialSuccessSnapshot?.fiveHour?.percentUsed == 25, "partial-success refresh should use the freshly parsed fiveHour")
check(partialSuccessSnapshot?.oneWeek?.percentUsed == 61, "partial-success refresh should preserve the last-known-good oneWeek instead of blanking it")

let redrawnClaudeOutput = """
Curret session
0% used
Reses 3:29pm
Current week (all models)
0% used
"""
let redrawnClaudeResult = try ClaudeCLIUsageProbe.parse(redrawnClaudeOutput)
check(redrawnClaudeResult.session?.percentUsed == 0, "Claude parser should tolerate TUI-redrawn session labels")
check(redrawnClaudeResult.weekly?.percentUsed == 0, "Claude parser should preserve weekly ordering after TUI redraw")

let rpcResponse: [String: Any] = [
    "result": [
        "rateLimits": [
            "planType": "plus",
            "primary": ["usedPercent": 25.0, "resetsAt": 1_900_000_000],
            "secondary": ["usedPercent": 40.0, "resetsAt": 1_900_100_000]
        ]
    ]
]
let codexResult = try CodexRPCClient.parseRateLimitsResponse(rpcResponse)
check(codexResult.primary?.percentUsed == 25, "Codex RPC parser should read primary percent")
check(codexResult.secondary?.percentUsed == 40, "Codex RPC parser should read secondary percent")

let credentialFixture = Data(#"{"claudeAiOauth":{"accessToken":"fixture-access","refreshToken":"fixture-refresh","expiresAt":1900000000000,"subscriptionType":"pro","scopes":["user:profile"]}}"#.utf8)
let parsedCredentials = try ClaudeCodeCredentialImporter.parseCredentials(credentialFixture)
check(parsedCredentials.accessToken == "fixture-access", "Claude credential parser should read access token")
check(parsedCredentials.refreshToken == "fixture-refresh", "Claude credential parser should read refresh token")
check(parsedCredentials.expiresAtMilliseconds == 1_900_000_000_000, "Claude credential parser should read expiry")

let profile = ClaudeProfile(
    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
    name: "Example Profile",
    accountLabel: "account@example.invalid"
)
let profileSource = SourceConfig(
    id: "claude-example",
    label: "CX",
    enabled: true,
    mode: .claudeOAuth,
    command: nil,
    quota: .session,
    claudeProfile: profile
)
let profileConfig = AppConfig(refreshIntervalSeconds: 30, sources: [profileSource])
let encodedProfileConfig = try JSONEncoder().encode(profileConfig)
let encodedProfileText = String(decoding: encodedProfileConfig, as: UTF8.self)
check(encodedProfileText.contains("Example Profile"), "profile metadata should persist in config")
check(!encodedProfileText.contains("fixture-access"), "OAuth access token must never persist in config")
check(!encodedProfileText.contains("fixture-refresh"), "OAuth refresh token must never persist in config")

let oauthUsageFixture = Data(#"{"five_hour":{"utilization":22.4,"resets_at":"2030-03-17T12:30:00.000Z"},"seven_day":{"utilization":61.1,"resets_at":"2030-03-20T18:45:00Z"}}"#.utf8)
let oauthUsage = try ClaudeOAuthUsageService.parseUsageResponse(oauthUsageFixture)
check(oauthUsage.session?.percentUsed == 22, "Claude OAuth parser should read five-hour usage")
check(oauthUsage.weekly?.percentUsed == 61, "Claude OAuth parser should read weekly usage")
check(oauthUsage.extra.isEmpty, "Claude OAuth parser should report no extras when limits is absent")

let oauthUsageUpdatedFixture = Data(#"{"five_hour":{"utilization":44.0,"resets_at":"2030-03-17T12:30:00.000Z"},"seven_day":{"utilization":66.0,"resets_at":"2030-03-20T18:45:00Z"}}"#.utf8)
let cacheProfileID = UUID()
let cacheStore = MemoryClaudeCredentialStore()
try cacheStore.save(
    ClaudeOAuthCredentials(
        accessToken: "cache-fixture-access",
        refreshToken: nil,
        expiresAtMilliseconds: (Date().timeIntervalSince1970 + 3600) * 1_000
    ),
    profileID: cacheProfileID
)
let cacheTransport = QueueHTTPTransport(responses: [
    HTTPResult(data: oauthUsageFixture, statusCode: 200),
    HTTPResult(data: oauthUsageUpdatedFixture, statusCode: 200)
])
let cacheService = ClaudeOAuthUsageService(
    store: cacheStore,
    transport: cacheTransport,
    cacheTTL: 3600,
    minForceFetchInterval: 0
)
let cachedUsageFirst = try await cacheService.fetch(profileID: cacheProfileID)
let cachedUsageSecond = try await cacheService.fetch(profileID: cacheProfileID)
check(cachedUsageFirst.session?.percentUsed == 22, "Claude OAuth cache fixture should start with first usage value")
check(cachedUsageSecond.session?.percentUsed == 22, "Claude OAuth should reuse cache while cache TTL is active")
let cachedRequests = await cacheTransport.requests
check(cachedRequests.count == 1, "Claude OAuth should avoid duplicate HTTP calls inside cache TTL")
let forcedUsage = try await cacheService.fetch(profileID: cacheProfileID, force: true)
check(forcedUsage.session?.percentUsed == 44, "forced Claude OAuth refresh should bypass cache and read fresh usage")
let forcedRequests = await cacheTransport.requests
check(forcedRequests.count == 2, "forced Claude OAuth refresh should make a new HTTP call")

// Force throttle: rapid manual refreshes must not each hit the network. A
// client-side floor (minForceFetchInterval) serves cache instead — this is
// what stops button-spamming from tripping the server's 429 rate limit.
let throttleProfileID = UUID()
let throttleStore = MemoryClaudeCredentialStore()
try throttleStore.save(
    ClaudeOAuthCredentials(
        accessToken: "throttle-access",
        refreshToken: nil,
        expiresAtMilliseconds: (Date().timeIntervalSince1970 + 3600) * 1_000
    ),
    profileID: throttleProfileID
)
let throttleTransport = QueueHTTPTransport(responses: [
    HTTPResult(data: oauthUsageFixture, statusCode: 200),
    HTTPResult(data: oauthUsageUpdatedFixture, statusCode: 200)
])
let throttleService = ClaudeOAuthUsageService(
    store: throttleStore,
    transport: throttleTransport,
    cacheTTL: 0,
    minForceFetchInterval: 3600
)
let throttleFirst = try await throttleService.fetch(profileID: throttleProfileID, force: true)
let throttleSecond = try await throttleService.fetch(profileID: throttleProfileID, force: true)
check(throttleFirst.session?.percentUsed == 22, "first forced fetch reads live usage")
check(throttleSecond.session?.percentUsed == 22, "a forced fetch inside the throttle window is served from cache")
let throttleRequests = await throttleTransport.requests
check(throttleRequests.count == 1, "force throttle should collapse rapid manual refreshes to a single HTTP call")

// Rate-limit visibility: a 429 must surface as a thrown rateLimited error (so
// the status bar can grey the stale value), never be masked by silently
// returning the cached value as if it were a fresh success. The lock then
// keeps throwing on subsequent fetches without making extra HTTP calls.
let rateLimitProfileID = UUID()
let rateLimitStore = MemoryClaudeCredentialStore()
try rateLimitStore.save(
    ClaudeOAuthCredentials(
        accessToken: "ratelimit-access",
        refreshToken: nil,
        expiresAtMilliseconds: (Date().timeIntervalSince1970 + 3600) * 1_000
    ),
    profileID: rateLimitProfileID
)
let rateLimitTransport = QueueHTTPTransport(responses: [
    HTTPResult(data: oauthUsageFixture, statusCode: 200),
    HTTPResult(data: Data(), statusCode: 429, headers: ["retry-after": "300"])
])
let rateLimitService = ClaudeOAuthUsageService(
    store: rateLimitStore,
    transport: rateLimitTransport,
    cacheTTL: 0,
    minForceFetchInterval: 0
)
_ = try await rateLimitService.fetch(profileID: rateLimitProfileID, force: true)
var rateLimitThrew = false
do {
    _ = try await rateLimitService.fetch(profileID: rateLimitProfileID, force: true)
} catch let error as ClaudeOAuthUsageError {
    if case .rateLimited = error { rateLimitThrew = true }
} catch {}
check(rateLimitThrew, "a 429 should surface as a rateLimited error, not a silent cached success")
var rateLimitStillLocked = false
do {
    _ = try await rateLimitService.fetch(profileID: rateLimitProfileID, force: true)
} catch let error as ClaudeOAuthUsageError {
    if case .rateLimited = error { rateLimitStillLocked = true }
} catch {}
check(rateLimitStillLocked, "while rate-limited the lock stays visible on subsequent fetches")
let rateLimitRequests = await rateLimitTransport.requests
check(rateLimitRequests.count == 2, "no extra HTTP calls should be made while the retry-after lock is active")

// Save & Refresh reuses one persistent OAuth service across config applies, so a
// server rate-limit lock (retryAfter) survives the monitor/probe rebuild instead
// of being forgotten — reapplying settings can no longer hammer a rate-limited
// endpoint or silently reset the force throttle.
let persistProfileID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
let persistStore = MemoryClaudeCredentialStore()
try persistStore.save(
    ClaudeOAuthCredentials(
        accessToken: "persist-access",
        refreshToken: nil,
        expiresAtMilliseconds: (Date().timeIntervalSince1970 + 3600) * 1_000
    ),
    profileID: persistProfileID
)
let persistTransport = QueueHTTPTransport(responses: [
    HTTPResult(data: Data(), statusCode: 429, headers: ["retry-after": "300"])
])
let persistService = ClaudeOAuthUsageService(
    store: persistStore,
    transport: persistTransport,
    cacheTTL: 0,
    minForceFetchInterval: 0
)
do { _ = try await persistService.fetch(profileID: persistProfileID, force: true) } catch {}
let persistProfile = ClaudeProfile(
    id: persistProfileID,
    name: "Persist Profile",
    accountLabel: "persist@example.invalid"
)
let persistSource = SourceConfig(
    id: "persist-example",
    label: "PX",
    enabled: true,
    mode: .claudeOAuth,
    command: nil,
    quota: .session,
    claudeProfile: persistProfile
)
let persistConfig = AppConfig(refreshIntervalSeconds: 30, sources: [persistSource])
let persistProbes = UsageProbeFactory.makeProbes(config: persistConfig, oauthService: persistService)
let persistSnapshot = await persistProbes.first!.readUsage()
check(persistSnapshot.status == .failed, "a rebuilt-but-reused OAuth service keeps the rate-limit lock across a config apply")
let persistRequests = await persistTransport.requests
check(persistRequests.count == 1, "reusing the service across a config apply makes no extra HTTP call while still locked")

// Real-world shape observed from the live API: a "limits" array with a
// model-scoped entry (scope.model.display_name) for extra per-model quotas
// like a "Fable" weekly cap, alongside the plain session/weekly_all entries.
let oauthUsageWithExtraFixture = Data(#"""
{
  "five_hour": {"utilization": 51, "resets_at": "2030-03-17T12:30:00Z"},
  "seven_day": {"utilization": 31, "resets_at": "2030-03-20T18:45:00Z"},
  "limits": [
    {"group": "session", "kind": "session", "percent": 51, "resets_at": "2030-03-17T12:30:00Z"},
    {"group": "weekly", "kind": "weekly_all", "percent": 31, "resets_at": "2030-03-20T18:45:00Z"},
    {"group": "weekly", "kind": "weekly_scoped", "percent": 19, "resets_at": "2030-03-20T18:45:00Z",
     "scope": {"model": {"display_name": "Fable", "id": null}}}
  ]
}
"""#.utf8)
let oauthUsageWithExtra = try ClaudeOAuthUsageService.parseUsageResponse(oauthUsageWithExtraFixture)
check(oauthUsageWithExtra.extra["Fable"]?.percentUsed == 19, "Claude OAuth parser should extract model-scoped extra limits like Fable")
check(oauthUsageWithExtra.extra.count == 1, "Claude OAuth parser should ignore limits without a model scope")
// Regression: resetsAt must come from the ISO instant directly, not from a
// locale-formatted round-trip through resetDescription (which silently
// failed — and left resetsAt nil — on any non-English-month system locale).
check(oauthUsageWithExtra.extra["Fable"]?.resetsAt != nil, "extra window resetsAt should parse directly from the ISO date, not via locale text round-trip")
check(oauthUsageWithExtra.weekly?.resetsAt != nil, "weekly window resetsAt should parse directly from the ISO date")

let refreshProfileID = UUID()
let memoryStore = MemoryClaudeCredentialStore()
try memoryStore.save(
    ClaudeOAuthCredentials(
        accessToken: "expired-fixture-access",
        refreshToken: "fixture-refresh-one",
        expiresAtMilliseconds: 0
    ),
    profileID: refreshProfileID
)
let refreshResponse = HTTPResult(
    data: Data(#"{"access_token":"fresh-fixture-access","refresh_token":"fixture-refresh-two","expires_in":3600}"#.utf8),
    statusCode: 200
)
let usageResponse = HTTPResult(data: oauthUsageFixture, statusCode: 200)
let queueTransport = QueueHTTPTransport(responses: [refreshResponse, usageResponse])
let refreshService = ClaudeOAuthUsageService(
    store: memoryStore,
    transport: queueTransport,
    cacheTTL: 0
)
let refreshedUsage = try await refreshService.fetch(profileID: refreshProfileID, force: true)
check(refreshedUsage.session?.percentUsed == 22, "refreshed OAuth credentials should fetch usage")
let rotatedCredentials = try memoryStore.load(profileID: refreshProfileID)
check(rotatedCredentials?.accessToken == "fresh-fixture-access", "refreshed access token should persist in credential store")
check(rotatedCredentials?.refreshToken == "fixture-refresh-two", "rotated refresh token should persist in credential store")
let recordedRequests = await queueTransport.requests
check(recordedRequests.count == 2, "expired credentials should refresh once before usage request")

let historyDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("ai-usage-history-check-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: historyDirectory) }

let historyStore = UsageHistoryStore(directory: historyDirectory)
let historyNow = Calendar.current.date(from: DateComponents(
    year: 2026, month: 7, day: 3, hour: 17, minute: 30, second: 0
))!
let historyTooOld = historyNow.addingTimeInterval(-25 * 60 * 60)
let historyYesterdayInsideWindow = historyNow.addingTimeInterval(-23 * 60 * 60)
let historyToday = historyNow.addingTimeInterval(-30 * 60)
let historyEncoder = JSONEncoder()
historyEncoder.dateEncodingStrategy = .secondsSince1970
let historyFormatter = DateFormatter()
historyFormatter.dateFormat = "yyyy-MM-dd"

func writeHistoryFixture(_ entries: [UsageHistoryEntry], for date: Date) throws {
    let path = historyDirectory.appendingPathComponent("\(historyFormatter.string(from: date)).jsonl")
    var data = Data()
    for entry in entries {
        data.append(try historyEncoder.encode(entry))
        data.append(UInt8(ascii: "\n"))
    }
    try data.write(to: path, options: .atomic)
}

try writeHistoryFixture([
    UsageHistoryEntry(ts: historyTooOld, sources: ["codex": .init(fiveHour: 90, oneWeek: 9)]),
    UsageHistoryEntry(ts: historyYesterdayInsideWindow, sources: ["codex": .init(fiveHour: 10, oneWeek: 1)])
], for: historyYesterdayInsideWindow)
try writeHistoryFixture([
    UsageHistoryEntry(ts: historyToday, sources: ["codex": .init(fiveHour: 20, oneWeek: 2)])
], for: historyToday)

let rollingDayHistory = await historyStore.load(days: 1, now: historyNow)
check(rollingDayHistory.map(\.ts) == [historyYesterdayInsideWindow, historyToday], "24h history should be rolling, not calendar-day only")
let todayStart = Calendar.current.startOfDay(for: historyNow)
let todayHistory = await historyStore.load(from: todayStart, to: historyNow)
check(todayHistory.map(\.ts) == [historyToday], "today history should start at local midnight")

if ProcessInfo.processInfo.environment["AI_USAGE_LIVE_CLAUDE_OAUTH_CHECK"] == "1" {
    let liveProfileID = UUID()
    let liveStore = KeychainClaudeCredentialStore()
    defer { try? liveStore.delete(profileID: liveProfileID) }
    _ = try ClaudeCodeCredentialImporter(store: liveStore).importCurrentAccount(
        profileID: liveProfileID,
        preferredName: "Temporary Live Check"
    )
    let liveService = ClaudeOAuthUsageService(store: liveStore, cacheTTL: 0)
    let liveUsage = try await liveService.fetch(profileID: liveProfileID, force: true)
    check(liveUsage.session != nil || liveUsage.weekly != nil, "live Claude OAuth check should return usage")
    print("Live Claude OAuth check passed")
}

// CodexAccountReader: decodes only the non-secret `email` claim from a local
// id_token, purely for display in Settings ("which account is this probing?").
let codexAccountFixtureHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("ai-usage-codex-account-check-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: codexAccountFixtureHome) }
try FileManager.default.createDirectory(at: codexAccountFixtureHome.appendingPathComponent(".codex"), withIntermediateDirectories: true)
let fakeJWTPayload = try JSONSerialization.data(withJSONObject: ["email": "test@example.com", "sub": "user-123"])
let fakeJWT = "eyJhbGciOiJub25lIn0." + fakeJWTPayload.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "") + ".fakesig"
let codexAuthFixture = try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": fakeJWT]])
try codexAuthFixture.write(to: codexAccountFixtureHome.appendingPathComponent(".codex/auth.json"))
check(
    CodexAccountReader.currentAccountEmail(homeDirectory: codexAccountFixtureHome) == "test@example.com",
    "CodexAccountReader should decode the email claim from the local id_token"
)
check(
    CodexAccountReader.currentAccountEmail(homeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ai-usage-codex-account-missing-\(UUID().uuidString)")) == nil,
    "CodexAccountReader should return nil when no auth.json exists, not throw"
)

// UsageEstimator: "how long can I keep working at this pace" projection.
let estimatorNow = Date(timeIntervalSince1970: 1_800_000_000)
let estimatorReset = estimatorNow.addingTimeInterval(3 * 3600) // 3h until reset

// Steady burn over 30 minutes, 20% used -> 40% used: rate implies ~50 more
// minutes to 100%, which lands well before the 3h reset, so it should show.
let steadyBurnPoints: [(ts: Date, pct: Int)] = [
    (estimatorNow.addingTimeInterval(-30 * 60), 20),
    (estimatorNow, 40)
]
let steadyEstimate = UsageEstimator.timeUntilExhausted(
    points: steadyBurnPoints, currentPct: 40, resetsAt: estimatorReset, now: estimatorNow
)
check(steadyEstimate != nil, "estimator should project exhaustion when the pace would run out before reset")
if let steadyEstimate {
    check(abs(steadyEstimate - 90 * 60) < 60, "estimator should project ~90 minutes remaining at this burn rate, got \(steadyEstimate)s")
}

// Same rate, but reset is very soon (5 min) — reset wins, no estimate needed.
let resetWinsEstimate = UsageEstimator.timeUntilExhausted(
    points: steadyBurnPoints, currentPct: 40, resetsAt: estimatorNow.addingTimeInterval(5 * 60), now: estimatorNow
)
check(resetWinsEstimate == nil, "estimator should stay silent when the reset would come before exhaustion")

// Same reset-wins scenario, but with onlyIfBeforeReset disabled (the "always
// show" setting) — the projection should still be returned even though the
// reset would come first.
let alwaysShowEstimate = UsageEstimator.timeUntilExhausted(
    points: steadyBurnPoints, currentPct: 40, resetsAt: estimatorNow.addingTimeInterval(5 * 60), now: estimatorNow,
    onlyIfBeforeReset: false
)
check(alwaysShowEstimate != nil, "estimator with onlyIfBeforeReset=false should still project even when reset comes first")
if let alwaysShowEstimate {
    check(abs(alwaysShowEstimate - 90 * 60) < 60, "estimator with onlyIfBeforeReset=false should project the same ~90 minutes, got \(alwaysShowEstimate)s")
}

// Too little elapsed time (5 min) since the first sample — not enough signal yet.
let tooEarlyPoints: [(ts: Date, pct: Int)] = [
    (estimatorNow.addingTimeInterval(-5 * 60), 20),
    (estimatorNow, 40)
]
let tooEarlyEstimate = UsageEstimator.timeUntilExhausted(
    points: tooEarlyPoints, currentPct: 40, resetsAt: estimatorReset, now: estimatorNow
)
check(tooEarlyEstimate == nil, "estimator should require a minimum elapsed span before projecting")

// Flat usage (no progress) must not divide by zero or return a bogus value.
let flatPoints: [(ts: Date, pct: Int)] = [
    (estimatorNow.addingTimeInterval(-30 * 60), 40),
    (estimatorNow, 40)
]
let flatEstimate = UsageEstimator.timeUntilExhausted(
    points: flatPoints, currentPct: 40, resetsAt: estimatorReset, now: estimatorNow
)
check(flatEstimate == nil, "estimator should return nil for flat/no-progress usage instead of dividing by zero")

// HistoryTrimmer: a cycle can reset while usage was still low, so a reset
// might only produce a small drop — this must still be detected as a reset,
// not glued onto the new cycle as leftover history from the old one. Uses
// the exact real-world numbers that surfaced the bug: a cycle ending at 9%
// resets to 0%, then climbs to 17% — the drop is only 9, below the old flat
// "10" threshold.
let trimmerBase = Date(timeIntervalSince1970: 1_800_000_000)
let smallDropResetPoints: [(ts: Date, pct: Int)] = [
    (trimmerBase, 0),
    (trimmerBase.addingTimeInterval(600), 9),      // end of old cycle
    (trimmerBase.addingTimeInterval(1200), 0),      // reset (drop of only 9)
    (trimmerBase.addingTimeInterval(1800), 1),
    (trimmerBase.addingTimeInterval(2400), 10),
    (trimmerBase.addingTimeInterval(3000), 17)
]
let trimmedSmallDropReset = HistoryTrimmer.trimToCurrentCycle(smallDropResetPoints)
check(trimmedSmallDropReset.count == 4, "trimmer should drop the previous cycle's tail even when the reset drop is smaller than the old flat threshold")
check(trimmedSmallDropReset.first?.pct == 0, "trimmed history should start at the reset (0%), not the old cycle's 9%")

// A same-cycle wobble (±1 read noise) must not be mistaken for a reset —
// it never lands near zero.
let noisyPoints: [(ts: Date, pct: Int)] = [
    (trimmerBase, 30),
    (trimmerBase.addingTimeInterval(600), 33),
    (trimmerBase.addingTimeInterval(1200), 32),    // -1 wobble, not a reset
    (trimmerBase.addingTimeInterval(1800), 35)
]
let trimmedNoisy = HistoryTrimmer.trimToCurrentCycle(noisyPoints)
check(trimmedNoisy.count == 4, "trimmer should not mistake a small same-cycle wobble for a reset")

// A genuine large drop (the common case) must still be caught.
let bigDropPoints: [(ts: Date, pct: Int)] = [
    (trimmerBase, 37),
    (trimmerBase.addingTimeInterval(600), 0),
    (trimmerBase.addingTimeInterval(1200), 5)
]
let trimmedBigDrop = HistoryTrimmer.trimToCurrentCycle(bigDropPoints)
check(trimmedBigDrop.count == 2, "trimmer should still catch a large drop as a reset")

// HistoryBlockMerger: consecutive equal-percent samples merge into one
// group; a change in value always starts a new group.
let mergedFlatRun = HistoryBlockMerger.mergedGroups(pcts: [4, 4, 4, 9, 15, 15, 22])
check(mergedFlatRun.count == 4, "merger should collapse each flat run into a single group")
check(mergedFlatRun[0].range == 0...2 && mergedFlatRun[0].pct == 4, "first group should span the three leading 4%% samples")
check(mergedFlatRun[1].range == 3...3 && mergedFlatRun[1].pct == 9, "a lone changed value should form its own single-index group")
check(mergedFlatRun[2].range == 4...5 && mergedFlatRun[2].pct == 15, "second flat run should span its two samples")
check(mergedFlatRun[3].range == 6...6 && mergedFlatRun[3].pct == 22, "trailing single value should form its own group")

let mergedNoRepeats = HistoryBlockMerger.mergedGroups(pcts: [1, 2, 3])
check(mergedNoRepeats.count == 3, "merger should leave all-distinct values as separate single-index groups")

let mergedEmpty = HistoryBlockMerger.mergedGroups(pcts: [])
check(mergedEmpty.isEmpty, "merger should return no groups for empty input")

// ExtraQuotaUsageWatcher: notify once per quiet-then-active burst of usage
// on an extra/model-scoped window (e.g. a "Fable" cap).
let watcherNow = Date(timeIntervalSince1970: 1_800_000_000)

// First observation of a window (no previous reading — e.g. right after an app
// restart, where pre-existing usage is seen for the first time) must NOT notify:
// it only establishes a baseline. Otherwise every restart fires, because existing
// usage looks like a fresh 0 -> N jump.
let firstObservation = ExtraQuotaUsageWatcher.evaluate(
    previousPercent: nil, currentPercent: 19, lastIncreaseAt: nil, now: watcherNow
)
check(!firstObservation.shouldNotify, "watcher must not notify on the first observation of a window (baseline only, e.g. after a restart)")
check(firstObservation.lastIncreaseAt == nil, "a baseline observation must not stamp an increase time")

// After a baseline, an actual observed increase between two readings does notify
// (usage genuinely resumed) — this is the real signal the feature is meant for.
let increaseAfterBaseline = ExtraQuotaUsageWatcher.evaluate(
    previousPercent: 19, currentPercent: 22, lastIncreaseAt: nil, now: watcherNow
)
check(increaseAfterBaseline.shouldNotify, "watcher should notify on a real observed increase after the baseline")
check(increaseAfterBaseline.lastIncreaseAt == watcherNow, "watcher should stamp the increase time")

let continuedBurst = ExtraQuotaUsageWatcher.evaluate(
    previousPercent: 3, currentPercent: 6, lastIncreaseAt: watcherNow, now: watcherNow.addingTimeInterval(5 * 60)
)
check(!continuedBurst.shouldNotify, "watcher should stay silent for a continued burst within the quiet period")
check(continuedBurst.lastIncreaseAt == watcherNow.addingTimeInterval(5 * 60), "watcher should still refresh the increase timestamp during a continued burst")

let flatUsage = ExtraQuotaUsageWatcher.evaluate(
    previousPercent: 6, currentPercent: 6, lastIncreaseAt: watcherNow, now: watcherNow.addingTimeInterval(10 * 60)
)
check(!flatUsage.shouldNotify, "watcher should not notify when the percent hasn't changed")
check(flatUsage.lastIncreaseAt == watcherNow, "watcher should leave the increase timestamp untouched when nothing changed")

let resetDrop = ExtraQuotaUsageWatcher.evaluate(
    previousPercent: 40, currentPercent: 0, lastIncreaseAt: watcherNow, now: watcherNow.addingTimeInterval(60)
)
check(!resetDrop.shouldNotify, "watcher should not treat a reset (percent drop) as new usage")

let freshStartAfterQuiet = ExtraQuotaUsageWatcher.evaluate(
    previousPercent: 6, currentPercent: 9, lastIncreaseAt: watcherNow, now: watcherNow.addingTimeInterval(31 * 60)
)
check(freshStartAfterQuiet.shouldNotify, "watcher should notify again once usage resumes after the quiet period elapses")

let stillWithinQuiet = ExtraQuotaUsageWatcher.evaluate(
    previousPercent: 6, currentPercent: 9, lastIncreaseAt: watcherNow, now: watcherNow.addingTimeInterval(29 * 60)
)
check(!stillWithinQuiet.shouldNotify, "watcher should stay silent for usage that resumes just under the quiet period")

// NotificationRules: standard-window edge detection (threshold / limit / reset),
// all on the raw used percent so the remaining-countdown display never affects it.
let baselineEvents = NotificationRules.evaluateStandardWindow(
    previousPercent: nil, currentPercent: 95,
    thresholdEnabled: true, thresholdPercentUsed: 90, limitEnabled: true, resetEnabled: true
)
check(baselineEvents.isEmpty, "no notification on the first observation of a window (baseline, e.g. after a restart)")

let crossedThreshold = NotificationRules.evaluateStandardWindow(
    previousPercent: 88, currentPercent: 91,
    thresholdEnabled: true, thresholdPercentUsed: 90, limitEnabled: true, resetEnabled: true
)
check(crossedThreshold == [.thresholdCrossed], "threshold fires exactly when the used percent crosses up through the level")

let stayedAboveThreshold = NotificationRules.evaluateStandardWindow(
    previousPercent: 91, currentPercent: 93,
    thresholdEnabled: true, thresholdPercentUsed: 90, limitEnabled: true, resetEnabled: true
)
check(stayedAboveThreshold.isEmpty, "threshold does not re-fire while staying above the level")

let hitLimit = NotificationRules.evaluateStandardWindow(
    previousPercent: 97, currentPercent: 100,
    thresholdEnabled: false, thresholdPercentUsed: 90, limitEnabled: true, resetEnabled: true
)
check(hitLimit == [.limitReached], "limit fires when the window reaches 100%")

let didReset = NotificationRules.evaluateStandardWindow(
    previousPercent: 80, currentPercent: 1,
    thresholdEnabled: true, thresholdPercentUsed: 90, limitEnabled: true, resetEnabled: true
)
check(didReset == [.reset], "a large drop is reported as a reset and nothing else")

let readNoise = NotificationRules.evaluateStandardWindow(
    previousPercent: 33, currentPercent: 32,
    thresholdEnabled: true, thresholdPercentUsed: 90, limitEnabled: true, resetEnabled: true
)
check(readNoise.isEmpty, "a 1-point same-cycle wobble is neither a reset nor a threshold crossing")

let thresholdDisabled = NotificationRules.evaluateStandardWindow(
    previousPercent: 88, currentPercent: 91,
    thresholdEnabled: false, thresholdPercentUsed: 90, limitEnabled: false, resetEnabled: false
)
check(thresholdDisabled.isEmpty, "disabled notification types never fire")

// NotificationStateStore round-trips the persistent per-window bookkeeping.
let notifyStateDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("ai-usage-notify-check-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: notifyStateDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: notifyStateDir) }
let notifyStore = NotificationStateStore(url: notifyStateDir.appendingPathComponent("notify-state.json"))
check(notifyStore.load().isEmpty, "missing notification state file loads as empty")
let stamped = Date(timeIntervalSince1970: 1_800_000_000)
notifyStore.save([
    "claude1|extra|Fable": NotificationWindowState(lastPercent: 19, lastIncreaseAt: stamped),
    "claude1|5-hour": NotificationWindowState(lastPercent: 90, paceFired: true)
])
let reloaded = notifyStore.load()
check(reloaded["claude1|extra|Fable"]?.lastPercent == 19, "notification state persists last-seen percent across a reload (restart)")
check(reloaded["claude1|extra|Fable"]?.lastIncreaseAt == stamped, "notification state persists the quiet-period timestamp across a reload")
check(reloaded["claude1|5-hour"]?.paceFired == true, "notification state persists the pace-fired flag across a reload")

print("AIUsageChecks passed")
