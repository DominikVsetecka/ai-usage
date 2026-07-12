import Foundation

/// Per-window notification bookkeeping, persisted across launches so a restart
/// alone never re-triggers anything. Keyed by `"sourceID|windowName"` (with
/// `"sourceID|__login"` for the per-source auth state).
public struct NotificationWindowState: Codable, Equatable, Sendable {
    /// Last percent we evaluated for this window — the baseline that edge
    /// detection (threshold/limit/reset crossings) compares against.
    public var lastPercent: Int?
    /// Last time this window's usage was seen to actively increase — drives the
    /// extra-quota "resumed after a quiet spell" gate.
    public var lastIncreaseAt: Date?
    /// Whether the pace warning has already fired for the current danger spell
    /// (cleared once the projection no longer runs out before the reset).
    public var paceFired: Bool?
    /// Whether the login-expired notice already fired for the current failure
    /// spell (cleared once the source reads successfully again).
    public var loginFailedNotified: Bool?

    public init(
        lastPercent: Int? = nil,
        lastIncreaseAt: Date? = nil,
        paceFired: Bool? = nil,
        loginFailedNotified: Bool? = nil
    ) {
        self.lastPercent = lastPercent
        self.lastIncreaseAt = lastIncreaseAt
        self.paceFired = paceFired
        self.loginFailedNotified = loginFailedNotified
    }
}

public enum StandardWindowNotification: Equatable, Sendable {
    case thresholdCrossed
    case limitReached
    case reset
}

/// Pure edge-detection for the standard (5-hour / weekly) windows. Operates on
/// the raw *used* percent — the "remaining countdown" display is a presentation
/// concern and never reaches here. Only fires on an actual transition between
/// two readings; a first observation with no baseline (nil previous, e.g. right
/// after a restart) never fires.
public enum NotificationRules {
    /// A cycle only ever climbs, so a meaningful drop marks a reset. Mirrors
    /// `HistoryTrimmer`'s heuristic (big drop, or a small drop landing near
    /// zero), gated on the window having been meaningfully used first so read
    /// noise near zero doesn't masquerade as a refresh.
    public static func isReset(previous: Int, current: Int, minPreviouslyUsed: Int = 15) -> Bool {
        let drop = previous - current
        let looksLikeReset = drop >= 10 || (drop >= 1 && current <= 3)
        return looksLikeReset && previous >= minPreviouslyUsed
    }

    public static func evaluateStandardWindow(
        previousPercent: Int?,
        currentPercent: Int,
        thresholdEnabled: Bool,
        thresholdPercentUsed: Int,
        limitEnabled: Bool,
        resetEnabled: Bool
    ) -> [StandardWindowNotification] {
        // First observation of the window this session — establish a baseline,
        // never fire. Otherwise pre-existing usage looks like a fresh jump.
        guard let previous = previousPercent else { return [] }

        // A reset is a downward event; if it happened this tick it's the only
        // thing worth saying (the window is now low, so no threshold/limit).
        if resetEnabled, isReset(previous: previous, current: currentPercent) {
            return [.reset]
        }

        // Reaching 100% is the harder, more specific event, so when a tick
        // crosses straight past the threshold to the limit (e.g. 88 -> 100),
        // report only "limit reached" rather than firing both at once.
        let hitLimit = limitEnabled && previous < 100 && currentPercent >= 100
        if hitLimit {
            return [.limitReached]
        }

        var out: [StandardWindowNotification] = []
        if thresholdEnabled, previous < thresholdPercentUsed, currentPercent >= thresholdPercentUsed {
            out.append(.thresholdCrossed)
        }
        return out
    }
}

/// Persists the per-window notification state to a small JSON file so the
/// quiet-period timers and last-seen levels survive app restarts.
public struct NotificationStateStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    public func load() -> [String: NotificationWindowState] {
        guard let data = try? Data(contentsOf: url),
              let state = try? Self.decoder.decode([String: NotificationWindowState].self, from: data) else {
            return [:]
        }
        return state
    }

    public func save(_ state: [String: NotificationWindowState]) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? Self.encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
