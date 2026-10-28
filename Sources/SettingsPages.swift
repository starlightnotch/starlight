import AppKit
import Carbon.HIToolbox
import SwiftUI

// Settings, organised by what you do. Each feature is one page (Dictation and Meetings have a
// History or Notes tab and a Settings tab); the rest are General, Answers, Shortcuts, Privacy,
// Account and About. On a page, the choices that change what you see are pictures (the notch at
// your text size, the same sentence in each dictation style, the keys to press), the rest are
// plain rows, and anything rarely changed waits under "More settings". Search in the sidebar
// finds any setting by name and takes you to it.

// MARK: - Choosing by seeing

/// One choice among tiles: a picture of what it does, and its name.
struct ChoiceTile<Value: Hashable> {
    let title: String
    let value: Value
    let picture: AnyView

    init(_ title: String, _ value: Value, @ViewBuilder picture: () -> some View) {
        self.title = title
        self.value = value
        self.picture = AnyView(picture())
    }
}

/// A choice shown as pictures, side by side; the chosen one has a white ring.
struct ChoiceTiles<Value: Hashable>: View {
    @Binding var selection: Value
    let tiles: [ChoiceTile<Value>]
    var height: CGFloat = 84

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(tiles.indices, id: \.self) { index in
                Tile(tile: tiles[index], chosen: tiles[index].value == selection, height: height) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = tiles[index].value }
                }
            }
        }
    }

    private struct Tile: View {
        let tile: ChoiceTile<Value>
        let chosen: Bool
        let height: CGFloat
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                VStack(spacing: 8) {
                    tile.picture
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .background(Color.white.opacity(0.045))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(chosen ? Color.white : Color.white.opacity(hovering ? 0.22 : 0.08), lineWidth: chosen ? 2 : 1)
                        )
                    Text(tile.title)
                        .font(.system(size: 12.5, weight: chosen ? .semibold : .regular))
                        .opacity(chosen ? 1 : hovering ? 0.85 : 0.6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .accessibilityAddTraits(chosen ? .isSelected : [])
        }
    }
}

/// A titled group that holds a picture or tiles rather than rows.
struct Block<Content: View>: View {
    let title: String
    /// What the choice means, shown when the pointer rests on the title (HoverInfo).
    var info: [String] = []
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(text: title).modifier(HoverInfo(title: title, lines: info))
            content.glassCard(padding: 14)
                .modifier(Highlighted(group: title))
        }
        .id(title)
    }
}

/// Lights a group for a moment when a search result points at it.
struct Highlighted: ViewModifier {
    let group: String
    @Environment(\.settingsHighlight) private var highlight

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(highlight == group ? 0.7 : 0), lineWidth: 1.5)
                .animation(.easeOut(duration: 0.3), value: highlight)
                .allowsHitTesting(false)
        )
    }
}

private struct SettingsHighlightKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

/// The settings on a page you rarely change, folded away under its main ones.
struct More<Content: View>: View {
    let page: CompanionState.Page
    @EnvironmentObject private var state: CompanionState
    @ViewBuilder let content: Content

    var body: some View {
        let open = state.unfolded.contains(page)
        VStack(alignment: .leading, spacing: 20) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                    if open { state.unfolded.remove(page) } else { state.unfolded.insert(page) }
                }
            } label: {
                HStack(spacing: 7) {
                    Chevron().frame(width: 7, height: 7).rotationEffect(.degrees(open ? 90 : 0))
                    Text(open ? "Fewer settings" : "More settings").font(.system(size: 13, weight: .semibold))
                }
                .opacity(0.6)
                .padding(.leading, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 20) { content }
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
    }
}

/// A small right-pointing chevron, drawn (the glyph set has no arrows this small).
struct Chevron: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.15, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY))
        return p.strokedPath(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
    }
}

/// A shortcut as the keys themselves: "Control + Option + Space" as three keycaps.
struct Keycaps: View {
    let keys: [String]
    var size: CGFloat = 12

    init(_ display: String, size: CGFloat = 12) {
        keys = display.components(separatedBy: " + ")
        self.size = size
    }

    var body: some View {
        HStack(spacing: size * 0.33) {
            ForEach(keys.indices, id: \.self) { index in
                Text(keys[index])
                    .font(.system(size: size, weight: .semibold))
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, size * 0.62)
                    .frame(minWidth: size * 2.25, minHeight: size * 2.1)
                    .background(RoundedRectangle(cornerRadius: size * 0.45, style: .continuous).fill(Color.white.opacity(0.1)))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.45, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - Pictures of the notch

/// A small piece of screen with the notch hanging from its top edge.
struct MiniScreen<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack(alignment: .top) {
            Color.white.opacity(0.06)
            content
        }
    }
}

/// The notch's own shape, small and black, with whatever it's showing inside.
struct MiniNotch<Inside: View>: View {
    var width: CGFloat = 50
    var height: CGFloat = 13
    @ViewBuilder var inside: Inside

    var body: some View {
        NotchShape(notchSize: CGSize(width: 50, height: 13))
            .fill(Color.black)
            .frame(width: width, height: height)
            .overlay { inside }
    }
}

extension MiniNotch where Inside == EmptyView {
    init(width: CGFloat = 50, height: CGFloat = 13) {
        self.width = width
        self.height = height
        inside = EmptyView()
    }
}

/// A MacBook and a monitor beside it, each with the notch drawn or not (Monitor mode's pictures).
struct MiniDisplays: View {
    let laptop: Bool
    let monitor: Bool

    var body: some View {
        MiniScreen {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(spacing: 0) {
                    screen(width: 42, height: 28, notch: laptop)
                    RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.3)).frame(width: 52, height: 3)
                }
                VStack(spacing: 0) {
                    screen(width: 56, height: 36, notch: monitor)
                    Rectangle().fill(.white.opacity(0.22)).frame(width: 5, height: 6)
                    RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.3)).frame(width: 20, height: 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func screen(width: CGFloat, height: CGFloat, notch: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(.white.opacity(0.1))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1))
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: 2.5, bottomTrailingRadius: 2.5, style: .continuous)
                    .fill(Color.black)
                    .frame(width: width * 0.32, height: 5)
                    .padding(.top, 1)
                    .opacity(notch ? 1 : 0)
                    .scaleEffect(x: notch ? 1 : 0.4, y: notch ? 1 : 0.2, anchor: .top)
            }
            .frame(width: width, height: height)
    }
}

/// The pointer, small.
struct Pointer: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.82))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.28, y: rect.minY + h * 0.6))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.5, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.66, y: rect.minY + h * 0.92))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.45, y: rect.minY + h * 0.56))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.56))
        p.closeSubpath()
        return p
    }
}

