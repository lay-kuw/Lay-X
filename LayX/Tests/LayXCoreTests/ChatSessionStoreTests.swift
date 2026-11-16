import Foundation
import Testing
@testable import LayXCore

/// Records every write so tests can prove what did — and did not — reach "disk".
actor RecordingRepository: PinnedChatStoring {
    private(set) var stored: [UUID: ChatSession] = [:]
    private(set) var saveCount = 0
    private(set) var deleteCount = 0
    func save(_ session: ChatSession) async throws { stored[session.id] = session; saveCount += 1 }
    func delete(id: UUID) async throws { stored[id] = nil; deleteCount += 1 }
    func loadAll() async throws -> [ChatSession] { Array(stored.values) }
    func preload(_ s: ChatSession) { stored[s.id] = s }
}

@MainActor
@Suite(.serialized) struct ChatSessionStoreTests {
    let ref = ModelReference(id: "test/model", directory: URL(fileURLWithPath: "/tmp/none"))

    func make(tokens: [String] = ["Hel", "lo", "!"], delay: Duration = .milliseconds(2),
              repo: RecordingRepository = RecordingRepository()) async throws
        -> (ChatSessionStore, RecordingRepository, ScriptedEngine) {
        let engine = ScriptedEngine(tokens: tokens, tokenDelay: delay)
        let coordinator = InferenceCoordinator(engine: engine)
        try await coordinator.load(ref)
        let store = ChatSessionStore(coordinator: coordinator, repository: repo,
                                     settings: { ChatGenerationSettings(parameters: GenerationParameters(maxTokens: 64)) },
                                     prepareModel: { throw InferenceError.noModelLoaded })
        store.flushInterval = .zero
        return (store, repo, engine)
    }

    func waitIdle(_ store: ChatSessionStore) async throws {
        for _ in 0..<500 where !store.generating.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await store.flushWrites()
    }

    @Test func unpinnedSessionsAreMemoryOnly() async throws {
        let (store, repo, _) = try await make()
        let id = store.newSession()
        store.send("Hi there", in: id)
        try await waitIdle(store)
        #expect(store.session(id)?.messages.map(\.content) == ["Hi there", "Hello!"])
        #expect(await repo.saveCount == 0)
        #expect(await repo.stored.isEmpty)
    }

    @Test func pinningPersistsAndLaterChangesArePersisted() async throws {
        let (store, repo, _) = try await make()
        let id = store.newSession()
        store.send("First", in: id)
        try await waitIdle(store)
        store.setPinned(id, true)
        await store.flushWrites()
        #expect(await repo.stored[id]?.messages.count == 2)
        store.send("Second", in: id)
        try await waitIdle(store)
        #expect(await repo.stored[id]?.messages.map(\.content) == ["First", "Hello!", "Second", "Hello!"])
        #expect(await repo.stored[id]?.messages.last?.metrics != nil)
    }

    @Test func unpinningRemovesStoredCopyButKeepsMemory() async throws {
        let (store, repo, _) = try await make()
        let id = store.newSession()
        store.send("Keep me", in: id)
        try await waitIdle(store)
        store.setPinned(id, true)
        store.setPinned(id, false)
        await store.flushWrites()
        #expect(await repo.stored[id] == nil)
        #expect(store.session(id)?.messages.count == 2)
        #expect(store.session(id)?.isPinned == false)
        // Further changes to the now-temporary session are not written.
        let before = await repo.saveCount
        store.send("More", in: id)
        try await waitIdle(store)
        #expect(await repo.saveCount == before)
    }

    @Test func unpinWhileGeneratingDoesNotResurrectStoredCopy() async throws {
        let (store, repo, _) = try await make(tokens: Array(repeating: "x", count: 30), delay: .milliseconds(3))
        let id = store.newSession()
        store.setPinned(id, true)
        store.send("go", in: id)
        try await Task.sleep(for: .milliseconds(20))
        store.setPinned(id, false)
        try await waitIdle(store)
        #expect(await repo.stored[id] == nil)
    }

