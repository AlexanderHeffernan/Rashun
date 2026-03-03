# Rashun

**A macOS menu bar app that tracks your free AI coding tool usage so you don't burn through your quota before the month is over.**

If you're a student (or anyone) relying on free-tier AI tools like [Amp](https://ampcode.com) and [GitHub Copilot](https://github.com/features/copilot), you know the pain: you're deep in a project, it's day 22, and suddenly you've hit your limit. Rashun sits quietly in your menu bar, shows you how much you have left at a glance, and nudges you when you're burning through tokens too fast.

```bash
curl -fsSL https://raw.githubusercontent.com/alexanderheffernan/rashun/main/install.sh | bash
```

---

## Features

- **Menu bar at a glance** — A brain icon fills up (or empties out) to reflect your average remaining quota, with a percentage right next to it.
- **Multiple sources** — Ships with support for **Amp Free**, **GitHub Copilot**, **Codex**, and **Gemini CLI**. Enable whichever ones you use.
- **Smart notifications** — Get alerted when your remaining usage drops below a threshold, when you're burning through tokens unusually fast, or when you're on pace to run out before the month ends.
- **Configurable polling** — Set how often Rashun checks your usage (default: every 2 minutes).
- **Preferences UI** — Toggle sources on/off, expand notification rules, and tune thresholds — all from a native settings window.
- **Extensible by design** — Adding a new AI source is as simple as dropping a single Swift file into `Sources/AISources/`. The build script auto-discovers it.

---

## How It Works

Rashun polls each enabled source on a timer. For each source, it fetches the current usage data (remaining quota vs. total limit), calculates the percentage remaining, and updates the menu bar icon accordingly. It also evaluates any enabled notification rules against the current and historical usage data, sending macOS notifications when conditions are met.

| Source | How it fetches data |
|---|---|
| **Amp** | Runs `~/.amp/bin/amp usage` and parses the output |
| **Copilot** | Uses `gh auth token` to authenticate, then hits the GitHub Copilot internal API |
| **Codex** | Reads recent `~/.codex/sessions/*.jsonl` token-count events and converts `used_percent` to percent remaining |
| **Gemini CLI** | Uses local `~/.gemini/oauth_creds.json` auth to call Gemini Code Assist quota APIs (`loadCodeAssist` + `retrieveUserQuota`) and tracks `gemini-3-pro-preview` remaining usage |

---

## Prerequisites

- **macOS 11+** (Big Sur or later)
- **Swift 6.2+** toolchain (ships with recent Xcode versions)
- For **Amp** monitoring: the [Amp CLI](https://ampcode.com) installed at `~/.amp/bin/amp`
- For **Copilot** monitoring: the [GitHub CLI (`gh`)](https://cli.github.com/) installed and authenticated (`gh auth login`)
- For **Codex** monitoring: Codex app/CLI installed with local session logs in `~/.codex/sessions`
- For **Gemini CLI** monitoring: Gemini CLI installed and authenticated (local credentials stored in `~/.gemini/oauth_creds.json`)

---

## Installation

### Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/alexanderheffernan/rashun/main/install.sh | bash
```

This downloads the latest build, installs it to `/Applications`, and clears macOS quarantine flags. To update, just run the same command again.

### Build from Source

If you prefer to build from source (requires Swift 6.2+):

```bash
git clone https://github.com/alexanderheffernan/rashun.git
cd rashun
chmod +x build.sh
./build.sh
```

`build.sh` will:
1. Auto-generate the source registry from `Sources/AISources/`
2. Build a release binary via `swift build`
3. Package it into `Rashun.app` with proper code signing
4. Launch the app

---

## Usage

Once running, you'll see a **brain icon** in your menu bar with a percentage.

1. **Click the icon** to see a breakdown of remaining usage per source.
2. **Open Settings** (`⌘,` from the menu) to enable/disable sources and configure notifications.
3. **Hit Refresh** to manually poll all sources.

### Notification Rules

Each source comes with built-in notification rules you can toggle on:

| Rule | What it does |
|---|---|
| **Percent remaining below** | Fires when your remaining usage drops below a threshold (e.g., 50%) |
| **Recent usage spike** | Fires when you burn through a large chunk of quota in a short time window |
| **Pacing alert** *(reset-window sources)* | Fires when your current trend is projected to hit 0% before the source reset |

All thresholds and time windows are configurable in Settings.

---

## Adding a New Source

Rashun is designed to make adding sources trivial. To add a new one:

1. **Create a new file** in `Sources/AISources/` — e.g., `ClaudeSource.swift`
2. **Define a struct** conforming to `AISource`:

```swift
import Foundation

struct ClaudeSource: AISource {
    let name = "Claude"
    let requirements = "Describe what the user needs installed/configured."

    func fetchUsage() async throws -> UsageResult {
        // Fetch remaining and total quota however you need to
        return UsageResult(remaining: 80, limit: 100)
    }
}
```

3. **Run `build.sh`** — it auto-discovers any struct conforming to `AISource` in that directory and registers it. No other wiring needed.

### Custom Notification Rules

Sources can also define their own notification rules by implementing `customNotificationDefinitions`.

---

## Project Structure

```
Sources/
├── App.swift                    # Entry point, menu bar setup, polling logic
├── AISources/
│   ├── AISource.swift           # AISource protocol & UsageResult model
│   ├── AmpSource.swift          # Amp Free usage fetcher
│   └── CopilotSource.swift      # GitHub Copilot usage fetcher
├── Notifications/
│   ├── NotificationModels.swift       # Core types (rules, events, contexts)
│   ├── NotificationDefinitions.swift  # Generic rules (threshold, spike)
│   ├── NotificationManager.swift      # macOS notification delivery
│   └── NotificationHistoryStore.swift # Usage history for rule evaluation
├── Preferences/
│   ├── PreferencesWindowController.swift  # Settings UI
│   └── SettingsStore.swift                # Persistent settings (UserDefaults)
└── Views/
    └── RefreshButton.swift      # Custom hoverable refresh button
```

---

## Contributing

Contributions are welcome! Whether it's a new AI source, a new notification rule, a bug fix, or a UI improvement.

1. Fork the repo
2. Create a feature branch (`git checkout -b my-new-source`)
3. Make your changes
4. Test by running `./build.sh` and verifying the app works
5. Open a pull request

Some ideas for contributions:
- New AI sources (Claude, ChatGPT, Cursor, etc.)
- New notification rule types
- An app icon
- Launch-at-login support

---

## License

This project is licensed under the [MIT License](LICENSE).

## TODO
- [X] Add app icon
- [X] Add launch-at-login support
- [ ] Need to fix start-up alert (“Rashun.app” would like to access files on a network volume.) – Likely fix is just to move the app bundle to /Applications instead of running from the project directory. Edit: Just installed to /Applications and it doesn't seem to have fixed the issue. Will need to investigate further.
- [X] Set up a testing framework and add unit tests
- [X] Set up a CI/CD pipeline (GitHub Actions)
- [X] Add an easier install path (no clone/build required), with optional auto-update support
- [X] Auto-update support 
- [ ] Better timezone handling, don't show UTC times to users in other timezones
- [ ] Evaluate AppKit vs SwiftUI trade-offs (AppKit currently gives better menu bar/notification control)
- [ ] Add macOS widgets
- [ ] Improve data management (export/import usage data, delete stored data)
- [ ] Improve error handling and user feedback (e.g., warning icon or alert when usage fetch fails)
- [ ] Add source health checks when enabling a source
- [ ] Do we need improved handling of my complex AI Sources with multiple usage quotas?
- [ ] Final cleanup and code documentation
