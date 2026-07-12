import Foundation

public struct FixtureUsageProbe: UsageProbing {
    public let sourceID: String
    public let label: String
    public let enabled: Bool
    private let percentUsed: Int?

    public init(sourceID: String, label: String, enabled: Bool, percentUsed: Int?) {
        self.sourceID = sourceID
        self.label = label
        self.enabled = enabled
        self.percentUsed = percentUsed
    }

    public func readUsage() async -> UsageSnapshot {
        UsageSnapshot(
            sourceID: sourceID,
            label: label,
            enabled: enabled,
            percentUsed: percentUsed,
            status: enabled ? .ok : .disabled,
            updatedAt: Date(),
            errorMessage: nil
        )
    }
}

public struct CommandUsageProbe: UsageProbing {
    public let sourceID: String
    public let label: String
    public let enabled: Bool
    private let command: CommandConfig?
    private let runner: CommandRunning

    public init(sourceID: String, label: String, enabled: Bool, command: CommandConfig?, runner: CommandRunning) {
        self.sourceID = sourceID
        self.label = label
        self.enabled = enabled
        self.command = command
        self.runner = runner
    }

    public func readUsage() async -> UsageSnapshot {
        guard enabled else {
            return UsageSnapshot(
                sourceID: sourceID,
                label: label,
                enabled: false,
                percentUsed: nil,
                status: .disabled,
                updatedAt: Date(),
                errorMessage: nil
            )
        }

        guard let command else {
            return failure("Missing command config")
        }

        do {
            let result = try runner.run(command)
            let combinedOutput = result.standardOutput + "\n" + result.standardError

            guard result.exitCode == 0 else {
                return failure("Command exited with \(result.exitCode)")
            }

            guard let percent = UsageParser.parsePercentUsed(from: combinedOutput) else {
                return failure("Could not parse usage percent")
            }

            return UsageSnapshot(
                sourceID: sourceID,
                label: label,
                enabled: enabled,
                percentUsed: percent,
                status: .ok,
                updatedAt: Date(),
                errorMessage: nil
            )
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private func failure(_ message: String) -> UsageSnapshot {
        UsageSnapshot(
            sourceID: sourceID,
            label: label,
            enabled: enabled,
            percentUsed: nil,
            status: .failed,
            updatedAt: Date(),
            errorMessage: message
        )
    }
}

public enum UsageProbeFactory {
    public static func makeProbes(
        config: AppConfig,
        runner: CommandRunning = CommandRunner(),
        oauthService: ClaudeOAuthUsageService? = nil
    ) -> [UsageProbing] {
        // Reuse a caller-provided OAuth service (kept alive across config
        // applies) so its cache and rate-limit backoff survive a Settings
        // "Save & Refresh"; only build a throwaway one when none is passed
        // (tests, one-off Test Connection) — using the long-lived default TTL
        // (see `ClaudeOAuthUsageService.defaultCacheTTL`), deliberately NOT
        // coupled to the UI refresh interval.
        let oauthUsageService = oauthService ?? ClaudeOAuthUsageService()
        return config.sources.map { source in
            switch source.mode {
            case .fixture:
                FixtureUsageProbe(
                    sourceID: source.id,
                    label: source.label,
                    enabled: source.enabled,
                    percentUsed: nil
                )
            case .command:
                CommandUsageProbe(
                    sourceID: source.id,
                    label: source.label,
                    enabled: source.enabled,
                    command: source.command,
                    runner: runner
                )
            case .claudeCLI:
                ClaudeCLIUsageProbe(
                    sourceID: source.id,
                    label: source.label,
                    enabled: source.enabled,
                    command: source.command,
                    configDirectory: source.localPath,
                    quota: source.quota ?? .session
                )
            case .claudeOAuth:
                ClaudeOAuthUsageProbe(
                    sourceID: source.id,
                    label: source.label,
                    enabled: source.enabled,
                    profile: source.claudeProfile,
                    quota: source.quota ?? .session,
                    service: oauthUsageService
                )
            case .codexRPC:
                CodexRPCUsageProbe(
                    sourceID: source.id,
                    label: source.label,
                    enabled: source.enabled,
                    command: source.command,
                    quota: source.quota ?? .session
                )
            }
        }
    }

}
