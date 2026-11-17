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
    private(set) var database: SQLiteDatabase?
    private(set) var databaseError: String?
    private(set) var pinnedChats: (any PinnedChatStoring)?
    let models: ModelLibrary
    let chats: ChatSessionStore
    let work = WorkProjects()
    let performance: PerformanceModel
    let images: ImageStudio
    private(set) var api: APIServerModel!
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var defaultsObserver: NSObjectProtocol?
    private var appliedEngineSettings: EngineSettings?
    private var idleTask: Task<Void, Never>?

    static let modelStorePathKey = "lx.modelStorePath"
    static let databaseFolderKey = "lx.databaseFolder"

    /// `<chosen folder>/LayX.sqlite`, or `~/.config/lay-x/database/LayX.sqlite` by default.
    static func databaseURL() throws -> URL {
        if let folder = UserDefaults.standard.string(forKey: databaseFolderKey) {
            return URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(LayXSchema.fileName)
        }
        return try LayXSchema.defaultURL()
    }

    var isDefaultDatabaseLocation: Bool { UserDefaults.standard.string(forKey: Self.databaseFolderKey) == nil }

    /// Moves (or switches) the database to `folder` (nil = default location), live.
    /// - No database there yet → the current one is moved (copied, then the old files are deleted).
    /// - A Lay X database already there → it is used; the current file is left where it was.
    /// Returns a user-facing message.
    func changeDatabaseLocation(to folder: URL?) async -> String {
        guard chats.generating.isEmpty else { return "Wait for replies to finish before moving the database." }
        let newURL: URL
        do {
            if let folder {
                let root = try ModelStore.root(forChosenFolder: folder)
                newURL = root.appendingPathComponent(LayXSchema.fileName)
            } else {
                newURL = try LayXSchema.defaultURL()
            }
        } catch {
            return "That folder can’t be used: \(error.localizedDescription)"
        }
        guard let oldURL = try? Self.databaseURL(), newURL.standardizedFileURL != oldURL.standardizedFileURL else {
            return "The database is already there."
        }
        var message: String
        do {
            await chats.flushWrites()
            if FileManager.default.fileExists(atPath: newURL.path) {
                message = "Now using the existing database in \((newURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath). The previous file was left in place."
                await database?.close()
            } else {
                if let db = database {
                    try await LayXSchema.move(db, from: oldURL, to: newURL)
                }
                message = "Database moved to \((newURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)."
            }
            let db = try SQLiteDatabase(location: .file(newURL), migrations: LayXSchema.migrations)
            let defaultFolder = try? LayXSchema.defaultURL().deletingLastPathComponent()
            if let folder, ModelStore.canonicalPath(folder) != defaultFolder.map(ModelStore.canonicalPath) {
                UserDefaults.standard.set(ModelStore.canonicalPath(folder), forKey: Self.databaseFolderKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.databaseFolderKey)
            }
            database = db
            databaseError = nil
            pinnedChats = PinnedChatRepository(database: db)
            await chats.replaceRepository(pinnedChats)
            await performance.replaceStore(BenchmarkStore(database: db))
            await images.replaceStore(Self.imageStore(db))
            await api.useDatabase(db)
        } catch {
            // Fall back to whatever is at the old location so pinning keeps working.
            if let db = try? SQLiteDatabase(location: .file(oldURL), migrations: LayXSchema.migrations) {
                database = db
                pinnedChats = PinnedChatRepository(database: db)
                await chats.replaceRepository(pinnedChats)
                await performance.replaceStore(BenchmarkStore(database: db))
            }
            message = "The database couldn’t be moved: \(error.localizedDescription). Lay X is still using the previous location."
        }
        return message
    }

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
            let db = try SQLiteDatabase(location: .file(try Self.databaseURL()), migrations: LayXSchema.migrations)
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
                // Chat never loads a model by itself: the one in memory (or loading) is used, otherwise the user
                // is asked to choose one.
                let id: String? = switch await coordinator.snapshot.model {
                case .ready(let info): info.id
                case .loading(let id, _): id
                default: nil
                }
                guard let id, let model = library.model(id) else {
                    throw library.installed.isEmpty ? ChatSetupError.noModelInstalled : ChatSetupError.noModelLoaded
                }
                return try await coordinator.load(model.reference)
            },
            webResearcher: { try WebResearcher(config: WebPreferences.config) })
        performance = PerformanceModel(store: database.map(BenchmarkStore.init(database:)), coordinator: coordinator)
        #if canImport(LayXMLX)
        let imageEngine: any ImageEngine = MLXImageEngine()
        #else
        let imageEngine: any ImageEngine = UnavailableImageEngine()
        #endif
        images = ImageStudio(
            engine: imageEngine, coordinator: coordinator, store: database.flatMap(Self.imageStore),
            loras: Self.loraFolder().map(LoRALibrary.init(folder:)),
            modelDirectory: { spec in
                // Current storage folder (it can be changed in Settings).
                AppServices.shared.models.imageStore.installedModel(spec.id).flatMap { $0.isImageModel ? $0.directory : nil }
            },
            availableMemory: { SystemMemory.availableBytes() },
            allowUnloadingTextModel: { ImagePreferences.makeRoom },
            keepLoaded: { ImagePreferences.keepLoaded })
        let images = self.images
        images.activeLoRAs = ImagePreferences.activeLoRAs
        Task { await images.loadHistory() }
        // Before a text model loads: free an idle image model if the text model wouldn't fit next to it.
        Task {
            await coordinator.setBeforeLoad { reference in
                let need = Int64(Double(ModelStore.allocatedSize(of: reference.directory)) * 1.2)
                guard SystemMemory.availableBytes() < need else { return }
                if await images.releaseForTextModel() {
                    Log.inference.info("Unloaded the image model to make room for a text model")
                }
            }
        }
        let chats = self.chats
        Task { await chats.loadPinned() }
        startMemoryPressureMonitor()
        inferenceStatus.startMemoryPolling(coordinator)
        api = APIServerModel(coordinator: coordinator, models: library)
        applyEngineSettings()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppServices.shared.applyEngineSettings() }
        }
        startIdleUnload()
        // "Keep the model ready": load the default chat model at launch (with warm-up).
        if EnginePreferences.preloadModel {
            Task {
                try? await Task.sleep(for: .milliseconds(300))   // let the store scan finish
                guard await coordinator.snapshot.model.loadedModel == nil,
                      let model = AppServices.defaultChatModel(in: library) else { return }
                _ = try? await coordinator.load(model.reference)
            }
        }
    }

    /// Pushes Settings → Models & Inference engine values to the engine when they change.
    func applyEngineSettings() {
        let settings = EnginePreferences.engineSettings
        guard settings != appliedEngineSettings else { return }
        appliedEngineSettings = settings
        let coordinator = self.coordinator
        Task { await coordinator.configure(settings) }
    }

    /// "Keep model loaded": unloads the model after the configured idle time (never while generating).
    private func startIdleUnload() {
        let status = inferenceStatus, coordinator = self.coordinator
        idleTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                let minutes = EnginePreferences.keepLoadedMinutes
                guard minutes > 0, status.loadedModel != nil, !status.isGenerating,
                      Date().timeIntervalSince(status.lastActivity) > Double(minutes * 60) else { continue }
                if await coordinator.handleMemoryPressure() {
                    Log.inference.info("Unloaded model after \(minutes) idle minutes")
                }
            }
        }
    }

    static func imageStore(_ db: SQLiteDatabase) -> ImageHistoryStore? {
        imagesFolder().map { ImageHistoryStore(database: db, folder: $0) }
    }

    // MARK: Image storage (Settings → Image Generation → Storage)

    static let imagesFolderKey = "lx.imagesFolderPath"
    static let loraFolderKey = "lx.loraFolderPath"

    /// Generated images: the chosen folder, else `~/.config/lay-x/images`.
    static func imagesFolder() -> URL? {
        if let path = UserDefaults.standard.string(forKey: imagesFolderKey) { return URL(fileURLWithPath: path, isDirectory: true) }
        return try? ImageHistoryStore.defaultFolder()
    }

    /// LoRAs: the chosen folder, else `~/.config/lay-x/loras`.
    static func loraFolder() -> URL? {
        if let path = UserDefaults.standard.string(forKey: loraFolderKey) { return URL(fileURLWithPath: path, isDirectory: true) }
        return try? LoRALibrary.defaultFolder()
    }

    /// Moves the generated images (PNG files) to `chosen` (nil = default) and keeps the history pointing at them.
    /// Returns a message for the user.
    func changeImagesFolder(to chosen: URL?) async -> String {
        guard !images.isBusy else { return "Wait for the image generation to finish." }
        guard let old = Self.imagesFolder(), let target = chosen ?? (try? ImageHistoryStore.defaultFolder()) else {
            return "That folder can’t be used."
        }
        do {
            let moved = try await Self.moveFiles(from: old, to: target) { $0.hasSuffix(".png") }
            if chosen == nil { UserDefaults.standard.removeObject(forKey: Self.imagesFolderKey) }
            else { UserDefaults.standard.set(target.path, forKey: Self.imagesFolderKey) }
            await images.replaceStore(database.flatMap(Self.imageStore))
            return "Images are now saved in \((target.path as NSString).abbreviatingWithTildeInPath)\(moved > 0 ? " (\(moved) moved)" : "")."
        } catch {
            return "The images couldn’t be moved: \(error.localizedDescription)"
        }
    }

    /// Moves the LoRA files to `chosen` (nil = default).
    func changeLoRAFolder(to chosen: URL?) async -> String {
        guard !images.isBusy else { return "Wait for the image generation to finish." }
        guard let old = Self.loraFolder(), let target = chosen ?? (try? LoRALibrary.defaultFolder()) else { return "That folder can’t be used." }
        do {
            let moved = try await Self.moveFiles(from: old, to: target) { $0.lowercased().hasSuffix(".safetensors") }
            if chosen == nil { UserDefaults.standard.removeObject(forKey: Self.loraFolderKey) }
            else { UserDefaults.standard.set(target.path, forKey: Self.loraFolderKey) }
            images.replaceLoRALibrary(LoRALibrary(folder: target))
            return "LoRAs are now kept in \((target.path as NSString).abbreviatingWithTildeInPath)\(moved > 0 ? " (\(moved) moved)" : "")."
        } catch {
            return "The LoRAs couldn’t be moved: \(error.localizedDescription)"
        }
    }

    /// Moves matching files (top level only); a file already present at the target is kept and the original left.
    private static func moveFiles(from old: URL, to new: URL, matching: @escaping @Sendable (String) -> Bool) async throws -> Int {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.createDirectory(at: new, withIntermediateDirectories: true)
            guard ModelStore.canonicalPath(old) != ModelStore.canonicalPath(new) else { return 0 }
            var moved = 0
            for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] where matching(name) && !name.hasPrefix(".") {
                let target = new.appendingPathComponent(name)
                guard !fm.fileExists(atPath: target.path) else { continue }
                try fm.moveItem(at: old.appendingPathComponent(name), to: target)
                moved += 1
            }
            return moved
        }.value
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
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        let coordinator = self.coordinator
        source.setEventHandler { [weak source] in
            let critical = source?.data.contains(.critical) ?? false
            Task {
                // Reusable KV caches go first, then an idle image model; the text model itself only under
                // critical pressure, and only when idle.
                await coordinator.discardCaches(key: nil)
                await AppServices.shared.images.releaseForTextModel()
                if critical, await coordinator.handleMemoryPressure() {
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
                if s.activeClient != nil || s.model != self.snapshot.model { self.lastActivity = Date() }
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
    /// Last time a model was loaded or a generation ran (idle unload).
    private(set) var lastActivity = Date()
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

struct UnavailableImageEngine: ImageEngine {
    func load(_ spec: ImageModelSpec, directory: URL, loras: [LoRAFile]) async throws -> LoRALoadReport {
        throw ImageEngineError.loadFailed("this build of Lay X was compiled without the MLX engine")
    }
    func unload() async {}
    func generate(_ request: ImageRequest) -> AsyncThrowingStream<ImageEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ImageEngineError.notLoaded) }
    }
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
