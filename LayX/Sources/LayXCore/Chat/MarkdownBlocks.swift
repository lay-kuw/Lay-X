import Foundation

/// Block-level Markdown split used by the chat renderer. Inline formatting (bold, code spans, links) is left to
/// `AttributedString(markdown:)`; this parser only separates the structures that need their own views.
/// It tolerates incomplete input (an unterminated code fence while streaming renders as an open code block).
public enum MarkdownBlock: Sendable, Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case listItem(marker: String, text: String, indent: Int)
    case code(language: String?, code: String, closed: Bool)
    case quote(String)
    case rule
}

public enum MarkdownParser {
    public static func blocks(_ source: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        func flushQuote() {
            if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"))) }
            quote = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph(); flushQuote()
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                var closed = false
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { closed = true; break }
                    code.append(lines[i])
                    i += 1
                }
                out.append(.code(language: lang.isEmpty ? nil : lang, code: code.joined(separator: "\n"), closed: closed))
                i += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph(); flushQuote()
                i += 1
                continue
            }
            if let h = heading(trimmed) {
                flushParagraph(); flushQuote()
                out.append(h)
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph(); flushQuote()
                out.append(.rule)
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
            } else if let item = listItem(line) {
                flushParagraph(); flushQuote()
                out.append(item)
            } else {
                flushQuote()
                paragraph.append(line)
            }
            i += 1
        }
        flushParagraph(); flushQuote()
        return out
    }

    static func heading(_ s: String) -> MarkdownBlock? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), s.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: s.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " }.count / 2
        let s = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "* ", "+ ", "• "] where s.hasPrefix(bullet) {
            return .listItem(marker: "•", text: String(s.dropFirst(bullet.count)), indent: indent)
        }
        if let dot = s.firstIndex(where: { $0 == "." || $0 == ")" }),
           s[s.startIndex..<dot].allSatisfy(\.isNumber), !s[s.startIndex..<dot].isEmpty,
           s.index(after: dot) < s.endIndex, s[s.index(after: dot)] == " " {
            return .listItem(marker: String(s[...dot]), text: String(s[s.index(dot, offsetBy: 2)...]), indent: indent)
        }
        return nil
    }
}
