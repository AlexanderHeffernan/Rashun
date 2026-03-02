import Cocoa
import ServiceManagement

@MainActor
final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private var currentSources: [AISource] = []
    private var expandedSources: Set<String> = []
    private weak var updateStatusLabel: NSTextField?
    private weak var installButton: NSButton?
    private weak var checkNowButton: NSButton?

    private init() {
        let vc = NSViewController()
        vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))

        let window = NSWindow(contentViewController: vc)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 480))

        super.init(window: window)

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)), name: .aiSettingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateStatusChanged(_:)), name: .updateStatusChanged, object: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func showWindowAndBringToFront() {
        self.window?.center()
        self.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Configure the preferences window to display the provided sources.
    func configure(withSources sources: [AISource]) {
        currentSources = sources
        SettingsStore.shared.ensureSources(sources.map { $0.name })
        for source in sources {
            SettingsStore.shared.ensureNotificationRules(source: source)
        }

        guard let vc = window?.contentViewController else { return }
        // Clear existing
        vc.view.subviews.forEach { $0.removeFromSuperview() }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        let intro = NSTextField(labelWithString: "Welcome to Rashun. Enable sources, then expand their notifications to set alert thresholds and pacing rules.")
        intro.font = NSFont.systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        stack.addArrangedSubview(intro)

        if #available(macOS 13.0, *) {
            let generalHeader = NSTextField(labelWithString: "General")
            generalHeader.font = NSFont.boldSystemFont(ofSize: 14)
            stack.addArrangedSubview(generalHeader)

            let launchCheckbox = NSButton(checkboxWithTitle: "Launch at Login", target: self, action: #selector(launchAtLoginToggled(_:)))
            launchCheckbox.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            stack.addArrangedSubview(launchCheckbox)
        }

        let header = NSTextField(labelWithString: "Sources")
        header.font = NSFont.boldSystemFont(ofSize: 14)
        stack.addArrangedSubview(header)

        for source in sources {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.distribution = .fill
            row.translatesAutoresizingMaskIntoConstraints = false

            let checkbox = NSButton(checkboxWithTitle: source.name, target: self, action: #selector(toggleChanged(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier(source.name)
            let isEnabled = SettingsStore.shared.isEnabled(sourceName: source.name)
            checkbox.state = isEnabled ? .on : .off
            row.addArrangedSubview(checkbox)

            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)

            if !isEnabled {
                expandedSources.remove(source.name)
            }

            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

            if isEnabled, !source.notificationDefinitions.isEmpty {
                let isExpanded = expandedSources.contains(source.name)
                let arrow = isExpanded ? "▾" : "▸"
                let toggle = NSButton(title: "Notifications \(arrow)", target: self, action: #selector(toggleNotificationsSection(_:)))
                toggle.bezelStyle = .inline
                toggle.setButtonType(.toggle)
                toggle.state = isExpanded ? .on : .off
                toggle.identifier = NSUserInterfaceItemIdentifier("collapse|\(source.name)")
                row.addArrangedSubview(toggle)

                if isExpanded {
                    let container = NSView()
                    container.translatesAutoresizingMaskIntoConstraints = false
                    let innerStack = NSStackView()
                    innerStack.orientation = .vertical
                    innerStack.alignment = .leading
                    innerStack.spacing = 6
                    innerStack.translatesAutoresizingMaskIntoConstraints = false
                    container.addSubview(innerStack)

                    NSLayoutConstraint.activate([
                        innerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
                        innerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
                        innerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
                        innerStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
                    ])

                    for definition in source.notificationDefinitions {
                        let ruleRow = NSStackView()
                        ruleRow.orientation = .horizontal
                        ruleRow.alignment = .centerY
                        ruleRow.spacing = 8

                        let ruleCheckbox = NSButton(checkboxWithTitle: definition.title, target: self, action: #selector(ruleToggleChanged(_:)))
                        ruleCheckbox.identifier = NSUserInterfaceItemIdentifier("rule|\(source.name)|\(definition.id)")
                        let ruleSettings = SettingsStore.shared.ruleSettings(for: source.name)
                        let ruleEnabled = ruleSettings.first(where: { $0.ruleId == definition.id })?.isEnabled ?? false
                        ruleCheckbox.state = ruleEnabled ? .on : .off
                        ruleRow.addArrangedSubview(ruleCheckbox)

                        for input in definition.inputs {
                            let inputField = NSTextField(string: "")
                            inputField.alignment = .right
                            inputField.isBezeled = true
                            inputField.bezelStyle = .roundedBezel
                            inputField.controlSize = .small
                            inputField.font = NSFont.systemFont(ofSize: 11)
                            inputField.translatesAutoresizingMaskIntoConstraints = false
                            inputField.widthAnchor.constraint(equalToConstant: 64).isActive = true
                            let currentValue = SettingsStore.shared.ruleInputValue(sourceName: source.name, ruleId: definition.id, inputId: input.id, defaultValue: input.defaultValue)
                            inputField.stringValue = String(format: "%.0f", currentValue)
                            inputField.identifier = NSUserInterfaceItemIdentifier("input|\(source.name)|\(definition.id)|\(input.id)")
                            inputField.delegate = self

                            let label = NSTextField(labelWithString: input.unit ?? "")
                            label.font = NSFont.systemFont(ofSize: 11)

                            let inputStack = NSStackView(views: [inputField, label])
                            inputStack.orientation = .horizontal
                            inputStack.spacing = 4
                            ruleRow.addArrangedSubview(inputStack)
                        }

                        innerStack.addArrangedSubview(ruleRow)

                        if !definition.detail.isEmpty {
                            let detail = NSTextField(wrappingLabelWithString: definition.detail)
                            detail.font = NSFont.systemFont(ofSize: 11)
                            detail.textColor = .secondaryLabelColor
                            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                            innerStack.addArrangedSubview(detail)
                        }
                    }

                    stack.addArrangedSubview(container)
                    container.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                }
            }
        }

        let pollHeader = NSTextField(labelWithString: "Polling")
        pollHeader.font = NSFont.boldSystemFont(ofSize: 14)
        stack.addArrangedSubview(pollHeader)

        let pollRow = NSStackView()
        pollRow.orientation = .horizontal
        pollRow.spacing = 8
        let pollLabel = NSTextField(labelWithString: "Refresh every")
        pollLabel.font = NSFont.systemFont(ofSize: 12)
        let pollField = NSTextField(string: "")
        pollField.alignment = .right
        pollField.isBezeled = true
        pollField.bezelStyle = .roundedBezel
        pollField.controlSize = .small
        pollField.font = NSFont.systemFont(ofSize: 11)
        pollField.translatesAutoresizingMaskIntoConstraints = false
        pollField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        pollField.stringValue = String(format: "%.0f", SettingsStore.shared.pollInterval() / 60)
        pollField.identifier = NSUserInterfaceItemIdentifier("poll|minutes")
        pollField.delegate = self
        let pollUnit = NSTextField(labelWithString: "minutes")
        pollUnit.font = NSFont.systemFont(ofSize: 11)
        pollRow.addArrangedSubview(pollLabel)
        pollRow.addArrangedSubview(pollField)
        pollRow.addArrangedSubview(pollUnit)
        stack.addArrangedSubview(pollRow)

        // MARK: Updates section
        let updateHeader = NSTextField(labelWithString: "Updates")
        updateHeader.font = NSFont.boldSystemFont(ofSize: 14)
        stack.addArrangedSubview(updateHeader)

        let versionLabel = NSTextField(labelWithString: "Current version: \(UpdateManager.shared.currentVersion)")
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(versionLabel)

        let autoCheckbox = NSButton(checkboxWithTitle: "Check for updates automatically", target: self, action: #selector(autoUpdateToggled(_:)))
        autoCheckbox.state = SettingsStore.shared.autoUpdateCheckEnabled ? .on : .off
        stack.addArrangedSubview(autoCheckbox)

        let updateRow = NSStackView()
        updateRow.orientation = .horizontal
        updateRow.spacing = 8
        updateRow.alignment = .centerY

        let checkBtn = NSButton(title: "Check Now", target: self, action: #selector(checkForUpdateClicked(_:)))
        checkBtn.bezelStyle = .rounded
        checkBtn.controlSize = .regular
        updateRow.addArrangedSubview(checkBtn)
        self.checkNowButton = checkBtn

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isEditable = false
        statusLabel.isBordered = false
        statusLabel.backgroundColor = .clear
        updateRow.addArrangedSubview(statusLabel)
        self.updateStatusLabel = statusLabel

        stack.addArrangedSubview(updateRow)

        if UpdateManager.shared.updateAvailable {
            let installBtn = NSButton(title: "Install & Restart", target: self, action: #selector(installUpdateClicked(_:)))
            installBtn.bezelStyle = .rounded
            installBtn.controlSize = .regular
            stack.addArrangedSubview(installBtn)
            self.installButton = installBtn
        }

        refreshUpdateStatus()

        documentView.addSubview(stack)
        vc.view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: vc.view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -20)
        ])
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let enabled = (sender.state == .on)

        // If enabling, show a confirmation alert with requirements
        if enabled {
            let req = currentSources.first(where: { $0.name == id })?.requirements ?? ""
            let alert = NSAlert()
            alert.messageText = "Enable \(id)?"
            alert.informativeText = req.isEmpty ? "Enable this source?" : req
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                SettingsStore.shared.setEnabled(true, for: id)
            } else {
                // revert checkbox state
                sender.state = .off
                SettingsStore.shared.setEnabled(false, for: id)
            }
        } else {
            SettingsStore.shared.setEnabled(false, for: id)
        }
    }

    @objc private func ruleToggleChanged(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        let parts = raw.split(separator: "|")
        guard parts.count == 3 else { return }
        let sourceName = String(parts[1])
        let ruleId = String(parts[2])
        let enabled = (sender.state == .on)
        SettingsStore.shared.setRuleEnabled(enabled, sourceName: sourceName, ruleId: ruleId)
    }

    @objc private func toggleNotificationsSection(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        let parts = raw.split(separator: "|")
        guard parts.count == 2 else { return }
        let sourceName = String(parts[1])
        if sender.state == .on {
            expandedSources.insert(sourceName)
        } else {
            expandedSources.remove(sourceName)
        }
        configure(withSources: currentSources)
    }

    @available(macOS 13.0, *)
    @objc private func launchAtLoginToggled(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            sender.state = (sender.state == .on) ? .off : .on
        }
    }

    @objc private func autoUpdateToggled(_ sender: NSButton) {
        SettingsStore.shared.setAutoUpdateCheckEnabled(sender.state == .on)
    }

    @objc private func checkForUpdateClicked(_ sender: NSButton) {
        Task {
            let found = await UpdateManager.shared.checkForUpdate(notify: false)
            if found {
                configure(withSources: currentSources)
            }
        }
    }

    @objc private func installUpdateClicked(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = "Install Update?"
        alert.informativeText = "Rashun will download version \(UpdateManager.shared.availableVersion ?? ""), install it, and restart."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install & Restart")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            UpdateManager.shared.installUpdate()
        }
    }

    @objc private func updateStatusChanged(_ note: Notification) {
        refreshUpdateStatus()
    }

    private func refreshUpdateStatus() {
        if UpdateManager.shared.isInstalling {
            updateStatusLabel?.stringValue = "Installing..."
            checkNowButton?.isEnabled = false
            installButton?.isEnabled = false
        } else if UpdateManager.shared.isChecking {
            updateStatusLabel?.stringValue = "Checking..."
            checkNowButton?.isEnabled = false
        } else if UpdateManager.shared.updateAvailable {
            updateStatusLabel?.stringValue = "Version \(UpdateManager.shared.availableVersion ?? "") available!"
            updateStatusLabel?.textColor = .systemGreen
            checkNowButton?.isEnabled = true
        } else if UpdateManager.shared.availableVersion != nil {
            updateStatusLabel?.stringValue = "Up to date"
            checkNowButton?.isEnabled = true
        } else {
            updateStatusLabel?.stringValue = ""
            checkNowButton?.isEnabled = true
        }
    }

    @objc private func settingsChanged(_ note: Notification) {
        configure(withSources: currentSources)
    }
}

