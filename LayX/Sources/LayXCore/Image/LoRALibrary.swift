import Foundation

/// LoRA adapters imported by the user: `.safetensors` files copied into one folder (`~/.config/lay-x/loras`).
/// Only the file header is read here (to tell SDXL LoRAs from others); weights are merged by the engine.
public struct LoRALibrary: Sendable {
    public let folder: URL

    public init(folder: URL) { self.folder = folder.standardizedFileURL }

    public static func defaultFolder() throws -> URL {
        let url = LayXPaths.configRoot.appendingPathComponent("loras", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    public struct Info: Sendable, Hashable, Identifiable {
        public enum Fit: Sendable, Hashable {
            case sdxl
            /// Made for another base model (SD 1.x / 2.x / Flux…): it won't apply.
            case otherBase(String)
            case unknown
        }
        public var file: String
        public var bytes: Int64
        public var fit: Fit
        /// Base model named in the metadata, e.g. "sdxl_base_v1-0".
        public var baseModel: String?
        /// Trigger words from the training metadata (most frequent tags), if present.
        public var triggerWords: [String]
        public var id: String { file }
        public var name: String { (file as NSString).deletingPathExtension }
    }

    public enum ImportError: Error, LocalizedError, Equatable {
        case notSafetensors, unreadable, alreadyExists(String)
        public var errorDescription: String? {
            switch self {
            case .notSafetensors: "Only .safetensors LoRA files can be added."
            case .unreadable: "That file isn’t a valid safetensors file."
            case .alreadyExists(let n): "A LoRA named “\(n)” is already added."
            }
        }
    }

    public func list() -> [Info] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.lowercased().hasSuffix(".safetensors") && !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { info(for: $0) }
    }

    public func url(for file: String) -> URL? {
        guard Self.isSafeName(file) else { return nil }
        let url = folder.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && name.lowercased().hasSuffix(".safetensors")
    }

    func info(for file: String) -> Info? {
        let url = folder.appendingPathComponent(file)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard let header = try? Self.header(of: url) else { return nil }
        let (fit, base, triggers) = Self.inspect(header)
        return Info(file: file, bytes: bytes, fit: fit, baseModel: base, triggerWords: triggers)
    }

    /// Copies a LoRA into the library (the original stays where it was).
    @discardableResult
    public func importFile(_ source: URL) throws -> Info {
        guard source.pathExtension.lowercased() == "safetensors" else { throw ImportError.notSafetensors }
        guard (try? Self.header(of: source)) != nil else { throw ImportError.unreadable }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = source.lastPathComponent.replacingOccurrences(of: "/", with: "_")
        guard Self.isSafeName(name) else { throw ImportError.notSafetensors }
        let target = folder.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw ImportError.alreadyExists((name as NSString).deletingPathExtension) }
        try FileManager.default.copyItem(at: source, to: target)
        guard let info = info(for: name) else { throw ImportError.unreadable }
        return info
    }

    public func delete(_ file: String) throws {
        guard let url = url(for: file) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: safetensors header

    /// The JSON header: tensor names → metadata, plus `__metadata__`.
    static func header(of url: URL) throws -> [String: Any] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let lengthData = try handle.read(upToCount: 8), lengthData.count == 8 else { throw ImportError.unreadable }
        let length = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        guard length > 2, length < 100_000_000, let json = try handle.read(upToCount: Int(length)),
              let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw ImportError.unreadable }
        return object
    }

    /// SDXL LoRAs touch the second text encoder (`lora_te2_` / `text_encoder_2`) or SDXL-only UNet blocks; SD 1.x
    /// LoRAs have attention in the first down block (`down_blocks_0_attentions`), which SDXL doesn't.
    static func inspect(_ header: [String: Any]) -> (LoRALibrary.Info.Fit, String?, [String]) {
        let keys = header.keys.filter { $0 != "__metadata__" }
        let meta = header["__metadata__"] as? [String: String] ?? [:]
        let base = meta["ss_base_model_version"] ?? meta["modelspec.architecture"]
        var triggers: [String] = []
        if let tags = meta["ss_tag_frequency"], let data = tags.data(using: .utf8),
           let freq = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Int]] {
            var total: [String: Int] = [:]
            for (_, counts) in freq { for (tag, n) in counts { total[tag.trimmingCharacters(in: .whitespaces), default: 0] += n } }
            // Captions are often whole sentences; trigger words are the short tags that recur.
            let tagCount = total.count
            triggers = total.filter { tag, n in
                !tag.isEmpty && tag.count <= 32 && tag.split(separator: " ").count <= 3 && (tagCount < 5 || n > 1)
            }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3).map(\.key)
        }
        let lowerBase = base?.lowercased() ?? ""
        if lowerBase.contains("sdxl") || lowerBase.contains("xl") { return (.sdxl, base, triggers) }
        if lowerBase.contains("flux") || lowerBase.contains("sd_v1") || lowerBase.contains("sd_v2") || lowerBase.contains("stable-diffusion-v1") {
            return (.otherBase(base ?? "another model"), base, triggers)
        }
        if keys.contains(where: { $0.contains("lora_te2_") || $0.hasPrefix("text_encoder_2.") || $0.contains("input_blocks_7_1") }) {
            return (.sdxl, base, triggers)
        }
        if keys.contains(where: { $0.contains("down_blocks_0_attentions") || $0.contains("down_blocks.0.attentions") }) {
            return (.otherBase("SD 1.x / 2.x"), base, triggers)
        }
        if keys.contains(where: { $0.contains("double_blocks") || $0.contains("single_blocks") }) {
            return (.otherBase("Flux"), base, triggers)
        }
        // UNet attention LoRA without any first-down-block attention: SDXL's layout.
        if keys.contains(where: { $0.contains("down_blocks_1_attentions") || $0.contains("down_blocks.1.attentions") }) {
            return (.sdxl, base, triggers)
        }
        return (.unknown, base, triggers)
    }
}
