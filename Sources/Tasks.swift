import AppKit
import Combine
import SwiftUI

// The corner list: a small folded tab in the bottom-right corner of the screen that opens into
// your tasks and pinned answers. Starlight writes tasks into it as a conversation goes (things
// someone said they'd do, or that need doing), and keeps answers there when you say "pin that".

// MARK: - The list

final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    struct Item: Identifiable, Codable, Equatable {
        enum Kind: String, Codable { case task, answer }
        var id = UUID()
        var text: String
        var kind: Kind = .task
        var done = false
        var created = Date()
        /// When it was ticked off.
        var completed: Date? = nil
        /// When it's due, read from its words ("by Friday", "tomorrow at 3", "in 2 hours").
        var due: Date? = nil
        /// The nudge for `due` has been shown.
        var nudged = false
    }

    @Published private(set) var items: [Item] = []

    /// The task just ticked off, which can still be put back.
    struct Undo: Equatable { let id: UUID; let text: String }
    @Published private(set) var undo: Undo?
    private var undoWork: DispatchWorkItem?
    static let undoSeconds: TimeInterval = 5

    private static var url: URL { NotesStore.folder.deletingLastPathComponent().appendingPathComponent("tasks.json") }

    /// For the renderer.
    init(preview: [Item]) { items = preview }

    private init() {
        if let data = try? Data(contentsOf: Self.url) {
            if let saved = try? JSONDecoder().decode([Item].self, from: data) {
                items = saved
            } else {
                // Unreadable (damaged, or from a newer version): kept aside, never written over.
                let aside = Self.url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: Self.url, to: aside)
            }
        }
        // Ticked tasks go out of sight at once and out of the file after a day.
        items.removeAll { $0.done && Date().timeIntervalSince($0.completed ?? $0.created) > 86_400 }
    }

    /// What's left to do: due soonest first, then the newest.
    var open: [Item] {
        items.filter { !$0.done }.sorted {
            switch ($0.due, $1.due) {
            case let (a?, b?): a < b
            case (_?, nil): true
            case (nil, _?): false
            default: $0.created > $1.created
            }
        }
    }

    /// Ticked off today.
    var doneToday: Int { items.filter { $0.done && Calendar.current.isDateInToday($0.completed ?? $0.created) }.count }

    /// "3 tasks", "1 task", "All done". Tasks everywhere, never "to-dos" or "things to do".
    static func headline(_ open: Int) -> String {
        open == 0 ? "All done" : open == 1 ? "1 task" : "\(open) tasks"
    }

    /// Under the heading: what's next, or how it's going.
    static func subline(_ store: TaskStore) -> String {
        let finished = store.doneToday
        if store.open.isEmpty { return finished > 0 ? "You finished \(finished) today" : "Nothing left. Add something below." }
        if finished > 0 { return "\(finished) done today. Keep going." }
        return store.open.count == 1 ? "Just one. You've got this." : "Newest first"
    }

    /// "now", "5m", "2h", "Yesterday", "Mon", "Oct 3".
    static func age(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if Calendar.current.isDateInToday(date) { return "\(Int(seconds / 3600))h" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        if seconds < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Adds it unless it's already there. Returns whether it was added.
    /// Heard (written from what you said): skipped when any task, done or not, says nearly the
    /// same thing. Typed: only an identical open task stops it; you meant to add it.
    @discardableResult
    func add(_ text: String, kind: Item.Kind = .task, typed: Bool = false) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        let duplicate = typed
            ? open.contains { $0.text.caseInsensitiveCompare(clean) == .orderedSame }
            : items.contains { Self.similar($0.text, clean) }
        guard !duplicate else { return false }
        if Dev.env("STARLIGHT_DRY_RUN") != nil { return true }
        var item = Item(text: clean, kind: kind)
        if kind == .task { item.due = Self.dueDate(in: clean) }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { items.insert(item, at: 0) }
        save()
        return true
    }

    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            items[i].done.toggle()
            items[i].completed = items[i].done ? Date() : nil
        }
        save()
        // Ticked off: it can be put back for a few seconds.
        undoWork?.cancel()
        if items[i].done {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { undo = Undo(id: id, text: items[i].text) }
            let work = DispatchWorkItem { [weak self] in withAnimation(.easeOut(duration: 0.25)) { self?.undo = nil } }
            undoWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoSeconds, execute: work)
        } else {
            undo = nil
        }
    }

    /// Puts the task just ticked off back on the list.
    func undoLast() {
        guard let undo, let i = items.firstIndex(where: { $0.id == undo.id }) else { return }
        undoWork?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
            items[i].done = false
            items[i].completed = nil
            self.undo = nil
        }
        save()
    }

    func markNudged(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].nudged = true
        save()
    }

    // MARK: Due dates

    /// When a task is due, from its words: "by Friday", "tomorrow at 3pm", "tonight", "in 2 hours",
    /// "on Oct 20". A day without a time means 9 AM that day. Nil when it doesn't say.
    static func dueDate(in text: String, now: Date = Date()) -> Date? {
        let lower = text.lowercased()
        let calendar = Calendar.current
        // "in 20 minutes", "in 2 hours", "in 3 days"
        if let match = lower.range(of: #"\bin (\d+|a|an|one|two|three|half an?) (minute|min|hour|hr|day|week)s?\b"#, options: .regularExpression) {
            let words = lower[match].split(separator: " ")
            let numbers = ["a": 1.0, "an": 1, "one": 1, "two": 2, "three": 3, "half": 0.5]
            let amount = Double(words[1]) ?? numbers[String(words[1])] ?? 1
            let unit = words.last.map(String.init) ?? "hour"
            let seconds = unit.hasPrefix("min") ? 60.0 : unit.hasPrefix("h") ? 3600 : unit.hasPrefix("d") ? 86_400 : unit.hasPrefix("w") ? 604_800 : 3600
            return now.addingTimeInterval(amount * seconds)
        }
        if lower.contains("tonight") {
            return calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now)
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), var date = match.date else { return nil }
        let phrase = (text as NSString).substring(with: match.range).lowercased()
        let saysTime = phrase.range(of: #"(\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)|\d{1,2}:\d{2}|noon|midnight|\bat \d)"#, options: .regularExpression) != nil
        if !saysTime {
            date = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
            // A date-only "today": by the end of the working day, or of the day once that's past.
            if calendar.isDateInToday(date), date < now {
                let fivePM = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: now) ?? date
                date = fivePM > now ? fivePM : calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now) ?? date
            }
        }
        // Long ago ("since 2019") isn't a due date.
        guard date > now.addingTimeInterval(-86_400) else { return nil }
        return date
    }

    /// "Now", "3 PM", "Tomorrow", "Fri", "Oct 20", "Overdue".
    static func dueLabel(_ due: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if due < now.addingTimeInterval(-60) { return "Overdue" }
        if due.timeIntervalSince(now) < 15 * 60 { return "Now" }
        let hasTime = calendar.component(.hour, from: due) != 9 || calendar.component(.minute, from: due) != 0
        let time = due.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(due) { return time }
        if calendar.isDateInTomorrow(due) { return hasTime ? "Tomorrow \(time)" : "Tomorrow" }
        if due.timeIntervalSince(now) < 6 * 86_400 { return due.formatted(.dateTime.weekday(.abbreviated)) + (hasTime ? " \(time)" : "") }
        return due.formatted(.dateTime.month(.abbreviated).day())
    }

    /// New words for a task, typed over the old ones. Its due date is read again from them
    /// ("…by Friday"); empty words leave it as it was.
    func rename(_ id: UUID, to text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = items.firstIndex(where: { $0.id == id }), items[i].text != clean else { return }
        let old = items[i].text
        items[i].text = clean.prefix(1).uppercased() + clean.dropFirst()
        // Only when the edit changed what it says about time: fixing a typo in yesterday's
        // "…tomorrow" doesn't move it a day.
        if items[i].kind == .task, Self.dueDate(in: old, now: items[i].created) != Self.dueDate(in: clean, now: items[i].created) {
            items[i].due = Self.dueDate(in: clean)
            items[i].nudged = false
        }
        save()
    }

    func remove(_ id: UUID) {
        Haptics.snap()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { items.removeAll { $0.id == id } }
        save()
    }

    /// Every open task, off the list (after you've confirmed). Undo isn't offered for this.
    func clearAll() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { items.removeAll() }
        undo = nil
        save()
    }

    func clearDone() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { items.removeAll(where: \.done) }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: Self.url, options: .atomic) }
    }

    /// Mostly the same words: "Send Dana the deck" ≈ "send the deck to Dana".
    static func similar(_ a: String, _ b: String) -> Bool {
        // Numbers count whatever their length: "March 12" isn't "March".
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 || $0.first?.isNumber == true })
        }
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return a.caseInsensitiveCompare(b) == .orderedSame }
        // Against the longer one: "Buy milk" isn't "Buy milk and eggs".
        return Double(x.intersection(y).count) / Double(max(x.count, y.count)) >= 0.8
    }
}

