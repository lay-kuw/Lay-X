import Foundation
import Testing
@testable import LayXCore

/// Creates a throwaway project folder.
struct TempProject {
    let root: URL
    init(files: [String: String] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("layx-work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files { try write(path, text) }
    }
    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func read(_ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct WorkspaceBoundaryTests {
    @Test(arguments: ["../outside.txt", "a/../../x", "/etc/passwd", "~/x", "a/./b", "", "a\\b"])
    func traversalIsRejected(_ path: String) throws {
        let p = try TempProject(); defer { p.remove() }
        let ws = try Workspace(root: p.root)
        #expect(throws: WorkspaceError.self) { try ws.resolve(path) }
    }

    @Test func normalPathsResolveInside() throws {
        let p = try TempProject(files: ["Sources/App.swift": "x"]); defer { p.remove() }
        let ws = try Workspace(root: p.root)
        #expect(try ws.resolve("Sources/App.swift").lastPathComponent == "App.swift")
        #expect(try ws.resolve("./New/File.swift").path.hasSuffix("New/File.swift"))
        #expect(ws.relativePath(of: try ws.resolve("Sources/App.swift")) == "Sources/App.swift")
    }

    @Test func symlinkEscapeIsRejected() throws {
        let p = try TempProject(); defer { p.remove() }
        let outside = try TempProject(files: ["secret.txt": "s"]); defer { outside.remove() }
        try FileManager.default.createSymbolicLink(at: p.root.appendingPathComponent("link"), withDestinationURL: outside.root)
        let ws = try Workspace(root: p.root)
        #expect(throws: WorkspaceError.self) { try ws.resolve("link/secret.txt") }
        #expect(throws: WorkspaceError.self) { try ws.resolve("link/new.txt") }
        // Scanner lists nothing behind the symlink.
        #expect(!WorkspaceScanner.scan(ws).contains { $0.path.hasPrefix("link") })
    }

    @Test func scannerSkipsBuildAndVCSDirectories() throws {
        let p = try TempProject(files: ["a.swift": "x", ".git/config": "x", "node_modules/m/i.js": "x", ".build/o": "x", "src/b.ts": "y"])
        defer { p.remove() }
        let paths = Set(WorkspaceScanner.scan(try Workspace(root: p.root)).map(\.path))
        #expect(paths == ["a.swift", "src", "src/b.ts"])
    }
}

@Suite struct TextFileTests {
    @Test func crlfAndBOMArePreservedOnWrite() throws {
        let p = try TempProject(); defer { p.remove() }
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb\r\n".utf8)
        try bytes.write(to: p.root.appendingPathComponent("w.txt"))
        let ws = try Workspace(root: p.root)
        let f = try TextFile.read("w.txt", in: ws)
        #expect(f.text == "a\nb\n")
        #expect(f.lineEnding == .crlf && f.hasBOM)
        #expect(f.encode("a\nB\nc\n") == Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nB\r\nc\r\n".utf8))
    }

    @Test func utf16RoundTrip() throws {
        let p = try TempProject(); defer { p.remove() }
        var data = Data([0xFF, 0xFE]); data.append("こんにちは\n".data(using: .utf16LittleEndian)!)
        try data.write(to: p.root.appendingPathComponent("u.txt"))
        let f = try TextFile.read("u.txt", in: try Workspace(root: p.root))
        #expect(f.text == "こんにちは\n")
        #expect(f.encode(f.text) == data)
    }

    @Test func binaryIsRejected() throws {
        let p = try TempProject(); defer { p.remove() }
        try Data([0x00, 0x01, 0x02, 0x00]).write(to: p.root.appendingPathComponent("b.bin"))
        #expect(throws: WorkspaceError.notText("b.bin")) { try TextFile.read("b.bin", in: try Workspace(root: p.root)) }
    }
}

@Suite struct LineDiffTests {
    @Test func unifiedHunkWithContext() {
        let old = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var newLines = (1...10).map { "line \($0)" }
        newLines[4] = "LINE 5"
        newLines.insert("inserted", at: 7)
        let diff = LineDiff.unified(old: old, new: newLines.joined(separator: "\n") + "\n", context: 1)
        #expect(diff.first?.kind == .hunk)
        #expect(diff.filter { $0.kind == .removed }.map(\.text) == ["line 5"])
        #expect(diff.filter { $0.kind == .added }.map(\.text) == ["LINE 5", "inserted"])
        #expect(LineDiff.stats(old: old, new: newLines.joined(separator: "\n") + "\n") == DiffStats(added: 2, removed: 1))
    }

    @Test func identicalTextHasNoDiff() {
        #expect(LineDiff.unified(old: "a\nb\n", new: "a\nb\n").isEmpty)
    }

    @Test func newFileIsAllAdditions() {
        let d = LineDiff.unified(old: "", new: "x\ny\n")
        #expect(d.filter { $0.kind == .added }.count == 2)
        #expect(d.first?.text == "@@ -0,0 +1,2 @@")
    }

    @Test func randomizedDiffReconstructsNewText() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let a = (0..<Int.random(in: 0...30, using: &rng)).map { _ in "l\(Int.random(in: 0...6, using: &rng))" }
            let b = (0..<Int.random(in: 0...30, using: &rng)).map { _ in "l\(Int.random(in: 0...6, using: &rng))" }
            var rebuilt: [String] = []
            for op in LineDiff.ops(a, b) {
                switch op {
                case .equal(let x, _): rebuilt.append(a[x])
                case .insert(let y): rebuilt.append(b[y])
                case .delete: break
                }
            }
            #expect(rebuilt == b)
        }
    }
}

@Suite struct ProposalTests {
    let output = """
    <think>plan</think>
    I'll add a greeting and a new helper.

    <<<FILE Sources/App.swift
    ```swift
    print("hello")
    print("world")
    ```
    FILE>>>

    <<<FILE Sources/Helper.swift
    func help() {}
    FILE>>>

    <<<FILE ../escape.txt
    nope
    FILE>>>

    <<<FILE Sources/Unfinished.swift
    func incomplete(
    """

