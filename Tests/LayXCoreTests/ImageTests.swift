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
    private(set) var lastRequest: ImageRequest?
    private(set) var loraSwaps = 0
    /// Behaves like the FLUX.2 / Qwen-Image engines: LoRAs switch on the loaded model.
    var liveLoRAs = false
    func setLiveLoRAs(_ v: Bool) { liveLoRAs = v }
    func load(_ spec: ImageModelSpec, directory: URL, loras: [LoRAFile]) async throws -> LoRALoadReport {
        loads += 1; loaded = true; lastLoRAs = loras
        return LoRALoadReport(appliedLayers: loras.isEmpty ? 0 : 140)
    }
    func setLoRAs(_ loras: [LoRAFile]) async throws -> LoRALoadReport? {
        guard liveLoRAs else { return nil }
        loraSwaps += 1; lastLoRAs = loras
        return LoRALoadReport(appliedLayers: loras.isEmpty ? 0 : 96)
    }
    func record(_ r: ImageRequest) { lastRequest = r }
    func unload() async { unloads += 1; loaded = false }
    func setRunning(_ v: Bool) { running = v }

    nonisolated func generate(_ request: ImageRequest) -> AsyncThrowingStream<ImageEvent, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                await self.record(request)
                await self.setRunning(true)
                defer { Task { await self.setRunning(false) } }
                do {
                    for i in 0..<request.count {
                        for step in 0...request.steps {
                            try await Task.sleep(for: await self.stepDelay)
                            if let probe = self.probe { await self.recordProbe(await probe()) }
                            c.yield(.progress(index: i, step: step, total: request.steps))
                        }
                        c.yield(.image(index: i, png: Data("PNG\(request.seed(at: i))".utf8), seed: request.seed(at: i)))
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

    @Test func deletingLeavesNoTraceOnDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lx-imgdb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("t.sqlite")
        let db = try SQLiteDatabase(location: .file(dbURL), migrations: LayXSchema.migrations)
        let store = ImageHistoryStore(database: db, folder: dir.appendingPathComponent("images"))
        let secret = "zq-secret-prompt-\(UUID().uuidString)"
        let r = try await store.save(png: Data("x".utf8), prompt: secret, negativePrompt: secret + "-neg", modelID: "m",
                                     seed: 1, steps: 1, size: .init(512, 512), duration: 1)
        _ = try await store.save(png: Data("y".utf8), prompt: "kept", negativePrompt: "", modelID: "m",
                                 seed: 2, steps: 1, size: .init(512, 512), duration: 1)
        try await store.delete(r)
        #expect(try await store.loadAll().map(\.prompt) == ["kept"])
        // Neither the database nor its write-ahead log keeps the deleted prompt.
        for suffix in ["", "-wal", "-journal"] {
            let file = URL(fileURLWithPath: dbURL.path + suffix)
            guard let data = try? Data(contentsOf: file) else { continue }
            #expect(data.range(of: Data(secret.utf8)) == nil, "found in \(file.lastPathComponent)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("images").path).count == 1)
    }

    @Test func missingFilesAreHiddenNotForgotten() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await store.save(png: Data("x".utf8), prompt: "p", negativePrompt: "", modelID: "m", seed: 1, steps: 1,
                                     size: .init(512, 512), duration: 1)
        let url = try #require(store.url(for: r))
        let aside = dir.deletingLastPathComponent().appendingPathComponent("aside-\(UUID().uuidString).png")
        try FileManager.default.moveItem(at: url, to: aside)
        #expect(try await store.loadAll().isEmpty)
        // The file comes back (drive reconnected, move finished): so does the record.
        try FileManager.default.moveItem(at: aside, to: url)
        #expect(try await store.loadAll().map(\.id) == [r.id])
    }

    @Test @MainActor func relocationNeverLosesFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-move-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        for n in ["a.png", "b.png"] { try Data(n.utf8).write(to: old.appendingPathComponent(n)) }
        try Data("other".utf8).write(to: new.appendingPathComponent("b.png"))
        // A same-named file at the target: refused before anything is copied or switched.
        var switched = false
        await #expect(throws: FolderRelocation.RelocationError.self) {
            _ = try await FolderRelocation.relocate(from: old, to: new, matching: { $0.hasSuffix(".png") }) { switched = true }
        }
        #expect(!switched)
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("a.png").path))
        #expect(!FileManager.default.fileExists(atPath: new.appendingPathComponent("a.png").path))
        #expect(try Data(contentsOf: new.appendingPathComponent("b.png")) == Data("other".utf8))
        // Without the clash: copied, switched, originals removed.
        try FileManager.default.removeItem(at: new.appendingPathComponent("b.png"))
        let moved = try await FolderRelocation.relocate(from: old, to: new, matching: { $0.hasSuffix(".png") }) { switched = true }
        #expect(moved == 2 && switched)
        #expect(try Data(contentsOf: new.appendingPathComponent("b.png")) == Data("b.png".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: old.path).isEmpty)
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
        for spec in ImageModelSpec.catalog {
            #expect(spec.sizes.allSatisfy { $0.width % spec.family.sizeStep == 0 && $0.height % spec.family.sizeStep == 0 && max($0.width, $0.height) <= spec.family.maxSide }, "\(spec.name)")
        }
        #expect(!ImageModelSpec.flux2Klein.usesGuidance && ImageModelSpec.flux2KleinBase.usesGuidance)
        #expect(ImageModelSpec.qwenImageFlash.runtimeBytes(for: .init(1024, 1024)) > ImageModelSpec.flux2Klein.runtimeBytes(for: .init(1024, 1024)))
    }

    @Test func customModelsTakeTheirFamilyDefaults() {
        let lightning = ImageModelSpec.spec(for: ModelRepoID("someone/Qwen-Image-Lightning")!, family: .qwenImage)
        #expect(lightning.family == .qwenImage && lightning.defaultSteps == 4 && !lightning.usesGuidance && lightning.isCustom)
        let full = ImageModelSpec.spec(for: ModelRepoID("unsloth/Qwen-Image")!, family: .qwenImage)
        #expect(full.usesGuidance && full.defaultSteps > 20)
        let base = ImageModelSpec.spec(for: ModelRepoID("someone/klein-base-ft")!, family: .flux2KleinBase)
        #expect(base.family == .flux2KleinBase && base.name == "klein base ft")
        #expect(ImageFamily(modelType: nil) == .sdxl && ImageFamily(modelType: "qwen-image") == .qwenImage)
        let z = ImageModelSpec.spec(for: ModelRepoID("someone/z-image-turbo-ft")!, family: .zImage)
        #expect(z.family == .zImage && z.defaultSteps == 8 && !z.usesGuidance && z.family.sourceMode == .strength && !z.family.swapsLoRAsLive)
        #expect(ImageModelSpec.spec(for: ModelRepoID("x/zb")!, family: .zImageBase).usesGuidance)
    }

    @Test func diffusersFilesTakeComponentsOnly() {
        func f(_ p: String) -> HubFile { HubFile(path: p, size: 1, sha256: nil) }
        let repo = ["model_index.json", "scheduler/scheduler_config.json", "transformer/config.json",
                    "transformer/diffusion_pytorch_model.safetensors", "text_encoder/config.json",
                    "text_encoder/model-00001-of-00002.safetensors", "text_encoder/model-00002-of-00002.safetensors",
                    "text_encoder/model.safetensors.index.json", "tokenizer/tokenizer.json", "tokenizer/chat_template.jinja",
                    "vae/config.json", "vae/diffusion_pytorch_model.safetensors",
                    "flux-2-klein-4b.safetensors", "editing.jpg", "README.md", "transformer/diffusion_pytorch_model.bin"].map(f)
        let picked = DiffusersFiles.select(from: repo).files?.map(\.path) ?? []
        #expect(picked.count == 12)
        #expect(!picked.contains("flux-2-klein-4b.safetensors") && !picked.contains("transformer/diffusion_pytorch_model.bin"))
        let broken = DiffusersFiles.select(from: repo.filter { !$0.path.hasPrefix("vae/") })
        #expect(broken.files == nil && broken.missing.contains("vae/config.json"))
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
        #expect(info.fit == .fits(.sdxl))
        #expect(info.triggerWords.first == "pixel art")

        let sd15 = tmp.appendingPathComponent("old.safetensors")
        try write(["lora_unet_down_blocks_0_attentions_0_proj_in.lora_down.weight": t], to: sd15)
        if case .otherBase = try lib.importFile(sd15).fit {} else { Issue.record("SD 1.x LoRA not detected") }

        let diffusersXL = tmp.appendingPathComponent("papercut.safetensors")
        try write(["lora_unet_down_blocks_1_attentions_0_proj_in.lora_down.weight": t], to: diffusersXL)
        #expect(try lib.importFile(diffusersXL).fit == .fits(.sdxl))

        #expect(throws: LoRALibrary.ImportError.alreadyExists("pixel-xl")) { try lib.importFile(xl) }
        let notST = tmp.appendingPathComponent("x.ckpt"); try Data("x".utf8).write(to: notST)
        #expect(throws: LoRALibrary.ImportError.notSafetensors) { try lib.importFile(notST) }

        #expect(lib.list().map(\.name) == ["old", "papercut", "pixel-xl"])
        try lib.delete("pixel-xl.safetensors")
        #expect(lib.list().map(\.name) == ["old", "papercut"])
        #expect(lib.url(for: "../evil.safetensors") == nil)
    }
    @Test func refusesWholeModels() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lx-lora-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let t = ["dtype": "F16", "shape": [4, 4], "data_offsets": [0, 32]] as [String: Any]
        let file = tmp.appendingPathComponent("illustrious.safetensors")
        try write(["model.diffusion_model.out.2.weight": t, "first_stage_model.encoder.conv_in.weight": t], to: file)
        #expect(throws: LoRALibrary.ImportError.fullModel) { try LoRALibrary(folder: tmp.appendingPathComponent("lib")).importFile(file) }
    }

    @Test func tellsBaseModelsApart() {
        func fit(_ keys: [String], _ base: String = "") -> LoRALibrary.Info.Fit { LoRALibrary.fit(keys: keys, base: base) }
        // FLUX.2 klein 4B: 5 double / 20 single blocks (BFL and diffusers names).
        #expect(fit(["diffusion_model.double_blocks.4.img_attn.qkv.lora_A.weight", "diffusion_model.single_blocks.19.linear1.lora_A.weight"])
                == .fits(.flux2Klein4B))
        #expect(fit(["transformer.transformer_blocks.3.attn.to_q.lora_A.weight",
                     "transformer.single_transformer_blocks.12.attn.to_qkv_mlp_proj.lora_A.weight"]) == .fits(.flux2Klein4B))
        // FLUX.1: 19 double / 38 single blocks, or its single-block proj_mlp.
        #expect(fit(["lora_unet_double_blocks_18_img_attn_qkv.lora_down.weight"]) == .otherBase("FLUX.1"))
        #expect(fit(["transformer.single_transformer_blocks.2.proj_mlp.lora_A.weight"]) == .otherBase("FLUX.1"))
        // Qwen-Image: per-stream MLPs / modulation.
        #expect(fit(["transformer_blocks.59.img_mlp.net.0.proj.lora_A.weight"]) == .fits(.qwenImage))
        #expect(fit(["x"], "Qwen-Image") == .fits(.qwenImage))
        #expect(fit(["transformer.transformer_blocks.59.attn.to_k.lora.down.weight"]) == .fits(.qwenImage))
        #expect(fit(["x"], "flux-2-klein-9b") == .otherBase("FLUX.2 klein 9B"))
        #expect(fit(["lora_te2_text_model_encoder_layers_0_mlp_fc1.lora_up.weight"]) == .fits(.sdxl))
        #expect(fit(["something"]) == .unknown)
        // Z-Image: single-stream `layers.N.attention.*` / `feed_forward.*`.
        #expect(fit(["diffusion_model.layers.12.attention.to_q.lora_A.weight", "layers.3.feed_forward.w1.lora_B.weight"]) == .fits(.zImage))
        #expect(fit(["x"], "Z-Image-Turbo") == .fits(.zImage))
        // A whole checkpoint dropped in as a "LoRA" (the bug report): not applied, and refused on import.
        let checkpoint = ["model.diffusion_model.input_blocks.0.0.weight", "first_stage_model.decoder.conv_in.weight",
                          "conditioner.embedders.1.model.logit_scale"]
        #expect(fit(checkpoint) == .fullModel)
        #expect(LoRALibrary.isFullModel(checkpoint) && !LoRALibrary.isFullModel(["unet.down.lora_A.weight", "unet.x.alpha"]))
        #expect(!ImageStudio.lora(LoRALibrary.Info(file: "c.safetensors", bytes: 0, fit: .fullModel, baseModel: nil, triggerWords: []),
                                  fits: .sdxl))
        #expect(LoRALibrary.maxIndex(["single_transformer_blocks.30.x", "transformer_blocks.2.y"], after: ["transformer_blocks"]) == 2)
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
        // `runCount` is set as soon as a run is requested (before its task starts), so a slow start isn't
        // mistaken for a finished run.
        try await Task.sleep(for: .milliseconds(10))
        for _ in 0..<500 where studio.isBusy || studio.runCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
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

    @Test func dynamicPromptsExpandPerImage() async throws {
        let (studio, dir) = try makeStudio(engine: ScriptedImageEngine(), coordinator: InferenceCoordinator(engine: ScriptedEngine()), free: { .max })
        defer { try? FileManager.default.removeItem(at: dir) }
        studio.generate(ImageRequest(prompt: "a {red|blue} (fox:1.2) __nope__", negativePrompt: "{blurry|dark}", steps: 1, cfg: 5,
                                     seed: 10, count: 8), spec: .sdxlTurbo)
        try await waitIdle(studio)
        #expect(studio.history.count == 8)
        #expect(studio.history.allSatisfy {
            ["a red (fox:1.2) __nope__", "a blue (fox:1.2) __nope__"].contains($0.prompt) && ["blurry", "dark"].contains($0.negativePrompt)
        })
        #expect(Set(studio.history.map(\.prompt)).count == 2)
        #expect(studio.notice?.contains("__nope__") == true)
        // The same seed picks the same options again.
        let first = studio.history.last!
        studio.generate(ImageRequest(prompt: "a {red|blue} (fox:1.2) __nope__", negativePrompt: "{blurry|dark}", steps: 1, cfg: 5,
                                     seed: 10, count: 1), spec: .sdxlTurbo)
        try await waitIdle(studio)
        #expect(studio.history.first?.prompt == first.prompt && studio.history.first?.negativePrompt == first.negativePrompt)
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

    @Test func requestsFollowTheModelFamily() async throws {
        let engine = ScriptedImageEngine()
        let (studio, dir) = try makeStudio(engine: engine, coordinator: InferenceCoordinator(engine: ScriptedEngine()), free: { .max })
        defer { try? FileManager.default.removeItem(at: dir) }
        // klein (distilled): no guidance / negative, the source is a reference (whole schedule), sizes step by 16.
        studio.generate(ImageRequest(prompt: "p", negativePrompt: "blurry", steps: 4, cfg: 5, seed: 1, size: .init(1000, 1000),
                                     source: Data([1]), strength: 0.4), spec: .flux2Klein)
        try await waitIdle(studio)
        var r = await engine.lastRequest
        #expect(r?.cfg == 0 && r?.negativePrompt == "" && r?.strength == 1 && r?.source != nil && r?.size == .init(992, 992))
        #expect(r?.effectiveSteps == 4)
        // Qwen-Image: text to image only.
        studio.generate(ImageRequest(prompt: "p", steps: 4, seed: 1, size: .init(1328, 1328), source: Data([1])), spec: .qwenImageFlash)
        try await waitIdle(studio)
        r = await engine.lastRequest
        #expect(r?.source == nil && r?.size == .init(1328, 1328))
        #expect(studio.history.first?.strength == 0)
        // klein base keeps guidance and the negative prompt.
        studio.generate(ImageRequest(prompt: "p", negativePrompt: "blurry", steps: 8, cfg: 4, seed: 1), spec: .flux2KleinBase)
        try await waitIdle(studio)
        r = await engine.lastRequest
        #expect(r?.cfg == 4 && r?.negativePrompt == "blurry")
    }

    @Test func liveLoRAsSwitchWithoutReloading() async throws {
        let engine = ScriptedImageEngine()
        await engine.setLiveLoRAs(true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lx-lora-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        func lora(_ name: String, _ header: String) throws {
            var length = UInt64(header.utf8.count).littleEndian
            var data = Data(bytes: &length, count: 8); data.append(Data(header.utf8))
            try data.write(to: tmp.appendingPathComponent(name))
        }
        let t = #"{"dtype":"F16","shape":[4,4],"data_offsets":[0,32]}"#
        try lora("qwen.safetensors", #"{"transformer_blocks.0.img_mlp.net.0.proj.lora_A.weight":\#(t)}"#)
        try lora("xl.safetensors", #"{"lora_te2_text_model_encoder_layers_0_mlp_fc1.lora_up.weight":\#(t)}"#)
        let db = try SQLiteDatabase(location: .inMemory, migrations: LayXSchema.migrations)
        let studio = ImageStudio(engine: engine, coordinator: InferenceCoordinator(engine: ScriptedEngine()),
                                 store: ImageHistoryStore(database: db, folder: tmp.appendingPathComponent("img")),
                                 loras: LoRALibrary(folder: tmp), modelDirectory: { _ in tmp }, availableMemory: { .max },
                                 keepLoaded: { nil })
        studio.generate(ImageRequest(prompt: "p", steps: 1, seed: 1), spec: .qwenImageFlash)
        try await waitIdle(studio)
        // The SDXL LoRA is dropped for a Qwen-Image model; the Qwen one switches on in place.
        let choices = [LoRAChoice(file: "qwen.safetensors", scale: 1.5), LoRAChoice(file: "xl.safetensors", scale: 1)]
        studio.generate(ImageRequest(prompt: "p", steps: 1, seed: 1, loras: choices), spec: .qwenImageFlash)
        try await waitIdle(studio)
        #expect(await engine.loads == 1)
        #expect(await engine.loraSwaps == 1)
        #expect(await engine.lastLoRAs.map(\.url.lastPathComponent) == ["qwen.safetensors"])
        #expect(studio.notice?.contains("96 layers") == true)
        #expect(studio.history.first?.loras == "qwen ×1.5")
    }

    @Test func randomSeedsAndBackgroundRuns() async throws {
        let (studio, dir) = try makeStudio(engine: ScriptedImageEngine(stepDelay: .milliseconds(15)),
                                           coordinator: InferenceCoordinator(engine: ScriptedEngine()), free: { .max })
        defer { try? FileManager.default.removeItem(at: dir) }
        studio.generate(ImageRequest(prompt: "first", steps: 1, seed: 1), spec: .sdxlTurbo)
        try await waitIdle(studio)
        let earlier = try #require(studio.history.first)
        // Random seeds: the first is the given seed, the rest differ from seed+1, …
        var request = ImageRequest(prompt: "p", steps: 3, seed: 100, count: 3)
        request.seeds = [100, 7, 9]
        studio.generate(request, spec: .sdxlTurbo)
        #expect(studio.watchingProgress && studio.runCount == 3)
        // Picking a history image while it runs: the run continues, the choice stays on screen.
        try await Task.sleep(for: .milliseconds(30))
        studio.select(earlier.id)
        #expect(!studio.watchingProgress)
        try await waitIdle(studio)
        #expect(studio.selectedID == earlier.id)
        #expect(Set(studio.history.prefix(3).map(\.seed)) == [100, 7, 9])
        #expect(studio.runCount == 0 && !studio.watchingProgress)
        #expect(ImageRequest.randomSeeds(first: 5, count: 4).count == 4 && ImageRequest.randomSeeds(first: 5, count: 4).first == 5)
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
