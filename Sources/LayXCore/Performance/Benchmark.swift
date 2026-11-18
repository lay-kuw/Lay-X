import CryptoKit
import Foundation

/// Fixed, repeatable benchmark configuration. Two results are comparable only if their `comparisonKey`s match.
public struct BenchmarkConfig: Sendable, Codable, Hashable {
    /// Prompt sizes to measure (approximate tokens; the measured count is recorded per run).
    public var promptTokens: [Int]
    public var generateTokens: Int
    public var iterations: Int
    public var warmupIterations: Int
    public var temperature: Double
    public var seed: UInt64

    public init(promptTokens: [Int] = [2048], generateTokens: Int = 256, iterations: Int = 3,
                warmupIterations: Int = 1, temperature: Double = 0, seed: UInt64 = 0) {
        self.promptTokens = promptTokens
        self.generateTokens = generateTokens
        self.iterations = iterations
        self.warmupIterations = warmupIterations
        self.temperature = temperature
        self.seed = seed
    }

    public static let quick = BenchmarkConfig(promptTokens: [2048], generateTokens: 256, iterations: 3)
    public static let contextSweep = BenchmarkConfig(promptTokens: [1024, 2048, 4096, 8192, 16384, 32768],
                                                     generateTokens: 128, iterations: 2)

    public var isSweep: Bool { promptTokens.count > 1 }
    public var comparisonKey: String { "gen \(generateTokens) · temp \(temperature) · seed \(seed)" }

    public var label: String {
        let prompts = promptTokens.count == 1 ? "prompt \(promptTokens[0].formatted())" : "prompts \(promptTokens.map(Self.k).joined(separator: "/"))"
        return "\(prompts) · gen \(generateTokens) · \(iterations) iteration\(iterations == 1 ? "" : "s")"
    }

    public static func k(_ n: Int) -> String { n >= 1024 ? "\(n / 1024)k" : "\(n)" }
}

/// Deterministic synthetic prompt — never user content.
public enum BenchmarkPrompt {
    static let paragraph = """
    The lighthouse keeper recorded the weather every hour: wind direction, cloud cover, the height of the swell \
    and the colour of the sea. Ships passed at regular intervals, and each one was noted with its flag and course. \
    In the evenings he repaired the lamp, cleaned the lenses and read old almanacs by the light of the stove.
    """

    /// Roughly `tokens` tokens of text plus an instruction that encourages a long continuation.
    public static func make(tokens: Int) -> String {
        let perParagraph = 70  // ≈ tokens per paragraph for common tokenizers
        let count = max(1, tokens / perParagraph)
        let body = (1...count).map { "[\($0)] " + paragraph }.joined(separator: "\n")
        return body + "\n\nContinue the logbook in the same style for many more entries."
    }
}

/// One measured generation.
public struct BenchmarkSample: Sendable, Codable, Hashable {
    public var promptTarget: Int
    public var metrics: GenerationMetrics
    public var outputSHA256: String? = nil
}

public struct BenchmarkPoint: Sendable, Codable, Hashable, Identifiable {
    public var id: Int { promptTarget }
    public var promptTarget: Int
    public var promptTokens: Int
    public var ttftMedianMs: Double
    public var ttftP95Ms: Double
    public var prefillMedian: Double
    public var decodeMedian: Double
    public var generatedTokens: Int
}

