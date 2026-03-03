import Cocoa

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

    var statusItem: NSStatusItem?
    var menu: NSMenu?
    var pollTimer: Timer?
    let loadingIndicator = "⏳"

    var sources: [AISource] { allSources }

    var results: [String: [String: String]] = [:]
    var loadingSources: Set<String> = []
    var lastRefreshDate: Date?

    func applicationDidFinishLaunching(_: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            // try to use an SF Symbol brain icon (template) and show a placeholder title
            if let brain = NSImage(systemSymbolName: "brain", accessibilityDescription: "AI") {
                brain.isTemplate = true
                button.image = brain
                button.imagePosition = .imageLeft
            } else {
                button.title = "AI"
            }
            button.title = "—"
        }

        menu = NSMenu()
        menu?.delegate = self
        statusItem?.menu = menu

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)), name: .aiSettingsChanged, object: nil)

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

        Task {
            _ = await NotificationManager.shared.requestAuthorization()
            await refresh()
            UpdateManager.shared.startPeriodicChecks()
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: SettingsStore.shared.pollInterval(), repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refresh() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenu()
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    func updateMenu() {
        menu?.removeAllItems()
        let enabled = sources.filter { SettingsStore.shared.isEnabled(sourceName: $0.name) }
        if enabled.isEmpty {
            menu?.addItem(withTitle: "No sources enabled — open Preferences...", action: #selector(showPreferences), keyEquivalent: "")
        } else {
            var hasWarnings = false
            for source in enabled {
                let hasWarning = !loadingSources.contains(source.name) && sourceHasWarning(source)
                if hasWarning { hasWarnings = true }
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.view = sourceMenuView(source: source, hasWarning: hasWarning)
                menu?.addItem(item)
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

        let refreshItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let refreshButton = RefreshButton(target: self, action: #selector(refreshClicked))
        refreshButton.update(loading: !loadingSources.isEmpty, lastRefresh: lastRefreshDate)
        refreshItem.view = refreshButton
        menu?.addItem(refreshItem)
        menu?.addItem(withTitle: "Usage History...", action: #selector(showChart), keyEquivalent: "")

        menu?.addItem(NSMenuItem.separator())
        menu?.addItem(withTitle: "Preferences...", action: #selector(showPreferences), keyEquivalent: ",")
        menu?.addItem(NSMenuItem.separator())
        menu?.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
    }

    private func sourceMenuView(source: AISource, hasWarning: Bool) -> NSView {
        let metrics = enabledMetrics(for: source)
        let currentResults = results[source.name] ?? [:]
        let warningSuffix = hasWarning ? "  ⚠" : ""

        if source.metrics.count <= 1 {
            let metricId = metrics.first?.id ?? source.metrics.first?.id ?? "default"
            let display = loadingSources.contains(source.name)
                ? loadingIndicator
                : (currentResults[metricId] ?? SourceHealthStore.shared.health(for: source.name)?.lastSuccessfulUsage?.formatted ?? "N/A")
            let label = NSTextField(labelWithString: "\(source.name) Remaining: \(display)\(warningSuffix)")
            label.font = NSFont.menuFont(ofSize: 0)
            label.textColor = .labelColor
            label.sizeToFit()
            let container = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 28, height: label.frame.height + 4))
            label.frame.origin = NSPoint(x: 14, y: 2)
            container.addSubview(label)
            return container
        }

        var labels: [NSTextField] = []
        let sourceLabel = NSTextField(labelWithString: "\(source.name)\(warningSuffix)")
        sourceLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        sourceLabel.textColor = .secondaryLabelColor
        labels.append(sourceLabel)

        if metrics.isEmpty {
            let noMetricsLabel = NSTextField(labelWithString: "No metrics enabled")
            noMetricsLabel.font = NSFont.menuFont(ofSize: 0)
            noMetricsLabel.textColor = .secondaryLabelColor
            labels.append(noMetricsLabel)
        } else {
            for metric in metrics {
                let metricWarningSuffix = metricHasWarning(source: source, metricId: metric.id) ? "  ⚠" : ""
                let display = loadingSources.contains(source.name)
                    ? loadingIndicator
                    : (currentResults[metric.id] ?? SourceHealthStore.shared.health(for: source.name, metricId: metric.id)?.lastSuccessfulUsage?.formatted ?? "N/A")
                let metricLabel = NSTextField(labelWithString: "\(metric.title) Remaining: \(display)\(metricWarningSuffix)")
                metricLabel.font = NSFont.menuFont(ofSize: 0)
                metricLabel.textColor = .labelColor
                labels.append(metricLabel)
            }
        }

        for label in labels { label.sizeToFit() }
        let maxWidth = labels.map { $0.frame.width }.max() ?? 0
        let lineHeight = (labels.map { $0.frame.height }.max() ?? 0) + 2
        let height = CGFloat(labels.count) * lineHeight + 4
        let container = NSView(frame: NSRect(x: 0, y: 0, width: maxWidth + 28, height: height))
        var y = height - lineHeight - 2
        for label in labels {
            label.frame.origin = NSPoint(x: 14, y: y)
            container.addSubview(label)
            y -= lineHeight
        }
        return container
    }

    @objc func refreshClicked() {
        Task { await refresh() }
    }

    @objc func showChart() {
        ChartWindowController.shared.configure(withSources: sources)
        ChartWindowController.shared.showWindowAndBringToFront()
    }

    @objc func showPreferences() {
        PreferencesWindowController.shared.configure(withSources: sources)
        PreferencesWindowController.shared.showWindowAndBringToFront()
    }

    func refresh() async {
        guard loadingSources.isEmpty else { return }
        let enabled = sources.filter { SettingsStore.shared.isEnabled(sourceName: $0.name) }
        for source in enabled { loadingSources.insert(source.name) }
        updateMenu()

        var percentValues: [Double] = []
        var usageResultsBySource: [String: [String: UsageResult]] = [:]

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
                    let metricUsages = fetchResult.usages
                    let metricDisplays = metricUsages.mapValues { $0.formatted }
                    results[name] = metricDisplays
                    usageResultsBySource[name] = metricUsages

                    if source.metrics.count > 1 {
                        for metric in source.metrics {
                            guard let metricUsage = metricUsages[metric.id] else { continue }
                            NotificationHistoryStore.shared.append(
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
            }
        }

        lastRefreshDate = Date()
        await evaluateNotifications(sources: enabled, results: usageResultsBySource)

        // compute average remaining percentage across successful sources
        if percentValues.isEmpty {
            // no successful sources to aggregate
            if let button = statusItem?.button {
                button.title = "—"
                if let outline = NSImage(systemSymbolName: "brain", accessibilityDescription: nil) {
                    outline.isTemplate = true
                    button.image = outline
                }
            }
        } else {
            let avg = percentValues.reduce(0, +) / Double(percentValues.count)
            let formatted = String(format: "%.0f%%", avg)
            if let button = statusItem?.button {
                button.title = formatted
                if let img = brainFillImage(percent: avg, size: NSSize(width: 16, height: 16)) {
                    button.image = img
                    button.imagePosition = .imageLeft
                }
            }
        }

        NotificationCenter.default.post(name: .aiDataRefreshed, object: nil)
    }

    private func enabledMetrics(for source: AISource) -> [AISourceMetric] {
        source.metrics.filter { SettingsStore.shared.isMetricEnabled(sourceName: source.name, metricId: $0.id) }
    }

    private func metricHistorySeriesName(source: AISource, metric: AISourceMetric) -> String {
        "\(source.name) - \(metric.title)"
    }

    /// Generate a template NSImage representing the brain with the bottom `percent` filled.
    /// `percent` is 0..100. Returns a template image so the system tints it for the menu bar.
    private func brainFillImage(percent: Double, size: NSSize) -> NSImage? {
        guard let fill = NSImage(systemSymbolName: "brain.fill", accessibilityDescription: nil),
              let outline = NSImage(systemSymbolName: "brain", accessibilityDescription: nil) else {
            return nil
        }

        let image = NSImage(size: size)
        image.isTemplate = true

        image.lockFocus()
        defer { image.unlockFocus() }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }

        let bounds = CGRect(origin: .zero, size: size)

        // Draw the filled brain clipped to the bottom percent
        ctx.saveGState()
        let clippedHeight = bounds.height * CGFloat(min(max(percent, 0), 100) / 100.0)
        let fillClipRect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: clippedHeight)
        ctx.clip(to: fillClipRect)
        fill.draw(in: bounds)
        ctx.restoreGState()

        // Draw the outline clipped to the top (unfilled) portion so it visually shows the empty area
        ctx.saveGState()
        let outlineClipRect = CGRect(x: bounds.minX, y: bounds.minY + clippedHeight, width: bounds.width, height: bounds.height - clippedHeight)
        ctx.clip(to: outlineClipRect)
        outline.draw(in: bounds)
        ctx.restoreGState()

        return image
    }

    @objc private func settingsChanged(_ note: Notification) {
        let enabled = Set(sources.filter { SettingsStore.shared.isEnabled(sourceName: $0.name) }.map { $0.name })
        // prune results for disabled sources
        results = results.filter { enabled.contains($0.key) }
        updateMenu()

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: SettingsStore.shared.pollInterval(), repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refresh() }
        }
    }

    private func evaluateNotifications(sources: [AISource], results: [String: [String: UsageResult]]) async {
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
                let history = NotificationHistoryStore.shared.history(for: scopedName)
                let previous = history.last
                let definitions = source.notificationDefinitions(for: metric.id)

                for rule in rules where rule.isEnabled {
                    guard let definition = definitions.first(where: { $0.id == rule.ruleId }) else { continue }
                    let ruleId = rule.ruleId
                    let valueProvider: (String, Double) -> Double = { inputId, defaultValue in
                        SettingsStore.shared.ruleInputValue(sourceName: scopedName, ruleId: ruleId, inputId: inputId, defaultValue: defaultValue)
                    }

                    let ctx = NotificationContext(
                        sourceName: source.name,
                        metricId: metric.id,
                        metricTitle: metric.title,
                        current: current,
                        previous: previous,
                        history: history,
                        inputValue: valueProvider
                    )

                    guard let event = definition.evaluate(ctx) else { continue }

                    let state = SettingsStore.shared.ruleState(sourceName: scopedName, ruleId: ruleId)
                    if shouldSend(event: event, state: state) {
                        NotificationManager.shared.sendNotification(title: event.title, body: event.body)
                        let newState = NotificationRuleState(lastFiredAt: Date(), lastFiredCycleKey: event.cycleKey)
                        SettingsStore.shared.setRuleState(newState, sourceName: scopedName, ruleId: ruleId)
                    }
                }

                NotificationHistoryStore.shared.append(sourceName: scopedName, usage: current)
            }
        }
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

}

func shouldSendNotification(event: NotificationEvent, state: NotificationRuleState?) -> Bool {
    if let cycleKey = event.cycleKey, state?.lastFiredCycleKey == cycleKey {
        return false
    }
    if let cooldown = event.cooldownSeconds, let last = state?.lastFiredAt {
        if Date().timeIntervalSince(last) < cooldown {
            return false
        }
    }
    return true
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
