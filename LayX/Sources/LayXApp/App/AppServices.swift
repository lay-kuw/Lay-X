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
        models = ModelLibrary(store: ModelStore(root: storeRoot), coordinator: coordinator, architectures: architectures)

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
        startMemoryPressureMonitor()
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
                }
                self.snapshot = s
            }
        }
    }

    /// Last measured metrics per model id (this session only; Performance persists benchmark runs separately).
    private(set) var metricsByModel: [String: GenerationMetrics] = [:]

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
