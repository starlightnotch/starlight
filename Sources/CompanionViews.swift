import AppKit
import Carbon.HIToolbox
import SwiftUI

// The Starlight window, in the notch's own language: black, white, quiet. Each page is a title
// and a few cards of rows; a row is a label and its control. Secondary actions are icon buttons.
// The sidebar and the buttons are Liquid Glass on macOS 26 and later; everything else stays
// still and black so the glass is the only thing with depth. No color but the check and cross.

// MARK: - Glass

extension View {
    /// Liquid Glass in `shape` on macOS 26 and later; before that, and in the offscreen renderer
    /// (which can't draw glass), the quiet fill it stands in for.
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, interactive: Bool = false, darken: Double = 0, fallback: Color = .white.opacity(0.07)) -> some View {
        if #available(macOS 26.0, *), !Render.isRendering {
            glassEffect(darken > 0 ? Glass.regular.tint(.black.opacity(darken)).interactive(interactive) : Glass.regular.interactive(interactive), in: shape)
        } else {
            background(shape.fill(fallback))
        }
    }

    /// Words scrolling under the top of the window soften away instead of meeting a hard edge.
    @ViewBuilder
    func softTopEdge() -> some View {
        if #available(macOS 26.0, *) { scrollEdgeEffectStyle(.soft, for: .top) } else { self }
    }
}

/// Glass presses itself on macOS 26 (it swells and catches the light); before it, a small spring.
struct GlassPressStyle: ButtonStyle {
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *), !Render.isRendering { configuration.label } else { PressableStyle().makeBody(configuration: configuration) }
    }
}

// MARK: - Building blocks

/// A card: near-black with a hairline edge.
struct GlassCard: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CardSurface())
    }
}

/// The one card surface every page uses: `surface-row` with a `hairline` edge.
struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 1))
    }
}

extension View {
    func glassCard(padding: CGFloat = 16) -> some View { modifier(GlassCard(padding: padding)) }
}

/// A vertical ScrollView, except in the offscreen renderer (ImageRenderer can't draw scroll views).
struct Scrolling<Content: View>: View {
    static var disabled: Bool { Render.isRendering }
    @ViewBuilder let content: Content
    var body: some View {
        if Self.disabled { VStack(spacing: 0) { content }.frame(maxHeight: .infinity, alignment: .top) } else { ScrollView { content }.softTopEdge() }
    }
}

/// A page: a title, an optional trailing accessory, and its cards.
struct Page<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 8) {
                Text(title).font(.system(size: 24, weight: .bold))
                Spacer()
                accessory
            }
            .frame(height: 32)
            content
        }
    }
}

extension Page where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        accessory = EmptyView()
        self.content = content()
    }
}

/// A card of rows, with hairlines between them.
struct Rows<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .modifier(CardSurface())
    }
}

/// A titled group of settings: a short heading over its card, and a note under it if one is
/// worth reading.
struct Section<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(text: title)
            Rows { content }.modifier(Highlighted(group: title))
            if let footer { Footnote(text: footer) }
        }
        .id(title)  // where a search result scrolls to
    }
}

/// One setting: its label, an optional quiet value or status, and the control.
struct Row<Control: View>: View {
    let title: String
    var value: String? = nil
    /// What it does, with examples: shown when the pointer rests on the row (HoverInfo).
    var info: [String] = []
    var last = false
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 12)
            if let value { Text(value).font(.system(size: 12).monospacedDigit()).opacity(0.5).lineLimit(1) }
            control
        }
        .frame(minHeight: 46)
        .contentShape(Rectangle())
        .modifier(HoverInfo(title: title, lines: info))
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) } }
    }
}

/// Resting the pointer on a setting for a moment shows a card that explains it, with examples.
/// The explanations live here, not as lines of text under every setting.
struct HoverInfo: ViewModifier {
    let title: String
    let lines: [String]
    var glyph: Glyph.Kind? = nil
    @State private var hovering = false
    @State private var shown = false

    /// When each card was last shown: one seen a moment ago waits for a longer, deliberate rest
    /// before it comes back, so passing over settings doesn't keep popping the same card.
    private static var lastShown: [String: Date] = [:]
    private static let firstDelay: TimeInterval = 0.8, againDelay: TimeInterval = 2.5, cooldown: TimeInterval = 90

    @ViewBuilder
    func body(content: Content) -> some View {
        if lines.isEmpty {
            content
        } else {
            content
                .onHover { inside in
                    hovering = inside
                    if inside {
                        let recent = Self.lastShown[title].map { Date().timeIntervalSince($0) < Self.cooldown } ?? false
                        DispatchQueue.main.asyncAfter(deadline: .now() + (recent ? Self.againDelay : Self.firstDelay)) {
                            guard hovering else { return }
                            Self.lastShown[title] = Date()
                            shown = true
                        }
                    } else {
                        shown = false
                    }
                }
                .popover(isPresented: $shown, arrowEdge: .bottom) { InfoCard(title: title, glyph: glyph, lines: lines) }
        }
    }
}

