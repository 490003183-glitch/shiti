import AppKit
import QuartzCore

/// An outside press may become a drag into the drawer. Decide only on release.
struct OutsideClickDismissal {
    private var waitingForLeftRelease = false

    mutating func consume(_ type: NSEvent.EventType, insidePanel: Bool) -> Bool {
        switch type {
        case .leftMouseDown:
            waitingForLeftRelease = !insidePanel
            return false
        case .leftMouseUp:
            let dismiss = waitingForLeftRelease && !insidePanel
            waitingForLeftRelease = false
            return dismiss
        case .rightMouseDown:
            waitingForLeftRelease = false
            return !insidePanel
        default:
            return false
        }
    }
}

enum DrawerGestureIntent: Equatable { case open, close }

struct TopEdgeGesture {
    private var accumulated: CGFloat = 0
    private var lastTime: TimeInterval = 0
    private var lastTrigger: TimeInterval = -.infinity
    private var edge: CGRect?

    static func isAtTop(_ point: CGPoint, screen: CGRect) -> Bool {
        point.x >= screen.minX && point.x < screen.maxX
            && point.y >= screen.maxY - 5 && point.y <= screen.maxY
    }

    mutating func consume(deltaY: CGFloat, inverted: Bool, precise: Bool, momentum: Bool,
                          screen: CGRect?, time: TimeInterval, reversed: Bool = false) -> DrawerGestureIntent? {
        guard let screen, !momentum else {
            accumulated = 0
            edge = nil
            return nil
        }
        guard time - lastTrigger >= 0.35 else { return nil }
        if edge != screen || time - lastTime > 0.3 {
            accumulated = 0
        }
        edge = screen
        lastTime = time
        // Physical downward movement: two fingers down with natural scrolling,
        // or the wheel down with conventional mouse scrolling.
        let delta = deltaY * (inverted ? 1 : -1) * (reversed ? -1 : 1)
        guard delta != 0 else { return nil }
        if accumulated * delta < 0 { accumulated = 0 }
        accumulated += delta
        let threshold: CGFloat = precise ? 8 : 0.5
        guard abs(accumulated) >= threshold else { return nil }
        let intent: DrawerGestureIntent = accumulated > 0 ? .open : .close
        lastTrigger = time
        accumulated = 0
        return intent
    }
}

/// A stationary, transparent window clips the moving content to its own screen.
/// This avoids drawing the drawer across a second display stacked above it.
final class DrawerClipView: NSView {
    let body: NSView
    private var settledProgress: CGFloat = 0
    private var flight: (from: CGFloat, target: CGFloat, start: TimeInterval, duration: TimeInterval)?
    private var completionWork: DispatchWorkItem?
    private var generation = 0
    private var completion: (() -> Void)?
    var isAnimating: Bool { flight != nil }
    var isSuspended: Bool { body.superview == nil }
    var progress: CGFloat {
        guard let flight else { return settledProgress }
        let t = min(1, max(0, (ProcessInfo.processInfo.systemUptime - flight.start) / flight.duration))
        return flight.from + (flight.target - flight.from) * CGFloat(1 - pow(1 - t, 3))
    }

    init(body: NSView) {
        self.body = body
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 12
        body.wantsLayer = true
        addSubview(body)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layoutBody()
    }

    private func layoutBody() {
        guard !isSuspended else { return }
        let frame = NSRect(origin: .zero, size: bounds.size)
        if body.frame != frame { body.frame = frame }
        setOffset(for: flight?.target ?? settledProgress)
    }

    private func setOffset(for progress: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.layer?.transform = CATransform3DMakeTranslation(0, (1 - progress) * bounds.height, 0)
        CATransaction.commit()
    }

    // Retain the same editor (including undo and selection) without a window
    // connection while hidden, so it does not participate in window layout.
    func suspend() {
        guard !isAnimating, progress == 0 else { return }
        body.removeFromSuperview()
    }

    func resume() {
        if isSuspended { addSubview(body) }
        layoutBody()
    }

    func animate(open: Bool, reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                 completion: @escaping () -> Void) {
        if open { resume() }
        let from: CGFloat
        if isAnimating, bounds.height > 0, let presentation = body.layer?.presentation() {
            from = min(1, max(0, 1 - presentation.transform.m42 / bounds.height))
        } else {
            from = progress
        }
        completionWork?.cancel()
        completionWork = nil
        flight = nil
        generation += 1
        body.layer?.removeAnimation(forKey: "drawerSlide")
        self.completion = completion
        let target: CGFloat = open ? 1 : 0
        guard !reduceMotion, abs(target - from) > 0.001 else {
            settledProgress = target
            layoutBody()
            finish()
            return
        }
        let duration = max(0.08, 0.24 * Double(abs(target - from)))
        flight = (from, target, ProcessInfo.processInfo.systemUptime, duration)
        setOffset(for: target)
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = (1 - from) * bounds.height
        animation.toValue = (1 - target) * bounds.height
        animation.duration = duration
        // x(t) is linear and y(t) = 1 - (1-t)^3, matching progress on reversal.
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 1.0 / 3, 1, 2.0 / 3, 1)
        body.layer?.add(animation, forKey: "drawerSlide")
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.settledProgress = target
            self.flight = nil
            self.body.layer?.removeAnimation(forKey: "drawerSlide")
            self.layoutBody()
            self.finish()
        }
        completionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func finish() {
        completionWork = nil
        let callback = completion
        completion = nil
        callback?()
    }

    func stop() {
        settledProgress = progress
        flight = nil
        generation += 1
        completionWork?.cancel()
        completionWork = nil
        body.layer?.removeAnimation(forKey: "drawerSlide")
        layoutBody()
        completion = nil
    }

    deinit { completionWork?.cancel() }
}
