import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Who said it: you (the microphone) or the other people (the Mac's audio output).
enum Speaker: String, Codable {
    case me, them
}

/// One thing said in a session: a question or a statement, by you or them, with when.
struct NoteItem: Identifiable, Equatable, Codable {
    var id = UUID()
    let time: TimeInterval
    let text: String
    let isQuestion: Bool
    /// nil in sessions saved before both sides were captured: those are all yours.
    var speaker: Speaker? = nil
    /// Which of the other people ("1", "2", …), when their voices could be told apart.
    var speakerID: String? = nil

    var isMine: Bool { speaker != .them }
}

typealias NotesResult = NoteSession

enum NotesPhase: Equatable {
    case idle, listening, finishing
    case done(NotesResult)
    case error(String)

    var isActive: Bool { self != .idle }
}

extension HotKey.Combo {
    /// ⌃⌥Space starts and stops a notes session.
    static let notes = HotKey.Combo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
    /// ⌃⌥T opens and closes the live transcript.
    static let transcript = HotKey.Combo(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey), keyName: "T")
}

/// Splits one audio stream into phrases on pauses, in 20 ms frames of 16 kHz audio. Runs on the
/// notes queue; the callbacks fire there too.
final class PhraseSegmenter {
    var onSpeechStart: (() -> Void)?
    /// Too short to transcribe, dropped.
    var onDiscard: (() -> Void)?
    /// A phrase: its audio, when it began (seconds since the session started), and how many
    /// seconds of quiet ended it (so when the speech itself stopped).
    var onPhrase: (([Float], TimeInterval, TimeInterval) -> Void)?
    /// A short pause mid-phrase (`earlyPause`): the phrase so far, for the agent's head start.
    /// Fires once per pause; `onResume` follows if the speech goes on.
    var onEarlyPause: (([Float], TimeInterval) -> Void)?
    var onResume: (() -> Void)?
    /// Quiet that's enough to start working on an answer, though not to end the phrase.
    var earlyPause: TimeInterval = 0.35
    private var earlyFired = false

    private let frameSize = 320
    /// Level that counts as speech, read live so the sensitivity setting applies mid-session.
    private let speechRMS: () -> Float
    /// Quiet that ends a phrase (settings, default 0.8 s), in frames.
    private var pauseFrames: Int { max(Int(AppSettings.shared.notesPause * 50), 10) }
    private let minimumSpeechFrames = 20  // ignore blips under 0.4 s
    private let maximumFrames = 1000      // split long monologues every 20 s
    private var pending: [Float] = []
    private var phrase: [Float] = []
    private var speechFrames = 0
    private var quietFrames = 0
    private var phraseStart: TimeInterval = 0
    private var sessionStart = Date()

    init(speechRMS: @escaping () -> Float) { self.speechRMS = speechRMS }

    /// After a pause: phrase times carry on from where they stopped.
    func shiftStart(by seconds: TimeInterval) { sessionStart = sessionStart.addingTimeInterval(seconds) }

    func reset(sessionStart: Date) {
        pending = []; phrase = []
        speechFrames = 0; quietFrames = 0; phraseStart = 0
        self.sessionStart = sessionStart
    }

    func feed(_ samples: [Float]) {
        pending += samples
        while pending.count >= frameSize {
            let frame = Array(pending.prefix(frameSize))
            pending.removeFirst(frameSize)
            consume(frame)
        }
    }

    /// The phrase being said right now, if any: its last `seconds` of audio, for live captions.
    func inProgress(lastSeconds seconds: Double) -> [Float]? {
        guard speechFrames > 0, !phrase.isEmpty else { return nil }
        let count = Int(seconds * 16_000)
        return phrase.count > count ? Array(phrase.suffix(count)) : phrase
    }

    /// Ends the current phrase now (the session is stopping).
    func flush() {
        if speechFrames >= minimumSpeechFrames { emit() } else if !phrase.isEmpty { clear(); onDiscard?() }
    }

