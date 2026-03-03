import SwiftUI
import ServiceManagement

@MainActor
final class PreferencesViewModel: ObservableObject {
    @Published private(set) var sources: [AISource] = []
    @Published var expandedSources: Set<String> = []
    @Published var pendingEnableSource: AISource?
    @Published var showInstallConfirmation = false
    @Published var pollMinutesText = ""
    @Published var ruleInputDrafts: [String: String] = [:]
    @Published private(set) var checkNowEnabled = true
    @Published private(set) var installEnabled = true
    @Published private(set) var updateStatusText = ""
    @Published private(set) var updateStatusIsPositive = false
    @Published var launchAtLoginErrorMessage: String?

    private var settings: SettingsStore { .shared }
    private var updates: UpdateManager { .shared }

    init() {
        registerObservers()
        pollMinutesText = formattedPollMinutes()
        refreshUpdateStatus()
    }

    func configure(withSources newSources: [AISource]) {
        sources = newSources
        settings.ensureSources(newSources.map { $0.name })
        for source in newSources {
            settings.ensureNotificationRules(source: source)
            if !settings.isEnabled(sourceName: source.name) { expandedSources.remove(source.name) }
            seedRuleInputDrafts(for: source)
        }
        pollMinutesText = formattedPollMinutes()
        refreshUpdateStatus()
    }

    func isSourceEnabled(_ sourceName: String) -> Bool { settings.isEnabled(sourceName: sourceName) }

    func sourceToggleChanged(_ source: AISource, enabled: Bool) {
        guard !enabled else { pendingEnableSource = source; return }
        expandedSources.remove(source.name)
        settings.setEnabled(false, for: source.name)
    }

    func confirmEnableSource() {
        guard let source = pendingEnableSource else { return }
        settings.setEnabled(true, for: source.name)
        pendingEnableSource = nil
    }

    func cancelEnableSource() { pendingEnableSource = nil }
    func isSourceExpanded(_ sourceName: String) -> Bool { expandedSources.contains(sourceName) }

    func toggleNotificationsSection(_ sourceName: String) {
        if !expandedSources.insert(sourceName).inserted { expandedSources.remove(sourceName) }
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
            for definition in source.notificationDefinitions {
                for input in definition.inputs { commitRuleInput(sourceName: source.name, ruleId: definition.id, input: input) }
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

    func checkForUpdates() async {
        _ = await updates.checkForUpdate(notify: false)
        refreshUpdateStatus()
    }

    func installUpdate() {
        updates.installUpdate()
        showInstallConfirmation = false
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
    }

    @objc private func handleSettingsChanged() { pollMinutesText = formattedPollMinutes() }
    @objc private func handleUpdateStatusChanged() { refreshUpdateStatus() }

    private func seedRuleInputDrafts(for source: AISource) {
        for definition in source.notificationDefinitions {
            for input in definition.inputs {
                let key = inputKey(sourceName: source.name, ruleId: definition.id, inputId: input.id)
                if ruleInputDrafts[key] != nil { continue }
                let value = settings.ruleInputValue(sourceName: source.name, ruleId: definition.id, inputId: input.id, defaultValue: input.defaultValue)
                ruleInputDrafts[key] = formattedNumber(value)
            }
        }
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
}
