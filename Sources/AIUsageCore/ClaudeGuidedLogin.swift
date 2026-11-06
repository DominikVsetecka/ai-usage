import Foundation

public struct ClaudeChromeProfile: Equatable, Hashable, Identifiable, Sendable {
    public let directoryName: String
    public let displayName: String
    public let accountEmail: String?

    public var id: String { directoryName }

    public init(directoryName: String, displayName: String, accountEmail: String? = nil) {
        self.directoryName = directoryName
        self.displayName = displayName
        self.accountEmail = accountEmail
    }
}

public struct ClaudeGuidedLoginResult: Equatable, Sendable {
    public let configDirectory: String
    public let accountLabel: String

    public init(configDirectory: String, accountLabel: String) {
        self.configDirectory = configDirectory
        self.accountLabel = accountLabel
    }
}

public struct ClaudeAuthStatus: Equatable, Sendable {
    public let loggedIn: Bool
    public let accountEmail: String?

    public init(loggedIn: Bool, accountEmail: String? = nil) {
        self.loggedIn = loggedIn
        self.accountEmail = accountEmail
    }
}

public enum ClaudeGuidedLoginError: LocalizedError, Equatable, Sendable {
    case invalidEmail
    case noChromeProfiles
    case loginFailed
    case loginTimedOut
    case cancelled
    case statusUnavailable
    case authenticationNotCompleted
    case wrongAccount(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .invalidEmail:
            "Enter the Claude account email address"
        case .noChromeProfiles:
            "No Google Chrome profiles were found"
        case .loginFailed:
            "Claude login did not complete. Retry and finish the browser sign-in."
        case .loginTimedOut:
            "Claude login timed out before browser sign-in completed"
        case .cancelled:
            "Claude login was cancelled"
        case .statusUnavailable:
            "Claude could not verify the new isolated login"
        case .authenticationNotCompleted:
            "The isolated Claude account is not signed in yet"
        case .wrongAccount(let expected, let actual):
            "The browser signed in as \(actual) instead of \(expected). Switch to \(expected) in the selected Chrome profile, then retry."
        }
    }
}

public struct ClaudeChromeProfileReader: Sendable {
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func profiles() -> [ClaudeChromeProfile] {
        let url = homeDirectory
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Self.parseProfiles(data)
    }

    public static func parseProfiles(_ data: Data) -> [ClaudeChromeProfile] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else {
            return []
        }

