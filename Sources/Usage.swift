import Foundation
import SwiftUI

/// How much Starlight is using: AI tokens (as the service reports them, or estimated from the text
/// when it doesn't), requests, and the app's memory. Kept per day for the last two weeks.
final class Usage: ObservableObject, @unchecked Sendable {
    static let shared = Usage()

    struct Totals: Codable, Equatable {
        var requests = 0
        var input = 0
        var output = 0
        /// Requests whose counts were estimated (about 4 characters a token).
        var estimated = 0
        /// Input tokens served from the prompt cache (much cheaper and faster).
        var cached = 0
        var tokens: Int { input + output }
    }

    @Published private(set) var stored = Totals()
    /// Today's totals: read from the day's entry, so they start over at midnight even with no
    /// request since.
    var today: Totals { days[Self.dayKey(Date())] ?? Totals() }
    @Published private(set) var sinceLaunch = Totals()
    @Published private(set) var days: [String: Totals] = [:]

    private let lock = NSLock()
    private static let key = "usageByDay"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: Totals].self, from: data) {
            days = saved
        }
        stored = days[Self.dayKey(Date())] ?? Totals()
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Test runs (--agent-test and the like) share the app's settings; their requests aren't yours.
    nonisolated(unsafe) static var paused = false

    /// One request's tokens. `estimated` when the service didn't say.
    static func record(input: Int, output: Int, estimated: Bool) {
        guard !paused else { return }
        Trace.current?.addTokens(input: input, output: output)
        DispatchQueue.main.async { shared.add(input: input, output: output, estimated: estimated) }
    }

    static func recordCached(_ tokens: Int) {
        guard !paused else { return }
        DispatchQueue.main.async {
            let key = dayKey(Date())
            var day = shared.days[key] ?? Totals()
            day.cached += tokens
            shared.days[key] = day
            shared.stored = day
            shared.sinceLaunch.cached += tokens
        }
    }

    /// Text to tokens, roughly: about four characters each.
    static func estimate(_ text: String) -> Int { max(1, (text.utf8.count + 3) / 4) }

    static func estimate(json: Any) -> Int {
        guard JSONSerialization.isValidJSONObject(json), let data = try? JSONSerialization.data(withJSONObject: json) else { return 0 }
        return max(1, data.count / 4)
    }

    private func add(input: Int, output: Int, estimated: Bool) {
        func bump(_ t: inout Totals) {
            t.requests += 1
            t.input += input
            t.output += output
            if estimated { t.estimated += 1 }
        }
        let key = Self.dayKey(Date())
        var day = days[key] ?? Totals()
        bump(&day)
        days[key] = day
        stored = day
        bump(&sinceLaunch)
        // Two weeks is plenty.
        let keep = Set((0..<14).map { Self.dayKey(Date().addingTimeInterval(-Double($0) * 86_400)) })
        days = days.filter { keep.contains($0.key) }
        if let data = try? JSONEncoder().encode(days) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// The last `count` days, oldest first, for the chart.
    func lastDays(_ count: Int) -> [(day: Date, totals: Totals)] {
        (0..<count).reversed().map { offset in
            let date = Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(offset) * 86_400))
            return (date, days[Self.dayKey(date)] ?? Totals())
        }
    }

    /// Starlight's memory right now, as Activity Monitor shows it.
    static var memoryBytes: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
