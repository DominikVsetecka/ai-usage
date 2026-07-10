import Foundation

public enum SourceStatus: String, Codable, Equatable, Sendable {
    case idle
    case ok
    case failed
    case disabled
}

public struct ProviderUsageWindow: Equatable, Sendable {
    public let percentUsed: Int
    public let resetDescription: String?
    public let resetsAt: Date?

    /// - Parameter resetsAt: pass the exact reset instant directly when it's
    ///   already known (e.g. parsed from an ISO 8601 API field), bypassing
    ///   the fragile text round-trip below. Falls back to text-parsing
    ///   `resetDescription` when omitted — the only option callers with just
    ///   a human-readable string (e.g. scraped CLI text) have.
    public init(percentUsed: Int, resetDescription: String?, resetsAt: Date? = nil) {
        self.percentUsed = min(100, max(0, percentUsed))
        self.resetDescription = resetDescription
        self.resetsAt = resetsAt ?? Self.parseResetDate(from: resetDescription)
    }

    // Parses reset description strings like:
    //   "Resets 1:30am (Europe/Vienna)"         → time-only, today or tomorrow
    //   "Resets Jun 30 at 9pm (Europe/Vienna)"  → specific date + time
    //   "Resets in 2h 15m"                      → relative from now
    public static func parseResetDate(from description: String?) -> Date? {
        guard let text = description else { return nil }

        // Relative: "in 2h 15m", "Resets in 30m"
        if text.localizedCaseInsensitiveContains("in ") {
            if let rel = parseRelativeDuration(text) { return rel }
        }

        // Extract optional timezone "(Europe/Vienna)"
        let tz: TimeZone
        if let tzRange = text.range(of: #"\(([^)]+)\)"#, options: .regularExpression),
           let id = text[tzRange].dropFirst().dropLast().trimmingCharacters(in: .whitespaces) as String?,
           let zone = TimeZone(identifier: id) {
            tz = zone
        } else {
            tz = .current
        }

        // Strip "Resets" prefix and timezone suffix, normalize "at" → ","
        var cleaned = text
        if let r = cleaned.range(of: "resets", options: .caseInsensitive) {
            cleaned = String(cleaned[r.upperBound...])
        }
        cleaned = cleaned
            .replacingOccurrences(of: #"\s*\([^)]+\)\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+at\s+"#, with: ", ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let formats = [
            "MMM d, yyyy, h:mma",
            "MMM d, yyyy, ha",
            "MMM d, yyyy",
            "MMM d, h:mma",
            "MMM d, ha",
            "h:mma",
            "ha",
            "MMM d",
        ]

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = tz

        for format in formats {
            fmt.dateFormat = format
            if let parsed = fmt.date(from: cleaned) {
                return resolveToFuture(parsed, format: format, tz: tz)
            }
        }
        return nil
    }

    private static func parseRelativeDuration(_ text: String) -> Date? {
        var total: TimeInterval = 0
        if let m = text.range(of: #"(\d+)\s*d(?:ays?)?"#, options: .regularExpression) {
            total += (Double(text[m].filter(\.isNumber)) ?? 0) * 86400
        }
        if let m = text.range(of: #"(\d+)\s*h(?:r|ours?)?"#, options: .regularExpression) {
            total += (Double(text[m].filter(\.isNumber)) ?? 0) * 3600
        }
        if let m = text.range(of: #"(\d+)\s*m(?:in(?:utes?)?)?"#, options: .regularExpression) {
            total += (Double(text[m].filter(\.isNumber)) ?? 0) * 60
        }
        return total > 0 ? Date().addingTimeInterval(total) : nil
    }

    private static func resolveToFuture(_ parsed: Date, format: String, tz: TimeZone) -> Date {
        var cal = Calendar.current
        cal.timeZone = tz
        let now = Date()
        if format.contains("yyyy") { return parsed }

        let hasMonth = format.contains("MMM")
        let hasTime  = format.contains("h")

        if hasMonth && hasTime {
            var c = cal.dateComponents([.month, .day, .hour, .minute], from: parsed)
            c.year = cal.component(.year, from: now)
            if let d = cal.date(from: c), d > now { return d }
            c.year! += 1
            return cal.date(from: c) ?? parsed
        }
        if hasMonth {
            var c = cal.dateComponents([.month, .day], from: parsed)
            c.year = cal.component(.year, from: now); c.hour = 0; c.minute = 0
            if let d = cal.date(from: c), d > now { return d }
            c.year! += 1
            return cal.date(from: c) ?? parsed
        }
        if hasTime {
            let pc = cal.dateComponents([.hour, .minute], from: parsed)
            var tc = cal.dateComponents([.year, .month, .day], from: now)
            tc.hour = pc.hour; tc.minute = pc.minute
            if let d = cal.date(from: tc), d > now { return d }
            if let tomorrow = cal.date(byAdding: .day, value: 1, to: now) {
                tc = cal.dateComponents([.year, .month, .day], from: tomorrow)
                tc.hour = pc.hour; tc.minute = pc.minute
                return cal.date(from: tc) ?? parsed
            }
        }
        return parsed
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public var sourceID: String
    public var label: String
    public var enabled: Bool
    public var percentUsed: Int?
    public var displayValue: String?
    public var status: SourceStatus
    public var updatedAt: Date?
    public var resetDescription: String?
    public var errorMessage: String?
    public var fiveHour: ProviderUsageWindow?
    public var oneWeek: ProviderUsageWindow?
    /// Additional named quota windows some accounts/plans expose beyond the
    /// standard 5-hour/weekly pair — e.g. a model-scoped weekly limit like
    /// "Fable" — keyed by their display name. Empty when none are reported.
    public var extraWindows: [String: ProviderUsageWindow]

    public init(
        sourceID: String,
        label: String,
        enabled: Bool,
        percentUsed: Int?,
        displayValue: String? = nil,
        status: SourceStatus,
        updatedAt: Date?,
        resetDescription: String? = nil,
        errorMessage: String?,
        fiveHour: ProviderUsageWindow? = nil,
        oneWeek: ProviderUsageWindow? = nil,
        extraWindows: [String: ProviderUsageWindow] = [:]
    ) {
        self.sourceID = sourceID
        self.label = label
        self.enabled = enabled
        self.percentUsed = percentUsed.map { min(100, max(0, $0)) }
        self.displayValue = displayValue
        self.status = status
        self.updatedAt = updatedAt
        self.resetDescription = resetDescription
        self.errorMessage = errorMessage
        self.fiveHour = fiveHour
        self.oneWeek = oneWeek
        self.extraWindows = extraWindows
    }

    public static func idle(from config: SourceConfig) -> UsageSnapshot {
        UsageSnapshot(
            sourceID: config.id,
            label: config.label,
            enabled: config.enabled,
            percentUsed: nil,
            displayValue: nil,
            status: config.enabled ? .idle : .disabled,
            updatedAt: nil,
            resetDescription: nil,
            errorMessage: nil
        )
    }
}

public protocol UsageProbing: Sendable {
    var sourceID: String { get }
    var label: String { get }
    var enabled: Bool { get }

    func readUsage() async -> UsageSnapshot
}

public protocol ForceRefreshableUsageProbing: UsageProbing {
    func readUsage(force: Bool) async -> UsageSnapshot
}
