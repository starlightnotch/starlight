import AppKit
import Combine
import QuartzCore
import SwiftUI

/// The notch's black shape, its shadow, and the clip for everything inside it, as Core Animation
/// layers whose springs run in the system's render server.
///
/// Drawn by SwiftUI, every frame of a spring was worked out on the main thread and handed over
/// just in time, so a frame now and then arrived late (about one per open, measured in Instruments)
/// even with the app idle. Here the render server runs the spring itself: the edge moves on every
/// display refresh whatever the app is doing. The content stays SwiftUI (NotchView with
/// `drawsShape: false`), clipped by `clip`, which morphs with the shape in the same transaction.
///
/// The springs are SwiftUI's own (Motion): response and damping become stiffness and damping, and
/// an interrupted spring hands its speed to the next one, so a hover that turns into an open, or
/// a close caught halfway, keeps moving the way it was. `STARLIGHT_SWIFTUI_SHAPE=1` draws the shape in
/// SwiftUI as before, for comparison.
final class NotchMorphView: NSView {
    static var isEnabled: Bool { Dev.env("STARLIGHT_SWIFTUI_SHAPE") == nil }

    private let model: NotchModel
    private let host: NSView
    private let fill = CAShapeLayer()
    private let clip = CAShapeLayer()
    private var observer: AnyCancellable?
    private var pending = false

    /// The spring in flight: where it started, where it's going, and how.
    private struct Flight {
        var from: CGSize
        var to: CGSize
        var velocity: CGSize      // points a second, at the start
        var spring: Spring
        var start: CFTimeInterval
        var speed: Double
    }
    private var flight: Flight?
    private var target: CGSize = .zero
    private var shadowed = false
    private var last = (hovering: false, pressing: false, open: false)

    struct Spring {
        let response: Double
        let damping: Double
        static let hoverIn = Spring(response: 0.36, damping: 0.5)
        static let close = Spring(response: 0.38, damping: 0.96)
        static let open = Spring(response: 0.46, damping: 0.66)
        static let press = Spring(response: 0.42, damping: 0.6)
        var omega: Double { 2 * .pi / response }
    }

    init(host: NSView, model: NotchModel) {
        self.host = host
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)

        fill.fillColor = NSColor.black.cgColor
        fill.shadowColor = NSColor.black.cgColor
        fill.shadowRadius = Motion.shadowRadius / 2
        fill.shadowOffset = CGSize(width: 0, height: Motion.shadowY)
        fill.shadowOpacity = 0
        layer?.insertSublayer(fill, at: 0)
        clip.fillColor = NSColor.black.cgColor
        host.wantsLayer = true
        host.layer?.mask = clip

