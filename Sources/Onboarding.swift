import AppKit
import CoreText
import SwiftUI

// The first-run welcome: a calm, spacious window that gets Starlight going (two permissions and a
// first dictation, no account), while the real notch up top shows
// what each step is about. The voice models start downloading at launch, behind all of it.

// MARK: - Window

@MainActor
final class Onboarding: NSObject, NSWindowDelegate {
    static let shared = Onboarding()
    static let doneKey = "onboarded"
    weak var model: NotchModel?
    private var window: NSWindow?
    private let state = OnboardingState()

    static var hasFinished: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    /// The tour runs in the notch (NotchTour). This window is the same tour for VoiceOver, which
    /// can't follow bubbles at the top of the screen.
    func show() {
        if NSWorkspace.shared.isVoiceOverEnabled { showWindow() } else { NotchTour.shared.start() }
    }

    /// On first launch (or STARLIGHT_ONBOARD for a test).
    func showIfNeeded() {
        if !Self.hasFinished || Dev.env("STARLIGHT_ONBOARD") != nil { show() }
    }

    func showWindow() {
        state.step = .hello
        state.dictationAtStart = DictationHistory.shared.entries.first?.id
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.contentView = NSHostingView(rootView: OnboardingView(state: state, model: model ?? NotchModel(), finish: { [weak self] in self?.finish() }))
            window.center()
            window.delegate = self
            DockIcon.mark(window)
            self.window = window
        }
        CaptureVisibility.apply()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        DockIcon.shared.update()
        teach(.hello)
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window?.orderOut(nil)
        DockIcon.shared.update()
        teach(.done)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in self?.teach(nil) }
    }

    /// Closed partway (red button, ⌘W): the notch stops teaching, so it doesn't stay on a tour
    /// card. The tour comes back next launch until it's finished.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { teach(nil) }
    }

    /// You hovered the notch during the tour: once it's closed again, a check and "Nice.", then
    /// it rests.
    func hoverLearned() {
        guard let model, model.tutorial?.invite == true, model.tutorial?.learned == false else { return }
        model.tutorial = .init(title: "Nice.", detail: "", invite: true, learned: true)
        Haptics.snap()
        Task { @MainActor [weak self] in
            // Wait for the pointer to leave and the notch to close (two minutes at most).
            for _ in 0..<600 {
                guard let model = self?.model, model.tutorial?.learned == true else { return }
                if !model.isOpen && !model.hovering { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let model = self?.model, model.tutorial?.learned == true else { return }
            withAnimation(model.scaled(Motion.close)) { model.tutorial = nil }
        }
    }

    /// The notch shows what this step is about.
    func teach(_ step: OnboardingState.Step?) {
        guard let model else { return }
        let card: NotchModel.Tutorial? = switch step {
        case .done: .init(title: "You're all set", detail: "Hover me any time.")
        default: nil
        }
        withAnimation(model.scaled(card == nil ? Motion.close : Motion.open)) { model.tutorial = card }
    }
}

@MainActor
final class OnboardingState: ObservableObject {
    enum Step: Int, CaseIterable { case hello, account, permissions, tryIt, pro, done }
    /// The tour as shown: no account and no Pro on the way to a first dictation (Starlight is
    /// free; Pro is offered when you first use something that needs it).
    static var steps: [Step] { Step.allCases.filter { $0 != .account && $0 != .pro } }
    @Published var step: Step = .hello
    @Published var forward = true
    /// The newest dictation when the tour began: a newer one is the test.
    var dictationAtStart: UUID?

    func go(_ next: Step) {
        forward = next.rawValue > step.rawValue
        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { step = next }
        Onboarding.shared.teach(next)
    }

    func next() { move(1) }
    func back() { move(-1) }

    private func move(_ by: Int) {
        let steps = Self.steps
        guard let i = steps.firstIndex(of: step), steps.indices.contains(i + by) else { return }
        go(steps[i + by])
    }
}

// MARK: - The tour

struct OnboardingView: View {
    @ObservedObject var state: OnboardingState
    var model: NotchModel
    let finish: () -> Void
    @ObservedObject private var account = StarlightAccount.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                switch state.step {
                case .hello: HelloStep(next: state.next)
                case .account: AccountStep()
                case .permissions: PermissionsStep()
                case .tryIt: TryItStep(model: model, since: state.dictationAtStart)
                case .pro: ProStep()
                case .done: DoneStep(finish: finish)
                }
            }
            .id(state.step)
            .transition(.asymmetric(
                insertion: .offset(x: state.forward ? 60 : -60).combined(with: .opacity),
                removal: .offset(x: state.forward ? -60 : 60).combined(with: .opacity)))

            if state.step != .hello && state.step != .done {
                VStack {
                    Spacer()
                    footer
                }
                .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .frame(minWidth: 760, minHeight: 580)
        .onChange(of: account.allows(.account)) { _, signedIn in
            // Signed in on the account step: on to the next one, the way setup moves along.
            guard signedIn, state.step == .account, !Render.isRendering else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { if state.step == .account { state.next() } }
        }
    }

    /// One way forward on every screen, the bright button; Not Now under it when there's
    /// something to skip; Back, quietly, in the corner.
    private var footer: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(spacing: 14) {
                BigButton(title: primary.title, minWidth: 240, action: primary.action)
                    .keyboardShortcut(.defaultAction)
                    .disabled(primary.busy)
                    .opacity(primary.busy ? 0.5 : 1)
                Button(secondary?.title ?? " ") { secondary?.action() }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .opacity(secondary == nil ? 0 : 0.55)
                    .disabled(secondary == nil)
            }
            .frame(maxWidth: .infinity)
            Button("Back", action: state.back)
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .opacity(0.4)
        }
        .padding(.horizontal, 48)
        .padding(.bottom, 36)
    }

    private var primary: (title: String, busy: Bool, action: () -> Void) {
        switch state.step {
        case .account where !account.allows(.account):
            (account.signingIn ? "Signing In…" : "Sign In", account.signingIn, { Task { await account.signIn() } })
        case .pro where !account.allows(.pro):
            ("Start Free Trial", false, { account.openSubscription() })
        default:
            ("Continue", false, state.next)
        }
    }

    private var secondary: (title: String, action: () -> Void)? {
        guard state.step == .pro, !account.allows(.pro) else { return nil }
        let notNow: () -> Void = state.next
        return ("Not Now", notNow)
    }
}

