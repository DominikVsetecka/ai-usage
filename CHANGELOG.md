# Changelog

All notable changes to AI Usage are documented in this file.

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
