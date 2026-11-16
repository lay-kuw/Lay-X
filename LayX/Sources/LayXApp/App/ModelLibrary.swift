import Foundation
import LayXCore

/// MainActor state for the Models screen and every model picker (Chat, Mini Chat, Settings).
/// Wraps `ModelStore` (disk), `ModelDownloader` (network) and the shared `InferenceCoordinator` (memory).
@MainActor
@Observable
final class ModelLibrary {
    /// Installed language models (chat, Work, API).
    private(set) var installed: [InstalledModel] = []
    /// Installed image models (Image screen).
    private(set) var imageModels: [InstalledModel] = []
    private(set) var incomplete: [(id: ModelRepoID, bytes: Int64)] = []
    private(set) var downloads: [ModelRepoID: DownloadState] = [:]
    private(set) var searchResults: [HubModelSummary] = []
    private(set) var compatibility: [ModelRepoID: ModelCompatibility] = [:]
    private(set) var isSearching = false
    private(set) var searchError: String?
    private(set) var storageUsed: Int64 = 0
    private(set) var storageFree: Int64 = 0
    /// Most recent user-visible error or confirmation (shown as a toast).
    var notice: String?

    private(set) var store: ModelStore
    @ObservationIgnored private var downloader: ModelDownloader
    @ObservationIgnored private let hub = HubAPI()
    @ObservationIgnored private let coordinator: InferenceCoordinator
    @ObservationIgnored private let architectures: any ModelArchitectureSupport
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    static let lastUsedKey = "lx.modelLastUsed"

    init(store: ModelStore, coordinator: InferenceCoordinator, architectures: any ModelArchitectureSupport) {
        self.store = store
        self.coordinator = coordinator
        self.architectures = architectures
        downloader = ModelDownloader(store: store, architectures: architectures)
        refresh()
        watchDownloads()
    }

    private func watchDownloads() {
        watchTask?.cancel()
        watchTask = Task { [weak self, downloader] in
            for await states in await downloader.updates() {
                guard let self else { return }
                let finished = states.contains { id, s in s == .completed && self.downloads[id] != .completed }
                self.downloads = states
                if finished { self.refresh() }
            }
        }
    }

    // MARK: Storage location

    /// Switches the model directory. Models in the previous location are left untouched (switch back to use
    /// them). Refused while a download is running. The loaded model, if any, stays loaded (it is in memory).
    /// Returns an error message, or nil on success.
    func changeStorage(to chosen: URL?) -> String? {
        guard activeDownloads.isEmpty else { return "Wait for downloads to finish (or pause them) before moving storage." }
        let root: URL
        if let chosen {
            guard let r = try? ModelStore.root(forChosenFolder: chosen) else { return "That folder can’t be used for models." }
            root = r
            if let d = try? ModelStore.defaultRoot(), ModelStore.canonicalPath(d) == root.path {
                UserDefaults.standard.removeObject(forKey: AppServices.modelStorePathKey)
            } else {
                UserDefaults.standard.set(root.path, forKey: AppServices.modelStorePathKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: AppServices.modelStorePathKey)
            guard let r = try? ModelStore.defaultRoot() else { return "The default folder isn’t available." }
            root = r
        }
        store = ModelStore(root: root)
        downloader = ModelDownloader(store: store, architectures: architectures)
        downloads = [:]
        watchDownloads()
        refresh()
        notice = "Models are now stored in \((root.path as NSString).abbreviatingWithTildeInPath)."
        return nil
    }

    var isDefaultStorage: Bool { UserDefaults.standard.string(forKey: AppServices.modelStorePathKey) == nil }

    // MARK: Disk

    func refresh() {
        let store = self.store
        Task.detached(priority: .userInitiated) {
            let all = store.installedModels()
            let incomplete = store.incompleteDownloads()
            let used = store.totalUsage()
            let free = store.availableCapacity()
            await MainActor.run {
                self.installed = all.filter { !$0.isImageModel }
                self.imageModels = all.filter(\.isImageModel)
                self.incomplete = incomplete
                self.storageUsed = used
                self.storageFree = free
            }
        }
    }

    func model(_ id: String) -> InstalledModel? { installed.first { $0.id.description == id } }
    func imageModel(_ spec: ImageModelSpec) -> InstalledModel? { imageModels.first { $0.id == spec.id } }

    // MARK: Discovery

    var sort: HubAPI.Sort = .trending
    /// true = only mlx-community (curated conversions); false = every MLX repo on the Hub.
    var curatedOnly = true
    private(set) var pageNumber = 1
    private(set) var hasNextPage = false
    @ObservationIgnored private var pageURLs: [URL?] = [nil]   // index = pageNumber - 1 (nil = first page)
    @ObservationIgnored private var nextURL: URL?
    @ObservationIgnored private var lastQuery = ""

    /// New search (resets to page 1). Debounced while typing.
    func search(_ query: String, debounce: Bool = true) {
        lastQuery = query
        pageURLs = [nil]
        pageNumber = 1
        load(pageURL: nil, debounce: debounce)
    }

    func nextPage() {
        guard let next = nextURL else { return }
        if pageURLs.count <= pageNumber { pageURLs.append(next) } else { pageURLs[pageNumber] = next }
        pageNumber += 1
        load(pageURL: next, debounce: false)
    }

    func previousPage() {
        guard pageNumber > 1 else { return }
        pageNumber -= 1
        load(pageURL: pageURLs[pageNumber - 1], debounce: false)
    }

    private func load(pageURL: URL?, debounce: Bool) {
        searchTask?.cancel()
        isSearching = true
        searchError = nil
        let query = lastQuery, sort = self.sort, author = curatedOnly ? "mlx-community" : nil
        searchTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            do {
                let page: HubAPI.Page
                if let pageURL {
                    page = try await hub.page(at: pageURL)
                } else {
                    page = try await hub.searchPage(query, author: author, sort: sort, limit: 50)
                }
                guard !Task.isCancelled else { return }
                let results = page.results.filter(\.isMLXLanguageModelRepo)
                var compat: [ModelRepoID: ModelCompatibility] = [:]
                for r in results {
                    if let type = r.modelType {
                        compat[r.id] = await architectures.supports(modelType: type) ? .compatible : .unsupportedArchitecture(type)
                    } else {
                        compat[r.id] = .unknown
                    }
                }
                searchResults = results
                compatibility.merge(compat) { $1 }
                nextURL = page.next
                hasNextPage = page.next != nil
            } catch is CancellationError {
                return
            } catch {
                searchError = (error as? LocalizedError)?.errorDescription ?? "Search failed."
            }
            isSearching = false
        }
    }

