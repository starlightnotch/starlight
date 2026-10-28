import Foundation

/// Looks things up on the web through OpenRouter's web search: Claude Haiku 5.5 with the `web`
/// plugin (https://openrouter.ai/docs/guides/features/web-search), or Claude's own web search tool
/// with an Anthropic key (AIService turns the plugin into it), on the same key or plan as
/// every other answer.
///
/// Built for speed:
/// - The search streams, so its answer types out in the notch as Haiku writes it.
/// - Its answer is the final answer: the meeting agent doesn't rewrite it.
/// - Time-sensitive questions search straight away, with no "should I search?" step (see
///   Agent.run).
/// - No thinking, three results, and a sub-30-word answer keep it quick and cheap.
struct WebSearchExtension: StarlightExtension {
    let id = "web-search"
    let name = "Web search"
    let summary = "News, prices, scores, weather, anything recent."
    let glyph = Glyph.Kind.globe

    func register(_ api: ExtensionAPI) {
        // Not offered where the service can't search (OpenAI's chat models, Ollama).
        guard Self.searches(AppSettings.shared.answerService) else { return }
        api.registerTool(AgentTool(
            name: "web_search",
            description: "Search the web for current or recent information: news, today's events, latest releases, live scores, prices, stock prices, weather, schedules, opening hours, anything that changes often or happened after your training data. Not needed for settled general knowledge. Its result is shown to the user as your answer.",
            parameters: ["type": "object",
                         "properties": ["query": ["type": "string", "description": "The user's question, rewritten to stand alone, e.g. \"Apple stock price today\""]],
                         "required": ["query"]],
            status: "Searching the web", glyph: .globe,
            keywords: ["news", "price", "prices", "cost", "costs", "stock", "shares", "weather", "forecast", "temperature", "score",
                       "scores", "game", "match", "latest", "current", "currently", "today", "tonight", "yesterday", "release",
                       "released", "open", "hours", "schedule", "election", "results", "winner", "won", "search", "google", "look"],
            run: { args in try await Self.search(args["query"] as? String ?? "", onText: { _ in }, onStatus: { _ in }) },
            answers: { args, onText, onStatus in try await Self.search(args["query"] as? String ?? "", onText: onText, onStatus: onStatus) }))
        // So it can say how it searched, and knows which earlier replies came from a search.
        let by = Self.engine == "local"
            ? "this Mac: it looks the question up on Startpage (Google results) and reads the top pages itself, free, then \(AppSettings.shared.answerService.displayName) writes the answer from them"
            : Self.searchedBy(AppSettings.shared.answerService)
        api.onBeforeAsk { _ in
            "Web search: your web_search tool runs on \(by), not on the user's Mac. Earlier replies that start with \(Agent.searchedTag) were answers from that search: you did search for them. Asked whether or how you searched, say so in one sentence, nothing more. Never write that tag yourself."
        }
    }

