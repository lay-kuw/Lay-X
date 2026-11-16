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

    static func ops(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        let max = n + m
        if max == 0 { return [] }
        var v = [Int](repeating: 0, count: 2 * max + 2)
        var trace: [[Int]] = []
        let offset = max + 1
        outer: for d in 0...max {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n, y >= m { trace.append(v); break outer }
            }
        }
        // Backtrack.
        var result: [Op] = []
        var x = n, y = m
        for d in stride(from: trace.count - 2, through: 0, by: -1) {
            let vd = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && vd[offset + k - 1] < vd[offset + k + 1]) { prevK = k + 1 } else { prevK = k - 1 }
            let prevX = vd[offset + prevK]
            let prevY = prevX - prevK
            while x > prevX, y > prevY { x -= 1; y -= 1; result.append(.equal(x, y)) }
            if d > 0 {
                if x == prevX { y -= 1; result.append(.insert(y)) } else { x -= 1; result.append(.delete(x)) }
            }
        }
        while x > 0, y > 0 { x -= 1; y -= 1; result.append(.equal(x, y)) }
        return result.reversed()
    }

    public static func stats(old: String, new: String) -> DiffStats {
        var s = DiffStats(added: 0, removed: 0)
        for op in ops(lines(old), lines(new)) {
            switch op {
            case .insert: s.added += 1
            case .delete: s.removed += 1
            case .equal: break
            }
        }
        return s
    }

    /// Unified diff with `context` lines around each change.
    public static func unified(old: String, new: String, context: Int = 3) -> [DiffLine] {
        let a = lines(old), b = lines(new)
        let all = ops(a, b)
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
