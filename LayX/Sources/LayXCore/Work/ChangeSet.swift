import Foundation

/// One file the model proposes to create or rewrite.
public struct ProposedChange: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case create, modify }
    public var id: String { path }
    public var path: String
    public var kind: Kind
    /// The file as read when the proposal was built (`nil` for a new file).
    public var original: TextFile?
    public var newText: String
    public var diff: [DiffLine]
    public var stats: DiffStats
    public var selected = true

    public var status: String { kind == .create ? "A" : "M" }
}

/// A complete proposal: what the model said plus concrete, reviewable file changes. Nothing on disk changes
/// until `ChangeApplier.apply` is called with the user's explicit selection.
public struct ChangeSet: Sendable, Hashable {
    public var summary: String
    public var changes: [ProposedChange]
    /// Blocks that were dropped (unsafe path, binary target, unchanged…), with a reason.
    public var rejected: [(path: String, reason: String)]
    public var createdAt = Date()

    public static func == (a: ChangeSet, b: ChangeSet) -> Bool {
        a.summary == b.summary && a.changes == b.changes && a.createdAt == b.createdAt
    }
    public func hash(into h: inout Hasher) { h.combine(summary); h.combine(changes); h.combine(createdAt) }
}

// MARK: - Parsing model output

public enum ProposalParser {
    public struct Block: Sendable, Equatable {
        public var path: String
        public var content: String
    }

    /// Extracts file blocks in the requested format:
    ///
    ///     <<<FILE relative/path.ext
    ///     …complete new content…
    ///     FILE>>>
    ///
    /// Tolerates a code fence wrapped around the content and an unterminated last block (treated as incomplete
    /// and dropped). Returns the prose outside blocks as the summary.
    public static func parse(_ output: String, knownPaths: Set<String> = []) -> (summary: String, blocks: [Block]) {
        let primary = parseFileBlocks(output)
        if !primary.blocks.isEmpty || knownPaths.isEmpty { return primary }
        return parseFencedFallback(output, knownPaths: knownPaths) ?? primary
    }

    /// Fallback for models that ignore the block format but write a fenced code block directly under (or
    /// labelled with) a path that was shown to them. Only paths the model was given are accepted.
    static func parseFencedFallback(_ output: String, knownPaths: Set<String>) -> (summary: String, blocks: [Block])? {
        let lines = ThinkingParser.stripThinking(output).components(separatedBy: "\n")
        var blocks: [Block] = []
        var summary: [String] = []
        var lastPathMention: String?
        var i = 0
        func mentionedPath(_ line: String) -> String? {
            knownPaths.sorted { $0.count > $1.count }.first { line.contains($0) }
        }
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                let path = mentionedPath(t) ?? lastPathMention
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { body.append(lines[i]); i += 1 }
                if i < lines.count, let path, !blocks.contains(where: { $0.path == path }) {
                    blocks.append(Block(path: path, content: body.joined(separator: "\n") + "\n"))
                }
                lastPathMention = nil
                i += 1
                continue
            }
            if !t.isEmpty { lastPathMention = mentionedPath(t) }
            if blocks.isEmpty { summary.append(lines[i]) }
            i += 1
        }
        guard !blocks.isEmpty else { return nil }
        return (summary.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), blocks)
    }

    static func parseFileBlocks(_ output: String) -> (summary: String, blocks: [Block]) {
        let text = ThinkingParser.stripThinking(output).replacingOccurrences(of: "\r\n", with: "\n")
        var blocks: [Block] = []
        var summaryLines: [String] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("<<<FILE") {
                let path = line.dropFirst("<<<FILE".count).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
                var body: [String] = []
                var closed = false
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces) == "FILE>>>" { closed = true; break }
                    body.append(lines[i])
                    i += 1
                }
                if closed, !path.isEmpty {
                    blocks.append(Block(path: path, content: unfence(body)))
                }
                i += 1
                continue
            }
            summaryLines.append(lines[i])
            i += 1
        }
        let summary = summaryLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (summary, blocks)
    }

    /// Removes one surrounding ``` fence if the model added it inside the block.
    static func unfence(_ body: [String]) -> String {
        var b = body
        while let f = b.first, f.trimmingCharacters(in: .whitespaces).isEmpty { b.removeFirst() }
        while let l = b.last, l.trimmingCharacters(in: .whitespaces).isEmpty { b.removeLast() }
        if let f = b.first, f.trimmingCharacters(in: .whitespaces).hasPrefix("```"),
           let l = b.last, l.trimmingCharacters(in: .whitespaces) == "```", b.count >= 2 {
            b.removeFirst(); b.removeLast()
        }
        return b.joined(separator: "\n") + "\n"
    }
}

// MARK: - Building a change set

