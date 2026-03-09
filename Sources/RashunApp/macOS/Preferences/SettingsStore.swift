import Foundation
import RashunCore

@MainActor
final class SettingsStore {
    static let shared = SettingsStore()
    private init() { load() }

    private let userDefaultsKey = "ai.sourceSettings.v1"
    private let sourceMetricSettingsKey = "ai.sourceMetricSettings.v1"
    private let notificationDefaultsKey = "ai.notificationSettings.v1"
    private let notificationStateKey = "ai.notificationState.v1"
    private let pollIntervalKey = "ai.pollIntervalSeconds.v1"
    private let autoUpdateCheckKey = "ai.autoUpdateCheck.v1"
    private let menuBarAppearanceKey = "ai.menuBarAppearance.v1"
    private var enabledMap: [String: Bool] = [:]
    private var sourceMetricEnabledMap: [String: [String: Bool]] = [:]
    private var notificationSettings: [String: [NotificationRuleSetting]] = [:]
    private var notificationState: [String: NotificationRuleState] = [:]

    private(set) var pollIntervalSeconds: TimeInterval = 120
    private(set) var autoUpdateCheckEnabled: Bool = true
    private(set) var menuBarAppearance = MenuBarAppearanceSettings()

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return }
        if let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) {
            enabledMap = decoded
        }
        if let metricData = UserDefaults.standard.data(forKey: sourceMetricSettingsKey),
           let decodedMetricSettings = try? JSONDecoder().decode([String: [String: Bool]].self, from: metricData) {
            sourceMetricEnabledMap = decodedMetricSettings
        }

        if let settingsData = UserDefaults.standard.data(forKey: notificationDefaultsKey),
           let decodedSettings = try? JSONDecoder().decode([String: [NotificationRuleSetting]].self, from: settingsData) {
            notificationSettings = decodedSettings
        }

        if let stateData = UserDefaults.standard.data(forKey: notificationStateKey),
           let decodedState = try? JSONDecoder().decode([String: NotificationRuleState].self, from: stateData) {
            notificationState = decodedState
        }

        let migrated = migrateLegacyCopilotPacingRuleIfNeeded()

        let poll = UserDefaults.standard.double(forKey: pollIntervalKey)
        if poll > 0 {
            pollIntervalSeconds = poll
        }

        if UserDefaults.standard.object(forKey: autoUpdateCheckKey) != nil {
            autoUpdateCheckEnabled = UserDefaults.standard.bool(forKey: autoUpdateCheckKey)
        }

        if let appearanceData = UserDefaults.standard.data(forKey: menuBarAppearanceKey),
           let decodedAppearance = try? JSONDecoder().decode(MenuBarAppearanceSettings.self, from: appearanceData) {
            menuBarAppearance = MenuBarAppearanceSettings.normalized(
                colorMode: decodedAppearance.colorMode,
                centerContentMode: decodedAppearance.centerContentMode,
                selectedMetrics: decodedAppearance.selectedMetrics
            )
        }

        if migrated {
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(enabledMap) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
        if let data = try? JSONEncoder().encode(sourceMetricEnabledMap) {
            UserDefaults.standard.set(data, forKey: sourceMetricSettingsKey)
        }

        if let data = try? JSONEncoder().encode(notificationSettings) {
            UserDefaults.standard.set(data, forKey: notificationDefaultsKey)
        }

        if let data = try? JSONEncoder().encode(notificationState) {
            UserDefaults.standard.set(data, forKey: notificationStateKey)
        }

        if let data = try? JSONEncoder().encode(menuBarAppearance) {
            UserDefaults.standard.set(data, forKey: menuBarAppearanceKey)
        }
    }

    func isEnabled(sourceName: String) -> Bool {
        return enabledMap[sourceName] ?? false
    }

    func setEnabled(_ enabled: Bool, for sourceName: String) {
        enabledMap[sourceName] = enabled
        save()
        NotificationCenter.default.post(name: .aiSettingsChanged, object: nil)
    }

    /// Ensure keys exist for provided sources; does not override existing settings.
    func ensureSources(_ sourceNames: [String]) {
        for name in sourceNames where enabledMap[name] == nil {
            enabledMap[name] = false
        }
        save()
    }

    func ensureSourceMetrics(source: AISource) {
        let metricSettings = sourceMetricEnabledMap[source.name] ?? [:]
        var updated: [String: Bool] = [:]
        for metric in source.metrics {
            if let existing = metricSettings[metric.id] {
                updated[metric.id] = existing
            } else {
                updated[metric.id] = metric.defaultEnabled
            }
        }
        sourceMetricEnabledMap[source.name] = updated
        save()
    }

    func isMetricEnabled(sourceName: String, metricId: String) -> Bool {
        sourceMetricEnabledMap[sourceName]?[metricId] ?? true
    }

    func setMetricEnabled(_ enabled: Bool, sourceName: String, metricId: String) {
        var metricSettings = sourceMetricEnabledMap[sourceName] ?? [:]
        metricSettings[metricId] = enabled
        sourceMetricEnabledMap[sourceName] = metricSettings
        save()
        NotificationCenter.default.post(name: .aiSettingsChanged, object: nil)
    }

    func pollInterval() -> TimeInterval {
        pollIntervalSeconds
    }

    func setPollIntervalSeconds(_ seconds: TimeInterval) {
        pollIntervalSeconds = max(30, seconds)
        UserDefaults.standard.set(pollIntervalSeconds, forKey: pollIntervalKey)
        NotificationCenter.default.post(name: .aiSettingsChanged, object: nil)
    }

    func setAutoUpdateCheckEnabled(_ enabled: Bool) {
        autoUpdateCheckEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: autoUpdateCheckKey)
        if enabled {
            UpdateManager.shared.startPeriodicChecks()
        } else {
            UpdateManager.shared.stopPeriodicChecks()
        }
    }

    func setMenuBarColorMode(_ mode: MenuBarColorMode) {
        menuBarAppearance = MenuBarAppearanceSettings.normalized(
            colorMode: mode,
            centerContentMode: menuBarAppearance.centerContentMode,
            selectedMetrics: menuBarAppearance.selectedMetrics
        )
        save()
        NotificationCenter.default.post(name: .aiSettingsChanged, object: nil)
    }

    func setMenuBarCenterContentMode(_ mode: MenuBarCenterContentMode) {
        menuBarAppearance = MenuBarAppearanceSettings.normalized(
            colorMode: menuBarAppearance.colorMode,
            centerContentMode: mode,
            selectedMetrics: menuBarAppearance.selectedMetrics
        )
        save()
        NotificationCenter.default.post(name: .aiSettingsChanged, object: nil)
    }

    func setMenuBarSelectedMetrics(_ selectedMetrics: [MenuBarMetricSelection]) {
        menuBarAppearance = MenuBarAppearanceSettings.normalized(
            colorMode: menuBarAppearance.colorMode,
            centerContentMode: menuBarAppearance.centerContentMode,
            selectedMetrics: selectedMetrics
        )
        save()
        NotificationCenter.default.post(name: .aiSettingsChanged, object: nil)
    }

    func ruleSettings(for sourceName: String) -> [NotificationRuleSetting] {
        notificationSettings[sourceName] ?? []
    }

    func ensureNotificationRules(source: AISource, metricId: String? = nil, scopeName: String? = nil) {
        let definitions: [NotificationDefinition]
        if let metricId {
            definitions = source.notificationDefinitions(for: metricId)
        } else if let primaryMetric = source.metrics.first {
            definitions = source.notificationDefinitions(for: primaryMetric.id)
        } else {
            definitions = []
        }
        let scopedSourceName = scopeName ?? source.name

        var current = notificationSettings[scopedSourceName] ?? []
        if current.isEmpty, scopedSourceName != source.name {
            current = notificationSettings[source.name] ?? []
        }
        var map: [String: NotificationRuleSetting] = [:]
        for setting in current {
            map[setting.ruleId] = setting
        }

        for definition in definitions {
            if map[definition.id] == nil {
                var values: [String: Double] = [:]
                for input in definition.inputs {
                    values[input.id] = input.defaultValue
                }
                map[definition.id] = NotificationRuleSetting(ruleId: definition.id, isEnabled: false, inputValues: values)
            }
        }

        let merged = definitions.compactMap { map[$0.id] }
        notificationSettings[scopedSourceName] = merged
        save()
    }

    func setRuleEnabled(_ enabled: Bool, sourceName: String, ruleId: String) {
        var rules = notificationSettings[sourceName] ?? []
        for idx in rules.indices where rules[idx].ruleId == ruleId {
            rules[idx].isEnabled = enabled
        }
        notificationSettings[sourceName] = rules
        clearRuleState(sourceName: sourceName, ruleId: ruleId)
        save()
        NotificationCenter.default.post(name: .aiSettingsChanged, object: nil)
    }

    func setRuleValue(_ value: Double, sourceName: String, ruleId: String, inputId: String) {
        var rules = notificationSettings[sourceName] ?? []
        for idx in rules.indices where rules[idx].ruleId == ruleId {
            rules[idx].inputValues[inputId] = value
        }
        notificationSettings[sourceName] = rules
        clearRuleState(sourceName: sourceName, ruleId: ruleId)
        save()
    }

    func clearRuleState(sourceName: String, ruleId: String) {
        notificationState.removeValue(forKey: ruleStateKey(sourceName: sourceName, ruleId: ruleId))
    }

    func ruleInputValue(sourceName: String, ruleId: String, inputId: String, defaultValue: Double) -> Double {
        guard let rules = notificationSettings[sourceName] else { return defaultValue }
        guard let rule = rules.first(where: { $0.ruleId == ruleId }) else { return defaultValue }
        return rule.inputValues[inputId] ?? defaultValue
    }

    func ruleStateKey(sourceName: String, ruleId: String) -> String {
        "\(sourceName):\(ruleId)"
    }

    func ruleState(sourceName: String, ruleId: String) -> NotificationRuleState? {
        notificationState[ruleStateKey(sourceName: sourceName, ruleId: ruleId)]
    }

    func setRuleState(_ state: NotificationRuleState, sourceName: String, ruleId: String) {
        notificationState[ruleStateKey(sourceName: sourceName, ruleId: ruleId)] = state
        save()
    }

    @discardableResult
    private func migrateLegacyCopilotPacingRuleIfNeeded() -> Bool {
        let sourceName = "Copilot"
        let legacyRuleId = "behindPace"
        let newRuleId = "pacingAlert"
        guard var rules = notificationSettings[sourceName],
              let legacyIndex = rules.firstIndex(where: { $0.ruleId == legacyRuleId }) else {
            return false
        }

        let legacy = rules.remove(at: legacyIndex)
        if let existing = rules.firstIndex(where: { $0.ruleId == newRuleId }) {
            rules[existing].isEnabled = rules[existing].isEnabled || legacy.isEnabled
        } else {
            rules.append(NotificationRuleSetting(ruleId: newRuleId, isEnabled: legacy.isEnabled, inputValues: [:]))
        }
        notificationSettings[sourceName] = rules

        let oldStateKey = ruleStateKey(sourceName: sourceName, ruleId: legacyRuleId)
        let newStateKey = ruleStateKey(sourceName: sourceName, ruleId: newRuleId)
        if notificationState[newStateKey] == nil, let old = notificationState[oldStateKey] {
            notificationState[newStateKey] = old
        }
        notificationState.removeValue(forKey: oldStateKey)

        return true
    }
}
