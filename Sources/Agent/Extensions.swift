import Foundation

// Starlight's extension system, modelled on pi's (pi-mono's coding agent): an extension is handed an
// API and registers what it adds.
//
//   pi                                     Starlight
//   pi.registerTool(name, {description,    api.registerTool(AgentTool(name:, description:,
//     parameters, execute})                  parameters:, run:))
//   execute → { content, details }         run → ToolResult(content:, display:)
//   before_agent_start (edit the prompt)   api.onBeforeAsk { request in "extra context" }
//   extensions folder, loaded at start     ~/Library/Application Support/Starlight/Extensions/<id>/
//
// Built-in extensions are Swift; your own are folders with an extension.json and a command
// (any language), see ScriptExtension.

struct ToolResult {
    /// What the model reads.
    var content: String
    /// One short line for the notch, like pi's `details`. nil shows nothing.
    var display: String? = nil
    /// For actions (saved, added, ran): shown with a green check or a red cross.
    var outcome: Outcome? = nil
    /// A moment in a saved meeting the answer comes from ("Open at 12:31").
    var link: MeetingMoment? = nil
}

/// What an action did, for the user to see at a glance.
struct Outcome: Equatable {
    let ok: Bool
    /// "Added Buy milk to Reminders", "Cancelled".
    let text: String
    /// The action is the whole answer: the turn ends here, with no reply written after it
    /// (faster, and nothing like "Done, I've saved that" to read).
    var ends = true

    /// Shown big, with `verb` small above it and the app's or file's own icon beside it:
    /// "Opened" / "Reminders". Nil shows `text` beside a check.
    var subject: String? = nil
    var verb: String? = nil
    /// A file or app whose Finder icon is shown.
    var icon: String? = nil

    static func done(_ text: String, ends: Bool = true) -> Outcome { Outcome(ok: true, text: text, ends: ends) }
    static func failed(_ text: String, ends: Bool = true) -> Outcome { Outcome(ok: false, text: text, ends: ends) }
    /// "Opened" + "Reminders" + Reminders.app's icon.
    static func item(_ verb: String, _ subject: String, icon: String?, ends: Bool = true) -> Outcome {
        Outcome(ok: true, text: "\(verb) \(subject)", ends: ends, subject: subject, verb: verb, icon: icon)
    }
}

struct AgentTool {
    let name: String
    let description: String
    /// JSON schema for the arguments, as the model sees it.
    let parameters: [String: Any]
    /// Shown in the notch while it runs ("Calculating").
    var status: String = "Working"
    var glyph: Glyph.Kind = .puzzle
    /// Words that mean a question is about this tool, for deciding whether it should win over a
    /// quick answer. Empty uses the name and description.
    var keywords: [String] = []
    let run: ([String: Any]) async throws -> ToolResult
    /// For tools whose result *is* the answer (web search): streams it through the callback.
    /// When it's the only tool the model calls, its text goes straight to the notch and the
    /// model isn't asked to rewrite it.
    /// The second callback updates the status line ("Reading apnews.com").
    var answers: (([String: Any], @escaping (String) -> Void, @escaping (String) -> Void) async throws -> ToolResult)? = nil

    var schema: [String: Any] {
        ["type": "function", "function": ["name": name, "description": description, "parameters": parameters]]
    }
}

/// One exchange in the live conversation: what the user said, and the agent's reply (nil
/// when it stayed quiet).
struct AgentTurn {
    let user: String
    let assistant: String?
    /// The reply came from a web or X search, so follow-ups are about something current.
    var searched = false
}

/// What the agent gets: the latest thing the user said, the conversation before it, and the
/// meeting it's happening in.
struct AgentRequest {
    /// The latest turn: everything said since the agent last replied or chose not to.
    let question: String
    /// This meeting so far, oldest first.
    let meeting: [NoteItem]
    let meetingStart: Date
    /// Earlier turns of this conversation, oldest first.
    var history: [AgentTurn] = []
    /// When set, the one line to act on (a double-clicked line): routing and searches use it
    /// instead of the conversation's unanswered text.
    var focus: String? = nil
    /// The double-clicked line is the user's own (they can ask for actions; the other side can't).
    var focusIsMine = false
    /// Force deep mode on or off; nil decides from the question (Agent.isComplex).
    var deep: Bool? = nil
    /// Live mode: the user is talking to Starlight, not in a meeting.
    var live = false
    /// Hold to ask: one question asked on purpose, so there's always an answer (never SKIP).
    var direct = false

