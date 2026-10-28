import AppKit
import SwiftUI

/// Starlight's own icon set, drawn instead of SF Symbols so every icon shares one language:
///
/// - A 24-unit grid, rounded caps and joins, one stroke weight that scales with size.
/// - Built from the app's own shapes: the voice bars (pills on a sine envelope), the notch
///   silhouette (cut into the page and the screen), the spring curve, and a four-point spark.
/// - Each icon has one small motion while hovered, eased with an overshoot like the notch's
///   springs: bars dance, slider knobs swap, the notch widens, the lid lifts, the arc rewinds.
struct Glyph: View {
    enum Kind {
        case voice, note, noteLive, noteAnswered, history, sliders, screen, spring, keycap, spark
        case check, alert, folder, trash, rewind, close, external, key, search, calc, memory, puzzle, globe, posts, agent, battery, headphones, play, pause, next, previous, screen2, export, copy, mouse, bluetooth
        case cross, terminal, file, todo, shield, gauge

        /// Moves continuously while active, instead of easing to a pose and stopping.
        var isPeriodic: Bool { self == .voice || self == .spring || self == .globe || self == .agent }
        /// Draws itself on when it appears (the result tick, the error mark).
        var drawsOn: Bool { self == .check || self == .alert || self == .cross }
    }

    let kind: Kind
    var size: CGFloat = 16
    var active = false

    /// A level the glyph shows (the battery's charge), set with `.environment(\.glyphLevel, …)`.
    @Environment(\.glyphLevel) private var level
    @State private var changed = Date.distantPast
    @State private var appeared = Date.distantPast
    @State private var running = false
    @State private var token = UUID()

    var body: some View {
        TimelineView(.animation(paused: !running)) { timeline in
            Canvas { context, canvas in
                let t = timeline.date
                let pose = GlyphPose(
                    amount: amount(at: t),
                    phase: t.timeIntervalSinceReferenceDate,
                    drawn: kind.drawsOn ? Self.easeOut(min(max(t.timeIntervalSince(appeared) / 0.4, 0), 1)) : 1,
                    level: level)
                GlyphArt.draw(kind, pose: pose, size: size, in: &context, canvas: canvas)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard kind.drawsOn, !Render.isRendering else { return }
            appeared = Date()
            run(for: 0.45)
        }
        .onChange(of: active) { _, _ in
            changed = Date()
            run(for: 0.5)
        }
        .accessibilityHidden(true)
    }

    /// 0 at rest, 1 in the hover pose, with a little overshoot on the way in.
    private func amount(at t: Date) -> Double {
        let dt = t.timeIntervalSince(changed)
        let k = min(max(dt / 0.42, 0), 1)
        return active ? Self.easeOutBack(k) : 1 - Self.easeOut(k)
    }

    private func run(for seconds: Double) {
        running = true
        let mine = UUID()
        token = mine
        let keepRunning = active && kind.isPeriodic
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if token == mine && !keepRunning { running = false }
        }
    }

    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.6, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    /// A template image for menus (NSMenuItem.image).
    @MainActor static func menuImage(_ kind: Kind) -> NSImage? {
        let renderer = ImageRenderer(content: Glyph(kind: kind, size: 16).foregroundStyle(.black))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}

struct GlyphPose {
    var amount: Double   // hover pose, 0…1 (can overshoot)
    var phase: Double    // seconds, for periodic motion
    var drawn: Double    // draw-on progress, 0…1
    var level: Double? = nil
}

private struct GlyphLevelKey: EnvironmentKey { static let defaultValue: Double? = nil }

extension EnvironmentValues {
    var glyphLevel: Double? {
        get { self[GlyphLevelKey.self] }
        set { self[GlyphLevelKey.self] = newValue }
    }
}

enum GlyphArt {
    /// Stroke weight in points: about 1.85pt at 24pt, never thinner than 1.25pt.
    static func strokeWidth(_ size: CGFloat) -> CGFloat { max(1.25, 1.85 * size / 24) }

    static func draw(_ kind: Glyph.Kind, pose p: GlyphPose, size: CGFloat, in ctx: inout GraphicsContext, canvas: CGSize) {
        ctx.scaleBy(x: canvas.width / 24, y: canvas.height / 24)
        let w = strokeWidth(size) * 24 / size
        let line = StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round)
        let a = CGFloat(p.amount)

