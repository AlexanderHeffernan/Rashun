<p align="center">
  <img src="icon.jpg" width="128" alt="Rashun app icon" />
</p>

<h1 align="center">Rashun</h1>

<p align="center">
  <strong>A macOS menu bar app that tracks your AI coding tool usage across multiple sources — so you always know where you stand.</strong>
</p>

<p align="center">
  <a href="#quick-install">
    <img src="https://img.shields.io/badge/install-one_command-935AFD?style=for-the-badge" alt="Install" />
  </a>
  <img src="https://img.shields.io/badge/platform-macOS_14%2B-000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/swift-6.2-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift 6.2" />
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-0DE4D1?style=for-the-badge" alt="MIT License" />
  </a>
</p>

---

If you juggle multiple AI coding tools — Amp, GitHub Copilot, Codex, Gemini CLI — keeping track of how much quota you have left across all of them is a pain. You're deep in a project, it's day 22 of the month, and suddenly one of them cuts you off.

Rashun sits in your menu bar, polls each source on a timer, and gives you a single at-a-glance view of your remaining quota. It charts your usage history over time, forecasts when you'll run out, and nudges you with notifications before you hit zero.

### Why I built this

As a student relying on the free tiers of multiple AI coding tools, I kept running into the same problem — burning through one tool's quota without realizing it, then scrambling to figure out which others I had left. I built Rashun so I'd never have to guess again.

```bash
curl -fsSL https://raw.githubusercontent.com/alexanderheffernan/rashun/main/install.sh | bash
```

---

<table>
  <tr>
    <td align="center" width="340">
      <img src="screenshots/menu-bar.png" width="320" alt="Menu bar dropdown showing source usage" />
      <br />
      <sub>Menu bar dropdown</sub>
    </td>
    <td align="center">
      <img src="screenshots/usage-history.png" width="560" alt="Usage History window with chart and forecasts" />
      <br />
      <sub>Usage history with forecasts</sub>
    </td>
  </tr>
  <tr>
    <td align="center" colspan="2">
      <img src="screenshots/preferences.png" width="660" alt="Preferences window — Sources tab" />
      <br />
      <sub>Preferences — Sources & notification rules</sub>
    </td>
  </tr>
</table>

## Features

- **Menu bar at a glance** — Ring icons show remaining quota per metric, with your choice of monochrome or source-branded colors. Display the AI source's logo or the overall remaining usage percentage in the center.
- **Four sources built in** — Ships with support for **Amp Free**, **GitHub Copilot**, **Codex** (tested with free-tier weekly rate limits only), and **Gemini CLI** (with per-model metric tracking for Gemini). Enable whichever ones you use.
- **Usage history & charts** — A dedicated window charts your usage trends over time with selectable ranges (Day, Week, Month, All). Toggle individual sources on and off in the legend.
- **Forecasting** — Each source projects when you'll run out based on your burn rate. Amp models its regenerating quota; Copilot, Codex, and Gemini project against their reset windows. Forecast curves appear as dashed lines on the chart alongside a summary of insights.
- **Smart notifications** — Get alerted when remaining usage drops below a threshold, when you're burning through tokens unusually fast, or when you're on pace to run out before reset. All thresholds are configurable.
- **Source health monitoring** — If a source fails to fetch, Rashun tracks consecutive failures, surfaces actionable error messages, and shows warning indicators in the menu dropdown and Preferences.
- **Auto-updates** — Rashun checks GitHub releases every 6 hours and notifies you when a new version is available. One-click install & restart from the Updates tab in Preferences.
- **Launch at login** — Optionally start Rashun when you sign in to your Mac.
- **Data management** — Export and import usage history as JSON. Delete history by source, date range, or entirely.
- **Configurable polling** — Set how often Rashun checks your usage (default: every 2 minutes).
- **Branded native UI** — A polished dark theme with source logos, card-based layouts, and segmented controls — all built with SwiftUI and AppKit.
- **Extensible by design** — Adding a new AI source is a single Swift file in `Sources/AISources/`. The build script auto-discovers it.

---

## How It Works

Rashun polls each enabled source on a timer. For each source, it fetches current usage data (remaining quota vs. total limit), calculates the percentage remaining, records a snapshot for historical tracking, and updates the menu bar icon. It evaluates notification rules against current and historical data, and generates per-source forecasts that are rendered as dashed projections on the usage chart.

