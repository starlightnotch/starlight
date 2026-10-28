import Foundation
import os

/// Web search from this Mac: look the question up on a search engine's
/// results page, read the top pages, and hand both to the AI provider to answer. No search fee
/// (OpenRouter's Exa plugin and Claude's web search tool each charge per search) and it works
/// with every provider, OpenAI and Ollama included. Search engines block datacenter IPs, not a
/// Mac at home, which is why this runs here and not on a server.
///
/// Engines in order: Startpage (Google's results), then Brave, then DuckDuckGo, the first with three
/// or more results. Startpage's newer /sp/search asks for a JavaScript check; its older
/// /do/dsearch doesn't. Bing was tried
/// and left out: without cookies it searches mostly the first word ("What's Apple's stock price"
/// → WhatsApp) and guesses the wrong city. When neither answers, WebSearch falls back to the
/// provider's own search. Beta: results pages change, and engines rate-limit or ask for a captcha.
enum LocalSearch {
    struct Result { let title: String; let url: String; let snippet: String }
    struct Found { let engine: String; let results: [Result]; let pages: [(url: String, text: String)] }

    /// Engines that said "too many requests", and until when they're skipped.
    private static let resting = OSAllocatedUnfairLock<[String: Date]>(initialState: [:])

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36"

    /// No cookies or cache: each search stands alone.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 6
        config.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept-Language": "en-US,en;q=0.9"]
        return URLSession(configuration: config)
    }()

    /// Results for `query`, and the text of the top `pages` of them (fetched side by side).
    static func search(_ query: String, pages: Int = 2) async -> Found {
        let started = Date()
        var engine = "none"
        var results: [Result] = []
        for (name, run) in [("startpage", startpage), ("brave", brave), ("duckduckgo", duckDuckGo)] as [(String, (String) async throws -> [Result])] {
            if let until = resting.withLock({ $0[name] }), until > Date() { continue }
            do {
                let found = try await run(query)
                DebugLog.write("local search: \(name) \(found.count) results")
                if found.count >= 3 { engine = name; results = found; break }
            } catch {
                DebugLog.write("local search: \(name) failed, \(error.localizedDescription)")
                // Too many searches (429), or a captcha page: leave this engine alone for a while.
                if (error as? URLError)?.code == .badServerResponse {
                    resting.withLock { $0[name] = Date().addingTimeInterval(600) }
                }
            }
        }
        // Twice as many as needed, side by side: some pages are only JavaScript (quotes, feeds)
        // or refuse; the highest-ranked ones that read well are kept.
        let read = await withTaskGroup(of: (Int, String?).self) { group in
            for (i, result) in results.prefix(pages * 2).enumerated() where !skipped(result.url) {
                group.addTask { (i, await pageText(result.url)) }
            }
            var texts: [(Int, String)] = []
            for await (i, text) in group { if let text { texts.append((i, text)) } }
            return texts.sorted { $0.0 < $1.0 }.prefix(pages).map { (url: results[$0.0].url, text: $0.1) }
        }
        DebugLog.write(String(format: "local search: %@, %d results, %d pages, %.1fs", engine, results.count, read.count,
                              Date().timeIntervalSince(started)))
        return Found(engine: engine, results: results, pages: read)
    }

    /// Pages with nothing to read without JavaScript, or video.
    private static func skipped(_ url: String) -> Bool {
        let h = host(url)
        return ["news.google.com", "youtube.com", "m.youtube.com", "x.com", "twitter.com", "instagram.com", "tiktok.com",
                "facebook.com"].contains(h)
    }

    /// About the news: results from the past day only.
    private static func isNews(_ query: String) -> Bool {
        query.lowercased().range(of: #"\b(news|headlines?|breaking)\b"#, options: .regularExpression) != nil
    }

    /// The results and pages as the model reads them.
    static func context(_ found: Found) -> String {
        var text = "Search results:\n"
        for (i, r) in found.results.prefix(8).enumerated() {
            text += "\n[\(i + 1)] \(r.title) (\(host(r.url)))\n\(r.snippet)\n"
        }
        for page in found.pages {
            text += "\n\nFrom \(host(page.url)):\n\(page.text)"
        }
        return text
    }

    static func host(_ url: String) -> String {
        URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
    }

    // MARK: Engines

    private static func get(_ url: String) async throws -> String {
        guard let url = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              !String(decoding: data.prefix(20_000), as: UTF8.self).localizedCaseInsensitiveContains("captcha") else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func encoded(_ query: String) -> String {
        query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
    }

    static func startpage(_ query: String) async throws -> [Result] {
        let html = try await get("https://www.startpage.com/do/dsearch?query=\(encoded(query))&cat=web&language=english"
                                 + (isNews(query) ? "&with_date=d" : ""))
        guard !html.contains("Anubis") else { throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "JavaScript check"]) }
        return html.components(separatedBy: "<div class=\"result css-").dropFirst().prefix(10).compactMap { block in
            guard let url = first(#"class="result-title[^"]*" href="(https?://[^"]+)""#, in: block),
                  let title = first(#"<h2[^>]*>(.*?)</h2>"#, in: block)
            else { return nil }
            let snippet = first(#"<p class="description[^"]*">(.*?)</p>"#, in: block) ?? ""
            return Result(title: plain(title), url: plain(url), snippet: String(plain(snippet).prefix(400)))
        }
    }

    static func brave(_ query: String) async throws -> [Result] {
        let html = try await get("https://search.brave.com/search?q=\(encoded(query))&source=web" + (isNews(query) ? "&tf=pd" : ""))
        return html.components(separatedBy: "data-type=\"web\"").dropFirst().prefix(10).compactMap { block in
            guard let url = first(#"<a href="(https?://[^"]+)""#, in: block),
                  let title = first(#"search-snippet-title[^"]*"[^>]*title="([^"]*)""#, in: block)
                    ?? first(#"search-snippet-title[^>]*>(.*?)</div>"#, in: block)
            else { return nil }
            let snippet = first(#"generic-snippet[^>]*>\s*<div class="content[^>]*>(.*?)</div>"#, in: block) ?? ""
            return Result(title: plain(title), url: plain(url), snippet: String(plain(snippet).prefix(400)))
        }
    }

    static func duckDuckGo(_ query: String) async throws -> [Result] {
        let html = try await get("https://html.duckduckgo.com/html/?q=\(encoded(query))" + (isNews(query) ? "&df=d" : ""))
        return html.components(separatedBy: "class=\"result__a\"").dropFirst().prefix(10).compactMap { block in
            guard let link = first(#"href="([^"]+)""#, in: block), let title = first(#">(.*?)</a>"#, in: block) else { return nil }
            var url = plain(link)
            if let uddg = URLComponents(string: url.hasPrefix("//") ? "https:" + url : url)?.queryItems?.first(where: { $0.name == "uddg" })?.value {
                url = uddg
            }
            // Ads link back through duckduckgo.com.
            guard url.hasPrefix("http"), !host(url).hasSuffix("duckduckgo.com") else { return nil }
            let snippet = first(#"class="result__snippet"[^>]*>(.*?)</a>"#, in: block) ?? ""
            return Result(title: plain(title), url: url, snippet: String(plain(snippet).prefix(400)))
        }
    }

    // MARK: Pages

    /// A page's readable text: its paragraphs, or all its text when it has few. Nil when it isn't
    /// HTML, is too big, or points at this Mac or the local network.
    static func pageText(_ address: String, limit: Int = 3000) async -> String? {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme ?? ""), isPublic(url.host ?? "") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "text/html").contains("html"),
              data.count < 6_000_000
        else { return nil }
        var html = String(decoding: data, as: UTF8.self)
        for tag in ["script", "style", "noscript", "svg", "nav", "header", "footer", "aside", "form", "figure"] {
            html = html.replacingOccurrences(of: "<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        }
        if let article = first(#"<article\b[^>]*>(.*?)</article>"#, in: html), article.count > 1500 { html = article }
        let paragraphs = all(#"<(?:p|h[1-3]|li)\b[^>]*>(.*?)</(?:p|h[1-3]|li)>"#, in: html)
            .map(plain).filter { $0.count > 30 }
        var text = paragraphs.joined(separator: "\n")
        if text.count < 400 { text = plain(html) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 100 else { return nil }
        return String(text.prefix(limit))
    }

    /// Not localhost or a private address: a result can't make this Mac fetch its own network.
    private static func isPublic(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.isEmpty || h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".localhost") || h.contains(":") { return false }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return true }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (0, _), (169, 254), (192, 168): return false
        case (172, 16...31), (100, 64...127): return false
        default: return true
        }
    }

    // MARK: Text

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func all(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Tags out, entities decoded, whitespace collapsed.
    static func plain(_ html: String) -> String {
        var t = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
                     "&mdash;": "—", "&middot;": "·", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“"]
        for (entity, char) in named { t = t.replacingOccurrences(of: entity, with: char) }
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            for match in regex.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
                guard let range = Range(match.range, in: t), let hexR = Range(match.range(at: 1), in: t),
                      let numR = Range(match.range(at: 2), in: t),
                      let code = UInt32(t[numR], radix: t[hexR].isEmpty ? 10 : 16), let scalar = Unicode.Scalar(code)
                else { continue }
                t.replaceSubrange(range, with: String(Character(scalar)))
            }
        }
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}
