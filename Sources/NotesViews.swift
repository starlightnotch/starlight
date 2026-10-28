import SwiftUI

/// The notes session in the notch.
///
/// - Listening: a compact indicator beside the camera (timer, level bars). Hover to see your
///   latest questions and points, with a stop button.
/// - Finishing: "Writing notes" while the last phrase is transcribed and the summary is written.
/// - Done: summary, your questions and your points; open the saved file or dismiss.
struct NotesContent: View {
    @ObservedObject var model: NotchModel
    var onStop: () -> Void
    var onDismiss: () -> Void
    /// Click the notch while listening: the live transcript.
    var onTranscript: () -> Void = {}
    /// Click the time beside the camera: pause or resume listening.
    var onPause: () -> Void = {}
    /// The finished card: copying the transcript keeps it open.
    var onKeep: () -> Void = {}

    var body: some View {
        let size = model.notesSize
        VStack(spacing: 0) {
            wings(width: size.width)
            Group {
                switch model.notes {
                case .listening where model.approval != nil:
                    ApprovalCard(approval: model.approval!)
                case .listening where model.showsCaption:
                    TeleprompterText(text: AttributedString(model.liveCaption), plain: model.liveCaption,
                                     font: NotesLayout.captionFont, width: NotesLayout.captionWidth,
                                     maxLines: NotesLayout.captionMaxLines)
                        .opacity(0.85)
                        .padding(.top, 4)
                case .listening where model.liveAnswer != nil && !model.notesExpanded && !model.transcriptOpen:
                    LiveAnswerCard(card: model.liveAnswer!, timer: model.liveAnswerTimer)
                case .listening where model.notesExpanded: live
                case .finishing: finishing
                case .done(let result): done(result)
                case .error(let message):
                    Text(message).font(.notch(size: 12)).opacity(0.75).frame(height: VoiceLayout.textLine)
                default: EmptyView()
                }
            }
            .id(contentKey)
            .transition(.notchContent(slowMotion: model.slowMotion))
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .foregroundStyle(.white)
        .contentShape(Rectangle())

    }

    private var contentKey: String {
        switch model.notes {
        case .listening where model.approval != nil: "approval-\(model.approval!.id)"
        case .listening: model.notesExpanded ? "live" : model.showsCaption ? "caption"
            : model.transcriptOpen ? "compact" : model.liveAnswer.map { "answer-\($0.id)" } ?? "compact"
        case .finishing: "finishing"
        case .done: "done"
        case .error: "error"
        case .idle: "idle"
        }
    }

    // MARK: Wings beside the camera

    private func wings(width: CGFloat) -> some View {
        let wing = (width - model.closedSize.width) / 2 - 14
        return HStack(spacing: 0) {
            leftWing.frame(width: max(wing, 0), alignment: .leading)
            Spacer(minLength: model.closedSize.width)
            rightWing.frame(width: max(wing, 0), alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: model.notchSize.height)
    }

    @ViewBuilder private var leftWing: some View {
        switch model.notes {
        case .listening:
            PauseControl(model: model, action: onPause)
        case .finishing:
            Glyph(kind: .voice, size: 15, active: true)
        case .done:
            Glyph(kind: .note, size: 15)
        case .error:
            Glyph(kind: .alert, size: 15)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var rightWing: some View {
        switch model.notes {
        case .listening where model.notesPaused:
            Text("Paused").font(.notch(size: 11.5, weight: .medium)).opacity(0.55).lineLimit(1).fixedSize()
                .transition(.opacity)
        case .listening where model.agentThinking:
            HStack(spacing: 5) {
                Glyph(kind: .agent, size: 13, active: true)
                Text("Thinking").font(.notch(size: 11.5, weight: .medium)).lineLimit(1).fixedSize()
            }
            .transition(.opacity)
        case .listening where AppSettings.shared.silentMode:
            // Listening, not answering: said where the level bars were.
            Text("Silent").font(.notch(size: 11.5, weight: .medium)).opacity(0.6).lineLimit(1).fixedSize()
                .transition(.opacity)
        case .listening:
            MiniLevelBars(levels: model.notesLevels)
        case .finishing:
            EmptyView()
        case .done:
            if model.notesDoneKept {
                Text("Saved").font(.notch(size: 12, weight: .medium)).opacity(0.6)
            } else {
                CountdownRing(timer: model.notesDoneTimer)
            }
        default:
            EmptyView()
        }
    }

    // MARK: Listening, expanded on hover

    /// Hovering the notch while it listens: the tasks Starlight has written down (newest first), or
    /// the last thing said when there are none yet. Then pause and stop.
    private var live: some View {
        let tasks = AppSettings.shared.tasksEnabled ? Array(TaskStore.shared.open.prefix(NotesLayout.visibleRows)) : []
        return VStack(alignment: .leading, spacing: 0) {
            if !tasks.isEmpty {
                ForEach(tasks) { task in
                    HStack(spacing: 9) {
                        Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1.2).frame(width: 12, height: 12)
                        Text(task.text).font(.notch(size: 12.5)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        if let due = task.due { DueChip(due: due, size: 10.5) }
                    }
                    .frame(height: NotesLayout.rowHeight)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else if let last = model.noteItems.last {
                Text(last.text)
                    .font(.notch(size: 12.5)).opacity(last.isMine ? 0.85 : 0.6)
                    .lineLimit(1).truncationMode(.head)
                    .frame(height: NotesLayout.rowHeight)
            } else {
                Text(model.sessionKind == .live ? "Listening to you" : "Listening")
                    .font(.notch(size: 12)).opacity(0.5)
                    .frame(height: NotesLayout.rowHeight)
            }
            HStack(spacing: 6) {
                // What's on screen: the full transcript overlay, and the tasks corner.
                if AppSettings.shared.tasksEnabled {
                    ScreenToggle(title: "Tasks", on: AppSettings.shared.showTasksCorner) { AppSettings.shared.showTasksCorner.toggle() }
                }
                ScreenToggle(title: "Window", on: model.transcriptOpen, action: onTranscript)
                Spacer()
                PauseButton(paused: model.notesPaused, action: onPause)
                StopButton(level: model.notesPaused ? 0 : averageLevel, action: onStop)
            }
            .frame(height: NotesLayout.footer)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var averageLevel: Double {
        model.notesLevels.isEmpty ? 0 : Double(model.notesLevels.reduce(0, +)) / Double(model.notesLevels.count * 100)
    }

    // MARK: Finishing and done

    private var finishing: some View {
        ShimmerText(text: "Writing notes").frame(height: 26)
    }

    /// Finished: the meeting in one big friendly line, like an answer card ("12 minutes with
    /// Dana"), a soft line under it, and the whole conversation one click from the clipboard.
    private func done(_ result: NotesResult) -> some View {
        let ending = result.ending
        return VStack(alignment: .leading, spacing: 0) {
            Text(ending.title)
                .font(Font(NotesLayout.headlineFont))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(height: NotesLayout.doneTitle, alignment: .leading)
            Text(ending.detail)
                .font(.notch(size: 12.5))
                .opacity(0.6)
                .lineLimit(1)
                .frame(height: NotesLayout.doneDetail, alignment: .leading)
                .padding(.top, 2)
            HStack(spacing: 6) {
                CopyPill(title: "Copy transcript") { onKeep(); return result.transcriptText }
                Spacer()
                PillButton(title: "Open", prominent: false) {
                    onDismiss()
                    CompanionWindow.shared.show(.session(result.id))
                }
                PillButton(title: "Done", prominent: true, action: onDismiss)
            }
            .frame(height: 28)
            .padding(.top, 14)
        }
        .padding(.horizontal, NotchText.inset)
        .padding(.top, 8)
    }
}

/// "Copy" that says "Copied" for a moment.
struct CopyPill: View {
    var title = "Copy"
    let text: () -> String
    @State private var copied = false

    var body: some View {
        PillButton(title: copied ? "Copied" : title, prominent: false) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(.easeOut(duration: 0.2)) { copied = false } }
        }
    }
}

/// The time beside the camera, which is also the pause button. Resting: the live dot and the
/// running time. With the pointer on the notch: a pause mark and "Pause" (click to pause).
/// Paused: the time holds, dimmed, with a pause mark; on hover it offers "Resume".
struct PauseControl: View {
    @ObservedObject var model: NotchModel
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let offering = model.notesExpanded || hovering
        Button(action: action) {
            HStack(spacing: 5) {
                ZStack {
                    if model.notesPaused {
                        Glyph(kind: offering ? .play : .pause, size: 11)
                    } else if offering {
                        Glyph(kind: .pause, size: 11)
                    } else {
                        LiveDot(color: .white)
                    }
                }
                .frame(width: 12, height: 12)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                Group {
                    if offering {
                        Text(model.notesPaused ? "Resume" : "Pause")
                    } else if model.notesPaused {
                        Text(NotesController.timestamp(model.pausedElapsed)).opacity(0.5)
                    } else if model.sessionKind == .live {
                        Text("Live")
                    } else {
                        Text(timerInterval: model.notesStart...Date.distantFuture, countsDown: false)
                    }
                }
                .font(.notch(size: 12, weight: .semibold).monospacedDigit())
                .lineLimit(1).fixedSize()
                .contentTransition(.opacity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: offering)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.notesPaused)
        .accessibilityLabel(model.notesPaused ? "Resume listening" : "Pause listening")
    }
}

/// A small on/off pill in the notch: white when on, grey when off.
struct ScreenToggle: View {
    let title: String
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.notch(size: 11, weight: .semibold))
                .foregroundStyle(on ? .black : .white.opacity(hovering ? 0.95 : 0.7))
                .padding(.horizontal, 9).frame(height: 22)
                .background(Capsule().fill(on ? Color.white.opacity(hovering ? 1 : 0.9) : Color.white.opacity(hovering ? 0.18 : 0.1)))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: on)
        .accessibilityLabel(on ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
    }
}

/// Beside Stop in the hover list: two bars to pause, a play mark to resume, in the same ring.
struct PauseButton: View {
    let paused: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white.opacity(hovering ? 0.6 : 0.28), lineWidth: 1.5)
                Glyph(kind: paused ? .play : .pause, size: 10)
            }
            .frame(width: 20, height: 20)
            .scaleEffect(hovering ? 1.08 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(paused ? "Resume" : "Pause")
    }
}

/// A line from a session. Yours: a white "?" badge for questions, a dot for points. Theirs: the
/// same marks drawn as outlines, and the text a step dimmer.
struct NoteRow: View {
    let item: NoteItem
    var wraps = false

    var body: some View {
        HStack(alignment: wraps ? .firstTextBaseline : .center, spacing: 8) {
            ZStack {
                if item.isQuestion && item.isMine {
                    Circle().fill(.white).frame(width: 15, height: 15)
                    Text("?").font(.notch(size: 10, weight: .heavy)).foregroundStyle(.black)
                } else if item.isQuestion {
                    Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.2).frame(width: 15, height: 15)
                    Text("?").font(.notch(size: 9.5, weight: .heavy)).foregroundStyle(.white.opacity(0.7))
                } else if item.isMine {
                    Circle().fill(.white.opacity(0.45)).frame(width: 5, height: 5)
                } else {
                    Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1).frame(width: 6, height: 6)
                }
            }
            .frame(width: 15)
            Text(item.text)
                .font(.notch(size: 12.5))
                .opacity(item.isMine ? 1 : 0.65)
                .lineLimit(wraps ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: wraps)
            Spacer(minLength: 0)
            Text(NotesController.timestamp(item.time))
                .font(.notch(size: 10, weight: .medium).monospacedDigit()).opacity(0.4)
        }
    }
}

