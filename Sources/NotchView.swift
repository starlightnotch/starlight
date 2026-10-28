import SwiftUI

/// How content inside the notch comes and goes: it sharpens out of a blur as it grows to full
/// size, from slightly smaller and toward the top of the notch. Hidden content sits underneath.
struct NotchContentEffect: ViewModifier {
    var shown: Bool
    /// Leaving content fades and shrinks without the blur: blurring a card's worth of text as it
    /// goes was the most expensive frame to draw, and cost a dropped frame on every close.
    var blurs = true

    func body(content: Content) -> some View {
        content
            .blur(radius: shown || !blurs ? 0 : Motion.contentBlur)
            .scaleEffect(shown ? 1 : Motion.contentHiddenScale, anchor: Motion.contentAnchor)
            .opacity(shown ? 1 : 0)
            .zIndex(shown ? 0 : -1)
    }
}

extension AnyTransition {
    /// For dictation: the same entrance, but the exit runs on the close spring, so the content
    /// shrinks and fades with the notch instead of vanishing first and leaving an empty card.
    static func notchContentClosing(slowMotion: Double = 1) -> AnyTransition {
        let hidden = NotchContentEffect(shown: false)
        let shown = NotchContentEffect(shown: true)
        return .asymmetric(
            insertion: .modifier(active: hidden, identity: shown).animation(Motion.contentIn.speed(1 / slowMotion)),
            removal: .modifier(active: NotchContentEffect(shown: false, blurs: false), identity: NotchContentEffect(shown: true, blurs: false))
                .animation(Motion.close.speed(1 / slowMotion))
        )
    }