        return cache.compactMap { directoryName, raw -> ClaudeChromeProfile? in
            guard let details = raw as? [String: Any] else { return nil }
            let name = (details["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = (details["user_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ClaudeChromeProfile(
                directoryName: directoryName,
                displayName: name?.isEmpty == false ? name! : directoryName,
                accountEmail: email?.isEmpty == false ? email : nil
            )
        }
        .sorted {
            if $0.directoryName == "Default" { return true }
            if $1.directoryName == "Default" { return false }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

public struct ClaudeGuidedLoginService: Sendable {
    /// An isolated login is only reused when its access token stays valid for
    /// at least this long. The Secure Profile refreshes 5 minutes before
    /// expiry and rotates the refresh token on the way, which leaves the
    /// isolated copy behind with an expired access token and a dead refresh
    /// token. `claude auth status` still reports such a copy as logged in, so
    /// the token's own expiry is the signal that it may have gone stale.
    public static let reusableLoginMinimumLifetime: TimeInterval = 30 * 60

    private let homeDirectory: URL
    private let runner: InteractivePTYRunner
    private let isolatedCredentials: @Sendable (String) -> ClaudeOAuthCredentials?

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        runner: InteractivePTYRunner = InteractivePTYRunner(),
        isolatedCredentials: @escaping @Sendable (String) -> ClaudeOAuthCredentials? = {
            try? ClaudeCodeCredentialImporter().isolatedCredentials(configDirectory: $0)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.runner = runner
        self.isolatedCredentials = isolatedCredentials
    }

    public func login(
        connectionID: String,
        email: String,
        usesSSO: Bool,
        chromeProfile: ClaudeChromeProfile?,
        claudeExecutable: String,
        cancellationToken: PTYCancellationToken? = nil,
        outputHandler: (@Sendable (String) -> Void)? = nil
    ) throws -> ClaudeGuidedLoginResult {
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanEmail.contains("@"), !cleanEmail.contains(" ") else {
            throw ClaudeGuidedLoginError.invalidEmail
        }

        let configURL = Self.configDirectory(homeDirectory: homeDirectory, connectionID: connectionID)
        try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: true)

        // A browser login may already have completed even if an earlier UI
        // attempt failed later while probing `/usage`. Reuse that isolated
        // credential instead of forcing another SSO round-trip, but only
        // while it is demonstrably fresh: once imported, the Secure Profile
        // rotates the refresh token and the isolated copy goes stale.
        if let existing = try? authenticationStatus(
            configDirectory: configURL.path,
            claudeExecutable: claudeExecutable
        ), existing.loggedIn,
           existing.accountEmail == nil ||
            existing.accountEmail?.localizedCaseInsensitiveCompare(cleanEmail) == .orderedSame,
           let credentials = isolatedCredentials(configURL.path),
           credentials.expiresAtMilliseconds != nil,
           !credentials.needsRefresh(buffer: Self.reusableLoginMinimumLifetime) {
            return ClaudeGuidedLoginResult(
                configDirectory: configURL.path,
                accountLabel: existing.accountEmail ?? cleanEmail
            )
        }

        // Without a Chrome profile (macOS can block reading Chrome's profile
        // list) Claude falls back to the default browser.
        var environment = ["CLAUDE_CONFIG_DIR": configURL.path]
        if let chromeProfile {
            environment["BROWSER"] = try prepareChromeBrowserHelper().path
            environment["AI_USAGE_CHROME_PROFILE"] = chromeProfile.directoryName
        }

        var arguments = ["auth", "login", "--claudeai", "--email", cleanEmail]
        if usesSSO { arguments.append("--sso") }

        let result: PTYCommandResult
        do {
            result = try runner.run(
                executable: claudeExecutable,
                arguments: arguments,
                environment: environment,
                timeout: 10 * 60,
                autoResponses: [:],
                removedEnvironmentKeys: Self.conflictingAuthenticationEnvironmentKeys,
                cancellationToken: cancellationToken,
                outputHandler: outputHandler
            )
        } catch PTYRunnerError.timedOut {
            throw ClaudeGuidedLoginError.loginTimedOut
        } catch PTYRunnerError.cancelled {
            throw ClaudeGuidedLoginError.cancelled
        } catch {
            throw error
        }
        guard result.exitCode == 0 else { throw ClaudeGuidedLoginError.loginFailed }

        let status = try authenticationStatus(
            configDirectory: configURL.path,
            claudeExecutable: claudeExecutable
        )
        guard status.loggedIn else { throw ClaudeGuidedLoginError.authenticationNotCompleted }
        // `--email` is only a hint: the browser authorizes whichever account
        // its claude.ai session belongs to.
        if let actual = status.accountEmail,
           actual.localizedCaseInsensitiveCompare(cleanEmail) != .orderedSame {
            throw ClaudeGuidedLoginError.wrongAccount(expected: cleanEmail, actual: actual)
        }

        return ClaudeGuidedLoginResult(
            configDirectory: configURL.path,
            accountLabel: status.accountEmail ?? cleanEmail
        )
    }

    public func authenticationStatus(
        configDirectory: String,
        claudeExecutable: String
    ) throws -> ClaudeAuthStatus {
        let result = try runner.run(
            executable: claudeExecutable,
            arguments: ["auth", "status", "--json"],
            environment: ["CLAUDE_CONFIG_DIR": configDirectory],
            timeout: 20,
            autoResponses: [:],
            removedEnvironmentKeys: Self.conflictingAuthenticationEnvironmentKeys
        )
        guard let status = Self.parseAuthStatus(result.output) else {
            throw ClaudeGuidedLoginError.statusUnavailable
        }
        return status
    }

    public func openInChrome(_ url: URL, profile: ClaudeChromeProfile) throws {
        let helper = try prepareChromeBrowserHelper()
        let process = Process()
        process.executableURL = helper
        process.arguments = [url.absoluteString]
        var environment = ProcessInfo.processInfo.environment
        environment["AI_USAGE_CHROME_PROFILE"] = profile.directoryName
        process.environment = environment
        try process.run()
    }

    public static func configDirectory(homeDirectory: URL, connectionID: String) -> URL {
        let safeID = connectionID.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? Character(String(scalar))
                : "-"
        }
        let component = String(safeID).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return homeDirectory
            .appendingPathComponent(".ai-usage/claude-accounts", isDirectory: true)
            .appendingPathComponent(component.isEmpty ? "claude" : component, isDirectory: true)
    }

    public static func parseAuthStatus(_ raw: String) -> ClaudeAuthStatus? {
        let stripped = raw.replacingOccurrences(
            of: #"\x1B\[[0-?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )
        guard let start = stripped.firstIndex(of: "{"),
              let end = stripped.lastIndex(of: "}"), start <= end,
              let data = String(stripped[start...end]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = root["loggedIn"] as? Bool else {
            return nil
        }
        return ClaudeAuthStatus(loggedIn: loggedIn, accountEmail: findEmail(in: root))
    }

    /// Claude Code prints a second OAuth URL whose redirect shows a code that
    /// can be pasted into the waiting PTY when localhost callback delivery is
    /// blocked by SSO, browser policy, VPN or profile isolation.
    public static func manualLoginURL(from output: String) -> URL? {
        let marker = "If the browser didn't open, visit:"
        guard let markerRange = output.range(of: marker) else { return nil }
        let remainder = output[markerRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawURL = remainder.split(whereSeparator: \.isWhitespace).first else {
            return nil
        }
        return URL(string: String(rawURL))
    }

    /// `open -a` drops `--args` when Chrome is already running, so the URL
    /// never reached the selected profile. `-n` starts a short-lived Chrome
    /// process that hands the profile and URL to the running instance.
    public static let chromeBrowserHelperScript = """
    #!/bin/zsh
    profile="${AI_USAGE_CHROME_PROFILE:-Default}"
    exec /usr/bin/open -na "Google Chrome" --args "--profile-directory=${profile}" "$@"
    """

    private static let conflictingAuthenticationEnvironmentKeys: Set<String> = [
        "CLAUDE_CODE_OAUTH_TOKEN",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN"
    ]

    private func prepareChromeBrowserHelper() throws -> URL {
        let directory = homeDirectory.appendingPathComponent(".ai-usage/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("open-claude-login-in-chrome")
        try Data(Self.chromeBrowserHelperScript.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private static func findEmail(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in ["email", "emailAddress", "accountEmail"] {
                if let email = dictionary[key] as? String, email.contains("@") { return email }
            }
            for nested in dictionary.values {
                if let email = findEmail(in: nested) { return email }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let email = findEmail(in: nested) { return email }
            }
        }
        return nil
    }
}
