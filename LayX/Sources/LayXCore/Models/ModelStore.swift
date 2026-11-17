import Foundation

/// The application-managed model directory. Every file operation is confined to `root`:
/// paths are built only from validated `ModelRepoID`s and validated relative file paths, and are re-checked
/// after symlink resolution before anything is written or deleted.
///
/// Layout: `<root>/<owner>/<name>/{config.json, *.safetensors, …, .layx-manifest.json}`;
/// in-progress downloads live in `<root>/<owner>/<name>/.partial/`.
public struct ModelStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// `~/.config/lay-x/models` (created if missing).
    public static func defaultRoot() throws -> URL {
        let url = LayXPaths.configRoot.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    public static let partialDirectoryName = ".partial"
    /// Uses a user-chosen folder as the store root as-is (no subfolder, no marker files).
    /// Lay X only ever creates or deletes `<owner>/<name>` model folders inside it.
    public static func root(forChosenFolder chosen: URL) throws -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: chosen.path, isDirectory: &isDir), isDir.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard FileManager.default.isWritableFile(atPath: chosen.path) else { throw CocoaError(.fileWriteNoPermission) }
        return URL(fileURLWithPath: canonicalPath(chosen), isDirectory: true)
    }

    // MARK: Paths

    public func directory(for id: ModelRepoID) -> URL {
        root.appendingPathComponent(id.owner, isDirectory: true).appendingPathComponent(id.name, isDirectory: true)
    }

    public func partialDirectory(for id: ModelRepoID) -> URL {
        directory(for: id).appendingPathComponent(Self.partialDirectoryName, isDirectory: true)
    }

    /// Validates a repository-relative file path (from the Hub tree) and returns its URL under `base`.
    /// Allows nested directories, rejects absolute paths, `.`/`..`, hidden components and control characters.
    public static func safeChild(of base: URL, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, relativePath.count < 512, !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"), !relativePath.contains("\0")
        else { throw ModelStoreError.unsafePath(relativePath) }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        for c in components {
            guard !c.isEmpty, c != ".", c != "..", !c.hasPrefix("."),
                  c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { throw ModelStoreError.unsafePath(relativePath) }
        }
        let url = base.appendingPathComponent(relativePath).standardizedFileURL
        guard isContained(url, in: base) else { throw ModelStoreError.unsafePath(relativePath) }
        return url
    }

    /// True if `url` (after resolving symlinks of its existing ancestors) lies strictly inside `base`.
    public static func isContained(_ url: URL, in base: URL) -> Bool {
        let b = canonicalPath(base)
        let u = canonicalPath(url)
        let prefix = b.hasSuffix("/") ? b : b + "/"
        return u.hasPrefix(prefix)
    }

    /// Resolves symlinks in the deepest *existing* ancestor and re-appends the remaining components.
    /// (`URL.resolvingSymlinksInPath()` leaves a path untouched when its final component doesn't exist yet,
    /// which would let a not-yet-created file escape through a symlinked parent directory.)
    public static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var remainder: [String] = []
        let fm = FileManager.default
        while !fm.fileExists(atPath: existing.path), existing.path != "/" {
            remainder.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in remainder { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL.path
    }

    // MARK: Queries

    /// Fully downloaded models (those with a manifest).
    public func installedModels() -> [InstalledModel] {
        let fm = FileManager.default
        guard let owners = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var result: [InstalledModel] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for owner in owners where ModelRepoID.isValidComponent(owner.lastPathComponent) {
            guard let names = try? fm.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil) else { continue }
            for dir in names {
                guard let id = ModelRepoID("\(owner.lastPathComponent)/\(dir.lastPathComponent)") else { continue }
                if let data = try? Data(contentsOf: dir.appendingPathComponent(InstalledModelManifest.fileName)),
                   let manifest = try? decoder.decode(InstalledModelManifest.self, from: data), manifest.id == id {
                    result.append(InstalledModel(manifest: manifest, directory: directory(for: id),
                                                 diskBytes: Self.allocatedSize(of: dir)))
                } else if let manifest = Self.inferManifest(id: id, directory: dir) {
                    // A model folder placed here by the user (no Lay X manifest): referenced read-only.
                    result.append(InstalledModel(manifest: manifest, directory: directory(for: id),
                                                 diskBytes: Self.allocatedSize(of: dir)))
                }
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    /// Writes the manifest of a model folder made on this Mac (an imported checkpoint), which marks it installed.
    @discardableResult
    public func registerLocalModel(_ id: ModelRepoID, modelType: String, kind: ModelKind) throws -> InstalledModel {
        let dir = directory(for: id)
        guard Self.isContained(dir, in: root) else { throw ModelStoreError.unsafePath(id.description) }
        let fm = FileManager.default
        var files: [HubFile] = []
        if let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      !url.lastPathComponent.hasPrefix(".") else { continue }
                let relative = String(url.standardizedFileURL.path.dropFirst(dir.standardizedFileURL.path.count + 1))
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                files.append(HubFile(path: relative, size: size, sha256: nil))
            }
        }
        let manifest = InstalledModelManifest(id: id, revision: "local", files: files.sorted { $0.path < $1.path },
                                              downloadedAt: Date(), modelType: modelType, kind: kind)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: dir.appendingPathComponent(InstalledModelManifest.fileName), options: .atomic)
        return InstalledModel(manifest: manifest, directory: dir, diskBytes: Self.allocatedSize(of: dir))
    }

    public func installedModel(_ id: ModelRepoID) -> InstalledModel? {
        installedModels().first { $0.id == id }
    }

    /// Builds an in-memory manifest for a complete model folder without one (config.json + *.safetensors,
    /// no unfinished download). Nothing is written.
    static func inferManifest(id: ModelRepoID, directory dir: URL) -> InstalledModelManifest? {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.appendingPathComponent(partialDirectoryName).path),
              fm.fileExists(atPath: dir.appendingPathComponent("config.json").path),
              let names = try? fm.contentsOfDirectory(atPath: dir.path),
              names.contains(where: { $0.hasSuffix(".safetensors") })
        else { return nil }
        let files = names.filter { !$0.hasPrefix(".") }.map { name -> HubFile in
            let size = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value ?? 0
            return HubFile(path: name, size: size, sha256: nil)
        }
        let config = readConfig(at: dir)
        let date = (try? fm.attributesOfItem(atPath: dir.path)[.modificationDate] as? Date) ?? Date()
        return InstalledModelManifest(id: id, revision: "local", files: files, downloadedAt: date, modelType: config.modelType,
                                      quantizationBits: config.bits, contextLength: config.context)
    }

    /// Models with a `.partial` directory and no manifest (interrupted downloads that can be resumed).
    public func incompleteDownloads() -> [(id: ModelRepoID, bytes: Int64)] {
        let fm = FileManager.default
        guard let owners = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [(ModelRepoID, Int64)] = []
        for owner in owners {
            for dir in (try? fm.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil)) ?? [] {
                guard let id = ModelRepoID("\(owner.lastPathComponent)/\(dir.lastPathComponent)") else { continue }
                let partial = partialDirectory(for: id)
                let hasManifest = fm.fileExists(atPath: dir.appendingPathComponent(InstalledModelManifest.fileName).path)
                if !hasManifest, fm.fileExists(atPath: partial.path) {
                    out.append((id, Self.allocatedSize(of: partial)))
                }
            }
        }
        return out
    }

    /// Bytes used by everything under `root`.
    public func totalUsage() -> Int64 { Self.allocatedSize(of: root) }

    public func availableCapacity() -> Int64 {
        let probe = FileManager.default.fileExists(atPath: root.path) ? root : root.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: Mutations

    /// Deletes an installed or partially downloaded model. Refuses ids in `inUse` (the loaded model).
    public func delete(_ id: ModelRepoID, inUse: Set<String>) throws {
        guard !inUse.contains(id.description) else { throw ModelStoreError.inUse(id.description) }
        let dir = directory(for: id)
        guard Self.isContained(dir, in: root) else { throw ModelStoreError.unsafePath(id.description) }
        // Refuse if the model directory itself is a symlink (could point outside the store).
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            throw ModelStoreError.unsafePath(id.description)
        }
        guard FileManager.default.fileExists(atPath: dir.path) else { throw ModelStoreError.notInstalled(id.description) }
        try FileManager.default.removeItem(at: dir)
        // Remove the owner directory if it became empty.
        let owner = dir.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: owner.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: owner)
        }
    }

    // MARK: Helpers

    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            guard let v = try? file.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Reads architecture details from a model's `config.json`.
    public static func readConfig(at directory: URL) -> (modelType: String?, bits: Int?, context: Int?) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil, nil) }
        return parseConfig(json)
    }

    static func parseConfig(_ json: [String: Any]) -> (modelType: String?, bits: Int?, context: Int?) {
        let text = json["text_config"] as? [String: Any]
        let modelType = json["model_type"] as? String
        let quant = (json["quantization"] as? [String: Any]) ?? (json["quantization_config"] as? [String: Any])
        let bits = quant?["bits"] as? Int
        let context = (json["max_position_embeddings"] as? Int) ?? (text?["max_position_embeddings"] as? Int)
            ?? (json["max_sequence_length"] as? Int) ?? (json["seq_length"] as? Int)
        return (modelType, bits, context)
    }
}
