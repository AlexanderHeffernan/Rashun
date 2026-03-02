import Cocoa

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    var menu: NSMenu?
    var pollTimer: Timer?
    let loadingIndicator = "⏳"

    var sources: [AISource] { allSources }

    var results: [String: String] = [:]
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
        updateMenu()

        Task {
            _ = await NotificationManager.shared.requestAuthorization()
            await refresh()
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
            menu?.addItem(withTitle: "No sources enabled — open Settings...", action: #selector(showPreferences), keyEquivalent: "")
        } else {
            for source in enabled {
                let display = loadingSources.contains(source.name)
                    ? loadingIndicator
                    : (results[source.name] ?? "N/A")
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                let label = NSTextField(labelWithString: "\(source.name) Remaining: \(display)")
                label.font = NSFont.menuFont(ofSize: 0)
                label.textColor = .labelColor
                label.sizeToFit()
                let container = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 28, height: label.frame.height + 4))
                label.frame.origin = NSPoint(x: 14, y: 2)
                container.addSubview(label)
                item.view = container
                menu?.addItem(item)
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
        menu?.addItem(withTitle: "Settings...", action: #selector(showPreferences), keyEquivalent: ",")
        menu?.addItem(NSMenuItem.separator())
        menu?.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
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
        var usageResults: [String: UsageResult] = [:]

        await withTaskGroup(of: (String, UsageResult?).self) { group in
            for source in enabled {
                group.addTask {
                    let res = try? await source.fetchUsage()
                    return (source.name, res)
                }
            }

            for await (name, res) in group {
                if let usage = res {
                    results[name] = usage.formatted
                    usageResults[name] = usage
                    let p = min(max(usage.percentRemaining, 0), 100)
                    percentValues.append(p)
                } else {
                    results[name] = "Error"
                }
                loadingSources.remove(name)
                updateMenu()
            }
        }

        lastRefreshDate = Date()
        await evaluateNotifications(sources: enabled, results: usageResults)

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

    private func evaluateNotifications(sources: [AISource], results: [String: UsageResult]) async {
        for source in sources {
            guard let current = results[source.name] else { continue }
            SettingsStore.shared.ensureNotificationRules(source: source)
            let rules = SettingsStore.shared.ruleSettings(for: source.name)
            let history = NotificationHistoryStore.shared.history(for: source.name)
            let previous = history.last

            for rule in rules where rule.isEnabled {
                guard let definition = source.notificationDefinitions.first(where: { $0.id == rule.ruleId }) else { continue }
                let ruleId = rule.ruleId
                let valueProvider: (String, Double) -> Double = { inputId, defaultValue in
                    SettingsStore.shared.ruleInputValue(sourceName: source.name, ruleId: ruleId, inputId: inputId, defaultValue: defaultValue)
                }

                let ctx = NotificationContext(
                    sourceName: source.name,
                    current: current,
                    previous: previous,
                    history: history,
                    inputValue: valueProvider
                )

                guard let event = definition.evaluate(ctx) else { continue }

                let state = SettingsStore.shared.ruleState(sourceName: source.name, ruleId: ruleId)
                if shouldSend(event: event, state: state) {
                    NotificationManager.shared.sendNotification(title: event.title, body: event.body)
                    let newState = NotificationRuleState(lastFiredAt: Date(), lastFiredCycleKey: event.cycleKey)
                    SettingsStore.shared.setRuleState(newState, sourceName: source.name, ruleId: ruleId)
                }
            }

            NotificationHistoryStore.shared.append(sourceName: source.name, usage: current)
        }
    }

    private func shouldSend(event: NotificationEvent, state: NotificationRuleState?) -> Bool {
        shouldSendNotification(event: event, state: state)
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
