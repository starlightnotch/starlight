import AppKit
import Combine
import Foundation

// Starlight knowing itself: what it can do (a manual it reads when you ask about it), its own
// settings and extensions (which it can change for you), and a config file you can edit by hand.

// MARK: - Settings, by name

/// Every setting that can be changed by name: by the agent ("turn off captions"), or in the
/// config file. Keys, the agent prompt and the microphone aren't here.
enum SettingsRegistry {
    struct Entry {
        let key: String
        let label: String
        /// Allowed values, shown to the model and in the file's notes.
        let help: String
        /// Only you change these (in Settings or the config file), never the agent.
        var protected = false
        let get: () -> Any
        /// Applies a value from JSON or speech; false if it doesn't fit.
        let set: (Any) -> Bool
    }

    private static var s: AppSettings { AppSettings.shared }

    static func bool(_ key: String, _ label: String, _ path: ReferenceWritableKeyPath<AppSettings, Bool>, protected: Bool = false) -> Entry {
        Entry(key: key, label: label, help: "on/off", protected: protected, get: { s[keyPath: path] }, set: { value in
            guard let on = asBool(value) else { return false }
            s[keyPath: path] = on
            return true
        })
    }

    static func choice<E: RawRepresentable & CaseIterable>(_ key: String, _ label: String,
                                                           _ path: ReferenceWritableKeyPath<AppSettings, E>, protected: Bool = false) -> Entry where E.RawValue == String {
        let all = E.allCases.map(\.rawValue)
        return Entry(key: key, label: label, help: all.joined(separator: ", "), protected: protected, get: { s[keyPath: path].rawValue }, set: { value in
            guard let text = (value as? String)?.lowercased().trimmingCharacters(in: .whitespaces), let e = E(rawValue: text) else { return false }
            s[keyPath: path] = e
            return true
        })
    }

    static func number(_ key: String, _ label: String, _ path: ReferenceWritableKeyPath<AppSettings, Double>,
                       _ range: ClosedRange<Double>, unit: String = "") -> Entry {
        Entry(key: key, label: label, help: "\(range.lowerBound.formatted())–\(range.upperBound.formatted())\(unit)",
              get: { s[keyPath: path] }, set: { value in
            guard let n = (value as? Double) ?? (value as? Int).map(Double.init) ?? (value as? String).flatMap({ Double($0.filter { $0.isNumber || $0 == "." }) })
            else { return false }
            s[keyPath: path] = min(max(n, range.lowerBound), range.upperBound)
            return true
        })
    }

    static func sound(_ key: String, _ label: String, _ path: ReferenceWritableKeyPath<AppSettings, String>) -> Entry {
        Entry(key: key, label: label, help: Sounds.choices.joined(separator: ", "), get: { s[keyPath: path] }, set: { value in
            guard let text = value as? String, let match = Sounds.choices.first(where: { $0.lowercased() == text.lowercased() }) else { return false }
            s[keyPath: path] = match
            return true
        })
    }