| Source | Metrics | How it fetches data |
|---|---|---|
| **Amp** | Amp Free | Runs `~/.amp/bin/amp usage` and parses `Amp Free: $x/$y remaining` |
| **Copilot** | Premium Interactions | Uses `gh auth token` for authentication, then hits the GitHub Copilot internal API |
| **Codex** | Codex | Extracts the latest usage percentage from `~/.codex/sessions/*.jsonl` session logs |
| **Gemini** | 2.5-Flash, 2.5-Flash-Lite, 2.5-Pro, 3-Flash-Preview, 3-Pro-Preview | Uses local `~/.gemini/oauth_creds.json` auth to call Gemini Code Assist quota APIs and tracks each model's remaining usage independently |

---

## Prerequisites

- **macOS 14+** (Sonoma or later)
- **Swift 6.2+** toolchain (ships with recent Xcode versions) — only needed if building from source

Each source has its own requirements:

| Source | What you need |
|---|---|
| **Amp** | [Amp CLI](https://ampcode.com) installed at `~/.amp/bin/amp` |
| **Copilot** | [GitHub CLI (`gh`)](https://cli.github.com/) installed and authenticated (`gh auth login`) |
| **Codex** | Codex app/CLI installed with local session logs in `~/.codex/sessions` |
| **Gemini** | Gemini CLI installed and authenticated (credentials at `~/.gemini/oauth_creds.json`) |

You only need the prerequisites for the sources you enable — Rashun won't complain about tools you don't use.

---

## Installation

### Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/alexanderheffernan/rashun/main/install.sh | bash
```

This downloads the latest release from GitHub, installs it to `/Applications`, and clears macOS quarantine flags. To update, run the same command again — or use the built-in auto-update from Preferences.

### Build from Source

```bash
git clone https://github.com/alexanderheffernan/rashun.git
cd rashun
chmod +x build.sh
./build.sh --open
```

`build.sh` will:
1. Auto-generate the source registry from `Sources/AISources/`
2. Build a release binary via `swift build`
3. Package it into `Rashun.app` with the app icon and code signing
4. Launch the app (with `--open`)

---

## Usage

Once running, you'll see **ring icons** in your menu bar representing the remaining quota for each selected metric.

1. **Click the menu bar icon** to see a breakdown of remaining usage per source, with progress bars and percentage values.
2. **Open Usage History** to view charts, toggle sources in the legend, and see forecast projections for when each source will run out or reset.
3. **Open Preferences** (`⌘,`) to configure everything:

| Tab | What you can do |
|---|---|
| **General** | Launch at login, set polling interval, customize menu bar appearance (color mode, center content, which metrics to display) |
| **Sources** | Enable/disable sources, view requirements, configure notification rules and thresholds per source and metric |
| **Data** | View stored data stats, export/import usage history as JSON, delete history by source or date range |
| **Updates** | See current version, toggle automatic update checks, check now, and install updates with one click |

### Notification Rules

Each source comes with notification rules you can toggle on:

| Rule | What it does |
|---|---|
| **Percent remaining below** | Fires when remaining usage drops below a threshold (e.g., 50%) |
| **Recent usage spike** | Fires when you burn through a large chunk of quota in a short time window |
| **Pacing alert** | Fires when your current burn rate projects you'll hit 0% before the source resets *(only for sources with reset windows)* |

All thresholds and time windows are configurable in Preferences → Sources.

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
    let metrics = [AISourceMetric(id: "claude", title: "Claude")]

    func fetchUsage(for metricId: String) async throws -> UsageResult {
        // Fetch remaining and total quota however you need to
        return UsageResult(remaining: 80, limit: 100)
    }
}
```

3. **Run `./build.sh`** — it auto-discovers any struct conforming to `AISource` in that directory and registers it. No other wiring needed.

### Optional Overrides

Sources can also customize their behavior by implementing any of these:

| Method | Purpose |
|---|---|
| `mapFetchError(for:_:)` | Provide actionable, source-specific error messages |
| `forecast(for:current:history:)` | Generate forecast projections on the usage chart |
| `pacingLookbackStart(for:)` | Enable pacing alerts with a custom cycle-start resolver |
| `notificationDefinitions(for:)` | Define custom notification rules |
| `menuBarBrandColorHex` | Set the source's brand color for colored menu bar rings |

---

## Project Structure

```
Sources/
├── App.swift                          # Entry point, menu bar setup, polling loop
├── GeneratedSourceList.swift          # Auto-generated source registry (build.sh)
├── AISources/
│   ├── AISource.swift                 # AISource protocol & default implementations
│   ├── AISourceModels.swift           # UsageResult, AISourceMetric, error types
│   ├── AmpSource.swift                # Amp Free usage fetcher
│   ├── CopilotSource.swift            # GitHub Copilot usage fetcher
│   ├── CodexSource.swift              # Codex session log parser
│   └── GeminiSource.swift             # Gemini CLI multi-model usage fetcher
├── Forecasting/
│   ├── ForecastModels.swift           # ForecastPoint, ForecastResult types
│   └── LinearRegression.swift         # Burn-rate regression for projections
├── Health/
│   └── SourceHealthStore.swift        # Tracks fetch success/failure per source
├── Notifications/
│   ├── NotificationModels.swift       # Core types (rules, events, contexts)
│   ├── NotificationDefinitions.swift  # Generic rules (threshold, spike, pacing)
│   ├── NotificationManager.swift      # macOS notification delivery & routing
│   └── NotificationHistoryStore.swift # Usage history for rule evaluation
├── Preferences/
│   ├── PreferencesRootView.swift      # Root settings view with tab bar
│   ├── PreferencesViewModel.swift     # Settings view model
│   ├── PreferencesWindowController.swift
│   ├── SettingsStore.swift            # Persistent settings (UserDefaults)
│   ├── DataManagement.swift           # Import/export/delete logic
│   ├── DataTabViewModel.swift         # Data tab view model
│   ├── Tabs/                          # General, Sources, Data, Updates tabs
│   └── Components/                    # Reusable Preferences UI components
├── UI/
│   ├── BrandTheme.swift               # Color palette and extensions
│   ├── BrandCard.swift                # Card container component
│   ├── BrandControls.swift            # Segmented controls, toggles, buttons
│   └── MenuBarAppearance.swift        # Menu bar color/content mode models
├── Update/
│   └── UpdateManager.swift            # GitHub release checker, in-app updater
├── UsageHistory/
│   ├── UsageHistoryRootView.swift     # Usage History window with chart & insights
│   ├── UsageHistoryViewModel.swift    # Chart data, series visibility, forecasts
│   ├── UsageChartView.swift           # Chart rendering
│   ├── UsageChartRepresentable.swift  # AppKit ↔ SwiftUI bridge for charts
│   ├── UsageHistoryModels.swift       # Snapshot, series, chart data types
│   └── ChartTimeRange.swift           # Time range enum (1h, 6h, 1d, 7d, 30d)
├── Views/
│   ├── MenuDropdownViews.swift        # Source cards in the menu dropdown
│   ├── ChartWindowController.swift    # Usage History window controller
│   └── RefreshButton.swift            # Hoverable refresh button
└── Resources/
    └── SourceLogos/                   # Amp, Copilot, Codex, Gemini logos
```

---

## CI/CD

Rashun uses GitHub Actions for continuous integration and automated releases:

- **Tests** — Runs on every push and PR to `main`. Generates the source list, runs `swift test`, builds the app bundle, and performs a smoke test (launches the app for 6 seconds, checks for crashes).
- **Release** — Triggers automatically when tests pass on `main`. Determines the version (auto-bumps patch, or uses a manual bump from `Info.plist`), stamps it, builds, smoke tests, zips the app, and creates a GitHub release with the install command.

---

## Contributing

Contributions are welcome — whether it's a new AI source, a new notification rule, a bug fix, or a UI improvement.

1. Fork the repo
2. Create a feature branch (`git checkout -b my-new-source`)
3. Make your changes
4. Test by running `./build.sh --test && swift test` and then `./build.sh --open` to verify the app works
5. Open a pull request

Some ideas for contributions:
- New AI sources (Claude, ChatGPT, Cursor, Windsurf, etc.)
- New notification rule types
- Additional forecast models
- UI improvements and accessibility

---

## License

This project is licensed under the [MIT License](LICENSE).
