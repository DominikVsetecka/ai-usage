import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
    public var refreshIntervalSeconds: TimeInterval
    public var remainingCountdownEnabled: Bool?
    public var menuBarFontSize: CGFloat?
    public var menuBarFontWeight: String?
    public var textColorMode: TextColorMode?
    public var sparklineDirection: SparklineDirection?
    public var visualBarMode: VisualBarMode?
    public var visualBlockWidth: VisualBlockWidth?
    public var visualHistoryStyle: VisualHistoryStyle?
    public var visualBarHeight: CGFloat?
    public var visualHistoryDarken: Double?
    public var popoverPercentFontSize: CGFloat?
    public var popoverPercentFontWeight: String?
    public var showUsageEstimate: Bool?
    public var alwaysShowUsageEstimate: Bool?
    public var mergeUnchangedHistoryBlocks: Bool?
    public var roundedHistorySteps: Bool?
    public var connectedHistorySteps: Bool?
    public var notifyOnExtraQuotaUsage: Bool?
    public var notifications: NotificationSettings?
    public var visualBlockGap: CGFloat?
    public var sources: [SourceConfig]

    public init(
        refreshIntervalSeconds: TimeInterval,
        remainingCountdownEnabled: Bool = false,
        menuBarFontSize: CGFloat? = nil,
        menuBarFontWeight: String? = nil,
        textColorMode: TextColorMode? = nil,
        sparklineDirection: SparklineDirection? = nil,
        visualBarMode: VisualBarMode? = nil,
        visualBlockWidth: VisualBlockWidth? = nil,
        visualHistoryStyle: VisualHistoryStyle? = nil,
        visualBarHeight: CGFloat? = nil,
        visualHistoryDarken: Double? = nil,
        popoverPercentFontSize: CGFloat? = nil,
        popoverPercentFontWeight: String? = nil,
        showUsageEstimate: Bool? = nil,
        alwaysShowUsageEstimate: Bool? = nil,
        mergeUnchangedHistoryBlocks: Bool? = nil,
        roundedHistorySteps: Bool? = nil,
        connectedHistorySteps: Bool? = nil,
        notifyOnExtraQuotaUsage: Bool? = nil,
        notifications: NotificationSettings? = nil,
        visualBlockGap: CGFloat? = nil,
        sources: [SourceConfig]
    ) {
        self.refreshIntervalSeconds = max(60, refreshIntervalSeconds)
        self.remainingCountdownEnabled = remainingCountdownEnabled
        self.menuBarFontSize = menuBarFontSize
        self.menuBarFontWeight = menuBarFontWeight
        self.textColorMode = textColorMode
        self.sparklineDirection = sparklineDirection
        self.visualBarMode = visualBarMode
        self.visualBlockWidth = visualBlockWidth
        self.visualHistoryStyle = visualHistoryStyle
        self.visualBarHeight = visualBarHeight
        self.visualHistoryDarken = visualHistoryDarken
        self.popoverPercentFontSize = popoverPercentFontSize
        self.popoverPercentFontWeight = popoverPercentFontWeight
        self.showUsageEstimate = showUsageEstimate
        self.alwaysShowUsageEstimate = alwaysShowUsageEstimate
        self.mergeUnchangedHistoryBlocks = mergeUnchangedHistoryBlocks
        self.roundedHistorySteps = roundedHistorySteps
        self.connectedHistorySteps = connectedHistorySteps
        self.notifyOnExtraQuotaUsage = notifyOnExtraQuotaUsage
        self.notifications = notifications
        self.visualBlockGap = visualBlockGap
        self.sources = sources
    }

    public var showsRemainingCountdown: Bool {
        remainingCountdownEnabled ?? false
    }

    public var resolvedVisualBarMode: VisualBarMode {
        visualBarMode ?? .time
    }

    public var resolvedVisualBlockWidth: VisualBlockWidth {
        visualBlockWidth ?? .medium
    }

    /// Gap between history blocks, in points. Defaults to the active block
    /// width preset's own gap (0 for Narrow, 2 for Medium) until the user
    /// overrides it via the slider — switching presets afterward keeps the
    /// override rather than resetting it.
    public static let visualBlockGapRange: ClosedRange<CGFloat> = 0...8

    public var resolvedVisualBlockGap: CGFloat {
        guard let visualBlockGap else { return resolvedVisualBlockWidth.metrics.gap }
        return min(Self.visualBlockGapRange.upperBound, max(Self.visualBlockGapRange.lowerBound, visualBlockGap))
    }

    public var resolvedVisualHistoryStyle: VisualHistoryStyle {
        visualHistoryStyle ?? .bars
    }

    public var resolvedShowUsageEstimate: Bool {
        showUsageEstimate ?? true
    }

    public var resolvedAlwaysShowUsageEstimate: Bool {
        alwaysShowUsageEstimate ?? false
    }

    public var resolvedMergeUnchangedHistoryBlocks: Bool {
        mergeUnchangedHistoryBlocks ?? false
    }

    public var resolvedRoundedHistorySteps: Bool {
        roundedHistorySteps ?? false
    }

    public var resolvedConnectedHistorySteps: Bool {
        connectedHistorySteps ?? false
    }

    public var resolvedNotifyOnExtraQuotaUsage: Bool {
        notifyOnExtraQuotaUsage ?? false
    }

    /// Resolved notification settings. When the new `notifications` block is
    /// absent (older configs), fall back to the legacy single `notifyOnExtra
    /// QuotaUsage` toggle so an existing Fable-notification preference keeps
    /// working, with every other notification type off until explicitly enabled.
    public var resolvedNotifications: NotificationSettings {
        if let notifications { return notifications }
        if notifyOnExtraQuotaUsage == true {
            return NotificationSettings(enabled: true, extraQuota: true)
        }
        return NotificationSettings()
    }

    public static let visualBarHeightRange: ClosedRange<CGFloat> = 8...56

    public var resolvedVisualBarHeight: CGFloat {
        min(Self.visualBarHeightRange.upperBound, max(Self.visualBarHeightRange.lowerBound, visualBarHeight ?? 30))
    }

    /// How much darker the history bars/line render vs. full brightness, in percent.
    public static let visualHistoryDarkenRange: ClosedRange<Double> = 0...100

    public var resolvedVisualHistoryDarken: Double {
        min(Self.visualHistoryDarkenRange.upperBound, max(Self.visualHistoryDarkenRange.lowerBound, visualHistoryDarken ?? 10))
    }

    public static let popoverPercentFontSizeRange: ClosedRange<CGFloat> = 9...20

    public var resolvedPopoverPercentFontSize: CGFloat {
        min(Self.popoverPercentFontSizeRange.upperBound, max(Self.popoverPercentFontSizeRange.lowerBound, popoverPercentFontSize ?? 12))
    }

    public static let `default` = AppConfig(
        refreshIntervalSeconds: 60,
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
        // Codable's synthesized decode bypasses the custom initializer (and its
        // 60s floor), so a config saved before this floor existed (e.g. an old
        // 15s or 30s value) must be caught here too, not just on fresh construction.
        copy.refreshIntervalSeconds = max(60, copy.refreshIntervalSeconds)
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

/// Which usage notifications are enabled and how they're tuned. All fields are
/// optional so older configs decode unchanged; the `resolved*` accessors apply
/// defaults. Everything is opt-in (default off) except the safe cross-restart
/// memory, which defaults on.
public struct NotificationSettings: Codable, Equatable, Sendable {
    /// Master switch — when off, no notifications fire regardless of the rest.
    public var enabled: Bool?
    /// Warn when a standard window crosses `thresholdPercentUsed`.
    public var threshold: Bool?
    /// The used-% at which the threshold warning fires (stored as "used", the
    /// display may show it as "remaining" — that's a presentation concern only).
    public var thresholdPercentUsed: Int?
    /// Alert when a standard window reaches 100%.
    public var limitReached: Bool?
    /// Warn when the burn rate projects running out before the reset.
    public var pace: Bool?
    /// Notify when a window resets (quota refreshed to ~0).
    public var reset: Bool?
    /// Notify when an extra/model-scoped quota (e.g. "Fable") resumes after a
    /// 30-minute quiet spell.
    public var extraQuota: Bool?
    /// Persist notification state (quiet-period timers, last-seen levels) across
    /// app restarts, so a restart alone never re-triggers a notification.
    public var extraQuotaPersist: Bool?
    /// Notify when a source can't be read because its login expired / needs a
    /// re-import (as opposed to a transient rate-limit or network blip).
    public var loginExpired: Bool?

    public init(
        enabled: Bool? = nil,
        threshold: Bool? = nil,
        thresholdPercentUsed: Int? = nil,
        limitReached: Bool? = nil,
        pace: Bool? = nil,
        reset: Bool? = nil,
        extraQuota: Bool? = nil,
        extraQuotaPersist: Bool? = nil,
        loginExpired: Bool? = nil
    ) {
        self.enabled = enabled
        self.threshold = threshold
        self.thresholdPercentUsed = thresholdPercentUsed
        self.limitReached = limitReached
        self.pace = pace
        self.reset = reset
        self.extraQuota = extraQuota
        self.extraQuotaPersist = extraQuotaPersist
        self.loginExpired = loginExpired
    }

    public static let thresholdPercentRange: ClosedRange<Int> = 50...99

    public var resolvedEnabled: Bool { enabled ?? false }
    public var resolvedThreshold: Bool { threshold ?? false }
    public var resolvedThresholdPercentUsed: Int {
        min(Self.thresholdPercentRange.upperBound, max(Self.thresholdPercentRange.lowerBound, thresholdPercentUsed ?? 90))
    }
    public var resolvedLimitReached: Bool { limitReached ?? false }
    public var resolvedPace: Bool { pace ?? false }
    public var resolvedReset: Bool { reset ?? false }
    public var resolvedExtraQuota: Bool { extraQuota ?? false }
    public var resolvedExtraQuotaPersist: Bool { extraQuotaPersist ?? true }
    public var resolvedLoginExpired: Bool { loginExpired ?? false }
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
    public var showFiveHourInPopover: Bool?
    public var showOneWeekInPopover: Bool?
    /// Governs any extra model-scoped windows this source reports (e.g. a
    /// "Fable" weekly cap) — one toggle for all of them, since their names
    /// aren't known ahead of time.
    public var showExtraInPopover: Bool?
    /// Overrides the global "remaining countdown" setting for this source's
    /// popover percent text. Nil inherits the app-wide default.
    public var popoverPercentMode: PercentDisplayMode?
    public var showPercentInPopover: Bool?

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
        claudeProfile: ClaudeProfile? = nil,
        showFiveHourInPopover: Bool? = nil,
        showOneWeekInPopover: Bool? = nil,
        showExtraInPopover: Bool? = nil,
        popoverPercentMode: PercentDisplayMode? = nil,
        showPercentInPopover: Bool? = nil
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
        self.showFiveHourInPopover = showFiveHourInPopover
        self.showOneWeekInPopover = showOneWeekInPopover
        self.showExtraInPopover = showExtraInPopover
        self.popoverPercentMode = popoverPercentMode
        self.showPercentInPopover = showPercentInPopover
    }

    public var resolvedShowFiveHourInPopover: Bool { showFiveHourInPopover ?? true }
    public var resolvedShowOneWeekInPopover: Bool { showOneWeekInPopover ?? true }
    public var resolvedShowExtraInPopover: Bool { showExtraInPopover ?? true }
    public var resolvedShowPercentInPopover: Bool { showPercentInPopover ?? true }

    /// Whether this source's popover percent should show "remaining" (vs.
    /// "used"), falling back to the app-wide default when unset.
    public func resolvedRemainingCountdown(globalDefault: Bool) -> Bool {
        switch popoverPercentMode {
        case .used: false
        case .remaining: true
        case nil: globalDefault
        }
    }
}

