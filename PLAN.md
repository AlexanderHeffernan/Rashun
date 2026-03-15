# Rashun AI Agent Integration — Implementation Plan

## Overview

Enable AI coding agents to automatically monitor their own usage quotas via Rashun. Agents will check their remaining usage before large tasks, use forecast data to reason about whether they can complete the task, and proactively suggest switching to another agent when running low.

**Approach:** A new `rashun setup ai` CLI command that injects a dynamic skill (instruction text) into each agent's global instruction file. No MCP server needed — agents already have terminal access and the existing `rashun` CLI with `--json` output is the perfect agent interface.

**Key principle:** Agent detection is driven by the `AISource` protocol itself. When a new source file is added to `Sources/RashunCore/AISources/`, it can declare its agent integration details (config directory, instruction file path, etc.) via protocol properties. The setup command discovers agents by iterating `allSources` — no separate mapping or wiring needed.

---

## What Gets Built

### 1. AISource Protocol Extensions

Extend the existing `AISource` protocol with optional agent-related properties. Default implementations return `nil`, so existing sources opt-in by overriding:

```swift
extension AISource {
    /// Directory that indicates the agent is installed (e.g. "~/.config/amp").
    /// Return nil if this source has no associated agent.
    var agentConfigDirectory: String? { nil }

    /// Path to the agent's global instruction file where skill text is injected.
    /// Return nil if the agent requires manual setup (e.g. Cursor User Rules).
    var agentInstructionFilePath: String? { nil }

    /// Display name for the agent in CLI output. Defaults to the source name.
    var agentName: String { name }

    /// CLI-friendly lowercase name used in `rashun status <name>` commands within skill text.
    var agentSourceCLIName: String { name.lowercased() }

    /// If true, the agent requires manual setup — print the skill text for the user to copy.
    var agentRequiresManualSetup: Bool { false }
}
```

#### Source-to-Agent Mapping (via protocol properties)

| Source | `agentConfigDirectory` | `agentInstructionFilePath` | `agentName` |
|---|---|---|---|
| AmpSource | `~/.config/amp` | `~/.config/amp/AGENTS.md` | `Amp` |
| CodexSource | `~/.codex` | `~/.codex/AGENTS.md` | `Codex` |
| CopilotSource | `~/.copilot` | `~/.copilot/instructions/rashun.instructions.md` | `Copilot` |
| GeminiSource | `~/.gemini` | `~/.gemini/AGENTS.md` | `Gemini CLI` |

Sources that don't have an associated agent (or future sources that aren't yet mapped) simply leave the defaults as `nil` and are automatically excluded from agent setup.

### 2. `SetupAICommand` — new CLI subcommand (`rashun setup ai`)

An interactive command that:
1. Iterates `allSources` and filters to those with non-nil `agentConfigDirectory`
2. Checks the filesystem to see which agents are actually installed
3. Presents the user with a selectable list of detected agents
4. Injects a **dynamic, per-agent skill snippet** into each selected agent's global instruction file
5. Handles agents that require manual setup by printing the skill text for copy-paste

#### Interactive Flow

```
$ rashun setup ai

🔍 Scanning for AI coding agents...

Found 4 agents installed:

  [•] Amp          ~/.config/amp/AGENTS.md
  [•] Codex        ~/.codex/AGENTS.md
  [•] Gemini CLI   ~/.gemini/AGENTS.md
  [ ] Copilot      ~/.copilot/instructions/rashun.instructions.md

  (space to toggle, enter to confirm)

✅ Added Rashun skill to Amp
✅ Added Rashun skill to Codex
✅ Added Rashun skill to Gemini CLI
⏭️  Skipped Copilot

Done! Your agents will now monitor usage via Rashun.
Run `rashun setup ai --status` to see what's configured.
Run `rashun setup ai --remove` to undo.
```

#### Subcommand Flags

| Flag | Description |
|---|---|
| `--status` | Show which agents currently have the Rashun skill installed |
| `--remove` | Interactive: select which agents to remove the Rashun skill from |
| `--all` | Non-interactive: install to all detected agents |
| `--manual` | Don't write files — output the generated skill text for a selected agent so the user can copy-paste it |
| `--json` | JSON output (consistent with all other commands) |

#### `--remove` Interactive Flow

