# PROGRESS — AI Usage

## Orbit refs

- Project: `ai-usage`
- Active tickets: `ORB-0120`, `ORB-0121`, `ORB-0122`
- Triage / later: `ORB-0119`
- Decisions: `DEC-0005`
- Completed: `ORB-0113`, `ORB-0114`, `ORB-0115`, `ORB-0116`, `ORB-0117`, `ORB-0118`

## Stand

Swift Package with full feature set; builds and runs as native macOS menu bar app.

Current feature set:

- Claude 1 and 2 fetch real usage via `claude /usage` in a native PTY; Codex via `codex app-server` JSON-RPC.
- Claude 2 supports a separate `CLAUDE_CONFIG_DIR` for a second subscription.
- PTY completion detection exits as soon as the usage screen settles (~5.5 s), not after the 20 s hard timeout.
- 0% usage edge case handled: section headers present but no "N% used/left" text → returns 0% instead of parse error.
- Stale-value preservation: on a failed fetch the last successful percentage is kept in the menu bar (dimmed); `--` only appears before the very first successful fetch.
- Provider icons: Claude and OpenAI SVG logos rendered via `NSTextAttachment`; both are template images tinted with the current text color. Falls back to text label if `NSImage(data:)` cannot parse the SVG.
- Text color mode: White (default) · Dimmed · Usage gradient (green 0% → red 100%).
- Icon, label, quota, binary path, CLAUDE_CONFIG_DIR all editable per source in Settings.
- Font size (System / 11–16 pt) and font weight (Light / Regular / Medium / Semibold / Bold) configurable globally.
- Test Connection button per provider: runs the probe immediately from the current draft config and shows result inline.
- Save & Refresh writes `~/.ai-usage/config.json`, rebuilds probes and refreshes without closing the Settings window.
- Remaining countdown: optional 100→0% display with colour-coded value (independent of text color mode).
- Refresh is concurrent and incremental across providers; interval 15 s / 30 s / 1 min / 2 min / 5 min.
- No cookie scraping, no Full Disk Access, no telemetry.

## Planned next

- Secure Claude account profiles: import the currently authenticated Claude Code OAuth credentials, store each profile secret in a separate app-owned macOS Keychain item, and keep only non-secret profile metadata in the JSON config.
- Direct Claude OAuth usage checks per imported profile, including token refresh, rate-limit handling and a cache independent from the visible 30-second UI refresh. The existing CLI/PTTY mode remains available during migration and as fallback.
- Multi-window snapshots: every active check retains both the 5-hour/session window and the 1-week window from one provider fetch instead of discarding the unselected window.
- A native click popover replaces the plain `NSMenu` as the primary detail view. It shows both windows, progress, reset time, freshness and errors for every enabled source; refresh, settings and quit remain directly accessible.

## Verification

- `swift build` passes on every session end.
- `swift run AIUsageChecks` passes.
- `swift run AIUsageSnapshot` passes with real local values; sample run reported `C1 0%  GPT 61%`.
- Settings-window smoke test passes (icons, font picker, test connection, colour mode).
- Real snapshot duration ~5.5 s after PTY completion detection fix.
- `swift test` is not used — this CommandLineTools setup exposes neither `XCTest` nor Swift `Testing`.

## Logs

- `2026-06-23` — Project direction defined from ClaudeBar reference: reduced Swift menu bar app, CLI-first, local-only, configurable 30 second refresh, no browser cookie reads for MVP.
- `2026-06-23` — Swift Package scaffold implemented: `AIUsageCore`, `AIUsage` menu bar executable, `AIUsageChecks`, fixture probes, config loading, `UsageMonitor`, safe `CommandRunner`, generic percent parser, AppKit `NSStatusItem` UI.
- `2026-06-24` — Default data path changed from fixtures to real local sources where available: Codex local session parser plus optional `ccusage` command for Claude. Codex unlimited credits render as `GPT ∞`.
- `2026-06-24` — Added `AIUsageSnapshot` terminal tool. Local snapshot currently shows real Codex data (`GPT 22%`) and Claude missing because `/opt/homebrew/bin/ccusage` is not installed.
- `2026-06-24` — Replaced interim probes after direct ClaudeBar source review: Claude now uses PTY `/usage`; Codex uses `app-server` JSON-RPC `account/rateLimits/read`. Added provider-specific Settings UI and JSON persistence. Real snapshot verified both providers.
- `2026-06-24` — Added remaining-quota countdown and per-value green/yellow/red menu-bar colors. Removed the temporary `AI ...` refresh title, made provider refresh concurrent/incremental, and reduced Claude PTY latency.
- `2026-06-24` — (ORB-0117) Added Test Connection button per source in Settings; shows spinner and inline result. Fixed 0% usage parse edge case in `ClaudeCLIUsageProbe.parse()`.
- `2026-06-24` — (ORB-0118) Provider icons (Claude SVG orange→template, OpenAI SVG black→template) in menu bar via `NSTextAttachment`; emoji/custom-text fallback. Stale-value preservation on probe failure (last good percent kept, shown dimmed). Configurable font size and weight in Settings. Text color mode: White / Dimmed / Usage gradient.
- `2026-06-24` — Save & Refresh no longer closes the Settings window. Both provider icons changed to template images so they always match the text color.
- `2026-06-24` — Removed "Emoji / custom" option from Icon Picker (redundant — emoji can be typed directly into Short Label). Cleaned up dead `"emoji"` branch in `iconModeBinding`. ORB-0119 opened: user-provided icon via file picker (Base64 or path in config) to avoid trademark issues with hardcoded brand SVGs.
- `2026-06-24` — Planned the next architecture in `ORB-0120`–`ORB-0122`: app-owned Keychain profiles without global Claude-login replacement, a two-window usage model, and a SwiftUI/AppKit menu-bar popover showing 5-hour and 1-week quota details for all active checks. Decision captured in `DEC-0005`.
