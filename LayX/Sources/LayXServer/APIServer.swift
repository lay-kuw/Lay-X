import Foundation
import Hummingbird
import LayXCore
import Logging
import Synchronization

/// OpenAI-compatible HTTP API on the shared inference coordinator.
///
/// Supported: `GET /v1/models`, `POST /v1/chat/completions` (streaming + non-streaming), text messages,
/// `temperature`, `top_p`, `max_tokens` / `max_completion_tokens`, `stop`, `seed`, `repetition_penalty`,
/// `stream_options.include_usage`, `chat_template_kwargs.enable_thinking`.
/// Not supported (rejected with 400): `n > 1`, tools / function calling, image/audio parts, `logprobs`,
/// `response_format` other than `text`. `frequency_penalty` / `presence_penalty` are accepted and ignored.
/// Not implemented: `/v1/completions`, `/v1/embeddings`, assistants, files, moderation.
public struct APIServerConfiguration: Sendable, Equatable {
    public enum Exposure: String, Sendable, Codable { case localhost, lan }
    public var exposure: Exposure
    public var port: Int
    /// Require a key on localhost too (always required on LAN).
    public var requireKeyOnLocalhost: Bool
    public var maxBodyBytes: Int
    public var maxConcurrentRequests: Int
    /// Allow a request's `model` field to load a different installed model.
    public var allowModelSwitching: Bool

    public init(exposure: Exposure = .localhost, port: Int = 1234, requireKeyOnLocalhost: Bool = false,
                maxBodyBytes: Int = 1 << 20, maxConcurrentRequests: Int = 8, allowModelSwitching: Bool = true) {
        self.allowModelSwitching = allowModelSwitching
        self.exposure = exposure
        self.port = port
        self.requireKeyOnLocalhost = requireKeyOnLocalhost
        self.maxBodyBytes = maxBodyBytes
        self.maxConcurrentRequests = maxConcurrentRequests
    }

    /// 127.0.0.1 unless LAN was explicitly enabled.
    public var host: String { exposure == .lan ? "0.0.0.0" : "127.0.0.1" }
    /// LAN mode always requires an API key.
    public var requiresKey: Bool { exposure == .lan || requireKeyOnLocalhost }
    public var isValidPort: Bool { (1024...65535).contains(port) }
}

/// Metadata about one request (never prompt or completion text).
public struct APIRequestRecord: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public var date: Date
    public var method: String
    public var path: String
    public var status: Int
    public var model: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var durationMs: Double
    public var client: String
    public var keyName: String?
    public var stream: Bool
    /// `User-Agent` header (client identification only).
    public var userAgent: String? = nil
}

/// What the server needs from the app. Closures keep LayXServer independent of UI and model storage.
public struct APIServerDependencies: Sendable {
    public var coordinator: InferenceCoordinator
    /// Installed model ids (served by `/v1/models`).
    public var installedModels: @Sendable () async -> [String]
    /// Loads an installed model by id (called only when the coordinator is idle).
    public var loadModel: @Sendable (String) async throws -> Void
    /// Model to load when nothing is loaded and the request doesn't name one.
    public var defaultModel: @Sendable () async -> String?
    public var keys: any APIKeyStoring
    public var log: @Sendable (APIRequestRecord) -> Void

    public init(coordinator: InferenceCoordinator, installedModels: @escaping @Sendable () async -> [String],
                loadModel: @escaping @Sendable (String) async throws -> Void, defaultModel: @escaping @Sendable () async -> String?,
                keys: any APIKeyStoring, log: @escaping @Sendable (APIRequestRecord) -> Void) {
        self.coordinator = coordinator
        self.installedModels = installedModels
        self.loadModel = loadModel
        self.defaultModel = defaultModel
        self.keys = keys
        self.log = log
    }
}

public struct APIRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    public let remoteAddress: String
    public var keyName: String?
    public var maxUploadSize: Int { 1 << 20 }

    public init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        remoteAddress = source.channel.remoteAddress?.ipAddress ?? "local"
    }
}

struct APIError: Error {
    var status: HTTPResponse.Status
    var message: String
    var type: String
    var code: String?
    var param: String?

    static func invalid(_ message: String, param: String? = nil) -> APIError {
        APIError(status: .badRequest, message: message, type: "invalid_request_error", code: nil, param: param)
    }
}

