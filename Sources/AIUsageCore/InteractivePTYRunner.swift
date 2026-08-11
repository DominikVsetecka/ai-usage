import Darwin
import Foundation

public struct PTYCommandResult: Sendable {
    public let output: String
    public let exitCode: Int32
}

public enum PTYRunnerError: LocalizedError, Sendable {
    case missingExecutable(String)
    case launchFailed(String)
    case timedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingExecutable(let path): "Missing executable: \(path)"
        case .launchFailed(let message): "Could not launch CLI: \(message)"
        case .timedOut: "CLI usage probe timed out"
        case .cancelled: "CLI operation was cancelled"
        }
    }
}

public final class PTYCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var pendingInput: [Data] = []

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Queues one line of interactive input for the running PTY command.
    /// This is used by browser-based authentication flows that occasionally
    /// fall back to asking for an authorization code in the terminal.
    public func sendLine(_ line: String) {
        lock.lock()
        pendingInput.append(Data((line + "\n").utf8))
        lock.unlock()
    }

    fileprivate var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    fileprivate func takePendingInput() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        let input = pendingInput
        pendingInput.removeAll(keepingCapacity: true)
        return input
    }
}

public struct InteractivePTYRunner: Sendable {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        autoResponses: [String: String],
        removedEnvironmentKeys: Set<String> = ["CLAUDE_CODE_OAUTH_TOKEN"],
        cancellationToken: PTYCancellationToken? = nil,
        outputHandler: (@Sendable (String) -> Void)? = nil
    ) throws -> PTYCommandResult {
        let executablePath = NSString(string: executable).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw PTYRunnerError.missingExecutable(executablePath)
        }

        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var size = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &size) == 0 else {
            throw PTYRunnerError.launchFailed("Could not create pseudo-terminal")
        }

        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)
        let primary = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondary = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = Self.safeWorkingDirectory()
        process.standardInput = secondary
        process.standardOutput = secondary
        process.standardError = secondary

        var processEnvironment = Self.processEnvironment(merging: environment)
        for key in removedEnvironmentKeys {
            processEnvironment.removeValue(forKey: key)
        }
        processEnvironment["TERM"] = "xterm-256color"
        processEnvironment["COLORTERM"] = "truecolor"
        process.environment = processEnvironment

        do {
            try process.run()
        } catch {
            try? primary.close()
            try? secondary.close()
            throw PTYRunnerError.launchFailed(error.localizedDescription)
        }

        var output = Data()
        var responded = Set<String>()
        var lastMeaningfulData = Date()
        let deadline = Date().addingTimeInterval(timeout)
        var wasCancelled = false

        while Date() < deadline {
            if cancellationToken?.isCancelled == true {
                wasCancelled = true
                break
            }

            for input in cancellationToken?.takePendingInput() ?? [] {
                try? primary.write(contentsOf: input)
                lastMeaningfulData = Date()
            }

            let before = output.count
            Self.readAvailable(fd: primaryFD, into: &output)
            if output.count > before {
                lastMeaningfulData = Date()
                outputHandler?(String(data: output, encoding: .utf8) ?? "")
            }

            let text = String(data: output, encoding: .utf8) ?? ""
            for (prompt, response) in autoResponses where !responded.contains(prompt) && text.contains(prompt) {
                if let data = response.data(using: .utf8) {
                    try? primary.write(contentsOf: data)
                    responded.insert(prompt)
                    lastMeaningfulData = Date()
                }
            }

            if !process.isRunning {
                break
            }

            if Self.hasUsageContent(text), Date().timeIntervalSince(lastMeaningfulData) > 2.5 {
                break
            }

            usleep(50_000)
        }

        Self.readAvailable(fd: primaryFD, into: &output)
        let didTimeOut = process.isRunning && !Self.hasUsageContent(String(data: output, encoding: .utf8) ?? "")

        if process.isRunning {
            process.terminate()
            let stopDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < stopDeadline {
                usleep(50_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()

        try? primary.close()
        try? secondary.close()

        if wasCancelled {
            throw PTYRunnerError.cancelled
        }
        if didTimeOut && output.isEmpty {
            throw PTYRunnerError.timedOut
        }

        return PTYCommandResult(
            output: String(data: output, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    private static func safeWorkingDirectory() -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ai-usage", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func processEnvironment(merging custom: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let fallbackPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existing = environment["PATH"], !existing.isEmpty {
            environment["PATH"] = "\(fallbackPath):\(existing)"
        } else {
            environment["PATH"] = fallbackPath
        }
        environment.merge(custom) { _, new in new }
        return environment
    }

    private static func readAvailable(fd: Int32, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func hasUsageContent(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("current session") ||
            lower.contains("current week") ||
            lower.contains("% used") ||
            lower.contains("%used") ||
            lower.contains("% left") ||
            lower.contains("%left") ||
            lower.contains("currentweek") ||
            lower.contains("not logged in") {
            return true
        }

        var normalized = lower
        let ansiPatterns = [
            #"\x1B\][^\x07]*(?:\x07|\x1B\\)"#,
            #"\x1B\[[0-?]*[ -/]*[@-~]"#,
            #"\x1B[()][AB012]"#
        ]
        for pattern in ansiPatterns {
            normalized = normalized.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let compact = normalized.filter { !$0.isWhitespace }
        return compact.contains("%used") || compact.contains("%left") || compact.contains("notloggedin")
    }
}
