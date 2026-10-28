import AppKit
import Foundation
import SwiftUI

/// When one phrase of speech ended, was cut, and came back as text.
struct PhraseTiming {
    let spoke: Date
    let cut: Date
    let transcribed: Date
}

/// The answer card under the notch during a notes session.
struct LiveAnswer: Equatable, Identifiable {
    var id = UUID()
    let question: String
    var text = ""
    /// While a tool is working: "Calculating", "Searching the web", "Reading apnews.com".
    var status: String? = nil
    var statusGlyph: Glyph.Kind = .agent
    /// The latest tool line, e.g. "15 × 23 + 7 = 352".
    var toolLine: (glyph: Glyph.Kind, text: String)?
    var finished = false
    var failed = false
    /// An action's result: a green check or a red cross.
    var outcome: Outcome?
    /// A picture of what the answer names, once it has loaded.
    var image: NSImage?
    /// The saved-meeting moment it comes from.
    var link: MeetingMoment?

    static func == (a: LiveAnswer, b: LiveAnswer) -> Bool {
        a.id == b.id && a.text == b.text && a.status == b.status && a.toolLine?.text == b.toolLine?.text
            && a.finished == b.finished && a.failed == b.failed && a.outcome == b.outcome && a.image === b.image && a.link == b.link
    }
}

/// A live conversation with the agent during notes. Everything you say goes to it, not just
/// questions; it decides when it has something worth saying (an answer, a follow-up, a fix, a
/// quick tip) and stays quiet otherwise.
///
/// - Turns: phrases are collected until you've stopped talking (no speech, nothing still being
///   transcribed, then `settle` seconds), and sent together. "What is the price of… from
///   Walmart, pick one" arrives as one turn, not three.
/// - Memory of the conversation: each turn goes with the earlier ones and the agent's replies, so
///   "like what?", "would you agree?" and corrections make sense.
/// - Interruptions: if you add words while it's still answering, that answer is dropped and the
///   turn is resent with them ("no, I said shoes, not gold"). Only your voice interrupts; the
///   other side talking doesn't cancel an answer meant for you.
/// - Both sides: lines are labelled "Me:" and "Them:"; you speaking holds a turn back, their
///   speech just adds to it.
/// - Quiet by default: the card only appears once there's text or a tool is working.
final class LiveAnswers {
    private let model: NotchModel
    private let settings = AppSettings.shared
    /// Called with each finished answer: what was said, and the reply.
    var onAnswer: ((String, String) -> Void)?
    /// A turn ended with nothing to say (a SKIP, an empty search).
    var onNothing: (() -> Void)?
    /// A complex question is being answered: show the transcript, where there's room for it.
    var onLongAnswer: (() -> Void)?

    /// Quiet after the last phrase before a turn is sent.
    static let settle: TimeInterval = 0.7
    /// A complete question ("…?" that doesn't trail off): a shorter wait is enough.
    static let questionSettle: TimeInterval = 0.3
    /// When only they've spoken since, a little longer: they're often mid-thought.
    static let theirSettle: TimeInterval = 1.2
    /// When you stop mid-sentence ("what is the price of"), how long to wait for the rest.
    static let unfinishedSettle: TimeInterval = 3

    /// Ends on a word that can't end a sentence: an article, preposition, conjunction or a bare
    /// "is", so more is probably coming.
    static func soundsUnfinished(_ text: String) -> Bool {
        let last = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(separator: " ").last.map(String.init) ?? ""
        let dangling: Set<String> = ["the", "a", "an", "of", "to", "for", "in", "on", "at", "with", "from", "by", "about", "and",
                                     "or", "but", "so", "because", "is", "are", "was", "what's", "whats", "my", "your", "our",
                                     "their", "if", "than", "like", "um", "uh"]
        return dangling.contains(last)
    }

    typealias Phrase = (speaker: Speaker, text: String, label: String, timing: PhraseTiming?)

    /// Live mode (see NotesController.startLive): everything you say is for Starlight.
    var isLive = false
    /// Hold to ask: every turn is a question asked on purpose, so it's always answered.
    var direct = false

