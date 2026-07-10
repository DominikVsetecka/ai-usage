import AIUsageCore
import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let settingsWindowController = SettingsWindowController()
    private var configURL: URL? { AppConfig.defaultConfigURL() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            let config = try AppConfig.load(from: configURL)
            if config.resolvedNotifyOnExtraQuotaUsage {
                ExtraQuotaNotifier.requestAuthorizationIfNeeded()
            }
            statusBarController = StatusBarController(config: config) { [weak self] in
                self?.openSettings()
            }
        } catch {
            let fallback = AppConfig.default
            statusBarController = StatusBarController(config: fallback) { [weak self] in
                self?.openSettings()
            }
            NSLog("AIUsage config load failed: \(error.localizedDescription)")
        }

        if ProcessInfo.processInfo.environment["AI_USAGE_SMOKE_TEST"] == "1" {
            if ProcessInfo.processInfo.environment["AI_USAGE_SMOKE_TEST_SETTINGS"] == "1" {
                openSettings()
            }
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func openSettings() {
        guard let controller = statusBarController else { return }
        settingsWindowController.show(
            config: controller.config,
            historyStore: controller.historyStore,
            snapshots: controller.snapshots
        ) { [weak self] config in
            guard let self else { return }
            do {
                if let configURL = self.configURL {
                    try config.save(to: configURL)
                }
                self.statusBarController?.apply(config: config)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not save settings"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
