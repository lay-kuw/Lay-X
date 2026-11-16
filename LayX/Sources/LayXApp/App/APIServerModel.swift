import AppKit
import Foundation
import LayXCore
import LayXServer

/// MainActor state for the API Server screen and Settings → API Server.
/// Persisted (UserDefaults): enabled, port, require-key-on-localhost, allow-model-switching.
/// Deliberately NOT persisted: LAN exposure (must be re-enabled after every launch).
/// Secrets: Keychain (hashes only). Request log: memory only, metadata only.
@MainActor
@Observable
final class APIServerModel {
    private(set) var status: APIServerController.Status = .stopped
    private(set) var requests: [APIRequestRecord] = []
    private(set) var keys: [APIKeyRecord] = []
    private(set) var keyLastUsed: [String: Date] = [:]
    private(set) var startedAt: Date?
    var keyError: String?
    /// Secret shown once after creating a key.
    var revealedKey: (name: String, secret: String)?

    var port: Int { didSet { UserDefaults.standard.set(port, forKey: Keys.port) } }
    var requireKeyOnLocalhost: Bool { didSet { UserDefaults.standard.set(requireKeyOnLocalhost, forKey: Keys.requireKey); restartIfRunning() } }
    var allowModelSwitching: Bool { didSet { UserDefaults.standard.set(allowModelSwitching, forKey: Keys.allowSwitch); restartIfRunning() } }
    /// LAN exposure — session only.
    private(set) var exposeLAN = false

    enum Keys {
        static let enabled = "lx.api.enabled"
        static let port = "lx.api.port"
        static let requireKey = "lx.api.requireKeyLocalhost"
        static let allowSwitch = "lx.api.allowModelSwitching"
    }

    @ObservationIgnored private var controller: APIServerController!
    @ObservationIgnored private let keyStore: any APIKeyStoring

    init(coordinator: InferenceCoordinator, models: ModelLibrary) {
        let d = UserDefaults.standard
        port = d.object(forKey: Keys.port) as? Int ?? 1234
        requireKeyOnLocalhost = d.object(forKey: Keys.requireKey) as? Bool ?? false
        allowModelSwitching = d.object(forKey: Keys.allowSwitch) as? Bool ?? true
        keyStore = KeychainAPIKeyStore()
        let deps = APIServerDependencies(
            coordinator: coordinator,
            installedModels: { await MainActor.run { models.installed.map(\.id.description) } },
            loadModel: { id in
                let model = await MainActor.run { models.model(id) }
                guard let model else { throw InferenceError.modelNotFound(id) }
                _ = try await coordinator.load(model.reference)
            },
            defaultModel: { await MainActor.run { AppServices.defaultChatModel(in: models)?.id.description } },
            keys: keyStore,
            log: { [weak self] record in Task { @MainActor in self?.append(record) } })
        controller = APIServerController(deps: deps)
        reloadKeys()
        let controller = self.controller!
        Task { [weak self] in
            for await s in await controller.updates() {
                guard let self else { return }
                if case .running = s, self.startedAt == nil { self.startedAt = Date() }
                if case .running = s {} else { self.startedAt = nil }
                self.status = s
            }
        }
        if d.bool(forKey: Keys.enabled) { start() }
    }

    var isRunning: Bool { if case .running = status { true } else { false } }
    var configuration: APIServerConfiguration {
        APIServerConfiguration(exposure: exposeLAN ? .lan : .localhost, port: port,
                               requireKeyOnLocalhost: requireKeyOnLocalhost, allowModelSwitching: allowModelSwitching)
    }
    var host: String { configuration.host }
    var baseURL: String { "http://\(exposeLAN ? (Self.lanAddress() ?? "0.0.0.0") : "127.0.0.1"):\(port)/v1" }

    func start() {
        UserDefaults.standard.set(true, forKey: Keys.enabled)
        let config = configuration
        Task { await controller.start(config) }
    }

    func stop() {
        UserDefaults.standard.set(false, forKey: Keys.enabled)
        Task { await controller.stop() }
    }

    /// Graceful stop on quit (keeps the "enabled" preference).
    func shutdown() async { await controller.stop() }

    private func restartIfRunning() {
        guard isRunning || status == .starting else { return }
        let config = configuration
        Task { await controller.start(config) }
    }

    func setPort(_ value: Int) {
        guard value != port else { return }
        port = value
        restartIfRunning()
    }

    /// Enabling LAN requires at least one API key (created on the spot if needed by the UI).
    func setLAN(_ on: Bool) {
        exposeLAN = on
        restartIfRunning()
    }

    // MARK: Keys

    func reloadKeys() {
        do { keys = try keyStore.all(); keyError = nil } catch { keyError = (error as? LocalizedError)?.errorDescription }
    }

    @discardableResult
    func createKey(name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let (secret, _) = try APIKeys.create(name: n.isEmpty ? "key \(keys.count + 1)" : n, in: keyStore)
            revealedKey = (n.isEmpty ? "key \(keys.count + 1)" : n, secret)
            reloadKeys()
            return true
        } catch {
            keyError = (error as? LocalizedError)?.errorDescription ?? "The key couldn’t be saved to the Keychain."
            return false
        }
    }

    func revoke(_ id: String) {
        do { try keyStore.remove(id: id); reloadKeys() } catch { keyError = (error as? LocalizedError)?.errorDescription }
    }

    /// Rotation = new key with the same name, then revoke the old one.
    func rotate(_ record: APIKeyRecord) {
        if createKey(name: record.name) { revoke(record.id) }
    }

    // MARK: Log & stats (memory only)

    private func append(_ r: APIRequestRecord) {
        requests.insert(r, at: 0)
        if requests.count > 500 { requests.removeLast(requests.count - 500) }
        if let k = r.keyName { keyLastUsed[k] = r.date }
    }

    var errorRate: Double? {
        guard !requests.isEmpty else { return nil }
        return Double(requests.filter { $0.status >= 400 }.count) / Double(requests.count)
    }
    var p50Latency: Double? {
        Stats.median(requests.filter { $0.path == "/v1/chat/completions" && $0.status == 200 }.map(\.durationMs))
    }
    var tokensOut: Int { requests.reduce(0) { $0 + ($1.completionTokens ?? 0) } }

    /// Requests per minute for the last 24 minutes (oldest first).
    var perMinute: [Int] {
        let now = Date()
        var buckets = [Int](repeating: 0, count: 24)
        for r in requests {
            let m = Int(now.timeIntervalSince(r.date) / 60)
            if m < 24 { buckets[23 - m] += 1 }
        }
        return buckets
    }

    struct ClientSummary: Identifiable {
        var id: String { name + agent }
        var name: String
        var agent: String
        var count: Int
        var lastSeen: Date
    }

    var clients: [ClientSummary] {
        var map: [String: ClientSummary] = [:]
        for r in requests {
            let agent = r.userAgent ?? "unknown"
            let product = agent.split(separator: " ").first.map(String.init) ?? agent
            let name = product.split(separator: "/").first.map(String.init) ?? product
            let key = "\(r.client)|\(product)"
            if var c = map[key] { c.count += 1; c.lastSeen = max(c.lastSeen, r.date); map[key] = c }
            else { map[key] = ClientSummary(name: name, agent: "\(product) · \(r.client)", count: 1, lastSeen: r.date) }
        }
        return map.values.sorted { $0.count > $1.count }
    }

    func count(path: String) -> Int { requests.filter { $0.path == path }.count }

    /// First non-loopback IPv4 address (shown in the base URL when LAN is on).
    static func lanAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}
