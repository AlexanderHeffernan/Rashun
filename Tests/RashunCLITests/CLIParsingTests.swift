import ArgumentParser
import XCTest
@testable import RashunCLI

final class CLIParsingTests: XCTestCase {
    func testRootConfigurationIncludesExpectedSubcommands() {
        let names = Set(RashunCLI.configuration.subcommands.map { $0.configuration.commandName })
        XCTAssertEqual(names, ["check", "forecast", "history", "status", "sources", "update", "version"])
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

    func testHistoryCommandDefaultsToShowSubcommand() {
        XCTAssertEqual(HistoryCommand.configuration.defaultSubcommand?.configuration.commandName, "show")
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
