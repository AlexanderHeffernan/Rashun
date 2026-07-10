import Cocoa

@MainActor
final class TrackingMenuButton: NSView {
    private let label = NSTextField(labelWithString: "")
    private let highlight = NSVisualEffectView()
    private weak var target: AnyObject?
    private var action: Selector?
    private var enabled = true
    private var trackingArea: NSTrackingArea?

    init(target: AnyObject, action: Selector) {
        self.target = target; self.action = action
        super.init(frame: .zero)
        highlight.material = .selection; highlight.state = .active; highlight.isEmphasized = true; highlight.blendingMode = .behindWindow; highlight.wantsLayer = true; highlight.layer?.cornerRadius = 5; highlight.isHidden = true
        addSubview(highlight); label.font = .menuFont(ofSize: 0); addSubview(label)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func update(title: String, isEnabled: Bool) {
        enabled = isEnabled; label.stringValue = title; label.textColor = isEnabled ? .labelColor : .secondaryLabelColor; label.sizeToFit()
        frame = NSRect(x: 0, y: 0, width: max(label.frame.width + 28, enclosingMenuItem?.menu?.size.width ?? 0), height: label.frame.height + 6)
        label.frame.origin = NSPoint(x: 14, y: 3)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let menuWidth = enclosingMenuItem?.menu?.size.width, frame.width < menuWidth {
            frame.size.width = menuWidth
        }
    }
    override func layout() { super.layout(); highlight.frame = bounds.insetBy(dx: 5, dy: 0) }
    override func updateTrackingAreas() { super.updateTrackingAreas(); if let trackingArea { removeTrackingArea(trackingArea) }; let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self); addTrackingArea(area); trackingArea = area }
    override func mouseEntered(with event: NSEvent) { guard enabled else { return }; highlight.isHidden = false; label.textColor = .white }
    override func mouseExited(with event: NSEvent) { highlight.isHidden = true; label.textColor = enabled ? .labelColor : .secondaryLabelColor }
    override func mouseUp(with event: NSEvent) { guard enabled, let target, let action else { return }; NSApp.sendAction(action, to: target, from: self) }
}
