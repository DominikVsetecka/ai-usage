# PROGRESS — AI Usage

## Orbit refs

- Project: `ai-usage`
- Active tickets: `ORB-0120`
- Completed: `ORB-0119`
- Completed: `ORB-0113`–`ORB-0118`, `ORB-0119`, `ORB-0121`, `ORB-0122`, `ORB-0123`
- Triage / later: `ORB-0119`
- Decisions: `DEC-0005`
- Done: `ORB-0113`–`ORB-0118`, `ORB-0121`, `ORB-0122`, `ORB-0123`

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
- Optional secure Claude profiles are implemented: targeted import from the current Claude Code credential source, per-profile app-owned Keychain storage, direct OAuth usage, automatic refresh-token rotation, 15-minute cache and `Retry-After` handling. The global Claude Code login is never modified.
- NSPopover replaces NSMenu as primary click interaction; shows 5-hour and 1-week windows per provider with integrated burn bar, hover tooltips, reset countdown, and reset marker.
- Local JSONL usage history (`~/.ai-usage/history/`) with Canvas-based `BurnBarView`: solid fill (remaining) left, burn-rate sparkline (used, now=left) right. Mouseover shows timestamp + value.
- Reset times parsed to `Date` via SwiftTerm-rendered PTY output; popover shows "Resets in X hr Y min" countdown.
- Vertical dashed line + dot in sparkline marks where the last reset occurred (position = `resetsAt − windowDuration`).
- History tab in Settings: line chart (5h solid, 1w dashed) with 1-day/7-day/30-day picker and scrollable recent-entries table.
- SwiftTerm used as terminal renderer for PTY output — correctly handles cursor movements, screen clears, partial-line overwrites. Replaces fragile regex ANSI-stripper.

## Planned next

- Secure Claude account profiles (ORB-0120): import Claude Code OAuth credentials per profile into app-owned Keychain; direct OAuth usage without CLI PTY.

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
- `2026-06-24` — (ORB-0123) Local history + integrated burn bar: `UsageHistoryStore` actor schreibt `~/.ai-usage/history/YYYY-MM-DD.jsonl` bei ≥1% Änderung oder alle 30 Minuten. `BurnBarView` (Canvas, kein Swift Charts) ersetzt den Flat-Balken: links = verbleibendes Kontingent (solid fill, schrumpft), rechts = Burn-Kurve im verbrauchten Bereich (jetzt=links, älteste Daten=rechts). Höhere Kurve = schneller verbraucht. Mouseover zeigt Tooltip mit Uhrzeit + %-Wert. Reset-Zeit unter den Balken verschoben damit alle Balken gleich breit sind.
- `2026-06-24` — (ORB-0122) NSPopover replaces NSMenu as primary click interaction. New `UsagePopoverView` (SwiftUI) + `PopoverViewModel` (ObservableObject). Header shows icon, title, refresh spinner, settings button. One `ProviderDetailSection` per enabled source with provider icon, label, stale badge. Two `WindowRow` entries per source (5-hour, 1-week) each with progress bar (green→red gradient), percentage, reset time. Missing windows show "—". Stale values dimmed at 60% opacity with clock badge + timestamp. Footer has Quit. `StatusBarController` rebuilt to own `NSPopover` and update view model on every render; menu removed.
- `2026-06-24` — (ORB-0121) Two-window usage model: `ProviderUsageWindow` moved to shared `UsageModels.swift`; `UsageSnapshot` extended with `fiveHour` and `oneWeek`; all three probes (Claude CLI, Claude OAuth, Codex RPC) now populate both windows; `UsageMonitor` stale-preservation covers all four per-window fields; checks for two-window snapshot and stale merge added. Menu bar unaffected — still uses `percentUsed` from the selected window.
- `2026-06-24` — Planned the next architecture in `ORB-0120`–`ORB-0122`: app-owned Keychain profiles without global Claude-login replacement, a two-window usage model, and a SwiftUI/AppKit menu-bar popover showing 5-hour and 1-week quota details for all active checks. Decision captured in `DEC-0005`.
- `2026-06-24` — Implemented the `ORB-0120` secure-profile foundation and Settings workflow. Unit-style checks cover credential parsing, config secrecy, both usage windows and refresh-token rotation. A live check successfully imported the current Claude Code login into a temporary AI Usage Keychain item, fetched OAuth usage and removed the item afterward. A broad Keychain scan was rejected after it hung; official credential import now probes only the known service (or an explicit override) with a hard three-second timeout.
- `2026-06-24` — Claude reset-Zeit Fix: SwiftTerm als Dependency hinzugefügt; `TerminalRenderer` ersetzt den bisherigen Regex-ANSI-Stripper. SwiftTerm simuliert einen echten VT100-Screen-Buffer — Cursor-Bewegungen, Screen-Clears und Partial-Line-Overwrites werden korrekt rekonstruiert. Ergebnis: `5h=Resets 1:30am (Europe/Vienna)` und `1w=Resets Jun 30 at 9pm (Europe/Vienna)` werden getrennt und korrekt erkannt.
- `2026-06-24` — History-Tab in Settings: Line-Chart (5h solid, 1w gestrichelt) mit 1d/7d/30d-Picker; scrollbare Tabelle der letzten Einträge. Popover-Höhe dynamisch (fixedSize), Popover wird sofort aktiv beim Klick (NSApp.activate).
- `2026-06-24` — Reset-Countdown: `ProviderUsageWindow.resetsAt: Date?` wird automatisch aus `resetDescription` geparst (time-only, month+day+time, relative, Zeitzone aus Klammern). Popover zeigt „Resets in X hr Y min".
- `2026-06-24` — Reset-Marker im Burn-Balken: gestrichelte Vertikallinie + Punkt an der Position des letzten Resets (`resetsAt − windowDuration`), nur wenn der Reset im sichtbaren History-Zeitraum liegt.
- `2026-06-24` — Reset-Marker jetzt auf allen vier Balken (5h Claude, 1w Claude, 5h Codex, 1w Codex): `BurnBarView` erhält `windowDuration`-Parameter; Fallback-Position via `resetAge / windowDuration * sparkW` wenn keine Burn-History vorhanden oder Reset außerhalb des Sparkline-Zeitraums liegt.
- `2026-06-24` — (ORB-0119) Icon-Datei-Picker: Picker-Dropdown entfernt, stattdessen NSOpenPanel-Button pro Provider; ausgewähltes SVG/PNG wird als Base64 in `SourceConfig.iconData` gespeichert; `ProviderIconRenderer` priorisiert `iconData` vor legacy `iconName`; "claude"/"openai" bleiben als Fallback für bestehende Configs.
- `2026-06-24` — Info-Tab in Settings: App-Name, Version, "by Dominik Vsetecka", GitHub-Link, Requirements-Übersicht (claude CLI, codex CLI).
- `2026-06-24` — History-Tab: "Show in Finder"-Button öffnet `~/.ai-usage/history/` direkt im Finder; `UsageHistoryStore.directory` als `public nonisolated let` exponiert.
- `2026-06-24` — README für öffentliches GitHub-Repo geschrieben: Requirements, Build & Run, Feature-Liste, Config-Anleitung, Privacy-Note.
