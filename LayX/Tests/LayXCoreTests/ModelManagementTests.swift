import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import LayXCore

// MARK: - Fake Hub served through URLProtocol (deterministic, no network)

final class FakeHub: Sendable {
    struct Repo: Sendable { var files: [String: Data]; var corrupt: Set<String> = [] }
    struct State: Sendable {
        var repos: [String: Repo] = [:]
        var requestedRanges: [String] = []
        var bytesPerChunk = 64
        var chunkDelay: Duration = .zero
    }
    let state = Mutex(State())
    static let current = Mutex<FakeHub?>(nil)

    func tree(_ repo: String) -> Data {
        let files = state.withLock { $0.repos[repo]?.files ?? [:] }
        let items: [[String: Any]] = files.keys.sorted().map { path in
            let data = files[path]!
            var item: [String: Any] = ["type": "file", "path": path, "size": data.count, "oid": "x"]
            if path.hasSuffix(".safetensors") {
                let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                item["lfs"] = ["oid": sha, "size": data.count, "pointerSize": 100]
            }
            return item
        }
        return try! JSONSerialization.data(withJSONObject: items)
    }

    func file(_ repo: String, _ path: String) -> Data? {
        state.withLock { s in
            guard var d = s.repos[repo]?.files[path] else { return nil }
            if s.repos[repo]?.corrupt.contains(path) == true, !d.isEmpty { d[0] ^= 0xFF }
            return d
        }
    }
}

final class FakeHubProtocol: URLProtocol, @unchecked Sendable {
    // URLProtocol requires subclassing; instances are used by one loading thread. (Test-only.)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "hub.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private let stopped = Mutex(false)

    override func startLoading() {
        guard let hub = FakeHub.current.withLock({ $0 }), let url = request.url else { return }
        let parts = url.path.split(separator: "/").map(String.init)
        // /api/models/{o}/{n}/tree/main  or  /{o}/{n}/resolve/main/{path}
        if parts.first == "api", parts.count >= 6 {
            respond(200, hub.tree("\(parts[2])/\(parts[3])"), headers: [:])
            return
        }
        guard parts.count >= 5, parts[2] == "resolve", let data = hub.file("\(parts[0])/\(parts[1])", parts[4...].joined(separator: "/")) else {
            respond(404, Data(), headers: [:]); return
        }
        var start = 0
        if let range = request.value(forHTTPHeaderField: "Range") {
            hub.state.withLock { $0.requestedRanges.append(range) }
            start = Int(range.dropFirst("bytes=".count).dropLast()) ?? 0
            if start >= data.count { respond(416, Data(), headers: [:]); return }
        }
        let body = data.subdata(in: start..<data.count)
        let status = start > 0 ? 206 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let (chunk, delay) = hub.state.withLock { ($0.bytesPerChunk, $0.chunkDelay) }
        // Test-only: deliver chunks from a background queue so cancellation (stopLoading) can interleave.
        let proto = self
        let client = self.client
        DispatchQueue.global().async {
            var offset = 0
            while offset < body.count {
                if proto.stopped.withLock({ $0 }) { return }
                let end = min(offset + chunk, body.count)
                client?.urlProtocol(proto, didLoad: body.subdata(in: offset..<end))
                offset = end
                if delay > .zero { Thread.sleep(forTimeInterval: delay.seconds) }
            }
            client?.urlProtocolDidFinishLoading(proto)
        }
    }

    override func stopLoading() { stopped.withLock { $0 = true } }

