import AppKit
import SwiftUI

/// The live transcript: click the notch during a notes session and a black panel drops below it
/// with the whole conversation as it happens. Them on the left, you on the right, the agent's
/// replies between. It follows the newest line unless you scroll up to read back.
///
/// Drag it by its top bar to move it; it reopens where you left it. Double-click the top bar to
/// snap it back under the notch. Double-click any line to have the agent answer it.
///
/// The panel never takes keyboard focus (you keep typing where you were), floats above other
/// windows, and is left out of screen sharing like the rest of Starlight.
final class TranscriptOverlay {
    static let shared = TranscriptOverlay()
    private var panel: NSPanel?
    private weak var model: NotchModel?
    private var screen: NSScreen?
    private var moveObserver: Any?
    private static let originKey = "transcriptOrigin"
    private static let sizeKey = "transcriptSize"
    static let minSize = NSSize(width: 380, height: 260)

    var isVisible: Bool { panel?.isVisible == true && model?.transcriptOpen != false }  // not while fading out

    func toggle(model: NotchModel, below notchScreen: NSScreen, onAnswer: @escaping (NoteItem, Bool?) -> Void) {
        if isVisible { hide() } else { show(model: model, on: notchScreen, onAnswer: onAnswer) }
    }

    func show(model: NotchModel, on screen: NSScreen, onAnswer: @escaping (NoteItem, Bool?) -> Void) {
        self.model = model
        self.screen = screen
        if panel == nil { panel = makePanel(model: model, onAnswer: onAnswer) }
        guard let panel else { return }
        let size = Self.size(on: screen)
        var frame = Self.homeFrame(size: size, model: model, on: screen)
        // Where you last left it, if that's still on a screen.
        // Its top bar (where you drag and close it) has to be fully on a screen, not a sliver.
        if let saved = UserDefaults.standard.string(forKey: Self.originKey).map(NSPointFromString) {
            let moved = NSRect(origin: saved, size: size)
            let header = NSRect(x: moved.minX, y: moved.maxY - 44, width: moved.width, height: 44)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(header) }) { frame = moved }
        }
        visibility += 1
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        withAnimation(model.scaled(Motion.close)) { model.transcriptOpen = true }
        CaptureVisibility.apply()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    /// Bumped by each show and hide: a fade-out that ends after a new show leaves it up.
    private var visibility = 0

    func hide() {
        guard let panel, panel.isVisible else { return }
        if let model { withAnimation(model.scaled(Motion.close)) { model.transcriptOpen = false } }
        visibility += 1
        let ticket = visibility
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard self?.visibility == ticket else { return }
            panel.orderOut(nil)
        })
    }

    /// Back under the notch (double-click the top bar).
    func snapHome() {
        guard let panel, let model, let screen else { return }
        UserDefaults.standard.removeObject(forKey: Self.originKey)
        let home = Self.homeFrame(size: panel.frame.size, model: model, on: screen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(home, display: true)
        }
    }

    /// The size you last dragged it to, or 600 wide and up to 70% of the screen tall.
    private static func size(on screen: NSScreen) -> NSSize {
        if let saved = UserDefaults.standard.string(forKey: sizeKey).map(NSSizeFromString),
           saved.width >= minSize.width, saved.height >= minSize.height {
            return NSSize(width: min(saved.width, screen.visibleFrame.width), height: min(saved.height, screen.visibleFrame.height))
        }
        return NSSize(width: 600, height: min(screen.visibleFrame.height * 0.7, 720))
    }

    /// Resizing from the corner grip keeps the top edge in place.
    func resize(by delta: CGSize) {
        guard let panel else { return }
        var frame = panel.frame
        let width = max(frame.width + delta.width, Self.minSize.width)
        let height = max(frame.height + delta.height, Self.minSize.height)
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: width, height: height)
        panel.setFrame(frame, display: true)
        UserDefaults.standard.set(NSStringFromSize(frame.size), forKey: Self.sizeKey)
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
    }

    private static func homeFrame(size: NSSize, model: NotchModel, on screen: NSScreen) -> NSRect {
        let top = screen.frame.maxY - model.notchSize.height - 12
        return NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }

    private func makePanel(model: NotchModel, onAnswer: @escaping (NoteItem, Bool?) -> Void) -> NSPanel {
        let panel = TranscriptPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: TranscriptView(model: model, onClose: { [weak self] in self?.hide() },
                                                          onHome: { [weak self] in self?.snapHome() }, onAnswer: onAnswer,
                                                          onResize: { [weak self] in self?.resize(by: $0) },
                                                          onAsk: { NotesController.ask?($0) }))
        host.wantsLayer = true
        panel.contentView = host
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { _ in
            UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
        }
        return panel
    }
}