// MARK: - Writing tasks as you talk

/// During notes and Live mode: every so often, the newest part of the conversation goes to the
/// answer model, which writes down any new tasks in it. Small and cheap: only new lines, only
/// when there are some, and the open list so it doesn't repeat itself.
final class TaskWriter {
    static let every: TimeInterval = 45
    private var timer: Timer?
    private var seen = 0
    private var lines: () -> [String] = { [] }
    private var running = false

    func begin(lines: @escaping () -> [String]) {
        self.lines = lines
        seen = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in self?.write() }
    }

    /// The session ended: one last look at what's new, then stop.
    func end() {
        timer?.invalidate()
        timer = nil
        write()
    }

    private func write() {
        let all = lines()
        guard !running, all.count - seen >= 2, AppSettings.shared.showTasksCorner, AppSettings.shared.hasAnswerKey else { return }
        let fresh = Array(all[max(seen - 6, 0)...])  // a little of what came before, for sense
        seen = all.count
        running = true
        let open = TaskStore.shared.open.map(\.text)
        Task.detached { [weak self] in
            defer { DispatchQueue.main.async { self?.running = false } }
            guard let tasks = await Self.ask(fresh, open: open) else { return }
            await MainActor.run {
                for task in tasks { TaskStore.shared.add(task) }
                if !tasks.isEmpty { TaskCorner.shared.flash() }
            }
        }
    }

    static let instructions = """
    You keep a to-do list from a live conversation. Read the lines and write down only clear, \
    new tasks: something someone said they would do, something the user was asked to do, or a \
    next step that was agreed. Short and specific, starting with a verb ("Send Dana the pricing \
    deck by Friday"); put the person first when it isn't the user ("Dana: review the draft"). \
    Never invent tasks, never include ideas or questions that weren't settled, never repeat one \
    already on the list. Reactions, small talk and fragments ("not bad", "so I can type", \
    "okay sure") are never tasks. When unsure, leave it out: most stretches of conversation have \
    none. Reply with JSON only: {"tasks": ["…"]}, an empty list when there are none.
    """

    /// Looks like a real task: a few words, not a question, not a reaction.
    static func plausible(_ task: String) -> Bool {
        let words = task.split { $0.isWhitespace }
        guard words.count >= 3, words.count <= 25, !task.hasSuffix("?") else { return false }
        let lower = task.lowercased()
        let reactions = ["not bad", "sounds good", "okay", "ok so", "so i can", "yeah", "sure", "thank", "cool", "nice", "great"]
        return !reactions.contains { lower.hasPrefix($0) }
    }

    private static func ask(_ lines: [String], open: [String]) async -> [String]? {
        let settings = AppSettings.shared
        guard let key = await settings.loadAnswerKey() else { return nil }
        let service = settings.answerService
        let user = "Already on the list:\n" + (open.isEmpty ? "(nothing)" : open.map { "- \($0)" }.joined(separator: "\n"))
            + "\n\nConversation:\n" + lines.joined(separator: "\n")
        var body: [String: Any] = [
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": user]],
            "max_tokens": 300, "temperature": 0,
        ]
        AppSettings.applyModel(to: &body, service: service)
        guard let (reply, status) = try? await AIService.send(body, service: service, key: key, timeout: 30),
              status == 200,
              let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return nil }
        if let usage = json["usage"] as? [String: Any], let input = usage["prompt_tokens"] as? Int {
            Usage.record(input: input, output: usage["completion_tokens"] as? Int ?? 0, estimated: false)
        } else {
            Usage.record(input: Usage.estimate(instructions + user), output: 40, estimated: true)
        }
        guard let content = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String,
              let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(content[start...end].utf8)) as? [String: Any] else { return nil }
        let tasks = (object["tasks"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter(plausible)
        if !tasks.isEmpty { DebugLog.write("tasks: wrote \(tasks.count): \(tasks.joined(separator: "; "))") }
        return Array(tasks.prefix(5))
    }
}