/// The card HoverInfo shows: the setting's name, then a few plain lines.
struct InfoCard: View {
    let title: String
    var glyph: Glyph.Kind? = nil
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let glyph { Glyph(kind: glyph, size: 14) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle().fill(.white.opacity(0.5)).frame(width: 3.5, height: 3.5).alignmentGuide(.firstTextBaseline) { $0.height + 2.5 }
                        Text(line).font(.system(size: 12)).opacity(0.75).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}

/// A switch the size of the system's small one, in black and white (the system's tints it
/// with the accent color, or a muted grey that looks disabled): on is white with a black knob,
/// off is quiet with a white one. The knob springs across and stretches while it's held.
struct Switch: View {
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Button { isOn.toggle() } label: { Color.clear.frame(width: 32, height: 19) }
            .buttonStyle(Track(isOn: isOn, hovering: hovering))
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isOn)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .accessibilityRepresentation { Toggle("", isOn: $isOn) }
    }

    private struct Track: ButtonStyle {
        let isOn: Bool
        let hovering: Bool
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(Capsule().fill(isOn ? Color.white.opacity(hovering ? 1 : 0.92) : Color.white.opacity(hovering ? 0.2 : 0.14)))
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Color.black : Color.white)
                        .frame(width: configuration.isPressed ? 19 : 15, height: 15)
                        .shadow(color: .black.opacity(isOn ? 0 : 0.3), radius: 1, y: 0.5)
                        .padding(2)
                }
                .contentShape(Capsule())
                .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
        }
    }
}

/// A round glass button for secondary actions.
struct IconButton: View {
    let icon: Glyph.Kind
    let label: String
    var size: CGFloat = 30
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Glyph(kind: icon, size: size * 0.5, active: hovering)
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.7))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .glass(Circle(), interactive: true)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel(label)
    }
}

/// A glass pill with words; `prominent` is white on black, for the one main action on a page.
struct GlassButton: View {
    let title: String
    var icon: Glyph.Kind? = nil
    var prominent = false
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        if prominent {
            label.foregroundStyle(.black)
                .background(Capsule().fill(Color.white.opacity(hovering ? 1 : 0.92)))
                .contentShape(Capsule())
                .wrapped(action: action, hovering: $hovering)
        } else {
            label.foregroundStyle(destructive ? .white.opacity(hovering ? 0.85 : 0.6) : .white)
                .contentShape(Capsule())
                .wrapped(action: action, hovering: $hovering)
                .glass(Capsule(), interactive: true)
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            if let icon { Glyph(kind: icon, size: 13, active: hovering) }
            Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 13)
        .frame(height: 28)
    }
}

private extension View {
    func wrapped(action: @escaping () -> Void, hovering: Binding<Bool>) -> some View {
        Button(action: action) { self }
            .buttonStyle(GlassPressStyle())
            .onHover { hovering.wrappedValue = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering.wrappedValue)
    }
}

/// A capsule text field.
struct Field: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var onSubmit: () -> Void = {}

    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.plain).font(.system(size: 13))
        .padding(.horizontal, 12).frame(height: 30)
        .background(Capsule().fill(.white.opacity(0.07)))
        .onSubmit(onSubmit)
    }
}

/// The heading over a group: one style for every group on every page.
struct Caption: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 13, weight: .semibold)).opacity(0.55).padding(.leading, 4) }
}

/// A note under a card, small but readable (never below `ink-tertiary`).
struct Footnote: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12)).opacity(0.5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

/// A page arriving: it rises a little into place as it fades in. The page it replaces is gone at
/// once (the page change itself isn't animated), so two pages never show at the same time.
private struct Entrance: ViewModifier {
    @State private var shown = Render.isRendering
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .onAppear { withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { shown = true } }
    }
}

// MARK: - Window content

