import AIUsageCore
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    func show(config: AppConfig, historyStore: UsageHistoryStore, onSave: @escaping (AppConfig) -> Void) {
        let view = SettingsView(
            config: config,
            historyStore: historyStore,
            onSave: { updated in
                onSave(updated)
            },
            onCancel: { [weak self] in
                self?.close()
            }
        )

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 740, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.minSize = NSSize(width: 560, height: 660)
            window.title = "AI Usage Settings"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        window?.contentViewController = NSHostingController(rootView: view)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