// MARK: - The corner

/// The corner of the screen: there only while you have something to do (and it's on in
/// Settings → General). Closed, it's a pill with your next task; open, the whole list. Finishing
/// the last one shows "All done" for a moment, then it goes.
final class TaskCorner {
    static let shared = TaskCorner()
    private var panel: NSPanel?
    private var host: NSView?
    private var observer: Any?
    private var refitters: [AnyCancellable] = []
    private let state = CornerState()
    private var hadOpen = false

    final class CornerState: ObservableObject {
        @Published var expanded = false
        @Published var pulse = 0
        /// The last task was just ticked off.
        @Published var celebrating = false
        /// Typing a new task in the pill (it's wider then).
        @Published var adding = false
        /// Where it sits (see Anchor), and whether it's being dragged.
        @Published var anchor = TaskCorner.Anchor(rawValue: UserDefaults.standard.string(forKey: "tasksAnchor") ?? "") ?? .bottomRight
        @Published var dragging = false
    }

    /// The pill, with room above it for "Undo".
    static let collapsed = NSSize(width: 320, height: 92)
    static let pillHeight: CGFloat = 34
    static let expandedSize = NSSize(width: 296, height: 440)
    /// Room above the list or pill for the Undo chip.
    static let undoRoom: CGFloat = 42
    /// Where the corner sits. Drag the pill and it snaps to the nearest of these.
    enum Anchor: String, CaseIterable {
        case bottomRight, bottomLeft, dockRight, dockLeft, topRight, topLeft
        var isTop: Bool { self == .topRight || self == .topLeft }
        var isLeft: Bool { self == .bottomLeft || self == .dockLeft || self == .topLeft }
        /// Things grow away from the corner they're anchored to.
        var alignment: Alignment {
            isTop ? (isLeft ? .topLeading : .topTrailing) : (isLeft ? .bottomLeading : .bottomTrailing)
        }
    }

    private static let anchorKey = "tasksAnchor"

    /// Dragging the pill: the window follows the pointer; letting go snaps it to a spot.
    private var dragStart: (window: NSPoint, mouse: NSPoint)?

