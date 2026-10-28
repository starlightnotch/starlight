import AppKit
import Combine

/// Live mode's key (Option Space, or Fn or another key on its own). Toggle, the default: press it
/// to start a Live conversation and again to end it. Hold: hold it, say "open Weather" or "who is
/// Magnus Carlsen", let go: the words go to the agent, which answers in the notch or just does it.
///
/// - Listening looks like dictation: the bars, your words as you say them.
/// - The answer is Live mode's card, from a session of its own, so follow-ups within two minutes
///   ("how old is he?") know what came before.
/// - During a notes or Live session the words go to that session instead.
final class AskController {
    private let model: NotchModel
    private let voice: VoiceController
    private let notes: NotesController
    private let settings = AppSettings.shared
    private lazy var asker: LiveAnswers = {
        let live = LiveAnswers(model: model)
        live.isLive = true  // asked to open, save or move something, it does
        live.direct = true  // and it always answers
        live.onNothing = { [weak self] in
            guard let self, self.waiting else { return }
            self.waiting = false
            self.timeout?.cancel()
            self.voice.answerFailed("Didn't catch a question there")
        }
        return live
    }()

    private var loneKey: LoneKeyMonitor?
    private var comboKey: HotKey?
    private var bound: (AskKey, AppSettings.KeyMode)?
    private var boundTrusted = false
    /// A lone key pressed with another (Fn + F): someone's shortcut, so letting go does nothing.
    private var chorded = false
    private var settingsObserver: AnyCancellable?
    private var cardObserver: AnyCancellable?
    private var approvalObserver: AnyCancellable?

    /// Between sending the words and the card (or an approval) showing up.
    private var waiting = false
    private var timeout: DispatchWorkItem?
    /// A lone key starts listening only once it's been held a moment: a tap of Fn stays a tap.
    private var holdWork: DispatchWorkItem?
    private var listening = false
    private var lastAsked: Date?
    /// Follow-ups within this long carry on the same conversation.
    private let followUpWindow: TimeInterval = 120
    private let holdDelay: TimeInterval = 0.15

    init(model: NotchModel, voice: VoiceController, notes: NotesController) {
        self.model = model
        self.voice = voice
        self.notes = notes
        voice.onAsk = { [weak self] text in self?.ask(text) }
        voice.onAnswerHover = { [weak self] over in self?.asker.hold(over) }
        voice.onAnswerClosed = { [weak self] in self?.closed() }
        cardObserver = model.$liveAnswer.dropFirst().sink { [weak self] card in
            DispatchQueue.main.async { self?.cardChanged(card) }
        }
        approvalObserver = model.$approval.dropFirst().sink { [weak self] approval in
            DispatchQueue.main.async { self?.approvalChanged(approval) }
        }
        apply()
        settingsObserver = settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.apply() }
        }
    }

    /// (Re)binds the key when it or its mode changes; off while a shortcut is being recorded, and
    /// while Live mode is off (the key is free for other apps then).
    func apply() {
        if settings.recordingShortcut || !settings.liveEnabled {
            loneKey = nil; comboKey = nil; bound = nil
            return
        }
        // Key monitors made before Accessibility was allowed never hear anything: made again once it is.
        let trusted = AXIsProcessTrusted()
        let wanted = (settings.askKey, settings.liveKeyMode)
        guard bound.map({ $0 != wanted }) ?? true || trusted != boundTrusted else { return }
        boundTrusted = trusted
        loneKey = nil
        comboKey = nil
        let hold = wanted.1 == .hold
        switch wanted.0 {
        case .lone(let key):
            let monitor = LoneKeyMonitor(key)
            if hold {
                monitor.onDown = { [weak self] in self?.keyDown(delayed: true) }
                monitor.onUp = { [weak self] in self?.keyUp() }
                monitor.onCancel = { [weak self] in self?.keyCancelled() }
            } else {
                // Toggled by a tap: on letting go, unless it was part of another shortcut.
                monitor.onDown = { [weak self] in self?.chorded = false }
                monitor.onCancel = { [weak self] in self?.chorded = true }
                monitor.onUp = { [weak self] in if self?.chorded == false { self?.notes.toggleLive() } }
            }
            loneKey = monitor
            bound = wanted
        case .combo(let combo):
            comboKey = hold
                ? HotKey(combo, onPress: { [weak self] in self?.keyDown(delayed: false) }, onRelease: { [weak self] in self?.keyUp() })
                : HotKey(combo, onPress: { [weak self] in self?.notes.toggleLive() })
            bound = comboKey?.status == noErr ? wanted : nil
        }
    }

    // MARK: The key

    /// The mic starts the moment the key goes down, so a question asked straight away is heard
    /// from its first word. A lone key is only shown (notch, sound) once it's clearly held.
    private func keyDown(delayed: Bool) {
        holdWork?.cancel()
        holdWork = nil
        guard model.notes != .finishing else { return }
        listening = true
        voice.askDown(revealAfter: delayed ? holdDelay : 0)
    }

    private func keyUp() {
        holdWork?.cancel()
        holdWork = nil
        guard listening else { return }
        listening = false
        voice.askUp()
    }

    /// Fn + another key: a shortcut of its own. Listening that already started is dropped.
    private func keyCancelled() {
        holdWork?.cancel()
        holdWork = nil
        guard listening else { return }
        listening = false
        // Recording, shown or not yet: Fn + another key is someone's shortcut, not a question.
        if voice.intent == .ask, model.voice == .recording || model.voice == .idle { voice.cancel() }
    }

    // MARK: Asking

    private func ask(_ text: String) {
        // A notes or Live session is listening already: it answers, in its own card.
        if model.notes == .listening {
            voice.dismiss()
            notes.live.typed(text)
            return
        }
        guard settings.hasAnswerKey else { return voice.answerFailed("Add a key in Agent settings") }
        let fresh = lastAsked.map { Date().timeIntervalSince($0) > followUpWindow } ?? true
        if fresh { asker.begin(start: Date(), meeting: { [] }) } else { asker.dismiss() }
        lastAsked = Date()
        waiting = true
        asker.typed(text)
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.waiting else { return }
            self.waiting = false
            self.voice.answerFailed("No answer came back")
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func cardChanged(_ card: LiveAnswer?) {
        guard model.notes != .listening else { return }
        if card != nil, waiting {
            waiting = false
            timeout?.cancel()
            voice.showAnswer()
        } else if card == nil, model.approval == nil, model.voice == .answer {
            // Its time ran out: the card is gone, so the notch closes.
            voice.dismiss()
        }
    }

    private func approvalChanged(_ approval: Approval?) {
        guard model.notes != .listening else { return }
        if approval != nil, waiting || model.voice == .answer {
            // The agent wants a yes first (Run, Move to Trash): ask in the notch, and give it time.
            timeout?.cancel()
            voice.showAnswer()
        }
        // Answered: the agent goes on, and its card replaces the approval.
        if approval == nil, model.voice == .answer, model.liveAnswer == nil { waiting = true; extendTimeout() }
    }

    private func extendTimeout() {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.waiting else { return }
            self.waiting = false
            if self.model.voice == .answer { self.voice.dismiss() }
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// The answer was put away (Esc, a click elsewhere, a new question): nothing more lands.
    private func closed() {
        waiting = false
        timeout?.cancel()
        guard model.notes != .listening else { return }
        asker.dismiss()
        Task { @MainActor in Approvals.shared.cancelAll() }
    }
}