struct CompanionView: View {
    @ObservedObject var state: CompanionState
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: NotesStore
    @State private var query = ""
    @FocusState private var searching: Bool
    private static let top = "page-top"

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 232).frame(maxHeight: .infinity, alignment: .top)
            ScrollViewReader { proxy in
                Scrolling {
                    Color.clear.frame(height: 0).id(Self.top)
                    // Centred, so a wide window keeps even margins instead of an empty strip on
                    // the right.
                    detail.padding(.horizontal, 36).padding(.top, 48).padding(.bottom, 36)
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .modifier(Entrance())
                        .id(state.page)
                }
                .environment(\.scrollToID) { id in
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .top) }
                }
                // Every page opens at its top, not where the last one was scrolled to.
                .onChange(of: state.page) { _, _ in proxy.scrollTo(Self.top, anchor: .top) }
                .onChange(of: state.scrollTarget) { _, target in
                    guard let target else { return }
                    // After the page (and its "More settings") are laid out.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(target, anchor: .top) }
                        state.scrollTarget = nil
                    }
                }
            }
        }
        .ignoresSafeArea()
        .environmentObject(state)
        .environment(\.settingsHighlight, state.highlight)
        .foregroundStyle(.white)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    // MARK: Sidebar

    @Namespace private var selection

    /// Flush with the window's left edge, on the same black, with nothing drawn around it: the
    /// selection is the only shape in it.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                AppMark().frame(width: 18, height: 15)
                Text("Starlight").font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.top, 46)
            .padding(.bottom, 12)

            searchField.padding(.horizontal, 4).padding(.bottom, 10)

            if query.isEmpty {
                row("History", icon: .history, pages: [.history])
                if !Edition.isOpenSource {
                    row("Meeting transcripts", trailing: store.sessions.isEmpty ? nil : "\(store.sessions.count)", icon: .note, pages: [.meetings],
                        selected: { if case .session = state.page { return true }; return false }())
                    row("Tasks", trailing: !AppSettings.shared.tasksEnabled || TaskStore.shared.open.isEmpty ? nil : "\(TaskStore.shared.open.count)", icon: .todo, pages: [.tasks])
                    row("Memory", icon: .memory, pages: [.memory])
                }

                group("Settings")
                row("Notch", icon: .screen, pages: [.general, .motion])
                row("Dictation", icon: .voice, pages: [.dictation])
                if !Edition.isOpenSource { row("Meetings", icon: .noteLive, pages: [.notes]) }
                row("Live mode", locked: !settings.hasAnswerKey, icon: .agent, pages: [.live])
                row("AI provider", icon: .key, pages: [.ai, .extensions])
                row("Shortcuts", icon: .keycap, pages: [.shortcuts])
                row("Privacy", icon: .shield, pages: [.permissions])
                row("About", icon: .spark, pages: [.about])
            } else {
                results
            }
            Spacer(minLength: 0)
            if StarlightAccount.isAvailable || Edition.isOpenSource { AccountCard().padding(.bottom, 12) }
        }
        .padding(.horizontal, 10)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Glyph(kind: .search, size: 13).opacity(0.45)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($searching)
                .onSubmit { if let first = SettingsIndex.search(query).first { open(first) } }
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button { query = "" } label: { Glyph(kind: .close, size: 10).opacity(0.5) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(searching ? 0.1 : 0.06)))
        .animation(.easeOut(duration: 0.15), value: searching)
    }

    /// What matches the search: each setting with the page it's on. Return opens the first.
    @ViewBuilder private var results: some View {
        let found = SettingsIndex.search(query)
        if found.isEmpty {
            Text("Nothing called that").font(.system(size: 12.5)).opacity(0.5).padding(.horizontal, 10).padding(.top, 6)
        } else {
            ForEach(found.prefix(14)) { entry in
                SearchResultRow(entry: entry) { open(entry) }
            }
        }
    }

    private func open(_ entry: SettingsIndex.Entry) {
        state.go(to: entry)
        query = ""
        searching = false
    }

    private func group(_ title: String) -> some View {
        Text(title).font(.system(size: 11.5, weight: .semibold)).opacity(0.4)
            .padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 4)
    }

    private func row(_ title: String, trailing: String? = nil, locked: Bool = false, icon: Glyph.Kind, pages: [CompanionState.Page], selected: Bool = false) -> some View {
        SidebarRow(title: title, trailing: trailing, locked: locked, icon: icon, selected: selected || pages.contains(state.page), namespace: selection) {
            state.page = pages[0]
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch state.page {
        case .meetings: MeetingsPage(store: store, state: state)
        case .session(let id):
            if let session = store.session(id) {
                SessionDetail(session: session, state: state)
            } else {
                Text("Deleted").opacity(0.4)
            }
        case .history: HistoryPage(history: .shared)
        case .dictation: DictationSettings(settings: settings)
        case .notes: MeetingSettings(settings: settings)
        case .live: LiveSettings(settings: settings)
        case .general, .motion: GeneralSettings(settings: settings)
        case .ai, .extensions: AIProviderPage(settings: settings)
        case .shortcuts: ShortcutSettings(settings: settings)
        case .permissions: PrivacyPage(settings: settings)
        case .account, .usage: AIProviderPage(settings: settings)  // what was Account is with Pro, on AI provider
        case .memory: MemoryPage(memory: .shared)
        case .tasks: TasksPage(store: .shared)
        case .about: AboutPage()
        }
    }
}

/// A search result: the setting, and the page it's on.
private struct SearchResultRow: View {
    let entry: SettingsIndex.Entry
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(entry.pageName).font(.system(size: 11)).opacity(0.45)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A sidebar row. The selection highlight slides between rows; other rows brighten on hover.
struct SidebarRow: View {
    let title: String
    var trailing: String? = nil
    var locked = false
    let icon: Glyph.Kind
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Glyph(kind: icon, size: 16, active: hovering)
                Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if let trailing { Text(trailing).font(.system(size: 10.5).monospacedDigit()).opacity(0.35) }
                if locked { LockMark() }
            }
            .foregroundStyle(selected || hovering ? .white : .white.opacity(0.6))
            .padding(.horizontal, 10).frame(height: 30)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.1))
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.04))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selected)
    }
}

/// Starlight's mark: the app icon's five voice bars (5, 10.5, 15, 10.5, 5 on a 24 grid, 4 apart),
/// at any size. `rise` (0…1) grows the bars up from the middle, one after another, for the
/// launch; `swell` lifts them like a breath.
struct AppMark: View {
    var rise: CGFloat = 1
    var swell: CGFloat = 0
    private static let heights: [CGFloat] = [5, 10.5, 15, 10.5, 5]

