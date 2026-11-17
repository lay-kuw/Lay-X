import Foundation
import Synchronization

/// A model on disk that an engine can load.
public struct ModelReference: Sendable, Hashable, Codable {
    /// Repository-style identifier, e.g. `mlx-community/Qwen3-4B-4bit`.
    public var id: String
    /// Directory containing `config.json`, tokenizer files and `*.safetensors`.
    public var directory: URL

    public init(id: String, directory: URL) {
        self.id = id
        self.directory = directory
    }
}

/// Sampling and length controls. `nil` means "engine / model default".
public struct GenerationParameters: Sendable, Hashable, Codable {
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int
    public var repetitionPenalty: Double?
    public var seed: UInt64?

    public init(temperature: Double = 0.7, topP: Double = 0.95, maxTokens: Int = 4096,
                repetitionPenalty: Double? = nil, seed: UInt64? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.repetitionPenalty = repetitionPenalty
        self.seed = seed
    }

    /// Clamps values into ranges every engine accepts.
    public func validated() -> GenerationParameters {
        var p = self
        p.temperature = min(max(temperature, 0), 2)
        p.topP = min(max(topP, 0.01), 1)
        p.maxTokens = min(max(maxTokens, 1), 131_072)
        if let r = repetitionPenalty { p.repetitionPenalty = min(max(r, 0.5), 2) }
        return p
    }
}

public struct PromptMessage: Sendable, Hashable, Codable {
    public var role: ChatRole
    public var content: String
    public init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

/// Where a generation request came from. Used for status display and scheduling diagnostics — never logged
/// together with content.
public enum InferenceClient: String, Sendable, Hashable, Codable {
    case chat, miniChat, work, benchmark, api, image

    /// Someone is waiting on the result (Chat, Mini Chat, API clients, image generation).
    public var isInteractive: Bool { self == .chat || self == .miniChat || self == .api || self == .image }
    /// Long background generation that may be paused at a token boundary so an interactive reply can run.
    public var isPreemptible: Bool { self == .work }
}

/// Cooperative pause switch for a running generation. Engines check it between tokens, so a paused generation
/// holds its state but runs no model work. `parked` confirms the generation has actually stopped at a token
/// boundary — the coordinator waits for it before starting another generation, because the backend must
/// never evaluate two generations at the same time (e.g. while the paused one is still prefilling).
public final class PauseGate: Sendable {
    private struct State { var paused = false, parked = false, done = false, armed = false }
    private let state = Mutex(State())
    public init() {}
    public var isPaused: Bool { state.withLock { $0.paused } }
    public var isParkedOrDone: Bool { state.withLock { $0.parked || $0.done } }
    public func pause() { state.withLock { $0.paused = true } }
    public func resume() { state.withLock { $0.paused = false } }
    /// Engines call this once the generation may safely stop (e.g. outside any exclusive section such as
    /// prompt prefill under a model lock). Before that, `waitWhilePaused` never blocks.
    public func arm() { state.withLock { $0.armed = true } }

    /// The generation finished (or failed / was cancelled); nobody needs to wait for it to park.
    public func markDone() { state.withLock { $0.done = true; $0.parked = false } }

    /// Blocks the calling (generation) thread while paused. Returns early if the task is cancelled.
    public func waitWhilePaused() {
        guard state.withLock({ $0.paused && $0.armed }) else { return }
        state.withLock { $0.parked = true }
        while isPaused && !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
        state.withLock { $0.parked = false }
    }

    /// Async variant for engines that run on Swift concurrency.
    public func waitWhilePausedAsync() async {
        guard state.withLock({ $0.paused && $0.armed }) else { return }
        state.withLock { $0.parked = true }
        while isPaused && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
        state.withLock { $0.parked = false }
    }

    /// Waits until the paused generation is parked (or done). Polls; the wait is at most one token or the
    /// remainder of a prefill.
    public func waitUntilParked() async {
        while !isParkedOrDone && isPaused { try? await Task.sleep(for: .milliseconds(3)) }
    }
}

public struct GenerationRequest: Sendable {
    public var messages: [PromptMessage]
    public var parameters: GenerationParameters
    public var client: InferenceClient
    /// Reasoning ("thinking") mode for models whose chat template supports `enable_thinking`
    /// (e.g. Qwen3). `nil` = the model's default. Ignored by templates without the flag.
    public var thinking: Bool?
    /// Groups requests whose KV cache may be reused (e.g. a chat session id). nil = prefix matching only.
    public var cacheKey: String?
    /// Set by the coordinator for preemptible requests.
    public var pauseGate: PauseGate?
    /// Run on this model: the coordinator loads it, if another one is loaded, after this request's turn in the
    /// queue comes and before generating — so selection, loading and generation can't be split by other requests.
    public var model: ModelReference?

    public init(messages: [PromptMessage], parameters: GenerationParameters, client: InferenceClient, thinking: Bool? = nil,
                cacheKey: String? = nil) {
        self.messages = messages
        self.parameters = parameters
        self.client = client
        self.thinking = thinking
        self.cacheKey = cacheKey
    }
}

public enum GenerationEvent: Sendable {
    /// Newly decoded text (may contain several tokens).
    case text(String)
    /// Terminal event. Always the last element of a successful stream.
    case finished(GenerationMetrics)
}

public struct LoadedModelInfo: Sendable, Hashable {
    public var id: String
    public var contextLength: Int?
    public var quantization: String?
    /// Wall time of `InferenceEngine.load`, measured by the coordinator with a monotonic clock.
    public var loadDuration: Duration
    /// Bytes of weights on disk (approximate memory footprint of the weights).
    public var weightBytes: Int64?

