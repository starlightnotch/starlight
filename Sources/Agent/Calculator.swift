import Foundation

/// The `calculate` tool's engine: a small recursive-descent parser, so Grok never does math in
/// its head. Evaluates in microseconds on this Mac.
///
///   numbers      12, 3.5, 1e6, 1,000 (thousands separators are dropped)
///   operators    + - * / ^ (or **), % (modulo), n% (percent, so 20% * 85 = 17), n! (factorial)
///   functions    sqrt cbrt abs exp ln log log2 log10 sin cos tan asin acos atan sinh cosh tanh
///                floor ceil round min max pow hypot
///   constants    pi, e, tau
///   equations    one unknown and "=", e.g. 2x + 3 = 7 or x^2 = 2 (returns every real root found)
///
/// Implicit multiplication works between numbers, brackets and names: 2pi, 3(4+1), 2x.
enum Calculator {
    enum Failure: LocalizedError {
        case syntax(String), unknown(String), domain(String)
        var errorDescription: String? {
            switch self {
            case .syntax(let s): "Couldn't read the expression: \(s)"
            case .unknown(let s): "Unknown name: \(s)"
            case .domain(let s): s
            }
        }
    }

    struct Result {
        let text: String     // what the model sees
        let display: String  // what the notch shows
    }

    static func evaluate(_ input: String) throws -> Result {
        let cleaned = clean(input)
        let sides = cleaned.split(separator: "=", omittingEmptySubsequences: false).map(String.init)
        if sides.count == 2 {
            return try solve(left: sides[0], right: sides[1], original: cleaned)
        }
        guard sides.count == 1 else { throw Failure.syntax("more than one =") }
        let value = try Parser.value(cleaned)
        guard value.isFinite else { throw Failure.domain("The result isn't a finite number.") }
        let shown = format(value)
        return Result(text: shown, display: "\(pretty(cleaned)) = \(shown)")
    }

    // MARK: Equations

    /// Finds real roots of left − right in one unknown by scanning for sign changes and refining
    /// with bisection, then Newton polishing. Covers linear, polynomial and most smooth equations.
    private static func solve(left: String, right: String, original: String) throws -> Result {
        let variable = try unknown(in: left + " " + right)
        let f: (Double) throws -> Double = { x in
            try Parser.value(left, variable: variable, at: x) - Parser.value(right, variable: variable, at: x)
        }
        var roots: [Double] = []
        func add(_ r: Double) {
            guard r.isFinite, abs((try? f(r)) ?? .infinity) < 1e-7 * max(1, abs(r)) else { return }
            if !roots.contains(where: { abs($0 - r) < 1e-6 * max(1, abs(r)) }) { roots.append(r) }
        }
        // Scan a wide log-spaced grid on both sides of zero.
        var grid: [Double] = [0]
        var step = 1e-3
        while step < 1e7 { grid.append(step); grid.append(-step); step *= 1.25 }
        grid.sort()
        var previous: (x: Double, y: Double)? = nil
        for x in grid {
            guard let y = try? f(x), y.isFinite else { previous = nil; continue }
            if y == 0 { add(x) }
            if let p = previous, p.y.sign != y.sign, p.y != 0 {
                var lo = p.x, hi = x, flo = p.y
                for _ in 0..<200 {
                    let mid = (lo + hi) / 2
                    guard let fm = try? f(mid) else { break }
                    if fm.sign == flo.sign { lo = mid; flo = fm } else { hi = mid }
                }
                add((lo + hi) / 2)
            }
            previous = (x, y)
        }
        // Double roots (x^2 = 0) touch zero without crossing: try Newton from a few starts.
        for start in [0.5, -0.5, 1, -1, 10, -10] where roots.isEmpty {
            var x = start
            for _ in 0..<60 {
                guard let y = try? f(x), let y2 = try? f(x + 1e-6) else { break }
                let slope = (y2 - y) / 1e-6
                guard slope != 0, slope.isFinite else { break }
                x -= y / slope
            }
            add(x)
        }
        guard !roots.isEmpty else { throw Failure.domain("No real solution found for \(original).") }
        let shown = roots.sorted().map { "\(variable) = \(format($0))" }.joined(separator: ", ")
        return Result(text: shown, display: "\(pretty(original)) → \(shown)")
    }

