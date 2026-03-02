import XCTest
@testable import Rashun

final class NotificationTests: XCTestCase {

    // MARK: - shouldSendNotification

    func testShouldSend_noState_sends() {
        let event = NotificationEvent(title: "T", body: "B", cooldownSeconds: 3600, cycleKey: nil)
        XCTAssertTrue(shouldSendNotification(event: event, state: nil))
    }

    func testShouldSend_cooldownNotElapsed_suppresses() {
        let event = NotificationEvent(title: "T", body: "B", cooldownSeconds: 3600, cycleKey: nil)
        let state = NotificationRuleState(lastFiredAt: Date(), lastFiredCycleKey: nil)
        XCTAssertFalse(shouldSendNotification(event: event, state: state))
    }

    func testShouldSend_cooldownElapsed_sends() {
        let event = NotificationEvent(title: "T", body: "B", cooldownSeconds: 3600, cycleKey: nil)
        let state = NotificationRuleState(lastFiredAt: Date().addingTimeInterval(-7200), lastFiredCycleKey: nil)
        XCTAssertTrue(shouldSendNotification(event: event, state: state))
    }

    func testShouldSend_matchingCycleKey_suppresses() {
        let event = NotificationEvent(title: "T", body: "B", cooldownSeconds: nil, cycleKey: "2024-01")
        let state = NotificationRuleState(lastFiredAt: nil, lastFiredCycleKey: "2024-01")
        XCTAssertFalse(shouldSendNotification(event: event, state: state))
    }

    func testShouldSend_differentCycleKey_sends() {
        let event = NotificationEvent(title: "T", body: "B", cooldownSeconds: nil, cycleKey: "2024-02")
        let state = NotificationRuleState(lastFiredAt: nil, lastFiredCycleKey: "2024-01")
        XCTAssertTrue(shouldSendNotification(event: event, state: state))
    }

    func testShouldSend_noCooldownNoCycleKey_sends() {
        let event = NotificationEvent(title: "T", body: "B", cooldownSeconds: nil, cycleKey: nil)
        let state = NotificationRuleState(lastFiredAt: Date(), lastFiredCycleKey: nil)
        XCTAssertTrue(shouldSendNotification(event: event, state: state))
    }

    // MARK: - NotificationContext helpers

    func testContextValue_delegatesToClosure() {
        let ctx = NotificationContext(
            sourceName: "Test",
            current: UsageResult(remaining: 50, limit: 100),
            previous: nil,
            history: [],
            inputValue: { id, def in id == "threshold" ? 42 : def }
        )
        XCTAssertEqual(ctx.value(for: "threshold", defaultValue: 10), 42)
        XCTAssertEqual(ctx.value(for: "other", defaultValue: 10), 10)
    }

    func testContextSnapshot_zeroMinutes_returnsNil() {
        let ctx = makeContext(
            history: [snapshot(minutesAgo: 10, remaining: 60)]
        )
        XCTAssertNil(ctx.snapshot(minutesAgo: 0))
    }

    func testContextSnapshot_negativeMinutes_returnsNil() {
        let ctx = makeContext(
            history: [snapshot(minutesAgo: 10, remaining: 60)]
        )
        XCTAssertNil(ctx.snapshot(minutesAgo: -5))
    }

