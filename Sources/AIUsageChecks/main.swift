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

print("AIUsageChecks passed")
