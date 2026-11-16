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

    func load(_ spec: ImageModelSpec, directory: URL) async throws { loads += 1; loaded = true }
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
                                     size: 512, duration: 1.2, date: Date(timeIntervalSince1970: 1000))
        let b = try await store.save(png: Data("b".utf8), prompt: "a dog", negativePrompt: "", modelID: "m", seed: UInt64.max - 1, steps: 1,
                                     size: 512, duration: 0.8, date: Date(timeIntervalSince1970: 2000))
        let all = try await store.loadAll()
        #expect(all.map(\.prompt) == ["a dog", "a cat"])
        #expect(all.first?.seed == UInt64.max - 1, "64-bit seeds survive SQLite")
        #expect(try Data(contentsOf: try #require(store.url(for: a))) == Data("a".utf8))
        try await store.delete(b)
        #expect(try await store.loadAll().map(\.id) == [a.id])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(b.file).path))
    }

    @Test func missingFilesAreDropped() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await store.save(png: Data("x".utf8), prompt: "p", negativePrompt: "", modelID: "m", seed: 1, steps: 1, size: 512, duration: 1)
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

    @Test func sdxlTurboSpecUsesFp16Weights() {
        let spec = ImageModelSpec.sdxlTurbo
        #expect(spec.files.filter { $0.hasSuffix(".safetensors") }.allSatisfy { $0.contains(".fp16.") })
        if case .image(let type, let files) = spec.downloadProfile {
            #expect(type == "sdxl-turbo")
            #expect(files.count == spec.files.count)
        } else {
            Issue.record("expected an image profile")
        }
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
        studio.generate(ImageRequest(prompt: "  a fox  ", steps: 2, seed: 10, count: 2), spec: .sdxlTurbo)
        try await waitIdle(studio)
        #expect(studio.error == nil)
        #expect(studio.history.map(\.seed) == [11, 10])
        #expect(studio.history.allSatisfy { $0.prompt == "a fox" && $0.width == 512 })
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
