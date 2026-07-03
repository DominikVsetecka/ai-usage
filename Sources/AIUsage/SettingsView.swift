import AIUsageCore
import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var draft: AppConfig
    let historyStore: UsageHistoryStore
    let onSave: (AppConfig) -> Void
    let onCancel: () -> Void

    @State private var selectedTab: SettingsTab = .settings

    enum SettingsTab { case settings, history, info }

    init(config: AppConfig, historyStore: UsageHistoryStore, onSave: @escaping (AppConfig) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: config)
        self.historyStore = historyStore
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            TabView(selection: $selectedTab) {
                settingsContent
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(SettingsTab.settings)

                HistoryView(historyStore: historyStore, config: draft)
                    .tabItem { Label("History", systemImage: "chart.line.uptrend.xyaxis") }
                    .tag(SettingsTab.history)

                InfoView()
                    .tabItem { Label("Info", systemImage: "info.circle") }
                    .tag(SettingsTab.info)
            }
        }
        .frame(minWidth: 660, minHeight: 660)
    }

    private var settingsContent: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    Picker("Refresh interval", selection: $draft.refreshIntervalSeconds) {
                        Text("15 seconds").tag(TimeInterval(15))
                        Text("30 seconds").tag(TimeInterval(30))
                        Text("1 minute").tag(TimeInterval(60))
                        Text("2 minutes").tag(TimeInterval(120))
                        Text("5 minutes").tag(TimeInterval(300))
                    }
                    .pickerStyle(.menu)

                    Toggle("Remaining countdown (100% to 0%)", isOn: remainingCountdownBinding)

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

                    Picker("Sparkline direction", selection: sparklineDirectionBinding) {
                        Text("Ascending — rises with usage").tag(SparklineDirection.ascending)
                        Text("Descending — drops from top").tag(SparklineDirection.descending)
                    }
                    .pickerStyle(.segmented)
                }

                ForEach(draft.sources.indices, id: \.self) { index in
                    ProviderSettingsSection(source: $draft.sources[index])
                }
            }
            .formStyle(.grouped)

            Divider()
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
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Usage")
                    .font(.headline)
                Text("Configure each menu bar value")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var remainingCountdownBinding: Binding<Bool> {
        Binding(
            get: { draft.showsRemainingCountdown },
            set: { draft.remainingCountdownEnabled = $0 }
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

private struct ProviderSettingsSection: View {
    @Binding var source: SourceConfig

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

            Picker("Usage value", selection: quotaBinding) {
                ForEach(QuotaSelection.allCases, id: \.self) { quota in
                    Text(quota.displayName).tag(quota)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!source.enabled)

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
                    Text("Credentials are copied into a separate AI Usage Keychain item. Importing never changes the account used by Claude Code, VS Code or Zed.")
                } else {
                    Text("Use a separate CLAUDE_CONFIG_DIR for a second subscription. The OAuth setup-token environment variable is excluded from the probe.")
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
                refreshIntervalSeconds: 30,
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

    private var enabledSources: [SourceConfig] { config.sources.filter(\.enabled) }

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
                if let v = w.fiveHour { pts.append(.init(ts: entry.ts, series: "\(source.label) 5h", pct: v, isWeek: false)) }
                if let v = w.oneWeek  { pts.append(.init(ts: entry.ts, series: "\(source.label) 1w", pct: v, isWeek: true)) }
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

            VStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.tint)
                    .padding(.bottom, 4)
                Text("AI Usage")
                    .font(.largeTitle.weight(.semibold))
                Text("Version 1.0")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("by Dominik Vsetecka")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

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
