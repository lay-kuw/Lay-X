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
    /// LoRAs merged into the loaded model.
    public private(set) var loadedLoRAs: [LoRAChoice] = []
    /// LoRAs in the library (refreshed on import / delete).
    public private(set) var loraLibrary: [LoRALibrary.Info] = []
    /// LoRAs switched on in the composer, with their strengths.
    public var activeLoRAs: [LoRAChoice] = []
    public var selectedID: UUID?
    /// The canvas follows the running generation (true when it starts; false once a history image is picked —
    /// the run carries on in the background).
    public private(set) var watchingProgress = false
    /// Images finished / requested in the running batch (0 / 0 when idle).
    public private(set) var runDone = 0
    public private(set) var runCount = 0

    /// Shows a history image (a running generation continues in the background).
    public func select(_ id: UUID) {
        selectedID = id
        watchingProgress = false
    }

    /// Shows the running generation on the canvas.
    public func watchProgress() { if isBusy { watchingProgress = true } }
    /// Image model chosen in the picker for this session (nothing is chosen at launch).
    public var selectedModelID: String?
    public private(set) var error: String?
    public private(set) var notice: String?

    public var isBusy: Bool { phase != .idle }

    /// Composer draft (kept while switching screens).
    public var draftPrompt = ""
    /// Fixed seed text ("" = random each time).
    public var draftSeed = ""
    public var draftNegative = ""
    /// Image to image source (PNG/JPEG data) and its label; nil = text to image.
    public var sourceImage: Data?
    public var sourceLabel = ""
    public var strength = 0.6

    /// Uses a history image as the source for image to image.
    public func useAsSource(_ record: ImageRecord) {
        guard let url = url(for: record), let data = try? Data(contentsOf: url) else { return }
        sourceImage = data
        sourceLabel = "From history · seed \(record.seed)"
    }

    @ObservationIgnored private let engine: any ImageEngine
    @ObservationIgnored private let coordinator: InferenceCoordinator
    @ObservationIgnored private var store: ImageHistoryStore?
    @ObservationIgnored private var loras: LoRALibrary?
    /// Folder of the `__name__` wildcard files (nil = wildcards stay as typed).
    public let wildcardsFolder: URL?
    @ObservationIgnored private let modelDirectory: @MainActor (ImageModelSpec) -> URL?
    @ObservationIgnored private let availableMemory: @Sendable () -> Int64
    @ObservationIgnored private let allowUnloadingTextModel: @MainActor () -> Bool
    @ObservationIgnored private let keepLoaded: @MainActor () -> Duration?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var generationCounter = 0

    public init(engine: any ImageEngine, coordinator: InferenceCoordinator, store: ImageHistoryStore?,
                loras: LoRALibrary? = nil, wildcardsFolder: URL? = nil,
                modelDirectory: @escaping @MainActor (ImageModelSpec) -> URL?,
                availableMemory: @escaping @Sendable () -> Int64,
                allowUnloadingTextModel: @escaping @MainActor () -> Bool = { true },
                keepLoaded: @escaping @MainActor () -> Duration? = { .seconds(300) }) {
        self.engine = engine
        self.coordinator = coordinator
        self.store = store
        self.loras = loras
        self.wildcardsFolder = wildcardsFolder
        self.modelDirectory = modelDirectory
        self.availableMemory = availableMemory
        self.allowUnloadingTextModel = allowUnloadingTextModel
        self.keepLoaded = keepLoaded
        refreshLoRAs()
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

    /// Most images one run makes (enough to leave it running overnight).
    public static let maxCount = 9999
    /// A run stops before the images folder's disk gets fuller than this.
    public static let minFreeDisk: Int64 = 2_000_000_000

    public func generate(_ request: ImageRequest, spec: ImageModelSpec) {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isBusy else { return }
        var req = request
        req.prompt = prompt
        let family = spec.family
        req.steps = min(max(req.steps, 1), 100)
        req.count = min(max(req.count, 1), Self.maxCount)
        req.strength = min(max(req.strength, 0.05), 1)
        req.cfg = spec.usesGuidance ? min(max(req.cfg, 0), 20) : 0
        if !spec.usesGuidance { req.negativePrompt = "" }
        switch family.sourceMode {
        case .strength: break
        case .reference: req.strength = 1      // the whole schedule runs; the source is a reference
        case .none: req.source = nil
        }
        let step = family.sizeStep
        req.size = ImageSize(min(max(req.size.width / step * step, 256), family.maxSide),
                             min(max(req.size.height / step * step, 256), family.maxSide))
        req.loras = Array(req.loras.filter { choice in
            guard choice.scale != 0, loras?.url(for: choice.file) != nil else { return false }
            return loraLibrary.first { $0.file == choice.file }.map { Self.lora($0, fits: family) } ?? true
        }.prefix(family.maxLoRAs))
        error = nil
        notice = nil
        expandDynamicPrompts(&req)
        idleTask?.cancel()
        generationCounter += 1
        watchingProgress = true
        runDone = 0
        runCount = req.count
        task = Task { await self.run(req, spec: spec) }
    }

    public func stop() { task?.cancel() }

    /// Dynamic Prompts: each image gets its own expansion, picked from its seed (so a seed reproduces it).
    private func expandDynamicPrompts(_ req: inout ImageRequest) {
        let hasPrompt = DynamicPrompt.hasSyntax(req.prompt)
        let hasNegative = !req.negativePrompt.isEmpty && DynamicPrompt.hasSyntax(req.negativePrompt)
        guard hasPrompt || hasNegative else { return }
        let library = WildcardLibrary(folder: wildcardsFolder)
        var cache: [String: [String]?] = [:]
        let lookup: (String) -> [String]? = { name in
            if let hit = cache[name] { return hit }
            let lines = library.lines(name)
            cache[name] = lines
            return lines
        }
        var missing = Set<String>()
        func expand(_ text: String, _ index: Int, salt: UInt64) -> String {
            let result = DynamicPrompt.expand(text, seed: req.seed(at: index) &+ salt, wildcards: lookup)
            missing.formUnion(result.missingWildcards)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if hasPrompt { req.prompts = (0..<req.count).map { expand(req.prompt, $0, salt: 0) } }
        if hasNegative { req.negativePrompts = (0..<req.count).map { expand(req.negativePrompt, $0, salt: 1) } }
        if !missing.isEmpty {
            let names = missing.sorted().map { "__\($0)__" }.joined(separator: ", ")
            notice = "No wildcard file for \(names) — add \(missing.count == 1 ? "it" : "them") as .txt in the wildcards folder."
        }
    }

    private func run(_ request: ImageRequest, spec: ImageModelSpec) async {
        // Long runs keep going with the display off: idle sleep is held off until the run ends.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Generating images")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            phase = .idle
            task = nil
            watchingProgress = false
            runDone = 0
            runCount = 0
            scheduleIdleUnload()
        }
        do {
            try await ensureLoaded(spec, loras: request.loras, size: request.size)
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
            if let free = store.availableSpace(), free < Self.minFreeDisk {
                error = String(format: "Stopped: the disk is almost full (%.1f GB free). %d image%@ saved.",
                               Double(free) / 1e9, runDone, runDone == 1 ? "" : "s")
                task?.cancel()
                return
            }
            do {
                let record = try await store.save(
                    png: png, prompt: request.prompt(at: index),
                    negativePrompt: request.cfg > 1 ? request.negativePrompt(at: index) : "",
                    modelID: spec.id.description, seed: seed, steps: request.steps, cfg: request.cfg, size: request.size,
                    loras: request.loras.map { "\($0.displayName) ×\(String(format: "%.2g", $0.scale))" }.joined(separator: ", "),
                    strength: request.source == nil ? 0 : request.strength,
                    duration: elapsed / Double(index + 1), index: index)
                history.insert(record, at: 0)
                runDone += 1
                // Only while the canvas follows the run; otherwise the user's choice stays on screen.
                if watchingProgress { selectedID = record.id }
            } catch {
                self.error = "The image couldn’t be saved: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Model & memory

    private func ensureLoaded(_ spec: ImageModelSpec, loras choices: [LoRAChoice], size: ImageSize) async throws {
        let total = spec.runtimeBytes(for: size)
        let files = choices.compactMap { c in loras?.url(for: c.file).map { LoRAFile(url: $0, scale: c.scale) } }
        if loadedModelID == spec.id.description {
            if loadedLoRAs == choices {
                // Loaded: only the activations for this size must fit.
                try await makeRoom(need: spec.activationBytes(for: size))
                return
            }
            // Models that attach LoRAs at run time switch them in place.
            if spec.family.swapsLoRAsLive {
                phase = .loadingModel
                if let report = try await engine.setLoRAs(files) {
                    loadedLoRAs = choices
                    reportLoRAs(report, files: files, spec: spec)
                    try await makeRoom(need: spec.activationBytes(for: size))
                    return
                }
            }
        }
        guard let directory = modelDirectory(spec) else {
            throw ImageEngineError.loadFailed("\(spec.name) isn’t downloaded yet")
        }
        if loadedModelID != nil { await engine.unload(); loadedModelID = nil; loadedLoRAs = [] }
        try await makeRoom(need: total)
        phase = .loadingModel
        try Task.checkCancellation()
        let report = try await engine.load(spec, directory: directory, loras: files)
        loadedModelID = spec.id.description
        loadedLoRAs = choices
        reportLoRAs(report, files: files, spec: spec)
    }

    private func reportLoRAs(_ report: LoRALoadReport, files: [LoRAFile], spec: ImageModelSpec) {
        guard !files.isEmpty else { return }
        notice = report.appliedLayers == 0
            ? "The LoRA didn’t match \(spec.name) — is it made for \(spec.family.loraBase.displayName)?"
            : "LoRA applied to \(report.appliedLayers) layers\(report.skippedLayers > 0 ? " (\(report.skippedLayers) skipped)" : "")."
    }

    /// A LoRA can be used with `family` (unknown formats are tried; the engine reports what applied).
    public nonisolated static func lora(_ info: LoRALibrary.Info, fits family: ImageFamily) -> Bool {
        switch info.fit {
        case .fits(let base): base == family.loraBase
        case .unknown: true
        case .otherBase, .fullModel: false
        }
    }

    private func makeRoom(need: Int64) async throws {
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
        loadedLoRAs = []
    }

    // MARK: LoRA

    public func refreshLoRAs() {
        loraLibrary = loras?.list() ?? []
        let known = Set(loraLibrary.map(\.file))
        activeLoRAs.removeAll { !known.contains($0.file) }
    }

    public func importLoRA(_ url: URL) {
        guard let loras else { error = "LoRAs can’t be stored: the LoRA folder isn’t available."; return }
        do {
            let info = try loras.importFile(url)
            refreshLoRAs()
            switch info.fit {
            case .fits(let base):
                notice = "Added \(info.name) (\(base.displayName))."
                if !activeLoRAs.contains(where: { $0.file == info.file }) { activeLoRAs.append(LoRAChoice(file: info.file, scale: 1)) }
            case .unknown:
                notice = "Added \(info.name)."
                if !activeLoRAs.contains(where: { $0.file == info.file }) { activeLoRAs.append(LoRAChoice(file: info.file, scale: 1)) }
            case .otherBase(let base):
                notice = "Added \(info.name), but it was made for \(base) — Lay X can’t apply it."
            case .fullModel:
                break   // refused by the library
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "The LoRA couldn’t be added."
        }
    }

    /// Switches the LoRA folder (Settings → Image Generation → Storage).
    public func replaceLoRALibrary(_ library: LoRALibrary?) {
        loras = library
        refreshLoRAs()
    }

    public func deleteLoRA(_ file: String) {
        try? loras?.delete(file)
        refreshLoRAs()
    }

    public var loraFolder: URL? { loras?.folder }

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
        Task {
            do { try await store.delete(record) } catch {
                self.error = "The image’s history entry couldn’t be deleted: \(error.localizedDescription)"
            }
        }
    }
}