    var body: some View {
        GeometryReader { geo in
            let unit = min(geo.size.width / 18, geo.size.height / 15)
            HStack(spacing: 2 * unit) {
                ForEach(0..<5, id: \.self) { i in
                    // Each bar starts a little after the one before it.
                    let own = min(max(rise * 1.6 - CGFloat(i) * 0.15, 0), 1)
                    let lift = 1 + swell * (i == 2 ? 0.12 : i == 1 || i == 3 ? 0.28 : 0.45)
                    Capsule().fill(.white)
                        .frame(width: 2 * unit, height: max(2 * unit, Self.heights[i] * unit * own * lift))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(18 / 15, contentMode: .fit)
    }
}

// MARK: - Notes session

/// A meeting, read like a deposition: who spoke, in capitals, and what they said, top to
/// bottom; Starlight's answers in place as STARLIGHT. Copy at the top right takes it all. Nothing else.
struct SessionDetail: View {
    let session: NoteSession
    @ObservedObject var state: CompanionState
    @State private var confirmDelete = false

    var body: some View {
        Page(title: RelativeDate.string(session.started)) {
            HStack(spacing: 6) {
                IconButton(icon: .trash, label: "Delete") { confirmDelete = true }
                CopyTranscriptButton(alwaysLabelled: true) { session.transcriptText }
            }
        } content: {
            Text(session.lengthText)
                .font(.system(size: 12).monospacedDigit()).opacity(0.4)
                .padding(.top, -10)
            DepositionTranscript(session: session, focus: state.focus?.sessionID == session.id ? state.focus?.time : nil)
                .padding(.top, 6)
        }
        .textSelection(.enabled)
        .animation(.easeOut(duration: 0.25), value: session)
        .confirmationDialog("Delete these notes?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                NotesStore.shared.delete(session.id)
                state.page = NotesStore.shared.sessions.first.map { .session($0.id) } ?? .meetings
            }
        }
    }
}

/// Speaker on the left, in capitals, what they said on the right. Right-click a name to rename
/// that person everywhere in the meeting.
struct DepositionTranscript: View {
    let session: NoteSession
    /// Seconds in: that turn is highlighted and scrolled to.
    var focus: TimeInterval? = nil
    @Environment(\.scrollToID) private var scrollToID
    @State private var renaming: String?
    @State private var draft = ""

    static let nameWidth: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(session.log) { entry in
                switch entry {
                case .chapter:
                    EmptyView()
                case .turn(let turn):
                    row(name: session.speakerName(turn), text: Text(turn.text),
                        nameOpacity: turn.isMine ? 0.95 : 0.6, textOpacity: turn.isMine ? 1 : 0.85)
                        .padding(.vertical, focusedTurn == turn.id ? 8 : 0)
                        .padding(.horizontal, focusedTurn == turn.id ? 10 : 0)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(focusedTurn == turn.id ? 0.09 : 0)))
                        .id(turn.id)
                        .contextMenu {
                            if let id = turn.speakerID {
                                Button("Rename \(session.speakerName(turn))…") { draft = session.speakerNames?[id] ?? ""; renaming = id }
                            }
                        }
                case .notch(_, let text, _):
                    row(name: "Starlight", text: Text(Markdown.inline(text)), nameOpacity: 0.4, textOpacity: 0.6)
                }
            }
            if session.items.isEmpty {
                Text("Nothing was said.").font(.system(size: 13)).opacity(0.4)
            }
        }
        .onAppear { scrollToFocus() }
        .onChange(of: focus) { _, _ in scrollToFocus() }
        .alert("Name this speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draft)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    /// The turn that holds the focused moment.
    private var focusedTurn: UUID? {
        guard let focus else { return nil }
        return session.turns.last { $0.time <= focus + 0.5 }?.id ?? session.turns.first?.id
    }

    private func scrollToFocus() {
        guard let id = focusedTurn else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { scrollToID(id) }
    }

    private func row(name: String, text: Text, nameOpacity: Double, textOpacity: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(name.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .opacity(nameOpacity)
                .lineLimit(1)
                .frame(width: Self.nameWidth, alignment: .leading)
            text
                .font(.system(size: 14))
                .lineSpacing(4)
                .opacity(textOpacity)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func save() {
        guard let id = renaming, var latest = NotesStore.shared.session(session.id) else { return }
        var names = latest.speakerNames ?? [:]
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        names[id] = name.isEmpty ? nil : name
        latest.speakerNames = names.isEmpty ? nil : names
        NotesStore.shared.save(latest)
        renaming = nil
    }
}

// MARK: - Settings pages

/// Your voice, learned or not: learn it (or again) right here, or forget it. Learning it is Pro:
/// it's what tells you from everyone else in a meeting.
struct YourVoiceSection: View {
    @ObservedObject private var profile = VoiceProfile.shared
    @StateObject private var enrollment = VoiceEnrollment()
    @State private var learning = false

    var body: some View {
        Section(title: "Your voice") {
            if learning {
                VoiceEnrollView(enrollment: enrollment)
                    .padding(.vertical, 18)
                    .frame(height: 210)
                    .onChange(of: enrollment.phase) { _, phase in
                        if phase == .done { DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { learning = false } } }
                    }
            } else {
                // Learned and matched on your Mac: it needs no AI, so it's never locked.
                Row(title: profile.isLearned ? "Starlight knows your voice" : "Learn your voice",
                    value: profile.learned.map { "Learned \($0.formatted(date: .abbreviated, time: .omitted))" },
                    info: ["A minute of reading aloud, so meeting notes can tell you from the others in the room.",
                           "Learned and kept on your Mac."],
                    last: true) {
                    HStack(spacing: 8) {
                        if profile.isLearned { GlassButton(title: "Forget", destructive: true) { profile.forget() } }
                        GlassButton(title: profile.isLearned ? "Learn again" : "Learn", prominent: !profile.isLearned) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { learning = true }
                            enrollment.again()
                        }
                    }
                }
            }
        }
        .onDisappear { enrollment.cancel() }
    }
}

/// What holding a key on its own needs: Accessibility (to hear the key from any app), and for Fn,
/// macOS's own Fn action off, or letting go would also open the emoji picker.
struct AskKeyNote: View {
    let key: AskKey
    @State private var trusted = AXIsProcessTrusted()
    @State private var fnBusy = LoneKey.fnDoesSomethingElse

