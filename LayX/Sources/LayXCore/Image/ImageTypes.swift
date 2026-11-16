import Foundation

/// Output size in pixels (multiples of 64).
public struct ImageSize: Sendable, Hashable, Codable, Identifiable {
    public var width: Int
    public var height: Int
    public var id: String { "\(width)x\(height)" }
    public init(_ width: Int, _ height: Int) { self.width = width; self.height = height }

    public var label: String { "\(width) × \(height)" }
    public var megapixels: Double { Double(width * height) / 1_048_576 }
    public var aspect: String {
        if width == height { return "Square" }
        return width > height ? "Landscape" : "Portrait"
    }

    /// SDXL training buckets (≈1 MP) plus smaller sizes for quick drafts.
    public static let sdxl: [ImageSize] = [
        .init(1024, 1024), .init(1152, 896), .init(896, 1152), .init(1216, 832), .init(832, 1216),
        .init(1344, 768), .init(768, 1344), .init(768, 768), .init(512, 512),
    ]
    public static let turbo: [ImageSize] = [.init(512, 512), .init(768, 512), .init(512, 768), .init(768, 768), .init(1024, 1024)]
}

/// An image model Lay X can run: any SDXL checkpoint in diffusers layout (downloaded once, then offline).
public struct ImageModelSpec: Sendable, Hashable, Identifiable {
    public var id: ModelRepoID
    public var name: String
    public var publisher: String
    /// One line for lists ("Photoreal", "Fast drafts", …).
    public var style: String
    public var summary: String
    /// Approximate download size (shown before the file list is known).
    public var downloadBytes: Int64
    public var sizes: [ImageSize]
    public var defaultSize: ImageSize
    public var defaultSteps: Int
    public var stepRange: ClosedRange<Int>
    public var defaultCFG: Double
    public var cfgRange: ClosedRange<Double>
    public var license: String
    public var licenseURL: URL
    /// Installed from a repository outside the catalog.
    public var isCustom = false

    /// Weights (fp16) + text encoders + VAE kept resident.
    static let weightBytes: Int64 = 7_400_000_000

    /// Memory needed to generate at `size` (weights + activations; the float32 VAE decode dominates at 1 MP).
    public func runtimeBytes(for size: ImageSize) -> Int64 {
        Self.weightBytes + 1_000_000_000 + Int64(size.megapixels * 5_000_000_000)
    }

    public var downloadProfile: DownloadProfile { .sdxl }

    static func hf(_ id: String) -> URL { URL(string: "https://huggingface.co/\(id)")! }

    public static let sdxlTurbo = ImageModelSpec(
        id: ModelRepoID("stabilityai/sdxl-turbo")!, name: "SDXL Turbo", publisher: "Stability AI", style: "Fastest",
        summary: "Instant drafts at 512 px in 1–4 steps. Lower detail.",
        downloadBytes: 6_950_000_000, sizes: ImageSize.turbo, defaultSize: .init(512, 512),
        defaultSteps: 2, stepRange: 1...8, defaultCFG: 0, cfgRange: 0...3,
        license: "Stability AI Community License",
        licenseURL: URL(string: "https://huggingface.co/stabilityai/sdxl-turbo/blob/main/LICENSE.md")!)

    public static let dreamShaperTurbo = ImageModelSpec(
        id: ModelRepoID("Lykon/dreamshaper-xl-v2-turbo")!, name: "DreamShaper XL Turbo", publisher: "Lykon", style: "Fast · versatile",
        summary: "High quality at 1024 px in about 6 steps — the best all-rounder.",
        downloadBytes: 6_940_000_000, sizes: ImageSize.sdxl, defaultSize: .init(1024, 1024),
        defaultSteps: 6, stepRange: 2...20, defaultCFG: 2, cfgRange: 0...6,
        license: "CreativeML Open RAIL++-M", licenseURL: hf("Lykon/dreamshaper-xl-v2-turbo"))

    public static let sdxlBase = ImageModelSpec(
        id: ModelRepoID("stabilityai/stable-diffusion-xl-base-1.0")!, name: "SDXL 1.0", publisher: "Stability AI", style: "Balanced",
        summary: "The original SDXL at 1024 px. Follows prompts well; needs ~30 steps.",
        downloadBytes: 6_940_000_000, sizes: ImageSize.sdxl, defaultSize: .init(1024, 1024),
        defaultSteps: 30, stepRange: 4...60, defaultCFG: 6, cfgRange: 1...15,
        license: "CreativeML Open RAIL++-M", licenseURL: hf("stabilityai/stable-diffusion-xl-base-1.0"))

