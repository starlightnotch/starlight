import Foundation

/// Facts you've asked Starlight to keep ("remember that the launch is March 12"). Stored in
/// ~/Library/Application Support/Starlight/memory.json and editable in the Starlight window.
final class MemoryStore: ObservableObject {
    struct Fact: Identifiable, Codable, Equatable {
        var id = UUID()
        var text: String
        var date = Date()
    }

    static let shared = MemoryStore()
    @Published private(set) var facts: [Fact] = []

    private static var url: URL { NotesStore.folder.deletingLastPathComponent().appendingPathComponent("memory.json") }

    private init() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        if let saved = try? JSONDecoder().decode([Fact].self, from: data) {
            facts = saved
        } else {
            // Unreadable (damaged, or from a newer version): kept aside, never written over.
            let aside = Self.url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: Self.url, to: aside)
        }
    }

    func add(_ text: String) {
        // `--agent-test` runs shouldn't leave facts behind.
        if Dev.env("STARLIGHT_DRY_RUN") != nil { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !contains(trimmed) else { return }
        facts.insert(Fact(text: trimmed), at: 0)
        save()
    }

    /// Already saved, in the same words or near enough.
    func contains(_ text: String) -> Bool { facts.contains { TaskStore.similar($0.text, text) } }

    func delete(_ id: UUID) {
        facts.removeAll { $0.id == id }
        save()
    }

    private func save() { try? JSONEncoder().encode(facts).write(to: Self.url, options: .atomic) }
}

/// Keyword search over everything Starlight has heard: this meeting, past notes (what you said, your
/// questions and their answers, summaries), dictations and saved facts. Scored by how many query
/// words match, weighted by rarity (IDF), with prefix matching ("launch" finds "launching").
enum MemorySearch {
    struct Hit {
        let source: String   // "this meeting", "notes Oct 12 · 11:22 PM", "dictation …", "memory"
        let text: String
        let date: Date
        var score: Double = 0
        /// For lines from a saved meeting: where to open it.
        var moment: MeetingMoment? = nil
    }

    private static let stopwords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "to", "of", "and", "or", "in", "on", "at", "for", "with",
        "what", "who", "when", "where", "why", "how", "which", "did", "do", "does", "i", "we", "you", "it", "that",
        "this", "my", "our", "me", "us", "about", "from", "by", "as", "can", "could", "should", "would", "will",
        "say", "said", "tell", "there", "any", "have", "has", "had",
    ]

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 && !stopwords.contains($0) }
    }

    static func documents(meeting: [NoteItem], meetingStart: Date) -> [Hit] {
        var docs: [Hit] = []
        for item in meeting {
            let who = item.isMine ? "" : ", they said"
            docs.append(Hit(source: "this meeting, \(NotesController.timestamp(item.time)) in\(who)", text: item.text,
                            date: meetingStart.addingTimeInterval(item.time)))
        }
        for session in NotesStore.shared.sessions {
            let label = "meeting notes \(RelativeDate.string(session.started))"
            for item in session.items {
                var text = item.text
                if item.isQuestion, let answer = session.answer(for: item) { text += " — answer: \(answer)" }
                docs.append(Hit(source: item.isMine ? label : label + ", \(session.speakerName(item)) said", text: text,
                                date: session.started.addingTimeInterval(item.time),
                                moment: MeetingMoment(sessionID: session.id, time: item.time)))
            }
            if let summary = session.summary { docs.append(Hit(source: "\(label), summary", text: summary, date: session.started)) }
        }
        for entry in DictationHistory.shared.entries.prefix(300) {
            docs.append(Hit(source: "dictation \(RelativeDate.string(entry.date))", text: entry.text, date: entry.date))
        }
        for fact in MemoryStore.shared.facts {
            docs.append(Hit(source: "saved memory \(RelativeDate.string(fact.date))", text: fact.text, date: fact.date))
        }
        return docs
    }

    static func search(_ query: String, in docs: [Hit], limit: Int = 8) -> [Hit] {
        let terms = Set(words(query))
        guard !terms.isEmpty else { return [] }
        let tokenized = docs.map { Set(words($0.text)) }
        func matches(_ term: String, _ doc: Set<String>) -> Bool {
            doc.contains(term) || (term.count >= 4 && doc.contains { $0.hasPrefix(term) || term.hasPrefix($0) && $0.count >= 4 })
        }
        let n = Double(max(docs.count, 1))
        var idf: [String: Double] = [:]
        for term in terms {
            let df = Double(tokenized.filter { matches(term, $0) }.count)
            idf[term] = log((n + 1) / (df + 0.5))
        }
        var hits: [Hit] = []
        for (i, doc) in docs.enumerated() {
            let score = terms.reduce(0.0) { $0 + (matches($1, tokenized[i]) ? idf[$1, default: 0] : 0) }
            guard score > 0 else { continue }
            var hit = doc
            // Slight preference for recent material.
            let ageDays = max(Date().timeIntervalSince(doc.date) / 86_400, 0)
            hit.score = score * (1 + 0.15 / (1 + ageDays))
            hits.append(hit)
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }
}