    @Test func parsesBlocksAndSummary() {
        let r = ProposalParser.parse(output)
        #expect(r.summary == "I'll add a greeting and a new helper.")
        #expect(r.blocks.map(\.path) == ["Sources/App.swift", "Sources/Helper.swift", "../escape.txt"])
        #expect(r.blocks[0].content == "print(\"hello\")\nprint(\"world\")\n")
    }

    @Test func fencedFallbackAcceptsOnlyKnownPaths() {
        let out = "Here is the update.\n\nSources/App.swift:\n```swift\nprint(1)\n```\n\n/etc/hosts\n```\nevil\n```\n"
        let r = ProposalParser.parse(out, knownPaths: ["Sources/App.swift"])
        #expect(r.blocks == [ProposalParser.Block(path: "Sources/App.swift", content: "print(1)\n")])
        #expect(r.summary == "Here is the update.\n\nSources/App.swift:")
        #expect(ProposalParser.parse(out).blocks.isEmpty, "no fallback without known paths")
    }

    @Test func buildsChangeSetAndRejectsUnsafePaths() throws {
        let p = try TempProject(files: ["Sources/App.swift": "print(\"hello\")\n"]); defer { p.remove() }
        let ws = try Workspace(root: p.root)
        let r = ProposalParser.parse(output)
        let set = ChangeSetBuilder.build(summary: r.summary, blocks: r.blocks, in: ws)
        #expect(set.changes.map(\.path) == ["Sources/App.swift", "Sources/Helper.swift"])
        #expect(set.changes.map(\.kind) == [.modify, .create])
        #expect(set.changes[0].stats == DiffStats(added: 1, removed: 0))
        #expect(set.rejected.map(\.path) == ["../escape.txt"])
        // Building a proposal never writes anything.
        #expect(p.read("Sources/App.swift") == "print(\"hello\")\n")
        #expect(p.read("Sources/Helper.swift") == nil)
    }
}

@Suite struct ChangeApplierTests {
    func proposal(_ p: TempProject, _ blocks: [ProposalParser.Block]) throws -> (Workspace, ChangeSet) {
        let ws = try Workspace(root: p.root)
        return (ws, ChangeSetBuilder.build(summary: "", blocks: blocks, in: ws))
    }

    @Test func appliesOnlySelectedChanges() throws {
        let p = try TempProject(files: ["a.txt": "1\n", "b.txt": "2\n"]); defer { p.remove() }
        var (ws, set) = try proposal(p, [.init(path: "a.txt", content: "one\n"), .init(path: "b.txt", content: "two\n")])
        set.changes[1].selected = false
        try ChangeApplier.apply(set.changes.filter(\.selected), in: ws)
        #expect(p.read("a.txt") == "one\n")
        #expect(p.read("b.txt") == "2\n")
    }

    @Test func conflictIsDetectedAndNothingIsWritten() throws {
        let p = try TempProject(files: ["a.txt": "1\n", "b.txt": "2\n"]); defer { p.remove() }
        let (ws, set) = try proposal(p, [.init(path: "a.txt", content: "one\n"), .init(path: "b.txt", content: "two\n")])
        try p.write("b.txt", "edited by user\n")
        #expect(throws: WorkspaceError.conflict(["b.txt"])) { try ChangeApplier.apply(set.changes, in: ws) }
        #expect(p.read("a.txt") == "1\n")
        #expect(p.read("b.txt") == "edited by user\n")
    }

