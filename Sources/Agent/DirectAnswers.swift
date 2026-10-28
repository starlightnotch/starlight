import Foundation

/// Requests plain enough to need no model: done on the Mac in milliseconds instead of a
/// round trip of half a second to three seconds.
///
/// - "Remember that the launch is March 12" → `remember`
/// - "Add call mom to my to-do list" → `add_todo`
/// - "What's 15 times 23 plus 7?" → the calculator, answer shown big
///
/// Only your own words, only one clear request; anything else goes to the agent as before.
enum DirectAnswers {
    /// True when it handled the request (and emitted the answer).
    static func handle(_ request: AgentRequest, said: String, api: ExtensionAPI,
                       emit: @escaping (Agent.Event) -> Void) async throws -> Bool {
        // Yours alone: a line from the other side of the call never runs anything directly.
        guard request.focus == nil, !request.unanswered.contains("Them") else { return false }
        let text = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 220 else { return false }
        let tools = Dictionary(api.tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        if let tool = tools["remember"], let fact = rememberFact(text) {
            return try await run(tool, ["fact": fact], emit: emit)
        }
        if let tool = tools["add_todo"], let title = todoTitle(text) {
            return try await run(tool, ["title": title], emit: emit)
        }
        // "Go silent", "you can answer again": silent mode on or off, at once.
        if let on = SilentMode.command(text) {
            try await HeadStart.waitForReveal()
            await MainActor.run { AppSettings.shared.silentMode = on }
            emit(.outcome(.done(on ? "Silent mode on: listening only" : "Silent mode off: answering again")))
            DebugLog.write("agent: silent mode \(on ? "on" : "off") directly")
            return true
        }
        // "Is Wi-Fi on?", "what's my battery at": read off the Mac, no model.
        if tools["mac_control"] != nil, let reply = MacControls.answer(text) {
            try await HeadStart.waitForReveal()
            emit(.text(reply))
            DebugLog.write("agent: Mac status directly: \(reply)")
            return true
        }
        // "Turn on dark mode", "volume to 30", "keep my Mac awake for an hour".
        if let tool = tools["mac_control"], let control = MacControls.parse(text) {
            return try await run(tool, ["action": control.action, "value": control.value], emit: emit)
        }
        // "Open Safari", "launch Notes": an installed app, opened at once.
        if let tool = tools["open_item"], let app = appToOpen(text) {
            return try await run(tool, ["target": app], emit: emit)
        }
        if tools["calculate"] != nil, let expression = SpokenMath.expression(text),
           let result = try? Calculator.evaluate(expression) {
            let started = Date()
            emit(.text(result.text + "."))
            emit(.tool(result.display))
            Trace.current?.span(.tools, "Calculator", from: started, path: "direct")
            DebugLog.write("agent: calculated directly: \(expression) = \(result.text)")
            return true
        }
        return false
    }

    private static func run(_ tool: AgentTool, _ args: [String: Any], emit: @escaping (Agent.Event) -> Void) async throws -> Bool {
        try await HeadStart.waitForReveal()  // not on half a sentence
        emit(.status(tool.status, tool.glyph))
        let started = Date()
        let result = try await tool.run(args)
        Trace.current?.span(.tools, tool.name, from: started, path: "direct")
        DebugLog.write("agent: \(tool.name) directly \(args) → \(result.content.prefix(120))")
        if let outcome = result.outcome { emit(.outcome(outcome)) } else { emit(.text(result.content)) }
        return true
    }

    /// "Open Safari", "can you launch Notes", "open up Spotify": the app's name, if it's installed.
    static func appToOpen(_ text: String) -> String? {
        guard !text.contains("?") else { return nil }
        let pattern = #"^(?:(?:hey|ok|okay),?\s+(?:starlight|star light|notch),?\s+)?(?:please\s+)?(?:can you\s+|could you\s+)?(?:open|launch|start|bring up|pull up)\s+(?:up\s+)?(?:the\s+|my\s+)?(.{2,40}?)(?:\s+app)?(?:\s+(?:for me|please))?[.!]*$"#
        guard let name = capture(pattern, text), !name.contains("/"), name.split(separator: " ").count <= 4,
              let url = MacFiles.application(named: name) else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    /// "Remember that X", "note that X", "remember X". Not questions ("remember what she said?").
    static func rememberFact(_ text: String) -> String? {
        guard !text.contains("?") else { return nil }
        let pattern = #"^(?:(?:hey|ok|okay),?\s+(?:starlight|star light|notch),?\s+)?(?:please\s+)?(?:can you\s+)?(?:remember|note|keep in mind|don't forget)\s+(?:that\s+)?(.{4,200}?)[.!]*$"#
        guard let fact = capture(pattern, text) else { return nil }
        let lower = fact.lowercased()
        // "Remember what…", "remember to…" are questions or reminders, not facts.
        if lower.range(of: #"^(what|when|where|who|why|how|if|whether|to)\b"#, options: .regularExpression) != nil { return nil }
        return sentence(fact)
    }

    /// "Add X to my to-do list", "put X on my list", "add X to reminders".
    static func todoTitle(_ text: String) -> String? {
        guard !text.contains("?") else { return nil }
        let pattern = #"^(?:(?:hey|ok|okay),?\s+(?:starlight|star light|notch),?\s+)?(?:please\s+)?(?:can you\s+)?(?:add|put)\s+(.{2,120}?)\s+(?:to|on|in|onto)\s+(?:my\s+|the\s+)?(?:to-?do(?:\s+list)?|todos|todo\s+list|reminders|list)(?:\s+please)?[.!]*$"#
        guard let title = capture(pattern, text) else { return nil }
        var result = title.trimmingCharacters(in: .whitespaces)
        if result.lowercased().hasPrefix("a reminder to ") { result = String(result.dropFirst(14)) }
        return result.prefix(1).uppercased() + result.dropFirst()
    }

    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }

    private static func sentence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.prefix(1).uppercased() + s.dropFirst()
        if let last = s.last, !".!".contains(last) { s += "." }
        return s
    }
}

/// Spoken arithmetic to an expression: "15 times 23 plus 7" → "15*23+7". Nil unless what's left
/// is nothing but numbers and operators, so "what's 2 plus 2 in binary" goes to the agent.
enum SpokenMath {
    static func expression(_ text: String) -> String? {
        var s = " " + text.lowercased() + " "
        s = s.replacingOccurrences(of: #"[?!]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\d),(\d{3})"#, with: "$1$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\d),(\d{3})"#, with: "$1$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\.\s*$"#, with: " ", options: .regularExpression)
        // The question around it.
        let lead = #"^\s*(?:(?:hey|ok|okay),?\s+(?:starlight|star light|notch),?\s+)?(?:so\s+)?(?:what\s+is|what's|whats|what\s+does|what\s+do\s+you\s+get\s+for|how\s+much\s+is|calculate|compute|work\s+out|tell\s+me|quick(?:ly)?,?)\s+"#
        guard s.range(of: lead, options: .regularExpression) != nil || s.range(of: #"^\s*[\d(]"#, options: .regularExpression) != nil else { return nil }
        s = s.replacingOccurrences(of: lead, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s(?:equal|equals|is)\s*$"#, with: " ", options: .regularExpression)
        let words: [(String, String)] = [
            (#"\bmultiplied by\b"#, "*"), (#"\btimes\b"#, "*"), (#"(?<=\d)\s*x\s*(?=\d)"#, "*"), ("×", "*"),
            (#"\bdivided by\b"#, "/"), (#"\bover\b"#, "/"), ("÷", "/"),
            (#"\bplus\b"#, "+"), (#"\bminus\b"#, "-"), (#"\bless\b"#, "-"),
            (#"\bto the power of\b"#, "^"), (#"\bsquared\b"#, "^2"), (#"\bcubed\b"#, "^3"),
            (#"\bpercent of\b"#, "% *"), (#"%\s*of\b"#, "% *"), (#"\bpercent\b"#, "%"),
            (#"\b(?:the\s+)?square root of\s+([\d.]+)"#, "sqrt($1)"),
        ]
        for (pattern, replacement) in words {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        let expression = s.trimmingCharacters(in: .whitespaces)
        // Only numbers, operators, brackets and sqrt; at least one operator between two numbers.
        guard expression.range(of: #"^[\d\s.+\-*/^%()]*(sqrt\([\d.]+\)[\d\s.+\-*/^%()]*)*$"#, options: .regularExpression) != nil,
              expression.range(of: #"(\d|\))\s*[+\-*/^%]"#, options: .regularExpression) != nil
                || expression.contains("sqrt(") else { return nil }
        return expression
    }
}

/// Silent mode's words: the commands that switch it, and being spoken to ("Starlight, …"; the old
/// name "Notch" still counts).
enum SilentMode {
    /// On, off, or nil when the text isn't about silent mode.
    static func command(_ text: String) -> Bool? {
        let t = " " + text.lowercased().replacingOccurrences(of: #"[^a-z' ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) + " "
        guard text.count < 80 else { return nil }
        // A command on its own ("Go silent.", "You can answer again."), or said to Starlight by name:
        // "we should stop talking about pricing" in a meeting isn't one.
        let words = t.split(separator: " ").filter { !["starlight", "star", "light", "notch", "please", "hey", "ok", "okay", "now", "for"].contains($0) }
        guard words.count <= 5 || spokenTo(text) else { return nil }
        func has(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        if has(#"\b(turn off|stop|end|disable|exit|leave|no more) (the )?silent( mode)?\b"#) || has(#"\bsilent mode off\b"#)
            || has(#"\b(you can|go ahead and|please) (answer|talk|speak|respond)\b"#) || has(#"\b(start|resume) (answering|responding|talking)\b"#)
            || has(#"\banswer again\b"#) || has(#"\bunmute (yourself|answers|starlight|notch)\b"#) { return false }
        if has(#"\b(go|be|stay) (silent|quiet)\b"#) || has(#"\b(turn on|enable|start) (the )?silent( mode)?\b"#) || has(#"\bsilent mode( on)?\b"#)
            || has(#"\b(stop|don't|do not) (answering|responding|talking|interrupting)\b"#) || has(#"\bmute (yourself|answers|starlight|notch)\b"#)
            || has(#"\bjust (listen|take notes)\b"#) { return true }
        return nil
    }

    /// "Starlight, what's ARR?", "hey Starlight …", "… right, Starlight?": the user is talking to Starlight.
    static func spokenTo(_ text: String) -> Bool {
        let t = text.lowercased()
        // "Starlight" (or how speech-to-text sometimes hears it); "Notch", its old name, still works.
        let name = #"(?:starlight|star light|starlite|notch)"#
        return t.range(of: #"^\W*(hey |hi |ok |okay |yo )?"# + name + #"\b"#, options: .regularExpression) != nil
            || t.range(of: #"\b(hey|ok|okay) "# + name + #"\b"#, options: .regularExpression) != nil
            || t.range(of: #",\s*"# + name + #"\W*$"#, options: .regularExpression) != nil
    }
}
