import Foundation

/// Demo mode for screenshots: when `AI_USAGE_DEMO_FILE` points to a JSON file,
/// every account shows the made-up values from that file instead of asking a
/// provider, and the Keychain inventory shows made-up items. Nothing real can
/// end up in a screenshot.
public struct DemoUsageData: Codable, Sendable {
    public struct Account: Codable, Sendable {
        public var fiveHour: Int?
        public var oneWeek: Int?
        public var fiveHourResetMinutes: Double?
        public var oneWeekResetHours: Double?
        public var extra: [String: Int]?
        public var failure: UsageFailure?
        public var message: String?
        public var retryInSeconds: Double?
    }

    public var accounts: [String: Account]

    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> DemoUsageData? {
        guard let path = environment["AI_USAGE_DEMO_FILE"], !path.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)) else { return nil }
        return try? JSONDecoder().decode(DemoUsageData.self, from: data)
    }
}

public struct DemoUsageProbe: UsageProbing {
    public let sourceID: String
    public let label: String
    public let enabled: Bool
    private let account: DemoUsageData.Account?

    public init(source: SourceConfig, account: DemoUsageData.Account?) {
        self.sourceID = source.id
        self.label = source.label
        self.enabled = source.enabled
        self.account = account
    }

    public func readUsage() async -> UsageSnapshot {
        let now = Date()
        let fiveHour = account?.fiveHour.map {
            ProviderUsageWindow(percentUsed: $0, resetDescription: nil, resetsAt: now.addingTimeInterval((account?.fiveHourResetMinutes ?? 140) * 60))
        }
        let oneWeek = account?.oneWeek.map {
            ProviderUsageWindow(percentUsed: $0, resetDescription: nil, resetsAt: now.addingTimeInterval((account?.oneWeekResetHours ?? 70) * 3_600))
        }
        let extra = (account?.extra ?? [:]).mapValues {
            ProviderUsageWindow(percentUsed: $0, resetDescription: nil, resetsAt: now.addingTimeInterval(4 * 86_400))
        }
        let failed = account?.failure != nil
        return UsageSnapshot(
            sourceID: sourceID,
            label: label,
            enabled: enabled,
            percentUsed: fiveHour?.percentUsed ?? oneWeek?.percentUsed,
            status: enabled ? (failed ? .failed : .ok) : .disabled,
            updatedAt: now,
            errorMessage: failed ? (account?.message ?? "Demo failure") : nil,
            fiveHour: fiveHour,
            oneWeek: oneWeek,
            extraWindows: extra,
            failure: account?.failure,
            retryAt: account?.retryInSeconds.map { now.addingTimeInterval($0) }
        )
    }
}
