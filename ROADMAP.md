# ROADMAP — AI Usage

## Orbit refs

- Project: `ai-usage`
- Active tickets: `ORB-0120`, `ORB-0121`, `ORB-0122`
- Triage / later: `ORB-0119`
- Decisions: `DEC-0005`
- Completed: `ORB-0113`, `ORB-0114`, `ORB-0115`, `ORB-0116`, `ORB-0117`, `ORB-0118`

## Current focus

1. `ORB-0120` — implementation and one-account live OAuth verification complete. Remaining acceptance: import and sustain both real Claude accounts through token refresh/re-login scenarios.
2. `ORB-0121` — refactor snapshots and probes so one fetch preserves both 5-hour/session and 1-week windows, with independent reset and stale state.
3. `ORB-0122` — replace the plain click menu with a compact native popover showing both windows for every enabled check.

The existing CLI/PTTY and Codex RPC implementation stays operational throughout these phases. New Claude profile mode is additive until real-account verification passes.

## Acceptance target

- Two Claude accounts can be imported through a guided workflow without manually editing paths or copying tokens.
- Secrets exist only in app-owned Keychain items and never in `config.json`, logs, Orbit or UI diagnostics.
- Importing or selecting an account does not overwrite Claude Code's global credentials or change the account used by VS Code/Zed/Terminal.
- The compact menu-bar title still shows one configured value per enabled source.
- Clicking the title opens a polished detail popover with 5-hour and 1-week values for every enabled source.
- A failed refresh keeps the last successful value visible and marks only the affected source/window stale.
- The 30-second refresh remains configurable; provider-level cache and `Retry-After` prevent excessive API calls.

## Later

- Auto-responses: add a broader "send Enter on any unknown prompt" fallback for Claude PTY robustness.
- Optional warning threshold per source (e.g. badge or colour change at 80%).
- Optional signed local `.app` bundle / login-item launch.
- (ORB-0119) User-provided icon per source via file picker (SVG/PNG → Base64 in config); replaces hardcoded brand SVGs to avoid trademark issues.
