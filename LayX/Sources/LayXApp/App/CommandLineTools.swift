#if canImport(LayXMLX)
import Foundation
import LayXCore
import LayXMLX

/// Headless developer/verification commands (no UI). Run from inside the app bundle:
///   LayX.app/Contents/MacOS/LayX --mlx-selftest
///   LayX.app/Contents/MacOS/LayX --download mlx-community/Qwen3-0.6B-4bit
///   LayX.app/Contents/MacOS/LayX --generate mlx-community/Qwen3-0.6B-4bit "prompt" [maxTokens]
///   LayX.app/Contents/MacOS/LayX --list-models
/// These print model output to stdout for verification only; nothing is persisted or logged.
nonisolated enum CommandLineTools {
    static func handle(_ args: [String]) -> Bool {
        guard args.count >= 2, args[1].hasPrefix("--") else { return false }
        switch args[1] {
        case "--mlx-selftest":
            print("mlx-selftest: \(MLXSelfTest.run())")
            exit(0)
        case "--download", "--generate", "--list-models", "--engine-check", "--search":
            Task.detached {
                do {
                    try await run(args)
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")\n".utf8))
                    exit(1)
                }
            }
            dispatchMain()
        default:
            return false
        }
    }

    /// Commands handled headlessly; anything else starts the GUI.
    static let commands: Set<String> = ["--mlx-selftest", "--download", "--generate", "--list-models", "--engine-check", "--search"]

    private static func run(_ args: [String]) async throws {
        let store = ModelStore(root: try ModelStore.defaultRoot())
        switch args[1] {
        case "--list-models":
            for m in store.installedModels() {
                print(m.id, m.manifest.modelType ?? "?", ByteCountFormatter.string(fromByteCount: m.diskBytes, countStyle: .file))
            }
        case "--download":
            guard args.count >= 3, let id = ModelRepoID(args[2]) else { throw ModelStoreError.invalidRepoID(args.dropFirst(2).first ?? "") }
            let downloader = ModelDownloader(store: store, architectures: MLXArchitectureSupport())
            let watcher = Task {
                var last = -1
                for await states in await downloader.updates() {
                    if case .active(let p)? = states[id] {
                        let pct = Int(p.fraction * 100)
                        if pct != last { last = pct; print("\(p.phase.rawValue) \(pct)% \(p.receivedBytes)/\(p.totalBytes)") }
                    }
                }
            }
            let model = try await downloader.download(id)
            watcher.cancel()
            print("installed \(model.id) at \(model.directory.path)")
        case "--generate":
            guard args.count >= 4, let id = ModelRepoID(args[2]) else { throw ModelStoreError.invalidRepoID(args.dropFirst(2).first ?? "") }
            guard let model = store.installedModel(id) else { throw ModelStoreError.notInstalled(id.description) }
            let maxTokens = args.count >= 5 ? Int(args[4]) ?? 256 : 256
            let coordinator = InferenceCoordinator(engine: MLXEngine())
            let info = try await coordinator.load(model.reference)
            print("loaded \(info.id) in \(String(format: "%.2f", info.loadDuration.seconds))s, context \(info.contextLength.map(String.init) ?? "?")")
            let request = GenerationRequest(
                messages: [PromptMessage(role: .user, content: args[3])],
                parameters: GenerationParameters(temperature: 0, maxTokens: maxTokens, seed: 0), client: .chat)
            for try await event in coordinator.generate(request) {
                switch event {
                case .text(let t): print(t, terminator: ""); fflush(stdout)
                case .finished(let m):
                    print("\n---")
                    print("prompt tokens \(m.promptTokens), generated \(m.generatedTokens), stop \(m.stopReason.rawValue)")
                    print(String(format: "TTFT %.0f ms, prefill %.0f tok/s, decode %.1f tok/s, total %.2f s",
                                 m.timeToFirstToken.milliseconds, m.prefillTokensPerSecond ?? 0,
                                 m.decodeTokensPerSecond ?? 0, m.totalDuration.seconds))
                }
            }
        case "--search":
            let support = MLXArchitectureSupport()
            for r in try await HubAPI().search(args.count >= 3 ? args[2] : "", limit: 12) {
                var ok = false
                if let type = r.modelType { ok = await support.supports(modelType: type) }
                print(r.isMLXLanguageModelRepo ? (ok ? "compatible  " : "unsupported ") : "not-LLM     ", r.id, r.modelType ?? "?", r.quantizationBits.map { "\($0)bit" } ?? "")
            }
        case "--engine-check":
            // Real-MLX lifecycle check: cancel mid-generation, immediate re-generation, unload, reload, queueing.
            guard args.count >= 3, let id = ModelRepoID(args[2]), let model = store.installedModel(id) else {
                throw ModelStoreError.notInstalled(args.dropFirst(2).first ?? "")
            }
            let coordinator = InferenceCoordinator(engine: MLXEngine())
            try await coordinator.load(model.reference)
            @Sendable func req(_ text: String, _ max: Int) -> GenerationRequest {
                GenerationRequest(messages: [PromptMessage(role: .user, content: text + " /no_think")],
                                  parameters: GenerationParameters(temperature: 0, maxTokens: max, seed: 0), client: .chat)
            }
            // 1. Cancel after a few chunks.
            let clock = ContinuousClock()
            let longTask = Task {
                var chunks = 0
                for try await e in coordinator.generate(req("Write a 500-word essay about the ocean.", 800)) {
                    if case .text = e { chunks += 1 }
                }
                return chunks
            }
            try await Task.sleep(for: .milliseconds(400))
            let cancelAt = clock.now
            longTask.cancel()
            let chunks = (try? await longTask.value) ?? -1
            print("1 cancel: stopped after \(chunks) chunks, consumer released in \(Int((clock.now - cancelAt).milliseconds)) ms")
            // 2. The next request must run normally (gate released, MLX task drained).
            var text = ""
            var metrics: GenerationMetrics?
            for try await e in coordinator.generate(req("Reply with exactly: OK", 10)) {
                switch e { case .text(let t): text += t; case .finished(let m): metrics = m }
            }
            print("2 after cancel: \(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")) [stop \(metrics?.stopReason.rawValue ?? "?")]")
            // 3. Two concurrent requests are serialized and both complete.
            async let a: String = { var s = ""; for try await e in coordinator.generate(req("Say red.", 12)) { if case .text(let t) = e { s += t } }; return s }()
            async let b: String = { var s = ""; for try await e in coordinator.generate(req("Say blue.", 12)) { if case .text(let t) = e { s += t } }; return s }()
            let (ra, rb) = try await (a, b)
            print("3 concurrent: \(!ra.isEmpty && !rb.isEmpty ? "both completed" : "FAILED")")
            // 4. maxTokens respected.
            var n = 0
            for try await e in coordinator.generate(req("Count from 1 to 100.", 8)) { if case .finished(let m) = e { n = m.generatedTokens; print("4 maxTokens=8: generated \(m.generatedTokens), stop \(m.stopReason.rawValue)") } }
            _ = n
            // 5. Unload → generate fails cleanly → reload works.
            await coordinator.unload()
            do {
                for try await _ in coordinator.generate(req("hi", 5)) {}
                print("5 unload: FAILED (generation succeeded without a model)")
            } catch {
                print("5 unload: generation rejected: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
            let info = try await coordinator.load(model.reference)
            print("6 reload: \(info.id) in \(String(format: "%.2f", info.loadDuration.seconds)) s")
        default:
            break
        }
    }
}
#endif