    /// Content coming into or leaving the notch.
    static func notchContent(slowMotion: Double = 1) -> AnyTransition {
        let hidden = NotchContentEffect(shown: false)
        let shown = NotchContentEffect(shown: true)
        return .asymmetric(
            insertion: .modifier(active: hidden, identity: shown).animation(Motion.contentIn.speed(1 / slowMotion)),
            removal: .modifier(active: NotchContentEffect(shown: false, blurs: false), identity: NotchContentEffect(shown: true, blurs: false))
                .animation(Motion.contentOut.speed(1 / slowMotion))
        )
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    var onStop: (() -> Void)?
    var voice: VoiceController?
    var notes: NotesController?
    /// False in the notch's window, where NotchMorphView draws the shape and clips this content
    /// with Core Animation; true for PNG renders and previews.
    var drawsShape = true

    var body: some View {
        // Corners are measured against the closed width and the hardware notch's height.
        let shape = NotchShape(notchSize: CGSize(width: model.closedSize.width, height: model.notchSize.height))
        let shadowed = model.isShadowed
        let size = model.size
        let _ = model.redraw

        // Background: ShadowedNotchShapeView. Pure black; the shadow's opacity drops to zero
        // when not shadowed, so the darkening fades in with the same spring as the shape.
        Group {
            if drawsShape {
                // Only the shadow's opacity animates: its blur radius and offset stay put, so it's
                // never rebuilt at the start of a spring.
                shape.fill(.black.shadow(.drop(color: .black.opacity(shadowed ? Motion.shadowOpacity : 0),
                                               radius: Motion.shadowRadius, x: 0, y: Motion.shadowY)))
            } else {
                // Clear, but still the notch's shape for clicks: without it SwiftUI passed clicks
                // through, and a click (the only way in with open on hover off) never arrived.
                Color.clear.contentShape(shape)
            }
        }
            .frame(width: size.width, height: size.height)
            // Content is laid out at its final size and only clipped by the moving shape, so
            // nothing inside relayouts while the notch morphs.
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    if model.voice.isActive {
                        VoiceContent(model: model, phase: model.voice, onStop: onStop)
                            .transition(.notchContentClosing(slowMotion: model.slowMotion))
                    } else if model.notes.isActive {
                        NotesContent(model: model,
                                     onStop: { notes?.stop() },
                                     onDismiss: { notes?.dismiss() },
                                     onTranscript: { notes?.toggleTranscript() },
                                     onPause: { notes?.togglePause() },
                                     onKeep: { notes?.keepDone() })
                            .transition(.notchContent(slowMotion: model.slowMotion))
                    } else if model.launching {
                        LaunchWings(model: model)
                            .transition(.notchContentClosing(slowMotion: model.slowMotion))
                    } else if let tutorial = model.tutorial, tutorial.invite, !model.isOpen, !model.hovering {
                        TutorialInvite(model: model, tutorial: tutorial)
                            .transition(.notchContent(slowMotion: model.slowMotion))
                    } else if let tutorial = model.tutorial, !tutorial.invite {
                        TutorialCard(tutorial: tutorial, top: model.closedSize.height) { NotchTour.shared.back(to: $0) }
                            .frame(width: model.size.width, height: model.size.height, alignment: .top)
                            .transition(.notchContent(slowMotion: model.slowMotion))
                    } else if let app = model.meetingPrompt, !model.isOpen {
                        MeetingPrompt(model: model, app: app,
                                      onTakeNotes: { notes?.startForMeeting() },
                                      onDismiss: { notes?.dismissMeetingPrompt() })
                            .transition(.notchContent(slowMotion: model.slowMotion))
                    } else if let toast = model.toast, !model.isOpen {
                        ToastWings(model: model, toast: toast)
                            .transition(.notchContent(slowMotion: model.slowMotion))
                    } else if model.isOpen {
                        OpenContent(model: model, voice: voice, notes: notes)
                            .frame(width: model.openContentSize.width, height: model.openContentSize.height, alignment: .top)
                            .transition(.notchContent(slowMotion: model.slowMotion))
                    } else if model.showsMusic, !model.isTucked, let track = model.nowPlaying {
                        if model.hovering {
                            MiniPlayer(model: model, track: track)
                                .transition(.notchContent(slowMotion: model.slowMotion))
                        } else {
                            MusicWings(model: model, track: track)
                                .transition(.opacity.animation(.easeOut(duration: 0.2)))
                        }
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .top)
                .modifier(ClipToNotch(shape: shape, on: drawsShape))
            }
            .overlay { if model.showOutline { shape.stroke(.red, lineWidth: 1) } }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The open notch, strictly black and white: the time on the left, large, with the date soft
/// under it, and three options on the right, each a glyph on a quiet disc that turns white on
/// hover and shows its shortcut. Settings sit beside the camera.
///
/// Every measurement follows the text size (TextScale): the shape grows and shrinks with it, so
/// the layout does too, and nothing ever runs into the curved sides.
struct OpenContent: View {
    @ObservedObject var model: NotchModel
    var voice: VoiceController?
    var notes: NotesController?
    @ObservedObject private var store = NotesStore.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let s = TextScale.factor
        let size = model.openContentSize
        // Beside the camera, each side gets what's left of the width after the housing.
        let wing = (size.width - model.closedSize.width) / 2
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 8 * s) {
                    UpdateButton()
                    BatteryLabel(model: model)
                }
                .frame(width: max(wing - 34 * s, 0), alignment: .leading)
                Spacer(minLength: model.closedSize.width)
                SettingsGlyphButton { CompanionWindow.shared.show(.general) }
                    .frame(width: max(wing - 30 * s, 0), alignment: .trailing)
            }
            .padding(.leading, 34 * s)
            .padding(.trailing, 30 * s)
            .frame(height: model.notchSize.height)

