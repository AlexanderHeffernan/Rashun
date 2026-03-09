import Cocoa
import RashunCore

@MainActor
class RefreshButton: NSView {
    private let label = NSTextField(labelWithString: "")
    private let highlightView = NSVisualEffectView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private weak var target: AnyObject?
    private var action: Selector?

    init(target: AnyObject, action: Selector) {
        self.target = target
        self.action = action
        super.init(frame: .zero)

        highlightView.material = .selection
        highlightView.state = .active
        highlightView.isEmphasized = true
        highlightView.blendingMode = .behindWindow
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 5
        highlightView.isHidden = true
        addSubview(highlightView)

        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .labelColor
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(loading: Bool, lastRefresh: Date?) {
        let timeText: String
        if loading {
            timeText = "Refreshing…"
        } else if let last = lastRefresh {
            let elapsed = Int(Date().timeIntervalSince(last))
            if elapsed < 60 {
                timeText = "just now"
            } else {
                let minutes = elapsed / 60
                timeText = "\(minutes) min ago"
            }
        } else {
            timeText = ""
        }

        label.stringValue = loading ? "Refreshing…" : (timeText.isEmpty ? "Refresh" : "Refresh (\(timeText))")
        label.sizeToFit()
        let height = label.frame.height + 4
        frame = NSRect(x: 0, y: 0, width: max(label.frame.width + 28, enclosingMenuItem?.menu?.size.width ?? 0), height: height)
        label.frame.origin = NSPoint(x: 14, y: 2)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let menuWidth = enclosingMenuItem?.menu?.size.width, frame.width < menuWidth {
            frame.size.width = menuWidth
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        highlightView.frame = bounds.insetBy(dx: 5, dy: 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        highlightView.isHidden = !isHovered
        label.textColor = isHovered ? .white : .labelColor
        super.draw(dirtyRect)
    }

    override func mouseUp(with event: NSEvent) {
        if let target, let action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }
}