    static let entries: [Entry] = [
        // General
        bool("open_on_hover", "Open on hover", \.openOnHover),
        bool("menu_bar_icon", "Menu bar icon", \.showMenuBarIcon),
        bool("hide_from_screen_sharing", "Hide from screen sharing", \.hideFromCapture, protected: true),
        bool("now_playing", "Now Playing", \.showNowPlaying),
        bool("bluetooth_devices", "Bluetooth devices", \.showHeadphones),
        bool("tasks", "Tasks", \.tasksEnabled),
        bool("tasks_corner", "Tasks in the corner", \.showTasksCorner),
        bool("overlay_with_sessions", "Open the window with each session", \.openOverlayWithSessions),
        number("animation_speed", "Animation speed", \.animationSpeed, 0.5...2, unit: "×"),
        choice("text_size", "Text size in the notch", \.textSize),
        bool("haptics", "Haptics", \.haptics),
        bool("sounds", "Sounds", \.sounds),
        // Dictation
        sound("start_sound", "Start sound", \.startSound),
        sound("stop_sound", "Stop sound", \.stopSound),
        choice("transcription_style", "Transcription style", \.transcriptionStyle),
        bool("auto_paste", "Paste into text fields", \.autoPaste),
        bool("close_after_dictation", "Close after dictation", \.closeAfterDictation),
        number("show_text_seconds", "Show text for", \.resultSeconds, 3...15, unit: " s"),
        bool("live_text", "Live text while dictating", \.liveText),
        // Notes
        choice("meetings", "Meetings", \.meetingMode),
        bool("captions_notch", "Captions in the notch", \.captionsNotch),
        bool("captions_transcript", "Captions in the transcript", \.captionsTranscript),
        bool("their_audio", "Their audio", \.captureTheirAudio, protected: true),
        number("phrase_pause", "Phrase pause", \.notesPause, 0.5...2, unit: " s"),
        number("voice_sensitivity", "Voice sensitivity", \.voiceSensitivity, 0...1),
        // Agent
        bool("live_answers", "Live answers", \.liveAnswers, protected: true),
        bool("silent_mode", "Silent mode: keep listening and taking notes, but don't answer unless spoken to as \"Starlight\"", \.silentMode),
        number("answer_seconds", "Answers stay for", \.liveAnswerSeconds, 4...30, unit: " s"),
        choice("proactivity", "During meetings: helps on its own (balanced) or only when asked (quiet)", \.proactivity),
        choice("answer_length", "Answer length", \.answerLength),
        choice("deep_mode", "Deep answers", \.deepMode),
        // How much Starlight asks before acting on your Mac: only you change this, never the agent.
        choice("computer_asks", "Computer asks before", \.computerAsks, protected: true),
    ]

    static func entry(_ key: String) -> Entry? {
        let k = key.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        return entries.first { $0.key == k }
    }

    static func asBool(_ value: Any) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? Int { return n != 0 }
        guard let t = (value as? String)?.lowercased().trimmingCharacters(in: .whitespaces) else { return nil }
        if ["on", "true", "yes", "1", "enable", "enabled"].contains(t) { return true }
        if ["off", "false", "no", "0", "disable", "disabled"].contains(t) { return false }
        return nil
    }

    /// "Captions in the notch: on" for the manual.
    static func describe(_ entry: Entry) -> String {
        let value = entry.get()
        let shown: String
        switch value {
        case let b as Bool: shown = b ? "on" : "off"
        case let d as Double: shown = d.formatted(.number.precision(.fractionLength(0...2)))
        default: shown = "\(value)"
        }
        return "\(entry.key) = \(shown) (\(entry.help))"
    }
}

// MARK: - The config file

/// `~/Library/Application Support/Starlight/config.json`: every setting above and every extension's
/// on/off, as plain JSON. Starlight rewrites it whenever something changes in the app, and applies
/// it the moment you save your own edits. API keys stay in the Keychain, never in the file.
final class ConfigFile {
    static let shared = ConfigFile()

    static var url: URL { NotesStore.folder.deletingLastPathComponent().appendingPathComponent("config.json") }

    private var lastWritten: Data?
    /// Which Starlight wrote the file, so a second copy's snapshot is never taken for your edits.
    private static let writer = Int(ProcessInfo.processInfo.processIdentifier)
    private var watcher: DispatchSourceFileSystemObject?
    private var observers: [AnyCancellable] = []
    private var writeWork: DispatchWorkItem?
    private var applying = false

    /// Writes the file and starts watching it (and the settings) for changes.
    func start() {
        write()
        watch()
        observers.append(AppSettings.shared.objectWillChange.sink { [weak self] in self?.scheduleWrite() })
        observers.append(Extensions.shared.objectWillChange.sink { [weak self] in self?.scheduleWrite() })
    }

    private func scheduleWrite() {
        guard !applying else { return }
        writeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write() }
        writeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    var contents: [String: Any] {
        var settings: [String: Any] = [:]
        for entry in SettingsRegistry.entries { settings[entry.key] = entry.get() }
        var extensions: [String: Any] = [:]
        for ext in Extensions.shared.all { extensions[ext.id] = Extensions.shared.isEnabled(ext) }
        var notes: [String: String] = [:]
        for entry in SettingsRegistry.entries { notes[entry.key] = entry.label + ": " + entry.help }
        return [
            "_about": "Starlight's settings. Edit and save: Starlight applies changes right away. API keys stay in the Keychain, not here.",
            "_values": notes,
            "settings": settings,
            "extensions": extensions,
            "_written_by": Self.writer,
        ]
    }