/// The big white button the tour moves on with.
struct BigButton: View {
    let title: String
    var prominent = true
    var minWidth: CGFloat = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(prominent ? .black : .white)
                .padding(.horizontal, 26).frame(minWidth: minWidth).frame(height: 44)
                .background(Capsule().fill(prominent ? Color.white.opacity(hovering ? 1 : 0.92) : Color.white.opacity(hovering ? 0.16 : 0.09)))
                .scaleEffect(hovering ? 1.03 : 1)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
    }
}

/// A step's page, the way a Mac sets itself up: an icon, a short title and one line under it,
/// then the content, all centered.
private struct StepPage<Content: View>: View {
    var glyph: Glyph.Kind? = nil
    let title: String
    var subtitle = ""
    /// Key caps shown where "{keys}" sits in the subtitle.
    var keys: String? = nil
    @ViewBuilder let content: Content
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            if let glyph {
                ZStack {
                    Circle().fill(.white.opacity(0.08))
                    Glyph(kind: glyph, size: 26)
                }
                .frame(width: 64, height: 64)
                .padding(.bottom, 22)
                .opacity(shown ? 1 : 0).scaleEffect(shown ? 1 : 0.85)
            }
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .multilineTextAlignment(.center)
                .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 12)
            if !subtitle.isEmpty {
                subtitleLine
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 10)
            }
            content
                .frame(maxWidth: 560)
                .padding(.top, 36)
                .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 14)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 64)
        .padding(.top, 64)
        .padding(.bottom, 130)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            guard !Render.isRendering else { shown = true; return }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.08)) { shown = true }
        }
    }
}

private extension StepPage {
    @ViewBuilder var subtitleLine: some View {
        if let keys, let range = subtitle.range(of: "{keys}") {
            HStack(spacing: 8) {
                Text(subtitle[..<range.lowerBound].trimmingCharacters(in: .whitespaces)).opacity(0.5)
                KeyCaps(keys: keys)
                Text(subtitle[range.upperBound...].trimmingCharacters(in: .whitespaces)).opacity(0.5)
            }
        } else {
            Text(subtitle).opacity(0.5)
        }
    }
}