    private var history: [AgentTurn] = []
    private var pending: [Phrase] = []
    /// Your phrase so far, sent at a short pause before the phrase officially ended. Confirmed
    /// (kept) when the full phrase says the same; dropped if you go on.
    private var earlyText: String?
    private var speaking = false
    private var transcribing = 0
    private var settleWork: DispatchWorkItem?
    /// The turn being answered. Until `revealAt` it's a head start: asked as soon as you paused,
    /// shown only once you've clearly finished, and dropped if you go on talking.
    private var current: (id: UUID, phrases: [Phrase], task: Task<Void, Never>, revealAt: Date)?
    /// The answer in flight is a long one (code, math): talking doesn't cancel it.
    private var currentIsLong = false
    private var meeting: () -> [NoteItem] = { [] }
    private var start = Date()

    private var dismissWork: DispatchWorkItem?
    private var hovering = false
    private var warnedNoKey = false
    /// Between begin() and end(); phrases transcribed after you stop aren't sent.
    private var active = false

    init(model: NotchModel) { self.model = model }

    /// STARLIGHT_NO_LIVE=1 turns live answers off for a test run (no key read, no requests).
    private static let enabledForThisRun = Dev.env("STARLIGHT_NO_LIVE") == nil

    /// A notes session started.
    /// After a pause: times carry on from where they stopped.
    func shiftStart(by seconds: TimeInterval) { start = start.addingTimeInterval(seconds) }

    /// Which session this is, and the double-click answers in flight for it.
    private var session = 0
    private var lineAnswers: [Task<Void, Never>] = []

    func begin(start: Date, meeting: @escaping () -> [NoteItem]) {
        self.start = start
        self.meeting = meeting
        history = []
        pending = []
        speaking = false
        transcribing = 0
        warnedNoKey = false
        active = true
        // Answers to double-clicked lines from the last session finish, but go nowhere.
        session += 1
        lineAnswers.forEach { $0.cancel() }
        lineAnswers = []
        // Nothing carries over from the last session: an answer still in flight, a head start,
        // the pointer state, the notch's "Thinking".
        current?.task.cancel()
        current = nil
        currentIsLong = false
        earlyText = nil
        hovering = false
        model.thinkingCount = 0
        AnswerImage.warmUp()
        settleWork?.cancel()
        dismiss()
    }

    /// The session stopped: nothing new is sent; an answer already on its way still lands.
    func end() {
        active = false
        settleWork?.cancel()
        pending = []
        dismiss()
        Task { @MainActor in Approvals.shared.cancelAll() }
    }

    // MARK: Hearing

    /// Speech began (before any words are known). Only yours holds the turn back.
    func speechStarted(_ speaker: Speaker) {
        guard speaker == .me else { return }
        speaking = true
        settleWork?.cancel()
        dropHeadStart()
    }

    /// Speech stopped. `kept` is false when it was too short to transcribe.
    func speechEnded(_ speaker: Speaker, kept: Bool) {
        if speaker == .me { speaking = false }
        // The phrase the head start was for: wait for its text before deciding.
        if kept { transcribing += 1; if !(speaker == .me && earlyText != nil) { dropHeadStart() } }
        scheduleSend()
    }

    /// Your phrase so far, at a short pause (0.35 s) instead of the full one (0.8 s): asked now,
    /// shown after the usual settle, dropped if you keep talking.
    func early(_ text: String, timing: PhraseTiming) {
        // Live mode always answers; in meetings, only with "Answer questions as they come up" on.
        guard active, isLive || settings.liveAnswers, Self.enabledForThisRun, settings.hasAnswerKey, earlyText == nil, transcribing == 0 else { return }
        let plain = (pending.map(\.text) + [text]).joined(separator: " ")
        guard !Agent.wantsDeep(AgentRequest(question: plain, meeting: [], meetingStart: start, history: history).routing) else { return }
        settleWork?.cancel()
        interruptIfAnswering()
        dropHeadStart()
        earlyText = text
        pending.append((.me, text, "Me", timing))
        send(revealAt: Date().addingTimeInterval(Self.settle(after: text)), early: true)
    }

    /// Typed into the overlay: sent straight away, no waiting to see if you'll go on.
    func typed(_ text: String) {
        guard active else { return }
        settleWork?.cancel()
        interruptIfAnswering()
        pending.append((.me, text, "Me", nil))
        send(revealAt: Date(), early: true, explicit: true)
    }

    /// You went on after the short pause: the head start was for half a sentence.
    func resumed() {
        guard let early = earlyText else { return }
        earlyText = nil
        withdrawEarly(early)
    }

