import Foundation

/// Every AI request goes out through here, to whichever service answers (Settings → Answers):
/// Starlight Pro, your own OpenRouter, Anthropic or OpenAI key, or Ollama on your Mac.
///
/// Callers build one shape, OpenAI's chat completions (what OpenRouter, OpenAI, Ollama and Pro
/// take as is), and read one shape back. For Anthropic the request becomes a Messages API one,
/// and its reply and its stream are turned back into chat completions here, so nothing else
/// needs to know which service answered.
enum AIService {
    typealias Service = AppSettings.AnswerService

    /// Set by `AppSettings.applyModel` for the services that think differently from OpenRouter
    /// (Anthropic, OpenAI): "high" for deep answers. Taken out before the request goes.
    static let thinkingKey = "starlight_thinking"

    /// One request and its whole reply (chat completions' shape), with the HTTP status.
    static func send(_ body: [String: Any], service: Service, key: String, timeout: TimeInterval,
                     headers: [String: String] = [:]) async throws -> (Data, Int) {
        let request = try make(body, service: service, key: key, timeout: timeout, stream: false, headers: headers)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard service == .anthropic, status == 200 else { return (data, status) }
        return (Anthropic.reply(data), status)
    }

    /// A streamed request: the HTTP status, the start of the error's body when it isn't 200, and
    /// the reply's `data:` lines (chat completions' shape, ending with `data: [DONE]`).
    static func stream(_ body: [String: Any], service: Service, key: String, timeout: TimeInterval,
                       headers: [String: String] = [:]) async throws -> (status: Int, error: Data, lines: AsyncThrowingStream<String, Error>) {
        var body = body
        body["stream"] = true
        let request = try make(body, service: service, key: key, timeout: timeout, stream: true, headers: headers)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > 4000 { break } }
            return (status, data, AsyncThrowingStream { $0.finish() })
        }
        let lines = service == .anthropic ? Anthropic.lines(bytes) : AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (status, Data(), lines)
    }

    /// Opens the connection ahead of time (TLS and HTTP/2 setup), so a first question doesn't pay for it.
    static func warmUp(_ service: Service) {
        guard service != .ollama else { return }
        URLSession.shared.dataTask(with: URLRequest(url: service.endpoint.deletingLastPathComponent(), timeoutInterval: 10)).resume()
    }

    // MARK: The request

    private static func make(_ body: [String: Any], service: Service, key: String, timeout: TimeInterval,
                             stream: Bool, headers: [String: String]) throws -> URLRequest {
        var body = body
        let deep = body.removeValue(forKey: thinkingKey) as? String == "high"
        var request = URLRequest(url: service.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        switch service {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = Anthropic.body(body, deep: deep)
        case .openai:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = openAI(body, deep: deep)
        case .ollama:
            body = plain(body)
        case .openrouter, .notch:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("Starlight", forHTTPHeaderField: "X-Title")
            body["messages"] = (body["messages"] as? [[String: Any]])?.map { $0.filter { $0.key != "reasoning_blocks" } }
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Chat completions without OpenRouter's own fields (routing, reasoning, its web plugin) and
    /// with the system prompt as plain text, for a service that takes only the standard ones.
    private static func plain(_ body: [String: Any]) -> [String: Any] {
        var body = body
        for field in ["provider", "reasoning", "plugins", "web_search_options"] { body[field] = nil }
        body["messages"] = (body["messages"] as? [[String: Any]])?.map { message in
            var message = message.filter { $0.key != "reasoning_blocks" }
            if let blocks = message["content"] as? [[String: Any]], blocks.allSatisfy({ $0["type"] as? String == "text" }) {
                message["content"] = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            }
            return message
        }
        return body
    }

    /// OpenAI: its reasoning models (o-series, GPT-5) take no temperature, count their thinking
    /// against `max_completion_tokens` (so they get room for it), and think little unless asked.
    private static func openAI(_ body: [String: Any], deep: Bool) -> [String: Any] {
        var body = plain(body)
        body["temperature"] = nil
        var limit = body.removeValue(forKey: "max_tokens") as? Int ?? 2000
        let model = body["model"] as? String ?? ""
        if model.hasPrefix("o") || model.hasPrefix("gpt-5") {
            body["reasoning_effort"] = deep ? "high" : "low"
            limit += deep ? 16000 : 4000
        }
        body["max_completion_tokens"] = limit
        return body
    }

    // MARK: Anthropic

    /// Anthropic's Messages API, in and out.
    enum Anthropic {
        /// Chat completions → Messages: the system prompt on its own, tool calls and their results
        /// as blocks (results from one step in one message), tools as input schemas.
        static func body(_ body: [String: Any], deep: Bool) -> [String: Any] {
            let model = body["model"] as? String ?? ""
            var out: [String: Any] = ["model": model, "max_tokens": body["max_tokens"] as? Int ?? 4096]
            if body["stream"] as? Bool == true { out["stream"] = true }
            var system: [[String: Any]] = []
            var messages: [[String: Any]] = []
            func add(_ role: String, _ blocks: [[String: Any]]) {
                guard !blocks.isEmpty else { return }
                if messages.last?["role"] as? String == role, let earlier = messages.last?["content"] as? [[String: Any]] {
                    messages[messages.count - 1]["content"] = earlier + blocks
                } else {
                    messages.append(["role": role, "content": blocks])
                }
            }
            for message in body["messages"] as? [[String: Any]] ?? [] {
                switch message["role"] as? String {
                case "system":
                    system += textBlocks(message["content"])
                case "assistant":
                    var blocks = message["reasoning_blocks"] as? [[String: Any]] ?? []
                    blocks += textBlocks(message["content"])
                    for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                        let function = call["function"] as? [String: Any] ?? [:]
                        let arguments = (function["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                        blocks.append(["type": "tool_use", "id": call["id"] as? String ?? "call", "name": function["name"] as? String ?? "",
                                       "input": arguments as? [String: Any] ?? [:]])
                    }
                    add("assistant", blocks)
                case "tool":
                    let content = (message["content"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(empty)"
                    add("user", [["type": "tool_result", "tool_use_id": message["tool_call_id"] as? String ?? "call", "content": content]])
                default:
                    add("user", textBlocks(message["content"]))
                }
            }
            if !system.isEmpty { out["system"] = system }
            out["messages"] = messages

            var tools: [[String: Any]] = (body["tools"] as? [[String: Any]] ?? []).compactMap { tool in
                guard let function = tool["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
                return ["name": name, "description": function["description"] as? String ?? "",
                        "input_schema": function["parameters"] as? [String: Any] ?? ["type": "object", "properties": [String: Any]()]]
            }
            // OpenRouter's web plugin → Claude's own web search.
            if let plugins = body["plugins"] as? [[String: Any]], plugins.contains(where: { $0["id"] as? String == "web" }) {
                tools.append(["type": model.contains("haiku") ? "web_search_20250305" : "web_search_20260209", "name": "web_search", "max_uses": 2])
            }
            if !tools.isEmpty {
                out["tools"] = tools
                out["tool_choice"] = ["type": "auto"]
            }

            // Thinking: as little as the model allows for everyday answers, a lot for deep ones.
            // Effort is the control on current models; Haiku can turn thinking off, Sonnet 5.5 only
            // between tool calls, Opus and Fable always think (at low effort, briefly).
            if takesEffort(model) { out["output_config"] = ["effort": deep ? "high" : "low"] }
            if deep {
                out["max_tokens"] = max(out["max_tokens"] as? Int ?? 0, 16000)
            } else if model.contains("haiku-5") {
                out["thinking"] = ["type": "disabled"]
            } else if model.contains("sonnet-5-5") {
                out["thinking"] = ["type": "between_tools"]
            }
            return out
        }

        /// Text, as Messages' blocks: a string, or chat completions' parts (cache marks kept).
        private static func textBlocks(_ content: Any?) -> [[String: Any]] {
            if let text = content as? String { return text.isEmpty ? [] : [["type": "text", "text": text]] }
            return (content as? [[String: Any]] ?? []).compactMap { part in
                guard part["type"] as? String == "text", let text = part["text"] as? String, !text.isEmpty else { return nil }
                var block: [String: Any] = ["type": "text", "text": text]
                if let cache = part["cache_control"] { block["cache_control"] = cache }
                return block
            }
        }

        /// The models that take an effort level (the 4.6 family and everything since).
        private static func takesEffort(_ model: String) -> Bool {
            model.range(of: #"claude-(opus|sonnet|haiku|fable|mythos)-5|claude-opus-4-[5-8]|claude-sonnet-4-6"#, options: .regularExpression) != nil
        }

        /// A whole Messages reply → chat completions.
        static func reply(_ data: Data) -> Data {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
            var text = ""
            var calls: [[String: Any]] = []
            var notes: [[String: Any]] = []
            for block in json["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    text += block["text"] as? String ?? ""
                    notes += (block["citations"] as? [[String: Any]] ?? []).compactMap(annotation)
                case "tool_use":
                    calls.append(["id": block["id"] ?? "", "type": "function",
                                  "function": ["name": block["name"] ?? "", "arguments": jsonString(block["input"] ?? [String: Any]())]])
                default: break
                }
            }
            var message: [String: Any] = ["role": "assistant", "content": text]
            if !calls.isEmpty { message["tool_calls"] = calls }
            if !notes.isEmpty { message["annotations"] = notes }
            var out: [String: Any] = ["model": json["model"] ?? "", "choices": [["index": 0, "message": message]]]
            if let usage = json["usage"] as? [String: Any] { out["usage"] = Self.usage(usage, output: usage["output_tokens"] as? Int ?? 0) }
            if json["stop_reason"] as? String == "refusal" { out["error"] = ["message": "The model declined to answer that."] }
            return (try? JSONSerialization.data(withJSONObject: out)) ?? data
        }

        /// Messages' stream → chat completions' `data:` lines. Thinking blocks come back whole, as
        /// `reasoning_blocks`, so the next step of a tool loop can send them back.
        static func lines(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    func emit(_ delta: [String: Any]) { continuation.yield("data: " + jsonString(["choices": [["index": 0, "delta": delta]]])) }
                    var tools: [Int: Int] = [:]
                    var thinking: [Int: [String: Any]] = [:]
                    var usage: [String: Any] = [:]
                    do {
                        for try await line in bytes.lines {
                            guard line.hasPrefix("data:"),
                                  let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
                            else { continue }
                            let index = event["index"] as? Int ?? 0
                            switch event["type"] as? String {
                            case "message_start":
                                usage = (event["message"] as? [String: Any])?["usage"] as? [String: Any] ?? [:]
                            case "content_block_start":
                                let block = event["content_block"] as? [String: Any] ?? [:]
                                switch block["type"] as? String {
                                case "tool_use":
                                    let n = tools.count
                                    tools[index] = n
                                    emit(["tool_calls": [["index": n, "id": block["id"] ?? "", "type": "function",
                                                          "function": ["name": block["name"] ?? "", "arguments": ""]]]])
                                case "thinking": thinking[index] = ["type": "thinking", "thinking": "", "signature": ""]
                                case "redacted_thinking": thinking[index] = block
                                case "text": if let text = block["text"] as? String, !text.isEmpty { emit(["content": text]) }
                                // Claude's own web search starting: anything it wrote before is lead-in.
                                case "server_tool_use": emit(["server_tool": block["name"] ?? ""])
                                default: break
                                }
                            case "content_block_delta":
                                let delta = event["delta"] as? [String: Any] ?? [:]
                                switch delta["type"] as? String {
                                case "text_delta": emit(["content": delta["text"] as? String ?? ""])
                                case "input_json_delta":
                                    if let n = tools[index] { emit(["tool_calls": [["index": n, "function": ["arguments": delta["partial_json"] as? String ?? ""]]]]) }
                                case "thinking_delta":
                                    let so = thinking[index]?["thinking"] as? String ?? ""
                                    thinking[index]?["thinking"] = so + (delta["thinking"] as? String ?? "")
                                case "signature_delta": thinking[index]?["signature"] = delta["signature"] as? String ?? ""
                                case "citations_delta":
                                    if let note = (delta["citation"] as? [String: Any]).flatMap(annotation) { emit(["annotations": [note]]) }
                                default: break
                                }
                            case "content_block_stop":
                                if let block = thinking.removeValue(forKey: index) { emit(["reasoning_blocks": [block]]) }
                            case "message_delta":
                                let output = (event["usage"] as? [String: Any])?["output_tokens"] as? Int ?? 0
                                if (event["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" {
                                    continuation.yield("data: " + jsonString(["error": ["message": "The model declined to answer that."]]))
                                }
                                continuation.yield("data: " + jsonString(["choices": [[String: Any]](), "usage": Self.usage(usage, output: output)]))
                            case "error":
                                continuation.yield("data: " + jsonString(["error": event["error"] ?? ["message": "The answer stopped partway"]]))
                            case "message_stop":
                                continuation.yield("data: [DONE]")
                            default: break
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        /// Messages' usage → chat completions' (cached tokens count as input, as OpenRouter counts them).
        private static func usage(_ usage: [String: Any], output: Int) -> [String: Any] {
            let read = usage["cache_read_input_tokens"] as? Int ?? 0
            let written = usage["cache_creation_input_tokens"] as? Int ?? 0
            return ["prompt_tokens": (usage["input_tokens"] as? Int ?? 0) + read + written, "completion_tokens": output,
                    "prompt_tokens_details": ["cached_tokens": read]]
        }

        /// A web search citation → chat completions' url_citation.
        private static func annotation(_ citation: [String: Any]) -> [String: Any]? {
            guard let url = citation["url"] as? String else { return nil }
            return ["type": "url_citation", "url_citation": ["url": url, "title": citation["title"] as? String ?? ""]]
        }
    }

    private static func jsonString(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: Models

    /// The models a service offers, for the picker in Settings → Answers: OpenRouter's public
    /// list, Anthropic's and OpenAI's with your key, and what Ollama has pulled.
    static func models(_ service: Service, key: String?) async -> [String] {
        let url: URL
        var request: URLRequest
        switch service {
        case .notch: return []
        case .openrouter: url = URL(string: "https://openrouter.ai/api/v1/models")!
        case .anthropic: url = URL(string: "https://api.anthropic.com/v1/models?limit=100")!
        case .openai: url = URL(string: "https://api.openai.com/v1/models")!
        case .ollama: url = AppSettings.shared.ollamaBase.appendingPathComponent("api/tags")
        }
        request = URLRequest(url: url, timeoutInterval: 15)
        if let key, !key.isEmpty {
            if service == .anthropic {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else if service != .ollama {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let entries = json["data"] as? [[String: Any]] ?? json["models"] as? [[String: Any]] ?? []
        var ids = entries.compactMap { $0["id"] as? String ?? $0["name"] as? String }
        // OpenAI lists every model it has (speech, images, embeddings): only the chat ones.
        if service == .openai {
            ids = ids.filter { ($0.hasPrefix("gpt-") || $0.hasPrefix("o")) && !$0.contains("audio") && !$0.contains("realtime")
                && !$0.contains("transcribe") && !$0.contains("tts") && !$0.contains("image") && !$0.contains("search") }
        }
        return service == .anthropic ? ids : ids.sorted()
    }
}