struct MemoryExtension: StarlightExtension {
    let id = "memory"
    let name = "Memory"
    let summary = "Past meetings, dictations and saved facts."
    let glyph = Glyph.Kind.memory

    func register(_ api: ExtensionAPI) {
        // Like a context file: what you asked it to keep, plus this meeting so far.
        api.onBeforeAsk { request in
            var context = ""
            // The memories this is about, plus the newest few: not all of them every time.
            let all = MemoryStore.shared.facts
            let said = request.focus ?? request.unanswered
            let related = MemorySearch.search(said, in: all.map { MemorySearch.Hit(source: $0.id.uuidString, text: $0.text, date: $0.date) }, limit: 6)
                .compactMap { hit in all.first { $0.id.uuidString == hit.source } }
            var facts = related
            for fact in all.prefix(4) where !facts.contains(where: { $0.id == fact.id }) { facts.append(fact) }
            if !facts.isEmpty {
                context += "Saved memories (related ones, then the newest; search_memory finds the rest):\n" + facts.map { "- \($0.text)" }.joined(separator: "\n") + "\n\n"
            }
            // The live conversation already carries the meeting; this is for one-off questions.
            let recent = request.history.isEmpty ? request.meeting.suffix(14) : []
            if !recent.isEmpty {
                context += "This meeting so far (oldest first):\n"
                    + recent.map { "[\(NotesController.timestamp($0.time))] \($0.isMine ? "Me" : "Them"): \($0.text)" }.joined(separator: "\n")
            }
            return context.isEmpty ? nil : context
        }

        var request: AgentRequest?
        api.onBeforeAsk { request = $0; return nil }

        api.registerTool(Self.searchMeetingsTool())

        api.registerTool(AgentTool(
            name: "search_memory",
            description: "Search the user's saved memories, past dictations and this meeting. For anything said in a past meeting (who said what, when, decisions) use search_meetings instead, which links to the moment. Call it only for questions about the user's own work and life (their people, projects, decisions, plans, dates, or what was said before). Never call it for public knowledge such as sports, history, science or famous people. Returns matching lines with when and where they were said.",
            parameters: ["type": "object",
                         "properties": ["query": ["type": "string", "description": "Keywords, e.g. \"pricing page owner\" or \"launch date March\""]],
                         "required": ["query"]],
            status: "Checking memory", glyph: .memory,
            run: { args in
                let query = args["query"] as? String ?? ""
                // Saved meetings and dictations are changed on the main thread: read them there.
                let meeting = request?.meeting ?? [], start = request?.meetingStart ?? Date()
                let docs = await MainActor.run { MemorySearch.documents(meeting: meeting, meetingStart: start) }
                let hits = MemorySearch.search(query, in: docs)
                guard !hits.isEmpty else {
                    return ToolResult(content: "No matches for \"\(query)\".", display: "Nothing in memory for \u{201C}\(query)\u{201D}")
                }
                let content = hits.map { "[\($0.source)] \($0.text)" }.joined(separator: "\n")
                var result = ToolResult(content: content, display: "Found \(hits.count) in memory")
                result.link = hits.first(where: { $0.moment != nil })?.moment
                return result
            }))

        api.registerTool(AgentTool(
            name: "remember",
            description: "Save a fact for later meetings, when the user asks you to remember something or states a decision, date, owner or number worth keeping. Write it as a standalone sentence.",
            parameters: ["type": "object",
                         "properties": ["fact": ["type": "string", "description": "e.g. \"Dana owns the pricing page update.\""]],
                         "required": ["fact"]],
            status: "Remembering", glyph: .memory,
            keywords: ["remember", "note", "save", "keep", "forget", "memory", "memorize", "decision", "decided"],
            run: { args in
                let fact = args["fact"] as? String ?? ""
                let already = await MainActor.run { () -> Bool in
                    let known = MemoryStore.shared.contains(fact)
                    if !known { MemoryStore.shared.add(fact) }
                    return known
                }
                return already ? ToolResult(content: "Already saved; don't save it again.", outcome: .done("Already remembered"))
                    : ToolResult(content: "Saved.", outcome: .done("Saved to memory"))
            }))
    }
}
