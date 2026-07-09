import Foundation

/// Reads the display-only identity of the ChatGPT/Codex account the local
/// `codex` CLI is currently logged into — purely informational, so users can
/// see at a glance which account is being probed. Never touches the actual
/// bearer tokens; only decodes the non-secret `email` claim already present
/// in the locally stored OIDC id token.
public enum CodexAccountReader {
    public static func currentAccountEmail(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let url = homeDirectory.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else {
            return nil
        }
        return Self.emailClaim(fromIDToken: idToken)
    }

    /// Decodes only the middle (payload) segment of a JWT and reads its
    /// `email` claim. Does not verify the signature — this is for display
    /// purposes only, never used to authenticate or authorize anything.
    static func emailClaim(fromIDToken idToken: String) -> String? {
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let payloadData = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        return payload["email"] as? String
    }
}
