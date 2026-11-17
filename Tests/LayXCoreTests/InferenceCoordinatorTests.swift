import Foundation
import Testing
@testable import LayXCore

@Suite struct InferenceCoordinatorTests {
    let ref = ModelReference(id: "test/model", directory: URL(fileURLWithPath: "/tmp/none"))

    func request(_ client: InferenceClient = .chat) -> GenerationRequest {
        GenerationRequest(messages: [PromptMessage(role: .user, content: "hi")],
                          parameters: GenerationParameters(), client: client)
    }

    func collect(_ stream: AsyncThrowingStream<GenerationEvent, Error>) async throws -> (String, GenerationMetrics?) {
        var text = ""
        var metrics: GenerationMetrics?
        for try await e in stream {
            switch e {
            case .text(let t): text += t
            case .finished(let m): metrics = m
            }
        }
        return (text, metrics)
    }

    @Test func generateWithoutModelFails() async throws {
        let c = InferenceCoordinator(engine: ScriptedEngine())
        await #expect(throws: InferenceError.noModelLoaded) { _ = try await collect(c.generate(request())) }
    }

    @Test func loadThenGenerateStreamsAndFinishes() async throws {
        let engine = ScriptedEngine()
        let c = InferenceCoordinator(engine: engine)
        let info = try await c.load(ref)
        #expect(info.id == "test/model")
        #expect(info.loadDuration > .zero)
        let (text, metrics) = try await collect(c.generate(request()))
        #expect(text == "Hello!")
        #expect(metrics?.generatedTokens == 3)
        #expect(await c.snapshot.lastMetrics?.generatedTokens == 3)
        #expect(await c.snapshot.activeClient == nil)
    }