/// Builds the router (also used directly by tests).
public enum APIRoutes {
    public static func router(_ deps: APIServerDependencies, configuration: APIServerConfiguration) -> Router<APIRequestContext> {
        let router = Router(context: APIRequestContext.self)
        let inFlight = Mutex(0)
        router.add(middleware: AuthMiddleware(deps: deps, configuration: configuration))

        router.get("/v1/models") { request, context -> Response in
            let ids = await deps.installedModels()
            deps.log(APIRequestRecord(date: Date(), method: "GET", path: "/v1/models", status: 200, model: nil, promptTokens: nil,
                                      completionTokens: nil, durationMs: 0, client: context.remoteAddress, keyName: context.keyName,
                                      stream: false, userAgent: request.headers[.userAgent].map { String($0.prefix(120)) }))
            let created = Int(Date().timeIntervalSince1970)
            return json(OpenAI.ModelList(data: ids.map { OpenAI.ModelList.Model(id: $0, created: created) }))
        }

        router.post("/v1/chat/completions") { request, context -> Response in
            let started = ContinuousClock.now
            var record = APIRequestRecord(date: Date(), method: "POST", path: "/v1/chat/completions", status: 200, model: nil,
                                          promptTokens: nil, completionTokens: nil, durationMs: 0, client: context.remoteAddress,
                                          keyName: context.keyName, stream: false,
                                          userAgent: request.headers[.userAgent].map { String($0.prefix(120)) })
            func finish(_ status: Int) { complete(record, status: status, started: started, deps: deps) }
            let admitted = inFlight.withLock { n -> Bool in
                guard n < configuration.maxConcurrentRequests else { return false }
                n += 1
                return true
            }
            guard admitted else {
                finish(429)
                return errorResponse(APIError(status: .tooManyRequests, message: "Too many concurrent requests.",
                                              type: "rate_limit_error", code: "too_many_requests"))
            }
            var releaseInStream = false
            defer { if !releaseInStream { inFlight.withLock { $0 -= 1 } } }
            do {
                let body = try await request.body.collect(upTo: configuration.maxBodyBytes)
                let decoder = JSONDecoder()
                let parsed: OpenAI.ChatCompletionRequest
                do {
                    parsed = try decoder.decode(OpenAI.ChatCompletionRequest.self, from: body)
                } catch {
                    throw APIError.invalid("Request body is not a valid chat completion request: \(Self.describe(decodingError: error))")
                }
                let (genRequest, stops) = try validate(parsed)
                let modelID = try await resolveModel(parsed.model, deps: deps, allowSwitching: configuration.allowModelSwitching)
                record.model = modelID
                let id = "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
                let created = Int(Date().timeIntervalSince1970)

                if parsed.stream == true {
                    record.stream = true
                    releaseInStream = true
                    let baseRecord = record
                    let includeUsage = parsed.stream_options?.include_usage == true
                    let stream = deps.coordinator.generate(genRequest)
                    var headers = HTTPFields()
                    headers[.contentType] = "text/event-stream"
                    headers[.cacheControl] = "no-cache"
                    return Response(status: .ok, headers: headers, body: ResponseBody { writer in
                        defer { inFlight.withLock { $0 -= 1 } }
                        var streamRecord = baseRecord
                        var filter = StopFilter(stops: stops)
                        var usage: OpenAI.Usage?
                        var reason = "stop"
                        func chunk(_ delta: OpenAI.ChatCompletionChunk.Delta, finish: String?, usage: OpenAI.Usage? = nil, choices: Bool = true) -> ByteBuffer {
                            let c = OpenAI.ChatCompletionChunk(
                                id: id, created: created, model: modelID,
                                choices: choices ? [.init(index: 0, delta: delta, finish_reason: finish)] : [], usage: usage)
                            return sse(c)
                        }
                        do {
                            try await writer.write(chunk(.init(role: "assistant", content: ""), finish: nil))
                            streamLoop: for try await event in stream {
                                switch event {
                                case .text(let t):
                                    let (out, hit) = filter.feed(t)
                                    if !out.isEmpty { try await writer.write(chunk(.init(content: out), finish: nil)) }
                                    if hit { reason = "stop"; break streamLoop }
                                case .finished(let m):
                                    let tail = filter.flush()
                                    if !tail.isEmpty { try await writer.write(chunk(.init(content: tail), finish: nil)) }
                                    reason = OpenAI.finishReason(m.stopReason)
                                    usage = .init(prompt_tokens: m.promptTokens, completion_tokens: m.generatedTokens,
                                                  total_tokens: m.promptTokens + m.generatedTokens)
                                }
                            }
                            try await writer.write(chunk(.init(), finish: reason))
                            if includeUsage, let usage { try await writer.write(chunk(.init(), finish: nil, usage: usage, choices: false)) }
                            try await writer.write(ByteBuffer(string: "data: [DONE]\n\n"))
                            try await writer.finish(nil)
                            streamRecord.promptTokens = usage?.prompt_tokens
                            streamRecord.completionTokens = usage?.completion_tokens
                            complete(streamRecord, status: 200, started: started, deps: deps)
                        } catch {
                            // Client went away (write failed) or generation failed mid-stream. Leaving the loop drops
                            // the generation stream, which cancels the generation.
                            if let api = mapError(error) {
                                try? await writer.write(sse(OpenAI.ErrorBody(error: .init(message: api.message, type: api.type, param: nil, code: api.code))))
                                try? await writer.finish(nil)
                                complete(streamRecord, status: Int(api.status.code), started: started, deps: deps)
                            } else {
                                complete(streamRecord, status: 499, started: started, deps: deps)
                            }
                        }
                    })
                }

                var text = ""
                var metrics: GenerationMetrics?
                var filter = StopFilter(stops: stops)
                loop: for try await event in deps.coordinator.generate(genRequest) {
                    switch event {
                    case .text(let t):
                        let (out, hit) = filter.feed(t)
                        text += out
                        if hit { break loop }
                    case .finished(let m):
                        text += filter.flush()
                        metrics = m
                    }
                }
                let usage = OpenAI.Usage(prompt_tokens: metrics?.promptTokens ?? 0, completion_tokens: metrics?.generatedTokens ?? 0,
                                         total_tokens: (metrics?.promptTokens ?? 0) + (metrics?.generatedTokens ?? 0))
                record.promptTokens = usage.prompt_tokens
                record.completionTokens = usage.completion_tokens
                finish(200)
                return json(OpenAI.ChatCompletion(
                    id: id, created: created, model: modelID,
                    choices: [.init(index: 0, message: .init(role: "assistant", content: text),
                                    finish_reason: metrics == nil ? "stop" : OpenAI.finishReason(metrics?.stopReason))],
                    usage: usage))
            } catch {
                let api = mapError(error) ?? APIError(status: .internalServerError, message: "Internal error.", type: "server_error")
                finish(Int(api.status.code))
                return errorResponse(api)
            }
        }
        return router
    }

