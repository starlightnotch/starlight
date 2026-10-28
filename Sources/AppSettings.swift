import AppKit
import Carbon.HIToolbox
import Combine
import Security

/// Everything the settings window changes, saved in UserDefaults (the OpenRouter key is in the
/// Keychain). Controllers read from `AppSettings.shared` and react to changes.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    // Features, each on or off (Settings → General). Off, its shortcuts are left free for other
    // apps, it's gone from the notch and the menu, and its settings grey out.
    @Published var dictationEnabled: Bool { didSet { defaults.set(dictationEnabled, forKey: "dictationEnabled") } }
    @Published var meetingsEnabled: Bool { didSet { defaults.set(meetingsEnabled, forKey: "meetingsEnabled") } }
    @Published var liveEnabled: Bool { didSet { defaults.set(liveEnabled, forKey: "liveEnabled") } }

    // General
    /// Open the notch after resting the pointer on it, without clicking .
    @Published var openOnHover: Bool { didSet { defaults.set(openOnHover, forKey: "openOnHover") } }
    @Published var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    /// Spotify / Music beside the closed notch and in the open one.
    @Published var showNowPlaying: Bool { didSet { defaults.set(showNowPlaying, forKey: "showNowPlaying") } }
    /// A moment of name and battery when headphones connect.
    @Published var showHeadphones: Bool { didSet { defaults.set(showHeadphones, forKey: "showHeadphones") } }
    /// The tasks tab in the bottom-right corner of the screen.
    @Published var showTasksCorner: Bool { didSet { defaults.set(showTasksCorner, forKey: "showTasksCorner") } }
    /// Tasks on or off (the Tasks page's switch). Off, they're nowhere: not in the corner, not
    /// written down from meetings, not in the notch or the menu, and the agent can't add any.
    @Published var tasksEnabled: Bool { didSet { defaults.set(tasksEnabled, forKey: "tasksEnabled") } }
    /// The transcript overlay opens by itself when notes or Live mode start.
    @Published var openOverlayWithSessions: Bool { didSet { defaults.set(openOverlayWithSessions, forKey: "openOverlayWithSessions") } }
    /// Exclude the notch and Starlight's window from screenshots, recordings and screen sharing.
    @Published var hideFromCapture: Bool { didSet { defaults.set(hideFromCapture, forKey: "hideFromCapture"); CaptureVisibility.apply() } }
    /// The mic: Smart (empty, the default), one of Microphone's choices, or the UID of one that's
    /// always used while it's connected (AudioCapture.preferredInputDevice).
    /// The microphone choices besides one particular mic.
    enum Microphone {
        static let smart = "", bluetooth = "@bluetooth", builtIn = "@builtin", system = "@system"
        static let choices = [smart, bluetooth, builtIn, system]
    }
    @Published var microphoneUID: String { didSet { defaults.set(microphoneUID, forKey: "microphoneUID") } }
    /// Where the notch hides while nothing's happening: on screens without a camera notch
    /// (an external monitor), everywhere, or nowhere. It comes back for anything it shows.
    enum MonitorMode: String, CaseIterable { case auto, show, hide }
    @Published var monitorMode: MonitorMode { didSet { defaults.set(monitorMode.rawValue, forKey: "monitorMode") } }

    // Motion
    @Published var animationSpeed: Double { didSet { defaults.set(animationSpeed, forKey: "animationSpeed") } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "sounds") } }
    @Published var startSound: String { didSet { defaults.set(startSound, forKey: "startSound") } }
    @Published var stopSound: String { didSet { defaults.set(stopSound, forKey: "stopSound") } }

    // Dictation
    /// How speech becomes text: word for word, tidied by rules, or polished by the local model.
    enum TranscriptionStyle: String, CaseIterable { case verbatim, clean, polished }
    /// How big the notch's text is; every card grows with it (TextScale).
    enum TextSize: String, CaseIterable {
        case smaller, standard, larger, largest
        var factor: CGFloat { switch self { case .smaller: 0.9; case .standard: 1; case .larger: 1.15; case .largest: 1.3 } }
    }
    @Published var textSize: TextSize { didSet { defaults.set(textSize.rawValue, forKey: "textSize"); TextScale.factor = textSize.factor } }
    /// Which speech model: English (Parakeet v2, the fastest and most accurate in English) or 25
    /// European languages (Parakeet v3: the same speed, it works out the language by itself).
    enum SpeechLanguages: String, CaseIterable { case english, european }
    @Published var speechLanguages: SpeechLanguages {
        didSet {
            defaults.set(speechLanguages.rawValue, forKey: "speechLanguages")
            if speechLanguages != oldValue { ParakeetModel.shared.reload() }
        }
    }
    /// Let the voice model go after 30 idle minutes (saves memory; the next dictation waits a
    /// second or two). Off by default: it loads at launch and stays loaded.
    @Published var unloadVoiceModel: Bool {
        didSet {
            defaults.set(unloadVoiceModel, forKey: "unloadVoiceModel")
            if unloadVoiceModel != oldValue { ParakeetModel.shared.unloadSettingChanged() }
        }
    }
    /// Beta: web search runs on this Mac (LocalSearch) instead of the provider's paid search.
    @Published var searchOnMac: Bool { didSet { defaults.set(searchOnMac, forKey: "searchOnMac") } }
    @Published var transcriptionStyle: TranscriptionStyle { didSet { defaults.set(transcriptionStyle.rawValue, forKey: "transcriptionStyle") } }
    var aiCleanup: Bool { transcriptionStyle == .polished }
    /// When dictation ends: close straight away (a moment of "Copied"), or show the text.
    @Published var closeAfterDictation: Bool { didSet { defaults.set(closeAfterDictation, forKey: "closeAfterDictation") } }
    /// Paste the dictation into the text field your cursor is in (needs Accessibility).
    @Published var autoPaste: Bool { didSet { defaults.set(autoPaste, forKey: "autoPaste") } }
    /// How readily speech is picked up during notes, 0 (only clear speech) to 1 (quiet voices too).
    @Published var voiceSensitivity: Double { didSet { defaults.set(voiceSensitivity, forKey: "voiceSensitivity") } }
    @Published var resultSeconds: Double { didSet { defaults.set(resultSeconds, forKey: "resultSeconds") } }
    @Published var liveText: Bool { didSet { defaults.set(liveText, forKey: "liveText") } }

    // Notes
    @Published var notesPause: Double { didSet { defaults.set(notesPause, forKey: "notesPause") } }
    /// When a meeting app starts using the mic: offer notes, start them, or nothing.
    enum MeetingMode: String, CaseIterable { case ask, auto, off }
    @Published var meetingMode: MeetingMode { didSet { defaults.set(meetingMode.rawValue, forKey: "meetingMode") } }
    /// Your words as you say them during notes: under the notch, and in the transcript panel.
    @Published var captionsNotch: Bool { didSet { defaults.set(captionsNotch, forKey: "captionsNotch") } }
    @Published var captionsTranscript: Bool { didSet { defaults.set(captionsTranscript, forKey: "captionsTranscript") } }
    /// Capture the other people's side (what the Mac plays) during notes.
    @Published var captureTheirAudio: Bool { didSet { defaults.set(captureTheirAudio, forKey: "captureTheirAudio") } }
    /// Why their side isn't being captured, if it isn't ("Not allowed"); not saved.
    @Published var theirAudioProblem: String?
    /// Answer questions under the notch as you ask them during notes.
    @Published var liveAnswers: Bool { didSet { defaults.set(liveAnswers, forKey: "liveAnswers") } }
    /// Silent mode: meetings and Live keep listening and taking notes, but Starlight doesn't answer on
    /// its own. "Starlight, …", hold-to-ask and typed questions still get answers.
    @Published var silentMode: Bool { didSet { defaults.set(silentMode, forKey: "silentMode") } }
    @Published var silentShortcut: HotKey.Combo { didSet { save(silentShortcut, "silentShortcut") } }
    @Published var liveAnswerSeconds: Double { didSet { defaults.set(liveAnswerSeconds, forKey: "liveAnswerSeconds") } }
    /// The agent's prompt; empty uses the built-in one.
    @Published var agentPrompt: String { didSet { defaults.set(agentPrompt, forKey: "agentPrompt") } }

    // Agent behavior
    /// In meetings: help on its own (answer what people ask, add what helps), or only when asked.
    /// A saved "proactive" from before (a third, chattier mode) reads as helping.
    enum Proactivity: String, CaseIterable { case quiet, balanced }
    enum AnswerLength: String, CaseIterable { case short, normal, detailed }
    enum DeepMode: String, CaseIterable { case auto, always, off }
    /// How often the agent speaks up on its own.
    @Published var proactivity: Proactivity { didSet { defaults.set(proactivity.rawValue, forKey: "proactivity") } }
    @Published var answerLength: AnswerLength { didSet { defaults.set(answerLength.rawValue, forKey: "answerLength") } }
    /// Long, worked answers with the stronger model: when the question needs it, always, or never.
    @Published var deepMode: DeepMode { didSet { defaults.set(deepMode.rawValue, forKey: "deepMode") } }
    /// Computer extension: ask before every command, or only before ones that change things.
    enum ComputerAsks: String, CaseIterable { case changes, always }
    @Published var computerAsks: ComputerAsks { didSet { defaults.set(computerAsks.rawValue, forKey: "computerAsks") } }

    // Shortcuts
    @Published var transcriptShortcut: HotKey.Combo { didSet { save(transcriptShortcut, "transcriptShortcut") } }
    /// Dictation's key, Control Space by default, pressed to start and stop or held while you talk.
    @Published var dictationShortcut: HotKey.Combo { didSet { save(dictationShortcut, "dictationShortcut") } }
    @Published var dictationKeyMode: KeyMode { didSet { defaults.set(dictationKeyMode.rawValue, forKey: "dictationKeyMode") } }
    @Published var notesShortcut: HotKey.Combo { didSet { save(notesShortcut, "notesShortcut") } }
    /// Live mode's key: Option Space by default, or a key on its own (Fn). Toggle starts and ends a
    /// Live conversation; held, it listens until you let go and answers that one question.
    @Published var askKey: AskKey { didSet { defaults.set(try? JSONEncoder().encode(askKey), forKey: "askKey") } }
    @Published var liveKeyMode: KeyMode { didSet { defaults.set(liveKeyMode.rawValue, forKey: "liveKeyMode") } }
    /// How a feature's key works: press to start and again to stop, or hold while you talk.
    enum KeyMode: String, CaseIterable { case toggle, hold }

    // AI answers
    /// Where answers come from: Pro, served by Starlight's backend (server/convex runs them on
    /// OpenRouter with its own key), your own key for OpenRouter, Anthropic or OpenAI, or a
    /// model running on your Mac in Ollama. Everything but Pro is free.
    enum AnswerService: String, CaseIterable, Identifiable {
        case notch, openrouter, anthropic, openai, ollama

        var id: String { rawValue }
        /// Where chat requests go (AIService shapes them for each).
        var endpoint: URL {
            switch self {
            case .notch: (StarlightAccount.serviceURL ?? URL(string: "https://invalid.local")!).appendingPathComponent("v1/chat/completions")
            case .openrouter: URL(string: "https://openrouter.ai/api/v1/chat/completions")!
            // STARLIGHT_ANTHROPIC_URL: another address, for testing against a stand-in.
            case .anthropic: URL(string: Dev.env("STARLIGHT_ANTHROPIC_URL") ?? "https://api.anthropic.com/v1/messages")!
            case .openai: URL(string: "https://api.openai.com/v1/chat/completions")!
            case .ollama: AppSettings.shared.ollamaBase.appendingPathComponent("v1/chat/completions")
            }
        }
        var displayName: String {
            switch self {
            case .notch: "Starlight"
            case .openrouter: "OpenRouter"
            case .anthropic: "Anthropic"
            case .openai: "OpenAI"
            case .ollama: "Local Ollama"
            }
        }
        /// Takes a key of your own (Pro uses your account; Ollama runs on your Mac).
        var needsKey: Bool { self == .openrouter || self == .anthropic || self == .openai }
        /// How its keys start, for the key field.
        var keyHint: String {
            switch self {
            case .openrouter: "sk-or-…"
            case .anthropic: "sk-ant-…"
            case .openai: "sk-…"
            default: ""
            }
        }
        /// Where to get a key.
        var keysPage: URL? {
            switch self {
            case .openrouter: URL(string: "https://openrouter.ai/keys")
            case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
            case .openai: URL(string: "https://platform.openai.com/api-keys")
            case .ollama: URL(string: "https://ollama.com/download")
            case .notch: nil
            }
        }
        /// The model it starts with: Claude Haiku 5.5 wherever it's offered (fast, and good with
        /// tools), GPT-5 mini on OpenAI. Ollama has none until you pick one you've pulled.
        var defaultModel: String {
            switch self {
            case .notch, .openrouter: "anthropic/claude-haiku-5.5"
            case .anthropic: "claude-haiku-5-5"
            case .openai: "gpt-5-mini"
            case .ollama: ""
            }
        }
        /// The ones this build offers: Pro only where accounts are set up.
        static var offered: [AnswerService] { StarlightAccount.hasService ? allCases : allCases.filter { $0 != .notch } }
    }
    /// Pro by default where this build has it (with accounts), OpenRouter otherwise.
    @Published var answerService: AnswerService {
        didSet {
            defaults.set(answerService.rawValue, forKey: "answerService")
            if answerService != oldValue { AIService.warmUp(answerService) }
        }
    }
    /// Ollama's address, for a model on this Mac (or another one on your network).
    @Published var ollamaURL: String { didSet { defaults.set(ollamaURL, forKey: "ollamaURL") } }
    var ollamaBase: URL {
        URL(string: ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            ?? URL(string: "http://localhost:11434")!
    }

    /// The model each service answers with (Settings → Answers); Pro's is Starlight's choice.
    func model(for service: AnswerService) -> String {
        guard service != .notch else { return service.defaultModel }
        let chosen = defaults.string(forKey: "model.\(service.rawValue)")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return chosen.isEmpty ? service.defaultModel : chosen
    }
    func setModel(_ model: String, for service: AnswerService) {
        objectWillChange.send()
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "model.\(service.rawValue)")
    }

    /// The model answers come from now.
    static var model: String { shared.model(for: shared.answerService) }
    static var modelName: String {
        let model = Self.model
        return model == AnswerService.notch.defaultModel ? "Claude Haiku 5.5" : model
    }

    /// How long the model thinks before it answers: not at all for everyday answers (fastest), hard
    /// for deep ones (code, real math, long problems).
    enum Thinking { case none, high }

    /// The model, the route and the thinking, for a chat request. On OpenRouter (and the answer
    /// service, which passes them on) Google Vertex serves Claude first, with OpenRouter's other
    /// Claude hosts behind it so an outage there doesn't stop answers. The other services get the
    /// thinking as a mark AIService turns into their own setting.
    static func applyModel(to body: inout [String: Any], thinking: Thinking = .none, service: AnswerService = shared.answerService) {
        let model = shared.model(for: service)
        body["model"] = model
        guard service == .notch || service == .openrouter else {
            if thinking == .high { body[AIService.thinkingKey] = "high" }
            return
        }
        if model.hasPrefix("anthropic/") {
            body["provider"] = ["order": ["google-vertex/global", "google-vertex"], "allow_fallbacks": true]
        }
        switch thinking {
        case .none:
            body["reasoning"] = ["effort": "none"]
        case .high:
            body["reasoning"] = ["effort": "high", "exclude": true]
            // Claude only thinks at its default temperature, and needs room past the thinking.
            body["temperature"] = nil
            body["max_tokens"] = max(body["max_tokens"] as? Int ?? 0, 12000)
        }
    }

    /// Answers can be asked for: Pro is on, a key is saved, or Ollama has a model picked.
    var hasAnswerKey: Bool {
        switch answerService {
        case .notch: StarlightAccount.hasPro
        case .ollama: !model(for: .ollama).isEmpty
        default: savedKeys.contains(answerService)
        }
    }
    var answerKey: String? { answerKeyFor(answerService) }
    /// The key, read off the main thread: if macOS asks before releasing it, the notch keeps working.
    func loadAnswerKey() async -> String? {
        let service = answerService
        switch service {
        case .notch: return await StarlightAccount.shared.accessToken()
        case .ollama: return "ollama"  // it takes none; callers want something to send
        default: return await Task.detached { Self.cleanKey(Keychain.read(service.rawValue), for: service) }.value
        }
    }

    /// The services with a key saved in the Keychain.
    @Published private(set) var savedKeys: Set<AnswerService>
    /// True while the settings window is recording a shortcut; Starlight's own shortcuts pause.
    @Published var recordingShortcut = false

    private init() {
        Self.moveSettingsFromOldID()
        defaults.register(defaults: [
            "dictationEnabled": true, "meetingsEnabled": true, "liveEnabled": true,
            "openOnHover": false, "showMenuBarIcon": false, "showNowPlaying": true, "showHeadphones": true, "showTasksCorner": false, "tasksEnabled": true, "openOverlayWithSessions": false, "hideFromCapture": true, "microphoneUID": "", "monitorMode": MonitorMode.auto.rawValue,
            "animationSpeed": 1.0, "haptics": true, "sounds": true, "startSound": "Starlight", "stopSound": "Starlight",
            "aiCleanup": true, "resultSeconds": 6.0, "liveText": true, "unloadVoiceModel": false, "autoPaste": true, "closeAfterDictation": true, "voiceSensitivity": 0.5,
            "proactivity": Proactivity.balanced.rawValue, "answerLength": AnswerLength.normal.rawValue, "deepMode": DeepMode.auto.rawValue,
            "notesPause": 0.8, "meetingMode": "ask", "captionsNotch": false, "captionsTranscript": true, "captureTheirAudio": true, "liveAnswers": false, "liveAnswerSeconds": 12.0,
        ])
        dictationEnabled = defaults.bool(forKey: "dictationEnabled")
        meetingsEnabled = defaults.bool(forKey: "meetingsEnabled")
        liveEnabled = defaults.bool(forKey: "liveEnabled")
        openOnHover = defaults.bool(forKey: "openOnHover")
        showMenuBarIcon = defaults.bool(forKey: "showMenuBarIcon")
        showNowPlaying = defaults.bool(forKey: "showNowPlaying")
        showHeadphones = defaults.bool(forKey: "showHeadphones")
        showTasksCorner = defaults.bool(forKey: "showTasksCorner")
        tasksEnabled = defaults.bool(forKey: "tasksEnabled")
        // The open-source build is dictation and Live mode: no meetings or tasks (see Edition).
        if Edition.isOpenSource { meetingsEnabled = false; tasksEnabled = false; showTasksCorner = false }
        openOverlayWithSessions = defaults.bool(forKey: "openOverlayWithSessions")
        hideFromCapture = defaults.bool(forKey: "hideFromCapture")
        microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        monitorMode = MonitorMode(rawValue: defaults.string(forKey: "monitorMode") ?? "") ?? .auto
        animationSpeed = defaults.double(forKey: "animationSpeed")
        haptics = defaults.bool(forKey: "haptics")
        sounds = defaults.bool(forKey: "sounds")
        // The app's own sound pair was called "Notch" before the rename.
        startSound = defaults.string(forKey: "startSound").map { $0 == "Notch" ? "Starlight" : $0 } ?? "Starlight"
        stopSound = defaults.string(forKey: "stopSound").map { $0 == "Notch" ? "Starlight" : $0 } ?? "Starlight"
        // The old on/off cleanup switch becomes polished (on) or clean (off).
        speechLanguages = SpeechLanguages(rawValue: defaults.string(forKey: "speechLanguages") ?? "") ?? .english
        let size = TextSize(rawValue: defaults.string(forKey: "textSize") ?? "") ?? .standard
        textSize = size
        TextScale.factor = size.factor
        // Clean by default: tidy and still instant. AI polish is a choice in Settings → Dictation.
        transcriptionStyle = TranscriptionStyle(rawValue: defaults.string(forKey: "transcriptionStyle") ?? "") ?? .clean
        closeAfterDictation = defaults.bool(forKey: "closeAfterDictation")
        voiceSensitivity = defaults.double(forKey: "voiceSensitivity")
        proactivity = Proactivity(rawValue: defaults.string(forKey: "proactivity") ?? "") ?? .balanced
        answerLength = AnswerLength(rawValue: defaults.string(forKey: "answerLength") ?? "") ?? .normal
        deepMode = DeepMode(rawValue: defaults.string(forKey: "deepMode") ?? "") ?? .auto
        autoPaste = defaults.bool(forKey: "autoPaste")
        computerAsks = ComputerAsks(rawValue: defaults.string(forKey: "computerAsks") ?? "") ?? .changes
        resultSeconds = defaults.double(forKey: "resultSeconds")
        liveText = defaults.bool(forKey: "liveText")
        unloadVoiceModel = defaults.bool(forKey: "unloadVoiceModel")
        searchOnMac = defaults.bool(forKey: "searchOnMac")
        notesPause = defaults.double(forKey: "notesPause")
        meetingMode = MeetingMode(rawValue: defaults.string(forKey: "meetingMode") ?? "") ?? .ask
        captionsNotch = defaults.bool(forKey: "captionsNotch")
        captionsTranscript = defaults.bool(forKey: "captionsTranscript")
        captureTheirAudio = defaults.bool(forKey: "captureTheirAudio")
        liveAnswers = defaults.bool(forKey: "liveAnswers")
        silentMode = defaults.bool(forKey: "silentMode")
        silentShortcut = Self.load("silentShortcut") ?? HotKey.Combo(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey), keyName: "S")
        liveAnswerSeconds = defaults.double(forKey: "liveAnswerSeconds")
        agentPrompt = defaults.string(forKey: "agentPrompt") ?? ""
        dictationShortcut = Self.load("dictationShortcut") ?? .toggleRecording
        dictationKeyMode = KeyMode(rawValue: defaults.string(forKey: "dictationKeyMode") ?? "") ?? .toggle
        notesShortcut = Self.load("notesShortcut") ?? .notes
        transcriptShortcut = Self.load("transcriptShortcut") ?? .transcript
        askKey = defaults.data(forKey: "askKey").flatMap { try? JSONDecoder().decode(AskKey.self, from: $0) } ?? .standard
        liveKeyMode = KeyMode(rawValue: defaults.string(forKey: "liveKeyMode") ?? "") ?? .toggle
        savedKeys = Set(AnswerService.allCases.filter { $0.needsKey && Keychain.exists($0.rawValue) })
        ollamaURL = defaults.string(forKey: "ollamaURL") ?? "http://localhost:11434"
        // Chosen in Settings → Answers; before that, Pro where this build has it (the hidden
        // `ownKey` default from before still picks your OpenRouter key).
        let chosen = defaults.string(forKey: "answerService").flatMap(AnswerService.init(rawValue:))
        answerService = chosen.flatMap { AnswerService.offered.contains($0) ? $0 : nil }
            ?? (StarlightAccount.hasService && !defaults.bool(forKey: "ownKey") ? .notch : .openrouter)
    }

    /// Settings saved under the old app ID (com.amadin.notch) come along once, the first time
    /// the app runs as com.starlightnotch.app.
    private static func moveSettingsFromOldID() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier == "com.starlightnotch.app", !defaults.bool(forKey: "movedFromOldID") else { return }
        if let old = defaults.persistentDomain(forName: "com.amadin.notch") {
            for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "movedFromOldID")
    }

    func resetShortcuts() {
        dictationShortcut = .toggleRecording
        dictationKeyMode = .toggle
        notesShortcut = .notes
        transcriptShortcut = .transcript
        askKey = .standard
        liveKeyMode = .toggle
        silentShortcut = HotKey.Combo(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey), keyName: "S")
    }

    // MARK: Keys

    /// Just the key, out of whatever was pasted: a whole `Authorization: Bearer sk-or-…` line,
    /// an `export KEY="…"`, quotes, line breaks. A key with spaces or line breaks in it is
    /// dropped from the request entirely ("Missing Authentication header").
    static func cleanKey(_ raw: String?, for service: AnswerService) -> String? {
        guard let raw else { return nil }
        let pattern = switch service {
        case .anthropic: #"sk-ant-[A-Za-z0-9_-]{20,}"#
        case .openai: #"sk-(proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}"#
        default: #"sk-or-[A-Za-z0-9_-]{20,}"#
        }
        if let match = raw.range(of: pattern, options: .regularExpression) { return String(raw[match]) }
        // No recognizable key: the longest run of key-like characters, without "Bearer" or quotes.
        let tokens = raw.split { !($0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0))) }
            .map(String.init).filter { $0.lowercased() != "bearer" }
        let best = tokens.max { $0.count < $1.count } ?? ""
        return best.isEmpty ? nil : best
    }

    /// The key looks like one for this service (the right prefix).
    static func looksLikeKey(_ key: String, for service: AnswerService) -> Bool {
        switch service {
        case .openrouter: key.hasPrefix("sk-or-")
        case .anthropic: key.hasPrefix("sk-ant-")
        case .openai: key.hasPrefix("sk-") && !key.hasPrefix("sk-or-") && !key.hasPrefix("sk-ant-")
        default: false
        }
    }

    /// Each service's key is its own Keychain item, named after it ("openrouter" as before).
    func answerKeyFor(_ service: AnswerService) -> String? {
        service.needsKey ? Self.cleanKey(Keychain.read(service.rawValue), for: service) : nil
    }

    var openRouterKey: String? { answerKeyFor(.openrouter) }

    func setKey(_ key: String?, for service: AnswerService) {
        guard service.needsKey else { return }
        let trimmed = Self.cleanKey(key, for: service) ?? ""
        if trimmed.isEmpty { Keychain.delete(service.rawValue) } else { Keychain.write(trimmed, account: service.rawValue) }
        if trimmed.isEmpty { savedKeys.remove(service) } else { savedKeys.insert(service) }
    }

    // MARK: Storage

    private func save(_ combo: HotKey.Combo, _ key: String) {
        defaults.set(try? JSONEncoder().encode(combo), forKey: key)
    }

    private static func load(_ key: String) -> HotKey.Combo? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotKey.Combo.self, from: data)
    }
}