/// One line of the live transcript: something said, or the agent's reply.
private enum TranscriptLine: Identifiable {
    case said(NoteItem)
    case agent(AgentReply)

    var id: UUID {
        switch self {
        case .said(let item): item.id
        case .agent(let reply): reply.id
        }
    }

    var time: TimeInterval {
        switch self {
        case .said(let item): item.time
        case .agent(let reply): reply.time
        }
    }
}

struct TranscriptView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject private var settings = AppSettings.shared
    /// Renaming one of the other speakers: their number, and the name being typed.
    @State private var renaming: String?
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool
    @State private var following = true
    @State private var unseen = false
    private static let bottom = "bottom"
    var onClose: () -> Void
    var onHome: () -> Void = {}
    /// A line to answer: nil = decide, true = in depth, false = fast.
    var onAnswer: (NoteItem, Bool?) -> Void = { _, _ in }
    var onResize: (CGSize) -> Void = { _ in }
    /// Typed into the ask bar at the bottom.
    var onAsk: (String) -> Void = { _ in }

    private var showsCaption: Bool { settings.captionsTranscript && !model.liveCaption.isEmpty }

    /// Changes whenever something new appears or grows, so the view can follow it.
    private var contentSignature: Int {
        var hasher = Hasher()
        hasher.combine(model.noteItems.count)
        hasher.combine(model.agentReplies.count)
        // Any reply still being written (not only the last one), and pictures arriving.
        hasher.combine(model.agentReplies.reduce(0) { $0 + $1.text.count })
        hasher.combine(model.agentReplies.filter { $0.image != nil }.count)
        hasher.combine(model.liveCaption.count)
        return hasher.finalize()
    }

    /// Smoothly to the end, after this update's layout (so the new line is measured first),
    /// and once more a moment later for anything that settled late (a picture, a wrapped line).
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard following else { return }
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
    }

    private var lines: [TranscriptLine] {
        (model.noteItems.map(TranscriptLine.said) + model.agentReplies.map(TranscriptLine.agent))
            .sorted { $0.time < $1.time }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if lines.isEmpty {
                VStack(spacing: 10) {
                    Glyph(kind: .voice, size: 22, active: model.notes == .listening).opacity(0.5)
                    ShimmerText(text: "Listening")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if Render.isRendering {
                // ImageRenderer can't draw scroll views.
                VStack(spacing: 10) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        row(line, previous: index > 0 ? lines[index - 1] : nil)
                    }
                    if showsCaption { CaptionBubble(text: model.liveCaption) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 10) {
                            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                                row(line, previous: index > 0 ? lines[index - 1] : nil).id(line.id)
                            }
                            if showsCaption { CaptionBubble(text: model.liveCaption).id("caption") }
                            Color.clear.frame(height: 1).id(Self.bottom)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 30)  // room above the panel's edge and the resize corner
                    }
                    .modifier(FollowsBottom(following: $following))
                    .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                    // Anything new (a line, streamed words, the live caption): follow it while
                    // you're at the bottom; if you've scrolled up to read, stay put.
                    .onChange(of: contentSignature) { _, _ in
                        guard following else { unseen = true; return }
                        scrollToBottom(proxy)
                    }
                    // You talking, or the agent starting a reply: always back to the bottom,
                    // even if you'd scrolled up.
                    .onChange(of: model.agentReplies.count) { old, new in
                        guard new > old else { return }
                        following = true
                        scrollToBottom(proxy)
                    }
                    .onChange(of: model.noteItems.count) { old, new in
                        guard new > old, model.noteItems.last?.isMine == true else { return }
                        following = true
                        scrollToBottom(proxy)
                    }
                    .overlay(alignment: .bottom) {
                        if unseen && !following {
                            Button {
                                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                                following = true
                                unseen = false
                            } label: {
                                Text("Latest").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.black)
                                    .padding(.horizontal, 12).frame(height: 24)
                                    .background(Capsule().fill(.white))
                            }
                            .buttonStyle(PressableStyle())
                            .padding(.bottom, 12)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                        }
                    }
                    .onChange(of: following) { _, now in if now { unseen = false } }
                    .animation(.easeOut(duration: 0.18), value: unseen && !following)
                }
            }
            if model.notes == .listening {
                AskBar(onAsk: { text in
                    following = true
                    onAsk(text)
                })
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 4)
            }
        }
        .foregroundStyle(.white)
        .overlay(alignment: .bottomTrailing) { ResizeGrip(onResize: onResize) }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .preferredColorScheme(.dark)
    }

    private func startRenaming(_ id: String) {
        nameDraft = model.speakerNames[id] ?? ""
        renaming = id
        // The panel takes keystrokes for the name field (still without activating Starlight).
        NSApp.windows.first { $0 is TranscriptPanel }?.makeKey()
        DispatchQueue.main.async { nameFocused = true }
    }

    private func finishRenaming() {
        if let id = renaming {
            let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { model.speakerNames[id] = nil } else { model.speakerNames[id] = name }
            model.guessedSpeakerNames.remove(id)  // yours now: Starlight won't change it
        }
        renaming = nil
        nameFocused = false
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let id = renaming {
                Text("Speaker \(id)").font(.system(size: 12, weight: .semibold)).opacity(0.45).fixedSize()
                TextField("Name", text: $nameDraft)
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                    .focused($nameFocused)
                    .onSubmit(finishRenaming)
                    .onExitCommand { renaming = nil }
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Capsule().fill(.white.opacity(0.08)))
                Button("Done", action: finishRenaming)
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
            } else if model.notes == .listening {
                LiveDot(color: .white)
                Text(timerInterval: model.notesStart...Date.distantFuture, countsDown: false)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .lineLimit(1).fixedSize()
            } else {
                Glyph(kind: .note, size: 14)
            }
            Spacer()
            if renaming == nil {
                CopyTranscriptButton { TranscriptText.plain(model.noteItems, name: model.speakerName) }
            }
            CloseButton(action: onClose)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 44)
        // The top bar moves the panel; double-click it to put it back under the notch.
        .background { if !Render.isRendering { WindowDragArea(onDoubleClick: onHome) } }
    }

    @ViewBuilder
    private func row(_ line: TranscriptLine, previous: TranscriptLine?) -> some View {
        switch line {
        case .said(let item):
            let newSpeaker: Bool = {
                guard case .said(let last) = previous else { return true }
                return last.isMine != item.isMine || last.speakerID != item.speakerID
            }()
            Bubble(item: item, name: model.speakerName(item), showsLabel: newSpeaker,
                   answering: model.answeringLines.contains(item.id),
                   onAnswer: { deep in onAnswer(item, deep) },
                   onRename: item.speakerID.map { id in { startRenaming(id) } })
        case .agent(let reply):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    if let outcome = reply.outcome {
                        OutcomeBadge(ok: outcome.ok, size: 14)
                    } else {
                        Glyph(kind: .agent, size: 13, active: reply.streaming)
                    }
                }
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                if reply.text.isEmpty {
                    ShimmerText(text: reply.outcome?.text ?? "Thinking")
                } else if reply.outcome != nil, AnswerText.clean(reply.text) == reply.outcome?.text {
                    Text(reply.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        RichReply(text: reply.text)
                        if let source = reply.source {
                            Text(source).font(.system(size: 11.5, weight: .medium)).opacity(0.4)
                        }
                        if let link = reply.link { MomentButton(moment: link) }
                    }
                }
                Spacer(minLength: 0)
                if let image = reply.image {
                    AnswerPicture(image: image, size: 56)
                        .alignmentGuide(.firstTextBaseline) { $0[.top] + 12 }
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 6)
            .transition(.opacity)
        }
    }
}