private struct PointerMark: View {
    var clicked = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            if clicked { Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1).frame(width: 14, height: 14).offset(x: -7, y: -7) }
            Pointer().fill(.white).frame(width: 9, height: 13)
                .overlay(Pointer().stroke(.black, lineWidth: 0.8).frame(width: 9, height: 13))
        }
        .frame(width: 9, height: 13, alignment: .topLeading)
    }
}

/// Lines standing in for words.
private struct TextLines: View {
    var widths: [CGFloat]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(widths.indices, id: \.self) { Capsule().fill(.white.opacity($0 == 0 ? 0.9 : 0.45)).frame(width: widths[$0], height: 3) }
        }
    }
}

/// The real notch, showing an answer at your text size, on a piece of screen.
struct NotchPreview: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var model: NotchModel = {
        let model = NotchModel()
        model.notchSize = NSScreen.main.flatMap { NotchModel.physicalNotchSize(for: $0) } ?? CGSize(width: 185, height: 32)
        model.voice = .answer
        // An answer with its picture, as the notch shows one: the photo ships with the app, so the
        // preview never goes online.
        let bridge = Bundle.main.url(forResource: "GoldenGate", withExtension: "jpg").flatMap(NSImage.init(contentsOf:))
        model.liveAnswer = LiveAnswer(question: "?", text: "San Francisco. The Golden Gate Bridge spans its bay.", finished: true, image: bridge)
        return model
    }()

    var body: some View {
        // An overlay, so the notch's own (wide) frame never widens the page.
        MiniScreen { Color.clear }
            .frame(maxWidth: .infinity)
            .frame(height: 168)
            .overlay(alignment: .top) {
                NotchView(model: model)
                    .frame(width: 720, height: 240, alignment: .top)
                    .id(settings.textSize)  // the notch measures its text when it's made
                    .allowsHitTesting(false)
            }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: settings.textSize)
    }
}

/// Asking Starlight, shown: a question, then its answer in the notch, one after another (Live
/// mode's lock card and Starlight Pro's welcome). Made up and offline; nothing is asked.
struct LiveDemo: View {
    private static let moments: [(asked: String, answer: String)] = [
        ("What's the capital of Italy?", "Rome. The capital since 1871."),
        ("A thousand dollars in Swiss francs?", "850 CHF. At today's rate."),
        ("Add buy milk to my reminders", "Added to Reminders. Buy milk, today."),
        ("Turn on dark mode", "Dark mode is on."),
    ]
    @StateObject private var model: NotchModel = {
        let model = NotchModel()
        model.notchSize = NSScreen.main.flatMap { NotchModel.physicalNotchSize(for: $0) } ?? CGSize(width: 185, height: 32)
        model.voice = .answer
        model.liveAnswer = LiveAnswer(question: LiveDemo.moments[0].asked, text: LiveDemo.moments[0].answer, finished: true)
        return model
    }()
    @State private var index = 0
    private let timer = Timer.publish(every: 3.4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            Text("\u{201C}\(Self.moments[index].asked)\u{201D}").font(.system(size: 13, weight: .medium)).opacity(0.75)
                .id(index).transition(.opacity)
            MiniScreen { Color.clear }
                .frame(maxWidth: .infinity)
                .frame(height: 118)
                .overlay(alignment: .top) {
                    NotchView(model: model)
                        .frame(width: 720, height: 200, alignment: .top)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .onReceive(timer) { _ in
            guard !Render.isRendering else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                index = (index + 1) % Self.moments.count
                model.liveAnswer = LiveAnswer(question: Self.moments[index].asked, text: Self.moments[index].answer, finished: true)
            }
        }
    }
}

