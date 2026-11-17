import Foundation
@testable import LayXCore

/// Deterministic test double. NOT evidence of real inference — it only exercises scheduling logic.
actor ScriptedEngine: InferenceEngine {
    var tokens: [String]
    var tokenDelay: Duration
    var loadDelay: Duration
    var failLoad = false
    private(set) var loadedID: String?
    private(set) var concurrentGenerations = 0
    private(set) var maxConcurrentGenerations = 0
    private(set) var cancelledGenerations = 0
    private(set) var completedGenerations = 0
    private(set) var requests: [GenerationRequest] = []
    func record(_ r: GenerationRequest) { requests.append(r) }
    /// Order in which tokens were produced, by client (to prove preemption).
    private(set) var emissionLog: [InferenceClient] = []
    func emitted(_ c: InferenceClient) { emissionLog.append(c) }

    init(tokens: [String] = ["Hel", "lo", "!"], tokenDelay: Duration = .milliseconds(5),
         loadDelay: Duration = .milliseconds(5)) {
        self.tokens = tokens
        self.tokenDelay = tokenDelay
        self.loadDelay = loadDelay
    }

    func setFailLoad(_ value: Bool) { failLoad = value }
    func setTokens(_ value: [String]) { tokens = value }

    func load(_ model: ModelReference, progress: @escaping @Sendable (Double) -> Void) async throws -> LoadedModelInfo {
        progress(0.5)
        try await Task.sleep(for: loadDelay)
        if failLoad { throw InferenceError.loadFailed("scripted failure") }
        loadedID = model.id
        progress(1)
        return LoadedModelInfo(id: model.id, contextLength: 4096)
    }

    func unload() async { loadedID = nil }

    nonisolated func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                request.pauseGate?.arm()
                await self.record(request)
                await self.begin()
                let clock = ContinuousClock()
                let start = clock.now
                var count = 0
                do {
                    for t in await self.tokens {
                        await request.pauseGate?.waitWhilePausedAsync()
                        try await Task.sleep(for: await self.tokenDelay)
                        await self.emitted(request.client)
                        continuation.yield(.text(t))
                        count += 1
                    }
                    let elapsed = clock.now - start
                    continuation.yield(.finished(GenerationMetrics(
                        promptTokens: request.messages.count, generatedTokens: count, timeToFirstToken: elapsed / 3,
                        prefillDuration: elapsed / 4, decodeDuration: elapsed / 2, totalDuration: elapsed,
                        stopReason: .endOfSequence)))
                    await self.end(cancelled: false)
                    continuation.finish()
                } catch {
                    await self.end(cancelled: true)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func begin() {
        concurrentGenerations += 1
        maxConcurrentGenerations = max(maxConcurrentGenerations, concurrentGenerations)
    }

    private func end(cancelled: Bool) {
        concurrentGenerations -= 1
        if cancelled { cancelledGenerations += 1 } else { completedGenerations += 1 }
    }
}
