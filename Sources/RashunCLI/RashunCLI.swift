import ArgumentParser
import Foundation
import RashunCore

@main
struct RashunCLI: AsyncParsableCommand {
    @OptionGroup
    var global: GlobalOptions

    static let configuration = CommandConfiguration(
        commandName: "rashun",
        abstract: "AI usage monitor CLI",
        discussion: "Run `rashun --help` to see all commands.",
        subcommands: [
            CheckCommand.self,
            ForecastCommand.self,
            HistoryCommand.self,
            StatusCommand.self,
            SourcesCommand.self,
            UpdateCommand.self,
            VersionCommand.self
        ]
    )

    func run() async throws {
        if global.json {
            struct RootInfo: Encodable {
                let version: String
                let quickStart: [String]
                let sources: [String]
            }

            try JSONOutput.print(RootInfo(
                version: Versioning.versionString(),
                quickStart: [
                    "rashun sources",
                    "rashun check <source>",
                    "rashun status <source>",
                    "rashun status",
                    "rashun --help"
                ],
                sources: allSources.map(\.name)
            ))
            return
        }

        let formatter = OutputFormatter(noColor: global.noColor)
        let sparkle = formatter.emoji("🔮", fallback: "*")
        print("\(sparkle) \(formatter.colorize("Rashun v\(Versioning.versionString())", as: .bold)) -- AI Usage Monitor")
        print("")
        print(formatter.colorize("Quick start:", as: .cyan))
        print("  rashun sources          See available AI sources and setup status")
        print("  rashun check <source>   Verify a source is configured correctly")
        print("  rashun status <source>  Check current usage for a source")
        print("  rashun status           Check usage for all active sources")
        print("  rashun --help           See all commands")
        print("")
        let sourceNames = allSources.map(\.name).joined(separator: ", ")
        print("Supported sources: \(sourceNames)")
    }
}
