import ArgumentParser
import XCTest

@testable import RashunCLI

final class CLIParsingTests: XCTestCase {
    func testRootConfigurationIncludesExpectedSubcommands() {
        let names = Set(RashunCLI.configuration.subcommands.map { $0.configuration.commandName })
        XCTAssertEqual(
            names,
            [
                "check", "forecast", "history", "setup", "status", "sources", "sync", "update",
                "version",
            ])
    }

    func testRootParseAcceptsGlobalFlags() throws {
        let command = try RashunCLI.parse(["--json", "--no-color"])
        XCTAssertTrue(command.global.json)
        XCTAssertTrue(command.global.noColor)
    }

    func testCheckCommandRequiresSourceArgument() {
        XCTAssertThrowsError(try CheckCommand.parse([]))
    }

    func testStatusCommandParsesOptionalSourceAndMetric() throws {
        let command = try StatusCommand.parse(["Codex", "--metric", "requests"])
        XCTAssertEqual(command.sourceName, "Codex")
        XCTAssertEqual(command.metric, "requests")
    }

    func testSyncCommandExposesSimpleDeviceWorkflow() {
        let names = Set(SyncCommand.configuration.subcommands.map { $0.configuration.commandName })
        XCTAssertEqual(names, ["connect", "devices", "pair", "remove", "serve", "sync-now"])
    }

    func testSyncConnectParsesPrintedCommand() throws {
        let command = try SyncCommand.Connect.parse(
            ["http://192.168.1.20:8787", "ABCD-2345"])
        XCTAssertEqual(command.address, "http://192.168.1.20:8787")
        XCTAssertEqual(command.code, "ABCD-2345")
        XCTAssertEqual(command.port, 8787)
    }

    func testSyncServeDefaultsToCrossPlatformLANEndpoint() throws {
        let command = try SyncCommand.Serve.parse([])
        XCTAssertEqual(command.host, "0.0.0.0")
        XCTAssertEqual(command.port, 8787)
        XCTAssertFalse(command.noPairingCode)
    }

    func testHistoryCommandDefaultsToShowSubcommand() {
        XCTAssertEqual(
            HistoryCommand.configuration.defaultSubcommand?.configuration.commandName, "show")
    }

    func testSourceResolverIsCaseInsensitiveForKnownSource() {
        XCTAssertNotNil(SourceResolver.resolve("codex"))
    }

    func testSourceResolverReturnsNilForUnknownSource() {
        XCTAssertNil(SourceResolver.resolve("not-a-real-source"))
    }

    func testHistoryClearJsonWithoutYesExitsWithConfirmationRequired() async {
        let command = try? HistoryClearCommand.parse(["--json"])
        XCTAssertNotNil(command)
        await assertExitCode(4) {
            try await command?.run()
        }
    }

    func testUpdateRejectsCheckAndInstallTogether() async throws {
        let command = try UpdateCommand.parse(["--check", "--install"])
        await assertExitCode(2) {
            try await command.run()
        }
    }

    func testStatusUnknownSourceExitsWithUserError() async throws {
        let command = try StatusCommand.parse(["--json", "not-a-real-source"])
        await assertExitCode(2) {
            try await command.run()
        }
    }

    func testCheckUnknownSourceExitsWithUserError() async throws {
        let command = try CheckCommand.parse(["--json", "not-a-real-source"])
        await assertExitCode(2) {
            try await command.run()
        }
    }

    func testForecastUnknownSourceExitsWithUserError() async throws {
        let command = try ForecastCommand.parse(["--json", "not-a-real-source"])
        await assertExitCode(2) {
            try await command.run()
        }
    }

    func testHistoryShowRejectsNonPositiveLimit() async throws {
        let command = try HistoryShowCommand.parse(["--json", "Codex", "--limit", "0"])
        await assertExitCode(2) {
            try await command.run()
        }
    }

    func testHistoryClearRejectsNonPositiveOlderThan() async throws {
        let command = try HistoryClearCommand.parse(["--json", "--older-than", "0"])
        await assertExitCode(2) {
            try await command.run()
        }
    }

    private func assertExitCode(_ expected: Int32, operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected ExitCode(\(expected))")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit.rawValue, expected)
        } catch {
            XCTFail("Expected ExitCode(\(expected)), got: \(error)")
        }
    }
}
