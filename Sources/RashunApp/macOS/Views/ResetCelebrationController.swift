import AppKit

/// A source-coloured reset burst that appears below the menu bar and lines up
/// with the metric ring that triggered it.
@MainActor
final class ResetCelebrationController {
    private struct CelebrationRequest {
        let sourceColorHex: UInt32
        let anchor: CGPoint?
    }

    static let shared = ResetCelebrationController()

    private let size = NSSize(width: 440, height: 340)
    private let maximumPulseRadius: CGFloat = 128
    private static let launchDuration: TimeInterval = 1.15
    private var panel: NSPanel?
    private var pendingRequests: [CelebrationRequest] = []
    private var isPresenting = false

    func celebrate(sourceColorHex: UInt32, anchor: CGPoint?) {
        pendingRequests.append(CelebrationRequest(sourceColorHex: sourceColorHex, anchor: anchor))
        presentNextIfNeeded()
    }

    private func presentNextIfNeeded() {
        guard !isPresenting, let request = pendingRequests.first else { return }
        pendingRequests.removeFirst()
        isPresenting = true

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]

        let panelOrigin = position(panel, below: request.anchor)
        let localX = burstX(anchor: request.anchor, panelOrigin: panelOrigin)
        let burstOrigin = CGPoint(x: localX, y: size.height - maximumPulseRadius - 8)
        // This sits just above the panel, at the menu-bar icon. It is clipped
        // by the panel boundary, making particles visibly emerge from the ring
        // while the effect itself never paints over the menu bar.
        let launchOrigin = CGPoint(x: localX, y: size.height + 12)

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        let sourceColor = Self.color(from: request.sourceColorHex)
        Self.addLaunch(
            to: view.layer!,
            launchOrigin: launchOrigin,
            burstOrigin: burstOrigin,
            sourceColor: sourceColor
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDuration) { [weak view] in
            guard let host = view?.layer else { return }
            Self.addBurst(to: host, origin: burstOrigin, sourceColor: sourceColor)
        }
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.68) { [weak self, weak panel] in
            panel?.orderOut(nil)
            if self?.panel === panel {
                self?.panel = nil
            }
            self?.isPresenting = false
            self?.presentNextIfNeeded()
        }
    }

    @discardableResult
    private func position(_ panel: NSPanel, below anchor: CGPoint?) -> CGPoint {
        let screen = NSScreen.screens.first(where: { screen in
            anchor.map { screen.frame.contains($0) } ?? false
        }) ?? NSScreen.main
        guard let screen else {
            panel.setFrameOrigin(.zero)
            return .zero
        }

        let anchorX = anchor?.x ?? screen.visibleFrame.maxX - 70
        let x = min(
            max(anchorX - size.width / 2, screen.visibleFrame.minX + 6),
            screen.visibleFrame.maxX - size.width - 6
        )
        // Keep the panel entirely in the usable screen area: the effect is
        // above other apps, but cannot cross into the system menu bar.
        let y = max(screen.visibleFrame.minY + 6, screen.visibleFrame.maxY - size.height - 2)
        let origin = CGPoint(x: x, y: y)
        panel.setFrameOrigin(origin)
        return origin
    }

    private func burstX(anchor: CGPoint?, panelOrigin: CGPoint) -> CGFloat {
        let desired = anchor.map { $0.x - panelOrigin.x } ?? size.width / 2
        return min(max(desired, maximumPulseRadius + 8), size.width - maximumPulseRadius - 8)
    }

    private static func addLaunch(
        to host: CALayer,
        launchOrigin: CGPoint,
        burstOrigin: CGPoint,
        sourceColor: NSColor
    ) {
        // A small chain of delayed embers follows the flare. Unlike a drawn
        // line, each ember naturally lags and fades as the comet moves on.
        for index in 0..<6 {
            let delay = TimeInterval(index + 1) * 0.024
            // Every ember uses the comet's own flight duration. It stays a
            // fixed, close distance behind rather than accelerating to catch
            // up later in the launch.
            let duration = launchDuration
            let diameter = 5.5 - CGFloat(index) * 0.7
            let ember = CALayer()
            ember.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            ember.cornerRadius = diameter / 2
            ember.position = launchOrigin
            ember.backgroundColor = sourceColor.withAlphaComponent(0.86 - CGFloat(index) * 0.1).cgColor
            ember.shadowColor = sourceColor.cgColor
            ember.shadowOpacity = 0.7
            ember.shadowRadius = 5
            ember.opacity = 0
            host.addSublayer(ember)

            let emberPosition = CABasicAnimation(keyPath: "position")
            emberPosition.fromValue = NSValue(point: launchOrigin)
            emberPosition.toValue = NSValue(point: burstOrigin)
            emberPosition.duration = duration
            emberPosition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let emberOpacity = CAKeyframeAnimation(keyPath: "opacity")
            emberOpacity.values = [0, 0.8 - Float(index) * 0.09, 0.12, 0]
            emberOpacity.keyTimes = [0, 0.08, 0.42, 0.7]
            emberOpacity.duration = duration
            let emberGroup = CAAnimationGroup()
            emberGroup.animations = [emberPosition, emberOpacity]
            emberGroup.beginTime = CACurrentMediaTime() + delay
            emberGroup.duration = duration
            ember.add(emberGroup, forKey: "rashun.reset.launchEmber.\(index)")
        }

        let rocket = CALayer()
        rocket.bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
        rocket.cornerRadius = 5
        rocket.position = launchOrigin
        rocket.backgroundColor = NSColor.white.cgColor
        rocket.shadowColor = sourceColor.cgColor
        rocket.shadowOpacity = 1
        rocket.shadowRadius = 10
        rocket.opacity = 0
        host.addSublayer(rocket)

        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: launchOrigin)
        position.toValue = NSValue(point: burstOrigin)
        position.duration = launchDuration
        // One continuous flare-like flight: quick out of the ring, gradually
        // slowing as it approaches the point where the firework opens.
        position.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 1, 1, 0]
        opacity.keyTimes = [0, 0.08, 0.88, 1]
        opacity.duration = launchDuration
        let rocketGroup = CAAnimationGroup()
        rocketGroup.animations = [position, opacity]
        rocketGroup.duration = launchDuration
        rocketGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
        rocket.add(rocketGroup, forKey: "rashun.reset.launch")
    }

    private static func addBurst(to host: CALayer, origin: CGPoint, sourceColor: NSColor) {
        addPulseRing(to: host, origin: origin, color: sourceColor)
        let colors = popColors(from: sourceColor)
        let particleCount = 132

        for index in 0..<particleCount {
            let angle = (CGFloat(index) / CGFloat(particleCount)) * 2 * .pi + CGFloat(index % 7) * 0.018
            let distance: CGFloat = 52 + CGFloat((index * 29) % 72)
            let end = CGPoint(
                x: origin.x + cos(angle) * distance,
                y: origin.y + sin(angle) * distance
            )
            let particle = CALayer()
            let particleSize = index.isMultiple(of: 4)
                ? CGSize(width: 7, height: 1.8)
                : CGSize(width: 3.6, height: 3.6)
            particle.bounds = CGRect(origin: .zero, size: particleSize)
            particle.position = end
            particle.cornerRadius = min(particleSize.width, particleSize.height) / 2
            particle.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
            particle.backgroundColor = colors[index % colors.count].cgColor
            particle.shadowColor = colors[index % colors.count].cgColor
            particle.shadowOpacity = 0.92
            particle.shadowRadius = 4
            particle.opacity = 0
            host.addSublayer(particle)
            particle.add(
                popAnimation(from: origin, to: end),
                forKey: "rashun.reset.pop"
            )
        }
    }

    private static func addPulseRing(to host: CALayer, origin: CGPoint, color: NSColor) {
        let ring = CAShapeLayer()
        let diameter: CGFloat = 18
        ring.path = CGPath(
            ellipseIn: CGRect(x: -diameter / 2, y: -diameter / 2, width: diameter, height: diameter),
            transform: nil
        )
        ring.position = origin
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = color.withAlphaComponent(0.92).cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        host.addSublayer(ring)

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.18, 8.8]
        scale.keyTimes = [0, 1]
        scale.duration = 1.18
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.95, 0]
        fade.keyTimes = [0, 0.06, 1]
        fade.duration = 1.18
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.18
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "rashun.reset.ring")
    }

    private static func popAnimation(from: CGPoint, to: CGPoint) -> CAAnimationGroup {
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: from)
        position.toValue = NSValue(point: to)
        position.duration = 1.34
        position.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 1, 0.82, 0]
        opacity.keyTimes = [0, 0.03, 0.74, 1]
        opacity.duration = 1.34

        let group = CAAnimationGroup()
        group.animations = [position, opacity]
        group.duration = 1.34
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return group
    }

    private static func popColors(from source: NSColor) -> [NSColor] {
        let accent = source.blended(withFraction: 0.52, of: .white) ?? source
        let soft = source.blended(withFraction: 0.22, of: .white) ?? source
        return [source, accent, .white, soft]
    }

    private static func color(from hex: UInt32) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
