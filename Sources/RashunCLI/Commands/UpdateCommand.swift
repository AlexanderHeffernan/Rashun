import ArgumentParser
import Foundation
import RashunCore

struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check for updates and optionally install"
    )

    @OptionGroup
    var global: GlobalOptions

    @Flag(name: .long, help: "Check for updates only")
    var check = false

    @Flag(name: .long, help: "Install latest update if available")
    var install = false

    private static let repository = "alexanderheffernan/rashun"

    @MainActor
    func run() async throws {
        if check && install {
            try emitErrorAndExit(
                code: "invalid_argument",
                short: "Invalid update flags",
                detail: "Use either --check or --install, not both.",
                exitCode: 2
            )
            return
        }

        let mode: UpdateMode = install ? .install : .check
        let service = UpdateCheckService(
            repository: Self.repository,
            currentVersionProvider: { Versioning.versionString() }
        )

        if !global.json {
            let formatter = OutputFormatter(noColor: global.noColor)
            print("\(formatter.emoji("🔄", fallback: "*")) Checking for updates...")
        }

        let hasNew = await service.checkForUpdate()
        let current = Versioning.versionString()
        let available = service.availableVersion

        if mode == .check {
            if global.json {
                try JSONOutput.print(UpdateCheckResponse(
                    currentVersion: current,
                    availableVersion: available,
                    updateAvailable: hasNew,
                    installed: false
                ))
                return
            }

            if hasNew, let available {
                let formatter = OutputFormatter(noColor: global.noColor)
                print("\(formatter.emoji("✅", fallback: "[ok]")) Update available: v\(available) (current: v\(current))")
                print("Run `rashun update --install` to update now.")
            } else {
                let formatter = OutputFormatter(noColor: global.noColor)
                print("\(formatter.emoji("✅", fallback: "[ok]")) Rashun v\(current) is up to date.")
            }
            return
        }

        guard hasNew else {
            if global.json {
                try JSONOutput.print(UpdateCheckResponse(
                    currentVersion: current,
                    availableVersion: available,
                    updateAvailable: false,
                    installed: false
                ))
            } else {
                let formatter = OutputFormatter(noColor: global.noColor)
                print("\(formatter.emoji("✅", fallback: "[ok]")) Rashun v\(current) is up to date.")
            }
            return
        }

        do {
            try CLIShellUpdateInstaller().installUpdate(from: Self.repository)
            if global.json {
                try JSONOutput.print(UpdateCheckResponse(
                    currentVersion: current,
                    availableVersion: available,
                    updateAvailable: true,
                    installed: true
                ))
                return
            }

            let formatter = OutputFormatter(noColor: global.noColor)
            if let available {
                print("\(formatter.emoji("✅", fallback: "[ok]")) Updated to v\(available). Restart your terminal session.")
            } else {
                print("\(formatter.emoji("✅", fallback: "[ok]")) Update installed. Restart your terminal session.")
            }
        } catch {
            try emitErrorAndExit(
                code: "install_failed",
                short: "Update install failed",
                detail: error.localizedDescription,
                exitCode: 1
            )
        }
    }

    private func emitErrorAndExit(code: String, short: String, detail: String, exitCode: Int32) throws {
        if global.json {
            try JSONOutput.print(JSONUpdateErrorEnvelope(error: JSONUpdateError(code: code, short: short, detail: detail)))
        } else {
            let formatter = OutputFormatter(noColor: global.noColor)
            print("\(formatter.emoji("❌", fallback: "[x]")) \(formatter.colorize(short, as: .yellow))")
            print(detail)
        }
        throw ExitCode(exitCode)
    }
}

@MainActor
private struct CLIShellUpdateInstaller: UpdateInstaller {
    func installUpdate(from repository: String) throws {
        #if os(Windows)
        throw UpdateInstallError.unsupportedPlatform
        #else
        let installURL = "https://raw.githubusercontent.com/\(repository)/main/install.sh"
        let script = "curl -fsSL \(installURL) | bash -s -- --update"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw UpdateInstallError.nonZeroExit(code: process.terminationStatus)
        }
        #endif
    }
}

private enum UpdateMode {
    case check
    case install
}

private enum UpdateInstallError: LocalizedError {
    case unsupportedPlatform
    case nonZeroExit(code: Int32)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Automatic install is not supported on this platform yet."
        case let .nonZeroExit(code):
            return "Installer exited with status \(code)."
        }
    }
}

private struct UpdateCheckResponse: Encodable {
    let currentVersion: String
    let availableVersion: String?
    let updateAvailable: Bool
    let installed: Bool
}

private struct JSONUpdateErrorEnvelope: Encodable {
    let error: JSONUpdateError
}

private struct JSONUpdateError: Encodable {
    let code: String
    let short: String
    let detail: String
}