/// Starlight Pro, when it's the provider picked and you don't have it yet: what you get, shown,
/// and the trial.
struct ProWelcome: View {
    @ObservedObject private var account = StarlightAccount.shared
    private static let perks = ["Ask anything, out loud", "Live mode: it answers, and does it", "Answers during meetings",
                                "Web search", "No key to set up"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LiveDemo()
            VStack(alignment: .leading, spacing: 4) {
                Text("Starlight Pro").font(.system(size: 22, weight: .bold))
                Text("Enhanced AI, built in.").font(.system(size: 14)).opacity(0.6)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.perks, id: \.self) { perk in
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).opacity(0.8)
                        Text(perk).font(.system(size: 13))
                    }
                }
            }
            HStack(spacing: 12) {
                GlassButton(title: account.signingIn ? "Signing in\u{2026}" : "Try Pro free", prominent: true) { account.upgrade() }
                Text("3 days free, then $15 a month").font(.system(size: 12)).opacity(0.5)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - A page with tabs

/// History and settings of one feature, on one page.
struct PageTabs: View {
    @EnvironmentObject private var state: CompanionState
    let tabs: [(String, CompanionState.Page)]

    var body: some View {
        Picker("", selection: Binding(get: { state.page }, set: { state.page = $0 })) {
            ForEach(tabs.indices, id: \.self) { Text(tabs[$0].0).tag(tabs[$0].1) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }
}

// MARK: - Shared explanations

/// How a feature's key works: Toggle (press to start, again to stop) or Hold (while you talk).
struct KeyModePicker: View {
    @Binding var mode: AppSettings.KeyMode

    var body: some View {
        Picker("", selection: $mode) {
            Text("Toggle").tag(AppSettings.KeyMode.toggle)
            Text("Hold").tag(AppSettings.KeyMode.hold)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 160)
    }
}

/// What each shortcut does, for its hover card (General and Shortcuts show the same words).
let dictateInfo = ["The keys for dictation: Control Space unless you change it. Pick how they work below."]
let dictationModeInfo = ["Toggle: press once and talk; press again and your words are typed where your cursor is.",
                         "Hold: hold the keys while you talk; let go and your words are typed."]
let liveKeyInfo = ["Live mode's key: Option Space, or a key on its own, like Fn."]
let liveModeInfo = ["Toggle: press to start a Live conversation, and again to end it.",
                    "Hold: hold, ask one thing, and let go. The answer shows in the notch, or it just does it."]
let meetingsInfo = ["Starts taking notes of a meeting; press again to stop and save them."]
let transcriptInfo = ["Shows or hides the transcript window: everything said so far, live, while notes or Live mode run.",
                      "A shortcut, not a switch."]
let silentInfo = ["Keeps taking notes but doesn't answer on its own.",
                  "Say \u{201C}Starlight, \u{2026}\u{201D} to ask anyway."]

// MARK: - General

/// The notch: its text size, how it opens, what shows in it, and monitors.
struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Page(title: "Notch") {
            Block(title: "Text size") {
                VStack(spacing: 12) {
                    NotchPreview(settings: settings)
                    Picker("", selection: $settings.textSize) {
                        Text("Smaller").tag(AppSettings.TextSize.smaller)
                        Text("Default").tag(AppSettings.TextSize.standard)
                        Text("Larger").tag(AppSettings.TextSize.larger)
                        Text("Largest").tag(AppSettings.TextSize.largest)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 340)
                }
            }
            Block(title: "The notch opens") {
                ChoiceTiles(selection: $settings.openOnHover, tiles: [
                    ChoiceTile("On hover", true) {
                        MiniScreen {
                            VStack(spacing: 3) {
                                MiniNotch(width: 62, height: 17)
                                PointerMark().offset(x: 6)
                            }
                        }
                    },
                    ChoiceTile("On click", false) {
                        MiniScreen {
                            VStack(spacing: 3) {
                                MiniNotch(width: 50, height: 13)
                                PointerMark(clicked: true).offset(x: 6)
                            }
                        }
                    },
                ])
            }
            Rows {
                Row(title: "Show what's playing", info: ["The song playing in Spotify, Music or a browser tab, beside the notch.",
                                                         "Hover it for play, pause and skip."]) { Switch(isOn: $settings.showNowPlaying) }
                Row(title: "Headphone batteries", info: ["When AirPods or other headphones connect, their name and battery show for a moment."]) {
                    Switch(isOn: $settings.showHeadphones)
                }
                Row(title: "Notch sounds", info: ["A soft chime when dictation starts and stops."]) { Switch(isOn: $settings.sounds) }
                Row(title: "Notch haptics", info: ["A light tap on the trackpad as the notch opens and things finish."]) { Switch(isOn: $settings.haptics) }
                Row(title: "Menu bar icon", info: ["Starlight's icon in the menu bar, with its menu."], last: true) {
                    Switch(isOn: $settings.showMenuBarIcon)
                }
            }
            .id("Shows in the notch").modifier(Highlighted(group: "Shows in the notch"))
            Block(title: "Monitor mode", info: ["Auto-detect: on a screen without a camera notch, like a monitor, the notch hides until something happens.",
                                                "Always show: it's always there.",
                                                "Hide: hidden on every screen until something happens. Hover the top of the screen to bring it back."]) {
                ChoiceTiles(selection: $settings.monitorMode, tiles: [
                    ChoiceTile("Auto-detect", AppSettings.MonitorMode.auto) { MiniDisplays(laptop: true, monitor: false) },
                    ChoiceTile("Always show", AppSettings.MonitorMode.show) { MiniDisplays(laptop: true, monitor: true) },
                    ChoiceTile("Hide", AppSettings.MonitorMode.hide) { MiniDisplays(laptop: false, monitor: false) },
                ])
            }
            Rows {
                Row(title: "Animation speed", value: String(format: "%.2g×", settings.animationSpeed),
                    info: ["How fast the notch opens, closes and changes shape."], last: true) {
                    HStack(spacing: 8) {
                        if abs(settings.animationSpeed - 1) > 0.01 {
                            IconButton(icon: .rewind, label: "Reset speed", size: 26) { settings.animationSpeed = 1 }
                        }
                        Slider(value: $settings.animationSpeed, in: 0.5...2, step: 0.05).frame(width: 160)
                    }
                }
            }
            .id("Animation")

        }
    }
}

/// A feature's page: its switch beside the title (what the feature is on hover). While it's off,
/// everything on the page greys out and can't be changed.
struct FeaturePage<Content: View>: View {
    let title: String
    var info: [String] = []
    @Binding var isOn: Bool
    /// Needs an AI provider and there isn't one: the page greys out under a lock card.
    var locked = false
    /// The lock card shows the feature at work (Live mode).
    var showcase = false
    @ViewBuilder let content: Content

    var body: some View {
        Page(title: title) {
            Switch(isOn: $isOn).modifier(HoverInfo(title: title, lines: info))
        } content: {
            VStack(alignment: .leading, spacing: 20) { content }
                .disabled(!isOn)
                .opacity(isOn ? 1 : 0.35)
                .animation(.easeOut(duration: 0.2), value: isOn)
                .modifier(LockedForAI(locked: locked, alignment: .top, showcase: showcase))
        }
    }
}

/// Dictation: talk, and it types where your cursor is. The mic and languages are here too.
struct DictationSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var microphones = AudioCapture.inputDevices()

    var body: some View {
        FeaturePage(title: "Dictation", info: ["Talk, and your words are typed where your cursor is, in any app.",
                                                "Off: its shortcuts are free for other apps, and it's gone from the notch."],
                    isOn: $settings.dictationEnabled) {
            Block(title: "Your words go", info: ["Where you're typing: straight into the text field your cursor is in (needs Accessibility), and on the clipboard too.",
                                                 "To the clipboard: copied, ready to paste with \u{2318}V.",
                                                 "Either way, every dictation is on the clipboard, so nothing is lost."]) {
                VStack(spacing: 12) {
                    ChoiceTiles(selection: destination, tiles: [
                        ChoiceTile("Where you're typing", true) { typedPicture },
                        ChoiceTile("To the clipboard", false) { clipboardPicture },
                    ])
                    if settings.autoPaste && !AutoPaste.isAllowed {
                        HStack {
                            Text("Needs Accessibility").font(.system(size: 12)).opacity(0.6)
                            Spacer()
                            GlassButton(title: "Allow") { AutoPaste.requestPermission() }
                        }
                    }
                }
            }
            Rows {
                Row(title: "Dictation shortcut", info: dictateInfo) { ShortcutRecorder(combo: $settings.dictationShortcut, defaultCombo: .toggleRecording) }
                Row(title: "Shortcut works by", info: dictationModeInfo, last: true) { KeyModePicker(mode: $settings.dictationKeyMode) }
            }
            .id("The text goes").modifier(Highlighted(group: "The text goes"))
            Block(title: "Dictation formatting", info: ["Word for word: exactly what you said, ums and all. Instant.",
                                                        "Clean: ums, ers and repeated words out, punctuation and capitals in. Instant.",
                                                        "Polished by AI: rewritten into clear sentences by a small model on your Mac. About a second more, and it downloads once (900 MB)."]) {
                ChoiceTiles(selection: $settings.transcriptionStyle, tiles: [
                    ChoiceTile("Word for word", .verbatim) { sample("um so the launch is uh moving to march i think") },
                    ChoiceTile("Clean", .clean) { sample("So the launch is moving to March, I think.") },
                    ChoiceTile("Polished by AI", .polished) { sample("The launch is moving to March.") },
                ], height: 76)
            }
            Block(title: "When you stop") {
                ChoiceTiles(selection: $settings.closeAfterDictation, tiles: [
                    ChoiceTile("The notch closes", true) { MiniScreen { MiniNotch().padding(.top, 0) } },
                    ChoiceTile("It shows the text", false) {
                        MiniScreen {
                            MiniNotch(width: 104, height: 34) { TextLines(widths: [70, 52]).padding(.top, 8) }
                        }
                    },
                ])
            }
            Rows {
                Row(title: "Words as you speak", info: ["Your words show in the notch while you talk."]) {
                    Switch(isOn: $settings.liveText)
                }
                if !settings.closeAfterDictation {
                    Row(title: "Show the text for", value: "\(Int(settings.resultSeconds)) s",
                        info: ["How long the notch shows what you said before it closes."]) {
                        Slider(value: $settings.resultSeconds, in: 3...15, step: 1).frame(width: 180)
                    }
                }
                Row(title: "Start sound") { SoundPicker(selection: $settings.startSound, rising: true) }
                Row(title: "Stop sound", last: true) { SoundPicker(selection: $settings.stopSound, rising: false) }
            }
            .id("While you talk")
            Rows {
                Row(title: "Microphone", value: microphoneStatus,
                    info: ["Smart: the built-in mic while your MacBook is open; with the lid closed (on a monitor), your Bluetooth headset's.",
                           "Prefer Bluetooth: your headset's mic whenever it's connected. Built-in: always the Mac's own.",
                           "Pick a mic and Starlight always uses it while it's connected."]) {
                    Picker("", selection: $settings.microphoneUID) {
                        Text("Smart").tag(AppSettings.Microphone.smart)
                        Text("Prefer Bluetooth").tag(AppSettings.Microphone.bluetooth)
                        Text("Built-in microphone").tag(AppSettings.Microphone.builtIn)
                        Text("System default (\(AudioCapture.name(of: AudioCapture.defaultInputDevice())))").tag(AppSettings.Microphone.system)
                        Divider()
                        if !AppSettings.Microphone.choices.contains(settings.microphoneUID),
                           !microphones.contains(where: { $0.uid == settings.microphoneUID }) {
                            Text("Disconnected").tag(settings.microphoneUID)
                        }
                        ForEach(microphones) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden().frame(width: 260)
                }
                Row(title: "Languages", info: ["English: the fastest and most accurate in English.",
                                               "25 European: works out the language by itself (French, German, Spanish and more). Switching downloads it once, about 460 MB."]) {
                    Picker("", selection: $settings.speechLanguages) {
                        Text("English").tag(AppSettings.SpeechLanguages.english)
                        Text("25 European").tag(AppSettings.SpeechLanguages.european)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                Row(title: "Unload voice model when not in use", info: ["Frees memory: the voice model unloads after 30 minutes unused.",
                                                                        "The first dictation after that waits a second or two."], last: true) {
                    Switch(isOn: $settings.unloadVoiceModel)
                }
            }
            .id("Voice model").modifier(Highlighted(group: "Voice model"))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            microphones = AudioCapture.inputDevices()  // headphones may have connected meanwhile
        }
    }

    /// Only says something when the chosen mic isn't the one in use.
    private var microphoneStatus: String? {
        guard !AppSettings.Microphone.choices.contains(settings.microphoneUID), AudioCapture.chosenInputDevice() == nil else { return nil }
        return "Not connected · using default"
    }

    /// Where you're typing, or the clipboard: one or the other.
    private var destination: Binding<Bool> {
        Binding(get: { settings.autoPaste }, set: { typed in
            settings.autoPaste = typed
            if typed, !AutoPaste.isAllowed { AutoPaste.requestPermission() }
        })
    }

    /// A text field with your words in it and the cursor after them.
    private var typedPicture: some View {
        MiniScreen {
            HStack(spacing: 3) {
                TextLines(widths: [54])
                Capsule().fill(.white).frame(width: 1.5, height: 11)
            }
            .padding(.horizontal, 10).frame(width: 96, height: 24, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The clipboard, holding your words.
    private var clipboardPicture: some View {
        MiniScreen {
            VStack(spacing: 6) {
                Glyph(kind: .copy, size: 18).opacity(0.85)
                TextLines(widths: [40])
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sample(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).opacity(0.85)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
    }
}

/// Meetings: transcripts of your calls, both sides, with help as it goes.
struct MeetingSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        FeaturePage(title: "Meetings", info: ["Transcripts of your calls: what you and the others say.",
                                               "Off: no \u{201C}Take notes?\u{201D} when a call starts, and its shortcut is free."],
                    isOn: $settings.meetingsEnabled) {
            Block(title: "When a call starts", info: ["When Zoom, Meet, Teams, FaceTime or another call app starts using the mic.",
                                                      "Ask first: the notch asks \u{201C}Take notes?\u{201D}",
                                                      "Take notes: notes start by themselves and stop when the call ends.",
                                                      "Nothing: you start notes yourself."]) {
                ChoiceTiles(selection: $settings.meetingMode, tiles: [
                    ChoiceTile("Ask first", .ask) {
                        MiniScreen {
                            MiniNotch(width: 92, height: 24) {
                                Text("Take notes?").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.white).padding(.top, 5)
                            }
                        }
                    },
                    ChoiceTile("Take notes", .auto) {
                        MiniScreen {
                            MiniNotch(width: 92, height: 24) {
                                HStack(spacing: 5) {
                                    AppMark(swell: 0.3).frame(width: 12, height: 10)
                                    Text("0:12").font(.system(size: 8.5, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                                }
                                .padding(.top, 5)
                            }
                        }
                    },
                    ChoiceTile("Nothing", .off) { MiniScreen { MiniNotch() } },
                ])
            }
            Rows {
                Row(title: "Toggle meetings", info: meetingsInfo) { ShortcutRecorder(combo: $settings.notesShortcut, defaultCombo: .notes) }
                Row(title: "Toggle transcript window", info: transcriptInfo) {
                    ShortcutRecorder(combo: $settings.transcriptShortcut, defaultCombo: .transcript)
                }
                Row(title: "Hear the other side", value: settings.captureTheirAudio ? settings.theirAudioProblem : nil,
                    info: ["Writes down what the others say too, from your Mac's audio, not only your mic."]) {
                    Switch(isOn: $settings.captureTheirAudio)
                }
                Row(title: "Captions under the notch", info: ["Your words as you say them, in a line under the notch."]) {
                    Switch(isOn: $settings.captionsNotch)
                }
                Row(title: "Captions in the transcript", info: ["Words show in the transcript window as they're said, before each line is final."]) {
                    Switch(isOn: $settings.captionsTranscript)
                }
                Row(title: "Open the transcript with each meeting", info: ["The transcript window opens by itself when notes start."], last: true) {
                    Switch(isOn: $settings.openOverlayWithSessions)
                }
            }
            .id("During a meeting").modifier(Highlighted(group: "During a meeting"))
            YourVoiceSection()
            .id("Silent mode")
            Rows {
                Row(title: "Voice sensitivity", value: "\(Int(settings.voiceSensitivity * 100))%",
                    info: ["Higher picks up quieter voices; lower ignores talk in the background."]) {
                    Slider(value: $settings.voiceSensitivity, in: 0...1, step: 0.05).frame(width: 180)
                }
                Row(title: "Pause between phrases", value: String(format: "%.1f s", settings.notesPause),
                    info: ["How long a pause ends a line in the transcript."], last: true) {
                    Slider(value: $settings.notesPause, in: 0.5...2, step: 0.1).frame(width: 180)
                }
            }
            .id("Hearing")
        }
    }
}

/// Live mode: a conversation with your Mac.
struct LiveSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var extensions = Extensions.shared

    var body: some View {
        FeaturePage(title: "Live mode", info: ["A conversation with your Mac: ask anything, or ask it to do something (\u{201C}open my last meeting\u{201D}).",
                                                "Off: its shortcut is free, and it's gone from the notch."],
                    isOn: $settings.liveEnabled, locked: !settings.hasAnswerKey, showcase: true) {
            Rows {
                Row(title: "Live mode shortcut", info: liveKeyInfo) { AskKeyRecorder(key: $settings.askKey) }
                Row(title: "Shortcut works by", info: liveModeInfo, last: true) { KeyModePicker(mode: $settings.liveKeyMode) }
            }
            AskKeyNote(key: settings.askKey)
            Rows {
                Row(title: "Toggle transcript window", info: transcriptInfo) {
                    ShortcutRecorder(combo: $settings.transcriptShortcut, defaultCombo: .transcript)
                }
                Row(title: "Toggle silent mode", info: silentInfo, last: true) {
                    ShortcutRecorder(combo: $settings.silentShortcut,
                                     defaultCombo: HotKey.Combo(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey), keyName: "S"))
                }
            }
            Rows {
                Row(title: "AI provider", info: ["Where Live mode's answers come from. The keys and models are on Answers."]) {
                    Picker("", selection: $settings.answerService) {
                        ForEach(AppSettings.AnswerService.offered) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(width: 200)
                }
                Row(title: "Answers stay for", value: "\(Int(settings.liveAnswerSeconds)) s",
                    info: ["How long an answer stays under the notch before it goes."]) {
                    Slider(value: $settings.liveAnswerSeconds, in: 5...30, step: 1).frame(width: 180)
                }
                Row(title: "Deep answers", info: ["Auto: thinks longer when a question needs it, like code or real math.",
                                                  "Always: every answer. Off: never, so answers come fastest."], last: true) {
                    Picker("", selection: $settings.deepMode) {
                        Text("Auto").tag(AppSettings.DeepMode.auto)
                        Text("Always").tag(AppSettings.DeepMode.always)
                        Text("Off").tag(AppSettings.DeepMode.off)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
            }
            .id("Answers and captions").modifier(Highlighted(group: "Answers and captions"))
            if !Edition.isOpenSource { MeetingAnswers(settings: settings) }
            Block(title: "How long answers are") {
                ChoiceTiles(selection: $settings.answerLength, tiles: [
                    ChoiceTile("Short", .short) { MiniAnswer(headline: "San Francisco.", detail: nil, height: 26) },
                    ChoiceTile("Normal", .normal) { MiniAnswer(headline: "San Francisco.", detail: "It spans the Golden Gate.", height: 38) },
                    ChoiceTile("Detailed", .detailed) { MiniAnswer(headline: "San Francisco.", detail: "It spans the Golden Gate; opened in 1937.", height: 50) },
                ], height: 78)
            }
            Rows {
                Row(title: "Hear the other side", info: ["Hears what your Mac plays too (a video, a call), not only your mic."]) {
                    Switch(isOn: $settings.captureTheirAudio)
                }
                Row(title: "Captions under the notch", info: ["Your words as you say them, in a line under the notch."]) {
                    Switch(isOn: $settings.captionsNotch)
                }
                Row(title: "Open the transcript when it starts", info: ["The transcript window opens by itself with Live mode and meeting notes."], last: true) {
                    Switch(isOn: $settings.openOverlayWithSessions)
                }
            }
            ToolsGrid(extensions: extensions)
            ForEach(extensions.problems, id: \.self) { problem in
                HStack(spacing: 8) { Glyph(kind: .alert, size: 13); Text(problem).font(.system(size: 12)) }.opacity(0.6)
            }
        }
    }
}

/// An answer as the notch shows it, small: big, with a line of detail under it (Answers and Live mode).
struct MiniAnswer: View {
    let headline: String
    let detail: String?
    let height: CGFloat

    var body: some View {
        MiniScreen {
            MiniNotch(width: 132, height: height) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.system(size: 10, weight: .semibold))
                    if let detail { Text(detail).font(.system(size: 7.5)).opacity(0.6).lineLimit(2) }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 6)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

// MARK: - Answers

/// The AI provider: Starlight (Pro), your own OpenRouter, Anthropic or OpenAI key, or a model in
/// Ollama, picked from a list, with what the one picked needs under it.
struct AIProviderPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var account = StarlightAccount.shared
    @State private var key = ""

    var body: some View {
        Page(title: "AI provider") {
            Rows {
                let offered = AppSettings.AnswerService.offered
                ForEach(offered) { service in
                    ProviderChoice(service: service, chosen: settings.answerService == service, last: service == offered.last) {
                        settings.answerService = service
                    }
                }
            }
            .id("AI provider").modifier(Highlighted(group: "AI provider"))
            if settings.answerService == .notch && !account.allows(.pro) && StarlightAccount.hasService { ProWelcome() }
            Rows { setup(settings.answerService) }
            Rows {
                Row(title: "Search the web from this Mac", value: "Beta",
                    info: ["Your Mac looks things up on Startpage and reads the top pages, then your AI answers from them.",
                           "No search fees, and it works with every provider, Ollama too."], last: true) {
                    Switch(isOn: $settings.searchOnMac)
                }
            }
        }
    }

    /// What the picked provider needs: Pro, a key, or Ollama's address; and the model.
    @ViewBuilder private func setup(_ service: AppSettings.AnswerService) -> some View {
        if service == .notch {
            // Without Pro, the welcome above has the trial; with it, Manage.
            if account.allows(.pro) {
                Row(title: "Starlight Pro", info: ["Enhanced AI, built in: no key to set up."], last: !account.isSignedIn) {
                    GlassButton(title: "Manage") { account.openSubscription() }
                }
            }
            if account.isSignedIn {
                Row(title: account.email ?? "Signed in", last: true) {
                    GlassButton(title: "Sign out", destructive: true) { account.signOut() }
                }
            }
        } else {
            if service.needsKey {
                Row(title: "\(service.displayName) key", value: settings.savedKeys.contains(service) ? "Saved" : nil,
                    info: ["Kept in your Keychain, and sent only to \(service.displayName).",
                           "Get one at \(service.keysPage?.host ?? service.displayName)."]) {
                    if settings.savedKeys.contains(service) {
                        IconButton(icon: .close, label: "Remove key", size: 28) { saveKey(nil) }
                    } else {
                        HStack(spacing: 6) {
                            Field(placeholder: service.keyHint, text: $key, secure: true) { saveKey(key); key = "" }
                                .frame(width: 210)
                            GlassButton(title: "Save", prominent: true) { saveKey(key); key = "" }
                        }
                    }
                }
            } else {
                Row(title: "Address", info: ["Where Ollama runs: usually this Mac. Another Mac on your network works too.",
                                             "Get Ollama at ollama.com."]) {
                    Field(placeholder: "http://localhost:11434", text: $settings.ollamaURL).frame(width: 210)
                }
            }
            Row(title: "Model", info: ["Type a model's name, or Choose from the ones \(service.displayName) offers.",
                                       "Empty uses \(service == .ollama ? "the first you pick" : service.defaultModel)."], last: true) {
                ModelPicker(settings: settings, service: service).id("\(service.rawValue) \(settings.savedKeys.contains(service))")
            }
        }
    }

    /// Only a real key is saved (just the key, from a pasted line); anything else beeps.
    private func saveKey(_ value: String?) {
        let service = settings.answerService
        if let value {
            guard let clean = AppSettings.cleanKey(value, for: service),
                  AppSettings.looksLikeKey(clean, for: service) else { return NSSound.beep() }
            settings.setKey(clean, for: service)
        } else {
            settings.setKey(nil, for: service)
        }
    }
}

/// One provider in the list: its name, a check when it's the one, and what it is on hover.
private struct ProviderChoice: View {
    let service: AppSettings.AnswerService
    let chosen: Bool
    let last: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            Row(title: service.displayName, info: Self.info[service] ?? [], last: last) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16)).opacity(chosen ? 1 : 0.3)
            }
        }
        .buttonStyle(.plain)
    }

    static let info: [AppSettings.AnswerService: [String]] = [
        .notch: ["Starlight Pro: enhanced AI, built in, with no key to set up."],
        .openrouter: ["Your own OpenRouter key: hundreds of models, Claude Haiku by default. Web search included.",
                      "Free in Starlight; OpenRouter bills you for what you use."],
        .anthropic: ["Your own Anthropic key: Claude, straight from Anthropic. Web search included.",
                     "Free in Starlight; Anthropic bills you for what you use."],
        .openai: ["Your own OpenAI key: GPT models. No web search.", "Free in Starlight; OpenAI bills you for what you use."],
        .ollama: ["A model running on your Mac in Ollama: free, and nothing leaves your Mac.",
                  "Pick one that can use tools for the best answers."],
    ]
}

/// In meetings: Starlight answers the questions people ask under the notch, or stays quiet and
/// just takes the notes (on Live mode, with the rest of answering).
private struct MeetingAnswers: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Block(title: "In meetings", info: ["Answers questions: when someone asks something, a short answer shows under the notch, for you alone.",
                                           "Stays quiet: it only takes the notes."]) {
            ChoiceTiles(selection: $settings.liveAnswers, tiles: [
                ChoiceTile("Answers questions", true) { answers(2) },
                ChoiceTile("Stays quiet", false) { quietPicture },
            ], height: 78)
        }
    }

    /// Stays quiet: the notch, listening, with nothing under it.
    private var quietPicture: some View {
        MiniScreen {
            VStack(spacing: 5) {
                MiniNotch()
                TextLines(widths: [44]).opacity(0.35)
            }
        }
    }

    private func answers(_ count: Int) -> some View {
        MiniScreen {
            VStack(spacing: 5) {
                MiniNotch()
                ForEach(0..<count, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.black)
                        .frame(width: 70, height: 11)
                        .overlay(Capsule().fill(.white.opacity(0.7)).frame(width: 40, height: 2.5))
                }
            }
        }
    }

}

