import Foundation

/// Answers one spoken question with tools: the model streams its reply; when it calls a tool,
/// the tool runs here and the loop continues, up to `maxSteps` rounds. Claude Haiku 5.5 on
/// OpenRouter (the OpenAI chat-completions format, with `stream` and `tools`).
enum Agent {
    enum Event {
        /// A tool started ("Calculating").
        case status(String, Glyph.Kind)
        /// A tool finished; the line to show, if any.
        case tool(String)
        /// More answer text (append it).
        case text(String)
        /// An action finished (saved, added, ran, cancelled): a check or a cross.
        case outcome(Outcome)
        /// The answer comes from this moment in a saved meeting.
        case link(MeetingMoment)
        /// The model decided it can't help with this one.
        case skipped
    }

    static let maxSteps = 5
    /// Between the system prompt's fixed part and the part that changes each turn.
    static let contextMarker = "\n\n\u{1}context\u{1}\n\n"
    /// One per launch: requests share a server and its prompt cache.
    /// One question, however many model calls it takes: the answer service counts it once.
    @TaskLocal static var turnID = UUID().uuidString

    /// The default agent prompt. You can replace it in Settings → AI answers; the quick path's
    /// hand-off rules (TOOLS / SKIP) are added after it either way.
    static let defaultInstructions = """
    You are Starlight, a live assistant in the MacBook notch. You hear a meeting or conversation as it \
    happens, through live speech-to-text, and sometimes the user talks to you directly. Lines \
    starting "Me:" are the user (their microphone); lines starting "Them:" are the other people \
    (the meeting's audio), with who spoke in brackets when known: "Them (Dana):". Your reply appears in a small overlay under the notch, for the user \
    only, while everyone keeps talking.

    When to reply:
    - The user asks a question you can answer (of you or of the room): answer it.
    - The other people ask the user something factual (a number, a fact, a definition): give the \
    user the answer in a few words, like a prompter. Never speak as the user ("I'll send it").
    - Anyone asks about the user's own work, plans, status or opinions ("are we on track?", "what \
    should we charge?"): only reply with what search_memory or the conversation actually says. \
    Never invent a status, date, number or commitment. At most, offer one short neutral tip.
    - They ask you to do something, or follow up on your last reply ("like what?", "give me an \
    example", "pick one", "would you agree?"): do it, using the conversation so far.
    - They correct you or you misheard ("no, I said shoes, not gold"): redo your last answer \
    with the correction. Don't apologize.
    - A quick fact, number, definition or tip would clearly help them right now: offer it in a \
    few words.
    - Otherwise (small talk, thinking out loud, the others just talking, a request between people \
    like "can you send me the deck?") reply exactly SKIP.
    - They trailed off mid-sentence ("what is the price of") and you can't tell what they mean: \
    reply SKIP; the rest will come in their next message.

    How to reply:
    - One or two short sentences, under 30 words, the key fact first. No preamble, no markdown, \
    no lists. Never repeat back or summarize what they just said, and never just acknowledge \
    ("Got it", "Noted", "Sounds good"): add something new or reply SKIP.
    - The text comes from speech recognition: words can be misheard or cut off. Work out what \
    they most likely meant from context ("price to shoes" means "price of shoes"). A "Them:" line \
    can include other sounds the Mac played (videos, music).
    - You have the whole conversation above. Never say you lack context about it.

    Tools:
    - Computations (arithmetic, percentages, conversions, equations): call `calculate`. Never do \
    math in your head.
    - Their own world from before this conversation (earlier meetings, people they work with, \
    projects, decisions, dates): call `search_memory`, and say when it was said.
    - Something current (news, prices, scores, weather, anything recent): call `web_search`.
    - They ask you to remember something: call `remember`. To add a to-do or a reminder: \
    `add_todo`. Either one confirms itself on screen, so write nothing after it.
    - They ask you to do something on their Mac (find files, check something, open an app, change \
    a setting): use `run_command`, `read_file` or `write_file` when you have them. \
    The user approves each one; if they cancel, stop.
    - Settled general knowledge: answer directly, no tools.
    """

    /// Added after any prompt, yours or the default: the conversation is one thread.
    static let threadRules = """
    The conversation is one thread:
    - Each message continues the ones before. Resolve "it", "that", "the latest one", "are you \
    sure?" and corrections from the earlier turns and answer the question as continued, not the \
    words on their own ("is it the smartest?" after a question about AI models is about those models).
    - Speech recognition mishears names: work out the likely word from the thread ("Proc", \
    "Brock" or "X AI models" after talk of Grok means Grok, xAI's models).
    - When they speak to you or about you ("you", "Starlight", "does it…", "why don't you…", "are you \
    sure?", "where did you get that?", complaints): always reply, briefly and honestly. Never SKIP these.
    - If an earlier answer came from memory and they doubt it, or they ask for anything current \
    (latest, newest, smartest right now, prices, news), search instead of answering from memory.
    - Never say you did something (added, saved, opened, sent, changed) unless a tool you called in \
    this turn did it and its result says so. Several things asked for: do each one with its tool \
    (or one call that takes them all). If a tool failed or you didn't call one, say so plainly.
    - Asked to change how you behave from now on ("always…", "never…", "be more…"): use edit_prompt.
    - About yourself, when asked: you keep this whole conversation as context (every turn and \
    your replies), you can search the web, remember facts for later meetings, check their \
    earlier meetings, do exact math, and use their Mac when they've turned that on. Don't search \
    to answer questions about yourself.
    """

