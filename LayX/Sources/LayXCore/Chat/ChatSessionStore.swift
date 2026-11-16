import Foundation
import Observation

/// Generation settings applied to chat turns (from Settings; per-chat overrides may come later).
public struct ChatGenerationSettings: Sendable, Equatable {
    public var parameters: GenerationParameters
    /// The user's "Soul": a persona / standing instructions sent as the system prompt.
    public var systemPrompt: String?
    /// Reasoning mode (`nil` = model default).
    public var thinking: Bool?
    /// Web search for chat replies.
    public var webMode: WebSearchMode

    public init(parameters: GenerationParameters = GenerationParameters(), systemPrompt: String? = nil, thinking: Bool? = nil,
                webMode: WebSearchMode = .off) {
        self.parameters = parameters
        self.systemPrompt = systemPrompt
        self.thinking = thinking
        self.webMode = webMode
    }
}

/// The single conversation store shared by Main Chat and Mini Chat.
///
/// Privacy contract:
/// - Sessions live in memory. Nothing is written for an unpinned session — no database row, no file, no log.
/// - Pinning writes the full session to SQLite; later changes to a pinned session are written too.
/// - Unpinning deletes the stored copy but keeps the in-memory session; deleting removes both.
/// - All writes for all sessions go through one serial queue, so a late save can never resurrect a session
///   that was unpinned or deleted after it.
@MainActor
@Observable
public final class ChatSessionStore {
    /// Newest first.
    public private(set) var sessions: [ChatSession] = []
    /// Sessions currently generating.
    public private(set) var generating: Set<UUID> = []
    /// Last generation error per session (cleared on the next send).
    public private(set) var errors: [UUID: String] = [:]
    /// Older messages left out of the last prompt for a session (context window).
    public private(set) var omittedMessages: [UUID: Int] = [:]
    /// Set when a pinned session couldn't be written.
    public var persistenceError: String?
    /// Live web-search step per session ("Searching the web for …").
    public private(set) var webStatus: [UUID: String] = [:]
    /// Text of replies being streamed, per session. Kept apart from `sessions` so a streaming flush only
    /// invalidates the views that show the live reply (not the sidebar, message list, composer…); committed to
    /// the message when the generation ends.
    public private(set) var liveReplies: [UUID: LiveReply] = [:]

    public struct LiveReply: Sendable, Equatable {
        public var messageID: UUID
        public var text: String
    }

    /// The text to show for `message`: the live text while it is streaming, otherwise its content.
    public func displayContent(_ message: ChatMessage, in id: UUID) -> String {
        if let live = liveReplies[id], live.messageID == message.id { return message.content + live.text }
        return message.content
    }