/// The model for a service: typed, or picked from the ones it offers (fetched when the menu opens,
/// with your key where the list needs one).
struct ModelPicker: View {
    @ObservedObject var settings: AppSettings
    let service: AppSettings.AnswerService
    @State private var text = ""
    @State private var options: [String] = []
    @State private var loading = false

    var body: some View {
        HStack(spacing: 6) {
            Field(placeholder: service == .ollama ? "llama3.2" : service.defaultModel, text: $text) { settings.setModel(text, for: service) }
                .frame(width: 210)
                .onChange(of: text) { _, value in settings.setModel(value, for: service) }
            Menu {
                if options.isEmpty {
                    Text(loading ? "Loading…" : service == .ollama ? "No models (is Ollama running?)" : "No list (check the key)")
                }
                ForEach(options, id: \.self) { option in Button(option) { text = option } }
            } label: {
                Text("Choose").font(.system(size: 13))
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .onAppear {
            text = settings.model(for: service) == service.defaultModel && service != .ollama ? "" : settings.model(for: service)
            load()
        }
    }

    private func load() {
        guard !loading else { return }
        loading = true
        Task {
            let key = service.needsKey ? settings.answerKeyFor(service) : nil
            let found = await AIService.models(service, key: key)
            options = found
            loading = false
        }
    }
}

/// Everything answers can use, as small tiles two by two: its icon, its name, a switch. The few
/// that need setting up (a folder, a token, a permission) show it under the tiles once they're on.
struct ToolsGrid: View {
    @ObservedObject var extensions: Extensions
    private static let group = "What it can use"
    private static let needsSetup: Set<String> = ["screen", "computer"]

    var body: some View {
        let all = extensions.all.filter { !Edition.hiddenExtensions.contains($0.id) }
        let setup = all.filter { extensions.isEnabled($0) && Self.needsSetup.contains($0.id) }
        VStack(alignment: .leading, spacing: 8) {
            Caption(text: Self.group)
            VStack(spacing: 10) {
                ForEach(Array(stride(from: 0, to: all.count, by: 2)), id: \.self) { start in
                    HStack(spacing: 10) {
                        ToolTile(ext: all[start], extensions: extensions)
                        // An odd one out: an empty half beside it (no height of its own, or it fills the page).
                        if start + 1 < all.count { ToolTile(ext: all[start + 1], extensions: extensions) } else { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                }
            }
            .modifier(Highlighted(group: Self.group))
            if !setup.isEmpty {
                Caption(text: "Set up").padding(.top, 12)
                Rows {
                    ForEach(Array(setup.enumerated()), id: \.element.id) { index, ext in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Glyph(kind: ext.glyph, size: 14)
                                Text(ext.name).font(.system(size: 13, weight: .medium))
                            }
                            ExtensionSetup(id: ext.id)
                        }
                        .padding(.vertical, 12)
                        .overlay(alignment: .bottom) { if index < setup.count - 1 { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) } }
                    }
                }
            }
        }
        .id(Self.group)
        .animation(.easeOut(duration: 0.2), value: setup.map(\.id))
    }
}

private struct ToolTile: View {
    let ext: any StarlightExtension
    @ObservedObject var extensions: Extensions