    func drag(_ phase: DragPhase) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .changed:
            if dragStart == nil { dragStart = (panel.frame.origin, mouse) }
            guard let start = dragStart else { return }
            panel.setFrameOrigin(NSPoint(x: start.window.x + mouse.x - start.mouse.x, y: start.window.y + mouse.y - start.mouse.y))
            withAnimation(.easeOut(duration: 0.15)) { state.dragging = true }
        case .ended:
            dragStart = nil
            let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            // The spot whose window would sit closest to where it was dropped.
            let best = Anchor.allCases.min { a, b in
                let fa = frame(for: panel.frame.size, at: a), fb = frame(for: panel.frame.size, at: b)
                return hypot(fa.midX - center.x, fa.midY - center.y) < hypot(fb.midX - center.x, fb.midY - center.y)
            } ?? .bottomRight
            UserDefaults.standard.set(best.rawValue, forKey: Self.anchorKey)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                state.anchor = best
                state.dragging = false
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().setFrame(frame(for: panel.frame.size, at: best), display: true)
            }
            Haptics.snap()
        }
    }

    enum DragPhase { case changed, ended }

    /// Room around the card inside the window, so its shadow is never clipped.
    static let shadowRoom: CGFloat = 20
    /// From the window to the screen's edges.
    static let edgeGap: CGFloat = 8
    /// The window always fits what's showing (so its empty parts never catch clicks meant for
    /// what's behind): growing at once, shrinking after the closing animation.
    private var fitWork: DispatchWorkItem?
    private var lastSize = CGSize(width: 240, height: 92)

    func fit(_ size: CGSize) {
        guard size.width > 1, size.height > 1, dragStart == nil else { return }  // not while you're moving it
        // The open list measures its rows once they're on screen; a little room above it so
        // it's never clipped while that settles (the space above is empty and transparent).
        let size = state.expanded ? CGSize(width: size.width, height: size.height + 16) : size
        lastSize = size
        guard let panel else { return }
        let frame = frame(for: size)
        fitWork?.cancel()
        if size.width >= panel.frame.width - 0.5 && size.height >= panel.frame.height - 0.5 {
            panel.setFrame(frame, display: true)
        } else if size.width > panel.frame.width || size.height > panel.frame.height {
            // Wider but shorter (or the other way): take the larger now, the exact size after.
            panel.setFrame(self.frame(for: CGSize(width: max(size.width, panel.frame.width), height: max(size.height, panel.frame.height))), display: true)
            let work = DispatchWorkItem { [weak self] in self.map { panel.setFrame($0.frame(for: size), display: true) } }
            fitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        } else {
            let work = DispatchWorkItem { panel.setFrame(frame, display: true) }
            fitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    private var dueTimer: Timer?

    func start() {
        observer = TaskStore.shared.$items.combineLatest(AppSettings.shared.$showTasksCorner, AppSettings.shared.$tasksEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items, corner, enabled in self?.changed(open: items.contains { !$0.done }, on: corner && enabled) }
        dueTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.checkDue() }
        checkDue()
        // Whatever changes what's shown, the window is measured again and fitted to it.
        refitters = [
            TaskStore.shared.objectWillChange.sink { [weak self] _ in self?.refit() },
            state.objectWillChange.sink { [weak self] _ in self?.refit() },
        ]
    }

    /// Measures what's showing (on an off-screen copy of just the content, since the window's
    /// own view fills the window) and fits the window to it.
    func refit() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel != nil else { return }
            let probe = NSHostingView(rootView: TaskCornerView(store: .shared, state: self.state, onExpand: { _ in }, measuring: true))
            self.fit(probe.fittingSize)
        }
    }

    /// A task came due: the corner opens on it with a chime, and the pill keeps pulsing.
    private func checkDue() {
        guard AppSettings.shared.showTasksCorner, AppSettings.shared.tasksEnabled else { return }
        let now = Date()
        let due = TaskStore.shared.open.filter { $0.due.map { $0 <= now } == true && !$0.nudged }
        guard !due.isEmpty else { return }
        for task in due { TaskStore.shared.markNudged(task.id) }
        // Only what just came due gets a chime; things already overdue (Starlight was closed) don't.
        guard due.contains(where: { now.timeIntervalSince($0.due!) < 120 }) else { return }
        DebugLog.write("tasks: due now: \(due.map(\.text).joined(separator: "; "))")
        Sounds.playApprovalRequest()
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.setExpanded(true)
            self?.flash()
        }
    }

    /// New tasks came in: a little bounce.
    func flash() { state.pulse += 1 }

    private func changed(open: Bool, on: Bool) {
        defer { hadOpen = open }
        guard on else { return hide() }
        if open {
            state.celebrating = false
            show()
        } else if hadOpen, panel?.isVisible == true {
            // The last one's done: a moment to enjoy it, then out of the way.
            Sounds.playTick()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { state.celebrating = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + TaskStore.undoSeconds) { [weak self] in
                guard let self, self.state.celebrating, !TaskStore.shared.items.contains(where: { !$0.done }) else { return }
                self.hide()
            }
        } else {
            hide()
        }
    }

    func setExpanded(_ on: Bool) {
        guard state.expanded != on, panel != nil else { return }
        withAnimation(.spring(response: on ? 0.42 : 0.38, dampingFraction: on ? 0.82 : 0.86)) { state.expanded = on }
        if !on { panel?.makeFirstResponder(nil) }
    }

    /// Typing a task in the pill: the corner takes the keyboard (without activating Starlight).
    func takeKeyboard() { panel?.makeKey() }

    /// "Read me my tasks": the list opens while Starlight reads it.
    func reveal() {
        guard AppSettings.shared.tasksEnabled else { return }
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.setExpanded(true) }
    }

    /// Bumped by each show and hide, so a fade-out that finishes after the corner was shown
    /// again doesn't hide it.
    private var visibility = 0

    private func show() {
        if panel == nil { panel = makePanel() }
        visibility += 1
        guard let panel else { return }
        if panel.isVisible {
            // Mid fade-out: come back.
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
            return
        }
        panel.setFrame(frame(for: lastSize), display: true)
        refit()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        CaptureVisibility.apply()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        visibility += 1
        let ticket = visibility
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }, completionHandler: { [weak self] in
            guard let self, self.visibility == ticket else { return }
            panel.orderOut(nil)
            self.state.expanded = false
            self.state.celebrating = false
        })
    }

    /// At its spot, a little in from the edges; always on the notch's screen.
    private func frame(for size: CGSize) -> NSRect { frame(for: size, at: state.anchor) }

    private func frame(for size: CGSize, at anchor: Anchor) -> NSRect {
        guard !NSScreen.screens.isEmpty else { return NSRect(origin: .zero, size: size) }
        let screen = AppDelegate.notchScreen()
        let visible = screen.visibleFrame, full = screen.frame
        let gap = Self.edgeGap
        // Beside the Dock: down at the very bottom of the screen, level with it.
        let dock = anchor == .dockLeft || anchor == .dockRight
        let x = anchor.isLeft ? (dock ? full.minX : visible.minX) + gap : (dock ? full.maxX : visible.maxX) - size.width - gap
        let y = anchor.isTop ? visible.maxY - size.height - gap : (dock ? full.minY : visible.minY) + (dock ? 0 : gap)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func makePanel() -> NSPanel {
        let panel = TypingPanel(contentRect: NSRect(origin: .zero, size: Self.collapsed),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        let host = AcceptingFirstClickHostingView(rootView: TaskCornerView(store: .shared, state: state,
                                                                            onExpand: { [weak self] in self?.setExpanded($0) }))
        host.autoresizingMask = [.width, .height]
        // We place and size the window ourselves (fit): left to SwiftUI, it grew to the right
        // from where it was put and went off the screen.
        host.sizingOptions = []
        panel.contentView = host
        self.host = host
        return panel
    }
}

/// Takes keyboard focus for "Add a task" without making Starlight the active app.
final class TypingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Views

struct TaskCornerView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var state: TaskCorner.CornerState
    let onExpand: (Bool) -> Void
    /// The size of what's showing, so the window can fit it exactly (and not catch clicks
    /// meant for whatever is behind its empty parts).
    var onSize: (CGSize) -> Void = { _ in }
    /// Laid out only to be measured: just the content, without filling the window.
    var measuring = false
    @State private var bounce = false

    var body: some View {
        let anchor = state.anchor
        VStack(alignment: anchor.isLeft ? .leading : .trailing, spacing: 8) {
            if anchor.isTop { content }
            if let undo = store.undo {
                UndoChip { store.undoLast() }
                    .id(undo.id)
                    .transition(.move(edge: anchor.isTop ? .top : .bottom).combined(with: .opacity))
            }
            if !anchor.isTop { content }
        }
        .scaleEffect(state.dragging ? 1.04 : 1, anchor: UnitPoint(x: anchor.isLeft ? 0 : 1, y: anchor.isTop ? 0 : 1))
        .padding(TaskCorner.shadowRoom)
        .frame(maxWidth: measuring ? nil : .infinity, maxHeight: measuring ? nil : .infinity, alignment: anchor.alignment)
        .foregroundStyle(.white)
        .onChange(of: state.pulse) { _, _ in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { bounce = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { bounce = false } }
        }
    }

    @ViewBuilder private var content: some View {
        let corner = UnitPoint(x: state.anchor.isLeft ? 0 : 1, y: state.anchor.isTop ? 0 : 1)
        ZStack(alignment: state.anchor.alignment) {
            if state.celebrating {
                AllDoneCard()
                    .transition(.scale(scale: 0.85, anchor: corner).combined(with: .opacity))
            } else if state.expanded {
                TaskList(store: store, onClose: { onExpand(false) })
                    .transition(.scale(scale: 0.3, anchor: corner).combined(with: .opacity))
            } else if let next = store.open.first {
                NextUpPill(next: next, more: store.open.count - 1, store: store, corner: state, onOpen: { onExpand(true) })
                    .scaleEffect(bounce ? 1.06 : 1, anchor: corner)
                    // Hold and drag to move it; it snaps to the nearest spot.
                    .simultaneousGesture(DragGesture(minimumDistance: 5, coordinateSpace: .global)
                        .onChanged { _ in TaskCorner.shared.drag(.changed) }
                        .onEnded { _ in TaskCorner.shared.drag(.ended) })
                    .transition(.scale(scale: 0.7, anchor: corner).combined(with: .opacity))
            }
        }
    }
}

