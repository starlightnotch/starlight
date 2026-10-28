import Foundation

/// Progressive disclosure for tools, as in Anthropic's Agent Skills: the model always sees a
/// short index of what it can do, and a group's full tool definitions only when they're
/// relevant. Every request used to carry all 20-odd tool schemas (most of an answer's tokens);
/// now it carries the few that nearly every answer uses, plus the groups the conversation is
/// about, plus `load_tools` for the rest.
///
///   Level 1, always: core tools (search, memory, math) and a one-line index of the other
///   groups ("mac: open, find, read and save files…").
///   Level 2, on demand: a group's tools, when the question mentions what they do ("open",
///   "my settings", "add a task"), or when the model asks with load_tools.
struct ToolDisclosure {
    /// Extensions whose tools are always loaded: cheap and used all the time.
    static let core: Set<String> = ["calculator", "memory", "web-search", "clock"]

    private let api: ExtensionAPI
    private(set) var loaded: Set<String>

    init(api: ExtensionAPI, request: AgentRequest) {
        self.api = api
        // What this turn and the one before are about: follow-ups ("open it") reuse the groups.
        let previous = request.history.last { $0.assistant != nil }?.user ?? ""
        let text = (request.focus ?? request.unanswered) + " " + previous
        loaded = Self.core.union(Self.relevant(api, to: text))
    }

    /// The groups the deferred tools fall into, with the words that load them.
    var deferred: [String] { api.groups.keys.filter { !loaded.contains($0) && !api.tools(in: $0).isEmpty }.sorted() }

    /// What to send this step: the loaded groups' tools, and load_tools while anything's left.
    var active: [AgentTool] {
        let tools = api.tools.filter { loaded.contains(api.group(of: $0.name) ?? "") }
        return deferred.isEmpty ? tools : tools + [loader]
    }

    /// "mac: Open, find, read and save files… (open_item, find_files, …)"
    var index: String {
        deferred.map { id in
            let names = api.tools(in: id).map(\.name).joined(separator: ", ")
            return "- \(id): \(api.groups[id]?.summary ?? "") (\(names))"
        }.joined(separator: "\n")
    }

    /// The level-1 tool: asks for more tools by group.
    var loader: AgentTool {
        AgentTool(
            name: "load_tools",
            description: "Load more of your tools by group, then call them in your next step. Groups not loaded yet:\n" + index,
            parameters: ["type": "object",
                         "properties": ["groups": ["type": "array", "items": ["type": "string", "enum": deferred]]],
                         "required": ["groups"]],
            status: "Getting ready", glyph: .puzzle,
            run: { _ in ToolResult(content: "") })
    }

    /// Handles a load_tools call: the groups join the next step's tools.
    mutating func load(_ arguments: String) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        let asked = (args["groups"] as? [String] ?? []).filter { api.groups[$0] != nil }
        loaded.formUnion(asked)
        let names = asked.flatMap { api.tools(in: $0).map(\.name) }
        DebugLog.write("agent: loaded tools \(asked.joined(separator: ", "))")
        return names.isEmpty ? "No such group. Groups: \(deferred.joined(separator: ", "))"
            : "Loaded: \(names.joined(separator: ", ")). Call them now."
    }

    /// Groups the text is plausibly about: a word that starts like one of the group's tool
    /// keywords or its name.
    static func relevant(_ api: ExtensionAPI, to text: String) -> Set<String> {
        let words = MemorySearch.words(text) + text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
        var groups: Set<String> = []
        for (id, info) in api.groups {
            var keys = Set(api.tools(in: id).flatMap(\.keywords).map { $0.lowercased() })
            keys.formUnion(MemorySearch.words(info.name))
            for key in keys {
                let multi = key.contains(" ")
                if multi ? text.lowercased().contains(key) : words.contains(where: { w in w.count >= 3 && key.count >= 3 && w.prefix(4) == key.prefix(4) }) {
                    groups.insert(id)
                    break
                }
            }
        }
        return groups
    }
}
