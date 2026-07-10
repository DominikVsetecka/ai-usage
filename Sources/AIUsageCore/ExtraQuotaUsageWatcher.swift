import Foundation

/// Decides whether a "this quota just started being used" notification
/// should fire for an extra/model-scoped window (e.g. a "Fable" cap), and
/// tracks the last time actual usage (a percent increase) was observed.
///
/// A single continuous burst of usage — the percent keeps ticking up on
/// every refresh — only ever notifies once, right at its start. Once the
/// window goes quiet for `quietPeriod` (default 30 minutes), the next
/// increase after that quiet spell is treated as a fresh start and notifies
/// again — that's the whole point: catch the user up on usage they may not
/// have noticed, without repeating for usage they're already aware of.
public enum ExtraQuotaUsageWatcher {
    public static func evaluate(
        previousPercent: Int?,
        currentPercent: Int,
        lastIncreaseAt: Date?,
        now: Date = Date(),
        quietPeriod: TimeInterval = 30 * 60
    ) -> (shouldNotify: Bool, lastIncreaseAt: Date?) {
        guard currentPercent > (previousPercent ?? 0) else {
            return (false, lastIncreaseAt)
        }
        let quietLongEnough = lastIncreaseAt.map { now.timeIntervalSince($0) >= quietPeriod } ?? true
        return (quietLongEnough, now)
    }
}
