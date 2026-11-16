import Foundation

/// The single owner of the model runtime. Chat, Mini Chat, Work, Benchmark and the API server all go
/// through one coordinator, which:
/// - keeps exactly one model loaded (no duplication in memory),
/// - serializes lifecycle operations and generations through one FIFO gate (the loaded model is not
///   safe for concurrent generation),
/// - bounds the wait queue,
/// - propagates cancellation (consumer stops iterating → generation stops),
/// - publishes state snapshots for every UI surface.
public actor InferenceCoordinator {
    public enum ModelState: Sendable, Equatable {
        case none
        case loading(id: String, progress: Double)
        case ready(LoadedModelInfo)
        case failed(id: String, message: String)

        public var loadedModel: LoadedModelInfo? { if case .ready(let info) = self { info } else { nil } }
    }

    public struct Snapshot: Sendable, Equatable {
        public var model: ModelState
        /// The client currently generating, if any.
        public var activeClient: InferenceClient?
        public var queuedCount: Int
        public var lastMetrics: GenerationMetrics?

        public init(model: ModelState = .none, activeClient: InferenceClient? = nil, queuedCount: Int = 0,
                    lastMetrics: GenerationMetrics? = nil) {
            self.model = model
            self.activeClient = activeClient
            self.queuedCount = queuedCount
            self.lastMetrics = lastMetrics
        }
    }

    private let engine: any InferenceEngine
    private let maxQueued: Int

    private var model: ModelState = .none
    private var lastMetrics: GenerationMetrics?
    private var activeClient: InferenceClient?

    // FIFO gate
    private var gateBusy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    /// Running generation tasks, so lifecycle changes can cancel them.
    private var generationTasks: [UUID: Task<Void, Never>] = [:]
    /// Generations cancelled by `load` / `unload` (reported as `.lifecycleChanged`, not user cancellation).
    private var lifecycleCancelled: Set<UUID> = []

    private var observers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    public init(engine: any InferenceEngine, maxQueued: Int = 8) {
        self.engine = engine
        self.maxQueued = maxQueued
    }

    // MARK: Observation

    public var snapshot: Snapshot {
        Snapshot(model: model, activeClient: activeClient, queuedCount: waiters.count, lastMetrics: lastMetrics)
    }

    /// A stream that yields the current snapshot immediately and then every change.
    public func snapshots() -> AsyncStream<Snapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func publish() {
        let s = snapshot
        for c in observers.values { c.yield(s) }
    }

    // MARK: Lifecycle

    /// Loads `reference`, replacing any loaded model. Running generations are cancelled first.
    @discardableResult
    public func load(_ reference: ModelReference) async throws -> LoadedModelInfo {
        cancelAllGenerations()
        let ticket = UUID()
        try await acquire(ticket, bypassLimit: true)
        defer { release() }

        if model.loadedModel != nil { await engine.unload() }
        model = .loading(id: reference.id, progress: 0)
        publish()

        let clock = ContinuousClock()
        let start = clock.now
        do {
            var info = try await engine.load(reference) { [weak self] fraction in
                Task { await self?.updateLoadProgress(id: reference.id, fraction) }
            }
            info.loadDuration = clock.now - start
            model = .ready(info)
            publish()
            return info
        } catch {
            model = .failed(id: reference.id, message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            publish()
            throw error
        }
    }

    private func updateLoadProgress(id: String, _ fraction: Double) {
        guard case .loading(let current, _) = model, current == id else { return }
        model = .loading(id: id, progress: min(max(fraction, 0), 1))
        publish()
    }

    /// Unloads the current model (if any), cancelling running generations.
    public func unload() async {
        cancelAllGenerations()
        let ticket = UUID()
        do { try await acquire(ticket, bypassLimit: true) } catch { return }
        defer { release() }
        if model.loadedModel != nil || model != .none { await engine.unload() }
        model = .none
        publish()
    }

    /// Called on system memory pressure: frees the model only when nothing is generating.
    public func handleMemoryPressure() async -> Bool {
        guard !gateBusy, model.loadedModel != nil else { return false }
        await unload()
        return true
    }

    // MARK: Memory

    /// Engine memory counters. Reading counters doesn't touch the model, so it bypasses the gate.
    public nonisolated func memory() async -> EngineMemory? { await engine.memory() }
    public nonisolated func resetPeakMemory() async { await engine.resetPeakMemory() }

    // MARK: Generation

    /// Streams a generation. Iteration order: zero or more `.text`, then `.finished`.
    /// Stop iterating (or cancel the consuming task) to cancel; queued requests are dropped from the queue.
    public nonisolated func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        let id = UUID()
        let task = Task { await self.track(id: id, request: request, into: continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Runs the generation in an inner task that is registered synchronously, so lifecycle changes can
    /// cancel it; cancellation of the outer task (consumer went away) is forwarded too.
    private func track(id: UUID, request: GenerationRequest,
                       into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) async {
        let inner = Task { await self.run(id: id, request: request, into: continuation) }
        generationTasks[id] = inner
        await withTaskCancellationHandler {
            await inner.value
        } onCancel: {
            inner.cancel()
        }
        generationTasks[id] = nil
    }

    private func run(id: UUID, request: GenerationRequest,
                     into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) async {
        do {
            try await acquire(id, bypassLimit: false)
        } catch {
            continuation.finish(throwing: error)
            return
        }
        defer {
            activeClient = nil
            release()
        }
        guard model.loadedModel != nil else {
            continuation.finish(throwing: InferenceError.noModelLoaded)
            return
        }
        activeClient = request.client
        publish()

        var req = request
        req.parameters = request.parameters.validated()
        do {
            var finished = false
            for try await event in engine.generate(req) {
                try Task.checkCancellation()
                if case .finished(let metrics) = event {
                    lastMetrics = metrics
                    finished = true
                }
                continuation.yield(event)
            }
            // AsyncThrowingStream iteration ends silently on cancellation; surface it explicitly.
            try Task.checkCancellation()
            guard finished else { throw InferenceError.generationFailed("the engine stopped unexpectedly") }
            continuation.finish()
        } catch is CancellationError {
            let lifecycle = lifecycleCancelled.remove(id) != nil
            continuation.finish(throwing: lifecycle ? InferenceError.lifecycleChanged : CancellationError())
        } catch {
            continuation.finish(throwing: error)
        }
        lifecycleCancelled.remove(id)
    }

    private func cancelAllGenerations() {
        for (id, task) in generationTasks {
            lifecycleCancelled.insert(id)
            task.cancel()
        }
    }

    // MARK: FIFO gate

    private func acquire(_ id: UUID, bypassLimit: Bool) async throws {
        try Task.checkCancellation()
        if !gateBusy {
            gateBusy = true
            return
        }
        if !bypassLimit, waiters.count >= maxQueued { throw InferenceError.queueFull }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    c.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, c))
                    publish()
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        publish()
    }

    private func release() {
        if waiters.isEmpty {
            gateBusy = false
        } else {
            // Ownership passes directly to the next waiter; gateBusy stays true.
            waiters.removeFirst().continuation.resume()
        }
        publish()
    }
}
