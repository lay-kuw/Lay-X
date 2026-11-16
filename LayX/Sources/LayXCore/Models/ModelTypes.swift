import Foundation

/// A validated Hugging Face repository id (`owner/name`). Construction rejects anything that could escape the
/// model storage directory (`..`, absolute paths, extra separators, control characters).
public struct ModelRepoID: Sendable, Hashable, Codable, CustomStringConvertible, Comparable {
    public let owner: String
    public let name: String

    public init?(_ raw: String) {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let owner = parts.first.map(String.init), let name = parts.last.map(String.init),
              Self.isValidComponent(owner), Self.isValidComponent(name)
        else { return nil }
        self.owner = owner
        self.name = name
    }

    public var description: String { "\(owner)/\(name)" }
    public static func < (a: Self, b: Self) -> Bool { a.description.lowercased() < b.description.lowercased() }

    static func isValidComponent(_ s: String) -> Bool {
        guard (1...96).contains(s.count), s != ".", s != "..", !s.hasPrefix("."), !s.hasPrefix("-") else { return false }
        return s.unicodeScalars.allSatisfy { c in
            (c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "-" || c == "_" || c == "."))
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = ModelRepoID(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid repo id"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// Why a model can or cannot run in Lay X.
public enum ModelCompatibility: Sendable, Hashable, Codable {
    case compatible
    /// Not an MLX conversion (e.g. PyTorch / GGUF weights).
    case notMLX
    /// MLX weights, but the architecture isn't implemented by MLXLLM (or is a VLM/audio/embedding model).
    case unsupportedArchitecture(String)
    case unknown

    public var isCompatible: Bool { self == .compatible }

    public var label: String {
        switch self {
        case .compatible: "Compatible"
        case .notMLX: "Not MLX format"
        case .unsupportedArchitecture(let t): "Unsupported architecture (\(t))"
        case .unknown: "Unknown"
        }
    }
}

/// Decides whether an architecture (`config.json` → `model_type`) is supported by the inference engine.
/// Implemented by the MLX module; tests use a fixed set.
public protocol ModelArchitectureSupport: Sendable {
    func supports(modelType: String) async -> Bool
}

/// A model listed by the Hub search.
public struct HubModelSummary: Sendable, Hashable, Identifiable {
    public var id: ModelRepoID
    public var modelType: String?
    public var quantizationBits: Int?
    public var parameterCount: Int64?
    public var downloads: Int
    public var lastModified: Date?
    public var tags: [String]
    public var libraryName: String?
    public var pipelineTag: String?
    public var likes: Int = 0
    public var trendingScore: Int = 0

    public init(id: ModelRepoID, modelType: String?, quantizationBits: Int?, parameterCount: Int64?, downloads: Int,
                lastModified: Date?, tags: [String], libraryName: String?, pipelineTag: String? = nil,
                likes: Int = 0, trendingScore: Int = 0) {
        self.likes = likes
        self.trendingScore = trendingScore
        self.id = id
        self.modelType = modelType
        self.quantizationBits = quantizationBits
        self.parameterCount = parameterCount
        self.downloads = downloads
        self.lastModified = lastModified
        self.tags = tags
        self.libraryName = libraryName
        self.pipelineTag = pipelineTag
    }

    /// An MLX conversion of a text-generation model: tagged `mlx` (or `library_name: mlx`), pipeline
    /// `text-generation` (or unspecified), and not an embedding / similarity / reranking model.
    /// Audio (`mlx-audio`) and vision (`image-text-to-text`, `mlx-vlm`) packages are excluded.
    public var isMLXLanguageModelRepo: Bool {
        let isMLX = libraryName == "mlx" || tags.contains("mlx")
        let excludedLibraries: Set<String> = ["mlx-audio", "mlx-vlm", "mlx-embeddings"]
        let excludedTags: Set<String> = ["sentence-similarity", "feature-extraction", "text-ranking", "sentence-transformers"]
        // image-text-to-text repos (e.g. Qwen3.5/3.6) ship a language model MLXLLM can run as text-only.
        let pipelineOK = pipelineTag == nil || pipelineTag == "text-generation" || pipelineTag == "image-text-to-text"
        return isMLX && pipelineOK && !excludedLibraries.contains(libraryName ?? "")
            && excludedTags.isDisjoint(with: tags)
    }
}

/// One file in a Hub repository snapshot.
public struct HubFile: Sendable, Hashable, Codable {
    public var path: String
    public var size: Int64
    /// SHA-256 of the content for LFS files (weights). `nil` for small git-stored files.
    public var sha256: String?

    public init(path: String, size: Int64, sha256: String?) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// Metadata written next to a completed download. Its presence marks the model as fully installed.
public struct InstalledModelManifest: Sendable, Hashable, Codable {
    public static let fileName = ".layx-manifest.json"
    public var id: ModelRepoID
    public var revision: String
    public var files: [HubFile]
    public var downloadedAt: Date
    public var modelType: String?
    public var quantizationBits: Int?
    public var contextLength: Int?

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// A model present in the storage directory.
public struct InstalledModel: Sendable, Hashable, Identifiable {
    public var id: ModelRepoID { manifest.id }
    public var manifest: InstalledModelManifest
    public var directory: URL
    /// Bytes actually on disk.
    public var diskBytes: Int64

    public var reference: ModelReference { ModelReference(id: manifest.id.description, directory: directory) }
}

public enum ModelStoreError: Error, Equatable, Sendable, LocalizedError {
    case invalidRepoID(String)
    case unsafePath(String)
    case notInstalled(String)
    case inUse(String)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case checksumMismatch(file: String)
    case sizeMismatch(file: String)
    case http(status: Int)
    case network(String)
    case noWeights
    case incompatible(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRepoID(let s): "“\(s)” isn’t a valid model id (expected owner/name)."
        case .unsafePath(let s): "Refused an unsafe file path in the model repository: \(s)"
        case .notInstalled(let s): "\(s) is not downloaded."
        case .inUse(let s): "\(s) is loaded. Unload it before deleting."
        case .insufficientDiskSpace(let need, let have):
            "Not enough disk space: \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)) needed, \(ByteCountFormatter.string(fromByteCount: have, countStyle: .file)) available."
        case .checksumMismatch(let f): "The downloaded file \(f) is corrupted (checksum mismatch). Download it again."
        case .sizeMismatch(let f): "The downloaded file \(f) has an unexpected size. Download it again."
        case .http(let status): "The model server responded with HTTP \(status)."
        case .network(let s): "Network error: \(s)"
        case .noWeights: "This repository has no .safetensors weights."
        case .incompatible(let why): "This model can’t run in Lay X: \(why)"
        }
    }
}