            HStack(alignment: .center, spacing: 0) {
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 3 * s) {
                        Text(context.date.formatted(date: .omitted, time: .shortened))
                            .font(.notch(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                        Text(context.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(.notch(size: 12.5, weight: .medium))
                            .opacity(0.55)
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
                Spacer(minLength: 20 * s)
                HStack(spacing: 18 * s) {
                    // Only what's on (Settings → General).
                    if settings.dictationEnabled {
                        HomeOption(icon: .voice, title: "Dictate", shortcut: settings.dictationShortcut.symbols) { voice?.start() }
                    }
                    if settings.liveEnabled {
                        HomeOption(icon: .agent, title: "Live", shortcut: settings.askKey.symbols) { notes?.startLive() }
                    }
                    if settings.meetingsEnabled {
                        HomeOption(icon: .noteLive, title: "Meeting", shortcut: settings.notesShortcut.symbols) { notes?.start() }
                    }
                }
            }
            .padding(.leading, 40 * s)
            .padding(.trailing, 34 * s)
            .padding(.bottom, 12 * s)
            .frame(height: size.height - model.notchSize.height)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .foregroundStyle(.white)
    }
}

/// One option on the home notch: a glyph on a quiet disc with its name below in soft white.
/// Hover turns the disc white (the glyph black), brings the name up to white, and swaps it for
/// the shortcut.
struct HomeOption: View {
    let icon: Glyph.Kind
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let s = TextScale.factor
        Button(action: action) {
            VStack(spacing: 8 * s) {
                ZStack {
                    Circle().fill(hovering ? Color.white : Color.white.opacity(0.1))
                    Glyph(kind: icon, size: 20 * s, active: hovering)
                        .foregroundStyle(hovering ? Color.black : Color.white)
                }
                .frame(width: 48 * s, height: 48 * s)
                .scaleEffect(hovering ? 1.04 : 1)
                Text(hovering ? (shortcut ?? title) : title)
                    .font(.notch(size: 11.5, weight: .medium, design: hovering && shortcut != nil ? .rounded : .default))
                    .opacity(hovering ? 1 : 0.6)
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.opacity)
            }
            .frame(width: 62 * s)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: hovering)
        .accessibilityLabel(title)
    }
}

/// Settings beside the camera: the word and its glyph in soft white, white under the pointer;
/// the glyph moves on hover.
struct SettingsGlyphButton: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("Settings").font(.notch(size: 11.5, weight: .medium))
                Glyph(kind: .sliders, size: 15 * TextScale.factor, active: hovering)
            }
            .opacity(hovering ? 1 : 0.6)
            .frame(height: 26).contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel("Settings")
    }
}

/// Sinks slightly while pressed, on the press spring.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

struct CircleIconButton: View {
    let icon: Glyph.Kind
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Glyph(kind: icon, size: 15, active: hovering)
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.75))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(hovering ? 0.2 : 0.1)))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel(help)
    }
}

/// A battery: a white outline with its charge filled in green (red under 20%), and a bolt
/// while charging.
struct BatteryIcon: View {
    let percent: Int
    var charging = false
    var height: CGFloat = 11

    private var fill: Color {
        // White, like everything else in the notch; red only when it's nearly empty.
        percent < 20 ? Color(red: 1, green: 0.27, blue: 0.23) : .white
    }

    var body: some View {
        let width = height * 2.05
        HStack(spacing: 1.2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                    .strokeBorder(.white.opacity(0.55), lineWidth: 1)
                RoundedRectangle(cornerRadius: height * 0.18, style: .continuous)
                    .fill(fill)
                    .frame(width: max((width - 4) * CGFloat(min(max(percent, 4), 100)) / 100, 2))
                    .padding(2)
                if charging {
                    Image(systemName: "bolt.fill").font(.notch(size: height * 0.7, weight: .bold))
                        .foregroundStyle(.white).frame(maxWidth: .infinity)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                }
            }
            .frame(width: width, height: height)
            Capsule().fill(.white.opacity(0.55)).frame(width: 1.6, height: height * 0.38)
        }
    }
}

/// Above the time and date in the open notch: your headphones' battery while they're
/// connected and report one (the Mac's own battery isn't shown).
struct BatteryLabel: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        if let phones = model.headphonesBattery {
            HStack(spacing: 5) {
                Glyph(kind: .headphones, size: 13)
                BatteryIcon(percent: phones.percent)
                Text("\(phones.percent)%").font(.notch(size: 11.5, weight: .medium).monospacedDigit())
            }
        }
    }
}