/// Start, stop and error sounds for dictation and notes. "Starlight" is Starlight's own pair, made
/// here: two soft bell tones (a sine with a little second harmonic, quick attack, smooth
/// decay), rising a fifth to start and falling to stop. The rest are macOS's sounds.
enum Sounds {
    static let choices = ["Starlight", "Glass", "Tink", "Pop", "Purr", "Bottle", "Morse", "Ping", "Hero", "Frog",
                          "Submarine", "Blow", "Funk", "Sosumi", "None"]

    // Every sound comes with a tap on the trackpad (Settings → haptics), even with sounds off.
    static func start() { Haptics.start(); play(AppSettings.shared.startSound, rising: true) }
    static func stop() { Haptics.stop(); play(AppSettings.shared.stopSound, rising: false) }
    static func error() { Haptics.stop(); play("Basso", rising: false) }
    /// A task ticked off: one bright, short note.
    static func playTick() {
        Haptics.snap()
        guard AppSettings.shared.sounds else { return }
        tick?.stop()
        tick?.play()
    }
    /// The agent wants your OK to do something on your Mac: two soft notes, up.
    static func playApprovalRequest() {
        Haptics.start()
        guard AppSettings.shared.sounds else { return }
        approval?.stop()
        approval?.play()
    }

    /// Something learned in the welcome tour: three notes up, a small bright chord.
    static func playSuccess() {
        Haptics.snap()
        guard AppSettings.shared.sounds else { return }
        success?.stop()
        success?.play()
    }

