import SwiftUI
import ServiceManagement
import RashunCore

@MainActor
final class PreferencesViewModel: ObservableObject {
    struct MenuBarMetricOption: Identifiable, Hashable {
        var id: String { "\(sourceName)::\(metricId)" }
        let sourceName: String
        let sourceTitle: String
        let metricId: String
        let metricTitle: String
    }

    struct NotificationSection: Identifiable {
        let id: String
        let title: String?
        let sourceName: String
        let definitions: [NotificationDefinition]
    }

    @Published private(set) var sources: [AISource] = []
    @Published var expandedSources: Set<String> = []
    @Published var pendingEnableSource: AISource?
    @Published var showInstallConfirmation = false
    @Published var selectedTab: PreferencesTab = .general
    @Published var pollMinutesText = ""
    @Published var ruleInputDrafts: [String: String] = [:]
    @Published private(set) var checkNowEnabled = true
    @Published private(set) var installEnabled = true
    @Published private(set) var updateStatusText = ""
    @Published private(set) var updateStatusIsPositive = false
    @Published var launchAtLoginErrorMessage: String?
    @Published var sourceHealthCheckErrorMessage: String?
    @Published private(set) var sourceHealthCheckInProgress = false
    @Published private(set) var healthCheckSourceName: String?
    @Published private(set) var menuBarAppearance = MenuBarAppearanceSettings()

    private var settings: SettingsStore { .shared }
    private var updates: UpdateManager { .shared }

    init() {
        registerObservers()
        pollMinutesText = formattedPollMinutes()
        menuBarAppearance = settings.menuBarAppearance
        refreshUpdateStatus()
    }

    func configure(withSources newSources: [AISource]) {
        sources = newSources
        settings.ensureSources(newSources.map { $0.name })
        for source in newSources {
            settings.ensureSourceMetrics(source: source)
            if source.metrics.count <= 1 {
                settings.ensureNotificationRules(source: source)
            } else {
                for metric in source.metrics {
                    settings.ensureNotificationRules(
                        source: source,
                        metricId: metric.id,
                        scopeName: notificationScopeName(source: source, metricId: metric.id)
                    )
                }
            }
            if !settings.isEnabled(sourceName: source.name) {
                let metricScopePrefix = "\(source.name)::"
                expandedSources = expandedSources.filter { $0 != source.name && !$0.hasPrefix(metricScopePrefix) }
            }
            seedRuleInputDrafts(for: source)
        }
        pollMinutesText = formattedPollMinutes()
        sanitizeMenuBarSelections()
        menuBarAppearance = settings.menuBarAppearance
        refreshUpdateStatus()
    }

    func isSourceEnabled(_ sourceName: String) -> Bool { settings.isEnabled(sourceName: sourceName) }

    func sourceToggleChanged(_ source: AISource, enabled: Bool) {
        guard !enabled else { pendingEnableSource = source; return }
        let metricScopePrefix = "\(source.name)::"
        expandedSources = expandedSources.filter { $0 != source.name && !$0.hasPrefix(metricScopePrefix) }
        settings.setEnabled(false, for: source.name)
    }

    func isMetricEnabled(sourceName: String, metricId: String) -> Bool {
        settings.isMetricEnabled(sourceName: sourceName, metricId: metricId)
    }

    func setMetricEnabled(sourceName: String, metricId: String, enabled: Bool) {
        settings.setMetricEnabled(enabled, sourceName: sourceName, metricId: metricId)
    }

    func confirmEnableSource() {
        guard let source = pendingEnableSource else { return }
        pendingEnableSource = nil
        sourceHealthCheckInProgress = true
        Task { @MainActor [weak self] in
            await self?.runEnableHealthCheck(for: source)
        }
    }

    func cancelEnableSource() { pendingEnableSource = nil }
    func isSourceExpanded(_ sourceName: String) -> Bool { expandedSources.contains(sourceName) }
    func isSourceHealthCheckInProgress(_ sourceName: String) -> Bool {
        sourceHealthCheckInProgress && healthCheckSourceName == sourceName
    }
    func sourceHasWarning(_ sourceName: String) -> Bool {
        SourceHealthStore.shared.health(for: sourceName)?.shortErrorMessage != nil
    }