    /// The early phrase is out of date: take it back, from the turn in flight (even one already
    /// showing) or from what's waiting, so it isn't sent again alongside the full phrase.
    private func withdrawEarly(_ early: String) {
        if let c = current, c.phrases.contains(where: { $0.speaker == .me && $0.text == early }) {
            c.task.cancel()
            current = nil
            if model.liveAnswer?.id == c.id { model.setLiveAnswer(nil) }
            pending = c.phrases.filter { !($0.speaker == .me && $0.text == early) } + pending
            DebugLog.write("live: head start withdrawn, more was said")
        } else {
            removeEarly(early)
        }
    }

    /// Hours in: keep the recent conversation (the agent only reads the last 24 turns anyway).
    func trimHistory() {
        if history.count > 200 { history.removeFirst(history.count - 200) }
    }

    private func removeEarly(_ text: String) {
        if let index = pending.lastIndex(where: { $0.speaker == .me && $0.text == text }) { pending.remove(at: index) }
    }

    /// Long enough to read it: the usual time, or about 3.5 words a second for long ones, up
    /// to a minute and a half (hovering holds it, and long ones have a ×).
    static func readingTime(_ text: String) -> TimeInterval {
        let words = Double(text.split { $0.isWhitespace }.count)
        return min(max(AppSettings.shared.liveAnswerSeconds, words / 3.5), 90)
    }

