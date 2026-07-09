import Foundation

/// Trims a series of recorded percentages down to just the current cycle —
/// pure math, shared by both the popover's history rendering and the burn-
/// rate estimate, so a fix here benefits both.
public enum HistoryTrimmer {
    /// Usage within a cycle only ever climbs, so either a big drop, or a
    /// small drop that lands very close to zero, marks a reset. The
    /// near-zero clause matters because a cycle can reset while usage was
    /// still low (e.g. 9% → 0%, a drop of only 9) — a flat "drop >= 10"
    /// threshold alone misses that and silently glues the previous cycle's
    /// tail onto the new one. A same-cycle wobble (e.g. 33% → 32%, ±1 read
    /// noise) never lands near zero, so it's still correctly ignored.
    public static func trimToCurrentCycle(
        _ points: [(ts: Date, pct: Int)],
        resetDrop: Int = 10,
        nearZeroThreshold: Int = 3
    ) -> [(ts: Date, pct: Int)] {
        guard points.count > 1 else { return points }
        var startIndex = 0
        for i in 1..<points.count {
            let drop = points[i - 1].pct - points[i].pct
            let isReset = drop >= resetDrop || (drop >= 1 && points[i].pct <= nearZeroThreshold)
            if isReset { startIndex = i }
        }
        return Array(points[startIndex...])
    }
}

/// Groups consecutive equal-percent samples together — pure index math, used
/// to draw a flat/unchanged stretch of history as one connected block instead
/// of many identical separate ones with gaps between them.
public enum HistoryBlockMerger {
    /// Each returned group is a closed index range into `pcts` (inclusive on
    /// both ends) plus the shared percent value for that range.
    public static func mergedGroups(pcts: [Int]) -> [(range: ClosedRange<Int>, pct: Int)] {
        guard !pcts.isEmpty else { return [] }
        var groups: [(range: ClosedRange<Int>, pct: Int)] = []
        for (index, pct) in pcts.enumerated() {
            if let last = groups.last, last.pct == pct {
                groups[groups.count - 1].range = last.range.lowerBound...index
            } else {
                groups.append((range: index...index, pct: pct))
            }
        }
        return groups
    }
}

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
    ///   - onlyIfBeforeReset: when true (default), only return a value if the
    ///     projected exhaustion would land before the reset — otherwise the
    ///     reset already is the binding constraint and there's nothing extra
    ///     worth surfacing. Pass false to always get a projection (once there's
    ///     enough signal) regardless of how it compares to the reset.
    public static func timeUntilExhausted(
        points: [(ts: Date, pct: Int)],
        currentPct: Int,
        resetsAt: Date,
        now: Date = Date(),
        minElapsed: TimeInterval = 15 * 60,
        onlyIfBeforeReset: Bool = true
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

        if onlyIfBeforeReset {
            let secondsToReset = resetsAt.timeIntervalSince(now)
            guard secondsToReset > 0, secondsToFull < secondsToReset else { return nil }
        }
        return secondsToFull
    }
}
