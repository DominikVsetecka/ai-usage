# AI Usage

A lightweight macOS menu bar app that shows your Claude and Codex quota at a glance.

```
C1 43%  GPT 12%
```

Click the menu bar item to open a popover with per-provider details, burn-rate sparklines, and reset countdowns.

## Requirements

- macOS 13 Ventura or later
- Swift 6 toolchain (Xcode 16+ or [swift.org](https://swift.org/download/))
- **`claude`** — [Anthropic Claude Code](https://claude.ai/code) installed and in `$PATH`
- **`codex`** — [OpenAI Codex CLI](https://github.com/openai/codex) installed and in `$PATH`

Each provider can be individually disabled in Settings if not installed.

## Build & Run

```bash
git clone https://github.com/DominikVsetecka/ai-usage.git
cd ai-usage
swift run AIUsage
```

Build a release binary:

```bash
swift build -c release
# .build/release/AIUsage
```

Print current values without starting the menu bar app:

```bash
swift run AIUsageSnapshot
```

## Features

- **Menu bar** — one value per enabled provider; configurable font size, weight, and color mode (white / dimmed / usage gradient)
- **Popover** — 5-hour and 1-week quota windows per provider with integrated burn-rate sparkline, percentage, and reset countdown ("Resets in 2 hr 15 min")
- **Reset marker** — dot + vertical line in the sparkline marks where the last quota reset occurred
- **Local history** — usage logged to `~/.ai-usage/history/YYYY-MM-DD.jsonl` on ≥1% change or every 30 min; 30-day retention
- **History tab** — line chart with 1-day / 7-day / 30-day picker; "Show in Finder" button opens the history folder
- **Secure Claude profiles** — OAuth credentials imported into a separate app-owned Keychain entry; never touches Claude Code's own login
- **Custom icons** — pick any SVG or PNG per provider via file picker; stored as Base64 in `config.json`
- **Configurable refresh** — 15 s / 30 s / 1 min / 2 min / 5 min

## Configuration

First launch creates a default config at `~/.ai-usage/config.json`. All settings are editable via the popover's gear icon.

History is stored at `~/.ai-usage/history/` and is not committed to git.

### Second Claude subscription

```bash
CLAUDE_CONFIG_DIR=~/.claude-account-2 claude auth login
```

Enable Claude 2 in Settings and set `CLAUDE_CONFIG_DIR` to `~/.claude-account-2`.

### Secure profile mode

Import the current Claude Code login into an isolated Keychain item without touching Claude Code's own credentials:

1. Log in with Claude Code using the first account.
2. Settings → Claude 1 → Connection: "Secure profile" → "Import Current Claude Account" → Save.
3. Switch Claude Code to the second account and repeat for Claude 2.

AI Usage never writes to Claude Code's Keychain item or `~/.claude.json`.

## Privacy

- No telemetry, no analytics, no network requests beyond the CLIs you configure
- All data stays locally under `~/.ai-usage/`
- History files are gitignored; no account data is committed

## License

MIT

---

by [Dominik Vsetecka](https://github.com/DominikVsetecka)
