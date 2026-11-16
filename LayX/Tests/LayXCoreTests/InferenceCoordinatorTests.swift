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
            for client in [InferenceClient.chat, .miniChat, .api, .work] {
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

    @Test func engineSettingsBudgetAndValidation() {
        let gb: Int64 = 1 << 30
        #expect(EngineSettings().weightBudget(physicalMemory: 64 * gb) == 48 * gb)
        #expect(EngineSettings(memoryLimitBytes: 20 * gb).weightBudget(physicalMemory: 64 * gb) == 20 * gb)
        #expect(EngineSettings(memoryLimitBytes: 100 * gb).weightBudget(physicalMemory: 64 * gb) < 64 * gb)
        #expect(EngineSettings(kvBits: 3).kvBits == nil)
        #expect(EngineSettings(kvBits: 8).kvBits == 8)
    }

    @Test func parametersAreClamped() {
        let p = GenerationParameters(temperature: 9, topP: 0, maxTokens: -5, repetitionPenalty: 10).validated()
        #expect(p.temperature == 2)
        #expect(p.topP == 0.01)
        #expect(p.maxTokens == 1)
        #expect(p.repetitionPenalty == 2)
    }
}