/// Keys drawn as keyboard keys: "Control" "Space". They light up while you hold them.
struct KeyCaps: View {
    let keys: String
    @State private var held: NSEvent.ModifierFlags = []
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 5) {
            ForEach(keys.components(separatedBy: " + "), id: \.self) { key in
                let down = isHeld(key)
                Text(key)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(down ? .black : .white)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(down ? 0.95 : 0.1)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    .scaleEffect(down ? 0.95 : 1)
            }
        }
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: held.rawValue)
        .onAppear {
            guard !Render.isRendering else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                held = event.modifierFlags.intersection([.control, .option, .shift, .command])
                return event
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }

    private func isHeld(_ key: String) -> Bool {
        switch key {
        case "Control": held.contains(.control)
        case "Option": held.contains(.option)
        case "Shift": held.contains(.shift)
        case "Command": held.contains(.command)
        default: false
        }
    }
}

/// A shortcut drawn the way it looks on a Mac keyboard: dark keycaps with a little depth, the
/// modifier's symbol top right and its name bottom left (⌃ "control"), a wide space bar.
///
/// - Every few seconds it acts the press out (each key in turn, then up) until you use it.
/// - Holding a modifier presses that key; Space on its own presses the space bar.
/// - `active` (dictating): every key stays down with a glow, after a ripple goes out from them.
/// - Clicking the keys does what pressing them would (`onPress`), with the same press.
struct MacKeyCombo: View {
    let keys: String
    var active = false
    var onPress: (() -> Void)? = nil
    @State private var held: NSEvent.ModifierFlags = []
    @State private var spaceDown = false
    @State private var clicking = false
    @State private var monitor: Any?
    /// How many keys of the combo the demo has pressed (0 = none).
    @State private var demo = 0
    @State private var demoTask: Task<Void, Never>?
    /// You've pressed something: the demo stops acting it out.
    @State private var used = false
    @State private var ripple = false

    private var parts: [String] { keys.components(separatedBy: " + ") }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, key in
                MacKey(name: key, down: active || clicking || isHeld(key) || index < demo, glowing: active)
            }
        }
        .background {
            // The ripple when dictation starts: a rounded ring growing out from the keys.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white, lineWidth: 2)
                .padding(-6)
                .scaleEffect(ripple ? 1.18 : 0.96)
                .opacity(ripple ? 0 : (active ? 0.7 : 0))
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !clicking { clicking = true; used = true; demo = 0 } }
            .onEnded { _ in clicking = false; onPress?() })
        .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        .onChange(of: active) { _, on in
            guard on else { ripple = false; return }
            used = true
            demo = 0
            ripple = false
            Haptics.start()
            withAnimation(.easeOut(duration: 0.7)) { ripple = true }
        }
        .onAppear {
            // Already dictating when it appears: no ripple to play, so none left showing.
            if active { ripple = true }
            guard !Render.isRendering else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { event in
                if event.type == .flagsChanged {
                    held = event.modifierFlags.intersection([.control, .option, .shift, .command])
                    if !held.isEmpty { used = true; demo = 0 }
                    return event
                }
                // Space on its own: the space bar goes down (and doesn't press a button on the page).
                guard event.keyCode == 49, parts.contains("Space") else { return event }
                spaceDown = event.type == .keyDown
                if spaceDown { used = true; demo = 0 }
                return nil
            }
            demoTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                while !Task.isCancelled && !used {
                    for step in 1...parts.count where !used {
                        withAnimation(.spring(response: 0.18, dampingFraction: 0.7)) { demo = step }
                        try? await Task.sleep(nanoseconds: 260_000_000)
                    }
                    try? await Task.sleep(nanoseconds: 380_000_000)
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { demo = 0 }
                    try? await Task.sleep(nanoseconds: 2_800_000_000)
                }
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            demoTask?.cancel()
        }
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: held.rawValue)
        .animation(.spring(response: 0.16, dampingFraction: 0.7), value: spaceDown)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(keys)
    }

    private func isHeld(_ key: String) -> Bool {
        switch key {
        case "Control": held.contains(.control)
        case "Option": held.contains(.option)
        case "Shift": held.contains(.shift)
        case "Command": held.contains(.command)
        case "Space": spaceDown
        default: false
        }
    }
}

/// One keycap. Modifiers as on a Mac keyboard: symbol top right, the word bottom left, in lowercase.
struct MacKey: View {
    let name: String
    var down: Bool
    /// Dictating: the key lights up a little.
    var glowing = false