    public static let realVis = ImageModelSpec(
        id: ModelRepoID("SG161222/RealVisXL_V5.0")!, name: "RealVisXL 5", publisher: "SG161222", style: "Photoreal",
        summary: "Photographic portraits, products and places.",
        downloadBytes: 6_940_000_000, sizes: ImageSize.sdxl, defaultSize: .init(896, 1152),
        defaultSteps: 30, stepRange: 4...60, defaultCFG: 5, cfgRange: 1...12,
        license: "CreativeML Open RAIL++-M", licenseURL: hf("SG161222/RealVisXL_V5.0"))

    public static let juggernaut = ImageModelSpec(
        id: ModelRepoID("RunDiffusion/Juggernaut-XL-v9")!, name: "Juggernaut XL 9", publisher: "RunDiffusion", style: "Photoreal · cinematic",
        summary: "Cinematic, detailed photographs and scenes.",
        downloadBytes: 6_940_000_000, sizes: ImageSize.sdxl, defaultSize: .init(1216, 832),
        defaultSteps: 30, stepRange: 4...60, defaultCFG: 5, cfgRange: 1...12,
        license: "CreativeML Open RAIL-M", licenseURL: hf("RunDiffusion/Juggernaut-XL-v9"))

    public static let animagine = ImageModelSpec(
        id: ModelRepoID("cagliostrolab/animagine-xl-4.0")!, name: "Animagine XL 4", publisher: "Cagliostro Lab", style: "Anime",
        summary: "Anime illustration. Works best with tag-style prompts.",
        downloadBytes: 13_900_000_000, sizes: ImageSize.sdxl, defaultSize: .init(832, 1216),
        defaultSteps: 28, stepRange: 4...60, defaultCFG: 5, cfgRange: 1...12,
        license: "CreativeML Open RAIL++-M", licenseURL: hf("cagliostrolab/animagine-xl-4.0"))

    public static let catalog: [ImageModelSpec] = [.dreamShaperTurbo, .sdxlBase, .realVis, .juggernaut, .animagine, .sdxlTurbo]

    public static func spec(_ id: String) -> ImageModelSpec? { catalog.first { $0.id.description == id } }

    /// Catalog entry, or generic SDXL defaults for a repository installed by name.
    public static func spec(for id: ModelRepoID) -> ImageModelSpec {
        if let known = spec(id.description) { return known }
        return ImageModelSpec(
            id: id, name: id.name.replacingOccurrences(of: "-", with: " "), publisher: id.owner, style: "SDXL",
            summary: "SDXL checkpoint added from Hugging Face.",
            downloadBytes: 6_940_000_000, sizes: ImageSize.sdxl, defaultSize: .init(1024, 1024),
            defaultSteps: 30, stepRange: 1...60, defaultCFG: 5, cfgRange: 0...15,
            license: "See the model page", licenseURL: hf(id.description), isCustom: true)
    }
}

/// The files an SDXL pipeline needs, chosen from a repository listing: configs, both tokenizers, and per
/// component the fp16 weights when published (otherwise full precision — converted to fp16 when loading).
public enum SDXLFiles {
    static let required = [
        "model_index.json", "scheduler/scheduler_config.json",
        "text_encoder/config.json", "text_encoder_2/config.json", "unet/config.json", "vae/config.json",
        "tokenizer/merges.txt", "tokenizer/vocab.json", "tokenizer_2/merges.txt", "tokenizer_2/vocab.json",
    ]
    static let weights = [
        ("unet", "diffusion_pytorch_model"), ("text_encoder", "model"), ("text_encoder_2", "model"),
        ("vae", "diffusion_pytorch_model"),
    ]