    var body: some View {
        Group {
            if case .lone(let lone) = key, !trusted {
                note("Holding \(lone.name) needs Accessibility, so Starlight can hear it from any app.", button: "Allow") {
                    AutoPaste.requestPermission()
                }
            } else if key == .lone(.fn), fnBusy {
                note("Fn also does something of its own when you let go. In Keyboard settings, set \u{201C}Press \u{1F310} key to\u{201D} to Do Nothing.",
                     button: "Open Keyboard") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
                }
            }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            trusted = AXIsProcessTrusted()
            fnBusy = LoneKey.fnDoesSomethingElse
        }
    }

    private func note(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Glyph(kind: .keycap, size: 16).opacity(0.7)
            Text(text).font(.system(size: 12.5)).opacity(0.6).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            GlassButton(title: button, action: action)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .modifier(CardSurface())
        .transition(.opacity)
    }
}

// MARK: - Meetings

/// Every saved meeting and Live session, newest first: when, how long, and how it began.
struct MeetingsPage: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var state: CompanionState
    @State private var shown = Paging.first

    var body: some View {
        Page(title: "Meeting transcripts") {
            HStack(spacing: 8) {
                IconButton(icon: .folder, label: "Notes folder") { NSWorkspace.shared.open(NotesStore.folder) }
            }
        } content: {
            if store.sessions.isEmpty {
                Empty(glyph: .note, title: "No meetings yet.",
                      keys: AppSettings.shared.notesShortcut.display, hint: "starts notes. Starlight also offers when a call starts.")
            } else {
                let sessions = store.sessions
                LazyRows {
                    ForEach(Array(sessions.prefix(shown).enumerated()), id: \.element.id) { index, session in
                        MeetingRow(session: session, last: index == min(shown, sessions.count) - 1) {
                            state.page = .session(session.id)
                        }
                    }
                    if sessions.count > shown { Paging.Loader { shown += Paging.step } }
                }
                .glassCard(padding: 0)
            }
        }
    }
}

/// Long lists come in pages: the first few dozen rows at once, the next as you scroll to the
/// end, so a page with hundreds of dictations opens as fast as one with ten.
enum Paging {
    static let first = 40
    static let step = 60

    /// At the end of what's shown: asks for more as soon as it scrolls into view.
    struct Loader: View {
        let more: () -> Void
        var body: some View { Color.clear.frame(height: 1).onAppear(perform: more) }
    }
}

/// A list that only builds the rows in view (except in the offscreen renderer, which can't draw
/// lazy stacks).
struct LazyRows<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        if Render.isRendering { VStack(spacing: 0) { content } } else { LazyVStack(spacing: 0) { content } }
    }
}

/// A list with nothing in it yet: its icon, and the keys that start it.
struct Empty: View {
    let glyph: Glyph.Kind
    let title: String
    let keys: String
    let hint: String

    var body: some View {
        VStack(spacing: 14) {
            GlyphWell(kind: glyph, size: 52, active: true)
            Text(title).font(.system(size: 17, weight: .semibold))
            HStack(spacing: 8) {
                Keycaps(keys)
                Text(hint).font(.system(size: 13)).opacity(0.55)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 48)
    }
}

private struct MeetingRow: View {
    let session: NoteSession
    let last: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(RelativeDate.string(session.started)).font(.system(size: 14.5, weight: .semibold))
                        if session.kind == "live" {
                            Text("Live").font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 7).frame(height: 18)
                                .background(Capsule().fill(.white.opacity(0.12)))
                        }
                    }
                    Text(session.items.first?.text ?? "Nothing was said")
                        .font(.system(size: 12.5)).opacity(0.45).lineLimit(1)
                }
                Spacer(minLength: 12)
                Text(session.lengthText).font(.system(size: 12.5, weight: .medium).monospacedDigit()).opacity(0.5)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.white.opacity(hovering ? 0.05 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.leading, 16) } }
    }
}

// MARK: - Dictation history

struct HistoryPage: View {
    @ObservedObject var history: DictationHistory
    @State private var query = ""
    @State private var confirmClear = false
    @State private var shown = Paging.first