    private func respond(_ status: Int, _ data: Data, headers: [String: String]) {
        let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

struct FixedArchitectures: ModelArchitectureSupport {
    var supported: Set<String> = ["qwen3", "llama"]
    func supports(modelType: String) async -> Bool { supported.contains(modelType) }
}

@Suite(.serialized) struct ModelDownloaderTests {
    let root: URL
    let hub = FakeHub()
    let config: URLSessionConfiguration

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("layx-models-\(UUID().uuidString)")
        config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeHubProtocol.self]
        FakeHub.current.withLock { $0 = hub }
        let weights = Data((0..<5000).map { UInt8($0 % 251) })
        hub.state.withLock {
            $0.repos["mlx-community/Tiny-4bit"] = .init(files: [
                "config.json": Data(#"{"model_type":"qwen3","max_position_embeddings":4096,"quantization":{"bits":4}}"#.utf8),
                "tokenizer.json": Data("{}".utf8),
                "model.safetensors": weights,
                "README.md": Data("docs".utf8),
                "images/logo.png": Data([1, 2, 3]),
            ])
            $0.repos["mlx-community/Gemma-Vision"] = .init(files: [
                "config.json": Data(#"{"model_type":"paligemma"}"#.utf8),
                "model.safetensors": weights,
            ])
            $0.repos["someone/pytorch-only"] = .init(files: [
                "config.json": Data(#"{"model_type":"qwen3"}"#.utf8),
                "pytorch_model.bin": weights,
            ])
        }
    }

    func makeDownloader() -> (ModelDownloader, ModelStore) {
        let store = ModelStore(root: root)
        let api = HubAPI(endpoint: URL(string: "https://hub.test")!, session: URLSession(configuration: config))
        return (ModelDownloader(store: store, hub: api, architectures: FixedArchitectures(), transferConfiguration: config), store)
    }

    @Test func downloadInstallsOnlyRequiredFilesWithManifest() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (downloader, store) = makeDownloader()
        let id = try #require(ModelRepoID("mlx-community/Tiny-4bit"))
        let model = try await downloader.download(id)
        let files = try FileManager.default.contentsOfDirectory(atPath: model.directory.path).sorted()
        #expect(files == [".layx-manifest.json", "config.json", "model.safetensors", "tokenizer.json"])
        #expect(model.manifest.modelType == "qwen3")
        #expect(model.manifest.contextLength == 4096)
        #expect(model.manifest.quantizationBits == 4)
        #expect(store.installedModels().map(\.id) == [id])
        #expect(await downloader.states[id] == .completed)
    }

    @Test func checksumMismatchFailsAndInstallsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        hub.state.withLock { $0.repos["mlx-community/Tiny-4bit"]?.corrupt = ["model.safetensors"] }
        let (downloader, store) = makeDownloader()
        let id = try #require(ModelRepoID("mlx-community/Tiny-4bit"))
        await #expect(throws: ModelStoreError.checksumMismatch(file: "model.safetensors")) { try await downloader.download(id) }
        #expect(store.installedModels().isEmpty)
        guard case .failed? = await downloader.states[id] else { Issue.record("expected failed state"); return }
        // The fix is a retry once the source is good again.
        hub.state.withLock { $0.repos["mlx-community/Tiny-4bit"]?.corrupt = [] }
        _ = try await downloader.download(id)
        #expect(store.installedModels().count == 1)
    }

    @Test func cancelLeavesResumablePartialThenResumesWithRange() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        hub.state.withLock { $0.bytesPerChunk = 100; $0.chunkDelay = .milliseconds(5) }
        let (downloader, store) = makeDownloader()
        let id = try #require(ModelRepoID("mlx-community/Tiny-4bit"))
        let task = Task { try await downloader.download(id) }
        try await Task.sleep(for: .milliseconds(150))
        await downloader.cancel(id)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await downloader.states[id] == .cancelled)
        #expect(store.installedModels().isEmpty)
        let partial = store.incompleteDownloads()
        #expect(partial.map(\.id) == [id])