    func sourceHasAnyMetricWarning(_ source: AISource) -> Bool {
        if source.metrics.count <= 1 {
            return sourceHasWarning(source.name)
        }
        return source.metrics.contains { metric in
            metricWarningSummary(sourceName: source.name, metricId: metric.id) != nil
        }
    }

    func sourceWarningSummary(_ sourceName: String) -> String? {
        SourceHealthStore.shared.health(for: sourceName)?.shortErrorMessage
    }

    func sourceWarningDetail(_ sourceName: String) -> String? {
        SourceHealthStore.shared.health(for: sourceName)?.detailedErrorMessage
    }

    func metricWarningSummary(sourceName: String, metricId: String) -> String? {
        SourceHealthStore.shared.health(for: sourceName, metricId: metricId)?.shortErrorMessage
    }

    func metricWarningDetail(sourceName: String, metricId: String) -> String? {
        SourceHealthStore.shared.health(for: sourceName, metricId: metricId)?.detailedErrorMessage
    }

    func toggleNotificationsSection(_ sourceName: String) {
        if !expandedSources.insert(sourceName).inserted { expandedSources.remove(sourceName) }
    }

    func isMetricNotificationsExpanded(sourceName: String, metricId: String) -> Bool {
        expandedSources.contains(notificationScopeName(sourceName: sourceName, metricId: metricId))
    }

    func toggleMetricNotificationsSection(sourceName: String, metricId: String) {
        toggleNotificationsSection(notificationScopeName(sourceName: sourceName, metricId: metricId))
    }

    func isRuleEnabled(sourceName: String, ruleId: String) -> Bool {
        settings.ruleSettings(for: sourceName).first(where: { $0.ruleId == ruleId })?.isEnabled ?? false
    }

    func setRuleEnabled(sourceName: String, ruleId: String, enabled: Bool) {
        settings.setRuleEnabled(enabled, sourceName: sourceName, ruleId: ruleId)
    }

    func ruleInputText(sourceName: String, ruleId: String, input: NotificationInputSpec) -> String {
        let key = inputKey(sourceName: sourceName, ruleId: ruleId, inputId: input.id)
        if let draft = ruleInputDrafts[key] { return draft }
        return formattedNumber(settings.ruleInputValue(
            sourceName: sourceName,
            ruleId: ruleId,
            inputId: input.id,
            defaultValue: input.defaultValue
        ))
    }

    func setRuleInputDraft(sourceName: String, ruleId: String, inputId: String, text: String) {
        ruleInputDrafts[inputKey(sourceName: sourceName, ruleId: ruleId, inputId: inputId)] = text
    }

    func commitRuleInput(sourceName: String, ruleId: String, input: NotificationInputSpec) {
        let key = inputKey(sourceName: sourceName, ruleId: ruleId, inputId: input.id)
        let current = settings.ruleInputValue(sourceName: sourceName, ruleId: ruleId, inputId: input.id, defaultValue: input.defaultValue)
        guard let parsed = Double(ruleInputDrafts[key] ?? "") else {
            ruleInputDrafts[key] = formattedNumber(current)
            return
        }
        let clamped = min(max(parsed, input.min), input.max)
        settings.setRuleValue(clamped, sourceName: sourceName, ruleId: ruleId, inputId: input.id)
        ruleInputDrafts[key] = formattedNumber(clamped)
    }

    func flushPendingEdits() {
        applyPollInterval()
        for source in sources {
            for section in notificationSections(for: source) {
                for definition in section.definitions {
                    for input in definition.inputs {
                        commitRuleInput(sourceName: section.sourceName, ruleId: definition.id, input: input)
                    }
                }
            }
        }
    }

    var autoUpdateCheckEnabled: Bool {
        get { settings.autoUpdateCheckEnabled }
        set { settings.setAutoUpdateCheckEnabled(newValue) }
    }