        func stroke(_ path: Path) { ctx.stroke(path, with: .foreground, style: line) }
        func fill(_ path: Path) { ctx.fill(path, with: .foreground) }
        /// Cuts a gap around a badge so it reads separately from the shape under it.
        func knockout(_ path: Path) {
            var c = ctx
            c.blendMode = .destinationOut
            c.fill(path, with: .color(.black))
        }
        func seg(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> Path {
            Path { $0.move(to: CGPoint(x: x1, y: y1)); $0.addLine(to: CGPoint(x: x2, y: y2)) }
        }
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }

        switch kind {
        case .voice:
            // The app's voice bars: five pills under a sine envelope.
            let base: [CGFloat] = [5, 10.5, 15, 10.5, 5]
            for (i, h0) in base.enumerated() {
                let wobble = sin(p.phase * 7 + Double(i) * 1.25)
                let h = min(max(h0 * (1 + 0.42 * min(a, 1) * CGFloat(wobble)), 3), 17)
                let x = 4 + CGFloat(i) * 4
                stroke(seg(x, 12 - h / 2, x, 12 + h / 2))
            }

        case .note, .noteLive, .noteAnswered:
            stroke(page)
            // Lines of text; the last one writes itself out on hover.
            stroke(seg(8.6, 10.6, 15.4, 10.6))
            stroke(seg(8.6, 14, 15.4, 14))
            stroke(seg(8.6, 17.4, 11.6 + 3.8 * a, 17.4))
            if kind == .noteLive {
                knockout(circle(18.2, 18.2, 4.6))
                fill(circle(18.2, 18.2, 2.9 + 0.35 * a))
            } else if kind == .noteAnswered {
                knockout(circle(18.4, 18, 5))
                fill(spark(center: CGPoint(x: 18.4, y: 18), radius: 4.2, turn: Double(a) * 90))
            }

        case .history, .rewind:
            // An arc that rewinds on hover; history keeps three voice bars inside.
            var arc = ctx
            arc.translateBy(x: 12, y: 12)
            arc.rotate(by: .degrees(-38 * Double(a)))
            arc.translateBy(x: -12, y: -12)
            let r: CGFloat = kind == .history ? 8.6 : 7.6
            arc.stroke(rewindArc(radius: r), with: .foreground, style: line)
            if kind == .history {
                stroke(seg(9.4, 10.6, 9.4, 13.4))
                stroke(seg(12, 9, 12, 15))
                stroke(seg(14.6, 10.2, 14.6, 13.8))
            }

        case .sliders:
            // Two sliders whose knobs trade places on hover.
            let k1 = 15.5 - 7 * a, k2 = 8.5 + 7 * a
            stroke(seg(3.5, 8, 20.5, 8))
            stroke(seg(3.5, 16, 20.5, 16))
            knockout(circle(k1, 8, 4.4))
            knockout(circle(k2, 16, 4.4))
            stroke(circle(k1, 8, 2.5))
            stroke(circle(k2, 16, 2.5))

        case .screen:
            // A display with the notch cut in; the notch widens on hover, like the real one.
            stroke(Path(roundedRect: CGRect(x: 2.5, y: 4.5, width: 19, height: 15), cornerRadius: 3.6, style: .continuous))
            let half = 2.8 + 1.8 * a, depth = 3.2 + 0.8 * a
            fill(Path(roundedRect: CGRect(x: 12 - half, y: 4.5, width: half * 2, height: depth),
                      cornerRadii: .init(bottomLeading: 1.6, bottomTrailing: 1.6), style: .continuous))

        case .spring:
            // An animation curve that overshoots and settles, like the notch's springs. On hover
            // a dot rides the curve from start to finish.
            var curve = Path()
            curve.move(to: CGPoint(x: 4, y: 19))
            curve.addCurve(to: CGPoint(x: 14, y: 4.2), control1: CGPoint(x: 9, y: 19), control2: CGPoint(x: 9.5, y: 4))
            curve.addCurve(to: CGPoint(x: 20, y: 7), control1: CGPoint(x: 17, y: 4.3), control2: CGPoint(x: 18, y: 7))
            stroke(curve)
            fill(circle(4, 19, w * 0.95))
            let ride = min(max(a, 0), 1)
            if ride > 0.02, let point = curve.trimmedPath(from: 0, to: ride).currentPoint {
                knockout(circle(point.x, point.y, 3.3))
                fill(circle(point.x, point.y, 2.1))
            } else {
                fill(circle(20, 7, w * 0.95))
            }

        case .keycap:
            // A small keyboard: two rows of keys and a space bar. Keys light up left to right on hover.
            stroke(Path(roundedRect: CGRect(x: 2.5, y: 5.5, width: 19, height: 13), cornerRadius: 3.4, style: .continuous))
            for row in 0..<2 {
                for col in 0..<4 {
                    let x = 6.6 + CGFloat(col) * 3.6, y = 9.4 + CGFloat(row) * 3
                    let lit = a * 5 > CGFloat(col + row)
                    fill(circle(x, y, lit ? w * 0.68 : w * 0.52))
                }
            }
            stroke(seg(8.6, 15.4, 15.4, 15.4))

        case .spark:
            // The big spark makes a quarter turn (it looks the same at rest and posed); the small one twinkles.
            fill(spark(center: CGPoint(x: 10.8, y: 13.2), radius: 8.8, turn: Double(a) * 90))
            let s = 3.3 * (1 + 0.3 * a)
            fill(spark(center: CGPoint(x: 19.2, y: 4.8), radius: s, turn: 0))

        case .check:
            // A filled disc with the tick cut out of it, drawn on when the result appears.
            fill(circle(12, 12, 10))
            var tick = Path()
            tick.move(to: CGPoint(x: 7.6, y: 12.4))
            tick.addLine(to: CGPoint(x: 10.7, y: 15.4))
            tick.addLine(to: CGPoint(x: 16.4, y: 9))
            var c = ctx
            c.blendMode = .destinationOut
            c.stroke(tick.trimmedPath(from: 0, to: p.drawn), with: .color(.black), style: StrokeStyle(lineWidth: w * 1.1, lineCap: .round, lineJoin: .round))

        case .alert:
            fill(circle(12, 12, 10))
            var c = ctx
            c.blendMode = .destinationOut
            c.stroke(seg(12, 6.8, 12, 13.2).trimmedPath(from: 0, to: p.drawn), with: .color(.black),
                     style: StrokeStyle(lineWidth: w * 1.1, lineCap: .round))
            if p.drawn > 0.6 { c.fill(circle(12, 17, w * 0.62), with: .color(.black)) }

        case .cross:
            // The check's opposite: a filled disc with an X cut out, drawn on stroke by stroke.
            fill(circle(12, 12, 10))
            var c = ctx
            c.blendMode = .destinationOut
            let style = StrokeStyle(lineWidth: w * 1.1, lineCap: .round)
            c.stroke(seg(8.6, 8.6, 15.4, 15.4).trimmedPath(from: 0, to: min(p.drawn * 2, 1)), with: .color(.black), style: style)
            if p.drawn > 0.5 {
                c.stroke(seg(15.4, 8.6, 8.6, 15.4).trimmedPath(from: 0, to: (p.drawn - 0.5) * 2), with: .color(.black), style: style)
            }

        case .gauge:
            // A dial whose needle swings up on hover.
            var arc = Path()
            arc.addArc(center: CGPoint(x: 12, y: 15), radius: 8.5, startAngle: .degrees(160), endAngle: .degrees(20), clockwise: false)
            stroke(arc)
            let angle = Angle.degrees(200 + 100 * Double(min(max(a, 0), 1)) + 20)
            let tip = CGPoint(x: 12 + 6 * CGFloat(cos(angle.radians)), y: 15 + 6 * CGFloat(sin(angle.radians)))
            stroke(seg(12, 15, tip.x, tip.y))
            fill(circle(12, 15, w * 0.9))

        case .shield:
            // A shield that lifts a little on hover while a tick draws itself inside.
            var c = ctx
            c.translateBy(x: 0, y: -1.2 * a)
            var shield = Path()
            shield.move(to: CGPoint(x: 12, y: 3))
            shield.addCurve(to: CGPoint(x: 19.5, y: 6), control1: CGPoint(x: 14.6, y: 4.6), control2: CGPoint(x: 17.2, y: 5.6))
            shield.addCurve(to: CGPoint(x: 12, y: 21), control1: CGPoint(x: 19.8, y: 13.5), control2: CGPoint(x: 16.8, y: 18.6))
            shield.addCurve(to: CGPoint(x: 4.5, y: 6), control1: CGPoint(x: 7.2, y: 18.6), control2: CGPoint(x: 4.2, y: 13.5))
            shield.addCurve(to: CGPoint(x: 12, y: 3), control1: CGPoint(x: 6.8, y: 5.6), control2: CGPoint(x: 9.4, y: 4.6))
            shield.closeSubpath()
            c.stroke(shield, with: .foreground, style: line)
            var tick = Path()
            tick.move(to: CGPoint(x: 8.8, y: 11.8))
            tick.addLine(to: CGPoint(x: 11.1, y: 14.1))
            tick.addLine(to: CGPoint(x: 15.4, y: 9.4))
            c.stroke(tick.trimmedPath(from: 0, to: 0.35 + 0.65 * min(max(a, 0), 1)), with: .foreground, style: line)

        case .terminal:
            // A window with a prompt; the cursor blinks while it's working.
            stroke(Path(roundedRect: CGRect(x: 3, y: 4.5, width: 18, height: 15), cornerRadius: 3.2, style: .continuous))
            var prompt = Path()
            prompt.move(to: CGPoint(x: 7, y: 9.5))
            prompt.addLine(to: CGPoint(x: 10, y: 12))
            prompt.addLine(to: CGPoint(x: 7, y: 14.5))
            stroke(prompt)
            stroke(seg(12.5, 14.8, 16.5 + a, 14.8))

        case .file:
            // A page with a folded corner and two lines of text.
            var page = Path()
            page.move(to: CGPoint(x: 13.5, y: 3))
            page.addLine(to: CGPoint(x: 8, y: 3))
            page.addArc(tangent1End: CGPoint(x: 5, y: 3), tangent2End: CGPoint(x: 5, y: 21), radius: 2.6)
            page.addArc(tangent1End: CGPoint(x: 5, y: 21), tangent2End: CGPoint(x: 19, y: 21), radius: 2.6)
            page.addArc(tangent1End: CGPoint(x: 19, y: 21), tangent2End: CGPoint(x: 19, y: 8.5), radius: 2.6)
            page.addLine(to: CGPoint(x: 19, y: 8.5))
            page.closeSubpath()
            stroke(page)
            var fold = Path()
            fold.move(to: CGPoint(x: 13.5, y: 3))
            fold.addLine(to: CGPoint(x: 13.5, y: 8.5))
            fold.addLine(to: CGPoint(x: 19, y: 8.5))
            stroke(fold)
            stroke(seg(8.5, 13, 15.5 - a, 13)); stroke(seg(8.5, 16.5, 13.5 + a, 16.5))

        case .todo:
            // A ticked box and a line, then an empty box and a line.
            stroke(Path(roundedRect: CGRect(x: 3.5, y: 4, width: 6.5, height: 6.5), cornerRadius: 1.8, style: .continuous))
            var tick = Path()
            tick.move(to: CGPoint(x: 5.1, y: 7.3))
            tick.addLine(to: CGPoint(x: 6.5, y: 8.7))
            tick.addLine(to: CGPoint(x: 8.6, y: 5.9))
            stroke(tick)
            stroke(seg(13, 7.25, 20.5, 7.25))
            stroke(Path(roundedRect: CGRect(x: 3.5, y: 13.5, width: 6.5, height: 6.5), cornerRadius: 1.8, style: .continuous))
            stroke(seg(13, 16.75, 18.5 + a * 2, 16.75))

        case .folder:
            var path = Path()
            path.move(to: CGPoint(x: 3, y: 17))
            path.addArc(tangent1End: CGPoint(x: 3, y: 5), tangent2End: CGPoint(x: 9, y: 5), radius: 2.2)
            path.addLine(to: CGPoint(x: 8.6, y: 5))
            path.addLine(to: CGPoint(x: 10.8, y: 7.4))
            path.addArc(tangent1End: CGPoint(x: 21, y: 7.4), tangent2End: CGPoint(x: 21, y: 19.5), radius: 2.2)
            path.addArc(tangent1End: CGPoint(x: 21, y: 19.5), tangent2End: CGPoint(x: 3, y: 19.5), radius: 2.2)
            path.addArc(tangent1End: CGPoint(x: 3, y: 19.5), tangent2End: CGPoint(x: 3, y: 5), radius: 2.2)
            path.closeSubpath()
            stroke(path)
            stroke(seg(3, 10.6 - 0.8 * a, 21, 10.6 - 0.8 * a))

        case .trash:
            // The lid lifts and tips on hover.
            var lid = ctx
            lid.translateBy(x: 0, y: -1.6 * a)
            lid.translateBy(x: 4, y: 6.5)
            lid.rotate(by: .degrees(-9 * Double(a)))
            lid.translateBy(x: -4, y: -6.5)
            var top = Path()
            top.move(to: CGPoint(x: 9.4, y: 6.5))
            top.addArc(tangent1End: CGPoint(x: 9.4, y: 3.8), tangent2End: CGPoint(x: 14.6, y: 3.8), radius: 1.4)
            top.addArc(tangent1End: CGPoint(x: 14.6, y: 3.8), tangent2End: CGPoint(x: 14.6, y: 6.5), radius: 1.4)
            top.addLine(to: CGPoint(x: 14.6, y: 6.5))
            lid.stroke(top, with: .foreground, style: line)
            lid.stroke(seg(3.8, 6.5, 20.2, 6.5), with: .foreground, style: line)
            var body = Path()
            body.move(to: CGPoint(x: 6, y: 9))
            body.addArc(tangent1End: CGPoint(x: 6.9, y: 20.5), tangent2End: CGPoint(x: 17, y: 20.5), radius: 2.2)
            body.addArc(tangent1End: CGPoint(x: 17.1, y: 20.5), tangent2End: CGPoint(x: 18, y: 9), radius: 2.2)
            body.addLine(to: CGPoint(x: 18, y: 9))
            stroke(body)
            stroke(seg(10.2, 11.5, 10.4, 17))
            stroke(seg(13.8, 11.5, 13.6, 17))

        case .close:
            let d = 4.6 * (1 - 0.08 * a)
            stroke(seg(12 - d, 12 - d, 12 + d, 12 + d))
            stroke(seg(12 + d, 12 - d, 12 - d, 12 + d))

        case .external:
            let o = 1.2 * a
            stroke(seg(7 + o, 17 - o, 16.5 + o, 7.5 - o))
            var head = Path()
            head.move(to: CGPoint(x: 9.5 + o, y: 7.5 - o))
            head.addLine(to: CGPoint(x: 16.5 + o, y: 7.5 - o))
            head.addLine(to: CGPoint(x: 16.5 + o, y: 14.5 - o))
            stroke(head)

        case .key:
            var c = ctx
            c.translateBy(x: 8.5, y: 15.5)
            c.rotate(by: .degrees(-18 * Double(a)))
            c.translateBy(x: -8.5, y: -15.5)
            c.stroke(circle(8.2, 15.8, 4.3), with: .foreground, style: line)
            c.stroke(seg(11.3, 12.7, 20, 4), with: .foreground, style: line)
            c.stroke(seg(16.8, 7.2, 19, 9.4), with: .foreground, style: line)
            c.stroke(seg(14.4, 9.6, 16, 11.2), with: .foreground, style: line)

        case .calc:
            // Plus, minus, times, equals in four quadrants; the times turns into a plus on hover.
            stroke(seg(4.5, 7.5, 10.5, 7.5)); stroke(seg(7.5, 4.5, 7.5, 10.5))
            stroke(seg(13.5, 7.5, 19.5, 7.5))
            var times = ctx
            times.translateBy(x: 7.5, y: 16.5)
            times.rotate(by: .degrees(45 * (1 - Double(min(a, 1)))))
            times.stroke(seg(-3, 0, 3, 0), with: .foreground, style: line)
            times.stroke(seg(0, -3, 0, 3), with: .foreground, style: line)
            stroke(seg(13.5, 15, 19.5, 15)); stroke(seg(13.5, 18.2, 19.5, 18.2))

        case .memory:
            // Past notes stacked behind the current page; they fan out on hover.
            let lift = 1.4 * a
            var back = ctx
            back.translateBy(x: lift, y: -lift)
            back.stroke(Path(roundedRect: CGRect(x: 8.5, y: 2.5, width: 12.5, height: 14.5), cornerRadius: 3, style: .continuous),
                        with: .foreground, style: line)
            let front = CGRect(x: 3, y: 7, width: 12.5, height: 14.5)
            knockout(Path(roundedRect: front.insetBy(dx: -w * 1.2, dy: -w * 1.2), cornerRadius: 4.2, style: .continuous))
            stroke(Path(roundedRect: front, cornerRadius: 3, style: .continuous))
            stroke(seg(6.3, 12, 12.2, 12))
            stroke(seg(6.3, 15.4, 10.4, 15.4))

        case .puzzle:
            // A puzzle piece: a square with knobs on its top and right; the knobs grow on hover.
            let body = CGRect(x: 3.5, y: 7.5, width: 13, height: 13)
            let r = 2.5 + 0.35 * a
            stroke(Path(roundedRect: body, cornerRadius: 2.6, style: .continuous))
            knockout(circle(10, 7.5, r + w * 0.2))
            knockout(circle(16.5, 14, r + w * 0.2))
            var knobs = Path()
            knobs.addArc(center: CGPoint(x: 10, y: 7.5), radius: r, startAngle: .degrees(160), endAngle: .degrees(20), clockwise: false)
            knobs.move(to: CGPoint(x: 16.5 + r * cos(.pi * 250 / 180), y: 14 + r * sin(.pi * 250 / 180)))
            knobs.addArc(center: CGPoint(x: 16.5, y: 14), radius: r, startAngle: .degrees(250), endAngle: .degrees(110), clockwise: false)
            stroke(knobs)

        case .globe:
            // A globe whose meridians turn while it's searching.
            stroke(circle(12, 12, 9))
            stroke(seg(3, 12, 21, 12))
            let spin = Double(min(max(a, 0), 1)) * p.phase * 2.4
            for offset in [Double.pi / 3, .pi / 3 + .pi / 2] {  // at rest: one meridian, half the globe's width
                let width = 9 * CGFloat(abs(cos(spin + offset)))
                if width > 0.6 {
                    stroke(Path(ellipseIn: CGRect(x: 12 - width, y: 3, width: width * 2, height: 18)))
                } else {
                    stroke(seg(12, 3, 12, 21))
                }
                if a < 0.01 { break }  // at rest: one meridian
            }

        case .agent:
            // The agent: a thin ring around a dot. Thinking (active), the ring opens into an arc
            // that turns, and the dot breathes.
            let k = min(max(a, 0), 1)
            let sweep = 360 - 110 * Double(k)
            let turn = Double(k) * p.phase * 300
            if sweep >= 359.5 {
                stroke(circle(12, 12, 8.2))
            } else {
                var arc = Path()
                arc.addArc(center: CGPoint(x: 12, y: 12), radius: 8.2, startAngle: .degrees(turn - 90),
                           endAngle: .degrees(turn - 90 + sweep), clockwise: false)
                stroke(arc)
            }
            let r = 2.7 + 0.45 * k * CGFloat(sin(p.phase * 5))
            fill(circle(12, 12, r))

        case .battery:
            // A battery outline with its charge as a fill; `amount` doubles as the level (0…1).
            stroke(Path(roundedRect: CGRect(x: 2.5, y: 7.5, width: 17, height: 9), cornerRadius: 2.6, style: .continuous))
            stroke(seg(21.2, 10.6, 21.2, 13.4))
            let level = CGFloat(min(max(p.level ?? Double(a), 0.06), 1))
            fill(Path(roundedRect: CGRect(x: 4.6, y: 9.6, width: 12.8 * level, height: 4.8), cornerRadius: 1.2, style: .continuous))

        case .headphones:
            // An over-ear band and two cups; the cups lean in on hover.
            var band = Path()
            band.addArc(center: CGPoint(x: 12, y: 13), radius: 8, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            stroke(band)
            let lean = 0.6 * a
            fill(Path(roundedRect: CGRect(x: 3 + lean, y: 13, width: 4.2, height: 7.5), cornerRadius: 1.8, style: .continuous))
            fill(Path(roundedRect: CGRect(x: 16.8 - lean, y: 13, width: 4.2, height: 7.5), cornerRadius: 1.8, style: .continuous))

        case .play:
            var tri = Path()
            tri.move(to: CGPoint(x: 8, y: 5.5)); tri.addLine(to: CGPoint(x: 19, y: 12)); tri.addLine(to: CGPoint(x: 8, y: 18.5)); tri.closeSubpath()
            ctx.fill(tri, with: .foreground)
            ctx.stroke(tri, with: .foreground, style: StrokeStyle(lineWidth: w * 0.9, lineJoin: .round))

        case .pause:
            fill(Path(roundedRect: CGRect(x: 6.5, y: 5.5, width: 4, height: 13), cornerRadius: 1.4, style: .continuous))
            fill(Path(roundedRect: CGRect(x: 13.5, y: 5.5, width: 4, height: 13), cornerRadius: 1.4, style: .continuous))

        case .next, .previous:
            // Two triangles and a bar; mirrored for previous.
            var c = ctx
            if kind == .previous { c.translateBy(x: 24, y: 0); c.scaleBy(x: -1, y: 1) }
            let shift = 0.8 * a
            for x0 in [4.0, 11.0] {
                var tri = Path()
                tri.move(to: CGPoint(x: x0 + shift, y: 7)); tri.addLine(to: CGPoint(x: x0 + 7 + shift, y: 12)); tri.addLine(to: CGPoint(x: x0 + shift, y: 17)); tri.closeSubpath()
                c.fill(tri, with: .foreground)
                c.stroke(tri, with: .foreground, style: StrokeStyle(lineWidth: w * 0.6, lineJoin: .round))
            }
            c.fill(Path(roundedRect: CGRect(x: 18.4, y: 7, width: 2, height: 10), cornerRadius: 1), with: .foreground)

        case .screen2:
            // A monitor with a line of text being read.
            stroke(Path(roundedRect: CGRect(x: 2.5, y: 4, width: 19, height: 13), cornerRadius: 2.6, style: .continuous))
            stroke(seg(9, 20.5, 15, 20.5))
            stroke(seg(6.5, 9, 6.5 + 8 + 3 * a, 9))
            stroke(seg(6.5, 12.5, 13, 12.5))

        case .export:
            // A tray with an arrow leaving it; the arrow lifts on hover.
            var tray = Path()
            tray.move(to: CGPoint(x: 4, y: 13)); tray.addLine(to: CGPoint(x: 4, y: 19.5)); tray.addLine(to: CGPoint(x: 20, y: 19.5)); tray.addLine(to: CGPoint(x: 20, y: 13))
            stroke(tray)
            let lift = 1.4 * a
            stroke(seg(12, 15 - lift, 12, 4.5 - lift))
            var head = Path()
            head.move(to: CGPoint(x: 8.2, y: 8.2 - lift)); head.addLine(to: CGPoint(x: 12, y: 4.4 - lift)); head.addLine(to: CGPoint(x: 15.8, y: 8.2 - lift))
            stroke(head)

        case .copy:
            // Two sheets; the front one slides on hover.
            let o = 1.2 * a
            stroke(Path(roundedRect: CGRect(x: 8.5 + o, y: 3.5 - o, width: 12, height: 13.5), cornerRadius: 2.8, style: .continuous))
            let front = CGRect(x: 3.5, y: 7.5, width: 12, height: 13.5)
            knockout(Path(roundedRect: front.insetBy(dx: -w * 1.1, dy: -w * 1.1), cornerRadius: 3.8, style: .continuous))
            stroke(Path(roundedRect: front, cornerRadius: 2.8, style: .continuous))

        case .mouse:
            stroke(Path(roundedRect: CGRect(x: 6.5, y: 3, width: 11, height: 18), cornerRadius: 5.5, style: .continuous))
            stroke(seg(12, 6.5, 12, 9.5 + a))

        case .bluetooth:
            // The Bluetooth rune.
            var rune = Path()
            rune.move(to: CGPoint(x: 7, y: 7.5)); rune.addLine(to: CGPoint(x: 16.5, y: 16)); rune.addLine(to: CGPoint(x: 12, y: 20))
            rune.addLine(to: CGPoint(x: 12, y: 4)); rune.addLine(to: CGPoint(x: 16.5, y: 8)); rune.addLine(to: CGPoint(x: 7, y: 16.5))
            stroke(rune)

        case .posts:
            // A post bubble with two lines of text; it hops up on hover.
            var c = ctx
            c.translateBy(x: 0, y: -1.4 * a)
            var bubble = Path()
            bubble.move(to: CGPoint(x: 7, y: 17.5))
            bubble.addArc(tangent1End: CGPoint(x: 3, y: 17.5), tangent2End: CGPoint(x: 3, y: 4), radius: 3.4)
            bubble.addArc(tangent1End: CGPoint(x: 3, y: 4), tangent2End: CGPoint(x: 21, y: 4), radius: 3.4)
            bubble.addArc(tangent1End: CGPoint(x: 21, y: 4), tangent2End: CGPoint(x: 21, y: 17.5), radius: 3.4)
            bubble.addArc(tangent1End: CGPoint(x: 21, y: 17.5), tangent2End: CGPoint(x: 3, y: 17.5), radius: 3.4)
            bubble.addLine(to: CGPoint(x: 11.5, y: 17.5))
            bubble.addLine(to: CGPoint(x: 7.5, y: 21))
            bubble.closeSubpath()
            c.stroke(bubble, with: .foreground, style: line)
            c.stroke(seg(7.5, 9, 16.5, 9), with: .foreground, style: line)
            c.stroke(seg(7.5, 12.6, 13, 12.6), with: .foreground, style: line)

        case .search:
            let r = 6.4 * (1 + 0.06 * a)
            stroke(circle(10.6, 10.6, r))
            stroke(seg(15.4, 15.4, 20, 20))
        }
    }