    /// nil (with the missing paths) when the repository isn't a complete SDXL pipeline in diffusers layout.
    public static func select(from all: [HubFile]) -> (files: [HubFile]?, missing: [String]) {
        let byPath = Dictionary(all.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [HubFile] = []
        var missing: [String] = []
        for path in required {
            if let f = byPath[path] { out.append(f) } else { missing.append(path) }
        }
        for (folder, base) in weights {
            if let f = byPath["\(folder)/\(base).fp16.safetensors"] ?? byPath["\(folder)/\(base).safetensors"] {
                out.append(f)
            } else {
                missing.append("\(folder)/\(base).safetensors")
            }
        }
        return (missing.isEmpty ? out : nil, missing)
    }
}

/// A LoRA chosen for a generation (file name in the LoRA folder + strength).
public struct LoRAChoice: Sendable, Hashable, Codable {
    public var file: String
    public var scale: Double
    public init(file: String, scale: Double) { self.file = file; self.scale = scale }
    public var displayName: String { (file as NSString).deletingPathExtension }
}

/// Resolved LoRA for the engine.
public struct LoRAFile: Sendable, Hashable {
    public var url: URL
    public var scale: Double
    public init(url: URL, scale: Double) { self.url = url; self.scale = scale }
}

public struct LoRALoadReport: Sendable, Hashable {
    public var appliedLayers: Int
    public var skippedLayers: Int
    public init(appliedLayers: Int = 0, skippedLayers: Int = 0) {
        self.appliedLayers = appliedLayers
        self.skippedLayers = skippedLayers
    }
}

public struct ImageRequest: Sendable, Hashable {
    public var prompt: String
    public var negativePrompt: String
    public var steps: Int
    /// Classifier-free guidance. ≤ 1 = off (faster; the negative prompt is then ignored).
    public var cfg: Double
    public var seed: UInt64
    public var count: Int
    public var size: ImageSize
    public var loras: [LoRAChoice]
    /// Image to image: the source picture (PNG/JPEG data, cropped to `size`) and how much of it to repaint
    /// (0 = keep, 1 = ignore the source).
    public var source: Data?
    public var strength: Double

    /// Denoising steps actually run (image to image skips the first part of the schedule).
    public var effectiveSteps: Int { source == nil ? steps : max(1, Int(Double(steps) * strength)) }

    public init(prompt: String, negativePrompt: String = "", steps: Int, cfg: Double = 0, seed: UInt64, count: Int = 1,
                size: ImageSize = .init(512, 512), loras: [LoRAChoice] = [], source: Data? = nil, strength: Double = 0.6) {
        self.source = source
        self.strength = strength
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.steps = steps
        self.cfg = cfg
        self.seed = seed
        self.count = count
        self.size = size
        self.loras = loras
    }

    public static func randomSeed() -> UInt64 { UInt64.random(in: 1...UInt64(UInt32.max)) }
}

public enum ImageEvent: Sendable {
    /// Text encoded / a denoising step finished (`step` of `total`), for image `index` of the batch.
    case progress(index: Int, step: Int, total: Int)
    /// A finished image (PNG).
    case image(index: Int, png: Data, seed: UInt64)
}

public enum ImageEngineError: Error, LocalizedError, Equatable {
    case notLoaded
    case loadFailed(String)
    case generationFailed(String)
    case notEnoughMemory(neededGB: Double, availableGB: Double)

    public var errorDescription: String? {
        switch self {
        case .notLoaded: "No image model is loaded."
        case .loadFailed(let m): "The image model couldn’t be loaded: \(m)"
        case .generationFailed(let m): "Image generation failed: \(m)"
        case .notEnoughMemory(let need, let have):
            String(format: "Not enough free memory for this image (needs about %.0f GB, %.0f GB free). Try a smaller size, close other apps or unload the chat model.", need, max(have, 0))
        }
    }
}

/// Image generation backend (MLX in the app; scripted in tests).
public protocol ImageEngine: Sendable {
    /// Loads the model with the LoRAs merged in (reloading replaces any previous model).
    func load(_ spec: ImageModelSpec, directory: URL, loras: [LoRAFile]) async throws -> LoRALoadReport
    func unload() async
    /// Streams progress and images. Cancelling the consuming task stops at the next step.
    func generate(_ request: ImageRequest) -> AsyncThrowingStream<ImageEvent, Error>
}

/// One saved image in the history.
public struct ImageRecord: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var prompt: String
    public var negativePrompt: String
    public var modelID: String
    public var seed: UInt64
    public var steps: Int
    public var cfg: Double
    public var width: Int
    public var height: Int
    /// e.g. "pixel-art-xl ×0.8" (empty without LoRAs).
    public var loras: String
    /// Image to image strength (0 = text to image).
    public var strength: Double
    /// File name inside the images folder.
    public var file: String
    public var duration: Double

    public init(id: UUID = UUID(), createdAt: Date = Date(), prompt: String, negativePrompt: String = "", modelID: String,
                seed: UInt64, steps: Int, cfg: Double = 0, width: Int, height: Int, loras: String = "", strength: Double = 0,
                file: String, duration: Double) {
        self.strength = strength
        self.id = id
        self.createdAt = createdAt
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.modelID = modelID
        self.seed = seed
        self.steps = steps
        self.cfg = cfg
        self.width = width
        self.height = height
        self.loras = loras
        self.file = file
        self.duration = duration
    }

    public var size: ImageSize { .init(width, height) }
}