    func write() {
        guard let data = try? JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]),
              data != lastWritten else { return }
        lastWritten = data
        try? data.write(to: Self.url, options: .atomic)
        watch()  // an atomic write replaces the file, so watch the new one
    }

    private func watch() {
        watcher?.cancel()
        let fd = open(Self.url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            // Editors save by replacing the file: read it a moment later, then watch the new one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.readEdits()
                self?.watch()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// Your edits: applied, then the file is rewritten tidily (with anything that didn't fit put back).
    private func readEdits() {
        guard let data = try? Data(contentsOf: Self.url), data != lastWritten else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            DebugLog.write("config: couldn't read config.json (not valid JSON); left as is")
            return
        }
        // Another Starlight that's still running wrote this: its settings, not your edits.
        if let pid = json["_written_by"] as? Int, pid != Self.writer,
           NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier == Bundle.main.bundleIdentifier {
            DebugLog.write("config: config.json was written by another Starlight (\(pid)); not applied")
            return
        }
        let changed = apply(json, byAgent: false)
        DebugLog.write("config: applied \(changed.count) change(s) from config.json: \(changed.joined(separator: ", "))")
        lastWritten = data
        write()
    }

    /// Applies `settings` and `extensions` from a config object. Returns what changed.
    @discardableResult
    func apply(_ json: [String: Any], byAgent: Bool) -> [String] {
        applying = true
        defer { applying = false; scheduleWrite() }
        var changed: [String] = []
        for (key, value) in json["settings"] as? [String: Any] ?? [:] {
            guard let entry = SettingsRegistry.entry(key), !(byAgent && entry.protected) else { continue }
            let before = "\(entry.get())"
            if entry.set(value), "\(entry.get())" != before { changed.append(entry.key) }
        }
        for (id, value) in json["extensions"] as? [String: Any] ?? [:] {
            guard let on = SettingsRegistry.asBool(value), let ext = Extensions.shared.all.first(where: { $0.id == id }),
                  Extensions.shared.isEnabled(ext) != on else { continue }
            Extensions.shared.setEnabled(ext, on)
            changed.append(id)
        }
        return changed
    }
}

// MARK: - The manual

enum StarlightManual {
    /// For questions about Starlight: what it does, how to use it, and how it's set up right now.
    static var text: String {
        let s = AppSettings.shared
        let exts = Extensions.shared.all.map { ext in
            "- \(ext.id) (\(ext.name)): \(Extensions.shared.isEnabled(ext) ? "on" : "off")\(ext.optIn ? ", opt-in" : "") — \(ext.summary)"
        }.joined(separator: "\n")
        let settings = SettingsRegistry.entries.map { "- " + SettingsRegistry.describe($0) + ($0.protected ? " [only the user changes this]" : "") }
            .joined(separator: "\n")
        return """
        About Starlight (you). Use this to answer questions about Starlight, how to use it, and how it's set up.
        Starlight lives in the MacBook notch. What it does:
        - Dictation: \(s.dictationShortcut.display) \(s.dictationKeyMode == .hold ? "held while you talk" : "starts and stops"). Words appear as you speak; \
        the text is copied to the clipboard, and with "Paste into text fields" on it's typed straight into the text box your cursor is in. Styles: verbatim, clean, polished (AI tidies it after). Afterwards \
        it closes by itself or shows the text. History is in the Starlight window: Dictation, then History.
        - Meeting notes: \(s.notesShortcut.display) starts and stops, or Starlight offers when a meeting app uses the mic. It hears your mic and \
        the other side (the Mac's audio), tells speakers apart and lets you name them, shows live captions, and answers live (that's \
        you). Click the time beside the camera to pause. \(s.transcriptShortcut.display) opens the live transcript panel (movable, resizable): \
        double-click a line to answer it, right-click for a fast or in-depth answer. When it ends: stats, the full conversation with \
        your answers in place, a timeline of sections, and copy.
        - Tasks: a folded tab in the bottom-right corner of the screen opens into the user's tasks and pinned answers. \
        During notes and Live mode Starlight writes tasks into it as they come up; "pin that" keeps an answer there (pin tool).
        - The notch: click to open (time, date, three shortcuts, Settings). Shows what Spotify or Music is playing (hover for controls) \
        and Bluetooth device batteries when they connect. Hidden from screen sharing.
        - You (the agent): the whole conversation is your context. You can search the web, remember facts for later meetings, \
        search past meetings, do exact math, show a picture of places and people, and with extensions add to-dos, use the Mac \
        (open files, apps and links; find, list, read and save files; move, rename or trash them; the clipboard; commands; \
        asks before changing anything that's already there), and read the screen.
        - Change your own settings with change_setting and turn extensions on or off with set_extension. Settings are also in a \
        config file the user can edit: \(ConfigFile.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) (changes apply as soon as it's saved).
        - Your own prompt: edit_prompt adds a rule, replaces it, resets it or undoes the last change; the user approves each one.
        - The Starlight window (the gear in the open notch, or the menu bar icon), where to send them for anything you can't \
        change: Dictation (History and Settings tabs: shortcut, style, where the text goes, microphone, languages), Meetings \
        (Notes and Settings: when a call starts, answering during meetings, captions, their voice, silent mode), Tasks, Memory; \
        then General (text size, opening on hover or click, what the notch shows, sounds, haptics, startup), Answers (where \
        answers come from, answer length, how often you speak up in meetings, the tools you can use and their setup), \
        Shortcuts, Privacy (permissions, hiding from screen sharing, their data), Account (plan, sign in, usage), About \
        (version, updates). Search at the top of the window finds any setting by name. Rarely used ones are under \
        "More settings" at the bottom of a page.
        - Only the user can change: API keys and models (Settings → Answers), hiding from screen sharing (Settings → Privacy).

        Extensions now:
        \(exts)

        Settings now (key = value (allowed)):
        \(settings)
        """
    }

