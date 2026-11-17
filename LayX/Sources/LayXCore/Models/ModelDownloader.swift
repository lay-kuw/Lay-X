import CryptoKit
import Foundation
import Synchronization

public struct DownloadProgress: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable {
        case preparing, downloading, verifying, finalizing
    }
    public var phase: Phase
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double
    public var currentFile: String?

    public var fraction: Double { totalBytes > 0 ? min(Double(receivedBytes) / Double(totalBytes), 1) : 0 }
}

public enum DownloadState: Sendable, Hashable {
    case active(DownloadProgress)
    case completed
    case failed(String)
    case cancelled
}

/// Downloads MLX models from the Hub into the `ModelStore`.
///
/// - One download per model id at a time; several models can download concurrently.
/// - Files stream into `<model>/.partial/` and are resumed with HTTP Range after an interruption or app restart.
/// - Every weight file is checked against the Hub's SHA-256 (LFS oid); every file against its expected size.
/// - Only when all files verify are they moved into place, and the manifest — which marks the model as
///   installed — is written last. A crash at any point leaves either the old state or a resumable partial.
/// - Incompatible architectures are rejected before any weights are downloaded.
public actor ModelDownloader {
    private let store: ModelStore
    private let hub: HubAPI
    private let architectures: any ModelArchitectureSupport
    private let transferConfiguration: URLSessionConfiguration

    private var tasks: [ModelRepoID: Task<InstalledModel, Error>] = [:]
    public private(set) var states: [ModelRepoID: DownloadState] = [:]
    private var observers: [UUID: AsyncStream<[ModelRepoID: DownloadState]>.Continuation] = [:]

    /// Disk space kept free beyond the download size.
    public static let diskMargin: Int64 = 1 << 30

    public init(store: ModelStore, hub: HubAPI = HubAPI(), architectures: any ModelArchitectureSupport,
                transferConfiguration: URLSessionConfiguration = .default) {
        self.store = store
        self.hub = hub
        self.architectures = architectures
        self.transferConfiguration = transferConfiguration
    }

    // MARK: Observation

    public func updates() -> AsyncStream<[ModelRepoID: DownloadState]> {
        let (stream, c) = AsyncStream.makeStream(of: [ModelRepoID: DownloadState].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = c
        c.yield(states)
        c.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func set(_ id: ModelRepoID, _ state: DownloadState) {
        states[id] = state
        for c in observers.values { c.yield(states) }
    }

    // MARK: Control

    /// Starts (or resumes) a download. Returns when the model is installed.
    @discardableResult
    public func download(_ id: ModelRepoID, revision: String = "main", profile: DownloadProfile = .languageModel) async throws -> InstalledModel {
        if let existing = tasks[id] { return try await existing.value }
        let task = Task { try await self.perform(id, revision: revision, profile: profile) }
        tasks[id] = task
        defer { tasks[id] = nil }
        do {
            let model = try await task.value
            set(id, .completed)
            return model
        } catch is CancellationError {
            set(id, .cancelled)
            throw CancellationError()
        } catch {
            set(id, .failed((error as? LocalizedError)?.errorDescription ?? "\(error)"))
            throw error
        }
    }

    /// Cancels a running download. Partial files stay on disk so the download can resume later.
    public func cancel(_ id: ModelRepoID) {
        tasks[id]?.cancel()
    }

    /// Cancels and removes partial data.
    public func discardPartial(_ id: ModelRepoID) async {
        if let t = tasks[id] {
            t.cancel()
            _ = await t.result
        }
        try? FileManager.default.removeItem(at: store.partialDirectory(for: id))
        states[id] = nil
        for c in observers.values { c.yield(states) }
    }

    public func clearFinishedState(_ id: ModelRepoID) {
        guard tasks[id] == nil else { return }
        states[id] = nil
        for c in observers.values { c.yield(states) }
    }

    /// Picks the files of an image pipeline and its family (checked before anything is downloaded).
    private func imagePipelineFiles(_ id: ModelRepoID, revision: String, all: [HubFile]) async throws -> ([HubFile], String) {
        func json(_ path: String) async throws -> [String: Any] {
            let data = try await hub.smallFile(path, of: id, revision: revision)
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        guard all.contains(where: { $0.path == "model_index.json" }) else {
            throw ModelStoreError.incompatible("no model_index.json — Lay X runs image models in diffusers format")
        }
        let index = try await json("model_index.json")
        let className = index["_class_name"] as? String ?? "this pipeline"
        switch className {
        case "StableDiffusionXLPipeline":
            // Exactly the files the SDXL pipeline loads (repositories also hold other formats and precisions).
            let picked = SDXLFiles.select(from: all)
            guard let chosen = picked.files else {
                throw ModelStoreError.incompatible("incomplete SDXL pipeline (missing \(picked.missing.prefix(3).joined(separator: ", ")))")
            }
            return (chosen, ImageFamily.sdxl.rawValue)
        case "ZImagePipeline":
            let picked = DiffusersFiles.select(from: all)
            guard let chosen = picked.files else {
                throw ModelStoreError.incompatible("incomplete pipeline (missing \(picked.missing.prefix(3).joined(separator: ", ")))")
            }
            if try await json("transformer/config.json")["quantization_config"] != nil {
                throw ModelStoreError.incompatible("pre-quantized weights can’t be loaded — choose the bf16 version")
            }
            // Turbo is distilled with shift 3; the base model uses 6.
            let shift = (try? await json("scheduler/scheduler_config.json"))?["shift"] as? Double ?? 3
            let turbo = shift < 4.5 || id.name.lowercased().contains("turbo")
            return (chosen, (turbo ? ImageFamily.zImage : .zImageBase).rawValue)
        case "Flux2KleinPipeline", "QwenImagePipeline":
            let picked = DiffusersFiles.select(from: all)
            guard let chosen = picked.files else {
                throw ModelStoreError.incompatible("incomplete pipeline (missing \(picked.missing.prefix(3).joined(separator: ", ")))")
            }
            let transformer = try await json("transformer/config.json")
            let int8 = all.contains { $0.path == "transformer/model-int8.safetensors" }
            if transformer["quantization_config"] != nil, !int8 {
                throw ModelStoreError.incompatible("pre-quantized weights (bitsandbytes / SDNQ / Nunchaku…) can’t be loaded — choose the bf16 version")
            }
            if className == "QwenImagePipeline" {
                if int8, !all.contains(where: { $0.path == "text_encoder/model-int8.safetensors" }) {
                    throw ModelStoreError.incompatible("the 8-bit transformer needs text_encoder/model-int8.safetensors")
                }
                return (chosen, ImageFamily.qwenImage.rawValue)
            }
            let double = transformer["num_layers"] as? Int, single = transformer["num_single_layers"] as? Int
            guard double == 5, single == 20 else {
                throw ModelStoreError.incompatible("only FLUX.2 klein 4B is supported (this is a larger klein — 9B models aren’t)")
            }
            let distilled = index["is_distilled"] as? Bool ?? false
            return (chosen, (distilled ? ImageFamily.flux2Klein : .flux2KleinBase).rawValue)
        default:
            throw ModelStoreError.incompatible("\(className) isn’t supported — Lay X runs SDXL, FLUX.2 klein 4B, Qwen-Image and Z-Image")
        }
    }

    // MARK: Work

    private func perform(_ id: ModelRepoID, revision: String, profile: DownloadProfile) async throws -> InstalledModel {
        set(id, .active(DownloadProgress(phase: .preparing, receivedBytes: 0, totalBytes: 0, bytesPerSecond: 0)))

        // 1. File list + compatibility gate (only config.json is fetched before the check).
        let all = try await hub.files(of: id, revision: revision)
        let files: [HubFile]
        let modelType: String
        var config: (modelType: String?, bits: Int?, context: Int?) = (nil, nil, nil)
        switch profile {
        case .languageModel:
            files = HubAPI.requiredFiles(all)
            guard files.contains(where: { $0.path.hasSuffix(".safetensors") }) else { throw ModelStoreError.noWeights }
            guard files.contains(where: { $0.path == "config.json" }) else { throw ModelStoreError.incompatible("no config.json") }
            let configData = try await hub.smallFile("config.json", of: id, revision: revision)
            let configJSON = (try? JSONSerialization.jsonObject(with: configData) as? [String: Any]) ?? [:]
            config = ModelStore.parseConfig(configJSON)
            guard let type = config.modelType else { throw ModelStoreError.incompatible("config.json has no model_type") }
            guard await architectures.supports(modelType: type) else {
                throw ModelStoreError.incompatible("architecture “\(type)” is not supported by the MLX engine")
            }
            modelType = type
        case .imagePipeline:
            (files, modelType) = try await imagePipelineFiles(id, revision: revision, all: all)
        }
        try Task.checkCancellation()

        // 2. Paths are validated before anything is written.
        let partial = store.partialDirectory(for: id)
        let targets = try files.map { (file: $0, url: try ModelStore.safeChild(of: partial, relativePath: $0.path)) }
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        guard ModelStore.isContained(partial, in: store.root) else { throw ModelStoreError.unsafePath(id.description) }

        // 3. Disk space for what's still missing.
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let already = targets.reduce(Int64(0)) { $0 + min(Self.fileSize($1.url), $1.file.size) }
        let available = store.availableCapacity()
        let needed = total - already + Self.diskMargin
        if available > 0, needed > available {
            throw ModelStoreError.insufficientDiskSpace(required: needed, available: available)
        }

        // 4. Transfer (resuming), with throttled progress.
        let meter = ProgressMeter(total: total, initial: already)
        let transfer = FileTransfer(configuration: transferConfiguration)
        for (file, url) in targets {
            try Task.checkCancellation()
            if Self.fileSize(url) == file.size, file.size > 0 { continue }  // complete; verified below
            if Self.fileSize(url) > file.size { try? FileManager.default.removeItem(at: url) }
            set(id, .active(meter.progress(.downloading, file: file.path)))
            try await transfer.run(hub.fileURL(file.path, of: id, revision: revision), to: url) { delta in
                if meter.add(delta) {
                    Task { await self.reportProgress(id, meter.progress(.downloading, file: file.path)) }
                }
            }
        }

        // 5. Verify sizes and checksums. A corrupted file is deleted so the next attempt re-downloads it.
        set(id, .active(meter.progress(.verifying, file: nil)))
        for (file, url) in targets {
            try Task.checkCancellation()
            guard Self.fileSize(url) == file.size else {
                try? FileManager.default.removeItem(at: url)
                throw ModelStoreError.sizeMismatch(file: file.path)
            }
            if let expected = file.sha256 {
                let actual = try await Self.sha256(of: url)
                guard actual == expected.lowercased() else {
                    try? FileManager.default.removeItem(at: url)
                    throw ModelStoreError.checksumMismatch(file: file.path)
                }
            }
        }

        // 6. Move into place, then write the manifest last.
        set(id, .active(meter.progress(.finalizing, file: nil)))
        let dir = store.directory(for: id)
        let fm = FileManager.default
        for (file, url) in targets {
            let final = try ModelStore.safeChild(of: dir, relativePath: file.path)
            // Image models keep files in subfolders (unet/, vae/, …).
            try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: url, to: final)
        }
        try? fm.removeItem(at: partial)
        let manifest = InstalledModelManifest(
            id: id, revision: revision, files: files, downloadedAt: Date(), modelType: modelType,
            quantizationBits: config.bits, contextLength: config.context, kind: profile.kind)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: dir.appendingPathComponent(InstalledModelManifest.fileName), options: .atomic)
        Log.models.info("Installed \(id.description, privacy: .public) (\(total) bytes)")
        return InstalledModel(manifest: manifest, directory: dir, diskBytes: ModelStore.allocatedSize(of: dir))
    }

    private func reportProgress(_ id: ModelRepoID, _ progress: DownloadProgress) {
        guard case .active = states[id] else { return }
        set(id, .active(progress))
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Streams the file through SHA-256 in 8 MB chunks off the actor.
    static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

/// Thread-safe byte counter that rate-limits progress events to ~10/s.
final class ProgressMeter: Sendable {
    private struct State {
        var received: Int64
        var lastReport: ContinuousClock.Instant
        var windowStart: ContinuousClock.Instant
        var windowBytes: Int64
        var rate: Double
    }
    private let state: Mutex<State>
    let total: Int64

    init(total: Int64, initial: Int64) {
        self.total = total
        let now = ContinuousClock.now
        state = Mutex(State(received: initial, lastReport: now, windowStart: now, windowBytes: 0, rate: 0))
    }

    /// Returns true when a progress event should be emitted.
    func add(_ delta: Int64) -> Bool {
        state.withLock { s in
            s.received += delta
            s.windowBytes += max(delta, 0)
            let now = ContinuousClock.now
            let window = (now - s.windowStart).seconds
            if window >= 1 {
                s.rate = Double(s.windowBytes) / window
                s.windowStart = now
                s.windowBytes = 0
            }
            guard now - s.lastReport >= .milliseconds(100) else { return false }
            s.lastReport = now
            return true
        }
    }

    func progress(_ phase: DownloadProgress.Phase, file: String?) -> DownloadProgress {
        state.withLock { s in
            DownloadProgress(phase: phase, receivedBytes: s.received, totalBytes: total, bytesPerSecond: s.rate, currentFile: file)
        }
    }
}
/// What a download fetches and how it is checked.
public enum DownloadProfile: Sendable, Hashable {
    /// MLX language model: weights + configs + tokenizer, architecture checked against the engine.
    case languageModel
    /// Image pipeline in diffusers layout (SDXL, FLUX.2 klein 4B, Qwen-Image): the family is read from
    /// `model_index.json` and recorded as the model type.
    case imagePipeline

    var kind: ModelKind { self == .imagePipeline ? .image : .language }
}