    private func consume(_ frame: [Float]) {
        let rms = (frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)).squareRoot()
        if rms > speechRMS() {
            if phrase.isEmpty {
                // Wall clock, so both speakers share one timeline.
                phraseStart = Date().timeIntervalSince(sessionStart)
                onSpeechStart?()
            }
            phrase += frame
            speechFrames += 1
            quietFrames = 0
            if earlyFired { earlyFired = false; onResume?() }
        } else if !phrase.isEmpty {
            phrase += frame
            quietFrames += 1
            if !earlyFired, onEarlyPause != nil, speechFrames >= minimumSpeechFrames,
               quietFrames == Int(earlyPause * 50), quietFrames < pauseFrames {
                earlyFired = true
                onEarlyPause?(phrase, Double(quietFrames * frameSize) / 16_000)
            }
        }
        if quietFrames >= pauseFrames || phrase.count / frameSize >= maximumFrames {
            if speechFrames >= minimumSpeechFrames { emit() } else { clear(); onDiscard?() }
        }
    }

    private func emit() {
        let audio = phrase, time = phraseStart, quiet = Double(quietFrames * frameSize) / 16_000
        clear()
        onPhrase?(audio, time, quiet)
    }

    private func clear() { phrase = []; speechFrames = 0; quietFrames = 0; earlyFired = false }
}

/// A notes session: both sides of a meeting. Your microphone is "me"; what the Mac plays (the
/// meeting app) is "them", via a process tap. Each stream is split on pauses, transcribed with
/// Parakeet in the order it was said, cleaned, and sorted into questions and statements. When
/// you stop, everything is saved as Markdown.
///
/// On speakers rather than headphones, your mic also hears them: a "me" phrase that matches
/// something they said moments before is dropped as an echo.
final class NotesController {
    let model: NotchModel
    let cleanup: CleanupModel  // reserved for a future summary step
    private let capture = AudioCapture(barCount: 10)
    private let system = SystemAudioCapture()
    private let micResampler = Resampler16k()
    private let systemResampler = Resampler16k()
    private let queue = DispatchQueue(label: "notch.notes")
    private let mine = PhraseSegmenter { NotesController.threshold(base: 0.012) }
    private let theirs = PhraseSegmenter { NotesController.threshold(base: 0.008) }  // meeting audio is cleaner than a mic
    private var transcriptKey: HotKey?
    private var silentKey: HotKey?
    private var boundSilentShortcut: HotKey.Combo?

    /// Voice sensitivity (0…1, 0.5 = the base level) scales the speech threshold from 2.5×
    /// (only clear, close speech) down to 0.35× (quiet voices).
    static func threshold(base: Float) -> Float {
        let s = Float(min(max(AppSettings.shared.voiceSensitivity, 0), 1))
        let factor = s < 0.5 ? 2.5 - 3 * s : 1 - 1.3 * (s - 0.5)
        return base * factor
    }
    private var hotKey: HotKey?

    private var transcriptions: Task<Void, Never>?
    private var started = Date()
    /// `started`, moved later by every pause: times in the transcript and the saved length count
    /// only time spent listening, matching the timer. (`started` itself names the session.)
    private var clock = Date()
    private var pausedAt: Date?
    /// Answers questions as you ask them, under the notch.
    lazy var live = LiveAnswers(model: model)
    /// Names the other speakers from the conversation.
    @MainActor lazy var naming = SpeakerNaming(model: model)
    private var answers: [NoteSession.Answer] = []
    /// Set once the session is saved; answers that finish later are added to it.
    private var savedID: String?
    /// Meeting apps using the mic: offers (or starts) notes, and ends them with the meeting.
    private let meetings = MeetingDetector()
    private var promptTimeout: DispatchWorkItem?
    /// This session was started for a meeting, so it ends when the meeting does.
    private var startedForMeeting = false
    /// A meeting app was on a call at some point while listening: when it hangs up, so do the notes.
    private var meetingDuringSession = false
    private var doneClose: DispatchWorkItem?
    /// Saves the session as it goes, so a long one (no time limit) is never lost.
    private var autosave: Timer?
    /// Writes tasks into the corner list as the conversation goes.
    private let taskWriter = TaskWriter()
    static let autosaveEvery: TimeInterval = 120
    /// Long sessions are checkpointed every two hours: saved in full, one continuous session.
    static let checkpointEvery: TimeInterval = 2 * 3600
    private var lastCheckpoint = Date()
    /// The finished card closes by itself after this long (hovering holds it; copying keeps it).
    static let doneSeconds: TimeInterval = 10
    private var meetingObserver: AnyCancellable?

    /// Live captions: your phrase in progress, re-transcribed about twice a second.
    private var captionTimer: Timer?
    private var captionBusy = false
    /// Their recent phrases, to recognise your mic picking them up from the speakers.
    private var recentTheirs: [(time: TimeInterval, words: Set<String>)] = []

