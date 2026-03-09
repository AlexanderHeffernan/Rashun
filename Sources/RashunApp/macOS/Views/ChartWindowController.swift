import Cocoa
import SwiftUI
import RashunCore

@MainActor
final class ChartWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ChartWindowController()

    private let viewModel = UsageHistoryViewModel()

    private init() {
        let rootView = UsageHistoryRootView(model: viewModel)
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Usage History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 980, height: 760))
        window.minSize = NSSize(width: 860, height: 560)

        super.init(window: window)
        window.delegate = self

        NotificationCenter.default.addObserver(self, selector: #selector(dataRefreshed), name: .aiDataRefreshed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dataRefreshed), name: .aiSettingsChanged, object: nil)
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

    @objc private func dataRefreshed() {
        guard window?.isVisible == true else { return }
        viewModel.reloadChart()
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        window?.makeFirstResponder(nil)
    }
}
