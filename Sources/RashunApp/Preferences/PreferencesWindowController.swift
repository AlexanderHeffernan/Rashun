import Cocoa
import SwiftUI
import RashunCore

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PreferencesWindowController()

    private let viewModel = PreferencesViewModel()

    private init() {
        let rootView = PreferencesRootView(model: viewModel)
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 520, height: 480))

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func showWindowAndBringToFront() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func configure(withSources sources: [AISource]) {
        viewModel.configure(withSources: sources)
    }

    func selectTab(_ tab: PreferencesTab) {
        viewModel.selectTab(tab)
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        window?.makeFirstResponder(nil)
        viewModel.flushPendingEdits()
    }
}