    @ObservationIgnored private let coordinator: InferenceCoordinator
    @ObservationIgnored private var repository: (any PinnedChatStoring)?
    @ObservationIgnored private let settings: @MainActor () -> ChatGenerationSettings
    /// Called before a generation when no model is loaded; should load the default model or throw.
    @ObservationIgnored private let prepareModel: @MainActor () async throws -> LoadedModelInfo
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Builds the configured researcher (throws if the provider isn't set up). Read-only web access.
    @ObservationIgnored private let webResearcher: @MainActor () throws -> any WebResearching
    @ObservationIgnored private var writeQueue: Task<Void, Never>?

    /// UI flush cadence for streamed text (buffer tokens, flush ~every 40 ms).
    public var flushInterval: Duration = .milliseconds(40)

    public init(coordinator: InferenceCoordinator, repository: (any PinnedChatStoring)?,
                settings: @escaping @MainActor () -> ChatGenerationSettings,
                prepareModel: @escaping @MainActor () async throws -> LoadedModelInfo,
                webResearcher: @escaping @MainActor () throws -> any WebResearching = { throw WebSearchError.notConfigured("web search is unavailable") }) {
        self.webResearcher = webResearcher
        self.coordinator = coordinator
        self.repository = repository
        self.settings = settings
        self.prepareModel = prepareModel
    }

    // MARK: Queries

    public func session(_ id: UUID?) -> ChatSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    public var pinnedSessions: [ChatSession] { sessions.filter(\.isPinned) }
    public var temporarySessions: [ChatSession] { sessions.filter { !$0.isPinned } }
    public func isGenerating(_ id: UUID?) -> Bool { id.map(generating.contains) ?? false }

    private func index(_ id: UUID) -> Int? { sessions.firstIndex { $0.id == id } }

    // MARK: Lifecycle

    /// Loads pinned sessions from disk (call once at launch).
    public func loadPinned() async {
        guard let repository else { return }
        do {
            let stored = try await repository.loadAll()
            let known = Set(sessions.map(\.id))
            sessions.append(contentsOf: stored.filter { !known.contains($0.id) })
        } catch {
            persistenceError = "Pinned chats couldn’t be loaded."
        }
    }

    /// Switches to another pinned-chat store (database moved or another database chosen): pinned sessions
    /// from the old store leave memory and the new store's pinned sessions are loaded. Temporary chats stay.
    public func replaceRepository(_ newRepository: (any PinnedChatStoring)?) async {
        await flushWrites()
        repository = newRepository
        persistenceError = nil
        sessions.removeAll { $0.isPinned && !generating.contains($0.id) }
        await loadPinned()
    }

    /// Creates an empty temporary session, or returns an existing empty temporary one (no clutter).
    @discardableResult
    public func newSession(modelID: String? = nil) -> UUID {
        if let empty = sessions.first(where: { !$0.isPinned && $0.messages.isEmpty && !generating.contains($0.id) }) {
            return empty.id
        }
        let s = ChatSession(modelID: modelID)
        sessions.insert(s, at: 0)
        return s.id
    }

    public func rename(_ id: UUID, to title: String) {
        guard let i = index(id) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        sessions[i].title = String(t.prefix(80))
        persistIfPinned(id)
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let i = index(id), sessions[i].isPinned != pinned else { return }
        sessions[i].isPinned = pinned
        sessions[i].pinnedAt = pinned ? Date() : nil
        if pinned {
            persistIfPinned(id)
        } else {
            enqueueWrite { repo in try await repo.delete(id: id) }
        }
    }

    public func togglePin(_ id: UUID) {
        guard let s = session(id) else { return }
        setPinned(id, !s.isPinned)
    }

    /// Removes the session from memory and (if it was ever pinned) from disk.
    public func delete(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        generating.remove(id)
        errors[id] = nil
        omittedMessages[id] = nil
        liveReplies[id] = nil
        let wasPinned = session(id)?.isPinned ?? false
        sessions.removeAll { $0.id == id }
        // Safe disposal: the conversation's KV cache is derived from its content.
        let coordinator = self.coordinator
        Task { await coordinator.discardCaches(key: id.uuidString) }
        if wasPinned { enqueueWrite { repo in try await repo.delete(id: id) } }
    }

    // MARK: Chat

    /// Appends a user message and streams the assistant reply.
    public func send(_ text: String, in id: UUID) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, let i = index(id), !generating.contains(id) else { return }
        sessions[i].messages.append(ChatMessage(role: .user, content: content))
        if sessions[i].title == "Untitled" { sessions[i].title = Self.title(from: content) }
        sessions[i].updatedAt = Date()
        moveToTop(id)
        persistIfPinned(id)
        startGeneration(id)
    }

    /// Replaces the last assistant reply with a new one (or answers a dangling user message).
    public func regenerate(_ id: UUID) {
        guard let i = index(id), !generating.contains(id) else { return }
        if sessions[i].messages.last?.role == .assistant { sessions[i].messages.removeLast() }
        guard sessions[i].messages.last?.role == .user else { return }
        startGeneration(id)
    }

    /// Stops a running generation; the partial reply is kept.
    public func stop(_ id: UUID) {
        tasks[id]?.cancel()
    }

    public func clearError(_ id: UUID) { errors[id] = nil }

    private func startGeneration(_ id: UUID) {
        errors[id] = nil
        generating.insert(id)
        tasks[id] = Task { [weak self] in
            await self?.runGeneration(id)
        }
    }

