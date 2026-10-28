import AppKit
import AVFoundation
import Combine

/// Dictation: ⌃Space toggles recording, ⌃⇧Space is push-to-talk,
/// Esc cancels. Audio goes to Parakeet while the notch shows the voice bars and live text; the
/// transcript is cleaned (rules, then the local model) and shown in the notch. Nothing is pasted
/// or put on the clipboard.
final class VoiceController {
    let model: NotchModel
    let capture = AudioCapture(barCount: VoiceLayout.barCount)
    let engine: TranscriptionEngine = ParakeetEngine()
    let cleanup = CleanupModel()

    /// Dictation's key (pressed or held, AppSettings.dictationKeyMode).
    private var toggleKey: HotKey?
    private var cancelKey: HotKey?
    private var starting = false
    private var stopWhenStarted = false
    private var pushToTalkActive = false
    private var waveTimer: Timer?
    private var dismissWork: DispatchWorkItem?
    private let settings = AppSettings.shared
    private var settingsObserver: AnyCancellable?
    private var boundShortcut: (HotKey.Combo, AppSettings.KeyMode)?
    /// Dictating types your words; asking (Live mode's key, held) sends them to the agent when you let go.
    enum Intent { case dictate, ask }
    private(set) var intent: Intent = .dictate
    /// Hold to ask: the words, once transcribed. The notch stays on "Thinking" until `showAnswer()`.
    var onAsk: ((String) -> Void)?
    /// The pointer over an answer (holds it), and the answer put away (Esc, a click elsewhere).
    var onAnswerHover: ((Bool) -> Void)?
    var onAnswerClosed: (() -> Void)?
    /// Result stays up while the pointer is over it, then counts down again when it leaves.
    var isPointerOver = false
    /// While a result shows, the pointer moving over the notch holds it; once the pointer has
    /// sat still for `parkedAfter` (parked there while you type or paste), the countdown resumes.
    private var parkedCheck: DispatchWorkItem?
    /// Key press → mic live, for the dictation's timing.
    private var micStart: (pressed: Date, live: Date)?
    private let parkedAfter: TimeInterval = 3

    /// Every pointer move while dictation is showing (from the app's tracking).
    func pointerMoved(inside: Bool) {
        let wasOver = isPointerOver
        isPointerOver = inside
        if model.voice == .answer { if inside != wasOver { onAnswerHover?(inside) }; return }
        guard dismissWork != nil else { return }
        switch model.voice {
        case .result, .error: break
        default: return
        }
        parkedCheck?.cancel()
        if inside {
            dismissWork?.cancel()
            model.resultTimer = nil
            let check = DispatchWorkItem { [weak self] in self?.scheduleDismiss(after: 2) }
            parkedCheck = check
            DispatchQueue.main.asyncAfter(deadline: .now() + parkedAfter, execute: check)
        } else if wasOver {
            scheduleDismiss(after: 2)
        }
    }
    /// Shorter than this is an accidental tap of the shortcut: cancelled quietly.
    private let minimumRecording: TimeInterval = 0.35