    static func complete(_ record: APIRequestRecord, status: Int, started: ContinuousClock.Instant, deps: APIServerDependencies) {
        var r = record
        r.status = status
        r.durationMs = (ContinuousClock.now - started).milliseconds
        deps.log(r)
    }

    // MARK: Validation

    static func validate(_ r: OpenAI.ChatCompletionRequest) throws -> (GenerationRequest, [String]) {
        if let n = r.n, n != 1 { throw APIError.invalid("Only n = 1 is supported.", param: "n") }
        if r.tools != nil || r.functions != nil || r.tool_choice != nil {
            throw APIError.invalid("Tool and function calling are not supported by Lay X.", param: "tools")
        }
        if r.logprobs == true { throw APIError.invalid("logprobs are not supported.", param: "logprobs") }
        if let f = r.response_format, f.type != "text" { throw APIError.invalid("Only response_format type \"text\" is supported.", param: "response_format") }
        guard !r.messages.isEmpty else { throw APIError.invalid("messages must not be empty.", param: "messages") }
        guard r.messages.count <= 500 else { throw APIError.invalid("Too many messages (max 500).", param: "messages") }
        var messages: [PromptMessage] = []
        for (i, m) in r.messages.enumerated() {
            let role: ChatRole
            switch m.role {
            case "system", "developer": role = .system
            case "user": role = .user
            case "assistant": role = .assistant
            default: throw APIError.invalid("Unsupported role “\(m.role)” in messages[\(i)].", param: "messages")
            }
            if m.content?.hasNonTextParts == true {
                throw APIError.invalid("Only text content is supported (messages[\(i)]).", param: "messages")
            }
            messages.append(PromptMessage(role: role, content: m.content?.text ?? ""))
        }
        if let t = r.temperature, !(0...2).contains(t) { throw APIError.invalid("temperature must be between 0 and 2.", param: "temperature") }
        if let p = r.top_p, !(0...1).contains(p) { throw APIError.invalid("top_p must be between 0 and 1.", param: "top_p") }
        let maxTokens = r.max_completion_tokens ?? r.max_tokens ?? 2048
        guard maxTokens >= 1 else { throw APIError.invalid("max_tokens must be at least 1.", param: "max_tokens") }
        let stops = (r.stop?.values ?? []).filter { !$0.isEmpty }
        guard stops.count <= 4 else { throw APIError.invalid("At most 4 stop sequences are supported.", param: "stop") }
        let params = GenerationParameters(temperature: r.temperature ?? 0.7, topP: r.top_p ?? 0.95,
                                          maxTokens: min(maxTokens, 32_768), repetitionPenalty: r.repetition_penalty, seed: r.seed)
        return (GenerationRequest(messages: messages, parameters: params, client: .api, thinking: r.chat_template_kwargs?.enable_thinking), stops)
    }

