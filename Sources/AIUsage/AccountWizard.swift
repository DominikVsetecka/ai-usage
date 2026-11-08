import AIUsageCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drives adding and repairing accounts. Nothing is written to the config
/// until the usage check succeeds (or the user explicitly saves a paused
/// account); a Keychain item created for an add that is cancelled afterwards
/// is deleted again.
@MainActor
final class AccountWizardModel: ObservableObject {
    enum Step: Equatable {
        case provider
        case method
        case diagnose
        case browserSetup
        case browserWait
        case wrongAccount(expected: String, actual: String)
        case liveDetect
        case codexSetup
        case codexWait
        case checking
        case display
        case done
        case failed(String)
        /// The browser signed in a ChatGPT account that is already connected.
        case codexDuplicate(email: String, label: String)
    }

    enum Method: Equatable {
        case ownLogin, claudeCodeLive, codex
    }

    enum CodexChoice: Equatable {
        /// The login the Codex CLI on this Mac already uses (`~/.codex`).
        case existingLogin
        /// A ChatGPT login just for AI Usage, in its own Codex folder.
        case ownLogin
    }

    enum CheckState: Equatable {
        case running, ok, failed
    }

    struct CheckItem: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var state: CheckState
    }

    enum CheckProblem: Equatable {
        case offline(String), login(String), incompatible(String), other(String)
    }

    let request: AccountWizardRequest
    let accounts: [SourceConfig]
    let snapshots: [UsageSnapshot]
    let events: [ConnectionEvent]
    private let onCommit: (AccountWizardOutcome) -> Void

    @Published var step: Step
    @Published var provider: AccountProvider?
    @Published var method: Method?
    @Published var candidate: SourceConfig

    @Published var email = ""
    @Published var usesSSO = false
    @Published var chromeProfiles: [ClaudeChromeProfile] = []
    @Published var chromeProfileID = ""
    @Published var manualLoginURL: URL?
    @Published var authorizationCode = ""
    @Published var codeSubmitted = false

    @Published var liveAccount: ClaudeCodeAccountPreview?
    @Published var liveError: String?
    @Published var isWorking = false

    @Published var codexFound = true
    @Published var codexVersion: String?
    @Published var codexEmail: String?
    @Published var codexDefaultOwner: SourceConfig?
    @Published var codexChoice: CodexChoice = .ownLogin
    @Published var codexDefaultEmail: String?
    @Published var ownCodexEmail: String?
    @Published var codexLoginURL: URL?

    @Published var checks: [CheckItem] = []
    @Published var checkProblem: CheckProblem?
    @Published var usage: UsageSnapshot?
    @Published var copiedDiagnostics = false

    private(set) var before: (health: ConnectionHealth, origin: String, fingerprint: String?)?
    private(set) var after: (origin: String, fingerprint: String?)?
    private var trail: [Step] = []
    private var loginCancellation: PTYCancellationToken?
    private var codexCancellation: ProcessCancellation?
    private var uncommittedProfileID: UUID?
    private var obsoleteProfileID: UUID?
    private var committed = false

    init(
        request: AccountWizardRequest,
        accounts: [SourceConfig],
        snapshots: [UsageSnapshot],
        events: [ConnectionEvent],
        onCommit: @escaping (AccountWizardOutcome) -> Void
    ) {
        self.request = request
        self.accounts = accounts
        self.snapshots = snapshots
        self.events = events
        self.onCommit = onCommit

        if case .fix(let id) = request, let existing = accounts.first(where: { $0.id == id }) {
            candidate = existing
            provider = existing.provider
            step = .diagnose
            method = existing.provider == .codex ? .codex : (existing.mode == .claudeCodeLive ? .claudeCodeLive : .ownLogin)
            email = existing.accountLabel ?? ""
            let health = ConnectionHealth.of(snapshots.first { $0.sourceID == id })
            let fingerprint = existing.claudeProfile.flatMap { try? KeychainClaudeCredentialStore().load(profileID: $0.id) }
                .map { KeychainInventory.fingerprint(of: $0.accessToken) }
            before = (health, AccountsPanel.originText(for: existing), fingerprint)
        } else {
            candidate = SourceConfig(id: "", label: "", enabled: true, mode: .claudeOAuth, command: nil)
            step = .provider
        }
        chromeProfiles = ClaudeChromeProfileReader().profiles()
        // Screenshot hook: start the add flow at the Claude sign-in choice.
        if !isFix, ProcessInfo.processInfo.environment["AI_USAGE_SMOKE_TEST_WIZARD"] == "add-claude" {
            provider = .claude
            candidate = makeCandidate(for: .claude)
            method = .ownLogin
            trail = [.provider]
            step = .method
        }
        let free = chromeProfiles.first { profile in
            profile.accountEmail.map { email in self.claudeAccount(withEmail: email) == nil } ?? false
        }
        let matching = chromeProfiles.first { $0.accountEmail?.caseInsensitiveCompare(email) == .orderedSame }
        let preselected = isFix ? (matching ?? chromeProfiles.first) : (free ?? chromeProfiles.first)
        chromeProfileID = preselected?.id ?? ""
        if !isFix, let address = preselected?.accountEmail { email = address }
    }

    var isFix: Bool {
        if case .fix = request { return true }
        return false
    }

    var existing: SourceConfig? {
        guard case .fix(let id) = request else { return nil }
        return accounts.first { $0.id == id }
    }

    var currentHealth: ConnectionHealth {
        guard let existing else { return .waiting }
        return ConnectionHealth.of(snapshots.first { $0.sourceID == existing.id })
    }

    var canGoBack: Bool {
        guard let previous = trail.last else { return false }
        switch step {
        case .checking, .done: return false
        default: return previous != step
        }
    }

    func claudeAccount(withEmail email: String) -> SourceConfig? {
        let clean = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return accounts.first {
            $0.provider == .claude && $0.id != existing?.id &&
                $0.accountLabel?.caseInsensitiveCompare(clean) == .orderedSame
        }
    }

    // MARK: Navigation

    func go(_ next: Step) {
        trail.append(step)
        step = next
        enter(next)
    }

    func back() {
        guard let previous = trail.popLast() else { return }
        step = previous
        enter(previous)
    }

    func next() {
        switch step {
        case .provider:
            guard let provider else { return }
            candidate = makeCandidate(for: provider)
            go(provider == .codex ? .codexSetup : .method)
        case .method:
            go(method == .claudeCodeLive ? .liveDetect : .browserSetup)
        case .diagnose:
            switch method {
            case .codex:
                if currentHealth == .needsLogin { go(.codexSetup) } else { runChecks(prefix: []) }
            case .claudeCodeLive: go(.liveDetect)
            default: go(.browserSetup)
            }
        case .browserSetup:
            startBrowserLogin()
        case .liveDetect:
            adoptLiveAccount()
        case .codexSetup:
            if codexEmail != nil {
                runChecks(prefix: [CheckItem(title: "Signed in as \(codexEmail ?? "")", state: .ok)])
            } else {
                startCodexLogin()
            }
        case .checking:
            if isFix { commit() } else { go(.display) }
        case .display:
            commit()
        default:
            break
        }
    }

    private func enter(_ step: Step) {
        switch step {
        case .liveDetect: detectLiveAccount()
        case .codexSetup: inspectCodex()
        default: break
        }
    }

    func cancel() {
        loginCancellation?.cancel()
        codexCancellation?.cancel()
        if !committed, let profileID = uncommittedProfileID {
            try? KeychainClaudeCredentialStore().delete(profileID: profileID)
        }
        // A ChatGPT login made for an account that was never added would
        // otherwise stay behind in its own folder.
        if !committed, !isFix, candidate.mode == .codexRPC, CodexAccountService.isAppOwned(candidate.codexHome) {
            try? FileManager.default.removeItem(at: CodexAccountService.resolvedHome(candidate.codexHome))
        }
    }

    // MARK: Claude own login

    private func startBrowserLogin() {
        go(.browserWait)
        manualLoginURL = nil
        authorizationCode = ""
        codeSubmitted = false
        let cancellation = PTYCancellationToken()
        loginCancellation = cancellation
        let accountID = candidate.id
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesSSO = usesSSO
        let chromeProfile = chromeProfiles.first { $0.id == chromeProfileID }
        let executable = candidate.command?.executable ?? Self.claudeExecutable(accounts: accounts)
        let profileID = candidate.mode == .claudeOAuth ? candidate.claudeProfile?.id : nil
        let name = candidate.displayName.isEmpty ? "Claude" : candidate.displayName
        let showManualURL: @Sendable (URL) -> Void = { [weak self] url in
            Task { @MainActor in self?.manualLoginURL = url }
        }

        Task {
            let outcome: Result<ImportedClaudeProfile, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let result = try ClaudeGuidedLoginService().login(
                        connectionID: accountID,
                        email: cleanEmail,
                        usesSSO: usesSSO,
                        chromeProfile: chromeProfile,
                        claudeExecutable: executable,
                        cancellationToken: cancellation,
                        outputHandler: { output in
                            guard let url = ClaudeGuidedLoginService.manualLoginURL(from: output) else { return }
                            showManualURL(url)
                        }
                    )
                    return .success(try ClaudeCodeCredentialImporter().importAccount(
                        configDirectory: result.configDirectory,
                        profileID: profileID,
                        preferredName: name
                    ))
                } catch {
                    return .failure(error)
                }
            }.value
            loginCancellation = nil
            guard step == .browserWait else { return }
            switch outcome {
            case .success(let imported):
                if candidate.claudeProfile?.id != imported.profile.id, !isFix {
                    uncommittedProfileID = imported.profile.id
                }
                if candidate.mode == .claudeCodeLive { obsoleteProfileID = nil }
                candidate.claudeProfile = imported.profile
                candidate.mode = .claudeOAuth
                candidate.credentialOrigin = .guidedLogin
                candidate.localPath = nil
                candidate.claudeCLIAccountLabel = nil
                candidate.command = CommandConfig(executable: executable, timeoutSeconds: 20)
                runChecks(prefix: [
                    CheckItem(title: "Signed in as \(imported.profile.accountLabel ?? cleanEmail)", state: .ok),
                    CheckItem(title: "Token saved in the Keychain (\(KeychainClaudeCredentialStore.service))", state: .ok)
                ])
            case .failure(let error):
                switch error as? ClaudeGuidedLoginError {
                case .wrongAccount(let expected, let actual):
                    step = .wrongAccount(expected: expected, actual: actual)
                case .cancelled:
                    back()
                default:
                    step = .failed(error.localizedDescription)
                }
            }
        }
    }

    func submitAuthorizationCode() {
        let code = authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        loginCancellation?.sendLine(code)
        authorizationCode = ""
        codeSubmitted = true
    }

    func openManualLogin() {
        guard let url = manualLoginURL else { return }
        if let profile = chromeProfiles.first(where: { $0.id == chromeProfileID }),
           (try? ClaudeGuidedLoginService().openInChrome(url, profile: profile)) != nil {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func stopBrowserLogin() {
        loginCancellation?.cancel()
    }

    func retryAfterWrongAccount() {
        step = .browserSetup
        startBrowserLogin()
    }

    // MARK: Claude Code live

    private func detectLiveAccount() {
        isWorking = true
        liveAccount = nil
        liveError = nil
        Task {
            let result: Result<ClaudeCodeAccountPreview, Error> = await Task.detached(priority: .userInitiated) {
                Result { try ClaudeCodeCredentialImporter().detectCurrentAccount() }
            }.value
            isWorking = false
            switch result {
            case .success(let preview): liveAccount = preview
            case .failure(let error): liveError = error.localizedDescription
            }
        }
    }

    var liveConflict: SourceConfig? {
        guard let identifier = liveAccount?.identifier else { return nil }
        return accounts.first { $0.id != existing?.id && $0.claudeProfile?.accountIdentifier == identifier }
    }

    var liveMismatch: Bool {
        guard isFix, let expected = existing?.claudeProfile?.accountIdentifier,
              let actual = liveAccount?.identifier else { return false }
        return expected != actual
    }

    private func adoptLiveAccount() {
        guard let liveAccount else { return }
        if candidate.mode == .claudeOAuth, let oldID = candidate.claudeProfile?.id {
            obsoleteProfileID = oldID
        }
        candidate.mode = .claudeCodeLive
        candidate.credentialOrigin = nil
        candidate.claudeProfile = ClaudeProfile(
            id: candidate.claudeProfile?.id ?? UUID(),
            name: candidate.displayName,
            accountLabel: liveAccount.label,
            accountIdentifier: liveAccount.identifier
        )
        runChecks(prefix: [
            CheckItem(title: "Claude Code is signed in as \(liveAccount.label ?? "an account")", state: .ok),
            CheckItem(title: "Nothing stored in the Keychain", state: .ok)
        ])
    }

    // MARK: Codex

    /// The folder an own ChatGPT login for this account lives in.
    private var ownCodexHome: String {
        CodexAccountService.appOwnedHome(accountID: candidate.id).path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func inspectCodex() {
        let executable = candidate.command?.executable ?? Self.codexExecutable(accounts: accounts)
        codexFound = FileManager.default.isExecutableFile(atPath: NSString(string: executable).expandingTildeInPath)
        if !isFix {
            codexDefaultOwner = accounts.first { $0.mode == .codexRPC && $0.codexHome == nil }
        }
        isWorking = true
        codexEmail = nil
        let found = codexFound
        let isFix = isFix
        let repairHome = candidate.codexHome
        let ownHome = ownCodexHome
        Task {
            let info = await Task.detached(priority: .userInitiated) { () -> (version: String?, defaultEmail: String?, ownEmail: String?) in
                guard found else { return (nil, nil, nil) }
                func signedInEmail(_ home: String?) -> String? {
                    guard CodexAccountService.isSignedIn(executable: executable, codexHome: home) else { return nil }
                    return CodexAccountService.accountEmail(codexHome: home) ?? "ChatGPT account"
                }
                let version = CodexRPCClient.cliVersion(executable: executable)
                if isFix { return (version, nil, signedInEmail(repairHome)) }
                // Only ask Codex about the own folder once it exists, so merely
                // opening this step never leaves an empty folder behind.
                let ownExists = FileManager.default.fileExists(atPath: CodexAccountService.resolvedHome(ownHome).path)
                return (version, signedInEmail(nil), ownExists ? signedInEmail(ownHome) : nil)
            }.value
            codexVersion = info.version
            codexDefaultEmail = info.defaultEmail
            ownCodexEmail = info.ownEmail
            if isFix {
                codexEmail = info.ownEmail
            } else {
                selectCodexChoice(codexDefaultOwner == nil && info.defaultEmail != nil ? .existingLogin : .ownLogin)
            }
            isWorking = false
        }
    }

    func selectCodexChoice(_ choice: CodexChoice) {
        codexChoice = choice
        switch choice {
        case .existingLogin:
            candidate.codexHome = nil
            codexEmail = codexDefaultEmail
        case .ownLogin:
            candidate.codexHome = ownCodexHome
            codexEmail = ownCodexEmail
        }
    }

    func chooseCodexExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the codex executable"
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            var command = candidate.command ?? CommandConfig(executable: url.path, timeoutSeconds: 15)
            command.executable = url.path
            candidate.command = command
            inspectCodex()
        }
    }

    private func startCodexLogin() {
        go(.codexWait)
        codexLoginURL = nil
        let cancellation = ProcessCancellation()
        codexCancellation = cancellation
        let executable = candidate.command?.executable ?? Self.codexExecutable(accounts: accounts)
        let home = candidate.codexHome ?? CodexAccountService.defaultHome
        let showLoginURL: @Sendable (URL) -> Void = { [weak self] url in
            Task { @MainActor in self?.codexLoginURL = url }
        }
        Task {
            let result: Result<String?, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    try CodexAccountService.login(executable: executable, codexHome: home, cancellation: cancellation, onLoginURL: showLoginURL)
                    return .success(CodexAccountService.accountEmail(codexHome: home))
                } catch {
                    return .failure(error)
                }
            }.value
            codexCancellation = nil
            guard step == .codexWait else { return }
            switch result {
            case .success(let address):
                codexEmail = address ?? "ChatGPT account"
                ownCodexEmail = codexEmail
                if let conflict = codexConflict {
                    step = .codexDuplicate(email: codexEmail ?? "", label: conflict.label)
                } else {
                    runChecks(prefix: [CheckItem(title: "Signed in as \(codexEmail ?? "")", state: .ok)])
                }
            case .failure(let error):
                if (error as? CodexLoginError) == .cancelled { back() } else { step = .failed(error.localizedDescription) }
            }
        }
    }

    /// Throws away a login that turned out to be a duplicate and starts over.
    func retryCodexLogin() {
        if CodexAccountService.isAppOwned(candidate.codexHome) {
            try? FileManager.default.removeItem(at: CodexAccountService.resolvedHome(candidate.codexHome))
        }
        codexEmail = nil
        ownCodexEmail = nil
        step = .codexSetup
        if trail.last == .codexSetup { trail.removeLast() }
        startCodexLogin()
    }

    /// Opens the pending ChatGPT sign-in in a private Chrome window, where no
    /// existing chatgpt.com session can be picked up by accident.
    func openCodexLoginPrivately() {
        guard let url = codexLoginURL else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-na", "Google Chrome", "--args", "--incognito", url.absoluteString]
        if (try? process.run()) == nil { NSWorkspace.shared.open(url) }
    }

    var chromeInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil
    }

    func stopCodexLogin() {
        codexCancellation?.cancel()
    }

    var codexConflict: SourceConfig? {
        guard let codexEmail, !isFix else { return nil }
        return accounts.first {
            $0.mode == .codexRPC && CodexAccountService.accountEmail(codexHome: $0.codexHome)?.caseInsensitiveCompare(codexEmail) == .orderedSame
        }
    }

    // MARK: Check & commit

    func runChecks(prefix: [CheckItem]) {
        if step != .checking { trail.append(step) }
        step = .checking
        checkProblem = nil
        usage = nil
        checks = prefix + [CheckItem(title: candidate.provider == .codex ? "Reading usage (finds the right Codex start options)" : "Reading usage", state: .running)]
        var testSource = candidate
        testSource.enabled = true
        let config = AppConfig(refreshIntervalSeconds: 90, sources: [testSource])
        Task {
            guard let probe = UsageProbeFactory.makeProbes(config: config).first else { return }
            let snapshot = await probe.readUsage()
            guard step == .checking else { return }
            let index = checks.count - 1
            if snapshot.status == .ok {
                checks[index].state = .ok
                checks[index].title = "Usage read · " + Self.usageSummary(snapshot)
                usage = snapshot
            } else {
                checks[index].state = .failed
                let message = snapshot.errorMessage ?? "No data returned"
                switch ConnectionHealth.of(snapshot) {
                case .retrying, .keychainLocked: checkProblem = .offline(message)
                case .needsLogin, .accountChanged: checkProblem = .login(message)
                case .incompatible: checkProblem = .incompatible(message)
                default: checkProblem = .other(message)
                }
            }
        }
    }

    func rerunChecks() {
        let prefix = checks.dropLast()
        runChecks(prefix: Array(prefix))
    }

    func saveDespiteProblem() {
        if isFix { commit() } else { go(.display) }
    }

    func copyDiagnostics() {
        guard case .incompatible(let message) = checkProblem else { return }
        let text = """
        AI Usage diagnostics
        Codex CLI: \(codexVersion ?? CodexRPCClient.cliVersion(executable: candidate.command?.executable ?? "") ?? "unknown")
        Tried start variants: \(CodexRPCClient.argumentLadder.map { $0.joined(separator: " ") }.joined(separator: " | "))
        Last error: \(message)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedDiagnostics = true
    }

    func commit() {
        if !isFix {
            if candidate.name?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { candidate.name = suggestedName }
            if candidate.label.trimmingCharacters(in: .whitespaces).isEmpty { candidate.label = suggestedLabel }
        }
        committed = true
        uncommittedProfileID = nil
        let message: String
        switch (isFix, candidate.mode) {
        case (_, .codexRPC):
            message = isFix ? "Repaired · Codex \(codexVersion ?? "") works again" : "Added · Codex \(candidate.codexHome == nil ? "default login" : "own folder")"
        case (_, .claudeCodeLive):
            message = "\(isFix ? "Switched" : "Added") · reads Claude Code live"
        default:
            let fingerprint = candidate.claudeProfile.flatMap { try? KeychainClaudeCredentialStore().load(profileID: $0.id) }
                .map { KeychainInventory.fingerprint(of: $0.accessToken) }
            after = (AccountsPanel.originText(for: candidate), fingerprint)
            message = "\(isFix ? "Reconnected" : "Added") · own login, token \(fingerprint ?? "saved")"
        }
        if after == nil { after = (AccountsPanel.originText(for: candidate), nil) }
        onCommit(AccountWizardOutcome(source: candidate, isNew: !isFix, message: message, obsoleteProfileID: obsoleteProfileID))
        go(.done)
    }

    // MARK: Defaults

    var suggestedName: String {
        switch candidate.provider {
        case .codex:
            return "Codex · " + (codexEmail?.split(separator: "@").first.map(String.init) ?? "Account")
        default:
            let address = candidate.accountLabel ?? email
            let profileName = chromeProfiles.first { $0.accountEmail?.caseInsensitiveCompare(address) == .orderedSame }?.displayName
            return "Claude · " + (profileName ?? address.split(separator: "@").last.map(String.init) ?? "Account")
        }
    }

    var suggestedLabel: String {
        let count = accounts.filter { $0.provider == candidate.provider }.count
        switch candidate.provider {
        case .codex: return count == 0 ? "GPT" : "GPT\(count + 1)"
        default: return "C\(count + 1)"
        }
    }

    private func makeCandidate(for provider: AccountProvider) -> SourceConfig {
        let sibling = accounts.first { $0.provider == provider }
        switch provider {
        case .codex:
            method = .codex
            return SourceConfig(
                id: AccountMigration.newAccountID(provider: .codex),
                label: "",
                enabled: true,
                mode: .codexRPC,
                command: CommandConfig(executable: Self.codexExecutable(accounts: accounts), timeoutSeconds: 15),
                iconData: sibling?.iconData
            )
        default:
            return SourceConfig(
                id: AccountMigration.newAccountID(provider: .claude),
                label: "",
                enabled: true,
                mode: .claudeOAuth,
                command: CommandConfig(executable: Self.claudeExecutable(accounts: accounts), timeoutSeconds: 20),
                iconData: sibling?.iconData
            )
        }
    }

    static func claudeExecutable(accounts: [SourceConfig]) -> String {
        if let path = accounts.first(where: { $0.provider == .claude })?.command?.executable, !path.isEmpty { return path }
        return ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", NSHomeDirectory() + "/.local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/claude"
    }

    static func codexExecutable(accounts: [SourceConfig]) -> String {
        if let path = accounts.first(where: { $0.provider == .codex })?.command?.executable, !path.isEmpty { return path }
        return ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/codex"
    }

    static func usageSummary(_ snapshot: UsageSnapshot) -> String {
        [snapshot.fiveHour.map { "5-hour \($0.percentUsed)%" }, snapshot.oneWeek.map { "week \($0.percentUsed)%" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Plain-language explanation for the repair flow's first screen.
    var diagnosis: String {
        guard let existing else { return "" }
        switch (currentHealth, existing.mode) {
        case (.incompatible, _):
            return "Your Codex login is fine. The Codex CLI was updated and no longer accepts how AI Usage started it. AI Usage now tries the known start options by itself — repairing checks that they work."
        case (.needsLogin, .codexRPC):
            return "Codex isn't signed in for this account any more. Sign in again in the browser; AI Usage waits until it's done."
        case (.accountChanged, _):
            return "Claude Code is now signed in with a different account, so AI Usage paused this one instead of showing someone else's numbers. Switch Claude Code back, or give this account its own login."
        case (.needsLogin, .claudeCodeLive):
            return "Claude Code's login has expired. Opening Claude Code once refreshes it — or give this account its own login so it no longer depends on Claude Code."
        case (_, .claudeOAuth) where existing.credentialOrigin == .claudeCodeCopy:
            return "This account used a copy of Claude Code's token. Claude Code refreshed that token on its own, which made the copy invalid — with this method it happens again and again. An own login belongs to AI Usage alone."
        case (.needsLogin, .claudeOAuth):
            return "Anthropic ended this login, for example after signing out on claude.ai or changing the password. The token belonged to AI Usage only; Claude Code wasn't involved."
        case (_, .claudeCLI):
            return "This account still reads usage through the Claude CLI. An own login is more reliable and also shows extra limits such as Fable."
        default:
            return existing.provider == .codex
                ? "Run a fresh check of this Codex account."
                : "Sign this account in again. Name, display settings and history stay as they are."
        }
    }
}

struct AccountWizard: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: AccountWizardModel
    /// Whether the menu bar shows remaining instead of used percent, so the
    /// preview matches the real menu bar.
    private let remaining: Bool

    init(
        request: AccountWizardRequest,
        accounts: [SourceConfig],
        snapshots: [UsageSnapshot],
        events: [ConnectionEvent],
        remaining: Bool,
        onCommit: @escaping (AccountWizardOutcome) -> Void
    ) {
        self.remaining = remaining
        _model = StateObject(wrappedValue: AccountWizardModel(
            request: request,
            accounts: accounts,
            snapshots: snapshots,
            events: events,
            onCommit: onCommit
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 560)
        .interactiveDismissDisabled(model.step == .browserWait || model.step == .codexWait)
    }

    // MARK: Header & footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            HStack(spacing: 6) {
                ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                    let current = chips.firstIndex(of: currentChip) ?? 0
                    Text(index < current ? "✓ \(chip)" : chip)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(index == current ? Color.accentColor : Color.secondary.opacity(0.15)))
                        .foregroundStyle(index == current ? Color.white : (index < current ? Color.green : Color.secondary))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var title: String {
        guard let existing = model.existing else { return "Add Account" }
        return model.currentHealth == .incompatible ? "Repair \(existing.label)" : "Reconnect \(existing.label)"
    }

    private var chips: [String] {
        if model.isFix {
            switch model.method {
            case .codex: return model.currentHealth == .needsLogin ? ["Diagnosis", "Sign-in", "Check", "Done"] : ["Diagnosis", "Check", "Done"]
            case .claudeCodeLive: return ["Diagnosis", "Claude Code", "Check", "Done"]
            default: return ["Diagnosis", "Browser", "Check", "Done"]
            }
        }
        switch model.provider {
        case .codex: return ["Provider", "Sign-in", "Check", "Display", "Done"]
        default: return model.method == .claudeCodeLive
            ? ["Provider", "Sign-in", "Claude Code", "Check", "Display", "Done"]
            : ["Provider", "Sign-in", "Browser", "Check", "Display", "Done"]
        }
    }

    private var currentChip: String {
        switch model.step {
        case .provider: "Provider"
        case .method: "Sign-in"
        case .diagnose: "Diagnosis"
        case .browserSetup, .browserWait, .wrongAccount: "Browser"
        case .liveDetect: "Claude Code"
        case .codexSetup, .codexWait, .codexDuplicate: "Sign-in"
        case .checking, .failed: "Check"
        case .display: "Display"
        case .done: "Done"
        }
    }

    private var footer: some View {
        HStack {
            if model.step != .done {
                Button("Cancel") {
                    model.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if model.canGoBack {
                Button("Back") { model.back() }
            }
            primaryButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.step {
        case .provider:
            Button("Continue") { model.next() }.keyboardShortcut(.defaultAction).disabled(model.provider == nil)
        case .method:
            Button("Continue") { model.next() }.keyboardShortcut(.defaultAction).disabled(model.method == nil)
        case .diagnose:
            Button(model.method == .codex && model.currentHealth != .needsLogin ? "Repair Now" : "Continue") { model.next() }
                .keyboardShortcut(.defaultAction)
        case .browserSetup:
            Button("Sign In in Browser") { model.next() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.email.contains("@") || model.claudeAccount(withEmail: model.email) != nil)
        case .browserWait:
            Button("Stop") { model.stopBrowserLogin() }
        case .wrongAccount:
            Button("Sign In Again") { model.retryAfterWrongAccount() }.keyboardShortcut(.defaultAction)
        case .liveDetect:
            Button("Continue") { model.next() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.liveAccount == nil || model.liveConflict != nil || model.liveMismatch)
        case .codexSetup:
            Button(model.codexEmail == nil ? "Sign In with ChatGPT…" : "Continue") { model.next() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.codexFound || model.isWorking || model.codexConflict != nil)
        case .codexWait:
            Button("Stop") { model.stopCodexLogin() }
        case .checking:
            switch model.checkProblem {
            case .offline:
                Button("Check Again") { model.rerunChecks() }
                Button("Save Anyway") { model.saveDespiteProblem() }.keyboardShortcut(.defaultAction)
            case .incompatible:
                Button(model.copiedDiagnostics ? "Diagnostics Copied" : "Copy Diagnostics") { model.copyDiagnostics() }
                Button("Save Paused") { model.saveDespiteProblem() }.keyboardShortcut(.defaultAction)
            case .login, .other:
                Button("Check Again") { model.rerunChecks() }.keyboardShortcut(.defaultAction)
            case nil:
                Button(model.isFix ? "Save" : "Continue") { model.next() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.usage == nil)
            }
        case .display:
            Button("Add Account") { model.next() }.keyboardShortcut(.defaultAction)
        case .done:
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        case .failed:
            Button("Try Again") { model.back() }.keyboardShortcut(.defaultAction)
        case .codexDuplicate:
            Button("Sign In Again") { model.retryCodexLogin() }.keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .provider: providerStep
        case .method: methodStep(heading: "How should AI Usage sign in?")
        case .diagnose: diagnoseStep
        case .browserSetup: browserSetupStep
        case .browserWait: browserWaitStep
        case .wrongAccount(let expected, let actual): wrongAccountStep(expected: expected, actual: actual)
        case .liveDetect: liveStep
        case .codexSetup: codexSetupStep
        case .codexWait: codexWaitStep
        case .checking: checkStep
        case .display: displayStep
        case .done: doneStep
        case .failed(let message): failedStep(message)
        case .codexDuplicate(let email, let label): codexDuplicateStep(email: email, label: label)
        }
    }

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which account do you want to add?").fontWeight(.semibold)
            choice(selected: model.provider == .claude, title: "Claude", detail: "Pro, Max or Team. Add as many accounts as you like.", provider: .claude) {
                model.provider = .claude
            }
            choice(selected: model.provider == .codex, title: "Codex / ChatGPT", detail: "Uses your installed Codex CLI. Several ChatGPT accounts work too.", provider: .codex) {
                model.provider = .codex
            }
            footnote("Nothing is saved until the final check succeeds.")
        }
    }

    private func methodStep(heading: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(heading).fontWeight(.semibold)
            choice(selected: model.method == .ownLogin, title: "Own login in the browser", badge: "Recommended",
                   detail: "A token that belongs to AI Usage alone. Claude Code can't invalidate it.") {
                model.method = .ownLogin
            }
            choice(selected: model.method == .claudeCodeLive, title: "Read Claude Code's login",
                   detail: "No second login. Follows whichever account Claude Code is signed in with and stores nothing.") {
                model.method = .claudeCodeLive
            }
        }
    }

    private var diagnoseStep: some View {
        let existing = model.existing
        let recent = model.events.filter { $0.account == existing?.id }.prefix(3)
        let snapshot = model.snapshots.first { $0.sourceID == existing?.id }
        // When the account entered its current state, from the history; the
        // last check time only as a fallback.
        let since = model.events.first { $0.account == existing?.id && $0.health == model.currentHealth }?.ts ?? snapshot?.updatedAt
        return VStack(alignment: .leading, spacing: 12) {
            if model.currentHealth.needsUser {
                notice(color: .red, title: "\(model.currentHealth.title)\(since.map { " since \($0.formatted(date: .omitted, time: .shortened))" } ?? "")",
                       text: snapshot?.errorMessage ?? "")
            }
            Text(model.diagnosis)
                .fixedSize(horizontal: false, vertical: true)
            if !recent.isEmpty {
                InspectorGroup {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, event in
                        VStack(spacing: 0) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(AccountsPanel.eventTime(event.ts))
                                    .monospacedDigit()
                                    .frame(width: 92, alignment: .leading)
                                Text(event.message)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            if index < recent.count - 1 { Divider().padding(.leading, 12) }
                        }
                    }
                }
            }
            if existing?.provider == .claude {
                methodStep(heading: "How should \(existing?.label ?? "it") be signed in from now on?")
            }
            footnote("Name, display settings and history of \(existing?.label ?? "this account") stay as they are. The last value stays visible meanwhile.")
        }
    }

    private var browserSetupStep: some View {
        let conflict = model.claudeAccount(withEmail: model.email)
        return VStack(alignment: .leading, spacing: 12) {
            Text(model.isFix ? "Sign in as \(model.email)" : "Which account?").fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude account e-mail\(model.isFix ? " (must match \(model.existing?.label ?? ""))" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("name@company.com", text: $model.email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isFix && !(model.existing?.accountLabel ?? "").isEmpty)
            }
            if let conflict {
                notice(color: .orange, title: "\(model.email) is already connected as \(conflict.label)",
                       text: "Two accounts with the same login would show the same numbers.")
            }
            Text("Open the login in").font(.caption).foregroundStyle(.secondary)
            if model.chromeProfiles.isEmpty {
                Text("Default browser — Chrome profiles couldn't be read. Make sure the right account is signed in to claude.ai there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(model.chromeProfiles) { profile in
                        let connected = profile.accountEmail.flatMap { model.claudeAccount(withEmail: $0) }
                        Button {
                            model.chromeProfileID = profile.id
                            if !model.isFix, let address = profile.accountEmail { model.email = address }
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.displayName).fontWeight(.medium)
                                Text((profile.accountEmail ?? "no Google account") + (connected.map { " · already \($0.label)" } ?? ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(model.chromeProfileID == profile.id ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: model.chromeProfileID == profile.id ? 2 : 1))
                    }
                }
            }
            Toggle("Sign in with company single sign-on (SSO)", isOn: $model.usesSSO)
            footnote("AI Usage signs this account into its own Claude folder and keeps only its OAuth token in the Keychain. It never reads browser cookies or your password.")
        }
    }

    private var browserWaitStep: some View {
        let profile = model.chromeProfiles.first { $0.id == model.chromeProfileID }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Waiting for the sign-in in your browser…").fontWeight(.semibold)
                    Text("claude.ai is open \(profile.map { "in the Chrome profile “\($0.displayName)”" } ?? "in your default browser"). Sign in as \(model.email)\(model.usesSSO ? " (SSO)" : ""). This window notices automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            Text("Time limit: 10 minutes. You can switch to the browser; this window stays open.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.manualLoginURL != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No browser opened, or still waiting after SSO?").fontWeight(.medium)
                    HStack {
                        Button {
                            model.openManualLogin()
                        } label: {
                            Label("Open Alternative Sign-In", systemImage: "arrow.up.right")
                        }
                        TextField("Paste the code claude.ai shows", text: $model.authorizationCode)
                            .textFieldStyle(.roundedBorder)
                        Button("Send Code") { model.submitAuthorizationCode() }
                            .disabled(model.authorizationCode.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if model.codeSubmitted {
                        Label("Code sent. Verifying the account…", systemImage: "checkmark")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func wrongAccountStep(expected: String, actual: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            notice(color: .red, title: "Wrong account signed in",
                   text: "The browser signed in as \(actual), but \(model.isFix ? "\(model.existing?.label ?? "this account") belongs to" : "you asked for") \(expected). Nothing was saved or overwritten.")
            Text("On claude.ai in the selected profile, sign out (top right) and sign in with the right account — or go back and pick another browser profile.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var liveStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isWorking {
                HStack { ProgressView().controlSize(.small); Text("Checking which account Claude Code uses…") }
            } else if let account = model.liveAccount {
                Text("Claude Code is signed in as").fontWeight(.semibold)
                InspectorGroup {
                    InspectorRow(title: "Account") { Text(account.label ?? "Name unavailable").foregroundStyle(.secondary) }
                    InspectorRow(title: "Source", showsDivider: false) { Text("Claude Code-credentials").font(.callout.monospaced()).foregroundStyle(.secondary) }
                }
                if let conflict = model.liveConflict {
                    notice(color: .orange, title: "Already connected as \(conflict.label)", text: "Two accounts with the same login would show the same numbers.")
                }
                if model.liveMismatch {
                    notice(color: .orange, title: "Claude Code uses a different account",
                           text: "\(model.existing?.label ?? "This account") belongs to \(model.existing?.accountLabel ?? "another account"). Switch Claude Code back (/logout, /login) and check again, or choose an own login.")
                    Button("Check Again") { model.go(.liveDetect) }
                }
                footnote("AI Usage reads the token on every check and stores nothing. If you switch accounts in Claude Code, this account pauses with “Account changed” instead of showing someone else's numbers.")
            } else {
                notice(color: .orange, title: "No Claude Code login found", text: model.liveError ?? "Sign in with Claude Code, then check again.")
                Button("Check Again") { model.go(.liveDetect) }
            }
        }
    }

    private var codexSetupStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.codexFound {
                notice(color: .orange, title: "Codex CLI not found",
                       text: "AI Usage signs in and reads usage through the Codex CLI. Install it with “brew install codex”, or choose the executable under Technical details.")
            } else if model.isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking the Codex login on this Mac…").foregroundStyle(.secondary)
                }
            } else if model.isFix || model.codexDefaultOwner != nil {
                chatGPTLoginCard
            } else {
                Text("How should AI Usage sign in to Codex?").fontWeight(.semibold)
                choice(selected: model.codexChoice == .ownLogin, title: "Sign in with ChatGPT in the browser", badge: "Own login",
                       detail: "A browser window opens for the ChatGPT login. The login belongs to AI Usage and lives in its own folder — use this for any ChatGPT account. Your Codex CLI stays as it is.") {
                    model.selectCodexChoice(.ownLogin)
                }
                choice(selected: model.codexChoice == .existingLogin, title: "Use the Codex login on this Mac",
                       detail: model.codexDefaultEmail.map { "Signed in as \($0). AI Usage reads it through the Codex CLI, nothing is copied." }
                        ?? "Not signed in yet. Signing in here also signs in your Codex CLI.") {
                    model.selectCodexChoice(.existingLogin)
                }
            }
            if let conflict = model.codexConflict {
                notice(color: .orange, title: "Already connected as \(conflict.label)", text: "Sign in with a different ChatGPT account.")
            }
            DisclosureGroup("Technical details") {
                codexDetails.padding(.top, 6)
            }
            .font(.callout)
        }
    }

    private var chatGPTLoginCard: some View {
        HStack(alignment: .top, spacing: 14) {
            AccountIcon(source: model.candidate, size: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.codexEmail.map { "Signed in as \($0)" } ?? "Sign in with ChatGPT")
                    .font(.headline)
                Text(model.codexEmail != nil
                     ? "This account is already signed in. Continue to check it."
                     : "A browser window opens for the ChatGPT login. Choose the account there; this window continues automatically.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let owner = model.codexDefaultOwner, !model.isFix {
                    Text("Your default Codex login\(model.codexDefaultEmail.map { " (\($0))" } ?? "") already runs as \(owner.label), so this account gets its own login and folder. Your normal Codex setup stays unchanged.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var codexDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorGroup {
                InspectorRow(title: "Path") {
                    HStack {
                        Text(model.candidate.command?.executable ?? "").font(.callout.monospaced()).foregroundStyle(.secondary)
                        Button("Choose…") { model.chooseCodexExecutable() }.controlSize(.small)
                    }
                }
                InspectorRow(title: "Version") {
                    Text(model.codexFound ? (model.codexVersion ?? (model.isWorking ? "…" : "unknown")) : "not found").foregroundStyle(.secondary)
                }
                InspectorRow(title: "Codex folder") {
                    Text(model.candidate.codexHome ?? CodexAccountService.defaultHome)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                InspectorRow(title: "Signed in", showsDivider: false) {
                    if model.isWorking {
                        ProgressView().controlSize(.mini)
                    } else if let address = model.codexEmail {
                        Text(address).foregroundStyle(.secondary)
                    } else {
                        Text("Not yet").foregroundStyle(.orange)
                    }
                }
            }
            footnote("The browser login runs through the official Codex CLI (codex login), the same way it signs in on its own. AI Usage never reads the token; Codex keeps and refreshes it.")
        }
    }

    private var codexWaitStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Waiting for the ChatGPT sign-in in your browser…").fontWeight(.semibold)
                    Text("Sign in with the ChatGPT account you want to add. This window continues automatically once the login is saved.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            Text("Time limit: 10 minutes.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let url = model.codexLoginURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No browser window, or it signs in the wrong account?").fontWeight(.medium)
                    HStack {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open the ChatGPT Sign-In", systemImage: "arrow.up.right")
                        }
                        if model.chromeInstalled {
                            Button("Open in Private Chrome Window") { model.openCodexLoginPrivately() }
                                .help("No existing chatgpt.com session is reused there, so you can pick any account")
                        }
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                    }
                }
            }
        }
    }

    private var checkStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.checkProblem != nil ? "Check stopped" : (model.usage != nil ? "Everything checked" : "Checking the connection…"))
                .fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.checks) { item in
                    HStack(spacing: 8) {
                        switch item.state {
                        case .running: ProgressView().controlSize(.mini).frame(width: 16)
                        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 16)
                        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).frame(width: 16)
                        }
                        Text(item.title)
                    }
                }
            }
            switch model.checkProblem {
            case .offline(let message):
                notice(color: .orange, title: "Usage couldn't be read right now",
                       text: "The login itself is fine. You can save the account; AI Usage keeps trying on its own. (\(message))")
            case .incompatible(let message):
                notice(color: .red, title: "AI Usage doesn't know this Codex version yet",
                       text: "No start option works with this Codex CLI. Your login is fine; an AI Usage update fixes it. Until then the account is paused. (\(message))")
            case .login(let message):
                notice(color: .red, title: "Not signed in", text: message)
            case .other(let message):
                notice(color: .red, title: "The check failed", text: message)
            case nil:
                if let usage = model.usage {
                    notice(color: .green, title: "Connected", text: AccountWizardModel.usageSummary(usage))
                }
            }
            footnote("The account is only saved once this check succeeds.")
        }
    }

    private var displayStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How should the account appear?").fontWeight(.semibold)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField(model.suggestedName, text: Binding(get: { model.candidate.name ?? "" }, set: { model.candidate.name = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Short label").font(.caption).foregroundStyle(.secondary)
                    TextField(model.suggestedLabel, text: $model.candidate.label)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
            }
            InspectorGroup {
                InspectorRow(title: "Value in menu bar") {
                    Picker("", selection: Binding(get: { model.candidate.quota ?? .session }, set: { model.candidate.quota = $0 })) {
                        ForEach(QuotaSelection.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                InspectorRow(title: "Show in popover") {
                    HStack(spacing: 12) {
                        Toggle("5-hour", isOn: Binding(get: { model.candidate.resolvedShowFiveHourInPopover }, set: { model.candidate.showFiveHourInPopover = $0 }))
                        Toggle("1-week", isOn: Binding(get: { model.candidate.resolvedShowOneWeekInPopover }, set: { model.candidate.showOneWeekInPopover = $0 }))
                        Toggle("Percent", isOn: Binding(get: { model.candidate.resolvedShowPercentInPopover }, set: { model.candidate.showPercentInPopover = $0 }))
                    }
                }
                InspectorRow(title: "Icon", showsDivider: false) {
                    HStack(spacing: 8) {
                        if let image = ProviderIconRenderer.image(iconData: model.candidate.iconData, iconName: model.candidate.iconName, size: 16, color: .labelColor) {
                            Image(nsImage: image)
                        }
                        Text(model.candidate.iconData != nil ? "Custom icon" : "None — shows the label")
                            .foregroundStyle(.secondary)
                        if model.candidate.iconData != nil {
                            Button {
                                model.candidate.iconData = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Remove the icon and show the label instead")
                        }
                        Button("Choose…", action: chooseIcon)
                    }
                }
            }
            Text("This is how the menu bar will look").font(.caption).foregroundStyle(.secondary)
            MenuBarPreview(
                sources: model.accounts,
                snapshots: model.snapshots,
                remaining: remaining,
                pending: previewValue.map { value in
                    var preview = model.candidate
                    if preview.label.isEmpty { preview.label = model.suggestedLabel }
                    return (preview, value)
                }
            )
            footnote("The new account goes to the end of the menu bar. You can reorder it later under Display.")
        }
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an SVG or PNG icon for this account"
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            model.candidate.iconData = data.base64EncodedString()
            model.candidate.iconName = nil
        }
    }

    private var previewValue: Int? {
        guard let usage = model.usage else { return nil }
        return ((model.candidate.quota ?? .session) == .weekly ? usage.oneWeek : usage.fiveHour)?.percentUsed ?? usage.percentUsed
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: model.usage != nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(model.usage != nil ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isFix
                         ? "\(model.candidate.label) \(model.usage != nil ? "is connected again" : "is saved")"
                         : "\(model.candidate.label) \(model.usage != nil ? "is connected" : "is saved")")
                        .font(.headline)
                    Text(model.isFix ? "Name, display settings and history are unchanged." : "\(model.candidate.displayName) · \(model.candidate.accountLabel ?? model.codexEmail ?? "")")
                        .foregroundStyle(.secondary)
                }
            }
            if model.isFix, let before = model.before, let after = model.after {
                InspectorGroup {
                    InspectorRow(title: "State") { Text("\(before.health.title) → \(model.usage != nil ? "Connected" : "Saved")").foregroundStyle(.secondary) }
                    InspectorRow(title: "Login") { Text(before.origin == after.origin ? after.origin : "\(before.origin) → \(after.origin)").foregroundStyle(.secondary) }
                    InspectorRow(title: "Keychain", showsDivider: false) {
                        Text(model.candidate.mode == .claudeOAuth ? "\(before.fingerprint ?? "–") → \(after.fingerprint ?? "–")" : "nothing stored")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                InspectorGroup {
                    InspectorRow(title: "Login") { Text(AccountsPanel.originText(for: model.candidate)).foregroundStyle(.secondary) }
                    InspectorRow(title: "Stored", showsDivider: false) {
                        Text(storedText).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            footnote("Card, history and Keychain inventory show the change right away.")
        }
    }

    private var storedText: String {
        switch model.candidate.mode {
        case .claudeOAuth: "\(KeychainClaudeCredentialStore.service) · \(model.after?.fingerprint ?? "")"
        case .codexRPC: "\(model.candidate.codexHome ?? CodexAccountService.defaultHome)/auth.json (Codex)"
        default: "nothing — reads Claude Code live"
        }
    }

    private func codexDuplicateStep(email: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            notice(color: .orange, title: "\(email) is already connected as \(label)",
                   text: "ChatGPT used the account your browser was already signed in with. Nothing was added.")
            Text("To add a different ChatGPT account:").fontWeight(.medium)
            VStack(alignment: .leading, spacing: 4) {
                Text("• On the next screen, open the sign-in in a private window\(model.chromeInstalled ? " (“Open in Private Chrome Window”)" : "") and sign in there, or")
                Text("• sign out on chatgpt.com in your browser first.")
            }
            .foregroundStyle(.secondary)
            footnote("“Sign In Again” discards this login and starts a fresh one.")
        }
    }

    private func failedStep(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            notice(color: .red, title: "That didn't work", text: message)
            Text("Nothing was changed. You can try again without affecting any other account.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Pieces

    private func choice(selected: Bool, title: String, badge: String? = nil, detail: String, provider: AccountProvider? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                if let provider {
                    AccountIcon(source: SourceConfig(id: "", label: "", enabled: true, mode: provider == .codex ? .codexRPC : .claudeOAuth, command: nil), size: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).fontWeight(.semibold)
                        if let badge {
                            Text(badge.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.green)
                        }
                    }
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1))
    }

    private func notice(color: Color, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.semibold)
            if !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.13)))
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