    private static let symbols = ["Control": "⌃", "Option": "⌥", "Shift": "⇧", "Command": "⌘", "Fn": "fn"]
    private var isModifier: Bool { Self.symbols[name] != nil }
    private var width: CGFloat {
        switch name {
        case "Space": 236
        case "Command": 82
        case "Control", "Option", "Shift": 76
        case "Return", "Tab", "Esc", "Delete": 76
        default: name.count > 2 ? 76 : 58
        }
    }

    var body: some View {
        let height: CGFloat = 58
        let depth: CGFloat = down ? 1 : 4
        ZStack {
            // The key's side, showing below its face: lower when pressed.
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(white: 0.04))
                .frame(width: width, height: height)
                .offset(y: 4)
            // The face.
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: down ? 0.16 : 0.2), Color(white: down ? 0.12 : 0.14)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(glowing ? 0.55 : down ? 0.08 : 0.14), lineWidth: glowing ? 1.5 : 1))
                .overlay(alignment: .topTrailing) {
                    if isModifier {
                        Text(Self.symbols[name] ?? "").font(.system(size: 15, weight: .regular)).opacity(0.85)
                            .padding(.top, 7).padding(.trailing, 10)
                    }
                }
                .overlay(alignment: isModifier ? .bottomLeading : .center) {
                    if isModifier {
                        Text(name.lowercased()).font(.system(size: 11.5, weight: .medium)).opacity(0.75)
                            .padding(.bottom, 8).padding(.leading, 10)
                    } else if name == "Space" {
                        // Blank on a real Mac; named here so nobody wonders which key it is.
                        Text("space").font(.system(size: 13, weight: .medium)).opacity(0.85)
                    } else {
                        Text(name).font(.system(size: name.count > 2 ? 12.5 : 19, weight: .medium)).opacity(0.85)
                    }
                }
                .frame(width: width, height: height)
                .offset(y: 4 - depth)
                .shadow(color: .white.opacity(glowing ? 0.22 : down ? 0.08 : 0), radius: glowing ? 14 : 10)
        }
        .frame(width: width, height: height + 4)
        .foregroundStyle(.white)
        .animation(.spring(response: 0.16, dampingFraction: 0.7), value: down)
        .animation(.easeOut(duration: 0.3), value: glowing)
    }
}

// MARK: Hello

private struct HelloStep: View {
    let next: () -> Void
    @State private var welcome = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HelloWriting()
                .frame(width: 420, height: 170)
            Text("Your notch, made useful.")
                .font(.system(size: 19, weight: .medium))
                .opacity(welcome ? 0.55 : 0)
                .padding(.top, 18)
            BigButton(title: "Get Started", minWidth: 240, action: next)
                .keyboardShortcut(.defaultAction)
                .opacity(welcome ? 1 : 0).scaleEffect(welcome ? 1 : 0.92)
                .padding(.top, 44)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !Render.isRendering else { welcome = true; return }
            withAnimation(.easeOut(duration: 0.6).delay(2.6)) { welcome = true }
        }
    }
}

/// "Starlight", written out: the pen traces each letter of a script face (Snell Roundhand), then
/// the word fills in and glows, the way a Mac says hello when it's new.
struct HelloWriting: View {
    @State private var drawn: CGFloat = 0
    @State private var filled = false
    @State private var glow = false

    var body: some View {
        GeometryReader { geo in
            let shape = WrittenWord(text: "Starlight")
            let width = max(1.2, geo.size.height * 0.008)
            ZStack {
                shape.fill(.white.opacity(0.35))
                    .blur(radius: glow ? 14 : 0)
                    .opacity(glow ? 1 : 0)
                shape.fill(.white).opacity(filled ? 1 : 0)
                shape.trim(from: 0, to: drawn)
                    .stroke(.white, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                    .opacity(filled ? 0 : 1)
            }
        }
        .onAppear {
            guard !Render.isRendering else { drawn = 1; filled = true; return }
            // Slow in, steady through the letters, then the ink settles.
            withAnimation(.timingCurve(0.45, 0.05, 0.35, 1, duration: 2.6).delay(0.3)) { drawn = 1 }
            withAnimation(.easeOut(duration: 0.7).delay(2.5)) { filled = true }
            withAnimation(.easeInOut(duration: 1.6).delay(2.9)) { glow = true }
        }
    }
}

/// A word as outlines in a script face, letter after letter so a trim writes it in order,
/// fitted to the frame without stretching.
struct WrittenWord: Shape {
    let text: String
    var font = "SnellRoundhand-Bold"