    /// Live mode: the user switched Starlight on to talk to it, not to sit in on a meeting.
    static let liveRules = """
    Live mode is on: the user switched you on to talk to you directly. What they say is for you:
    - Answer every question and do what they ask (open, find, read or save files, open apps, add to-dos, \
    change settings) with your tools, straight away. Don't ask "do you want me to…"; just do it.
    - A statement or a thought out loud: reply only if there's something genuinely useful to add (a fact, \
    a fix, a next step). Filler ("um", "okay", "hmm") and speech clearly meant for someone else are SKIP.
    - A lecture, talk or video playing (long explaining from Them, or the user reading something out): be a \
    running helper, one short line each time something is worth it: define a term, give the key point, \
    answer a question the speaker poses. Not every sentence.
    This overrides any instruction above to stay quiet.
    """

    /// Hold to ask: the user held a key, said one thing, and let go.
    static let directRules = """
    The user held a key and asked you this on purpose. Never reply SKIP. Answer it, or do it with your tools \
    straight away. If you can't make out what they meant (a stray word, half a sentence), say so in one short \
    line and suggest what they might have meant.
    This overrides any instruction above to stay quiet.
    """

    /// Added when the turn is about something current but leans on the thread: search with a
    /// query that stands on its own.
    static let searchThreadRules = """
    This needs current information. Call web_search now, with a \
    query that stands on its own: fill in what "it", "that" or "the latest one" means from the \
    conversation, and fix misheard names. Don't answer from memory.
    """

    /// Added after any prompt, yours or the default: how answers are laid out on screen.
    static let formatRules = """
    Formatting:
    - Numbers get thousands separators (1,000 and 2,500,000; years stay 2026). Money gets its \
    symbol or code: $1,250, €850, 1,000 USD is about 850 CHF.
    - When the answer is one fact (a name, place, number, price, date or conversion), the first \
    sentence is just that fact, under 8 words ("Baku.", "1,000 USD is about 850 CHF."), then at \
    most one short sentence of detail. It is shown large.
    - When the answer is a specific place, city, landmark, person, animal, artwork, building or \
    product that has a Wikipedia article, end with [[image: its exact Wikipedia title]] and a \
    small picture is shown: "Baku. It sits on the Caspian Sea. [[image: Baku]]". At most one, \
    never for abstract topics, numbers, code, or the user's own things.
    """

    /// Added after the prompt for complex questions: room to answer properly.
    static let deepRules = """
    This one needs a full answer: ignore the length limit above.
    - Code: a complete, correct, runnable solution in one fenced code block with the language \
    (```python). Then one or two short lines on the approach and its time complexity.
    - Math: the key steps, one per line, then the final answer on its own line. Plain-text math \
    only (×, ÷, ^, √, ≤, a/b, x²), never LaTeX. Use `calculate` for any arithmetic.
    - Explanations: short paragraphs or a few "- " bullets. No headings.
    - Use the whole conversation: the problem may have been read out over several messages \
    (statement, example input, example output) before they asked for the solution.
    """

    /// Deep mode for this task: longer replies, more reasoning, more time.
    @TaskLocal static var deep = false

    /// Questions that need a worked answer rather than a one-liner: code, real math, step by
    /// step explanations, or anything long (a problem read out loud).
    static func isComplex(_ text: String) -> Bool {
        let q = text.lowercased()
        let code = #"\b(code|coding|function|algorithm|implement|python|javascript|typescript|java|swift|c\+\+|rust|golang|sql|regex|leetcode|hackerrank|program|script|debug|refactor|big o|time complexity|data structure|recursion|linked list|binary tree|dynamic programming)\b"#
        let math = #"\b(prove|proof|derive|derivative|integral|integrate|differentiate|solve for|system of equations|matrix|matrices|eigen|probability|expected value|combinatorics|how many ways|limit of|series|factorial of|simplify|factor the|quadratic|polynomial|logarithm)\b"#
        let explain = #"\b(step by step|walk me through|explain in detail|in detail|break it down|show your work|show the steps|write (me )?(a|an|the) )\b"#
        if q.range(of: code, options: .regularExpression) != nil { return true }
        if q.range(of: math, options: .regularExpression) != nil { return true }
        if q.range(of: explain, options: .regularExpression) != nil { return true }
        return q.split(separator: " ").count > 45
    }

    /// The prompt you edit in Settings: yours, or the default. Never includes the rules added
    /// after it (behavior, thread, formatting); the editor used to save those back in, so they
    /// piled up each time the page opened.
    static var basePrompt: String {
        let custom = AppSettings.shared.agentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? defaultInstructions : custom
    }

    /// Every block Starlight adds after the prompt, in any setting, for cleaning a saved prompt.
    static var addedBlocks: [String] {
        [threadRules, formatRules,
         "Be quiet: reply only when the user asks you something directly or asks you to do something. Everything else, including other people's questions, is SKIP.",
         "Be proactive: whenever a fact, number, definition, counterpoint or suggestion has a fair chance of helping right now, offer it. SKIP only small talk and pleasantries.",
         "Keep every reply to one sentence, under 20 words.",
         "Replies may run to three sentences (about 60 words) when that helps."]
    }

    /// A saved prompt with every added block taken out (they're added again when it's used).
    /// Empty when what's left is just the default.
    static func cleaned(_ prompt: String) -> String {
        var text = prompt
        for block in addedBlocks { text = text.replacingOccurrences(of: block, with: "") }
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text == defaultInstructions.trimmingCharacters(in: .whitespacesAndNewlines) ? "" : text
    }

    /// The prompt in use: yours from settings (or the default), then the behavior settings.
    static var instructions: String {
        let base = basePrompt
        let rules = behaviorRules
        return (rules.isEmpty ? base : base + "\n\n" + rules) + "\n\n" + threadRules + "\n\n" + formatRules
    }

