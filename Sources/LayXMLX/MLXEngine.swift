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
/// - One `ModelContainer` at a time; load/unload/configure wait for every running generation.
/// - Several generations may be in flight (an interactive reply while a Work generation is paused at a token
///   boundary by its `PauseGate`); each owns its own KV cache.
/// - KV-cache reuse (`PromptCacheIndex`): a conversation's cache is taken back on its next turn so only the new
///   suffix is prefilled; other requests may start from a copy of the longest shared prefix. Caches are dropped
///   on unload / model change / settings change / chat deletion / memory pressure, and are never persisted.
public actor MLXEngine: InferenceEngine {
    private var container: ModelContainer?
    private var loadedID: String?
    private var contextLength: Int?
    private var generationTasks: [UUID: Task<Void, Never>] = [:]
    private var settings = EngineSettings()
    private var caches = PromptCacheIndex<KVCacheBox>(budgetBytes: EngineSettings().cacheBudgetBytes)
    /// Whether this model's caches can be rewound (attention-only); hybrid/state-space models need exact prefixes.
    private var cacheTrimmable = true
    /// System-prompt boundary per system text (template rendering is not free; Soul rarely changes).
    private var systemBoundaryCache: [String: Int] = [:]

    public init() {}

    // MARK: Lifecycle

    public func load(_ model: ModelReference, progress: @escaping @Sendable (Double) -> Void) async throws -> LoadedModelInfo {
        await drainGenerations()
        let hadModel = container != nil
        unloadNow()
        if hadModel { await releaseFreedBuffers() }

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
            progress(0.9)
            container = loaded
            loadedID = model.id
            contextLength = config.context
            cacheTrimmable = (try? await loaded.perform { context in
                canTrimPromptCache(try context.model.newCache(parameters: nil))
            }) ?? false
            if settings.warmUp { await warmUp(loaded) }
            progress(1)
            return LoadedModelInfo(
                id: model.id, contextLength: config.context,
                quantization: config.bits.map { "\($0)-bit" }, weightBytes: weightBytes)
        } catch {
            unloadNow()
            throw InferenceError.loadFailed(Self.describe(error))
        }
    }

    /// Keeps the model "hot": one short generation compiles the Metal kernels so the first reply is fast.
    private func warmUp(_ container: ModelContainer) async {
        guard let input = try? await container.prepare(input: UserInput(prompt: "Hi")),
              let stream = try? await container.generate(input: input, parameters: GenerateParameters(maxTokens: 2, temperature: 0))
        else { return }
        for await _ in stream {}
    }

    public func unload() async {
        await drainGenerations()
        unloadNow()
        await releaseFreedBuffers()
    }

    /// Weight buffers are returned to MLX's cache when the last reference (container, iterator, stream) goes
    /// away, which can happen just after `unloadNow()`. Clear again once they have been released so the memory
    /// actually goes back to the system.
    private func releaseFreedBuffers() async {
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(40))
            Memory.clearCache()
            if Memory.cacheMemory == 0 { break }
        }
    }

    private func unloadNow() {
        _ = caches.removeAll()
        systemBoundaryCache.removeAll()
        container = nil
        loadedID = nil
        contextLength = nil
        Memory.clearCache()
    }

    private func drainGenerations() async {
        let tasks = generationTasks
        generationTasks.removeAll()
        for t in tasks.values { t.cancel() }
        for t in tasks.values { await t.value }
    }

    // MARK: Caches

    public func discardCaches(key: String?) async {
        if let key { _ = caches.remove(key: key) } else { _ = caches.removeAll() }
        Memory.clearCache()
    }

    public func cacheBytes() async -> Int64 { caches.totalBytes }

    // MARK: Generation

    public nonisolated func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        let task = Task { await self.run(request, continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func run(_ request: GenerationRequest,
                     _ continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) async {
        guard let container, loadedID != nil else {
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
        let promptIDs = lmInput.text.tokens.asArray(Int.self)
        let promptTokens = promptIDs.count
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
        if let rp = request.parameters.repetitionPenalty { parameters.repetitionPenalty = Float(rp) }
        if let bits = settings.kvBits { parameters.kvBits = bits }
        let generateParameters = parameters
        let engineSettings = settings

        // KV-cache reuse (never for benchmarks — they must measure full prefill).
        let reusable = request.client != .benchmark && settings.cacheBudgetBytes > 0
        var reused = 0
        var startCache: KVCacheBox?
        if reusable, let match = caches.take(key: request.cacheKey, prompt: promptIDs, exactOnly: !cacheTrimmable) {
            let box = match.exclusive ? match.entry.payload : KVCacheBox(match.entry.payload.caches.map { $0.copy() })
            let offset = box.caches.map(\.offset).max() ?? 0
            var shared = min(match.shared, offset)
            if offset > shared {
                if canTrimPromptCache(box.caches) { trimPromptCache(box.caches, numTokens: offset - shared) } else { shared = 0 }
            }
            if shared > 0 { startCache = box; reused = shared }
        }

        // Snapshot points: where the next turn of this conversation will diverge (history boundary), and the end
        // of a long system prompt (shared by other conversations with the same Soul). Found by rendering the
        // template with placeholder turns and comparing token prefixes — no template-specific knowledge needed.
        var plan: [(position: Int, key: String)] = []
        if reusable {
            let boundaries = await snapshotBoundaries(container: container, request: request, prompt: promptIDs)
            if let sys = boundaries.system, sys > reused, sys >= 64 {
                plan.append((sys, "prefix:\(promptIDs.prefix(sys).hashValue)"))
            }
            if let hist = boundaries.history, hist > reused {
                plan.append((hist, request.cacheKey ?? "anon-\(UUID().uuidString)"))
            }
            plan.sort { $0.position < $1.position }
        }

        let reuseCount = reused
        let snapshotPlan = plan
        let promptTail = Array(promptIDs.suffix(8))
        let h: GenerationHandle
        do {
            h = try await container.perform(nonSendable: (lmInput, startCache)) { context, values in
                let (input, startBox) = values
                let cache = try startBox?.caches ?? context.model.newCache(parameters: generateParameters)
                let tokens = input.text.tokens
                func slice(_ from: Int, _ to: Int?) -> MLXArray {
                    if tokens.ndim == 1 { return to.map { tokens[from ..< $0] } ?? tokens[from...] }
                    return to.map { tokens[0..., from ..< $0] } ?? tokens[0..., from...]
                }
                // Prefill up to each snapshot point and keep a copy of the cache there.
                var current = reuseCount
                var snapshots: [CacheSnapshot] = []
                for point in snapshotPlan where point.position > current && point.position < tokens.dim(-1) {
                    _ = try TokenIterator(input: LMInput(tokens: slice(current, point.position)), model: context.model,
                                          cache: cache, state: nil, parameters: generateParameters, components: .init())
                    current = point.position
                    snapshots.append(CacheSnapshot(position: point.position, key: point.key, box: KVCacheBox(cache.map { $0.copy() })))
                }
                let iteratorInput = current > 0 ? LMInput(tokens: slice(current, nil)) : input
                var components = GenerationComponents()
                if engineSettings.gpuLimit < 0.999 || request.pauseGate != nil {
                    components.logitProcessorFactory = { GenerationControl(settings: engineSettings, gate: request.pauseGate) }
                }
                let iterator = try TokenIterator(
                    input: iteratorInput, model: context.model, cache: cache, state: nil, parameters: generateParameters,
                    components: components)
                // Templates such as Qwen3.5/3.6 end the prompt with "<think>\n" when thinking is on, so the
                // model's output starts inside the reasoning block without an opening tag.
                let tail = context.tokenizer.decode(tokenIds: promptTail)
                let opensThinking = tail.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("<think>")
                let (s, t) = generateTask(
                    promptTokenCount: iteratorInput.text.tokens.size, modelConfiguration: context.configuration,
                    tokenizer: context.tokenizer, iterator: iterator)
                return GenerationHandle(stream: s, task: t, opensThinking: opensThinking, snapshots: snapshots)
            }
        } catch {
            continuation.finish(throwing: InferenceError.generationFailed(Self.describe(error)))
            return
        }
        // Store snapshots right away (they are copies, independent of the running generation).
        var evictedAny = false
        for snap in h.snapshots {
            let evicted = caches.insert(key: snap.key, tokens: Array(promptIDs.prefix(snap.position)), bytes: snap.box.bytes, payload: snap.box)
            evictedAny = evictedAny || !evicted.isEmpty
        }
        if evictedAny { Memory.clearCache() }
        let (mlxStream, mlxTask, opensThinking) = (h.stream, h.task, h.opensThinking)
        // Prefill ran inside the model's exclusive section; only from here on may this generation park
        // (parking while holding that lock would deadlock the interactive request that paused it).
        request.pauseGate?.arm()
        let taskID = UUID()
        generationTasks[taskID] = mlxTask
        defer { generationTasks[taskID] = nil }
        // Re-insert the opening tag the template already emitted, so every consumer sees a well-formed block.
        if opensThinking { continuation.yield(.text("<think>\n")) }

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
            request.pauseGate?.markDone()
            request.pauseGate?.resume()
            mlxTask.cancel()
            await mlxTask.value
            continuation.finish(throwing: CancellationError())
            return
        }
        await mlxTask.value
        request.pauseGate?.markDone()
        let end = clock.now

        let first = firstToken ?? end
        let stop: GenerationMetrics.StopReason = switch info?.stopReason {
        case .length?: maxTokens < request.parameters.maxTokens ? .contextLimit : .maxTokens
        case .cancelled?: .cancelled
        default: .endOfSequence
        }
        var metrics = GenerationMetrics(
            promptTokens: promptTokens - reused,
            generatedTokens: info?.generationTokenCount ?? 0,
            timeToFirstToken: first - start,
            prefillDuration: first - prepared,
            decodeDuration: end - first,
            totalDuration: end - start,
            stopReason: stop)
        metrics.cachedPromptTokens = reused > 0 ? reused : nil
        continuation.yield(.finished(metrics))
        continuation.finish()
    }

    /// Token positions where reusable snapshots should be taken (see `run`).
    private func snapshotBoundaries(container: ModelContainer, request: GenerationRequest, prompt: [Int]) async
        -> (system: Int?, history: Int?) {
        @Sendable func dicts(_ messages: [PromptMessage]) -> [[String: any Sendable]] {
            messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        }
        let extra: [String: any Sendable]? = request.thinking.map { ["enable_thinking": $0] }
        let msgs = request.messages
        let systemText = msgs.first?.role == .system ? msgs.first?.content : nil
        let knownSystem = systemText.flatMap { systemBoundaryCache[$0] }
        let result: (Int?, Int?) = await container.perform { context in
            let tok = context.tokenizer
            var history: Int?
            // Placeholder next turn (assistant reply + user message): the shared prefix is what the real next turn
            // will share too.
            if let next = try? tok.applyChatTemplate(
                messages: dicts(msgs + [PromptMessage(role: .assistant, content: "X"), PromptMessage(role: .user, content: "Y")]),
                tools: nil, additionalContext: extra) {
                let n = PromptCacheIndex<Int>.commonPrefix(prompt, next)
                if n > 0, n < prompt.count { history = n }
            }
            var system = knownSystem
            if system == nil, let first = msgs.first, first.role == .system,
               let a = try? tok.applyChatTemplate(messages: dicts([first, PromptMessage(role: .user, content: "A")]), tools: nil, additionalContext: extra),
               let b = try? tok.applyChatTemplate(messages: dicts([first, PromptMessage(role: .user, content: "Z")]), tools: nil, additionalContext: extra) {
                let n = PromptCacheIndex<Int>.commonPrefix(a, b)
                if n > 0, PromptCacheIndex<Int>.commonPrefix(prompt, a) >= n { system = n }
            }
            return (system, history)
        }
        if let systemText, let sys = result.0, knownSystem == nil { systemBoundaryCache[systemText] = sys }
        return result
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
        let previous = self.settings
        self.settings = settings
        // MLX treats the limit as a soft cap: allocations beyond it wait for running work or fail.
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        Memory.memoryLimit = Int(settings.weightBudget(physicalMemory: physical) + physical / 10)
        // Cached KV layouts depend on the KV quantization; a smaller budget evicts.
        if previous.kvBits != settings.kvBits { _ = caches.removeAll() } else { _ = caches.setBudget(settings.cacheBudgetBytes) }
        caches.budgetBytes = settings.cacheBudgetBytes
        Memory.clearCache()
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

/// A generation's KV cache. `@unchecked Sendable` because MLX caches are reference types without Sendable
/// conformance; ownership is handed over explicitly (generation ⇄ cache index, copies for shared prefixes), so a
/// cache is never used by two generations at once.
final class KVCacheBox: @unchecked Sendable {
    let caches: [KVCache]
    init(_ caches: [KVCache]) { self.caches = caches }
    var bytes: Int64 { caches.reduce(0) { $0 + $1.state.reduce(0) { $0 + Int64($1.nbytes) } } }
}

struct CacheSnapshot: Sendable {
    let position: Int
    let key: String
    let box: KVCacheBox
}

/// `perform` requires a Sendable result; members are Sendable (caches through their boxes).
private struct GenerationHandle: Sendable {
    let stream: AsyncStream<Generation>
    let task: Task<Void, Never>
    let opensThinking: Bool
    let snapshots: [CacheSnapshot]
}

/// Per-token control in the generation loop (runs on the generation thread):
/// - waits while the coordinator has paused this generation (an interactive reply is running),
/// - caps the GPU duty cycle (`EngineSettings.gpuLimit`) with a feedback loop: the unthrottled token time G is
///   the median of unpaused intervals (tokens 3–8, re-measured every 64), the target interval is G / gpuLimit,
///   and the pause is corrected each token from the measured interval (absorbing sleep overshoot and MLX's
///   look-ahead scheduling).
/// Logits are untouched.
struct GenerationControl: LogitProcessor {
    let settings: EngineSettings
    let gate: PauseGate?
    private var last: ContinuousClock.Instant?
    private var count = 0
    private var window: [Double] = []
    private var tokenTime: Double = 0
    private var pause: Double = 0

    init(settings: EngineSettings, gate: PauseGate?) {
        self.settings = settings
        self.gate = gate
    }

    mutating func prompt(_ prompt: MLXArray) { last = nil; count = 0; window = []; tokenTime = 0; pause = 0 }

    func process(logits: MLXArray) -> MLXArray { logits }

    private func measuring(_ n: Int) -> Bool { (3...8).contains(n) || (n > 8 && n % 64 < 4) }

    mutating func didSample(token: MLXArray) {
        if let gate, gate.isPaused {
            gate.waitWhilePaused()
            last = nil   // don't count the pause as token time
            return
        }
        guard settings.gpuLimit < 0.999 else { return }
        let now = ContinuousClock.now
        count += 1
        if let last {
            let interval = (now - last).seconds
            if measuring(count) {
                window.append(interval)
                if window.count >= 4 {
                    tokenTime = window.sorted()[window.count / 2]
                    if !measuring(count + 1) { window = [] }
                }
            } else if tokenTime > 0 {
                let target = tokenTime / settings.gpuLimit
                pause = min(max(pause + 0.5 * (target - interval), 0), 0.25)
            }
        }
        if !measuring(count + 1), tokenTime > 0 {
            if pause == 0 { pause = settings.pause(forTokenTime: tokenTime) - tokenTime }
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        }
        last = now
    }
}
