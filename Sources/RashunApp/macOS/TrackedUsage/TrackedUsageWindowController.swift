import Cocoa
import SwiftUI

@MainActor
final class TrackedUsageWindowController: NSWindowController {
    static let shared = TrackedUsageWindowController()
    private let viewModel = TrackedUsageViewModel()

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: TrackedUsageRootView(model: viewModel)))
        window.title = "Tracked Usage"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 920, height: 700))
        window.minSize = NSSize(width: 740, height: 520)
        super.init(window: window)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .aiDataRefreshed, object: nil)
    }
    required init?(coder: NSCoder) { nil }
    func showWindowAndBringToFront() { viewModel.reload(); window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func reload() { viewModel.reload() }
}