/// A line someone said. Yours: white on black's opposite, on the right. Theirs: a quiet grey
/// bubble on the left. Double-click to have it answered; it brightens on hover to show that.
private struct Bubble: View {
    let item: NoteItem
    /// "You", "Speaker 2", or the name you gave them.
    let name: String
    let showsLabel: Bool
    let answering: Bool
    /// nil = double-click (decide), true/false from the right-click menu.
    let onAnswer: (Bool?) -> Void
    /// Their lines, when we know who: rename that speaker.
    var onRename: (() -> Void)? = nil
    @State private var hovering = false

    /// Each of the other people gets a slightly different grey, so turns are easy to follow.
    private var theirFill: Double {
        let shades = [0.08, 0.13, 0.05, 0.16]
        let index = (item.speakerID.flatMap(Int.init) ?? 1) - 1
        return shades[max(index, 0) % shades.count]
    }

    var body: some View {
        let mine = item.isMine
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            if showsLabel {
                Text(name).font(.system(size: 10.5, weight: .semibold)).opacity(0.4)
                    .padding(.horizontal, 4)
            }
            Text(item.text)
                .font(.system(size: 13.5))
                .foregroundStyle(mine ? .black : .white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(mine ? Color.white.opacity(hovering ? 1 : 0.92) : Color.white.opacity(theirFill + (hovering ? 0.05 : 0))))
                .scaleEffect(answering ? 0.98 : 1)
                .animation(Motion.press, value: answering)
                .onTapGesture(count: 2) { onAnswer(nil) }
                .contextMenu {
                    Button("Answer fast") { onAnswer(false) }
                    Button("Answer in depth") { onAnswer(true) }
                    if let onRename {
                        Divider()
                        Button("Rename \(name)…", action: onRename)
                    }
                }
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)

        }
        .frame(maxWidth: 380, alignment: mine ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .transition(.opacity.combined(with: .offset(y: 6)))
    }
}