    public init(id: String, contextLength: Int? = nil, quantization: String? = nil,
                loadDuration: Duration = .zero, weightBytes: Int64? = nil) {
        self.id = id
        self.contextLength = contextLength
        self.quantization = quantization
        self.loadDuration = loadDuration
        self.weightBytes = weightBytes
    }
}

public enum InferenceError: Error, Equatable, Sendable, LocalizedError {
    case noModelLoaded
    case modelNotFound(String)
    case unsupportedModel(String)
    case loadFailed(String)
    case insufficientMemory(requiredBytes: Int64, availableBytes: Int64)
    case queueFull
    case lifecycleChanged
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noModelLoaded: "No model is loaded. Load a model from Models first."
        case .modelNotFound(let id): "The model “\(id)” is not downloaded."
        case .unsupportedModel(let why): "This model isn’t supported by Lay X: \(why)"
        case .loadFailed(let why): "The model couldn’t be loaded: \(why)"
        case .insufficientMemory(let need, let have):
            "Not enough memory to load this model (needs about \(ByteCountFormatter.string(fromByteCount: need, countStyle: .memory)), \(ByteCountFormatter.string(fromByteCount: have, countStyle: .memory)) available)."
        case .queueFull: "Too many requests are waiting. Try again in a moment."
        case .lifecycleChanged: "Generation stopped because the model was changed or unloaded."
        case .generationFailed(let why): "Generation failed: \(why)"
        }
    }
}

/// A local inference backend. Implementations own at most one loaded model.
///
/// Concurrency contract: the `InferenceCoordinator` guarantees that `load`, `unload` and `generate` are never
/// called concurrently, so engines do not need their own request scheduling.
public protocol InferenceEngine: Sendable {
    func load(_ model: ModelReference, progress: @escaping @Sendable (Double) -> Void) async throws -> LoadedModelInfo
    func unload() async
    /// Streams text for `request`. Must stop promptly when the consuming task is cancelled and must end with
    /// exactly one `.finished` event on success.
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
    /// Memory in use by the engine (nil if the backend can't report it). Default: nil.
    func memory() async -> EngineMemory?
    /// Resets the engine's peak-memory counter (benchmarks). Default: no-op.
    func resetPeakMemory() async
    /// Applies runtime settings (memory limit, KV-cache quantization). Default: no-op.
    func configure(_ settings: EngineSettings) async
    /// Releases cached buffers that aren't in use. Default: no-op.
    func clearCache() async
    /// Drops reusable KV caches for `key` (nil = all). Default: no-op.
    func discardCaches(key: String?) async
    /// Bytes held by reusable KV caches. Default: 0.
    func cacheBytes() async -> Int64
}

/// Engine-level settings from Settings → Models & Inference.
public struct EngineSettings: Sendable, Hashable, Codable {
    /// Upper bound for model weights + KV cache, in bytes (`nil` = 75 % of RAM).
    public var memoryLimitBytes: Int64?
    /// KV-cache quantization bits (`nil` = off, 8 or 4).
    public var kvBits: Int?
    /// Upper bound for the share of time the GPU spends generating (0.3–1.0). Below 1, the engine pauses
    /// between tokens in proportion to the time each token took, leaving GPU time for the UI and other apps.
    public var gpuLimit: Double
    /// Memory for reusable KV caches (conversation + prefix caches). 0 disables caching.
    public var cacheBudgetBytes: Int64
    /// Run a tiny generation right after loading so the first real reply doesn't pay kernel compilation.
    public var warmUp: Bool

    public init(memoryLimitBytes: Int64? = nil, kvBits: Int? = nil, gpuLimit: Double = 1,
                cacheBudgetBytes: Int64 = 2 << 30, warmUp: Bool = true) {
        self.memoryLimitBytes = memoryLimitBytes
        self.kvBits = kvBits.flatMap { [4, 8].contains($0) ? $0 : nil }
        self.gpuLimit = min(max(gpuLimit, 0.3), 1)
        self.cacheBudgetBytes = max(cacheBudgetBytes, 0)
        self.warmUp = warmUp
    }

    /// Pause to insert after each token, given the unthrottled per-token time `tokenTime` (seconds).
    /// MLX schedules the next step before the current token is consumed, so the GPU keeps working during the
    /// pause; the token interval then becomes ≈ max(tokenTime, pause). Pausing tokenTime / gpuLimit makes the GPU
    /// busy ≈ gpuLimit of the time. Capped at 0.25 s.
    public func pause(forTokenTime tokenTime: Double) -> Double {
        guard gpuLimit < 0.999, tokenTime > 0 else { return 0 }
        return min(tokenTime / gpuLimit, 0.25)
    }

    /// Effective weight budget for load-time checks.
    public func weightBudget(physicalMemory: Int64) -> Int64 {
        let cap = Int64(Double(physicalMemory) * 0.9)
        return min(memoryLimitBytes ?? Int64(Double(physicalMemory) * 0.75), cap)
    }
}

extension InferenceEngine {
    /// Memory in use by the engine (nil if the backend can't report it).
    public func memory() async -> EngineMemory? { nil }
    /// Resets the engine's peak-memory counter (benchmarks).
    public func resetPeakMemory() async {}
    public func configure(_ settings: EngineSettings) async {}
    public func clearCache() async {}
    public func discardCaches(key: String?) async {}
    public func cacheBytes() async -> Int64 { 0 }
}