```
$ rashun setup ai --remove

🔍 Scanning for installed Rashun skills...

Found Rashun skill in 3 agents:

  [•] Amp          ~/.config/amp/AGENTS.md
  [•] Codex        ~/.codex/AGENTS.md
  [ ] Gemini CLI   ~/.gemini/AGENTS.md

  (space to toggle, enter to confirm)

✅ Removed Rashun skill from Amp
✅ Removed Rashun skill from Codex
⏭️  Kept Gemini CLI

Done! Run `rashun setup ai` to re-add.
```

#### `--manual` Flow

```
$ rashun setup ai --manual

🔍 Scanning for AI coding agents...

Found 4 agents installed:

  [1] Amp          ~/.config/amp/AGENTS.md
  [2] Codex        ~/.codex/AGENTS.md
  [3] Gemini CLI   ~/.gemini/AGENTS.md
  [4] Copilot      ~/.copilot/instructions/rashun.instructions.md

Select an agent (1-4): 1

📋 Copy the following into ~/.config/amp/AGENTS.md:

────────────────────────────────────────
<!-- rashun:start -->
## Rashun — AI Usage Monitoring
...
<!-- rashun:end -->
────────────────────────────────────────
```

### 3. Dynamic Per-Agent Skill Text

Each agent gets a tailored instruction snippet generated at setup time. The snippet is wrapped in HTML comment markers for idempotent install/update/removal:

```markdown
<!-- rashun:start -->
<!-- rashun:end -->
```

#### Skill Template

`{agent_name}` and `{source_cli_name}` are replaced per-agent:

```markdown
<!-- rashun:start -->
## Rashun — AI Usage Monitoring

You are {agent_name}, which uses the "{source_name}" quota. This project has
Rashun installed — a CLI tool that tracks your remaining AI usage quota.

### When to check usage
- Before starting a large or multi-step task
- When you sense you've been working for a while and may have used significant quota
- After completing a major task, to inform the user of remaining capacity

### How to check usage
1. Run `rashun status {source_cli_name} --json` to see your current remaining percentage.
2. Run `rashun forecast {source_cli_name} --json` and read the "summary" field to understand
   whether you are projected to run out before your quota resets.

### How to interpret the data
Do NOT use a fixed percentage as a threshold. A source with 20% remaining on a monthly
quota is very different from 20% remaining on a daily quota. Use the forecast summary
to reason about whether you have enough remaining usage to complete the current task.

The forecast summary will tell you one of:
- When the source will reach 100% (regenerating sources like Amp)
- When the source will hit 0% and when it resets (depleting sources like Copilot)
- How much will remain at reset (if usage is sustainable)

### When to warn the user
If the forecast indicates you will run out before the quota resets, or if the remaining
usage looks insufficient for the task at hand:
1. Stop and inform the user of the situation.
2. Offer to save a summary of the current conversation as a markdown file.
3. Run `rashun status --json` (all sources) and show the user which other sources
   have remaining capacity, so they can choose which agent to switch to.
<!-- rashun:end -->
```

---

## Implementation Details

### New Files

| File | Purpose |
|---|---|
| `Sources/RashunCLI/Commands/SetupAICommand.swift` | Main command implementation |
| `Sources/RashunCLI/AgentSetup/AgentDetector.swift` | Detects installed agents by checking `agentConfigDirectory` on each source |
| `Sources/RashunCLI/AgentSetup/SkillGenerator.swift` | Generates per-agent skill text from the template using AISource properties |
| `Sources/RashunCLI/AgentSetup/SkillInstaller.swift` | Reads/writes instruction files, handles markers, idempotency |
| `Sources/RashunCLI/AgentSetup/InteractiveSelector.swift` | Terminal-based interactive checkbox selector |

### Modified Files

| File | Change |
|---|---|
| `Sources/RashunCore/AISources/AISource.swift` | Add agent-related protocol properties with default `nil` implementations |
| `Sources/RashunCore/AISources/AmpSource.swift` | Override `agentConfigDirectory`, `agentInstructionFilePath`, `agentName` |
| `Sources/RashunCore/AISources/CodexSource.swift` | Override `agentConfigDirectory`, `agentInstructionFilePath` |
| `Sources/RashunCore/AISources/CopilotSource.swift` | Override `agentConfigDirectory`, `agentInstructionFilePath` |
| `Sources/RashunCore/AISources/GeminiSource.swift` | Override `agentConfigDirectory`, `agentInstructionFilePath`, `agentName` |
| `Sources/RashunCLI/RashunCLI.swift` | Add `SetupAICommand.self` to subcommands array |
| `Package.swift` | No changes needed — new files are in existing targets |