/// The panel's close button: a fine × that gains a soft disc on hover.
private struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Glyph(kind: .close, size: 13, active: hovering)
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.4))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(hovering ? 0.1 : 0)))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel("Close")
    }
}

/// Lets a SwiftUI area drag its window (a borderless panel has no title bar to grab).
private struct WindowDragArea: NSViewRepresentable {
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: DragView, context: Context) { view.onDoubleClick = onDoubleClick }

    final class DragView: NSView {
        var onDoubleClick: (() -> Void)?
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onDoubleClick?(); return }
            window?.performDrag(with: event)
        }
    }
}

/// The agent's reply with light formatting: paragraphs with **bold** and `code`, and fenced
/// code blocks in a monospaced box that scrolls sideways. While a reply streams, an unclosed
/// fence already shows as code.
struct RichReply: View {
    let text: String

    private enum Block: Hashable {
        case prose(String)
        case code(language: String, body: String)
    }

    private var blocks: [Block] {
        var blocks: [Block] = []
        let parts = AnswerText.clean(text).components(separatedBy: "```")
        for (index, part) in parts.enumerated() {
            if index % 2 == 0 {
                let prose = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !prose.isEmpty { blocks.append(.prose(prose)) }
            } else {
                var lines = part.components(separatedBy: "\n")
                let language = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
                lines.removeFirst()
                let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                if !body.isEmpty || !language.isEmpty { blocks.append(.code(language: language, body: body)) }
            }
        }
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks, id: \.self) { block in
                switch block {
                case .prose(let prose):
                    Text(Markdown.inline(prose))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .code(let language, let body):
                    VStack(alignment: .leading, spacing: 6) {
                        if !language.isEmpty {
                            Text(language).font(.system(size: 10.5, weight: .semibold)).opacity(0.35)
                        }
                        let code = Text(CodeHighlighter.highlight(body, language: language))
                            .font(.system(size: 12, design: .monospaced))
                            .lineSpacing(2)
                            .fixedSize()
                            .textSelection(.enabled)
                        if Render.isRendering { code } else { ScrollView(.horizontal, showsIndicators: false) { code } }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06)))
                }
            }
        }
    }

}