    var body: some View {
        Page(title: "History") {
            HStack(spacing: 8) {
                if !history.entries.isEmpty {
                    IconButton(icon: .trash, label: "Clear all") { confirmClear = true }
                        .confirmationDialog("Clear all dictations?", isPresented: $confirmClear) {
                            Button("Clear all", role: .destructive) { history.clear() }
                        }
                }
            }
        } content: {
            if history.totalWords > 0 { DictationStats(history: history) }
            if history.entries.isEmpty {
                Empty(glyph: .voice, title: "Nothing dictated yet.", keys: AppSettings.shared.dictationShortcut.display, hint: "and talk.")
            } else {
                HStack(spacing: 8) {
                    Glyph(kind: .search, size: 14).opacity(0.4)
                    TextField("Search \(history.entries.count.formatted()) dictations", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                    if !query.isEmpty {
                        Button { query = "" } label: { Glyph(kind: .close, size: 12).opacity(0.4) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(.white.opacity(0.07)))
                .onChange(of: query) { _, _ in shown = Paging.first }

                // Worked out once per change, not once per row.
                let list = filtered
                if list.isEmpty {
                    Text("No dictation says that.").font(.system(size: 13)).opacity(0.5).padding(.horizontal, 4)
                } else {
                    LazyRows {
                        ForEach(Array(list.prefix(shown).enumerated()), id: \.element.id) { index, entry in
                            HistoryRow(entry: entry, last: index == min(shown, list.count) - 1) { id in
                                withAnimation(.easeOut(duration: 0.2)) { history.delete(id) }
                            }
                        }
                        if list.count > shown { Paging.Loader { shown += Paging.step } }
                    }
                    .padding(.horizontal, 16)
                    .modifier(CardSurface())
                }
            }
        }
    }

    private var filtered: [DictationHistory.Entry] {
        query.isEmpty ? history.entries : history.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }
}

struct HistoryRow: View {
    let entry: DictationHistory.Entry
    var last = false
    let onDelete: (UUID) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(entry.text).font(.system(size: 13.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            ZStack(alignment: .trailing) {
                Text(RelativeDate.string(entry.date)).font(.system(size: 11)).opacity(hovering ? 0 : 0.35)
                Button { onDelete(entry.id) } label: { Glyph(kind: .trash, size: 14, active: hovering) }
                    .buttonStyle(.plain).opacity(hovering ? 0.7 : 0)
                    .accessibilityLabel("Delete")
            }
            .fixedSize()
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) } }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Memory

struct MemoryPage: View {
    @ObservedObject var memory: MemoryStore
    @State private var draft = ""

    var body: some View {
        Page(title: "Memory") {
            HStack(spacing: 8) {
                Field(placeholder: "Remember…", text: $draft, onSubmit: add)
                IconButton(icon: .memory, label: "Add", action: add).disabled(draft.isEmpty).opacity(draft.isEmpty ? 0.4 : 1)
            }

            if !memory.facts.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(memory.facts.enumerated()), id: \.element.id) { index, fact in
                        FactRow(fact: fact, last: index == memory.facts.count - 1) { memory.delete(fact.id) }
                    }
                }
                .padding(.horizontal, 16)
                .modifier(CardSurface())
            }

            HStack(spacing: 16) {
                Label { Text("\(NotesStore.shared.sessions.count)") } icon: { Glyph(kind: .note, size: 13) }
                Label { Text("\(DictationHistory.shared.entries.count)") } icon: { Glyph(kind: .voice, size: 13) }
            }
            .font(.system(size: 12).monospacedDigit())
            .opacity(0.35)
            .accessibilityLabel("Also searches your notes and dictations")
        }
    }

    private func add() {
        memory.add(draft)
        draft = ""
    }
}

struct FactRow: View {
    let fact: MemoryStore.Fact
    var last = false
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(fact.text).font(.system(size: 13.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            ZStack(alignment: .trailing) {
                Text(RelativeDate.string(fact.date)).font(.system(size: 11)).opacity(hovering ? 0 : 0.35)
                Button(action: onDelete) { Glyph(kind: .trash, size: 14, active: hovering) }
                    .buttonStyle(.plain).opacity(hovering ? 0.7 : 0).accessibilityLabel("Forget")
            }
            .fixedSize()
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) } }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Extensions

/// Pick a sound; choosing one plays it.
struct SoundPicker: View {
    @Binding var selection: String
    let rising: Bool

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(Sounds.choices, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(width: 160)
        .onChange(of: selection) { _, new in Sounds.preview(new, rising: rising) }
    }
}

// MARK: - Meeting timeline

private struct ScrollToIDKey: EnvironmentKey {
    static let defaultValue: (AnyHashable) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Scrolls the Starlight window's page to a view with this id.
    var scrollToID: (AnyHashable) -> Void {
        get { self[ScrollToIDKey.self] }
        set { self[ScrollToIDKey.self] = newValue }
    }
}

/// The meeting in sections, like video chapters: a segmented bar across the top (each
/// segment as long as its section) and the sections as a vertical timeline. Hover the bar to
/// see a section's title; click either to jump to it in the transcript.
struct MeetingTimeline: View {
    let session: NoteSession
    let writing: Bool
    @Binding var selected: UUID?
    let onSelect: (NoteSession.Chapter) -> Void
    @State private var hovered: UUID?

    private var chapters: [NoteSession.Chapter] { session.chapters ?? [] }

    private func end(of index: Int) -> TimeInterval {
        index + 1 < chapters.count ? chapters[index + 1].start : max(session.duration, (chapters.last?.start ?? 0) + 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Caption(text: "Timeline")
                Spacer()
                if writing {
                    HStack(spacing: 6) {
                        Glyph(kind: .agent, size: 12, active: true)
                        ShimmerText(text: "Writing the timeline")
                    }
                } else if AppSettings.shared.hasAnswerKey {
                    Button { Task.detached { await Chapters.write(for: session.id) } } label: {
                        Glyph(kind: .rewind, size: 12).opacity(0.45)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Rewrite the timeline")
                }
            }

            if !chapters.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    segmentBar
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                            ChapterRow(chapter: chapter, last: index == chapters.count - 1,
                                       selected: selected == chapter.id) { onSelect(chapter) }
                        }
                    }
                }
                .glassCard(padding: 18)
            }
        }
    }

    /// One segment per section, as wide as its share of the meeting; the hovered or chosen one
    /// lights up, and its title and time show underneath.
    private var segmentBar: some View {
        let shown = chapters.first { $0.id == (hovered ?? selected) } ?? chapters[0]
        let focus: UUID? = shown.id
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let gap: CGFloat = 3
                let total = max(session.duration, end(of: chapters.count - 1))
                let usable = geometry.size.width - gap * CGFloat(chapters.count - 1)
                HStack(spacing: gap) {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        let width = max(usable * CGFloat((end(of: index) - chapter.start) / total), 6)
                        Capsule()
                            .fill(.white.opacity(chapter.id == focus ? 0.95 : 0.22))
                            .frame(width: width, height: chapter.id == focus ? 7 : 5)
                            .frame(height: 9)
                            .contentShape(Rectangle())
                            .onHover { hovered = $0 ? chapter.id : (hovered == chapter.id ? nil : hovered) }
                            .onTapGesture { onSelect(chapter) }
                    }
                }
                .animation(.easeOut(duration: 0.15), value: focus)
            }
            .frame(height: 9)
            HStack(spacing: 8) {
                Text(NotesController.timestamp(shown.start)).font(.system(size: 11).monospacedDigit()).opacity(0.45)
                Text(shown.title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(NotesController.timestamp(session.duration)).font(.system(size: 11).monospacedDigit()).opacity(0.3)
            }
            .animation(nil, value: focus)
        }
    }
}