        observer = model.objectWillChange.sink { [weak self] in self?.scheduleUpdate() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Clicks, scrolls and hovers belong to the SwiftUI content (whose hosting view opens the
    /// notch on mouseUp); the layers here never take them, so where there's no notch, there's
    /// nothing to hit.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates; the host's hitTest wants this view's.
        host.hitTest(convert(point, from: superview))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        clip.frame = host.bounds
        CATransaction.commit()
        // The panel moved or resized: redraw where the notch is now, without a spring.
        flight = nil
        apply(size: target == .zero ? model.size : target, animated: false)
    }

    /// The model changes several things per event; one update after them, on this turn's end.
    private func scheduleUpdate() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.update()
        }
    }

    private func update() {
        let size = model.size
        let state = (hovering: model.hovering, pressing: model.pressing, open: model.isOpen)
        defer { last = state }
        if model.isShadowed != shadowed {
            shadowed = model.isShadowed
            let fade = CABasicAnimation(keyPath: "shadowOpacity")
            fade.fromValue = fill.presentation()?.shadowOpacity ?? fill.shadowOpacity
            fade.duration = 0.3
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fill.shadowOpacity = shadowed ? Float(Motion.shadowOpacity) : 0
            fill.add(fade, forKey: "shadow")
        }
        guard abs(size.width - target.width) > 0.01 || abs(size.height - target.height) > 0.01 else { return }
        // The same spring the model picked for this change.
        let spring: Spring
        if state.pressing != last.pressing, !state.open { spring = .press }
        else if state.hovering != last.hovering, !state.open, !last.open { spring = state.hovering ? .hoverIn : .close }
        else if state.open != last.open { spring = state.open ? .open : .close }
        else { spring = size.width * size.height >= target.width * target.height ? .open : .close }
        apply(size: size, animated: true, spring: spring)
    }

    /// Where the notch is now, and how fast it's moving, from the spring in flight.
    private func current(at time: CFTimeInterval) -> (size: CGSize, velocity: CGSize) {
        guard let f = flight else { return (target, .zero) }
        let t = (time - f.start) * f.speed
        func axis(_ from: CGFloat, _ to: CGFloat, _ v0: CGFloat) -> (CGFloat, CGFloat) {
            let (x, v) = Self.spring(displacement: Double(from - to), velocity: Double(v0), spring: f.spring, time: t)
            return (to + CGFloat(x), CGFloat(v * f.speed))
        }
        let (w, vw) = axis(f.from.width, f.to.width, f.velocity.width)
        let (h, vh) = axis(f.from.height, f.to.height, f.velocity.height)
        return (CGSize(width: w, height: h), CGSize(width: vw, height: vh))
    }

    /// A damped spring's offset from its rest point and its speed, `time` seconds in.
    static func spring(displacement x0: Double, velocity v0: Double, spring: Spring, time t: Double) -> (Double, Double) {
        let w = spring.omega, z = min(spring.damping, 0.9999)
        let wd = w * (1 - z * z).squareRoot()
        let a = x0, b = (v0 + z * w * x0) / wd
        let e = exp(-z * w * t), c = cos(wd * t), s = sin(wd * t)
        let x = e * (a * c + b * s)
        let v = e * ((b * wd - z * w * a) * c - (a * wd + z * w * b) * s)
        return (x, v)
    }

    private func path(_ size: CGSize) -> CGPath {
        let rect = CGRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
        return NotchShape(notchSize: CGSize(width: model.closedSize.width, height: model.notchSize.height)).path(in: rect).cgPath
    }

    private func apply(size: CGSize, animated: Bool, spring: Spring = .close) {
        let now = CACurrentMediaTime()
        let (from, velocity) = current(at: now)
        target = size
        NotchTrace.lastDrawn = size
        let speed = AppSettings.shared.animationSpeed / max(model.slowMotion, 0.01)
        let newPath = path(size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard animated, bounds.width > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            flight = nil
            for layer in [fill, clip] { layer.removeAllAnimations() }
            fill.path = newPath; fill.shadowPath = newPath; clip.path = newPath
            return
        }
        flight = Flight(from: from, to: size, velocity: velocity, spring: spring, start: now, speed: speed)
        // The render server's spring runs from 0 (where it is) to 1 (where it's going); its
        // starting speed is the old spring's, in those units, along the side that moves most.
        let dw = size.width - from.width, dh = size.height - from.height
        let progressVelocity = abs(dw) >= abs(dh) ? (abs(dw) > 0.5 ? velocity.width / dw : 0) : (abs(dh) > 0.5 ? velocity.height / dh : 0)
        let fromPath = path(from)
        for (layer, key) in [(fill, "path"), (fill, "shadowPath"), (clip, "path")] {
            let animation = CASpringAnimation(keyPath: key)
            animation.mass = 1
            animation.stiffness = spring.omega * spring.omega
            animation.damping = 2 * min(spring.damping, 0.9999) * spring.omega
            animation.initialVelocity = progressVelocity
            animation.fromValue = fromPath
            animation.toValue = newPath
            animation.duration = animation.settlingDuration
            animation.speed = Float(speed)
            layer.add(animation, forKey: key == "shadowPath" ? "morph-shadow" : "morph")
        }
        fill.path = newPath
        fill.shadowPath = newPath
        clip.path = newPath
    }
}
