import AppKit
import Combine
import SwiftUI

/// The welcome tour: a short journey in the notch itself, simple enough for a child. Each step
/// is one line in the notch and one small bubble under it, like a permission card: what it is
/// on the left ("Microphone · hears you"), the one thing to do on the right ("Allow"). While you
/// do it, the bubble says what's happening and what comes next ("When you're done, press
/// Control Space"); when it's done, the action turns into a green check, the notch says
/// something nice, and on to the next.
///
/// One short flow to a first dictation in under a minute, with no account: hello, allow the
/// microphone, allow typing, then press the keys and talk. The voice model has been downloading
/// since launch; a bar under each line shows how far along it is, so nothing waits for it until
/// you talk. Then asking Starlight (connect an AI provider), open at login, and done. Steps already done (allowed) are skipped, and each
/// permission moves on by itself the moment it's granted. A step that waits on you offers Skip,
/// quietly, after a while.
@MainActor
final class NotchTour: ObservableObject, BubbleOwner {
    static let shared = NotchTour()

    enum Step: Int, CaseIterable { case hello, microphone, typing, talk, ai, startup, done }

    typealias Bubble = NotchBubble

    @Published private(set) var step: Step?

    weak var model: NotchModel?
    weak var voice: VoiceController?
    var isRunning: Bool { step != nil }

    private let host = BubbleHost.shared
    /// The tour's bubble, while it's up.
    private var bubble: Bubble? { host.bubble(of: self) }
    private var watchers: Set<AnyCancellable> = []
    private var timers: [DispatchWorkItem] = []
    private var poll: Timer?
    private var dictationAtStart: UUID?
    /// Came back to this step from its dot: it shows even when it's done already, and waits.
    private var revisiting = false
    /// Follows the voice model's download for the whole tour (not reset between steps).
    private var downloadWatcher: AnyCancellable?
    private let settings = AppSettings.shared

    /// STARLIGHT_TOUR_PREVIEW: every step waits for you, even ones already done (to look at them).
    private let preview = Dev.env("STARLIGHT_TOUR_PREVIEW") != nil

    private var micAllowed: Bool { !preview && Permission.all.first { $0.id == "mic" }?.state() == .allowed }
    private var typingAllowed: Bool { !preview && AXIsProcessTrusted() }

    /// The steps, for the progress dots.
    private let dotted: [Step] = Step.allCases

    /// The practice uses the dictation shortcut: press, talk, press again.
    private var talkKeys: String { settings.dictationShortcut.display }
    private var liveKeys: String { settings.askKey.display }

    // MARK: Running

