import Foundation

/// Instant, rule-based cleanup applied to every transcript (and to the live text).
/// Parakeet already punctuates and capitalizes; this removes what it leaves in.
enum TextCleaner {
    private static let rules: [(NSRegularExpression, String)] = [
        // Spoken formatting commands.
        (#"(?i)[,.]?\s*\bnew paragraph\b[,.]?\s*"#, "\n\n"),
        (#"(?i)[,.]?\s*\bnew line\b[,.]?\s*"#, "\n"),
        // Hesitation sounds, with the commas around them: "so, uh, we" → "so we".
        (#"(?i)^(?:um+|uh+|erm+|uhm+|hmm+|mm+|ah+)\b[,.]?\s*"#, ""),
        (#"(?i),?\s+(?:um+|uh+|erm+|uhm+|hmm+|mm+|ah+)\b,?(?=\s|$|[.!?])"#, ""),
        // Stutters on small words: "I I think", "the the". Content words are left alone, since
        // "very very" or "had had" can be deliberate.
        (#"(?i)\b(i|a|an|the|to|and|but|so|it|is|we|you|he|she|they|that|this|in|on|of|for|my|our|was)(?:[\s,]+\1\b)+"#, "$1"),
        // Spacing around punctuation.
        (#"[ \t]+([,.!?;:])"#, "$1"),
        (#"([,;!?])(?=[A-Za-z])"#, "$1 "),
        (#"[ \t]{2,}"#, " "),
        (#",\s*([.!?])"#, "$1"),
        (#"^[ \t,]+"#, ""),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: [.anchorsMatchLines]), $0.1) }

    static func clean(_ text: String) -> String {
        var s = text
        for (regex, template) in rules {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return capitalizeSentences(s)
    }

    /// Capital letter at the start and after sentence-ending punctuation or a line break.
    private static func capitalizeSentences(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for ch in text {
            if capitalizeNext, ch.isLetter {
                result.append(contentsOf: ch.uppercased())
                capitalizeNext = false
            } else {
                result.append(ch)
                if ch == "." && endsWithAbbreviation(result) {
                    capitalizeNext = false
                } else if ".!?\n".contains(ch) {
                    capitalizeNext = true
                } else if !ch.isWhitespace {
                    capitalizeNext = false
                }
            }
        }
        return result
    }

    /// "e.g." / "i.e." / "a.m.": a period right after a lone letter doesn't end a sentence.
    private static func endsWithAbbreviation(_ text: String) -> Bool {
        let chars = Array(text.suffix(3))  // includes the period just appended
        guard chars.count >= 2, chars[chars.count - 2].isLetter else { return false }
        return chars.count == 2 || chars[chars.count - 3] == "." || chars[chars.count - 3].isWhitespace
    }
}
