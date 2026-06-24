# AI Usage

Local-first macOS menu bar app for compact AI quota visibility.

AI Usage displays Claude and Codex quota percentages side by side without sending telemetry or storing account data in the repository.

## Current Status

The app is functional for local use:

- Claude usage is read from the authenticated Claude CLI `/usage` screen.
- Codex usage is read through the local read-only `codex app-server` JSON-RPC interface.
- Values refresh concurrently and remain visible when a provider temporarily fails.
- Settings, remaining-quota mode, provider icons and connection checks are implemented.
- Claude sources can optionally import the current Claude Code account into a separate app-owned macOS Keychain profile and fetch usage directly.

A click popover with both 5-hour and 1-week windows is planned next. See `PLAN.md` and `ROADMAP.md`.

## Goal

Build a reduced ClaudeBar-inspired Swift app that shows one to three usage percentages directly in the macOS menu bar:

```text
C1 43%  C2 71%  GPT 12%
```

The app is intentionally local-first and narrow in scope. It should be easy to run for one user, but avoid broad permissions and avoid scraping browser data unless there is no better option.

## Scope

MVP:

- Native macOS menu bar app.
- Three configurable sources: Claude subscription 1, Claude subscription 2, GPT Codex.
- Default refresh interval: 30 seconds.
- Refresh interval configurable.
- Optional remaining-quota countdown from 100% to 0%.
- Countdown colors transition from green through yellow to red.
- Menu actions: refresh now, settings, show last update / errors, quit.
- Claude quota via the authenticated Claude CLI `/usage` screen.
- Codex quota via `codex app-server` JSON-RPC.
- Fixture-backed parsers and lightweight tests.

Out of scope for the MVP:

- Auto-updater.
- Public release, notarization, Homebrew cask.
- Browser cookie scraping.
- Full Disk Access.
- Historical analytics dashboard.
- Themes and notifications.

## Security Model

The app should be boring and constrained:

- No telemetry.
- The current implementation uses only the official local CLIs and no direct Claude network client.
- No browser cookie reads.
- No Full Disk Access requirement.
- No shell string execution.
- Commands run through `Process` with executable path plus argument array.
- Probe output is parsed into percentages and status only.
- Raw command output is not persisted.
- Probe timeouts prevent hanging menu bar refreshes.

The planned Claude profile mode is deliberately narrower than browser/API scraping: it imports the currently authenticated Claude Code OAuth credentials into a separate app-owned Keychain item and uses them only for quota and token refresh. It never reads browser storage or swaps the global Claude Code login. See `PLAN.md` and `ROADMAP.md`.

### Repository privacy

The repository contains no connected account data, email addresses, OAuth tokens, session cookies or captured provider responses. Runtime configuration is stored outside the repository at `~/.ai-usage/config.json`; current CLI credentials remain owned by the official Claude and Codex tools.

The planned profile implementation follows the same boundary:

- secrets are stored only in per-profile macOS Keychain items
- `config.json` contains non-secret metadata and Keychain references only
- credentials and raw authenticated responses are never committed or logged
- `.gitignore` excludes local config, environment and secret-file patterns

## Planned Stack

- Swift.
- AppKit `NSStatusItem` for menu bar rendering.
- `NSMenu` for the current controls; `NSPopover` + SwiftUI is planned for the two-window detail view.
- Swift Package Manager.
- No third-party dependencies unless a concrete need appears.

## Requirements

- macOS 13 or newer
- Swift 6 toolchain
- Claude Code CLI for Claude checks
- Codex CLI for Codex checks

## Local Usage

Build:

```sh
swift build
```

Run the menu bar app:

```sh
swift run AIUsage
```

Or double-click:

```text
start-ai-usage.command
```

Run the lightweight checks:

```sh
swift run AIUsageChecks
```

Print the current values in Terminal without starting the menu bar app:

```sh
swift run AIUsageSnapshot
```

The current CommandLineTools setup does not expose `XCTest` or Swift `Testing`, so the project uses `AIUsageChecks` as a small assertion-based verification executable.

Final local use can remain unsigned for this machine. Distribution to other machines would require signing and possibly notarization.

## Configuration

Open the menu bar item and choose `Settings…`.

Each provider has its own settings:

- enabled/disabled
- short menu bar label
- session or weekly quota
- CLI binary path
- Claude only: `CLAUDE_CONFIG_DIR` for a separate account
- Claude only: CLI or secure Keychain profile connection

General settings include `Remaining countdown (100% to 0%)`:

- off: display percent used
- on: display percent remaining (`100 - used`)
- 100% remaining is green
- 0% remaining is red
- no usage naturally displays 100%

Default fetch workflow:

- `C1`: starts `claude /usage --allowed-tools ""` in a pseudo-terminal and parses `% used`
- `C2`: same CLI workflow, disabled until a second config directory is authenticated
- `GPT`: starts `codex -s read-only -a untrusted app-server`, initializes JSON-RPC and calls `account/rateLimits/read`

If a source cannot produce a percentage, it is shown as `--%` with the concrete error in the menu.

Refresh keeps the last known values visible. Claude and Codex refresh concurrently, and each result is rendered as soon as it arrives instead of replacing the title with a temporary `AI ...` label.

Optional config path:

```sh
AI_USAGE_CONFIG=/path/to/config.json swift run AIUsage
```

Default config lookup path:

```text
~/.ai-usage/config.json
```

Settings are saved automatically to this file. `config.example.json` documents the complete structure.

For a second Claude subscription, authenticate a separate config directory once:

```sh
CLAUDE_CONFIG_DIR=~/.claude-account-2 claude auth login
```

Then enable Claude Subscription 2 in Settings and use `~/.claude-account-2` as its `CLAUDE_CONFIG_DIR`.

No browser cookies, repository-local OAuth token files or Full Disk Access are used. In CLI mode, credentials remain owned by the official tools. In secure-profile mode, imported Claude OAuth secrets exist only in app-owned Keychain items.

### Secure Claude profiles

The optional secure-profile mode removes the need to maintain multiple `CLAUDE_CONFIG_DIR` folders:

1. Log Claude Code into the first account using the official CLI.
2. Open AI Usage Settings for Claude 1, select `Secure profile`, then choose `Import Current Claude Account`.
3. Save the settings.
4. Log Claude Code into the second account.
5. Repeat the import under Claude 2, then save again.
6. Restore Claude Code to whichever account you want to use interactively.

AI Usage copies only the OAuth fields required for quota and refresh into separate Keychain items. Importing, refreshing, replacing or removing an AI Usage profile never writes to Claude Code's Keychain item or `~/.claude.json`.

The direct OAuth usage endpoint is not a documented public Anthropic API and may change. AI Usage therefore keeps the Claude CLI mode available as a fallback, caches successful direct responses for 15 minutes and honours provider rate limits.
