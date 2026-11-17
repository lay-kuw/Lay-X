import Foundation

/// Index of reusable KV caches, independent of the inference backend (the payload is the backend's cache).
///
/// - Conversation cache: an entry per `key` (e.g. a chat session). The next turn takes it exclusively (no copy)
///   and only the new suffix of the prompt is prefilled.
/// - Prefix cache: a request without its own entry may start from the longest shared token prefix of any
///   entry (the caller copies the payload, so the original stays intact) — e.g. the same Soul/system prompt.
/// - Bounded: least-recently-used entries are evicted beyond `budgetBytes`; evicted payloads are returned so
///   the caller can release them safely.
public struct PromptCacheIndex<Payload> {
    public struct Entry {
        public let id: UUID
        public let key: String?
        public let tokens: [Int]
        public let bytes: Int64
        public let payload: Payload
        var lastUsed: UInt64
    }

    public struct Match {
        public let entry: Entry
        /// Tokens shared with the prompt (≤ prompt count − 1, so at least one token is always prefilled).
        public let shared: Int
        /// true = removed from the index and owned by the caller; false = shared, the caller must copy.
        public let exclusive: Bool
    }

    public private(set) var entries: [Entry] = []
    public var budgetBytes: Int64
    private var clock: UInt64 = 0

    public init(budgetBytes: Int64) { self.budgetBytes = budgetBytes }

    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    public static func commonPrefix(_ a: [Int], _ b: [Int]) -> Int {
        var n = 0
        let limit = min(a.count, b.count)
        while n < limit, a[n] == b[n] { n += 1 }
        return n
    }

    /// Best cache for `prompt`: the entry for `key` if it shares any prefix (taken exclusively), else the
    /// longest shared prefix ≥ `minShared` among all entries (shared, copy before use).
    /// `exactOnly`: only entries whose whole token list is a prefix of the prompt (for caches that can't be
    /// rewound, e.g. state-space layers).
    public mutating func take(key: String?, prompt: [Int], minShared: Int = 32, exactOnly: Bool = false) -> Match? {
        guard prompt.count > 1 else { return nil }
        clock += 1
        func usable(_ e: Entry, _ shared: Int) -> Bool { !exactOnly || shared == e.tokens.count }
        if let key, let i = entries.firstIndex(where: { $0.key == key }) {
            let entry = entries.remove(at: i)
            let shared = min(Self.commonPrefix(entry.tokens, prompt), prompt.count - 1)
            if usable(entry, shared), shared > 0 { return Match(entry: entry, shared: shared, exclusive: true) }
            // Unusable for this prompt: fall through to prefix sharing (the stale entry is dropped).
        }
        var best: (index: Int, shared: Int)?
        for (i, e) in entries.enumerated() {
            let shared = min(Self.commonPrefix(e.tokens, prompt), prompt.count - 1)
            if shared >= minShared, usable(e, shared), shared > (best?.shared ?? 0) { best = (i, shared) }
        }
        guard let best else { return nil }
        entries[best.index].lastUsed = clock
        return Match(entry: entries[best.index], shared: best.shared, exclusive: false)
    }

    /// Stores a cache (replacing any entry with the same key). Returns payloads evicted to stay within budget.
    @discardableResult
    public mutating func insert(key: String?, tokens: [Int], bytes: Int64, payload: Payload) -> [Payload] {
        var evicted: [Payload] = []
        if let key, let i = entries.firstIndex(where: { $0.key == key }) { evicted.append(entries.remove(at: i).payload) }
        guard budgetBytes > 0, bytes <= budgetBytes, !tokens.isEmpty else { return evicted + [payload] }
        clock += 1
        entries.append(Entry(id: UUID(), key: key, tokens: tokens, bytes: bytes, payload: payload, lastUsed: clock))
        while totalBytes > budgetBytes, let lru = entries.indices.min(by: { entries[$0].lastUsed < entries[$1].lastUsed }) {
            evicted.append(entries.remove(at: lru).payload)
        }
        return evicted
    }

    /// Removes the entry for `key` (e.g. the chat was deleted).
    public mutating func remove(key: String) -> [Payload] {
        let removed = entries.filter { $0.key == key }.map(\.payload)
        entries.removeAll { $0.key == key }
        return removed
    }

    public mutating func removeAll() -> [Payload] {
        defer { entries.removeAll() }
        return entries.map(\.payload)
    }

    /// Shrinks the budget (or applies a new one), returning evicted payloads.
    public mutating func setBudget(_ bytes: Int64) -> [Payload] {
        budgetBytes = bytes
        var evicted: [Payload] = []
        while totalBytes > budgetBytes, let lru = entries.indices.min(by: { entries[$0].lastUsed < entries[$1].lastUsed }) {
            evicted.append(entries.remove(at: lru).payload)
        }
        return evicted
    }
}
