import Foundation

/// Projects "how long can I keep working at this pace" from recent burn
/// history — pure math, no UI/formatting concerns.
public enum UsageEstimator {
    /// Time until the burn rate observed since the last reset would reach
    /// 100%, or `nil` if there isn't enough signal to say anything useful.
    ///
    /// Deliberately conservative: a burst right after a reset would otherwise
    /// extrapolate into a wildly wrong number, and if the reset itself comes
    /// before the projected exhaustion, that pace was never the binding
    /// constraint, so there's nothing worth surfacing.
    ///
    /// - Parameters:
    ///   - points: samples since the last reset, oldest first.
    ///   - currentPct: the most recently observed percent used.
    ///   - resetsAt: when the current cycle resets.
    ///   - now: injectable for testing; defaults to the real time.
    ///   - minElapsed: minimum span between the first and last sample before
    ///     a projection is considered meaningful (default 15 minutes).
    public static func timeUntilExhausted(
        points: [(ts: Date, pct: Int)],
        currentPct: Int,
        resetsAt: Date,
        now: Date = Date(),
        minElapsed: TimeInterval = 15 * 60
    ) -> TimeInterval? {
        guard let first = points.first, let last = points.last else { return nil }
        let elapsed = last.ts.timeIntervalSince(first.ts)
        guard elapsed >= minElapsed else { return nil }

        let deltaPct = currentPct - first.pct
        guard deltaPct > 0 else { return nil }
        let ratePerSecond = Double(deltaPct) / elapsed

        let remainingPct = Double(100 - currentPct)
        guard remainingPct > 0 else { return nil }
        let secondsToFull = remainingPct / ratePerSecond

        let secondsToReset = resetsAt.timeIntervalSince(now)
        guard secondsToReset > 0, secondsToFull < secondsToReset else { return nil }
        return secondsToFull
    }
}