    @Test func newFileConflictsIfCreatedMeanwhile() throws {
        let p = try TempProject(); defer { p.remove() }
        let (ws, set) = try proposal(p, [.init(path: "n.txt", content: "new\n")])
        try p.write("n.txt", "someone else\n")
        #expect(throws: WorkspaceError.conflict(["n.txt"])) { try ChangeApplier.apply(set.changes, in: ws) }
    }

    @Test func multiFileFailureRollsEverythingBack() throws {
        let p = try TempProject(files: ["a.txt": "1\n", "b.txt": "2\n"]); defer { p.remove() }
        let (ws, set) = try proposal(p, [.init(path: "a.txt", content: "one\n"), .init(path: "b.txt", content: "two\n"),
                                         .init(path: "new/dir/c.txt", content: "three\n")])
        #expect(throws: WorkspaceError.applyFailed(CocoaError(.fileWriteUnknown).localizedDescription, rolledBack: true)) {
            try ChangeApplier.apply(set.changes, in: ws, failAfter: 2)
        }
        #expect(p.read("a.txt") == "1\n")
        #expect(p.read("b.txt") == "2\n")
        #expect(!FileManager.default.fileExists(atPath: p.root.appendingPathComponent("new").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: p.root.path).filter { $0.contains("layx-") }
        #expect(leftovers.isEmpty)
    }

    @Test func createsNestedFilesAndPreservesPermissions() throws {
        let p = try TempProject(files: ["run.sh": "echo hi\n"]); defer { p.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.root.appendingPathComponent("run.sh").path)
        let (ws, set) = try proposal(p, [.init(path: "run.sh", content: "echo bye\n"), .init(path: "x/y/z.txt", content: "z\n")])
        try ChangeApplier.apply(set.changes, in: ws)
        #expect(p.read("run.sh") == "echo bye\n")
        #expect(p.read("x/y/z.txt") == "z\n")
        let perms = try FileManager.default.attributesOfItem(atPath: p.root.appendingPathComponent("run.sh").path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o755)
    }
}

@MainActor
@Suite(.serialized) struct WorkSessionTests {
    @Test func proposalRequiresExplicitApproval() async throws {
        let p = try TempProject(files: ["Sources/Greeter.swift": "let greeting = \"hi\"\n"]); defer { p.remove() }
        let engine = ScriptedEngine(tokens: [
            "Change the greeting.\n", "<<<FILE Sources/Greeter.swift\n", "let greeting = \"hello\"\n", "FILE>>>\n",
        ], tokenDelay: .milliseconds(1))
        let coordinator = InferenceCoordinator(engine: engine)
        try await coordinator.load(ModelReference(id: "t/m", directory: p.root))
        let session = WorkSession(workspace: try Workspace(root: p.root), coordinator: coordinator,
                                  prepareModel: { throw InferenceError.noModelLoaded })
        session.propose("Make the greeter say hello")
        for _ in 0..<200 where session.phase != .proposed && session.phase != .idle { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.phase == .proposed)
        #expect(session.changeSet?.changes.map(\.path) == ["Sources/Greeter.swift"])
        // Proposal alone writes nothing.
        #expect(p.read("Sources/Greeter.swift") == "let greeting = \"hi\"\n")
        session.reject()
        #expect(p.read("Sources/Greeter.swift") == "let greeting = \"hi\"\n")

        session.propose("again")
        for _ in 0..<200 where session.phase != .proposed { try await Task.sleep(for: .milliseconds(5)) }
        session.apply()
        #expect(p.read("Sources/Greeter.swift") == "let greeting = \"hello\"\n")
        #expect(session.phase == .idle)
    }

    @Test func clearConversationKeepsPendingProposal() async throws {
        let p = try TempProject(files: ["a.txt": "1\n"]); defer { p.remove() }
        let engine = ScriptedEngine(tokens: ["Edit.\n", "<<<FILE a.txt\n", "2\n", "FILE>>>\n"], tokenDelay: .milliseconds(1))
        let coordinator = InferenceCoordinator(engine: engine)
        try await coordinator.load(ModelReference(id: "t/m", directory: p.root))
        let session = WorkSession(workspace: try Workspace(root: p.root), coordinator: coordinator, prepareModel: { throw InferenceError.noModelLoaded })
        session.propose("change a")
        for _ in 0..<200 where session.phase != .proposed { try await Task.sleep(for: .milliseconds(5)) }
        session.clearConversation()
        #expect(session.turns.isEmpty)
        #expect(session.phase == .proposed)
        #expect(session.changeSet?.changes.count == 1)
        #expect(p.read("a.txt") == "1\n")
    }