/// Small level meter for the compact indicator.
struct MiniLevelBars: View {
    var levels: [Int]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 2, height: max(3, 14 * VoiceLayout.displayLevel(level) / 100))
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.1), value: levels)
    }
}

struct PillButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.notch(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? .black : .white)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Capsule().fill(prominent ? Color.white.opacity(hovering ? 1 : 0.9) : Color.white.opacity(hovering ? 0.22 : 0.14)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// How an answer card is laid out, shared by the view and the notch's size so they agree.
struct AnswerCardLayout {
    enum Main {
        /// Nothing to show yet: "Thinking…" or the tool at work.
        case status
        /// An action with nothing written after it: check or cross, and what happened.
        case outcome(Outcome)
        /// A short fact, big, with any detail small under it.
        case headline(String, detail: String)
        /// Normal text.
        case body(String)
        /// More than fits in a few lines, or code: a wider card that scrolls inside the notch.
        case long(String)
    }

    let main: Main
    /// The picture beside the text, when one has loaded.
    let image: NSImage?
    /// Under the text: an action's result (small), or the tool line.
    let footerOutcome: Outcome?
    let toolLine: (glyph: Glyph.Kind, text: String)?
    /// "Open at 12:31": the meeting moment it comes from.
    let link: MeetingMoment?

    init(_ card: LiveAnswer) {
        let text = AnswerText.clean(card.text)
        image = card.failed ? nil : card.image
        link = card.outcome == nil ? card.link : nil
        toolLine = card.outcome == nil && card.link == nil ? card.toolLine : nil
        if text.isEmpty {
            if let outcome = card.outcome, card.status == nil || card.finished {
                main = .outcome(outcome)
            } else {
                main = .status
            }
            footerOutcome = nil
            return
        }
        footerOutcome = card.outcome
        if card.failed {
            main = .body(text)
            return
        }
        if Self.isLong(text, imageWidth: image != nil ? NotesLayout.imageSize + 12 : 0) {
            main = .long(text)
            return
        }
        switch AnswerText.shape(text, finished: card.finished) {
        case .pending: main = .status
        case .headline(let headline, let detail): main = .headline(headline, detail: detail)
        case .body: main = .body(text)
        }
    }

    var isLong: Bool { if case .long = main { return true }; return false }

    /// The card's width: wider for long answers and code.
    var width: CGFloat { isLong ? NotesLayout.longAnswerWidth : NotesLayout.answerWidth }

    var textWidth: CGFloat {
        // Long ones leave room at the right for their ×.
        if isLong { return NotesLayout.longAnswerWidth - 2 * NotchText.inset - 30 - (image != nil ? NotesLayout.imageSize + 12 : 0) }
        return NotesLayout.answerTextWidth - (image != nil ? NotesLayout.imageSize + 12 : 0)
    }

    /// Code, or more than the normal card's lines.
    static func isLong(_ text: String, imageWidth: CGFloat) -> Bool {
        if text.contains("```") { return true }
        return NotchText.overflows(Markdown.plain(text), font: NotesLayout.answerFont,
                                   width: NotesLayout.answerTextWidth - imageWidth, maxLines: NotesLayout.answerMaxLines)
    }

    /// How tall a long answer's content is (prose and code blocks), before it's capped and scrolls.
    static func longHeight(_ text: String, width: CGFloat) -> CGFloat {
        var h: CGFloat = 0
        for (index, part) in text.components(separatedBy: "```").enumerated() {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if index % 2 == 0 {
                let rect = (Markdown.plain(trimmed) as NSString).boundingRect(
                    with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin], attributes: [.font: NotesLayout.answerFont])
                let lines = ceil(rect.height / NotchText.lineHeight(NotesLayout.answerFont))
                h += ceil(rect.height) + lines * 2 + 10
            } else {
                let lines = CGFloat(max(trimmed.components(separatedBy: "\n").count - 1, 1))
                h += lines * 16 + 24 + 16 + 10
            }
        }
        return max(h, 20)
    }

    static func headlineHeight(_ text: String, width: CGFloat) -> CGFloat {
        NotchText.height(Markdown.plain(text), font: NotesLayout.headlineFont, width: width, maxLines: NotesLayout.headlineMaxLines)
    }

    static func detailHeight(_ text: String, width: CGFloat) -> CGFloat {
        text.isEmpty ? 0 : 3 + NotchText.height(Markdown.plain(text), font: NotesLayout.detailFont, width: width, maxLines: NotesLayout.detailMaxLines)
    }

    static func outcomeHeight(_ outcome: Outcome) -> CGFloat {
        if outcome.ok, outcome.subject != nil { return NotesLayout.itemHeight }
        return max(NotesLayout.outcomeBadge + 2, NotchText.height(outcome.text, font: NotesLayout.outcomeFont,
                                                           width: NotesLayout.answerTextWidth - NotesLayout.outcomeBadge - 10, maxLines: 2))
    }

    var mainHeight: CGFloat {
        let picture = image != nil ? NotesLayout.imageSize : 0
        switch main {
        case .status: return 18
        case .outcome(let outcome): return Self.outcomeHeight(outcome)
        case .headline(let headline, let detail):
            return max(Self.headlineHeight(headline, width: textWidth) + Self.detailHeight(detail, width: textWidth), picture)
        case .body(let text):
            return max(NotchText.height(Markdown.plain(text), font: NotesLayout.answerFont, width: textWidth,
                                        maxLines: NotesLayout.answerMaxLines), picture)
        case .long(let text):
            return max(min(Self.longHeight(text, width: textWidth), NotesLayout.longAnswerMaxHeight), picture)
        }
    }

    var height: CGFloat {
        var h = mainHeight
        if footerOutcome != nil || toolLine != nil { h += 6 + 18 } else if link != nil { h += 8 + 26 }
        return h
    }
}

