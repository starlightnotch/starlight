import Foundation

/// Splits a finished meeting into sections, like video chapters: when each part started, a
/// short specific title and a one-line summary. Written once when the session ends (and again
/// on request), with the Answer model, from the timestamped transcript.
enum Chapters {
    static let instructions = """
    You turn a meeting transcript into a timeline of sections, like the chapters of a video.
    Reply with JSON only: {"chapters": [{"start": seconds, "title": "...", "summary": "..."}]}
    - The first chapter starts at 0. Each later one starts where the conversation turns to a \\
    new topic, at the timestamp of the line where that happens.
    - About one chapter per 3 to 6 minutes, between 2 and 10 in total (1 is fine for a very \\
    short conversation with a single topic).
    - Titles: 2 to 5 words, specific to what was discussed ("Q2 launch date", "Pricing page \\
    owner"), never generic ("Discussion", "Introduction", "Wrap-up" only when that's truly all it is).
    - Summaries: one sentence, under 20 words, what was said or decided, using people's names \\
    as given. Never invent anything not in the transcript.
    """

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Writes the chapters and saves them with the session. Quietly does nothing without a key.
    static func write(for id: String) async {
        let settings = AppSettings.shared
        guard settings.hasAnswerKey, let session = await MainActor.run(body: { NotesStore.shared.session(id) }),
              session.items.count >= 3 else { return }
        await MainActor.run { _ = NotesStore.shared.writingChapters.insert(id) }
        defer { Task { @MainActor in NotesStore.shared.writingChapters.remove(id) } }
        guard let key = await settings.loadAnswerKey() else { return }
        do {
            let chapters = try await request(session, key: key, service: settings.answerService)
            await MainActor.run {
                guard var latest = NotesStore.shared.session(id) else { return }
                latest.chapters = chapters
                NotesStore.shared.save(latest)
            }
            DebugLog.write("chapters: \(chapters.count) for \(id)")
        } catch {
            DebugLog.write("chapters: failed: \(error.localizedDescription)")
        }
    }

    private static func request(_ session: NoteSession, key: String, service: AppSettings.AnswerService) async throws -> [NoteSession.Chapter] {
        let transcript = session.items.map { "[\(NotesController.timestamp($0.time))] \(session.speakerName($0)): \($0.text)" }
            .joined(separator: "\n")
        var body: [String: Any] = [
            "messages": [["role": "system", "content": instructions],
                         ["role": "user", "content": "Meeting length: \(NotesController.timestamp(session.duration))\n\n" + transcript]],
            "max_tokens": 1500,
            "temperature": 0.2,
        ]
        AppSettings.applyModel(to: &body, service: service)
        let (data, status) = try await AIService.send(body, service: service, key: key, timeout: 90)
        // Only answered requests count toward usage.
        if status == 200, let usage = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["usage"] as? [String: Any],
           let input = usage["prompt_tokens"] as? Int {
            Usage.record(input: input, output: usage["completion_tokens"] as? Int ?? 0, estimated: false)
        } else if status == 200 {
            Usage.record(input: Usage.estimate(transcript) + 300, output: Usage.estimate(String(decoding: data, as: UTF8.self)), estimated: true)
        }
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String,
              let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end,
              let object = try JSONSerialization.jsonObject(with: Data(content[start...end].utf8)) as? [String: Any]
        else { throw Failure(message: "The timeline couldn't be written.") }

        var chapters = (object["chapters"] as? [[String: Any]] ?? []).compactMap { entry -> NoteSession.Chapter? in
            guard let title = entry["title"] as? String else { return nil }
            let start = (entry["start"] as? Double) ?? Double(entry["start"] as? Int ?? 0)
            return NoteSession.Chapter(start: max(0, min(start, session.duration)), title: title,
                                       summary: entry["summary"] as? String ?? "")
        }
        chapters.sort { $0.start < $1.start }
        if var first = chapters.first, first.start > 0 {  // the timeline always starts at the start
            first = NoteSession.Chapter(id: first.id, start: 0, title: first.title, summary: first.summary)
            chapters[0] = first
        }
        return chapters
    }
}
