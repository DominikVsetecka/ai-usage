# PLAN — AI Usage

## Orbit refs

- Project: `ai-usage`
- Active tickets: `ORB-0120`, `ORB-0121`, `ORB-0122`
- Triage / later: `ORB-0119`
- Decisions: `DEC-0005`
- Completed: `ORB-0113`, `ORB-0114`, `ORB-0115`, `ORB-0116`, `ORB-0117`, `ORB-0118`

## Objective

Extend the current local menu-bar app in two directions without destabilising the working probes:

1. Make two Claude subscriptions easy to configure through app-managed profiles whose secrets are protected by macOS Keychain.
2. Turn a click on the menu-bar values into a compact detail popover showing both the 5-hour and 1-week window for every enabled source.

The menu-bar title remains intentionally small and continues to show one user-selected window per source.

## Architecture decision

`DEC-0005` defines the security boundary:

- `config.json` stores profile UUID, display name, source settings and a Keychain reference only.
- Each Claude profile gets its own generic-password item in the app's Keychain service.
- The secret payload contains only the OAuth values required for usage and refresh.
- Keychain accessibility is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Profile import reads the current official Claude Code credential source once; it never writes back to or swaps Claude Code's global credential item.
- No browser cookies, browser database access, Full Disk Access or raw-token logging.

## Phase 0 — credential and endpoint spike (`ORB-0120`)

Before UI work, validate the complete lifecycle against the two real accounts:

1. Detect Claude Code credentials from the supported local sources: `~/.claude/.credentials.json`, the legacy `Claude Code-credentials` Keychain item and its current hashed variant.
2. Parse only `accessToken`, `refreshToken`, `expiresAt`, subscription type and stable account metadata when available.
3. Verify `GET https://api.anthropic.com/api/oauth/usage` returns both expected windows with the required OAuth beta header.
4. Verify refresh through `POST https://platform.claude.com/v1/oauth/token`, including refresh-token rotation and an invalid-grant/re-login state.
5. Measure throttling and honour `Retry-After`. Start with a per-profile 15-minute network cache while retaining the 30-second UI refresh and cached display updates.
6. Record redacted fixtures and parser checks. Never save live payloads containing tokens.

Exit condition: import, usage fetch, refresh and re-login failure are understood and covered by fixtures before the profile UI is considered complete.

## Phase 1 — secure Claude profiles (`ORB-0120`)

### Domain and persistence

- Add `ClaudeProfile` metadata with stable UUID, user-visible name, optional non-secret account label, enabled state and Keychain account reference.
- Add a small `KeychainCredentialStore` built on Security.framework rather than shelling out for app-owned writes.
- Use a dedicated service name such as `app.ai-usage.claude-profile` and profile UUID as `kSecAttrAccount`.
- Support add/update/read/delete and duplicate-account detection.
- Keep the existing `SourceConfig.localPath` CLI profile mode readable for backward compatibility.

### Import and management UX

- Add `Import current Claude Code account` in Claude settings.
- Show the detected account identity and require a profile name before storing it.
- Make the second-account workflow explicit: log Claude Code into account B, return to AI Usage, import it, then restore Claude Code to either account if desired. Import itself does not change that login.
- Provide profile rename, connection test, replace credentials and remove profile actions.
- Removing a profile deletes its Keychain item and metadata after confirmation.

### Direct usage probe

- Add a profile-aware Claude OAuth probe using an injected network client and credential store.
- Refresh five minutes before expiry; atomically replace rotated tokens in the same Keychain item.
- Cache successful usage per profile, honour server backoff and keep stale data on transient failures.
- Report authentication-required separately from network/rate-limit failures.
- Keep CLI/PTTY as a selectable fallback until both real profiles pass sustained use.

## Phase 2 — two-window usage model (`ORB-0121`)

The current probes parse two windows but select one before returning `UsageSnapshot`. Move selection to presentation:

- Introduce stable window kinds: `fiveHour` and `oneWeek`.
- Each window carries percent used, reset timestamp/description, freshness and optional error state.
- `UsageSnapshot` carries both windows plus provider-level status and updated time.
- Claude CLI/API map current session to `fiveHour` and current week/all models to `oneWeek`.
- Codex RPC maps primary/secondary by reported `windowDurationMins`; use 300 and 10080 when available, with a safe primary/secondary fallback if upstream omits duration.
- Preserve the last successful value independently for each window.
- Keep `SourceConfig.quota` as the compact menu-bar selection; it no longer controls what the probe fetches.
- Migrate old config values without requiring a reset.

Checks cover parsing, mapping, countdown conversion, partial-window responses, stale preservation and reset formatting.

## Phase 3 — menu-bar detail popover (`ORB-0122`)

Replace `statusItem.menu` as the primary click interaction with `NSPopover` hosting SwiftUI content.

### Layout

- Compact header with app name, last refresh state, icon-only refresh and settings buttons with tooltips.
- One unframed provider section per enabled check, identified by icon, source label and optional profile name.
- Two fixed-height quota rows per provider: `5-hour window` and `1-week window`.
- Each row shows the percentage, a stable-width progress bar and reset time. Missing windows remain visible as unavailable rather than shifting the layout.
- Footer contains concise error/stale context and Quit; detailed raw output is never shown.
- Use system materials, semantic colours and at most 8 px corner radius. Avoid nested cards and oversized typography.

### Behaviour

- Clicking the status item toggles the popover; clicking outside closes it.
- Refresh updates rows in place and does not blank or resize the popover.
- Settings opens the existing settings window without destroying cached values.
- Remaining-countdown mode applies consistently to title, percentages and progress bars: 100% remaining is green, 0% is red.
- Used mode uses the inverse semantic direction: low usage green, high usage red.
- Stale values are dimmed and timestamped; an unavailable or authentication-required state has a direct settings action.
- Keyboard and VoiceOver labels cover refresh, settings, source, window, percentage and reset time.

### Window sizing

- Width target: approximately 360–420 pt.
- Height is content-driven with a bounded scroll region when all three checks are enabled.
- Fixed row geometry prevents jumps during refresh or error transitions.

## Verification and rollout

1. Extend `AIUsageChecks` with fake Keychain/network stores and two-window fixtures.
2. Run `swift build` and `swift run AIUsageChecks` after each phase.
3. Verify account isolation: importing/refreshing profile B must not change Claude Code `/status` for profile A.
4. Verify two real Claude profiles plus Codex RPC in the popover.
5. Test light/dark appearance, stale refresh, offline mode, expired token, disabled source and all-three-source overflow.
6. Keep the existing plain menu available behind a temporary fallback during popover smoke testing, then remove it after stable daily use.

## Non-goals

- Browser-cookie extraction or embedded browser login.
- Replacing the globally active Claude Code/VS Code/Zed account.
- Persisting raw provider responses or credentials outside Keychain.
- A general analytics dashboard, history charts or notifications in this phase.
