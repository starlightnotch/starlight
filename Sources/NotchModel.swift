import SwiftUI

enum NotchState: String, CaseIterable, Identifiable {
    case closed, open
    var id: String { rawValue }
}

/// Dictation, shown in the notch.
enum VoicePhase: Equatable {
    case idle, recording, processing
    /// Finished and closing: a tick and "Copied" beside the camera for a moment.
    case done(copied: Bool)
    case result(String)
    case error(String)
    /// Hold to ask: the agent's answer (or the approval it's waiting on), in the live answer card.
    case answer

    var isActive: Bool { self != .idle }
    /// Identity for content transitions: changes when the notch should swap what it shows.
    var key: String {
        switch self {
        case .idle: "idle"
        case .recording, .processing: "live"
        case .done: "done"
        case .result: "result"
        case .error: "error"
        case .answer: "answer"
        }
    }
}

/// Layout of the dictation notch.
enum VoiceLayout {
    static let barCount = 34
    static let barWidth: CGFloat = 2.2
    static let barPitch: CGFloat = 4.4
    static let barMaxHeight: CGFloat = 24

    /// A level (0–100) lifted so quiet speech still moves the bars: its square root, 0–100.
    static func displayLevel(_ level: Int) -> Double {
        100 * (Double(max(level, 0)) / 100).squareRoot()
    }

    /// Bar `i` of `n`: its height (tallest in the middle, tapering to the ends) and opacity.
    static func bar(_ i: Int, of n: Int, level: Int, maxHeight: CGFloat) -> (height: CGFloat, opacity: Double) {
        let envelope = 0.5 - 0.5 * cos(2 * Double.pi * (Double(i) + 0.5) / Double(n))
        let t = min(displayLevel(level) / 100 * (0.25 + 0.75 * envelope), 1)
        let height = max(barWidth, CGFloat(t) * maxHeight)
        return (height, 0.35 + 0.65 * t)
    }
    static var wing: CGFloat { 96 * TextScale.factor }           // width added on each side of the notch
    static var barsBand: CGFloat { 30 * TextScale.factor }
    static var textLine: CGFloat { 18 * TextScale.factor }
    static var bottomPadding: CGFloat { 8 * TextScale.factor }
    static var resultWidth: CGFloat { 440 * TextScale.factor }
    static var liveFont: NSFont { NSFont.systemFont(ofSize: 12 * TextScale.factor) }
    static var doneWing: CGFloat { 72 * TextScale.factor }
    static let liveMaxLines = 2
    static var resultFont: NSFont { NSFont.systemFont(ofSize: 13 * TextScale.factor) }
    static let resultTextInset: CGFloat = NotchText.inset
    static let resultMaxLines = 3
}

