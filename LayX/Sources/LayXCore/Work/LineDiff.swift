import Foundation

/// One rendered line of a unified diff.
public struct DiffLine: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case context, added, removed, hunk }
    public var id: Int
    public var kind: Kind
    public var old: Int?
    public var new: Int?
    public var text: String

    public init(id: Int, kind: Kind, old: Int?, new: Int?, text: String) {
        self.id = id
        self.kind = kind
        self.old = old
        self.new = new
        self.text = text
    }
}

public struct DiffStats: Sendable, Hashable {
    public var added: Int
    public var removed: Int
}

/// Line diff (Myers O(ND)) with unified hunks.
public enum LineDiff {
    enum Op: Equatable { case equal(Int, Int), insert(Int), delete(Int) }

    public static func lines(_ s: String) -> [String] {
        if s.isEmpty { return [] }
        var l = s.components(separatedBy: "\n")
        if l.last == "" { l.removeLast() }
        return l
    }

    /// Most edit-distance trace cells kept (≈ 16 MB of Ints). Past it the changed middle is reported as one
    /// replacement block — still a correct diff, just not minimal.
    static let maxTraceCells = 2_000_000

    static func ops(_ a: [String], _ b: [String]) -> [Op] {
        // Common prefix and suffix are equal runs: keep them out of the O(ND) search.
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1 }
        var result = (0..<start).map { Op.equal($0, $0) }
        result += middle(a, b, from: start, a: endA, b: endB)
        result += (0..<(a.count - endA)).map { Op.equal(endA + $0, endB + $0) }
        return result
    }

    /// Myers on a[lo..<hiA] vs b[lo..<hiB]. The trace keeps only the band −d…d of each round (O(D²) memory,
    /// not O(D·(N+M))), and gives up to a plain replacement past `maxTraceCells`.
    private static func middle(_ a: [String], _ b: [String], from lo: Int, a hiA: Int, b hiB: Int) -> [Op] {
        let n = hiA - lo, m = hiB - lo
        if n == 0 && m == 0 { return [] }
        if n == 0 { return (0..<m).map { .insert(lo + $0) } }
        if m == 0 { return (0..<n).map { .delete(lo + $0) } }
        let max = n + m
        let offset = max + 1
        var v = [Int](repeating: 0, count: 2 * max + 2)
        var trace: [[Int]] = []   // trace[d][k + d] = v[k] before round d, for k in −d…d
        var cells = 0
        var found = false
        outer: for d in 0...max {
            trace.append(Array(v[(offset - d)...(offset + d)]))
            cells += 2 * d + 1
            if cells > maxTraceCells { break }
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[lo + x] == b[lo + y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n, y >= m { found = true; break outer }
            }
        }
        guard found else {
            return (0..<n).map { .delete(lo + $0) } + (0..<m).map { .insert(lo + $0) }
        }
        var result: [Op] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let band = trace[d]
            func vd(_ k: Int) -> Int { band[k + d] }
            let k = x - y
            let prevK = (k == -d || (k != d && vd(k - 1) < vd(k + 1))) ? k + 1 : k - 1
            let prevX = d == 0 ? 0 : vd(prevK)
            let prevY = prevX - prevK
            while x > prevX, y > prevY { x -= 1; y -= 1; result.append(.equal(lo + x, lo + y)) }
            if d > 0 {
                if x == prevX { y -= 1; result.append(.insert(lo + y)) } else { x -= 1; result.append(.delete(lo + x)) }
            }
        }
        while x > 0, y > 0 { x -= 1; y -= 1; result.append(.equal(lo + x, lo + y)) }
        return result.reversed()
    }

    public static func stats(old: String, new: String) -> DiffStats { diff(old: old, new: new).stats }

    /// The unified diff and its counts from one computation.
    public static func diff(old: String, new: String, context: Int = 3) -> (lines: [DiffLine], stats: DiffStats) {
        let a = lines(old), b = lines(new)
        let all = ops(a, b)
        var stats = DiffStats(added: 0, removed: 0)
        for op in all {
            switch op {
            case .insert: stats.added += 1
            case .delete: stats.removed += 1
            case .equal: break
            }
        }
        return (render(all, a, b, context: context), stats)
    }

    /// Unified diff with `context` lines around each change.
    public static func unified(old: String, new: String, context: Int = 3) -> [DiffLine] {
        diff(old: old, new: new, context: context).lines
    }

    static func render(_ all: [Op], _ a: [String], _ b: [String], context: Int) -> [DiffLine] {
        guard all.contains(where: { if case .equal = $0 { false } else { true } }) else { return [] }
        // Mark ops to keep (changes plus surrounding context).
        var keep = [Bool](repeating: false, count: all.count)
        for (i, op) in all.enumerated() {
            if case .equal = op { continue }
            for j in Swift.max(0, i - context)...Swift.min(all.count - 1, i + context) { keep[j] = true }
        }
        var out: [DiffLine] = []
        var i = 0
        var id = 0
        while i < all.count {
            guard keep[i] else { i += 1; continue }
            var j = i
            while j < all.count, keep[j] { j += 1 }
            let chunk = all[i..<j]
            let oldStart = chunk.compactMap { op -> Int? in
                switch op { case .equal(let x, _), .delete(let x): x; case .insert: nil }
            }.first.map { $0 + 1 } ?? 0
            let newStart = chunk.compactMap { op -> Int? in
                switch op { case .equal(_, let y), .insert(let y): y; case .delete: nil }
            }.first.map { $0 + 1 } ?? 0
            let oldCount = chunk.filter { if case .insert = $0 { false } else { true } }.count
            let newCount = chunk.filter { if case .delete = $0 { false } else { true } }.count
            out.append(DiffLine(id: id, kind: .hunk, old: nil, new: nil,
                                text: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"))
            id += 1
            for op in chunk {
                switch op {
                case .equal(let x, let y): out.append(DiffLine(id: id, kind: .context, old: x + 1, new: y + 1, text: a[x]))
                case .delete(let x): out.append(DiffLine(id: id, kind: .removed, old: x + 1, new: nil, text: a[x]))
                case .insert(let y): out.append(DiffLine(id: id, kind: .added, old: nil, new: y + 1, text: b[y]))
                }
                id += 1
            }
            i = j
        }
        return out
    }
}