    static func wanted(_ text: String) -> Bool {
        Agent.isAboutStarlight(text) || text.lowercased().range(
            of: #"\b(setting|settings|extension|extensions|feature|features|shortcut|shortcuts|config|configure|turn (on|off)|switch (on|off)|enable|disable|how do i|how can i|how to|what can you|can you do|notch|dictat|captions?|transcript|pause)"#,
            options: .regularExpression) != nil
    }
}

/// The prompt as it was before the agent last changed it, for "undo that".
enum PromptHistory { static let key = "agentPromptBeforeLastEdit" }

// MARK: - The extension

/// Built in: the manual when you ask about Starlight, and tools to change its settings and
/// extensions. Turning on an opt-in extension (one that reads your screen or uses your Mac)
/// asks you first.
struct StarlightSelfExtension: StarlightExtension {
    let id = "notch"
    let name = "Starlight"
    let summary = "Knows its own features; changes its settings and extensions for you."
    let glyph = Glyph.Kind.sliders

    func register(_ api: ExtensionAPI) {
        final class Box: @unchecked Sendable { var fromUser = false }
        let box = Box()
        api.onBeforeAsk { request in
            box.fromUser = request.fromUser
            let said = request.focus ?? request.unanswered
            return StarlightManual.wanted(said)
                ? StarlightManual.text
                : "You are Starlight; for questions about your own features or settings, you have a manual (ask about Starlight to see it)."
        }
        let refuse = ToolResult(content: "error: only the user can ask for this. Don't retry.", outcome: .failed("Only you can change that"))
        var meeting: [NoteItem] = []
        var meetingStart = Date()
        var history: [AgentTurn] = []
        api.onBeforeAsk { request in
            meeting = request.meeting
            meetingStart = request.meetingStart
            history = request.history
            return nil
        }

        api.registerTool(AgentTool(
            name: "edit_prompt",
            description: "Change your own agent prompt (how you answer) when the user asks: add an instruction (\"from now on, answer in Spanish\", \"always give sources\"), replace the whole prompt, reset it to the default, or undo the last change. The user sees the change and must approve it. Write added instructions as one short rule.",
            parameters: ["type": "object",
                         "properties": ["action": ["type": "string", "enum": ["add", "replace", "reset", "undo"]],
                                        "text": ["type": "string", "description": "For add: the new rule. For replace: the whole new prompt."]],
                         "required": ["action"]],
            status: "Waiting for you", glyph: .agent,
            keywords: ["prompt", "instructions", "from now on", "always", "never", "behave", "personality", "tone", "style", "rule"],
            run: { args in
                guard box.fromUser else { return refuse }
                let action = args["action"] as? String ?? "add"
                let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let current = await MainActor.run { Agent.basePrompt }
                let previous = UserDefaults.standard.string(forKey: PromptHistory.key)
                let next: String
                let summary: String
                switch action {
                case "add":
                    guard !text.isEmpty else { return ToolResult(content: "error: no rule to add") }
                    next = current + "\n- " + text
                    summary = text
                case "replace":
                    guard text.count >= 20 else { return ToolResult(content: "error: the new prompt is empty or too short") }
                    next = text
                    summary = String(text.prefix(160)) + (text.count > 160 ? "…" : "")
                case "reset":
                    next = Agent.defaultInstructions
                    summary = "Back to the default prompt"
                case "undo":
                    guard let previous else { return ToolResult(content: "Nothing to undo.", outcome: .failed("No earlier prompt to go back to")) }
                    next = previous.isEmpty ? Agent.defaultInstructions : previous
                    summary = "Back to the prompt before the last change"
                default:
                    return ToolResult(content: "error: unknown action")
                }
                if Dev.env("STARLIGHT_DRY_RUN") != nil {
                    return ToolResult(content: "Changed (test run).", outcome: .item("Prompt updated (test)", summary, icon: nil))
                }
                let title = ["add": "Add to how Starlight answers", "replace": "Replace Starlight's prompt",
                             "reset": "Reset Starlight's prompt", "undo": "Undo the last prompt change"][action] ?? "Change Starlight's prompt"
                guard await Approvals.shared.ask(Approval(title: title, detail: summary, action: "Change", glyph: .agent)) else {
                    return ToolResult(content: "The user said no.", outcome: .failed("Prompt left as it was"))
                }
                await MainActor.run {
                    UserDefaults.standard.set(AppSettings.shared.agentPrompt, forKey: PromptHistory.key)
                    AppSettings.shared.agentPrompt = Agent.cleaned(next)
                }
                DebugLog.write("agent: prompt \(action) by voice: \(summary)")
                return ToolResult(content: "Done. The new prompt applies from your next reply.",
                                  outcome: .item(action == "add" ? "Added to my prompt" : action == "undo" ? "Prompt change undone" : action == "reset" ? "Prompt reset" : "Prompt replaced",
                                                 action == "add" ? text : summary, icon: nil))
            }))

        api.registerTool(AgentTool(
            name: "list_tasks",
            description: "Read back the user's tasks (the list in the corner of the screen): what's left to do, with when each is due. Use for \"what do I have to do?\", \"read me my tasks\", \"what's due today?\". The list also opens on screen.",
            parameters: ["type": "object", "properties": [:], "required": []],
            status: "Reading your tasks", glyph: .todo,
            keywords: ["tasks", "task", "to-do", "todo", "list", "due", "what do i have", "need to do", "read me"],
            run: { _ in
                guard await MainActor.run(body: { AppSettings.shared.tasksEnabled }) else {
                    return ToolResult(content: "Tasks are turned off (Settings → Tasks). Say so, and offer to turn them on.", display: "Tasks are off")
                }
                let open = await MainActor.run { () -> [TaskStore.Item] in
                    let items = TaskStore.shared.open
                    if !items.isEmpty { TaskCorner.shared.reveal() }
                    return items
                }
                guard !open.isEmpty else { return ToolResult(content: "The list is empty: no tasks.", display: "No tasks") }
                let lines = open.enumerated().map { i, task in
                    "\(i + 1). \(task.text)" + (task.due.map { " (due \(TaskStore.dueLabel($0)))" } ?? "")
                }
                return ToolResult(content: "\(open.count) open, soonest due first:\n" + lines.joined(separator: "\n")
                                  + "\nRead them back briefly, in this order.", display: open.count == 1 ? "1 task" : "\(open.count) tasks")
            }))

        api.registerTool(AgentTool(
            name: "pin",
            description: "Put something on Starlight's own list in the bottom-right corner of the screen: a task (\"add that to my tasks\", \"I need to email Dana\") or an answer to keep (\"pin that\", \"save that answer\"). For Apple Reminders use add_todo instead, if they say Reminders.",
            parameters: ["type": "object",
                         "properties": ["text": ["type": "string", "description": "A short task starting with a verb, or the answer to keep"],
                                        "more": ["type": "array", "items": ["type": "string"],
                                                 "description": "More tasks, when they asked for several at once"],
                                        "kind": ["type": "string", "enum": ["task", "answer"]]],
                         "required": ["text"]],
            status: "Pinning", glyph: .todo,
            keywords: ["pin", "task", "tasks", "list", "keep", "save that", "note that", "to-do", "todo"],
            run: { args in
                guard box.fromUser else { return refuse }
                guard await MainActor.run(body: { AppSettings.shared.tasksEnabled }) else {
                    return ToolResult(content: "Tasks are turned off (Settings → Tasks), so nothing was added. Say so, and offer to turn them on.",
                                      outcome: .failed("Tasks are off"))
                }
                let all = ([args["text"] as? String ?? ""] + (args["more"] as? [String] ?? []))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                guard !all.isEmpty else { return ToolResult(content: "error: nothing to pin") }
                let kind: TaskStore.Item.Kind = (args["kind"] as? String) == "answer" ? .answer : .task
                let added = await MainActor.run { all.filter { TaskStore.shared.add($0, kind: kind) } }
                if !added.isEmpty { await MainActor.run { TaskCorner.shared.flash() } }
                let already = all.filter { !added.contains($0) }
                // Exactly what happened, so the reply can't claim more.
                let report = (added.isEmpty ? "" : "Added: \(added.joined(separator: "; ")). ") + (already.isEmpty ? "" : "Already on the list: \(already.joined(separator: "; ")).")
                let verb = added.isEmpty ? "Already on your list" : kind == .task ? (added.count == 1 ? "Added to tasks" : "Added \(added.count) tasks") : "Pinned"
                return ToolResult(content: report, outcome: .item(verb, (added.isEmpty ? all : added).joined(separator: " · "), icon: nil))
            }))

        api.registerTool(AgentTool(
            name: "open_transcript",
            description: "Show this meeting's transcript so far: Starlight writes it to a text file and opens it (in TextEdit unless they name another app), or copies it to the clipboard. Use this whenever they want to see, read, open, save or copy the transcript; never retype the transcript yourself.",
            parameters: ["type": "object",
                         "properties": ["app": ["type": "string", "description": "An app to open it in, e.g. TextEdit (default)"],
                                        "copy": ["type": "boolean", "description": "Copy to the clipboard instead of opening"]],
                         "required": []],
            status: "Opening the transcript", glyph: .file,
            keywords: ["transcript", "textedit", "text", "file", "open", "copy", "notes", "conversation", "read"],
            run: { args in
                guard box.fromUser else { return refuse }
                guard !meeting.isEmpty else {
                    return ToolResult(content: "There's no transcript yet: nothing has been said in a notes session.", outcome: .failed("No transcript yet"))
                }
                let session = NoteSession(id: NoteSession.makeID(meetingStart), started: meetingStart,
                                          duration: Date().timeIntervalSince(meetingStart), items: meeting,
                                          answers: history.compactMap { turn in turn.assistant.map { NoteSession.Answer(question: turn.user, answer: $0) } })
                let text = session.transcriptText
                if SettingsRegistry.asBool(args["copy"] ?? false) == true {
                    await MainActor.run {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    return ToolResult(content: "Copied the transcript.", outcome: .done("Transcript copied"))
                }
                if Dev.env("STARLIGHT_DRY_RUN") != nil {
                    return ToolResult(content: "Opened (test run).", outcome: .done("Opened the transcript (test)"))
                }
                let folder = NotesStore.folder.deletingLastPathComponent().appendingPathComponent("Transcripts", isDirectory: true)
                let file = folder.appendingPathComponent("Transcript \(session.id).txt")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try text.write(to: file, atomically: true, encoding: .utf8)
                } catch {
                    return ToolResult(content: "error: \(error.localizedDescription)", outcome: .failed("Couldn't write the transcript"))
                }
                let appName = (args["app"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "TextEdit"
                let opened = await MainActor.run { () -> Bool in
                    let config = NSWorkspace.OpenConfiguration()
                    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appName == "TextEdit" ? "com.apple.TextEdit" : "")
                        ?? NSWorkspace.shared.urlsForApplications(toOpen: file).first(where: { $0.lastPathComponent.lowercased().hasPrefix(appName.lowercased()) }) {
                        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: config)
                        return true
                    }
                    return NSWorkspace.shared.open(file)
                }
                return opened
                    ? ToolResult(content: "Opened the transcript in \(appName).", outcome: .done("Opened in \(appName)"))
                    : ToolResult(content: "error: couldn't open it", outcome: .failed("Couldn't open \(appName)"))
            }))

        api.registerTool(AgentTool(
            name: "change_setting",
            description: "Change one of Starlight's own settings when the user asks (\"turn off captions\", \"be quieter\", \"shorter answers\", \"use the Glass sound\"). Setting names and values are in Starlight's manual; on/off settings take on or off.",
            parameters: ["type": "object",
                         "properties": ["name": ["type": "string", "enum": SettingsRegistry.entries.filter { !$0.protected }.map(\.key)],
                                        "value": ["type": "string", "description": "on/off, a listed choice, or a number"]],
                         "required": ["name", "value"]],
            status: "Changing settings", glyph: .sliders,
            keywords: ["setting", "settings", "turn", "switch", "captions", "quieter", "shorter", "longer", "sound", "sounds", "proactive",
                       "hover", "haptics", "faster", "slower", "sensitivity"],
            run: { args in
                guard box.fromUser else { return refuse }
                let name = args["name"] as? String ?? "", value = args["value"] ?? ""
                guard let entry = SettingsRegistry.entry(name) else {
                    return ToolResult(content: "error: no setting named \(name)", outcome: .failed("No setting called \(name)"))
                }
                guard !entry.protected else {
                    return ToolResult(content: "error: only the user can change this, in Settings.", outcome: .failed("\(entry.label) is yours to change"))
                }
                if Dev.env("STARLIGHT_DRY_RUN") != nil {
                    return ToolResult(content: "Changed (test run).", outcome: .done("\(entry.label): \(value) (test)"))
                }
                return await MainActor.run {
                    guard entry.set(value) else {
                        return ToolResult(content: "error: \(value) doesn't fit (\(entry.help))", outcome: .failed("\(entry.label) can't be \(value)"))
                    }
                    let shown = SettingsRegistry.describe(entry).components(separatedBy: " = ").last?.components(separatedBy: " (").first ?? "\(value)"
                    return ToolResult(content: "Done: \(entry.key) = \(shown)", outcome: .done("\(entry.label): \(shown)"))
                }
            }))

        api.registerTool(AgentTool(
            name: "set_extension",
            description: "Turn one of Starlight's extensions on or off when the user asks (\"turn on Reminders\", \"stop searching X\"). Turning on an opt-in extension asks the user to confirm.",
            parameters: ["type": "object",
                         "properties": ["id": ["type": "string", "enum": Extensions.shared.all.map(\.id)],
                                        "on": ["type": "boolean"]],
                         "required": ["id", "on"]],
            status: "Changing extensions", glyph: .puzzle,
            keywords: ["extension", "extensions", "turn", "enable", "disable", "plugin", "reminders", "computer", "files", "terminal", "screen"],
            run: { args in
                guard box.fromUser else { return refuse }
                let id = args["id"] as? String ?? ""
                let on = SettingsRegistry.asBool(args["on"] ?? true) ?? true
                guard let ext = Extensions.shared.all.first(where: { $0.id == id }) else {
                    return ToolResult(content: "error: no extension \(id)", outcome: .failed("No extension called \(id)"))
                }
                if ext.id == "notch", !on {
                    return ToolResult(content: "error: this one can only be turned off in Settings.", outcome: .failed("Turn that off in Settings"))
                }
                if Dev.env("STARLIGHT_DRY_RUN") != nil {
                    return ToolResult(content: "Done (test run).", outcome: .done("\(ext.name): \(on ? "on" : "off") (test)"))
                }
                // Opt-in extensions read your screen or act on your Mac: your click turns them on.
                if on, ext.optIn, !Extensions.shared.isEnabled(ext) {
                    let approved = await Approvals.shared.ask(Approval(title: "Turn on \(ext.name)", detail: ext.summary, action: "Turn on",
                                                                       glyph: ext.glyph))
                    guard approved else { return ToolResult(content: "The user said no.", outcome: .failed("Left \(ext.name) off")) }
                }
                await MainActor.run { Extensions.shared.setEnabled(ext, on) }
                return ToolResult(content: "\(ext.name) is \(on ? "on" : "off").", outcome: .done("\(ext.name): \(on ? "on" : "off")"))
            }))
    }
}
