import Foundation
import XCTest

@testable import RashunCore

#if !os(Linux) && !os(Windows)
    final class PersistenceMigrationSafetyTests: XCTestCase {
        func testFileBackendSerializesTransactionsAcrossInstances() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let first = FilePersistenceBackend(directoryURL: directory)
            let second = FilePersistenceBackend(directoryURL: directory)
            let group = DispatchGroup()

            for backend in [first, second] {
                group.enter()
                DispatchQueue.global().async {
                    for _ in 0..<100 {
                        try! backend.updateData(forKey: "counter") { data in
                            let value =
                                data.flatMap { try? JSONDecoder().decode(Int.self, from: $0) } ?? 0
                            return try? JSONEncoder().encode(value + 1)
                        }
                    }
                    group.leave()
                }
            }

            XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
            let total = try first.data(forKey: "counter").flatMap {
                try? JSONDecoder().decode(Int.self, from: $0)
            }
            XCTAssertEqual(total, 200)
        }

        func testFileBackendDoesNotMutateWhenLockCannotBeOpened() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let backend = FilePersistenceBackend(directoryURL: directory)
            let original = Data("original".utf8)
            try backend.set(original, forKey: "trackedUsage.v1")
            let lockURL = directory.appendingPathComponent("trackedUsage.v1.json.lock")
            try FileManager.default.removeItem(at: lockURL)
            try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)

            XCTAssertThrowsError(
                try backend.updateData(forKey: "trackedUsage.v1") { _ in Data("changed".utf8) }
            ) { error in
                guard case PersistenceBackendError.lockOpenFailed = error else {
                    return XCTFail("Expected lockOpenFailed, got \(error)")
                }
            }
            XCTAssertEqual(try backend.data(forKey: "trackedUsage.v1"), original)
        }

        func testFileBackendDoesNotMutateWhenDirectoryCannotBeCreated() throws {
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: parent) }
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            let blockingFile = parent.appendingPathComponent("not-a-directory")
            try Data("blocking".utf8).write(to: blockingFile)
            let backend = FilePersistenceBackend(
                directoryURL: blockingFile.appendingPathComponent("tracking"))

            XCTAssertThrowsError(try backend.set(Data("changed".utf8), forKey: "shared")) {
                error in
                guard case PersistenceBackendError.directoryCreationFailed = error else {
                    return XCTFail("Expected directoryCreationFailed, got \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: blockingFile), Data("blocking".utf8))
        }

        func testFileBackendWaitsForAnotherProcessLock() throws {
            let python = URL(fileURLWithPath: "/usr/bin/python3")
            guard FileManager.default.isExecutableFile(atPath: python.path) else {
                throw XCTSkip("System Python is unavailable for the subprocess lock test.")
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let backend = FilePersistenceBackend(directoryURL: directory)
            try backend.set(Data("before".utf8), forKey: "shared")
            let lockPath = directory.appendingPathComponent("shared.json.lock").path
            let output = Pipe()
            let process = Process()
            process.executableURL = python
            process.arguments = [
                "-c",
                "import fcntl,sys,time; f=open(sys.argv[1],'r+'); fcntl.flock(f,fcntl.LOCK_EX); print('locked',flush=True); time.sleep(0.5)",
                lockPath,
            ]
            process.standardOutput = output
            try process.run()
            let ready = output.fileHandleForReading.availableData
            XCTAssertTrue(String(decoding: ready, as: UTF8.self).contains("locked"))

            let started = Date()
            try backend.updateData(forKey: "shared") { _ in Data("after".utf8) }
            let elapsed = Date().timeIntervalSince(started)
            process.waitUntilExit()

            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertGreaterThanOrEqual(elapsed, 0.3)
            XCTAssertEqual(try backend.data(forKey: "shared"), Data("after".utf8))
        }

        func testUsageHistoryMigration_prefersLegacyWhenSharedEmpty() {
            MainActor.assumeIsolated {
                let backend = InMemoryPersistenceBackend()
                let legacy = InMemoryPersistenceBackend()

                let snapshots = Self.makeSnapshots(count: 5)
                let payload = try! JSONEncoder().encode(["AMP": snapshots])
                try! legacy.set(payload, forKey: "ai.notificationHistory.v1")

                let store = UsageHistoryStore(backend: backend, legacyBackends: [legacy])
                XCTAssertEqual(store.countSnapshots(), 5)

                let reloaded = UsageHistoryStore(backend: backend, legacyBackends: [legacy])
                XCTAssertEqual(reloaded.countSnapshots(), 5)
            }
        }

        func testUsageHistoryReplaceAllHistory_blocksLargeDataLossWithoutForce() {
            MainActor.assumeIsolated {
                let backend = InMemoryPersistenceBackend()
                let store = UsageHistoryStore(backend: backend)

                let large = ["AMP": Self.makeSnapshots(count: 100)]
                XCTAssertTrue(store.replaceAllHistory(large, force: true))
                XCTAssertEqual(store.countSnapshots(), 100)

                let small = ["AMP": Self.makeSnapshots(count: 1)]
                XCTAssertFalse(store.replaceAllHistory(small))
                XCTAssertEqual(store.countSnapshots(), 100)
                XCTAssertTrue(store.replaceAllHistory(small, force: true))
                XCTAssertEqual(store.countSnapshots(), 1)
            }
        }

        func testSourceHealthMigration_isOneWayAfterMarker() {
            MainActor.assumeIsolated {
                let backend = InMemoryPersistenceBackend()
                let legacy = InMemoryPersistenceBackend()

                let legacyPayload = try! JSONEncoder().encode([
                    "AMP": SourceHealthRecord(consecutiveFailures: 2)
                ])
                try! legacy.set(legacyPayload, forKey: "ai.sourceHealth.v1")

                let store = SourceHealthStore(backend: backend, legacyBackends: [legacy])
                XCTAssertEqual(store.health(for: "AMP")?.consecutiveFailures, 2)

                let newPayload = try! JSONEncoder().encode([
                    "AMP": SourceHealthRecord(consecutiveFailures: 0)
                ])
                try! backend.set(newPayload, forKey: "ai.sourceHealth.v1")

                let reloaded = SourceHealthStore(backend: backend, legacyBackends: [legacy])
                XCTAssertEqual(reloaded.health(for: "AMP")?.consecutiveFailures, 0)
            }
        }

        private static func makeSnapshots(count: Int) -> [UsageSnapshot] {
            let now = Date()
            return (0..<count).map { index in
                UsageSnapshot(
                    timestamp: now.addingTimeInterval(Double(index) * 60),
                    usage: UsageResult(
                        remaining: Double(max(0, 100 - index)),
                        limit: 100,
                        resetDate: now.addingTimeInterval(3600),
                        cycleStartDate: now.addingTimeInterval(-3600)
                    )
                )
            }
        }
    }
#endif