    var body: some View {
        let on = extensions.isEnabled(ext)
        HStack(spacing: 10) {
            GlyphWell(kind: ext.glyph, size: 28, active: on)
            Text(ext.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 6)
            Switch(isOn: Binding(get: { extensions.isEnabled(ext) }, set: { extensions.setEnabled(ext, $0) }))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .modifier(CardSurface())
        // Resting on a tile for a moment shows what it can do, in a card under it.
        .modifier(HoverInfo(title: ext.name, lines: ToolDetail.lines[ext.id] ?? [ext.summary], glyph: ext.glyph))
    }
}

/// What each tool can do, in a few plain lines with examples: the card a tile shows on hover.
private enum ToolDetail {
    static let lines: [String: [String]] = [
        "notch": ["Answers questions about Starlight itself.",
                  "Changes its own settings when you ask: \u{201C}make the text bigger\u{201D}.",
                  "Turns these tools on or off for you."],
        "calculator": ["Exact math: sums, percentages, unit conversions and equations.",
                       "\u{201C}What\u{2019}s 18% of 240?\u{201D}, \u{201C}solve 2x + 3 = 11\u{201D}."],
        "memory": ["Searches your past meetings and dictations.",
                   "Remembers what you tell it to: \u{201C}remember my flight is Friday at 9\u{201D}."],
        "web-search": ["Looks up anything recent: news, prices, scores, weather, opening hours.",
                       "\u{201C}How did the Warriors do last night?\u{201D}",
                       "Works with Pro, OpenRouter or Anthropic."],
        "screen": ["Reads the window you\u{2019}re in, only when you ask about it.",
                   "\u{201C}Summarize this page\u{201D}, \u{201C}what does this error mean?\u{201D}",
                   "Needs Accessibility, and Screen Recording for some apps."],
        "reminders": ["Adds reminders to Apple Reminders, with a time if you say one.",
                      "\u{201C}Remind me to call Sam at 5.\u{201D}"],
        "computer": ["Files: finds, opens and reads them; saves new ones; moves, renames or trashes them.",
                     "Apps and links: opens them for you.",
                     "Terminal: runs commands, like \u{201C}how much space is left on my disk?\u{201D}",
                     "The clipboard: reads it and copies to it.",
                     "Asks before anything that changes your Mac."],
        "clock": ["Today\u{2019}s date and the time.",
                  "How long the meeting has been going."],
        "mac-controls": ["Look and sound: dark mode, volume, brightness, Night Shift.",
                         "Connections: Wi-Fi and Bluetooth on or off.",
                         "Power: Low Power Mode, keep awake, lock the screen.",
                         "Focus, quitting apps, and any page of System Settings.",
                         "\u{201C}Turn on dark mode\u{201D} works without the AI."],
    ]
}

// MARK: - Shortcuts

struct ShortcutSettings: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        Page(title: "Shortcuts") {
            IconButton(icon: .rewind, label: "Reset shortcuts") { settings.resetShortcuts() }
        } content: {
            Section(title: "Dictation") {
                Row(title: "Dictation shortcut", info: dictateInfo) { ShortcutRecorder(combo: $settings.dictationShortcut, defaultCombo: .toggleRecording) }
                Row(title: "Shortcut works by", info: dictationModeInfo, last: true) { KeyModePicker(mode: $settings.dictationKeyMode) }
            }
            Section(title: "Live mode") {
                Row(title: "Live mode shortcut", info: liveKeyInfo) { AskKeyRecorder(key: $settings.askKey) }
                Row(title: "Shortcut works by", info: liveModeInfo, last: true) { KeyModePicker(mode: $settings.liveKeyMode) }
            }
            AskKeyNote(key: settings.askKey)
            if !Edition.isOpenSource { Section(title: "Meetings") {
                Row(title: "Toggle meetings", info: meetingsInfo) { ShortcutRecorder(combo: $settings.notesShortcut, defaultCombo: .notes) }
                Row(title: "Toggle transcript window", info: transcriptInfo) { ShortcutRecorder(combo: $settings.transcriptShortcut, defaultCombo: .transcript) }
                Row(title: "Toggle silent mode", info: silentInfo, last: true) {
                    ShortcutRecorder(combo: $settings.silentShortcut,
                                     defaultCombo: HotKey.Combo(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey), keyName: "S"))
                }
            } }
        }
    }
}