        hub.state.withLock { $0.chunkDelay = .zero; $0.requestedRanges = [] }
        _ = try await downloader.download(id)
        #expect(store.installedModels().count == 1)
        #expect(hub.state.withLock { !$0.requestedRanges.isEmpty }, "resume should use HTTP Range")
        #expect(store.incompleteDownloads().isEmpty)
    }

    @Test func unsupportedArchitectureIsRejectedBeforeWeights() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (downloader, store) = makeDownloader()
        let id = try #require(ModelRepoID("mlx-community/Gemma-Vision"))
        await #expect(throws: ModelStoreError.self) { try await downloader.download(id) }
        #expect(!FileManager.default.fileExists(atPath: store.partialDirectory(for: id).path))
    }

    @Test func repoWithoutSafetensorsIsRejected() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (downloader, _) = makeDownloader()
        await #expect(throws: ModelStoreError.noWeights) { try await downloader.download(ModelRepoID("someone/pytorch-only")!) }
    }

    @Test func deleteRefusesLoadedModelAndRemovesOthers() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (downloader, store) = makeDownloader()
        let id = try #require(ModelRepoID("mlx-community/Tiny-4bit"))
        _ = try await downloader.download(id)
        #expect(throws: ModelStoreError.inUse(id.description)) { try store.delete(id, inUse: [id.description]) }
        try store.delete(id, inUse: [])
        #expect(store.installedModels().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: id).path))
        #expect(throws: ModelStoreError.notInstalled(id.description)) { try store.delete(id, inUse: []) }
    }
}

@Suite struct ModelStoreSafetyTests {
    @Test(arguments: ["mlx-community/Qwen3-0.6B-4bit", "a/b", "Org_1/model.v2"])
    func validRepoIDs(_ raw: String) { #expect(ModelRepoID(raw)?.description == raw) }

    @Test(arguments: ["", "noslash", "a/b/c", "../etc", "a/..", "./x", "a/.hidden", "/abs/path", "a/b c", "a\\b/c",
                      "a/-rf", "a/\u{0}", "ａ/b"])
    func invalidRepoIDs(_ raw: String) { #expect(ModelRepoID(raw) == nil) }

    @Test(arguments: ["../x", "a/../../x", "/etc/passwd", ".git/config", "a/./b", "", "a//b", "x\\y"])
    func unsafeRelativePathsAreRejected(_ path: String) {
        let base = URL(fileURLWithPath: "/tmp/layx-base")
        #expect(throws: ModelStoreError.self) { try ModelStore.safeChild(of: base, relativePath: path) }
    }

    @Test func safeRelativePathsStayInside() throws {
        let base = URL(fileURLWithPath: "/tmp/layx-base")
        #expect(try ModelStore.safeChild(of: base, relativePath: "model.safetensors").path == "/tmp/layx-base/model.safetensors")
        #expect(try ModelStore.safeChild(of: base, relativePath: "sub/dir/file.json").path == "/tmp/layx-base/sub/dir/file.json")
    }

    @Test func symlinkEscapeIsDetected() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("layx-sym-\(UUID().uuidString)")
        let base = tmp.appendingPathComponent("base"), outside = tmp.appendingPathComponent("outside")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(!ModelStore.isContained(base.appendingPathComponent("link/file"), in: base))
        #expect(throws: ModelStoreError.self) { try ModelStore.safeChild(of: base, relativePath: "link/file") }
    }

    @Test func deleteRefusesSymlinkedModelDirectory() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("layx-del-\(UUID().uuidString)")
        let root = tmp.appendingPathComponent("models"), victim = tmp.appendingPathComponent("victim")
        try fm.createDirectory(at: root.appendingPathComponent("evil"), withIntermediateDirectories: true)
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: victim.appendingPathComponent("important.txt"))
        defer { try? fm.removeItem(at: tmp) }
        try fm.createSymbolicLink(at: root.appendingPathComponent("evil/model"), withDestinationURL: victim)
        let store = ModelStore(root: root)
        #expect(throws: ModelStoreError.self) { try store.delete(ModelRepoID("evil/model")!, inUse: []) }
        #expect(fm.fileExists(atPath: victim.appendingPathComponent("important.txt").path))
    }
}

@Suite struct StorageLocationTests {
    func tmp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("layx-loc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func emptyFolderIsUsedDirectly() throws {
        let dir = try tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = try ModelStore.root(forChosenFolder: dir)
        #expect(root.standardizedFileURL.path == dir.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(ModelStore.storeMarker).path))
    }