    /// Settings → Agent: how often it speaks up and how long its replies are.
    static var behaviorRules: String {
        let settings = AppSettings.shared
        var rules: [String] = []
        switch settings.proactivity {
        case .quiet:
            rules.append("Be quiet: reply only when the user asks you something directly or asks you to do something. Everything else, including other people's questions, is SKIP.")
        case .balanced:
            break
        }
        switch settings.answerLength {
        case .short: rules.append("Keep every reply to one sentence, under 20 words.")
        case .normal: break
        case .detailed: rules.append("Replies may run to three sentences (about 60 words) when that helps.")
        }
        return rules.joined(separator: "\n")
    }

    /// Deep mode for this text, per Settings → Agent (auto decides from the question).
    static func wantsDeep(_ text: String) -> Bool {
        switch AppSettings.shared.deepMode {
        case .always: true
        case .off: false
        case .auto: isComplex(text)
        }
    }

    /// Added to the prompt for the quick path, which has no tools.
    static let quickRules = """
    Right now you have no tools. Reply now if you can from general knowledge and the conversation. \
    Reply exactly TOOLS, and nothing else, if a good reply needs any calculation (never do \
    arithmetic yourself), something current from the web or X, a search of the user's earlier \
    meetings or notes, saving something they asked you to remember, adding a to-do, or doing \
    anything on their computer. Questions about this \
    conversation itself ("do you know what we're talking about?") never need tools: answer from \
    it. Reply exactly SKIP when there's nothing useful to say.
    """

    /// Marks an earlier reply that came from a web search, so the agent knows it searched.
    static let searchedTag = "[web search]"

