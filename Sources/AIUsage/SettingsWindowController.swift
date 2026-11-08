import AIUsageCore
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    func show(
        config: AppConfig,
        historyStore: UsageHistoryStore,
        eventStore: ConnectionEventStore,
        snapshots: [UsageSnapshot],
        initialPanel: SettingsView.SettingsPanel = .general,
        onCredentialsChanged: @escaping (UUID) -> Void,
        onCommitAccounts: @escaping ([SourceConfig]) -> Void,
        onSave: @escaping (AppConfig) -> Void
    ) {
        let view = SettingsView(
            config: config,
            historyStore: historyStore,
            eventStore: eventStore,
            snapshots: snapshots,
            initialPanel: initialPanel,
            onSave: { updated in
                onSave(updated)
            },
            onCommitAccounts: onCommitAccounts,
            onCancel: { [weak self] in
                self?.close()
            },
            onCredentialsChanged: onCredentialsChanged
        )

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.minSize = NSSize(width: 660, height: 660)
            window.title = "AI Usage Settings"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        window?.contentViewController = NSHostingController(rootView: view)
        // Screenshot hook (smoke-test runs only): a fixed window size.
        if let size = ProcessInfo.processInfo.environment["AI_USAGE_SMOKE_TEST_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }),
           size.count == 2 {
            window?.setContentSize(NSSize(width: size[0], height: size[1]))
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
