import Foundation
import UserNotifications

/// Without a delegate, macOS applies its default (restrictive) presentation
/// behavior while the requesting app is frontmost — e.g. right when the
/// Settings window has focus, which is exactly when the demo button is
/// clicked — and that default silently drops the sound (and can drop the
/// banner too). Explicitly opting in to banner + sound here is what makes a
/// notification triggered while AI Usage itself is active behave the same
/// as one triggered in the background.
private final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

/// Posts the app's local usage notifications (thresholds, limit reached, cycle
/// reset, pace, login-expired, and extra/model-scoped quota resume). The
/// gating logic lives in `NotificationRules` / `ExtraQuotaUsageWatcher`
/// (AIUsageCore); this only formats and delivers.
///
/// `UNUserNotificationCenter` requires a real app bundle identifier and throws
/// when there isn't one — true for the ad-hoc-signed `.app` in `dist/`, but not
/// for a plain `swift run` debug binary, so every entry point here first checks
/// `Bundle.main.bundleIdentifier`.
enum UsageNotifier {
    // UNUserNotificationCenter.delegate is weak, so this needs a strong owner
    // that outlives any single call — kept here instead of the center itself.
    private static let presenter = NotificationPresenter()

    private static func ensureDelegate() {
        UNUserNotificationCenter.current().delegate = presenter
    }

    static func requestAuthorizationIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        ensureDelegate()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        ensureDelegate()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("AIUsage: failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    static func notifyThreshold(sourceLabel: String, windowName: String, percentUsed: Int, remaining: Bool) {
        if remaining {
            post(title: "\(windowName) running low",
                 body: "\(sourceLabel): only \(max(0, 100 - percentUsed))% left on \(windowName).")
        } else {
            post(title: "\(windowName) usage high",
                 body: "\(sourceLabel): \(windowName) at \(percentUsed)% used.")
        }
    }

    static func notifyLimitReached(sourceLabel: String, windowName: String) {
        post(title: "\(windowName) limit reached",
             body: "\(sourceLabel): the \(windowName) quota is at 100%.")
    }

    static func notifyReset(sourceLabel: String, windowName: String) {
        post(title: "\(windowName) refreshed",
             body: "\(sourceLabel): the \(windowName) quota just reset — full again.")
    }

    static func notifyPace(sourceLabel: String, secondsUntilExhausted: TimeInterval) {
        post(title: "Running out soon",
             body: "\(sourceLabel): at this pace the 5-hour limit is reached in \(Self.durationText(secondsUntilExhausted)).")
    }

    static func notifyLoginExpired(sourceLabel: String) {
        post(title: "Login needs attention",
             body: "\(sourceLabel): usage couldn't be read — the login may have expired. Re-import the profile in Settings.")
    }

    static func notifyExtraQuotaResumed(sourceLabel: String, windowName: String) {
        post(title: "\(windowName) quota in use",
             body: "\(sourceLabel) just started using the \(windowName) quota.")
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "≈\(h)h \(m)m" }
        if m > 0 { return "≈\(m)m" }
        return "under a minute"
    }

    /// Settings' "Show demo notification" button — requests authorization if
    /// needed (it may not have been granted yet if the setting was just turned
    /// on and not saved) and then posts a sample so the user can preview it.
    static func sendDemoNotification() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        ensureDelegate()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            notifyThreshold(sourceLabel: "Claude", windowName: "5-hour", percentUsed: 90, remaining: false)
        }
    }
}
