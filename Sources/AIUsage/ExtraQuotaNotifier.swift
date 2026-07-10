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

/// Posts a brief local notification the first time an extra/model-scoped
/// quota (e.g. a "Fable" cap) starts being used after a quiet spell — see
/// `ExtraQuotaUsageWatcher` (AIUsageCore) for the gating logic.
///
/// `UNUserNotificationCenter` requires a real app bundle identifier and
/// throws when there isn't one — true for the ad-hoc-signed `.app` in
/// `dist/`, but not for a plain `swift run` debug binary, so every entry
/// point here first checks `Bundle.main.bundleIdentifier`.
enum ExtraQuotaNotifier {
    // UNUserNotificationCenter.delegate is weak, so this needs a strong
    // owner that outlives any single call — kept here instead of the center
    // itself.
    private static let presenter = NotificationPresenter()

    private static func ensureDelegate() {
        UNUserNotificationCenter.current().delegate = presenter
    }

    static func requestAuthorizationIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        ensureDelegate()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyUsageStarted(sourceLabel: String, windowName: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        ensureDelegate()
        let content = UNMutableNotificationContent()
        content.title = "\(windowName) quota in use"
        content.body = "\(sourceLabel) just started using the \(windowName) quota."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("AIUsage: failed to post extra-quota notification: \(error.localizedDescription)")
            }
        }
    }

    /// Settings' "Show demo notification" button — requests authorization if
    /// needed (it may not have been granted yet if the setting was just
    /// turned on and not saved) and then posts a sample notification so the
    /// user can preview it without waiting for real extra-quota usage.
    static func sendDemoNotification() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        ensureDelegate()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            notifyUsageStarted(sourceLabel: "Claude", windowName: "Fable")
        }
    }
}