    func path(in rect: CGRect) -> Path {
        let face = CTFontCreateWithName(font as CFString, 100, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): face]))
        let outline = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
            for (glyph, at) in zip(glyphs, positions) {
                if let letter = CTFontCreatePathForGlyph(runFont, glyph, nil) {
                    outline.addPath(letter, transform: CGAffineTransform(translationX: at.x, y: at.y))
                }
            }
        }
        // Core Text draws upward; SwiftUI downward.
        let p = Path(outline).applying(CGAffineTransform(scaleX: 1, y: -1))
        let box = p.boundingRect
        guard box.width > 0, box.height > 0 else { return p }
        let scale = min(rect.width / box.width, rect.height / box.height) * 0.92
        return p.applying(CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -box.midX, y: -box.midY))
    }
}

// MARK: Your notch

/// "Control + Space", as keys.
struct KeysChip: View {
    let keys: String
    var body: some View {
        HStack(spacing: 5) {
            ForEach(keys.components(separatedBy: " + "), id: \.self) { key in
                Text(key)
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 9).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.1)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            }
        }
    }
}

// MARK: Permissions

private struct PermissionsStep: View {
    @State private var refresh = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    /// What dictation needs. The others (system audio, screen, reminders…) wait for their feature.
    private static let first = Permission.all.filter { ["mic", "accessibility"].contains($0.id) }
    private static let why = ["mic": "To hear you when you dictate", "accessibility": "To type into the app you're using"]

    var body: some View {
        let _ = refresh
        StepPage(glyph: .shield, title: "Two permissions") {
            VStack(spacing: 10) {
                ForEach(Self.first) { permission in
                    PermissionRow(permission: permission, detail: Self.why[permission.id] ?? permission.purpose) { refresh += 1 }
                }
            }
        }
        .onReceive(timer) { _ in refresh += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh += 1 }
    }
}

/// One permission: what it's for, and Allow (macOS asks right here) or a check once it's on.
private struct PermissionRow: View {
    let permission: Permission
    let detail: String
    let changed: () -> Void

    var body: some View {
        let state = permission.state()
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(.white.opacity(0.08))
                Glyph(kind: permission.glyph, size: 18)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.name).font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 13.5)).opacity(0.5)
            }
            Spacer(minLength: 12)
            switch state {
            case .allowed:
                OutcomeBadge(ok: true, size: 26).transition(.scale(scale: 0.4).combined(with: .opacity))
            case .asksWhenUsed:
                Text("When used").font(.system(size: 13, weight: .medium)).opacity(0.4)
            case .notAsked, .notAllowed:
                let opensSettings = state == .notAllowed || permission.request == nil
                Button {
                    // Asking first also adds Starlight to the list in System Settings (Accessibility
                    // only appears there once asked), then Settings opens if needed.
                    permission.request?()
                    if opensSettings { permission.openSettings() }
                    for delay in [0.6, 1.5, 3.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { changed() } }
                } label: {
                    Text(opensSettings ? "Open Settings" : "Allow")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16).frame(height: 32)
                        .background(Capsule().fill(.white.opacity(0.92)))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.05)))
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: state == .allowed)
    }
}

// MARK: Account

/// Your free account: the hosted Clerk sign-in (email, Google or Apple). Required, since
/// dictation needs it; Continue waits for it.
private struct AccountStep: View {
    @ObservedObject private var account = StarlightAccount.shared

