import XCTest
@testable import RashunCore

final class UsageSampleStabilityGateTests: XCTestCase {
    func testSuspiciousQuotaJumpIsWithheldUntilMatchingSecondSample() {
        var gate = UsageSampleStabilityGate()
        let oldReset = Date(timeIntervalSince1970: 1_700_000_000)
        let newReset = oldReset.addingTimeInterval(7 * 24 * 3600)
        let previous = UsageResult(remaining: 30, limit: 100, resetDate: oldReset)
        let reset = UsageResult(remaining: 100, limit: 100, resetDate: newReset)

        XCTAssertNil(gate.verifiedUsage(scope: "Codex::weekly", incoming: reset, previousAccepted: previous))
        let confirmed = gate.verifiedUsage(scope: "Codex::weekly", incoming: reset, previousAccepted: previous)
        XCTAssertEqual(confirmed?.usage.remaining, 100)
        XCTAssertEqual(confirmed?.previousAccepted.remaining, 30)
        XCTAssertTrue(confirmed?.wasConfirmed == true)
    }

    func testCorrectedQuotaJumpIsDiscardedAndNormalSampleIsAccepted() {
        var gate = UsageSampleStabilityGate()
        let oldReset = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = UsageResult(remaining: 30, limit: 100, resetDate: oldReset)
        let misfire = UsageResult(remaining: 100, limit: 100, resetDate: oldReset.addingTimeInterval(7 * 24 * 3600))
        let corrected = UsageResult(remaining: 28, limit: 100, resetDate: oldReset)

        XCTAssertNil(gate.verifiedUsage(scope: "Codex::weekly", incoming: misfire, previousAccepted: previous))
        XCTAssertEqual(gate.verifiedUsage(scope: "Codex::weekly", incoming: corrected, previousAccepted: previous)?.usage.remaining, 28)
    }

    func testConfirmedResetRetainsEvidenceWhenUsageDropsSlightlyBeforeSecondPoll() {
        var gate = UsageSampleStabilityGate()
        let oldReset = Date(timeIntervalSince1970: 1_700_000_000)
        let newReset = oldReset.addingTimeInterval(7 * 24 * 3600)
        let previous = UsageResult(remaining: 30, limit: 100, resetDate: oldReset)
        let reset = UsageResult(remaining: 100, limit: 100, resetDate: newReset)
        let postResetUsage = UsageResult(remaining: 92, limit: 100, resetDate: newReset)

        XCTAssertNil(gate.verifiedUsage(scope: "Codex::weekly", incoming: reset, previousAccepted: previous))

        let confirmed = gate.verifiedUsage(
            scope: "Codex::weekly",
            incoming: postResetUsage,
            previousAccepted: previous
        )
        XCTAssertEqual(confirmed?.usage.remaining, 92)
        XCTAssertEqual(confirmed?.previousAccepted.remaining, 30)
        XCTAssertEqual(confirmed?.confirmedResetUsage?.remaining, 100)
        XCTAssertTrue(confirmed?.wasConfirmed == true)
    }

    func testConfirmationAllowsSmallResetDateRevision() {
        var gate = UsageSampleStabilityGate()
        let oldReset = Date(timeIntervalSince1970: 1_700_000_000)
        let newReset = oldReset.addingTimeInterval(7 * 24 * 3600)
        let previous = UsageResult(remaining: 30, limit: 100, resetDate: oldReset)
        let reset = UsageResult(remaining: 100, limit: 100, resetDate: newReset)
        let revised = UsageResult(remaining: 97, limit: 100, resetDate: newReset.addingTimeInterval(30))

        XCTAssertNil(gate.verifiedUsage(scope: "Codex::weekly", incoming: reset, previousAccepted: previous))
        XCTAssertTrue(
            gate.verifiedUsage(scope: "Codex::weekly", incoming: revised, previousAccepted: previous)?.wasConfirmed == true
        )
    }

    func testConfirmationRejectsLowQuotaEvenWhenResetDateMatches() {
        var gate = UsageSampleStabilityGate()
        let oldReset = Date(timeIntervalSince1970: 1_700_000_000)
        let newReset = oldReset.addingTimeInterval(7 * 24 * 3600)
        let previous = UsageResult(remaining: 62, limit: 100, resetDate: oldReset)
        let candidate = UsageResult(remaining: 99, limit: 100, resetDate: newReset)
        let corrected = UsageResult(remaining: 62, limit: 100, resetDate: newReset)

        XCTAssertNil(gate.verifiedUsage(scope: "Codex::weekly", incoming: candidate, previousAccepted: previous))

        let result = gate.verifiedUsage(scope: "Codex::weekly", incoming: corrected, previousAccepted: previous)
        XCTAssertEqual(result?.usage.remaining, 62)
        XCTAssertFalse(result?.wasConfirmed == true)
        XCTAssertNil(result?.confirmedResetUsage)
    }

    func testConfirmsAnEarlyResetWhenResetWindowOnlyMovesBySeconds() {
        var gate = UsageSampleStabilityGate()
        let cycleStart = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = cycleStart.addingTimeInterval(5 * 3600)
        let previous = UsageResult(remaining: 27, limit: 100, resetDate: reset, cycleStartDate: cycleStart)
        let falseReset = UsageResult(
            remaining: 94,
            limit: 100,
            resetDate: reset.addingTimeInterval(178),
            cycleStartDate: cycleStart.addingTimeInterval(178)
        )

        XCTAssertNil(gate.verifiedUsage(scope: "Codex::5h", incoming: falseReset, previousAccepted: previous))
        XCTAssertTrue(
            gate.verifiedUsage(scope: "Codex::5h", incoming: falseReset, previousAccepted: previous)?.wasConfirmed == true
        )
    }
}
