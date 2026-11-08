import Darwin
import Foundation

public struct CodexRPCUsageProbe: UsageProbing {
    public let sourceID: String
    public let label: String
    public let enabled: Bool

    private let command: CommandConfig?
    private let quota: QuotaSelection

    public init(
        sourceID: String,
        label: String,
        enabled: Bool,
        command: CommandConfig?,
        quota: QuotaSelection
    ) {
        self.sourceID = sourceID
        self.label = label
        self.enabled = enabled
        self.command = command
        self.quota = quota
    }

    public func readUsage() async -> UsageSnapshot {
        guard enabled else {
            return UsageSnapshot(sourceID: sourceID, label: label, enabled: false, percentUsed: nil, status: .disabled, updatedAt: Date(), errorMessage: nil)
        }
        guard let command else { return failure("Missing Codex RPC settings", kind: .notConfigured) }

        do {
            let result = try await Task.detached(priority: .utility) {
                try CodexRPCClient.fetch(command: command)
            }.value
            let selected = result.selectedWindow(for: quota)
            guard let selected else {
                return failure("Codex did not report \(quota.displayName.lowercased()) usage")
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
                fiveHour: result.fiveHour,
                oneWeek: result.oneWeek,
                standardWindowsAuthoritative: true
            )
        } catch let error as CodexRPCError {
            return failure(error.localizedDescription, kind: error.failure)
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private func failure(_ message: String, kind: UsageFailure? = nil) -> UsageSnapshot {
        UsageSnapshot(sourceID: sourceID, label: label, enabled: enabled, percentUsed: nil, status: .failed, updatedAt: Date(), errorMessage: message, failure: kind)
    }
}

public struct CodexRateLimitResult: Equatable, Sendable {
    public let primary: ProviderUsageWindow?
    public let secondary: ProviderUsageWindow?
    public let fiveHour: ProviderUsageWindow?
    public let oneWeek: ProviderUsageWindow?
    public let planType: String?

    public init(
        primary: ProviderUsageWindow?,
        secondary: ProviderUsageWindow?,
        fiveHour: ProviderUsageWindow? = nil,
        oneWeek: ProviderUsageWindow? = nil,
        planType: String?
    ) {
        self.primary = primary
        self.secondary = secondary
        self.fiveHour = fiveHour
        self.oneWeek = oneWeek
        self.planType = planType
    }

    public func selectedWindow(for quota: QuotaSelection) -> ProviderUsageWindow? {
        switch quota {
        case .session:
            // During Codex rollout tests the account may expose only the
            // weekly cap. In that case the menu bar should still show the real
            // available quota rather than failing because "Session" was saved
            // in an older/default config.
            return fiveHour ?? oneWeek ?? primary ?? secondary
        case .weekly:
            return oneWeek ?? fiveHour ?? secondary ?? primary
        }
    }
}

public enum CodexRPCClient {
    /// Start variants for `codex app-server`, tried in order. Optional flags
    /// changed between CLI releases before (`-a untrusted` disappeared in
    /// 0.16x and broke every check while the login itself was fine), so no
    /// single variant is hard-wired: the first one the installed CLI accepts
    /// wins and is remembered per CLI version.
    public static let argumentLadder: [[String]] = [
        ["-s", "read-only", "app-server"],
        ["app-server"]
    ]

    private static let memo = CodexArgumentMemo()
    private static let ignoreSIGPIPE: Void = {
        // A CLI that rejects its arguments exits before reading stdin; writing
        // the handshake into that closed pipe must fail with EPIPE instead of
        // killing the app.
        signal(SIGPIPE, SIG_IGN)
    }()

    public static func fetch(command: CommandConfig) throws -> CodexRateLimitResult {
        _ = ignoreSIGPIPE
        let executable = NSString(string: command.executable).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CodexRPCError("Missing executable: \(executable)", failure: .notConfigured)
        }
        let version = cliVersion(executable: executable)
        let key = "\(executable)|\(version ?? "unknown")"
        let first = memo.workingIndex(for: key) ?? 0
        let order = Array(first..<argumentLadder.count) + Array(0..<first)

        var rejection: CodexRPCError?
        for index in order {
            do {
                let result = try fetch(command: command, executable: executable, arguments: argumentLadder[index])
                memo.remember(index, for: key)
                return result
            } catch let error as CodexRPCError where error.isArgumentRejection {
                rejection = error
            }
        }
        let detail = rejection?.message.split(separator: "\n").first.map(String.init) ?? "no start variant was accepted"
        throw CodexRPCError(
            "Codex CLI \(version ?? "") is not compatible with AI Usage yet: \(detail)",
            failure: .incompatible
        )
    }

    /// `codex --version` → "0.166.0", cached until the binary behind the
    /// (usually symlinked) path changes, e.g. after `brew upgrade`.
    public static func cliVersion(executable: String) -> String? {
        let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let modified = (try? FileManager.default.attributesOfItem(atPath: resolved.path)[.modificationDate] as? Date) ?? nil
        let cacheKey = "\(resolved.path)|\(modified?.timeIntervalSince1970 ?? 0)"
        if let cached = memo.version(for: cacheKey) { return cached }
        guard let result = try? CommandRunner().run(CommandConfig(executable: executable, arguments: ["--version"], timeoutSeconds: 5)),
              result.exitCode == 0 else { return nil }
        let version = parseVersion(result.standardOutput)
        if let version { memo.rememberVersion(version, for: cacheKey) }
        return version
    }

    public static func parseVersion(_ output: String) -> String? {
        guard let range = output.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    /// stderr of a CLI that refused its command line (clap-style parser).
    public static func isArgumentRejection(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return ["invalid value", "unexpected argument", "possible values", "unrecognized subcommand", "unrecognized option"]
            .contains(where: text.contains)
    }

    private static func fetch(command: CommandConfig, executable: String, arguments: [String]) throws -> CodexRateLimitResult {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = safeWorkingDirectory()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        process.environment = processEnvironment(merging: command.environment)

        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? error.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(1)
                while process.isRunning && Date() < deadline { usleep(25_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        }

        let outputFD = output.fileHandleForReading.fileDescriptor
        _ = fcntl(outputFD, F_SETFL, O_NONBLOCK)
        var buffer = Data()
        var nextID = 1

        func exitError() -> CodexRPCError {
            process.waitUntilExit()
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if isArgumentRejection(stderr) {
                return CodexRPCError(stderr, failure: .incompatible, isArgumentRejection: true)
            }
            return CodexRPCError(stderr.isEmpty ? "Codex app-server exited unexpectedly" : stderr)
        }

        func send(method: String, params: [String: Any] = [:], notification: Bool = false) throws -> Int? {
            var payload: [String: Any] = ["method": method, "params": params]
            let id: Int?
            if notification {
                id = nil
            } else {
                id = nextID
                payload["id"] = nextID
                nextID += 1
            }
            let data = try JSONSerialization.data(withJSONObject: payload) + Data([0x0A])
            do {
                try input.fileHandleForWriting.write(contentsOf: data)
            } catch {
                throw exitError()
            }
            return id
        }

        func receive(id: Int, timeout: TimeInterval) throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                readAvailable(fd: outputFD, into: &buffer)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    guard !line.isEmpty,
                          let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                        continue
                    }
                    guard let messageID = (message["id"] as? NSNumber)?.intValue, messageID == id else {
                        continue
                    }
                    if let rpcError = message["error"] as? [String: Any] {
                        let text = rpcError["message"] as? String ?? "Codex RPC error"
                        let isAuth = text.lowercased().contains("authentication required") || text.lowercased().contains("not logged in")
                        throw CodexRPCError(isAuth ? "Codex is not signed in for this account" : text, failure: isAuth ? .authentication : nil)
                    }
                    return message
                }
                if !process.isRunning {
                    throw exitError()
                }
                usleep(20_000)
            }
            throw CodexRPCError("Codex RPC timed out", failure: .network)
        }

