import AppKit

/// A moment in a saved meeting, for "Open at 12:31" links.
struct MeetingMoment: Codable, Equatable {
    let sessionID: String
    let time: TimeInterval
}

/// Search across every saved meeting by what was said, who said it, and when: "what did Dana
/// say about pricing last week?". Each result knows its moment, so the answer can link to it.
enum MeetingSearch {
    struct Result {
        let session: NoteSession
        let turn: NoteSession.Turn
        let score: Double
        var moment: MeetingMoment { MeetingMoment(sessionID: session.id, time: turn.time) }
    }

    /// "today", "yesterday", "this week", "last week", "this month", "last month", or a date.
    static func range(_ when: String?) -> ClosedRange<Date>? {
        guard let when = when?.lowercased().trimmingCharacters(in: .whitespaces), !when.isEmpty, when != "any" else { return nil }
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        func week(_ offset: Int) -> ClosedRange<Date>? {
            guard let start = cal.dateInterval(of: .weekOfYear, for: now)?.start,
                  let from = cal.date(byAdding: .weekOfYear, value: offset, to: start),
                  let to = cal.date(byAdding: .weekOfYear, value: 1, to: from) else { return nil }
            return from...to
        }
        func month(_ offset: Int) -> ClosedRange<Date>? {
            guard let start = cal.dateInterval(of: .month, for: now)?.start,
                  let from = cal.date(byAdding: .month, value: offset, to: start),
                  let to = cal.date(byAdding: .month, value: 1, to: from) else { return nil }
            return from...to
        }
        switch when {
        case "today": return today...now
        case "yesterday": return today.addingTimeInterval(-86_400)...today
        case "this week": return week(0)
        case "last week": return week(-1)
        case "this month": return month(0)
        case "last month": return month(-1)
        default:
            if let match = (try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue))?
                .firstMatch(in: when, range: NSRange(when.startIndex..., in: when)), let date = match.date {
                let day = cal.startOfDay(for: date)
                return day...day.addingTimeInterval(86_400)
            }
            return nil
        }
    }

    static func search(_ query: String, person: String?, when: String?, limit: Int = 8) -> [Result] {
        let range = range(when)
        let who = person?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        let me = ["me", "i", "myself", "you", "user"].contains(who)
        var docs: [MemorySearch.Hit] = []
        var lookup: [(NoteSession, NoteSession.Turn)] = []
        for session in NotesStore.shared.sessions {
            if let range, !range.contains(session.started) { continue }
            for turn in session.turns {
                if !who.isEmpty {
                    let name = session.speakerName(turn).lowercased()
                    if me ? !turn.isMine : !name.contains(who) { continue }
                }
                docs.append(MemorySearch.Hit(source: "\(lookup.count)", text: turn.text, date: session.started.addingTimeInterval(turn.time)))
                lookup.append((session, turn))
            }
        }
        // No words to match ("what did Dana say last week?"): their latest turns.
        if MemorySearch.words(query).isEmpty {
            return docs.sorted { $0.date > $1.date }.prefix(limit).compactMap { hit in
                Int(hit.source).map { Result(session: lookup[$0].0, turn: lookup[$0].1, score: 0) }
            }
        }
        return MemorySearch.search(query, in: docs, limit: limit).compactMap { hit in
            Int(hit.source).map { Result(session: lookup[$0].0, turn: lookup[$0].1, score: hit.score) }
        }
    }

    /// "Mon, Oct 12 · 3:04 PM"
    static func when(_ session: NoteSession) -> String {
        session.started.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}

/// Built into Memory: searching past meetings.
extension MemoryExtension {
    static func searchMeetingsTool() -> AgentTool {
        AgentTool(
            name: "search_meetings",
            description: "Search every saved meeting for what was said: by topic words, by who said it (a name, or \"me\"), and when (today, yesterday, this week, last week, this month, last month, or a date). Use for \"what did Dana say about pricing last week?\", \"when did we decide the launch date?\", \"what did I promise in Monday's meeting?\". Results are numbered, with when and who; answer from them and say when it was said. The best match is linked so the user can open that moment.",
            parameters: ["type": "object",
                         "properties": ["query": ["type": "string", "description": "Topic words, e.g. \"pricing page\"; empty to get everything that person said"],
                                        "person": ["type": "string", "description": "Who said it, if they named someone"],
                                        "when": ["type": "string", "description": "today, yesterday, this week, last week, this month, last month, or a date"]],
                         "required": []],
            status: "Searching your meetings", glyph: .memory,
            keywords: ["meeting", "meetings", "said", "say", "mentioned", "talked", "discussed", "decided", "promised", "agreed",
                       "last week", "yesterday", "call"],
            run: { args in
                let query = args["query"] as? String ?? ""
                let person = args["person"] as? String
                let when = args["when"] as? String
                let results = await MainActor.run { MeetingSearch.search(query, person: person, when: when) }
                guard !results.isEmpty else {
                    return ToolResult(content: "Nothing in saved meetings for that.", display: "Nothing in your meetings")
                }
                let lines = results.enumerated().map { i, r in
                    "[\(i + 1)] \(MeetingSearch.when(r.session)), \(NotesController.timestamp(r.turn.time)) in — \(r.session.speakerName(r.turn)): \(r.turn.text)"
                }
                var result = ToolResult(content: lines.joined(separator: "\n"), display: "Found \(results.count) in your meetings")
                result.link = results.first?.moment
                return result
            })
    }
}