    static func resolveModel(_ requested: String?, deps: APIServerDependencies, allowSwitching: Bool = true) async throws -> String {
        let snapshot = await deps.coordinator.snapshot
        let loaded = snapshot.model.loadedModel?.id
        let name = requested?.trimmingCharacters(in: .whitespaces)
        if name == nil || name == "" || name == "default" || name == loaded {
            if let loaded { return loaded }
            guard let fallback = await deps.defaultModel() else {
                throw APIError(status: .serviceUnavailable, message: "No model is installed in Lay X.", type: "server_error", code: "model_not_loaded")
            }
            try await deps.loadModel(fallback)
            return fallback
        }
        guard let name, await deps.installedModels().contains(name) else {
            throw APIError(status: .notFound, message: "The model “\(requested ?? "")” is not installed in Lay X.",
                           type: "invalid_request_error", code: "model_not_found", param: "model")
        }
        guard allowSwitching || loaded == nil else {
            throw APIError(status: .badRequest, message: "Model switching via the model field is disabled. The loaded model is “\(loaded ?? "")”.",
                           type: "invalid_request_error", code: "model_switching_disabled", param: "model")
        }
        // Switching models would cancel other users' generations; only do it when idle.
        guard snapshot.activeClient == nil, snapshot.queuedCount == 0 else {
            throw APIError(status: .serviceUnavailable, message: "Another model is busy. Retry shortly or use “\(loaded ?? "default")”.",
                           type: "server_error", code: "model_busy")
        }
        try await deps.loadModel(name)
        return name
    }

    // MARK: Helpers

    static func mapError(_ error: Error) -> APIError? {
        switch error {
        case let e as APIError: return e
        case is CancellationError: return nil
        case let e as any HTTPResponseError where e.status == .contentTooLarge:
            // e.g. NIOTooManyBytesError from `collect(upTo:)`
            return APIError(status: .contentTooLarge, message: "Request body is too large (max 1 MB).", type: "invalid_request_error", code: "body_too_large")
        case let e as any HTTPResponseError:
            return APIError(status: e.status, message: "Request error.", type: "invalid_request_error")
        case let e as InferenceError:
            switch e {
            case .noModelLoaded, .modelNotFound:
                return APIError(status: .serviceUnavailable, message: e.errorDescription ?? "", type: "server_error", code: "model_not_loaded")
            case .queueFull:
                return APIError(status: .tooManyRequests, message: e.errorDescription ?? "", type: "rate_limit_error", code: "queue_full")
            case .lifecycleChanged:
                return APIError(status: .serviceUnavailable, message: e.errorDescription ?? "", type: "server_error", code: "model_changed")
            case .insufficientMemory, .unsupportedModel, .loadFailed:
                return APIError(status: .serviceUnavailable, message: e.errorDescription ?? "", type: "server_error", code: "model_load_failed")
            case .generationFailed:
                return APIError(status: .badRequest, message: e.errorDescription ?? "", type: "invalid_request_error", code: "generation_failed")
            }
        default:
            if "\(error)".contains("tooLarge") || "\(error)".contains("TooLarge") {
                return APIError(status: .contentTooLarge, message: "Request body is too large (max 1 MB).", type: "invalid_request_error", code: "body_too_large")
            }
            return APIError(status: .internalServerError, message: "Internal error.", type: "server_error")
        }
    }

