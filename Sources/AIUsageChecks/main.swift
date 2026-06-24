import AIUsageCore
import Foundation

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
try countdownConfig.save(to: temporaryConfigURL)
let reloadedConfig = try AppConfig.load(from: temporaryConfigURL)
check(reloadedConfig == countdownConfig, "saved settings should load without changes")
check(reloadedConfig.showsRemainingCountdown, "countdown setting should persist")
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

print("AIUsageChecks passed")
