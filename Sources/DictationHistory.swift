import Foundation
import ServiceManagement

/// Every dictation result, newest first, so text isn't lost when the notch hides it (nothing is
/// pasted). Stored in ~/Library/Application Support/Starlight/dictations.json.
final class DictationHistory: ObservableObject {
    struct Entry: Identifiable, Codable, Equatable {
        var id = UUID()
        let date: Date
        let text: String
        let duration: TimeInterval
    }

    static let shared = DictationHistory()
    static let limit = 500
    @Published private(set) var entries: [Entry] = []
    /// Every dictation ever, not just the last 500 kept above: the words and the seconds spoken,
    /// for the two numbers on top of History. Clearing the history keeps them.
    @Published private(set) var totalWords = 0
    @Published private(set) var totalSeconds: TimeInterval = 0

    /// Words per minute across all of it; nil until there's a dictation to go on.
    var wordsPerMinute: Int? {
        totalSeconds >= 1 && totalWords > 0 ? Int((Double(totalWords) / (totalSeconds / 60)).rounded()) : nil
    }

    private static func words(in text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    private static var url: URL {
        NotesStore.folder.deletingLastPathComponent().appendingPathComponent("dictations.json")
    }

    private init() {
        defer { loadTotals() }
        guard let data = try? Data(contentsOf: Self.url) else { return }
        if let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        } else {
            // Unreadable (damaged, or from a newer version): kept aside, never written over.
            let aside = Self.url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: Self.url, to: aside)
        }
    }

    /// Adds it at the top; returns its id, for swapping in the polished text later.
    @discardableResult
    func add(_ text: String, duration: TimeInterval) -> UUID {
        let entry = Entry(date: Date(), text: text, duration: duration)
        entries.insert(entry, at: 0)
        totalWords += Self.words(in: text)
        totalSeconds += duration
        UserDefaults.standard.set(totalWords, forKey: "dictation.totalWords")
        UserDefaults.standard.set(totalSeconds, forKey: "dictation.totalSeconds")
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
        return entry.id
    }

    /// That entry, rewritten (the polished version of what was dictated). By id: another
    /// dictation may have finished in the meantime.
    func replace(_ id: UUID, with text: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let old = entries[i]
        entries[i] = Entry(id: old.id, date: old.date, text: text, duration: old.duration)
        save()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        try? JSONEncoder().encode(entries).write(to: Self.url, options: .atomic)
    }

    /// The running totals; the first time, counted from the history there is.
    private func loadTotals() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "dictation.totalWords") == nil {
            defaults.set(entries.reduce(0) { $0 + Self.words(in: $1.text) }, forKey: "dictation.totalWords")
            defaults.set(entries.reduce(0) { $0 + $1.duration }, forKey: "dictation.totalSeconds")
        }
        totalWords = defaults.integer(forKey: "dictation.totalWords")
        totalSeconds = defaults.double(forKey: "dictation.totalSeconds")
    }
}

/// Launch at login through SMAppService.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            DebugLog.write("login item: \(error)")
        }
        if needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

/// "Today 3:42 PM", "Yesterday 9:10 AM", "Mon 2:05 PM", "Oct 3 · 11:20 AM".
enum RelativeDate {
    static func string(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 6 {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        let day = sameYear ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(date: .abbreviated, time: .omitted)
        return "\(day) · \(time)"
    }
}
