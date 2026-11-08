import Foundation
import SwiftUI

/// When the periodic refresh runs next. One timer serves every account, so a
/// rate-limited account is asked again at the first run after its lock ends.
@MainActor
final class RefreshClock: ObservableObject {
    static let shared = RefreshClock()

    @Published private(set) var nextRefreshAt: Date?
    @Published private(set) var interval: TimeInterval = 90

    func scheduled(interval: TimeInterval, from start: Date = Date()) {
        self.interval = interval
        nextRefreshAt = start.addingTimeInterval(interval)
    }

    /// The first refresh at or after `date`; the next refresh when nil.
    func nextAttempt(notBefore date: Date?) -> Date? {
        guard var next = nextRefreshAt else { return nil }
        guard let date, interval > 0 else { return next }
        while next < date { next += interval }
        return next
    }
}

/// "next in 1:12", ticking every second.
struct CountdownText: View {
    let prefix: String
    let target: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.text(prefix: prefix, target: target, now: context.date))
                .monospacedDigit()
        }
    }

    static func text(prefix: String, target: Date?, now: Date) -> String {
        guard let target else { return "\(prefix) –" }
        let seconds = Int(target.timeIntervalSince(now).rounded(.up))
        guard seconds > 0 else { return "updating…" }
        return "\(prefix) \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
