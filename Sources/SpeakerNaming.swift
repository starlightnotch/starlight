import Foundation

/// Puts names to the voices in a meeting, the way you would by listening.
///
/// - Someone introduces themselves ("I'm Dana", "my name is Sam", "this is Priya from sales"):
///   that speaker is named at once.
/// - Names that come out in conversation ("yo Amin, what do you think?", then someone answers):
///   every couple of minutes, and when the meeting ends, the agent reads the transcript and names
///   a speaker only where the conversation makes it clear.
/// - A name you type yourself always wins; Starlight never changes it. Its own guesses can be
///   corrected by later evidence.
@MainActor
final class SpeakerNaming {
    private let model: NotchModel
    private var lastRun = Date.distantPast
    private var linesAtLastRun = 0
    private var running = false
    /// How often the transcript is read for names during a meeting.
    private let every: TimeInterval = 120

    init(model: NotchModel) { self.model = model }

    func reset() {
        lastRun = Date()
        linesAtLastRun = 0
        model.guessedSpeakerNames = []
    }

    /// A finished line from one of the other speakers.
    func heard(_ text: String, from speakerID: String?) {
        guard let speakerID else { return }
        if let found = Self.introduced(text) { assign(speakerID, found, reason: "introduced themselves") }
        let lines = model.noteItems.count
        if Date().timeIntervalSince(lastRun) > every, lines - linesAtLastRun >= 6, needsNames { Task { await inferNames() } }
    }

    /// The meeting ended: one last read, and the saved session gets the names.
    func finish(sessionID: String) {
        guard needsNames, model.noteItems.count >= 4 else { return }
        Task {
            await inferNames()
            guard var session = NotesStore.shared.session(sessionID), session.speakerNames != model.speakerNames else { return }
            session.speakerNames = model.speakerNames.isEmpty ? nil : model.speakerNames
            NotesStore.shared.save(session)
        }
    }

    /// Speakers heard who have no name yet, or only a guess.
    private var needsNames: Bool {
        let ids = Set(model.noteItems.compactMap(\.speakerID))
        return ids.contains { model.speakerNames[$0] == nil || model.guessedSpeakerNames.contains($0) }
    }

    private func assign(_ id: String, _ name: String, reason: String) {
        // Yours stays: only an empty name or Starlight's own guess is replaced.
        guard model.speakerNames[id] == nil || model.guessedSpeakerNames.contains(id), model.speakerNames[id] != name else { return }
        model.speakerNames[id] = name
        model.guessedSpeakerNames.insert(id)
        DebugLog.write("speakers: \(id) is \(name) (\(reason))")
    }

    // MARK: Rules

    /// "I'm Dana", "my name is Sam", "this is Priya (here / from …)", "Dana here". Only capitalized
    /// words that aren't everyday ones, so "I'm Good" and "this is Monday" don't name anyone.
    static func introduced(_ text: String) -> String? {
        let patterns = [#"(?i:\b(?:my name is|my name's|i am|i'm|i’m|this is|it's|it’s))\s+([A-Z][a-z]{1,15})(?:\s+(?:here|speaking|from|on|calling)\b|[,.!]|$)"#,
                        #"^\s*(?i:hi|hey|hello)?,?\s*([A-Z][a-z]{1,15})\s+here\b"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[range])
            if !notNames.contains(name.lowercased()) { return name }
        }
        return nil
    }

    private static let notNames: Set<String> = ["good", "fine", "great", "okay", "sorry", "sure", "here", "back", "done", "ready", "just",
        "not", "so", "really", "going", "trying", "thinking", "glad", "happy", "excited", "the", "that", "this", "what", "monday",
        "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow", "yesterday", "everyone", "all",
        "actually", "also", "still", "very", "pretty", "well", "right", "true", "interesting", "important", "crazy", "insane",
        "amazing", "awesome", "perfect", "nice", "cool", "weird", "hard", "easy", "late", "early", "new", "it", "me", "him", "her",
        "them", "we", "you", "they", "one", "zoom", "google", "apple", "slack", "notch", "march", "april", "may", "june", "july"]

    // MARK: The agent

    private func inferNames() async {
        guard !running, AppSettings.shared.hasAnswerKey else { return }
        let settings = AppSettings.shared
        guard let key = await settings.loadAnswerKey() else { return }
        running = true
        defer { running = false }
        lastRun = Date()
        linesAtLastRun = model.noteItems.count
        let lines = model.noteItems.suffix(160).map { item -> String in
            let who = item.isMine ? "Me" : item.speakerID.map { id in
                "Speaker \(id)" + (model.speakerNames[id].map { model.guessedSpeakerNames.contains(id) ? " (guessed: \($0))" : " (\($0))" } ?? "")
            } ?? "Them"
            return "\(who): \(item.text)"
        }.joined(separator: "\n")
        guard let found = try? await Self.ask(lines, key: key, service: settings.answerService) else { return }
        for (id, name) in found where model.noteItems.contains(where: { $0.speakerID == id }) {
            assign(id, name, reason: "from the conversation")
        }
    }

    private static let instructions = """
    You read a meeting transcript and work out the names of the other speakers ("Speaker 3" and so on). \
    "Me" is the user; ignore them. Name a speaker only when the transcript makes it clear: they introduce \
    themselves, someone addresses them by name and they're the one who answers, or someone refers to them \
    by name in a way that can only mean them. Never guess from a name that's merely mentioned. A speaker \
    already named in parentheses keeps that name unless the transcript clearly shows a different one; a \
    "guessed" name can be corrected. Reply with JSON only: {"names": {"3": "Amin"}}, or {"names": {}} if \
    nothing is clear. First names, as said.
    """

    private static func ask(_ transcript: String, key: String, service: AppSettings.AnswerService) async throws -> [String: String] {
        var body: [String: Any] = [
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": transcript]],
            "max_tokens": 200, "temperature": 0,
        ]
        AppSettings.applyModel(to: &body, service: service)
        let (data, status) = try await AIService.send(body, service: service, key: key, timeout: 45)
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String,
              let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end,
              let object = try JSONSerialization.jsonObject(with: Data(content[start...end].utf8)) as? [String: Any] else { return [:] }
        if let usage = json["usage"] as? [String: Any], let input = usage["prompt_tokens"] as? Int {
            Usage.record(input: input, output: usage["completion_tokens"] as? Int ?? 0, estimated: false)
        }
        let names = object["names"] as? [String: String] ?? [:]
        // First names only, letters and a hyphen or apostrophe; anything else is a misread.
        return names.filter { $0.value.range(of: #"^[A-Z][A-Za-z'\-]{1,20}$"#, options: .regularExpression) != nil }
    }
}