/// Layout of the notes notch.
enum NotesLayout {
    static var wing: CGFloat { 76 * TextScale.factor }          // compact live indicator beside the notch (fits 1:02:34)
    static var thinkingWing: CGFloat { 96 * TextScale.factor }
    static var meetingWing: CGFloat { 118 * TextScale.factor }
    static var toastWing: CGFloat { 112 * TextScale.factor }
    /// The launch hello's wings: room for the mark and "Starlight" (wider than "Notch" was).
    static var launchWing: CGFloat { 112 * TextScale.factor }
    static var musicWing: CGFloat { 40 * TextScale.factor }
    static var musicHoverWing: CGFloat { 132 * TextScale.factor }
    /// Extra height in the open notch for the media row.
    static var mediaRow: CGFloat { 63 * TextScale.factor }   // the row and the progress line under it
    static var captionFont: NSFont { NSFont.systemFont(ofSize: 12.5 * TextScale.factor) }
    static let captionMaxLines = 2
    static var captionWidth: CGFloat { answerWidth - 2 * NotchText.inset }
    static var expandedWidth: CGFloat { 440 * TextScale.factor }
    static let visibleRows = 3
    static var rowHeight: CGFloat { 22 * TextScale.factor }
    static var footer: CGFloat { 36 * TextScale.factor }
    static var doneWidth: CGFloat { 460 * TextScale.factor }
    static let doneRows = 3
    /// The finished meeting: one big line, a soft line under it.
    static var doneTitle: CGFloat { 30 * TextScale.factor }
    static var doneDetail: CGFloat { 16 * TextScale.factor }
    static var windowHeight: CGFloat { 380 * TextScale.factor }
    static var answerWidth: CGFloat { 460 * TextScale.factor }
    static var answerFont: NSFont { NSFont.systemFont(ofSize: 13 * TextScale.factor) }
    static let answerMaxLines = 3
    /// Long answers and code: a wider card, up to this tall, scrolling inside.
    static var longAnswerWidth: CGFloat { 580 * TextScale.factor }
    static var longAnswerMaxHeight: CGFloat {
        min(420, (NSScreen.main?.visibleFrame.height ?? 900) * 0.45)
    }
    /// A short fact, shown big ("Baku.", "1,000 USD is about 850 CHF.").
    static var headlineFont: NSFont { NSFont.systemFont(ofSize: 22 * TextScale.factor, weight: .semibold) }
    static let headlineMaxLines = 2
    static var detailFont: NSFont { NSFont.systemFont(ofSize: 12.5 * TextScale.factor) }
    static let detailMaxLines = 2
    /// "Added Buy milk", "Saved to memory": beside a check or a cross.
    static var outcomeFont: NSFont { NSFont.systemFont(ofSize: 15 * TextScale.factor, weight: .semibold) }
    static var outcomeBadge: CGFloat { 20 * TextScale.factor }
    /// An app or file that was opened, saved or moved: its icon and its name, big.
    static var itemHeight: CGFloat { 46 * TextScale.factor }
    /// The picture beside an answer.
    static var imageSize: CGFloat { 64 * TextScale.factor }
    /// The text column inside an answer card.
    static var answerTextWidth: CGFloat { answerWidth - 2 * NotchText.inset }
    /// The approval card: title row, the command, the buttons.
    static var approvalDetailFont: NSFont { NSFont.monospacedSystemFont(ofSize: 12 * TextScale.factor, weight: .regular) }
    static let approvalDetailMaxLines = 9
}

/// How the notch moves. Every change of shape runs on one of these springs; content inside
/// fades and scales on the content springs.
enum Motion {
    /// Pointer arrives: a quick, lively swell with a little bounce.
    static let hoverIn = Animation.spring(response: 0.36, dampingFraction: 0.5, blendDuration: 0)
    /// Closing and pointer leaving: settles without bouncing.
    static let close = Animation.spring(response: 0.38, dampingFraction: 0.96, blendDuration: 0)
    /// Opening: a bit slower, with a small overshoot so it feels like it pops out.
    static let open = Animation.spring(response: 0.46, dampingFraction: 0.66, blendDuration: 0)
    /// Press: gives a little under your finger.
    static let press = Animation.spring(response: 0.42, dampingFraction: 0.6, blendDuration: 0)

    /// The closed shape is a little wider than the hardware notch, so its soft edge never shows;
    /// +1 height because the window starts 1pt above the screen.
    static let closedExtra = CGSize(width: 6, height: 1)
    /// How much bigger the notch gets under the pointer.
    static let hoverGrow = CGSize(width: 18, height: 7)
    /// Pressing gives back some of that.
    static let pressFraction: CGFloat = 0.55

    /// Content inside the notch comes in a moment after the shape starts to grow, and leaves fast.
    static let contentIn = Animation.spring(response: 0.32, dampingFraction: 1, blendDuration: 0).delay(0.08)
    static let contentOut = Animation.spring(response: 0.18, dampingFraction: 1, blendDuration: 0)
    /// Hidden content: blurred, smaller, scaled toward the top of the notch.
    static let contentBlur: CGFloat = 22
    static let contentHiddenScale: CGFloat = 0.8
    static let contentAnchor = UnitPoint(x: 0.5, y: 0)

    /// The notch casts a soft shadow while it's hovered or open.
    static let shadowOpacity = 0.6
    static let shadowRadius: CGFloat = 18
    static let shadowY: CGFloat = 6
}

/// Something the agent said during a session, with when (seconds since it started).
struct AgentReply: Identifiable, Equatable {
    var id = UUID()
    let time: TimeInterval
    var text: String
    /// The line it answers, when you asked for it by double-clicking that line.
    var answering: UUID? = nil
    /// Still being written (the icon turns; empty text shows "Thinking").
    var streaming = false
    /// An action's result: a check or a cross beside the text.
    var outcome: Outcome? = nil
    /// A picture of what the answer names.
    var image: NSImage? = nil
    /// The notch card it came from, so a picture that arrives later finds it.
    var card: UUID? = nil
    /// The saved-meeting moment it comes from.
    var link: MeetingMoment? = nil
    /// "from apnews.com": where a searched answer came from.
    var source: String? = nil
}

