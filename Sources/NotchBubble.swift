import AppKit
import SwiftUI

/// A small bubble that drops out from under the notch, like a permission card: what it is on the
/// left ("Microphone · hears you"), the one thing to do on the right ("Allow"), and a green check
/// there once it's done. The welcome tour is made of them, and when something needs a permission
/// it doesn't have yet, it asks with one (PermissionAsk).
struct NotchBubble: Equatable {
    enum Action: Hashable {
        /// One small white button.
        case button(String)
        /// Google and Apple (the ones Clerk has on), and Email, side by side.
        case providers([StarlightAccount.Provider])
        /// The keys to press. Clicking them presses them; for Ask, holding them holds the key.
        case keys(String, hold: Bool)
        /// Working on it (or waiting on you, in System Settings).
        case working
        /// How far along something is, 0…1 (a model installing); nil while it works out how much.
        case progress(Double?)

        /// Which action it is, for its transition: progress moving along is the same one.
        var identity: AnyHashable {
            if case .progress = self { return "progress" }
            return self
        }
        /// Done.
        case check
    }
    var label: String
    /// A few quiet words after the label: "hears you".
    var sub: String?
    var action: Action
    /// A quiet second way out (Not now, Skip), beside the action.
    var quiet: String?
    var busy = false
    /// Still shown while the notch is busy listening (the guide for what you're doing then).
    var duringVoice = false
}

/// What a bubble's taps go to: the tour, or the permission being asked for.
@MainActor
protocol BubbleOwner: AnyObject {
    func tap(quiet: Bool, provider: StarlightAccount.Provider?)
    func hold(_ down: Bool)
}

/// The bubble's window, just under the notch's, and the one bubble in it.
@MainActor
final class BubbleHost: ObservableObject {
    static let shared = BubbleHost()

    @Published private(set) var bubble: NotchBubble?
    /// Which bubble it is: a new key drops a new one; the same key changes the one that's there.
    @Published private(set) var key: String?
    private(set) weak var owner: BubbleOwner?

    weak var model: NotchModel?
    weak var notchWindow: NSWindow?
    private var panel: BubblePanel?

    static let drop = Animation.spring(response: 0.5, dampingFraction: 0.72)
    static let rise = Animation.spring(response: 0.38, dampingFraction: 0.9)
    /// The bubble changing in place: words swapping, Allow turning into a check.
    static let morph = Animation.spring(response: 0.42, dampingFraction: 0.8)

    func show(_ new: NotchBubble, key: String, owner: BubbleOwner) {
        guard new != bubble || key != self.key || owner !== self.owner else { return }
        makePanel()
        let fresh = bubble == nil || key != self.key
        self.owner = owner
        withAnimation(fresh ? Self.drop : Self.morph) {
            self.key = key
            bubble = new
        }
    }

    /// Rises back into the notch, if it's still `owner`'s.
    func hide(_ owner: BubbleOwner) {
        guard self.owner === owner, bubble != nil else { return }
        withAnimation(Self.rise) { bubble = nil }
        let panel = self.panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if self?.bubble == nil { panel?.orderOut(nil) }
        }
    }

    /// `owner`'s bubble, while it's up.
    func bubble(of owner: BubbleOwner) -> NotchBubble? { self.owner === owner ? bubble : nil }

    private func makePanel() {
        guard let model else { return }
        if panel == nil {
            let panel = BubblePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            let host = AcceptingFirstClickHostingView(rootView: NotchBubbleView(host: self, model: model, panel: panel))
            host.sizingOptions = []
            panel.contentView = host
            self.panel = panel
        }
        guard panel?.isVisible != true else { return }
        place()
        if let notch = notchWindow { panel?.order(.below, relativeTo: notch.windowNumber) } else { panel?.orderFrontRegardless() }
        CaptureVisibility.apply()
    }

    /// Under the notch on its screen, wide and tall enough for the notch's card and the bubble.
    func place() {
        guard let panel, let screen = notchWindow?.screen ?? NSScreen.main else { return }
        let width = 560 * TextScale.factor, height = 440 * TextScale.factor
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height), display: false)
    }
}

/// Only where the bubble is does the window take the pointer; everywhere else clicks go through
/// to whatever is behind.
final class BubblePanel: NSPanel {
    var hitRects: [CGRect] = [] { didSet { updatePointer() } }
    private var monitors: [Any] = []

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        if place == .out { stopWatching() } else { watchPointer() }
    }
    override func orderFrontRegardless() { super.orderFrontRegardless(); watchPointer() }
    override func orderOut(_ sender: Any?) { super.orderOut(sender); stopWatching() }

    private func watchPointer() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.updatePointer() }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in self?.updatePointer(); return event }) { monitors.append(local) }
    }

    private func stopWatching() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func updatePointer() {
        let p = NSEvent.mouseLocation
        // Frames are top-left based in the window; the screen is bottom-left based.
        let over = hitRects.contains { r in
            NSRect(x: frame.minX + r.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height).insetBy(dx: -2, dy: -2).contains(p)
        }
        if ignoresMouseEvents == over { ignoresMouseEvents = !over }
    }
}

