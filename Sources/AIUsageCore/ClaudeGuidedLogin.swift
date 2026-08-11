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
    private let homeDirectory: URL
    private let runner: InteractivePTYRunner

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        runner: InteractivePTYRunner = InteractivePTYRunner()
    ) {
        self.homeDirectory = homeDirectory
        self.runner = runner
    }

    public func login(
        connectionID: String,
        email: String,
        usesSSO: Bool,
        chromeProfile: ClaudeChromeProfile,
        claudeExecutable: String,
        cancellationToken: PTYCancellationToken? = nil
    ) throws -> ClaudeGuidedLoginResult {
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanEmail.contains("@"), !cleanEmail.contains(" ") else {
            throw ClaudeGuidedLoginError.invalidEmail
        }

        let configURL = Self.configDirectory(homeDirectory: homeDirectory, connectionID: connectionID)
        try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: true)
        let browserHelper = try prepareChromeBrowserHelper()

        var arguments = ["auth", "login", "--claudeai", "--email", cleanEmail]
        if usesSSO { arguments.append("--sso") }

        let result: PTYCommandResult
        do {
            result = try runner.run(
                executable: claudeExecutable,
                arguments: arguments,
                environment: [
                    "CLAUDE_CONFIG_DIR": configURL.path,
                    "BROWSER": browserHelper.path,
                    "AI_USAGE_CHROME_PROFILE": chromeProfile.directoryName
                ],
                timeout: 10 * 60,
                autoResponses: [:],
                removedEnvironmentKeys: Self.conflictingAuthenticationEnvironmentKeys,
                cancellationToken: cancellationToken
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

    public static let chromeBrowserHelperScript = """
    #!/bin/zsh
    profile="${AI_USAGE_CHROME_PROFILE:-Default}"
    exec /usr/bin/open -a "Google Chrome" --args "--profile-directory=${profile}" "$@"
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