    // MARK: Downloads

    /// Starts or resumes a download. `kind` nil = decide: catalog image models, or a resumed download whose
    /// partial folder holds `model_index.json` (diffusers pipeline), are image models.
    func download(_ id: ModelRepoID, kind: ModelKind? = nil) {
        let partialIndex = store.partialDirectory(for: id).appendingPathComponent("model_index.json")
        let isImage = kind == .image || (kind == nil && (ImageModelSpec.spec(id.description) != nil
                                                         || FileManager.default.fileExists(atPath: partialIndex.path)))
        Task {
            do {
                let profile: DownloadProfile = isImage ? .imagePipeline : .languageModel
                let installed = try await downloader.download(id, profile: profile)
                notice = "\(isImage ? ImageModelSpec.spec(for: installed).name : ModelDisplay.name(id)) is ready."
            } catch is CancellationError {
                refresh()
            } catch {
                notice = (error as? LocalizedError)?.errorDescription ?? "Download failed."
                refresh()
            }
        }
    }

    func cancelDownload(_ id: ModelRepoID) {
        Task { await downloader.cancel(id) }
    }

    func discardPartial(_ id: ModelRepoID) {
        Task {
            await downloader.discardPartial(id)
            refresh()
        }
    }

    var activeDownloads: [(id: ModelRepoID, progress: DownloadProgress)] {
        downloads.compactMap { id, s in if case .active(let p) = s { (id, p) } else { nil } }.sorted { $0.id < $1.id }
    }

    // MARK: Lifecycle

    func load(_ model: InstalledModel) {
        Task {
            do {
                try await coordinator.load(model.reference)
                var used = UserDefaults.standard.dictionary(forKey: Self.lastUsedKey) as? [String: Double] ?? [:]
                used[model.id.description] = Date().timeIntervalSince1970
                UserDefaults.standard.set(used, forKey: Self.lastUsedKey)
            } catch {
                notice = (error as? LocalizedError)?.errorDescription ?? "The model couldn’t be loaded."
            }
        }
    }

    func unload() {
        Task { await coordinator.unload() }
    }

    func delete(_ id: ModelRepoID, loadedID: String?) {
        do {
            try store.delete(id, inUse: Set([loadedID].compactMap { $0 }))
            Task { await downloader.clearFinishedState(id) }
            notice = "Deleted \(ModelDisplay.name(id))."
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? "The model couldn’t be deleted."
        }
        refresh()
    }