/// One run of the countdown ring beside a dictation result.
struct ResultTimer: Equatable {
    var id = UUID()
    let duration: Double
}

final class NotchModel: ObservableObject {
    @Published var state: NotchState = .closed
    @Published var hovering = false
    @Published var pressing = false
    /// Physical notch size; the drawn shape adds Motion.closedExtra.
    @Published var notchSize = CGSize(width: 185, height: 33.5)

    /// The open notch: room for the clock and the three options.
    @Published var openSize = CGSize(width: 580, height: 150)
    @Published var slowMotion: Double = 1
    @Published var showOutline = false

    @Published var voice: VoicePhase = .idle
    @Published var levels: [Int] = Array(repeating: 0, count: VoiceLayout.barCount)
    @Published var partial = ""
    @Published var recordingStart = Date()
    @Published var engineName = ""
    @Published var engineStatus: EngineStatus = .idle
    @Published var cleanupState: CleanupModel.State = .missing
    /// Starts the cleanup model download again after it failed.
    var cleanupRetry: (() -> Void)?
    @Published var processingLabel = "Transcribing"
    /// The result's auto-dismiss countdown; nil while it's held (pointer over the notch).
    @Published var resultTimer: ResultTimer?
    @Published var notes: NotesPhase = .idle
    @Published var noteItems: [NoteItem] = []
    /// Bumped to make the notch redraw at its current size (see AppDelegate's close watchdog).
    @Published var redraw = 0
    @Published var notesStart = Date()
    /// Notes are paused: nothing is heard; the timer shows `pausedElapsed`.
    @Published var notesPaused = false
    /// Notes (a meeting) or Live mode (talking to Starlight); same session, different manner.
    enum SessionKind { case notes, live }
    @Published var sessionKind: SessionKind = .notes
    /// The last dictation was pasted into a text field (the notch says "Pasted").
    @Published var dictationPasted = false
    /// The finished card's auto-close countdown, and whether you asked it to stay.
    @Published var notesDoneTimer: ResultTimer?
    @Published var notesDoneKept = false
    var pausedElapsed: TimeInterval = 0
    @Published var notesLevels: [Int] = Array(repeating: 0, count: 10)
    /// Hovering the notch while listening shows your latest questions and points.
    @Published var notesExpanded = false
    /// The agent's replies this session, for the live transcript.
    @Published var agentReplies: [AgentReply] = []
    /// The live transcript panel is open: the notch keeps to its timer and voice bars.
    @Published var transcriptOpen = false
    /// What Spotify or Music is playing (mirrors NowPlaying), shown beside the closed notch.
    @Published var nowPlaying: NowPlaying.Track?
    /// A brief note beside the camera (headphones connecting), gone after a few seconds.
    @Published var toast: Toast?

    struct Toast: Equatable {
        var id = UUID()
        let icon: Glyph.Kind
        let title: String
        /// The device's battery, 0…100, when it reports one.
        var battery: Int? = nil
        /// Left of the camera instead of the battery ("Listening only"); a device without a battery
        /// says "Connected".
        var detail: String? = nil
    }