    /// The user (not the other side of a call) asked for this turn: the double-clicked line is
    /// theirs, or the current turn has a line of theirs, or it has no speaker labels at all (typed,
    /// tests). Only the current turn counts: earlier quiet turns don't vouch for this one.
    var fromUser: Bool {
        if focus != nil { return focusIsMine }
        let labels = question.matches(of: #/(?m)^(Me|Them)(?: \([^)]*\))?:/#).map { String($0.output.1) }
        return labels.isEmpty || labels.contains("Me")
    }

    /// What routing decisions look at (deep or quick, search, tools): the double-clicked line, or
    /// this turn plus the quiet turns just before it while they're short ("What is the price of"
    /// + "shoes at Walmart"), without speaker labels. A long backlog of turns the agent stayed
    /// quiet on doesn't make every new turn look long or complex.
    var routing: String {
        if let focus { return focus }
        func strip(_ text: String) -> String {
            text.replacingOccurrences(of: #"(?m)^(Me|Them)( \([^)]*\))?:\s*"#, with: "", options: .regularExpression)
        }
        var parts = [strip(question)]
        var words = parts[0].split(separator: " ").count
        for turn in history.reversed() {
            guard turn.assistant == nil else { break }
            let text = strip(turn.user)
            let count = text.split(separator: " ").count
            guard words + count <= 40 else { break }
            parts.insert(text, at: 0)
            words += count
        }
        return parts.joined(separator: " ")
    }

    /// Everything said since the agent last replied: turns it stayed quiet on, then this one.
    /// "What is the price of" (skipped) + "shoes at Walmart" is one request.
    var unanswered: String {
        let quiet = history.reversed().prefix { $0.assistant == nil }.reversed().map(\.user)
        return (quiet + [question]).joined(separator: " ")
    }
}

/// Handed to each extension's `register`.
final class ExtensionAPI {
    private(set) var tools: [AgentTool] = []
    private(set) var contextHooks: [(AgentRequest) -> String?] = []
    /// Which extension each tool came from, for loading tools by group (ToolDisclosure).
    private(set) var groups: [String: (name: String, summary: String)] = [:]
    private var toolGroups: [String: String] = [:]
    /// The extension registering right now.
    var registering: (id: String, name: String, summary: String)? {
        didSet { if let r = registering { groups[r.id] = (r.name, r.summary) } }
    }

    /// Tools that only run when the user asked (not the other side of a call): anything that
    /// saves, sends, reads your screen, or runs a script.
    private(set) var userOnly: Set<String> = ["remember", "add_todo", "read_screen"]
    func markUserOnly(_ name: String) { userOnly.insert(name) }

    func registerTool(_ tool: AgentTool) {
        guard !Edition.hiddenTools.contains(tool.name) else { return }
        tools.append(tool)
        if let id = registering?.id { toolGroups[tool.name] = id }
    }

    func group(of tool: String) -> String? { toolGroups[tool] }
    func tools(in group: String) -> [AgentTool] { tools.filter { toolGroups[$0.name] == group } }
    /// Runs before every question; return text to add to the model's instructions (or nil).
    func onBeforeAsk(_ hook: @escaping (AgentRequest) -> String?) { contextHooks.append(hook) }
}

protocol StarlightExtension {
    var id: String { get }
    var name: String { get }
    var summary: String { get }
    var glyph: Glyph.Kind { get }
    var isBuiltIn: Bool { get }
    /// Off until you switch it on (reads your screen, writes to other apps).
    var optIn: Bool { get }
    func register(_ api: ExtensionAPI)
}

extension StarlightExtension {
    var isBuiltIn: Bool { true }
    var optIn: Bool { false }
}

/// Every installed extension and which are switched on.
final class Extensions: ObservableObject {
    static let shared = Extensions()
    @Published private(set) var all: [any StarlightExtension] = []
    @Published private(set) var problems: [String] = []
    @Published var disabled: Set<String> {
        didSet { UserDefaults.standard.set(Array(disabled), forKey: "disabledExtensions") }
    }
    /// Opt-in extensions you've switched on.
    @Published var optedIn: Set<String> {
        didSet { UserDefaults.standard.set(Array(optedIn), forKey: "optedInExtensions") }
    }

    static var folder: URL {
        let dir = NotesStore.folder.deletingLastPathComponent().appendingPathComponent("Extensions", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            ScriptExtension.writeExample(in: dir)
        }
        return dir
    }

    private init() {
        disabled = Set(UserDefaults.standard.stringArray(forKey: "disabledExtensions") ?? [])
        optedIn = Set(UserDefaults.standard.stringArray(forKey: "optedInExtensions") ?? [])
        // Tests: STARLIGHT_OPT_IN=screen,computer switches opt-in extensions on for this run only.
        if let extra = Dev.env("STARLIGHT_OPT_IN") {
            optedIn.formUnion(extra.split(separator: ",").map(String.init))
        }
        reload()
    }

    /// Built-ins plus every folder in the extensions folder (folders starting with "_" are skipped).
    func reload() {
        var loaded: [any StarlightExtension] = [StarlightSelfExtension(), CalculatorExtension(), MemoryExtension(), WebSearchExtension(),
                                            ScreenExtension(), RemindersExtension(), ComputerExtension(), ClockExtension(), MacControlsExtension()]
        var problems: [String] = []
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !folder.lastPathComponent.hasPrefix("_") {
            do { loaded.append(try ScriptExtension(folder: folder)) } catch { problems.append("\(folder.lastPathComponent): \(error.localizedDescription)") }
        }
        all = loaded
        self.problems = problems
    }

    func isEnabled(_ ext: any StarlightExtension) -> Bool { ext.optIn ? optedIn.contains(ext.id) : !disabled.contains(ext.id) }

    func isEnabled(id: String) -> Bool { all.first { $0.id == id }.map(isEnabled) ?? false }

    func setEnabled(_ ext: any StarlightExtension, _ on: Bool) {
        if ext.optIn {
            if on { optedIn.insert(ext.id) } else { optedIn.remove(ext.id) }
        } else {
            if on { disabled.remove(ext.id) } else { disabled.insert(ext.id) }
        }
    }

    /// A fresh API with every enabled extension registered, for one question.
    func makeAPI() -> ExtensionAPI {
        let api = ExtensionAPI()
        for ext in all where isEnabled(ext) && !Edition.hiddenExtensions.contains(ext.id) {
            api.registering = (ext.id, ext.name, ext.summary)
            ext.register(api)
        }
        api.registering = nil
        return api
    }
}

// MARK: - Built-in extensions

struct CalculatorExtension: StarlightExtension {
    let id = "calculator"
    let name = "Calculator"
    let summary = "Exact math, on this Mac."
    let glyph = Glyph.Kind.calc

    func register(_ api: ExtensionAPI) {
        api.registerTool(AgentTool(
            name: "calculate",
            description: "Evaluate a math expression exactly. Call it only when the user's question asks you to compute something (a sum, a percentage, a conversion, an equation); never for looking up facts, records or times. Supports + - * / ^, n% (percent), n!, % (mod), sqrt cbrt abs exp ln log log2 sin cos tan asin acos atan floor ceil round min max pow hypot, pi e, and equations in one unknown like 2x + 3 = 7.",
            parameters: ["type": "object",
                         "properties": ["expression": ["type": "string", "description": "e.g. (15*23+7)/2, 20% * 85, sqrt(2)^3, x^2 - 5x + 6 = 0"]],
                         "required": ["expression"]],
            status: "Calculating", glyph: .calc,
            run: { args in
                let expression = args["expression"] as? String ?? ""
                do {
                    let result = try Calculator.evaluate(expression)
                    return ToolResult(content: result.text, display: result.display)
                } catch {
                    return ToolResult(content: "error: \(error.localizedDescription)")
                }
            }))
    }
}

struct ClockExtension: StarlightExtension {
    let id = "clock"
    let name = "Clock"
    let summary = "Today's date and the meeting's length."
    let glyph = Glyph.Kind.history

    func register(_ api: ExtensionAPI) {
        api.onBeforeAsk { request in
            let now = Date()
            let elapsed = NotesController.timestamp(now.timeIntervalSince(request.meetingStart))
            return "Now: \(now.formatted(date: .complete, time: .shortened)) (\(TimeZone.current.identifier)). This meeting started \(elapsed) ago."
        }
    }
}