/// A small text button for the list's heading: grey, or white when it's the one that acts.
struct SmallPill: View {
    let title: String
    let prominent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prominent ? .black : .white.opacity(hovering ? 0.95 : 0.65))
                .padding(.horizontal, 9).frame(height: 22)
                .background(Capsule().fill(prominent ? Color.white.opacity(hovering ? 1 : 0.9) : Color.white.opacity(hovering ? 0.16 : 0.08)))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }
}

/// "Undo" for a few seconds after ticking a task off.
struct UndoChip: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Undo")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 12).frame(height: 26)
                .background(Capsule().fill(.white.opacity(hovering ? 1 : 0.92)))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }
}

/// When a task is due: "3 PM", "Tomorrow", "Fri". Overdue or due now, it stands out in red.
struct DueChip: View {
    let due: Date
    var size: CGFloat = 12

    var body: some View {
        let label = TaskStore.dueLabel(due)
        let urgent = label == "Overdue" || label == "Now"
        Text(label)
            .font(.system(size: size, weight: .semibold).monospacedDigit())
            .foregroundStyle(urgent ? OutcomeBadge.red : .white.opacity(0.85))
            .padding(.horizontal, size < 11 ? 6 : 8).frame(height: size + (size < 11 ? 7 : 10))
            .background(Capsule().fill(urgent ? OutcomeBadge.red.opacity(0.16) : .white.opacity(0.1)))
            .fixedSize()
    }
}