/// Bottom-right corner handle: drag to resize the panel. Two short diagonal lines, faint until
/// hovered.
private struct ResizeGrip: View {
    let onResize: (CGSize) -> Void
    @State private var hovering = false
    @State private var last: CGSize = .zero

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: size.width - 4, y: size.height - 11))
            path.addLine(to: CGPoint(x: size.width - 11, y: size.height - 4))
            path.move(to: CGPoint(x: size.width - 4, y: size.height - 6.5))
            path.addLine(to: CGPoint(x: size.width - 6.5, y: size.height - 4))
            context.stroke(path, with: .color(.white.opacity(hovering ? 0.7 : 0.25)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        .frame(width: 22, height: 22)
        .padding(4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                // Screen y grows upwards; dragging down should make the panel taller.
                let delta = CGSize(width: value.translation.width - last.width, height: value.translation.height - last.height)
                last = value.translation
                onResize(CGSize(width: delta.width, height: delta.height))
            }
            .onEnded { _ in last = .zero })
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Tracks whether the scroll view is at (or near) the bottom, where following new lines makes
/// sense. macOS 15+; earlier systems always follow.
/// Only a scroll movement (yours, or ours following) changes `following`. Content growing
/// mustn't: a new line makes the content taller for a moment before we scroll to it, which
/// used to read as "you scrolled up" and stopped the following.
private struct FollowsBottom: ViewModifier {
    @Binding var following: Bool

    private struct Position: Equatable {
        var offset: CGFloat
        var distanceFromBottom: CGFloat
    }

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Position.self) { geometry in
                Position(offset: geometry.contentOffset.y,
                         distanceFromBottom: geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height)
            } action: { old, new in
                guard abs(new.offset - old.offset) > 0.5 else { return }  // size changed, not scrolled
                if new.distanceFromBottom < 80 {
                    if !following { following = true }
                } else if new.offset < old.offset - 2, following {
                    // Only scrolling *up* stops following: a smooth scroll down that's still on
                    // its way while more text arrives never counts as you leaving the bottom.
                    following = false
                }
            }
        } else {
            content
        }
    }
}

/// What you're saying right now, as it's heard: your bubble, dimmed, with a caret. It becomes
/// a normal line when you pause.
private struct CaptionBubble: View {
    let text: String

    var body: some View {
        (Text(text) + Text(" \u{258D}").foregroundColor(.black.opacity(0.35)))
            .font(.system(size: 13.5))
            .foregroundStyle(.black.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.55)))
            .frame(maxWidth: 380, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .transition(.opacity)
    }
}

/// The transcript's window: borderless and non-activating, but able to take keystrokes when a
/// text field in it is in use (renaming a speaker).
/// "Ask Starlight…": type a question when you can't say it out loud. Return sends; the answer comes
/// into the transcript like any other.
struct AskBar: View {
    let onAsk: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if Render.isRendering {
                Text("Ask Starlight…").font(.system(size: 13)).opacity(0.35)
                Spacer(minLength: 0)
            } else {
                TextField("Ask Starlight…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(send)
            }
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(text.isEmpty ? .white.opacity(0.4) : .black)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(text.isEmpty ? Color.white.opacity(0.1) : Color.white))
            }
            .buttonStyle(PressableStyle())
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(focused ? 0.1 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(focused ? 0.18 : 0.06), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            // The overlay takes the keyboard for typing (still without activating Starlight).
            NSApp.windows.first { $0 is TranscriptPanel }?.makeKey()
            focused = true
        }
        .animation(.easeOut(duration: 0.15), value: focused)
        .animation(.easeOut(duration: 0.15), value: text.isEmpty)
    }

    private func send() {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        onAsk(question)
        text = ""
        focused = true
    }
}

final class TranscriptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The transcript as plain text: "[m:ss] Name: line", exactly as heard, no AI replies.
enum TranscriptText {
    static func plain(_ items: [NoteItem], name: (NoteItem) -> String) -> String {
        items.map { "[\(NotesController.timestamp($0.time))] \(name($0)): \($0.text)" }.joined(separator: "\n")
    }
}

/// Copies the transcript (only what was said); the glyph turns into a tick for a moment.
struct CopyTranscriptButton: View {
    /// Shows "Copy transcript" all the time, not just on hover.
    var alwaysLabelled = false
    let text: () -> String
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        } label: {
            HStack(spacing: 5) {
                if copied {
                    Glyph(kind: .check, size: 13)
                    Text("Copied").font(.system(size: 11.5, weight: .semibold))
                } else {
                    Glyph(kind: .copy, size: 14, active: hovering)
                    if hovering || alwaysLabelled { Text("Copy transcript").font(.system(size: 11.5, weight: .medium)) }
                }
            }
            .foregroundStyle(.white.opacity(hovering || copied ? 0.95 : alwaysLabelled ? 0.7 : 0.45))
            .padding(.horizontal, 8).frame(height: 26)
            .background(Capsule().fill(.white.opacity(hovering ? 0.1 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: copied)
        .accessibilityLabel("Copy transcript")
    }
}