    @Test func nonEmptyFolderGetsSubfolder() throws {
        let dir = try tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("mine".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let root = try ModelStore.root(forChosenFolder: dir)
        #expect(root.lastPathComponent == "Lay X Models")
        // Choosing the same folder again reuses the subfolder; choosing the store itself uses it directly.
        #expect(try ModelStore.root(forChosenFolder: dir) == root)
        #expect(try ModelStore.root(forChosenFolder: root).standardizedFileURL.path == root.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.txt").path))
    }
}

@Suite struct HubParsingTests {
    @Test func parseSearchExtractsMetadata() throws {
        let json = #"""
        [{"id":"mlx-community/Qwen3-0.6B-4bit","downloads":1234,"lastModified":"2025-04-28T21:26:13.000Z",
          "library_name":"mlx","tags":["mlx","safetensors"],
          "config":{"model_type":"qwen3","quantization_config":{"bits":4}},
          "safetensors":{"total":751632384}},
         {"id":"../evil","downloads":1}]
        """#
        let r = try HubAPI.parseSearch(Data(json.utf8))
        #expect(r.count == 1)
        #expect(r[0].modelType == "qwen3")
        #expect(r[0].quantizationBits == 4)
        #expect(r[0].parameterCount == 751_632_384)
        #expect(r[0].downloads == 1234)
        #expect(r[0].lastModified != nil)
        #expect(r[0].isMLXLanguageModelRepo)
    }

    @Test func audioAndVisionPackagesAreNotLanguageModels() {
        let s = HubModelSummary(id: ModelRepoID("mlx-community/Qwen3-ASR-0.6B-4bit")!, modelType: "qwen3_asr",
                                quantizationBits: 4, parameterCount: nil, downloads: 0, lastModified: nil,
                                tags: ["mlx-audio", "mlx"], libraryName: "mlx-audio")
        #expect(!s.isMLXLanguageModelRepo)
        let embedding = HubModelSummary(id: ModelRepoID("mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ")!, modelType: "qwen3",
                                        quantizationBits: 4, parameterCount: nil, downloads: 0, lastModified: nil,
                                        tags: ["mlx", "sentence-transformers", "feature-extraction"], libraryName: "mlx",
                                        pipelineTag: "text-generation")
        #expect(!embedding.isMLXLanguageModelRepo)
        let vlm = HubModelSummary(id: ModelRepoID("mlx-community/Qwen3.5-0.8B-4bit")!, modelType: "qwen3_5",
                                  quantizationBits: 4, parameterCount: nil, downloads: 0, lastModified: nil,
                                  tags: ["transformers", "mlx"], libraryName: "transformers", pipelineTag: "image-text-to-text")
        #expect(!vlm.isMLXLanguageModelRepo)
        let llm = HubModelSummary(id: ModelRepoID("mlx-community/Qwen3-4B-4bit")!, modelType: "qwen3",
                                  quantizationBits: 4, parameterCount: nil, downloads: 0, lastModified: nil,
                                  tags: ["mlx", "text-generation"], libraryName: "mlx", pipelineTag: "text-generation")
        #expect(llm.isMLXLanguageModelRepo)
    }

    @Test func requiredFilesSelection() {
        let all = ["config.json", "model.safetensors", "model-00001-of-00002.safetensors", "tokenizer.json",
                   "tokenizer.model", "merges.txt", "chat_template.jinja", "README.md", ".gitattributes",
                   "pytorch_model.bin", "assets/x.json", "model.gguf"].map { HubFile(path: $0, size: 1, sha256: nil) }
        #expect(Set(HubAPI.requiredFiles(all).map(\.path)) == [
            "config.json", "model.safetensors", "model-00001-of-00002.safetensors", "tokenizer.json",
            "tokenizer.model", "merges.txt", "chat_template.jinja"])
    }

    @Test func configParsingHandlesNestedTextConfig() {
        let c = ModelStore.parseConfig(["model_type": "gemma3", "text_config": ["max_position_embeddings": 131072],
                                        "quantization": ["bits": 8]])
        #expect(c.modelType == "gemma3")
        #expect(c.context == 131072)
        #expect(c.bits == 8)
    }
}