/// Closed: your next task in plain words, its circle to tick it off right there, and how many
/// more there are. Click the words to see them all.
struct NextUpPill: View {
    let next: TaskStore.Item
    let more: Int
    @ObservedObject var store: TaskStore
    /// Shared with the window, which grows to fit the field while you type.
    @ObservedObject var corner: TaskCorner.CornerState
    let onOpen: () -> Void
    @State private var hovering = false
    @State private var completing = false
    @State private var draft = ""

    private var adding: Bool {
        get { corner.adding }
        nonmutating set { corner.adding = newValue }
    }
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            if adding {
                Text("+").font(.system(size: 13, weight: .semibold)).opacity(0.5).frame(width: 15)
                TextField("Add a task", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .focused($focused)
                    .frame(width: 180)
                    .onSubmit(add)
                    .onExitCommand { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { adding = false } }
                    .onChange(of: focused) { _, on in if !on, draft.isEmpty { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { adding = false } } }
            } else {
                TickCircle(ticked: completing, size: 15, action: complete)
                Text(next.text)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 160, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .strikeAcross(completing, fontSize: 12)
                    .opacity(completing ? 0.5 : 1)
                    .id(next.id)
                    .transition(.push(from: .bottom))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onOpen)
                if let due = next.due, !completing { DueChip(due: due, size: 9.5) }
                if more > 0 {
                    Text("+\(more)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize()
                        .background(Capsule().fill(.white.opacity(0.14)))
                        .onTapGesture(perform: onOpen)
                }
                Button(action: startAdding) {
                    Text("+").font(.system(size: 12, weight: .semibold)).offset(y: -0.5)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.white.opacity(hovering ? 0.16 : 0.08)))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Add a task")
            }
        }
        .padding(.leading, 9).padding(.trailing, 8)
        .frame(height: TaskCorner.pillHeight)
        .background(Capsule().fill(.black))
        .overlay(Capsule().strokeBorder(.white.opacity(hovering || adding ? 0.24 : 0.12), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.3), radius: 7, y: 2)
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: adding)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: next.id)
        .accessibilityLabel("Next: \(next.text). \(more) more.")
    }

    private func startAdding() {
        TaskCorner.shared.takeKeyboard()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { adding = true }
        DispatchQueue.main.async { focused = true }
    }

    private func add() {
        let task = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !task.isEmpty { store.add(task.prefix(1).uppercased() + task.dropFirst(), typed: true) }
        draft = ""
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { adding = false }
    }

    private func complete() {
        guard !completing else { return }
        Sounds.playTick()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { completing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            store.toggle(next.id)
            completing = false
        }
    }
}

/// The last task done: a green check, big and friendly, for a moment.
struct AllDoneCard: View {

    var body: some View {
        HStack(spacing: 14) {
            OutcomeBadge(ok: true, size: 18)
            Text("All done").font(.system(size: 13.5, weight: .semibold))
        }
        .padding(.horizontal, 12).frame(height: TaskCorner.pillHeight)
        .background(Capsule().fill(.black))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.3), radius: 7, y: 2)
    }
}