/// Spotify or Music in the open notch: artwork, title and artist, and the three controls.
struct MediaRow: View {
    let track: NowPlaying.Track

    var body: some View {
        HStack(spacing: 12) {
            Artwork(image: track.artwork, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.notch(size: 13, weight: .semibold)).lineLimit(1)
                Text(track.artist).font(.notch(size: 11.5)).opacity(0.6).lineLimit(1)
            }
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                MediaButton(icon: .previous, size: 16) { NowPlaying.shared.previous() }
                MediaButton(icon: track.isPlaying ? .pause : .play, size: 20) { NowPlaying.shared.playPause() }
                MediaButton(icon: .next, size: 16) { NowPlaying.shared.next() }
            }
        }
        .frame(height: 40)
    }
}

private struct MediaButton: View {
    let icon: Glyph.Kind
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Glyph(kind: icon, size: size, active: hovering)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Album art, rounded; a music glyph on black while it loads.
struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Glyph(kind: .voice, size: size * 0.45).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

/// Beside the closed notch while music plays: the artwork on the left, moving bars on the
/// right (still while paused).
struct MusicWings: View {
    @ObservedObject var model: NotchModel
    let track: NowPlaying.Track

    var body: some View {
        HStack(spacing: 0) {
            Artwork(image: track.artwork, size: 20)
                .frame(width: NotesLayout.musicWing - 10, alignment: .leading)
            Spacer(minLength: model.closedSize.width)
            MusicBars(playing: track.isPlaying)
                .frame(width: NotesLayout.musicWing - 10, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(width: model.size.width, height: model.closedSize.height - 1)
        .foregroundStyle(.white)
    }
}

/// Four thin bars that move with the music (a gentle animation, not the actual audio).
struct MusicBars: View {
    let playing: Bool
    var body: some View {
        TimelineView(.animation(paused: !playing || Render.isRendering)) { context in
            HStack(spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().frame(width: 2.5, height: Self.height(bar: i, at: context.date, playing: playing))
                }
            }
            .frame(height: 14)
        }
    }

    private static func height(bar i: Int, at date: Date, playing: Bool) -> CGFloat {
        guard playing else { return 5 }
        let t = date.timeIntervalSinceReferenceDate
        let speed = 5.5 + Double(i) * 1.3
        let wave = (sin(t * speed + Double(i) * 1.7) + 1) / 2
        return CGFloat(4 + 9 * wave)
    }
}

/// A Bluetooth device just connected, beside the camera for a few seconds: its battery on the
/// left, the device on the right ("84%" · "AirPods Pro").
struct ToastWings: View {
    @ObservedObject var model: NotchModel
    let toast: NotchModel.Toast

