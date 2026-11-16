import Foundation
import LayXCore
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Smallest possible GPU round-trip. Used by `LayX --mlx-selftest` to prove the Metal library is bundled.
public enum MLXSelfTest {
    public static func run() -> Float {
        let a = MLXArray([1, 2, 3] as [Float]) * 2
        return a.sum().item(Float.self)
    }
}

/// Architecture support as implemented by MLXLLM's model registry.
public struct MLXArchitectureSupport: ModelArchitectureSupport {
    public init() {}
    public func supports(modelType: String) async -> Bool {
        await LLMTypeRegistry.shared.contains(modelType)
    }
}

/// `InferenceEngine` backed by mlx-swift-lm.
///
/// Holds at most one `ModelContainer`. The coordinator never calls into this actor concurrently, but the MLX
/// generation loop runs in its own task that can outlive a consumer's cancellation; `generationTask` is awaited
/// before the next load/unload/generate so GPU work never overlaps.
public actor MLXEngine: InferenceEngine {
    private var container: ModelContainer?
    private var loadedID: String?
    private var contextLength: Int?
    private var generationTask: Task<Void, Never>?
    private var settings = EngineSettings()


    public init() {}

    // MARK: Lifecycle

    public func load(_ model: ModelReference, progress: @escaping @Sendable (Double) -> Void) async throws -> LoadedModelInfo {
        await drainGeneration()
        unloadNow()

        let dir = model.directory
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) else {
            throw InferenceError.modelNotFound(model.id)
        }
        let config = ModelStore.readConfig(at: dir)
        guard let modelType = config.modelType else {
            throw InferenceError.unsupportedModel("config.json has no model_type")
        }
        guard await LLMTypeRegistry.shared.contains(modelType) else {
            throw InferenceError.unsupportedModel("architecture “\(modelType)” is not implemented by MLXLLM")
        }

        let weightBytes = Self.weightBytes(in: dir)
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        let budget = settings.weightBudget(physicalMemory: physical)
        if weightBytes > budget {
            throw InferenceError.insufficientMemory(requiredBytes: weightBytes, availableBytes: budget)
        }

        progress(0.05)
        do {
            let loaded = try await LLMModelFactory.shared.loadContainer(
                from: dir, using: #huggingFaceTokenizerLoader())
            progress(1)
            container = loaded
            loadedID = model.id
            contextLength = config.context
            return LoadedModelInfo(
                id: model.id, contextLength: config.context,
                quantization: config.bits.map { "\($0)-bit" }, weightBytes: weightBytes)
        } catch {
            unloadNow()
            throw InferenceError.loadFailed(Self.describe(error))
        }
    }

    public func unload() async {
        await drainGeneration()
        unloadNow()
    }

    private func unloadNow() {
        container = nil
        loadedID = nil
        contextLength = nil
        Memory.clearCache()
    }

    private func drainGeneration() async {
        if let t = generationTask {
            t.cancel()
            await t.value
            generationTask = nil
        }
    }

    // MARK: Generation

    public nonisolated func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        let task = Task { await self.run(request, continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func run(_ request: GenerationRequest,
                     _ continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) async {
        await drainGeneration()
        guard let container, let modelID = loadedID else {
            continuation.finish(throwing: InferenceError.noModelLoaded)
            return
        }
        let clock = ContinuousClock()
        let start = clock.now

        // Prompt formatting through the model's own chat template.
        let chat: [Chat.Message] = request.messages.map { m in
            switch m.role {
            case .system: .system(m.content)
            case .user: .user(m.content)
            case .assistant: .assistant(m.content)
            }
        }
        let lmInput: LMInput
        do {
            let context: [String: any Sendable]? = request.thinking.map { ["enable_thinking": $0] }
            lmInput = try await container.prepare(input: UserInput(chat: chat, additionalContext: context))
        } catch {
            continuation.finish(throwing: InferenceError.generationFailed("prompt formatting failed: \(Self.describe(error))"))
            return
        }
        let promptTokens = lmInput.text.tokens.size
        let prepared = clock.now

        // Context window: never exceed the model's maximum; shrink max output if necessary.
        var maxTokens = request.parameters.maxTokens
        if let ctx = contextLength {
            let room = ctx - promptTokens
            guard room > 0 else {
                continuation.finish(throwing: InferenceError.generationFailed(
                    "the prompt (\(promptTokens) tokens) exceeds the model’s context window (\(ctx) tokens)"))
                return
            }
            maxTokens = min(maxTokens, room)
        }

        var parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: Float(request.parameters.temperature),
            topP: Float(request.parameters.topP))
        parameters.seed = request.parameters.seed
        if let bits = settings.kvBits { parameters.kvBits = bits }
        if let rp = request.parameters.repetitionPenalty { parameters.repetitionPenalty = Float(rp) }
        let generateParameters = parameters

        let pair: (AsyncStream<Generation>, Task<Void, Never>)
        do {
            pair = try await container.perform(nonSendable: lmInput) { context, input in
                let iterator = try TokenIterator(
                    input: input, model: context.model, cache: nil, state: nil, parameters: generateParameters,
                    components: .init())
                let (s, t) = generateTask(
                    promptTokenCount: input.text.tokens.size, modelConfiguration: context.configuration,
                    tokenizer: context.tokenizer, iterator: iterator)
                return GenerationHandle(stream: s, task: t)
            }.pair
        } catch {
            continuation.finish(throwing: InferenceError.generationFailed(Self.describe(error)))
            return
        }
        let (mlxStream, mlxTask) = pair
        generationTask = mlxTask

        var firstToken: ContinuousClock.Instant?
        var info: GenerateCompletionInfo?
        for await event in mlxStream {
            if Task.isCancelled { break }
            switch event {
            case .chunk(let text):
                if firstToken == nil { firstToken = clock.now }
                continuation.yield(.text(text))
            case .info(let i):
                info = i
            case .toolCall, .rejectedToolCall:
                break
            }
        }
        if Task.isCancelled {
            mlxTask.cancel()
            await mlxTask.value
            generationTask = nil
            continuation.finish(throwing: CancellationError())
            return
        }
        await mlxTask.value
        generationTask = nil
        let end = clock.now
        let first = firstToken ?? end
        let stop: GenerationMetrics.StopReason = switch info?.stopReason {
        case .length?: maxTokens < request.parameters.maxTokens ? .contextLimit : .maxTokens
        case .cancelled?: .cancelled
        default: .endOfSequence
        }
        continuation.yield(.finished(GenerationMetrics(
            promptTokens: info?.promptTokenCount ?? promptTokens,
            generatedTokens: info?.generationTokenCount ?? 0,
            timeToFirstToken: first - start,
            prefillDuration: first - prepared,
            decodeDuration: end - first,
            totalDuration: end - start,
            stopReason: stop)))
        _ = modelID
        continuation.finish()
    }

    // MARK: Memory

    public func memory() async -> EngineMemory? {
        let s = Memory.snapshot()
        return EngineMemory(activeBytes: Int64(s.activeMemory), cacheBytes: Int64(s.cacheMemory), peakBytes: Int64(s.peakMemory))
    }

    public func resetPeakMemory() async {
        Memory.peakMemory = 0
    }

    public func configure(_ settings: EngineSettings) async {
        self.settings = settings
        // MLX treats the limit as a soft cap: allocations beyond it wait for running work or fail.
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        Memory.memoryLimit = Int(settings.weightBudget(physicalMemory: physical) + physical / 10)
    }

    public func clearCache() async {
        Memory.clearCache()
    }

    // MARK: Helpers

    static func weightBytes(in dir: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "safetensors" }.reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// `perform` requires a Sendable result; both members are Sendable.
private struct GenerationHandle: Sendable {
    let stream: AsyncStream<Generation>
    let task: Task<Void, Never>
    var pair: (AsyncStream<Generation>, Task<Void, Never>) { (stream, task) }
}