/// A section on the vertical timeline: its time, a node on the rail, the title and summary.
private struct ChapterRow: View {
    let chapter: NoteSession.Chapter
    let last: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(NotesController.timestamp(chapter.start))
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .opacity(selected || hovering ? 0.9 : 0.45)
                .frame(width: 40, alignment: .trailing)
                .padding(.top, 1)
            ZStack(alignment: .top) {
                if !last {
                    Rectangle().fill(.white.opacity(0.12)).frame(width: 1).padding(.top, 12)
                }
                Circle()
                    .fill(selected ? Color.white : Color.black)
                    .overlay(Circle().strokeBorder(.white.opacity(selected || hovering ? 0.95 : 0.5), lineWidth: 1.2))
                    .frame(width: 9, height: 9)
                    .padding(.top, 4)
            }
            .frame(width: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(chapter.title).font(.system(size: 13.5, weight: .semibold))
                if !chapter.summary.isEmpty {
                    Text(chapter.summary).font(.system(size: 12.5)).opacity(0.6).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, last ? 0 : 18)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

/// The whole conversation: section dividers where each section starts, each speaker's name
/// when the turn changes, then their lines.
/// The whole meeting as it happened: each person's turn as one paragraph, the sections it
/// moved through, and what Starlight added, in place. Selectable; copy takes it all.
struct ConversationLog: View {
    let session: NoteSession
    let selected: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let log = session.log
            ForEach(Array(log.enumerated()), id: \.element.id) { index, entry in
                switch entry {
                case .chapter(let chapter):
                    HStack(spacing: 10) {
                        Text(NotesController.timestamp(chapter.start)).font(.system(size: 11, weight: .medium).monospacedDigit()).opacity(0.45)
                        Text(chapter.title).font(.system(size: 12.5, weight: .semibold))
                        Rectangle().fill(.white.opacity(selected == chapter.id ? 0.5 : 0.1)).frame(height: 1)
                    }
                    .padding(.top, 6)
                    .id(chapter.id)
                case .turn(let turn):
                    // The name once per run of turns; after that just the time.
                    let repeats: Bool = {
                        guard index > 0, case .turn(let previous) = log[index - 1] else { return false }
                        return previous.isMine == turn.isMine && previous.speakerID == turn.speakerID
                    }()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            if !repeats {
                                Text(session.speakerName(turn)).font(.system(size: 11.5, weight: .semibold))
                                    .opacity(turn.isMine ? 0.95 : 0.6)
                            }
                            Text(NotesController.timestamp(turn.time)).font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                .opacity(0.3)
                        }
                        Text(turn.text)
                            .font(.system(size: 13.5))
                            .lineSpacing(3)
                            .opacity(turn.isMine ? 1 : 0.78)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .notch(let time, let text, _):
                    HStack(alignment: .top, spacing: 10) {
                        Glyph(kind: .agent, size: 13).opacity(0.7).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("Starlight").font(.system(size: 11, weight: .semibold)).opacity(0.5)
                                Text(NotesController.timestamp(time)).font(.system(size: 10.5, weight: .medium).monospacedDigit()).opacity(0.3)
                            }
                            RichReply(text: text)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
                }
            }
            if session.items.isEmpty {
                Text("Nothing was said.").font(.system(size: 12.5)).opacity(0.4)
            }
        }
    }
}

/// The meeting in one friendly line, like the notch shows when it ends, and who did the talking.
struct MeetingStatsCard: View {
    let session: NoteSession

    var body: some View {
        let ending = session.ending
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ending.title).font(.system(size: 24, weight: .semibold))
                Text(ending.detail).font(.system(size: 13)).opacity(0.55)
            }
            if let share = session.stats.yourShare { TalkShareBar(share: share) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

struct MeetingStat: View {
    let value: String
    let label: String
    var size: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 10.5, weight: .medium)).opacity(0.4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// How the talking was shared: you in white, everyone else in grey, by words spoken.
struct TalkShareBar: View {
    let share: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Capsule().fill(.white).frame(width: max(geo.size.width * share - 1, 3))
                    Capsule().fill(.white.opacity(0.22))
                }
            }
            .frame(height: 5)
            HStack {
                Text("You \(Int((share * 100).rounded()))%").font(.system(size: 11, weight: .semibold).monospacedDigit())
                Spacer()
                Text("Them \(100 - Int((share * 100).rounded()))%").font(.system(size: 11, weight: .medium).monospacedDigit()).opacity(0.5)
            }
        }
    }
}

