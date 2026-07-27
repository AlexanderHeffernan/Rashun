import RashunCore
import XCTest

@testable import Rashun

@MainActor
final class TrackedUsageAppPolicyTests: XCTestCase {
    func testActiveSharedSessionIsSelectedForRecordingWhenAppTrackingToggleIsOff() throws {
        let store = TrackedUsageStore(backend: InMemoryPersistenceBackend())
        let label = try store.createLabel(name: "CLI session")
        let session = try store.startExistingLabel(label.id.uuidString)

        let selected = try trackingSessionForAppRefresh(store: store, trackingEnabled: false)

        XCTAssertEqual(selected?.id, session.id)
    }

    func testStopBoundaryFailureLeavesSessionActive() async throws {
        struct BoundaryFailure: Error {}
        let store = TrackedUsageStore(backend: InMemoryPersistenceBackend())
        let label = try store.createLabel(name: "Work")
        let session = try store.start(label: label)

        do {
            _ = try await stopTrackingSessionAfterBoundary(
                sessionID: session.id, store: store
            ) {
                throw BoundaryFailure()
            }
            XCTFail("Expected the boundary failure to propagate.")
        } catch is BoundaryFailure {
            XCTAssertEqual(try store.readActiveSession()?.id, session.id)
        }
    }
}
