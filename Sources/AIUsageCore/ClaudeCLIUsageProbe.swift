import Foundation
import SwiftTerm

public struct ClaudeCLIUsageProbe: UsageProbing {
    public let sourceID: String
    public let label: String
    public let enabled: Bool

    private let command: CommandConfig?
    private let configDirectory: String?
    private let quota: QuotaSelection
    private let runner: InteractivePTYRunner

    public init(
        sourceID: String,
        label: String,
        enabled: Bool,
        command: CommandConfig?,
        configDirectory: String?,
        quota: QuotaSelection,
        runner: InteractivePTYRunner = InteractivePTYRunner()
    ) {
        self.sourceID = sourceID
        self.label = label
        self.enabled = enabled
        self.command = command
        self.configDirectory = configDirectory
        self.quota = quota
        self.runner = runner
    }

    public func readUsage() async -> UsageSnapshot {
        guard enabled else { return disabledSnapshot() }
        guard let command else { return failure("Missing Claude CLI settings") }

        do {
            let result = try await Task.detached(priority: .utility) {
                var environment = command.environment
                if let configDirectory, !configDirectory.trimmingCharacters(in: .whitespaces).isEmpty {
                    environment["CLAUDE_CONFIG_DIR"] = NSString(string: configDirectory).expandingTildeInPath
                }

                return try runner.run(
                    executable: command.executable,
                    arguments: ["/usage", "--allowed-tools", ""],
                    environment: environment,
                    timeout: command.timeoutSeconds,
                    autoResponses: [
                        "Accessing": "\r",
                        "/usage": "\r",
                        "Esc to cancel": "\r",
                        "Ready to code here?": "\r",
                        "Press Enter to continue": "\r",
                        "ctrl+t to disable": "\r",
                        "Yes, I trust this folder": "\r"
                    ]
                )
            }.value

            let parsed: ClaudeUsageResult
            do {
                parsed = try Self.parse(result.output)
            } catch {
                if ProcessInfo.processInfo.environment["AI_USAGE_DEBUG_OUTPUT"] == "1" {
                    return failure("\(error.localizedDescription) | \(Self.debugSummary(result.output))")
                }
                throw error
            }
            let selected = quota == .weekly ? parsed.weekly : parsed.session
            guard let selected else {
                return failure("Claude did not report \(quota.displayName.lowercased()) usage")
            }

            return UsageSnapshot(
                sourceID: sourceID,
                label: label,
                enabled: enabled,
                percentUsed: selected.percentUsed,
                status: .ok,
                updatedAt: Date(),
                resetDescription: selected.resetDescription,
                errorMessage: nil,
                fiveHour: parsed.session,
                oneWeek: parsed.weekly
            )
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private static let renderer = TerminalRenderer()

    public static func parse(_ raw: String) throws -> ClaudeUsageResult {
        let text = renderer.render(raw)
        let lower = text.lowercased()

        if lower.contains("not logged in") || lower.contains("please log in") || lower.contains("login required") {
            throw ClaudeUsageError("Claude is not logged in for this profile")
        }
        if lower.contains("only available for subscription plans") {
            throw ClaudeUsageError("Claude /usage requires a subscription login")
        }

        var session = extractWindow(labels: ["Current session"], text: text)
        var weekly = extractWindow(labels: ["Current week (all models)", "Current week"], text: text)

        // Claude's TUI redraw turns every \r into \n, padding the text with many blank lines.
        // extractWindow's 14-line window is often too narrow to capture the reset line.
        // Fall back: scan the whole text for reset descriptions in document order.
        let resets = allResetDescriptions(in: text)  // ordered: session first, weekly second

        // Claude's TUI redraw can overwrite individual label characters in raw PTY output.
        // The /usage screen is stable in ordering: session first, weekly second.
        let orderedPercents = orderedUsagePercents(in: text)
        if session == nil, let first = orderedPercents.first {
            session = ProviderUsageWindow(percentUsed: first, resetDescription: resets.first)
        }
        if weekly == nil, orderedPercents.count > 1 {
            // Use second distinct reset description if available, otherwise none
            let weeklyReset = resets.count > 1 ? resets[1] : nil
            weekly = ProviderUsageWindow(percentUsed: orderedPercents[1], resetDescription: weeklyReset)
        }

        // Patch missing reset descriptions if extractWindow found the window but missed the reset line
        if session != nil, session?.resetDescription == nil, let r = resets.first {
            session = ProviderUsageWindow(percentUsed: session!.percentUsed, resetDescription: r)
        }
        if weekly != nil, weekly?.resetDescription == nil {
            // Fall back to session reset when both windows share the same reset schedule
            let weeklyReset = resets.count > 1 ? resets[1] : resets.first
            if let r = weeklyReset {
                weekly = ProviderUsageWindow(percentUsed: weekly!.percentUsed, resetDescription: r)
            }
        }

        // 0% usage: section headers visible but no "N% used/left" pattern in output
        let lowerText = text.lowercased()
        if session == nil, lowerText.contains("current session") {
            session = ProviderUsageWindow(percentUsed: 0, resetDescription: resets.first)
        }
        if weekly == nil, lowerText.contains("current week") {
            weekly = ProviderUsageWindow(percentUsed: 0, resetDescription: resets.count > 1 ? resets[1] : resets.first)
        }

        guard session != nil || weekly != nil else {
            throw ClaudeUsageError("Could not parse Claude /usage output")
        }
        return ClaudeUsageResult(session: session, weekly: weekly)
    }

    // Collect all non-empty lines containing "reset" in document order.
    // In Claude's /usage output: session reset appears before weekly reset.
    private static func allResetDescriptions(in text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.localizedCaseInsensitiveContains("reset") }
            .filter { seen.insert($0).inserted }  // deduplicate TUI redraw repetitions
    }

    private static func extractWindow(labels: [String], text: String) -> ProviderUsageWindow? {
        let lines = text.components(separatedBy: .newlines)
        for label in labels {
            guard let index = lines.firstIndex(where: { $0.localizedCaseInsensitiveContains(label) }) else {
                continue
            }
            let window = lines[index..<min(lines.count, index + 14)]
            for line in window {
                if let percent = percentUsed(from: line) {
                    let reset = window.first(where: { $0.localizedCaseInsensitiveContains("reset") })?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return ProviderUsageWindow(percentUsed: percent, resetDescription: reset)
                }
            }
        }
        return nil
    }

    private static func percentUsed(from line: String) -> Int? {
        if let value = regexPercent(pattern: #"([0-9]{1,3})\s*%\s*used"#, line: line) {
            return min(100, max(0, value))
        }
        if let value = regexPercent(pattern: #"([0-9]{1,3})\s*%\s*left"#, line: line) {
            return min(100, max(0, 100 - value))
        }
        return nil
    }

    private static func orderedUsagePercents(in text: String) -> [Int] {
        let pattern = #"([0-9]{1,3})\s*%\s*(used|left)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: text),
                  let modeRange = Range(match.range(at: 2), in: text),
                  let value = Int(text[valueRange]) else { return nil }
            let mode = text[modeRange].lowercased()
            return mode == "left" ? 100 - value : value
        }
    }

    private static func regexPercent(pattern: String, line: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let valueRange = Range(match.range(at: 1), in: line) else { return nil }
        return Int(line[valueRange])
    }

    private static func debugSummary(_ text: String) -> String {
        let normalized = renderer.render(text)
            .replacingOccurrences(of: "\n", with: " | ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(1200))
    }

    private func disabledSnapshot() -> UsageSnapshot {
        UsageSnapshot(sourceID: sourceID, label: label, enabled: false, percentUsed: nil, status: .disabled, updatedAt: Date(), errorMessage: nil)
    }

    private func failure(_ message: String) -> UsageSnapshot {
        UsageSnapshot(sourceID: sourceID, label: label, enabled: enabled, percentUsed: nil, status: .failed, updatedAt: Date(), errorMessage: message)
    }
}

public struct ClaudeUsageResult: Equatable, Sendable {
    public let session: ProviderUsageWindow?
    public let weekly: ProviderUsageWindow?
}

private struct ClaudeUsageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
