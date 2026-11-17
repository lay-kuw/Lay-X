import Foundation

// Prompt syntax shared by every image model:
//
// Dynamic Prompts (expanded per image before generation, all models)
//   {red|green|blue}         one option at random
//   {2::red|blue}            weighted option (default weight 1)
//   {2$$red|green|blue}      two distinct options, joined with ", "
//   {1-3$$a|b|c}  {2-$$…}    a random count in a range (`2-` = 2 up to all)
//   {2$$ and $$a|b|c}        a custom separator
//   __name__                 a random line of `name.txt` in the wildcards folder (`__dir/name__` for subfolders)
//   \{ \} \|                 literal braces / bar
//
// Emphasis (A1111 style; applied to the CLIP embeddings of SDXL-family models)
//   (word)  ×1.1   ((word)) ×1.21   [word] ÷1.1   (word:1.4) ×1.4   \( \) \[ \] literal brackets

// MARK: - Dynamic Prompts

public enum DynamicPrompt {
    public struct Result: Sendable, Hashable {
        public var text: String
        /// Wildcards used in the prompt that have no (non-empty) file.
        public var missingWildcards: Set<String>
    }

    /// Whether `text` contains variants or wildcards (otherwise expanding returns it unchanged).
    public static func hasSyntax(_ text: String) -> Bool {
        text.contains("{") || text.contains("__")
    }

    /// Expands variants and wildcards. The same `seed` always picks the same options.
    public static func expand(_ text: String, seed: UInt64, wildcards: (String) -> [String]? = { _ in nil }) -> Result {
        var rng = SplitMix64(seed: seed ^ 0x9E37_79B9_7F4A_7C15)
        var missing = Set<String>()
        var parser = Parser(Array(text))
        let nodes = parser.sequence(inBraces: false)
        let out = evaluate(nodes, rng: &rng, wildcards: wildcards, missing: &missing, depth: 0)
        return Result(text: out, missingWildcards: missing)
    }

    // AST

    indirect enum Node {
        case text(String)
        case variant(Variant)
        case wildcard(String)
    }

    struct Variant {
        var options: [(weight: Double, body: [Node])]
        var lower: Int?
        var upper: Int?
        /// `N-` (up to all options).
        var openUpper = false
        var separator = ", "
    }

    struct Parser {
        let c: [Character]
        var i = 0
        init(_ c: [Character]) { self.c = c }

        /// Text, variants and wildcards up to the end, or (inside braces) up to an unescaped `|` / `}`.
        mutating func sequence(inBraces: Bool) -> [Node] {
            var nodes: [Node] = []
            var buffer = ""
            func flush() { if !buffer.isEmpty { nodes.append(.text(buffer)); buffer = "" } }
            while i < c.count {
                let ch = c[i]
                if ch == "\\", i + 1 < c.count {
                    let next = c[i + 1]
                    // Only the Dynamic Prompts characters are unescaped; `\(` etc. are left for emphasis parsing.
                    if next == "{" || next == "}" || next == "|" { buffer.append(next) } else { buffer.append(ch); buffer.append(next) }
                    i += 2
                    continue
                }
                if inBraces, ch == "|" || ch == "}" { break }
                if ch == "{" {
                    i += 1
                    flush()
                    nodes.append(.variant(variant()))
                    continue
                }
                if ch == "_", i + 1 < c.count, c[i + 1] == "_", let (name, end) = wildcardName(from: i + 2) {
                    flush()
                    nodes.append(.wildcard(name))
                    i = end
                    continue
                }
                buffer.append(ch)
                i += 1
            }
            flush()
            return nodes
        }

        /// `name__` starting at `start`: returns the name and the index after the closing `__`.
        func wildcardName(from start: Int) -> (String, Int)? {
            var j = start
            var name = ""
            while j < c.count {
                if c[j] == "_", j + 1 < c.count, c[j + 1] == "_" {
                    // `___x__`: extra leading underscores belong to the name only if it is otherwise empty.
                    if name.isEmpty { return nil }
                    return (name, j + 2)
                }
                let ch = c[j]
                guard ch.isLetter || ch.isNumber || "_-./".contains(ch) else { return nil }
                name.append(ch)
                j += 1
            }
            return nil
        }

        /// After `{`: an optional `N$$` / `N-M$$` / `…$$sep$$` prefix, then `|`-separated options up to `}`.
        mutating func variant() -> Variant {
            var v = Variant(options: [])
            parseQuantity(into: &v)
            while true {
                let weight = parseOptionWeight()
                let body = sequence(inBraces: true)
                v.options.append((weight, body))
                if i < c.count, c[i] == "|" { i += 1; continue }
                if i < c.count, c[i] == "}" { i += 1 }
                break     // `}` or an unclosed variant at the end
            }
            return v
        }