/// Open: a big friendly heading, a place to add, your tasks, and the done ones tucked away.
struct TaskList: View {
    @ObservedObject var store: TaskStore
    let onClose: () -> Void
    /// The rows' real height once laid out (the estimate is only the first frame's guess).
    @State private var measured: CGFloat?
    /// "Clear all?" showing in the heading.
    @State private var confirmClear = false

    private struct RowsHeight: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                if confirmClear {
                    Text("Clear all \(store.open.count)?").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    SmallPill(title: "Cancel", prominent: false) { withAnimation(.easeOut(duration: 0.15)) { confirmClear = false } }
                    SmallPill(title: "Clear", prominent: true) {
                        store.clearAll()
                        confirmClear = false
                    }
                } else {
                    Text(TaskStore.headline(store.open.filter { $0.kind == .task }.count)).font(.system(size: 16, weight: .semibold))
                        .contentTransition(.numericText())
                    Spacer()
                    if store.open.count > 1 {
                        SmallPill(title: "Clear", prominent: false) { withAnimation(.easeOut(duration: 0.15)) { confirmClear = true } }
                    }
                }
                Button(action: onClose) {
                    Glyph(kind: .close, size: 9).frame(width: 22, height: 22)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
                .buttonStyle(PressableStyle()).opacity(0.7)
            }
            .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 6)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .global)
                .onChanged { _ in TaskCorner.shared.drag(.changed) }
                .onEnded { _ in TaskCorner.shared.drag(.ended) })

            AddTaskField(store: store, fontSize: 12.5).padding(.horizontal, 6)

            Scrolling {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.open) { item in
                        TaskRow(item: item, store: store, fontSize: 12.5, onEditBegin: { TaskCorner.shared.takeKeyboard() })
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 2)
                .padding(.bottom, 8)
                .background(GeometryReader { Color.clear.preference(key: RowsHeight.self, value: $0.size.height) })
            }
            .frame(height: min(measured ?? Self.rowsHeight(store), TaskCorner.expandedSize.height - Self.fixedHeight - TaskCorner.undoRoom))
            .onPreferenceChange(RowsHeight.self) { height in if height > 0 { measured = height } }
        }
        .frame(width: TaskCorner.expandedSize.width, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
    }

    /// The heading and the add field.
    static let fixedHeight: CGFloat = 11 + 22 + 6 + 32

    /// The rows' height, worked out from their text, so the card is just as tall as it needs.
    static func rowsHeight(_ store: TaskStore) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12.5)
        let width = TaskCorner.expandedSize.width - 12 - 16 - 26 - 8
        func row(_ item: TaskStore.Item) -> CGFloat {
            let room = width - (item.due == nil ? 0 : 80)
            let text = (item.text as NSString).boundingRect(with: CGSize(width: room, height: 1000),
                                                            options: [.usesLineFragmentOrigin], attributes: [.font: font])
            let lines = max(1, Int((ceil(text.height) / ceil(font.ascender - font.descender + font.leading)).rounded()))
            return max(ceil(text.height) + CGFloat(lines - 1) * 2, 17) + 12 + 2 + 4
        }
        let h: CGFloat = store.open.reduce(CGFloat(0)) { $0 + row($1) }
        return max(h, 20) + 6 + 16
    }
}

