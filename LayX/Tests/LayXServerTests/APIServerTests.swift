import Foundation
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing
@testable import LayXCore
@testable import LayXServer

/// Deterministic engine for API tests (not evidence of real inference).
actor FakeEngine: InferenceEngine {
    let tokens: [String]
    let delay: Duration
    private(set) var lastRequest: GenerationRequest?
    private(set) var cancelled = 0
    init(tokens: [String] = ["Hello", ",", " world", "!"], delay: Duration = .milliseconds(2)) {
        self.tokens = tokens
        self.delay = delay
    }
    func load(_ model: ModelReference, progress: @escaping @Sendable (Double) -> Void) async throws -> LoadedModelInfo {
        LoadedModelInfo(id: model.id, contextLength: 4096)
    }
    func unload() async {}
    func memory() async -> EngineMemory? { nil }
    func resetPeakMemory() async {}
    func record(_ r: GenerationRequest) { lastRequest = r }
    func markCancelled() { cancelled += 1 }
    nonisolated func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                await self.record(request)
                do {
                    for t in tokens { try await Task.sleep(for: delay); c.yield(.text(t)) }
                    c.yield(.finished(GenerationMetrics(promptTokens: 7, generatedTokens: tokens.count, timeToFirstToken: .milliseconds(5),
                                                        prefillDuration: .milliseconds(4), decodeDuration: .milliseconds(10),
                                                        totalDuration: .milliseconds(15), stopReason: .endOfSequence)))
                    c.finish()
                } catch {
                    await self.markCancelled()
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

final class LogSink: Sendable {
    let records = Mutex<[APIRequestRecord]>([])
    func add(_ r: APIRequestRecord) { records.withLock { $0.append(r) } }
}

struct Harness {
    let engine: FakeEngine
    let coordinator: InferenceCoordinator
    let keys = InMemoryAPIKeyStore()
    let log = LogSink()

    init(engine: FakeEngine = FakeEngine(), loaded: Bool = true) async throws {
        self.engine = engine
        coordinator = InferenceCoordinator(engine: engine)
        if loaded { try await coordinator.load(ModelReference(id: "mlx-community/Test-4bit", directory: URL(fileURLWithPath: "/tmp"))) }
    }

    func app(_ config: APIServerConfiguration = .init()) -> some ApplicationProtocol {
        let coordinator = self.coordinator, log = self.log
        let deps = APIServerDependencies(
            coordinator: coordinator,
            installedModels: { ["mlx-community/Test-4bit", "mlx-community/Other-4bit"] },
            loadModel: { id in _ = try await coordinator.load(ModelReference(id: id, directory: URL(fileURLWithPath: "/tmp"))) },
            defaultModel: { "mlx-community/Test-4bit" },
            keys: keys, log: { log.add($0) })
        return Application(router: APIRoutes.router(deps, configuration: config))
    }
}

func jsonBody(_ s: String) -> ByteBuffer { ByteBuffer(string: s) }
let jsonHeaders: HTTPFields = [.contentType: "application/json"]
func object(_ b: ByteBuffer) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(buffer: b)) as? [String: Any])
}