    /// Who runs the search, for the agent to tell the user.
    static func searchedBy(_ service: AppSettings.AnswerService) -> String {
        switch service {
        case .openrouter: "OpenRouter's servers (its web plugin, which uses Exa search), on the user's OpenRouter key"
        case .anthropic: "Anthropic's servers (Claude's own web search tool), on the user's Anthropic key"
        default: "Starlight's servers (Starlight Pro)"
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Which search runs: "local" (this Mac looks it up, see LocalSearch; Settings → AI provider),
    /// else the provider's: "exa" (OpenRouter searches, then Haiku reads the results) or "native"
    /// (Claude's own web search tool). STARLIGHT_SEARCH_ENGINE overrides it for tests.
    static var engine: String {
        Dev.env("STARLIGHT_SEARCH_ENGINE") ?? (AppSettings.shared.searchOnMac ? "local" : "exa")
    }

    /// Searches and streams the answer through `onText`. Returns the full answer and sources.
    /// A search that fails before writing anything is tried once more.
    static func search(_ query: String, onText: @escaping (String) -> Void,
                       onStatus: @escaping (String) -> Void) async throws -> ToolResult {
        let settings = AppSettings.shared
        guard settings.hasAnswerKey, let key = await settings.loadAnswerKey(), !key.isEmpty else {
            // Thrown, not returned: the card says so, and in the tool loop the model sees it.
            throw Failure(message: settings.answerService == .notch ? "Web search is on Pro (Settings → AI provider)"
                          : "Web search needs your \(settings.answerService.displayName) key (Settings → AI provider)")
        }
        // OpenRouter, Claude and Pro search the web; OpenAI's chat models and Ollama's can't.
        guard Self.searches(settings.answerService) else {
            throw Failure(message: "Web search needs Pro, OpenRouter, Anthropic, or Search from this Mac (Settings → AI provider)")
        }
        var wrote = false
        do {
            return try await stream(query, service: settings.answerService, key: key, onText: { wrote = true; onText($0) })
        } catch let error as Failure where !wrote && !error.message.hasPrefix("Error 4") {
            DebugLog.write("web search: \(error.message), trying again")
            return try await stream(query, service: settings.answerService, key: key, onText: onText)
        }
    }

    /// The services that can search the web: all of them when this Mac does the searching.
    static func searches(_ service: AppSettings.AnswerService) -> Bool {
        engine == "local" || service == .notch || service == .openrouter || service == .anthropic
    }

    /// Opens the connection ahead of time (TLS and HTTP/2 setup), so the first question in a
    /// meeting doesn't pay for it. Called when a notes session starts.
    static func warmUp() {
        AIService.warmUp(AppSettings.shared.answerService)
    }

    private static func stream(_ query: String, service: AppSettings.AnswerService, key: String,
                               onText: @escaping (String) -> Void) async throws -> ToolResult {
        // The same question as the answer that called it: counted once on a plan.
        let headers = service == .notch
            ? ["X-Starlight-Turn": Agent.turnID, "X-Notch-Turn": Agent.turnID]  // the second for a backend from before the rename
            : [:]
        let today = Date().formatted(date: .complete, time: .omitted)
        var engine = Self.engine
        var userText = query
        var sources: [String] = []
        if engine == "local" {
            // Looked up here; the provider only reads the results and writes the answer.
            let found = await LocalSearch.search(query)
            if !found.results.isEmpty {
                userText = "Question: \(query)\n\nWeb results from \(today):\n\n" + LocalSearch.context(found)
                sources = found.pages.map(\.url) + found.results.prefix(3).map(\.url)
            } else if service == .notch || service == .openrouter || service == .anthropic {
                // The engines are busy (rate limit, captcha): the provider's own search, paid.
                DebugLog.write("web search: nothing from this Mac, using \(service.rawValue)'s search")
                engine = "exa"
            } else {
                throw Failure(message: "Search found nothing (the search engines may be busy).")
            }
        }
        let local = engine == "local"
        let messages: [[String: Any]] = [
            ["role": "system", "content": "Today is \(today). Answer from the web results in one or two short sentences, under 30 words, the key fact first, with the date when it matters. If there are many results (films, games, headlines), name only the top two or three. Plain text: no markdown, no links, no citation marks." + (local ? " Results can be old or disagree: go by the most recent dated one, and settle on the answer before writing (never correct yourself mid-answer). Don't name or cite the sites. If the results don't answer it, say so briefly." : "")],
            ["role": "user", "content": userText],
        ]
        var body: [String: Any] = [
            "messages": messages, "stream": true, "max_tokens": 200,
            "stream_options": ["include_usage": true],
        ]
        if !local {
            // Our own words in place of OpenRouter's, which asks for cited links: the source is
            // shown under the answer instead.
            body["plugins"] = [["id": "web", "engine": engine, "max_results": 3,
                                "search_prompt": "Web search results from \(today). Use them to answer; don't name or cite the sites."]]
        }
        if engine == "native" { body["web_search_options"] = ["search_context_size": "low"] }
        AppSettings.applyModel(to: &body, service: service)

        let started = Date()
        let (status, data, lines) = try await AIService.stream(body, service: service, key: key, timeout: 30, headers: headers)
        guard status == 200 else {
            let error = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"]
            let message = (error as? [String: Any])?["message"] as? String ?? (error as? String)
                ?? String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "request failed"
            DebugLog.write("web search: HTTP \(status) \(message)")
            if service == .notch, [401, 402, 429, 502, 503].contains(status) { throw Failure(message: String(message.prefix(160))) }
            throw Failure(message: "Error \(status): \(message)")
        }

        var raw = ""
        var shown = ""
        var firstText: TimeInterval?
        var provider: String?
        var countedUsage = false
        // Claude can write a lead-in ("I'll search for today's news.") before its web search
        // tool runs: held until the search starts, then dropped.
        var holding = service == .anthropic && !local
        defer {
            if !countedUsage { Usage.record(input: Usage.estimate(json: messages) + 1500, output: Usage.estimate(raw), estimated: true) }
        }
        for try await line in lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let error = event["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "failed"
                DebugLog.write("web search: stream error \(payload.prefix(300))")
                if raw.isEmpty { throw Failure(message: "Search failed: \(message)") }
            }
            provider = provider ?? event["provider"] as? String
            if let usage = event["usage"] as? [String: Any], let input = usage["prompt_tokens"] as? Int {
                Usage.record(input: input, output: usage["completion_tokens"] as? Int ?? 0, estimated: false)
                countedUsage = true
            }
            guard let choice = (event["choices"] as? [[String: Any]])?.first else { continue }
            let delta = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any] ?? [:]
            for note in delta["annotations"] as? [[String: Any]] ?? [] {
                if let url = (note["url_citation"] as? [String: Any])?["url"] as? String ?? note["url"] as? String { sources.append(url) }
            }
            if delta["server_tool"] != nil, holding {
                if !raw.isEmpty { DebugLog.write("web search: dropped lead-in \"\(raw.prefix(80))\"") }
                raw = ""
                holding = false
                continue
            }
            guard let text = delta["content"] as? String, !text.isEmpty else { continue }
            if firstText == nil { firstText = Date().timeIntervalSince(started) }
            raw += text
            if holding { continue }
            // Emit only the part that's settled: citation marks are removed, and a "[" that
            // might start one is held until it closes.
            let clean = Self.clean(raw, final: false)
            if clean.count > shown.count, clean.hasPrefix(shown) {
                onText(String(clean.dropFirst(shown.count)))
                shown = clean
            }
        }
        let final = Self.clean(raw, final: true)
        if final.count > shown.count, final.hasPrefix(shown) { onText(String(final.dropFirst(shown.count))) }
        var seen = Set<String>()
        // The search engine itself isn't a source.
        sources = sources.filter { !($0.contains("exa.ai") || $0.contains("openrouter.ai")) && seen.insert($0).inserted }
        DebugLog.write(String(format: "web search: %@ on %@, first text %.1fs, done %.1fs, %d sources",
                              engine, provider ?? "?", firstText ?? -1, Date().timeIntervalSince(started), sources.count))

        guard !final.isEmpty else {
            DebugLog.write("web search: ended with no text")
            throw Failure(message: "Search came back empty.")
        }
        var content = final
        if !sources.isEmpty { content += "\n\nSources:\n" + sources.prefix(5).map { "- \($0)" }.joined(separator: "\n") }
        let host = sources.lazy.compactMap { URL(string: $0)?.host?.replacingOccurrences(of: "www.", with: "") }.first
        // Shown under the answer: where it came from.
        return ToolResult(content: content, display: "from \(host ?? "the web")")
    }