        mutating func parseQuantity(into v: inout Variant) {
            var j = i
            var lower = "", upper = "", dash = false
            while j < c.count, c[j].isASCII, c[j].isNumber { lower.append(c[j]); j += 1 }
            if j < c.count, c[j] == "-" {
                dash = true
                j += 1
                while j < c.count, c[j].isASCII, c[j].isNumber { upper.append(c[j]); j += 1 }
            }
            guard (!lower.isEmpty || !upper.isEmpty), j + 1 < c.count, c[j] == "$", c[j + 1] == "$" else { return }
            j += 2
            v.lower = Int(lower) ?? 1
            v.upper = dash ? Int(upper) : v.lower
            v.openUpper = dash && upper.isEmpty
            // An optional separator: `…$$sep$$`, before any option delimiter.
            var k = j
            var separator = ""
            while k < c.count, c[k] != "|", c[k] != "}", c[k] != "{" {
                if c[k] == "$", k + 1 < c.count, c[k + 1] == "$" {
                    v.separator = separator
                    j = k + 2
                    break
                }
                separator.append(c[k])
                k += 1
            }
            i = j
        }

        /// `2.5::` at the start of an option.
        mutating func parseOptionWeight() -> Double {
            var j = i
            while j < c.count, c[j] == " " { j += 1 }
            var digits = ""
            while j < c.count, c[j].isASCII, c[j].isNumber || c[j] == "." { digits.append(c[j]); j += 1 }
            guard !digits.isEmpty, let w = Double(digits), j + 1 < c.count, c[j] == ":", c[j + 1] == ":" else { return 1 }
            i = j + 2
            return max(w, 0)
        }
    }

    static func evaluate(_ nodes: [Node], rng: inout SplitMix64, wildcards: (String) -> [String]?,
                         missing: inout Set<String>, depth: Int) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let s):
                out += s
            case .variant(let v):
                out += pick(v, rng: &rng).map {
                    evaluate($0, rng: &rng, wildcards: wildcards, missing: &missing, depth: depth)
                }.joined(separator: v.separator)
            case .wildcard(let name):
                guard let lines = wildcards(name), !lines.isEmpty else {
                    missing.insert(name)
                    out += "__\(name)__"
                    continue
                }
                let line = lines[Int(rng.next() % UInt64(lines.count))]
                if depth >= 10 { out += line; continue }     // a wildcard that includes itself
                var parser = Parser(Array(line))
                out += evaluate(parser.sequence(inBraces: false), rng: &rng, wildcards: wildcards,
                                missing: &missing, depth: depth + 1)
            }
        }
        return out
    }

    /// The options chosen for a variant (distinct, weighted).
    static func pick(_ v: Variant, rng: inout SplitMix64) -> [[Node]] {
        guard !v.options.isEmpty else { return [] }
        let lower = min(max(v.lower ?? 1, 0), v.options.count)
        let upper = v.openUpper ? v.options.count : min(max(v.upper ?? lower, lower), v.options.count)
        let count = lower == upper ? lower : lower + Int(rng.next() % UInt64(upper - lower + 1))
        var pool = v.options
        var chosen: [[Node]] = []
        for _ in 0..<count where !pool.isEmpty {
            let total = pool.reduce(0) { $0 + $1.weight }
            var index = pool.count - 1
            if total > 0 {
                var r = Double(rng.next() >> 11) / Double(1 << 53) * total
                for (k, option) in pool.enumerated() {
                    if r < option.weight { index = k; break }
                    r -= option.weight
                }
            } else {
                index = Int(rng.next() % UInt64(pool.count))
            }
            chosen.append(pool.remove(at: index).body)
        }
        return chosen
    }
}

/// Small deterministic generator (so a seed reproduces its prompt).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Wildcard files: `<folder>/<name>.txt`, one option per line (blank lines and `#` comments skipped).
public struct WildcardLibrary: Sendable {
    public let folder: URL?

    public init(folder: URL?) { self.folder = folder }

