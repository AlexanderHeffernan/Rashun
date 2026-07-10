import Cocoa
import SwiftUI
import UserNotifications
import RashunCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct MetricFetchResult {
        let usages: [String: UsageResult]
        let errorsByMetric: [String: Error]
    }

    private struct SourceMetricFetchError: Error {
        let metricId: String
        let underlying: Error
        let errorsByMetric: [String: Error]
    }

    private struct ResetCelebration: Hashable {
        let sourceName: String
        let metricId: String
        let sourceColorHex: UInt32
    }

    var statusItem: NSStatusItem?
    var menu: NSMenu?
    var pollTimer: Timer?
    let loadingIndicator = "⏳"

    var sources: [AISource] { allSources }

    var results: [String: [String: String]] = [:]
    var latestUsageResults: [String: [String: UsageResult]] = [:]
    var sourceHeaderDetails: [String: String] = [:]
    var loadingSources: Set<String> = []
    var lastRefreshDate: Date?
    private var usageSampleStabilityGate = UsageSampleStabilityGate()
    private let statusRingSize: CGFloat = 20
    private let statusRingSpacing: CGFloat = 3
    #if DEBUG
    private var simulatedCodexWeeklyResetSample: UsageResult?
    private var simulatedCodexWeeklyResetBaseline: UsageResult?
    #endif
    private var isSleepSuspended = false
    private var isLockSuspended = false
    private var lastResumeRefreshTriggerDate: Date?
    private let resumeRefreshDebounceSeconds: TimeInterval = 8
    private let trackedUsageStore = TrackedUsageStore.shared
    private var isStoppingTrackingSession = false
    private var trackingCompletionSummary: String?
    private var trackingIndicatorPulseTimer: Timer?
    private var trackingIndicatorPulsePhase = 0.0

    private var isPollingSuspended: Bool {
        isSleepSuspended || isLockSuspended
    }

    func applicationDidFinishLaunching(_: Notification) {
        UNUserNotificationCenter.current().delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.imagePosition = .imageOnly
            button.title = ""
        }

        menu = NSMenu()
        menu?.delegate = self
        statusItem?.menu = menu

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)), name: .aiSettingsChanged, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleDidWake), name: NSWorkspace.didWakeNotification, object: nil)

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScreenLocked),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScreenUnlocked),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )

        SettingsStore.shared.ensureSources(sources.map { $0.name })
        for source in sources {
            SettingsStore.shared.ensureSourceMetrics(source: source)
            if source.metrics.count <= 1 {
                if let usage = SourceHealthStore.shared.health(for: source.name)?.lastSuccessfulUsage {
                    let metricId = source.metrics.first?.id ?? "default"
                    results[source.name] = [metricId: usage.formatted]
                }
                continue
            }

            var metricDisplays: [String: String] = [:]
            for metric in source.metrics {
                if let usage = SourceHealthStore.shared.health(for: source.name, metricId: metric.id)?.lastSuccessfulUsage {
                    metricDisplays[metric.id] = usage.formatted
                }
            }
            if !metricDisplays.isEmpty {
                results[source.name] = metricDisplays
            }
        }
        updateMenu()
        updateStatusIcon()

        Task {
            _ = await NotificationManager.shared.requestAuthorization()
            UpdateManager.shared.startPeriodicChecks()
            await refresh(origin: trackedUsageStore.activeSession == nil ? .poll : .recovery)
        }

        schedulePollTimer()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func menuWillOpen(_ menu: NSMenu) {
        trackingCompletionSummary = nil
        updateMenu()
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    func updateMenu() {
        menu?.removeAllItems()
        let enabled = sources.filter { SettingsStore.shared.isEnabled(sourceName: $0.name) }
        if enabled.isEmpty {
            menu?.addItem(withTitle: "No sources enabled — open Preferences...", action: #selector(AppDelegate.showPreferences), keyEquivalent: "")
        } else {
            var hasWarnings = false
            for (index, source) in enabled.enumerated() {
                let hasWarning = !loadingSources.contains(source.name) && sourceHasWarning(source)
                if hasWarning { hasWarnings = true }
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.view = sourceMenuView(source: source, hasWarning: hasWarning)
                menu?.addItem(item)
                if index < enabled.count - 1 {
                    menu?.addItem(NSMenuItem.separator())
                }
            }
            if hasWarnings {
                let hint = NSMenuItem(
                    title: "⚠ See Preferences > Sources",
                    action: nil,
                    keyEquivalent: ""
                )
                hint.isEnabled = false
                menu?.addItem(hint)
            }
        }
        menu?.addItem(NSMenuItem.separator())

        if SettingsStore.shared.trackingEnabled || trackedUsageStore.activeSession != nil {
            addTrackingMenuSection()
            menu?.addItem(NSMenuItem.separator())
        }

        let refreshItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let refreshButton = RefreshButton(target: self, action: #selector(refreshClicked))
        refreshButton.update(loading: !loadingSources.isEmpty, lastRefresh: lastRefreshDate)
        refreshItem.view = refreshButton
        menu?.addItem(refreshItem)
        menu?.addItem(withTitle: "Usage History...", action: #selector(showChart), keyEquivalent: "")

        menu?.addItem(NSMenuItem.separator())
        menu?.addItem(withTitle: "Preferences...", action: #selector(AppDelegate.showPreferences), keyEquivalent: ",")
        menu?.addItem(NSMenuItem.separator())
        menu?.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
    }

    private func addTrackingMenuSection() {
        if let session = trackedUsageStore.activeSession {
            let elapsed = Date().timeIntervalSince(session.startedAt)
            let title = "● Tracking \(session.labelNameSnapshot) • \(compactDuration(elapsed))"
            let indicator = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            indicator.isEnabled = false
            menu?.addItem(indicator)
            for metric in TrackedUsageAttributionEngine.results(for: session) {
                menu?.addItem(withTitle: "   \(metric.sourceName) \(metric.metricTitle): \(String(format: "%.1f", metric.percentagePointsConsumed))%", action: nil, keyEquivalent: "")
            }
            let stopItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let stopButton = TrackingMenuButton(target: self, action: #selector(stopTrackingSession))
            stopButton.update(title: isStoppingTrackingSession ? "Stopping…" : "Stop Session", isEnabled: !isStoppingTrackingSession)
            stopItem.view = stopButton
            menu?.addItem(stopItem)
        } else {
            menu?.addItem(withTitle: "Start Session…", action: #selector(startTrackingSession), keyEquivalent: "")
        }
        menu?.addItem(withTitle: "Tracked Usage…", action: #selector(showTrackedUsage), keyEquivalent: "")
    }

    private func compactDuration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    @objc private func startTrackingSession() {
        let alert = NSAlert()
        alert.messageText = "Start tracked session"
        alert.informativeText = "Choose a label for this observed usage session."
        let labels = trackedUsageStore.labels.filter { $0.archivedAt == nil }
        guard !labels.isEmpty else { openPreferences(tab: .tracking); return }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 28), pullsDown: false)
        for label in labels { picker.addItem(withTitle: label.name); picker.lastItem?.representedObject = label.id.uuidString }
        alert.accessoryView = picker
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Manage Labels…")
        let response = alert.runModal()
        if response == .alertThirdButtonReturn { openPreferences(tab: .tracking); return }
        guard response == .alertFirstButtonReturn, let identifier = picker.selectedItem?.representedObject as? String, let id = UUID(uuidString: identifier), let label = labels.first(where: { $0.id == id }) else { return }
        _ = trackedUsageStore.start(label: label)
        updateMenu()
        updateStatusIcon()
        NotificationCenter.default.post(name: .aiDataRefreshed, object: nil)
        Task { await refreshForTrackingBoundary(origin: .start) }
    }

    @objc private func stopTrackingSession() {
        guard !isStoppingTrackingSession else { return }
        isStoppingTrackingSession = true
        updateMenu()
        Task {
            await refreshForTrackingBoundary(origin: .stop)
            _ = trackedUsageStore.stop()
            isStoppingTrackingSession = false
            trackingCompletionSummary = nil
            updateMenu()
            updateStatusIcon()
            NotificationCenter.default.post(name: .aiDataRefreshed, object: nil)
        }
    }

    @objc private func showTrackedUsage() {
        TrackedUsageWindowController.shared.showWindowAndBringToFront()
    }

    private func sourceMenuView(source: AISource, hasWarning: Bool) -> NSView {
        let metrics = enabledMetrics(for: source)
        let colorMode = SettingsStore.shared.menuBarAppearance.colorMode
        let rows: [MenuDropdownMetricRowModel]
        if metrics.isEmpty {
            rows = [
                MenuDropdownMetricRowModel(
                    title: "No metrics enabled",
                    valueText: "--",
                    detailText: nil,
                    progress: 0,
                    colorHex: nil,
                    hasValue: false,
                    hasWarning: hasWarning
                )
            ]
        } else {
            let sourceHasSingleMetric = source.metrics.count <= 1 && metrics.count <= 1
            rows = metrics.map { metric in
                let warning = metricHasWarning(source: source, metricId: metric.id)
                let rowTitle = sourceHasSingleMetric ? "Remaining" : metric.title
                let usage = usageResultForIcon(sourceName: source.name, metricId: metric.id)
                if loadingSources.contains(source.name) {
                    if let usage {
                        let percent = min(max(usage.percentRemaining, 0), 100)
                        return MenuDropdownMetricRowModel(
                            title: rowTitle,
                            valueText: "\(Int(round(percent)))%",
                            detailText: refreshingTimingText(source: source, metric: metric, usage: usage),
                            progress: percent / 100,
                            colorHex: metricColorHex(source: source, metric: metric, usage: usage, colorMode: colorMode),
                            hasValue: true,
                            hasWarning: warning
                        )
                    }

                    return MenuDropdownMetricRowModel(
                        title: rowTitle,
                        valueText: "Refreshing",
                        detailText: nil,
                        progress: 0,
                        colorHex: nil,
                        hasValue: false,
                        hasWarning: warning
                    )
                }

                if let usage {
                    let percent = min(max(usage.percentRemaining, 0), 100)
                    return MenuDropdownMetricRowModel(
                        title: rowTitle,
                        valueText: "\(Int(round(percent)))%",
                        detailText: metricTimingText(source: source, metric: metric, usage: usage),
                        progress: percent / 100,
                        colorHex: metricColorHex(source: source, metric: metric, usage: usage, colorMode: colorMode),
                        hasValue: true,
                        hasWarning: warning
                    )
                }

                return MenuDropdownMetricRowModel(
                    title: rowTitle,
                    valueText: "--",
                    detailText: nil,
                    progress: 0,
                    colorHex: nil,
                    hasValue: false,
                    hasWarning: warning
                )
            }
        }

        let host = NSHostingView(
            rootView: MenuDropdownSourceCardView(
                sourceName: source.displayName,
                headerDetailText: sourceHeaderDetails[source.name],
                logoImage: logoImage(forSourceName: source.name),
                sourceColorHex: source.menuBarBrandColorHex,
                rows: rows
            )
        )
        let fit = host.fittingSize
        host.frame = NSRect(origin: .zero, size: fit)
        return host
    }

    private func metricColorHex(
        source: AISource,
        metric: AISourceMetric,
        usage: UsageResult,
        colorMode: MenuBarColorMode
    ) -> UInt32 {
        if colorMode == .pace,
           let status = paceStatus(source: source, metric: metric, usage: usage) {
            return status.colorHex
        }
        return source.menuBarBrandColorHex
    }

    private func refreshingTimingText(source: AISource, metric: AISourceMetric, usage: UsageResult) -> String? {
        let timingText = metricTimingText(source: source, metric: metric, usage: usage)
        guard let timingText else {
            return "Refreshing"
        }
        return "\(timingText) • Refreshing"
    }

    private func metricTimingText(source: AISource, metric: AISourceMetric, usage: UsageResult) -> String? {
        let paceLabel = paceStatus(source: source, metric: metric, usage: usage)?.detailText
        let percent = min(max(usage.percentRemaining, 0), 100)
        guard Int(round(percent)) < 100 else {
            return paceLabel
        }

        let now = Date()
        let baseText: String?
        if let resetDate = usage.resetDate, resetDate > now {
            baseText = "Resets \(compactDateDescription(for: resetDate, now: now))"
        } else {
            let history = UsageHistoryStore.shared.history(for: notificationScopeName(source: source, metric: metric))
            if let forecast = source.forecast(for: metric.id, current: usage, history: history),
               let fullDate = forecast.points.last(where: { $0.value >= 99.5 })?.date,
               fullDate > now {
                baseText = "Reaches 100% \(compactDateDescription(for: fullDate, now: now))"
            } else {
                baseText = nil
            }
        }

        guard let paceLabel else {
            return baseText
        }
        guard let baseText else {
            return paceLabel
        }
        return "\(baseText) • \(paceLabel)"
    }

    private func paceStatus(source: AISource, metric: AISourceMetric, usage: UsageResult) -> PaceStatus? {
        let percent = min(max(usage.percentRemaining, 0), 100)
        let history = UsageHistoryStore.shared.history(for: notificationScopeName(source: source, metric: metric))
        if let assessment = source.pacingAssessment(for: metric.id, current: usage, history: history, now: Date()) {
            if assessment.recommendation == .limitReached {
                return PaceStatus(score: assessment.score, isExhausted: true, overrideLabel: assessment.recommendation.label)
            }
            return PaceStatus(score: assessment.score, overrideLabel: assessment.recommendation.label)
        }

        guard source.pacingBehavior != .none else {
            return nil
        }

        if Int(round(percent)) >= 100 {
            return PaceStatus(score: 100)
        }

        if let forecast = source.forecast(for: metric.id, current: usage, history: history),
           let fullDate = forecast.points.last(where: { $0.value >= 99.5 })?.date {
            let hoursToFull = fullDate.timeIntervalSince(Date()) / 3600
            if hoursToFull <= 6 {
                let urgency = 30 + ((6 - max(hoursToFull, 0)) / 6) * 50
                return PaceStatus(score: urgency)
            }
            if percent < 25 {
                return PaceStatus(score: -min(60, (25 - percent) * 2.4))
            }
            return PaceStatus(score: 0)
        }

        return nil
    }

    private func compactDateDescription(for date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        if interval < 24 * 3600,
           let relative = Self.menuRelativeFormatter.string(from: interval) {
            return "in \(relative)"
        }
        return Self.menuDateFormatter.string(from: date)
    }

    private static let menuRelativeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private static let menuDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d 'at' h:mm a"
        return formatter
    }()

    @objc func refreshClicked() {
        Task { await refresh() }
    }

    @objc private func handleWillSleep(_: Notification) {
        isSleepSuspended = true
    }

    @objc private func handleDidWake(_: Notification) {
        isSleepSuspended = false
        triggerResumeRefreshIfNeeded()
    }

    @objc private func handleScreenLocked(_: Notification) {
        isLockSuspended = true
    }

    @objc private func handleScreenUnlocked(_: Notification) {
        isLockSuspended = false
        triggerResumeRefreshIfNeeded()
    }

    private func triggerResumeRefreshIfNeeded() {
        guard !isPollingSuspended else { return }
        guard loadingSources.isEmpty else { return }
        if let lastTrigger = lastResumeRefreshTriggerDate,
           Date().timeIntervalSince(lastTrigger) < resumeRefreshDebounceSeconds {
            return
        }
        lastResumeRefreshTriggerDate = Date()
        Task {
            await refresh()
            _ = await UpdateManager.shared.checkForUpdateIfDue(notify: true)
        }
    }

    private func schedulePollTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: SettingsStore.shared.pollInterval(), repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isPollingSuspended else { return }
                await self.refresh()
                _ = await UpdateManager.shared.checkForUpdateIfDue(notify: true)
            }
        }
    }

    @objc func showChart() {
        ChartWindowController.shared.configure(withSources: sources)
        ChartWindowController.shared.showWindowAndBringToFront()
    }

    @objc func showPreferences() {
        openPreferences(tab: nil)
    }

    #if DEBUG
    func simulateCodexWeeklyResetForTesting() {
        guard let source = sources.first(where: { $0.name == "Codex" }),
              let metric = source.metrics.first(where: { $0.id == "codex-pro-weekly" }) else {
            return
        }

        let now = Date()
        // Keep a dedicated low baseline for each two-click test sequence. Using
        // the last displayed value would make later runs start at 100% and skip
        // the extreme-jump path this control is meant to exercise.
        let stabilityBaseline = simulatedCodexWeeklyResetBaseline ?? UsageResult(
            remaining: 25,
            limit: 100,
            resetDate: now
        )
        simulatedCodexWeeklyResetBaseline = stabilityBaseline
        let reset = simulatedCodexWeeklyResetSample ?? UsageResult(
            remaining: 100,
            limit: 100,
            resetDate: (stabilityBaseline.resetDate ?? now).addingTimeInterval(7 * 24 * 3600),
            cycleStartDate: now
        )
        simulatedCodexWeeklyResetSample = reset
        let scope = "\(source.name)::\(metric.id)"

        guard let verifiedReset = usageSampleStabilityGate.verifiedUsage(
            scope: scope,
            incoming: reset,
            previousAccepted: stabilityBaseline
        ) else {
            return
        }
        simulatedCodexWeeklyResetSample = nil
        simulatedCodexWeeklyResetBaseline = nil

        var displayedUsages = latestUsageResults[source.name] ?? [:]
        displayedUsages[metric.id] = verifiedReset.usage
        latestUsageResults[source.name] = displayedUsages
        results[source.name] = displayedUsages.mapValues(\.formatted)
        SourceHealthStore.shared.recordSuccess(sourceName: source.name, metricId: metric.id, usage: verifiedReset.usage)
        lastRefreshDate = now
        updateMenu()
        updateStatusIcon()
        NotificationCenter.default.post(name: .aiDataRefreshed, object: nil)

        Task {
            let celebrations = await evaluateNotifications(
                sources: [source],
                results: [source.name: [metric.id: verifiedReset.usage]],
                previousOverrides: [source.name: [metric.id: verifiedReset.previousAccepted]],
                resetCurrentOverrides: verifiedReset.confirmedResetUsage.map {
                    [source.name: [metric.id: $0]]
                } ?? [:],
                confirmedResetMetricIds: verifiedReset.wasConfirmed
                    ? [source.name: [metric.id]]
                    : [:]
            )
            playResetCelebrations(celebrations)
        }
    }
    #endif

    func openPreferences(tab: PreferencesTab?) {
        PreferencesWindowController.shared.configure(withSources: sources)
        if let tab {
            PreferencesWindowController.shared.selectTab(tab)
        }
        PreferencesWindowController.shared.showWindowAndBringToFront()
    }

    @discardableResult
    func refresh(origin: TrackedUsageObservationOrigin = .poll) async -> Bool {
        guard loadingSources.isEmpty else { return false }
        let enabled = sources.filter { SettingsStore.shared.isEnabled(sourceName: $0.name) }
        for source in enabled { loadingSources.insert(source.name) }
        updateMenu()

        var percentValues: [Double] = []
        var usageResultsBySource: [String: [String: UsageResult]] = [:]
        var notificationPreviousOverrides: [String: [String: UsageResult]] = [:]
        var notificationResetCurrentOverrides: [String: [String: UsageResult]] = [:]
        var confirmedResetMetricIds: [String: Set<String>] = [:]
        var trackedObservations: [TrackedUsageObservation] = []

        await withTaskGroup(of: (String, Result<MetricFetchResult, Error>).self) { group in
            for source in enabled {
                group.addTask {
                    do {
                        let fetchResult = try await self.fetchUsageByMetric(for: source)
                        return (source.name, .success(fetchResult))
                    } catch {
                        return (source.name, .failure(error))
                    }
                }
            }

            for await (name, result) in group {
                guard let source = enabled.first(where: { $0.name == name }) else {
                    loadingSources.remove(name)
                    updateMenu()
                    continue
                }
                switch result {
                case let .success(fetchResult):
                    var metricUsages: [String: UsageResult] = [:]
                    let previousUsages = latestUsageResults[name] ?? [:]

                    func recordVerifiedUsage(_ verifiedUsage: UsageSampleStabilityGate.VerifiedUsage, metricId: String) {
                        metricUsages[metricId] = verifiedUsage.usage
                        if verifiedUsage.wasConfirmed {
                            notificationPreviousOverrides[name, default: [:]][metricId] = verifiedUsage.previousAccepted
                        }
                        if let resetUsage = verifiedUsage.confirmedResetUsage {
                            notificationResetCurrentOverrides[name, default: [:]][metricId] = resetUsage
                        }
                        if verifiedUsage.wasConfirmed, verifiedUsage.confirmedResetUsage != nil {
                            confirmedResetMetricIds[name, default: []].insert(metricId)
                        }
                    }

                    for (metricId, incomingUsage) in fetchResult.usages {
                        let scope = "\(name)::\(metricId)"
                        let previousAccepted = stablePreviousUsage(
                            source: source,
                            metricId: metricId,
                            displayedUsage: previousUsages[metricId]
                        )
                        guard source.pacingBehavior == .resetWindow else {
                            recordVerifiedUsage(
                                UsageSampleStabilityGate.VerifiedUsage(
                                    usage: incomingUsage,
                                    previousAccepted: previousAccepted ?? incomingUsage,
                                    wasConfirmed: false
                                ),
                                metricId: metricId
                            )
                            continue
                        }
                        if let verifiedUsage = usageSampleStabilityGate.verifiedUsage(
                            scope: scope,
                            incoming: incomingUsage,
                            previousAccepted: previousAccepted
                        ) {
                            recordVerifiedUsage(verifiedUsage, metricId: metricId)
                        }
                    }

                    guard !metricUsages.isEmpty else {
                        loadingSources.remove(name)
                        updateMenu()
                        updateStatusIcon()
                        continue
                    }
                    var displayedUsages = previousUsages
                    for (metricId, usage) in metricUsages {
                        displayedUsages[metricId] = usage
                    }
                    let metricDisplays = displayedUsages.mapValues { $0.formatted }
                    results[name] = metricDisplays
                    latestUsageResults[name] = displayedUsages
                    usageResultsBySource[name] = metricUsages
                    sourceHeaderDetails[name] = await headerDetailText(for: source)

                    if SettingsStore.shared.trackingEnabled, let activeSession = trackedUsageStore.activeSession {
                        let timestamp = Date()
                        let shouldRecord = origin != .poll || !activeSession.observations.isEmpty
                        let observations: [TrackedUsageObservation] = shouldRecord ? metricUsages.map { metricID, usage in
                            let title = source.metrics.first(where: { $0.id == metricID })?.title ?? metricID
                            return TrackedUsageObservation(timestamp: timestamp, sourceName: source.name, metricID: metricID, metricTitle: title, remaining: usage.remaining, limit: usage.limit, resetDate: usage.resetDate, cycleStartDate: usage.cycleStartDate, origin: origin)
                        } : []
                        trackedObservations.append(contentsOf: observations)
                    }

                    if source.metrics.count > 1 {
                        for metric in source.metrics {
                            guard let metricUsage = metricUsages[metric.id] else { continue }
                            UsageHistoryStore.shared.append(
                                sourceName: metricHistorySeriesName(source: source, metric: metric),
                                usage: metricUsage
                            )
                        }
                    }

                    recordMetricHealth(source: source, metricUsages: metricUsages, errorsByMetric: fetchResult.errorsByMetric)

                    let enabledMetricSet = Set(enabledMetrics(for: source).map(\.id))
                    let usableMetricIds: [String]
                    if enabledMetricSet.isEmpty {
                        usableMetricIds = source.metrics.map(\.id)
                    } else {
                        usableMetricIds = source.metrics.map(\.id).filter { enabledMetricSet.contains($0) }
                    }

                    for metricId in usableMetricIds {
                        guard let metricUsage = metricUsages[metricId] else { continue }
                        let p = min(max(metricUsage.percentRemaining, 0), 100)
                        percentValues.append(p)
                    }
                case let .failure(error):
                    let mappedMetricId: String
                    let mappedError: Error
                    if let scoped = error as? SourceMetricFetchError {
                        mappedMetricId = scoped.metricId
                        mappedError = scoped.underlying
                        recordMetricHealth(source: source, metricUsages: [:], errorsByMetric: scoped.errorsByMetric)
                    } else {
                        mappedMetricId = source.metrics.first?.id ?? "default"
                        mappedError = error
                        let presentation = source.mapFetchError(for: mappedMetricId, mappedError)
                        if source.metrics.count <= 1 {
                            SourceHealthStore.shared.recordFailure(sourceName: name, presentation: presentation)
                        } else {
                            SourceHealthStore.shared.recordFailure(sourceName: name, metricId: mappedMetricId, presentation: presentation)
                        }
                    }
                    results[name] = fallbackDisplays(source: source, currentDisplays: results[name] ?? [:])
                    appendFallbackPercents(source: source, into: &percentValues)
                }
                loadingSources.remove(name)
                updateMenu()
                updateStatusIcon()
            }
        }

        trackedUsageStore.append(contentsOf: trackedObservations)

        lastRefreshDate = Date()
        let celebrations = await evaluateNotifications(
            sources: enabled,
            results: usageResultsBySource,
            previousOverrides: notificationPreviousOverrides,
            resetCurrentOverrides: notificationResetCurrentOverrides,
            confirmedResetMetricIds: confirmedResetMetricIds
        )
        playResetCelebrations(celebrations)

        if percentValues.isEmpty {
            latestUsageResults = latestUsageResults.filter { key, _ in
                enabled.contains { $0.name == key }
            }
        }
        updateStatusIcon()

        NotificationCenter.default.post(name: .aiDataRefreshed, object: nil)
        return true
    }

    private func refreshForTrackingBoundary(origin: TrackedUsageObservationOrigin) async {
        while true {
            while !loadingSources.isEmpty {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if await refresh(origin: origin) {
                return
            }
        }
    }

    private func enabledMetrics(for source: AISource) -> [AISourceMetric] {
        source.metrics.filter { SettingsStore.shared.isMetricEnabled(sourceName: source.name, metricId: $0.id) }
    }

    private func stablePreviousUsage(
        source: AISource,
        metricId: String,
        displayedUsage: UsageResult?
    ) -> UsageResult? {
        let scope = source.metrics.count <= 1 ? source.name : "\(source.name)::\(metricId)"
        let persistedHistory = UsageHistoryStore.shared.history(for: scope).last?.usage
        let sourceHealth: UsageResult?
        if source.metrics.count <= 1 {
            sourceHealth = SourceHealthStore.shared.health(for: source.name)?.lastSuccessfulUsage
        } else {
            sourceHealth = SourceHealthStore.shared.health(for: source.name, metricId: metricId)?.lastSuccessfulUsage
        }

        // An in-memory value can be stale or come from a non-polling path.
        // The lowest recent persisted reading is the safe baseline for an
        // apparent reset: it can only make a near-full jump more cautious.
        return [displayedUsage, persistedHistory, sourceHealth]
            .compactMap { $0 }
            .min { $0.percentRemaining < $1.percentRemaining }
    }

    private func playResetCelebrations(_ celebrations: [ResetCelebration]) {
        for celebration in Set(celebrations) {
            ResetCelebrationController.shared.celebrate(
                sourceColorHex: celebration.sourceColorHex,
                anchor: statusItemRingScreenPoint(
                    sourceName: celebration.sourceName,
                    metricId: celebration.metricId
                )
            )
        }
    }

    private func statusItemRingScreenPoint(sourceName: String, metricId: String) -> CGPoint? {
        let metrics = selectedMetricsForStatusIcon()
        guard let index = metrics.firstIndex(where: {
            $0.sourceName == sourceName && $0.metricId == metricId
        }),
        let button = statusItem?.button,
        let window = button.window else {
            return nil
        }

        let layoutWidth = statusRingSize * CGFloat(metrics.count) + statusRingSpacing * CGFloat(max(0, metrics.count - 1))
        guard layoutWidth > 0 else { return nil }
        let imageRect = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
        let scale = min(imageRect.width / layoutWidth, imageRect.height / statusRingSize)
        let renderedWidth = layoutWidth * scale
        let renderedOriginX = imageRect.midX - renderedWidth / 2
        let x = renderedOriginX + (CGFloat(index) * (statusRingSize + statusRingSpacing) + statusRingSize / 2) * scale
        let pointInWindow = button.convert(NSPoint(x: x, y: imageRect.midY), to: nil)
        return window.convertPoint(toScreen: pointInWindow)
    }

    private func metricHistorySeriesName(source: AISource, metric: AISourceMetric) -> String {
        "\(source.name) - \(metric.title)"
    }

    @objc private func settingsChanged(_ note: Notification) {
        let enabled = Set(sources.filter { SettingsStore.shared.isEnabled(sourceName: $0.name) }.map { $0.name })
        // prune results for disabled sources
        results = results.filter { enabled.contains($0.key) }
        latestUsageResults = latestUsageResults.filter { enabled.contains($0.key) }
        updateMenu()
        updateStatusIcon()

        schedulePollTimer()
    }

    private struct IconRingMetric {
        let sourceName: String
        let sourceDisplayName: String
        let metricId: String
        let metricTitle: String
        let menuBarBadgeText: String?
        let percentRemaining: Double
        let hasUsage: Bool
        let sourceColorHex: UInt32
        let paceStatus: PaceStatus?
    }

    private struct PaceStatus {
        let score: Double
        var isExhausted: Bool = false
        var overrideLabel: String?

        var label: String {
            if let overrideLabel {
                return overrideLabel
            }
            if isExhausted {
                return "Limit reached"
            }
            if score >= 30 {
                return "Push hard"
            }
            if score >= 15 {
                return "Push"
            }
            if score > 5 {
                return "Push lightly"
            }
            if score <= -30 {
                return "Conserve hard"
            }
            if score <= -15 {
                return "Conserve"
            }
            if score < -5 {
                return "Conserve lightly"
            }
            return "On pace"
        }

        var detailText: String {
            if isExhausted {
                return label
            }
            let rounded = Int(round(score))
            if rounded > 0 {
                return "\(label) (+\(rounded) pts)"
            }
            return "\(label) (\(rounded) pts)"
        }

        var colorHex: UInt32 {
            if isExhausted {
                return Self.conserveColorHex
            }
            let clampedScore = min(max(score, -100), 100)
            if abs(clampedScore) <= 5 {
                return Self.onPaceColorHex
            }
            if clampedScore > 0 {
                return Self.interpolateHex(from: Self.onPaceColorHex, to: Self.pushColorHex, fraction: clampedScore / 100)
            }
            // Ease toward red faster so bad pacing reads clearly red well before -100.
            let fraction = (abs(clampedScore) / 100).squareRoot()
            return Self.interpolateHex(from: Self.onPaceColorHex, to: Self.conserveColorHex, fraction: fraction)
        }

        private static let pushColorHex: UInt32 = 0x0DE2CF
        private static let onPaceColorHex: UInt32 = 0x955CFE
        private static let conserveColorHex: UInt32 = 0xFF1E33

        private static func interpolateHex(from start: UInt32, to end: UInt32, fraction: Double) -> UInt32 {
            let t = min(max(fraction, 0), 1)
            let startR = Double((start >> 16) & 0xFF)
            let startG = Double((start >> 8) & 0xFF)
            let startB = Double(start & 0xFF)
            let endR = Double((end >> 16) & 0xFF)
            let endG = Double((end >> 8) & 0xFF)
            let endB = Double(end & 0xFF)

            let red = UInt32(round(startR + (endR - startR) * t))
            let green = UInt32(round(startG + (endG - startG) * t))
            let blue = UInt32(round(startB + (endB - startB) * t))
            return (red << 16) | (green << 8) | blue
        }
    }
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        updateTrackingSessionTitle(on: button)
        let metrics = selectedMetricsForStatusIcon()
        if metrics.isEmpty {
            if let placeholder = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "No selected metrics") {
                placeholder.isTemplate = true
                button.image = placeholder
                button.toolTip = nil
            }
            return
        }

        let appearance = SettingsStore.shared.menuBarAppearance
        if let image = ringMetersImage(
            metrics: metrics,
            colorMode: appearance.colorMode,
            centerMode: appearance.centerContentMode,
            showMetricBadges: appearance.showMetricBadges
        ) {
            button.image = image
        }
        button.toolTip = nil
    }

    private func updateTrackingSessionTitle(on button: NSStatusBarButton) {
        guard SettingsStore.shared.showTrackingSessionInMenuBar,
              let session = trackedUsageStore.activeSession,
              let label = trackedUsageStore.labels.first(where: { $0.id == session.labelID }) else {
            trackingIndicatorPulseTimer?.invalidate()
            trackingIndicatorPulseTimer = nil
            button.title = ""
            button.imagePosition = .imageOnly
            return
        }
        applyTrackingSessionTitle(session: session, color: NSColor(hexString: label.colorHex) ?? .systemPurple, alpha: 1, button: button)
        if trackingIndicatorPulseTimer == nil {
            trackingIndicatorPulseTimer = Timer.scheduledTimer(timeInterval: 0.12, target: self, selector: #selector(pulseTrackingIndicator), userInfo: nil, repeats: true)
        }
    }

    @objc private func pulseTrackingIndicator() {
        guard let button = statusItem?.button,
              let active = trackedUsageStore.activeSession,
              SettingsStore.shared.showTrackingSessionInMenuBar,
              let current = trackedUsageStore.labels.first(where: { $0.id == active.labelID }) else { return }
        trackingIndicatorPulsePhase += 0.28
        applyTrackingSessionTitle(session: active, color: NSColor(hexString: current.colorHex) ?? .systemPurple, alpha: 0.56 + 0.44 * ((sin(trackingIndicatorPulsePhase) + 1) / 2), button: button)
    }

    private func applyTrackingSessionTitle(session: TrackedSession, color: NSColor, alpha: CGFloat, button: NSStatusBarButton) {
        button.attributedTitle = NSAttributedString(
            string: "● \(session.labelNameSnapshot) ",
            attributes: [.foregroundColor: color.withAlphaComponent(alpha), .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
        )
        button.imagePosition = .imageRight
    }

    private func selectedMetricsForStatusIcon() -> [IconRingMetric] {
        let enabledSources = sources.filter { SettingsStore.shared.isEnabled(sourceName: $0.name) }
        let appearance = SettingsStore.shared.menuBarAppearance
        let configuredSelections = appearance.selectedMetrics
        let validSelections = configuredSelections.filter { selection in
            guard let source = enabledSources.first(where: { $0.name == selection.sourceName }) else { return false }
            guard SettingsStore.shared.isMetricEnabled(sourceName: selection.sourceName, metricId: selection.metricId) else { return false }
            return source.metrics.contains(where: { $0.id == selection.metricId })
        }

        let chosenSelections: [MenuBarMetricSelection]
        if configuredSelections.isEmpty {
            chosenSelections = enabledSources
                .flatMap { source in
                    source.metrics
                        .filter { SettingsStore.shared.isMetricEnabled(sourceName: source.name, metricId: $0.id) }
                        .map { metric in MenuBarMetricSelection(sourceName: source.name, metricId: metric.id) }
                }
                .map { $0 }
        } else {
            // Honor explicit menu-bar selections; do not silently fall back to unrelated metrics.
            chosenSelections = validSelections
        }

        return chosenSelections.compactMap { selection in
            guard let source = enabledSources.first(where: { $0.name == selection.sourceName }),
                  let metric = source.metrics.first(where: { $0.id == selection.metricId }) else {
                return nil
            }
            let usage = usageResultForIcon(sourceName: selection.sourceName, metricId: selection.metricId)
            let clampedPercent = usage.map { min(max($0.percentRemaining, 0), 100) } ?? 0
            return IconRingMetric(
                sourceName: source.name,
                sourceDisplayName: source.displayName,
                metricId: metric.id,
                metricTitle: metric.title,
                menuBarBadgeText: metric.menuBarBadgeText,
                percentRemaining: clampedPercent,
                hasUsage: usage != nil,
                sourceColorHex: source.menuBarBrandColorHex,
                paceStatus: usage.flatMap { paceStatus(source: source, metric: metric, usage: $0) }
            )
        }
    }

    private func usageResultForIcon(sourceName: String, metricId: String) -> UsageResult? {
        if let usage = latestUsageResults[sourceName]?[metricId] {
            return usage
        }
        guard let source = sources.first(where: { $0.name == sourceName }) else { return nil }
        if source.metrics.count <= 1 {
            return SourceHealthStore.shared.health(for: sourceName)?.lastSuccessfulUsage
        }
        return SourceHealthStore.shared.health(for: sourceName, metricId: metricId)?.lastSuccessfulUsage
    }

    private func ringMetersImage(
        metrics: [IconRingMetric],
        colorMode: MenuBarColorMode,
        centerMode: MenuBarCenterContentMode,
        showMetricBadges: Bool
    ) -> NSImage? {
        let count = metrics.count
        guard count > 0 else { return nil }

        let width = statusRingSize * CGFloat(count) + statusRingSpacing * CGFloat(max(0, count - 1))
        let size = NSSize(width: width, height: statusRingSize)
        let image = NSImage(size: size)
        image.isTemplate = colorMode == .monochrome

        image.lockFocus()
        defer { image.unlockFocus() }
        guard let context = NSGraphicsContext.current?.cgContext else { return nil }

        for index in 0..<count {
            let metric = metrics[index]
            let rect = CGRect(
                x: CGFloat(index) * (statusRingSize + statusRingSpacing),
                y: 0,
                width: statusRingSize,
                height: statusRingSize
            )
            drawRing(
                in: context,
                rect: rect.insetBy(dx: 0.7, dy: 0.7),
                metric: metric,
                colorMode: colorMode,
                centerMode: centerMode,
                showMetricBadges: showMetricBadges
            )
        }

        return image
    }

    private func drawRing(
        in context: CGContext,
        rect: CGRect,
        metric: IconRingMetric,
        colorMode: MenuBarColorMode,
        centerMode: MenuBarCenterContentMode,
        showMetricBadges: Bool
    ) {
        let percent = metric.percentRemaining
        let clampedPercent = min(max(percent, 0), 100)
        let progress = CGFloat(clampedPercent / 100)
        let lineWidth: CGFloat = 2.2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = (min(rect.width, rect.height) / 2) - (lineWidth / 2)
        let startAngle = CGFloat.pi / 2
        let endAngle = startAngle - (2 * CGFloat.pi * progress)

        let trackPath = CGMutablePath()
        trackPath.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        context.addPath(trackPath)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setStrokeColor(trackColor(for: colorMode).cgColor)
        context.strokePath()

        guard progress > 0 else {
            drawRingCenter(in: rect, metric: metric, colorMode: colorMode, centerMode: centerMode)
            if showMetricBadges {
                drawMetricBadgeIfNeeded(in: context, rect: rect, metric: metric, colorMode: colorMode)
            }
            return
        }

        let progressPath = CGMutablePath()
        progressPath.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)

        switch colorMode {
        case .monochrome:
            context.addPath(progressPath)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.95).cgColor)
            context.strokePath()
        case .brandGradient:
            context.saveGState()
            context.addPath(progressPath)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.replacePathWithStrokedPath()
            context.clip()
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [brandPrimaryColor.cgColor, brandAccentColor.cgColor] as CFArray,
                locations: [0, 1]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: rect.minX, y: rect.maxY),
                    end: CGPoint(x: rect.maxX, y: rect.minY),
                    options: []
                )
            }
            context.restoreGState()
        case .sourceSolid:
            context.addPath(progressPath)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setStrokeColor(colorFromHex(metric.sourceColorHex).cgColor)
            context.strokePath()
        case .pace:
            context.addPath(progressPath)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setStrokeColor(paceColor(for: metric).cgColor)
            context.strokePath()
        }

        drawRingCenter(in: rect, metric: metric, colorMode: colorMode, centerMode: centerMode)
        if showMetricBadges {
            drawMetricBadgeIfNeeded(in: context, rect: rect, metric: metric, colorMode: colorMode)
        }
    }

    private var brandPrimaryColor: NSColor { NSColor(calibratedRed: 147 / 255, green: 90 / 255, blue: 253 / 255, alpha: 1) }
    private var brandAccentColor: NSColor { NSColor(calibratedRed: 13 / 255, green: 228 / 255, blue: 209 / 255, alpha: 1) }

    private func trackColor(for mode: MenuBarColorMode) -> NSColor {
        switch mode {
        case .monochrome:
            return NSColor.black.withAlphaComponent(0.25)
        case .brandGradient, .sourceSolid, .pace:
            return NSColor(calibratedWhite: 0.45, alpha: 0.28)
        }
    }

    private func drawRingCenter(
        in rect: CGRect,
        metric: IconRingMetric,
        colorMode: MenuBarColorMode,
        centerMode: MenuBarCenterContentMode
    ) {
        let foreground: NSColor
        switch colorMode {
        case .monochrome:
            foreground = NSColor.black.withAlphaComponent(0.95)
        case .pace:
            foreground = paceColor(for: metric)
        case .brandGradient, .sourceSolid:
            foreground = NSColor.white.withAlphaComponent(0.96)
        }

        let centerRect = rect.insetBy(dx: 3.8, dy: 3.8)
        switch centerMode {
        case .logo:
            if let image = logoImage(for: metric) {
                drawCenteredImage(image, in: centerRect, tint: colorMode == .pace ? foreground : nil)
                return
            }
            drawPercentageCenter(metric: metric, in: centerRect, color: foreground)
        case .percentage:
            drawPercentageCenter(metric: metric, in: centerRect, color: foreground)
        case .pacePoints:
            drawPacePointsCenter(metric: metric, in: centerRect, color: foreground)
        }
    }

    private func logoImage(for metric: IconRingMetric) -> NSImage? {
        logoImage(forSourceName: metric.sourceName)
    }

    private func logoImage(forSourceName sourceName: String) -> NSImage? {
        let assetBaseName = logoBaseName(forSourceName: sourceName)
        if let inMemory = NSImage(named: assetBaseName) {
            return inMemory
        }

        // Avoid Bundle.module here: if SwiftPM resource bundle placement differs in packaged builds,
        // Bundle.module can hard-fail with fatalError during initialization.
        let appBundleCandidates: [URL?] = [
            Bundle.main.bundleURL.appendingPathComponent("Rashun_Rashun.bundle"),
            Bundle.main.resourceURL?.appendingPathComponent("Rashun_Rashun.bundle")
        ]
        for bundleURL in appBundleCandidates.compactMap({ $0 }).filter({ FileManager.default.fileExists(atPath: $0.path) }) {
            let logoCandidates = [
                bundleURL.appendingPathComponent("SourceLogos/\(assetBaseName).png"),
                bundleURL.appendingPathComponent("Resources/SourceLogos/\(assetBaseName).png"),
                bundleURL.appendingPathComponent("\(assetBaseName).png")
            ]
            for candidate in logoCandidates where FileManager.default.fileExists(atPath: candidate.path) {
                if let image = NSImage(contentsOf: candidate) {
                    return image
                }
            }
        }

        let localCandidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/Resources/SourceLogos/\(assetBaseName).png"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/SourceLogos/\(assetBaseName).png")
        ]
        for candidate in localCandidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let image = NSImage(contentsOf: candidate) {
                return image
            }
        }

        return nil
    }

    private func logoBaseName(forSourceName sourceName: String) -> String {
        let lowered = sourceName.lowercased()
        return lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
    }

    private func drawPercentageCenter(metric: IconRingMetric, in rect: CGRect, color: NSColor) {
        guard metric.hasUsage else {
            drawCenterText("--", in: rect, color: color.withAlphaComponent(0.9), size: 6.0, weight: .semibold)
            return
        }
        let percentRemaining = metric.percentRemaining
        let value = Int(round(percentRemaining))
        let text = "\(value)"
        let fontSize: CGFloat
        if value >= 100 {
            fontSize = 5.6
        } else if value >= 10 {
            fontSize = 6.6
        } else {
            fontSize = 7.0
        }
        drawCenterText(text, in: rect, color: color, size: fontSize, weight: .semibold)
    }

    private func drawPacePointsCenter(metric: IconRingMetric, in rect: CGRect, color: NSColor) {
        guard let status = metric.paceStatus else {
            drawCenterText("--", in: rect, color: color.withAlphaComponent(0.9), size: 6.0, weight: .semibold)
            return
        }

        let value = Int(round(status.score))
        let text = value > 0 ? "+\(value)" : "\(value)"
        let fontSize: CGFloat
        if abs(value) >= 100 {
            fontSize = 4.8
        } else if abs(value) >= 10 {
            fontSize = 5.8
        } else {
            fontSize = 6.8
        }
        drawCenterText(text, in: rect, color: color, size: fontSize, weight: .bold)
    }

    private func drawCenterText(_ text: String, in rect: CGRect, color: NSColor, size: CGFloat, weight: NSFont.Weight) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let nsText = NSString(string: text)
        let textSize = nsText.size(withAttributes: attributes)
        let drawRect = CGRect(
            x: rect.midX - (textSize.width / 2),
            y: rect.midY - (textSize.height / 2),
            width: textSize.width,
            height: textSize.height
        )
        nsText.draw(in: drawRect, withAttributes: attributes)
    }

    private func drawCenteredImage(_ image: NSImage, in rect: CGRect, tint: NSColor? = nil) {
        guard image.size.width > 0, image.size.height > 0 else {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }

        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let drawSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawRect = CGRect(
            x: rect.midX - (drawSize.width / 2),
            y: rect.midY - (drawSize.height / 2),
            width: drawSize.width,
            height: drawSize.height
        )
        guard let tint else {
            image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }

        tint.setFill()
        drawRect.fill()
        image.draw(in: drawRect, from: .zero, operation: .destinationIn, fraction: 1)
    }

    private func drawMetricBadgeIfNeeded(
        in context: CGContext,
        rect: CGRect,
        metric: IconRingMetric,
        colorMode: MenuBarColorMode
    ) {
        guard let badgeText = metric.menuBarBadgeText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !badgeText.isEmpty else {
            return
        }

        let maxTextWidth = rect.width - 4.0
        var fontSize: CGFloat = badgeText.count > 5 ? 3.7 : badgeText.count > 2 ? 4.6 : 5.2
        var font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let nsText = NSString(string: badgeText)
        var textSize = nsText.size(withAttributes: attributes)
        while textSize.width > maxTextWidth, fontSize > 3.2 {
            fontSize -= 0.2
            font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
            textSize = nsText.size(withAttributes: [
                .font: font,
                .foregroundColor: NSColor.white
            ])
        }
        let finalAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let horizontalPadding: CGFloat = 2.1
        let badgeSize = CGSize(
            width: min(max(textSize.width + horizontalPadding * 2, 8.0), rect.width - 1),
            height: 7.0
        )
        let badgeRect = CGRect(
            x: rect.maxX - badgeSize.width,
            y: rect.minY,
            width: badgeSize.width,
            height: badgeSize.height
        )
        let badgePath = CGPath(
            roundedRect: badgeRect,
            cornerWidth: badgeRect.height / 2,
            cornerHeight: badgeRect.height / 2,
            transform: nil
        )

        context.saveGState()
        context.addPath(badgePath)
        context.setFillColor(badgeFillColor(for: metric, colorMode: colorMode).cgColor)
        context.fillPath()

        let textRect = CGRect(
            x: badgeRect.midX - (textSize.width / 2),
            y: badgeRect.midY - (textSize.height / 2) + 0.2,
            width: textSize.width,
            height: textSize.height
        )

        if colorMode == .monochrome {
            context.setBlendMode(.clear)
        }
        nsText.draw(in: textRect, withAttributes: finalAttributes)
        context.restoreGState()
    }

    private func badgeFillColor(for metric: IconRingMetric, colorMode: MenuBarColorMode) -> NSColor {
        switch colorMode {
        case .monochrome:
            return NSColor.black.withAlphaComponent(0.95)
        case .brandGradient:
            return darkerColor(brandAccentColor)
        case .sourceSolid:
            return darkerColor(colorFromHex(metric.sourceColorHex))
        case .pace:
            return darkerColor(paceColor(for: metric))
        }
    }

    private func paceColor(for metric: IconRingMetric) -> NSColor {
        if let paceStatus = metric.paceStatus {
            return colorFromHex(paceStatus.colorHex)
        }
        return colorFromHex(metric.sourceColorHex)
    }

    private func darkerColor(_ color: NSColor) -> NSColor {
        let converted = color.usingColorSpace(.sRGB) ?? color
        return NSColor(
            calibratedRed: max(0, converted.redComponent * 0.58),
            green: max(0, converted.greenComponent * 0.58),
            blue: max(0, converted.blueComponent * 0.58),
            alpha: converted.alphaComponent
        )
    }

    private func colorFromHex(_ hex: UInt32) -> NSColor {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        return NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }

    private func evaluateNotifications(
        sources: [AISource],
        results: [String: [String: UsageResult]],
        previousOverrides: [String: [String: UsageResult]] = [:],
        resetCurrentOverrides: [String: [String: UsageResult]] = [:],
        confirmedResetMetricIds: [String: Set<String>] = [:]
    ) async -> [ResetCelebration] {
        var celebrations: [ResetCelebration] = []
        for source in sources {
            let metricUsages = results[source.name] ?? [:]
            for metric in enabledMetrics(for: source) {
                guard let current = metricUsages[metric.id] else { continue }
                let scopedName = notificationScopeName(source: source, metric: metric)
                SettingsStore.shared.ensureNotificationRules(
                    source: source,
                    metricId: metric.id,
                    scopeName: scopedName
                )
                let rules = SettingsStore.shared.ruleSettings(for: scopedName)
                let history = UsageHistoryStore.shared.history(for: scopedName)
                let previous = previousOverrides[source.name]?[metric.id].map {
                    UsageSnapshot(timestamp: Date(), usage: $0)
                } ?? history.last
                let definitions = source.notificationDefinitions(for: metric.id)

                for rule in rules where rule.isEnabled {
                    guard let definition = definitions.first(where: { $0.id == rule.ruleId }) else { continue }
                    let ruleId = rule.ruleId
                    guard ruleId != "metricReset" || confirmedResetMetricIds[source.name]?.contains(metric.id) == true else {
                        continue
                    }
                    let valueProvider: (String, Double) -> Double = { inputId, defaultValue in
                        SettingsStore.shared.ruleInputValue(sourceName: scopedName, ruleId: ruleId, inputId: inputId, defaultValue: defaultValue)
                    }

                    let ctx = NotificationContext(
                        sourceName: source.name,
                        metricId: metric.id,
                        metricTitle: metric.title,
                        current: ruleId == "metricReset"
                            ? resetCurrentOverrides[source.name]?[metric.id] ?? current
                            : current,
                        previous: previous,
                        history: history,
                        inputValue: valueProvider
                    )

                    guard let event = definition.evaluate(ctx) else { continue }

                    let state = SettingsStore.shared.ruleState(sourceName: scopedName, ruleId: ruleId)
                    guard shouldSend(event: event, state: state) else { continue }
                    NotificationManager.shared.sendNotification(
                        title: event.title,
                        body: event.body,
                        route: .usageHistory
                    )
                    let newState = NotificationRuleState(lastFiredAt: Date(), lastFiredCycleKey: event.cycleKey)
                    SettingsStore.shared.setRuleState(newState, sourceName: scopedName, ruleId: ruleId)
                    if ruleId == "metricReset" {
                        celebrations.append(
                            ResetCelebration(
                                sourceName: source.name,
                                metricId: metric.id,
                                sourceColorHex: source.menuBarBrandColorHex
                            )
                        )
                    }
                }

                UsageHistoryStore.shared.append(sourceName: scopedName, usage: current)
            }
        }
        return celebrations
    }

    private func shouldSend(event: NotificationEvent, state: NotificationRuleState?) -> Bool {
        shouldSendNotification(event: event, state: state)
    }

    private func notificationScopeName(source: AISource, metric: AISourceMetric) -> String {
        if source.metrics.count <= 1 {
            return source.name
        }
        return "\(source.name)::\(metric.id)"
    }

    private func sourceHasWarning(_ source: AISource) -> Bool {
        if source.metrics.count <= 1 {
            return SourceHealthStore.shared.health(for: source.name)?.shortErrorMessage != nil
        }
        let metrics = enabledMetrics(for: source)
        return metrics.contains { metric in
            metricHasWarning(source: source, metricId: metric.id)
        }
    }

    private func metricHasWarning(source: AISource, metricId: String) -> Bool {
        if source.metrics.count <= 1 {
            return SourceHealthStore.shared.health(for: source.name)?.shortErrorMessage != nil
        }
        return SourceHealthStore.shared.health(for: source.name, metricId: metricId)?.shortErrorMessage != nil
    }

    private func recordMetricHealth(source: AISource, metricUsages: [String: UsageResult], errorsByMetric: [String: Error]) {
        if source.metrics.count <= 1 {
            guard let metric = source.metrics.first else { return }
            if let usage = metricUsages[metric.id] {
                SourceHealthStore.shared.recordSuccess(sourceName: source.name, usage: usage)
                return
            }
            if let error = errorsByMetric[metric.id] {
                let presentation = source.mapFetchError(for: metric.id, error)
                SourceHealthStore.shared.recordFailure(sourceName: source.name, presentation: presentation)
            }
            return
        }

        for metric in source.metrics {
            if let usage = metricUsages[metric.id] {
                SourceHealthStore.shared.recordSuccess(sourceName: source.name, metricId: metric.id, usage: usage)
            } else if let error = errorsByMetric[metric.id] {
                let presentation = source.mapFetchError(for: metric.id, error)
                SourceHealthStore.shared.recordFailure(sourceName: source.name, metricId: metric.id, presentation: presentation)
            }
        }
    }

    private func fallbackDisplays(source: AISource, currentDisplays: [String: String]) -> [String: String] {
        if source.metrics.count <= 1 {
            guard let metricId = source.metrics.first?.id else { return [:] }
            if let previous = SourceHealthStore.shared.health(for: source.name)?.lastSuccessfulUsage {
                return [metricId: previous.formatted]
            }
            return [:]
        }

        var fallback = currentDisplays
        for metric in source.metrics {
            if fallback[metric.id] != nil { continue }
            if let previous = SourceHealthStore.shared.health(for: source.name, metricId: metric.id)?.lastSuccessfulUsage {
                fallback[metric.id] = previous.formatted
            }
        }
        return fallback
    }

    private func appendFallbackPercents(source: AISource, into percents: inout [Double]) {
        let enabledMetricSet = Set(enabledMetrics(for: source).map(\.id))
        let usableMetricIds: [String]
        if enabledMetricSet.isEmpty {
            usableMetricIds = source.metrics.map(\.id)
        } else {
            usableMetricIds = source.metrics.map(\.id).filter { enabledMetricSet.contains($0) }
        }

        if source.metrics.count <= 1 {
            if let previous = SourceHealthStore.shared.health(for: source.name)?.lastSuccessfulUsage {
                let p = min(max(previous.percentRemaining, 0), 100)
                percents.append(p)
            }
            return
        }

        for metricId in usableMetricIds {
            guard let previous = SourceHealthStore.shared.health(for: source.name, metricId: metricId)?.lastSuccessfulUsage else { continue }
            let p = min(max(previous.percentRemaining, 0), 100)
            percents.append(p)
        }
    }

    private func fetchUsageByMetric(for source: AISource) async throws -> MetricFetchResult {
        var usages: [String: UsageResult] = [:]
        var errorsByMetric: [String: Error] = [:]
        var firstError: (metricId: String, error: Error)?
        for metric in source.metrics {
            do {
                usages[metric.id] = try await source.fetchUsage(for: metric.id)
            } catch {
                errorsByMetric[metric.id] = error
                if firstError == nil {
                    firstError = (metric.id, error)
                }
            }
        }
        if usages.isEmpty, let firstError {
            throw SourceMetricFetchError(metricId: firstError.metricId, underlying: firstError.error, errorsByMetric: errorsByMetric)
        }
        return MetricFetchResult(usages: usages, errorsByMetric: errorsByMetric)
    }

    private func headerDetailText(for source: AISource) async -> String? {
        guard source.name == "Codex",
              let balance = await CodexSource.latestResetBalance(),
              balance.count > 0 else {
            return nil
        }

        var parts = ["\(balance.count) \(balance.count == 1 ? "reset" : "resets")"]
        if let nextExpiration = balance.nextExpiration {
            parts.append("next exp. \(compactDaysDescription(for: nextExpiration, now: Date()))")
        }
        return parts.joined(separator: ", ")
    }

    private func compactDaysDescription(for date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "now" }
        if seconds < 24 * 3600 {
            if let relative = Self.menuRelativeFormatter.string(from: seconds) {
                return "in \(relative)"
            }
            return Self.menuDateFormatter.string(from: date)
        }
        let days = Int(ceil(seconds / (24 * 3600)))
        return days == 1 ? "1 day" : "\(days) days"
    }

}

private extension NSColor {
    convenience init?(hexString: String) {
        let value = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let number = UInt64(value, radix: 16) else { return nil }
        self.init(red: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255, blue: CGFloat(number & 255) / 255, alpha: 1)
    }
}

@MainActor
extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard let route = NotificationManager.shared.route(for: response.notification.request.content.userInfo) else {
            return
        }

        switch route {
        case .usageHistory:
            showChart()
        case .preferencesUpdates:
            openPreferences(tab: .updates)
        }
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
