import RashunCore
import XCTest

@testable import Rashun

@MainActor
final class SettingsStoreNotificationTests: XCTestCase {
    func testSourceNotificationRulesPersistSeparatelyFromMetricRules() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = CodexSource()
        let store = SettingsStore(defaults: defaults)
        store.ensureSourceNotificationRules(source: source)
        store.ensureNotificationRules(
            source: source,
            metricId: "codex-pro-weekly",
            scopeName: "Codex::codex-pro-weekly"
        )

        store.setRuleEnabled(
            true,
            sourceName: source.name,
            ruleId: CodexSource.bankedResetExpiringRuleID
        )
        store.setRuleValue(
            5,
            sourceName: source.name,
            ruleId: CodexSource.bankedResetExpiringRuleID,
            inputId: CodexSource.expirationWarningDaysInputID
        )

        let reloaded = SettingsStore(defaults: defaults)
        let sourceRules = reloaded.ruleSettings(for: source.name)
        let expiryRule = try XCTUnwrap(
            sourceRules.first { $0.ruleId == CodexSource.bankedResetExpiringRuleID })
        XCTAssertTrue(expiryRule.isEnabled)
        XCTAssertEqual(expiryRule.inputValues[CodexSource.expirationWarningDaysInputID], 5)
        XCTAssertFalse(
            reloaded.ruleSettings(for: "Codex::codex-pro-weekly").contains {
                $0.ruleId == CodexSource.bankedResetExpiringRuleID
            })
    }

    func testSourceNotificationDefaultsAreDisabledWithTwoDayExpiryLeadTime() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = CodexSource()
        let store = SettingsStore(defaults: defaults)
        store.ensureSourceNotificationRules(source: source)

        let rules = store.ruleSettings(for: source.name)
        XCTAssertEqual(rules.count, 2)
        XCTAssertTrue(rules.allSatisfy { !$0.isEnabled })
        let expiryRule = try XCTUnwrap(
            rules.first { $0.ruleId == CodexSource.bankedResetExpiringRuleID })
        XCTAssertEqual(expiryRule.inputValues[CodexSource.expirationWarningDaysInputID], 2)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "SettingsStoreNotificationTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}