        let initializeID = try send(
            method: "initialize",
            params: ["clientInfo": ["name": "ai-usage", "version": "1.0.0"]]
        )!
        _ = try receive(id: initializeID, timeout: command.timeoutSeconds)
        _ = try send(method: "initialized", notification: true)

        let limitsID = try send(method: "account/rateLimits/read")!
        let response = try receive(id: limitsID, timeout: command.timeoutSeconds)
        return try parseRateLimitsResponse(response)
    }

    public static func parseRateLimitsResponse(_ response: [String: Any]) throws -> CodexRateLimitResult {
        guard let result = response["result"] as? [String: Any],
              let rateLimits = result["rateLimits"] as? [String: Any] else {
            throw CodexRPCError("Invalid Codex rate limits response")
        }

        let primaryParsed = parseWindow(rateLimits["primary"])
        let secondaryParsed = parseWindow(rateLimits["secondary"])
        let primary = primaryParsed?.window
        let secondary = secondaryParsed?.window
        guard primary != nil || secondary != nil else {
            throw CodexRPCError("No Codex rate limits available yet")
        }

        let standard = classifyStandardWindows(primary: primaryParsed, secondary: secondaryParsed)
        return CodexRateLimitResult(
            primary: primary,
            secondary: secondary,
            fiveHour: standard.fiveHour,
            oneWeek: standard.oneWeek,
            planType: rateLimits["planType"] as? String
        )
    }

    private struct ParsedCodexWindow {
        let window: ProviderUsageWindow
        let resetsAt: Date?
        let hintedKind: CodexWindowKind?
    }

    private enum CodexWindowKind {
        case fiveHour
        case oneWeek
    }

    private static func parseWindow(_ value: Any?) -> ParsedCodexWindow? {
        guard let dict = value as? [String: Any],
              let number = dict["usedPercent"] as? NSNumber else {
            return nil
        }
        let used = min(100, max(0, Int(number.doubleValue.rounded())))
        let resetsAt: Date?
        if let rawResetsAt = dict["resetsAt"] as? NSNumber {
            resetsAt = Date(timeIntervalSince1970: rawResetsAt.doubleValue)
        } else {
            resetsAt = nil
        }
        return ParsedCodexWindow(
            window: ProviderUsageWindow(
                percentUsed: used,
                resetDescription: resetsAt.map(resetText),
                resetsAt: resetsAt
            ),
            resetsAt: resetsAt,
            hintedKind: kindHint(from: dict, resetsAt: resetsAt)
        )
    }

    private static func classifyStandardWindows(
        primary: ParsedCodexWindow?,
        secondary: ParsedCodexWindow?
    ) -> (fiveHour: ProviderUsageWindow?, oneWeek: ProviderUsageWindow?) {
        var fiveHour: ProviderUsageWindow?
        var oneWeek: ProviderUsageWindow?

        func assign(_ parsed: ParsedCodexWindow?, fallback: CodexWindowKind) {
            guard let parsed else { return }
            switch parsed.hintedKind ?? fallback {
            case .fiveHour:
                if fiveHour == nil { fiveHour = parsed.window }
                else if oneWeek == nil { oneWeek = parsed.window }
            case .oneWeek:
                if oneWeek == nil { oneWeek = parsed.window }
                else if fiveHour == nil { fiveHour = parsed.window }
            }
        }

        if primary != nil && secondary != nil {
            // Historical Codex shape: primary = 5-hour, secondary = weekly.
            // Explicit hints still win if the RPC starts labeling windows.
            assign(primary, fallback: .fiveHour)
            assign(secondary, fallback: .oneWeek)
        } else {
            // New test shape can expose only one weekly window. With no hint,
            // keep the old assumption for a sole primary and weekly for a sole
            // secondary, but reset distance can identify the weekly-only case.
            assign(primary, fallback: .fiveHour)
            assign(secondary, fallback: .oneWeek)
        }

        return (fiveHour, oneWeek)
    }

    private static func kindHint(from dict: [String: Any], resetsAt: Date?) -> CodexWindowKind? {
        let text = dict.values.compactMap { value -> String? in
            switch value {
            case let string as String:
                return string.lowercased()
            case let nested as [String: Any]:
                return nested.values.compactMap { $0 as? String }.joined(separator: " ").lowercased()
            default:
                return nil
            }
        }.joined(separator: " ")

        if text.contains("five_hour") || text.contains("5-hour") || text.contains("5 hour") || text.contains("5h") || text.contains("session") {
            return .fiveHour
        }
        if text.contains("seven_day") || text.contains("7-day") || text.contains("7 day") || text.contains("7d") || text.contains("weekly") || text.contains("week") {
            return .oneWeek
        }

        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSinceNow
        if remaining > 24 * 3600 {
            return .oneWeek
        }
        if remaining > 0 && remaining <= 12 * 3600 {
            return .fiveHour
        }
        return nil
    }

    private static func resetText(_ date: Date) -> String {
        let interval = max(0, date.timeIntervalSinceNow)
        let days = Int(interval / 86_400)
        let hours = Int(interval.truncatingRemainder(dividingBy: 86_400) / 3_600)
        let minutes = Int(interval.truncatingRemainder(dividingBy: 3_600) / 60)
        if days > 0 { return "Resets in \(days)d \(hours)h" }
        if hours > 0 { return "Resets in \(hours)h \(minutes)m" }
        return "Resets in \(minutes)m"
    }

    private static func readAvailable(fd: Int32, into data: inout Data) {
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else { break }
            data.append(contentsOf: bytes.prefix(count))
        }
    }

    private static func safeWorkingDirectory() -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ai-usage", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Environment for the Codex process. `CODEX_HOME` may be stored with a
    /// leading `~` (shorter in the config, readable in Settings); Codex itself
    /// does not expand it, so it is resolved here.
    public static func processEnvironment(merging custom: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let fallbackPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existing = environment["PATH"], !existing.isEmpty {
            environment["PATH"] = "\(fallbackPath):\(existing)"
        } else {
            environment["PATH"] = fallbackPath
        }
        environment.merge(custom) { _, new in new }
        if let home = environment["CODEX_HOME"], home.hasPrefix("~") {
            environment["CODEX_HOME"] = NSString(string: home).expandingTildeInPath
        }
        return environment
    }
}

struct CodexRPCError: LocalizedError {
    let message: String
    let failure: UsageFailure?
    let isArgumentRejection: Bool

    init(_ message: String, failure: UsageFailure? = nil, isArgumentRejection: Bool = false) {
        self.message = message
        self.failure = failure
        self.isArgumentRejection = isArgumentRejection
    }

    var errorDescription: String? { message }
}

/// Remembers, per CLI binary and version, which `argumentLadder` entry
/// worked, so only a CLI update costs an extra failed start.
private final class CodexArgumentMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var working: [String: Int] = [:]
    private var versions: [String: String] = [:]

    func workingIndex(for key: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return working[key]
    }

    func remember(_ index: Int, for key: String) {
        lock.lock(); defer { lock.unlock() }
        working[key] = index
    }

    func version(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return versions[key]
    }

    func rememberVersion(_ version: String, for key: String) {
        lock.lock(); defer { lock.unlock() }
        versions[key] = version
    }
}
