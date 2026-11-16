import Foundation

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
    case chat, miniChat, work, benchmark, api
}

public struct GenerationRequest: Sendable {
    public var messages: [PromptMessage]
    public var parameters: GenerationParameters
    public var client: InferenceClient
    /// Reasoning ("thinking") mode for models whose chat template supports `enable_thinking`
    /// (e.g. Qwen3). `nil` = the model's default. Ignored by templates without the flag.
    public var thinking: Bool?

    public init(messages: [PromptMessage], parameters: GenerationParameters, client: InferenceClient, thinking: Bool? = nil) {
        self.messages = messages
        self.parameters = parameters
        self.client = client
        self.thinking = thinking
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
}

extension InferenceEngine {
    /// Memory in use by the engine (nil if the backend can't report it).
    public func memory() async -> EngineMemory? { nil }
    /// Resets the engine's peak-memory counter (benchmarks).
    public func resetPeakMemory() async {}
}