    /// A page with the notch cut into its top edge.
    static let page: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 5, y: 12))
        p.addArc(tangent1End: CGPoint(x: 5, y: 3), tangent2End: CGPoint(x: 19, y: 3), radius: 3.6)
        p.addLine(to: CGPoint(x: 9.2, y: 3))
        p.addArc(tangent1End: CGPoint(x: 10.4, y: 3), tangent2End: CGPoint(x: 10.4, y: 5.6), radius: 1.1)
        p.addArc(tangent1End: CGPoint(x: 10.4, y: 5.6), tangent2End: CGPoint(x: 13.6, y: 5.6), radius: 1.2)
        p.addArc(tangent1End: CGPoint(x: 13.6, y: 5.6), tangent2End: CGPoint(x: 13.6, y: 3), radius: 1.2)
        p.addArc(tangent1End: CGPoint(x: 13.6, y: 3), tangent2End: CGPoint(x: 15, y: 3), radius: 1.1)
        p.addArc(tangent1End: CGPoint(x: 19, y: 3), tangent2End: CGPoint(x: 19, y: 21), radius: 3.6)
        p.addArc(tangent1End: CGPoint(x: 19, y: 21), tangent2End: CGPoint(x: 5, y: 21), radius: 3.6)
        p.addArc(tangent1End: CGPoint(x: 5, y: 21), tangent2End: CGPoint(x: 5, y: 3), radius: 3.6)
        p.closeSubpath()
        return p
    }()

    /// A four-point spark with concave sides.
    static func spark(center c: CGPoint, radius r: CGFloat, turn degrees: Double) -> Path {
        var p = Path()
        let pinch = r * 0.16
        for i in 0..<4 {
            let angle = (Double(i) * 90 - 90 + degrees) * .pi / 180
            let next = angle + .pi / 2
            let tip = CGPoint(x: c.x + r * CGFloat(cos(angle)), y: c.y + r * CGFloat(sin(angle)))
            let nextTip = CGPoint(x: c.x + r * CGFloat(cos(next)), y: c.y + r * CGFloat(sin(next)))
            let mid = angle + .pi / 4
            let control = CGPoint(x: c.x + pinch * CGFloat(cos(mid)), y: c.y + pinch * CGFloat(sin(mid)))
            if i == 0 { p.move(to: tip) }
            p.addQuadCurve(to: nextTip, control: control)
        }
        p.closeSubpath()
        return p
    }

    /// A 300° arc open at the lower left, with an arrowhead pointing back along it.
    static func rewindArc(radius r: CGFloat) -> Path {
        let start: Double = 150, sweep: Double = 290
        var p = Path()
        for i in 0...40 {
            let deg = start + sweep * Double(i) / 40
            let point = CGPoint(x: 12 + r * CGFloat(cos(deg * .pi / 180)), y: 12 + r * CGFloat(sin(deg * .pi / 180)))
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        // Arrowhead at the start, pointing the way the arc rewinds.
        let s = start * .pi / 180
        let tip = CGPoint(x: 12 + r * CGFloat(cos(s)), y: 12 + r * CGFloat(sin(s)))
        let back = CGPoint(x: CGFloat(sin(s)), y: -CGFloat(cos(s)))  // direction of travel at the start
        let len: CGFloat = 3.4
        for turn in [0.75, -0.75] as [Double] {
            let dx = back.x * CGFloat(cos(turn)) - back.y * CGFloat(sin(turn)), dy = back.x * CGFloat(sin(turn)) + back.y * CGFloat(cos(turn))
            p.move(to: tip)
            p.addLine(to: CGPoint(x: tip.x - len * dx, y: tip.y - len * dy))
        }
        return p
    }
}

/// The icon well used in the launcher and sidebar headers: a soft-lit squircle with a hairline.
struct GlyphWell: View {
    let kind: Glyph.Kind
    var size: CGFloat = 34
    var active = false

    var body: some View {
        Glyph(kind: kind, size: size * 0.53, active: active)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(active ? 0.2 : 0.14), .white.opacity(active ? 0.1 : 0.05)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                                  lineWidth: 0.75)
            )
    }
}

/// The "on air" dot beside the timer: a solid core with a halo that breathes outward.
struct LiveDot: View {
    var color: Color
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35)).frame(width: 6, height: 6)
                .phaseAnimator([false, true]) { halo, out in
                    halo.scaleEffect(out ? 2.1 : 1).opacity(out ? 0 : 1)
                } animation: { out in out ? .easeOut(duration: 1.1) : .linear(duration: 0) }
            Circle().fill(color).frame(width: 6, height: 6)
        }
        .frame(width: 12, height: 12)
    }
}