extension PreferencesWindowController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        guard let raw = field.identifier?.rawValue else { return }

        if raw == "poll|minutes" {
            guard let minutes = Double(field.stringValue), minutes > 0 else {
                field.stringValue = String(format: "%.0f", SettingsStore.shared.pollInterval() / 60)
                return
            }
            SettingsStore.shared.setPollIntervalSeconds(minutes * 60)
            return
        }

        let parts = raw.split(separator: "|")
        guard parts.count == 4 else { return }
        let sourceName = String(parts[1])
        let ruleId = String(parts[2])
        let inputId = String(parts[3])

        guard let parsed = Double(field.stringValue) else {
            let current = SettingsStore.shared.ruleInputValue(sourceName: sourceName, ruleId: ruleId, inputId: inputId, defaultValue: 0)
            field.stringValue = String(format: "%.0f", current)
            return
        }

        let spec = currentSources.first(where: { $0.name == sourceName })?
            .notificationDefinitions.first(where: { $0.id == ruleId })?
            .inputs.first(where: { $0.id == inputId })
        let clamped = spec.map { min(max(parsed, $0.min), $0.max) } ?? parsed

        SettingsStore.shared.setRuleValue(clamped, sourceName: sourceName, ruleId: ruleId, inputId: inputId)
        field.stringValue = String(format: "%.0f", clamped)
    }
}
