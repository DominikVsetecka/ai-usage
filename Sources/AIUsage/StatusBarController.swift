import AIUsageCore
import AppKit
import Foundation

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private var monitor: UsageMonitor
    private(set) var config: AppConfig
    private let onOpenSettings: () -> Void
    private var timer: Timer?

    init(config: AppConfig, onOpenSettings: @escaping () -> Void) {
        self.config = config
        self.monitor = UsageMonitor(config: config)
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusItem()
        render()
        scheduleRefresh()

        Task {
            await refreshNow()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func apply(config: AppConfig) {
        self.config = config
        self.monitor = UsageMonitor(config: config)
        render()
        scheduleRefresh()
        Task { await refreshNow() }
    }

    private func configureStatusItem() {
        renderStatusTitle()
        statusItem.menu = buildMenu()
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
        _ = await monitor.refresh { [weak self] _ in
            self?.render()
        }
        render()
    }

    private func render() {
        renderStatusTitle()
        statusItem.menu = buildMenu()
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
            // Emoji or custom text — render as label
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

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let title = NSMenuItem(
            title: UsageFormatter.menuBarTitle(
                for: monitor.snapshots,
                remainingCountdown: config.showsRemainingCountdown
            ),
            action: nil,
            keyEquivalent: ""
        )
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        for snapshot in monitor.snapshots.filter(\.enabled) {
            let value = snapshot.displayValue ?? snapshot.percentUsed.map {
                let display = UsageFormatter.displayPercent(
                    percentUsed: $0,
                    remainingCountdown: config.showsRemainingCountdown
                )
                return "\(display)%"
            } ?? "--%"
            let updated = UsageFormatter.shortTime(snapshot.updatedAt)
            let status = snapshot.status.rawValue
            let reset = snapshot.resetDescription.map { "  \($0)" } ?? ""
            let item = NSMenuItem(title: "\(snapshot.label): \(value)  \(status)  \(updated)\(reset)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)

            if let errorMessage = snapshot.errorMessage {
                let error = NSMenuItem(title: "  \(errorMessage)", action: nil, keyEquivalent: "")
                error.isEnabled = false
                menu.addItem(error)
            }
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshMenuAction), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let interval = NSMenuItem(title: "Refresh every \(Int(monitor.refreshIntervalSeconds))s", action: nil, keyEquivalent: "")
        interval.isEnabled = false
        menu.addItem(interval)

        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsMenuAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit AI Usage", action: #selector(quitMenuAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func refreshMenuAction() {
        Task {
            await refreshNow()
        }
    }

    @objc private func quitMenuAction() {
        stop()
        NSApp.terminate(nil)
    }

    @objc private func settingsMenuAction() {
        onOpenSettings()
    }
}
