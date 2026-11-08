import AIUsageCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum AccountWizardRequest: Identifiable, Equatable {
    case add
    case fix(String)

    var id: String {
        switch self {
        case .add: "add"
        case .fix(let accountID): "fix-\(accountID)"
        }
    }
}

/// What the wizard hands back once an account was added or repaired.
struct AccountWizardOutcome {
    let source: SourceConfig
    let isNew: Bool
    let message: String
    /// Keychain item that is no longer needed, e.g. after switching an account
    /// from its own login to reading Claude Code live.
    let obsoleteProfileID: UUID?
}

/// Settings › Accounts: menu bar preview, accounts as cards, one inspector for
/// the selected account, plus connection history and the Keychain inventory.
/// Adding, reconnecting and removing take effect immediately; display tweaks
/// stay in the Settings draft until Save & Refresh.
struct AccountsPanel: View {
    @Binding var draft: AppConfig
    let snapshots: [UsageSnapshot]
    let eventStore: ConnectionEventStore
    let onCommitAccounts: ([SourceConfig]) -> Void
    let onCredentialsChanged: (UUID) -> Void

    private enum InspectorTab: String, CaseIterable, Identifiable {
        case display = "Display"
        case connection = "Connection"
        case keychain = "Keychain"
        var id: String { rawValue }
    }

    private struct PendingRemoval: Identifiable {
        let id = UUID()
        let source: SourceConfig
        let index: Int
        let keepHistory: Bool
    }

    @ObservedObject private var clock = RefreshClock.shared
    @State private var selectedID: String?
    @State private var tab: InspectorTab = .display
    @State private var wizard: AccountWizardRequest?
    @State private var events: [ConnectionEvent] = []
    @State private var historyShowsAll = true
    @State private var keychainItems: [KeychainItemInfo] = []
    @State private var confirmingRemovalID: String?
    @State private var keepHistory = true
    @State private var pendingRemoval: PendingRemoval?
    @State private var toast: String?
    @State private var toastToken = UUID()
    @State private var freshID: String?

    private var selected: SourceConfig? {
        draft.sources.first { $0.id == selectedID }
    }

    private func snapshot(for id: String) -> UsageSnapshot? {
        snapshots.first { $0.sourceID == id }
    }

    private func health(for source: SourceConfig) -> ConnectionHealth {
        guard source.enabled else { return .disabled }
        return ConnectionHealth.of(snapshot(for: source.id))
    }

    private var attention: [SourceConfig] {
        draft.sources.filter { health(for: $0).needsUser }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MenuBarPreview(sources: draft.sources, snapshots: snapshots, remaining: draft.showsRemainingCountdown)
                if !attention.isEmpty {
                    attentionBanner
                }
                cards
                if let source = selected {
                    inspector(for: source)
                } else if draft.sources.isEmpty {
                    emptyState
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        historyPanel
                        keychainPanel
                    }
                    VStack(spacing: 12) {
                        historyPanel
                        keychainPanel
                    }
                }
                Text("Adding, reconnecting and removing accounts takes effect immediately. Display changes apply with Save & Refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .overlay(alignment: .bottom) { toastView }
        .sheet(item: $wizard) { request in
            AccountWizard(
                request: request,
                accounts: draft.sources,
                snapshots: snapshots,
                events: events,
                remaining: draft.showsRemainingCountdown,
                onCommit: apply(outcome:)
            )
        }
        .task {
            if selectedID == nil { selectedID = draft.sources.first?.id }
            // Screenshot hook: open the wizard right away (smoke-test runs only).
            if let start = ProcessInfo.processInfo.environment["AI_USAGE_SMOKE_TEST_WIZARD"] {
                // A sheet requested before the window is on screen is dropped.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                wizard = start.hasPrefix("fix:") ? .fix(String(start.dropFirst(4))) : .add
            }
            await reloadEvents()
            await reloadKeychain()
        }
        .onChange(of: snapshots) { _ in
            Task { await reloadEvents() }
        }
    }

    // MARK: Sections