// MARK: - Privacy

/// What Starlight may use (macOS permissions), what it shows, and what happens to your data.
struct PrivacyPage: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var needsApproval = LoginItem.needsApproval

    var body: some View {
        Page(title: "Privacy") {
            PermissionsCard()
            Rows {
                Row(title: "Hide Starlight when you share your screen",
                    info: ["The notch and Starlight's windows stay out of screenshots, recordings and screen sharing."]) {
                    Switch(isOn: $settings.hideFromCapture)
                }
                Row(title: "Open the notch at login", value: needsApproval ? "Needs approval" : nil,
                    info: ["Starlight starts when you log in to your Mac, so the notch is always there."], last: true) {
                    Switch(isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in
                            LoginItem.set(on)
                            launchAtLogin = LoginItem.isEnabled || LoginItem.needsApproval
                            needsApproval = LoginItem.needsApproval
                        }
                }
            }
            .id("Startup").modifier(Highlighted(group: "Startup"))
            Rows {
                Point(glyph: .voice, title: "Your voice stays on your Mac.", detail: "Dictation and meeting transcripts are made here. Audio is never saved or sent.")
                Point(glyph: .globe, title: "Questions go to the AI service you pick.", detail: "Only what an answer needs, like the meeting so far or your screen when you ask about it. With Ollama, nothing leaves your Mac.")
                Point(glyph: .key, title: "Keys stay in your Keychain.", detail: "Never in a file, never sent anywhere but the service they belong to.")
                Point(glyph: .shield, title: "No tracking.", detail: "No analytics, no ads. Your notes and dictations are files you can delete.", last: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            launchAtLogin = LoginItem.isEnabled || LoginItem.needsApproval
            needsApproval = LoginItem.needsApproval
        }
    }

    private struct Point: View {
        let glyph: Glyph.Kind
        let title: String
        let detail: String
        var last = false
        var body: some View {
            HStack(alignment: .center, spacing: 12) {
                GlyphWell(kind: glyph, size: 30)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .modifier(HoverInfo(title: title, lines: [detail], glyph: glyph))
            .overlay(alignment: .bottom) { if !last { Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.leading, 42) } }
        }
    }
}

// MARK: - Search

/// Every setting, by the words someone might look for it with, and where it lives.
@MainActor
enum SettingsIndex {
    struct Entry: Identifiable, Hashable {
        let title: String
        let page: CompanionState.Page
        let group: String
        var more = false
        var words = ""
        var id: String { "\(title)·\(group)" }
        @MainActor var pageName: String { SettingsIndex.name(of: page) }
    }

    static func name(of page: CompanionState.Page) -> String {
        switch page {
        case .general, .motion: "Notch"
        case .dictation: "Dictation"
        case .notes: "Meetings"
        case .live: "Live mode"
        case .history: "History"
        case .meetings, .session: "Meeting transcripts"
        case .ai, .extensions: "AI provider"
        case .shortcuts: "Shortcuts"
        case .permissions: "Privacy"
        case .account, .usage: "Answers"
        case .about: "About"
        case .tasks: "Tasks"
        case .memory: "Memory"
        }
    }

    static let entries: [Entry] = [
        Entry(title: "Text size", page: .general, group: "Text size", words: "font bigger smaller larger zoom"),
        Entry(title: "Open on hover or click", page: .general, group: "The notch opens", words: "hover click open"),
        Entry(title: "What's playing", page: .general, group: "Shows in the notch", words: "now playing music spotify"),
        Entry(title: "Headphone batteries", page: .general, group: "Shows in the notch", words: "airpods bluetooth battery"),
        Entry(title: "Monitor mode", page: .general, group: "Monitor mode", words: "external display monitor hide notch auto detect"),
        Entry(title: "Notch sounds", page: .general, group: "Shows in the notch", words: "sound audio chime"),
        Entry(title: "Notch haptics", page: .general, group: "Shows in the notch", words: "vibration trackpad feedback"),
        Entry(title: "Open at login", page: .permissions, group: "Startup", words: "launch startup login"),
        Entry(title: "Menu bar icon", page: .general, group: "Shows in the notch", words: "menubar status icon"),
        Entry(title: "Welcome tour", page: .about, group: "Welcome tour", words: "onboarding intro tutorial"),
        Entry(title: "Animation speed", page: .general, group: "Animation", words: "motion slow fast"),
        Entry(title: "Dictation on or off", page: .dictation, group: "Your words go", words: "turn off disable dictate"),
        Entry(title: "Meetings on or off", page: .notes, group: "When a call starts", words: "turn off disable notes meeting"),
        Entry(title: "Live mode on or off", page: .live, group: "Answers and captions", words: "turn off disable live conversation"),
        Entry(title: "Dictation shortcut", page: .dictation, group: "The text goes", words: "key hotkey push to talk"),
        Entry(title: "Dictation style", page: .dictation, group: "Dictation formatting", words: "style verbatim clean polished ai format"),
        Entry(title: "Close or show the text", page: .dictation, group: "When you stop", words: "result after"),
        Entry(title: "Paste where you're typing", page: .dictation, group: "Your words go", words: "auto paste insert accessibility"),
        Entry(title: "Copy to the clipboard", page: .dictation, group: "Your words go", words: "copy clipboard"),
        Entry(title: "Microphone", page: .dictation, group: "Voice model", words: "mic input device smart bluetooth airpods built-in lid monitor"),
        Entry(title: "Languages", page: .dictation, group: "Voice model", words: "language european english"),
        Entry(title: "Words as you speak", page: .dictation, group: "While you talk", words: "live text partial"),
        Entry(title: "Start and stop sounds", page: .dictation, group: "While you talk", words: "sound chime"),
        Entry(title: "Unload voice model when not in use", page: .dictation, group: "Voice model", words: "ram memory parakeet speech model"),
        Entry(title: "When a call starts", page: .notes, group: "When a call starts", words: "meeting zoom call notes auto ask"),
        Entry(title: "Hear the other side", page: .notes, group: "During a meeting", words: "system audio them"),
        Entry(title: "Captions", page: .notes, group: "During a meeting", words: "subtitles transcript"),
        Entry(title: "Your voice", page: .notes, group: "Your voice", words: "learn voice speaker"),
        Entry(title: "Silent mode", page: .live, group: "Answers and captions", words: "mute quiet listen only"),
        Entry(title: "Answers stay for", page: .live, group: "Answers and captions", words: "duration seconds"),
        Entry(title: "Voice sensitivity", page: .notes, group: "Hearing", words: "volume threshold"),
        Entry(title: "AI provider", page: .ai, group: "AI provider", words: "api key openrouter anthropic claude openai gpt ollama local plan pro model"),
        Entry(title: "Answer length", page: .live, group: "How long answers are", words: "short detailed"),
        Entry(title: "Answer questions in meetings", page: .live, group: "In meetings", words: "proactive quiet helps speaks up answers meetings during"),
        Entry(title: "Tools and extensions", page: .live, group: "What it can use", words: "web search reminders files apps terminal commands computer calculator mac controls"),
        Entry(title: "Deep answers", page: .live, group: "Answers and captions", words: "reasoning thinking"),
        Entry(title: "Live mode shortcut", page: .live, group: "Answers and captions", words: "fn hold ask toggle option space key"),
        Entry(title: "Meeting shortcuts", page: .shortcuts, group: "Meetings", words: "notes live transcript silent"),
        Entry(title: "Sign in or out", page: .ai, group: "AI provider", words: "account sign in out login logout email google apple"),
        Entry(title: "Plan and subscription", page: .ai, group: "AI provider", words: "pro trial subscription billing manage cancel upgrade price"),
        Entry(title: "Permissions", page: .permissions, group: "Permissions", words: "microphone accessibility screen recording bluetooth reminders allow"),
        Entry(title: "Hide from screen sharing", page: .permissions, group: "Screen sharing", words: "zoom capture recording hide"),
        Entry(title: "Updates", page: .about, group: "Updates", words: "update version"),
        Entry(title: "Email support", page: .about, group: "Help", words: "help contact support email bug problem"),
    ]

    static func search(_ query: String) -> [Entry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return entries.filter { entry in
            if Edition.isOpenSource, [.notes, .meetings, .tasks, .memory].contains(entry.page) || entry.group == "In meetings" { return false }
            let haystack = "\(entry.title) \(entry.group) \(entry.words) \(entry.pageName)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}
