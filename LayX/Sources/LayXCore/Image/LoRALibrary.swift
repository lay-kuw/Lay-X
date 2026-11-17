import Foundation

/// LoRA adapters imported by the user: `.safetensors` files copied into one folder (`~/.config/lay-x/loras`).
/// Only the file header is read here (to tell which base model a LoRA is for); weights are merged by the engine.
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
            /// Made for a base Lay X runs.
            case fits(LoRABase)
            /// Made for another base model (SD 1.x / 2.x, FLUX.1, klein 9B…): it won't apply.
            case otherBase(String)
            /// A whole model (single-file checkpoint), not a LoRA — import it in Models instead.
            case fullModel
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
        case notSafetensors, unreadable, alreadyExists(String), fullModel
        public var errorDescription: String? {
            switch self {
            case .fullModel: "This file is a whole model (checkpoint), not a LoRA. Add it in Models → Image → Import Model File…"
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
        guard let header = try? Self.header(of: source) else { throw ImportError.unreadable }
        if Self.isFullModel(Array(header.keys)) { throw ImportError.fullModel }
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

    /// Which base a LoRA is for, from its metadata and tensor names:
    /// - SDXL: second text encoder (`lora_te2_` / `text_encoder_2`) or SDXL-only UNet blocks; SD 1.x has attention
    ///   in the first down block, which SDXL doesn't.
    /// - Qwen-Image: per-stream MLP / modulation names (`img_mlp`, `txt_mlp`, `img_mod`).
    /// - FLUX: `double_blocks` / `single_blocks` (BFL) or `single_transformer_blocks` (diffusers). klein 4B has 5
    ///   double and 20 single blocks; FLUX.1 and klein 9B have more.
    static func inspect(_ header: [String: Any]) -> (LoRALibrary.Info.Fit, String?, [String]) {
        let keys = header.keys.filter { $0 != "__metadata__" }
        let meta = header["__metadata__"] as? [String: String] ?? [:]
        let base = meta["ss_base_model_version"] ?? meta["modelspec.architecture"] ?? meta["base_model"]
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
        return (fit(keys: keys, base: base ?? ""), base, triggers)
    }

    /// A checkpoint (UNet / VAE / text encoder weights) rather than low-rank adapters.
    public static func isFullModel(_ keys: [String]) -> Bool {
        let adapter = keys.contains { k in
            let l = k.lowercased()
            return l.contains("lora") || l.contains("lokr") || l.contains("hada_") || l.hasSuffix(".alpha")
        }
        guard !adapter else { return false }
        return keys.contains { $0.hasPrefix("model.diffusion_model.") || $0.hasPrefix("first_stage_model.") || $0.hasPrefix("unet.") }
            || keys.count > 1500
    }

    static func fit(keys: [String], base: String) -> LoRALibrary.Info.Fit {
        if isFullModel(keys) { return .fullModel }
        let lowerBase = base.lowercased()
        if lowerBase.contains("qwen") { return .fits(.qwenImage) }
        if lowerBase.contains("klein") {
            return lowerBase.contains("9b") ? .otherBase("FLUX.2 klein 9B") : .fits(.flux2Klein4B)
        }
        if lowerBase.contains("sdxl") || lowerBase.contains("xl") { return .fits(.sdxl) }
        if lowerBase.contains("sd_v1") || lowerBase.contains("sd_v2") || lowerBase.contains("stable-diffusion-v1") {
            return .otherBase("SD 1.x / 2.x")
        }
        if keys.contains(where: { $0.contains("img_mlp") || $0.contains("txt_mlp") || $0.contains("img_mod") || $0.contains("txt_mod") }) {
            return .fits(.qwenImage)
        }
        let hasSingle = keys.contains { $0.contains("single_blocks") || $0.contains("single_transformer_blocks") }
        // Attention-only Qwen-Image LoRAs: 60 joint blocks and no single-stream ones (FLUX has ≤ 19 joint blocks).
        if !hasSingle, maxIndex(keys, after: ["transformer_blocks"]) >= 19 { return .fits(.qwenImage) }
        let isFlux = keys.contains { $0.contains("double_blocks") || $0.contains("single_blocks") || $0.contains("single_transformer_blocks") }
        if isFlux || lowerBase.contains("flux") {
            let double = maxIndex(keys, after: ["double_blocks", "transformer_blocks"])
            let single = maxIndex(keys, after: ["single_blocks", "single_transformer_blocks"])
            if double >= 5 || single >= 20 { return .otherBase(lowerBase.contains("flux.2") || lowerBase.contains("flux2") ? "FLUX.2 (not klein 4B)" : "FLUX.1") }
            // FLUX.1 names its single-block MLP `proj_mlp`; FLUX.2 fuses it into the attention projection.
            if keys.contains(where: { $0.contains("proj_mlp") }) || lowerBase.contains("flux.1") || lowerBase.contains("flux-1") {
                return .otherBase("FLUX.1")
            }
            return .fits(.flux2Klein4B)
        }
        if keys.contains(where: { $0.contains("lora_te2_") || $0.hasPrefix("text_encoder_2.") || $0.contains("input_blocks_7_1") }) {
            return .fits(.sdxl)
        }
        if keys.contains(where: { $0.contains("down_blocks_0_attentions") || $0.contains("down_blocks.0.attentions") }) {
            return .otherBase("SD 1.x / 2.x")
        }
        // UNet attention LoRA without any first-down-block attention: SDXL's layout.
        if keys.contains(where: { $0.contains("down_blocks_1_attentions") || $0.contains("down_blocks.1.attentions") }) {
            return .fits(.sdxl)
        }
        return .unknown
    }

    /// Largest block number after any of `markers` ("…double_blocks.12.…" / "…double_blocks_12_…"), or -1.
    /// A marker preceded by "single_" doesn't count (`transformer_blocks` vs `single_transformer_blocks`).
    static func maxIndex(_ keys: [String], after markers: [String]) -> Int {
        var best = -1
        for key in keys {
            for marker in markers {
                var search = key.startIndex..<key.endIndex
                while let range = key.range(of: marker, range: search) {
                    search = range.upperBound..<key.endIndex
                    if !marker.hasPrefix("single"), key[..<range.lowerBound].hasSuffix("single_") { continue }
                    let rest = key[range.upperBound...].drop { $0 == "." || $0 == "_" }
                    if let n = Int(rest.prefix { $0.isNumber }) { best = max(best, n) }
                }
            }
        }
        return best
    }
}
