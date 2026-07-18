import AIUsageCore
import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var draft: AppConfig
    @State private var latestSnapshots: [UsageSnapshot]
    let historyStore: UsageHistoryStore
    let onSave: (AppConfig) -> Void
    let onCancel: () -> Void

    @State private var selectedPanelID: String = SettingsPanel.general.id

    enum SettingsPanel: String, CaseIterable, Identifiable {
        case general, menuBar, popover, notifications, connections, history, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .menuBar: "Menu Bar"
            case .popover: "Popover"
            case .notifications: "Notifications"
            case .connections: "Connections"
            case .history: "History"
            case .about: "About"
            }
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .menuBar: "menubar.rectangle"
            case .popover: "rectangle.on.rectangle"
            case .notifications: "bell.badge"
            case .connections: "link"
            case .history: "chart.line.uptrend.xyaxis"
            case .about: "info.circle"
            }
        }
    }

    private var currentPanel: SettingsPanel { SettingsPanel(rawValue: selectedPanelID) ?? .general }

    private var sidebarSelection: Binding<String?> {
        Binding(
            get: { selectedPanelID },
            set: { selectedPanelID = $0 ?? SettingsPanel.general.id }
        )
    }

    init(
        config: AppConfig,
        historyStore: UsageHistoryStore,
        snapshots: [UsageSnapshot],
        onSave: @escaping (AppConfig) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: config)
        _latestSnapshots = State(initialValue: snapshots)
        self.historyStore = historyStore
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPanel.allCases, selection: sidebarSelection) { panel in
                Label(panel.title, systemImage: panel.icon)
                    .tag(panel.id)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            VStack(spacing: 0) {
                detailContent
                Divider()
                footer
            }
        }
        .frame(minWidth: 820, minHeight: 640)
    }

    @ViewBuilder private var detailContent: some View {
        switch currentPanel {
        case .general: generalPanel
        case .menuBar: menuBarPanel
        case .popover: popoverPanel
        case .notifications: notificationsPanel
        case .connections: connectionsPanel
        case .history: HistoryView(historyStore: historyStore, config: draft)
        case .about: InfoView()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Save & Refresh") {
                onSave(draft)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var generalPanel: some View {
        Form {
            Section {
                Picker("Refresh interval", selection: $draft.refreshIntervalSeconds) {
                    Text("90 seconds").tag(TimeInterval(90))
                    Text("2 minutes").tag(TimeInterval(120))
                    Text("5 minutes").tag(TimeInterval(300))
                }
                .pickerStyle(.menu)

                Toggle("Remaining countdown (100% to 0%)", isOn: remainingCountdownBinding)
                    .help("Show how much quota is left instead of how much is used — affects both the menu bar and the popover.")
            } header: {
                Text("General")
            } footer: {
                Text("This is exactly how often Claude usage is actually checked over the network — not a display-only tick with a longer cache behind it. A manual refresh always checks immediately, at most once every 10 seconds.")
            }
        }
        .formStyle(.grouped)
    }

    private var menuBarPanel: some View {
        Form {
            Section {
                    Picker("Font size", selection: $draft.menuBarFontSize) {
                        Text("System (\(Int(NSFont.systemFontSize))pt)").tag(Optional<CGFloat>.none)
                        Text("11pt").tag(Optional<CGFloat>.some(11))
                        Text("12pt").tag(Optional<CGFloat>.some(12))
                        Text("13pt").tag(Optional<CGFloat>.some(13))
                        Text("14pt").tag(Optional<CGFloat>.some(14))
                        Text("15pt").tag(Optional<CGFloat>.some(15))
                        Text("16pt").tag(Optional<CGFloat>.some(16))
                    }
                    .pickerStyle(.menu)

                    Picker("Font weight", selection: fontWeightBinding) {
                        Text("Light").tag("light")
                        Text("Regular").tag("regular")
                        Text("Medium (default)").tag("medium")
                        Text("Semibold").tag("semibold")
                        Text("Bold").tag("bold")
                    }
                    .pickerStyle(.menu)

                    Picker("Text color", selection: textColorModeBinding) {
                        Text("White").tag(TextColorMode.primary)
                        Text("Dimmed").tag(TextColorMode.secondary)
                        Text("Usage gradient (green → red)").tag(TextColorMode.percentageGradient)
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Menu Bar")
                } footer: {
                    Text("How the percentage text looks in the macOS menu bar.")
                }
            }
        .formStyle(.grouped)
    }

    private var popoverPanel: some View {
        Form {
                Section {
                    VisualBarPreviewRow(config: draft)
                        .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))

                    Picker("Bar fill", selection: visualBarModeBinding) {
                        ForEach(VisualBarMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    LabeledContent("Bar height") {
                        HStack {
                            Slider(
                                value: visualBarHeightBinding,
                                in: AppConfig.visualBarHeightRange,
                                step: 1
                            )
                            Text("\(Int(draft.resolvedVisualBarHeight))pt")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }

                    Picker("History style", selection: visualHistoryStyleBinding) {
                        ForEach(VisualHistoryStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)

                    if draft.resolvedVisualHistoryStyle == .bars {
                        Picker("History block width", selection: visualBlockWidthBinding) {
                            ForEach(VisualBlockWidth.allCases, id: \.self) { width in
                                Text(width.displayName).tag(width)
                            }
                        }
                        .pickerStyle(.segmented)

                        if !draft.resolvedConnectedHistorySteps {
                            LabeledContent("History block gap") {
                                HStack {
                                    Slider(
                                        value: visualBlockGapBinding,
                                        in: AppConfig.visualBlockGapRange,
                                        step: 1
                                    )
                                    Text("\(Int(draft.resolvedVisualBlockGap))pt")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 34, alignment: .trailing)
                                }
                            }
                        }

                        Toggle("Merge unchanged history blocks", isOn: mergeUnchangedHistoryBlocksBinding)
                            .help("Draw consecutive blocks with the same recorded percent as one connected block instead of separate ones with gaps.")

                        Toggle("Rounded history steps", isOn: roundedHistoryStepsBinding)
                            .help("Softer, more rounded top corners on each history block, so jumps between different values look less sharp.")

                        Toggle("Connect history steps", isOn: connectedHistoryStepsBinding)
                            .help("No gaps between blocks at all — they connect smoothly, and each entry's brightness restarts lighter at its own start so individual updates stay visible.")
                    }

                    LabeledContent("History darkness") {
                        HStack {
                            Slider(
                                value: visualHistoryDarkenBinding,
                                in: AppConfig.visualHistoryDarkenRange,
                                step: 5
                            )
                            Text("\(Int(draft.resolvedVisualHistoryDarken))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }

                    Picker("History direction", selection: sparklineDirectionBinding) {
                        Text("Ascending — rises with usage").tag(SparklineDirection.ascending)
                        Text("Descending — drops from top").tag(SparklineDirection.descending)
                    }
                    .pickerStyle(.segmented)

                    LabeledContent("Percent size") {
                        HStack {
                            Slider(
                                value: popoverPercentFontSizeBinding,
                                in: AppConfig.popoverPercentFontSizeRange,
                                step: 1
                            )
                            Text("\(Int(draft.resolvedPopoverPercentFontSize))pt")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }

                    Picker("Percent weight", selection: popoverPercentFontWeightBinding) {
                        Text("Light").tag("light")
                        Text("Regular").tag("regular")
                        Text("Medium").tag("medium")
                        Text("Semibold (default)").tag("semibold")
                        Text("Bold").tag("bold")
                    }
                    .pickerStyle(.menu)

                    Toggle("Show pace estimate on 5-hour window", isOn: showUsageEstimateBinding)
                        .help("\"≈Xh Ym left at this pace\" next to the reset time, projected from the burn rate since the last reset. Only appears once there's enough data and only if you'd run out before the reset.")

                    if draft.resolvedShowUsageEstimate {
                        Toggle("Always show pace estimate", isOn: alwaysShowUsageEstimateBinding)
                            .help("Show the estimate even when you're on track to reset before running out — normally it only appears when the pace would run out before the reset.")
                    }
                } header: {
                    Text("Popover")
                } footer: {
                    Text("How the usage bars in the click-to-open popover look: the fill shows the current cycle, the history shows past updates.")
                }
            }
        .formStyle(.grouped)
    }

    private var connectionsPanel: some View {
        Form {
            ForEach(draft.sources.indices, id: \.self) { index in
                ProviderSettingsSection(
                    source: $draft.sources[index],
                    snapshot: latestSnapshots.first(where: { $0.sourceID == draft.sources[index].id })
                )
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: .aiUsageSnapshotsDidUpdate)) { notification in
            guard let snapshots = notification.object as? [UsageSnapshot] else { return }
            latestSnapshots = snapshots
        }
    }

    private var notificationsPanel: some View {
        let n = draft.resolvedNotifications
        let remaining = draft.showsRemainingCountdown
        return Form {
            Section {
                Toggle("Enable notifications", isOn: notifEnabledBinding)
                if n.resolvedEnabled {
                    Button("Show demo notification") {
                        UsageNotifier.sendDemoNotification()
                    }
                }
            } footer: {
                Text("System notifications need the built app bundle (dist/AI Usage.app), not a plain swift run. macOS may ask for permission the first time one fires.")
            }

            if n.resolvedEnabled {
                Section {
                    Toggle(remaining ? "Warn when running low" : "Warn near the limit", isOn: notifThresholdBinding)
                    if n.resolvedThreshold {
                        Picker("Threshold", selection: notifThresholdPercentBinding) {
                            ForEach([80, 85, 90, 95], id: \.self) { used in
                                Text(remaining ? "\(100 - used)% left" : "\(used)% used").tag(used)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Toggle("Alert when a window hits 100%", isOn: notifLimitBinding)
                } header: {
                    Text("Usage thresholds")
                } footer: {
                    Text("Fires once per cycle when a 5-hour or weekly window crosses the level. Always based on actual usage — the wording follows your \(remaining ? "remaining" : "used") display.")
                }

                Section("Pace") {
                    Toggle("Warn if you'll run out before the reset", isOn: notifPaceBinding)
                        .help("Uses the burn rate since the last reset to project whether the 5-hour window runs out before it resets.")
                }

                Section("Cycle") {
                    Toggle("Notify when a window resets (quota refreshed)", isOn: notifResetBinding)
                }

                Section("Extra quotas") {
                    Toggle("Notify when an extra quota (e.g. Fable) resumes after 30+ min quiet", isOn: notifExtraBinding)
                }

                Section("Account") {
                    Toggle("Notify when a login expires / needs re-import", isOn: notifLoginBinding)
                }

                Section {
                    Toggle("Remember notification state across restarts", isOn: notifPersistBinding)
                } footer: {
                    Text("Keeps the quiet-period timers and last-seen levels across restarts, so restarting the app alone never re-triggers a notification.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func updateNotifications(_ mutate: (inout NotificationSettings) -> Void) {
        var n = draft.notifications ?? draft.resolvedNotifications
        mutate(&n)
        draft.notifications = n
    }

    private var notifEnabledBinding: Binding<Bool> {
        Binding(get: { draft.resolvedNotifications.resolvedEnabled }, set: { v in updateNotifications { $0.enabled = v } })
    }
    private var notifThresholdBinding: Binding<Bool> {
        Binding(get: { draft.resolvedNotifications.resolvedThreshold }, set: { v in updateNotifications { $0.threshold = v } })
    }
    private var notifThresholdPercentBinding: Binding<Int> {
        Binding(get: { draft.resolvedNotifications.resolvedThresholdPercentUsed }, set: { v in updateNotifications { $0.thresholdPercentUsed = v } })
    }
    private var notifLimitBinding: Binding<Bool> {
        Binding(get: { draft.resolvedNotifications.resolvedLimitReached }, set: { v in updateNotifications { $0.limitReached = v } })
    }
    private var notifPaceBinding: Binding<Bool> {
        Binding(get: { draft.resolvedNotifications.resolvedPace }, set: { v in updateNotifications { $0.pace = v } })
    }
    private var notifResetBinding: Binding<Bool> {
        Binding(get: { draft.resolvedNotifications.resolvedReset }, set: { v in updateNotifications { $0.reset = v } })
    }
    private var notifExtraBinding: Binding<Bool> {
        Binding(get: { draft.resolvedNotifications.resolvedExtraQuota }, set: { v in updateNotifications { $0.extraQuota = v } })
    }
    private var notifLoginBinding: Binding<Bool> {
        Binding(get: { draft.resolvedNotifications.resolvedLoginExpired }, set: { v in updateNotifications { $0.loginExpired = v } })
    }
    private var notifPersistBinding: Binding<Bool> {
        Binding(get: { draft.resolvedNotifications.resolvedExtraQuotaPersist }, set: { v in updateNotifications { $0.extraQuotaPersist = v } })
    }

    private var remainingCountdownBinding: Binding<Bool> {
        Binding(
            get: { draft.showsRemainingCountdown },
            set: { draft.remainingCountdownEnabled = $0 }
        )
    }


    private var visualBarModeBinding: Binding<VisualBarMode> {
        Binding(
            get: { draft.resolvedVisualBarMode },
            set: { draft.visualBarMode = $0 == .time ? nil : $0 }
        )
    }

    private var visualBlockWidthBinding: Binding<VisualBlockWidth> {
        Binding(
            get: { draft.resolvedVisualBlockWidth },
            set: { draft.visualBlockWidth = $0 == .medium ? nil : $0 }
        )
    }

    private var visualBlockGapBinding: Binding<CGFloat> {
        Binding(
            get: { draft.resolvedVisualBlockGap },
            set: { draft.visualBlockGap = $0 }
        )
    }

    private var mergeUnchangedHistoryBlocksBinding: Binding<Bool> {
        Binding(
            get: { draft.resolvedMergeUnchangedHistoryBlocks },
            set: { draft.mergeUnchangedHistoryBlocks = $0 }
        )
    }

    private var roundedHistoryStepsBinding: Binding<Bool> {
        Binding(
            get: { draft.resolvedRoundedHistorySteps },
            set: { draft.roundedHistorySteps = $0 }
        )
    }

    private var connectedHistoryStepsBinding: Binding<Bool> {
        Binding(
            get: { draft.resolvedConnectedHistorySteps },
            set: { draft.connectedHistorySteps = $0 }
        )
    }

    private var visualBarHeightBinding: Binding<CGFloat> {
        Binding(
            get: { draft.resolvedVisualBarHeight },
            set: { draft.visualBarHeight = $0 }
        )
    }

    private var visualHistoryStyleBinding: Binding<VisualHistoryStyle> {
        Binding(
            get: { draft.resolvedVisualHistoryStyle },
            set: { draft.visualHistoryStyle = $0 == .bars ? nil : $0 }
        )
    }

    private var visualHistoryDarkenBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedVisualHistoryDarken },
            set: { draft.visualHistoryDarken = $0 }
        )
    }

    private var popoverPercentFontSizeBinding: Binding<CGFloat> {
        Binding(
            get: { draft.resolvedPopoverPercentFontSize },
            set: { draft.popoverPercentFontSize = $0 }
        )
    }

    private var popoverPercentFontWeightBinding: Binding<String> {
        Binding(
            get: { draft.popoverPercentFontWeight ?? "semibold" },
            set: { draft.popoverPercentFontWeight = $0 == "semibold" ? nil : $0 }
        )
    }

    private var showUsageEstimateBinding: Binding<Bool> {
        Binding(
            get: { draft.resolvedShowUsageEstimate },
            set: { draft.showUsageEstimate = $0 }
        )
    }

    private var alwaysShowUsageEstimateBinding: Binding<Bool> {
        Binding(
            get: { draft.resolvedAlwaysShowUsageEstimate },
            set: { draft.alwaysShowUsageEstimate = $0 }
        )
    }

    private var fontWeightBinding: Binding<String> {
        Binding(
            get: { draft.menuBarFontWeight ?? "medium" },
            set: { draft.menuBarFontWeight = $0 == "medium" ? nil : $0 }
        )
    }

    private var textColorModeBinding: Binding<TextColorMode> {
        Binding(
            get: { draft.textColorMode ?? .primary },
            set: { draft.textColorMode = $0 == .primary ? nil : $0 }
        )
    }

    private var sparklineDirectionBinding: Binding<SparklineDirection> {
        Binding(
            get: { draft.sparklineDirection ?? .ascending },
            set: { draft.sparklineDirection = $0 == .ascending ? nil : $0 }
        )
    }
}

/// Live "how it'll look" demo for the Popover bar settings — same row layout
/// and same bar view as the real popover, driven by fixed sample data so it
/// updates instantly as the user changes bar fill, height, or history style.
private struct VisualBarPreviewRow: View {
    let config: AppConfig

    private static let demoPct = 58
    private static let demoCycleRemainingFrac: CGFloat = 0.62

    // A fixed, realistic-looking usage curve — climbs, resets, climbs again —
    // purely for demonstration; unrelated to any real usage history.
    private static let demoPoints: [BurnPoint] = {
        let shape = [4, 4, 4, 9, 15, 18, 22, 26, 29, 31, 33, 0, 0, 3, 7, 10, 14, 17, 19, 22, 25, 28, 31, 34, 37, 40, 42, 45, 47, 49, 52, 55, 58]
        let step: TimeInterval = 600
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return shape.enumerated().map { index, pct in
            let ts = base.addingTimeInterval(TimeInterval(index) * step)
            return BurnPoint(id: ts, ts: ts, pct: pct)
        }
    }()

    private var demoColor: Color {
        let remaining = 100 - min(100, max(0, Self.demoPct))
        return Color(hue: Double(remaining) / 300, saturation: 0.82, brightness: 0.88)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("5-hour")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)

                VisualBurnBarView(
                    burnPoints: Self.demoPoints,
                    currentPct: Self.demoPct,
                    remainingCountdown: config.showsRemainingCountdown,
                    color: demoColor,
                    sparklineDirection: config.sparklineDirection ?? .ascending,
                    barMode: config.resolvedVisualBarMode,
                    blockWidth: config.resolvedVisualBlockWidth,
                    blockGap: config.resolvedVisualBlockGap,
                    historyStyle: config.resolvedVisualHistoryStyle,
                    barHeight: config.resolvedVisualBarHeight,
                    historyDarken: config.resolvedVisualHistoryDarken,
                    mergeUnchangedHistory: config.resolvedMergeUnchangedHistoryBlocks,
                    roundedHistorySteps: config.resolvedRoundedHistorySteps,
                    connectedHistorySteps: config.resolvedConnectedHistorySteps,
                    cycleRemainingFrac: Self.demoCycleRemainingFrac
                )

                let displayPct = config.showsRemainingCountdown ? max(0, 100 - Self.demoPct) : Self.demoPct
                Text("\(displayPct)%")
                    .font(.system(size: config.resolvedPopoverPercentFontSize, weight: resolvedPercentFontWeight(from: config.popoverPercentFontWeight), design: .monospaced).monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }
}

private struct ProviderSettingsSection: View {
    @Binding var source: SourceConfig
    let snapshot: UsageSnapshot?

    private enum TestState {
        case idle, testing, ok(Int), failed(String)
        var isBusy: Bool { if case .testing = self { return true }; return false }
    }

    private enum ImportState {
        case idle, importing, imported(String), failed(String)
        var isBusy: Bool { if case .importing = self { return true }; return false }
    }

    @State private var testState: TestState = .idle
    @State private var importState: ImportState = .idle
    @State private var confirmsProfileRemoval = false

    private var isClaude: Bool { source.id.hasPrefix("claude") }
    private var usesClaudeProfile: Bool { source.mode == .claudeOAuth }
    private var isCodex: Bool { source.mode == .codexRPC }

    private var canTest: Bool {
        if usesClaudeProfile { return source.claudeProfile != nil }
        guard let cmd = source.command else { return false }
        return !cmd.executable.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var testButtonTitle: String {
        switch testState {
        case .testing: return "Testing…"
        case .failed: return "Retry"
        default: return "Test Connection"
        }
    }

    @ViewBuilder
    private var testResultView: some View {
        switch testState {
        case .ok(let pct):
            Label("\(100 - pct)% left · OK", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.callout).lineLimit(2)
        default:
            EmptyView()
        }
    }

    var body: some View {
        Section {
            Toggle("Show in menu bar", isOn: $source.enabled)

            TextField("Short label", text: $source.label)
                .textFieldStyle(.roundedBorder)
                .disabled(!source.enabled)

            Picker("Usage value in menu bar", selection: quotaBinding) {
                ForEach(QuotaSelection.allCases, id: \.self) { quota in
                    Text(quota.displayName).tag(quota)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!source.enabled)

            LabeledContent("Show in popover") {
                HStack(spacing: 16) {
                    Toggle("5-hour", isOn: showFiveHourBinding)
                    Toggle("1-week", isOn: showOneWeekBinding)
                    if isClaude {
                        Toggle("Extra", isOn: showExtraBinding)
                            .help("Model-scoped weekly limits some plans report, like \"Fable\" — only available with the Secure profile connection.")
                    }
                    Toggle("Percent", isOn: showPercentBinding)
                }
            }
            .disabled(!source.enabled)

            Picker("Percent shown", selection: $source.popoverPercentMode) {
                Text("Global default").tag(Optional<PercentDisplayMode>.none)
                ForEach(PercentDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(Optional(mode))
                }
            }
            .pickerStyle(.segmented)
            .disabled(!source.enabled || !source.resolvedShowPercentInPopover)

            if isClaude {
                Picker("Connection", selection: claudeConnectionBinding) {
                    Text("Secure profile").tag(SourceMode.claudeOAuth)
                    Text("Claude CLI").tag(SourceMode.claudeCLI)
                }
                .pickerStyle(.segmented)

                if usesClaudeProfile {
                    claudeProfileControls
                } else {
                    TextField("Claude CLI path", text: executableBinding)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!source.enabled)

                    TextField("CLAUDE_CONFIG_DIR (empty = default account)", text: localPathBinding)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!source.enabled)
                }
            } else {
                TextField("Codex CLI path", text: executableBinding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!source.enabled)
            }

            LabeledContent("Fetch method") {
                Text(fetchMethodDescription)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Last usage check") {
                Text(lastUsageCheckDescription)
                    .foregroundStyle(lastUsageCheckColor)
                    .lineLimit(2)
            }

            LabeledContent("Last value") {
                Text(lastUsageValueDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            if isClaude {
                LabeledContent("Verify usage") {
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://claude.ai/new#settings/usage")!)
                    } label: {
                        Label("Open claude.ai usage page", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.link)
                }
            } else {
                LabeledContent("Codex account") {
                    Text(codexAccountEmail ?? "Unknown — log in with `codex login`")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("Verify usage") {
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/cloud/settings/analytics")!)
                    } label: {
                        Label("Open ChatGPT usage page", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.link)
                }
            }

            LabeledContent("Icon") {
                HStack(spacing: 8) {
                    if let img = ProviderIconRenderer.image(iconData: source.iconData, iconName: source.iconName, size: 16, color: .labelColor) {
                        Image(nsImage: img)
                            .interpolation(.high)
                            .antialiased(true)
                    }
                    Text(iconDisplayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if source.iconData != nil {
                        Button {
                            source.iconData = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        panel.message = "Choose an SVG or PNG icon for this provider"
                        if panel.runModal() == .OK,
                           let url = panel.url,
                           let data = try? Data(contentsOf: url) {
                            source.iconData = data.base64EncodedString()
                            source.iconName = nil
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    runTest()
                } label: {
                    HStack(spacing: 6) {
                        if case .testing = testState {
                            ProgressView().controlSize(.mini)
                        }
                        Text(testButtonTitle)
                    }
                }
                .disabled(!canTest || testState.isBusy)

                testResultView
            }
        } header: {
            Label(providerName, systemImage: providerIcon)
        } footer: {
            if isClaude {
                if usesClaudeProfile {
                    Text("Credentials are copied into a separate AI Usage Keychain item. Importing never changes the account used by Claude Code, VS Code or Zed. Secure profile is also required to see extra model-scoped limits some plans report (e.g. \"Fable\") — the Claude CLI connection can't read those.")
                } else {
                    Text("Use a separate CLAUDE_CONFIG_DIR for a second subscription. The OAuth setup-token environment variable is excluded from the probe. Note: extra model-scoped limits some plans report (e.g. \"Fable\") only show up with the Secure profile connection, not Claude CLI.")
                }
            } else {
                Text("Uses JSON-RPC initialize, initialized, then account/rateLimits/read in read-only mode.")
            }
        }
        .onChange(of: source.command?.executable) { _ in testState = .idle }
        .onChange(of: source.mode) { _ in testState = .idle }
        .confirmationDialog(
            "Remove secure Claude profile?",
            isPresented: $confirmsProfileRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Profile", role: .destructive) {
                removeClaudeProfile()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes only the AI Usage Keychain copy. Your Claude Code login is not changed.")
        }
    }

    @ViewBuilder
    private var claudeProfileControls: some View {
        if let profile = source.claudeProfile {
            TextField("Profile name", text: profileNameBinding)
                .textFieldStyle(.roundedBorder)

            if let accountLabel = profile.accountLabel {
                LabeledContent("Claude account") {
                    Text(accountLabel)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            LabeledContent("Profile") {
                Text("Not imported")
                    .foregroundStyle(.secondary)
            }
        }

        HStack(spacing: 10) {
            Button {
                importCurrentClaudeAccount()
            } label: {
                HStack(spacing: 6) {
                    if case .importing = importState {
                        ProgressView().controlSize(.mini)
                    }
                    Text(source.claudeProfile == nil ? "Import Current Claude Account" : "Replace from Current Login")
                }
            }
            .disabled(importState.isBusy)

            if source.claudeProfile != nil {
                Button("Remove", role: .destructive) {
                    confirmsProfileRemoval = true
                }
                .disabled(importState.isBusy)
            }

            switch importState {
            case .imported(let source):
                Label(source, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            case .failed(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(2)
            default:
                EmptyView()
            }
        }
    }

    private func runTest() {
        testState = .testing
        Task { @MainActor in
            let testSource = SourceConfig(
                id: source.id,
                label: source.label,
                enabled: true,
                mode: source.mode,
                command: source.command,
                localPath: source.localPath,
                quota: source.quota,
                iconName: source.iconName,
                claudeProfile: source.claudeProfile
            )
            let probes = UsageProbeFactory.makeProbes(config: AppConfig(
                refreshIntervalSeconds: 60,
                sources: [testSource]
            ))
            guard let probe = probes.first else {
                testState = .failed("Could not create probe")
                return
            }
            let snap = await probe.readUsage()
            guard case .testing = testState else { return }
            if snap.status == .ok, let pct = snap.percentUsed {
                testState = .ok(pct)
            } else {
                testState = .failed(snap.errorMessage ?? "No data returned")
            }
        }
    }

    private func importCurrentClaudeAccount() {
        importState = .importing
        let existingID = source.claudeProfile?.id
        let preferredName = source.claudeProfile?.name ?? providerName

        Task {
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    try ClaudeCodeCredentialImporter().importCurrentAccount(
                        profileID: existingID,
                        preferredName: preferredName
                    )
                }.value
                source.claudeProfile = imported.profile
                source.mode = .claudeOAuth
                source.localPath = nil
                importState = .imported(imported.credentialSourceDescription)
                testState = .idle
            } catch {
                importState = .failed(error.localizedDescription)
            }
        }
    }

    private func removeClaudeProfile() {
        guard let profileID = source.claudeProfile?.id else { return }
        importState = .importing
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try KeychainClaudeCredentialStore().delete(profileID: profileID)
                }.value
                source.claudeProfile = nil
                testState = .idle
                importState = .idle
            } catch {
                importState = .failed(error.localizedDescription)
            }
        }
    }

    private var providerName: String {
        switch source.id {
        case "claude1": "Claude Subscription 1"
        case "claude2": "Claude Subscription 2"
        case "codex": "GPT Codex"
        default: source.label
        }
    }

    private var providerIcon: String {
        isCodex ? "chevron.left.forwardslash.chevron.right" : "terminal"
    }

    private var fetchMethodDescription: String {
        if isCodex { return "RPC · codex app-server" }
        if usesClaudeProfile { return "OAuth · Anthropic usage" }
        return "CLI · claude /usage"
    }

    private var lastUsageCheckDescription: String {
        guard let snapshot else { return "No check yet" }
        let time = snapshot.updatedAt.map(Self.lastCheckFormatter.string(from:)) ?? "Never"
        switch snapshot.status {
        case .ok:
            return "\(time) · OK"
        case .failed:
            if let message = snapshot.errorMessage, !message.isEmpty {
                return "\(time) · Failed: \(message)"
            }
            return "\(time) · Failed"
        case .disabled:
            return "\(time) · Disabled"
        case .idle:
            return "\(time) · Waiting"
        }
    }

    private var lastUsageCheckColor: Color {
        guard let snapshot else { return .secondary }
        switch snapshot.status {
        case .ok: return .green
        case .failed: return .red
        case .disabled, .idle: return .secondary
        }
    }

    private var lastUsageValueDescription: String {
        guard let snapshot else { return "No value yet" }
        if let displayValue = snapshot.displayValue {
            return displayValue
        }

        var parts: [String] = []
        if let fiveHour = snapshot.fiveHour {
            parts.append("5-hour \(fiveHour.percentUsed)% used")
        }
        if let oneWeek = snapshot.oneWeek {
            parts.append("1-week \(oneWeek.percentUsed)% used")
        }
        for (name, window) in snapshot.extraWindows.sorted(by: { $0.key < $1.key }) {
            parts.append("\(name) \(window.percentUsed)% used")
        }
        if parts.isEmpty, let percentUsed = snapshot.percentUsed {
            parts.append("\(percentUsed)% used")
        }
        return parts.isEmpty ? "No value yet" : parts.joined(separator: " · ")
    }

    private static let lastCheckFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private var claudeConnectionBinding: Binding<SourceMode> {
        Binding(
            get: { usesClaudeProfile ? .claudeOAuth : .claudeCLI },
            set: { source.mode = $0 }
        )
    }

    private var profileNameBinding: Binding<String> {
        Binding(
            get: { source.claudeProfile?.name ?? "" },
            set: { value in
                guard var profile = source.claudeProfile else { return }
                profile.name = value
                source.claudeProfile = profile
            }
        )
    }

    private var quotaBinding: Binding<QuotaSelection> {
        Binding(
            get: { source.quota ?? .session },
            set: { source.quota = $0 }
        )
    }

    private var showFiveHourBinding: Binding<Bool> {
        Binding(
            get: { source.resolvedShowFiveHourInPopover },
            set: { source.showFiveHourInPopover = $0 }
        )
    }

    private var showOneWeekBinding: Binding<Bool> {
        Binding(
            get: { source.resolvedShowOneWeekInPopover },
            set: { source.showOneWeekInPopover = $0 }
        )
    }

    private var showExtraBinding: Binding<Bool> {
        Binding(
            get: { source.resolvedShowExtraInPopover },
            set: { source.showExtraInPopover = $0 }
        )
    }

    private var showPercentBinding: Binding<Bool> {
        Binding(
            get: { source.resolvedShowPercentInPopover },
            set: { source.showPercentInPopover = $0 }
        )
    }

    private var executableBinding: Binding<String> {
        Binding(
            get: { source.command?.executable ?? "" },
            set: { value in
                var command = source.command ?? defaultCommand
                command.executable = value
                source.command = command
            }
        )
    }

    private var localPathBinding: Binding<String> {
        Binding(
            get: { source.localPath ?? "" },
            set: { source.localPath = $0.isEmpty ? nil : $0 }
        )
    }

    private var defaultCommand: CommandConfig {
        CommandConfig(
            executable: isCodex ? "/opt/homebrew/bin/codex" : "/opt/homebrew/bin/claude",
            timeoutSeconds: isCodex ? 15 : 20
        )
    }

    private var iconDisplayName: String {
        source.iconData != nil ? "Custom icon" : "None"
    }

    private var codexAccountEmail: String? {
        CodexAccountReader.currentAccountEmail()
    }

}

/// Tappable chips to show/hide individual series in the History chart, so a
/// busy chart with many connections can be decluttered on the fly.
private struct SeriesToggleRow: View {
    let seriesNames: [String]
    @Binding var hidden: Set<String>
    let color: (String) -> Color

    var body: some View {
        HStack(spacing: 8) {
            ForEach(seriesNames, id: \.self) { name in
                let isVisible = !hidden.contains(name)
                Button {
                    if isVisible {
                        hidden.insert(name)
                    } else {
                        hidden.remove(name)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isVisible ? color(name) : Color.secondary.opacity(0.35))
                            .frame(width: 7, height: 7)
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(isVisible ? .primary : .secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(isVisible ? color(name).opacity(0.14) : Color.secondary.opacity(0.08))
                    )
                    .overlay(
                        Capsule().stroke(isVisible ? color(name).opacity(0.4) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - History tab

private struct HistoryView: View {
    let historyStore: UsageHistoryStore
    let config: AppConfig

    @State private var selectedRange: HistoryRange = .rollingDay
    @State private var entries: [UsageHistoryEntry] = []
    @State private var isLoading = false
    @State private var zoomLevel = 0
    @State private var xZoomDomain: ClosedRange<Date>?
    @State private var dragStartX: CGFloat?
    @State private var dragEndX: CGFloat?
    @State private var hiddenSeries: Set<String> = []

    private var enabledSources: [SourceConfig] { config.sources.filter(\.enabled) }

    // Every series that could appear, regardless of whether it currently has
    // data — lets the toggle row stay stable as sources gain/lose points.
    // Extra (model-scoped) series names aren't known ahead of time, so they're
    // discovered from whatever's actually been recorded for each source.
    private var allSeriesNames: [String] {
        enabledSources.flatMap { source -> [String] in
            var names = ["\(source.label) 5h", "\(source.label) 1w"]
            let extraNames = Set(entries.compactMap { $0.sources[source.id]?.extra?.keys }.flatMap { $0 }).sorted()
            names += extraNames.map { "\(source.label) \($0)" }
            return names
        }
    }

    // A fixed, deterministic palette so a series always gets the same color
    // in the legend, the chart lines, and its own toggle chip.
    private static let seriesPalette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .yellow, .indigo]

    private func color(for series: String) -> Color {
        guard let index = allSeriesNames.firstIndex(of: series) else { return .secondary }
        return Self.seriesPalette[index % Self.seriesPalette.count]
    }

    private enum HistoryRange: String, CaseIterable, Identifiable {
        case today
        case rollingDay
        case week
        case month

        var id: String { rawValue }

        var label: String {
            switch self {
            case .today: "Today"
            case .rollingDay: "24 h"
            case .week: "7 days"
            case .month: "30 days"
            }
        }

        var usesTimeAxis: Bool {
            switch self {
            case .today, .rollingDay: true
            case .week, .month: false
            }
        }

        func domain(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
            switch self {
            case .today:
                return calendar.startOfDay(for: now)...now
            case .rollingDay:
                return now.addingTimeInterval(-86_400)...now
            case .week:
                return now.addingTimeInterval(-7 * 86_400)...now
            case .month:
                return now.addingTimeInterval(-30 * 86_400)...now
            }
        }
    }

    private struct ChartPoint: Identifiable {
        let id = UUID()
        let ts: Date
        let series: String
        let pct: Int
        let isWeek: Bool
    }

    private var chartPoints: [ChartPoint] {
        entries.flatMap { entry in
            enabledSources.flatMap { source -> [ChartPoint] in
                guard let w = entry.sources[source.id] else { return [] }
                var pts: [ChartPoint] = []
                let fiveHKey = "\(source.label) 5h"
                let oneWKey = "\(source.label) 1w"
                if !hiddenSeries.contains(fiveHKey), let v = w.fiveHour { pts.append(.init(ts: entry.ts, series: fiveHKey, pct: v, isWeek: false)) }
                if !hiddenSeries.contains(oneWKey), let v = w.oneWeek { pts.append(.init(ts: entry.ts, series: oneWKey, pct: v, isWeek: true)) }
                // Extra (model-scoped) windows reset weekly, like 1-week — styled the same.
                for (name, v) in w.extra ?? [:] {
                    let key = "\(source.label) \(name)"
                    if !hiddenSeries.contains(key) { pts.append(.init(ts: entry.ts, series: key, pct: v, isWeek: true)) }
                }
                return pts
            }
        }
    }

    private var chartXDomain: ClosedRange<Date> {
        if let xZoomDomain { return xZoomDomain }
        return selectedRange.domain()
    }

    private var chartYDomain: ClosedRange<Double> {
        guard zoomLevel > 0, !chartPoints.isEmpty else { return 0...100 }
        let values = chartPoints.map(\.pct)
        guard let minValue = values.min(), let maxValue = values.max() else { return 0...100 }

        let margin = zoomLevel == 1 ? 15 : 8
        var lower = max(0, minValue - margin)
        var upper = min(100, maxValue + margin)

        if upper - lower < 12 {
            let center = (upper + lower) / 2
            lower = max(0, center - 6)
            upper = min(100, center + 6)
        }
        return Double(lower)...Double(upper)
    }

    private var yAxisValues: [Double] {
        let domain = chartYDomain
        if domain.lowerBound == 0, domain.upperBound == 100 {
            return [0, 25, 50, 75, 100]
        }

        let step = max(5, ((domain.upperBound - domain.lowerBound) / 4).rounded())
        let start = (domain.lowerBound / step).rounded(.down) * step
        return stride(from: start, through: domain.upperBound, by: step)
            .filter { $0 >= domain.lowerBound && $0 <= domain.upperBound }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Usage over time")
                    .font(.headline)
                Spacer()
                Picker("", selection: $selectedRange) {
                    ForEach(HistoryRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                HStack(spacing: 6) {
                    Button {
                        xZoomDomain = nil
                    } label: {
                        Image(systemName: "arrow.left.and.right")
                    }
                    .disabled(xZoomDomain == nil)
                    .help("Show full time range")

                    Button {
                        zoomLevel = max(0, zoomLevel - 1)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .disabled(zoomLevel == 0)
                    .help("Zoom statistics out")

                    Button {
                        zoomLevel = min(2, zoomLevel + 1)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .disabled(zoomLevel == 2 || chartPoints.isEmpty)
                    .help("Zoom statistics in")
                }
                .buttonStyle(.borderless)
                Button {
                    NSWorkspace.shared.open(historyStore.directory)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show history folder in Finder")
            }

            if !allSeriesNames.isEmpty {
                SeriesToggleRow(
                    seriesNames: allSeriesNames,
                    hidden: $hiddenSeries,
                    color: color(for:)
                )
            }

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if chartPoints.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No history yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Usage is recorded on ≥1% change or every 30 minutes.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Chart(chartPoints) { pt in
                    LineMark(
                        x: .value("Time", pt.ts),
                        y: .value("%", pt.pct)
                    )
                    .foregroundStyle(by: .value("Series", pt.series))
                    .lineStyle(pt.isWeek
                        ? StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                        : StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                }
                .chartForegroundStyleScale(domain: allSeriesNames, range: allSeriesNames.map(color(for:)))
                .chartXScale(domain: chartXDomain)
                .chartYScale(domain: chartYDomain)
                .chartYAxis {
                    AxisMarks(values: yAxisValues) { value in
                        AxisGridLine()
                        AxisValueLabel { Text("\(Int(value.as(Double.self) ?? 0))%").font(.caption2) }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) {
                        AxisGridLine()
                        AxisValueLabel(
                            format: selectedRange.usesTimeAxis
                                ? .dateTime.hour().minute()
                                : .dateTime.day().month()
                        )
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        let plotArea = geometry[proxy.plotAreaFrame]
                        ZStack(alignment: .topLeading) {
                            if let dragStartX, let dragEndX {
                                let lower = min(dragStartX, dragEndX)
                                let upper = max(dragStartX, dragEndX)
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.16))
                                    .overlay {
                                        Rectangle()
                                            .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
                                    }
                                    .frame(width: max(1, upper - lower), height: plotArea.height)
                                    .offset(x: plotArea.minX + lower, y: plotArea.minY)
                            }

                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .frame(width: plotArea.width, height: plotArea.height)
                                .offset(x: plotArea.minX, y: plotArea.minY)
                                .gesture(
                                    DragGesture(minimumDistance: 8)
                                        .onChanged { value in
                                            let x = min(max(value.location.x - plotArea.minX, 0), plotArea.width)
                                            if dragStartX == nil {
                                                dragStartX = min(max(value.startLocation.x - plotArea.minX, 0), plotArea.width)
                                            }
                                            dragEndX = x
                                        }
                                        .onEnded { _ in
                                            defer {
                                                dragStartX = nil
                                                dragEndX = nil
                                            }
                                            guard let dragStartX, let dragEndX,
                                                  abs(dragEndX - dragStartX) >= 12 else {
                                                return
                                            }
                                            let lowerX = min(dragStartX, dragEndX)
                                            let upperX = max(dragStartX, dragEndX)
                                            guard let start: Date = proxy.value(atX: lowerX),
                                                  let end: Date = proxy.value(atX: upperX),
                                                  end.timeIntervalSince(start) >= 60 else {
                                                return
                                            }
                                            xZoomDomain = start...end
                                        }
                                )
                        }
                    }
                }
                .frame(height: 220)

                Divider()

                recentTable
            }
        }
        .padding(20)
        .task(id: selectedRange) {
            isLoading = true
            xZoomDomain = nil
            let domain = selectedRange.domain()
            entries = await historyStore.load(from: domain.lowerBound, to: domain.upperBound)
            isLoading = false
        }
    }

    private var recentTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent entries")
                .font(.subheadline.weight(.medium))

            // Column header
            HStack(spacing: 0) {
                Text("Time")
                    .frame(width: 150, alignment: .leading)
                ForEach(enabledSources, id: \.id) { src in
                    Text("\(src.label) 5h")
                        .frame(width: 72, alignment: .trailing)
                    Text("\(src.label) 1w")
                        .frame(width: 72, alignment: .trailing)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.suffix(50).reversed().enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 0) {
                            Text(entry.ts, format: .dateTime.day().month().hour().minute().second())
                                .frame(width: 150, alignment: .leading)
                                .foregroundStyle(.secondary)
                            ForEach(enabledSources, id: \.id) { src in
                                let w = entry.sources[src.id]
                                Text(w?.fiveHour.map { "\($0)%" } ?? "—")
                                    .frame(width: 72, alignment: .trailing)
                                Text(w?.oneWeek.map  { "\($0)%" } ?? "—")
                                    .frame(width: 72, alignment: .trailing)
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .padding(.vertical, 3)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }
}

// MARK: - Info tab

private struct InfoView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Version 1.6 · 2026-07-18")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                NSWorkspace.shared.open(URL(string: "https://github.com/DominikVsetecka/ai-usage")!)
            } label: {
                Label("github.com/DominikVsetecka/ai-usage", systemImage: "link")
            }
            .buttonStyle(.link)

            Divider()
                .frame(maxWidth: 380)

            VStack(alignment: .leading, spacing: 12) {
                Text("Requirements")
                    .font(.headline)
                InfoRequirementRow(
                    icon: "apple.terminal",
                    name: "claude",
                    detail: "Anthropic Claude Code CLI — provides the /usage command"
                )
                InfoRequirementRow(
                    icon: "apple.terminal",
                    name: "codex",
                    detail: "OpenAI Codex CLI — communicates via app-server JSON-RPC"
                )
                Text("Each provider can be disabled in Settings if not installed.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: 380, alignment: .leading)

            Spacer()
        }
        .padding(28)
    }
}

private struct InfoRequirementRow: View {
    let icon: String
    let name: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.callout.weight(.medium))
                    .fontDesign(.monospaced)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