/// A completed (or cancelled) benchmark run. Contains only synthetic-prompt measurements.
public struct BenchmarkResult: Sendable, Codable, Hashable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public var modelID: String
    public var quantization: String?
    public var config: BenchmarkConfig
    public var hardware: HardwareInfo
    public var engine: String
    public var loadDuration: Duration?
    public var peakMemoryBytes: Int64?
    public var weightBytes: Int64?
    public var samples: [BenchmarkSample]
    public var completed: Bool

    public var points: [BenchmarkPoint] {
        Dictionary(grouping: samples, by: \.promptTarget).keys.sorted().compactMap { target in
            let s = samples.filter { $0.promptTarget == target }.map(\.metrics)
            guard !s.isEmpty else { return nil }
            return BenchmarkPoint(
                promptTarget: target,
                promptTokens: Stats.median(s.map { Double($0.promptTokens) }).map { Int($0) } ?? 0,
                ttftMedianMs: Stats.median(s.map { $0.timeToFirstToken.milliseconds }) ?? 0,
                ttftP95Ms: Stats.percentile(s.map { $0.timeToFirstToken.milliseconds }, 95) ?? 0,
                prefillMedian: Stats.median(s.compactMap(\.prefillTokensPerSecond)) ?? 0,
                decodeMedian: Stats.median(s.compactMap(\.decodeTokensPerSecond)) ?? 0,
                generatedTokens: Stats.median(s.map { Double($0.generatedTokens) }).map { Int($0) } ?? 0)
        }
    }

    /// The point used for headline numbers: the 2k prompt if measured, else the smallest.
    public var headline: BenchmarkPoint? {
        points.first { $0.promptTarget == 2048 } ?? points.first
    }

    public var title: String {
        let name = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return config.isSweep ? "Context sweep · \(name)" : name
    }

    public func csv() -> String {
        var rows = ["model,quantization,prompt_target,prompt_tokens,generated_tokens,ttft_ms,prefill_tok_s,decode_tok_s,total_s,stop,config,hardware"]
        for s in samples {
            let m = s.metrics
            rows.append([
                modelID, quantization ?? "", "\(s.promptTarget)", "\(m.promptTokens)", "\(m.generatedTokens)",
                String(format: "%.1f", m.timeToFirstToken.milliseconds),
                m.prefillTokensPerSecond.map { String(format: "%.1f", $0) } ?? "",
                m.decodeTokensPerSecond.map { String(format: "%.2f", $0) } ?? "",
                String(format: "%.3f", m.totalDuration.seconds), m.stopReason.rawValue,
                config.comparisonKey, hardware.summary,
            ].map(Self.csvField).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    static func csvField(_ s: String) -> String {
        s.contains(",") || s.contains("\"") || s.contains("\n") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}

public enum Stats {
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Nearest-rank percentile.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let rank = Int((p / 100 * Double(s.count)).rounded(.up))
        return s[min(max(rank, 1), s.count) - 1]
    }
}

public struct BenchmarkProgress: Sendable, Equatable {
    public var step: Int
    public var total: Int
    public var promptTarget: Int
    public var warmup: Bool
    public init(step: Int, total: Int, promptTarget: Int, warmup: Bool) {
        self.step = step; self.total = total; self.promptTarget = promptTarget; self.warmup = warmup
    }
    public var fraction: Double { total > 0 ? Double(step) / Double(total) : 0 }
}

/// Runs a benchmark through the shared coordinator (`client: .benchmark`), so it is queued behind — never
/// concurrent with — chat, Work and API generations. Cancellable; a cancelled run keeps its finished samples.
public enum BenchmarkRunner {
    public static func run(_ config: BenchmarkConfig, coordinator: InferenceCoordinator, engineName: String,
                           captureOutputDigest: Bool = false,
                           progress: @escaping @Sendable (BenchmarkProgress) -> Void) async throws -> BenchmarkResult {
        guard let model = await coordinator.snapshot.model.loadedModel else { throw InferenceError.noModelLoaded }
        var result = BenchmarkResult(
            modelID: model.id, quantization: model.quantization, config: config, hardware: .current, engine: engineName,
            loadDuration: model.loadDuration, peakMemoryBytes: nil, weightBytes: model.weightBytes, samples: [], completed: false)
        await coordinator.resetPeakMemory()
        let targets = config.promptTokens.filter { target in model.contextLength.map { target + config.generateTokens < $0 } ?? true }
        let total = targets.count * (config.iterations + config.warmupIterations)
        var step = 0
        for target in targets {
            let prompt = BenchmarkPrompt.make(tokens: target)
            for i in 0..<(config.warmupIterations + config.iterations) {
                if Task.isCancelled { break }
                let warmup = i < config.warmupIterations
                progress(BenchmarkProgress(step: step, total: total, promptTarget: target, warmup: warmup))
                let request = GenerationRequest(
                    messages: [PromptMessage(role: .user, content: prompt)],
                    parameters: GenerationParameters(temperature: config.temperature, topP: 1, maxTokens: config.generateTokens, seed: config.seed),
                    client: .benchmark, thinking: false)
                var metrics: GenerationMetrics?
                var output: SHA256? = captureOutputDigest && !warmup ? SHA256() : nil
                for try await event in coordinator.generate(request) {
                    switch event {
                    case .text(let text): output?.update(data: Data(text.utf8))
                    case .finished(let m): metrics = m
                    }
                }
                if Task.isCancelled { break }
                if let m = metrics, !warmup {
                    result.samples.append(BenchmarkSample(
                        promptTarget: target, metrics: m, outputSHA256: output.map { $0.finalize().map { String(format: "%02x", $0) }.joined() }))
                }
                step += 1
            }
        }
        result.peakMemoryBytes = await coordinator.memory()?.peakBytes
        result.completed = !Task.isCancelled && step == total
        progress(BenchmarkProgress(step: step, total: total, promptTarget: targets.last ?? 0, warmup: false))
        return result
    }
}

/// Benchmark results in SQLite (`benchmark_run`, JSON payload). Synthetic prompts only — no chat content.
public struct BenchmarkStore: Sendable {
    let db: SQLiteDatabase
    public init(database: SQLiteDatabase) { db = database }

    public func save(_ r: BenchmarkResult) async throws {
        let data = try JSONEncoder().encode(r)
        try await db.execute("INSERT OR REPLACE INTO benchmark_run (id, created_at, payload) VALUES (?, ?, ?)",
                             [.text(r.id.uuidString), .double(r.date.timeIntervalSince1970), .blob(data)])
    }

    public func loadAll() async throws -> [BenchmarkResult] {
        let decoder = JSONDecoder()
        return try await db.query("SELECT payload FROM benchmark_run ORDER BY created_at DESC LIMIT 200")
            .compactMap { $0["payload"].blob.flatMap { try? decoder.decode(BenchmarkResult.self, from: $0) } }
    }

    public func delete(_ id: UUID) async throws {
        try await db.execute("DELETE FROM benchmark_run WHERE id = ?", [.text(id.uuidString)])
    }
}
