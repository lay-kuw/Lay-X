import Foundation

/// `@path` completion for Work requests.
public enum MentionCompleter {
    public struct Suggestion: Sendable, Hashable, Identifiable {
        public var id: String { path }
        public var path: String
        public var isDirectory: Bool
        public var name: String { String(path.split(separator: "/").last ?? "") }
        /// Text inserted after "@" (folders end with "/" so completion can continue inside them).
        public var insertion: String { isDirectory ? path + "/" : path }
    }

    /// The `@…` token being typed at the end of `text` (without the "@"), or nil.
    public static func activeQuery(in text: String) -> String? {
        guard let last = text.last, !last.isWhitespace else { return nil }
        let token = text.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        guard token.hasPrefix("@") else { return nil }
        return String(token.dropFirst())
    }

    /// Ranked files and folders for `query`: name prefix > path-component prefix > substring; then shallower,
    /// then folders before files.
    public static func suggestions(for query: String, in entries: [WorkspaceEntry], limit: Int = 8) -> [Suggestion] {
        let q = query.lowercased()
        let scored: [(WorkspaceEntry, Int)] = entries.compactMap { e in
            let path = e.path.lowercased()
            if q.isEmpty { return e.depth == 0 ? (e, 1) : nil }
            // Typing inside a folder ("Sources/Ch") matches by path prefix.
            if q.contains("/") { return path.hasPrefix(q) ? (e, 3) : (path.contains(q) ? (e, 1) : nil) }
            let name = e.name.lowercased()
            if name.hasPrefix(q) { return (e, 3) }
            if path.split(separator: "/").contains(where: { $0.hasPrefix(q) }) { return (e, 2) }
            if path.contains(q) { return (e, 1) }
            return nil
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.depth != b.0.depth { return a.0.depth < b.0.depth }
            if a.0.isDirectory != b.0.isDirectory { return a.0.isDirectory }
            return a.0.path.localizedStandardCompare(b.0.path) == .orderedAscending
        }
        .prefix(limit)
        .map { Suggestion(path: $0.0.path, isDirectory: $0.0.isDirectory) }
    }

    /// Replaces the trailing `@…` token with the suggestion (files get a trailing space).
    public static func apply(_ suggestion: Suggestion, to text: String) -> String {
        guard activeQuery(in: text) != nil, let at = text.lastIndex(of: "@") else { return text }
        return String(text[..<at]) + "@" + suggestion.insertion + (suggestion.isDirectory ? "" : " ")
    }
}
