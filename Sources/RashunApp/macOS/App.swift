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

    var statusItem: NSStatusItem?
    var menu: NSMenu?
    var pollTimer: Timer?
    let loadingIndicator = "⏳"

    var sources: [AISource] { allSources }

    var results: [String: [String: String]] = [:]
    var latestUsageResults: [String: [String: UsageResult]] = [:]
    var loadingSources: Set<String> = []
    var lastRefreshDate: Date?
    private var isSleepSuspended = false
    private var isLockSuspended = false
    private var lastResumeRefreshTriggerDate: Date?
    private let resumeRefreshDebounceSeconds: TimeInterval = 8

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
            await refresh()
        }

        schedulePollTimer()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
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

    private func sourceMenuView(source: AISource, hasWarning: Bool) -> NSView {
        let metrics = enabledMetrics(for: source)
        let rows: [MenuDropdownMetricRowModel]
        if metrics.isEmpty {
            rows = [
                MenuDropdownMetricRowModel(
                    title: "No metrics enabled",
                    valueText: "--",
                    progress: 0,
                    hasValue: false,
                    hasWarning: hasWarning
                )
            ]
        } else {
            let sourceHasSingleMetric = source.metrics.count <= 1 && metrics.count <= 1
            rows = metrics.map { metric in
                let warning = metricHasWarning(source: source, metricId: metric.id)
                let rowTitle = sourceHasSingleMetric ? "Remaining" : metric.title
                if loadingSources.contains(source.name) {
                    return MenuDropdownMetricRowModel(
                        title: rowTitle,
                        valueText: "Refreshing",
                        progress: 0,
                        hasValue: false,
                        hasWarning: warning
                    )
                }

                if let usage = usageResultForIcon(sourceName: source.name, metricId: metric.id) {
                    let percent = min(max(usage.percentRemaining, 0), 100)
                    return MenuDropdownMetricRowModel(
                        title: rowTitle,
                        valueText: "\(Int(round(percent)))%",
                        progress: percent / 100,
                        hasValue: true,
                        hasWarning: warning
                    )
                }

                return MenuDropdownMetricRowModel(
                    title: rowTitle,
                    valueText: "--",
                    progress: 0,
                    hasValue: false,
                    hasWarning: warning
                )
            }
        }

        let host = NSHostingView(
            rootView: MenuDropdownSourceCardView(
                sourceName: source.name,
                logoImage: logoImage(forSourceName: source.name),
                sourceColorHex: source.menuBarBrandColorHex,
                rows: rows
            )
        )
        let fit = host.fittingSize
        host.frame = NSRect(origin: .zero, size: fit)
        return host
    }

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

    func openPreferences(tab: PreferencesTab?) {
        PreferencesWindowController.shared.configure(withSources: sources)
        if let tab {
            PreferencesWindowController.shared.selectTab(tab)
        }
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
                    latestUsageResults[name] = metricUsages
                    usageResultsBySource[name] = metricUsages

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

        lastRefreshDate = Date()
        await evaluateNotifications(sources: enabled, results: usageResultsBySource)

        if percentValues.isEmpty {
            latestUsageResults = latestUsageResults.filter { key, _ in
                enabled.contains { $0.name == key }
            }
        }
        updateStatusIcon()

        NotificationCenter.default.post(name: .aiDataRefreshed, object: nil)
    }

    private func enabledMetrics(for source: AISource) -> [AISourceMetric] {
        source.metrics.filter { SettingsStore.shared.isMetricEnabled(sourceName: source.name, metricId: $0.id) }
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
        let metricTitle: String
        let percentRemaining: Double
        let hasUsage: Bool
        let sourceColorHex: UInt32
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let metrics = selectedMetricsForStatusIcon()
        if metrics.isEmpty {
            if let placeholder = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "No selected metrics") {
                placeholder.isTemplate = true
                button.image = placeholder
                button.toolTip = "No menu bar metrics selected"
            }
            return
        }

        let appearance = SettingsStore.shared.menuBarAppearance
        if let image = ringMetersImage(
            metrics: metrics,
            colorMode: appearance.colorMode,
            centerMode: appearance.centerContentMode
        ) {
            button.image = image
        }
        button.toolTip = metrics.map { metric in
            let valueText = metric.hasUsage
                ? "\(String(format: "%.1f", metric.percentRemaining))%"
                : "N/A"
            return "\(metric.sourceName) · \(metric.metricTitle): \(valueText)"
        }.joined(separator: "\n")
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
                metricTitle: metric.title,
                percentRemaining: clampedPercent,
                hasUsage: usage != nil,
                sourceColorHex: source.menuBarBrandColorHex
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
        centerMode: MenuBarCenterContentMode
    ) -> NSImage? {
        let ringSize: CGFloat = 20
        let spacing: CGFloat = 3
        let count = metrics.count
        guard count > 0 else { return nil }

        let width = ringSize * CGFloat(count) + spacing * CGFloat(max(0, count - 1))
        let size = NSSize(width: width, height: ringSize)
        let image = NSImage(size: size)
        image.isTemplate = colorMode == .monochrome

        image.lockFocus()
        defer { image.unlockFocus() }
        guard let context = NSGraphicsContext.current?.cgContext else { return nil }

        for index in 0..<count {
            let metric = metrics[index]
            let rect = CGRect(
                x: CGFloat(index) * (ringSize + spacing),
                y: 0,
                width: ringSize,
                height: ringSize
            )
            drawRing(
                in: context,
                rect: rect.insetBy(dx: 0.7, dy: 0.7),
                metric: metric,
                colorMode: colorMode,
                centerMode: centerMode
            )
        }

        return image
    }

    private func drawRing(
        in context: CGContext,
        rect: CGRect,
        metric: IconRingMetric,
        colorMode: MenuBarColorMode,
        centerMode: MenuBarCenterContentMode
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
        }

        drawRingCenter(in: rect, metric: metric, colorMode: colorMode, centerMode: centerMode)
    }

    private var brandPrimaryColor: NSColor { NSColor(calibratedRed: 147 / 255, green: 90 / 255, blue: 253 / 255, alpha: 1) }
    private var brandAccentColor: NSColor { NSColor(calibratedRed: 13 / 255, green: 228 / 255, blue: 209 / 255, alpha: 1) }

    private func trackColor(for mode: MenuBarColorMode) -> NSColor {
        switch mode {
        case .monochrome:
            return NSColor.black.withAlphaComponent(0.25)
        case .brandGradient, .sourceSolid:
            return NSColor(calibratedWhite: 0.45, alpha: 0.28)
        }
    }

    private func drawRingCenter(
        in rect: CGRect,
        metric: IconRingMetric,
        colorMode: MenuBarColorMode,
        centerMode: MenuBarCenterContentMode
    ) {
        let foreground: NSColor = colorMode == .monochrome
            ? NSColor.black.withAlphaComponent(0.95)
            : NSColor.white.withAlphaComponent(0.96)

        let centerRect = rect.insetBy(dx: 3.8, dy: 3.8)
        switch centerMode {
        case .logo:
            if let image = logoImage(for: metric) {
                drawCenteredImage(image, in: centerRect)
                return
            }
            drawPercentageCenter(metric: metric, in: centerRect, color: foreground)
        case .percentage:
            drawPercentageCenter(metric: metric, in: centerRect, color: foreground)
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

    private func drawCenteredImage(_ image: NSImage, in rect: CGRect) {
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
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func colorFromHex(_ hex: UInt32) -> NSColor {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        return NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
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
                let history = UsageHistoryStore.shared.history(for: scopedName)
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
                        NotificationManager.shared.sendNotification(
                            title: event.title,
                            body: event.body,
                            route: .usageHistory
                        )
                        let newState = NotificationRuleState(lastFiredAt: Date(), lastFiredCycleKey: event.cycleKey)
                        SettingsStore.shared.setRuleState(newState, sourceName: scopedName, ruleId: ruleId)
                    }
                }

                UsageHistoryStore.shared.append(sourceName: scopedName, usage: current)
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

@MainActor
extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
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