    /// Strips citation marks like "[1]", "[[1]](https://…)" and markdown links. Unless `final`,
    /// anything from an unclosed "[" or "(" onward is held back, since it may become one.
    static func clean(_ text: String, final: Bool) -> String {
        var t = text
        t = t.replacingOccurrences(of: #"\s*\[\[?\d+\]?\]\([^)]*\)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*\[\d+\]"#, with: "", options: .regularExpression)
        // "(formula1.com)", and site names left at the very end ("… 2026. apple.com en.wikipedia.org").
        t = t.replacingOccurrences(of: #"\s*\((?:source:\s*)?[A-Za-z0-9.-]+\.[A-Za-z]{2,}\)"#, with: "", options: .regularExpression)
        if final { t = t.replacingOccurrences(of: #"([.!?])(\s+[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+)+\s*$"#, with: "$1", options: .regularExpression) }
        // "… per [cnbc.com]", "[formula1.com]": a site named in brackets.
        t = t.replacingOccurrences(of: #"(,?\s+(per|via|from|according to))?\s*\[[A-Za-z0-9.-]+\.[A-Za-z]{2,}(/[^\]]*)?\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "**", with: "")
        t = t.replacingOccurrences(of: #"\s*\n+\s*"#, with: " ", options: .regularExpression)  // one paragraph for the notch
        if !final, let open = t.lastIndex(where: { $0 == "[" || $0 == "(" }),
           !t[open...].contains(where: { $0 == "]" || $0 == ")" }) {
            t = String(t[..<open])
        }
        if final { while t.last?.isWhitespace == true { t.removeLast() } }
        return t
    }
}