// MARK: - Views

private struct BubbleFrameKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

/// The bubble, under the notch's current shape, dropping out from under it.
struct NotchBubbleView: View {
    @ObservedObject var host: BubbleHost
    @ObservedObject var model: NotchModel
    let panel: BubblePanel

    /// Out of the way while the notch is busy being itself (listening, answering), unless it's
    /// the guide for what you're doing right then.
    private var hidden: Bool {
        (model.voice.isActive || model.notes.isActive) && !(host.bubble?.duringVoice ?? false)
    }

    var body: some View {
        let s = TextScale.factor
        VStack {
            if let bubble = host.bubble, !hidden {
                BubbleView(bubble: bubble, owner: host.owner)
                    .background(GeometryReader { geo in Color.clear.preference(key: BubbleFrameKey.self, value: [geo.frame(in: .global)]) })
                    .transition(.asymmetric(
                        insertion: .offset(y: -22 * s).combined(with: .scale(scale: 0.92, anchor: .top)).combined(with: .opacity),
                        removal: .offset(y: -18 * s).combined(with: .scale(scale: 0.92, anchor: .top)).combined(with: .opacity)))
                    // A new one drops in; the same one changes in place.
                    .id(host.key)
            }
        }
        // Under whatever shape the notch has right now (its card, or itself listening), or where
        // it would be while it's tucked away.
        .padding(.top, (model.isTucked ? model.closedSize.height : model.size.height) + 8 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(model.scaled(Motion.open), value: model.size.height)
        .animation(BubbleHost.drop, value: hidden)
        .onPreferenceChange(BubbleFrameKey.self) { rects in panel.hitRects = rects }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}

/// A small black card, like a permission: what it is on the left, in the notch's own type, and
/// the one thing to do on the right, small and white. When it's done, that turns into a check.
struct BubbleView: View {
    let bubble: NotchBubble
    weak var owner: BubbleOwner?

    var body: some View {
        let s = TextScale.factor
        HStack(spacing: 14 * s) {
            HStack(spacing: 5 * s) {
                Text(bubble.label).font(.notch(size: 13, weight: .semibold))
                if let sub = bubble.sub {
                    Text("· \(sub)").font(.notch(size: 12)).foregroundStyle(.white.opacity(0.62))
                }
            }
            .lineLimit(1).fixedSize()
            .contentTransition(.opacity)
            .id(bubble.label)
            .transition(.opacity)
            Spacer(minLength: 0)
            HStack(spacing: 6 * s) {
                if let quiet = bubble.quiet {
                    BubblePill(title: quiet, prominent: false) { owner?.tap(quiet: true, provider: nil) }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                action
                    .id(bubble.action.identity)
                    .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity), removal: .opacity))
            }
        }
        .padding(.leading, 14 * s)
        .padding(.trailing, trailingInset * s)
        .frame(minWidth: 230 * s, minHeight: 40 * s)
        .background(
            RoundedRectangle(cornerRadius: 14 * s, style: .continuous).fill(Color.black)
                // A hairline, so it still reads over a dark window.
                .overlay(RoundedRectangle(cornerRadius: 14 * s, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 9, y: 6)
        )
        .fixedSize()
        .animation(BubbleHost.morph, value: bubble)
    }

    /// Pills sit 8 from the edge, like the mockup; a check or keys get a little more room.
    private var trailingInset: CGFloat {
        switch bubble.action {
        case .button, .providers: 8
        case .keys, .working, .progress, .check: 10
        }
    }

    @ViewBuilder private var action: some View {
        let s = TextScale.factor
        switch bubble.action {
        case .button(let title):
            BubblePill(title: title, prominent: true, busy: bubble.busy) { owner?.tap(quiet: false, provider: nil) }
        case .providers(let providers):
            HStack(spacing: 6 * s) {
                if providers.contains(.google) {
                    BubblePill(prominent: true, busy: bubble.busy, action: { owner?.tap(quiet: false, provider: .google) }) {
                        HStack(spacing: 5 * s) {
                            GoogleLogo().frame(width: 11 * s, height: 11 * s)
                            Text("Google")
                        }
                    }
                }
                if providers.contains(.apple) {
                    BubblePill(prominent: true, busy: bubble.busy, action: { owner?.tap(quiet: false, provider: .apple) }) {
                        HStack(spacing: 4 * s) {
                            Image(systemName: "applelogo").font(.system(size: 11 * s, weight: .medium)).offset(y: -0.5)
                            Text("Apple")
                        }
                    }
                }
                if providers.contains(.email) {
                    BubblePill(prominent: true, busy: bubble.busy, action: { owner?.tap(quiet: false, provider: .email) }) {
                        Text("Email")
                    }
                }
            }
        case .keys(let keys, let hold):
            KeysButton(keys: keys, hold: hold, owner: owner)
        case .working, .progress(nil):
            Spinner().frame(width: 16 * s, height: 16 * s).padding(2 * s)
        case .progress(let fraction?):
            ProgressRing(fraction: fraction).frame(width: 16 * s, height: 16 * s).padding(2 * s)
        case .check:
            OutcomeBadge(ok: true, size: 20 * s)
        }
    }
}

/// Working on it: a short white arc going round.
private struct Spinner: View {
    @State private var turning = false

