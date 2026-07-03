import Foundation

public struct CommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum CommandRunnerError: Error, Equatable, LocalizedError, Sendable {
    case missingExecutable(String)
    case timedOut(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .missingExecutable(let executable):
            "Missing executable: \(executable)"
        case .timedOut(let seconds):
            "Command timed out after \(Int(seconds))s"
        }
    }
}

public protocol CommandRunning: Sendable {
    func run(_ config: CommandConfig) throws -> CommandResult
}

public struct CommandRunner: CommandRunning {
    public init() {}

    public func run(_ config: CommandConfig) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: config.executable) else {
            throw CommandRunnerError.missingExecutable(config.executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.executable)
        process.arguments = config.arguments
        process.currentDirectoryURL = Self.safeWorkingDirectory()
        process.environment = Self.processEnvironment(merging: config.environment)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let deadline = Date().addingTimeInterval(config.timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            throw CommandRunnerError.timedOut(config.timeoutSeconds)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(data: outputData, encoding: .utf8) ?? "",
            standardError: String(data: errorData, encoding: .utf8) ?? ""
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
}