public enum PercentDisplayMode: String, Codable, Equatable, CaseIterable, Sendable {
    case used
    case remaining

    public var displayName: String {
        switch self {
        case .used: "Used"
        case .remaining: "Remaining"
        }
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

/// How the tall "Visual" bar encodes cycle time and usage.
public enum VisualBarMode: String, Codable, Equatable, CaseIterable, Sendable {
    /// Width = cycle time remaining, full height; usage via blocks + number.
    case time
    /// Like `time`, but the fill's height equals the current level (the last
    /// update block) — e.g. 86% tall when 86% is left.
    case timeLevel

    public var displayName: String {
        switch self {
        case .time: "Time width"
        case .timeLevel: "Time width · level height"
        }
    }
}

/// Width of the history blocks inside the Visual bar.
public enum VisualBlockWidth: String, Codable, Equatable, CaseIterable, Sendable {
    case narrow
    case medium

    public var displayName: String {
        switch self {
        case .narrow: "Narrow"
        case .medium: "Medium"
        }
    }

    /// (block width, gap) in points.
    public var metrics: (width: CGFloat, gap: CGFloat) {
        switch self {
        case .narrow: (3, 0)
        case .medium: (4, 2)
        }
    }
}

/// How the Visual bar renders its session-history region.
public enum VisualHistoryStyle: String, Codable, Equatable, CaseIterable, Sendable {
    /// Discrete vertical blocks, one per sample bucket.
    case bars
    /// A smooth filled line, like the classic sparkline.
    case line

    public var displayName: String {
        switch self {
        case .bars: "Bars"
        case .line: "Line"
        }
    }
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
