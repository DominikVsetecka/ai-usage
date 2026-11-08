import Foundation

/// One-time upgrade of a v1 config (fixed `claude1`/`claude2`/`codex` slots)
/// to the free account list. Source IDs are kept, so existing history files,
/// notification state and guided-login folders keep matching.
public enum AccountMigration {
    public static func migrate(_ config: AppConfig, homeDirectory: URL) -> (config: AppConfig, changed: Bool) {
        guard (config.configVersion ?? 1) < AppConfig.currentConfigVersion else { return (config, false) }
        var copy = config
        for index in copy.sources.indices where copy.sources[index].mode == .claudeOAuth && copy.sources[index].credentialOrigin == nil {
            // A guided login leaves its isolated config folder behind; a plain
            // import copied Claude Code's token and has none.
            let folder = ClaudeGuidedLoginService.configDirectory(homeDirectory: homeDirectory, connectionID: copy.sources[index].id)
            copy.sources[index].credentialOrigin = FileManager.default.fileExists(atPath: folder.path) ? .guidedLogin : .claudeCodeCopy
        }
        copy.configVersion = AppConfig.currentConfigVersion
        return (copy, true)
    }

    /// Writes `config.v1.json` next to the config once, before the first
    /// migrated save, so the old file can always be restored by hand.
    public static func backUpOriginal(configURL: URL) throws {
        let backup = configURL.deletingLastPathComponent().appendingPathComponent("config.v1.json")
        guard !FileManager.default.fileExists(atPath: backup.path),
              FileManager.default.fileExists(atPath: configURL.path) else { return }
        try FileManager.default.copyItem(at: configURL, to: backup)
    }

    /// A new, stable account ID. Migrated accounts keep their old ID.
    public static func newAccountID(provider: AccountProvider) -> String {
        "\(provider.rawValue)-\(UUID().uuidString.prefix(8).lowercased())"
    }
}
