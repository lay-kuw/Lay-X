import Foundation
import Observation

/// State and orchestration of the Image screen: model loading (with memory arbitration against the text
/// model), generation through the shared GPU gate, saving and history. `@MainActor` because the UI observes it.
///
/// Memory rules:
/// - Image generation and text generation never run at the same time (the coordinator's gate).
/// - Before the image model loads, reusable KV caches are dropped if memory is short; if it is still short and
///   automatic unloading is allowed, an idle text model is unloaded (and the user is told).
/// - Before a text model loads, `releaseForTextModel()` frees an idle image model when memory is short.
/// - An idle image model is unloaded after `keepLoaded` (default 5 minutes).
@MainActor
@Observable
public final class ImageStudio {
    public enum Phase: Equatable, Sendable {
        case idle
        case freeingMemory
        case loadingModel
        /// Waiting for the GPU (a text generation is running).
        case waiting
        case generating(index: Int, count: Int, step: Int, total: Int)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var history: [ImageRecord] = []
    public private(set) var loadedModelID: String?
    public var selectedID: UUID?
    public private(set) var error: String?
    public private(set) var notice: String?

    public var isBusy: Bool { phase != .idle }

    /// Composer draft (kept while switching screens).
    public var draftPrompt = ""
    /// Fixed seed text ("" = random each time).
    public var draftSeed = ""

    @ObservationIgnored private let engine: any ImageEngine
    @ObservationIgnored private let coordinator: InferenceCoordinator
    @ObservationIgnored private var store: ImageHistoryStore?
    @ObservationIgnored private let modelDirectory: @MainActor (ImageModelSpec) -> URL?
    @ObservationIgnored private let availableMemory: @Sendable () -> Int64
    @ObservationIgnored private let allowUnloadingTextModel: @MainActor () -> Bool
    @ObservationIgnored private let keepLoaded: @MainActor () -> Duration?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var generationCounter = 0

    public init(engine: any ImageEngine, coordinator: InferenceCoordinator, store: ImageHistoryStore?,
                modelDirectory: @escaping @MainActor (ImageModelSpec) -> URL?,
                availableMemory: @escaping @Sendable () -> Int64,
                allowUnloadingTextModel: @escaping @MainActor () -> Bool = { true },
                keepLoaded: @escaping @MainActor () -> Duration? = { .seconds(300) }) {
        self.engine = engine
        self.coordinator = coordinator
        self.store = store
        self.modelDirectory = modelDirectory
        self.availableMemory = availableMemory
        self.allowUnloadingTextModel = allowUnloadingTextModel
        self.keepLoaded = keepLoaded
    }

    public var imagesFolder: URL? { store?.folder }

    public func url(for record: ImageRecord) -> URL? { store?.url(for: record) }

    public var selected: ImageRecord? { history.first { $0.id == selectedID } ?? history.first }

    public func clearMessages() { error = nil; notice = nil }

    /// Switches storage (database or folder moved).
    public func replaceStore(_ newStore: ImageHistoryStore?) async {
        store = newStore
        await loadHistory()
    }

    public func loadHistory() async {
        guard let store else { history = []; return }
        history = (try? await store.loadAll()) ?? []
    }

    // MARK: Generation

    public func generate(_ request: ImageRequest, spec: ImageModelSpec) {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isBusy else { return }
        var req = request
        req.prompt = prompt
        req.steps = min(max(req.steps, 1), spec.stepChoices.max() ?? 4)
        req.count = min(max(req.count, 1), 4)
        req.size = spec.resolution
        error = nil
        notice = nil
        idleTask?.cancel()
        generationCounter += 1
        task = Task { await self.run(req, spec: spec) }
    }

    public func stop() { task?.cancel() }