    init(model: NotchModel, cleanup: CleanupModel) {
        self.model = model
        self.cleanup = cleanup
        applyShortcut()
        settingsObserver = AppSettings.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.applyShortcut() }
        }
        capture.onBuffer = { [weak self] buffer in self?.ingest(buffer, from: .me) }
        // The mic went dead and didn't come back after a few restarts: end the phrase that was
        // under way, so Live answers don't wait forever for you to finish talking.
        capture.onSilentInput = { [weak self] in
            guard let self, self.model.notes == .listening else { return }
            DebugLog.write("notes: no audio from the mic")
            self.queue.async { self.mine.flush() }
            self.live.speechEnded(.me, kept: false)
            self.model.setCaption("")
        }
        system.onBuffer = { [weak self] buffer in self?.ingest(buffer, from: .them) }
        system.onFailure = { DispatchQueue.main.async { AppSettings.shared.theirAudioProblem = "Stopped when the output changed" } }
        live.onAnswer = { [weak self] question, answer in self?.record(question, answer) }
        Self.closeAnswer = { [weak self] in self?.live.dismiss() }
        Self.ask = { [weak self] text in
            guard let self, self.model.notes == .listening else { return }
            // In the transcript as one of your lines, and asked at once (you've clearly finished).
            let item = NoteItem(time: Date().timeIntervalSince(self.clock), text: text, isQuestion: true, speaker: .me)
            self.model.addNote(item)
            self.live.typed(text)
        }
        meetings.onChange = { [weak self] app in self?.meetingChanged(app) }
        // Watching for calls only while meetings are on and something should happen when one starts.
        meetingObserver = AppSettings.shared.$meetingMode.combineLatest(AppSettings.shared.$meetingsEnabled)
            .receive(on: DispatchQueue.main).sink { [weak self] mode, enabled in
                if mode == .off || !enabled { self?.meetings.stop(); self?.dismissMeetingPrompt() } else { self?.meetings.start() }
            }
        capture.onLevels = { [weak model] levels in
            guard model?.notes == .listening else { return }
            model?.notesLevels = levels
        }
        for (segmenter, speaker) in [(mine, Speaker.me), (theirs, Speaker.them)] {
            segmenter.onSpeechStart = { [weak self] in DispatchQueue.main.async { self?.live.speechStarted(speaker) } }
            segmenter.onDiscard = { [weak self] in
                DispatchQueue.main.async {
                    self?.live.speechEnded(speaker, kept: false)
                    if speaker == .me { self?.model.setCaption("") }
                }
            }
            segmenter.onPhrase = { [weak self] audio, time, quiet in
                let cut = Date()
                self?.transcribe(audio, at: time, from: speaker, spoke: cut.addingTimeInterval(-quiet), cut: cut)
            }
        }
        // Your side only: a head start on the answer at a short pause (see LiveAnswers).
        mine.onEarlyPause = { [weak self] audio, quiet in
            let cut = Date()
            DispatchQueue.main.async { self?.transcribeEarly(audio, spoke: cut.addingTimeInterval(-quiet), cut: cut) }
        }
        mine.onResume = { [weak self] in DispatchQueue.main.async { self?.live.resumed() } }
    }

    private var settingsObserver: AnyCancellable?
    private var boundShortcut: HotKey.Combo?

    private var boundTranscriptShortcut: HotKey.Combo?

    func applyShortcut() {
        let settings = AppSettings.shared
        if settings.recordingShortcut {
            hotKey = nil; boundShortcut = nil
            transcriptKey = nil; boundTranscriptShortcut = nil
            silentKey = nil; boundSilentShortcut = nil
            return
        }
        // A feature that's off leaves its shortcut free for other apps. (Live mode's key is
        // AskController's: pressed or held.)
        if !settings.meetingsEnabled {
            hotKey = nil; boundShortcut = nil
        } else if settings.notesShortcut != boundShortcut {
            hotKey = nil
            hotKey = HotKey(settings.notesShortcut, onPress: { [weak self] in self?.toggle() })
            boundShortcut = hotKey?.status == noErr ? settings.notesShortcut : nil
        }
        let sessions = settings.meetingsEnabled || settings.liveEnabled
        if !sessions {
            silentKey = nil; boundSilentShortcut = nil
        } else if settings.silentShortcut != boundSilentShortcut {
            silentKey = nil
            silentKey = HotKey(settings.silentShortcut, onPress: { [weak self] in self?.toggleSilent() })
            boundSilentShortcut = silentKey?.status == noErr ? settings.silentShortcut : nil
        }
        if !sessions {
            transcriptKey = nil; boundTranscriptShortcut = nil
        } else if settings.transcriptShortcut != boundTranscriptShortcut {
            transcriptKey = nil
            transcriptKey = HotKey(settings.transcriptShortcut, onPress: { [weak self] in self?.toggleTranscript() })
            boundTranscriptShortcut = transcriptKey?.status == noErr ? settings.transcriptShortcut : nil
        }
    }

    var isListening: Bool { model.notes == .listening }

    /// Silent mode on or off (its shortcut): the meeting notch says "Silent"; outside one, a notice.
    func toggleSilent() {
        let settings = AppSettings.shared
        settings.silentMode.toggle()
        Haptics.snap()
        let on = settings.silentMode
        model.flash(NotchModel.Toast(icon: on ? .voice : .agent, title: on ? "Silent" : "Answering",
                                     detail: on ? "Listening only" : "Answers on"))
    }

    /// Live mode: like notes, but you're talking to Starlight. Everything said is answered or done,
    /// a lecture gets a running helper, and asking it to open or save something just happens.
    func startLive() {
        guard AppSettings.shared.liveEnabled else { return }  // Live mode is off (General)
        guard StarlightAccount.shared.check(.ai, on: model) else { return }
        if model.notes == .listening {
            // Already listening: the session carries on, now in live mode.
            withAnimation(model.scaled(Motion.open)) { model.sessionKind = .live }
            live.isLive = true
            return
        }
        start(kind: .live)
    }

    func toggleLive() {
        switch model.notes {
        case .listening where model.sessionKind == .live: stop()
        case .finishing: break
        default: startLive()
        }
    }

    func toggle() {
        guard !starting else { return }
        switch model.notes {
        case .listening: stop()
        case .finishing: break
        default: start()
        }
    }

    /// From the meeting prompt's Take notes, or automatically: a session that ends with the meeting.
    func startForMeeting() {
        guard StarlightAccount.shared.check(.ai, on: model) else { return }
        dismissMeetingPrompt()
        startedForMeeting = true
        start()
    }

    private func meetingChanged(_ app: MeetingApp?) {
        let mode = AppSettings.shared.meetingMode
        if let app {
            if model.notes == .listening { if model.sessionKind == .notes { meetingDuringSession = true }; return }
            guard model.notes == .idle, mode != .off, AppSettings.shared.meetingsEnabled else { return }
            DebugLog.write("meeting: \(app.name) is using the mic")
            if mode == .auto { return startForMeeting() }
            withAnimation(model.scaled(Motion.open)) { model.meetingPrompt = app }
            promptTimeout?.cancel()
            let timeout = DispatchWorkItem { [weak self] in self?.dismissMeetingPrompt() }
            promptTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        } else {
            DebugLog.write("meeting: ended")
            dismissMeetingPrompt()
            // The call ended: so does a session that was taking its notes.
            if startedForMeeting || meetingDuringSession, model.notes == .listening {
                DebugLog.write("meeting: ended, stopping notes")
                stop()
            }
        }
    }

    func dismissMeetingPrompt() {
        promptTimeout?.cancel()
        guard model.meetingPrompt != nil else { return }
        withAnimation(model.scaled(Motion.close)) { model.meetingPrompt = nil }
    }

    /// Between pressing start and listening (the mic permission check is async): a second
    /// press, or a meeting starting at the same moment, doesn't start a second session.
    private var starting = false
    /// The × on a long answer in the notch.
    static var closeAnswer: (() -> Void)?
    /// A question typed into the overlay's ask bar.
    static var ask: ((String) -> Void)?

    func start(kind: NotchModel.SessionKind = .notes) {
        guard model.notes != .listening, model.notes != .finishing, !starting else { return }
        // Off in General: nothing starts.
        guard kind == .live ? AppSettings.shared.liveEnabled : AppSettings.shared.meetingsEnabled else { return }
        // Notes and Live are the AI side of Starlight: free with your own key, or Pro.
        guard StarlightAccount.shared.check(.ai, on: model) else { return }
        starting = true
        model.sessionKind = kind
        live.isLive = kind == .live
        dismissMeetingPrompt()
        Task { @MainActor in
            defer { starting = false }
            let testAudio = Dev.env("STARLIGHT_TEST_NOTES_AUDIO")
            let allowed = testAudio != nil ? true : await AudioCapture.requestPermission()
            guard allowed else {
                PermissionAsk.shared.need("mic")
                return fail("Mic access is off")
            }
            let now = Date()
            queue.sync {
                mine.reset(sessionStart: now)
                theirs.reset(sessionStart: now)
            }
            micResampler.reset()
            systemResampler.reset()
            recentTheirs = []
            transcriptions = nil
            model.speakerNames = [:]
            MainActor.assumeIsolated { naming.reset() }
            if AppSettings.shared.captureTheirAudio || VoiceProfile.shared.isLearned {
                SpeakerIdentifier.shared.prepare()
                SpeakerIdentifier.shared.reset()
                // One person split in two: their lines join, under the earlier number.
                SpeakerIdentifier.shared.onMerge = { [weak self] from, into in
                    guard let model = self?.model else { return }
                    model.noteItems = model.noteItems.map { item in
                        var item = item
                        if item.speakerID == from { item.speakerID = into }
                        return item
                    }
                    if model.speakerNames[into] == nil, let name = model.speakerNames[from] {
                        model.speakerNames[into] = name
                        if model.guessedSpeakerNames.contains(from) { model.guessedSpeakerNames.insert(into) }
                    }
                    model.speakerNames[from] = nil
                    model.guessedSpeakerNames.remove(from)
                }
                // A new speaker confirmed: their first phrase, filed with someone else, moves over.
                SpeakerIdentifier.shared.onRelabel = { [weak self] time, label in
                    guard let model = self?.model else { return }
                    model.noteItems = model.noteItems.map { item in
                        var item = item
                        if !item.isMine, abs(item.time - time) < 0.01 { item.speakerID = label }
                        return item
                    }
                }
            }
            ParakeetModel.shared.beginUse()
            do {
                if let testAudio { try capture.startFile(URL(fileURLWithPath: testAudio)) } else { try capture.start() }
            } catch {
                ParakeetModel.shared.endUse()
                return fail("Mic didn't start")
            }
            startTheirSide()
            Sounds.start()
            started = now
            clock = now
            pausedAt = nil
            answers = []
            savedID = nil
            live.begin(start: started) { [weak self] in self?.model.noteItems ?? [] }
            if AppSettings.shared.liveAnswers { WebSearchExtension.warmUp() }
            model.noteItems = []
            model.agentReplies = []
            model.liveCaption = ""
            startCaptions()
            model.notesStart = started
            model.notesPaused = false
            lastCheckpoint = started
            if AppSettings.shared.tasksEnabled { taskWriter.begin { [weak self] in
                guard let self else { return [] }
                return self.model.noteItems.map { "\(self.model.speakerName($0)): \($0.text)" }
            } }
            autosave?.invalidate()
            autosave = Timer.scheduledTimer(withTimeInterval: Self.autosaveEvery, repeats: true) { [weak self] _ in self?.saveProgress() }
            meetingDuringSession = kind == .notes && (startedForMeeting || meetings.current != nil)
            model.setNotes(.listening)
            if AppSettings.shared.openOverlayWithSessions { showTranscript() }
        }
    }

    /// The other side, if it's on in settings. Notes still work from your mic if it can't start
    /// (macOS asks once for permission to record system audio).
    private func startTheirSide() {
        let settings = AppSettings.shared
        // A test file stands in for your mic; don't record whatever the Mac is really playing.
        guard settings.captureTheirAudio, Dev.env("STARLIGHT_TEST_NOTES_AUDIO") == nil else { return }
        // Off the main thread: the first time, starting waits on macOS's permission prompt.
        let system = self.system
        // Start and stop go through one queue, so a stop can't slip in while a start is still
        // waiting on the permission prompt (and then be undone by it).
        systemQueue.async { [weak self] in
            do {
                try system.start()
                DispatchQueue.main.async {
                    settings.theirAudioProblem = nil
                    UserDefaults.standard.set(true, forKey: SystemAudioPermission.key)
                    // Paused or stopped while it was starting: stop it again.
                    if let self, self.model.notes != .listening || self.model.notesPaused { self.stopTheirSide() }
                }
            } catch {
                DebugLog.write("system audio: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    settings.theirAudioProblem = "Not allowed"
                    MainActor.assumeIsolated { PermissionAsk.shared.need("audio") }
                }
            }
        }
    }

    private let systemQueue = DispatchQueue(label: "notch.systemaudio")

    private func stopTheirSide() {
        let system = self.system
        systemQueue.async { system.stop() }
    }

    // MARK: Pause

    /// Click the time beside the camera: stop listening for a while. The mic (and the Mac's
    /// audio) really stop, so the orange mic light goes off; the timer holds where it was.
    func togglePause() { model.notesPaused ? resume() : pause() }

    func pause() {
        guard model.notes == .listening, !model.notesPaused else { return }
        stopCaptions()
        capture.stop()
        stopTheirSide()
        queue.sync {
            mine.flush()
            theirs.flush()
        }
        model.setCaption("")
        Sounds.stop()
        pausedAt = Date()
        withAnimation(model.scaled(Motion.open)) {
            model.pausedElapsed = Date().timeIntervalSince(model.notesStart)
            model.notesPaused = true
        }
        DebugLog.write("notes: paused")
    }

    func resume() {
        guard model.notes == .listening, model.notesPaused else { return }
        // Before the mic starts: its audio thread uses these right away.
        micResampler.reset()
        systemResampler.reset()
        if let pausedAt {
            let paused = Date().timeIntervalSince(pausedAt)
            clock = clock.addingTimeInterval(paused)
            live.shiftStart(by: paused)
            queue.sync {
                mine.shiftStart(by: paused)
                theirs.shiftStart(by: paused)
            }
            self.pausedAt = nil
        }
        do {
            if let testAudio = Dev.env("STARLIGHT_TEST_NOTES_AUDIO") {
                try capture.startFile(URL(fileURLWithPath: testAudio))
            } else {
                try capture.start()
            }
        } catch {
            DebugLog.write("notes: resume failed: \(error)")
            return
        }
        startTheirSide()
        startCaptions()
        Sounds.start()
        withAnimation(model.scaled(Motion.open)) {
            model.notesStart = Date().addingTimeInterval(-model.pausedElapsed)  // the timer carries on
            model.notesPaused = false
        }
        DebugLog.write("notes: resumed")
    }

    /// The session so far, saved under its final name; stopping saves over it.
    private func saveProgress() {
        guard model.notes == .listening, !model.noteItems.isEmpty else { return }
        var session = NoteSession(id: NoteSession.makeID(started), started: started, duration: Date().timeIntervalSince(clock),
                                  items: model.noteItems)
        if !model.speakerNames.isEmpty { session.speakerNames = model.speakerNames }
        if !answers.isEmpty { session.answers = answers }
        if model.sessionKind == .live { session.kind = "live" }
        NotesStore.shared.save(session)
        if Date().timeIntervalSince(lastCheckpoint) >= Self.checkpointEvery {
            lastCheckpoint = Date()
            live.trimHistory()
            DebugLog.write("notes: two-hour checkpoint at \(NotesController.timestamp(session.duration)), \(session.items.count) lines saved")
        }
    }

    func stop() {
        guard model.notes == .listening else { return }
        autosave?.invalidate()
        autosave = nil
        taskWriter.end()
        startedForMeeting = false
        meetingDuringSession = false
        model.notesDoneKept = false
        model.notesPaused = false
        stopCaptions()
        capture.stop()
        stopTheirSide()
        Sounds.stop()
        model.notesExpanded = false
        live.end()
        model.setNotes(.finishing)
        queue.sync {
            mine.flush()
            theirs.flush()
        }
        let started = self.started, clock = self.clock
        Task { @MainActor in
            // Let the last phrases reach the transcription queue, then wait for it.
            await Task.yield()
            await transcriptions?.value
            ParakeetModel.shared.endUse()
            let items = model.noteItems
            let duration = Date().timeIntervalSince(clock)
            if items.isEmpty {
                fail("Didn't hear anything")
            } else {
                var session = NoteSession(id: NoteSession.makeID(started), started: started, duration: duration, items: items)
                if model.sessionKind == .live { session.kind = "live" }
                if !model.speakerNames.isEmpty { session.speakerNames = model.speakerNames }
                if !answers.isEmpty {
                    session.answers = answers
                    session.answerModel = "\(AppSettings.model), live"
                }
                NotesStore.shared.save(session)
                savedID = session.id
                naming.finish(sessionID: session.id)
                // The timeline of sections, written in the background.
                let id = session.id
                Task.detached { await Chapters.write(for: id) }
                model.setNotes(.done(session))
                scheduleDoneClose(after: Self.doneSeconds)
            }
        }
    }

    func dismiss() {
        doneClose?.cancel()
        doneClose = nil
        model.notesDoneTimer = nil
        TranscriptOverlay.shared.hide()
        model.setNotes(.idle)
    }

    // MARK: The finished card

    /// Closes the finished card in `seconds`, with the ring counting down beside the camera.
    private func scheduleDoneClose(after seconds: TimeInterval) {
        doneClose?.cancel()
        guard case .done = model.notes, !model.notesDoneKept else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .done = self.model.notes else { return }
            DebugLog.write("notes: finished card closed by itself")
            self.dismiss()
        }
        doneClose = work
        model.notesDoneTimer = ResultTimer(duration: seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// The pointer is on the finished card: it stays; leaving starts a short countdown again.
    func holdDone(_ over: Bool) {
        guard case .done = model.notes, !model.notesDoneKept else { return }
        if over {
            guard doneClose != nil else { return }
            doneClose?.cancel()
            doneClose = nil
            model.notesDoneTimer = nil
        } else if doneClose == nil {
            scheduleDoneClose(after: 4)
        }
    }

    /// Copied the transcript: a moment to see "Copied", then the card closes by itself.
    func keepDone() {
        doneClose?.cancel()
        doneClose = nil
        model.notesDoneTimer = nil
        model.notesDoneKept = true  // the pointer on it doesn't hold it open now
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .done = self.model.notes else { return }
            self.dismiss()
        }
        doneClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    /// The live transcript panel below the notch. Opening it clears the answer card, since the
    /// transcript shows the agent's replies too.
    /// Double-clicked a line in the transcript.
    func answer(_ item: NoteItem, deep: Bool? = nil) { live.answer(item, deep: deep) }

    /// Opens the transcript if it isn't open (for long answers).
    func showTranscript() {
        guard !TranscriptOverlay.shared.isVisible else { return }
        TranscriptOverlay.shared.show(model: model, on: AppDelegate.notchScreen()) { [weak self] item, deep in self?.answer(item, deep: deep) }
    }

    func toggleTranscript() {
        live.dismiss()
        TranscriptOverlay.shared.toggle(model: model, below: AppDelegate.notchScreen()) { [weak self] item, deep in self?.answer(item, deep: deep) }
    }

    private func fail(_ message: String) {
        startedForMeeting = false
        meetingDuringSession = false
        Sounds.error()
        model.setNotes(.error(message))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if case .error = self?.model.notes { self?.dismiss() }
        }
    }

    // MARK: Live captions

    /// Like dictation's live text: while you're mid-phrase, transcribe what's been said so far
    /// (the last 12 s) and show it. Skips a beat if the previous pass is still running, and
    /// does nothing while both caption places are off.
    private func startCaptions() {
        captionTimer?.invalidate()
        let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in self?.captionTick() }
        RunLoop.main.add(timer, forMode: .common)
        captionTimer = timer
    }

    private func stopCaptions() {
        captionTimer?.invalidate()
        captionTimer = nil
        model.setCaption("")
    }

    private func captionTick() {
        let settings = AppSettings.shared
        guard settings.captionsNotch || settings.captionsTranscript, !captionBusy, model.notes == .listening else { return }
        guard let audio = queue.sync(execute: { mine.inProgress(lastSeconds: 12) }), audio.count >= 8_000 else { return }
        captionBusy = true
        Task { @MainActor in
            defer { captionBusy = false }
            guard let raw = try? await ParakeetModel.shared.transcribeIfLoaded(audio) else { return }
            // Only if you're still mid-phrase; the final line replaces the caption otherwise.
            guard queue.sync(execute: { mine.inProgress(lastSeconds: 0.1) }) != nil else { return }
            // Meetings and Live mode keep your exact words; only dictation is tidied (its own setting).
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Mid-sentence, so no closing full stop yet (the final line gets its punctuation).
            while let last = text.last, ".,;:".contains(last) { text.removeLast() }
            if !text.isEmpty {
                model.setCaption(text)
                if Dev.env("STARLIGHT_DEBUG_CAPTIONS") != nil { DebugLog.write("caption: \(text)") }
            }
        }
    }

    // MARK: Audio

    /// Capture thread → notes queue. Each buffer is converted while it's still valid.
    private func ingest(_ buffer: AVAudioPCMBuffer, from speaker: Speaker) {
        let samples = (speaker == .me ? micResampler : systemResampler).convert(buffer)
        queue.async { [self] in (speaker == .me ? mine : theirs).feed(samples) }
    }

    /// Queues a phrase for transcription. Both speakers share one queue, so phrases come out in
    /// the order they ended.
    private func transcribe(_ audio: [Float], at time: TimeInterval, from speaker: Speaker, spoke: Date = Date(), cut: Date = Date()) {
        DispatchQueue.main.async { [self] in
            live.speechEnded(speaker, kept: true)
            let previous = transcriptions
            // Their voice fingerprint is taken alongside the transcription, off the main thread.
            let who: Task<String?, Never>? = speaker == .them ? Task.detached { await SpeakerIdentifier.shared.identify(audio, at: time) } : nil
            // On your mic: is it you? With your voice learned, someone else in the room (an
            // in-person meeting) is told apart and numbered like the other side of a call.
            let inRoom: Task<String?, Never>? = speaker == .me && VoiceProfile.shared.isLearned ? Task.detached {
                guard await VoiceProfile.shared.isSomeoneElse(audio) else { return nil }
                return await SpeakerIdentifier.shared.identify(audio) ?? "room"
            } : nil
            transcriptions = Task { @MainActor in
                await previous?.value
                guard let raw = try? await ParakeetModel.shared.transcribe(audio) else { return live.heard(nil, from: speaker) }
                let roomID = await inRoom?.value
                let speaker: Speaker = roomID != nil ? .them : speaker
                let theirID = await who?.value
                let speakerID = roomID == "room" ? nil : roomID ?? theirID
                let text = raw
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if speaker == .me, isEcho(text, at: time) {
                    DebugLog.write("notes: dropped an echo of their audio: \(text)")
                    model.setCaption("")
                    return live.heard(nil, from: speaker)
                }
                if speaker == .them { remember(text, at: time) }
                if speaker == .me { model.setCaption("") }  // the final line takes over
                for sentence in Self.sentences(text) {
                    model.addNote(NoteItem(time: time, text: sentence, isQuestion: Self.isQuestion(sentence), speaker: speaker,
                                           speakerID: speakerID))
                }
                // Everything goes to the live agent as heard, even one-word replies ("shoes"),
                // which the notes leave out. Their lines carry who said them.
                if speaker == .them { naming.heard(text, from: speakerID) }
                live.heard(text, from: speaker, label: speaker == .me ? "Me" : model.agentLabel(speakerID),
                           timing: PhraseTiming(spoke: spoke, cut: cut, transcribed: Date()))
            }
        }
    }

    /// The phrase so far, at a short pause: transcribed in order with the rest, and handed to the
    /// agent as a head start. It isn't a note; the full phrase still arrives when it ends.
    private func transcribeEarly(_ audio: [Float], spoke: Date, cut: Date) {
        let previous = transcriptions
        let task = Task { @MainActor in
            await previous?.value
            guard let raw = try? await ParakeetModel.shared.transcribeIfLoaded(audio) else { return }
            let text = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isEcho(text, at: Date().timeIntervalSince(clock)) else { return }
            live.early(text, timing: PhraseTiming(spoke: spoke, cut: cut, transcribed: Date()))
        }
        transcriptions = task
    }

    // MARK: Echo

    private func remember(_ text: String, at time: TimeInterval) {
        recentTheirs.append((time, Self.words(text)))
        recentTheirs.removeAll { time - $0.time > 20 }
    }

    /// Your mic heard the speakers: most of the words match something they said in the last few
    /// seconds.
    private func isEcho(_ text: String, at time: TimeInterval) -> Bool {
        let words = Self.words(text)
        guard words.count >= 2 else { return false }
        return recentTheirs.contains { theirs in
            abs(theirs.time - time) < 6 && Double(words.intersection(theirs.words).count) / Double(words.count) >= 0.6
        }
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// Keeps a live answer with the session, including answers that finish after you stop.
    private func record(_ question: String, _ answer: String) {
        guard !answer.isEmpty else { return }
        let entry = NoteSession.Answer(question: question, answer: answer, time: Date().timeIntervalSince(clock))
        answers.append(entry)
        guard let id = savedID, var session = NotesStore.shared.session(id) else { return }
        session.answers = (session.answers ?? []) + [entry]
        session.answerModel = session.answerModel ?? "\(AppSettings.model), live"
        NotesStore.shared.save(session)
    }

    // MARK: Text

    static func sentences(_ text: String) -> [String] {
        text.replacingOccurrences(of: #"(?<=[.!?])\s+"#, with: "\n", options: .regularExpression)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.split(separator: " ").count >= 2 }
    }

    private static let questionStarts: Set<String> = [
        "who", "what", "when", "where", "why", "how", "which", "can", "could", "would", "should", "do", "does",
        "did", "is", "are", "was", "were", "will", "have", "has", "shall", "may", "am",
    ]

    static func isQuestion(_ sentence: String) -> Bool {
        if sentence.hasSuffix("?") { return true }
        let first = sentence.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).first.map(String.init) ?? ""
        return questionStarts.contains(first) && !sentence.hasSuffix(".")
    }

    static func timestamp(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