    /// Plays a choice even when sounds are off, for trying them in settings.
    static func preview(_ name: String, rising: Bool) { play(name, rising: rising, always: true) }

    private static func play(_ name: String, rising: Bool, always: Bool = false) {
        guard always || AppSettings.shared.sounds, name != "None" else { return }
        if name == "Starlight" {
            let sound = rising ? notchStart : notchStop
            sound?.stop()
            sound?.play()
        } else {
            NSSound(named: name)?.play()
        }
    }

    private static let notchStart = chime([(1046.5, 0), (1568.0, 0.055)])   // C6 then G6
    private static let notchStop = chime([(1568.0, 0), (1046.5, 0.055)])    // G6 then C6
    private static let approval = chime([(1318.5, 0), (1318.5, 0.11)])      // E6 twice
    private static let tick = chime([(1760.0, 0)])                          // A6
    private static let success = chime([(1046.5, 0), (1318.5, 0.07), (1568.0, 0.14)])  // C6, E6, G6

    /// Bell tones at (frequency, start time), as an in-memory WAV.
    private static func chime(_ notes: [(Double, Double)]) -> NSSound? {
        let rate = 44_100.0, length = 0.42
        var samples = [Float](repeating: 0, count: Int(rate * length))
        for (frequency, offset) in notes {
            let start = Int(offset * rate)
            for i in start..<samples.count {
                let t = Double(i - start) / rate
                let attack = min(t / 0.004, 1)
                let decay = exp(-t / 0.085)
                let tone = sin(2 * .pi * frequency * t) + 0.18 * sin(4 * .pi * frequency * t) + 0.05 * sin(6 * .pi * frequency * t)
                samples[i] += Float(0.16 * attack * decay * tone)
            }
        }
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count * 2).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16).littleEndian); append(UInt16(1).littleEndian)
        append(UInt16(1).littleEndian); append(UInt32(rate).littleEndian); append(UInt32(rate * 2).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count * 2).littleEndian)
        pcm.forEach { append($0.littleEndian) }
        return NSSound(data: data)
    }
}