    @Test func concurrentRequestsAreSerialized() async throws {
        let engine = ScriptedEngine(tokenDelay: .milliseconds(10))
        let c = InferenceCoordinator(engine: engine)
        try await c.load(ref)
        try await withThrowingTaskGroup(of: String.self) { group in
            // No Work here: an interactive request legitimately runs while Work is paused (covered by the
            // preemption tests), which this engine would count as two concurrent generations.
            for client in [InferenceClient.chat, .miniChat, .api, .benchmark] {
                group.addTask { try await collect(c.generate(request(client))).0 }
            }
            for try await text in group { #expect(text == "Hello!") }
        }
        #expect(await engine.maxConcurrentGenerations == 1)
        #expect(await engine.completedGenerations == 4)
    }

    @Test func cancellingConsumerStopsGeneration() async throws {
        let engine = ScriptedEngine(tokens: Array(repeating: "x", count: 200), tokenDelay: .milliseconds(5))
        let c = InferenceCoordinator(engine: engine)
        try await c.load(ref)
        let task = Task {
            var n = 0
            for try await e in c.generate(request()) { if case .text = e { n += 1 } }
            return n
        }
        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        // The cancelled consumer's own loop ends quietly (standard AsyncSequence semantics).
        _ = await task.result
        try await Task.sleep(for: .milliseconds(50))
        #expect(await engine.cancelledGenerations == 1)
        #expect(await engine.completedGenerations == 0)
        // Gate was released: a new request runs.
        await engine.setTokens(["ok"])
        #expect(try await collect(c.generate(request())).0 == "ok")
    }

    @Test func queuedRequestCanBeCancelledWithoutRunning() async throws {
        let engine = ScriptedEngine(tokens: Array(repeating: "x", count: 20), tokenDelay: .milliseconds(10))
        let c = InferenceCoordinator(engine: engine)
        try await c.load(ref)
        let first = Task { try await collect(c.generate(request())) }
        try await Task.sleep(for: .milliseconds(20))
        let queued = Task { try await collect(c.generate(request(.api))) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await c.snapshot.queuedCount == 1)
        queued.cancel()
        _ = await queued.result
        _ = try await first.value
        #expect(await engine.completedGenerations == 1)
        #expect(await c.snapshot.queuedCount == 0)
    }

    @Test func queueLimitRejectsExcessRequests() async throws {
        let engine = ScriptedEngine(tokens: ["a"], tokenDelay: .milliseconds(100))
        let c = InferenceCoordinator(engine: engine, maxQueued: 1)
        try await c.load(ref)
        let a = Task { try await collect(c.generate(request())) }
        try await Task.sleep(for: .milliseconds(20))
        let b = Task { try await collect(c.generate(request())) }
        try await Task.sleep(for: .milliseconds(20))
        await #expect(throws: InferenceError.queueFull) { _ = try await collect(c.generate(request())) }
        _ = try await a.value
        _ = try await b.value
    }

    @Test func loadingNewModelCancelsRunningGeneration() async throws {
        let engine = ScriptedEngine(tokens: Array(repeating: "x", count: 200), tokenDelay: .milliseconds(5))
        let c = InferenceCoordinator(engine: engine)
        try await c.load(ref)
        let gen = Task { try await collect(c.generate(request())) }
        try await Task.sleep(for: .milliseconds(30))
        try await c.load(ModelReference(id: "test/other", directory: ref.directory))
        await #expect(throws: InferenceError.lifecycleChanged) { _ = try await gen.value }
        #expect(await c.snapshot.model.loadedModel?.id == "test/other")
        #expect(await engine.loadedID == "test/other")
    }

    @Test func failedLoadIsReportedAndRecoverable() async throws {
        let engine = ScriptedEngine()
        await engine.setFailLoad(true)
        let c = InferenceCoordinator(engine: engine)
        await #expect(throws: InferenceError.self) { try await c.load(ref) }
        guard case .failed(let id, _) = await c.snapshot.model else { Issue.record("expected failed"); return }
        #expect(id == "test/model")
        await engine.setFailLoad(false)
        try await c.load(ref)
        #expect(await c.snapshot.model.loadedModel != nil)
    }

    @Test func unloadClearsState() async throws {
        let engine = ScriptedEngine()
        let c = InferenceCoordinator(engine: engine)
        try await c.load(ref)
        await c.unload()
        #expect(await c.snapshot.model == .none)
        #expect(await engine.loadedID == nil)
    }

    @Test func snapshotsStreamReportsLoadingAndReady() async throws {
        let c = InferenceCoordinator(engine: ScriptedEngine(loadDelay: .milliseconds(30)))
        let stream = await c.snapshots()
        let observer = Task {
            var sawLoading = false
            for await s in stream {
                if case .loading = s.model { sawLoading = true }
                if case .ready = s.model { return sawLoading }
            }
            return false
        }
        try await c.load(ref)
        #expect(await observer.value)
    }

    @Test func metricsRates() {
        let m = GenerationMetrics(promptTokens: 100, generatedTokens: 11, timeToFirstToken: .milliseconds(250),
                                  prefillDuration: .milliseconds(200), decodeDuration: .seconds(1),
                                  totalDuration: .milliseconds(1250), stopReason: .endOfSequence)
        #expect(m.prefillTokensPerSecond == 500)
        #expect(m.decodeTokensPerSecond == 10)
        let empty = GenerationMetrics(promptTokens: 0, generatedTokens: 0, timeToFirstToken: .zero,
                                      prefillDuration: .zero, decodeDuration: .zero, totalDuration: .zero,
                                      stopReason: .cancelled)
        #expect(empty.prefillTokensPerSecond == nil)
        #expect(empty.decodeTokensPerSecond == nil)
    }

    @Test func chatPreemptsWorkAndWorkResumes() async throws {
        let engine = ScriptedEngine(tokens: Array(repeating: "x", count: 40), tokenDelay: .milliseconds(3))
        let c = InferenceCoordinator(engine: engine)
        try await c.load(ref)
        let work = Task { try await collect(c.generate(request(.work))) }
        try await Task.sleep(for: .milliseconds(30))
        await engine.setTokens(["a", "b", "c"])
        let chatText = try await collect(c.generate(request(.chat))).0
        #expect(chatText == "abc")
        let (workText, _) = try await work.value
        #expect(workText.count == 40, "work finishes after resuming")
        // While chat was generating, work produced no tokens: the chat tokens are contiguous in the log.
        let log = await engine.emissionLog
        let first = try #require(log.firstIndex(of: .chat)), last = try #require(log.lastIndex(of: .chat))
        #expect(log[first...last].allSatisfy { $0 == .chat })
        #expect(log.first == .work && log.last == .work)
        #expect(await c.snapshot.pausedClient == nil)
    }

    /// Review finding: stopping Work while Chat runs on top of it released the gate, so an API request ran at the
    /// same time as the chat.
    @Test func stoppingPausedWorkKeepsTheGateForTheRunningChat() async throws {
        let engine = ScriptedEngine(tokens: Array(repeating: "w", count: 200), tokenDelay: .milliseconds(3))
        let c = InferenceCoordinator(engine: engine)
        try await c.load(ref)
        let work = Task { try await collect(c.generate(request(.work))) }
        try await Task.sleep(for: .milliseconds(20))
        await engine.setTokens(Array(repeating: "c", count: 30))
        let chat = Task { try await collect(c.generate(request(.chat))) }
        try await Task.sleep(for: .milliseconds(20))
        work.cancel()                                     // Work stopped while the chat is generating
        try await Task.sleep(for: .milliseconds(10))
        await engine.setTokens(Array(repeating: "a", count: 5))
        let api = Task { try await collect(c.generate(request(.api))) }
        _ = try await chat.value
        _ = try await api.value
        let log = await engine.emissionLog
        let lastChat = try #require(log.lastIndex(of: .chat)), firstAPI = try #require(log.firstIndex(of: .api))
        #expect(lastChat < firstAPI, "the API request waited for the chat")
        #expect(await c.snapshot.activeClient == nil)
        #expect(await c.isIdleWithModel)
    }

    /// Review finding: the API checked "idle" and then loaded, so another request could slip in between, and a
    /// load cancelled running generations. A pinned request now switches models in its own turn.
    @Test func pinnedModelSwitchesInItsTurnWithoutCancellingOthers() async throws {
        let engine = ScriptedEngine(tokens: Array(repeating: "c", count: 20), tokenDelay: .milliseconds(3))
        let c = InferenceCoordinator(engine: engine)
        try await c.load(ref)
        let chat = Task { try await collect(c.generate(request(.chat))) }
        try await Task.sleep(for: .milliseconds(10))
        var pinned = request(.api)
        let other = ModelReference(id: "test/other", directory: URL(fileURLWithPath: "/tmp/none"))
        pinned.model = other
        let api = Task { try await collect(c.generate(pinned)) }
        let (chatText, _) = try await chat.value
        #expect(chatText.count == 20, "the running chat was not cancelled by the switch")
        _ = try await api.value
        #expect(await c.snapshot.model.loadedModel?.id == "test/other")
        let log = await engine.emissionLog
        #expect(log.lastIndex(of: .chat)! < log.firstIndex(of: .api)!)
    }

    @Test func workDoesNotPreemptChatAndBenchmarkIsNotPreempted() async throws {
        let engine = ScriptedEngine(tokens: Array(repeating: "y", count: 15), tokenDelay: .milliseconds(3))
        let c = InferenceCoordinator(engine: engine)
        try await c.load(ref)
        let bench = Task { try await collect(c.generate(request(.benchmark))) }
        try await Task.sleep(for: .milliseconds(15))
        let chat = Task { try await collect(c.generate(request(.chat))) }
        _ = try await bench.value
        _ = try await chat.value
        let log = await engine.emissionLog
        // FIFO: benchmark tokens all come before chat tokens.
        #expect(log.lastIndex(of: .benchmark)! < log.firstIndex(of: .chat)!)
    }

    @Test func pausedSnapshotIsReported() async throws {
        let engine = ScriptedEngine(tokens: Array(repeating: "x", count: 60), tokenDelay: .milliseconds(3))
        let c = InferenceCoordinator(engine: engine)
        try await c.load(ref)
        let work = Task { try await collect(c.generate(request(.work))) }
        try await Task.sleep(for: .milliseconds(20))
        await engine.setTokens(Array(repeating: "c", count: 20))
        let chat = Task { try await collect(c.generate(request(.chat))) }
        try await Task.sleep(for: .milliseconds(20))
        let snap = await c.snapshot
        #expect(snap.pausedClient == .work)
        #expect(snap.activeClient == .chat)
        _ = try await chat.value
        _ = try await work.value
    }

    @Test func engineSettingsBudgetAndValidation() {
        let gb: Int64 = 1 << 30
        #expect(EngineSettings().weightBudget(physicalMemory: 64 * gb) == 48 * gb)
        #expect(EngineSettings(memoryLimitBytes: 20 * gb).weightBudget(physicalMemory: 64 * gb) == 20 * gb)
        #expect(EngineSettings(memoryLimitBytes: 100 * gb).weightBudget(physicalMemory: 64 * gb) < 64 * gb)
        #expect(EngineSettings(kvBits: 3).kvBits == nil)
        #expect(EngineSettings(kvBits: 8).kvBits == 8)
        #expect(EngineSettings(gpuLimit: 1).pause(forTokenTime: 0.02) == 0)
        #expect(abs(EngineSettings(gpuLimit: 0.5).pause(forTokenTime: 0.02) - 0.04) < 1e-9)   // interval 2× → 50 %
        #expect(abs(EngineSettings(gpuLimit: 0.8).pause(forTokenTime: 0.02) - 0.025) < 1e-9)  // interval 1.25× → 80 %
        #expect(EngineSettings(gpuLimit: 0.1).gpuLimit == 0.3)
        #expect(EngineSettings(gpuLimit: 0.3).pause(forTokenTime: 2) == 0.25)
    }

    @Test func parametersAreClamped() {
        let p = GenerationParameters(temperature: 9, topP: 0, maxTokens: -5, repetitionPenalty: 10).validated()
        #expect(p.temperature == 2)
        #expect(p.topP == 0.01)
        #expect(p.maxTokens == 1)
        #expect(p.repetitionPenalty == 2)
    }
}