    private var attentionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(attention.count == 1 ? "1 account needs you" : "\(attention.count) accounts need you")
                    .fontWeight(.semibold)
                Text(attention.map { "\($0.label): \(health(for: $0).title)" }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let first = attention.first {
                Button(Self.fixTitle(for: health(for: first), label: first.label)) {
                    wizard = .fix(first.id)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.12)))
    }

    private var cards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
            ForEach(draft.sources, id: \.id) { source in
                AccountCard(
                    source: source,
                    snapshot: snapshot(for: source.id),
                    health: health(for: source),
                    remaining: source.resolvedRemainingCountdown(globalDefault: draft.showsRemainingCountdown),
                    nextUpdate: clock.nextAttempt(notBefore: snapshot(for: source.id)?.retryAt),
                    isSelected: source.id == selectedID,
                    isFresh: source.id == freshID,
                    onSelect: {
                        selectedID = source.id
                        confirmingRemovalID = nil
                        freshID = nil
                    },
                    onFix: { wizard = .fix(source.id) }
                )
            }
            Button {
                wizard = .add
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                        .font(.title2)
                    Text("Add Account")
                        .fontWeight(.semibold)
                    Text("Claude or Codex")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(Color(nsColor: .separatorColor))
            )
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No accounts yet")
                .font(.headline)
            Text("Add a Claude or Codex account. AI Usage signs in with its own login, so your Claude Code and Codex setups stay untouched.")
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .windowBackgroundColor).opacity(0.6)))
    }

    private func inspector(for source: SourceConfig) -> some View {
        let health = health(for: source)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AccountIcon(source: source, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.displayName)
                        .font(.headline)
                    Text("\(source.accountLabel ?? Self.codexEmail(for: source) ?? "Account unknown") · \(Self.originText(for: source))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                HealthPill(health: health)
                Button("Remove…", role: .destructive) {
                    confirmingRemovalID = source.id
                }
            }

            if confirmingRemovalID == source.id {
                removalConfirmation(for: source)
            } else {
                Picker("", selection: $tab) {
                    ForEach(InspectorTab.allCases) { tab in
                        Text(tab == .connection && health.needsUser ? "\(tab.rawValue) ●" : tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)

                if let binding = binding(for: source.id) {
                    switch tab {
                    case .display:
                        AccountDisplayTab(
                            source: binding,
                            position: (draft.sources.firstIndex { $0.id == source.id } ?? 0) + 1,
                            count: draft.sources.count,
                            onMove: { move(source.id, by: $0) }
                        )
                    case .connection:
                        AccountConnectionTab(
                            source: binding,
                            snapshot: snapshot(for: source.id),
                            health: health,
                            nextUpdate: clock.nextAttempt(notBefore: snapshot(for: source.id)?.retryAt),
                            onReconnect: { wizard = .fix(source.id) }
                        )
                    case .keychain:
                        AccountKeychainTab(source: source, items: keychainItems)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .windowBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func removalConfirmation(for source: SourceConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remove “\(source.displayName)”?")
                .fontWeight(.semibold)
            Text(Self.removalDetail(for: source))
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Keep connection history", isOn: $keepHistory)
            Text("You can undo this for 8 seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Remove", role: .destructive) { remove(source) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                Button("Cancel") { confirmingRemovalID = nil }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.red.opacity(0.6)))
    }

    private var historyPanel: some View {
        let shown = historyShowsAll || selected == nil ? events : events.filter { $0.account == selectedID }
        return PanelBox(title: "History") {
            if let selected {
                Picker("", selection: $historyShowsAll) {
                    Text("All").tag(true)
                    Text("Only \(selected.label)").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
        } content: {
            if shown.isEmpty {
                Text("No events yet.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(shown) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Self.eventTime(event.ts))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 92, alignment: .leading)
                                Text(eventText(event))
                                    .font(.callout)
                                    .fontWeight(historyShowsAll && event.account == selectedID ? .semibold : .regular)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private var keychainPanel: some View {
        PanelBox(title: "Keychain inventory") {
            Button {
                Task { await reloadKeychain() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Read the Keychain again")
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(keychainItems) { item in
                    let owner = draft.sources.first { $0.claudeProfile?.id == item.profileID && $0.mode == .claudeOAuth }
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.service)
                                .font(.caption.monospaced())
                            Text("\(item.account.prefix(8))… · \(item.fingerprint ?? "unreadable")")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let owner {
                            ownerTag(owner.label, active: owner.id == selectedID)
                        } else {
                            Text("Orphaned")
                                .font(.callout)
                                .foregroundStyle(.orange)
                            Button("Delete") { deleteOrphan(item) }
                                .controlSize(.small)
                        }
                    }
                    .modifier(InventoryRowStyle(active: owner != nil && owner?.id == selectedID))
                }
                ForEach(draft.sources.filter { $0.mode == .codexRPC || $0.mode == .claudeCodeLive }, id: \.id) { source in
                    HStack {
                        Text(source.mode == .codexRPC ? "\(source.codexHome ?? CodexAccountService.defaultHome)/auth.json" : "Claude Code-credentials")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        ownerTag("\(source.label) · read only", active: source.id == selectedID)
                    }
                    .modifier(InventoryRowStyle(active: source.id == selectedID))
                }
                if keychainItems.isEmpty && !draft.sources.contains(where: { $0.mode == .codexRPC || $0.mode == .claudeCodeLive }) {
                    Text("AI Usage has nothing stored.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Text("Tokens are never shown — only their last four characters, so you can spot changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func ownerTag(_ text: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            if active {
                Image(systemName: "checkmark.circle.fill")
                Text("Active ·")
            }
            Text(text)
        }
        .font(.callout.weight(active ? .semibold : .regular))
        .foregroundStyle(active ? Color.green : Color.secondary)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            HStack(spacing: 14) {
                Text(toast)
                if pendingRemoval != nil {
                    Button("Undo", action: undoRemoval)
                        .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color(white: 0.12)))
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Actions

    private func binding(for id: String) -> Binding<SourceConfig>? {
        guard let current = draft.sources.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { draft.sources.first { $0.id == id } ?? current },
            set: { updated in
                guard let index = draft.sources.firstIndex(where: { $0.id == id }) else { return }
                draft.sources[index] = updated
            }
        )
    }

    private func move(_ id: String, by offset: Int) {
        guard let index = draft.sources.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard draft.sources.indices.contains(target) else { return }
        draft.sources.swapAt(index, target)
    }

    private func apply(outcome: AccountWizardOutcome) {
        if outcome.isNew {
            draft.sources.append(outcome.source)
            freshID = outcome.source.id
            tab = .display
        } else if let index = draft.sources.firstIndex(where: { $0.id == outcome.source.id }) {
            draft.sources[index] = outcome.source
        }
        selectedID = outcome.source.id
        onCommitAccounts(draft.sources)
        if let profileID = outcome.source.claudeProfile?.id {
            onCredentialsChanged(profileID)
        }
        let source = outcome.source
        Task {
            await eventStore.append(ConnectionEvent(account: source.id, kind: outcome.isNew ? .added : .reconnected, message: outcome.message))
            if let obsolete = outcome.obsoleteProfileID {
                let deleted = await Task.detached { (try? KeychainClaudeCredentialStore().delete(profileID: obsolete)) != nil }.value
                if deleted {
                    await eventStore.append(ConnectionEvent(account: source.id, kind: .keychainDeleted, message: "Old Keychain copy deleted"))
                }
            }
            await reloadEvents()
            await reloadKeychain()
        }
        show(toast: outcome.isNew ? "\(source.label) added" : "\(source.label) updated")
    }

    private func remove(_ source: SourceConfig) {
        guard let index = draft.sources.firstIndex(where: { $0.id == source.id }) else { return }
        finalizePendingRemoval()
        draft.sources.remove(at: index)
        confirmingRemovalID = nil
        selectedID = draft.sources.first?.id
        onCommitAccounts(draft.sources)
        let removal = PendingRemoval(source: source, index: index, keepHistory: keepHistory)
        pendingRemoval = removal
        Task {
            await eventStore.append(ConnectionEvent(account: source.id, kind: .removed, message: "Removed\(keepHistory ? ", history kept" : "")"))
            await reloadEvents()
        }
        show(toast: "\(source.label) removed", duration: 8)
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if pendingRemoval?.id == removal.id { finalizePendingRemoval() }
        }
    }

    private func undoRemoval() {
        guard let removal = pendingRemoval else { return }
        pendingRemoval = nil
        draft.sources.insert(removal.source, at: min(removal.index, draft.sources.count))
        selectedID = removal.source.id
        onCommitAccounts(draft.sources)
        toast = nil
        Task {
            await eventStore.append(ConnectionEvent(account: removal.source.id, kind: .note, message: "Removal undone"))
            await reloadEvents()
        }
    }

    /// Deletes what only the removed account used: its Keychain item, an
    /// app-created Codex folder and its guided-login folder. Claude Code's and
    /// Codex's own logins are never touched.
    private func finalizePendingRemoval() {
        guard let removal = pendingRemoval else { return }
        pendingRemoval = nil
        let source = removal.source
        let stillUsed = draft.sources.contains { $0.claudeProfile?.id == source.claudeProfile?.id }
        Task {
            let messages = await Task.detached { () -> [String] in
                var messages: [String] = []
                if source.mode == .claudeOAuth, let profileID = source.claudeProfile?.id, !stillUsed,
                   (try? KeychainClaudeCredentialStore().delete(profileID: profileID)) != nil {
                    messages.append("Keychain item deleted (\(KeychainClaudeCredentialStore.service))")
                }
                if CodexAccountService.isAppOwned(source.codexHome),
                   (try? FileManager.default.removeItem(at: CodexAccountService.resolvedHome(source.codexHome))) != nil {
                    messages.append("Own Codex folder deleted")
                }
                let loginFolder = ClaudeGuidedLoginService.configDirectory(
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    connectionID: source.id
                )
                if FileManager.default.fileExists(atPath: loginFolder.path),
                   (try? FileManager.default.removeItem(at: loginFolder)) != nil {
                    messages.append("Login folder deleted")
                }
                return messages
            }.value
            for message in messages {
                await eventStore.append(ConnectionEvent(account: source.id, kind: .keychainDeleted, message: message))
            }
            if !removal.keepHistory {
                await eventStore.prune(removingAccounts: [source.id])
            }
            if let profileID = source.claudeProfile?.id { onCredentialsChanged(profileID) }
            await reloadEvents()
            await reloadKeychain()
        }
    }

    private func deleteOrphan(_ item: KeychainItemInfo) {
        guard let profileID = item.profileID else { return }
        Task {
            _ = await Task.detached { try? KeychainClaudeCredentialStore().delete(profileID: profileID) }.value
            await eventStore.append(ConnectionEvent(account: Self.keychainEventAccount, kind: .keychainDeleted, message: "Orphaned item \(item.account.prefix(8))… deleted"))
            await reloadEvents()
            await reloadKeychain()
        }
    }

    private func show(toast text: String, duration: Double = 4) {
        let token = UUID()
        toastToken = token
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if toastToken == token { withAnimation { toast = nil } }
        }
    }

    private func reloadEvents() async {
        events = await eventStore.load()
    }

    private func reloadKeychain() async {
        if DemoUsageData.load() != nil {
            keychainItems = KeychainInventory.demoItems(for: draft.sources)
            return
        }
        let owned = Set(draft.sources.filter { $0.mode == .claudeOAuth }.compactMap(\.claudeProfile?.id))
        keychainItems = await Task.detached { KeychainInventory.appItems(detailsFor: owned) }.value
    }

    /// History entries that belong to no account (orphan clean-up).
    static let keychainEventAccount = "keychain"

    private func eventText(_ event: ConnectionEvent) -> String {
        if event.account == Self.keychainEventAccount {
            return "Keychain · \(event.message)"
        }
        // Entries written before orphan clean-up had its own label used the
        // Keychain item's UUID as account.
        if UUID(uuidString: event.account) != nil {
            return "Keychain · Orphaned item \(event.account.prefix(8))… deleted"
        }
        let label = draft.sources.first { $0.id == event.account }?.label ?? event.account
        return "\(label) · \(event.message)"
    }

    // MARK: Shared wording

    static func fixTitle(for health: ConnectionHealth, label: String) -> String {
        switch health {
        case .incompatible: "Repair \(label)"
        case .notConfigured: "Set Up \(label)"
        default: "Reconnect \(label)"
        }
    }

    static func originText(for source: SourceConfig) -> String {
        switch source.mode {
        case .claudeOAuth:
            switch source.credentialOrigin {
            case .guidedLogin: "Own login"
            case .claudeCodeCopy: "Copy of Claude Code's login (legacy)"
            case nil: "Secure profile"
            }
        case .claudeCodeLive: "Reads Claude Code live"
        case .claudeCLI: "Claude CLI"
        case .codexRPC: source.codexHome == nil ? "Codex CLI · default login" : "Codex CLI · own folder"
        case .fixture, .command: "Command"
        }
    }

    static func codexEmail(for source: SourceConfig) -> String? {
        source.mode == .codexRPC ? CodexAccountService.accountEmail(codexHome: source.codexHome) : nil
    }

    static func removalDetail(for source: SourceConfig) -> String {
        switch source.mode {
        case .claudeOAuth: "Deletes its Keychain item (\(KeychainClaudeCredentialStore.service)). Claude Code stays signed in."
        case .claudeCodeLive: "AI Usage stored nothing for this account. Claude Code stays signed in."
        case .codexRPC:
            CodexAccountService.isAppOwned(source.codexHome)
                ? "Deletes this account's own Codex folder. Your normal Codex setup stays untouched."
                : "Nothing to delete — your Codex login stays as it is."
        default: "Removes the account from the menu bar."
        }
    }

    static func eventTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "dd.MM. HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Building blocks

/// Marks the inventory rows that belong to the account selected above.
private struct InventoryRowStyle: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(active ? Color.green.opacity(0.16) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(active ? Color.green.opacity(0.7) : Color.clear, lineWidth: 1.5))
            .animation(.easeOut(duration: 0.15), value: active)
    }
}

struct MenuBarPreview: View {
    let sources: [SourceConfig]
    let snapshots: [UsageSnapshot]
    let remaining: Bool
    /// The account being added in the wizard, drawn with a dashed outline.
    var pending: (source: SourceConfig, value: Int)?

    var body: some View {
        HStack(spacing: 14) {
            Text("MENU BAR")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(white: 0.55))
            Spacer(minLength: 8)
            ForEach(sources.filter(\.enabled), id: \.id) { source in
                item(for: source)
            }
            if let pending {
                HStack(spacing: 4) {
                    if let icon = ProviderIconRenderer.image(iconData: pending.source.iconData, iconName: pending.source.iconName, size: 12, color: .white) {
                        Image(nsImage: icon)
                    } else {
                        Text(pending.source.label)
                    }
                    Text("\(remaining ? 100 - pending.value : pending.value)%")
                }
                .padding(.horizontal, 3)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2])).foregroundStyle(Color.accentColor))
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(Color(white: 0.96))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.11)))
    }

    private func item(for source: SourceConfig) -> some View {
        let snapshot = snapshots.first { $0.sourceID == source.id }
        let health = ConnectionHealth.of(snapshot)
        let window = (source.quota ?? .session) == .weekly ? snapshot?.oneWeek : snapshot?.fiveHour
        let value = window?.percentUsed ?? snapshot?.percentUsed
        let text = value.map { "\(remaining ? 100 - $0 : $0)%" } ?? "--%"
        return HStack(spacing: 4) {
            if health.needsUser {
                Circle().fill(Color.red).frame(width: 6, height: 6)
            } else if health == .retrying || health == .keychainLocked {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
            }
            if let icon = ProviderIconRenderer.image(iconData: source.iconData, iconName: source.iconName, size: 12, color: .white) {
                Image(nsImage: icon)
            } else {
                Text(source.label)
            }
            Text(text)
        }
        .opacity(health == .connected ? 1 : 0.55)
    }
}

struct AccountIcon: View {
    let source: SourceConfig
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26)
                .fill(source.provider == .codex ? Color(white: 0.15) : Color(red: 0.79, green: 0.42, blue: 0.26))
            if let icon = ProviderIconRenderer.image(iconData: source.iconData, iconName: source.iconName, size: size * 0.58, color: .white) {
                Image(nsImage: icon)
            } else {
                Text(source.provider == .codex ? "G" : "C")
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

struct HealthPill: View {
    let health: ConnectionHealth

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Self.color(for: health)).frame(width: 6, height: 6)
            Text(health.title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Self.color(for: health))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Self.color(for: health).opacity(0.15)))
    }

    static func color(for health: ConnectionHealth) -> Color {
        if health.needsUser { return .red }
        switch health {
        case .connected: return .green
        case .retrying, .keychainLocked, .failing: return .orange
        default: return .secondary
        }
    }
}

private struct AccountCard: View {
    let source: SourceConfig
    let snapshot: UsageSnapshot?
    let health: ConnectionHealth
    let remaining: Bool
    let nextUpdate: Date?
    let isSelected: Bool
    let isFresh: Bool
    let onSelect: () -> Void
    let onFix: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                AccountIcon(source: source, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.label)
                        .fontWeight(.semibold)
                    Text(source.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isFresh {
                    Text("NEW")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Circle()
                    .fill(HealthPill.color(for: health))
                    .frame(width: 8, height: 8)
            }
            UsageMeter(title: "5-hour", window: snapshot?.fiveHour, stale: health != .connected, remaining: remaining)
            UsageMeter(title: "Week", window: snapshot?.oneWeek, stale: health != .connected, remaining: remaining)
            HStack {
                footer
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if health.needsUser {
                    Button(health == .incompatible ? "Repair" : "Reconnect", action: onFix)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var borderColor: Color {
        if isSelected { return health.needsUser ? .red : .accentColor }
        return health.needsUser ? .red.opacity(0.7) : Color(nsColor: .separatorColor)
    }

    @ViewBuilder
    private var footer: some View {
        switch health {
        case .connected:
            HStack(spacing: 0) {
                Text("Checked \(snapshot?.updatedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–") · ")
                CountdownText(prefix: "next in", target: nextUpdate)
            }
            .foregroundStyle(.secondary)
        case .waiting:
            Text("Checking…").foregroundStyle(.secondary)
        case .disabled:
            Text("Hidden from menu bar").foregroundStyle(.secondary)
        case .retrying, .keychainLocked, .failing:
            HStack(spacing: 0) {
                Text(snapshot?.retryAt != nil ? "Rate-limited · " : "\(health.title) · ")
                CountdownText(prefix: snapshot?.retryAt != nil ? "retry in" : "next try in", target: nextUpdate)
            }
            .foregroundStyle(HealthPill.color(for: health))
            .help(snapshot?.retryAt != nil
                  ? "The provider limits requests for a while. AI Usage asks again at the first refresh after the limit ends."
                  : "AI Usage tries again at the next refresh.")
        default:
            Text(health.title).foregroundStyle(HealthPill.color(for: health))
        }
    }
}

private struct UsageMeter: View {
    let title: String
    let window: ProviderUsageWindow?
    let stale: Bool
    let remaining: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(stale ? Color.secondary : Color.accentColor)
                        .frame(width: geometry.size.width * CGFloat(window?.percentUsed ?? 0) / 100)
                }
            }
            .frame(height: 6)
        }
    }

    private var valueText: String {
        guard let window else { return "–" }
        let value = remaining ? 100 - window.percentUsed : window.percentUsed
        return "\(value)% \(remaining ? "left" : "used")\(stale ? " · old" : "")"
    }
}