### No Other Changes to RashunCore

The setup command only generates and writes text files. It reads agent properties from `AISource` and iterates `allSources` to discover available agents, but does not modify any core logic beyond the protocol extension.

---

## Key Design Decisions

### Protocol-Driven Agent Discovery

Agent detection is entirely driven by the `AISource` protocol. To add agent support for a new source, you:
1. Create the new source file in `Sources/RashunCore/AISources/`
2. Override `agentConfigDirectory`, `agentInstructionFilePath`, and optionally `agentName`
3. Run `build.sh` to regenerate `GeneratedSourceList.swift`

That's it. The `SetupAICommand` will automatically pick up the new agent via `allSources`. No separate mapping table, no additional wiring.

### Idempotency via Markers

All injected content is wrapped in `<!-- rashun:start -->` / `<!-- rashun:end -->` HTML comment markers. This enables:
- **`rashun setup ai`** to detect if already installed (skip or update)
- **`rashun setup ai --remove`** to cleanly strip the section
- **Re-running** to update the skill text (e.g., after adding a new source)

Markdown renderers ignore HTML comments, so the markers are invisible in normal viewing.

### Interactive Terminal Selector

The interactive selector uses raw terminal input (not ArgumentParser) to present a checkbox list:
- Arrow keys to navigate
- Space to toggle
- Enter to confirm
- Respects `--no-color` for plain output
- Falls back to numbered list input if stdin is not a TTY (e.g., piped input)

### Manual Mode for Safety

The `--manual` flag lets safety-conscious users see the exact skill text that would be written, without Rashun touching any files. The user selects an agent from a numbered list and gets the generated skill text printed to stdout, ready to copy-paste.

### File Writing Safety

- Create parent directories if they don't exist (e.g., `~/.config/amp/`)
- If the instruction file doesn't exist, create it with just the Rashun section
- If the instruction file exists, append the Rashun section (or replace existing markers)
- Never overwrite or delete content outside the markers
- Back up the original file before first modification (`.bak` extension)

---

## Testing

### Unit Tests

| Test | What it verifies |
|---|---|
| `SkillGeneratorTests` | Template renders correctly for each agent, source names are correct |
| `SkillInstallerTests` | Appends to empty file, appends to existing file, replaces existing markers, remove strips cleanly |
| `AgentDetectorTests` | Detects agents based on `agentConfigDirectory` existence, filters sources without agent config |

### Integration / Smoke Tests

| Test | What it verifies |
|---|---|
| Install to temp dir | Full flow: detect → select → write → verify content |
| Idempotent re-install | Running twice doesn't duplicate the section |
| Remove after install | Content is cleanly removed, rest of file untouched |
| `--status` output | Correctly reports installed/not-installed state |
| `--manual` output | Prints correct skill text without writing files |
| `--json` output | All subcommands produce valid JSON |

### Manual Testing

1. Run `rashun setup ai` and verify skill appears in each agent's config
2. Start an Amp session and confirm it runs `rashun status amp --json` before large tasks
3. Start a Codex session and confirm it uses `rashun status codex --json`
4. Verify `rashun setup ai --remove` interactively removes from selected agents
5. Verify `rashun setup ai --manual` prints skill text without writing files
6. Verify re-running after adding a new source picks up the new agent

---

## Build Order

- [x] **AISource protocol extension** — add agent properties with defaults, update all four existing sources
- [X] **`AgentDetector`** — iterate `allSources`, filter by `agentConfigDirectory`, check filesystem
- [X] **`SkillGenerator`** — template rendering using AISource agent properties
- [X] **`SkillInstaller`** — file read/write with marker-based idempotency
- [ ] **`InteractiveSelector`** — terminal checkbox UI
- [ ] **`SetupAICommand`** — ties it all together as `rashun setup ai`
- [ ] **Register in `RashunCLI.swift`** — add to subcommands
- [ ] **Tests** — unit tests for each component, integration test for full flow
- [ ] **README update** — document the feature