    func lastUsed(_ id: ModelRepoID) -> Date? {
        (UserDefaults.standard.dictionary(forKey: Self.lastUsedKey) as? [String: Double])?[id.description]
            .map(Date.init(timeIntervalSince1970:))
    }
}

/// Human-readable labels derived from repository names, e.g. `Qwen3-30B-A3B-4bit` → "Qwen3 30B-A3B".
enum ModelDisplay {
    static func name(_ id: ModelRepoID) -> String {
        var n = id.name
        for suffix in ["-4bit", "-8bit", "-6bit", "-3bit", "-5bit", "-bf16", "-fp16", "-MLX", "-mlx", "-DWQ", "-qat"] {
            if let r = n.range(of: suffix, options: [.caseInsensitive, .backwards]) { n.removeSubrange(r.lowerBound...) ; break }
        }
        n = n.replacingOccurrences(of: "-Instruct", with: "").replacingOccurrences(of: "-it", with: "")
        // Keep MoE "30B-A3B" together, space elsewhere.
        var parts = n.split(separator: "-").map(String.init)
        var merged: [String] = []
        while !parts.isEmpty {
            let p = parts.removeFirst()
            if let next = parts.first, next.range(of: #"^A\d+(\.\d+)?B$"#, options: .regularExpression) != nil {
                merged.append("\(p)-\(next)")
                parts.removeFirst()
            } else {
                merged.append(p)
            }
        }
        return merged.joined(separator: " ")
    }

    /// Display name without the variant, plus the variant (e.g. `Qwen3.6-35B-A3B-OptiQ-4bit` →
    /// ("Qwen3.6 35B-A3B", "OptiQ")). The variant is what follows the parameter size, minus quantization tokens.
    static func split(_ id: ModelRepoID) -> (name: String, variant: String?) {
        let full = name(id)
        let words = full.split(separator: " ").map(String.init)
        guard let sizeIndex = words.firstIndex(where: { $0.range(of: #"^\d+(\.\d+)?[BM](-A\d+(\.\d+)?B)?$"#, options: .regularExpression) != nil }),
              sizeIndex < words.count - 1 else { return (full, nil) }
        let quantWords: Set<String> = ["MLX", "mlx", "Instruct", "it", "Chat"]
        let rest = words[(sizeIndex + 1)...].filter { !quantWords.contains($0) && $0.range(of: #"^\d+bit$"#, options: .regularExpression) == nil }
        return (words[...sizeIndex].joined(separator: " "), rest.isEmpty ? nil : rest.joined(separator: " "))
    }

    /// "OptiQ · 4-bit · 256K" (+ size when `withSize`).
    static func subtitle(_ m: InstalledModel, withSize: Bool) -> String {
        var parts: [String] = []
        if let v = split(m.id).variant { parts.append(v) }
        if let b = m.manifest.quantizationBits { parts.append("\(b)-bit") }
        if let c = m.manifest.contextLength { parts.append(context(c).uppercased()) }
        if withSize { parts.append(bytes(m.diskBytes)) }
        return parts.joined(separator: " · ")
    }

    /// Parameter size parsed from the name ("0.6B", "30B MoE"); nil when not stated.
    static func parameters(_ id: ModelRepoID) -> String? {
        let n = id.name
        guard let r = n.range(of: #"(?<![A-Za-z0-9.])\d+(\.\d+)?[BM](?![A-Za-z])"#, options: .regularExpression) else { return nil }
        let size = String(n[r])
        return n.range(of: #"-A\d+(\.\d+)?B"#, options: .regularExpression) != nil ? "\(size) MoE" : size
    }

    static func quant(bits: Int?) -> String { bits.map { "\($0)-bit" } ?? "—" }

    static func context(_ tokens: Int?) -> String {
        guard let t = tokens else { return "—" }
        return t >= 1024 ? "\(Int((Double(t) / 1024).rounded()))k" : "\(t)"
    }

    static func bytes(_ b: Int64) -> String {
        let gb = Double(b) / 1_000_000_000
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(b) / 1_000_000)
    }

    static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let s = now.timeIntervalSince(date)
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(Int(s / 60))m"
        case ..<86400: return "\(Int(s / 3600))h"
        case ..<(86400 * 7): return "\(Int(s / 86400))d"
        case ..<(86400 * 30): return "\(Int(s / (86400 * 7)))w"
        default: return "\(Int(s / (86400 * 30)))mo"
        }
    }
}