    var body: some View {
        StepPage(glyph: .key, title: "Sign in to Starlight") {
            Group {
                if account.allows(.account) {
                    HStack(spacing: 10) {
                        OutcomeBadge(ok: true, size: 22)
                        Text(account.email.map { "Signed in as \($0)" } ?? "You're signed in")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                } else if let problem = account.problem {
                    Text(problem).font(.system(size: 14, weight: .medium)).opacity(0.8)
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: account.allows(.account))
        }
    }
}

// MARK: Downloads

/// The voice model's download, 0…1, or nil while it's working out how much there is.
private func voiceProgress(_ model: NotchModel) -> Double? {
    switch model.engineStatus {
    case .ready, .idle: 1
    case .loading(_, let fraction): fraction.map { min($0, 0.99) }
    case .failed: 0
    }
}

private struct DownloadRow: View {
    let glyph: Glyph.Kind
    let title: String
    let detail: String
    let progress: Double?
    let failed: Bool
    let retry: () -> Void

    var body: some View {
        let done = progress == 1
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                ZStack {
                    Circle().fill(done ? Color.white : Color.white.opacity(0.08))
                    Glyph(kind: glyph, size: 22, active: !done && !failed).foregroundStyle(done ? .black : .white)
                }
                .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 21, weight: .semibold))
                    Text(detail).font(.system(size: 14.5)).opacity(0.5)
                }
                Spacer(minLength: 16)
                Group {
                    if failed {
                        BigButton(title: "Try again", prominent: false, action: retry).scaleEffect(0.85, anchor: .trailing)
                    } else if done {
                        OutcomeBadge(ok: true, size: 28).transition(.scale(scale: 0.4).combined(with: .opacity))
                    } else if let progress {
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 26, weight: .bold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    } else {
                        ShimmerText(text: "Starting").font(.system(size: 15, weight: .semibold))
                    }
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(.white.opacity(done ? 0.9 : 0.75))
                        .frame(width: max(6, geo.size.width * (progress ?? 0)))
                        .opacity(failed ? 0 : 1)
                }
            }
            .frame(height: 6)
            .padding(.leading, 74)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: progress)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: done)
    }
}

// MARK: Try it

private struct TryItStep: View {
    @ObservedObject var model: NotchModel
    let since: UUID?
    @ObservedObject private var history = DictationHistory.shared
    @ObservedObject private var settings = AppSettings.shared

    private var tried: DictationHistory.Entry? {
        guard let first = history.entries.first, first.id != since else { return nil }
        return first
    }

    /// What's on the page: the words as you say them, held when you stop, then the finished
    /// dictation once it's saved.
    @State private var heard = ""
    private var words: String { heard }
    /// The voice model, still coming in: its progress shows in place of the keys.
    private var downloading: Bool { voiceProgress(model) != 1 }

    private var listening: Bool { model.voice == .recording }
    /// Done the moment you stop talking: the check shows at once, and the final text swaps in
    /// when it's ready (a fraction of a second later), with no "writing" in between.
    private var finished: Bool { !listening && !heard.isEmpty }

    var body: some View { dictation }

    private var dictation: some View {
        StepPage(glyph: .voice, title: "Try it") {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(words.isEmpty && !model.voice.isActive ? 0.16 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                    .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white.opacity(words.isEmpty && !model.voice.isActive ? 0 : 0.06)))
                if words.isEmpty && downloading && !listening {
                    DownloadRow(glyph: .voice, title: "Getting ready", detail: "The voice model downloads once, then it all runs on your Mac",
                                progress: voiceProgress(model), failed: { if case .failed = model.engineStatus { return true }; return false }(),
                                retry: { ParakeetModel.shared.prepare() })
                        .padding(28)
                        .frame(maxHeight: .infinity)
                        .transition(.opacity)
                } else if words.isEmpty {
                    VStack(spacing: listening ? 10 : 16) {
                        // The keys stay through the press: down and glowing once you're talking.
                        MacKeyCombo(keys: settings.dictationShortcut.display, active: listening) {
                            (NSApp.delegate as? AppDelegate)?.voice.toggle()
                        }
                        .scaleEffect(listening ? 0.72 : 1)
                        if listening {
                            ListeningBars(levels: model.levels).transition(.opacity.combined(with: .scale(scale: 0.9)))
                            Text("Listening. Press again to finish.").font(.system(size: 14, weight: .medium)).opacity(0.55)
                                .transition(.opacity)
                        } else {
                            Text("Press to start talking, or click the keys. Press again to finish.")
                                .font(.system(size: 15, weight: .medium)).opacity(0.45)
                                .transition(.opacity)
                        }
                    }
                    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: listening)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 10) {
                            if finished {
                                OutcomeBadge(ok: true, size: 22).transition(.scale.combined(with: .opacity))
                                Text("Sweet, you're set.").font(.system(size: 15, weight: .semibold)).opacity(0.8)
                            } else {
                                LiveDot(color: .white)
                                ShimmerText(text: "Listening")
                                    .font(.system(size: 15, weight: .semibold)).opacity(0.8)
                            }
                        }
                        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: finished)
                        AppearingWords(text: words, size: words.count > 120 ? 19 : 26)
                    }
                    .padding(28)
                    .transition(.opacity)
                }
            }
            .frame(height: 230)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: words.isEmpty)
            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: downloading)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: finished)
            .onChange(of: model.partial) { _, text in if listening, !text.isEmpty { heard = text } }
            .onChange(of: model.voice) { _, phase in if phase == .recording { heard = "" } }
            .onChange(of: tried?.id) { _, _ in if let tried { heard = tried.text } }
            .onAppear { if Render.isRendering, !model.partial.isEmpty { heard = model.partial } }
        }
    }
}

