# Changelog

All notable changes to AI Usage are documented in this file.

## 1.5 — 2026-07-12

### Added

- Notifications settings section with a full set of opt-in usage alerts, all off by default and configurable per type:
  - **Usage threshold** — warn once per cycle when a 5-hour or weekly window crosses a chosen level (80/85/90/95%). Always evaluated on real used percent; the wording follows your used-vs-remaining display, so in remaining-countdown mode it reads "only 10% left".
  - **Limit reached** — alert when a window hits 100%.
  - **Pace** — warn when the burn rate projects running out of the 5-hour window before it resets (reuses the existing pace estimator).
  - **Cycle reset** — notify when a window resets (quota refreshed).
  - **Extra quota resumed** — the existing "Fable started being used again after 30+ min quiet" notification, now alongside the rest.
  - **Login expired** — notify when a source can't be read because its login needs a re-import (as opposed to a transient rate-limit).
- "Remember notification state across restarts" — persists the quiet-period timers and last-seen levels to `~/.ai-usage/notify-state.json`, so restarting the app never re-triggers a notification on its own.
- Diagnostic fetch log at `~/.ai-usage/fetch-log.txt` (last 100 lines): every Claude usage fetch with a timestamp, the refresh trigger (timer/startup/manual/settings-apply), whether it was a cache hit or a real network call, the interval since the last real fetch, and any 429 with its backoff — for troubleshooting refresh timing and rate-limits.

### Fixed

- Rate-limit backoff no longer fully resets after a single successful fetch. Diagnostic logging captured a real case where the account was hitting a persistently tight server-side limit (roughly every other 30s refresh got a 429) — a lone success in between kept snapping the backoff straight back to its 60s floor, so the app just kept re-tripping the same limit at the tightest possible cadence. The streak now decays by one step on success instead, so a 429 that recurs right after one clean fetch still escalates the wait (120s, 240s, ...) instead of resetting.
- **Found the actual root cause of the rate-limit problem, and it predates all of the above:** the Claude usage cache had been silently shortened from 15 minutes to 20 seconds shortly before v1.4, which meant almost every periodic refresh tick made a real network call instead of serving from cache — roughly a 45x jump in request rate against an account-level limit. (v1.4's "couple the cache TTL to the refresh interval" change didn't fix this — at the 30s default it only worked out to ~24s, essentially the same broken behavior.) The cache is now back to a 15-minute default, matching the original v1.3 design, and is deliberately decoupled from the UI refresh interval: the 5-hour/weekly usage windows don't meaningfully change on a 20-30s cadence anyway. A manual refresh (or Save & Refresh) still bypasses the cache immediately, subject only to the existing 10s floor.

### Changed

- Settings were reorganized from three crowded tabs into a macOS-style left sidebar with focused panels: General, Menu Bar, Popover, Notifications, Connections, History, About.

### Fixed

- The extra-quota (Fable) notification no longer fires on every app restart. Pre-existing usage seen for the first time now only establishes a baseline; a notification requires an actual observed increase, gated by the 30-minute quiet period (which now survives restarts when state-remembering is on).
- A window jumping straight past the threshold to 100% now sends only the "limit reached" alert instead of both the threshold and limit notifications at once.
- The login-expired notification now also recognizes the Claude CLI "not logged in" state, and no longer misfires for a source that simply hasn't been set up yet.
- Rate-limit backoff is now exponential (60s → 120s → … capped at 15 min, resetting on the next success) instead of a flat retry, so a persistent 429 is no longer retried every interval — which kept re-tripping the limit and re-surfacing the error. A server-provided Retry-After still wins when it asks for longer.

## 1.4 — 2026-07-11

### Changed

- Refresh interval minimum is now 30 seconds; the 15-second option was removed. At 15s the numbers barely move (the usage windows are 5-hour and weekly), so it only added API load for no real benefit. A saved 15-second config auto-migrates to 30 seconds.
- The Claude usage cache now scales with the configured refresh interval (about 0.8× the interval) instead of a fixed 20 seconds, so lowering the interval actually yields proportionally fresher data instead of staying capped at the old fixed window. (The design note DEC-0006 claimed a "15-minute cache"; the code had always used a much shorter window — this reconciles note and behaviour.)

### Fixed