@Suite struct APIServerTests {
    @Test func listsInstalledModels() async throws {
        let h = try await Harness()
        try await h.app().test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get) { r in
                #expect(r.status == .ok)
                let o = try object(r.body)
                #expect(o["object"] as? String == "list")
                let data = try #require(o["data"] as? [[String: Any]])
                #expect(data.map { $0["id"] as? String } == ["mlx-community/Test-4bit", "mlx-community/Other-4bit"])
                #expect(data.first?["object"] as? String == "model")
            }
        }
    }

    @Test func nonStreamingCompletionSchema() async throws {
        let h = try await Harness()
        try await h.app().test(.router) { client in
            let body = #"{"model":"mlx-community/Test-4bit","messages":[{"role":"system","content":"Be brief."},{"role":"user","content":[{"type":"text","text":"Hi"}]}],"temperature":0.2,"max_tokens":50,"seed":3}"#
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: jsonHeaders, body: jsonBody(body)) { r in
                #expect(r.status == .ok)
                #expect(r.headers[.contentType] == "application/json")
                let o = try object(r.body)
                #expect(o["object"] as? String == "chat.completion")
                #expect((o["id"] as? String)?.hasPrefix("chatcmpl-") == true)
                #expect(o["model"] as? String == "mlx-community/Test-4bit")
                let choice = try #require((o["choices"] as? [[String: Any]])?.first)
                #expect(choice["finish_reason"] as? String == "stop")
                let message = try #require(choice["message"] as? [String: Any])
                #expect(message["role"] as? String == "assistant")
                #expect(message["content"] as? String == "Hello, world!")
                let usage = try #require(o["usage"] as? [String: Int])
                #expect(usage == ["prompt_tokens": 7, "completion_tokens": 4, "total_tokens": 11])
            }
        }
        let req = try #require(await h.engine.lastRequest)
        #expect(req.messages.map(\.role) == [.system, .user])
        #expect(req.parameters.temperature == 0.2)
        #expect(req.parameters.maxTokens == 50)
        #expect(req.parameters.seed == 3)
        #expect(req.client == .api)
        #expect(h.log.records.withLock { $0.last?.status } == 200)
        #expect(h.log.records.withLock { $0.last?.completionTokens } == 4)
    }

    @Test func streamingUsesSSEFramingAndEndsWithDone() async throws {
        let h = try await Harness()
        try await h.app().test(.router) { client in
            let body = #"{"messages":[{"role":"user","content":"Hi"}],"stream":true,"stream_options":{"include_usage":true}}"#
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: jsonHeaders, body: jsonBody(body)) { r in
                #expect(r.status == .ok)
                #expect(r.headers[.contentType] == "text/event-stream")
                let text = String(buffer: r.body)
                let events = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
                #expect(events.allSatisfy { $0.hasPrefix("data: ") })
                #expect(events.last == "data: [DONE]")
                let chunks = try events.dropLast().map { e -> [String: Any] in
                    try #require(try JSONSerialization.jsonObject(with: Data(e.dropFirst(6).utf8)) as? [String: Any])
                }
                #expect(chunks.allSatisfy { $0["object"] as? String == "chat.completion.chunk" })
                let ids = Set(chunks.compactMap { $0["id"] as? String })
                #expect(ids.count == 1)
                let deltas = chunks.compactMap { ($0["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] }
                #expect(deltas.first?["role"] as? String == "assistant")
                #expect(deltas.compactMap { $0["content"] as? String }.joined() == "Hello, world!")
                let finishes = chunks.compactMap { ($0["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String }
                #expect(finishes == ["stop"])
                let usage = chunks.last?["usage"] as? [String: Int]
                #expect(usage?["total_tokens"] == 11)
            }
        }
    }

    @Test func stopSequencesCutOutput() async throws {
        let h = try await Harness(engine: FakeEngine(tokens: ["one ", "two", " END", " three"]))
        try await h.app().test(.router) { client in
            let body = #"{"messages":[{"role":"user","content":"count"}],"stop":"END"}"#
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: jsonHeaders, body: jsonBody(body)) { r in
                let o = try object(r.body)
                let content = ((o["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
                #expect(content == "one two ")
            }
        }
    }

    @Test(arguments: [
        (#"{"messages":[]}"#, "messages"),
        (#"{"messages":[{"role":"user","content":"x"}],"n":2}"#, "n"),
        (#"{"messages":[{"role":"user","content":"x"}],"tools":[{"type":"function"}]}"#, "tools"),
        (#"{"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"x"}}]}]}"#, "messages"),
        (#"{"messages":[{"role":"user","content":"x"}],"temperature":5}"#, "temperature"),
        (#"{"messages":[{"role":"wizard","content":"x"}]}"#, "messages"),
        (#"{"messages":"nope"}"#, ""),
        (#"not json"#, ""),
    ])
    func invalidRequestsAreRejected(_ body: String, _ param: String) async throws {
        let h = try await Harness()
        try await h.app().test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: jsonHeaders, body: jsonBody(body)) { r in
                #expect(r.status == .badRequest)
                let e = try #require(try object(r.body)["error"] as? [String: Any])
                #expect(e["type"] as? String == "invalid_request_error")
                if !param.isEmpty { #expect(e["param"] as? String == param) }
            }
        }
        #expect(await h.engine.lastRequest == nil, "invalid requests never reach the engine")
    }

    @Test func unknownModelIs404() async throws {
        let h = try await Harness()
        try await h.app().test(.router) { client in
            let body = #"{"model":"nobody/missing","messages":[{"role":"user","content":"x"}]}"#
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: jsonHeaders, body: jsonBody(body)) { r in
                #expect(r.status == .notFound)
                let o = try object(r.body)
                #expect((o["error"] as? [String: Any])?["code"] as? String == "model_not_found")
            }
        }
    }

    @Test func installedModelIsLoadedOnDemandWhenIdle() async throws {
        let h = try await Harness()
        try await h.app().test(.router) { client in
            let body = #"{"model":"mlx-community/Other-4bit","messages":[{"role":"user","content":"x"}]}"#
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: jsonHeaders, body: jsonBody(body)) { r in
                #expect(r.status == .ok)
                let o = try object(r.body)
                #expect(o["model"] as? String == "mlx-community/Other-4bit")
            }
        }
        #expect(await h.coordinator.snapshot.model.loadedModel?.id == "mlx-community/Other-4bit")
    }

    @Test func modelSwitchingCanBeDisabled() async throws {
        let h = try await Harness()
        try await h.app(.init(allowModelSwitching: false)).test(.router) { client in
            let body = #"{"model":"mlx-community/Other-4bit","messages":[{"role":"user","content":"x"}]}"#
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: jsonHeaders, body: jsonBody(body)) { r in
                #expect(r.status == .badRequest)
            }
        }
        #expect(await h.coordinator.snapshot.model.loadedModel?.id == "mlx-community/Test-4bit")
    }

    @Test func noModelLoadedLoadsDefault() async throws {
        let h = try await Harness(loaded: false)
        try await h.app().test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: jsonHeaders,
                                     body: jsonBody(#"{"messages":[{"role":"user","content":"x"}]}"#)) { r in
                #expect(r.status == .ok)
            }
        }
    }

    @Test func oversizedBodyIsRejected() async throws {
        let h = try await Harness()
        let big = String(repeating: "a", count: 1_100_000)
        try await h.app().test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: jsonHeaders,
                                     body: jsonBody(#"{"messages":[{"role":"user","content":"\#(big)"}]}"#)) { r in
                #expect(r.status == .contentTooLarge, "got \(r.status) \(String(buffer: r.body).prefix(200))")
            }
        }
    }
}

@Suite struct APIAuthTests {
    @Test func localhostDefaultNeedsNoKey() async throws {
        let h = try await Harness()
        #expect(APIServerConfiguration().host == "127.0.0.1")
        #expect(!APIServerConfiguration().requiresKey)
        try await h.app().test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get) { #expect($0.status == .ok) }
        }
    }

    @Test func lanModeRequiresKeyAndBindsAllInterfaces() async throws {
        let config = APIServerConfiguration(exposure: .lan, port: 1234)
        #expect(config.host == "0.0.0.0")
        #expect(config.requiresKey)
        let h = try await Harness()
        let (secret, _) = try APIKeys.create(name: "laptop", in: h.keys)
        try await h.app(config).test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get) { r in
                #expect(r.status == .unauthorized)
                let o = try object(r.body)
                #expect((o["error"] as? [String: Any])?["code"] as? String == "invalid_api_key")
            }
            try await client.execute(uri: "/v1/models", method: .get, headers: [.authorization: "Bearer lx-wrong"]) {
                #expect($0.status == .unauthorized)
            }
            try await client.execute(uri: "/v1/models", method: .get, headers: [.authorization: "Bearer \(secret)"]) {
                #expect($0.status == .ok)
            }
        }
        #expect(h.log.records.withLock { $0.filter { $0.status == 401 }.count } == 2)
    }

    @Test func revokedKeyStopsWorking() async throws {
        let h = try await Harness()
        let (secret, record) = try APIKeys.create(name: "temp", in: h.keys)
        try h.keys.remove(id: record.id)
        try await h.app(.init(requireKeyOnLocalhost: true)).test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get, headers: [.authorization: "Bearer \(secret)"]) {
                #expect($0.status == .unauthorized)
            }
        }
    }

    @Test func keysAreHashedAndVerifiedExactly() throws {
        let store = InMemoryAPIKeyStore()
        let (secret, record) = try APIKeys.create(name: "k", in: store)
        #expect(secret.hasPrefix("lx-") && secret.count == 43)
        #expect(record.hash != secret && record.hash.count == 64)
        #expect(!(try store.all()).contains { $0.hash.contains(secret) })
        #expect(APIKeys.verify(secret, in: try store.all())?.id == record.id)
        #expect(APIKeys.verify(String(secret.dropLast()), in: try store.all()) == nil)
        #expect(APIKeys.generate() != APIKeys.generate())
    }

    @Test func portValidation() {
        #expect(APIServerConfiguration(port: 1234).isValidPort)
        #expect(!APIServerConfiguration(port: 80).isValidPort)
        #expect(!APIServerConfiguration(port: 70000).isValidPort)
    }
}

@Suite struct StopFilterTests {
    @Test func holdsBackPartialMatchesAcrossChunks() {
        var f = StopFilter(stops: ["<END>"])
        var out = f.feed("abc<E").0
        #expect(!out.contains("<"), "a possible stop prefix is held back")
        out += f.feed("N").0
        let r = f.feed("D>tail")
        out += r.0
        #expect(r.1)
        #expect(out == "abc")
        #expect(f.flush() == "")
    }

    @Test func noStopsPassesThrough() {
        var f = StopFilter(stops: [])
        #expect(f.feed("x").0 == "x")
    }

    @Test func falseStartIsReleased() {
        var f = StopFilter(stops: ["STOP"])
        var out = f.feed("ST").0
        out += f.feed("ART here").0
        out += f.flush()
        #expect(out == "START here")
    }
}

@Suite(.serialized) struct APIServerLifecycleTests {
    @Test func startStopAndPortConflict() async throws {
        let h = try await Harness()
        let deps = APIServerDependencies(coordinator: h.coordinator, installedModels: { [] }, loadModel: { _ in },
                                         defaultModel: { nil }, keys: h.keys, log: { _ in })
        let port = Int.random(in: 41000...49000)
        let a = APIServerController(deps: deps)
        await a.start(.init(port: port))
        for _ in 0..<100 { if case .running = await a.status { break }; try await Task.sleep(for: .milliseconds(20)) }
        #expect(await a.status == .running(host: "127.0.0.1", port: port))

        // Real HTTP request against the live socket.
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("\"list\""))

        let b = APIServerController(deps: deps)
        await b.start(.init(port: port))
        for _ in 0..<100 { if case .failed = await b.status { break }; try await Task.sleep(for: .milliseconds(20)) }
        guard case .failed(let message) = await b.status else { Issue.record("expected port conflict, got \(await b.status)"); return }
        #expect(message.contains("already in use"))

        await a.stop()
        #expect(await a.status == .stopped)
        await #expect(throws: (any Error).self) {
            _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        }
    }

    @Test func clientDisconnectCancelsGeneration() async throws {
        let engine = FakeEngine(tokens: Array(repeating: "x", count: 500), delay: .milliseconds(5))
        let h = try await Harness(engine: engine)
        let deps = APIServerDependencies(coordinator: h.coordinator, installedModels: { ["mlx-community/Test-4bit"] },
                                         loadModel: { _ in }, defaultModel: { nil }, keys: h.keys, log: { _ in })
        let port = Int.random(in: 41000...49000)
        let server = APIServerController(deps: deps)
        await server.start(.init(port: port))
        for _ in 0..<100 { if case .running = await server.status { break }; try await Task.sleep(for: .milliseconds(20)) }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"messages":[{"role":"user","content":"go"}],"stream":true}"#.utf8)
        let client = Task {
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            var n = 0
            for try await _ in bytes.lines { n += 1; if n >= 5 { break } }  // read a little, then hang up
            return n
        }
        _ = try await client.value
        for _ in 0..<100 where await engine.cancelled == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await engine.cancelled == 1)
        #expect(await h.coordinator.snapshot.activeClient == nil)
        await server.stop()
    }
}