    private func runGeneration(_ id: UUID) async {
        defer {
            generating.remove(id)
            tasks[id] = nil
            persistIfPinned(id)
        }
        let model: LoadedModelInfo
        do {
            if let loaded = await coordinator.snapshot.model.loadedModel {
                model = loaded
            } else {
                model = try await prepareModel()
            }
        } catch {
            if !Task.isCancelled { errors[id] = Self.message(error) }
            return
        }
        guard index(id) != nil else { return }
        let config = settings()

        // Optional web research (read-only: only the planned query leaves the Mac; pages are fetched with GET).
        var web: WebContext?
        var webNote: String?
        if config.webMode != .off, let history = session(id)?.messages {
            (web, webNote) = await research(for: history, mode: config.webMode, sessionID: id, contextLength: model.contextLength)
            if Task.isCancelled { webStatus[id] = nil; return }
        }
        guard let i = index(id) else { return }
        var system = config.systemPrompt ?? ""
        if let web {
            let budget = max(2000, (model.contextLength ?? 8192) * 3 / 2)
            system += (system.isEmpty ? "" : "\n\n") + String(WebQuery.contextMessage(web).prefix(budget))
        }
        let prompt = PromptBuilder.build(history: sessions[i].messages, systemPrompt: system.isEmpty ? nil : system,
                                         contextLength: model.contextLength, maxOutputTokens: config.parameters.maxTokens)
        omittedMessages[id] = prompt.omittedCount > 0 ? prompt.omittedCount : nil
        sessions[i].modelID = model.id
        var reply = ChatMessage(role: .assistant, content: "", modelID: model.id)
        reply.sources = web?.sources ?? []
        reply.webNote = webNote
        sessions[i].messages.append(reply)
        let messageID = sessions[i].messages[sessions[i].messages.count - 1].id

        let request = GenerationRequest(messages: prompt.messages, parameters: config.parameters, client: .chat, thinking: config.thinking,
                                        cacheKey: id.uuidString)
        let clock = ContinuousClock()
        var buffer = ""
        var lastFlush = clock.now
        do {
            for try await event in coordinator.generate(request) {
                switch event {
                case .text(let t):
                    buffer += t
                    if clock.now - lastFlush >= flushInterval {
                        append(buffer, to: messageID, in: id)
                        buffer = ""
                        lastFlush = clock.now
                    }
                case .finished(let metrics):
                    append(buffer, to: messageID, in: id)
                    buffer = ""
                    commitLive(messageID, in: id)
                    setMetrics(metrics, on: messageID, in: id)
                }
            }
            append(buffer, to: messageID, in: id)
            commitLive(messageID, in: id)
            if Task.isCancelled { markInterrupted(messageID, in: id) }
        } catch {
            append(buffer, to: messageID, in: id)
            commitLive(messageID, in: id)
            if error is CancellationError || Task.isCancelled {
                markInterrupted(messageID, in: id)
            } else {
                errors[id] = Self.message(error)
                markInterrupted(messageID, in: id)
            }
        }
        removeIfEmpty(messageID, in: id)
    }

    /// Plans a query with the model (Auto may decide not to search), then searches and reads top pages.
    private func research(for history: [ChatMessage], mode: WebSearchMode, sessionID id: UUID,
                          contextLength: Int?) async -> (WebContext?, String?) {
        let researcher: any WebResearching
        do { researcher = try webResearcher() } catch {
            return (nil, (error as? LocalizedError)?.errorDescription)
        }
        webStatus[id] = mode == .auto ? "Deciding whether to search the web…" : "Planning a web search…"
        defer { webStatus[id] = nil }
        let recent = history.suffix(5).map { m -> String in
            let who = m.role == .user ? "User" : "Assistant"
            return "\(who): \(String(ThinkingParser.stripThinking(m.content).prefix(1500)))"
        }.joined(separator: "\n")
        let plan = GenerationRequest(
            messages: [PromptMessage(role: .system, content: WebQuery.plannerPrompt(decide: mode == .auto)),
                       PromptMessage(role: .user, content: "Conversation:\n\(recent)\n\nToday is \(Date().formatted(date: .complete, time: .omitted)).")],
            parameters: GenerationParameters(temperature: 0, topP: 1, maxTokens: 48), client: .chat, thinking: false)
        var reply = ""
        do {
            for try await event in coordinator.generate(plan) { if case .text(let t) = event { reply += t } }
        } catch {
            return (nil, Task.isCancelled ? nil : "Web search skipped: \((error as? LocalizedError)?.errorDescription ?? "planning failed").")
        }
        guard let query = WebQuery.parsePlan(reply, decide: mode == .auto) else {
            return (nil, nil)  // Auto decided the web isn't needed.
        }
        webStatus[id] = "Searching the web for “\(query)”…"
        do {
            return (try await researcher.research(query), nil)
        } catch {
            return (nil, "\((error as? LocalizedError)?.errorDescription ?? "Web search failed.") Answered without the web.")
        }
    }