/// The other people in the meeting, nameable: type a name and it replaces "Speaker 2"
/// everywhere in this session.
private struct PeopleCard: View {
    let session: NoteSession
    @State private var drafts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Caption(text: "People")
            Rows {
                ForEach(Array(session.speakerIDs.enumerated()), id: \.element) { index, id in
                    Row(title: "Speaker \(id)", last: index == session.speakerIDs.count - 1) {
                        Field(placeholder: "Name", text: Binding(
                            get: { drafts[id] ?? session.speakerNames?[id] ?? "" },
                            set: { drafts[id] = $0 }), onSubmit: { save(id) })
                            .frame(width: 200)
                            .onDisappear { save(id) }
                    }
                }
            }
        }
    }

    private func save(_ id: String) {
        guard let draft = drafts[id], var latest = NotesStore.shared.session(session.id) else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = latest.speakerNames ?? [:]
        names[id] = name.isEmpty ? nil : name
        latest.speakerNames = names.isEmpty ? nil : names
        NotesStore.shared.save(latest)
        drafts[id] = nil
    }
}

/// The few settings an extension needs, under its row.
struct ExtensionSetup: View {
    let id: String
    @ObservedObject private var settings = AppSettings.shared
    @State private var accessibility = AXIsProcessTrusted()
    @State private var screenRecording = CGPreflightScreenCaptureAccess()

    var body: some View {
        switch id {
        case "screen":
            VStack(alignment: .leading, spacing: 8) {
                permission("Accessibility", granted: accessibility) {
                    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                }
                permission("Screen Recording (apps that draw their own text)", granted: screenRecording) {
                    _ = CGRequestScreenCaptureAccess()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                accessibility = AXIsProcessTrusted()
                screenRecording = CGPreflightScreenCaptureAccess()
            }
        case "computer":
            HStack {
                Text("Ask before").font(.system(size: 12))
                Spacer()
                Picker("", selection: $settings.computerAsks) {
                    Text("Changes only").tag(AppSettings.ComputerAsks.changes)
                    Text("Every command").tag(AppSettings.ComputerAsks.always)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
        default:
            EmptyView()
        }
    }

    private func permission(_ name: String, granted: Bool, ask: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Circle().fill(granted ? Color.white : Color.clear)
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                .frame(width: 8, height: 8)
            Text(name).font(.system(size: 12)).opacity(granted ? 0.8 : 0.6)
            Spacer()
            if !granted { GlassButton(title: "Allow", action: ask) }
        }
    }
}


// MARK: - Account card

/// The bottom of the sidebar. Signed out, or without Pro: Upgrade to Pro, which signs in first
/// and opens the plans. Signed in: your picture and name, and Manage account, which opens your
/// account on the website in your browser (right-click to sign out).
struct AccountCard: View {
    @ObservedObject private var account = StarlightAccount.shared
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 14) {
            if !(account.plan?.active ?? false) { upgradeCard }
            if account.isSignedIn { profile }
        }
    }

    private var upgradeCard: some View {
        Button { account.upgrade() } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Glyph(kind: .spark, size: 15)
                    Text("Starlight Pro").font(.system(size: 13.5, weight: .semibold))
                }
                Text("Enhanced AI, built in.").font(.system(size: 12)).opacity(0.6)
                Text(account.signingIn ? "Signing in\u{2026}" : "Upgrade to Pro")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 30)
                    .background(Capsule().fill(.white.opacity(hovering ? 1 : 0.92)))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(hovering ? 0.11 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .disabled(account.signingIn)
    }

    private var profile: some View {
        HStack(spacing: 10) {
            AsyncImage(url: account.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Text(initial).font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.14))
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name ?? account.email ?? "Signed in").font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Button("Manage account") { account.openAccountSettings() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5)).opacity(0.6)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .contextMenu { Button("Sign out") { account.signOut() } }
    }

    private var initial: String {
        String((account.name ?? account.email ?? "S").prefix(1)).uppercased()
    }
}

/// The lock on what needs an AI provider while there isn't one.
struct LockMark: View {
    var body: some View {
        Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).opacity(0.55)
            .help("Needs an AI provider")
    }
}

/// What needs AI, while there's no AI provider: greyed out and out of reach, with a lock card
/// over it to set one up (Pro, or your own key or a model in Ollama).
struct LockedForAI: ViewModifier {
    let locked: Bool
    /// Centered over a short area; near the top of a long page, where it's seen.
    var alignment: Alignment = .center
    /// The card shows the feature at work (Live mode), to want it, not just to unlock it.
    var showcase = false

    func body(content: Content) -> some View {
        content
            .disabled(locked)
            .opacity(locked ? 0.22 : 1)
            .overlay(alignment: alignment) {
                if locked { AILockCard(showcase: showcase).padding(.top, alignment == .top ? 24 : 0).transition(.opacity) }
            }
            .animation(.easeOut(duration: 0.2), value: locked)
    }
}

/// The lock card: set up AI to use this, with Pro or your own provider.
struct AILockCard: View {
    var showcase = false
    @EnvironmentObject private var state: CompanionState
    @ObservedObject private var account = StarlightAccount.shared

    var body: some View {
        VStack(spacing: 12) {
            if showcase {
                LiveDemo().frame(width: 440).padding(.bottom, 4)
                Text("Ask anything. Get it done.").font(.system(size: 18, weight: .bold))
                Text("Talk to your Mac, ask it questions, or tell it to take action.").font(.system(size: 13)).opacity(0.6)
                    .padding(.bottom, 4)
            } else {
                Image(systemName: "lock.fill").font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.white.opacity(0.1)))
                Text("Set up AI to use this").font(.system(size: 14, weight: .semibold))
            }
            HStack(spacing: 8) {
                if StarlightAccount.isAvailable {
                    GlassButton(title: account.signingIn ? "Signing in\u{2026}" : "Upgrade to Pro", prominent: true) { account.upgrade() }
                }
                GlassButton(title: "Connect your AI", prominent: !StarlightAccount.isAvailable) { state.page = .ai }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }
}