/// Minimal generic-password Keychain storage.
///
/// Signed with a Developer ID, the Keychain trusts every version from the same team, so updates
/// read keys silently. Builds without a team are trusted build by build, so a rebuilt Starlight is
/// asked again the first time it reads a key. So: `exists` never decrypts (and never prompts),
/// keys are read only when needed and off the main thread (AppSettings.loadAnswerKey), and a key
/// read once is remembered for the rest of the run.
///
/// A key saved by a differently signed Starlight (a dev build, before the Developer ID one) is
/// saved again after its first read, so the item belongs to this team from then on.
enum Keychain {
    private static let service = "com.starlightnotch.app"
    /// Where keys were saved before the app ID changed; moved over on first read.
    private static let oldService = "com.amadin.notch"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    static func read(_ account: String) -> String? {
        if let cached = lock.withLock({ cache[account] }) { return cached }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            if status == errSecItemNotFound, let moved = moveFromOldService(account) { return moved }
            // Why, without the key: -128 is a Keychain prompt that was cancelled, -25293 a denied one.
            if status != errSecItemNotFound { DebugLog.write("keychain: reading \(account) failed (\(status))") }
            return nil
        }
        lock.withLock { cache[account] = value }
        let signer = "keychainSigner.\(account)"
        if let team = teamID, UserDefaults.standard.string(forKey: signer) != team {
            write(value, account: account)
            UserDefaults.standard.set(team, forKey: signer)
        }
        return value
    }

    /// A key saved under the old app ID: saved again under the new one, and the old copy removed.
    private static func moveFromOldService(_ account: String) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: oldService,
                                      kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
        write(value, account: account)
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: oldService, kSecAttrAccount: account] as CFDictionary)
        DebugLog.write("keychain: moved \(account) to the new app ID")
        return value
    }

    /// This build's Developer ID team, or nil for a dev build.
    static let teamID: String? = {
        var code: SecCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              let staticCode = { var s: SecStaticCode?; SecCodeCopyStaticCode(code, [], &s); return s }(),
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// Whether an item is there, from its attributes only: no decryption, so no prompt.
    static func exists(_ account: String) -> Bool {
        [service, oldService].contains { service in
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                          kSecAttrAccount: account, kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitOne]
            var result: AnyObject?
            return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        }
    }

    static func write(_ value: String, account: String) {
        delete(account)
        lock.withLock { cache[account] = value }
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                     kSecAttrAccount: account, kSecValueData: Data(value.utf8),
                                     kSecAttrLabel: "Starlight: \(account)", kSecAttrDescription: "Starlight API key"]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        _ = lock.withLock { cache.removeValue(forKey: account) }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// Window sharing type for capture: `.none` asks macOS to leave Starlight's windows out of
/// screenshots, screen recordings and screen sharing. Apps capture through different paths, so
/// check it with the app you share from.
enum CaptureVisibility {
    static func apply() {
        // STARLIGHT_VISIBLE_TO_CAPTURE: a test run that screenshots itself.
        let hidden = AppSettings.shared.hideFromCapture && Dev.env("STARLIGHT_VISIBLE_TO_CAPTURE") == nil
        let type: NSWindow.SharingType = hidden ? .none : .readOnly
        for window in NSApp?.windows ?? [] where window.sharingType != type { window.sharingType = type }
    }
}
