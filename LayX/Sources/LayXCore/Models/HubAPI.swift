import Foundation

/// Minimal read-only client for the Hugging Face Hub metadata API. Only model metadata and files are
/// fetched; nothing about the user (prompts, chats, files) is ever sent.
public struct HubAPI: Sendable {
    public var endpoint: URL
    public var session: URLSession

    public init(endpoint: URL = URL(string: "https://huggingface.co")!, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public enum Sort: String, Sendable, CaseIterable, Identifiable {
        case trending = "trendingScore", downloads, likes, updated = "lastModified", newest = "createdAt"
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .trending: "Trending"
            case .downloads: "Downloads"
            case .likes: "Likes"
            case .updated: "Updated"
            case .newest: "Newest"
            }
        }
    }

    public struct Page: Sendable {
        public var results: [HubModelSummary]
        /// Next page (from the `Link: <…>; rel="next"` header), restricted to the Hub host.
        public var next: URL?
    }

    /// One page of MLX models, sorted by `sort` (descending).
    public func searchPage(_ query: String, author: String? = "mlx-community", sort: Sort = .trending, limit: Int = 50) async throws -> Page {
        guard var c = URLComponents(url: endpoint.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false) else {
            throw ModelStoreError.network("invalid endpoint")
        }
        var items = [
            URLQueryItem(name: "filter", value: "mlx"),
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
        ]
        if let author { items.append(URLQueryItem(name: "author", value: author)) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "search", value: String(trimmed.prefix(100)))) }
        for e in ["config", "downloads", "likes", "trendingScore", "lastModified", "library_name", "pipeline_tag", "tags", "safetensors"] {
            items.append(URLQueryItem(name: "expand[]", value: e))
        }
        c.queryItems = items
        guard let url = c.url else { throw ModelStoreError.network("invalid search query") }
        return try await page(at: url)
    }

    /// Fetches a page by URL (first page or a `next` link).
    public func page(at url: URL) async throws -> Page {
        guard url.host == endpoint.host else { throw ModelStoreError.network("unexpected host") }
        let (data, response) = try await getWithResponse(url)
        let next = Self.nextLink(response.value(forHTTPHeaderField: "Link")).flatMap { $0.host == endpoint.host ? $0 : nil }
        return Page(results: try Self.parseSearch(data), next: next)
    }

    static func nextLink(_ header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") where part.contains("rel=\"next\"") {
            if let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">"), open < close {
                return URL(string: String(part[part.index(after: open)..<close]))
            }
        }
        return nil
    }

    /// Searches MLX conversions. `author` defaults to `mlx-community`, the established source of MLX weights.
    public func search(_ query: String, author: String? = "mlx-community", limit: Int = 40) async throws -> [HubModelSummary] {
        guard var c = URLComponents(url: endpoint.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false) else {
            throw ModelStoreError.network("invalid endpoint")
        }
        var items = [
            URLQueryItem(name: "filter", value: "mlx"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
        ]
        if let author { items.append(URLQueryItem(name: "author", value: author)) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "search", value: String(trimmed.prefix(100)))) }
        for e in ["config", "downloads", "lastModified", "library_name", "pipeline_tag", "tags", "safetensors"] {
            items.append(URLQueryItem(name: "expand[]", value: e))
        }
        c.queryItems = items
        guard let url = c.url else { throw ModelStoreError.network("invalid search query") }
        let data = try await get(url)
        return try Self.parseSearch(data)
    }

    /// Lists every file of `id` at `revision` (recursive).
    public func files(of id: ModelRepoID, revision: String = "main") async throws -> [HubFile] {
        let url = endpoint.appendingPathComponent("api/models/\(id.owner)/\(id.name)/tree/\(revision)")
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ModelStoreError.network("invalid endpoint") }
        c.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        guard let full = c.url else { throw ModelStoreError.network("invalid endpoint") }
        return try Self.parseTree(try await get(full))
    }

    /// Downloads a small file (e.g. `config.json`) into memory.
    public func smallFile(_ path: String, of id: ModelRepoID, revision: String = "main") async throws -> Data {
        try await get(fileURL(path, of: id, revision: revision))
    }

    public func fileURL(_ path: String, of id: ModelRepoID, revision: String = "main") -> URL {
        var url = endpoint.appendingPathComponent(id.owner).appendingPathComponent(id.name)
            .appendingPathComponent("resolve").appendingPathComponent(revision)
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        return url
    }

    private func getWithResponse(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("LayX", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ModelStoreError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ModelStoreError.http(status: 0) }
        guard (200..<300).contains(http.statusCode) else { throw ModelStoreError.http(status: http.statusCode) }
        return (data, http)
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("LayX", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ModelStoreError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ModelStoreError.http(status: status) }
        return data
    }

    // MARK: Parsing (pure, unit-tested)

    static func parseSearch(_ data: Data) throws -> [HubModelSummary] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return array.compactMap { item in
            guard let raw = item["id"] as? String, let id = ModelRepoID(raw) else { return nil }
            let config = item["config"] as? [String: Any] ?? [:]
            let parsed = ModelStore.parseConfig(config)
            let safetensors = item["safetensors"] as? [String: Any]
            return HubModelSummary(
                id: id, modelType: parsed.modelType, quantizationBits: parsed.bits,
                parameterCount: (safetensors?["total"] as? NSNumber)?.int64Value,
                downloads: item["downloads"] as? Int ?? 0,
                lastModified: (item["lastModified"] as? String).flatMap { iso.date(from: $0) },
                tags: item["tags"] as? [String] ?? [],
                libraryName: item["library_name"] as? String,
                pipelineTag: item["pipeline_tag"] as? String,
                likes: item["likes"] as? Int ?? 0,
                trendingScore: item["trendingScore"] as? Int ?? 0)
        }
    }

    static func parseTree(_ data: Data) throws -> [HubFile] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            guard item["type"] as? String == "file", let path = item["path"] as? String else { return nil }
            let lfs = item["lfs"] as? [String: Any]
            let size = (lfs?["size"] as? NSNumber)?.int64Value ?? (item["size"] as? NSNumber)?.int64Value ?? 0
            return HubFile(path: path, size: size, sha256: lfs?["oid"] as? String)
        }
    }

    /// The files an MLX LLM needs: weights, configs, tokenizer and chat template. Skips docs, images, other
    /// weight formats, and anything in subdirectories.
    public static func requiredFiles(_ all: [HubFile]) -> [HubFile] {
        let names: Set<String> = ["tokenizer.model", "merges.txt", "vocab.txt", "chat_template.jinja"]
        return all.filter { f in
            guard !f.path.contains("/") else { return false }
            let lower = f.path.lowercased()
            return lower.hasSuffix(".safetensors") || lower.hasSuffix(".json") || lower.hasSuffix(".tiktoken")
                || names.contains(lower)
        }
    }
}
