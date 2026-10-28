import Foundation

/// A saved notes session. Stored as JSON (for the app) plus Markdown (to read anywhere) in
/// ~/Library/Application Support/Starlight/Notes/.
struct NoteSession: Identifiable, Equatable, Codable {
    struct Answer: Equatable, Codable {
        var question: String
        var answer: String
        /// Seconds into the meeting it came in (older sessions don't have it).
        var time: TimeInterval? = nil
    }

    let id: String          // file name stem, e.g. "2026-10-12 23.09"
    let started: Date
    let duration: TimeInterval
    var items: [NoteItem]
    var summary: String? = nil
    var answers: [Answer]? = nil
    var answerModel: String? = nil
    /// Names you gave the other speakers ("2" → "Dana").
    var speakerNames: [String: String]? = nil
    /// The meeting's sections, written when it ends.
    var chapters: [Chapter]? = nil
    /// "live" for a Live mode session; nil for notes.
    var kind: String? = nil

    struct Chapter: Identifiable, Equatable, Codable {
        var id = UUID()
        let start: TimeInterval
        let title: String
        let summary: String
    }

    /// "You", a name you gave, "Speaker 2", or "Them" when their voices weren't told apart.
    func speakerName(_ item: NoteItem) -> String {
        if item.isMine { return "You" }
        guard let id = item.speakerID else { return "Them" }
        return speakerNames?[id] ?? "Speaker \(id)"
    }

    /// Everyone on their side, in the order they first spoke.
    var speakerIDs: [String] {
        var seen: [String] = []
        for item in items { if let id = item.speakerID, !seen.contains(id) { seen.append(id) } }
        return seen
    }

    /// Your questions and points; their side is in `items` with `speaker == .them`.
    var questions: [NoteItem] { items.filter { $0.isMine && $0.isQuestion } }
    var statements: [NoteItem] { items.filter { $0.isMine && !$0.isQuestion } }
    var hasTheirSide: Bool { items.contains { !$0.isMine } }
    var file: URL? { NotesStore.markdownURL(id) }