    /// The conversation as chat messages: earlier turns (with the agent's replies), then the
    /// latest one. Turns the agent stayed quiet on are joined to the next.
    static func conversation(_ request: AgentRequest) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        var unanswered: [String] = []
        for turn in request.history.suffix(24) {
            unanswered.append(turn.user)
            if let reply = turn.assistant {
                messages.append(["role": "user", "content": unanswered.joined(separator: " ")])
                messages.append(["role": "assistant", "content": turn.searched ? searchedTag + " " + reply : reply])
                unanswered = []
            }
        }
        unanswered.append(request.question)
        messages.append(["role": "user", "content": unanswered.joined(separator: " ")])
        return messages
    }

    /// Reads like a question or a request, so a reply is likely and the tool loop is worth
    /// starting alongside the quick path.
    static func expectsReply(_ text: String) -> Bool {
        let q = text.lowercased()
        if q.contains("?") { return true }
        return q.range(of: #"\b(what|who|when|where|why|how|which|can you|could you|would you|tell me|give me|show me|find|look up|search|pick|explain|remember|calculate|is it|are there|do you|does)\b"#,
                       options: .regularExpression) != nil
    }

    /// Stands on its own (no "that", "it", "one"…), so it can be searched as typed.
    static func isStandalone(_ request: AgentRequest) -> Bool {
        if !request.history.contains(where: { $0.assistant != nil }) { return true }
        return request.unanswered.lowercased().range(of: #"\b(it|that|this|those|these|they|them|one|ones|he|she|there)\b"#,
                                                   options: .regularExpression) == nil
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Streams events for one question. Ends normally when the answer is complete.
    static func ask(_ request: AgentRequest, service: AppSettings.AnswerService, model: String, key: String) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.$turnID.withValue(UUID().uuidString) {
                        try await run(request, service: service, model: model, key: key, emit: { continuation.yield($0) })
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Questions whose answer changes over time, so training data can't be trusted: with web
    /// search on, these skip the quick path (it answered "this year's" final from 2025 data).
    static func isTimely(_ question: String) -> Bool {
        let q = question.lowercased()
        let pattern = #"\b(today|tonight|yesterday|tomorrow|this (week|month|year|season|morning|afternoon|evening|weekend)|last (night|week|month|weekend)|next (week|month)|right now|currently|current|latest|newest|recent|recently|news|just (happened|announced|released|came out)|price|prices|cost now|stock|shares|weather|forecast|temperature|score|scores|standings|schedule|release date|come out|open now|20[2-9]\d)\b"#
        // "Who won the last Super Bowl", "who's winning": results change, so search right away.
        let results = #"\b(who (won|is winning|'s winning|leads|is leading)|(last|latest|most recent|this year's|next) (super bowl|world cup|world series|nba finals|stanley cup|champions league|election|olympics|grand prix|game|match|race|final|finals|season|champion|winner|album|iphone))\b"#
        return q.range(of: pattern, options: .regularExpression) != nil || q.range(of: results, options: .regularExpression) != nil
    }

    /// About Starlight itself ("does it have context history?", "why don't you have web search?",
    /// "are you sure?"), not the topic: answered by the agent about itself, not searched.
    static func isAboutStarlight(_ text: String) -> Bool {
        text.lowercased().range(of: #"\b(do you|don't you|dont you|can't you|cant you|can you not|are you|were you|did you|have you|you have|you don't|your|yourself|notch|does it have|is it able|context history|do you remember|you said)\b"#,
                                options: .regularExpression) != nil
            && !(wantsSearch(text) && searchSubject(text) != nil && text.lowercased().range(of: #"\b(why|how come)\b"#, options: .regularExpression) == nil)
    }

    /// Asks for a search in so many words.
    static func wantsSearch(_ text: String) -> Bool {
        text.lowercased().range(of: #"\b(search|google|look (it |that |this )?up|look online|check online|check the (web|internet)|find out)\b"#,
                                options: .regularExpression) != nil
    }

    /// What's left to search for once the asking is taken out; nil when it's only "can you
    /// search the web right now?".
    static func searchSubject(_ text: String) -> String? {
        let filler: Set<String> = ["can", "could", "you", "go", "ahead", "and", "do", "a", "an", "the", "web", "search", "searching",
                                   "internet", "online", "look", "it", "that", "this", "up", "google", "right", "now", "please",
                                   "yeah", "yes", "yo", "ok", "okay", "so", "just", "check", "find", "out", "for", "me", "on",
                                   "again", "actually", "then", "real", "quick", "hey", "notch", "would", "will", "i", "want", "to"]
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !filler.contains($0) }
        return words.count >= 2 ? words.joined(separator: " ") : nil
    }

    /// Mentions X or what people are posting.
    static func mentionsX(_ question: String) -> Bool {
        question.lowercased().range(of: #"\b(on x|x posts?|twitter|tweet|tweets|tweeted|tweeting|posting|posted|trending|people (are )?saying|reactions?|replies)\b"#,
                                    options: .regularExpression) != nil
    }

    /// About the user or their meeting ("did I say…", "our launch"), so memory may matter more
    /// than the web.
    static func isPersonal(_ question: String) -> Bool {
        question.lowercased().range(of: #"\b(i|i'm|i've|we|we're|my|our|ours|me|us|you said|did i|did we)\b"#, options: .regularExpression) != nil
    }

    /// Questions that always go straight to the tool loop: math (the calculator must do it) and
    /// requests to remember something (it must actually be saved).
    static func needsTools(_ question: String) -> Bool {
        let q = question.lowercased()
        if q.range(of: #"^\W*(remember|note that|don't forget|save that|keep in mind)"#, options: .regularExpression) != nil { return true }
        if q.range(of: #"\b(remind me|to-?do|todo list|add .{1,60} to (my )?(list|reminders))\b"#, options: .regularExpression) != nil { return true }
        let mathWords = #"\b(calculate|compute|solve|plus|minus|times|multipl|divid|percent|squared|cubed|square root|power of|equals|sum of|average of|convert)"#
        if q.range(of: mathWords, options: .regularExpression) != nil { return true }
        // Digits next to an operator: "15*23", "18% of 240", "2x + 3 = 7".
        return q.range(of: #"\d\s*([+*/^=%x×÷-]|of\b)\s*\(?\d"#, options: .regularExpression) != nil
            || q.range(of: #"\d+\s*%"#, options: .regularExpression) != nil
    }

    /// Runs two requests at once: a quick one with no tools, and the full tool loop. If the quick
    /// one answers, it streams and the tool loop is cancelled; if it says TOOLS, the tool loop,
    /// already under way, takes over. General questions skip a tool round trip; tool questions
    /// lose nothing.
    private static func run(_ request: AgentRequest, service: AppSettings.AnswerService, model: String, key: String,
                            emit: @escaping (Event) -> Void) async throws {
        let trace = Trace.current
        trace?.mark("sent")
        let emit: (Event) -> Void = { event in
            switch event {
            case .text, .outcome: trace?.mark("ready")
            default: break
            }
            emit(event)
        }
        // Settings, extensions and memories change on the main thread: everything this turn
        // reads from them is taken there, once, before the turn starts.
        let (api, instructions, extras) = await MainActor.run { () -> (ExtensionAPI, String, String) in
            let api = Extensions.shared.makeAPI()
            let extras = api.contextHooks.compactMap { $0(request) }.map { "\n\n" + $0 }.joined()
            return (api, Self.instructions, extras)
        }
        // Everything after the marker changes turn to turn (the time, memories, this request's
        // extras); everything before it is the same every time, so it's cached (see stream()).
        let context = contextMarker + (request.live ? liveRules : "") + (request.direct ? directRules : "") + extras
        let search = api.tools.first { $0.name == "web_search" }
        // This turn (and short quiet turns just before it), without speaker labels, for routing.
        let said = request.routing

        // Plain requests that need no model at all: "remember that…", "add … to my to-do list",
        // "what's 15 times 23 plus 7". Done here, in milliseconds.
        if try await DirectAnswers.handle(request, said: said, api: api, emit: emit) {
            trace?.setWinner("direct")
            return
        }

        // Complex questions: straight to the tool loop with the stronger model, room to write
        // and time to think. No quick path, no instant search.
        if request.deep ?? wantsDeep(said) {
            DebugLog.write("agent: deep mode")
            trace?.setWinner("full")
            return try await $deep.withValue(true) {
                try await runTools(request, system: instructions + "\n\n" + deepRules + context, api: api, service: service,
                                   model: model, key: key, emit: emit)
            }
        }
        let timely = search != nil && isTimely(said)
        // A follow-up on something current ("is it the smartest?" after a search), or "search
        // the web" with nothing to search for but the thread: the model writes the query, with
        // the whole conversation, on the tool path. Never the quick path's memory, never the
        // literal words as a query.
        let lastAnswered = request.history.last { $0.assistant != nil }
        let followUp = !isStandalone(request)
        let searchThread = search != nil && !isAboutStarlight(said) && (
            (followUp && (lastAnswered?.searched == true || isTimely(lastAnswered?.user ?? "")))
            || (wantsSearch(said) && searchSubject(said) == nil))
        if searchThread {
            DebugLog.write("agent: search with the thread")
            trace?.setWinner("full")
            return try await runTools(request, system: instructions + "\n\n" + searchThreadRules + context, api: api,
                                      service: service, model: model, key: key, emit: emit)
        }
        // Time-sensitive and not about the user's own world: search right away, no model step first.
        // Questions about X go to the agent, which picks X search (or both).
        let aboutX = api.tools.contains { $0.name == "x_search" } && mentionsX(said)
        // An explicit "search …" mid-conversation also goes to the model, which can write a
        // better query from the thread than the words as heard.
        if let search, let answers = search.answers, timely, !aboutX, isStandalone(request),
           !(wantsSearch(said) && lastAnswered != nil),
           !LiveAnswers.soundsUnfinished(request.question),
           !isPersonal(said), !needsTools(said) {
            emit(.status(search.status, search.glyph))
            trace?.setWinner("search")
            var gate = Gate(reserved: [], emit: emit)
            let searched = Date()
            var firstText: Date?
            let result = try await answers(["query": said], { text in
                if firstText == nil { firstText = Date(); trace?.span(.tools, "Web search", from: searched, path: "search") }
                gate.feed(text)
            }, { emit(.status($0, search.glyph)) })
            if let firstText { trace?.span(.writing, "Search answer", from: firstText, path: "search") }
            _ = gate.finish()
            DebugLog.write("agent: searched directly")
            if let display = result.display { emit(.tool(display)) }
            return
        }
        // Cut off mid-sentence: only the quick path, which can wait (SKIP) for the rest.
        let unfinished = LiveAnswers.soundsUnfinished(request.question)
        guard !api.tools.isEmpty, unfinished || !(needsTools(said) || timely || aboutX) else {
            trace?.setWinner("full")
            return try await runTools(request, system: instructions + context, api: api, service: service, model: model, key: key, emit: emit)
        }

        // Tools the quick path can't stand in for: saving a memory, and every extension's own
        // tools. If the full path reaches for one of these first, it wins.
        // Only tools the question is plausibly about count, so a trigger-happy model can't hijack
        // "who won the World Cup" with a dice roll.
        let questionWords = MemorySearch.words(said)
        let aboutStarlight = isAboutStarlight(said)
        let strong = Set(api.tools.filter { tool in
            guard tool.name != "calculate", tool.name != "search_memory" else { return false }
            if aboutStarlight, tool.name == "web_search" || tool.name == "x_search" { return false }
            let toolWords = tool.keywords.isEmpty
                ? MemorySearch.words(tool.name.replacingOccurrences(of: "_", with: " ") + " " + tool.description)
                : tool.keywords
            return questionWords.contains { q in toolWords.contains { t in q.count >= 3 && t.count >= 3 && q.prefix(4) == t.prefix(4) } }
        }.map(\.name))
        // A plain command for one of those tools ("turn off captions", "open my resume", "add …
        // to my tasks"): straight to the tool path. Asking the quick path as well only doubles
        // the prompt for an answer that has to come from the tool anyway.
        if !strong.isEmpty, !said.contains("?"), !expectsReply(said) || said.lowercased().range(of: #"^\W*(can you|could you|please)\b"#, options: .regularExpression) != nil {
            DebugLog.write("agent: a command for \(strong.sorted().joined(separator: ", ")), tools first")
            trace?.setWinner("full")
            return try await runTools(request, system: instructions + context, api: api, service: service, model: model, key: key, emit: emit)
        }
        // Speculate only when a reply is likely; for plain statements (most of a meeting) the tool
        // loop starts only if the quick path asks for it, and quick text streams straight out.
        // Also when a tool is plainly what's asked for ("draft a Slack message" isn't a question).
        // Only when a tool the question is about could win: running both paths doubles the tokens,
        // and for everything else the quick path's TOOLS hands over in a moment anyway.
        let speculate = !strong.isEmpty && !unfinished
        let arbiter = Arbiter(emit: emit, strongTools: speculate ? strong : [], trace: trace)
        func startFull() -> Task<Void, Error> {
            Task {
                try await Trace.$path.withValue("full") {
                    try await runTools(request, system: instructions + context, api: api, service: service, model: model, key: key,
                                       emit: { arbiter.fromTools($0) }, onFirstMove: { arbiter.fullMoved($0) })
                }
            }
        }
        let full: Task<Void, Error>? = speculate ? startFull() : nil
        var quickWord: String? = "TOOLS"
        do {
            var gate = Gate(reserved: ["TOOLS", "SKIP"]) { arbiter.fromQuick($0) }
            let toolList = api.groups.sorted { $0.key < $1.key }.map { id, info in
                "- \(info.name): \(info.summary)"
            }.joined(separator: "\n")
            let quick = instructions + "\n\n" + quickRules + "\n\nTools the full assistant has (reply TOOLS if one of them should answer this):\n" + toolList + context
            _ = try await Trace.$path.withValue("quick") {
                try await stream(messages: [["role": "system", "content": quick]] + conversation(request),
                                 tools: [], service: service, model: model, key: key, onText: { gate.feed($0) }, label: "Quick answer")
            }
            quickWord = gate.finish()
        } catch is CancellationError {
            full?.cancel()
            throw CancellationError()
        } catch {
            // Cancelled (URLSession says so with its own error), or the quick answer had already
            // started showing: don't run the whole tool loop for nothing.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || arbiter.chose == .quick {
                full?.cancel()
                throw error
            }
            DebugLog.write("agent: quick path failed: \(error.localizedDescription)")
        }

        switch quickWord {
        case nil:
            // The quick path answered. Give the full path a moment to show its first move, unless
            // it already has; then the arbiter picks.
            let deadline = Date().addingTimeInterval(3)
            // Cancelled while waiting: the speculative tool loop goes too, so it can't act for a
            // turn that's gone.
            do {
                while full != nil, arbiter.isPending, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            } catch {
                full?.cancel()
                throw error
            }
            if arbiter.chooseQuickIfPending() || arbiter.chose == .quick {
                full?.cancel()
                DebugLog.write("agent: answered on the quick path")
                return
            }
        case "SKIP":
            // A question for the room is final, unless the full path already went for a strong tool.
            if arbiter.skipIfPending() {
                full?.cancel()
                return
            }
        default:
            arbiter.chooseTools()
        }
        let tools = full ?? startFull()
        try await withTaskCancellationHandler { try await tools.value } onCancel: { tools.cancel() }
    }

    /// The full path's first move in its first reply.
    enum FirstMove { case text, tool(String) }

    /// Decides which path's events reach the notch. Quick text is held until the full path's
    /// first move is known: a strong tool means the full path wins.
    private final class Arbiter: @unchecked Sendable {
        enum Choice { case pending, quick, tools }
        private let emit: (Event) -> Void
        private let strongTools: Set<String>
        private let trace: Trace?
        private let lock = NSLock()
        private var choice = Choice.pending
        private var quickEvents: [Event] = []
        private var toolEvents: [Event] = []
        private var fullMove: FirstMove?

        init(emit: @escaping (Event) -> Void, strongTools: Set<String>, trace: Trace?) {
            self.emit = emit
            self.strongTools = strongTools
            self.trace = trace
        }

        var chose: Choice { lock.withLock { choice } }
        var isPending: Bool { lock.withLock { choice == .pending && fullMove == nil } }

        func fromQuick(_ event: Event) {
            lock.withLock {
                // No tool this question could be about: nothing to wait for.
                if choice == .pending, strongTools.isEmpty { pick(.quick) }
                switch choice {
                case .pending: quickEvents.append(event)
                case .quick: emit(event)
                case .tools: break
                }
            }
        }

        func fromTools(_ event: Event) {
            lock.withLock {
                switch choice {
                case .pending: toolEvents.append(event)
                case .tools: emit(event)
                case .quick: break
                }
            }
        }

        func fullMoved(_ move: FirstMove) {
            lock.withLock {
                guard fullMove == nil else { return }
                fullMove = move
                if choice == .pending, case .tool(let name) = move, strongTools.contains(name) { pick(.tools) }
            }
        }

        /// Quick answered: show it unless a strong tool already won.
        func chooseQuickIfPending() -> Bool {
            lock.withLock {
                guard choice == .pending else { return false }
                pick(.quick)
                return true
            }
        }

        func skipIfPending() -> Bool {
            lock.withLock {
                guard choice == .pending else { return false }
                choice = .quick
                trace?.setWinner("quick")
                quickEvents = []
                emit(.skipped)
                return true
            }
        }

        func chooseTools() { lock.withLock { if choice == .pending { pick(.tools) } } }

        /// Call with the lock held.
        private func pick(_ new: Choice) {
            choice = new
            trace?.setWinner(new == .quick ? "quick" : "full")
            (new == .quick ? quickEvents : toolEvents).forEach(emit)
            quickEvents = []
            toolEvents = []
        }
    }

    /// The tool loop: stream, run any tools the model calls, repeat.
    private static func runTools(_ request: AgentRequest, system: String, api: ExtensionAPI, service: AppSettings.AnswerService,
                                 model: String, key: String, emit: @escaping (Event) -> Void,
                                 onFirstMove: ((FirstMove) -> Void)? = nil) async throws {
        let tools = Dictionary(api.tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var messages: [[String: Any]] = [["role": "system", "content": system]] + conversation(request)
        // Only the tools this turn is likely to need; the rest load on request.
        var disclosure = ToolDisclosure(api: api, request: request)
        var wrote = false
        let emit: (Event) -> Void = { event in
            if case .text = event { wrote = true }
            emit(event)
        }

        for step in 0..<maxSteps {
            let lastStep = step == maxSteps - 1
            // Each step's words are judged on their own (a later SKIP is still a SKIP), and
            // start on a new paragraph after words already shown.
            let separate = step > 0 && wrote
            var first = true
            var gate = Gate(reserved: ["SKIP"], leadIns: !lastStep) { event in
                if separate, first, case .text = event { first = false; emit(.text("\n\n")) }
                emit(event)
            }
            let reply = try await stream(messages: messages, tools: lastStep ? [] : disclosure.active, service: service, model: model, key: key,
                                         onText: { gate.feed($0) }, onFirstMove: step == 0 ? onFirstMove : nil,
                                         label: step == 0 ? "Model" : "Model, step \(step + 1)")
            if reply.toolCalls.isEmpty {
                if gate.finish() != nil { emit(.skipped) }
                return
            }
            var step: [String: Any] = [
                "role": "assistant",
                "content": reply.text.isEmpty ? NSNull() : reply.text,
                "tool_calls": reply.toolCalls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] },
            ]
            if !reply.reasoning.isEmpty { step["reasoning_blocks"] = reply.reasoning }
            messages.append(step)
            // An answering tool (web or X search): its streamed result is the answer, no rewrite.
            // Several calls to the same one (the model sometimes searches twice) count as one.
            if let call = reply.toolCalls.first, reply.toolCalls.allSatisfy({ $0.name == call.name }),
               let tool = tools[call.name], let answers = tool.answers {
                gate.dropLeadIn()
                gate.leadIns = false
                let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
                emit(.status(tool.status, tool.glyph))
                let searched = Date()
                var firstText: Date?
                let result = try await answers(args, { text in
                    if firstText == nil { firstText = Date(); Trace.current?.span(.tools, call.name, from: searched) }
                    gate.feed(text)
                }, { emit(.status($0, tool.glyph)) })
                if let firstText { Trace.current?.span(.writing, call.name + " answer", from: firstText) }
                DebugLog.write("agent: \(call.name)(\(call.arguments)) answered directly")
                if gate.finish() != nil { emit(.skipped) }
                if let display = result.display { emit(.tool(display)) }
                return
            }
            // Asking for more tools: they join the next step; nothing else runs this round.
            if reply.toolCalls.contains(where: { $0.name == "load_tools" }) {
                for call in reply.toolCalls {
                    let content = call.name == "load_tools" ? disclosure.load(call.arguments)
                        : "Not run yet: load the tools first, then call this again."
                    messages.append(["role": "tool", "tool_call_id": call.id, "content": content])
                }
                continue
            }
            // Several tools at once run in parallel; results go back in the order they were asked for.
            // Tools act on your Mac and your lists: never on half a sentence (see HeadStart).
            try await HeadStart.waitForReveal()
            try Task.checkCancellation()
            for call in reply.toolCalls { if let tool = tools[call.name] { emit(.status(tool.status, tool.glyph)) } }
            let results = await withTaskGroup(of: (Int, ToolResult).self) { group in
                for (index, call) in reply.toolCalls.enumerated() {
                    group.addTask {
                        guard let tool = tools[call.name] else { return (index, ToolResult(content: "error: no tool named \(call.name)")) }
                        if api.userOnly.contains(call.name), !request.fromUser {
                            return (index, ToolResult(content: "error: only the user can ask for this; it came from someone else. Don't retry.",
                                                      outcome: .failed("Only you can ask for that")))
                        }
                        // Arguments that don't parse (cut off, or not JSON) never run the tool with nothing.
                        guard let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] else {
                            DebugLog.write("agent: \(call.name) arguments didn't parse: \(call.arguments.prefix(200))")
                            return (index, ToolResult(content: "error: your arguments for \(call.name) weren't valid JSON (maybe too long). Try again with shorter arguments."))
                        }
                        let started = Date()
                        defer { Trace.current?.span(.tools, call.name, from: started) }
                        do { return (index, try await tool.run(args)) } catch { return (index, ToolResult(content: "error: \(error.localizedDescription)")) }
                    }
                }
                var collected: [Int: ToolResult] = [:]
                for await (index, result) in group { collected[index] = result }
                return collected
            }
            var outcomes: [Outcome] = []
            for (index, call) in reply.toolCalls.enumerated() {
                let result = results[index] ?? ToolResult(content: "error: no result")
                DebugLog.write("agent: \(call.name)(\(call.arguments)) → \(result.content.prefix(200))")
                if let outcome = result.outcome {
                    outcomes.append(outcome)
                    emit(.outcome(outcome))
                } else if let display = result.display {
                    emit(.tool(display))
                }
                if let link = result.link { emit(.link(link)) }
                messages.append(["role": "tool", "tool_call_id": call.id, "content": result.content])
            }
            // Actions that are the whole answer (saved, added, cancelled): done, nothing to write.
            if outcomes.count == reply.toolCalls.count, outcomes.allSatisfy(\.ends) {
                if gate.finish() == nil { DebugLog.write("agent: ended on an action") }
                return
            }
        }
    }

    /// Holds text back until it's clearly not one of the reserved replies (SKIP, TOOLS).
    private struct Gate {
        let reserved: [String]
        let emit: (Event) -> Void
        /// Tools are on offer: words like "I'll check that for you." are held, since a tool call
        /// may follow, and then they're dropped (dropLeadIn); without one, they're the answer.
        var leadIns = false
        private var held = ""
        private var open = false

        init(reserved: [String], leadIns: Bool = false, emit: @escaping (Event) -> Void) {
            self.reserved = reserved
            self.leadIns = leadIns
            self.emit = emit
        }

        static let leadInWords = ["i'll", "i will", "let me", "i'm going to", "checking", "looking", "searching",
                                  "one moment", "one sec", "give me a", "sure, let me", "sure, i'll", "okay, let me", "ok, let me"]

        /// Starts like a lead-in, or could still turn into one.
        private static func mayBeLeadIn(_ text: String) -> Bool {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "’", with: "'")
            return leadInWords.contains { t.hasPrefix($0) || (t.count < $0.count && $0.hasPrefix(t)) }
        }

        /// A tool call came after the words held so far: they were a lead-in, never shown.
        mutating func dropLeadIn() {
            if !open { held = "" }
        }

        mutating func feed(_ text: String) {
            if open { return emit(.text(text)) }
            held += text
            let probe = held.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !probe.isEmpty else { return }
            if leadIns, Self.mayBeLeadIn(held) { return }
            // Still spelling a reserved word, or the word with nothing but punctuation after it.
            // "Skip the first step…" is an answer, not SKIP.
            let couldBeReserved = reserved.contains { word in
                word.hasPrefix(probe) || (probe.hasPrefix(word) && probe.dropFirst(word.count).allSatisfy { !$0.isLetter && !$0.isNumber })
            }
            if !couldBeReserved {
                open = true
                emit(.text(String(held.drop(while: \.isWhitespace))))
            }
        }

        /// Ends the reply. Returns the reserved word it was (an empty reply counts as the first),
        /// or nil when it was a real answer.
        mutating func finish() -> String? {
            if open { return nil }
            let probe = held.trimmingCharacters(in: .whitespacesAndNewlines)
            if probe.isEmpty { return reserved.first }
            let bare = probe.uppercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
            if let word = reserved.first(where: { $0 == bare }) { return word }
            open = true
            emit(.text(probe))
            return nil
        }
    }

    // MARK: Streaming chat completions

    struct ToolCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    struct Reply {
        var text = ""
        var toolCalls: [ToolCall] = []
        /// Claude's thinking blocks (Anthropic only), sent back with the tool calls they led to.
        var reasoning: [[String: Any]] = []
    }

    private static func stream(messages: [[String: Any]], tools: [AgentTool], service: AppSettings.AnswerService, model: String,
                               key: String, onText: (String) -> Void, onFirstMove: ((FirstMove) -> Void)? = nil,
                               label: String = "Model") async throws -> Reply {
        let requested = Date()
        var firstMove: Date?
        var firstText: Date?
        defer {
            // Reasoning: request → first word or tool call. Then writing the words, or the tool call.
            if let trace = Trace.current, !Task.isCancelled {
                if let firstMove {
                    trace.span(.reasoning, label, from: requested, to: firstMove)
                    if let firstText { trace.span(.writing, label + " text", from: firstText) }
                    else { trace.span(.reasoning, label + ", tool call", from: firstMove) }
                }
            }
        }
        // The same question counted once on a plan.
        let headers = service == .notch
            ? ["X-Starlight-Turn": Self.turnID, "X-Notch-Turn": Self.turnID]  // its name before the rename, for an older backend
            : [:]
        // The fixed part of the system prompt is marked for caching: Claude only caches what it's
        // told to.
        var messages = messages
        if let system = messages.first?["content"] as? String, system.contains(contextMarker) {
            let parts = system.components(separatedBy: contextMarker)
            let fixed = parts[0], changing = parts.dropFirst().joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if model.hasPrefix("anthropic/") || service == .anthropic {
                var blocks: [[String: Any]] = [["type": "text", "text": fixed, "cache_control": ["type": "ephemeral"]]]
                if !changing.isEmpty { blocks.append(["type": "text", "text": changing]) }
                messages[0]["content"] = blocks
            } else {
                messages[0]["content"] = changing.isEmpty ? fixed : fixed + "\n\n" + changing
            }
        }
        if Dev.env("STARLIGHT_DEBUG_PROMPT") != nil,
           let system = (messages.first?["content"] as? String)
            ?? (messages.first?["content"] as? [[String: Any]])?.compactMap({ $0["text"] as? String }).joined(separator: "\n\n") {
            let parts = system.components(separatedBy: "\n\n")
            print("  prompt: system \(Usage.estimate(system)) tok, tools \(tools.isEmpty ? 0 : Usage.estimate(json: tools.map(\.schema))) tok, messages \(Usage.estimate(json: Array(messages.dropFirst()))) tok")
            for part in parts.sorted(by: { $0.count > $1.count }).prefix(6) { print("    \(Usage.estimate(part)) tok: \(part.prefix(70).replacingOccurrences(of: "\n", with: " "))") }
        }
        var body: [String: Any] = ["model": model, "messages": messages, "stream": true, "max_tokens": deep ? 4000 : (tools.isEmpty ? 400 : 2500), "temperature": 0.2]
        if !tools.isEmpty {
            body["tools"] = tools.map(\.schema)
            body["tool_choice"] = "auto"
        }
        // No thinking for everyday answers; hard thinking for deep ones.
        AppSettings.applyModel(to: &body, thinking: deep ? .high : .none)
        body["model"] = model  // STARLIGHT_MODEL in tests
        // The last chunk then says how many tokens it used (Settings → Account, under usage).
        body["stream_options"] = ["include_usage": true]
        let estimatedInput = Usage.estimate(json: messages) + (tools.isEmpty ? 0 : Usage.estimate(json: tools.map(\.schema)))
        var reported: (Int, Int)?
        var streamed = ""

        let (status, data, lines) = try await AIService.stream(body, service: service, key: key, timeout: deep ? 120 : 30, headers: headers)
        guard status == 200 else {
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"]
            let message = (error as? [String: Any])?["message"] as? String ?? (error as? String) ?? String(data: data, encoding: .utf8) ?? "request failed"
            DebugLog.write("agent: HTTP \(status) \(message)")
            // A key that isn't accepted says so plainly, with where to fix it.
            if service == .notch {
                // The answer service's own words: signed out, not on Pro, a limit, down for a moment.
                if status == 401 { throw Failure(message: "Sign in again in Settings → Account.") }
                if [402, 429, 502, 503].contains(status) { throw Failure(message: String(message.prefix(160))) }
            } else if status == 401 || status == 403 {
                throw Failure(message: "\(service.displayName) didn't accept your key. Paste it again in Settings → Answers.")
            }
            throw Failure(message: "Error \(status): \(message.prefix(160))")
        }
        // Counted only once the request got through (a 401 or 429 used nothing).
        defer {
            if let reported { Usage.record(input: reported.0, output: reported.1, estimated: false) }
            else { Usage.record(input: estimatedInput, output: Usage.estimate(streamed), estimated: true) }
        }

        var reply = Reply()
        var calls: [Int: ToolCall] = [:]
        var moved = false
        for try await line in lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            // A provider failing mid-answer sends its error inside the stream, still with a 200:
            // said, not taken for "nothing to say".
            if let error = json["error"], !(error is NSNull) {
                let message = (error as? [String: Any])?["message"] as? String ?? (error as? String) ?? "The answer stopped partway"
                DebugLog.write("agent: error in the stream: \(message)")
                throw Failure(message: String(message.prefix(160)))
            }
            if let usage = json["usage"] as? [String: Any], let input = usage["prompt_tokens"] as? Int {
                reported = (input, usage["completion_tokens"] as? Int ?? 0)
                let cached = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
                if cached > 0 { Usage.recordCached(cached) }
            }
            guard let choice = (json["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { continue }
            reply.reasoning += delta["reasoning_blocks"] as? [[String: Any]] ?? []
            if let text = delta["content"] as? String, !text.isEmpty {
                reply.text += text
                streamed += text
                if !moved, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    moved = true; firstMove = Date(); firstText = firstMove; onFirstMove?(.text)
                }
                onText(text)
            }
            for (n, part) in ((delta["tool_calls"] as? [[String: Any]]) ?? []).enumerated() {
                let index = part["index"] as? Int ?? n
                var call = calls[index] ?? ToolCall()
                if let id = part["id"] as? String, !id.isEmpty { call.id = id }
                if let function = part["function"] as? [String: Any] {
                    if let name = function["name"] as? String { call.name += name; streamed += name }
                    if let args = function["arguments"] as? String { call.arguments += args; streamed += args }
                }
                calls[index] = call
                if !moved, !call.name.isEmpty { moved = true; firstMove = Date(); onFirstMove?(.tool(call.name)) }
            }
        }
        reply.toolCalls = calls.keys.sorted().compactMap { i in
            var call = calls[i]!
            guard !call.name.isEmpty else { return nil }
            if call.id.isEmpty { call.id = "call_\(i)" }
            if call.arguments.isEmpty { call.arguments = "{}" }
            return call
        }
        return reply
    }
}
