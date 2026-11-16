import Foundation
import Testing
@testable import LayXCore

/// Image engine for tests: a few timed steps, then a tiny fake PNG per image. Records when it ran.
actor ScriptedImageEngine: ImageEngine {
    private(set) var loads = 0
    private(set) var unloads = 0
    private(set) var loaded = false
    private(set) var running = false
    var stepDelay: Duration
    /// Checked at every step; counts steps where it returned false.
    private let probe: (@Sendable () async -> Bool)?
    private(set) var probeFailures = 0
    func recordProbe(_ ok: Bool) { if !ok { probeFailures += 1 } }

    init(stepDelay: Duration = .milliseconds(5), probe: (@Sendable () async -> Bool)? = nil) {
        self.stepDelay = stepDelay
        self.probe = probe
    }

    private(set) var lastLoRAs: [LoRAFile] = []
    func load(_ spec: ImageModelSpec, directory: URL, loras: [LoRAFile]) async throws -> LoRALoadReport {
        loads += 1; loaded = true; lastLoRAs = loras
        return LoRALoadReport(appliedLayers: loras.isEmpty ? 0 : 140)
    }
    func unload() async { unloads += 1; loaded = false }
    func setRunning(_ v: Bool) { running = v }

    nonisolated func generate(_ request: ImageRequest) -> AsyncThrowingStream<ImageEvent, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                await self.setRunning(true)
                defer { Task { await self.setRunning(false) } }
                do {
                    for i in 0..<request.count {
                        for step in 0...request.steps {
                            try await Task.sleep(for: await self.stepDelay)
                            if let probe = self.probe { await self.recordProbe(await probe()) }
                            c.yield(.progress(index: i, step: step, total: request.steps))
                        }
                        c.yield(.image(index: i, png: Data("PNG\(request.seed &+ UInt64(i))".utf8), seed: request.seed &+ UInt64(i)))
                    }
                    c.finish()
                } catch {
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Image history store")
struct ImageHistoryStoreTests {
    func makeStore() throws -> (ImageHistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lx-img-\(UUID().uuidString)")
        let db = try SQLiteDatabase(location: .inMemory, migrations: LayXSchema.migrations)
        return (ImageHistoryStore(database: db, folder: dir), dir)
    }

    @Test func saveLoadDelete() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try await store.save(png: Data("a".utf8), prompt: "a cat", negativePrompt: "", modelID: "m", seed: 7, steps: 2,
                                     size: .init(512, 512), duration: 1.2, date: Date(timeIntervalSince1970: 1000))
        let b = try await store.save(png: Data("b".utf8), prompt: "a dog", negativePrompt: "ugly", modelID: "m", seed: UInt64.max - 1,
                                     steps: 30, cfg: 6.5, size: .init(1216, 832), loras: "pixel ×0.8", duration: 0.8,
                                     date: Date(timeIntervalSince1970: 2000))
        let all = try await store.loadAll()
        #expect(all.map(\.prompt) == ["a dog", "a cat"])
        #expect(all.first?.size == ImageSize(1216, 832))
        #expect(all.first?.cfg == 6.5 && all.first?.loras == "pixel ×0.8" && all.first?.negativePrompt == "ugly")
        #expect(all.first?.seed == UInt64.max - 1, "64-bit seeds survive SQLite")
        #expect(try Data(contentsOf: try #require(store.url(for: a))) == Data("a".utf8))
        try await store.delete(b)
        #expect(try await store.loadAll().map(\.id) == [a.id])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(b.file).path))
    }

    @Test func missingFilesAreDropped() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await store.save(png: Data("x".utf8), prompt: "p", negativePrompt: "", modelID: "m", seed: 1, steps: 1,
                                     size: .init(512, 512), duration: 1)
        try FileManager.default.removeItem(at: try #require(store.url(for: r)))
        #expect(try await store.loadAll().isEmpty)
    }

    @Test func fileNamesAreSafe() {
        #expect(ImageHistoryStore.isSafeName("layx-20261116-120000-42.png"))
        #expect(!ImageHistoryStore.isSafeName("../x.png"))
        #expect(!ImageHistoryStore.isSafeName(".hidden.png"))
        #expect(!ImageHistoryStore.isSafeName("a/b.png"))
        #expect(!ImageHistoryStore.isSafeName("x.jpg"))
        let name = ImageHistoryStore.fileName(date: Date(timeIntervalSince1970: 0), seed: 42, index: 1)
        #expect(name.hasPrefix("layx-") && name.hasSuffix("-42-2.png"))
    }

    @Test func sdxlFilesPreferFp16AndRequireAPipeline() {
        func f(_ p: String) -> HubFile { HubFile(path: p, size: 1, sha256: nil) }
        let common = SDXLFiles.required.map(f)
        let both = common + ["unet/diffusion_pytorch_model", "vae/diffusion_pytorch_model", "text_encoder/model", "text_encoder_2/model"]
            .flatMap { [f($0 + ".safetensors"), f($0 + ".fp16.safetensors")] } + [f("unet/model.onnx"), f("sd_xl_base.safetensors")]
        let picked = SDXLFiles.select(from: both).files?.map(\.path) ?? []
        #expect(picked.filter { $0.hasSuffix(".safetensors") }.allSatisfy { $0.contains(".fp16.") })
        #expect(picked.count == SDXLFiles.required.count + 4)
        #expect(!picked.contains("unet/model.onnx"))
        let fullOnly = common + ["unet/diffusion_pytorch_model", "vae/diffusion_pytorch_model", "text_encoder/model", "text_encoder_2/model"]
            .map { f($0 + ".safetensors") }
        #expect(SDXLFiles.select(from: fullOnly).files?.contains { $0.path == "unet/diffusion_pytorch_model.safetensors" } == true)
        let r = SDXLFiles.select(from: [f("model.safetensors"), f("config.json")])
        #expect(r.files == nil && r.missing.contains("unet/config.json"))
    }

    @Test func imageToImageRunsPartOfTheSchedule() {
        var r = ImageRequest(prompt: "p", steps: 30, seed: 1)
        #expect(r.effectiveSteps == 30)
        r.source = Data([1]); r.strength = 0.5
        #expect(r.effectiveSteps == 15)
        r.strength = 0.01
        #expect(r.effectiveSteps == 1)
    }

    @Test func catalogAndSizes() {
        #expect(ImageModelSpec.catalog.allSatisfy { $0.sizes.contains($0.defaultSize) && $0.stepRange.contains($0.defaultSteps) })
        #expect(ImageSize.sdxl.allSatisfy { $0.width % 64 == 0 && $0.height % 64 == 0 })
        let custom = ImageModelSpec.spec(for: ModelRepoID("someone/my-sdxl")!)
        #expect(custom.isCustom && custom.defaultSize == ImageSize(1024, 1024))
        #expect(ImageModelSpec.dreamShaperTurbo.runtimeBytes(for: .init(1024, 1024)) > ImageModelSpec.dreamShaperTurbo.runtimeBytes(for: .init(512, 512)))
    }
}

@Suite("LoRA library")
struct LoRALibraryTests {
    /// Minimal safetensors file: 8-byte header length + JSON header (no tensor data needed for inspection).
    func write(_ header: [String: Any], to url: URL) throws {
        let json = try JSONSerialization.data(withJSONObject: header)
        var length = UInt64(json.count).littleEndian
        var data = Data(bytes: &length, count: 8)
        data.append(json)
        try data.write(to: url)
    }

    @Test func importInspectDelete() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lx-lora-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = LoRALibrary(folder: tmp.appendingPathComponent("lib"))
        let t = ["dtype": "F16", "shape": [4, 4], "data_offsets": [0, 32]] as [String: Any]

        let xl = tmp.appendingPathComponent("pixel-xl.safetensors")
        try write(["lora_unet_input_blocks_4_1_proj_in.lora_down.weight": t, "lora_te2_text_model_encoder_layers_0_mlp_fc1.lora_up.weight": t,
                   "__metadata__": ["ss_tag_frequency": "{\"img\": {\"pixel art\": 30, \"cat\": 2}}"]], to: xl)
        let info = try lib.importFile(xl)
        #expect(info.fit == .sdxl)
        #expect(info.triggerWords.first == "pixel art")

        let sd15 = tmp.appendingPathComponent("old.safetensors")
        try write(["lora_unet_down_blocks_0_attentions_0_proj_in.lora_down.weight": t], to: sd15)
        if case .otherBase = try lib.importFile(sd15).fit {} else { Issue.record("SD 1.x LoRA not detected") }

        let diffusersXL = tmp.appendingPathComponent("papercut.safetensors")
        try write(["lora_unet_down_blocks_1_attentions_0_proj_in.lora_down.weight": t], to: diffusersXL)
        #expect(try lib.importFile(diffusersXL).fit == .sdxl)

        #expect(throws: LoRALibrary.ImportError.alreadyExists("pixel-xl")) { try lib.importFile(xl) }
        let notST = tmp.appendingPathComponent("x.ckpt"); try Data("x".utf8).write(to: notST)
        #expect(throws: LoRALibrary.ImportError.notSafetensors) { try lib.importFile(notST) }

        #expect(lib.list().map(\.name) == ["old", "papercut", "pixel-xl"])
        try lib.delete("pixel-xl.safetensors")
        #expect(lib.list().map(\.name) == ["old", "papercut"])
        #expect(lib.url(for: "../evil.safetensors") == nil)
    }
}

