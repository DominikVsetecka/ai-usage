import Foundation

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

    public static func parse(_ raw: String) throws -> ClaudeUsageResult {
        let text = normalizeTerminalOutput(raw)
        let lower = text.lowercased()

        if lower.contains("not logged in") || lower.contains("please log in") || lower.contains("login required") {
            throw ClaudeUsageError("Claude is not logged in for this profile")
        }
        if lower.contains("only available for subscription plans") {
            throw ClaudeUsageError("Claude /usage requires a subscription login")
        }

        var session = extractWindow(labels: ["Current session"], text: text)
        var weekly = extractWindow(labels: ["Current week (all models)", "Current week"], text: text)

        // Claude's TUI redraw can overwrite individual label characters in raw PTY output.
        // The /usage screen is stable in ordering: session first, weekly second.
        let orderedPercents = orderedUsagePercents(in: text)
        if session == nil, let first = orderedPercents.first {
            session = ProviderUsageWindow(percentUsed: first, resetDescription: nil)
        }
        if weekly == nil, orderedPercents.count > 1 {
            weekly = ProviderUsageWindow(percentUsed: orderedPercents[1], resetDescription: nil)
        }

        // 0% usage: section headers visible but no "N% used/left" pattern in output
        let lowerText = text.lowercased()
        if session == nil, lowerText.contains("current session") {
            session = ProviderUsageWindow(percentUsed: 0, resetDescription: nil)
        }
        if weekly == nil, lowerText.contains("current week") {
            weekly = ProviderUsageWindow(percentUsed: 0, resetDescription: nil)
        }

        guard session != nil || weekly != nil else {
            throw ClaudeUsageError("Could not parse Claude /usage output")
        }
        return ClaudeUsageResult(session: session, weekly: weekly)
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

    private static func normalizeTerminalOutput(_ text: String) -> String {
        var result = text
        let patterns = [
            #"\x1B\][^\x07]*(?:\x07|\x1B\\)"#,
            #"\x1B\[[0-?]*[ -/]*[@-~]"#,
            #"\x1B[()][AB012]"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result.replacingOccurrences(of: "\r", with: "\n")
    }

    private static func debugSummary(_ text: String) -> String {
        let normalized = normalizeTerminalOutput(text)
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
