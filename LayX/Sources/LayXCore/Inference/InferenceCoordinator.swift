import Foundation
import Synchronization

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
        /// A preemptible generation paused so an interactive reply can run.
        public var pausedClient: InferenceClient?

        public init(model: ModelState = .none, activeClient: InferenceClient? = nil, queuedCount: Int = 0,
                    lastMetrics: GenerationMetrics? = nil, pausedClient: InferenceClient? = nil) {
            self.model = model
            self.activeClient = activeClient
            self.queuedCount = queuedCount
            self.lastMetrics = lastMetrics
            self.pausedClient = pausedClient
        }
    }

    private let engine: any InferenceEngine
    private let maxQueued: Int

    private var model: ModelState = .none
    private var lastMetrics: GenerationMetrics?

    // FIFO gate (one primary owner at a time) + one interactive "overlay" that may run while a preemptible
    // primary generation is paused.
    private enum Owner { case lifecycle, generation(UUID, InferenceClient, PauseGate?) }
    private enum Slot { case primary, overlay }
    private var gateBusy = false
    private var owner: Owner?
    private var waiters: [(id: UUID, owner: Owner, continuation: CheckedContinuation<Void, Error>)] = []
    private var overlay: (id: UUID, client: InferenceClient)?
    private var overlayWaiters: [(id: UUID, client: InferenceClient, continuation: CheckedContinuation<Void, Error>)] = []
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
        var primary: InferenceClient?
        var paused: InferenceClient?
        if case .generation(_, let client, let gate)? = owner {
            if gate?.isPaused == true { paused = client } else { primary = client }
        }
        return Snapshot(model: model, activeClient: overlay?.client ?? primary, queuedCount: waiters.count + overlayWaiters.count,
                        lastMetrics: lastMetrics, pausedClient: paused)
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
    /// Called before a text model loads (e.g. to free an idle image model when memory is short).
    private var beforeLoad: (@Sendable (ModelReference) async -> Void)?
    public func setBeforeLoad(_ hook: (@Sendable (ModelReference) async -> Void)?) { beforeLoad = hook }

    @discardableResult
    public func load(_ reference: ModelReference) async throws -> LoadedModelInfo {
        await beforeLoad?(reference)
        cancelAllGenerations()
        let ticket = UUID()
        try await acquire(ticket, as: .lifecycle, bypassLimit: true)
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
        do { try await acquire(ticket, as: .lifecycle, bypassLimit: true) } catch { return }
        defer { release() }
        if model.loadedModel != nil || model != .none { await engine.unload() }
        model = .none
        publish()
    }

    /// Called on system memory pressure: frees the model only when nothing is generating. (Callers should
    /// drop KV caches first with `discardCaches(key: nil)`.)
    public func handleMemoryPressure() async -> Bool {
        guard !gateBusy, overlay == nil, model.loadedModel != nil else { return false }
        await unload()
        return true
    }

    // MARK: Memory

    /// Engine memory counters. Reading counters doesn't touch the model, so it bypasses the gate.
    public nonisolated func memory() async -> EngineMemory? { await engine.memory() }
    public nonisolated func resetPeakMemory() async { await engine.resetPeakMemory() }

    /// Applies engine settings between generations (through the gate, so never mid-generation).
    public func configure(_ settings: EngineSettings) async {
        let ticket = UUID()
        do { try await acquire(ticket, as: .lifecycle, bypassLimit: true) } catch { return }
        defer { release() }
        await engine.configure(settings)
    }

    public nonisolated func clearCache() async { await engine.clearCache() }
    /// Drops reusable KV caches for a conversation (nil = all), e.g. when a chat is deleted.
    public nonisolated func discardCaches(key: String?) async { await engine.discardCaches(key: key) }
    public nonisolated func cacheBytes() async -> Int64 { await engine.cacheBytes() }

    // MARK: Other GPU work

    /// Runs non-text GPU work (image generation) under the generation gate: it never overlaps a text
    /// generation, waits its turn like any request, and — being interactive — pauses a running Work
    /// generation at a token boundary instead of waiting for it to finish.
    public func exclusive<T: Sendable>(client: InferenceClient, _ body: @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        let slot = try await acquireGeneration(id, client: client, gate: nil)
        defer { releaseGeneration(slot) }
        publish()
        return try await body()
    }

    /// True when a text model is loaded and nothing is generating or queued (safe to unload for memory).
    public var isIdleWithModel: Bool { !gateBusy && overlay == nil && model.loadedModel != nil }

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
        var req = request
        req.parameters = request.parameters.validated()
        req.pauseGate = request.client.isPreemptible ? PauseGate() : nil
        let slot: Slot
        do {
            slot = try await acquireGeneration(id, client: request.client, gate: req.pauseGate)
        } catch {
            continuation.finish(throwing: error)
            return
        }
        defer {
            req.pauseGate?.markDone()
            releaseGeneration(slot)
        }
        guard model.loadedModel != nil else {
            continuation.finish(throwing: InferenceError.noModelLoaded)
            return
        }
        publish()

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

    // MARK: Gate

    /// Lifecycle operations take the primary gate (FIFO).
    private func acquire(_ id: UUID, as role: Owner, bypassLimit: Bool) async throws {
        try Task.checkCancellation()
        if !gateBusy {
            gateBusy = true
            owner = role
            return
        }
        if !bypassLimit, waiters.count >= maxQueued { throw InferenceError.queueFull }
        try await wait(id, as: role)
    }

    /// Generations take the primary gate, except an interactive request that arrives while a preemptible
    /// generation holds it: that generation is paused and the request runs as the overlay.
    private func acquireGeneration(_ id: UUID, client: InferenceClient, gate: PauseGate?) async throws -> Slot {
        try Task.checkCancellation()
        let role = Owner.generation(id, client, gate)
        if !gateBusy {
            gateBusy = true
            owner = role
            return .primary
        }
        if client.isInteractive, case .generation(_, let ownerClient, let ownerGate)? = owner, ownerClient.isPreemptible {
            if overlay == nil {
                overlay = (id, client)
                ownerGate?.pause()
                publish()
                // Never run two generations at once: wait until the paused one has stopped at a token boundary.
                await ownerGate?.waitUntilParked()
                return .overlay
            }
            guard overlayWaiters.count < maxQueued else { throw InferenceError.queueFull }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { c.resume(throwing: CancellationError()) } else {
                        overlayWaiters.append((id, client, c))
                        publish()
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
            return .overlay
        }
        guard waiters.count < maxQueued else { throw InferenceError.queueFull }
        try await wait(id, as: role)
        return .primary
    }

    private func wait(_ id: UUID, as role: Owner) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    c.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, role, c))
                    publish()
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if let index = overlayWaiters.firstIndex(where: { $0.id == id }) {
            overlayWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
        publish()
    }

    private func releaseGeneration(_ slot: Slot) {
        switch slot {
        case .primary: release()
        case .overlay:
            if !overlayWaiters.isEmpty, case .generation(_, let c, _)? = owner, c.isPreemptible {
                let next = overlayWaiters.removeFirst()
                overlay = (next.id, next.client)
                next.continuation.resume()
            } else {
                // Hand any queued interactive requests to the normal queue and resume the paused generation.
                overlay = nil
                for w in overlayWaiters { waiters.insert((w.id, .generation(w.id, w.client, nil), w.continuation), at: 0) }
                overlayWaiters.removeAll()
                if case .generation(_, _, let gate)? = owner { gate?.resume() }
            }
            publish()
        }
    }

    private func release() {
        if waiters.isEmpty {
            gateBusy = false
            owner = nil
        } else {
            // Ownership passes directly to the next waiter; gateBusy stays true.
            let next = waiters.removeFirst()
            owner = next.owner
            // An interactive overlay may still be running; a newly started preemptible owner starts paused.
            if overlay != nil, case .generation(_, let c, let gate) = next.owner, c.isPreemptible { gate?.pause() }
            next.continuation.resume()
        }
        publish()
    }
}
