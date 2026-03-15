import ArgumentParser
import Foundation
import RashunCore

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Configure Rashun integrations",
        subcommands: [SetupAICommand.self],
        defaultSubcommand: SetupAICommand.self
    )
}

struct SetupAICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ai",
        abstract: "Install the Rashun skill into AI agent configuration files"
    )

    @OptionGroup
    var global: GlobalOptions

    @Flag(name: .long, help: "Show which agents currently have the Rashun skill installed")
    var status = false

    @Flag(name: .long, help: "Interactively select which agents to remove the Rashun skill from")
    var remove = false

    @Flag(name: .long, help: "Install to all detected agents (non-interactive)")
    var all = false

    @Flag(name: .long, help: "Output the generated skill text instead of writing files")
    var manual = false

    func validate() throws {
        let flagCount = [status, remove, all, manual].filter { $0 }.count
        if flagCount > 1 {
            throw ValidationError("Only one of --status, --remove, --all, or --manual may be specified.")
        }
    }

    @MainActor
    func run() async throws {
        if status {
            try runStatus()
        } else if remove {
            try runRemove()
        } else if all {
            try runAll()
        } else if manual {
            try runManual()
        } else if global.json {
            try runAll()
        } else {
            try runInteractiveInstall()
        }
    }

    // MARK: - Status

    @MainActor
    private func runStatus() throws {
        let agents = AgentDetector.detectAll()

        if global.json {
            try JSONOutput.print(StatusResponse(agents: agents.map { agent in
                AgentStatusEntry(
                    name: agent.source.name,
                    skillInstalled: SkillInstaller.isInstalled(for: agent.source),
                    instructionFile: agent.instructionFilePath
                )
            }))
            return
        }

        let formatter = OutputFormatter(noColor: global.noColor)
        print("\(formatter.emoji("🔍", fallback: "*")) \(formatter.colorize("Rashun Skill Status", as: .bold))")
        print("")

        if agents.isEmpty {
            print("No supported agents detected.")
            return
        }

        for agent in agents {
            let installed = SkillInstaller.isInstalled(for: agent.source)
            let statusText: String
            let symbol: String
            if agent.source.agentRequiresManualSetup {
                statusText = formatter.colorize("manual setup required", as: .yellow)
                symbol = formatter.emoji("✋", fallback: "[manual]")
            } else if installed {
                statusText = formatter.colorize("installed", as: .green)
                symbol = formatter.emoji("✅", fallback: "[ok]")
            } else {
                statusText = "not installed"
                symbol = formatter.emoji("⏭️", fallback: "[-]")
            }
            let path = agent.instructionFilePath ?? "n/a"
            print("  \(symbol) \(formatter.colorize(agent.source.name, as: .bold))  \(statusText)  \(formatter.colorize(path, as: .cyan))")
        }
    }

    // MARK: - Remove

    @MainActor
    private func runRemove() throws {
        let agents = AgentDetector.detectAll()
        let withSkill = agents.filter { SkillInstaller.isInstalled(for: $0.source) }

        if withSkill.isEmpty {
            if global.json {
                try JSONOutput.print(ResultsResponse(results: []))
                return
            }
            let formatter = OutputFormatter(noColor: global.noColor)
            print("\(formatter.emoji("⏭️", fallback: "[-]")) No agents have the Rashun skill installed.")
            return
        }

        if global.json {
            var results: [ActionResult] = []
            for agent in withSkill {
                let result = try SkillInstaller.remove(for: agent.source)
                results.append(ActionResult(
                    name: agent.source.name,
                    action: result == .removed ? "removed" : "skipped"
                ))
            }
            try JSONOutput.print(ResultsResponse(results: results))
            return
        }

        let formatter = OutputFormatter(noColor: global.noColor)

        var items = withSkill.map { agent in
            SelectableItem(
                label: agent.source.name,
                detail: agent.instructionFilePath ?? "",
                isSelected: true
            )
        }

        print("\(formatter.colorize("Select agents to remove the Rashun skill from:", as: .bold))")
        print("")

        guard let selectedIndices = InteractiveSelector.select(
            items: &items,
            prompt: "(↑/↓ to move, space to toggle, enter to confirm)",
            formatter: formatter
        ) else {
            print("Cancelled.")
            return
        }

        print("")

        for (index, agent) in withSkill.enumerated() {
            if selectedIndices.contains(index) {
                let result = try SkillInstaller.remove(for: agent.source)
                switch result {
                case .removed:
                    print("  \(formatter.emoji("✅", fallback: "[ok]")) \(formatter.colorize(agent.source.name, as: .bold))  removed")
                case .notInstalled:
                    print("  \(formatter.emoji("⏭️", fallback: "[-]")) \(formatter.colorize(agent.source.name, as: .bold))  was not installed")
                }
            } else {
                print("  \(formatter.emoji("⏭️", fallback: "[-]")) \(formatter.colorize(agent.source.name, as: .bold))  kept")
            }
        }
    }

    // MARK: - All (non-interactive install)

    @MainActor
    private func runAll() throws {
        let agents = AgentDetector.detectInstalled()
        let manualAgents = agents.filter { $0.source.agentRequiresManualSetup }
        let autoAgents = agents.filter { !$0.source.agentRequiresManualSetup }

        if agents.isEmpty {
            if global.json {
                try JSONOutput.print(ResultsResponse(results: []))
                return
            }
            let formatter = OutputFormatter(noColor: global.noColor)
            print("\(formatter.emoji("⏭️", fallback: "[-]")) No installed agents detected.")
            return
        }

        var results: [ActionResult] = []
        let formatter = global.json ? nil : OutputFormatter(noColor: global.noColor)

        for agent in autoAgents {
            let result = try SkillInstaller.install(for: agent.source)
            let action: String
            switch result {
            case .installed:
                action = "installed"
            case .updated:
                action = "updated"
            }
            results.append(ActionResult(name: agent.source.name, action: action))

            if let formatter {
                print("  \(formatter.emoji("✅", fallback: "[ok]")) \(formatter.colorize(agent.source.name, as: .bold))  \(action)  \(formatter.colorize(agent.instructionFilePath ?? "", as: .cyan))")
            }
        }

        for agent in manualAgents {
            results.append(ActionResult(name: agent.source.name, action: "manual"))
            if let formatter {
                print("  \(formatter.emoji("✋", fallback: "[manual]")) \(formatter.colorize(agent.source.name, as: .bold))  manual setup required")
            }
        }

        if global.json {
            try JSONOutput.print(ResultsResponse(results: results))
        } else if let formatter {
            print("")
            print("\(formatter.emoji("✅", fallback: "[ok]")) Done. Run \(formatter.colorize("rashun setup ai --status", as: .cyan)) to verify.")
        }
    }

    // MARK: - Manual

    @MainActor
    private func runManual() throws {
        let agents = AgentDetector.detectInstalled()

        if agents.isEmpty {
            if global.json {
                try emitErrorAndExit(
                    code: "no_agents",
                    short: "No agents detected",
                    detail: "No installed agents were detected. Install an agent first.",
                    exitCode: 1
                )
            } else {
                let formatter = OutputFormatter(noColor: global.noColor)
                print("\(formatter.emoji("⏭️", fallback: "[-]")) No installed agents detected.")
            }
            return
        }

        if global.json {
            let agent = agents[0]
            let skillText = SkillGenerator.generate(for: agent.source)
            try JSONOutput.print(ManualResponse(agent: agent.source.name, skillText: skillText))
            return
        }

        let formatter = OutputFormatter(noColor: global.noColor)

        print("\(formatter.colorize("Select an agent:", as: .bold))")
        print("")
        for (index, agent) in agents.enumerated() {
            print("  \(index + 1). \(agent.source.name)  \(formatter.colorize(agent.instructionFilePath ?? "", as: .cyan))")
        }
        print("")
        print("Enter number: ", terminator: "")
        fflush(stdout)

        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              let choice = Int(input),
              choice >= 1, choice <= agents.count else {
            print("Invalid selection.")
            return
        }

        let agent = agents[choice - 1]
        let skillText = SkillGenerator.generate(for: agent.source)

        print("")
        print(formatter.colorize("─── Skill text for \(agent.source.name) ───", as: .bold))
        print("")
        print(skillText)
        print("")
        print(formatter.colorize("─── End ───", as: .bold))
        print("")
        print("Copy the text above into \(formatter.colorize(agent.instructionFilePath ?? "your agent's instruction file", as: .cyan)).")
    }

    // MARK: - Interactive Install (default)

    @MainActor
    private func runInteractiveInstall() throws {
        let allAgents = AgentDetector.detectAll()

        if allAgents.isEmpty {
            let formatter = OutputFormatter(noColor: global.noColor)
            print("\(formatter.emoji("⏭️", fallback: "[-]")) No supported agents detected.")
            return
        }

        let installedAgents = allAgents.filter(\.isInstalled)
        let manualAgents = installedAgents.filter { $0.source.agentRequiresManualSetup }
        let autoAgents = installedAgents.filter { !$0.source.agentRequiresManualSetup }

        if installedAgents.isEmpty {
            let formatter = OutputFormatter(noColor: global.noColor)
            print("\(formatter.emoji("⏭️", fallback: "[-]")) No installed agents detected.")
            print("")
            print("The following agents could be set up once installed:")
            for agent in allAgents {
                print("  • \(agent.source.name)  \(formatter.colorize(agent.configDirectory, as: .cyan))")
            }
            return
        }

        let formatter = OutputFormatter(noColor: global.noColor)

        print("\(formatter.emoji("🔍", fallback: "*")) \(formatter.colorize("Rashun Skill Installer", as: .bold))")
        print("")
        print("Select agents to install the Rashun skill to:")
        print(formatter.colorize("Note: agents already configured will be updated.", as: .cyan))
        if !manualAgents.isEmpty {
            let names = manualAgents.map { $0.source.name }.joined(separator: ", ")
            print(formatter.colorize("Manual setup required for: \(names). Run `rashun setup ai --manual`.", as: .cyan))
        }
        print("")

        if autoAgents.isEmpty {
            print("\(formatter.emoji("✋", fallback: "[manual]")) No auto-installable agents detected.")
            return
        }

        var items = autoAgents.map { agent in
            let alreadyInstalled = SkillInstaller.isInstalled(for: agent.source)
            let statusNote = alreadyInstalled ? " (already configured)" : ""
            return SelectableItem(
                label: agent.source.name,
                detail: (agent.instructionFilePath ?? "") + statusNote,
                isSelected: true
            )
        }

        guard let selectedIndices = InteractiveSelector.select(
            items: &items,
            prompt: "(↑/↓ to move, space to toggle, enter to confirm)",
            formatter: formatter
        ) else {
            print("Cancelled.")
            return
        }

        print("")

        for (index, agent) in autoAgents.enumerated() {
            if selectedIndices.contains(index) {
                let result = try SkillInstaller.install(for: agent.source)
                let action: String
                switch result {
                case .installed:
                    action = "installed"
                case .updated:
                    action = "updated"
                }
                print("  \(formatter.emoji("✅", fallback: "[ok]")) \(formatter.colorize(agent.source.name, as: .bold))  \(action)  \(formatter.colorize(agent.instructionFilePath ?? "", as: .cyan))")
            } else {
                print("  \(formatter.emoji("⏭️", fallback: "[-]")) \(formatter.colorize(agent.source.name, as: .bold))  skipped")
            }
        }

        print("")
        print("\(formatter.emoji("✅", fallback: "[ok]")) Done!")
        print("  Run \(formatter.colorize("rashun setup ai --status", as: .cyan)) to check installation status.")
        print("  Run \(formatter.colorize("rashun setup ai --remove", as: .cyan)) to uninstall from specific agents.")
    }

    // MARK: - Helpers

    private func emitErrorAndExit(code: String, short: String, detail: String, exitCode: Int32) throws {
        if global.json {
            try JSONOutput.print(JSONErrorEnvelope(error: SetupErrorStatus(code: code, short: short, detail: detail)))
        } else {
            let formatter = OutputFormatter(noColor: global.noColor)
            print("\(formatter.emoji("❌", fallback: "[x]")) \(formatter.colorize(short, as: .yellow))")
            print(detail)
        }
        throw ExitCode(exitCode)
    }
}

// MARK: - JSON Response Types

private struct StatusResponse: Encodable {
    let agents: [AgentStatusEntry]
}

private struct AgentStatusEntry: Encodable {
    let name: String
    let skillInstalled: Bool
    let instructionFile: String?
}

private struct ResultsResponse: Encodable {
    let results: [ActionResult]
}

private struct ActionResult: Encodable {
    let name: String
    let action: String
}

private struct ManualResponse: Encodable {
    let agent: String
    let skillText: String
}

private struct JSONErrorEnvelope: Encodable {
    let error: SetupErrorStatus
}

private struct SetupErrorStatus: Encodable {
    let code: String
    let short: String
    let detail: String
}
