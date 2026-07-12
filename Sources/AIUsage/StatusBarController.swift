import AIUsageCore
import AppKit
import Foundation
import SwiftUI

extension Notification.Name {
    static let aiUsageSnapshotsDidUpdate = Notification.Name("AIUsageSnapshotsDidUpdate")
}

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private var monitor: UsageMonitor
    /// One long-lived OAuth service reused across every config apply, so its
    /// usage cache and rate-limit backoff survive "Save & Refresh" instead of
    /// being reset by a fresh `UsageMonitor`. Uses the default long cache TTL
    /// (`ClaudeOAuthUsageService.defaultCacheTTL`, 15 minutes) regardless of the
    /// UI refresh interval — periodic (non-forced) ticks mostly re-render from
    /// cache; a manual/Save & Refresh force still bypasses it. This matches the
    /// original v1.3 design: the account-rate-limited endpoint should almost
    /// never be hit by the automatic timer.
    private let oauthUsageService = ClaudeOAuthUsageService(logURL: StatusBarController.fetchLogURL())
    private(set) var config: AppConfig
    private let onOpenSettings: () -> Void
    private var timer: Timer?
    private var popover: NSPopover?
    private var popoverViewModel: PopoverViewModel?
    let historyStore: UsageHistoryStore
    private let notifyStateStore = NotificationStateStore(url: StatusBarController.notifyStateURL())
    /// Persistent per-window notification bookkeeping (baselines, quiet-period
    /// timers, pace/login flags), keyed `"sourceID|windowName"`. Loaded on
    /// launch when the user keeps notification state across restarts, so a
    /// restart alone never re-triggers a notification.
    private var notifyState: [String: NotificationWindowState] = [:]

    var snapshots: [UsageSnapshot] {
        monitor.snapshots
    }

    init(config: AppConfig, onOpenSettings: @escaping () -> Void) {
        self.config = config
        self.monitor = UsageMonitor(config: config, oauthService: oauthUsageService)
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.historyStore = UsageHistoryStore(directory: Self.historyDirectory())
        if config.resolvedNotifications.resolvedEnabled {
            UsageNotifier.requestAuthorizationIfNeeded()
        }
        if config.resolvedNotifications.resolvedExtraQuotaPersist {
            self.notifyState = notifyStateStore.load()
        }
        configureStatusItem()
        render()
        scheduleRefresh()

        Task {
            await refreshNow(force: true, trigger: "startup")
        }
    }

    private static func historyDirectory() -> URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "~"
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".ai-usage/history")
    }

    private static func notifyStateURL() -> URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "~"
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".ai-usage/notify-state.json")
    }

    private static func fetchLogURL() -> URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "~"
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".ai-usage/fetch-log.txt")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        popover?.performClose(nil)
    }

    func apply(config: AppConfig) {
        self.config = config
        self.monitor = UsageMonitor(config: config, oauthService: oauthUsageService)
        popoverViewModel?.config = config
        if config.resolvedNotifications.resolvedEnabled {
            UsageNotifier.requestAuthorizationIfNeeded()
        }
        // Re-sync persisted notification state with the (possibly changed)
        // persist preference: load from disk when on, start clean when off.
        notifyState = config.resolvedNotifications.resolvedExtraQuotaPersist ? notifyStateStore.load() : [:]
        render()
        scheduleRefresh()
        Task {
            await refreshNow(force: true, trigger: "settings-apply")
        }
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
            Task { await self?.refreshNow(force: true, trigger: "manual-refresh") }
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
        pop.appearance = NSAppearance(named: .darkAqua)
        pop.contentSize = UsagePopoverView.preferredContentSize(for: vm.snapshots, config: config)
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
            updatePopoverContentSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            if let popoverWindow = popover.contentViewController?.view.window {
                popoverWindow.appearance = NSAppearance(named: .darkAqua)
            }
            // Reload history explicitly on every open rather than relying only
            // on SwiftUI's onAppear (unreliable to re-fire on a long-lived,
            // reused NSHostingController) or the next periodic timer tick —
            // otherwise a stale/empty load can linger until restart.
            Task { [weak popoverViewModel] in
                await popoverViewModel?.loadHistory()
            }
        }
    }

    private func scheduleRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: monitor.refreshIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshNow(trigger: "timer")
            }
        }
        timer?.tolerance = min(5, monitor.refreshIntervalSeconds * 0.1)
    }

    private func refreshNow(force: Bool = false, trigger: String = "unknown") async {
        await oauthUsageService.note("refresh cycle  trigger=\(trigger) force=\(force) interval=\(Int(monitor.refreshIntervalSeconds))s")
        popoverViewModel?.isRefreshing = true
        _ = await monitor.refresh(force: force) { [weak self] _ in
            self?.render()
        }
        await historyStore.record(monitor.snapshots)
        await checkNotifications(current: monitor.snapshots)
        if popover?.isShown == true {
            await popoverViewModel?.loadHistory()
        }
        popoverViewModel?.isRefreshing = false
        render()
    }

    /// Evaluates all enabled notification types against the latest snapshots and
    /// posts any that fire. All gating (baselines, once-per-crossing, quiet
    /// periods, pace/login hysteresis) lives in the persistent `notifyState`, so
    /// a restart alone never re-triggers anything. Runs after `historyStore.record`
    /// so the pace projection sees the current sample.
    private func checkNotifications(current: [UsageSnapshot]) async {
        let settings = config.resolvedNotifications
        guard settings.resolvedEnabled else { return }
        let now = Date()
        let globalRemaining = config.showsRemainingCountdown

        var historyEntries: [UsageHistoryEntry] = []
        if settings.resolvedPace {
            historyEntries = await historyStore.load(days: 1)
        }

        for snapshot in current where snapshot.enabled {
            let sourceConfig = config.sources.first { $0.id == snapshot.sourceID }
            let remaining = sourceConfig?.resolvedRemainingCountdown(globalDefault: globalRemaining) ?? globalRemaining

            // Login expired (per source).
            if settings.resolvedLoginExpired {
                let key = "\(snapshot.sourceID)|__login"
                var state = notifyState[key] ?? NotificationWindowState()
                if snapshot.status == .failed, Self.isAuthError(snapshot.errorMessage) {
                    if state.loginFailedNotified != true {
                        UsageNotifier.notifyLoginExpired(sourceLabel: snapshot.label)
                        state.loginFailedNotified = true
                    }
                } else if snapshot.status == .ok {
                    state.loginFailedNotified = false
                }
                notifyState[key] = state
            }

            // Standard windows: threshold / limit / reset.
            let standardWindows: [(name: String, window: ProviderUsageWindow?)] = [
                ("5-hour", snapshot.fiveHour),
                ("1-week", snapshot.oneWeek)
            ]
            for (windowName, maybeWindow) in standardWindows {
                guard let window = maybeWindow else { continue }
                let key = "\(snapshot.sourceID)|\(windowName)"
                var state = notifyState[key] ?? NotificationWindowState()
                let events = NotificationRules.evaluateStandardWindow(
                    previousPercent: state.lastPercent,
                    currentPercent: window.percentUsed,
                    thresholdEnabled: settings.resolvedThreshold,
                    thresholdPercentUsed: settings.resolvedThresholdPercentUsed,
                    limitEnabled: settings.resolvedLimitReached,
                    resetEnabled: settings.resolvedReset
                )
                for event in events {
                    switch event {
                    case .thresholdCrossed:
                        UsageNotifier.notifyThreshold(sourceLabel: snapshot.label, windowName: windowName, percentUsed: window.percentUsed, remaining: remaining)
                    case .limitReached:
                        UsageNotifier.notifyLimitReached(sourceLabel: snapshot.label, windowName: windowName)
                    case .reset:
                        UsageNotifier.notifyReset(sourceLabel: snapshot.label, windowName: windowName)
                    }
                }
                state.lastPercent = window.percentUsed
                notifyState[key] = state
            }

            // Pace: 5-hour only, reusing the same state entry.
            if settings.resolvedPace, let five = snapshot.fiveHour, let resetsAt = five.resetsAt {
                let key = "\(snapshot.sourceID)|5-hour"
                var state = notifyState[key] ?? NotificationWindowState()
                let points = Self.paceHistoryPoints(entries: historyEntries, sourceID: snapshot.sourceID)
                let projection = UsageEstimator.timeUntilExhausted(
                    points: points,
                    currentPct: five.percentUsed,
                    resetsAt: resetsAt,
                    now: now
                )
                if let projection {
                    if state.paceFired != true {
                        UsageNotifier.notifyPace(sourceLabel: snapshot.label, secondsUntilExhausted: projection)
                        state.paceFired = true
                    }
                } else {
                    state.paceFired = false
                }
                notifyState[key] = state
            }

            // Extra/model-scoped quotas: resume after a quiet spell.
            if settings.resolvedExtraQuota {
                for (windowName, window) in snapshot.extraWindows {
                    let key = "\(snapshot.sourceID)|extra|\(windowName)"
                    var state = notifyState[key] ?? NotificationWindowState()
                    let result = ExtraQuotaUsageWatcher.evaluate(
                        previousPercent: state.lastPercent,
                        currentPercent: window.percentUsed,
                        lastIncreaseAt: state.lastIncreaseAt,
                        now: now
                    )
                    state.lastIncreaseAt = result.lastIncreaseAt
                    state.lastPercent = window.percentUsed
                    if result.shouldNotify {
                        UsageNotifier.notifyExtraQuotaResumed(sourceLabel: snapshot.label, windowName: windowName)
                    }
                    notifyState[key] = state
                }
            }
        }

        if settings.resolvedExtraQuotaPersist {
            notifyStateStore.save(notifyState)
        }
    }

    private static func paceHistoryPoints(entries: [UsageHistoryEntry], sourceID: String) -> [(ts: Date, pct: Int)] {
        let raw = entries.compactMap { entry -> (ts: Date, pct: Int)? in
            guard let pct = entry.sources[sourceID]?.fiveHour else { return nil }
            return (entry.ts, pct)
        }
        return HistoryTrimmer.trimToCurrentCycle(raw)
    }

    private static func isAuthError(_ message: String?) -> Bool {
        guard let message = message?.lowercased() else { return false }
        // Match genuine "your login stopped working" cases across OAuth and CLI.
        // Deliberately excludes the never-configured case ("Import a Claude Code
        // account in Settings"), which is a setup prompt, not an expired login.
        return message.contains("session expired")
            || message.contains("no longer valid")
            || message.contains("credentials are missing")
            || message.contains("import this profile")   // OAuth session-expired guidance
            || message.contains("logged in")             // CLI "(not) logged in"
            || message.contains("please log in")
            || message.contains("login required")
    }

    private func render() {
        renderStatusTitle()
        popoverViewModel?.snapshots = monitor.snapshots
        popoverViewModel?.config = config
        NotificationCenter.default.post(name: .aiUsageSnapshotsDidUpdate, object: monitor.snapshots)
        updatePopoverContentSize()
    }

    private func updatePopoverContentSize() {
        popover?.contentSize = UsagePopoverView.preferredContentSize(for: monitor.snapshots, config: config)
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
        if let icon = ProviderIconRenderer.image(iconData: source?.iconData, iconName: source?.iconName, size: fontSize, color: color) {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = CGRect(x: 0, y: -floor(fontSize * 0.18), width: fontSize, height: fontSize)
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(string: " \(value)", attributes: [.font: font, .foregroundColor: color]))
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
