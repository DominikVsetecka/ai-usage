import AIUsageCore
import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var draft: AppConfig
    let onSave: (AppConfig) -> Void
    let onCancel: () -> Void

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: config)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

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
        .frame(minWidth: 540, minHeight: 620)
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
            Label("\(pct)% · OK", systemImage: "checkmark.circle.fill")
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

            Picker("Icon", selection: iconModeBinding) {
                Text("Label text").tag("none")
                Text("Claude Logo").tag("claude")
                Text("OpenAI Logo").tag("openai")
            }
            .pickerStyle(.menu)

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

    private var iconModeBinding: Binding<String> {
        Binding(
            get: {
                switch source.iconName {
                case "claude": return "claude"
                case "openai": return "openai"
                default: return "none"
                }
            },
            set: { mode in
                switch mode {
                case "claude": source.iconName = "claude"
                case "openai": source.iconName = "openai"
                default: source.iconName = nil
                }
            }
        )
    }

}