    init(model: NotchModel) {
        self.model = model
        model.engineName = engine.displayName
        applyShortcuts()
        settingsObserver = settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.applyShortcuts() }
        }
        capture.onLevels = { [weak model] levels in
            guard model?.voice == .recording else { return }
            model?.levels = levels
        }
        // Called on the audio thread; the engine buffers from the first moment of recording.
        capture.onBuffer = { [weak self] buffer in self?.engine.append(buffer) }
        engine.statusHandler = { [weak self, weak model] status in
            model?.engineStatus = status
            // Every model downloads by itself, one after another, starting with the one the first
            // dictation needs: the voice model, then the polish model (900 MB), then the
            // meeting speaker models.
            switch status {
            case .ready, .failed:
                self?.cleanup.prepare()
                SpeakerIdentifier.fetchModels()
            default: break
            }
        }
        capture.onSilentInput = { [weak self] in
            guard let self, self.model.voice == .recording else { return }
            self.cancel()
            self.show(error: "No audio from the mic")
        }
        cleanup.onState = { [weak model] state in model?.cleanupState = state }
        model.cleanupRetry = { [weak self] in self?.cleanup.prepare() }
        // Load the voice model at launch so the first dictation is instant (the others follow it,
        // above), and ready the mic.
        engine.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.capture.prepare() }
    }

    /// (Re)registers dictation's key when it or its mode changes: pressed, it starts and stops;
    /// held, it listens until you let go.
    func applyShortcuts() {
        let wanted = (settings.dictationShortcut, settings.dictationKeyMode)
        // Dictation off, or a shortcut being recorded: the key is free.
        if settings.recordingShortcut || !settings.dictationEnabled {
            toggleKey = nil; boundShortcut = nil
            return
        }
        if let bound = boundShortcut, bound == wanted { return }
        toggleKey = nil
        let hold = wanted.1 == .hold
        toggleKey = HotKey(wanted.0,
                           onPress: { [weak self] in if hold { self?.pushToTalkDown() } else { self?.toggle() } },
                           onRelease: { [weak self] in if hold { self?.pushToTalkUp() } })
        // Only remembered when it took: one another app holds gets tried again (AppDelegate's
        // retry), so quitting that app brings the shortcut back without a relaunch.
        boundShortcut = toggleKey?.status == noErr ? wanted : nil
    }

    /// Non-nil when another app (another dictation app, say) already holds the shortcut.
    var hotKeyProblem: String? {
        guard settings.dictationEnabled, toggleKey?.status != noErr else { return nil }
        return "\(settings.dictationShortcut.display) already in use by another app"
    }

    // MARK: Input

    func toggle() {
        switch model.voice {
        case .recording: stop()
        case .processing: break
        default: start()
        }
    }

    /// Hold to talk (the shortcut, or the welcome tour's keys): listening while it's held.
    func pushToTalkDown() {
        guard model.voice != .recording, !starting else { return }
        pushToTalkActive = true
        start()
    }

    /// Hold to ask: listening from the key going down; `stop()` on release sends the words.
    func askDown(revealAfter: TimeInterval = 0) {
        guard model.voice != .recording, model.voice != .processing, !starting else { return }
        pushToTalkActive = true
        start(intent: .ask, revealAfter: revealAfter)
    }

    func askUp() { pushToTalkUp() }

    func pushToTalkUp() {
        guard pushToTalkActive else { return }
        pushToTalkActive = false
        stop()
    }

    /// Clicking the notch: stop while recording, dismiss a result.
    func handleClick() {
        switch model.voice {
        case .recording: stop()
        case .result, .error, .done: dismiss()
        // An answer's own buttons (Run, Cancel, a link) take clicks; Esc or a click elsewhere puts it away.
        default: break
        }
    }

    // MARK: Flow

    /// Recording, not shown yet (hold to ask's first moment): released now, it was a tap.
    private var hiddenStart = false
    private var revealWork: DispatchWorkItem?

    /// The recording notch and its sound, for a recording that's already started.
    private func reveal(_ pressed: Date) {
        revealWork = nil
        hiddenStart = false
        Sounds.start()
        model.partial = ""
        model.levels = Array(repeating: 0, count: VoiceLayout.barCount)
        model.recordingStart = pressed
        model.setVoice(.recording)
    }

    /// `revealAfter`: the mic starts now (nothing you say is lost), the notch and sound once it's
    /// clear this is a hold and not a tap.
    func start(intent: Intent = .dictate, revealAfter: TimeInterval = 0) {
        guard !starting, model.voice != .recording, model.voice != .processing else { return }
        guard intent == .ask || settings.dictationEnabled else { return }  // dictation is off (General)
        // Dictation is free, no account; asking is AI: free with your own key, or Pro.
        guard intent != .ask || StarlightAccount.shared.check(.ai, on: model) else { return }
        if model.voice == .answer { onAnswerClosed?() }
        self.intent = intent
        starting = true
        stopWhenStarted = false
        // Anything still waiting to put the last result away is called off.
        dismissWork?.cancel()
        dismissWork = nil
        parkedCheck?.cancel()
        parkedCheck = nil
        model.resultTimer = nil
        let pressed = Date()
        let testAudio = Dev.env("STARLIGHT_TEST_AUDIO")

        // Mic first, then the notch: with the mic already allowed, recording starts right here, before
        // anything is drawn (the opening animation used to run first and delay the mic ~100 ms).
        // revealAfter (hold to ask): the notch and sound wait until it's clearly a hold.
        if testAudio != nil || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            if beginRecording(pressed: pressed, testAudio: testAudio) {
                if revealAfter > 0 {
                    hiddenStart = true
                    model.recordingStart = pressed
                    let work = DispatchWorkItem { [weak self] in self?.reveal(pressed) }
                    revealWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + revealAfter, execute: work)
                } else {
                    reveal(pressed)
                }
            }
            finishStarting()
            return
        }
        // First use: macOS asks for the mic first (its bubble waiting under the notch), then the
        // notch opens. Said no before: the bubble's Allow opens System Settings.
        let firstTime = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        MainActor.assumeIsolated { PermissionAsk.shared.need("mic", prompting: firstTime) }
        Task { @MainActor in
            defer { starting = false }
            guard await AudioCapture.requestPermission() else { return show(error: "Mic access is off") }
            if beginRecording(pressed: pressed, testAudio: nil) { reveal(Date()) }
            finishStarting()
        }
    }

    /// Starts the engine and the mic. False (and an error shown) if the mic didn't start.
    private func beginRecording(pressed: Date, testAudio: String?) -> Bool {
        engine.prepare()
        // The polish model loads once you've been talking a moment (a quick dictation never
        // needs it), so its 900 MB doesn't land on the GPU the instant you press the key.
        if settings.aiCleanup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.model.voice == .recording else { return }
                self.cleanup.warmUp()
            }
        }
        engine.start(onPartial: { [weak self] text in
            guard let self, self.settings.liveText else { return }
            self.model.setPartial(self.settings.transcriptionStyle == .verbatim ? text : TextCleaner.clean(text))
        })
        do {
            if let path = testAudio { try capture.startFile(URL(fileURLWithPath: path)) } else { try capture.start() }
        } catch {
            engine.cancel()
            DebugLog.write("capture: start failed: \(error)")
            show(error: "Mic didn't start")
            return false
        }
        DebugLog.write(String(format: "dictation start: mic live %.0f ms after the key (%@)",
                              Date().timeIntervalSince(pressed) * 1000, capture.deviceName))
        micStart = (pressed, Date())
        return true
    }

    private func finishStarting() {
        cancelKey = HotKey(.cancel, onPress: { [weak self] in self?.cancel() })
        // Stop pressed while starting: done starting first, so stop() doesn't just defer again.
        starting = false
        if stopWhenStarted { stopWhenStarted = false; stop() }
    }

    func stop() {
        if starting { stopWhenStarted = true; return }
        // Let go before it was shown: a tap of the key, not a question. Nothing to show or keep.
        if hiddenStart { return cancel() }
        guard model.voice == .recording else { return }
        let recorded = Date().timeIntervalSince(model.recordingStart)
        if recorded < minimumRecording { return cancel() }
        capture.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.capture.prepare() }
        cancelKey = nil
        Sounds.stop()
        model.processingLabel = model.engineStatus == .ready ? "Transcribing" : "Loading model"
        model.setVoice(.processing)
        startProcessingWave()
        let trace = Trace(.dictation, label: "Dictation, \(String(format: "%.1f", recorded)) s")
        if let micStart { trace.span(.mic, "Key → mic live", from: micStart.pressed, to: micStart.live) }
        Task { @MainActor in
            let started = Date()
            let raw: String
            do {
                raw = try await engine.finish()
            } catch {
                stopProcessingWave()
                return show(error: "Transcription failed")
            }
            let transcribed = Date()
            trace.span(.transcription, "Parakeet, last words", from: started, to: transcribed)
            // Verbatim keeps Parakeet's words as they are; clean and polished tidy them.
            var text = settings.transcriptionStyle == .verbatim ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : TextCleaner.clean(raw)
            DebugLog.write(String(format: "transcribe %.2fs", transcribed.timeIntervalSince(started)) + "\n  raw:   \(raw)\n  rules: \(text)")
            if intent == .ask {
                // The bars keep moving while the agent thinks; the answer replaces them.
                guard model.voice == .processing else { return stopProcessingWave() }
                guard !text.isEmpty else { stopProcessingWave(); return show(error: "Didn't hear anything") }
                model.processingLabel = "Thinking"
                trace.span(.writing, "Sent to the agent", from: transcribed)
                Timings.shared.add(trace)
                cancelKey = HotKey(.cancel, onPress: { [weak self] in self?.cancel() })
                onAsk?(text)
                return
            }
            guard model.voice == .processing else { return stopProcessingWave() }
            guard !text.isEmpty else { stopProcessingWave(); return show(error: "Didn't hear anything") }

            // Paste into text fields: straight into the box your cursor is in. With the AI polish on,
            // the polished text goes in (it waits up to 2.5 s for it); otherwise right away.
            var pasting = settings.autoPaste && Dev.env("STARLIGHT_TEST_AUDIO") == nil
                && AutoPaste.cursorInTextField()
            let target = NSWorkspace.shared.frontmostApplication?.processIdentifier
            var polishedEarly = false
            if pasting, settings.aiCleanup, cleanup.state == .ready {
                model.processingLabel = "Polishing"
                // One budget for the whole polish: generation stops at the deadline.
                let input = text
                if let polished = await cleanup.polish(input, total: 2.5) {
                    text = polished
                    polishedEarly = true
                }
                guard model.voice == .processing else { return }
            }
            // The bars keep moving through "Polishing"; they stop as the result shows.
            stopProcessingWave()
            // You switched apps while it polished: ⌘V would land somewhere else, so it's copied instead.
            if pasting, NSWorkspace.shared.frontmostApplication?.processIdentifier != target { pasting = false }
            model.dictationPasted = pasting

            // Shown and on the clipboard at once; the AI polish (about a second) swaps in after.
            let entry = DictationHistory.shared.add(text, duration: recorded)
            // Always on the clipboard; pasted too when you're typing somewhere, so it's never lost.
            let clip = pasting ? nil : copy(text)
            if pasting { AutoPaste.paste(text, keepOnClipboard: true) }
            // It could have gone straight into the text box with Accessibility on.
            if settings.autoPaste, !AutoPaste.isAllowed, Dev.env("STARLIGHT_TEST_AUDIO") == nil {
                PermissionAsk.shared.need("accessibility", blocking: false)
            }
            if settings.closeAfterDictation || pasting {
                // Closes by itself: a tick and "Copied" (or "Pasted") beside the camera, then the notch is small again.
                model.setVoice(.done(copied: clip != nil || pasting))
                let work = DispatchWorkItem { [weak self] in self?.dismiss() }
                dismissWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
            } else {
                model.setVoice(.result(text))
                scheduleDismiss(after: settings.resultSeconds)
            }
            trace.span(.writing, "Cleanup and clipboard", from: transcribed)
            trace.mark("shown")
            trace.mark("done")
            Timings.shared.add(trace)

            guard !pasting, !polishedEarly, settings.aiCleanup, cleanup.state == .ready,
                  let polished = await cleanup.polish(text), polished != text else { return }
            DebugLog.write(String(format: "polish %.2fs", Date().timeIntervalSince(transcribed)) + "\n  final: \(polished)")
            trace.span(.polish, "AI polish (after it's shown)", from: transcribed)
            Timings.shared.objectWillChange.send()
            DictationHistory.shared.replace(entry, with: polished)
            // Only if the clipboard still holds our text (you haven't copied something else since).
            if let clip, NSPasteboard.general.changeCount == clip { copy(polished) }
            if case .result(let shown) = model.voice, shown == text { model.setVoice(.result(polished)) }
        }
    }

    /// Puts the text on the clipboard if that's on (or `always`); returns the clipboard's change
    /// count after.
    @discardableResult
    private func copy(_ text: String) -> Int? {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return NSPasteboard.general.changeCount
    }

    /// The agent's first words (or an approval) arrived: the card takes over from the bars.
    func showAnswer() {
        guard model.voice == .processing || model.voice == .answer else { return }
        stopProcessingWave()
        dismissWork?.cancel()
        dismissWork = nil
        if cancelKey == nil { cancelKey = HotKey(.cancel, onPress: { [weak self] in self?.dismiss() }) }
        model.setVoice(.answer)
    }

    /// Hold to ask got nothing back in time.
    func answerFailed(_ message: String) {
        guard model.voice == .processing else { return }
        stopProcessingWave()
        cancelKey = nil
        show(error: message)
    }

    func cancel() {
        revealWork?.cancel()
        revealWork = nil
        hiddenStart = false
        defer { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.capture.prepare() } }
        if model.voice == .answer || (intent == .ask && model.voice == .processing) { onAnswerClosed?() }
        capture.stop()
        engine.cancel()
        cancelKey = nil
        pushToTalkActive = false
        stopProcessingWave()
        model.setVoice(.idle)
    }

    /// The notch went back to rest after dictating (the pointer may still be on it).
    var onClosed: (() -> Void)?

    func dismiss() {
        if model.voice == .answer { onAnswerClosed?() }
        if model.voice.isActive { onClosed?() }
        cancelKey = nil
        parkedCheck?.cancel()
        dismissWork?.cancel()
        dismissWork = nil
        model.resultTimer = nil
        model.setVoice(.idle)
    }

    private func show(error message: String) {
        Sounds.error()
        model.setVoice(.error(message))
        scheduleDismiss(after: 3)
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissWork?.cancel()
        // Only puts a result away: never a new dictation that started meanwhile.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            switch self.model.voice {
            case .result, .error, .done: self.dismiss()
            default: break
            }
        }
        dismissWork = work
        // The countdown always starts: a pointer that just happens to be where the result
        // appeared doesn't hold it. Moving onto the notch afterwards does (isPointerOver).
        model.resultTimer = ResultTimer(duration: seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// While transcribing, the bars run a travelling sine wave.
    private func startProcessingWave() {
        var phase = 0.0
        waveTimer?.invalidate()
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            phase += 0.22
            self?.model.levels = (0..<VoiceLayout.barCount).map { i in
                Int(34 + 24 * sin(phase - Double(i) * 0.42))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        waveTimer = timer
    }

    private func stopProcessingWave() {
        waveTimer?.invalidate()
        waveTimer = nil
    }
}

/// Appends to ~/Library/Logs/Starlight.log (timings and transcripts, for tuning). Only in dev
/// builds, or with `defaults write com.starlightnotch.app debugLog -bool true`: released copies keep
/// no log of what you say. Starts over past 5 MB.
enum DebugLog {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Starlight.log")
    static let enabled = Keychain.teamID == nil || UserDefaults.standard.bool(forKey: "debugLog")

    static func write(_ line: String) {
        guard enabled else { return }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        let entry = "\(Date()) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }
}
