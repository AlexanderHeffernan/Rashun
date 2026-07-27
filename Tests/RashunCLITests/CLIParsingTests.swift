import ArgumentParser
import Foundation
import RashunCore
import XCTest

@testable import RashunCLI

@MainActor
final class CLIParsingTests: XCTestCase {
    func testRootConfigurationIncludesExpectedSubcommands() {
        let names = Set(RashunCLI.configuration.subcommands.map { $0.configuration.commandName })
        XCTAssertEqual(
            names,
            [
                "check", "forecast", "history", "setup", "status", "sources", "sync", "update",
                "tracking", "version",
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

    func testTrackingCommandExposesSharedSessionWorkflow() {
        let names = Set(
            TrackingCommand.configuration.subcommands.map { $0.configuration.commandName })
        XCTAssertEqual(names, ["start", "stop", "status", "sessions", "labels"])
        XCTAssertNoThrow(try TrackingCommand.Start.parse(["Work"]))
        XCTAssertThrowsError(try TrackingCommand.Start.parse([]))
    }

    func testTrackingStartIgnoresAppToggleAndStartsThroughCore() async throws {
        let store = TrackedUsageStore(backend: InMemoryPersistenceBackend())
        _ = try store.createLabel(name: "Work")
        TrackingCommandStore.provider = { store }
        defer { TrackingCommandStore.provider = { TrackedUsageStore.shared } }
        let command = try TrackingCommand.Start.parse(["Work"])

        try await command.run()

        XCTAssertEqual(try store.readActiveSession()?.labelNameSnapshot, "Work")
    }

    func testTrackingStartWriteFailureExitsNonzero() async throws {
        let backend = CLIFailingPersistenceBackend()
        let store = TrackedUsageStore(backend: backend)
        _ = try store.createLabel(name: "Work")
        backend.failUpdates = true
        TrackingCommandStore.provider = { store }
        defer { TrackingCommandStore.provider = { TrackedUsageStore.shared } }
        let command = try TrackingCommand.Start.parse(["--json", "Work"])

        await assertExitCode(1) { try await command.run() }
        XCTAssertNil(try store.readActiveSession())
    }

    func testTrackingStopWriteFailureExitsNonzeroAndLeavesSessionActive() async throws {
        let backend = CLIFailingPersistenceBackend()
        let store = TrackedUsageStore(backend: backend)
        _ = try store.createLabel(name: "Work")
        let started = try store.startExistingLabel("Work")
        backend.failUpdates = true
        TrackingCommandStore.provider = { store }
        defer { TrackingCommandStore.provider = { TrackedUsageStore.shared } }
        let command = try TrackingCommand.Stop.parse(["--json"])

        await assertExitCode(1) { try await command.run() }
        XCTAssertEqual(try store.readActiveSession()?.id, started.id)
    }

    func testTrackingReadFailureExitsNonzeroInJSONMode() async throws {
        let store = TrackedUsageStore(
            backend: InMemoryPersistenceBackend(initialStorage: [
                "trackedUsage.v1": Data("invalid".utf8)
            ]))
        TrackingCommandStore.provider = { store }
        defer { TrackingCommandStore.provider = { TrackedUsageStore.shared } }
        let command = try TrackingCommand.Status.parse(["--json"])

        await assertExitCode(1) { try await command.run() }
    }

    func testTrackingFutureSchemaReadExitsNonzeroInJSONMode() async throws {
        let future = Data(
            "{\"schemaVersion\":3,\"labels\":[],\"sessions\":[],\"activeSession\":null,\"deletedLabels\":[],\"deletedSessions\":[]}"
                .utf8)
        let store = TrackedUsageStore(
            backend: InMemoryPersistenceBackend(initialStorage: ["trackedUsage.v1": future]))
        TrackingCommandStore.provider = { store }
        defer { TrackingCommandStore.provider = { TrackedUsageStore.shared } }
        let command = try TrackingCommand.Labels.parse(["--json"])

        await assertExitCode(1) { try await command.run() }
        XCTAssertThrowsError(try store.readLabels())
    }

    func testTrackingPersistenceJSONErrorUsesStableCode() throws {
        let response = TrackingOutput.persistenceResponse(
            error: PersistenceBackendError.writeFailed(path: "tracking", detail: "failed"))
        let data = try JSONOutput.encoder.encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: String])
        XCTAssertEqual(error["code"], "tracking_data_unavailable")
        XCTAssertTrue(try XCTUnwrap(error["detail"]).contains("failed"))
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

private final class CLIFailingPersistenceBackend: PersistenceBackend, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    var failUpdates = false

    func data(forKey key: String) throws -> Data? { storage[key] }

    func set(_ data: Data?, forKey key: String) throws {
        storage[key] = data
    }

    func updateData(forKey key: String, _ update: (Data?) throws -> Data?) throws -> Data? {
        let updated = try update(storage[key])
        if failUpdates {
            throw PersistenceBackendError.writeFailed(path: key, detail: "injected failure")
        }
        storage[key] = updated
        return updated
    }
}