    /// `~/.config/lay-x/wildcards` (created if needed).
    public static func defaultFolder() throws -> URL {
        let url = LayXPaths.configRoot.appendingPathComponent("wildcards", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    public func lines(_ name: String) -> [String]? {
        guard let folder else { return nil }
        let parts = name.split(separator: "/").map(String.init)
        // Stay inside the folder.
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix(".") }) else { return nil }
        let url = parts.reduce(folder) { $0.appendingPathComponent($1) }.appendingPathExtension("txt")
        guard url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

// MARK: - Emphasis

public enum PromptWeighting {
    public struct Segment: Sendable, Hashable {
        public var text: String
        public var weight: Double
        public init(_ text: String, _ weight: Double) { self.text = text; self.weight = weight }
    }

    /// A1111 attention syntax → text runs with weights (adjacent runs of equal weight merged).
    public static func parse(_ text: String) -> [Segment] {
        var res: [Segment] = []
        var round: [Int] = []
        var square: [Int] = []
        func multiply(from start: Int, _ m: Double) {
            for p in start..<res.count { res[p].weight *= m }
        }
        let c = Array(text)
        var i = 0
        var plain = ""
        func flush() { if !plain.isEmpty { res.append(Segment(plain, 1)); plain = "" } }
        while i < c.count {
            let ch = c[i]
            switch ch {
            case "\\":
                if i + 1 < c.count, "()[]\\".contains(c[i + 1]) {
                    flush()
                    res.append(Segment(String(c[i + 1]), 1))
                    i += 2
                } else {
                    plain.append(ch)
                    i += 1
                }
            case "(":
                flush(); round.append(res.count); i += 1
            case "[":
                flush(); square.append(res.count); i += 1
            case ":":
                // `:1.3)` closes a round group with an explicit weight.
                if !round.isEmpty, let (weight, end) = explicitWeight(c, from: i + 1) {
                    flush()
                    multiply(from: round.removeLast(), weight)
                    i = end
                } else {
                    plain.append(ch)
                    i += 1
                }
            case ")":
                flush()
                if let start = round.popLast() { multiply(from: start, 1.1) } else { res.append(Segment(")", 1)) }
                i += 1
            case "]":
                flush()
                if let start = square.popLast() { multiply(from: start, 1 / 1.1) } else { res.append(Segment("]", 1)) }
                i += 1
            default:
                plain.append(ch)
                i += 1
            }
        }
        flush()
        // Unclosed brackets still apply (as in A1111).
        for start in round { multiply(from: start, 1.1) }
        for start in square { multiply(from: start, 1 / 1.1) }
        var merged: [Segment] = []
        for s in res where !s.text.isEmpty {
            if let last = merged.last, abs(last.weight - s.weight) < 1e-9 {
                merged[merged.count - 1].text += s.text
            } else {
                merged.append(s)
            }
        }
        return merged.isEmpty ? [Segment("", 1)] : merged
    }

    /// `\s*[+-]?[.\d]+\s*)` from `start`.
    static func explicitWeight(_ c: [Character], from start: Int) -> (Double, Int)? {
        var j = start
        while j < c.count, c[j] == " " { j += 1 }
        var number = ""
        if j < c.count, c[j] == "+" || c[j] == "-" { number.append(c[j]); j += 1 }
        while j < c.count, c[j].isASCII, c[j].isNumber || c[j] == "." { number.append(c[j]); j += 1 }
        while j < c.count, c[j] == " " { j += 1 }
        guard j < c.count, c[j] == ")", let w = Double(number) else { return nil }
        return (w, j + 1)
    }

    /// Whether `text` uses emphasis syntax at all.
    public static func hasSyntax(_ text: String) -> Bool {
        text.contains { "()[]\\".contains($0) }
    }

    /// For models whose text encoder is a language model (FLUX.2 klein, Qwen-Image, Z-Image): explicit
    /// `(text:1.3)` weights become `text` and `\(` escapes become `(`; other brackets stay, since they are
    /// usually ordinary punctuation there.
    public static func stripExplicitWeights(_ text: String) -> String {
        guard hasSyntax(text) else { return text }
        let c = Array(text)
        var out: [Character] = []
        var opens: [Int] = []          // positions in `out` of unmatched "("
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\\", i + 1 < c.count, "()[]\\".contains(c[i + 1]) {
                out.append(c[i + 1]); i += 2; continue
            }
            if ch == "(" { opens.append(out.count); out.append(ch); i += 1; continue }
            if ch == ")" { _ = opens.popLast(); out.append(ch); i += 1; continue }
            if ch == ":", !opens.isEmpty, let (_, end) = explicitWeight(c, from: i + 1) {
                out.remove(at: opens.removeLast())
                i = end
                continue
            }
            out.append(ch)
            i += 1
        }
        return String(out)
    }
}