    @Test func customInstructionsReplaceDefaultButFixedRulesRemain() {
        let custom = WorkPrompt.system(instructions: "Prefer small diffs. Explain in Japanese.")
        #expect(custom.hasPrefix("Prefer small diffs."))
        #expect(!custom.contains("You are Lay X Work"))
        #expect(custom.hasSuffix(WorkPrompt.fixedRules))
        #expect(custom.contains("<<<FILE"))
        #expect(WorkPrompt.system(instructions: "  ") == WorkPrompt.system)
        #expect(WorkPrompt.system.hasPrefix(WorkPrompt.defaultInstructions))
    }

    @Test func folderMentionIncludesItsFiles() throws {
        let p = try TempProject(files: ["Sources/Chat/View.swift": "v", "Sources/Chat/Model.swift": "m", "Other/X.swift": "x"])
        defer { p.remove() }
        let ws = try Workspace(root: p.root)
        let sel = ContextBuilder.select(request: "refactor @Sources/Chat/", entries: WorkspaceScanner.scan(ws), focus: nil, in: ws, tokenBudget: 10_000)
        #expect(Set(sel.files.map(\.path)) == ["Sources/Chat/View.swift", "Sources/Chat/Model.swift"])
    }

    @Test func contextSelectionPrefersMentionsAndRespectsBudget() throws {
        let p = try TempProject(files: ["Sources/ChatView.swift": String(repeating: "x", count: 900),
                                        "Sources/Other.swift": "y", "README.md": "readme"]); defer { p.remove() }
        let ws = try Workspace(root: p.root)
        let entries = WorkspaceScanner.scan(ws)
        let sel = ContextBuilder.select(request: "fix @Sources/Other.swift and the chat view", entries: entries, focus: nil,
                                        in: ws, tokenBudget: 10_000)
        #expect(sel.files.first?.path == "Sources/Other.swift")
        #expect(sel.files.map(\.path).contains("Sources/ChatView.swift"))
        let tight = ContextBuilder.select(request: "chat view", entries: entries, focus: nil, in: ws, tokenBudget: 100)
        #expect(!tight.files.map(\.path).contains("Sources/ChatView.swift"))
    }
}

@Suite struct MentionCompleterTests {
    let entries = [
        WorkspaceEntry(path: "Sources", isDirectory: true, size: 0),
        WorkspaceEntry(path: "Sources/Chat", isDirectory: true, size: 0),
        WorkspaceEntry(path: "Sources/Chat/ChatView.swift", isDirectory: false, size: 1),
        WorkspaceEntry(path: "Sources/Chat/Composer.swift", isDirectory: false, size: 1),
        WorkspaceEntry(path: "README.md", isDirectory: false, size: 1),
        WorkspaceEntry(path: "Tests/ChatTests.swift", isDirectory: false, size: 1),
    ]

    @Test func detectsTrailingMention() {
        #expect(MentionCompleter.activeQuery(in: "fix @Cha") == "Cha")
        #expect(MentionCompleter.activeQuery(in: "@") == "")
        #expect(MentionCompleter.activeQuery(in: "fix @ChatView.swift ") == nil)
        #expect(MentionCompleter.activeQuery(in: "mail me@example") == nil)
        #expect(MentionCompleter.activeQuery(in: "no mention") == nil)
    }

    @Test func ranksNamePrefixFirstAndFoldersEndWithSlash() {
        let s = MentionCompleter.suggestions(for: "chat", in: entries)
        #expect(s.first?.path == "Sources/Chat")
        #expect(s.first?.insertion == "Sources/Chat/")
        #expect(s.map(\.path).contains("Sources/Chat/ChatView.swift"))
        #expect(MentionCompleter.suggestions(for: "", in: entries).map(\.path) == ["Sources", "README.md"])
        #expect(MentionCompleter.suggestions(for: "sources/chat/co", in: entries).map(\.path) == ["Sources/Chat/Composer.swift"])
    }

    @Test func applyReplacesToken() {
        let file = MentionCompleter.Suggestion(path: "Sources/Chat/ChatView.swift", isDirectory: false)
        #expect(MentionCompleter.apply(file, to: "refactor @Chat") == "refactor @Sources/Chat/ChatView.swift ")
        let folder = MentionCompleter.Suggestion(path: "Sources/Chat", isDirectory: true)
        #expect(MentionCompleter.apply(folder, to: "@So") == "@Sources/Chat/")
    }
}
