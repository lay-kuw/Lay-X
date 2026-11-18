import Foundation
import Testing
@testable import LayXCore

@Suite struct StatsTests {
    @Test func medianAndPercentile() {
        #expect(Stats.median([]) == nil)
        #expect(Stats.median([3, 1, 2]) == 2)
        #expect(Stats.median([4, 1, 3, 2]) == 2.5)
        #expect(Stats.percentile([10, 20, 30, 40, 50, 60, 70, 80, 90, 100], 95) == 100)
        #expect(Stats.percentile([10, 20, 30, 40, 50, 60, 70, 80, 90, 100], 50) == 50)
        #expect(Stats.percentile([7], 95) == 7)
    }

    @Test func tokenRatesUseMeasurementBoundaries() {
        // 2048 prompt tokens prefilled in 0.5 s; 257 tokens generated, first token at end of prefill,
        // remaining 256 decoded over 2 s.
        let m = GenerationMetrics(promptTokens: 2048, generatedTokens: 257, timeToFirstToken: .milliseconds(520),
                                  prefillDuration: .milliseconds(500), decodeDuration: .seconds(2),
                                  totalDuration: .milliseconds(2520), stopReason: .maxTokens)
        #expect(m.prefillTokensPerSecond == 4096)
        #expect(m.decodeTokensPerSecond == 128)
    }
}

@Suite struct BenchmarkTests {
    func metrics(ttft: Int, decodeSeconds: Double, tokens: Int = 101) -> GenerationMetrics {
        GenerationMetrics(promptTokens: 2000, generatedTokens: tokens, timeToFirstToken: .milliseconds(ttft),
                          prefillDuration: .milliseconds(ttft - 10), decodeDuration: .seconds(decodeSeconds),
                          totalDuration: .milliseconds(ttft) + .seconds(decodeSeconds), stopReason: .maxTokens)
    }

    @Test func pointsAggregateByPromptTarget() {
        let r = BenchmarkResult(modelID: "a/b", quantization: "4-bit", config: .contextSweep, hardware: .current, engine: "test",
                                loadDuration: nil, peakMemoryBytes: nil, weightBytes: nil, samples: [
                                    BenchmarkSample(promptTarget: 2048, metrics: metrics(ttft: 100, decodeSeconds: 1)),
                                    BenchmarkSample(promptTarget: 2048, metrics: metrics(ttft: 300, decodeSeconds: 2)),
                                    BenchmarkSample(promptTarget: 1024, metrics: metrics(ttft: 50, decodeSeconds: 1)),
                                ], completed: true)
        #expect(r.points.map(\.promptTarget) == [1024, 2048])
        let p = try! #require(r.headline)
        #expect(p.promptTarget == 2048)
        #expect(p.ttftMedianMs == 200)
        #expect(p.ttftP95Ms == 300)
        #expect(p.decodeMedian == 75)  // median of 100 and 50 tok/s
        #expect(r.title.hasPrefix("Context sweep"))
    }

    @Test func comparabilityKeyIgnoresPromptListButNotGeneration() {
        var a = BenchmarkConfig.quick
        var b = BenchmarkConfig.quick
        b.iterations = 10
        #expect(a.comparisonKey == b.comparisonKey)
        a.generateTokens = 64
        #expect(a.comparisonKey != b.comparisonKey)
        #expect(BenchmarkConfig.quick.label == "prompt 2,048 · gen 256 · 3 iterations")
    }

    @Test func syntheticPromptScalesAndIsDeterministic() {
        #expect(BenchmarkPrompt.make(tokens: 1024) == BenchmarkPrompt.make(tokens: 1024))
        let small = PromptBuilder.estimateTokens(BenchmarkPrompt.make(tokens: 1024))
        let big = PromptBuilder.estimateTokens(BenchmarkPrompt.make(tokens: 4096))
        #expect(big > small * 3)
    }

    @Test func csvEscapesFields() {
        #expect(BenchmarkResult.csvField("a,b") == "\"a,b\"")
        #expect(BenchmarkResult.csvField("q\"x") == "\"q\"\"x\"")
        #expect(BenchmarkResult.csvField("plain") == "plain")
    }

    @Test func runnerUsesCoordinatorSkipsWarmupAndPersists() async throws {
        let engine = ScriptedEngine(tokens: ["a", "b", "c"], tokenDelay: .milliseconds(1))
        let coordinator = InferenceCoordinator(engine: engine)
        try await coordinator.load(ModelReference(id: "t/m", directory: URL(fileURLWithPath: "/tmp")))
        let config = BenchmarkConfig(promptTokens: [512, 1024], generateTokens: 8, iterations: 2, warmupIterations: 1)
        let steps = StepCounter()
        let result = try await BenchmarkRunner.run(config, coordinator: coordinator, engineName: "scripted") { p in
            Task { await steps.add(p.step) }
        }
        #expect(result.samples.count == 4)  // 2 targets × 2 measured iterations (warm-ups excluded)
        #expect(result.completed)
        #expect(await engine.completedGenerations == 6)
        #expect(result.csv().split(separator: "\n").count == 5)

        let db = try SQLiteDatabase(location: .inMemory, migrations: LayXSchema.migrations)
        let store = BenchmarkStore(database: db)
        try await store.save(result)
        #expect(try await store.loadAll().first?.samples.count == 4)
        try await store.delete(result.id)
        #expect(try await store.loadAll().isEmpty)
    }

    @Test func runnerRequiresLoadedModel() async {
        let coordinator = InferenceCoordinator(engine: ScriptedEngine())
        await #expect(throws: InferenceError.noModelLoaded) {
            _ = try await BenchmarkRunner.run(.quick, coordinator: coordinator, engineName: "x") { _ in }
        }
    }

    @Test func outputDigestIsIndependentOfChunkBoundaries() async throws {
        let engine = ScriptedEngine(tokens: ["a", "bc"])
        let coordinator = InferenceCoordinator(engine: engine)
        try await coordinator.load(ModelReference(id: "t/m", directory: URL(fileURLWithPath: "/tmp")))
        let config = BenchmarkConfig(promptTokens: [128], iterations: 1, warmupIterations: 0)

        let first = try await BenchmarkRunner.run(
            config, coordinator: coordinator, engineName: "scripted", captureOutputDigest: true) { _ in }
        await engine.setTokens(["ab", "c"])
        let second = try await BenchmarkRunner.run(
            config, coordinator: coordinator, engineName: "scripted", captureOutputDigest: true) { _ in }
        let digest = try #require(first.samples.first?.outputSHA256)
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")  // SHA-256("abc")
        #expect(second.samples.first?.outputSHA256 == digest)
    }

    @Test func hardwareInfoIsPopulated() {
        let h = HardwareInfo.current
        #expect(h.memoryBytes > 0)
        #expect(h.summary.contains("GB"))
        #expect(SystemMemory.usedBytes() ?? 0 > 0)
    }
}

actor StepCounter { var steps: [Int] = []; func add(_ s: Int) { steps.append(s) } }