/// Words that rise in one by one as they're heard, wrapping like a paragraph.
private struct AppearingWords: View {
    let text: String
    let size: CGFloat

    var body: some View {
        let words = text.split(separator: " ").map(String.init)
        WordFlow(spacing: size * 0.27, lineSpacing: size * 0.22) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                Text(word)
                    .font(.system(size: size, weight: .semibold))
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.96, anchor: .bottomLeading)),
                                            removal: .opacity))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: words)
        .frame(maxHeight: 130, alignment: .topLeading)
        .clipped()
    }
}

/// Lays words left to right, wrapping to the next line when the row is full.
private struct WordFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            for (index, x) in row.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var items: [(Int, CGFloat)] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                let y = row.y + row.height + lineSpacing
                rows.append(Row(y: y))
                row = rows[rows.count - 1]
            }
            let x = row.items.isEmpty ? 0 : row.width + spacing
            row.items.append((index, x))
            row.width = x + size.width
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// A few bars that move with your voice while nothing's been heard yet.
private struct ListeningBars: View {
    let levels: [Int]
    var body: some View {
        HStack(spacing: 4) {
            let recent = Array(levels.suffix(9))
            ForEach(0..<recent.count, id: \.self) { i in
                Capsule().fill(.white).frame(width: 4, height: min(40, 6 + CGFloat(recent[i]) * 1.4))
            }
        }
        .frame(height: 40)
        .animation(.easeOut(duration: 0.1), value: levels)
    }
}

// MARK: Done

// MARK: Pro

/// What Pro adds, once dictation already works, as a plain offer: three lines and the price.
/// Start Free Trial (below) opens the checkout window, signed in; Not Now finishes on Free.
private struct ProStep: View {
    @ObservedObject private var account = StarlightAccount.shared

    var body: some View {
        let pro = account.allows(.pro)
        StepPage(glyph: .spark, title: pro ? "You're on Pro" : "Starlight Pro",
                 subtitle: pro ? "Ask, Live and Notes are on." : "The AI, right in your notch. Free for 3 days, then $15 a month.") {
            VStack(alignment: .leading, spacing: 18) {
                ProPerk(glyph: .spark, title: "Ask", detail: "Ask anything out loud, from any app.")
                ProPerk(glyph: .agent, title: "Live", detail: "A conversation that answers and gets things done.")
                ProPerk(glyph: .noteLive, title: "Notes", detail: "Your meetings, with answers as you talk.")
            }
            .frame(width: 400, alignment: .leading)
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: pro)
        }
    }
}

private struct ProPerk: View {
    let glyph: Glyph.Kind
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(.white.opacity(0.08))
                Glyph(kind: glyph, size: 18)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 13.5)).opacity(0.5)
            }
        }
    }
}

// MARK: Done

private struct DoneStep: View {
    let finish: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            OutcomeBadge(ok: true, size: 54)
                .scaleEffect(shown ? 1 : 0.5).opacity(shown ? 1 : 0)
            Text("You're all set")
                .font(.system(size: 44, weight: .bold))
                .padding(.top, 28)
            Tip(text: "Press \(settings.dictationShortcut.display) in any app to dictate.")
                .padding(.top, 4)
            .padding(.top, 26)
            .opacity(shown ? 1 : 0)
            BigButton(title: "Start using Starlight", minWidth: 240, action: finish)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 44)
            Spacer()
        }
        .padding(.horizontal, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !Render.isRendering else { shown = true; return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.6).delay(0.1)) { shown = true }
        }
    }
}

private struct Tip: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 16)).opacity(0.6).multilineTextAlignment(.center)
    }
}