/// The answer under the notch, on its own (your question isn't repeated). A short fact is
/// big; a longer one streams in with a soft caret; an action shows a green check or a red
/// cross; a place or a person gets a small picture beside it.
struct LiveAnswerCard: View {
    let card: LiveAnswer
    let timer: ResultTimer?

    var body: some View {
        let layout = AnswerCardLayout(card)
        // Just the answer: what you asked isn't repeated back.
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                main(layout)
                    .frame(width: layout.textWidth, alignment: .topLeading)
                if let image = layout.image {
                    AnswerPicture(image: image)
                        .transition(.scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity))
                }
            }
            .frame(height: layout.mainHeight, alignment: .top)

            if let outcome = layout.footerOutcome {
                HStack(spacing: 6) {
                    OutcomeBadge(ok: outcome.ok, size: 14)
                    Text(outcome.text).font(.notch(size: 11.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        .opacity(0.75)
                }
                .frame(height: 18)
                .padding(.top, 2)
                .transition(.opacity)
            } else if let link = layout.link {
                MomentButton(moment: link)
                    .padding(.top, 4)
                    .transition(.opacity)
            } else if let tool = layout.toolLine {
                HStack(spacing: 6) {
                    Glyph(kind: tool.glyph, size: 12)
                    Text(tool.text).font(.notch(size: 11, weight: .medium, design: .rounded).monospacedDigit()).lineLimit(1)
                }
                .opacity(0.5)
                .frame(height: 18)
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: card.text.isEmpty)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: card.image != nil)
        .padding(.horizontal, NotchText.inset)
        .frame(width: layout.width, alignment: .leading)
        // Hovering a finished answer: Copy, Keep and Close in the corner, over the card (it doesn't
        // change size, so the notch never moves under the pointer). Long answers always show Close.
        .overlay(alignment: .topTrailing) {
            if (hovering || layout.isLong || Self.previewHover), card.finished || card.failed {
                AnswerControls(card: card, full: hovering || Self.previewHover)
                    .offset(x: -12, y: 0)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: hovering)
        .onHover { hovering = $0 }
        .padding(.top, 4)
    }

    @State private var hovering = false
    /// For the PNG renderer: draw as if hovered.
    nonisolated(unsafe) static var previewHover = false

    @ViewBuilder private func main(_ layout: AnswerCardLayout) -> some View {
        switch layout.main {
        case .status:
            HStack(spacing: 7) {
                Glyph(kind: card.statusGlyph, size: 14, active: true)
                ShimmerText(text: (card.status ?? "Thinking") + "…")
            }
            .frame(height: 18)
            .transition(.opacity)
        case .outcome(let outcome) where outcome.ok && outcome.subject != nil:
            ItemCard(outcome: outcome)
                .transition(.scale(scale: 0.85, anchor: .leading).combined(with: .opacity))
        case .outcome(let outcome):
            HStack(alignment: .top, spacing: 10) {
                OutcomeBadge(ok: outcome.ok, size: NotesLayout.outcomeBadge)
                    .padding(.top, 1)
                Text(outcome.text)
                    .font(Font(NotesLayout.outcomeFont))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.scale(scale: 0.96, anchor: .leading).combined(with: .opacity))
        case .headline(let headline, let detail):
            VStack(alignment: .leading, spacing: 3) {
                Text(Markdown.inline(headline))
                    .font(Font(NotesLayout.headlineFont))
                    .lineLimit(NotesLayout.headlineMaxLines)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white)
                if !detail.isEmpty {
                    TeleprompterText(text: Markdown.inline(detail), plain: Markdown.plain(detail), font: NotesLayout.detailFont,
                                     width: layout.textWidth, maxLines: NotesLayout.detailMaxLines, caret: !card.finished)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .transition(.opacity)
        case .body(let text):
            TeleprompterText(text: Markdown.inline(text), plain: Markdown.plain(text), font: NotesLayout.answerFont,
                             width: layout.textWidth, maxLines: NotesLayout.answerMaxLines, caret: !card.finished)
                .foregroundStyle(.white.opacity(card.failed ? 0.6 : 1))
                .transition(.opacity)
        case .long(let text):
            LongAnswer(text: text, finished: card.finished, height: layout.mainHeight)
                .transition(.opacity)
        }
    }
}

/// A long answer in the notch: formatted like the transcript (paragraphs, code in its box),
/// scrolling inside the card. While it's being written it follows the newest words; once it's
/// done you can scroll back through it. Fades at the edges when there's more to see.
struct LongAnswer: View {
    let text: String
    let finished: Bool
    let height: CGFloat

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            RichReply(text: text)
            Color.clear.frame(height: 1).id("end")
        }
        Group {
            if Render.isRendering {
                content.frame(height: height, alignment: .top).clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) { content }
                        .onChange(of: text) { _, _ in
                            guard !finished else { return }
                            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("end", anchor: .bottom) }
                        }
                }
            }
        }
        .frame(height: height)
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9),
                                   .init(color: .black.opacity(0.25), location: 1)], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// The × on a long answer, to put it away before its time is up.
