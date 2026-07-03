import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
    public var refreshIntervalSeconds: TimeInterval
    public var remainingCountdownEnabled: Bool?
    public var menuBarFontSize: CGFloat?
    public var menuBarFontWeight: String?
    public var textColorMode: TextColorMode?
    public var sparklineDirection: SparklineDirection?
    public var sources: [SourceConfig]

    public init(
        refreshIntervalSeconds: TimeInterval,
        remainingCountdownEnabled: Bool = false,
        menuBarFontSize: CGFloat? = nil,
        menuBarFontWeight: String? = nil,
        textColorMode: TextColorMode? = nil,
        sparklineDirection: SparklineDirection? = nil,
        sources: [SourceConfig]
    ) {
        self.refreshIntervalSeconds = max(5, refreshIntervalSeconds)
        self.remainingCountdownEnabled = remainingCountdownEnabled
        self.menuBarFontSize = menuBarFontSize
        self.menuBarFontWeight = menuBarFontWeight
        self.textColorMode = textColorMode
        self.sparklineDirection = sparklineDirection
        self.sources = sources
    }

    public var showsRemainingCountdown: Bool {
        remainingCountdownEnabled ?? false
    }

    public static let `default` = AppConfig(
        refreshIntervalSeconds: 30,
        remainingCountdownEnabled: false,
        sources: [
            SourceConfig(
                id: "claude1",
                label: "C1",
                enabled: true,
                mode: .claudeCLI,
                command: CommandConfig(
                    executable: "/opt/homebrew/bin/claude",
                    timeoutSeconds: 20
                ),
                quota: .session,
                iconName: "claude"
            ),
            SourceConfig(
                id: "claude2",
                label: "C2",
                enabled: false,
                mode: .claudeCLI,
                command: CommandConfig(
                    executable: "/opt/homebrew/bin/claude",
                    timeoutSeconds: 20
                ),
                localPath: "~/.claude-account-2",
                quota: .session,
                iconName: "claude"
            ),
            SourceConfig(
                id: "codex",
                label: "GPT",
                enabled: true,
                mode: .codexRPC,
                command: CommandConfig(executable: "/opt/homebrew/bin/codex", timeoutSeconds: 15),
                quota: .session,
                iconName: "openai"
            )
        ]
    )

    public static func load(from url: URL?) throws -> AppConfig {
        guard let url else {
            return .default
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return .default
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(AppConfig.self, from: data).normalized()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func defaultConfigURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let override = environment["AI_USAGE_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }

        guard let home = environment["HOME"], !home.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: home)
            .appendingPathComponent(".ai-usage", isDirectory: true)
            .appendingPathComponent("config.json")
            .standardizedFileURL
    }

    private func normalized() -> AppConfig {
        var copy = self
        for index in copy.sources.indices {
            if copy.sources[index].label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                copy.sources[index].label = Self.defaultLabel(for: copy.sources[index].id)
            }
        }
        return copy
    }

    private static func defaultLabel(for sourceID: String) -> String {
        switch sourceID {
        case "claude1": "C1"
        case "claude2": "C2"
        case "codex": "GPT"
        default: sourceID
        }
    }
}

public struct SourceConfig: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var enabled: Bool
    public var mode: SourceMode
    public var command: CommandConfig?
    public var localPath: String?
    public var quota: QuotaSelection?
    public var iconName: String?
    public var iconData: String?     // Base64-encoded image (SVG/PNG); takes priority over iconName
    public var claudeProfile: ClaudeProfile?

    public init(
        id: String,
        label: String,
        enabled: Bool,
        mode: SourceMode,
        command: CommandConfig?,
        localPath: String? = nil,
        quota: QuotaSelection? = .session,
        iconName: String? = nil,
        iconData: String? = nil,
        claudeProfile: ClaudeProfile? = nil
    ) {
        self.id = id
        self.label = label
        self.enabled = enabled
        self.mode = mode
        self.command = command
        self.localPath = localPath
        self.quota = quota
        self.iconName = iconName
        self.iconData = iconData
        self.claudeProfile = claudeProfile
    }
}

public enum SourceMode: String, Codable, Equatable, Sendable {
    case fixture
    case command
    case claudeCLI
    case claudeOAuth
    case codexRPC
}

public enum TextColorMode: String, Codable, Equatable, CaseIterable, Sendable {
    case primary            // immer .labelColor (weiß/schwarz je nach Mode)
    case secondary          // immer .secondaryLabelColor (abgetöntes weiß)
    case percentageGradient // grün (0% verbraucht) → rot (100% verbraucht)
}

public enum SparklineDirection: String, Codable, Equatable, CaseIterable, Sendable {
    case ascending   // 0% at bottom, rises with usage (default)
    case descending  // 0% at top, drops as quota is consumed
}

public enum QuotaSelection: String, Codable, Equatable, CaseIterable, Sendable {
    case session
    case weekly

    public var displayName: String {
        switch self {
        case .session: "Session"
        case .weekly: "Week"
        }
    }
}

public struct CommandConfig: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var timeoutSeconds: TimeInterval

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        timeoutSeconds: TimeInterval = 5
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeoutSeconds = max(1, timeoutSeconds)
    }
}
