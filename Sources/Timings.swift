import Foundation
import SwiftUI

/// One measured run, a dictation or an answer, as stages on a timeline so the slow part is
/// obvious.
///
/// An answer runs from the moment you stopped talking:
///   End of speech: the pause that ends a phrase, then the wait for you to go on
///   Transcription: Parakeet turning the phrase into text
///   Reasoning: the model's time to its first word or tool call
///   Tools: calculator, memory, search, a command (with your click)
///   Writing: first word on screen → last
///
/// A dictation runs from the key press:
///   Mic start: the key → audio arriving
///   Transcription: you stop → text
///   Writing: the cleanup rules and the clipboard
///   Polish: the AI rewrite, which swaps in after the text is already shown
///
/// The agent runs a quick path and a full path at once; spans carry which path they belong to,
/// and only the path that answered counts toward the totals (the other is shown dimmed).
final class Trace: @unchecked Sendable, Identifiable {
    enum Kind: String { case answer = "Answer", dictation = "Dictation" }

    enum Stage: String, CaseIterable {
        case mic = "Mic start"
        case endOfSpeech = "End of speech"
        case transcription = "Transcription"
        case reasoning = "Reasoning"
        case tools = "Tools"
        case writing = "Writing"
        case polish = "Polish"
    }

    struct Span: Identifiable {
        let id = UUID()
        let stage: Stage
        let name: String
        let start: Date
        var end: Date
        /// "quick", "full", "search"; nil for spans outside the agent.
        let path: String?
    }

    /// The trace the agent's code marks, for the task answering one turn.
    @TaskLocal static var current: Trace?
    /// Which of the agent's parallel paths the code is running in.
    @TaskLocal static var path: String?

    let id = UUID()
    let kind: Kind
    let label: String
    /// Where the clock starts: you stopped talking (answers), the key press (dictation).
    let origin: Date

    private let lock = NSLock()
    private var _spans: [Span] = []
    private var _marks: [String: Date] = [:]
    private var _winner: String?

    init(_ kind: Kind, label: String, origin: Date = Date()) {
        self.kind = kind
        self.label = label
        self.origin = origin
    }

    private var _tokensIn = 0
    private var _tokensOut = 0
    /// AI tokens this run used, every request counted (both of the agent's paths cost).
    var tokens: (input: Int, output: Int) { lock.withLock { (_tokensIn, _tokensOut) } }
    func addTokens(input: Int, output: Int) { lock.withLock { _tokensIn += input; _tokensOut += output } }

    var spans: [Span] { lock.withLock { _spans } }
    var winner: String? { lock.withLock { _winner } }
    func mark(_ name: String, at date: Date = Date()) { lock.withLock { if _marks[name] == nil { _marks[name] = date } } }
    func time(_ name: String) -> Date? { lock.withLock { _marks[name] } }
    func setWinner(_ path: String) { lock.withLock { _winner = path } }

    func span(_ stage: Stage, _ name: String, from start: Date, to end: Date = Date(), path: String? = Trace.path) {
        guard end >= start else { return }
        lock.withLock { _spans.append(Span(stage: stage, name: name, start: start, end: end, path: path)) }
    }

    /// Times `work` as one span.
    func measure<T>(_ stage: Stage, _ name: String, _ work: () async throws -> T) async rethrows -> T {
        let start = Date()
        defer { span(stage, name, from: start) }
        return try await work()
    }

    /// The first time the user sees something: words, or an action's check.
    var shown: Date? { time("shown") }
    var finished: Date? { time("done") }

    /// Seconds from the origin to the first words on screen.
    var toFirstWords: TimeInterval? { shown.map { $0.timeIntervalSince(origin) } }

    func counts(_ span: Span) -> Bool {
        guard let path = span.path, let winner else { return true }
        return path == winner
    }

    /// Time in each stage on the way to the first words (plus writing and polish after them).
    /// Reasoning is what's left of the agent's time once tools are taken out.
    var breakdown: [(stage: Stage, seconds: TimeInterval)] {
        let spans = spans.filter(counts)
        func total(_ stage: Stage, before limit: Date? = nil) -> TimeInterval {
            spans.filter { $0.stage == stage }.reduce(0) { sum, span in
                let end = limit.map { min(span.end, $0) } ?? span.end
                return sum + max(end.timeIntervalSince(span.start), 0)
            }
        }
        var result: [(Stage, TimeInterval)] = []
        switch kind {
        case .answer:
            // "ready": the agent had words (or a result) to show. Shown later than that means it
            // was held back until you'd clearly finished talking, which is end of speech too.
            let ready = time("ready") ?? shown
            let held = (shown ?? .distantPast).timeIntervalSince(ready ?? .distantFuture)
            result.append((.endOfSpeech, total(.endOfSpeech) + max(held, 0)))
            result.append((.transcription, total(.transcription)))
            if let sent = time("sent"), let ready, let shown {
                let tools = total(.tools, before: ready)
                result.append((.reasoning, max(ready.timeIntervalSince(sent) - tools, 0)))
                result.append((.tools, tools))
                if let finished { result.append((.writing, max(finished.timeIntervalSince(shown), 0))) }
            }
        case .dictation:
            result.append((.mic, total(.mic)))
            result.append((.transcription, total(.transcription)))
            result.append((.writing, total(.writing)))
            let polish = total(.polish)
            if polish > 0 { result.append((.polish, polish)) }
        }
        return result
    }

    var summaryLine: String {
        let parts = breakdown.map { String(format: "%@ %.2f", $0.stage.rawValue.lowercased(), $0.seconds) }.joined(separator: " · ")
        let first = toFirstWords.map { String(format: "%.2fs to first words", $0) } ?? "nothing shown"
        let t = tokens
        let usage = t.input + t.output > 0 ? " · \(t.input) in / \(t.output) out tokens" : ""
        return "\(first) · \(parts)" + (winner.map { " · \($0) path" } ?? "") + usage
    }
}

/// The latest runs, for Settings → Speed and the log.
@MainActor
final class Timings: ObservableObject {
    static let shared = Timings()
    @Published private(set) var traces: [Trace] = []
    static let kept = 40

    func add(_ trace: Trace) {
        DebugLog.write("timing: \(trace.kind.rawValue.lowercased()) \(trace.summaryLine) · \(trace.label.replacingOccurrences(of: "\n", with: " ").prefix(80))")
        for span in trace.spans {
            DebugLog.write(String(format: "  %@%@ %@ +%.2f → +%.2f (%.2fs)", trace.counts(span) ? "" : "(unused) ", span.stage.rawValue, span.name,
                                  span.start.timeIntervalSince(trace.origin), span.end.timeIntervalSince(trace.origin),
                                  span.end.timeIntervalSince(span.start)))
        }
        traces.insert(trace, at: 0)
        if traces.count > Self.kept { traces.removeLast(traces.count - Self.kept) }
    }

    func clear() { traces = [] }

    /// Average seconds per stage over the recent runs of one kind.
    func averages(_ kind: Trace.Kind) -> [(stage: Trace.Stage, seconds: TimeInterval)] {
        let runs = traces.filter { $0.kind == kind && $0.shown != nil }
        guard !runs.isEmpty else { return [] }
        return Trace.Stage.allCases.compactMap { stage in
            let values = runs.compactMap { $0.breakdown.first { $0.stage == stage }?.seconds }
            return values.isEmpty ? nil : (stage, values.reduce(0, +) / Double(values.count))
        }
    }

    func averageToFirstWords(_ kind: Trace.Kind) -> TimeInterval? {
        let values = traces.filter { $0.kind == kind }.compactMap(\.toFirstWords)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