    var body: some View {
        Circle().trim(from: 0, to: 0.28)
            .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .background(Circle().stroke(.white.opacity(0.18), lineWidth: 2))
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = !Render.isRendering }
    }
}

/// How far along: a white arc filling a faint ring, clockwise from the top.
private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        Circle().trim(from: 0, to: max(0.02, min(fraction, 1)))
            .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .background(Circle().stroke(.white.opacity(0.18), lineWidth: 2))
            .animation(.easeOut(duration: 0.35), value: fraction)
    }
}

/// A small pill: white with black words for the thing to do, a quiet grey one for the way out.
private struct BubblePill<Label: View>: View {
    var prominent = true
    var busy = false
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        let s = TextScale.factor
        Button(action: action) {
            label
                .font(.notch(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 11 * s).frame(height: 24 * s)
                .background(Capsule().fill(prominent ? Color.white.opacity(hovering ? 1 : 0.94) : Color.white.opacity(hovering ? 0.2 : 0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .disabled(busy)
        .opacity(busy ? 0.55 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

extension BubblePill where Label == Text {
    init(title: String, prominent: Bool, busy: Bool = false, action: @escaping () -> Void) {
        self.init(prominent: prominent, busy: busy, action: action) { Text(title) }
    }
}

/// The keys as keycaps. Clicking them presses them (dictation); for Ask, holding them is
/// holding the key: press, ask, let go.
private struct KeysButton: View {
    let keys: String
    let hold: Bool
    weak var owner: BubbleOwner?
    @State private var hovering = false

    var body: some View {
        // A button either way: its press tracking takes the first click on a window that's never
        // focused (a drag gesture there can miss it). For Ask, the press is the hold.
        Button { if !hold { owner?.tap(quiet: false, provider: nil) } } label: { face }
            .buttonStyle(KeyPressStyle(hovering: hovering) { down in if hold { owner?.hold(down) } })
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var face: some View {
        Keycaps(keys, size: 11.5 * TextScale.factor).contentShape(Rectangle())
    }
}

/// Pressed in, and says when the press starts and ends.
private struct KeyPressStyle: ButtonStyle {
    let hovering: Bool
    let pressed: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(hovering || configuration.isPressed ? 0.08 : 0)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, down in pressed(down) }
    }
}

/// Google's G, in its four colors, as Google asks it be shown on a sign-in button.
struct GoogleLogo: View {
    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width, geo.size.height)
            let line = w * 0.2
            let ring = w - line
            let blue = Color(red: 66 / 255, green: 133 / 255, blue: 244 / 255)
            ZStack {
                arc(0.0, 0.125, blue, ring, line)                                                     // right, under the bar
                arc(0.125, 0.375, Color(red: 52 / 255, green: 168 / 255, blue: 83 / 255), ring, line) // bottom
                arc(0.375, 0.625, Color(red: 251 / 255, green: 188 / 255, blue: 5 / 255), ring, line) // left
                arc(0.625, 0.875, Color(red: 234 / 255, green: 67 / 255, blue: 53 / 255), ring, line) // top
                // The bar, from the middle out to the right.
                Rectangle().fill(blue).frame(width: w / 2, height: line).offset(x: w / 4 - line / 4)
            }
            .frame(width: w, height: w)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func arc(_ from: CGFloat, _ to: CGFloat, _ color: Color, _ ring: CGFloat, _ line: CGFloat) -> some View {
        Circle().trim(from: from, to: to).stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .butt)).frame(width: ring, height: ring)
    }
}
