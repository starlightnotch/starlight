import Foundation

/// `Starlight --agent-test "question" ["question" …]`: asks the live agent with your saved key and
/// prints what the notch would show, with timings. Questions see the earlier ones as this meeting.
@MainActor
enum AgentTest {
    static func run(_ questions: [String]) {
        setenv("STARLIGHT_DRY_RUN", "1", 1)  // remember() won't save
        Usage.paused = true  // the test's tokens aren't counted as yours
        let settings = AppSettings.shared
        // STARLIGHT_SERVICE=openrouter|notch and STARLIGHT_MODEL=…: try another service or model. For
        // notch, STARLIGHT_TOKEN is a Clerk session token for a Pro test account.
        let env = ProcessInfo.processInfo.environment
        let service = env["STARLIGHT_SERVICE"].flatMap(AppSettings.AnswerService.init(rawValue:)) ?? settings.answerService
        let key = service == .notch ? env["STARLIGHT_TOKEN"] : service == .ollama ? "ollama" : env["STARLIGHT_KEY"] ?? settings.answerKeyFor(service)
        guard let key, !key.isEmpty else { return print("No \(service.rawValue) key saved.") }
        let model = Dev.env("STARLIGHT_MODEL") ?? AppSettings.model
        print("service \(service.rawValue) · model \(model) · tools: \(Extensions.shared.makeAPI().tools.map(\.name).joined(separator: ", "))")
        var meeting: [NoteItem] = []
        var history: [AgentTurn] = []  // each argument is one turn of a running conversation
        let start = Date()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for question in questions {
                meeting.append(NoteItem(time: Date().timeIntervalSince(start), text: question, isQuestion: true))
                var request = AgentRequest(question: question, meeting: meeting, meetingStart: start, history: history)
                request.live = Dev.env("STARLIGHT_LIVE_MODE") != nil
                let t0 = Date()
                var first: TimeInterval?
                var text = ""
                var outcome: Outcome?
                var searched = false
                print("\nQ: \(question)")
                do {
                    let trace = Trace(.answer, label: question, origin: t0)
                    trace.mark("sent")
                    let events = Trace.$current.withValue(trace) { Agent.ask(request, service: service, model: model, key: key) }
                    defer {
                        trace.mark("done")
                        print("  ⏱ " + trace.summaryLine)
                        for span in trace.spans.sorted(by: { $0.start < $1.start }) {
                            print(String(format: "     %@%-13@ %-26@ %5.2f → %5.2f", trace.counts(span) ? "  " : "· ", span.stage.rawValue,
                                         span.name, span.start.timeIntervalSince(t0), span.end.timeIntervalSince(t0)))
                        }
                    }
                    for try await event in events {
                        if case .text = event { trace.mark("shown") }
                        if case .outcome = event { trace.mark("shown") }
                        let t = String(format: "%5.2fs", Date().timeIntervalSince(t0))
                        switch event {
                        case .status(let label, let glyph): if glyph == .globe || glyph == .posts { searched = true }; print("  \(t)  [\(label)]")
                        case .tool(let line): print("  \(t)  tool → \(line)")
                        case .text(let delta):
                            if first == nil { first = Date().timeIntervalSince(t0) }
                            text += delta
                        case .link(let moment): print("  \(t)  link → \(moment.sessionID) at \(NotesController.timestamp(moment.time))")
                        case .outcome(let result): outcome = result; print("  \(t)  \(result.ok ? "✓" : "✗") \(result.text)")
                        case .skipped: print("  \(t)  SKIP (not shown)")
                        }
                    }
                    history.append(AgentTurn(user: question, assistant: text.isEmpty ? outcome?.text : text, searched: searched))
                    if !text.isEmpty {
                        print(String(format: "  first words %.2fs · done %.2fs", first ?? 0, Date().timeIntervalSince(t0)))
                        print("A: \(AnswerText.clean(text))")
                        if let image = AnswerText.imageQuery(text) {
                            let loaded = await AnswerImage.load(image)
                            print("  image: \(image) → \(loaded.map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "none")")
                        }
                        if case .headline(let headline, _) = AnswerText.shape(AnswerText.clean(text), finished: true) { print("  big: \(headline)") }
                    }
                } catch {
                    print("  failed: \(error.localizedDescription)")
                }
            }
            done.signal()
        }
        while done.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
}