    var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        launchAtLoginErrorMessage = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLaunchAtLoginUI()
        } catch {
            launchAtLoginErrorMessage = "Could not update Launch at Login. \(error.localizedDescription)"
            objectWillChange.send()
        }
    }

    func applyPollInterval() {
        guard let minutes = Double(pollMinutesText), minutes > 0 else {
            pollMinutesText = formattedPollMinutes()
            return
        }
        settings.setPollIntervalSeconds(minutes * 60)
        pollMinutesText = formattedPollMinutes()
    }

    var menuBarColorMode: MenuBarColorMode {
        get { menuBarAppearance.colorMode }
        set { settings.setMenuBarColorMode(newValue) }
    }

    var menuBarCenterContentMode: MenuBarCenterContentMode {
        get { menuBarAppearance.centerContentMode }
        set { settings.setMenuBarCenterContentMode(newValue) }
    }

    var menuBarSelectionCount: Int { menuBarAppearance.selectedMetrics.count }

    func menuBarMetricOptions() -> [MenuBarMetricOption] {
        sources.filter { settings.isEnabled(sourceName: $0.name) }.flatMap { source in
            source.metrics
                .filter { settings.isMetricEnabled(sourceName: source.name, metricId: $0.id) }
                .map { metric in
                MenuBarMetricOption(
                    sourceName: source.name,
                    sourceTitle: source.name,
                    metricId: metric.id,
                    metricTitle: metric.title
                )
            }
        }
    }

    func isMenuBarMetricSelected(sourceName: String, metricId: String) -> Bool {
        menuBarAppearance.selectedMetrics.contains { selection in
            selection.sourceName == sourceName && selection.metricId == metricId
        }
    }

    func setMenuBarMetricSelected(sourceName: String, metricId: String, selected: Bool) {
        guard settings.isEnabled(sourceName: sourceName),
              settings.isMetricEnabled(sourceName: sourceName, metricId: metricId) else { return }
        var current = menuBarAppearance.selectedMetrics
        let target = MenuBarMetricSelection(sourceName: sourceName, metricId: metricId)
        if selected {
            guard !current.contains(target) else { return }
            current.append(target)
        } else {
            current.removeAll { $0 == target }
        }
        settings.setMenuBarSelectedMetrics(current)
    }

    func checkForUpdates() async {
        _ = await updates.checkForUpdate(notify: false)
        refreshUpdateStatus()
    }

    func installUpdate() {
        updates.installUpdate()
        showInstallConfirmation = false
    }

    func selectTab(_ tab: PreferencesTab) {
        selectedTab = tab
    }

    var updateStatusColor: Color {
        if updateStatusIsPositive { return BrandPalette.accent }
        if updateStatusText.isEmpty { return BrandPalette.textSecondary }
        return BrandPalette.warning
    }

    var updateAvailable: Bool { updates.updateAvailable }
    var currentVersionText: String { "Current version: \(updates.currentVersion)" }
    var availableVersionText: String { updates.availableVersion ?? "" }

    var pendingEnableMessage: String {
        guard let source = pendingEnableSource else { return "" }
        return source.requirements.isEmpty ? "Enable this source?" : source.requirements
    }

    private func registerObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleSettingsChanged), name: .aiSettingsChanged, object: nil)
        center.addObserver(self, selector: #selector(handleUpdateStatusChanged), name: .updateStatusChanged, object: nil)
        center.addObserver(self, selector: #selector(handleSourceHealthChanged), name: .aiSourceHealthChanged, object: nil)
    }

    @objc private func handleSettingsChanged() {
        pollMinutesText = formattedPollMinutes()
        sanitizeMenuBarSelections()
        menuBarAppearance = settings.menuBarAppearance
    }

    private func sanitizeMenuBarSelections() {
        let validSelections = settings.menuBarAppearance.selectedMetrics.filter { selection in
            guard settings.isEnabled(sourceName: selection.sourceName),
                  settings.isMetricEnabled(sourceName: selection.sourceName, metricId: selection.metricId),
                  let source = sources.first(where: { $0.name == selection.sourceName }) else {
                return false
            }
            return source.metrics.contains(where: { $0.id == selection.metricId })
        }

        if validSelections != settings.menuBarAppearance.selectedMetrics {
            settings.setMenuBarSelectedMetrics(validSelections)
        }
    }
    @objc private func handleUpdateStatusChanged() { refreshUpdateStatus() }
    @objc private func handleSourceHealthChanged() { objectWillChange.send() }

    private func runEnableHealthCheck(for source: AISource) async {
        healthCheckSourceName = source.name
        defer {
            sourceHealthCheckInProgress = false
            healthCheckSourceName = nil
        }
        do {
            guard let metricId = source.metrics.first?.id else {
                throw source.unsupportedMetricError("default")
            }
            let usage = try await source.fetchUsage(for: metricId)
            if source.metrics.count <= 1 {
                SourceHealthStore.shared.recordSuccess(sourceName: source.name, usage: usage)
            } else {
                SourceHealthStore.shared.recordSuccess(sourceName: source.name, metricId: metricId, usage: usage)
            }
            settings.setEnabled(true, for: source.name)
        } catch {
            let metricId = source.metrics.first?.id ?? "default"
            let presentation = source.mapFetchError(for: metricId, error)
            if source.metrics.count <= 1 {
                SourceHealthStore.shared.recordFailure(sourceName: source.name, presentation: presentation)
            } else {
                SourceHealthStore.shared.recordFailure(sourceName: source.name, metricId: metricId, presentation: presentation)
            }
            sourceHealthCheckErrorMessage = "Could not enable \(source.name).\n\n\(presentation.detailedMessage)"
            settings.setEnabled(false, for: source.name)
        }
    }

    private func seedRuleInputDrafts(for source: AISource) {
        for section in notificationSections(for: source) {
            for definition in section.definitions {
                for input in definition.inputs {
                    let key = inputKey(sourceName: section.sourceName, ruleId: definition.id, inputId: input.id)
                    if ruleInputDrafts[key] != nil { continue }
                    let value = settings.ruleInputValue(
                        sourceName: section.sourceName,
                        ruleId: definition.id,
                        inputId: input.id,
                        defaultValue: input.defaultValue
                    )
                    ruleInputDrafts[key] = formattedNumber(value)
                }
            }
        }
    }

    func notificationSections(for source: AISource) -> [NotificationSection] {
        guard let primaryMetric = source.metrics.first else { return [] }

        if source.metrics.count <= 1 {
            return [
                NotificationSection(
                    id: source.name,
                    title: nil,
                    sourceName: source.name,
                    definitions: source.notificationDefinitions(for: primaryMetric.id)
                )
            ]
        }

        return source.metrics.map { metric in
            NotificationSection(
                id: notificationScopeName(source: source, metricId: metric.id),
                title: metric.title,
                sourceName: notificationScopeName(source: source, metricId: metric.id),
                definitions: source.notificationDefinitions(for: metric.id)
            )
        }
    }

    func notificationDefinitions(for source: AISource) -> [NotificationDefinition] {
        notificationSections(for: source).first?.definitions ?? []
    }

    func notificationDefinitions(for source: AISource, metricId: String) -> [NotificationDefinition] {
        source.notificationDefinitions(for: metricId)
    }

    private func formattedPollMinutes() -> String { formattedNumber(settings.pollInterval() / 60) }
    private func formattedNumber(_ value: Double) -> String { String(format: "%.0f", value) }

    private func refreshLaunchAtLoginUI() {
        objectWillChange.send()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self?.objectWillChange.send()
        }
    }

    private func refreshUpdateStatus() {
        if updates.isInstalling {
            updateStatusText = "Installing..."
            checkNowEnabled = false
            installEnabled = false
            updateStatusIsPositive = false
            return
        }

        if updates.isChecking {
            updateStatusText = "Checking..."
            checkNowEnabled = false
            installEnabled = true
            updateStatusIsPositive = false
            return
        }

        checkNowEnabled = true
        installEnabled = true

        if updates.updateAvailable {
            updateStatusText = "Version \(updates.availableVersion ?? "") available"
            updateStatusIsPositive = true
        } else if updates.availableVersion != nil {
            updateStatusText = "Up to date"
            updateStatusIsPositive = true
        } else {
            updateStatusText = ""
            updateStatusIsPositive = false
        }
    }

    private func inputKey(sourceName: String, ruleId: String, inputId: String) -> String {
        "\(sourceName)|\(ruleId)|\(inputId)"
    }

    private func notificationScopeName(source: AISource, metricId: String) -> String {
        if source.metrics.count <= 1 {
            return source.name
        }
        return "\(source.name)::\(metricId)"
    }

    private func notificationScopeName(sourceName: String, metricId: String) -> String {
        "\(sourceName)::\(metricId)"
    }
}
