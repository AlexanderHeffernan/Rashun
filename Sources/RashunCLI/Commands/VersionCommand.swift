import ArgumentParser
import Foundation
import RashunCore

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Show current version"
    )

    @OptionGroup
    var global: GlobalOptions

    func run() throws {
        let version = Versioning.versionString()
        if global.json {
            struct VersionResponse: Encodable {
                let version: String
            }
            try JSONOutput.print(VersionResponse(version: version))
            return
        }

        print("Rashun v\(version)")
    }
}