    static func describe(decodingError: Error) -> String {
        guard let e = decodingError as? DecodingError else { return "malformed JSON" }
        switch e {
        case .keyNotFound(let key, _): return "missing field “\(key.stringValue)”"
        case .typeMismatch(_, let c), .valueNotFound(_, let c):
            return "wrong type at “\(c.codingPath.map(\.stringValue).joined(separator: "."))”"
        case .dataCorrupted: return "malformed JSON"
        @unknown default: return "malformed JSON"
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    static func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    static func sse<T: Encodable>(_ value: T) -> ByteBuffer {
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        var buffer = ByteBuffer(string: "data: ")
        buffer.writeBytes(data)
        buffer.writeString("\n\n")
        return buffer
    }

    static func errorResponse(_ e: APIError) -> Response {
        json(OpenAI.ErrorBody(error: .init(message: e.message, type: e.type, param: e.param, code: e.code)), status: e.status)
    }
}

/// Bearer-token authentication. Required on LAN (and on localhost when configured).
struct AuthMiddleware: RouterMiddleware {
    typealias Context = APIRequestContext
    let deps: APIServerDependencies
    let configuration: APIServerConfiguration

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard configuration.requiresKey else { return try await next(request, context) }
        let header = request.headers[.authorization] ?? ""
        let token = header.hasPrefix("Bearer ") ? String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces) : ""
        guard !token.isEmpty, let record = APIKeys.verify(token, in: (try? deps.keys.all()) ?? []) else {
            deps.log(APIRequestRecord(date: Date(), method: request.method.rawValue, path: request.uri.path, status: 401, model: nil,
                                      promptTokens: nil, completionTokens: nil, durationMs: 0, client: context.remoteAddress,
                                      keyName: nil, stream: false, userAgent: request.headers[.userAgent].map { String($0.prefix(120)) }))
            var r = APIRoutes.errorResponse(APIError(status: .unauthorized, message: "Missing or invalid API key. Send “Authorization: Bearer <key>”.",
                                                     type: "invalid_request_error", code: "invalid_api_key"))
            r.headers[.wwwAuthenticate] = "Bearer"
            return r
        }
        var ctx = context
        ctx.keyName = record.name
        return try await next(request, ctx)
    }
}

/// Cuts output at the first stop sequence, holding back text that might be the start of one.
struct StopFilter {
    let stops: [String]
    private var pending = ""
    private var stopped = false

    init(stops: [String]) { self.stops = stops }

    /// Returns text safe to emit, and whether a stop sequence was hit.
    mutating func feed(_ text: String) -> (String, Bool) {
        guard !stopped else { return ("", true) }
        guard !stops.isEmpty else { return (text, false) }
        pending += text
        if let r = stops.compactMap({ pending.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            let out = String(pending[..<r.lowerBound])
            pending = ""
            stopped = true
            return (out, true)
        }
        let hold = (stops.map(\.count).max() ?? 1) - 1
        guard pending.count > hold else { return ("", false) }
        let cut = pending.index(pending.endIndex, offsetBy: -hold)
        let out = String(pending[..<cut])
        pending = String(pending[cut...])
        return (out, false)
    }

    mutating func flush() -> String {
        defer { pending = "" }
        return stopped ? "" : pending
    }
}

// MARK: - Server lifecycle

/// Starts and stops the HTTP server. One instance per app.
public actor APIServerController {
    public enum Status: Sendable, Equatable {
        case stopped
        case starting
        case running(host: String, port: Int)
        case failed(String)
    }

    public private(set) var status: Status = .stopped
    private var task: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<Status>.Continuation] = [:]
    private let deps: APIServerDependencies

    public init(deps: APIServerDependencies) { self.deps = deps }

    public func updates() -> AsyncStream<Status> {
        let (stream, c) = AsyncStream.makeStream(of: Status.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = c
        c.yield(status)
        c.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func set(_ s: Status) {
        status = s
        for c in observers.values { c.yield(s) }
    }

    /// Starts (or restarts) with `configuration`. Port conflicts and bind failures are reported in `status`.
    public func start(_ configuration: APIServerConfiguration) async {
        await stop()
        guard configuration.isValidPort else { set(.failed("Port must be between 1024 and 65535.")); return }
        set(.starting)
        let router = APIRoutes.router(deps, configuration: configuration)
        let host = configuration.host, port = configuration.port
        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port), serverName: "LayX", reuseAddress: false),
            onServerRunning: { [weak self] _ in await self?.set(.running(host: host, port: port)) },
            logger: { var l = Logger(label: "app.layx.api"); l.logLevel = .critical; return l }())
        task = Task { [weak self] in
            do {
                try await app.run()
                await self?.didExit(error: nil)
            } catch {
                await self?.didExit(error: error)
            }
        }
    }

    private func didExit(error: Error?) {
        guard let error else { if case .running = status { set(.stopped) }; return }
        let text = "\(error)"
        if text.contains("Address already in use") || text.contains("errno: 48") || text.contains("EADDRINUSE") {
            set(.failed("That port is already in use by another app. Choose a different port."))
        } else if text.contains("Permission denied") || text.contains("errno: 13") {
            set(.failed("macOS refused to open the port (permission denied)."))
        } else if case .stopped = status {
            // Stopped deliberately.
        } else {
            set(.failed("The server stopped unexpectedly."))
        }
    }

    /// Graceful stop: cancels the server task (in-flight streams are cancelled, which cancels their generations).
    public func stop() async {
        guard let task else { return }
        self.task = nil
        set(.stopped)
        task.cancel()
        await task.value
    }
}