    var body: some View {
        let wing = NotesLayout.toastWing - 14
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if let battery = toast.battery {
                    BatteryIcon(percent: battery, height: 11)
                    Text("\(battery)%").font(.notch(size: 12, weight: .semibold).monospacedDigit())
                } else if let detail = toast.detail {
                    Text(detail).font(.notch(size: 12, weight: .medium)).opacity(0.7).lineLimit(1).fixedSize()
                } else {
                    Glyph(kind: .bluetooth, size: 14)
                    Text("Connected").font(.notch(size: 12, weight: .medium)).opacity(0.7)
                }
            }
            .frame(width: wing, alignment: .leading)
            Spacer(minLength: model.closedSize.width)
            HStack(spacing: 6) {
                Text(toast.title).font(.notch(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Glyph(kind: toast.icon, size: 15)
            }
            .frame(width: wing, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(width: model.size.width, height: model.notchSize.height)
        .foregroundStyle(.white)
    }
}

/// Starlight starting up: its mark on the left, "Ready" on the right with a light passing over it,
/// both easing in a beat after the notch spreads out.
struct LaunchWings: View {
    @ObservedObject var model: NotchModel
    @State private var shown = false
    @State private var rise: CGFloat = 0
    @State private var swell: CGFloat = 0

    var body: some View {
        let wing = NotesLayout.launchWing - 14
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                // The icon's bars grow up one after another, take one breath, and settle.
                AppMark(rise: rise, swell: swell).frame(width: 17, height: 14)
                Text("Starlight").font(.notch(size: 12.5, weight: .semibold))
                    .lineLimit(1).fixedSize()  // one line always, never wrapped under the mark
                    .offset(x: shown ? 0 : -6)
            }
            .frame(width: wing, alignment: .leading)
            Spacer(minLength: model.closedSize.width)
            ShimmerText(text: "Ready")
                .frame(width: wing, alignment: .trailing)
                .offset(x: shown ? 0 : 6)
        }
        .opacity(shown ? 1 : 0)
        .padding(.horizontal, 14)
        .frame(width: model.size.width, height: model.notchSize.height)
        .foregroundStyle(.white)
        .onAppear {
            guard !Render.isRendering else { shown = true; rise = 1; return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.75).delay(0.12)) { shown = true }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.16)) { rise = 1 }
            withAnimation(.easeInOut(duration: 0.32).delay(0.62)) { swell = 1 }
            withAnimation(.easeInOut(duration: 0.4).delay(0.94)) { swell = 0 }
        }
    }
}

/// Hovering the music notch: a mini player. The source and the moving bars beside the camera,
/// then the artwork, title and artist, and the controls. A click on it (not a control) opens
/// the launcher as usual.
struct MiniPlayer: View {
    @ObservedObject var model: NotchModel
    let track: NowPlaying.Track

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(track.app.isEmpty ? track.source.rawValue : track.app)
                    .font(.notch(size: 11, weight: .semibold)).opacity(0.5)
                Spacer(minLength: model.closedSize.width)
                MusicBars(playing: track.isPlaying)
            }
            .padding(.horizontal, 26)
            .frame(height: model.notchSize.height)
            MediaRow(track: track)
                .padding(.horizontal, 22)
            PlaybackLine(track: track)
                .padding(.horizontal, 26)
                .padding(.top, 4)
                .padding(.bottom, 10)
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .top)
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onTapGesture { model.pinned = false; model.set(.open) }
    }
}


/// How far into the song: a thin line under the player that fills as it plays. Asks the player
/// when it appears and every few seconds; moves smoothly in between.
struct PlaybackLine: View {
    let track: NowPlaying.Track
    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var asked = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !track.isPlaying || duration == 0)) { context in
            let now = track.isPlaying ? position + context.date.timeIntervalSince(asked) : position
            let fraction = duration > 0 ? min(max(now / duration, 0), 1) : 0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(.white).frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 3)
            .opacity(duration > 0 ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: duration > 0)
        }
        .onAppear(perform: ask)
        .onChange(of: track.title) { _, _ in ask() }
        .onChange(of: track.isPlaying) { _, _ in ask() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in ask() }
    }

    private func ask() {
        guard !Render.isRendering else { position = 74; duration = 223; return }
        NowPlaying.shared.progress { result in
            guard let result else { return }
            position = result.position
            duration = result.duration
            asked = Date()
        }
    }
}

/// SwiftUI's own clip, when it draws the shape; in the window the morph layer clips instead.
private struct ClipToNotch: ViewModifier {
    let shape: NotchShape
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.clipShape(shape) } else { content }
    }
}

/// The tour's "hover me", beside the camera: a cursor on the left, the words on the right, a
/// slow glow passing over them. Once you've hovered, a check and "Nice." instead.
struct TutorialInvite: View {
    @ObservedObject var model: NotchModel
    let tutorial: NotchModel.Tutorial
    @State private var pulse = false