    /// How long to wait after your words before showing an answer to them.
    static func settle(after text: String) -> TimeInterval {
        if soundsUnfinished(text) { return unfinishedSettle }
        return text.trimmingCharacters(in: .whitespaces).hasSuffix("?") ? questionSettle : settle
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces) }
        return norm(a) == norm(b)
    }

    /// A phrase came back from transcription (nil if it had no words).
    func heard(_ text: String?, from speaker: Speaker, label: String? = nil, timing: PhraseTiming? = nil) {
        transcribing = max(transcribing - 1, 0)
        if speaker == .me, let early = earlyText {
            earlyText = nil
            if let text, Self.same(text, early) {
                // The full phrase is what was already asked: the head start stands.
                if current == nil, let index = pending.lastIndex(where: { $0.speaker == .me && $0.text == early }) {
                    pending[index].text = text
                }
                DebugLog.write("live: head start confirmed")
                if current == nil { scheduleSend() }
                return
            }
            withdrawEarly(early)
        }
        if let text, !text.isEmpty {
            dropHeadStart()
            if speaker == .me { interruptIfAnswering() }
            pending.append((speaker, text, label ?? (speaker == .me ? "Me" : "Them"), timing))
        }
        scheduleSend()
    }

    /// "Me: …", "Them (Dana): …" lines, joined.
    private static func transcript(_ phrases: [Phrase]) -> String {
        var lines: [String] = []
        for phrase in phrases {
            let label = phrase.label + ":"
            if let last = lines.last, last.hasPrefix(label) { lines[lines.count - 1] += " " + phrase.text } else { lines.append("\(label) \(phrase.text)") }
        }
        return lines.joined(separator: "\n")
    }

    private func interruptIfAnswering() {
        // Waiting for your click: talking ("yes, run it") doesn't cancel the request.
        guard let current, !currentIsLong, model.approval == nil else { return }
        current.task.cancel()
        pending = current.phrases + pending
        self.current = nil
        if model.liveAnswer?.id == current.id { model.setLiveAnswer(nil) }
        DebugLog.write("live: interrupted, resending with the new words")
    }

    /// The answer's head start: the turn goes to the agent the moment its words are in, and
    /// the settle time runs alongside the model instead of before it. What you see is the same,
    /// it just arrives about `settle` sooner. Long answers (which open the transcript) still wait.
    private func scheduleSend() {
        settleWork?.cancel()
        guard active, isLive || settings.liveAnswers, Self.enabledForThisRun, !pending.isEmpty, !speaking, transcribing == 0 else { return }
        let lastMine = pending.last { $0.speaker == .me }?.text ?? ""
        let wait = !pending.contains { $0.speaker == .me } ? Self.theirSettle : Self.settle(after: lastMine)
        let plain = pending.map(\.text).joined(separator: " ")
        if !Agent.wantsDeep(AgentRequest(question: plain, meeting: [], meetingStart: start, history: history).routing) {
            return send(revealAt: Date().addingTimeInterval(wait))
        }
        let work = DispatchWorkItem { [weak self] in self?.send() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// More was said before the head start was due to show: drop it; the words go back and
    /// are asked again with the new ones.
    private func dropHeadStart() {
        guard let current, Date() < current.revealAt else { return }
        current.task.cancel()
        pending = current.phrases + pending
        self.current = nil
        DebugLog.write("live: head start dropped, more was said")
    }

    // MARK: Asking

    private func send(revealAt: Date = Date(), early: Bool = false, explicit: Bool = false) {
        guard active, !pending.isEmpty, early || !speaking, transcribing == 0 else { return }
        let phrases = pending
        pending = []
        let said = Self.transcript(phrases)
        // Silent mode: listening and taking notes, not answering, unless it's spoken to ("Starlight, …"),
        // asked to stop being silent, typed to, or asked directly (hold to ask).
        if settings.silentMode, !explicit, !direct {
            let mine = phrases.filter { $0.speaker == .me }.map(\.text).joined(separator: " ")
            guard SilentMode.spokenTo(mine) || SilentMode.command(mine) != nil else {
                DebugLog.write("live: silent, not answering")
                return
            }
        }
        // Timed from when you stopped talking (the last phrase's end).
        let last = phrases.last { $0.speaker == .me } ?? phrases.last
        let trace = Trace(.answer, label: said, origin: last?.timing?.spoke ?? Date())
        if let timing = last?.timing {
            trace.span(.endOfSpeech, "Pause that ends a phrase", from: timing.spoke, to: timing.cut)
            trace.span(.transcription, "Parakeet", from: timing.cut, to: timing.transcribed)
            trace.span(.endOfSpeech, "Waiting for more", from: timing.transcribed)
        }
        trace.mark("sent")

        guard settings.hasAnswerKey else {
            if !warnedNoKey {
                warnedNoKey = true
                show(LiveAnswer(question: said, text: "Add a key in Agent settings", finished: true, failed: true), seconds: 5)
            }
            return
        }

        let id = UUID()
        var request = AgentRequest(question: said, meeting: meeting(), meetingStart: start, history: history)
        request.live = isLive
        request.direct = direct
        let service = settings.answerService
        let started = Date()
        // Code, real math, long problems: the answer goes to the transcript, which has room;
        // the notch just says it's working on it.
        let long = Agent.wantsDeep(request.routing)
        let reply = AgentReply(time: Date().timeIntervalSince(start), text: "", streaming: true)
        if long {
            // Thinking shows at once: in the transcript (a placeholder row), in the notch, and on
            // the card, which then holds the whole answer, scrolling (no need for the overlay).
            model.agentReplies.append(reply)
            setThinking(true)
            update(id, said) { $0.status = "Thinking"; $0.statusGlyph = .agent }
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            // Read off the main thread: after a rebuild macOS may ask before releasing the key.
            guard let key = await self.settings.loadAnswerKey() else {
                // Not "nothing to say": the question never went anywhere. Say why, and where to fix it.
                DebugLog.write("live: couldn't read the \(service) key from the Keychain")
                let message = service == .notch ? "Sign in again in Settings → Account."
                    : "Couldn't read your API key. Paste it again in Settings → Answers."
                if long { self.setThinking(false); self.finishReply(reply, fallback: message) }
                self.finish(id, said: said, reply: nil, dismissIfEmpty: false, nothing: false)
                self.update(id, said) { $0.text = message; $0.failed = true; $0.finished = true; $0.status = nil }
                if self.model.liveAnswer?.id == id { self.scheduleDismiss(after: 6) }
                return
            }
            var text = ""
            var skipped = false
            var outcome: Outcome?
            var image: NSImage?
            var imageQuery: String?
            var revealed = false
            var searched = false
            var link: MeetingMoment?
            var source: String?
            // @MainActor matters: a nested func in a main-actor closure is *not* main-actor itself,
            // so without it the card was updated from a background thread and SwiftUI deadlocked
            // (the notch froze and stopped answering after a streamed answer).
            @MainActor func attempt(_ name: String) async throws {
                let events = Trace.$current.withValue(trace) {
                    HeadStart.$revealAt.withValue(revealAt) { Agent.ask(request, service: service, model: name, key: key) }
                }
                for try await event in events {
                    try Task.checkCancellation()
                    // The head start: the agent has been working since you paused; nothing shows
                    // until you've clearly finished.
                    if !revealed {
                        revealed = true
                        let wait = revealAt.timeIntervalSinceNow
                        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                    }
                    switch event {
                    case .text, .outcome: trace.mark("shown")
                    default: break
                    }
                    switch event {
                    case .status(let label, let glyph):
                        if glyph == .globe || glyph == .posts { searched = true }
                        self.update(id, said) { $0.status = label; $0.statusGlyph = glyph }
                    case .tool(let line):
                        if line.hasPrefix("from ") { source = line }
                        self.update(id, said) { $0.toolLine = ($0.statusGlyph, line) }
                    case .link(let moment):
                        link = moment
                        if long, let index = self.model.agentReplies.firstIndex(where: { $0.id == reply.id }) {
                            self.model.agentReplies[index].link = moment
                        }
                        self.update(id, said) { $0.link = moment }
                    case .outcome(let result):
                        outcome = result
                        if long { self.setOutcome(reply, result) }
                        self.update(id, said) { $0.outcome = result; $0.status = nil }
                    case .text(let delta):
                        text += delta
                        // A picture of what it names: fetched while the rest streams in.
                        if imageQuery == nil, let query = AnswerText.imageQuery(text) {
                            imageQuery = query
                            Task { @MainActor in
                                guard let loaded = await AnswerImage.load(query) else { return }
                                image = loaded
                                self.attachImage(loaded, card: id, reply: long ? reply.id : nil)
                            }
                        }
                        if long {
                            if text == delta { self.setThinking(false) }  // first words: done thinking
                            self.streamReply(reply, text)
                            self.update(id, said) { $0.text = text; $0.status = nil }
                        } else {
                            self.update(id, said) { $0.text = text; $0.status = nil }
                        }
                    case .skipped:
                        skipped = true
                    }
                }
            }
            do {
                try await attempt(AppSettings.model)
                try Task.checkCancellation()
                trace.mark("done")
                if let ready = trace.time("ready"), let shown = trace.shown, shown > ready {
                    trace.span(.endOfSpeech, "Held until you'd finished", from: ready, to: shown, path: nil)
                }
                if trace.shown != nil { Timings.shared.add(trace) }
                let cleaned = AnswerText.clean(text)
                // An action with nothing written after it: its confirmation is the reply.
                let answer = cleaned.isEmpty ? outcome?.text ?? "" : cleaned
                DebugLog.write(String(format: "live: %.2fs %@ → %@%@", Date().timeIntervalSince(started), said, skipped ? "SKIP" : answer,
                                      outcome.map { " [\($0.ok ? "✓" : "✗")]" } ?? ""))
                if long {
                    // Already in the transcript; the card only said it was working.
                    if text.isEmpty { self.setThinking(false) }
                    self.finishReply(reply, fallback: outcome?.text ?? (skipped ? "Nothing useful to add." : nil))
                    if self.current?.id == id { self.current = nil }
                    self.history.append(AgentTurn(user: said, assistant: skipped || answer.isEmpty ? nil : answer, searched: searched))
                    if !answer.isEmpty { self.onAnswer?(said, answer) }
                    if answer.isEmpty {
                        if self.model.liveAnswer?.id == id { self.dismiss() }
                    } else {
                        self.update(id, said) { $0.finished = true; $0.status = nil }
                        if self.model.liveAnswer?.id == id { self.scheduleDismiss(after: Self.readingTime(answer)) }
                    }
                    return
                }
                self.finish(id, said: said, reply: skipped || answer.isEmpty ? nil : answer, outcome: outcome, image: image,
                            searched: searched, link: link, source: source)
            } catch {
                // Interrupted: the words were put back and will be resent with the new ones.
                if Task.isCancelled || error is CancellationError {
                    // A long answer already has its row and "Thinking": close them.
                    if long {
                        if text.isEmpty { self.setThinking(false) }
                        self.finishReply(reply, fallback: nil)
                    }
                    return
                }
                DebugLog.write("live: failed: \(error.localizedDescription)")
                if long {
                    if text.isEmpty { self.setThinking(false); self.streamReply(reply, error.localizedDescription) }
                    self.finishReply(reply, fallback: nil)
                }
                self.finish(id, said: said, reply: nil, dismissIfEmpty: false, nothing: false)
                self.update(id, said) { $0.text = error.localizedDescription; $0.failed = true; $0.finished = true; $0.status = nil }
                if self.model.liveAnswer?.id == id { self.scheduleDismiss(after: 5) }
            }
        }
        current = (id, phrases, task, revealAt)
        currentIsLong = long
    }

    private func finish(_ id: UUID, said: String, reply: String?, outcome: Outcome? = nil, image: NSImage? = nil,
                        searched: Bool = false, link: MeetingMoment? = nil, source: String? = nil, dismissIfEmpty: Bool = true,
                        nothing: Bool = true) {
        if current?.id == id { current = nil }
        history.append(AgentTurn(user: said, assistant: reply, searched: searched))
        // Nothing to say after all (a SKIP after a tool, an empty search): the card that said
        // "Searching…" goes, rather than spinning until the next turn.
        guard let reply else {
            if dismissIfEmpty, model.liveAnswer?.id == id { dismiss() }
            // A real "nothing to add", not a failure (those show their own card).
            if nothing { onNothing?() }
            return
        }
        onAnswer?(said, reply)
        model.agentReplies.append(AgentReply(time: Date().timeIntervalSince(start), text: reply, outcome: outcome, image: image,
                                             card: id, link: link, source: source))
        update(id, said) { $0.finished = true; $0.status = nil }
        // A confirmation is read at a glance; an answer gets its full time.
        let seconds = outcome != nil && AnswerText.clean(model.liveAnswer?.text ?? "").isEmpty
            ? min(settings.liveAnswerSeconds, 4) : Self.readingTime(reply)
        if model.liveAnswer?.id == id { scheduleDismiss(after: seconds) }
    }

    /// A picture arrived: onto the card, and onto its transcript reply.
    private func attachImage(_ image: NSImage, card: UUID, reply: UUID?) {
        if model.liveAnswer?.id == card {
            var updated = model.liveAnswer!
            updated.image = image
            model.setLiveAnswer(updated)
        }
        if let index = model.agentReplies.firstIndex(where: { $0.id == reply || ($0.card == card && reply == nil) }) {
            model.agentReplies[index].image = image
        }
    }

    private func setOutcome(_ reply: AgentReply, _ outcome: Outcome) {
        if let index = model.agentReplies.firstIndex(where: { $0.id == reply.id }) { model.agentReplies[index].outcome = outcome }
    }

    /// The notch's "Thinking", counted so overlapping answers don't switch it off early.
    private func setThinking(_ on: Bool) {
        withAnimation(model.scaled(on ? Motion.open : Motion.close)) {
            model.thinkingCount = max(model.thinkingCount + (on ? 1 : -1), 0)
        }
    }

    /// A transcript reply is complete: its icon stops turning; an empty one gets `fallback` or goes.
    private func finishReply(_ reply: AgentReply, fallback: String?) {
        guard let index = model.agentReplies.firstIndex(where: { $0.id == reply.id }) else { return }
        model.agentReplies[index].streaming = false
        if model.agentReplies[index].text.isEmpty {
            if let fallback { model.agentReplies[index].text = fallback } else { model.agentReplies.remove(at: index) }
        }
    }

    /// Adds or updates a streaming reply in the transcript.
    private func streamReply(_ reply: AgentReply, _ text: String) {
        if let index = model.agentReplies.firstIndex(where: { $0.id == reply.id }) {
            model.agentReplies[index].text = text
        } else {
            var first = reply
            first.text = text
            model.agentReplies.append(first)
        }
    }

    // MARK: Answering a line on request

    /// Double-clicked in the transcript: answer that line now, whoever said it. The reply streams
    /// in under the line; it isn't cancelled by people talking and never comes back as SKIP.
    /// `deep`: nil decides (Settings → Agent), true for a worked answer, false for a quick one.
    func answer(_ item: NoteItem, deep: Bool? = nil) {
        guard !model.answeringLines.contains(item.id) else { return }
        guard settings.hasAnswerKey else {
            model.agentReplies.append(AgentReply(time: item.time + 0.001, text: "Add a key in Agent settings", answering: item.id))
            return
        }
        model.answeringLines.insert(item.id)
        setThinking(true)
        let who = item.isMine ? "Me" : "Them"
        let request = AgentRequest(
            question: "Answer this line now (the user double-clicked it): \(who): \(item.text)\nIf it's a question, answer it. If not, give the most useful thing to know or say about it. Don't reply SKIP.",
            meeting: meeting(), meetingStart: start, history: history, focus: item.text, focusIsMine: item.isMine, deep: deep)
        let service = settings.answerService, modelName = AppSettings.model
        let reply = AgentReply(time: item.time + 0.001, text: "", answering: item.id, streaming: true)
        model.agentReplies.append(reply)  // shows "Thinking" under the line right away

        let thisSession = session
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var stillThinking = true
            defer {
                self.model.answeringLines.remove(item.id)
                if stillThinking { self.setThinking(false) }
                self.finishReply(reply, fallback: "Nothing useful to add on that one.")
            }
            guard let key = await self.settings.loadAnswerKey() else { return }
            var text = ""
            var outcome: Outcome?
            var failed = false
            @MainActor func show(_ value: String) {
                if let index = self.model.agentReplies.firstIndex(where: { $0.id == reply.id }) { self.model.agentReplies[index].text = value }
            }
            do {
                for try await event in Agent.ask(request, service: service, model: modelName, key: key) {
                    switch event {
                    case .text(let delta):
                        if stillThinking { stillThinking = false; self.setThinking(false) }
                        text += delta
                        show(text)
                    case .outcome(let result):
                        if stillThinking { stillThinking = false; self.setThinking(false) }
                        outcome = result
                        self.setOutcome(reply, result)
                    case .link(let moment):
                        if let index = self.model.agentReplies.firstIndex(where: { $0.id == reply.id }) { self.model.agentReplies[index].link = moment }
                    default:
                        break
                    }
                }
            } catch {
                text = error.localizedDescription
                failed = true
            }
            var final = AnswerText.clean(text)
            if final.isEmpty, let outcome { final = outcome.text }
            show(final.isEmpty || final.uppercased().hasPrefix("SKIP") ? "Nothing useful to add on that one." : final)
            if let query = AnswerText.imageQuery(text), let image = await AnswerImage.load(query),
               let index = self.model.agentReplies.firstIndex(where: { $0.id == reply.id }) {
                self.model.agentReplies[index].image = image
            }
            if !final.isEmpty, !failed, !final.uppercased().hasPrefix("SKIP"), self.session == thisSession { self.onAnswer?(item.text, final) }
            DebugLog.write("live: answered a double-clicked line: \(item.text) → \(final)")
        }
        lineAnswers.append(task)
    }

    // MARK: Card

    /// The one whose answer is on screen (the notes session's, or hold-to-ask's): the card's
    /// hover controls act on it.
    nonisolated(unsafe) static weak var onScreen: LiveAnswers?
    /// Kept with the card's Keep: it stays until closed.
    private var kept = false

    /// Keep this answer up until it's closed (the card's Keep).
    func keep() {
        kept = true
        dismissWork?.cancel()
        dismissWork = nil
        model.liveAnswerTimer = nil
        Haptics.snap()
    }

    /// The pointer is over the notch: keep the answer up; it counts down again when you leave.
    func hold(_ over: Bool) {
        guard over != hovering else { return }
        hovering = over
        guard model.liveAnswer?.finished == true, !kept else { return }
        if over {
            dismissWork?.cancel()
            model.liveAnswerTimer = nil
        } else {
            scheduleDismiss(after: 3)
        }
    }

    func dismiss() {
        kept = false
        dismissWork?.cancel()
        dismissWork = nil
        hovering = false
        model.liveAnswerTimer = nil
        model.setLiveAnswer(nil)
    }

    private func show(_ card: LiveAnswer, seconds: Double?) {
        Self.onScreen = self
        kept = false
        dismissWork?.cancel()
        model.liveAnswerTimer = nil
        model.setLiveAnswer(card)
        if let seconds { scheduleDismiss(after: seconds) }
    }

    /// Updates this turn's card, creating it on its first real content (so a SKIP never flashes).
    private func update(_ id: UUID, _ said: String, _ change: (inout LiveAnswer) -> Void) {
        var card: LiveAnswer
        if let existing = model.liveAnswer, existing.id == id {
            card = existing
        } else {
            // While the transcript is open, replies go there; the notch stays quiet.
            guard !model.transcriptOpen else { return }
            // Only the turn in flight (or one just finished) may take over the card, and never
            // from an answer that's still being written.
            guard current == nil || current?.id == id else { return }
            if let existing = model.liveAnswer, !existing.finished, !existing.failed { return }
            card = LiveAnswer(id: id, question: said)
            Self.onScreen = self
            kept = false
            dismissWork?.cancel()
            model.liveAnswerTimer = nil
        }
        change(&card)
        model.setLiveAnswer(card)
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissWork?.cancel()
        if kept { model.liveAnswerTimer = nil; return }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        if hovering { model.liveAnswerTimer = nil; return }
        model.liveAnswerTimer = ResultTimer(duration: seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
