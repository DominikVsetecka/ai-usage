import AIUsageCore
import AppKit
import Foundation
import SwiftUI

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private var monitor: UsageMonitor
    private(set) var config: AppConfig
    private let onOpenSettings: () -> Void
    private var timer: Timer?
    private var popover: NSPopover?
    private var popoverViewModel: PopoverViewModel?
    private let historyStore: UsageHistoryStore

    init(config: AppConfig, onOpenSettings: @escaping () -> Void) {
        self.config = config
        self.monitor = UsageMonitor(config: config)
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.historyStore = UsageHistoryStore(directory: Self.historyDirectory())
        configureStatusItem()
        render()
        scheduleRefresh()

        Task {
            await refreshNow()
        }
    }

    private static func historyDirectory() -> URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "~"
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".ai-usage/history")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        popover?.performClose(nil)
    }

    func apply(config: AppConfig) {
        self.config = config
        self.monitor = UsageMonitor(config: config)
        popoverViewModel?.config = config
        render()
        scheduleRefresh()
        Task { await refreshNow() }
    }

    private func configureStatusItem() {
        renderStatusTitle()
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp])
        }
        setupPopover()
    }

    private func setupPopover() {
        let vm = PopoverViewModel(config: config)
        vm.snapshots = monitor.snapshots
        vm.historyStore = historyStore
        vm.onRefresh = { [weak self] in
            Task { await self?.refreshNow() }
        }
        vm.onOpenSettings = { [weak self] in
            self?.popover?.performClose(nil)
            self?.onOpenSettings()
        }
        vm.onQuit = { [weak self] in
            self?.stop()
            NSApp.terminate(nil)
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentViewController = NSHostingController(rootView: UsagePopoverView(viewModel: vm))

        self.popoverViewModel = vm
        self.popover = pop
    }

    @objc private func statusItemClicked() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            guard let button = statusItem.button else { return }
            popoverViewModel?.snapshots = monitor.snapshots
            popoverViewModel?.config = config
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func scheduleRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: monitor.refreshIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshNow()
            }
        }
        timer?.tolerance = min(5, monitor.refreshIntervalSeconds * 0.1)
    }

    private func refreshNow() async {
        popoverViewModel?.isRefreshing = true
        _ = await monitor.refresh { [weak self] _ in
            self?.render()
        }
        await historyStore.record(monitor.snapshots)
        if popover?.isShown == true {
            await popoverViewModel?.loadHistory()
        }
        popoverViewModel?.isRefreshing = false
        render()
    }

    private func render() {
        renderStatusTitle()
        popoverViewModel?.snapshots = monitor.snapshots
        popoverViewModel?.config = config
    }

    private func renderStatusTitle() {
        guard let button = statusItem.button else { return }
        let fontSize = config.menuBarFontSize ?? NSFont.systemFontSize
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: resolvedFontWeight())
        let title = NSMutableAttributedString()
        let enabledSnapshots = monitor.snapshots.filter(\.enabled)

        if enabledSnapshots.isEmpty {
            title.append(NSAttributedString(string: "AI --%", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }

        for (index, snapshot) in enabledSnapshots.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            }

            let value: String
            let isStale = snapshot.status == .failed && snapshot.percentUsed != nil
            let color: NSColor
            if let displayValue = snapshot.displayValue {
                value = displayValue
                color = isStale ? .secondaryLabelColor : resolvedTextColor(for: snapshot)
            } else if let percentUsed = snapshot.percentUsed {
                let displayPercent = UsageFormatter.displayPercent(
                    percentUsed: percentUsed,
                    remainingCountdown: config.showsRemainingCountdown
                )
                value = "\(displayPercent)%"
                color = isStale ? .secondaryLabelColor : resolvedTextColor(for: snapshot)
            } else {
                value = "--%"
                color = .secondaryLabelColor
            }

            let source = config.sources.first(where: { $0.id == snapshot.sourceID })
            appendIconAndValue(to: title, source: source, snapshot: snapshot, value: value, color: color, font: font, fontSize: fontSize)
        }

        button.attributedTitle = title
    }

    private func appendIconAndValue(
        to title: NSMutableAttributedString,
        source: SourceConfig?,
        snapshot: UsageSnapshot,
        value: String,
        color: NSColor,
        font: NSFont,
        fontSize: CGFloat
    ) {
        let iconName = source?.iconName ?? ""

        if let icon = ProviderIconRenderer.image(named: iconName, size: fontSize, color: color) {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = CGRect(x: 0, y: -floor(fontSize * 0.18), width: fontSize, height: fontSize)
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(string: " \(value)", attributes: [.font: font, .foregroundColor: color]))
        } else if !iconName.isEmpty, iconName != "claude", iconName != "openai" {
            title.append(NSAttributedString(string: "\(iconName) \(value)", attributes: [.font: font, .foregroundColor: color]))
        } else {
            title.append(NSAttributedString(string: "\(snapshot.label) \(value)", attributes: [.font: font, .foregroundColor: color]))
        }
    }

    private func resolvedFontWeight() -> NSFont.Weight {
        switch config.menuBarFontWeight {
        case "light": return .light
        case "regular": return .regular
        case "semibold": return .semibold
        case "bold": return .bold
        default: return .medium
        }
    }

    private func resolvedTextColor(for snapshot: UsageSnapshot) -> NSColor {
        switch config.textColorMode ?? .primary {
        case .primary:
            return .labelColor
        case .secondary:
            return .secondaryLabelColor
        case .percentageGradient:
            guard let pct = snapshot.percentUsed else { return .secondaryLabelColor }
            let remaining = 100 - min(100, max(0, pct))
            return NSColor(calibratedHue: CGFloat(remaining) / 300, saturation: 0.82, brightness: 0.88, alpha: 1)
        }
    }
}