    static func makeID(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: date)
    }

    var title: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: started)
    }

    func answer(for question: NoteItem) -> String? {
        answers?.first { $0.question.caseInsensitiveCompare(question.text) == .orderedSame }?.answer
    }

    // MARK: The conversation, as it happened

    /// One person talking until someone else does: their sentences joined back together.
    struct Turn: Identifiable, Equatable {
        let id: UUID
        let time: TimeInterval
        let isMine: Bool
        let speakerID: String?
        var text: String
    }

    /// The meeting in order: who said what, the sections it moved through, and what Starlight added.
    enum LogEntry: Identifiable, Equatable {
        case chapter(Chapter)
        case turn(Turn)
        case notch(time: TimeInterval, text: String, id: String)

        var id: String {
            switch self {
            case .chapter(let c): "chapter-\(c.id)"
            case .turn(let t): "turn-\(t.id)"
            case .notch(_, _, let id): id
            }
        }
    }

    /// A pause this long starts a new paragraph, even from the same person.
    static let turnPause: TimeInterval = 6

    var turns: [Turn] {
        var out: [Turn] = []
        var lastTime: TimeInterval = -.infinity
        for item in items {
            defer { lastTime = item.time }
            if var last = out.last, last.isMine == item.isMine, last.speakerID == item.speakerID,
               item.time - lastTime < Self.turnPause {
                last.text += " " + item.text
                out[out.count - 1] = last
            } else {
                out.append(Turn(id: item.id, time: item.time, isMine: item.isMine, speakerID: item.speakerID, text: item.text))
            }
        }
        return out
    }

    func speakerName(_ turn: Turn) -> String {
        if turn.isMine { return "You" }
        guard let id = turn.speakerID else { return "Them" }
        return speakerNames?[id] ?? "Speaker \(id)"
    }

    var log: [LogEntry] {
        let turns = self.turns
        // When each of Starlight's answers came: its own time, or just after the turn it answered.
        var placed: [(TimeInterval, Int, String)] = []
        for (index, answer) in (answers ?? []).enumerated() {
            let asked = answer.question.replacingOccurrences(of: #"(?m)^(Me|Them)( \([^)]*\))?:\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let probe = String(asked.prefix(40))
            let time = answer.time
                ?? turns.last(where: { !probe.isEmpty && $0.text.lowercased().contains(probe) }).map { $0.time + 0.5 }
                ?? duration
            placed.append((time, index, answer.answer))
        }
        placed.sort { $0.0 < $1.0 }
        var chapters = (chapters ?? []).sorted { $0.start < $1.start }
        var out: [LogEntry] = []
        var pending = placed[...]
        for turn in turns {
            while let next = pending.first, next.0 < turn.time {
                out.append(.notch(time: next.0, text: next.2, id: "notch-\(next.1)")); pending = pending.dropFirst()
            }
            while let next = chapters.first, next.start <= turn.time + 0.5 { out.append(.chapter(next)); chapters.removeFirst() }
            out.append(.turn(turn))
        }
        for next in pending { out.append(.notch(time: next.0, text: next.2, id: "notch-\(next.1)")) }
        out.append(contentsOf: chapters.map(LogEntry.chapter))
        return out
    }

    /// The transcript the way a court reporter writes one: a heading, then each speaker's name
    /// in capitals and what they said, Starlight's answers included as STARLIGHT. No timestamps or
    /// sections, nothing to clean up before pasting.
    var transcriptText: String {
        let date = started.formatted(date: .complete, time: .shortened)
        var out = "TRANSCRIPT\n\(date) · \(lengthText)\n"
        for entry in log {
            switch entry {
            case .chapter: continue
            case .turn(let t): out += "\n\(speakerName(t).uppercased()): \(t.text)\n"
            case .notch(_, let text, _): out += "\nSTARLIGHT: \(Markdown.plain(text))\n"
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "13 min", "45 sec", "1 hr 5 min".
    var lengthText: String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(max(seconds, 1)) sec" }
        let minutes = Int((duration / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(minutes % 60) min"
    }

    /// The whole log as plain text, with times, to paste anywhere.
    var plainLog: String {
        let stamp = NotesController.timestamp
        return log.compactMap { entry -> String? in
            switch entry {
            case .chapter(let c): "\n— \(c.title) (\(stamp(c.start))) —"
            case .turn(let t): "[\(stamp(t.time))] \(speakerName(t)): \(t.text)"
            case .notch(let time, let text, _): "[\(stamp(time))] Starlight: \(text)"
            }
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// At-a-glance numbers for the end of a meeting.
    struct Stats: Equatable {
        let duration: TimeInterval
        let words: Int
        let yourWords: Int
        let people: Int
        let questions: Int
        let answers: Int
        let turns: Int
        /// Your share of the words spoken, 0…1; nil when only your side was heard.
        var yourShare: Double? = nil
    }

    /// The end of a meeting in words: "12 minutes with Dana", then "You did most of the
    /// talking · Starlight answered 2".
    var ending: (title: String, detail: String) {
        let st = stats
        let length: String = {
            let seconds = Int(duration.rounded())
            if seconds < 60 { return "\(max(seconds, 1)) second\(seconds == 1 ? "" : "s")" }
            let minutes = Int((duration / 60).rounded())
            if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h) hour\(h == 1 ? "" : "s")" : "\(h) hr \(m) min"
        }()
        let names = speakerIDs.compactMap { speakerNames?[$0] }
        let title: String
        if kind == "live" {
            title = "\(length) live"
        } else if !hasTheirSide {
            title = "\(length) of notes"
        } else if !names.isEmpty, names.count == speakerIDs.count, names.count <= 2 {
            title = "\(length) with " + names.joined(separator: " and ")
        } else if st.people > 2 {
            title = "\(length) with \(st.people - 1) people"
        } else {
            title = "\(length) of conversation"
        }
        // Who did the talking, by name when there is one: "Anna did most of the talking".
        guard let share = st.yourShare else { return (title, "Saved to your notes") }
        if share > 0.6 { return (title, "You did most of the talking") }
        if share > 0.4 { return (title, "A good back-and-forth") }
        var words: [String: Int] = [:]
        for item in items where !item.isMine { words[item.speakerID ?? "", default: 0] += item.text.split { $0.isWhitespace }.count }
        let top = words.max { $0.value < $1.value }?.key
        let name = top.flatMap { $0.isEmpty ? nil : speakerNames?[$0] }
        return (title, "\(name ?? "They") did most of the talking")
    }

    var stats: Stats {
        func count(_ text: String) -> Int { text.split { $0.isWhitespace }.count }
        let mine = items.filter(\.isMine).reduce(0) { $0 + count($1.text) }
        let total = items.reduce(0) { $0 + count($1.text) }
        let people = 1 + (hasTheirSide ? max(speakerIDs.count, 1) : 0)
        return Stats(duration: duration, words: total, yourWords: mine, people: people,
                     questions: items.filter(\.isQuestion).count, answers: answers?.count ?? 0, turns: turns.count,
                     yourShare: hasTheirSide && total > 0 ? Double(mine) / Double(total) : nil)
    }
}

final class NotesStore: ObservableObject {
    static let shared = NotesStore()
    @Published private(set) var sessions: [NoteSession] = []
    /// Sessions whose timeline is being written right now.
    @Published var writingChapters: Set<String> = []

    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Starlight/Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func markdownURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).md") }
    private static func jsonURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).json") }

    /// Read off the main thread: every saved meeting is decoded here, and doing it on the main
    /// thread held up the first open of the notch by a few frames.
    private init() {
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = Self.load()
            DispatchQueue.main.async { if self.sessions.isEmpty { self.sessions = loaded } }
        }
    }

    func reload() { sessions = Self.load() }

    private static func load() -> [NoteSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(NoteSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.started > $1.started }
    }

    func session(_ id: String) -> NoteSession? { sessions.first { $0.id == id } }

    func save(_ session: NoteSession) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try? encoder.encode(session).write(to: Self.jsonURL(session.id), options: .atomic)
        try? Self.markdown(session).write(to: Self.markdownURL(session.id), atomically: true, encoding: .utf8)
        if let i = sessions.firstIndex(where: { $0.id == session.id }) { sessions[i] = session } else { sessions.insert(session, at: 0) }
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: Self.jsonURL(id))
        try? FileManager.default.removeItem(at: Self.markdownURL(id))
        sessions.removeAll { $0.id == id }
    }

    static func markdown(_ s: NoteSession) -> String {
        let stamp = NotesController.timestamp
        var md = "# Notes — \(s.title)\n\n_\(stamp(s.duration))_\n\n"
        if let summary = s.summary { md += "**Summary:** \(summary)\n\n" }
        let st = s.stats
        md += "_\(st.words.formatted()) words · \(st.people) \(st.people == 1 ? "person" : "people") · \(st.answers) from Starlight_\n\n"
        if let chapters = s.chapters, !chapters.isEmpty {
            md += "## Timeline\n\n" + chapters.map { "- [\(stamp($0.start))] **\($0.title)**: \($0.summary)" }.joined(separator: "\n") + "\n\n"
        }
        md += "## Conversation\n\n"
        for entry in s.log {
            switch entry {
            case .chapter(let c): md += "\n### \(c.title)\n\n"
            case .turn(let t): md += "**\(s.speakerName(t))** [\(stamp(t.time))]: \(t.text)\n\n"
            case .notch(let time, let text, _): md += "> **Starlight** [\(stamp(time))]: \(text.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
            }
        }
        if let model = s.answerModel { md += "\n_Answers by \(model)._\n" }
        return md
    }
}