- Rapid manual refreshes could trip Claude's usage API rate limit (HTTP 429) and then lock every refresh for several minutes. Manual refresh now has a client-side floor — at most one real network fetch per 10 seconds, extra clicks are served from cache — so button-spamming can no longer trigger the lockout.
- When Claude's usage API does rate-limit, the value is now shown greyed out (stale, with the retry time) instead of silently freezing the last value while still looking current — so the lock is actually visible rather than looking like "refresh does nothing".
- Settings "Save & Refresh" now reuses the same usage service instead of rebuilding it, so the 10-second manual-refresh throttle and any active rate-limit backoff survive a settings apply. Previously each apply started a fresh service with an empty cache, so repeatedly pressing Save & Refresh could bypass the throttle and re-hit a rate-limited endpoint.

## 1.3 — 2026-07-10

### Added

- Popover history styling options: merge consecutive blocks with unchanged usage into one continuous block, round the step corners, or connect steps into one smooth outline with no gaps — flat-tangent curves between value changes, with the boundary between the remaining-time fill and the newest history entry left flat since that's a mode change, not a value transition.
- "Always show pace estimate" setting: the burn-rate estimate next to the 5-hour reset can now optionally always be shown, instead of only when it would run out before the reset.

## 1.2 — 2026-07-09

### Added

- Codex account transparency: Settings now show which ChatGPT/Codex account is being probed (read locally from the non-secret `email` claim in the CLI's own id token — never a token or secret), plus a "Verify usage" link for both Claude (`claude.ai/new#settings/usage`) and Codex (`chatgpt.com/codex/cloud/settings/analytics`) so the numbers can be manually cross-checked.
- Burn-rate estimate: the 5-hour window now shows "≈Xh Ym left at this pace" next to the reset countdown, projected from the burn rate since the last reset. Only shown once there's enough signal (15+ minutes of data) and only when it would run out before the next reset — otherwise the reset countdown alone is the relevant number.

### Fixed

- The popover could occasionally show no history at all until the app was restarted. Root cause: a probe reporting overall success while failing to parse just one window (e.g. a Claude CLI `/usage` redraw glitch) silently blanked that window instead of keeping the last-known-good value — only a hard failure was covered before. The popover also now reloads history explicitly every time it's opened, and a transient empty load never overwrites already-good data.
- Untouched (0% used) model-scoped extra windows (e.g. a "Fable" cap) report no reset timestamp from the API and were misrendered as a fully elapsed bar (all history, no remaining fill) instead of the opposite — fully remaining.

## 1.1 — 2026-07-06

### Added

- Unified "Visual" popover bar style, replacing the old "Compact" style: a time-remaining fill plus burn history rendered as blocks or a smooth line, with configurable bar height, history darkness, block width, and a live preview row in Settings.
- Per-connection popover controls: choose which windows (5-hour / 1-week / Extra) appear, and how the percent number displays per row — used vs. remaining override, global font size/weight, or hide it entirely.
- Generic extra-quota support: `UsageSnapshot.extraWindows` picks up model-scoped weekly limits some plans report (discovered live: a separate "Fable" weekly cap) from the Claude OAuth API's `limits` array, keyed by display name so future model-specific limits show up automatically. Only available through the Secure profile (OAuth) connection — the Claude CLI `/usage` text screen doesn't expose it. Settings call this out explicitly.
- History tab: per-series toggle chips above the chart to declutter a busy multi-connection view.
- Settings reorganized into clearly labeled General / Menu Bar / Popover sections.

### Fixed

- `resetsAt` now parses the API's ISO date directly instead of round-tripping through a locale-formatted string — the old path silently failed (and left the time-remaining bar fill empty) on any non-English system locale.
- The popover now has a fixed opaque dark background and forced dark color scheme, so bright windows behind it (e.g. a white browser) no longer bleed through the native popover vibrancy and wash out the text.
- The hover tooltip on multi-day windows (1-week, Extra) now includes the date, not just the time.

## 1.0 — 2026-06-25

Initial public release.

- Claude (CLI or Secure OAuth profile) and Codex quota tracking in the macOS menu bar.
- Two-window usage model (5-hour and 1-week) with independent reset tracking and stale-value preservation.
- Native `NSPopover` detail view with per-provider burn-rate sparklines and reset countdowns.
- Local JSONL usage history with a History tab (line chart, 1-day/7-day/30-day ranges).
- Secure Claude profiles: OAuth credentials imported into an app-owned Keychain entry, isolated from Claude Code's own login.
- Configurable menu bar font size/weight/color, custom per-provider icons, and configurable refresh interval.