/// An answer's controls: Copy (a check once it's copied), Keep (stays up until closed), Close.
struct AnswerControls: View {
    let card: LiveAnswer
    /// All three while hovered; just Close otherwise (long answers).
    var full: Bool
    @State private var copied = false
    @State private var keptIt = false

    var body: some View {
        HStack(spacing: 6) {
            if full, !AnswerText.clean(card.text).isEmpty {
                ControlDot(glyph: copied ? .check : .copy, label: copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AnswerText.clean(card.text), forType: .string)
                    Haptics.snap()
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { copied = false } }
                }
                ControlDot(glyph: keptIt ? .check : .history, label: keptIt ? "Kept" : "Keep") {
                    LiveAnswers.onScreen?.keep()
                    withAnimation { keptIt = true }
                }
            }
            ControlDot(glyph: .close, label: "Close") {
                if let owner = LiveAnswers.onScreen { owner.dismiss() } else { NotesController.closeAnswer?() }
            }
        }
        // Black behind them, fading at the left edge, so text underneath doesn't show through.
        .padding(.leading, 14).padding(.vertical, 2)
        .background(LinearGradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black, location: 0.35)],
                                   startPoint: .leading, endPoint: .trailing))
    }
}

/// A small round control in the notch, with its name as a tooltip.
struct ControlDot: View {
    let glyph: Glyph.Kind
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Glyph(kind: glyph, size: 10, active: hovering)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(hovering ? 0.2 : 0.1)))
                .contentTransition(.opacity)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