/// A task: the circle to tick, the words, when it was added. Ticking draws the check, sweeps a
/// line through the words, then the task slides away to Done. Click the words to change them:
/// Return keeps the edit, Esc puts the old words back.
struct TaskRow: View {
    let item: TaskStore.Item
    @ObservedObject var store: TaskStore
    var fontSize: CGFloat = 15
    /// Editing is about to start: the corner's window takes the keyboard first.
    var onEditBegin: () -> Void = {}
    @State private var hovering = false
    @State private var completing = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var ticked: Bool { item.done || completing }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: fontSize < 13 ? 9 : 12) {
            Group {
                if item.kind == .answer {
                    let side: CGFloat = fontSize < 13 ? 16 : fontSize < 15 ? 20 : 22
                    Glyph(kind: .agent, size: side * 0.7).opacity(0.7).frame(width: side, height: side)
                } else {
                    TickCircle(ticked: ticked, size: fontSize < 13 ? 16 : fontSize < 15 ? 20 : 22, action: tick)
                }
            }
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 5 }

            if editing {
                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize))
                    .lineSpacing(2)
                    .focused($focused)
                    .onSubmit(commitEdit)
                    .onExitCommand(perform: cancelEdit)
                    .onChange(of: focused) { _, on in if !on { commitEdit() } }
            } else {
                WritingText(text: item.text, fresh: Date().timeIntervalSince(item.created) < 4)
                    .font(.system(size: fontSize))
                    .lineSpacing(2)
                    .opacity(ticked ? 0.4 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .strikeAcross(ticked, fontSize: fontSize)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: beginEdit)
                    .help(item.kind == .task && !ticked ? "Click to edit" : "")
            }

            Spacer(minLength: 6)
            // The due chip, and on hover the × to remove in its place. The slot is always there,
            // so hovering never changes the row's layout or re-wraps its text: only fades.
            ZStack(alignment: .trailing) {
                if let due = item.due, !ticked { DueChip(due: due, size: fontSize < 13 ? 10 : fontSize < 15 ? 11 : 12).opacity(hovering ? 0 : 1) }
                Button { store.remove(item.id) } label: {
                    Glyph(kind: .close, size: 9).frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.1)))
                }
                .buttonStyle(PressableStyle())
                .opacity(hovering ? 0.75 : 0)
                .allowsHitTesting(hovering)
                .accessibilityLabel("Remove")
            }
            .frame(minWidth: 22, alignment: .trailing)
            .opacity(editing ? 0 : 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, fontSize < 13 ? 6 : fontSize < 15 ? 8 : 10)
        // Hover: a soft glow behind the row, nothing moves.
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(editing ? 0.1 : hovering ? 0.07 : 0))
                .shadow(color: .white.opacity(hovering ? 0.08 : 0), radius: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(hovering ? 0.08 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private func beginEdit() {
        guard item.kind == .task, !ticked, !editing else { return }
        onEditBegin()
        draft = item.text
        withAnimation(.easeOut(duration: 0.15)) { editing = true }
        DispatchQueue.main.async { focused = true }
    }

    private func commitEdit() {
        guard editing else { return }
        store.rename(item.id, to: draft.replacingOccurrences(of: "\n", with: " "))
        withAnimation(.easeOut(duration: 0.15)) { editing = false }
    }

    private func cancelEdit() {
        draft = item.text
        withAnimation(.easeOut(duration: 0.15)) { editing = false }
    }

    private func tick() {
        guard !item.done else { return store.toggle(item.id) }  // back to open, straight away
        guard !completing else { return }
        Sounds.playTick()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { completing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            store.toggle(item.id)
            completing = false
        }
    }
}

/// The circle you tick: it brightens and swells a little on hover, and fills green with a
/// white check that draws itself in.
struct TickCircle: View {
    let ticked: Bool
    var size: CGFloat = 22
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.white.opacity(ticked ? 0 : hovering ? 0.85 : 0.45), lineWidth: 1.5)
                if ticked { OutcomeBadge(ok: true, size: size).transition(.scale(scale: 0.4).combined(with: .opacity)) }
            }
            .frame(width: size, height: size)
            .scaleEffect(hovering && !ticked ? 1.08 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hovering)
        .accessibilityLabel(ticked ? "Mark not done" : "Mark done")
    }
}

extension View {
    /// A line drawn through the text from left to right as it's ticked off.
    func strikeAcross(_ on: Bool, fontSize: CGFloat) -> some View {
        overlay(alignment: .topLeading) {
            GeometryReader { geo in
                Rectangle().fill(.white.opacity(0.6))
                    .frame(width: geo.size.width, height: 1.3)
                    .scaleEffect(x: on ? 1 : 0, anchor: .leading)
                    .offset(y: min(geo.size.height / 2, fontSize * 0.62))
            }
            .allowsHitTesting(false)
        }
    }
}

/// "Add a task": type and press Return; the field stays ready for the next one.
struct AddTaskField: View {
    @ObservedObject var store: TaskStore
    var fontSize: CGFloat = 15
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: fontSize < 13 ? 9 : 12) {
            ZStack {
                Circle().strokeBorder(.white.opacity(focused ? 0.6 : 0.25), style: StrokeStyle(lineWidth: 1.3, dash: [2.5, 2.5]))
                Text("+").font(.system(size: fontSize < 13 ? 11 : 14, weight: .semibold)).opacity(focused ? 0.85 : 0.45).offset(y: -0.5)
            }
            .frame(width: fontSize < 13 ? 16 : 22, height: fontSize < 13 ? 16 : 22)
            if Render.isRendering {
                Text("Add a task").font(.system(size: fontSize)).opacity(0.35)
                Spacer(minLength: 0)
            } else {
                TextField("Add a task", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize))
                    .focused($focused)
                    .onSubmit(add)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: fontSize < 13 ? 32 : fontSize < 15 ? 40 : 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(focused ? 0.08 : 0.04)))
        .animation(.easeOut(duration: 0.15), value: focused)
    }

    private func add() {
        let task = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        store.add(task.prefix(1).uppercased() + task.dropFirst(), typed: true)
        text = ""
        focused = true
    }
}

/// Text that types itself in when it's new, as if Starlight were writing it down.
struct WritingText: View {
    let text: String
    let fresh: Bool
    @State private var shown = 0

    var body: some View {
        Text(fresh && shown < text.count ? String(text.prefix(shown)) : text)
            .onAppear {
                guard fresh, !Render.isRendering else { shown = text.count; return }
                let step = max(0.012, 0.7 / Double(max(text.count, 1)))
                for i in 1...max(text.count, 1) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(i)) { shown = i }
                }
            }
    }
}