    @Test func deleteRemovesMemoryAndStoredCopy() async throws {
        let (store, repo, _) = try await make()
        let id = store.newSession()
        store.send("x", in: id)
        try await waitIdle(store)
        store.setPinned(id, true)
        store.delete(id)
        await store.flushWrites()
        #expect(store.session(id) == nil)
        #expect(await repo.stored[id] == nil)
    }

    @Test func pinnedSessionsLoadAtLaunch() async throws {
        let repo = RecordingRepository()
        let saved = ChatSession(title: "Saved", messages: [ChatMessage(role: .user, content: "old")], isPinned: true, pinnedAt: Date())
        await repo.preload(saved)
        let (store, _, _) = try await make(repo: repo)
        await store.loadPinned()
        #expect(store.pinnedSessions.map(\.id) == [saved.id])
        #expect(store.temporarySessions.isEmpty)
    }

    @Test func replacingRepositorySwapsPinnedButKeepsTemporary() async throws {
        let (store, _, _) = try await make()
        let temp = store.newSession()
        store.send("temp", in: temp)
        try await waitIdle(store)
        let pinned = store.newSession()
        store.send("pinned", in: pinned)
        try await waitIdle(store)
        store.setPinned(pinned, true)
        let other = RecordingRepository()
        let foreign = ChatSession(title: "From other DB", messages: [ChatMessage(role: .user, content: "x")], isPinned: true, pinnedAt: Date())
        await other.preload(foreign)
        await store.replaceRepository(other)
        #expect(store.pinnedSessions.map(\.id) == [foreign.id])
        #expect(store.session(temp) != nil)
        #expect(store.session(pinned) == nil)
    }

    @Test func sessionSwitchingKeepsIndependentHistories() async throws {
        let (store, _, _) = try await make()
        let a = store.newSession()
        store.send("in A", in: a)
        try await waitIdle(store)
        let b = store.newSession()
        #expect(a != b)
        store.send("in B", in: b)
        try await waitIdle(store)
        #expect(store.session(a)?.messages.first?.content == "in A")
        #expect(store.session(b)?.messages.first?.content == "in B")
        #expect(store.sessions.first?.id == b, "most recently used first")
        #expect(store.session(a)?.title == "in A")
    }

    @Test func newSessionReusesEmptyTemporarySession() async throws {
        let (store, _, _) = try await make()
        let a = store.newSession()
        #expect(store.newSession() == a)
        #expect(store.sessions.count == 1)
    }

    @Test func stopKeepsPartialReplyMarkedInterrupted() async throws {
        let (store, _, engine) = try await make(tokens: Array(repeating: "x", count: 200), delay: .milliseconds(3))
        let id = store.newSession()
        store.send("long", in: id)
        try await Task.sleep(for: .milliseconds(60))
        store.stop(id)
        try await waitIdle(store)
        let reply = try #require(store.session(id)?.messages.last)
        #expect(reply.role == .assistant)
        #expect(reply.interrupted)
        #expect(!reply.content.isEmpty && reply.content.count < 200)
        #expect(!store.isGenerating(id))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await engine.cancelledGenerations == 1)
    }

    @Test func regenerateReplacesLastReply() async throws {
        let (store, _, engine) = try await make()
        let id = store.newSession()
        store.send("q", in: id)
        try await waitIdle(store)
        await engine.setTokens(["second"])
        store.regenerate(id)
        try await waitIdle(store)
        #expect(store.session(id)?.messages.map(\.content) == ["q", "second"])
    }

    @Test func generationErrorIsReportedAndEmptyReplyRemoved() async throws {
        let engine = ScriptedEngine()
        let coordinator = InferenceCoordinator(engine: engine)  // nothing loaded
        let store = ChatSessionStore(coordinator: coordinator, repository: nil, settings: { ChatGenerationSettings() },
                                     prepareModel: { throw InferenceError.noModelLoaded })
        let id = store.newSession()
        store.send("hello", in: id)
        try await waitIdle(store)
        #expect(store.errors[id] == InferenceError.noModelLoaded.errorDescription)
        #expect(store.session(id)?.messages.map(\.role) == [.user])
    }

