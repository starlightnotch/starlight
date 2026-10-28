import SwiftUI

/// The two numbers on top of Dictation → History: every word dictated, and how fast you talk.
struct DictationStats: View {
    @ObservedObject var history: DictationHistory

    var body: some View {
        HStack(spacing: 12) {
            BigStat(value: history.totalWords.formatted(), label: "words dictated")
            BigStat(value: history.wordsPerMinute.map { $0.formatted() } ?? "\u{2013}", label: "average words per minute")
        }
    }
}

/// A number, big, with what it counts under it.
struct BigStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text(label).font(.system(size: 12)).opacity(0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