    private static func unknown(in text: String) throws -> String {
        let names = Set(text.matches(of: #/[A-Za-z_][A-Za-z_0-9]*/#).map { String($0.output) })
            .subtracting(Parser.functions.keys).subtracting(Parser.constants.keys)
        guard names.count == 1, let name = names.first else {
            throw Failure.syntax(names.isEmpty ? "an equation needs one unknown, like x" : "more than one unknown: \(names.sorted().joined(separator: ", "))")
        }
        return name
    }

    // MARK: Text

    private static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "**", with: "^")
            .replacingOccurrences(of: "π", with: "pi").replacingOccurrences(of: "√", with: "sqrt")
        t = t.replacingOccurrences(of: #"(?<=\d),(?=\d{3}\b)"#, with: "", options: .regularExpression)
        // "18% of 240", "half of 30" style: "of" multiplies.
        t = t.replacingOccurrences(of: #"\s+of\s+"#, with: " * ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "$", with: "")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pretty(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "*", with: " × ").replacingOccurrences(of: "/", with: " ÷ ")
            .replacingOccurrences(of: "+", with: " + ").replacingOccurrences(of: "=", with: " = ")
        // Binary minus gets spaces; a leading or unary minus (after an operator or bracket) doesn't.
        t = t.replacingOccurrences(of: #"(?<=[\w)!%.])\s*-\s*"#, with: " - ", options: .regularExpression)
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Whole numbers with separators, others to 10 significant digits.
    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 {
            return Int64(v).formatted(.number.grouping(.automatic))
        }
        if abs(v) >= 1e15 || abs(v) < 1e-6 { return String(format: "%.6g", v) }
        return v.formatted(.number.precision(.significantDigits(1...10)).grouping(.automatic))
    }

    // MARK: Parser

    private struct Parser {
        static let functions: [String: ([Double]) throws -> Double] = [
            "sqrt": { try one($0) { x in guard x >= 0 else { throw Failure.domain("Square root of a negative number.") }; return x.squareRoot() } },
            "cbrt": { try one($0, Foundation.cbrt) }, "abs": { try one($0, Swift.abs) }, "exp": { try one($0, Foundation.exp) },
            "ln": { try one($0, Foundation.log) }, "log": { try one($0, Foundation.log10) }, "log10": { try one($0, Foundation.log10) },
            "log2": { try one($0, Foundation.log2) },
            "sin": { try one($0, Foundation.sin) }, "cos": { try one($0, Foundation.cos) }, "tan": { try one($0, Foundation.tan) },
            "asin": { try one($0, Foundation.asin) }, "acos": { try one($0, Foundation.acos) }, "atan": { try one($0, Foundation.atan) },
            "sinh": { try one($0, Foundation.sinh) }, "cosh": { try one($0, Foundation.cosh) }, "tanh": { try one($0, Foundation.tanh) },
            "floor": { try one($0, Foundation.floor) }, "ceil": { try one($0, Foundation.ceil) }, "round": { try one($0) { $0.rounded() } },
            "min": { args in guard let m = args.min() else { throw Failure.syntax("min needs values") }; return m },
            "max": { args in guard let m = args.max() else { throw Failure.syntax("max needs values") }; return m },
            "pow": { args in guard args.count == 2 else { throw Failure.syntax("pow takes two values") }; return Foundation.pow(args[0], args[1]) },
            "hypot": { args in guard args.count == 2 else { throw Failure.syntax("hypot takes two values") }; return Foundation.hypot(args[0], args[1]) },
        ]
        static let constants: [String: Double] = ["pi": .pi, "e": M_E, "tau": 2 * .pi]

        private static func one(_ args: [Double], _ f: (Double) throws -> Double) throws -> Double {
            guard args.count == 1 else { throw Failure.syntax("expected one value") }
            return try f(args[0])
        }

        private let chars: [Character]
        private var i = 0
        private let variable: String?
        private let value: Double

        static func value(_ text: String, variable: String? = nil, at x: Double = 0) throws -> Double {
            var parser = Parser(text, variable: variable, value: x)
            return try parser.parse()
        }

        init(_ text: String, variable: String? = nil, value: Double = 0) {
            chars = Array(text)
            self.variable = variable
            self.value = value
        }

        mutating func parse() throws -> Double {
            let v = try expression()
            skip()
            guard i == chars.count else { throw Failure.syntax("unexpected \"\(String(chars[i...]))\"") }
            return v
        }

        private mutating func skip() { while i < chars.count, chars[i].isWhitespace { i += 1 } }
        private mutating func peek() -> Character? { skip(); return i < chars.count ? chars[i] : nil }

        private mutating func expression() throws -> Double {
            var v = try term()
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                let rhs = try term()
                v = c == "+" ? v + rhs : v - rhs
            }
            return v
        }

        private mutating func term() throws -> Double {
            var v = try unary()
            while let c = peek() {
                if c == "*" || c == "/" || c == "%" {
                    i += 1
                    let rhs = try unary()
                    if c == "*" { v *= rhs }
                    else if c == "/" { guard rhs != 0 else { throw Failure.domain("Division by zero.") }; v /= rhs }
                    else { v = v.truncatingRemainder(dividingBy: rhs) }
                } else if c == "(" || c.isLetter || c.isNumber || c == "." {
                    v *= try unary()  // implicit multiplication: 2pi, 3(4+1), 2x
                } else {
                    break
                }
            }
            return v
        }

        private mutating func unary() throws -> Double {
            if let c = peek(), c == "-" || c == "+" {
                i += 1
                let v = try unary()
                return c == "-" ? -v : v
            }
            return try power()
        }

        private mutating func power() throws -> Double {
            let base = try postfix()
            if peek() == "^" {
                i += 1
                let exponent = try unary()  // right-associative: 2^3^2 = 2^9
                return Foundation.pow(base, exponent)
            }
            return base
        }

        private mutating func postfix() throws -> Double {
            var v = try primary()
            while let c = peek() {
                if c == "!" {
                    i += 1
                    guard v >= 0, v == v.rounded(), v <= 170 else { throw Failure.domain("Factorial needs a whole number from 0 to 170.") }
                    v = (1...max(Int(v), 1)).reduce(1.0) { $0 * Double($1) }
                } else if c == "%" {
                    // Percent when nothing that could be a right operand follows: "20% * 85", "15%".
                    let after = chars[(i + 1)...].first { !$0.isWhitespace }
                    if after == nil || after == ")" || after == "*" || after == "/" || after == "+" || after == "-" || after == "^" || after == "," {
                        i += 1
                        v /= 100
                    } else { break }
                } else { break }
            }
            return v
        }

        private mutating func primary() throws -> Double {
            guard let c = peek() else { throw Failure.syntax("expression ends early") }
            if c == "(" {
                i += 1
                let v = try expression()
                guard peek() == ")" else { throw Failure.syntax("missing )") }
                i += 1
                return v
            }
            if c.isNumber || c == "." { return try number() }
            if c.isLetter || c == "_" {
                var name = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { name.append(chars[i]); i += 1 }
                let lower = name.lowercased()
                if let f = Self.functions[lower] {
                    guard peek() == "(" else {
                        return try f([try power()])  // sqrt 16, sin pi
                    }
                    i += 1
                    var args = [try expression()]
                    while peek() == "," { i += 1; args.append(try expression()) }
                    guard peek() == ")" else { throw Failure.syntax("missing ) after \(name)") }
                    i += 1
                    return try f(args)
                }
                if let constant = Self.constants[lower] { return constant }
                if name == variable { return value }
                throw Failure.unknown(name)
            }
            throw Failure.syntax("unexpected \"\(c)\"")
        }

        private mutating func number() throws -> Double {
            let start = i
            while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
            if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                // Scientific notation only when digits follow (so "2e" stays 2 × e).
                var j = i + 1
                if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                if j < chars.count, chars[j].isNumber {
                    i = j
                    while i < chars.count, chars[i].isNumber { i += 1 }
                }
            }
            guard let v = Double(String(chars[start..<i])) else { throw Failure.syntax("bad number \(String(chars[start..<i]))") }
            return v
        }
    }
}