@Suite("Image studio")
@MainActor
struct ImageStudioTests {
    let ref = ModelReference(id: "test/model", directory: URL(fileURLWithPath: "/tmp/none"))

    func makeStudio(engine: ScriptedImageEngine, coordinator: InferenceCoordinator, free: @escaping @Sendable () -> Int64,
                    makeRoom: Bool = true) throws -> (ImageStudio, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lx-img-\(UUID().uuidString)")
        let db = try SQLiteDatabase(location: .inMemory, migrations: LayXSchema.migrations)
        let studio = ImageStudio(engine: engine, coordinator: coordinator, store: ImageHistoryStore(database: db, folder: dir),
                                 modelDirectory: { _ in dir }, availableMemory: free,
                                 allowUnloadingTextModel: { makeRoom }, keepLoaded: { nil })
        return (studio, dir)
    }

    func waitIdle(_ studio: ImageStudio) async throws {
        try await Task.sleep(for: .milliseconds(10))
        for _ in 0..<500 where studio.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func generatesAndSavesEachImage() async throws {
        let engine = ScriptedImageEngine()
        let (studio, dir) = try makeStudio(engine: engine, coordinator: InferenceCoordinator(engine: ScriptedEngine()), free: { .max })
        defer { try? FileManager.default.removeItem(at: dir) }
        studio.generate(ImageRequest(prompt: "  a fox  ", negativePrompt: "blurry", steps: 2, cfg: 5, seed: 10, count: 2,
                                     size: .init(1216, 832)), spec: .sdxlTurbo)
        try await waitIdle(studio)
        #expect(studio.error == nil)
        #expect(studio.history.map(\.seed) == [11, 10])
        #expect(studio.history.allSatisfy { $0.prompt == "a fox" && $0.width == 1216 && $0.height == 832 && $0.cfg == 5 })
        #expect(studio.history.first?.negativePrompt == "blurry")
        #expect(studio.selectedID == studio.history.first?.id)
        #expect(studio.loadedModelID == "stabilityai/sdxl-turbo")
        // Second run reuses the loaded model.
        studio.generate(ImageRequest(prompt: "again", steps: 1, seed: 1), spec: .sdxlTurbo)
        try await waitIdle(studio)
        #expect(await engine.loads == 1)
    }

    @Test func unloadsIdleTextModelWhenMemoryIsShort() async throws {
        let text = InferenceCoordinator(engine: ScriptedEngine())
        try await text.load(ref)
        let engine = ScriptedImageEngine()
        // Short on memory until the text model is gone.
        let (studio, dir) = try makeStudio(engine: engine, coordinator: text, free: {
            1_000_000_000
        })
        defer { try? FileManager.default.removeItem(at: dir) }
        studio.generate(ImageRequest(prompt: "p", steps: 1, seed: 1), spec: .sdxlTurbo)
        try await waitIdle(studio)
        // Free memory never grows in this fake, so after unloading the text model it still fails — but the
        // text model was unloaded first and the user was told.
        #expect(await text.snapshot.model.loadedModel == nil)
        #expect(studio.error?.contains("Not enough free memory") == true)
        #expect(await engine.loads == 0)
    }

    @Test func keepsTextModelWhenMakingRoomIsOff() async throws {
        let text = InferenceCoordinator(engine: ScriptedEngine())
        try await text.load(ref)
        let (studio, dir) = try makeStudio(engine: ScriptedImageEngine(), coordinator: text, free: { 1_000_000_000 }, makeRoom: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        studio.generate(ImageRequest(prompt: "p", steps: 1, seed: 1), spec: .sdxlTurbo)
        try await waitIdle(studio)
        #expect(await text.snapshot.model.loadedModel != nil)
        #expect(studio.error != nil)
    }

    @Test func imageWaitsForTextGenerationAndNeverOverlaps() async throws {
        let textEngine = ScriptedEngine(tokens: Array(repeating: "x", count: 30), tokenDelay: .milliseconds(3))
        let text = InferenceCoordinator(engine: textEngine)
        try await text.load(ref)
        // Every image step must run while the image holds the GPU gate (not the chat).
        let imageEngine = ScriptedImageEngine(stepDelay: .milliseconds(3), probe: { await text.snapshot.activeClient == .image })
        let (studio, dir) = try makeStudio(engine: imageEngine, coordinator: text, free: { .max })
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = Task {
            var n = 0
            for try await e in text.generate(GenerationRequest(messages: [PromptMessage(role: .user, content: "hi")],
                                                               parameters: GenerationParameters(), client: .chat)) {
                if case .text = e { n += 1 }
            }
            return n
        }
        try await Task.sleep(for: .milliseconds(10))
        studio.generate(ImageRequest(prompt: "p", steps: 2, seed: 1), spec: .sdxlTurbo)
        #expect(try await chat.value == 30)
        try await waitIdle(studio)
        #expect(studio.history.count == 1)
        #expect(await imageEngine.probeFailures == 0)
        // The text tokens were all emitted before any image step (FIFO behind the running chat).
        #expect(await textEngine.emissionLog.count == 30)
    }

    @Test func imageToImageIsRecorded() async throws {
        let (studio, dir) = try makeStudio(engine: ScriptedImageEngine(), coordinator: InferenceCoordinator(engine: ScriptedEngine()), free: { .max })
        defer { try? FileManager.default.removeItem(at: dir) }
        studio.generate(ImageRequest(prompt: "p", steps: 4, seed: 1, count: 8, source: Data([1, 2]), strength: 0.75), spec: .sdxlTurbo)
        try await waitIdle(studio)
        #expect(studio.history.count == 8, "up to 8 images per run")
        #expect(studio.history.allSatisfy { $0.strength == 0.75 })
        studio.generate(ImageRequest(prompt: "p", steps: 4, seed: 1), spec: .sdxlTurbo)
        try await waitIdle(studio)
        #expect(studio.history.first?.strength == 0)
    }

    @Test func stopCancels() async throws {
        let (studio, dir) = try makeStudio(engine: ScriptedImageEngine(stepDelay: .milliseconds(50)),
                                           coordinator: InferenceCoordinator(engine: ScriptedEngine()), free: { .max })
        defer { try? FileManager.default.removeItem(at: dir) }
        studio.generate(ImageRequest(prompt: "p", steps: 4, seed: 1, count: 4), spec: .sdxlTurbo)
        try await Task.sleep(for: .milliseconds(80))
        studio.stop()
        try await waitIdle(studio)
        #expect(studio.history.count < 4)
        #expect(studio.notice == "Stopped.")
        #expect(studio.error == nil)
    }

    @Test func changingLoRAsReloadsTheModel() async throws {
        let engine = ScriptedImageEngine()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lx-lora-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var length = UInt64(2).littleEndian
        var data = Data(bytes: &length, count: 8); data.append(Data("{}".utf8))
        try data.write(to: tmp.appendingPathComponent("style.safetensors"))
        let db = try SQLiteDatabase(location: .inMemory, migrations: LayXSchema.migrations)
        let studio = ImageStudio(engine: engine, coordinator: InferenceCoordinator(engine: ScriptedEngine()),
                                 store: ImageHistoryStore(database: db, folder: tmp.appendingPathComponent("img")),
                                 loras: LoRALibrary(folder: tmp), modelDirectory: { _ in tmp }, availableMemory: { .max },
                                 keepLoaded: { nil })
        studio.generate(ImageRequest(prompt: "p", steps: 1, seed: 1), spec: .sdxlTurbo)
        try await waitIdle(studio)
        let lora = LoRAChoice(file: "style.safetensors", scale: 0.8)
        studio.generate(ImageRequest(prompt: "p", steps: 1, seed: 1, loras: [lora]), spec: .sdxlTurbo)
        try await waitIdle(studio)
        #expect(await engine.loads == 2)
        #expect(await engine.lastLoRAs.map(\.scale) == [0.8])
        #expect(studio.loadedLoRAs == [lora])
        #expect(studio.notice?.contains("140 layers") == true)
        #expect(studio.history.first?.loras == "style ×0.8")
        studio.generate(ImageRequest(prompt: "p", steps: 1, seed: 2, loras: [lora]), spec: .sdxlTurbo)
        try await waitIdle(studio)
        #expect(await engine.loads == 2)
    }

    @Test func releasesImageModelForTextModel() async throws {
        let engine = ScriptedImageEngine()
        let (studio, dir) = try makeStudio(engine: engine, coordinator: InferenceCoordinator(engine: ScriptedEngine()), free: { .max })
        defer { try? FileManager.default.removeItem(at: dir) }
        studio.generate(ImageRequest(prompt: "p", steps: 1, seed: 1), spec: .sdxlTurbo)
        try await waitIdle(studio)
        #expect(studio.loadedModelID != nil)
        #expect(await studio.releaseForTextModel())
        #expect(studio.loadedModelID == nil)
        #expect(await engine.unloads == 1)
        #expect(await !studio.releaseForTextModel())
    }
}
