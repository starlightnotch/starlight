import Foundation

/// Answers the questions in a notes session (and writes a short summary) with Claude Haiku 5.5
/// on OpenRouter. Only the text of the notes is sent, and only when you press Answer.
enum OpenRouter {
    struct Reply {
        let summary: String?
        let answers: [NoteSession.Answer]
        /// The provider OpenRouter actually used, from the response.
        var provider: String? = nil
        var model: String? = nil
    }

    enum Failure: LocalizedError {
        case noKey, rejectedKey, noCredits, server(Int, String), service(String), unreadable
        var errorDescription: String? {
            switch self {
            case .noKey: "Add your API key in Settings → Answers."
            case .rejectedKey: "The key wasn't accepted. Check it in Settings → Answers."
            case .noCredits: "Your account with the AI service is out of credits."
            case .server(let code, let message): "Error \(code): \(message)"
            case .service(let message): message
            case .unreadable: "The model's reply couldn't be read. Try again or pick another model."
            }
        }
    }


    private static let system = """
    You help someone right after a conversation. You get the questions they asked and the points they \
    made, in order. Reply with JSON only, in this shape:
    {"summary": "two or three sentences, second person, about what they asked and said",
     "answers": [{"question": "the question, copied exactly", "answer": "a clear, direct answer"}]}
    Answer every question, in order, in one to four sentences each. If an answer depends on context \
    you don't have, give the best general answer and say briefly what it depends on. Never invent \
    facts about the people or the conversation.
    """

    static func answer(_ session: NoteSession, key: String?,
                       service: AppSettings.AnswerService = AppSettings.shared.answerService) async throws -> Reply {
        guard let key, !key.isEmpty else { throw Failure.noKey }
        var notes = ""
        // Your questions get answers; their lines are context ("Them: …").
        for item in session.items {
            notes += (item.isMine ? (item.isQuestion ? "Q: " : "- ") : "Them: ") + item.text + "\n"
        }

        var body: [String: Any] = [
            "messages": [["role": "system", "content": system], ["role": "user", "content": notes]],
            "max_tokens": 4000,
        ]
        AppSettings.applyModel(to: &body, service: service)
        let (data, status) = try await AIService.send(body, service: service, key: key, timeout: 90)
        if status != 200 {
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? "request failed"
            DebugLog.write("openrouter: HTTP \(status) \(message) metadata: \(error?["metadata"].map { "\($0)" } ?? "none")")
            // The answer service's own words: signed out, not on Pro, down for a moment.
            if service == .notch, [401, 402, 429, 502, 503].contains(status) { throw Failure.service(message) }
            if status == 401 || status == 403 { throw Failure.rejectedKey }
            if status == 402 { throw Failure.noCredits }
            throw Failure.server(status, message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
        if let usage = json["usage"] as? [String: Any], let input = usage["prompt_tokens"] as? Int {
            Usage.record(input: input, output: usage["completion_tokens"] as? Int ?? 0, estimated: false)
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String
        else { throw Failure.unreadable }
        var reply = try parse(content)
        reply.provider = json["provider"] as? String
        reply.model = json["model"] as? String
        return reply
    }

    /// Reads the JSON object out of the reply, tolerating code fences or text around it.
    static func parse(_ content: String) throws -> Reply {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(content[start...end].utf8)) as? [String: Any]
        else { throw Failure.unreadable }
        let answers = (object["answers"] as? [[String: Any]] ?? []).compactMap { entry -> NoteSession.Answer? in
            guard let q = entry["question"] as? String, let a = entry["answer"] as? String else { return nil }
            return NoteSession.Answer(question: q, answer: a)
        }
        return Reply(summary: object["summary"] as? String, answers: answers)
    }
}

extension OpenRouter {
    /// `Starlight --answer-test`: one Answer request, printing which provider served it. Uses
    /// OPENROUTER_API_KEY from the environment, or the key saved in Settings; for
    /// STARLIGHT_SERVICE=notch, STARLIGHT_TOKEN (a Clerk session token for a Pro test account).
    static func runAnswerTest() {
        let env = ProcessInfo.processInfo.environment
        let service = env["STARLIGHT_SERVICE"].flatMap(AppSettings.AnswerService.init(rawValue:)) ?? AppSettings.shared.answerService
        let key = switch service {
        case .notch: env["STARLIGHT_TOKEN"]
        case .ollama: "ollama"
        case .openrouter: env["OPENROUTER_API_KEY"] ?? AppSettings.shared.openRouterKey
        default: env["STARLIGHT_KEY"] ?? AppSettings.shared.answerKeyFor(service)
        }
        let session = NotesStore.shared.sessions.first ?? NoteSession(
            id: "answer-test", started: Date(), duration: 30,
            items: [NoteItem(time: 0, text: "How many r's are in the word strawberry?", isQuestion: true),
                    NoteItem(time: 5, text: "I think we should ship the beta to fifty people.", isQuestion: false)])
        print("service \(service.rawValue), model \(AppSettings.shared.model(for: service))")
        print("notes: \(session.questions.count) questions, \(session.statements.count) points")
        let done = DispatchSemaphore(value: 0)
        Task {
            let start = Date()
            do {
                let reply = try await answer(session, key: key, service: service)
                print(String(format: "served by provider: %@ (model %@) in %.1fs", reply.provider ?? "unknown",
                             reply.model ?? "?", Date().timeIntervalSince(start)))
                if let summary = reply.summary { print("summary: \(summary)") }
                for a in reply.answers { print("Q: \(a.question)\nA: \(a.answer)") }
            } catch {
                print("failed: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
    }
}

extension OpenRouter {
    /// `Starlight --key-check`: describes the saved key without printing it, and asks OpenRouter
    /// whether it is valid (GET /api/v1/key).
    static func runKeyCheck() {
        guard let key = AppSettings.shared.openRouterKey else { return print("no key saved") }
        let scalars = key.unicodeScalars
        print("length: \(key.count) (OpenRouter keys are usually 73)")
        print("starts with sk-or-v1-: \(key.hasPrefix("sk-or-v1-"))")
        print("spaces or line breaks inside: \(scalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) })")
        print("non-ASCII characters: \(scalars.filter { !$0.isASCII }.count)")
        print("quotes or 'Bearer': \(key.contains("\"") || key.contains("'") || key.lowercased().contains("bearer"))")
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!, timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("OpenRouter says: HTTP \(status) \(status == 200 ? "(key is valid)" : "(key not accepted)")")
            if status == 200, let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let info = json["data"] as? [String: Any] {
                print("usage so far: \(info["usage"] ?? "?"), limit: \(info["limit"] ?? "none")")
            } else if let data, let text = String(data: data, encoding: .utf8) {
                print("reply: \(text.prefix(200))")
            }
            if let error { print("network error: \(error.localizedDescription)") }
            done.signal()
        }.resume()
        done.wait()

        // A minimal chat request and the account's credits, to tell a key problem from an account one.
        func call(_ path: String, body: [String: Any]?) {
            var r = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/\(path)")!, timeoutInterval: 60)
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if let body {
                r.httpMethod = "POST"
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: r) { data, response, _ in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                print("\(path): HTTP \(status) \(data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.prefix(220)) } ?? "")")
                sem.signal()
            }.resume()
            sem.wait()
        }
        call("credits", body: nil)
        call("chat/completions", body: ["model": AppSettings.model, "max_tokens": 5,
                                        "messages": [["role": "user", "content": "Say hi"]]])
    }
}
