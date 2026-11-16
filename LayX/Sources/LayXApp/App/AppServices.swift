import Foundation
import LayXCore
#if canImport(LayXMLX)
import LayXMLX
#endif

/// Process-wide services shared by every window, Mini Chat and the API server.
/// Created once at launch; UI-bound state observes these through `@MainActor` models.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let coordinator: InferenceCoordinator
    let inferenceStatus: InferenceStatusModel
    /// `nil` when the database could not be opened; pinning then reports an error instead of silently failing.
    let database: SQLiteDatabase?
    let databaseError: String?
    let pinnedChats: (any PinnedChatStoring)?
    let models: ModelLibrary
    let chats: ChatSessionStore
    let work = WorkProjects()
    let performance: PerformanceModel
    private var memoryPressure: DispatchSourceMemoryPressure?

    static let modelStorePathKey = "lx.modelStorePath"

    private init() {
        #if canImport(LayXMLX)
        let engine: any InferenceEngine = MLXEngine()
        let architectures: any ModelArchitectureSupport = MLXArchitectureSupport()
        #else
        let engine: any InferenceEngine = UnavailableEngine()
        let architectures: any ModelArchitectureSupport = NoArchitectures()
        #endif
        coordinator = InferenceCoordinator(engine: engine)
        inferenceStatus = InferenceStatusModel(coordinator: coordinator)

        let storeRoot = UserDefaults.standard.string(forKey: Self.modelStorePathKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? (try? ModelStore.defaultRoot())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("LayXModels", isDirectory: true)
        let library = ModelLibrary(store: ModelStore(root: storeRoot), coordinator: coordinator, architectures: architectures)
        models = library

        do {
            let db = try SQLiteDatabase(location: .file(try LayXSchema.defaultURL()), migrations: LayXSchema.migrations)
            database = db
            databaseError = nil
            pinnedChats = PinnedChatRepository(database: db)
        } catch {
            Log.persistence.error("Database unavailable: \(String(describing: error), privacy: .public)")
            database = nil
            databaseError = "Pinned chats can’t be saved: the local database couldn’t be opened."
            pinnedChats = nil
        }
        let coordinator = self.coordinator
        chats = ChatSessionStore(
            coordinator: coordinator, repository: pinnedChats,
            settings: { ChatPreferences.current },
            prepareModel: {
                guard let model = AppServices.defaultChatModel(in: library) else { throw ChatSetupError.noModelInstalled }
                return try await coordinator.load(model.reference)
            })
        performance = PerformanceModel(store: database.map(BenchmarkStore.init(database:)), coordinator: coordinator)
        let chats = self.chats
        Task { await chats.loadPinned() }
        startMemoryPressureMonitor()
        inferenceStatus.startMemoryPolling(coordinator)
    }

    /// The model used when a chat needs one and none is loaded: the configured default if installed, else the
    /// most recently used, else the first installed model.
    static func defaultChatModel(in library: ModelLibrary) -> InstalledModel? {
        if let id = UserDefaults.standard.string(forKey: ChatPreferences.defaultChatModelKey), let m = library.model(id) { return m }
        let byUse = library.installed.sorted {
            (library.lastUsed($0.id) ?? .distantPast) > (library.lastUsed($1.id) ?? .distantPast)
        }
        return byUse.first
    }

    /// On critical memory pressure the model is unloaded if nothing is generating (it reloads on demand).
    private func startMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.critical], queue: .main)
        let coordinator = self.coordinator
        source.setEventHandler {
            Task {
                if await coordinator.handleMemoryPressure() {
                    Log.inference.notice("Unloaded model after critical memory pressure")
                }
            }
        }
        source.activate()
        memoryPressure = source
    }
}

/// MainActor mirror of the coordinator's state for SwiftUI.
@MainActor
@Observable
final class InferenceStatusModel {
    private(set) var snapshot = InferenceCoordinator.Snapshot()
    @ObservationIgnored private var task: Task<Void, Never>?

    init(coordinator: InferenceCoordinator) {
        task = Task { [weak self] in
            for await s in await coordinator.snapshots() {
                guard let self else { return }
                if let m = s.lastMetrics, m != self.snapshot.lastMetrics, let id = s.model.loadedModel?.id {
                    self.metricsByModel[id] = m
                    self.history.insert(LiveSample(date: Date(), client: self.snapshot.activeClient ?? .chat, modelID: id, metrics: m), at: 0)
                    if self.history.count > 100 { self.history.removeLast() }
                }
                self.snapshot = s
            }
        }
    }

    /// Last measured metrics per model id (this session only; Performance persists benchmark runs separately).
    private(set) var metricsByModel: [String: GenerationMetrics] = [:]
    /// Recent generations across Chat / Mini Chat / Work / API / Benchmark — numbers only, no content.
    private(set) var history: [LiveSample] = []
    private(set) var engineMemory: EngineMemory?
    private(set) var systemMemoryUsed: Int64?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    struct LiveSample: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let client: InferenceClient
        let modelID: String
        let metrics: GenerationMetrics
    }

    /// Polls memory counters every 2 s (cheap reads; no model access).
    func startMemoryPolling(_ coordinator: InferenceCoordinator) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let engine = await coordinator.memory()
                let system = SystemMemory.usedBytes()
                self?.engineMemory = engine
                self?.systemMemoryUsed = system
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    var loadedModel: LoadedModelInfo? { snapshot.model.loadedModel }
    var isGenerating: Bool { snapshot.activeClient != nil }
}

#if !canImport(LayXMLX)
struct NoArchitectures: ModelArchitectureSupport {
    func supports(modelType: String) async -> Bool { false }
}

/// Engine used when the app is built with `LAYX_NO_MLX=1`.
struct UnavailableEngine: InferenceEngine {
    func load(_ model: ModelReference, progress: @escaping @Sendable (Double) -> Void) async throws -> LoadedModelInfo {
        throw InferenceError.loadFailed("this build of Lay X was compiled without the MLX engine")
    }
    func unload() async {}
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: InferenceError.noModelLoaded) }
    }
}
#endif
