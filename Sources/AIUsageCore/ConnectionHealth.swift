import Foundation

/// What a connection's latest check means for the user. Only the `needsUser`
/// states ask for action; everything else either works or heals itself while
/// the last known value stays visible.
public enum ConnectionHealth: String, Codable, Equatable, Sendable {
    case connected
    case waiting
    case disabled
    case retrying
    case keychainLocked
    case needsLogin
    case accountChanged
    case incompatible
    case notConfigured
    case failing

    public var needsUser: Bool {
        switch self {
        case .needsLogin, .accountChanged, .incompatible, .notConfigured: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .connected: "Connected"
        case .waiting: "Checking…"
        case .disabled: "Hidden"
        case .retrying: "Retrying"
        case .keychainLocked: "Keychain locked"
        case .needsLogin: "Login needed"
        case .accountChanged: "Account changed"
        case .incompatible: "CLI incompatible"
        case .notConfigured: "Not set up"
        case .failing: "Error"
        }
    }

    public static func of(_ snapshot: UsageSnapshot?) -> ConnectionHealth {
        guard let snapshot else { return .waiting }
        switch snapshot.status {
        case .ok: return .connected
        case .idle: return .waiting
        case .disabled: return .disabled
        case .failed:
            switch snapshot.failure ?? inferredFailure(from: snapshot.errorMessage) {
            case .authentication: return .needsLogin
            case .accountChanged: return .accountChanged
            case .network, .rateLimited: return .retrying
            case .keychainLocked: return .keychainLocked
            case .incompatible: return .incompatible
            case .notConfigured: return .notConfigured
            case .other: return .failing
            }
        }
    }

    /// Fallback for probes that only report text (Claude CLI scraping).
    public static func inferredFailure(from message: String?) -> UsageFailure {
        guard let message = message?.lowercased() else { return .other }
        let authentication = ["session expired", "no longer valid", "credentials are missing", "logged in",
                              "please log in", "login required", "authentication required", "reconnect"]
        if authentication.contains(where: message.contains) { return .authentication }
        let incompatible = ["invalid value", "unexpected argument", "possible values", "unrecognized"]
        if incompatible.contains(where: message.contains) { return .incompatible }
        let notConfigured = ["missing executable", "missing claude cli settings", "missing codex", "import a claude code account"]
        if notConfigured.contains(where: message.contains) { return .notConfigured }
        let network = ["timed out", "could not be reached", "network", "offline", "rate-limited"]
        if network.contains(where: message.contains) { return .network }
        return .other
    }
}