    /// A short notice beside the camera ("Silent · Listening only"), gone after a moment.
    func flash(_ toast: Toast, for seconds: Double = 2.2) {
        guard !voice.isActive, !notes.isActive, !isOpen else { return }
        withAnimation(scaled(Motion.open)) { self.toast = toast }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.toast?.id == toast.id else { return }
            withAnimation(self.scaled(Motion.close)) { self.toast = nil }
        }
    }

    /// Battery of the headphones connected now, for the open notch (refreshed when it opens).
    @Published var headphonesBattery: HeadphonesBattery?

    struct HeadphonesBattery: Equatable {
        let name: String
        let percent: Int
    }

    /// Monitor mode (Settings → General): the notch tucks away while nothing's happening.
    @Published var hidesIdle = false

    /// Tucked away: hidden at rest, with nothing to show. Only the sliver above the screen's top
    /// edge is drawn; hovering where the notch would be brings it back.
    var isTucked: Bool {
        hidesIdle && !hovering && !isOpen && !voice.isActive && !notes.isActive && tutorial == nil && !launching
            && meetingPrompt == nil && toast == nil
    }

    /// Music shows beside the closed notch when nothing else is using it.
    var showsMusic: Bool {
        nowPlaying != nil && !voice.isActive && !notes.isActive && meetingPrompt == nil && toast == nil
    }

    /// A meeting just started and Starlight is offering to take notes (Settings → Notes → Meetings).
    @Published var meetingPrompt: MeetingApp?

    /// Names you gave the other speakers during this session ("2" → "Dana").
    @Published var speakerNames: [String: String] = [:]
    /// The ones Starlight worked out itself (SpeakerNaming); a name you type is never in here.
    @Published var guessedSpeakerNames: Set<String> = []

    func speakerName(_ item: NoteItem) -> String {
        if item.isMine { return "You" }
        guard let id = item.speakerID else { return "Them" }
        return speakerNames[id] ?? "Speaker \(id)"
    }

    /// How their lines are labelled for the agent: "Them (Dana)", "Them (Speaker 2)" or "Them".
    func agentLabel(_ id: String?) -> String {
        guard let id else { return "Them" }
        return "Them (\(speakerNames[id] ?? "Speaker \(id)"))"
    }

    /// Your words so far in the phrase you're saying (empty between phrases).
    @Published var liveCaption = ""
    /// Deep answers and double-clicked lines in progress: the notch says "Thinking".
    @Published var thinkingCount = 0
    var agentThinking: Bool { thinkingCount > 0 }
    /// Lines you double-clicked that the agent is answering right now.
    @Published var answeringLines: Set<UUID> = []
    /// The live answer under the notch during notes, and its auto-dismiss countdown.
    @Published var liveAnswer: LiveAnswer?
    @Published var liveAnswerTimer: ResultTimer?
    /// The agent wants to do something on your Mac and is waiting for your click.
    @Published var approval: Approval?
    /// The welcome tour's lesson for this step, shown in the notch ("hello", "This is Starlight").
    struct Tutorial: Hashable {
        let title: String
        let detail: String
        /// Small, beside the camera, asking to be hovered; the notch still opens when you do.
        var invite = false
        /// The invite was taken: a check and "Nice." once the notch is closed again.
        var learned = false
        /// The hello: "Starlight" set big beside the mark, instead of a title.
        var wordmark = false
        /// Where the tour is (0-based) of how many steps, shown as dots under the card.
        var progress: Int?
        var steps = 0
        /// The voice model downloading behind the tour, 0…1 (shown as a bar under the card).
        var download: Double?
        /// A shortcut to press, as big keys under the line ("Control + Space").
        var keys: String?
    }
    @Published var tutorial: Tutorial?
    /// The hello when Starlight starts: the notch spreads its wings for a moment, then settles.
    @Published var launching = false

    /// Plays the launch: out on the open spring, back on the close one. Reduce Motion: a fade.
    func playLaunch() {
        guard !voice.isActive, !notes.isActive else { return }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(still ? .easeOut(duration: 0.3) : scaled(Motion.open)) { launching = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            withAnimation(still ? .easeOut(duration: 0.3) : self.scaled(Motion.close)) { self.launching = false }
        }
    }
    /// Set by the PNG renderer, which can't draw AppKit layers.
    var drawsBarsInSwiftUI = false

    /// Set by the Lab buttons so pointer tracking doesn't immediately undo them.
    var pinned = false

    var isOpen: Bool { state == .open }
    /// The notch casts its shadow while it's hovered, open, or showing something.
    var isShadowed: Bool { isOpen || hovering || launching || meetingPrompt != nil || toast != nil || voice.isActive || (notes.isActive && (notes != .listening || notesExpanded)) }

    /// The closed shape: the hardware notch plus a hair, so its edge never shows.
    var closedSize: CGSize {
        CGSize(width: notchSize.width + Motion.closedExtra.width, height: notchSize.height + Motion.closedExtra.height)
    }

    /// The frame the NotchShape is laid out in. Animating this drives the whole morph.
    var size: CGSize {
        if voice.isActive { return voiceSize(voice, partial: partial) }
        if notes.isActive { return notesSize }
        if let tutorial, !tutorial.invite {
            let s = TextScale.factor
            return CGSize(width: NotesLayout.answerWidth - 40,
                          height: closedSize.height + (tutorial.wordmark ? 78 : tutorial.detail.isEmpty ? 44 : 62) * s
                              + (tutorial.progress != nil ? 16 * s : 0) + (tutorial.download != nil ? 30 * s : 0)
                              + (tutorial.keys != nil ? 50 * s : 0))
        }
        if let tutorial, tutorial.invite, !isOpen, !hovering {
            return CGSize(width: closedSize.width + 2 * NotesLayout.toastWing, height: closedSize.height)
        }
        if launching { return CGSize(width: closedSize.width + 2 * NotesLayout.launchWing, height: closedSize.height) }
        if meetingPrompt != nil && !isOpen {
            return CGSize(width: closedSize.width + 2 * NotesLayout.meetingWing, height: closedSize.height)
        }
        if toast != nil && !isOpen {
            return CGSize(width: closedSize.width + 2 * NotesLayout.toastWing, height: closedSize.height)
        }
        if isOpen {
            let open = openContentSize
            return CGSize(width: max(open.width, closedSize.width), height: max(open.height, closedSize.height))
        }
        // Tucked away: up into the bezel, where the window starts above the screen.
        if isTucked { return CGSize(width: closedSize.width, height: Motion.closedExtra.height) }
        // Music: its sides at rest; hovering grows it into a mini player (not the full notch).
        if showsMusic && hovering {
            return CGSize(width: closedSize.width + 2 * NotesLayout.musicHoverWing, height: closedSize.height + NotesLayout.mediaRow)
        }
        var s = closedSize
        if showsMusic { s.width += 2 * NotesLayout.musicWing }
        if hovering {
            let k: CGFloat = pressing ? Motion.pressFraction : 1
            s.width += Motion.hoverGrow.width * k
            s.height += Motion.hoverGrow.height * k
        }
        return s
    }

    /// The open notch's size. Music lives beside the closed notch, not in here.
    var openContentSize: CGSize { CGSize(width: openSize.width * TextScale.factor, height: openSize.height * TextScale.factor) }

    /// Shown under the bars while recording if the voice model isn't ready yet.
    var statusLine: String? {
        guard partial.isEmpty, case .loading(let label, let fraction) = engineStatus else { return nil }
        if let fraction, fraction > 0 { return "\(label) · \(Int(fraction * 100))%" }
        return label + "…"
    }

    func voiceSize(_ phase: VoicePhase, partial: String) -> CGSize {
        let c = closedSize
        let wide = c.width + 2 * VoiceLayout.wing
        switch phase {
        case .idle:
            return c
        case .recording:
            // Your words wrap to two lines inside the notch (then scroll, fading at the top).
            let text: CGFloat = !partial.isEmpty
                ? NotchText.height(partial, font: VoiceLayout.liveFont, width: wide - 2 * NotchText.inset, maxLines: VoiceLayout.liveMaxLines) + 4
                : statusLine == nil ? 0 : VoiceLayout.textLine
            return CGSize(width: wide, height: c.height + VoiceLayout.barsBand + text + VoiceLayout.bottomPadding)
        case .processing:
            return CGSize(width: wide, height: c.height + VoiceLayout.barsBand + VoiceLayout.bottomPadding)
        case .done:
            return CGSize(width: c.width + 2 * VoiceLayout.doneWing, height: c.height)
        case .result(let text):
            return CGSize(width: VoiceLayout.resultWidth, height: c.height + 6 + Self.resultTextHeight(text) + 14)
        case .error:
            return CGSize(width: wide, height: c.height + VoiceLayout.textLine + 14)
        case .answer:
            if let approval { return CGSize(width: NotesLayout.answerWidth, height: c.height + Self.approvalHeight(approval) + 14) }
            if let card = liveAnswer { return CGSize(width: AnswerCardLayout(card).width, height: c.height + Self.liveAnswerHeight(card) + 14) }
            return CGSize(width: wide, height: c.height)
        }
    }

    /// Height of the result text at the result width, capped at `resultMaxLines`.
    static func resultTextHeight(_ text: String) -> CGFloat {
        NotchText.height(text, font: VoiceLayout.resultFont, width: VoiceLayout.resultWidth - 2 * VoiceLayout.resultTextInset,
                         maxLines: VoiceLayout.resultMaxLines)
    }

    var notesSize: CGSize {
        let c = closedSize
        switch notes {
        case .idle:
            return c
        case .listening where approval != nil:
            return CGSize(width: NotesLayout.answerWidth, height: c.height + Self.approvalHeight(approval!) + 14)
        case .listening where showsCaption:
            let text = NotchText.height(liveCaption, font: NotesLayout.captionFont, width: NotesLayout.captionWidth,
                                        maxLines: NotesLayout.captionMaxLines)
            return CGSize(width: NotesLayout.answerWidth, height: c.height + 4 + text + 14)
        case .listening where liveAnswer != nil && !notesExpanded && !transcriptOpen:
            return CGSize(width: AnswerCardLayout(liveAnswer!).width, height: c.height + Self.liveAnswerHeight(liveAnswer!) + 14)
        case .listening where notesExpanded:
            let rows = CGFloat(min(max(AppSettings.shared.tasksEnabled ? TaskStore.shared.open.count : 0, 1), NotesLayout.visibleRows))
            return CGSize(width: NotesLayout.expandedWidth, height: c.height + 8 + rows * NotesLayout.rowHeight + NotesLayout.footer)
        case .listening:
            // A little wider while the agent is thinking, to fit "Thinking" beside the camera.
            return CGSize(width: c.width + 2 * (agentThinking ? NotesLayout.thinkingWing : NotesLayout.wing), height: c.height)
        case .finishing:
            return CGSize(width: c.width + 2 * VoiceLayout.wing, height: c.height + 34)
        case .done:
            return CGSize(width: NotesLayout.doneWidth, height: c.height + 8 + NotesLayout.doneTitle + 2 + NotesLayout.doneDetail + 14 + 28 + 16)
        case .error:
            return CGSize(width: c.width + 2 * VoiceLayout.wing, height: c.height + VoiceLayout.textLine + 14)
        }
    }

    /// What the finished notch shows: up to three of your latest questions, topped up with your
    /// latest points, in the order you said them.
    static func doneLines(_ result: NotesResult) -> [NoteItem] {
        let questions = Array(result.questions.suffix(NotesLayout.doneRows))
        let points = Array(result.statements.suffix(NotesLayout.doneRows - questions.count))
        return (questions + points).sorted { $0.time < $1.time }
    }

    func setNotes(_ phase: NotesPhase) {
        guard phase != notes else { return }
        withAnimation(scaled(phase == .idle ? Motion.close : Motion.open)) {
            notes = phase
            if phase.isActive { hovering = false; pressing = false; state = .closed }
        }
    }

    /// Height of the answer card below the notch: question line, answer (or status), footer.
    static func liveAnswerHeight(_ card: LiveAnswer) -> CGFloat {
        4 + AnswerCardLayout(card).height
    }

    /// The approval card: title, the command in a box (or a file's name big), and Cancel / Run.
    static func approvalHeight(_ approval: Approval) -> CGFloat {
        if approval.subject != nil {
            let detail = approval.detail.isEmpty ? 0
                : 6 + NotchText.height(approval.detail, font: .systemFont(ofSize: 12), width: NotesLayout.answerTextWidth, maxLines: 2)
            return 6 + NotesLayout.itemHeight + detail + 12 + 26
        }
        let detail = NotchText.height(approval.detail, font: NotesLayout.approvalDetailFont,
                                      width: NotesLayout.answerTextWidth - 20, maxLines: NotesLayout.approvalDetailMaxLines)
        return 6 + 20 + 8 + (detail + 16) + 10 + 26
    }

    /// The caption line under the compact notch: on in settings, something being said, and
    /// nothing more important there (an answer, the hover list, the open transcript).
    var showsCaption: Bool {
        notes == .listening && AppSettings.shared.captionsNotch && !liveCaption.isEmpty
            && liveAnswer == nil && approval == nil && !notesExpanded && !transcriptOpen
    }

    /// Sets the live caption; the notch springs only when it appears or goes.
    func setCaption(_ text: String) {
        guard text != liveCaption else { return }
        if text.isEmpty != liveCaption.isEmpty {
            withAnimation(scaled(text.isEmpty ? Motion.close : Motion.open)) { liveCaption = text }
        } else {
            liveCaption = text
        }
    }

    /// Updates the card; the notch springs only when the card's height actually changes.
    func setLiveAnswer(_ card: LiveAnswer?) {
        // SwiftUI state must change on the main thread; anything else can deadlock it.
        guard Thread.isMainThread else { return DispatchQueue.main.async { self.setLiveAnswer(card) } }
        guard card != liveAnswer else { return }
        let resizes = (card == nil) != (liveAnswer == nil) || card?.id != liveAnswer?.id
            || card.map(Self.liveAnswerHeight) != liveAnswer.map(Self.liveAnswerHeight)
        if resizes {
            withAnimation(scaled(card == nil ? Motion.close : Motion.open)) { liveAnswer = card }
        } else {
            liveAnswer = card
        }
    }

    func setNotesExpanded(_ value: Bool) {
        guard value != notesExpanded else { return }
        withAnimation(scaled(value ? Motion.open : Motion.close)) { notesExpanded = value }
    }

    func addNote(_ item: NoteItem) {
        withAnimation(scaled(Motion.open)) { noteItems.append(item) }
    }

    /// Voice phases grow with the open spring and shrink back with the close spring.
    func setVoice(_ phase: VoicePhase) {
        guard phase != voice else { return }
        NotchTrace.mark("voice \(voice.key)->\(phase.key)")
        if Dev.env("STARLIGHT_DEBUG_VOICE") != nil {
            DebugLog.write("voice: \(voice.key) → \(phase.key), hovering \(hovering), open \(isOpen)")
        }
        withAnimation(scaled(phase == .idle ? Motion.close : Motion.open)) {
            voice = phase
            if phase.isActive { hovering = false; pressing = false; state = .closed }
        }
    }

    func setPartial(_ text: String) {
        guard voice == .recording, text != partial else { return }
        let width = closedSize.width + 2 * VoiceLayout.wing - 2 * NotchText.inset
        let height = { (t: String) in t.isEmpty ? 0 : NotchText.height(t, font: VoiceLayout.liveFont, width: width, maxLines: VoiceLayout.liveMaxLines) }
        if height(partial) != height(text) {
            withAnimation(scaled(Motion.open)) { partial = text }  // the notch grows when a line is added
        } else {
            partial = text
        }
    }

    /// Settings' animation speed, slowed further by the Lab's slow-motion slider.
    func scaled(_ base: Animation) -> Animation { base.speed(AppSettings.shared.animationSpeed / slowMotion) }

    /// Opening and closing each get their own spring.
    func set(_ new: NotchState) {
        guard new != state else { return }
        withAnimation(scaled(new == .open ? Motion.open : Motion.close)) {
            state = new
            if new == .open { pressing = false }
        }
        if new == .open { haptic() }
    }

    func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        withAnimation(scaled(value ? Motion.hoverIn : Motion.close)) { hovering = value }
        if value && !isOpen { haptic() }
    }

    func setPressing(_ value: Bool) {
        guard value != pressing else { return }
        withAnimation(scaled(Motion.press)) { pressing = value }
    }

    /// After the spring has started, on the next turn of the run loop: the trackpad call never
    /// holds up the first frame.
    private func haptic() {
        guard AppSettings.shared.haptics else { return }
        DispatchQueue.main.async { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    /// The hardware notch: the gap between the screen's two menu bar areas, as tall as the safe area.
    static func physicalNotchSize(for screen: NSScreen) -> CGSize? {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        let width = screen.frame.width - left.width - right.width
        let height = screen.safeAreaInsets.top
        return width > 0 && height > 0 ? CGSize(width: width, height: height) : nil
    }
}


/// A light tap on the trackpad (when Haptics is on), for snapping things into place.
/// Taps on the Force Touch trackpad, felt while your finger's on it. Off with Settings → haptics.
enum Haptics {
    /// A small click: a task ticked, a pill snapping into place.
    static func snap() { perform(.alignment) }
    /// Something starting: dictation, Live, notes, a card asking for you.
    static func start() { perform(.levelChange) }
    /// Something ending.
    static func stop() { perform(.generic) }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard AppSettings.shared.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}


/// The notch's text size (Settings → General → Text size). Fonts, the widths text wraps in and the
/// line heights all scale together, so a bigger size gets a wider card instead of cut-off text;
/// the closed notch still matches the hardware.
enum TextScale {
    nonisolated(unsafe) static var factor: CGFloat = 1
}

extension Font {
    /// `.system(size:)` at the notch's text size.
    static func notch(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * TextScale.factor, weight: weight, design: design)
    }
}