    private func append(_ text: String, to messageID: UUID, in id: UUID) {
        guard !text.isEmpty, index(id) != nil else { return }
        if liveReplies[id]?.messageID == messageID {
            liveReplies[id]?.text += text
        } else {
            liveReplies[id] = LiveReply(messageID: messageID, text: text)
        }
    }

    /// Moves the streamed text into the message (one `sessions` change per generation).
    private func commitLive(_ messageID: UUID, in id: UUID) {
        guard let live = liveReplies[id], live.messageID == messageID else { return }
        liveReplies[id] = nil
        guard let i = index(id), let m = sessions[i].messages.lastIndex(where: { $0.id == messageID }) else { return }
        sessions[i].messages[m].content += live.text
    }

    private func setMetrics(_ metrics: GenerationMetrics, on messageID: UUID, in id: UUID) {
        guard let i = index(id), let m = sessions[i].messages.lastIndex(where: { $0.id == messageID }) else { return }
        sessions[i].messages[m].metrics = metrics
        sessions[i].updatedAt = Date()
    }

    private func markInterrupted(_ messageID: UUID, in id: UUID) {
        guard let i = index(id), let m = sessions[i].messages.lastIndex(where: { $0.id == messageID }) else { return }
        sessions[i].messages[m].interrupted = true
    }

    private func removeIfEmpty(_ messageID: UUID, in id: UUID) {
        guard let i = index(id), let m = sessions[i].messages.lastIndex(where: { $0.id == messageID }),
              sessions[i].messages[m].content.isEmpty else { return }
        sessions[i].messages.remove(at: m)
    }

    private func moveToTop(_ id: UUID) {
        guard let i = index(id), i > 0 else { return }
        let s = sessions.remove(at: i)
        sessions.insert(s, at: 0)
    }

    // MARK: Persistence (pinned only)

    private func persistIfPinned(_ id: UUID) {
        guard let s = session(id), s.isPinned else { return }
        enqueueWrite { [weak self] repo in
            // Re-check at write time: the session may have been unpinned/deleted while queued.
            guard let current = await self?.session(id), current.isPinned else { return }
            try await repo.save(current)
        }
    }

    private func enqueueWrite(_ op: @escaping @Sendable (any PinnedChatStoring) async throws -> Void) {
        guard let repository else {
            persistenceError = "Pinned chats can’t be saved: the local database isn’t available."
            return
        }
        let previous = writeQueue
        writeQueue = Task { [weak self] in
            await previous?.value
            do {
                try await op(repository)
            } catch {
                await MainActor.run { self?.persistenceError = "A pinned chat couldn’t be saved." }
            }
        }
    }

    /// Waits for all queued writes (tests, app termination).
    public func flushWrites() async {
        await writeQueue?.value
    }

    /// Cancels every generation (app termination).
    public func cancelAll() {
        for t in tasks.values { t.cancel() }
    }

    // MARK: Helpers

    static func title(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let t = firstLine.trimmingCharacters(in: .whitespaces)
        return t.count > 48 ? String(t.prefix(47)) + "…" : t
    }

    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Something went wrong while generating."
    }
}