public enum ChangeSetBuilder {
    /// Turns parsed blocks into concrete changes, reading each target's current content (for diff + conflict
    /// detection). Unsafe or unreadable targets are rejected, never silently written.
    public static func build(summary: String, blocks: [ProposalParser.Block], in workspace: Workspace) -> ChangeSet {
        var changes: [ProposedChange] = []
        var rejected: [(String, String)] = []
        var seen = Set<String>()
        for block in blocks {
            var path = block.path
            if path.hasPrefix("./") { path.removeFirst(2) }
            guard !seen.contains(path) else { rejected.append((path, "listed twice; the first version is used")); continue }
            do {
                let url = try workspace.resolve(path)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                    guard !isDir.boolValue else { rejected.append((path, "is a folder")); continue }
                    let original = try TextFile.read(path, in: workspace)
                    var newText = block.content
                    if original.text.hasSuffix("\n") == false, newText.hasSuffix("\n") { newText.removeLast() }
                    guard newText != original.text else { rejected.append((path, "no changes")); continue }
                    let d = LineDiff.diff(old: original.text, new: newText)
                    changes.append(ProposedChange(
                        path: path, kind: .modify, original: original, newText: newText, diff: d.lines, stats: d.stats))
                } else {
                    let d = LineDiff.diff(old: "", new: block.content)
                    changes.append(ProposedChange(
                        path: path, kind: .create, original: nil, newText: block.content, diff: d.lines, stats: d.stats))
                }
                seen.insert(path)
            } catch {
                rejected.append((path, (error as? LocalizedError)?.errorDescription ?? "rejected"))
            }
        }
        return ChangeSet(summary: summary, changes: changes, rejected: rejected)
    }
}

// MARK: - Applying (only after explicit approval)

public enum ChangeApplier {
    /// Applies `changes` (the user-approved subset) atomically as a group:
    /// 1. verify every target is unchanged since the proposal (hash) / still absent for new files;
    /// 2. stage new contents in temp files next to each target (same volume);
    /// 3. swap them in one by one, keeping the previous bytes in memory;
    /// 4. on any failure, restore every already-swapped file and remove created files/dirs.
    /// Encoding, BOM, line endings and POSIX permissions of existing files are preserved.
    @discardableResult
    public static func apply(_ changes: [ProposedChange], in workspace: Workspace,
                             fileManager fm: FileManager = .default,
                             failAfter: Int? = nil) throws -> [String] {
        // 1. Verify.
        var conflicts: [String] = []
        var targets: [(change: ProposedChange, url: URL, backup: Data?, permissions: NSNumber?)] = []
        for change in changes {
            let url = try workspace.resolve(change.path)
            switch change.kind {
            case .modify:
                guard let original = change.original, let current = try? Data(contentsOf: url),
                      TextFile.hash(current) == original.sha256
                else { conflicts.append(change.path); continue }
                let perms = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
                targets.append((change, url, current, perms))
            case .create:
                guard !fm.fileExists(atPath: url.path) else { conflicts.append(change.path); continue }
                targets.append((change, url, nil, nil))
            }
        }
        guard conflicts.isEmpty else { throw WorkspaceError.conflict(conflicts) }

        // 2. Stage.
        var createdDirs: [URL] = []
        var staged: [URL] = []
        func cleanupStaged() { for t in staged { try? fm.removeItem(at: t) } }
        do {
            for t in targets {
                let dir = t.url.deletingLastPathComponent()
                if !fm.fileExists(atPath: dir.path) {
                    // Record each directory level we create, outermost first, for rollback.
                    var missing: [URL] = []
                    var d = dir
                    while !fm.fileExists(atPath: d.path), ModelStore.isContained(d, in: workspace.root) {
                        missing.insert(d, at: 0)
                        d = d.deletingLastPathComponent()
                    }
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    createdDirs.append(contentsOf: missing)
                }
                guard ModelStore.isContained(t.url, in: workspace.root) else { throw WorkspaceError.outsideWorkspace(t.change.path) }
                let file = t.change.original ?? .new(t.change.path)
                guard let data = file.encode(t.change.newText) else {
                    throw WorkspaceError.applyFailed("\(t.change.path) can’t be saved in its original encoding", rolledBack: true)
                }
                let tmp = dir.appendingPathComponent(".\(t.url.lastPathComponent).layx-\(UUID().uuidString.prefix(8)).tmp")
                try data.write(to: tmp)
                if let p = t.permissions { try? fm.setAttributes([.posixPermissions: p], ofItemAtPath: tmp.path) }
                staged.append(tmp)
            }
        } catch {
            cleanupStaged()
            removeDirs(createdDirs, fm)
            if let e = error as? WorkspaceError { throw e }
            throw WorkspaceError.applyFailed(error.localizedDescription, rolledBack: true)
        }

        // 3. Commit.
        var committed: [Int] = []
        do {
            for (i, t) in targets.enumerated() {
                if let failAfter, i >= failAfter { throw CocoaError(.fileWriteUnknown) }  // test hook
                if t.change.kind == .modify {
                    _ = try fm.replaceItemAt(t.url, withItemAt: staged[i])
                } else {
                    try fm.moveItem(at: staged[i], to: t.url)
                }
                committed.append(i)
            }
        } catch {
            // 4. Roll back.
            var restored = true
            for i in committed.reversed() {
                let t = targets[i]
                if let backup = t.backup {
                    do { try backup.write(to: t.url, options: .atomic) } catch { restored = false }
                } else {
                    do { try fm.removeItem(at: t.url) } catch { restored = false }
                }
            }
            for (i, tmp) in staged.enumerated() where !committed.contains(i) { try? fm.removeItem(at: tmp) }
            removeDirs(createdDirs, fm)
            throw WorkspaceError.applyFailed(error.localizedDescription, rolledBack: restored)
        }
        return targets.map(\.change.path)
    }

    private static func removeDirs(_ dirs: [URL], _ fm: FileManager) {
        for d in dirs.reversed() where (try? fm.contentsOfDirectory(atPath: d.path))?.isEmpty == true {
            try? fm.removeItem(at: d)
        }
    }
}
