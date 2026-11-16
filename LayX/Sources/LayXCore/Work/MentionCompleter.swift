import Foundation

/// `@path` completion for Work requests.
public enum MentionCompleter {
    public struct Suggestion: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable {
            case file, folder
            /// `@all` — every file in the project.
            case all
            /// A path that doesn't exist yet — Work will create it.
            case new
        }
        public var id: String { "\(kind)-\(path)" }
        public var path: String
        public var kind: Kind
        public var isDirectory: Bool { kind == .folder }
        public var name: String { kind == .all ? "all" : String(path.split(separator: "/").last ?? "") }
        /// Text inserted after "@" (folders end with "/" so completion can continue inside them).
        public var insertion: String { isDirectory ? path + "/" : path }

        public init(path: String, isDirectory: Bool) {
            self.path = path
            self.kind = isDirectory ? .folder : .file
        }

        public init(path: String, kind: Kind) {
            self.path = path
            self.kind = kind
        }
    }

    /// The `@…` token being typed at the end of `text` (without the "@"), or nil.
    public static func activeQuery(in text: String) -> String? {
        guard let last = text.last, !last.isWhitespace else { return nil }
        let token = text.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        guard token.hasPrefix("@") else { return nil }
        return String(token.dropFirst())
    }

    /// Ranked files and folders for `query`: name prefix > path-component prefix > substring; then shallower,
    /// then folders before files. `@all` is offered while the query is a prefix of "all"; a query that looks
    /// like a new file path (has an extension, matches nothing exactly) is offered as "create".
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
        var out = scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.depth != b.0.depth { return a.0.depth < b.0.depth }
            if a.0.isDirectory != b.0.isDirectory { return a.0.isDirectory }
            return a.0.path.localizedStandardCompare(b.0.path) == .orderedAscending
        }
        .prefix(limit)
        .map { Suggestion(path: $0.0.path, isDirectory: $0.0.isDirectory) }

        if "all".hasPrefix(q) {
            out.insert(Suggestion(path: "all", kind: .all), at: 0)
        }
        let typed = query.hasPrefix("./") ? String(query.dropFirst(2)) : query
        let last = typed.split(separator: "/").last.map(String.init) ?? ""
        if last.contains("."), !last.hasPrefix("."), !last.hasSuffix("."), !typed.contains(".."), !typed.hasPrefix("/"),
           !entries.contains(where: { $0.path == typed }) {
            out.insert(Suggestion(path: typed, kind: .new), at: 0)
        }
        return Array(out.prefix(limit))
    }

    /// Replaces the trailing `@…` token with the suggestion (files get a trailing space).
    public static func apply(_ suggestion: Suggestion, to text: String) -> String {
        guard activeQuery(in: text) != nil, let at = text.lastIndex(of: "@") else { return text }
        return String(text[..<at]) + "@" + suggestion.insertion + (suggestion.isDirectory ? "" : " ")
    }
}
