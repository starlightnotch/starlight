import AppKit

/// How an answer is shown: a short fact ("1,000 USD is about 850 CHF.") gets big type with any
/// detail small under it; a picture of the place or person when the agent names one
/// (`[[image: Baku]]` at the end of its reply); and numbers grouped with commas.
enum AnswerText {
    /// Longest first sentence that's shown big.
    static let headlineLimit = 48

    /// The reply without the image marker (and without half a marker while it streams in).
    static func clean(_ text: String) -> String {
        var text = text
        if let range = text.range(of: #"\[\[\s*image\s*:[^\]]*\]\]"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        // Half a marker at the end while it streams ("[[ima"), but never "[[1, 2]]" in code.
        if let open = text.range(of: "[[", options: .backwards) {
            let tail = text[open.lowerBound...].lowercased().replacingOccurrences(of: " ", with: "")
            let marker = "[[image:"
            if tail.count <= 90, !tail.contains("]"), tail.hasPrefix(marker) || marker.hasPrefix(tail) {
                text.removeSubrange(open.lowerBound...)
            }
        } else if text.hasSuffix("["), !text.contains("```") {
            text.removeLast()
        }
        return grouped(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What to show a picture of, from the `[[image: …]]` marker.
    static func imageQuery(_ text: String) -> String? {
        guard let range = text.range(of: #"\[\[\s*image\s*:([^\]]*)\]\]"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let inner = text[range].dropFirst(2).dropLast(2)
        let query = inner.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return query.isEmpty ? nil : String(query.prefix(80))
    }

    enum Shape: Equatable {
        /// Still streaming and too early to tell: show nothing yet (a few hundredths of a second).
        case pending
        /// A short fact, shown big, with the rest small under it.
        case headline(String, detail: String)
        /// Everything else: normal text.
        case body
    }

    /// Big headline or normal text. A reply is a headline when its first sentence is short;
    /// while it streams, the shape is held until that first sentence is known.
    static func shape(_ text: String, finished: Bool) -> Shape {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("```") else { return text.isEmpty && !finished ? .pending : .body }
        if let end = sentenceEnd(text) {
            let first = String(text[..<end]).trimmingCharacters(in: .whitespaces)
            guard first.count <= headlineLimit else { return .body }
            return .headline(first, detail: String(text[end...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if text.count > headlineLimit { return .body }
        return finished ? .headline(text, detail: "") : .pending
    }

    /// Just past the first sentence: ". ", "! ", "? ", or a line break. Not after a decimal
    /// point or an initial ("U.S. dollars").
    private static func sentenceEnd(_ text: String) -> String.Index? {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" { return text.index(text.startIndex, offsetBy: i) }
            if ".!?".contains(c), i + 1 < chars.count, chars[i + 1] == " " || chars[i + 1] == "\n" {
                let initial = c == "." && i >= 1 && chars[i - 1].isUppercase && (i == 1 || chars[i - 2] == "." || chars[i - 2] == " ")
                if !initial { return text.index(text.startIndex, offsetBy: i + 1) }
            }
            i += 1
        }
        return nil
    }

    /// "1000000" → "1,000,000" outside code. Five digits or more always; four only beside money
    /// ("$1000", "1000 USD"), so years stay years. Leaves decimals, phone numbers, IDs and times alone.
    static func grouped(_ text: String) -> String {
        guard text.contains(where: \.isNumber) else { return text }
        let parts = text.components(separatedBy: "`")
        return parts.enumerated().map { index, part in index % 2 == 1 ? part : groupedProse(part) }.joined(separator: "`")
    }

    private static let money = #"(?:[$€£¥₹]|\b(?:USD|EUR|GBP|CHF|JPY|CAD|AUD|INR|CNY|dollars?|euros?|pounds?|francs?|yen)\b)"#

    private static func groupedProse(_ text: String) -> String {
        let pattern = #"(?<![\d.,:/#\-\w])(\d{4,})(?![\d,:/\-]|\.\d*[A-Za-z]|[A-Za-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let digits = ns.substring(with: match.range(at: 1))
            if digits.count == 4 {
                let before = ns.substring(to: match.range.location).suffix(2)
                let after = ns.substring(from: match.range.location + match.range.length).prefix(10)
                let besideMoney = String(before).range(of: money + #"\s?$"#, options: .regularExpression) != nil
                    || String(after).range(of: #"^(?:\.\d+)?\s?"# + money, options: .regularExpression) != nil
                guard besideMoney else { continue }
            }
            guard digits.first != "0", let value = Int(digits) else { continue }
            let pretty = value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
            result = (result as NSString).replacingCharacters(in: match.range(at: 1), with: pretty)
        }
        return result
    }
}

/// Small pictures for answers, from Wikipedia's page summaries (no key needed). Cached for the
/// session; nil when there's no article or no picture.
enum AnswerImage {
    private static let cache = NSCache<NSString, NSImage>()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6
        config.httpAdditionalHeaders = ["User-Agent": "Starlight/1.0 (macOS notch assistant)"]
        return URLSession(configuration: config)
    }()

    static func load(_ query: String) async -> NSImage? {
        if let cached = cache.object(forKey: query as NSString) { return cached }
        let title = query.replacingOccurrences(of: " ", with: "_")
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)?redirect=true") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String != "disambiguation",
                  let thumb = (json["thumbnail"] as? [String: Any])?["source"] as? String,
                  let imageURL = URL(string: thumb) else { return nil }
            let (imageData, _) = try await session.data(from: imageURL)
            guard let image = NSImage(data: imageData) else { return nil }
            cache.setObject(image, forKey: query as NSString)
            return image
        } catch {
            DebugLog.write("image: \(query): \(error.localizedDescription)")
            return nil
        }
    }

    /// Opens the connection early, so the first picture of a session comes as fast as the rest.
    static func warmUp() {
        guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        session.dataTask(with: request).resume()
    }
}