    private func run(_ request: ImageRequest, spec: ImageModelSpec) async {
        defer {
            phase = .idle
            task = nil
            scheduleIdleUnload()
        }
        do {
            try await ensureLoaded(spec)
            phase = .waiting
            let clock = ContinuousClock()
            let start = clock.now
            let engine = self.engine
            try await coordinator.exclusive(client: .image) {
                for try await event in engine.generate(request) {
                    try Task.checkCancellation()
                    await self.handle(event, request: request, spec: spec, elapsed: (clock.now - start).seconds)
                }
                try Task.checkCancellation()
            }
        } catch is CancellationError {
            notice = "Stopped."
        } catch {
            if Task.isCancelled { notice = "Stopped." } else {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Image generation failed."
            }
        }
    }

    private func handle(_ event: ImageEvent, request: ImageRequest, spec: ImageModelSpec, elapsed: Double) async {
        switch event {
        case .progress(let index, let step, let total):
            phase = .generating(index: index, count: request.count, step: step, total: total)
        case .image(let index, let png, let seed):
            guard let store else {
                error = "Images can’t be saved: the local database isn’t available."
                return
            }
            do {
                let record = try await store.save(
                    png: png, prompt: request.prompt, negativePrompt: request.negativePrompt, modelID: spec.id.description,
                    seed: seed, steps: request.steps, size: request.size, duration: elapsed / Double(index + 1), index: index)
                history.insert(record, at: 0)
                selectedID = record.id
            } catch {
                self.error = "The image couldn’t be saved: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Model & memory

    private func ensureLoaded(_ spec: ImageModelSpec) async throws {
        if loadedModelID == spec.id.description { return }
        guard let directory = modelDirectory(spec) else {
            throw ImageEngineError.loadFailed("\(spec.name) isn’t downloaded yet")
        }
        if loadedModelID != nil { await engine.unload(); loadedModelID = nil }
        try await makeRoom(for: spec)
        phase = .loadingModel
        try Task.checkCancellation()
        try await engine.load(spec, directory: directory)
        loadedModelID = spec.id.description
    }

    private func makeRoom(for spec: ImageModelSpec) async throws {
        let need = spec.runtimeBytes
        var available = availableMemory()
        guard available < need else { return }
        phase = .freeingMemory
        await coordinator.discardCaches(key: nil)
        await coordinator.clearCache()
        available = availableMemory()
        if available < need, allowUnloadingTextModel(), await coordinator.isIdleWithModel {
            let name = await coordinator.snapshot.model.loadedModel?.id.split(separator: "/").last.map(String.init) ?? "the chat model"
            await coordinator.unload()
            await coordinator.clearCache()
            // macOS reports freed pages with a delay: give it up to 3 s.
            for _ in 0..<30 {
                available = availableMemory()
                if available >= need { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            notice = "Unloaded \(name) to make room for image generation. It reloads when you chat."
        }
        guard available >= need else {
            throw ImageEngineError.notEnoughMemory(neededGB: Double(need) / 1_073_741_824, availableGB: Double(available) / 1_073_741_824)
        }
    }

    /// Frees an idle image model (called before a text model loads when memory is short). Returns true if it
    /// was unloaded.
    @discardableResult
    public func releaseForTextModel() async -> Bool {
        guard loadedModelID != nil, !isBusy else { return false }
        await unloadModel()
        return true
    }

    public func unloadModel() async {
        idleTask?.cancel()
        guard loadedModelID != nil, !isBusy else { return }
        await engine.unload()
        loadedModelID = nil
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        guard loadedModelID != nil, let keep = keepLoaded() else { return }
        let counter = generationCounter
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: keep)
            guard !Task.isCancelled, let self, self.generationCounter == counter, !self.isBusy else { return }
            await self.unloadModel()
        }
    }

    // MARK: History

    public func delete(_ record: ImageRecord) {
        history.removeAll { $0.id == record.id }
        if selectedID == record.id { selectedID = history.first?.id }
        guard let store else { return }
        Task { try? await store.delete(record) }
    }
}