    func start() {
        guard let model else { return }
        end(seen: false)
        model.set(.closed)
        model.setHovering(false)
        // STARLIGHT_TOUR_STEP=talk (any step's name): starts there, for checking one step.
        let first = Dev.env("STARLIGHT_TOUR_STEP").flatMap { name in Step.allCases.first { "\($0)" == name } }
        go(first ?? .hello)
        // The download bar under each line until the voice is in.
        downloadWatcher = model.$engineStatus.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshDownload() }
    }

    /// How far the voice model's download is, while it's downloading (0…1, the download alone).
    private var downloadFraction: Double? {
        guard let model, case .loading(_, let fraction) = model.engineStatus, !preview else { return nil }
        // FluidAudio's fraction runs 0…0.5 for the download and 0.5…1 for preparing it.
        return min((fraction ?? 0) / 0.5, 1)
    }

    /// The bar under the notch's line, kept current. Not on the practice step, whose bubble has its own.
    private func refreshDownload() {
        guard let model, let tutorial = model.tutorial, !tutorial.invite, step != .talk, step != nil else { return }
        let download = downloadFraction
        guard tutorial.download != download else { return }
        model.tutorial = NotchModel.Tutorial(title: tutorial.title, detail: tutorial.detail, wordmark: tutorial.wordmark,
                                             progress: tutorial.progress, steps: tutorial.steps, download: download)
    }

    /// Ends the tour: the bubble rises back in and the notch rests. `seen` means it counts as
    /// done, so it doesn't come back next launch.
    private func end(seen: Bool) {
        let wasRunning = step != nil
        if seen { UserDefaults.standard.set(true, forKey: Onboarding.doneKey) }
        reset()
        downloadWatcher = nil
        step = nil
        host.hide(self)
        if wasRunning, let model { withAnimation(model.scaled(Motion.close)) { model.tutorial = nil } }
    }

    private func reset() {
        timers.forEach { $0.cancel() }
        timers.removeAll()
        watchers.removeAll()
        poll?.invalidate(); poll = nil
    }

    private func next(after seconds: Double = 0) {
        guard let from = step else { return }
        later(seconds) {
            guard self.step == from else { return }
            if let following = Step(rawValue: from.rawValue + 1) { self.go(following) } else { self.end(seen: true) }
        }
    }

    /// A progress dot was clicked: back to that earlier step.
    func back(to index: Int) {
        guard let current = step, let here = dotted.firstIndex(of: current), dotted.indices.contains(index), index < here else { return }
        if model?.voice.isActive == true { voice?.cancel() }
        revisiting = true
        go(dotted[index])
    }

    private func go(_ step: Step) {
        guard let model else { return }
        reset()
        let revisit = revisiting
        revisiting = false
        self.step = step
        DebugLog.write("tour: \(step)")
        host.hide(self)
        switch step {
        case .hello:
            line(model, "Starlight", wordmark: true)
            offer(.init(label: "No account needed", action: .button("Get started")), after: 0.6)

        case .microphone:
            if micAllowed && revisit { return done(model, "Let me hear you.", label: "Microphone", sub: "allowed") }
            guard !micAllowed else { return go(.typing) }
            line(model, "Let me hear you.")
            offer(Self.allow("mic"), after: 0.5)
            watchPermission({ self.micAllowed }, praise: "Got it!")

        case .typing:
            if typingAllowed && revisit { return done(model, "Let me type for you.", label: "Accessibility", sub: "allowed") }
            guard !typingAllowed else { return go(.talk) }
            line(model, "Let me type for you.")
            offer(Self.allow("accessibility"), after: 0.5)
            watchPermission({ self.typingAllowed }, praise: "Perfect!")

        case .talk:
            talk(model)

        case .ai:
            // Asking Starlight needs an AI: connected already, the keys; otherwise, a way to connect one.
            if settings.hasAnswerKey && !preview {
                line(model, "Ask me anything.", keys: liveKeys)
                offer(.init(label: "Questions, or things to do", action: .button("Got it")), after: 0.6)
            } else {
                line(model, "Want to ask me questions?")
                offer(.init(label: "Connect an AI provider", action: .button("Set up"), quiet: "Not now"), after: 0.6)
            }

        case .startup:
            // A notch app that's gone after a restart is one you forget: offered once, here.
            if LoginItem.isEnabled && revisit { return done(model, "Start me with your Mac?", label: "Open at login", sub: "on") }
            guard !LoginItem.isEnabled || preview else { return go(.done) }
            line(model, "Start me with your Mac?")
            offer(.init(label: "Open at login", action: .button("Turn on"), quiet: "Not now"), after: 0.6)

        case .done:
            line(model, "You’re all set!")
            offer(.init(label: "Hover me any time", action: .button("Done")), after: 0.6)
            later(0.6) { Sounds.playSuccess() }
            later(15) { self.end(seen: true) }
        }
    }

    /// Dictation, guided as you go: press the keys, talk, press them again, and your words land
    /// where you're typing. The voice model may still be downloading: the bubble shows how far,
    /// then the keys once it's in.
    private func talk(_ model: NotchModel) {
        let hold = settings.dictationKeyMode == .hold
        line(model, hold ? "Hold, and talk." : "Press, and talk.", keys: talkKeys)
        dictationAtStart = DictationHistory.shared.entries.first?.id
        let start = Bubble(label: hold ? "Let go when you're done" : "Press again when you're done", action: .keys(talkKeys, hold: false), duringVoice: true)
        model.$engineStatus.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] status in
            guard let self, self.step == .talk, !model.voice.isActive else { return }
            switch status {
            case .loading(let label, let fraction):
                let sub = label == ParakeetModel.downloadingLabel ? ParakeetModel.downloadSize : "almost ready"
                self.show(Bubble(label: "Getting my voice ready", sub: sub,
                                 action: .progress(fraction.map { ($0 * 100).rounded() / 100 }), duringVoice: true))
            case .failed:
                self.show(Bubble(label: "Couldn’t download my voice", sub: "check your internet", action: .button("Try again"), quiet: "Skip"))
            case .ready, .idle:
                if self.bubble?.action != .keys(self.talkKeys, hold: false) { self.show(start) }
            }
        }.store(in: &watchers)
        model.$voice.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] phase in
            guard let self, self.step == .talk, self.voice?.intent != .ask else { return }
            switch phase {
            case .recording:
                // The most important thing to know while it listens: how to finish.
                self.show(Bubble(label: hold ? "Let go when you’re done" : "When you’re done, press", action: .keys(self.talkKeys, hold: false), duringVoice: true))
            case .processing:
                self.show(Bubble(label: "Writing it down", action: .working, duringVoice: true))
            case .idle:
                // Stopped without any words: back to the start.
                if DictationHistory.shared.entries.first?.id == self.dictationAtStart { self.show(start) }
            default: break
            }
        }.store(in: &watchers)
        DictationHistory.shared.$entries.receive(on: RunLoop.main).sink { [weak self] entries in
            guard let self, self.step == .talk, let newest = entries.first, newest.id != self.dictationAtStart else { return }
            self.dictationAtStart = newest.id
            self.waitUntil({ !model.voice.isActive }) { self.praise("Nice! You just dictated.", label: "Works in any app") }
        }.store(in: &watchers)
        offerSkip(after: 45)
    }

    // MARK: Taps

    func tap(quiet: Bool, provider: StarlightAccount.Provider?) {
        guard let step else { return }
        if quiet { return next() }  // Not now, or Skip: on to the next step
        switch step {
        case .hello: next()
        case .done: end(seen: true)
        case .startup:
            if LoginItem.isEnabled && bubble?.action == .button("Continue") { return next() }
            LoginItem.set(true)
            praise("I’ll be here.", label: LoginItem.needsApproval ? "Allow it in Login Items" : "Opens at login")
        case .microphone:
            if micAllowed { return next() }  // came back to it: Continue
            Permission.named("mic")?.ask()
        case .typing:
            if typingAllowed { return next() }
            if Permission.named("accessibility")?.ask() == true, let model { line(model, "Turn on Starlight in the list.") }
        case .talk:
            if case .failed = model?.engineStatus { ParakeetModel.shared.prepare() } else { voice?.toggle() }  // Try again, or the keys
        case .ai:
            if !settings.hasAnswerKey { CompanionWindow.shared.show(.ai) }  // Connect: pick one in Settings
            next()
        }
    }

    /// A step you came back to that's done already: its line, a check beside what it is, and
    /// Continue, so it waits for you instead of moving on by itself.
    private func done(_ model: NotchModel, _ title: String, label: String, sub: String) {
        line(model, title)
        offer(Bubble(label: label + " ✓", sub: sub, action: .button("Continue")), after: 0.3)
    }

    /// Nothing in the tour is held now (the practice is press, talk, press again).
    func hold(_ down: Bool) {}

    // MARK: Pieces

    /// One short line in the notch (and sometimes a quiet one under it), and dots for where you are.
    private func line(_ model: NotchModel, _ title: String, detail: String = "", wordmark: Bool = false, keys: String? = nil) {
        let place = step.flatMap { dotted.firstIndex(of: $0) }
        let tutorial = NotchModel.Tutorial(title: title, detail: wordmark ? "Private voice typing and AI." : detail, wordmark: wordmark,
                                           progress: place, steps: dotted.count, download: step == .talk ? nil : downloadFraction, keys: keys)
        withAnimation(model.scaled(Motion.open)) { model.tutorial = tutorial }
    }


    private func offer(_ new: Bubble, after delay: Double) {
        let current = step
        later(delay) { if self.step == current { self.show(new) } }
    }

    private func show(_ new: Bubble) {
        guard let step else { return }
        host.show(new, key: "tour.\(step)", owner: self)
    }

    /// For a step that waits on you: after a while, a quiet Skip (or `label`) in the same bubble.
    private func offerSkip(after seconds: Double, label: String = "Skip") {
        let current = step
        later(seconds) {
            guard self.step == current, var bubble = self.bubble, bubble.quiet == nil, bubble.action != .check, bubble.action != .working,
                  self.model?.voice.isActive != true else { return }
            bubble.quiet = label
            self.show(bubble)
        }
    }

    /// Done: the bubble's action turns into a green check, the notch says something nice, a
    /// chime, and on to the next. `label` changes what the bubble says, when it said what to do.
    private func praise(_ words: String, label: String? = nil) {
        guard let step, let model else { return }
        reset()
        Sounds.playSuccess()
        line(model, words)
        var done = bubble ?? Bubble(label: label ?? "", action: .check)
        if let label { done.label = label; done.sub = nil }
        done.action = .check
        done.quiet = nil
        done.busy = false
        done.duringVoice = true
        show(done)
        let current = step
        later(1.9) {
            guard self.step == current else { return }
            if let following = Step(rawValue: current.rawValue + 1) { self.go(following) } else { self.end(seen: true) }
        }
    }


    private func watchPermission(_ allowed: @escaping () -> Bool, praise words: String) {
        let current = step
        poll = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.step == current, allowed() else { return }
                self.praise(words)
            }
        }
        offerSkip(after: 25)
    }

    /// A permission's bubble: "Microphone · hears you  [Allow]".
    static func allow(_ id: String) -> Bubble {
        let permission = Permission.named(id)
        return Bubble(label: permission?.name ?? id, sub: permission?.does, action: .button("Allow"))
    }

    private func later(_ seconds: Double, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        timers.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Runs `work` once `condition` holds (checked a few times a second), or after `seconds` if
    /// it never does.
    private func waitUntil(_ condition: @escaping () -> Bool, orAfter seconds: Double = .infinity, _ work: @escaping () -> Void) {
        let current = step
        let deadline = Date().addingTimeInterval(seconds)
        func check() {
            guard step == current else { return }
            if condition() || Date() > deadline { work() } else { later(0.2, check) }
        }
        check()
    }
}
