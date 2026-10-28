import SwiftUI

/// The little markdown Starlight renders: **bold**, *italic* and `code` in a line, plus syntax
/// colour for code blocks.
enum Markdown {
    /// Inline markdown, line breaks kept. Falls back to the plain text if it doesn't parse.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// The text without markdown marks, for measuring how much room it needs.
    static func plain(_ text: String) -> String {
        String(inline(text).characters)
    }
}

/// Colours code for display: keywords, strings, numbers, comments, function calls. A light
/// tokenizer that works across the usual languages (Python, JavaScript/TypeScript, Swift, Java,
/// C-family, Go, Rust, SQL, shell), not a parser. Muted colours so it reads calmly on black.
enum CodeHighlighter {
    static let plain = Color.white.opacity(0.88)
    static let keyword = Color(red: 0.80, green: 0.66, blue: 0.95)   // soft violet
    static let string = Color(red: 0.66, green: 0.86, blue: 0.66)    // sage
    static let number = Color(red: 0.95, green: 0.78, blue: 0.56)    // sand
    static let comment = Color.white.opacity(0.38)
    static let call = Color(red: 0.62, green: 0.80, blue: 0.98)      // pale blue
    static let type = Color(red: 0.95, green: 0.86, blue: 0.62)      // pale gold

    private static let keywords: Set<String> = [
        // Python
        "def", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "import", "from", "as",
        "class", "try", "except", "finally", "with", "lambda", "yield", "pass", "break", "continue", "None", "True",
        "False", "global", "nonlocal", "raise", "assert", "del", "async", "await",
        // C-family, JavaScript, Swift, Go, Rust, Java
        "function", "const", "let", "var", "new", "this", "self", "null", "undefined", "true", "false", "switch", "case",
        "default", "do", "typeof", "instanceof", "export", "extends", "implements", "interface", "public", "private",
        "protected", "static", "final", "void", "int", "long", "double", "float", "bool", "boolean", "char", "string",
        "struct", "enum", "func", "guard", "inout", "where", "protocol", "extension", "fn", "mut", "impl", "pub", "use",
        "mod", "match", "package", "type", "go", "defer", "chan", "map", "nil", "throw", "throws", "catch", "auto",
        // SQL (upper and lower case)
        "select", "insert", "update", "delete", "where", "join", "left", "right", "inner", "outer", "on", "group", "by",
        "order", "having", "limit", "values", "into", "create", "table", "distinct", "count",
    ]

    static func highlight(_ code: String, language: String) -> AttributedString {
        let hashComments = ["python", "py", "ruby", "rb", "bash", "sh", "shell", "zsh", "r", "yaml", "toml"].contains(language.lowercased())
        let sql = language.lowercased() == "sql"
        var out = AttributedString()
        let chars = Array(code)
        var i = 0

        func append(_ s: String, _ color: Color) {
            var piece = AttributedString(s)
            piece.foregroundColor = color
            out += piece
        }

        while i < chars.count {
            let c = chars[i]
            // Comments: # (script languages), //, /* */, -- (SQL)
            if (hashComments && c == "#") || (c == "/" && i + 1 < chars.count && chars[i + 1] == "/")
                || (sql && c == "-" && i + 1 < chars.count && chars[i + 1] == "-") {
                var j = i
                while j < chars.count, chars[j] != "\n" { j += 1 }
                append(String(chars[i..<j]), comment)
                i = j
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                var j = i + 2
                while j + 1 < chars.count, !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                j = min(j + 2, chars.count)
                append(String(chars[i..<j]), comment)
                i = j
                continue
            }
            // Strings: "…", '…', `…`, with escapes
            if c == "\"" || c == "'" || c == "`" {
                var j = i + 1
                while j < chars.count, chars[j] != c {
                    if chars[j] == "\\" { j += 1 }
                    if j < chars.count, chars[j] == "\n", c != "`" { break }
                    j += 1
                }
                j = min(j + 1, chars.count)
                append(String(chars[i..<j]), string)
                i = j
                continue
            }
            // Numbers
            if c.isNumber, i == 0 || !(chars[i - 1].isLetter || chars[i - 1] == "_") {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "_" || chars[j] == "x" { j += 1 }
                append(String(chars[i..<j]), number)
                i = j
                continue
            }
            // Words: keywords, calls, Types
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                let next = chars[j...].first { $0 != " " }
                let color: Color
                if keywords.contains(word) || (sql && keywords.contains(word.lowercased())) {
                    color = keyword
                } else if next == "(" {
                    color = call
                } else if word.first?.isUppercase == true, word.count > 1 {
                    color = type
                } else {
                    color = plain
                }
                append(word, color)
                i = j
                continue
            }
            append(String(c), plain)
            i += 1
        }
        return out
    }
}