    @Test func mainAndMiniShareSessionState() async throws {
        // Mini Chat and Main Chat hold ids into the same store; a message sent from one is visible to the other.
        let (store, _, _) = try await make()
        let miniCurrent = store.newSession()
        store.send("from mini", in: miniCurrent)
        try await waitIdle(store)
        let mainCurrent = miniCurrent  // "Open in Chat"
        #expect(store.session(mainCurrent)?.messages.count == 2)
        store.send("from main", in: mainCurrent)
        try await waitIdle(store)
        #expect(store.session(miniCurrent)?.messages.count == 4)
    }
}

@Suite struct PromptBuilderTests {
    func msg(_ role: ChatRole, _ n: Int) -> ChatMessage { ChatMessage(role: role, content: String(repeating: "a", count: n)) }

    @Test func noTrimmingWhenContextUnknown() {
        let r = PromptBuilder.build(history: [msg(.user, 10), msg(.assistant, 10), msg(.user, 10)], systemPrompt: "sys",
                                    contextLength: nil, maxOutputTokens: 100)
        #expect(r.messages.count == 4)
        #expect(r.messages.first?.role == .system)
        #expect(r.omittedCount == 0)
    }

    @Test func trimsOldestAndNeverStartsWithAssistant() {
        // Each 300-byte message ≈ 100 tokens + overhead.
        let history = (0..<10).map { msg($0 % 2 == 0 ? .user : .assistant, 300) }
        let r = PromptBuilder.build(history: history, systemPrompt: nil, contextLength: 1024, maxOutputTokens: 256)
        #expect(r.omittedCount > 0)
        #expect(r.messages.first?.role == .user)
        #expect(r.messages.last?.content == history.last?.content)
        #expect(r.estimatedTokens <= 1024 - 256)
    }

    @Test func latestMessageIsAlwaysKept() {
        let r = PromptBuilder.build(history: [msg(.user, 9000)], systemPrompt: nil, contextLength: 512, maxOutputTokens: 128)
        #expect(r.messages.count == 1)
    }

    @Test func thinkingIsStrippedFromHistory() {
        let h = [ChatMessage(role: .user, content: "q"), ChatMessage(role: .assistant, content: "<think>secret</think>\n\nAnswer")]
        let r = PromptBuilder.build(history: h, systemPrompt: nil, contextLength: nil, maxOutputTokens: 10)
        #expect(r.messages[1].content == "Answer")
    }

    @Test func thinkingParser() {
        #expect(ThinkingParser.split("plain") == .init(thinking: nil, answer: "plain", isThinking: false))
        #expect(ThinkingParser.split("<think>\n\n</think>\n\nHi") == .init(thinking: nil, answer: "Hi", isThinking: false))
        #expect(ThinkingParser.split("<think>step 1</think>Done") == .init(thinking: "step 1", answer: "Done", isThinking: false))
        #expect(ThinkingParser.split("<think>still going") == .init(thinking: "still going", answer: "", isThinking: true))
    }
}

@Suite struct MarkdownParserTests {
    @Test func splitsBlocks() {
        let md = """
        # Title
        Some *text*
        continues here.

        - one
        - two
        1. first

        ```swift
        let x = 1
        ```
        > quoted
        ---
        """
        #expect(MarkdownParser.blocks(md) == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some *text*\ncontinues here."),
            .listItem(marker: "•", text: "one", indent: 0),
            .listItem(marker: "•", text: "two", indent: 0),
            .listItem(marker: "1.", text: "first", indent: 0),
            .code(language: "swift", code: "let x = 1", closed: true),
            .quote("quoted"),
            .rule,
        ])
    }

    @Test func unterminatedFenceWhileStreaming() {
        #expect(MarkdownParser.blocks("Look:\n```py\nprint(1)") == [
            .paragraph("Look:"), .code(language: "py", code: "print(1)", closed: false),
        ])
    }

    @Test func hashWithoutSpaceIsNotHeading() {
        #expect(MarkdownParser.blocks("#hashtag") == [.paragraph("#hashtag")])
    }
}