struct CloseAnswerButton: View {
    @State private var hovering = false
    var body: some View {
        Button { NotesController.closeAnswer?() } label: {
            Glyph(kind: .close, size: 9)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(hovering ? 0.18 : 0.1)))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel("Close")
    }
}

/// "Open at 12:31": jumps to that moment in the saved meeting.
struct MomentButton: View {
    let moment: MeetingMoment
    @State private var hovering = false

    /// "From today's meeting · 12:31", "From your Oct 12 meeting · 4:05".
    static func label(_ moment: MeetingMoment) -> String {
        let at = NotesController.timestamp(moment.time)
        guard let session = NotesStore.shared.session(moment.sessionID) else { return "Open at \(at)" }
        let cal = Calendar.current
        let day = cal.isDateInToday(session.started) ? "today's" : cal.isDateInYesterday(session.started) ? "yesterday's"
            : "your " + session.started.formatted(.dateTime.month(.abbreviated).day())
        return "From \(day) \(session.kind == "live" ? "session" : "meeting") · \(at)"
    }

    var body: some View {
        Button {
            CompanionWindow.shared.show(.session(moment.sessionID), at: moment.time)
        } label: {
            HStack(spacing: 6) {
                Glyph(kind: .note, size: 12)
                Text(Self.label(moment)).font(.notch(size: 12, weight: .semibold))
            }
            .foregroundStyle(hovering ? .black : .white)
            .padding(.horizontal, 11).frame(height: 26)
            .background(Capsule().fill(hovering ? Color.white : Color.white.opacity(0.14)))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Done: a white check on a green circle. Failed or cancelled: a white cross on red. The only
/// colour in the notch besides a picture, so a result reads at a glance. The mark draws itself on.
struct OutcomeBadge: View {
    let ok: Bool
    var size: CGFloat = 18
    @State private var drawn: CGFloat = 0

    static let green = Color(red: 0.19, green: 0.78, blue: 0.35)
    static let red = Color(red: 1, green: 0.27, blue: 0.23)

    var body: some View {
        ZStack {
            Circle().fill(ok ? Self.green : Self.red)
            mark
                .trim(from: 0, to: drawn)
                .stroke(.white, style: StrokeStyle(lineWidth: max(size * 0.12, 1.6), lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .scaleEffect(0.6 + 0.4 * min(drawn * 2, 1))
        .onAppear {
            guard !Render.isRendering else { drawn = 1; return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) { drawn = 1 }
        }
        .accessibilityLabel(ok ? "Done" : "Didn't happen")
    }

    private var mark: Path {
        Path { path in
            let s = size
            if ok {
                path.move(to: CGPoint(x: s * 0.29, y: s * 0.52))
                path.addLine(to: CGPoint(x: s * 0.44, y: s * 0.66))
                path.addLine(to: CGPoint(x: s * 0.72, y: s * 0.37))
            } else {
                path.move(to: CGPoint(x: s * 0.34, y: s * 0.34)); path.addLine(to: CGPoint(x: s * 0.66, y: s * 0.66))
                path.move(to: CGPoint(x: s * 0.66, y: s * 0.34)); path.addLine(to: CGPoint(x: s * 0.34, y: s * 0.66))
            }
        }
    }
}

/// Something opened, saved or moved: the app's or file's own icon, what happened small, and its
/// name big ("Opened" / "Reminders"). The icon pops in with a little bounce.
struct ItemCard: View {
    let outcome: Outcome
    @State private var shown = false

    var body: some View {
        HStack(spacing: 14) {
            if let path = outcome.icon {
                ItemIcon(path: path, size: NotesLayout.itemHeight)
                    .scaleEffect(shown ? 1 : 0.55)
                    .rotationEffect(.degrees(shown ? 0 : -12))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(outcome.verb ?? "Done").font(.notch(size: 12.5, weight: .medium)).opacity(0.55).lineLimit(1)
                Text(outcome.subject ?? outcome.text)
                    .font(Font(NotesLayout.headlineFont))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.middle)
            }
            .offset(x: shown ? 0 : -6)
            .opacity(shown ? 1 : 0)
        }
        .frame(height: NotesLayout.itemHeight, alignment: .leading)
        .onAppear {
            guard !Render.isRendering else { shown = true; return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.58)) { shown = true }
        }
    }
}

/// A file's or app's Finder icon.
struct ItemIcon: View {
    let path: String
    var size: CGFloat = 40

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// The small picture beside an answer.
struct AnswerPicture: View {
    let image: NSImage
    var size: CGFloat = NotesLayout.imageSize

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// The agent wants to do something on your Mac, and waits for your click. A file or app reads
/// like the result would: its icon, the action small, its name big ("Move to Trash" / "old.png").
/// Only a real terminal command shows as code.
struct ApprovalCard: View {
    let approval: Approval
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let subject = approval.subject {
                HStack(spacing: 14) {
                    if let icon = approval.icon {
                        ItemIcon(path: icon, size: NotesLayout.itemHeight)
                            .scaleEffect(shown ? 1 : 0.6)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(approval.title).font(.notch(size: 12.5, weight: .medium)).opacity(0.55).lineLimit(1)
                        Text(subject).font(Font(NotesLayout.headlineFont)).lineLimit(1).minimumScaleFactor(0.7).truncationMode(.middle)
                    }
                }
                .frame(height: NotesLayout.itemHeight, alignment: .leading)
                .padding(.top, 6)
                if !approval.detail.isEmpty {
                    Text(approval.detail)
                        .font(.notch(size: 12))
                        .opacity(0.45)
                        .lineLimit(2)
                        .frame(width: NotesLayout.answerTextWidth, alignment: .leading)
                        .padding(.top, 6)
                }
            } else {
                HStack(spacing: 8) {
                    Glyph(kind: approval.glyph, size: 15)
                    Text(approval.title).font(.notch(size: 13, weight: .semibold))
                    Spacer()
                }
                .frame(height: 20)
                .padding(.top, 6)

                Text(approval.detail)
                    .font(Font(NotesLayout.approvalDetailFont))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(NotesLayout.approvalDetailMaxLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: NotesLayout.answerTextWidth - 20, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
                    .padding(.top, 8)
                    .textSelection(.enabled)
            }

            HStack(spacing: 6) {
                Spacer()
                PillButton(title: "Cancel", prominent: false) { Approvals.shared.decide(approval.id, false) }
                PillButton(title: approval.action, prominent: true) { Approvals.shared.decide(approval.id, true) }
            }
            .frame(height: 26)
            .padding(.top, approval.subject == nil ? 10 : 12)
        }
        .padding(.horizontal, NotchText.inset)
        .frame(width: NotesLayout.answerWidth, alignment: .leading)
        .onAppear {
            guard !Render.isRendering else { shown = true; return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.58)) { shown = true }
        }
    }
}

/// A label with a soft highlight sweeping across it, for "Thinking…" and tool status. The
/// highlight is a gradient in the text's own coordinates, so it fits any width and never
/// slides past the end of a short label.
struct ShimmerText: View {
    let text: String
    @State private var phase: CGFloat = -0.4

    /// Stop positions must stay in order, so each is pinned to 0…1 (monotonic in phase).
    private static func clamp(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }

    var body: some View {
        Text(text)
            .font(.notch(size: 12.5, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(LinearGradient(
                stops: [.init(color: .white.opacity(0.38), location: 0),
                        .init(color: .white.opacity(0.38), location: Self.clamp(phase - 0.25)),
                        .init(color: .white.opacity(0.95), location: Self.clamp(phase)),
                        .init(color: .white.opacity(0.38), location: Self.clamp(phase + 0.25)),
                        .init(color: .white.opacity(0.38), location: 1)],
                startPoint: .leading, endPoint: .trailing))
            .onAppear {
                guard !Render.isRendering else { phase = 0.5; return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.4 }
            }
    }
}

/// Text inside the notch. The notch's bottom corners grow rounder as it gets taller, so text
/// keeps `inset` from the sides to stay clear of the curve. Long text never truncates: it
/// wraps to the notch's width, and past `maxLines` it scrolls up like a teleprompter, the
/// oldest line fading out at the top, so the newest words are always in view.
enum NotchText {
    static let inset: CGFloat = 28

    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

    /// The height the text takes at `width`, at least one line and at most `maxLines`.
    static func height(_ text: String, font: NSFont, width: CGFloat, maxLines: Int) -> CGFloat {
        let line = lineHeight(font)
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return min(max(ceil(rect.height), line), line * CGFloat(maxLines))
    }

    static func overflows(_ text: String, font: NSFont, width: CGFloat, maxLines: Int) -> Bool {
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return ceil(rect.height) > lineHeight(font) * CGFloat(maxLines) + 1
    }
}

/// See NotchText: wraps to `width`, shows the last `maxLines`, fades the top line when there's
/// more above it, and glides as new words push it up.
struct TeleprompterText: View {
    let text: AttributedString
    /// The same text without formatting, for measuring.
    let plain: String
    let font: NSFont
    let width: CGFloat
    let maxLines: Int
    var caret = false
    /// Live dictation: each new word fades up from dim as it's heard, instead of popping in.
    var animateWords = false

    /// When each word (by position) last arrived or changed; a corrected word fades in again.
    @State private var words: [String] = []
    @State private var arrivals: [Date] = []
    /// Bumped once the newest word has settled, so the animation timeline stops ticking.
    @State private var settled = true

    private static let fade: TimeInterval = 0.34

    var body: some View {
        Group {
            if animateWords && !Render.isRendering {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: settled)) { context in
                    laidOut(fadingWords(at: context.date))
                }
            } else {
                laidOut(Text(text))
            }
        }
        .onAppear { if animateWords { track(plain) } }
        .onChange(of: plain) { _, new in if animateWords { track(new) } }
    }

    private func laidOut(_ content: Text) -> some View {
        let height = NotchText.height(plain, font: font, width: width, maxLines: maxLines)
        let overflowing = NotchText.overflows(plain + (caret ? " \u{258D}" : ""), font: font, width: width, maxLines: maxLines)
        let line = NotchText.lineHeight(font)
        return (content + Text(caret ? " \u{258D}" : "").foregroundColor(.white.opacity(0.45)))
            .font(Font(font))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
            // Taller than the box: pinned to the bottom, the overflow goes up and is clipped.
            .frame(width: width, height: height, alignment: .bottomLeading)
            .clipped()
            // More above: only the top edge of the top line softens (it stays readable; fading
            // the whole line made two-line text hard to read as it scrolled).
            .mask {
                LinearGradient(stops: [.init(color: .black.opacity(overflowing ? 0.3 : 1), location: 0),
                                       .init(color: .black, location: overflowing ? min(line * 0.45 / height, 0.3) : 0)],
                               startPoint: .top, endPoint: .bottom)
            }
            .animation(.easeOut(duration: 0.18), value: plain)
    }

    /// The words joined back up, each at the brightness its age gives it: 25% when it lands,
    /// full white a third of a second later (ease-out), so they arrive one by one.
    private func fadingWords(at now: Date) -> Text {
        var result = Text("")
        for (index, word) in words.enumerated() {
            let age = index < arrivals.count ? now.timeIntervalSince(arrivals[index]) : Self.fade
            let p = min(max(age / Self.fade, 0), 1)
            let eased = 1 - pow(1 - p, 3)
            let piece = Text(index == 0 ? word : " " + word).foregroundColor(.white.opacity(0.25 + 0.75 * eased))
            result = result + piece
        }
        return result
    }

    private func track(_ text: String) {
        let new = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let now = Date()
        var times = arrivals
        if times.count > new.count { times.removeLast(times.count - new.count) }
        for i in new.indices {
            if i >= times.count { times.append(now) }
            else if i >= words.count || words[i] != new[i] { times[i] = now }
        }
        words = new
        arrivals = times
        settled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fade + 0.05) {
            if let newest = arrivals.max(), Date().timeIntervalSince(newest) >= Self.fade { settled = true }
        }
    }
}

/// A meeting just started: beside the camera, which app, and Take notes (or × to wave it off).
struct MeetingPrompt: View {
    @ObservedObject var model: NotchModel
    let app: MeetingApp
    let onTakeNotes: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let wing = NotesLayout.meetingWing - 14
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                LiveDot(color: .white)
                Text(app.name).font(.notch(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: wing, alignment: .leading)
            Spacer(minLength: model.closedSize.width)
            HStack(spacing: 6) {
                Button(action: onTakeNotes) {
                    Text("Take notes").font(.notch(size: 11.5, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(PressableStyle())
                Button(action: onDismiss) {
                    Glyph(kind: .close, size: 11).frame(width: 18, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .opacity(0.6)
                .accessibilityLabel("Not now")
            }
            .frame(width: wing, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(width: model.size.width, height: model.notchSize.height)
        .foregroundStyle(.white)
    }
}