    var body: some View {
        let wing = NotesLayout.toastWing - 14
        HStack(spacing: 0) {
            Group {
                if tutorial.learned {
                    OutcomeBadge(ok: true, size: 16).transition(.scale.combined(with: .opacity))
                } else {
                    Glyph(kind: .mouse, size: 15, active: true)
                        .offset(y: pulse ? -1.5 : 1.5)
                }
            }
            .frame(width: wing, alignment: .leading)
            Spacer(minLength: model.closedSize.width)
            Group {
                if tutorial.learned {
                    Text(tutorial.title).font(.notch(size: 12.5, weight: .semibold))
                } else {
                    ShimmerText(text: tutorial.title).font(.notch(size: 12.5, weight: .semibold))
                }
            }
            .lineLimit(1).fixedSize()
            .frame(width: wing, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(width: model.size.width, height: model.notchSize.height)
        .foregroundStyle(.white)
        .onAppear {
            guard !Render.isRendering else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// The welcome tour teaching from the notch: one line, a quiet one under it, and dots for
/// where you are. The hello sets "Starlight" big beside the mark, in the notch's own type, the
/// bars rising one after another as it appears.
struct TutorialCard: View {
    let tutorial: NotchModel.Tutorial
    /// Below the camera.
    var top: CGFloat = 32
    /// A dot for an earlier step was clicked: the tour goes back to it.
    var onDot: ((Int) -> Void)? = nil
    @State private var rise: CGFloat = 0
    @State private var shown = false

    var body: some View {
        let s = TextScale.factor
        VStack(spacing: 4 * s) {
            if tutorial.wordmark {
                HStack(spacing: 10 * s) {
                    AppMark(rise: rise).frame(width: 25 * s, height: 21 * s)
                    Text("Starlight").font(.notch(size: 30, weight: .bold)).tracking(-0.5)
                        .opacity(shown ? 1 : 0).offset(x: shown ? 0 : -8 * s)
                }
            } else {
                Text(tutorial.title).font(.notch(size: 19, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            if !tutorial.detail.isEmpty {
                Text(tutorial.detail).font(.notch(size: 12.5)).opacity(0.55)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            if let keys = tutorial.keys {
                Keycaps(keys, size: 16 * s).foregroundStyle(.white).padding(.top, 8 * s)
            }
            if let place = tutorial.progress, tutorial.steps > 1 {
                HStack(spacing: 0) {
                    ForEach(0..<tutorial.steps, id: \.self) { i in
                        TourDot(opacity: i == place ? 1 : i < place ? 0.5 : 0.2, action: i < place ? onDot.map { go in { go(i) } } : nil)
                    }
                }
                .padding(.top, 1 * s)
            }
            if let download = tutorial.download {
                VStack(spacing: 4 * s) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15))
                            Capsule().fill(.white.opacity(0.85)).frame(width: max(geo.size.width * download, 3 * s))
                        }
                    }
                    .frame(width: 120 * s, height: 3 * s)
                    .animation(.easeOut(duration: 0.4), value: download)
                    Text("Downloading my voice · \(Int(download * 100))%").font(.notch(size: 10.5)).opacity(0.45)
                        .monospacedDigit()
                }
                .padding(.top, 8 * s)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 28 * s)
        .padding(.top, top + 6 * s)
        .foregroundStyle(.white)
        .id(tutorial.title + tutorial.detail)
        .transition(.opacity)
        .onAppear {
            guard tutorial.wordmark else { return }
            guard !Render.isRendering else { rise = 1; shown = true; return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.15)) { rise = 1 }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82).delay(0.35)) { shown = true }
        }
    }
}

/// One of the tour's progress dots. An earlier step's dot is a button back to it: it brightens
/// and grows a little under the pointer, with room around it so it's easy to hit.
struct TourDot: View {
    let opacity: Double
    var action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        let s = TextScale.factor
        let dot = Circle().fill(.white.opacity(hovering ? 1 : opacity))
            .frame(width: 4.5 * s, height: 4.5 * s)
            .scaleEffect(hovering ? 1.5 : 1)
            .frame(width: 9.5 * s, height: 14 * s)
            .contentShape(Rectangle())
        if let action {
            Button(action: action) { dot }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
                .help("Go back")
        } else {
            dot
        }
    }
}
