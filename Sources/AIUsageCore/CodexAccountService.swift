import Foundation

/// Codex accounts beyond the default `~/.codex` login get their own
/// `CODEX_HOME` under `~/.ai-usage/codex-accounts/<id>`, so a second ChatGPT
/// login never touches the user's normal Codex setup.
public enum CodexAccountService {
    public static let defaultHome = "~/.codex"

    public static func appOwnedHome(accountID: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(".ai-usage/codex-accounts", isDirectory: true)
            .appendingPathComponent(accountID, isDirectory: true)
    }

    /// True only for folders AI Usage created itself — the only ones it may
    /// delete when an account is removed.
    public static func isAppOwned(_ path: String?, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let path else { return false }
        let root = homeDirectory.appendingPathComponent(".ai-usage/codex-accounts", isDirectory: true).standardizedFileURL.path
        let expanded = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
        return expanded.hasPrefix(root + "/")
    }

    public static func resolvedHome(_ path: String?) -> URL {
        URL(fileURLWithPath: NSString(string: path ?? defaultHome).expandingTildeInPath, isDirectory: true)
    }

    /// `codex login status` exits 0 when signed in.
    public static func isSignedIn(executable: String, codexHome: String?) -> Bool {
        var environment: [String: String] = [:]
        if let codexHome { environment["CODEX_HOME"] = resolvedHome(codexHome).path }
        let command = CommandConfig(executable: executable, arguments: ["login", "status"], environment: environment, timeoutSeconds: 15)
        return (try? CommandRunner().run(command))?.exitCode == 0
    }

    public static func accountEmail(codexHome: String?) -> String? {
        CodexAccountReader.accountEmail(codexHome: resolvedHome(codexHome))
    }

    /// Runs `codex login` (opens the browser) and returns once it exits.
    /// `onLoginURL` receives the fallback URL Codex prints for when no browser
    /// opened.
    public static func login(
        executable: String,
        codexHome: String,
        cancellation: ProcessCancellation,
        timeout: TimeInterval = 10 * 60,
        onLoginURL: @escaping @Sendable (URL) -> Void
    ) throws {
        let home = resolvedHome(codexHome)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: NSString(string: executable).expandingTildeInPath)
        process.arguments = ["login"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            let text = String(data: handle.availableData, encoding: .utf8) ?? ""
            if let url = loginURL(in: text) { onLoginURL(url) }
        }
        try process.run()
        cancellation.attach(process)
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            throw CodexLoginError.timedOut
        }
        if cancellation.isCancelled { throw CodexLoginError.cancelled }
        guard process.terminationStatus == 0 else { throw CodexLoginError.failed }
    }

    public static func loginURL(in text: String) -> URL? {
        guard let range = text.range(of: #"https://auth\.openai\.com/\S+"#, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }
}

public enum CodexLoginError: LocalizedError, Equatable {
    case timedOut, cancelled, failed

    public var errorDescription: String? {
        switch self {
        case .timedOut: "The Codex login timed out before the browser sign-in finished"
        case .cancelled: "The Codex login was cancelled"
        case .failed: "The Codex login didn't complete. Retry and finish the browser sign-in."
        }
    }
}

public final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func attach(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        if cancelled { process.terminate() }
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        process?.terminate()
    }
}
