import AIUsageCore
import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let settingsWindowController = SettingsWindowController()
    private var configURL: URL? { AppConfig.defaultConfigURL() }
    private var openAccountsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        openAccountsObserver = NotificationCenter.default.addObserver(forName: .aiUsageOpenAccounts, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings(panel: .connections) }
        }

        do {
            let config = try loadMigratedConfig()
            // Notification authorization is requested by StatusBarController on
            // init/apply when notifications are enabled.
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
            let environment = ProcessInfo.processInfo.environment
            if environment["AI_USAGE_SMOKE_TEST_SETTINGS"] == "1" {
                openSettings(panel: environment["AI_USAGE_SMOKE_TEST_PANEL"].flatMap(SettingsView.SettingsPanel.init(rawValue:)) ?? .general)
            }
            if let path = environment["AI_USAGE_SMOKE_TEST_POPOVER_PNG"] {
                Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        await self?.statusBarController?.renderPopoverSnapshot(to: URL(fileURLWithPath: path))
                    }
                }
            }
            let seconds = environment["AI_USAGE_SMOKE_TEST_SECONDS"].flatMap(Double.init) ?? 2
            Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Loads the config and upgrades a v1 file (fixed slots) once, keeping a
    /// `config.v1.json` backup next to it.
    private func loadMigratedConfig() throws -> AppConfig {
        let loaded = try AppConfig.load(from: configURL)
        let result = AccountMigration.migrate(loaded, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        guard result.changed, let configURL, FileManager.default.fileExists(atPath: configURL.path) else { return result.config }
        try AccountMigration.backUpOriginal(configURL: configURL)
        try result.config.save(to: configURL)
        return result.config
    }

    private func openSettings(panel: SettingsView.SettingsPanel = .general) {
        guard let controller = statusBarController else { return }
        settingsWindowController.show(
            config: controller.config,
            historyStore: controller.historyStore,
            eventStore: controller.eventStore,
            snapshots: controller.snapshots,
            initialPanel: panel,
            onCredentialsChanged: { [weak self] profileID in
                self?.statusBarController?.clearOAuthCache(profileID: profileID)
            },
            onCommitAccounts: { [weak self] sources in
                self?.commitAccounts(sources)
            }
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

extension AppDelegate {
    /// Saves only the account list into the running config, so adding or
    /// removing an account never also applies unsaved edits from other panels.
    fileprivate func commitAccounts(_ sources: [SourceConfig]) {
        guard let controller = statusBarController else { return }
        var config = controller.config
        config.sources = sources
        do {
            if let configURL { try config.save(to: configURL) }
            controller.apply(config: config)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save the account change"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