struct PanelBox<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                accessory()
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// A grouped list of label/value rows, like a Form section.
struct InspectorGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

struct InspectorRow<Content: View>: View {
    let title: String
    var showsDivider = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                Spacer(minLength: 12)
                content()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if showsDivider {
                Divider().padding(.leading, 12)
            }
        }
    }
}

// MARK: - Inspector tabs

private struct AccountDisplayTab: View {
    @Binding var source: SourceConfig
    let position: Int
    let count: Int
    let onMove: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorGroup {
                InspectorRow(title: "Name") {
                    TextField("Name", text: nameBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
                InspectorRow(title: "Short label in menu bar") {
                    TextField("Label", text: $source.label)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                InspectorRow(title: "Show in menu bar") {
                    Toggle("", isOn: $source.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                InspectorRow(title: "Value in menu bar") {
                    Picker("", selection: quotaBinding) {
                        ForEach(QuotaSelection.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                InspectorRow(title: "Show in popover") {
                    HStack(spacing: 12) {
                        Toggle("5-hour", isOn: binding(\.showFiveHourInPopover, default: true))
                        Toggle("1-week", isOn: binding(\.showOneWeekInPopover, default: true))
                        if source.provider == .claude {
                            Toggle("Extra", isOn: binding(\.showExtraInPopover, default: true))
                                .help("Model-scoped limits some plans report, like \"Fable\"")
                        }
                        Toggle("Percent", isOn: binding(\.showPercentInPopover, default: true))
                    }
                }
                InspectorRow(title: "Percent shown") {
                    Picker("", selection: $source.popoverPercentMode) {
                        Text("Global default").tag(Optional<PercentDisplayMode>.none)
                        ForEach(PercentDisplayMode.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                    .disabled(!source.resolvedShowPercentInPopover)
                }
                InspectorRow(title: "Icon") {
                    HStack(spacing: 8) {
                        if let image = ProviderIconRenderer.image(iconData: source.iconData, iconName: source.iconName, size: 16, color: .labelColor) {
                            Image(nsImage: image)
                        }
                        Text(source.iconData != nil ? "Custom icon" : "None")
                            .foregroundStyle(.secondary)
                        if source.iconData != nil {
                            Button {
                                source.iconData = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        Button("Choose…", action: chooseIcon)
                    }
                }
                InspectorRow(title: "Position in menu bar", showsDivider: false) {
                    HStack(spacing: 6) {
                        Text("\(position) of \(count)")
                            .foregroundStyle(.secondary)
                        Button { onMove(-1) } label: { Image(systemName: "arrow.left") }
                            .disabled(position <= 1)
                            .help("Move left")
                        Button { onMove(1) } label: { Image(systemName: "arrow.right") }
                            .disabled(position >= count)
                            .help("Move right")
                    }
                }
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(get: { source.name ?? source.displayName }, set: { source.name = $0 })
    }

    private var quotaBinding: Binding<QuotaSelection> {
        Binding(get: { source.quota ?? .session }, set: { source.quota = $0 })
    }

    private func binding(_ keyPath: WritableKeyPath<SourceConfig, Bool?>, default value: Bool) -> Binding<Bool> {
        Binding(get: { source[keyPath: keyPath] ?? value }, set: { source[keyPath: keyPath] = $0 })
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an SVG or PNG icon for this account"
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            source.iconData = data.base64EncodedString()
            source.iconName = nil
        }
    }
}

private struct AccountConnectionTab: View {
    @Binding var source: SourceConfig
    let snapshot: UsageSnapshot?
    let health: ConnectionHealth
    let nextUpdate: Date?
    let onReconnect: () -> Void

    private enum TestState: Equatable {
        case idle, testing, ok(String), failed(String)
    }

    @State private var testState: TestState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if health.needsUser {
                notice(
                    title: health.title,
                    text: snapshot?.errorMessage ?? "This account needs your attention.",
                    color: .red,
                    action: AccountsPanel.fixTitle(for: health, label: source.label)
                )
            } else if source.mode == .claudeOAuth && source.credentialOrigin == .claudeCodeCopy {
                notice(
                    title: "Legacy import",
                    text: "This account uses a copy of Claude Code's token. Both sides refresh the same token, so whichever refreshes first breaks the other — that's why this connection keeps getting lost. An own login fixes it for good.",
                    color: .orange,
                    action: "Switch to Own Login…"
                )
            } else if health == .retrying || health == .keychainLocked {
                notice(
                    title: health.title,
                    text: health == .keychainLocked
                        ? "The Keychain is still locked after wake. AI Usage waits until you unlock your Mac."
                        : "AI Usage keeps trying on its own and shows the last value meanwhile.\(snapshot?.errorMessage.map { " (\($0))" } ?? "")",
                    color: .orange,
                    action: nil
                )
            }

            InspectorGroup {
                InspectorRow(title: "State") { HealthPill(health: health) }
                InspectorRow(title: "Login") {
                    Text(AccountsPanel.originText(for: source)).foregroundStyle(.secondary)
                }
                InspectorRow(title: "Account") {
                    Text(source.accountLabel ?? AccountsPanel.codexEmail(for: source) ?? "Unknown")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if source.mode == .codexRPC || source.mode == .claudeCLI {
                    InspectorRow(title: source.mode == .codexRPC ? "Codex CLI" : "Claude CLI") {
                        TextField("Path", text: executableBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                    }
                }
                if source.mode == .codexRPC {
                    InspectorRow(title: "Codex folder") {
                        Text(source.codexHome ?? CodexAccountService.defaultHome)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                InspectorRow(title: "Last check") {
                    Text(lastCheck).foregroundStyle(.secondary)
                }
                InspectorRow(title: snapshot?.retryAt != nil ? "Next attempt (rate-limited)" : "Next update") {
                    CountdownText(prefix: "in", target: nextUpdate)
                        .foregroundStyle(snapshot?.retryAt != nil ? Color.orange : Color.secondary)
                }
                InspectorRow(title: "Last value", showsDivider: false) {
                    Text(lastValue)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 10) {
                Button(action: runTest) {
                    HStack(spacing: 6) {
                        if testState == .testing { ProgressView().controlSize(.mini) }
                        Text("Test Connection")
                    }
                }
                .disabled(testState == .testing)
                Button("Reconnect…", action: onReconnect)
                Spacer()
                Button {
                    let url = source.provider == .codex
                        ? "https://chatgpt.com/codex/cloud/settings/analytics"
                        : "https://claude.ai/new#settings/usage"
                    NSWorkspace.shared.open(URL(string: url)!)
                } label: {
                    Label("Verify on website", systemImage: "arrow.up.right")
                }
                .buttonStyle(.link)
            }
            switch testState {
            case .ok(let text):
                Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            case .failed(let text):
                Label(text, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.callout).lineLimit(3)
            default:
                EmptyView()
            }
        }
        .onChange(of: source.id) { _ in testState = .idle }
    }

    private func notice(title: String, text: String, color: Color, action: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).fontWeight(.semibold)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action, action: onReconnect)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.12)))
    }

    private var executableBinding: Binding<String> {
        Binding(
            get: { source.command?.executable ?? "" },
            set: { value in
                var command = source.command ?? CommandConfig(executable: value, timeoutSeconds: source.provider == .codex ? 15 : 20)
                command.executable = value
                source.command = command
            }
        )
    }

    private var lastCheck: String {
        guard let snapshot, let date = snapshot.updatedAt else { return "No check yet" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private var lastValue: String {
        guard let snapshot else { return "No value yet" }
        var parts: [String] = []
        if let five = snapshot.fiveHour { parts.append("5-hour \(five.percentUsed)% used") }
        if let week = snapshot.oneWeek { parts.append("1-week \(week.percentUsed)% used") }
        for (name, window) in snapshot.extraWindows.sorted(by: { $0.key < $1.key }) {
            parts.append("\(name) \(window.percentUsed)% used")
        }
        return parts.isEmpty ? "No value yet" : parts.joined(separator: " · ")
    }

    private func runTest() {
        testState = .testing
        var testSource = source
        testSource.enabled = true
        let config = AppConfig(refreshIntervalSeconds: 90, sources: [testSource])
        Task {
            guard let probe = UsageProbeFactory.makeProbes(config: config).first else { return }
            let result = await probe.readUsage()
            if result.status == .ok {
                testState = .ok("Works · " + [result.fiveHour.map { "5-hour \($0.percentUsed)%" }, result.oneWeek.map { "week \($0.percentUsed)%" }]
                    .compactMap { $0 }.joined(separator: " · "))
            } else {
                testState = .failed(result.errorMessage ?? "No data returned")
            }
        }
    }
}

private struct AccountKeychainTab: View {
    let source: SourceConfig
    let items: [KeychainItemInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stored by AI Usage").fontWeight(.semibold)
            if source.mode == .claudeOAuth, let item = items.first(where: { $0.profileID == source.claudeProfile?.id }) {
                InspectorGroup {
                    InspectorRow(title: "Service") { mono(item.service) }
                    InspectorRow(title: "Key") { mono(item.account) }
                    InspectorRow(title: "Contents") { Text("access token, refresh token, expiry, scopes").foregroundStyle(.secondary) }
                    InspectorRow(title: "Token fingerprint") { mono(item.fingerprint ?? "unreadable") }
                    InspectorRow(title: "Access token expires") { Text(format(item.expiresAt)).foregroundStyle(.secondary) }
                    InspectorRow(title: "Access") { Text("This Mac only, when unlocked").foregroundStyle(.secondary) }
                    InspectorRow(title: "Created") { Text(format(item.created)).foregroundStyle(.secondary) }
                    InspectorRow(title: "Last changed", showsDivider: false) { Text(format(item.modified)).foregroundStyle(.secondary) }
                }
            } else if source.mode == .claudeOAuth {
                Text("No Keychain item found for this account. Reconnect it to sign in again.")
                    .foregroundStyle(.orange)
            } else {
                Text("Nothing. AI Usage keeps no Keychain item for this account.")
                    .foregroundStyle(.secondary)
            }

            Text("Read only").fontWeight(.semibold)
            switch source.mode {
            case .codexRPC:
                InspectorGroup {
                    InspectorRow(title: "\(source.codexHome ?? CodexAccountService.defaultHome)/auth.json", showsDivider: false) {
                        Text("only the e-mail from the ID token").foregroundStyle(.secondary)
                    }
                }
            case .claudeCodeLive:
                InspectorGroup {
                    InspectorRow(title: "Claude Code-credentials", showsDivider: false) {
                        Text("read on every check, never stored").foregroundStyle(.secondary)
                    }
                }
            case .claudeCLI:
                InspectorGroup {
                    InspectorRow(title: source.localPath ?? "~/.claude", showsDivider: false) {
                        Text("Claude CLI's own login").foregroundStyle(.secondary)
                    }
                }
            default:
                Text("No external sources.").foregroundStyle(.secondary)
            }
            Text("Tokens are never shown. The fingerprint shows the last four characters so you can see when a token changed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func mono(_ text: String) -> some View {
        Text(text)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    private func format(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "–"
    }
}