    func testContextSnapshot_findsOldestMatchingSnapshot() {
        let old = snapshot(minutesAgo: 30, remaining: 80)
        let recent = snapshot(minutesAgo: 5, remaining: 60)
        let ctx = makeContext(history: [old, recent])

        // Looking 10 min ago: recent (5 min ago) is too new, should find old (30 min ago)
        let found = ctx.snapshot(minutesAgo: 10)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.usage.remaining, 80)
    }

    func testContextSnapshot_noSnapshotOldEnough_returnsNil() {
        let ctx = makeContext(
            history: [snapshot(minutesAgo: 1, remaining: 60)]
        )
        XCTAssertNil(ctx.snapshot(minutesAgo: 10))
    }

    // MARK: - percentRemainingBelow rule

    func testPercentBelow_firesWhenCrossingThreshold() {
        let rule = genericRule(id: "percentRemainingBelow")
        let ctx = NotificationContext(
            sourceName: "Test",
            current: UsageResult(remaining: 40, limit: 100),
            previous: UsageSnapshot(
                timestamp: Date().addingTimeInterval(-60),
                usage: UsageResult(remaining: 60, limit: 100)
            ),
            history: [],
            inputValue: { id, def in id == "threshold" ? 50 : def }
        )
        let event = rule.evaluate(ctx)
        XCTAssertNotNil(event)
        XCTAssertTrue(event!.title.contains("Test"))
    }

    func testPercentBelow_doesNotFireAboveThreshold() {
        let rule = genericRule(id: "percentRemainingBelow")
        let ctx = NotificationContext(
            sourceName: "Test",
            current: UsageResult(remaining: 60, limit: 100),
            previous: nil,
            history: [],
            inputValue: { id, def in id == "threshold" ? 50 : def }
        )
        XCTAssertNil(rule.evaluate(ctx))
    }

    func testPercentBelow_doesNotReFireWhenAlreadyBelow() {
        let rule = genericRule(id: "percentRemainingBelow")
        let ctx = NotificationContext(
            sourceName: "Test",
            current: UsageResult(remaining: 30, limit: 100),
            previous: UsageSnapshot(
                timestamp: Date().addingTimeInterval(-60),
                usage: UsageResult(remaining: 40, limit: 100)
            ),
            history: [],
            inputValue: { id, def in id == "threshold" ? 50 : def }
        )
        XCTAssertNil(rule.evaluate(ctx))
    }

    func testPercentBelow_firesWithNoPrevious() {
        let rule = genericRule(id: "percentRemainingBelow")
        let ctx = NotificationContext(
            sourceName: "Test",
            current: UsageResult(remaining: 30, limit: 100),
            previous: nil,
            history: [],
            inputValue: { id, def in id == "threshold" ? 50 : def }
        )
        XCTAssertNotNil(rule.evaluate(ctx))
    }

    // MARK: - recentUsageSpike rule

    func testUsageSpike_firesOnLargeDrop() {
        let rule = genericRule(id: "recentUsageSpike")
        let ctx = NotificationContext(
            sourceName: "Test",
            current: UsageResult(remaining: 40, limit: 100),
            previous: nil,
            history: [snapshot(minutesAgo: 30, remaining: 60)],
            inputValue: { id, def in
                if id == "dropPercent" { return 10 }
                if id == "minutes" { return 30 }
                return def
            }
        )
        let event = rule.evaluate(ctx)
        XCTAssertNotNil(event)
        XCTAssertTrue(event!.title.contains("spike"))
    }

    func testUsageSpike_doesNotFireOnSmallDrop() {
        let rule = genericRule(id: "recentUsageSpike")
        let ctx = NotificationContext(
            sourceName: "Test",
            current: UsageResult(remaining: 55, limit: 100),
            previous: nil,
            history: [snapshot(minutesAgo: 30, remaining: 60)],
            inputValue: { id, def in
                if id == "dropPercent" { return 10 }
                if id == "minutes" { return 30 }
                return def
            }
        )
        XCTAssertNil(rule.evaluate(ctx))
    }

    func testUsageSpike_doesNotFireWithNoHistory() {
        let rule = genericRule(id: "recentUsageSpike")
        let ctx = NotificationContext(
            sourceName: "Test",
            current: UsageResult(remaining: 40, limit: 100),
            previous: nil,
            history: [],
            inputValue: { id, def in
                if id == "dropPercent" { return 10 }
                if id == "minutes" { return 30 }
                return def
            }
        )
        XCTAssertNil(rule.evaluate(ctx))
    }

    // MARK: - Helpers

    private func genericRule(id: String) -> NotificationDefinition {
        NotificationDefinitions.generic(sourceName: "Test").first { $0.id == id }!
    }

    private func makeContext(
        remaining: Double = 50,
        limit: Double = 100,
        history: [UsageSnapshot] = []
    ) -> NotificationContext {
        NotificationContext(
            sourceName: "Test",
            current: UsageResult(remaining: remaining, limit: limit),
            previous: nil,
            history: history,
            inputValue: { _, def in def }
        )
    }

    private func snapshot(minutesAgo: Double, remaining: Double) -> UsageSnapshot {
        UsageSnapshot(
            timestamp: Date().addingTimeInterval(-minutesAgo * 60),
            usage: UsageResult(remaining: remaining, limit: 100)
        )
    }
}
