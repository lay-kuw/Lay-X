import Foundation

/// Output size in pixels (multiples of the family's step: 64 for SDXL, 16 for FLUX.2 / Qwen-Image).
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
    /// FLUX.2 klein: ≈1 MP buckets (multiples of 16) plus a larger square.
    public static let klein: [ImageSize] = [
        .init(1024, 1024), .init(1152, 896), .init(896, 1152), .init(1248, 832), .init(832, 1248),
        .init(1360, 768), .init(768, 1360), .init(1280, 1280), .init(768, 768), .init(512, 512),
    ]
    /// Qwen-Image: its native ≈1.7 MP buckets and ≈1 MP ones (faster).
    public static let qwen: [ImageSize] = [
        .init(1024, 1024), .init(1152, 896), .init(896, 1152), .init(1248, 832), .init(832, 1248),
        .init(1328, 1328), .init(1472, 1104), .init(1104, 1472), .init(1584, 1056), .init(1056, 1584),
        .init(1664, 928), .init(928, 1664), .init(768, 768),
    ]
}

/// The LoRA formats Lay X can apply (one per base architecture).
public enum LoRABase: String, Sendable, Hashable, Codable {
    case sdxl, flux2Klein4B, qwenImage, zImage

    public var displayName: String {
        switch self {
        case .sdxl: "SDXL"
        case .flux2Klein4B: "FLUX.2 klein 4B"
        case .qwenImage: "Qwen-Image"
        case .zImage: "Z-Image"
        }
    }
}

/// Model architecture. Decides what the composer offers (guidance, negative prompt, source image, LoRA) and how
/// the engine runs it. Stored as the installed model's `modelType`.
public enum ImageFamily: String, Sendable, Hashable, Codable, CaseIterable {
    /// Stable Diffusion XL (UNet, CLIP ×2). LoRAs are merged at load.
    case sdxl
    /// FLUX.2 klein 4B, step-distilled: ~4 steps, no guidance / negative prompt.
    case flux2Klein = "flux2-klein"
    /// FLUX.2 klein base 4B: ~28 steps with guidance and a negative prompt.
    case flux2KleinBase = "flux2-klein-base"
    /// Qwen-Image (20B MMDiT + Qwen2.5-VL). Text to image only.
    case qwenImage = "qwen-image"
    /// Z-Image Turbo (6B single-stream DiT + Qwen3-4B), distilled: ~8 steps, no guidance.
    case zImage = "z-image"
    /// Z-Image base: ~28 steps with guidance and a negative prompt.
    case zImageBase = "z-image-base"

    public init(modelType: String?) { self = modelType.flatMap(ImageFamily.init(rawValue:)) ?? .sdxl }

    public var displayName: String {
        switch self {
        case .sdxl: "SDXL"
        case .flux2Klein: "FLUX.2 klein"
        case .flux2KleinBase: "FLUX.2 klein base"
        case .qwenImage: "Qwen-Image"
        case .zImage: "Z-Image Turbo"
        case .zImageBase: "Z-Image"
        }
    }

    /// Width and height are rounded down to a multiple of this.
    public var sizeStep: Int { self == .sdxl ? 64 : 16 }
    public var maxSide: Int { self == .qwenImage ? 1792 : self == .sdxl ? 2048 : 1536 }

    public enum SourceMode: Sendable, Hashable {
        /// Image to image: the source is noised and repainted (strength = how much).
        case strength
        /// The source conditions the model as a reference picture (edits / variations); no strength.
        case reference
        /// No image input.
        case none
    }
    public var sourceMode: SourceMode {
        switch self {
        case .sdxl, .zImage, .zImageBase: .strength
        case .flux2Klein, .flux2KleinBase: .reference
        case .qwenImage: .none
        }
    }

    public var loraBase: LoRABase {
        switch self {
        case .sdxl: .sdxl
        case .flux2Klein, .flux2KleinBase: .flux2Klein4B
        case .qwenImage: .qwenImage
        case .zImage, .zImageBase: .zImage
        }
    }
    /// LoRAs are attached to the loaded model (no reload when the selection changes).
    public var swapsLoRAsLive: Bool { self != .sdxl && self != .zImage && self != .zImageBase }
    public var maxLoRAs: Int { self == .sdxl ? 8 : 4 }
    public var loraScaleRange: ClosedRange<Double> { self == .sdxl ? 0...1.5 : 0...2 }

    /// Hugging Face pipeline filter for browsing.
    public var hubFilter: String {
        switch self {
        case .sdxl: "diffusers:StableDiffusionXLPipeline"
        case .flux2Klein, .flux2KleinBase: "diffusers:Flux2KleinPipeline"
        case .qwenImage: "diffusers:QwenImagePipeline"
        case .zImage, .zImageBase: "diffusers:ZImagePipeline"
        }
    }
}

/// What a model is good at (Models → Image → Discover groups the curated models by these).
public enum ImagePurpose: String, Sendable, Hashable, CaseIterable, Identifiable {
    case general, photo, anime, text, fast
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .general: "All-round"
        case .photo: "Photoreal"
        case .anime: "Anime & art"
        case .text: "Text & design"
        case .fast: "Fast"
        }
    }
    public var symbol: String {
        switch self {
        case .general: "sparkles"
        case .photo: "camera"
        case .anime: "paintbrush.pointed"
        case .text: "textformat"
        case .fast: "bolt"
        }
    }
}

/// An image model Lay X can run (downloaded once in diffusers layout, then offline).
public struct ImageModelSpec: Sendable, Hashable, Identifiable {
    public var id: ModelRepoID
    public var name: String
    public var publisher: String
    /// One line for lists ("Photoreal", "Fast drafts", …).
    public var style: String
    public var summary: String
    public var family: ImageFamily = .sdxl
    /// Approximate download size (shown before the file list is known).
    public var downloadBytes: Int64
    public var sizes: [ImageSize]
    public var defaultSize: ImageSize
    public var defaultSteps: Int
    public var stepRange: ClosedRange<Int>
    /// Guidance (CFG). A 0...0 range = guidance distilled into the model: no CFG slider, no negative prompt.
    public var defaultCFG: Double
    public var cfgRange: ClosedRange<Double>
    public var license: String
    public var licenseURL: URL
    /// Installed from a repository outside the catalog.
    public var isCustom = false
    /// Memory kept while loaded (weights).
    public var residentBytes: Int64 = 7_400_000_000
    /// Extra memory while generating, per megapixel (activations, VAE decode, per-request encoders).
    public var activationBytesPerMP: Int64 = 5_000_000_000

    /// CFG slider and negative prompt are offered.
    public var usesGuidance: Bool { cfgRange.upperBound > 0 }

    /// Memory needed beyond the loaded weights to generate at `size`.
    public func activationBytes(for size: ImageSize) -> Int64 {
        1_000_000_000 + Int64(max(size.megapixels, 0.5) * Double(activationBytesPerMP))
    }

    /// Memory needed to load and generate at `size`.
    public func runtimeBytes(for size: ImageSize) -> Int64 { residentBytes + activationBytes(for: size) }

    public var downloadProfile: DownloadProfile { .imagePipeline }

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

    // FLUX.2 klein 4B: Qwen3-4B text encoder kept resident with the DiT (≈16 GB in bf16).
    public static let flux2Klein = ImageModelSpec(
        id: ModelRepoID("mlx-community/FLUX.2-klein-4B-bf16")!, name: "FLUX.2 klein 4B", publisher: "Black Forest Labs",
        style: "FLUX · fast", summary: "Sharp, prompt-faithful images in 4 steps. Edits from a reference image.",
        family: .flux2Klein, downloadBytes: 16_000_000_000, sizes: ImageSize.klein, defaultSize: .init(1024, 1024),
        defaultSteps: 4, stepRange: 1...12, defaultCFG: 0, cfgRange: 0...0,
        license: "Apache 2.0", licenseURL: hf("black-forest-labs/FLUX.2-klein-4B"),
        residentBytes: 16_200_000_000, activationBytesPerMP: 11_000_000_000)

    public static let flux2KleinBase = ImageModelSpec(
        id: ModelRepoID("mlx-community/FLUX.2-klein-base-4B-bf16")!, name: "FLUX.2 klein base 4B", publisher: "Black Forest Labs",
        style: "FLUX · quality", summary: "The undistilled klein: guidance and negative prompts, ~28 steps.",
        family: .flux2KleinBase, downloadBytes: 16_000_000_000, sizes: ImageSize.klein, defaultSize: .init(1024, 1024),
        defaultSteps: 28, stepRange: 8...50, defaultCFG: 4, cfgRange: 1.5...8,
        license: "Apache 2.0", licenseURL: hf("black-forest-labs/FLUX.2-klein-base-4B"),
        residentBytes: 16_200_000_000, activationBytesPerMP: 12_400_000_000)

    // Qwen-Image: the 7B text encoder loads per prompt and is released before denoising (activation figure).
    public static let qwenImageFlash = ImageModelSpec(
        id: ModelRepoID("mlx-community/Qwen-Image-Flash-8bit")!, name: "Qwen-Image Flash", publisher: "Qwen · NVIDIA",
        style: "Qwen · text in images", summary: "Qwen-Image distilled to 4 steps (8-bit). Excellent at text and layout.",
        family: .qwenImage, downloadBytes: 29_500_000_000, sizes: ImageSize.qwen, defaultSize: .init(1024, 1024),
        defaultSteps: 4, stepRange: 2...8, defaultCFG: 0, cfgRange: 0...0,
        license: "NVIDIA Open Model License", licenseURL: hf("nvidia/Qwen-Image-Flash"),
        residentBytes: 22_100_000_000, activationBytesPerMP: 8_000_000_000)

    public static let qwenImage2512 = ImageModelSpec(
        id: ModelRepoID("Qwen/Qwen-Image-2512")!, name: "Qwen-Image 2512", publisher: "Qwen",
        style: "Qwen · best quality", summary: "Full Qwen-Image (bf16, 20B). Highest quality, slow: ~30–50 steps.",
        family: .qwenImage, downloadBytes: 57_700_000_000, sizes: ImageSize.qwen, defaultSize: .init(1328, 1328),
        defaultSteps: 30, stepRange: 10...60, defaultCFG: 4, cfgRange: 1.5...8,
        license: "Apache 2.0", licenseURL: hf("Qwen/Qwen-Image-2512"),
        residentBytes: 41_200_000_000, activationBytesPerMP: 12_000_000_000)

    // Z-Image (Alibaba Tongyi): Qwen3-4B encoder resident with the 6B DiT (bf16).
    public static let zImageTurbo = ImageModelSpec(
        id: ModelRepoID("mlx-community/Z-Image-Turbo-bf16")!, name: "Z-Image Turbo", publisher: "Alibaba Tongyi",
        style: "Photoreal · fast", summary: "Photographic detail and bilingual text in 8 steps — one of the best open models.",
        family: .zImage, downloadBytes: 20_500_000_000, sizes: ImageSize.klein, defaultSize: .init(1024, 1024),
        defaultSteps: 8, stepRange: 4...16, defaultCFG: 0, cfgRange: 0...0,
        license: "Apache 2.0", licenseURL: hf("Tongyi-MAI/Z-Image-Turbo"),
        residentBytes: 20_800_000_000, activationBytesPerMP: 12_000_000_000)

    public static let zImageBase = ImageModelSpec(
        id: ModelRepoID("mlx-community/Z-Image-bf16")!, name: "Z-Image", publisher: "Alibaba Tongyi",
        style: "Photoreal · quality", summary: "The undistilled Z-Image: guidance and negative prompts, ~28 steps.",
        family: .zImageBase, downloadBytes: 20_500_000_000, sizes: ImageSize.klein, defaultSize: .init(1024, 1024),
        defaultSteps: 28, stepRange: 10...50, defaultCFG: 4, cfgRange: 1.5...8,
        license: "Apache 2.0", licenseURL: hf("Tongyi-MAI/Z-Image"),
        residentBytes: 20_800_000_000, activationBytesPerMP: 14_000_000_000)

    public static let catalog: [ImageModelSpec] = [
        .zImageTurbo, .dreamShaperTurbo, .flux2Klein, .qwenImageFlash, .sdxlBase, .realVis, .juggernaut, .animagine,
        .zImageBase, .flux2KleinBase, .qwenImage2512, .sdxlTurbo,
    ]

    /// Purposes of the curated models; others get their family's typical use.
    public var purposes: [ImagePurpose] {
        switch id.description {
        case Self.dreamShaperTurbo.id.description: [.general, .fast]
        case Self.flux2Klein.id.description: [.general, .fast, .text]
        case Self.qwenImageFlash.id.description: [.text, .general, .fast]
        case Self.sdxlBase.id.description: [.general]
        case Self.realVis.id.description, Self.juggernaut.id.description: [.photo]
        case Self.animagine.id.description: [.anime]
        case Self.flux2KleinBase.id.description: [.general, .text]
        case Self.qwenImage2512.id.description: [.text, .photo]
        case Self.sdxlTurbo.id.description: [.fast]
        case Self.zImageTurbo.id.description: [.photo, .general, .fast, .text]
        case Self.zImageBase.id.description: [.photo, .general]
        default: family == .qwenImage ? [.text] : family == .zImage || family == .zImageBase ? [.photo] : [.general]
        }
    }

    public static func spec(_ id: String) -> ImageModelSpec? { catalog.first { $0.id.description == id } }

    /// Catalog entry, or defaults for the family of a repository installed by name.
    public static func spec(for id: ModelRepoID, family: ImageFamily? = nil) -> ImageModelSpec {
        if let known = spec(id.description) { return known }
        let family = family ?? .sdxl
        let base: ImageModelSpec
        switch family {
        case .sdxl:
            base = ImageModelSpec(
                id: id, name: "", publisher: "", style: "SDXL", summary: "SDXL checkpoint added from Hugging Face.",
                downloadBytes: 6_940_000_000, sizes: ImageSize.sdxl, defaultSize: .init(1024, 1024),
                defaultSteps: 30, stepRange: 1...60, defaultCFG: 5, cfgRange: 0...15,
                license: "", licenseURL: hf(id.description))
        case .flux2Klein: base = .flux2Klein
        case .flux2KleinBase: base = .flux2KleinBase
        case .qwenImage:
            // Distilled fine-tunes run like Flash; anything else like the full model.
            let lower = id.name.lowercased()
            let distilled = ["flash", "lightning", "turbo", "4step", "8step", "fast"].contains { lower.contains($0) }
            base = distilled ? .qwenImageFlash : .qwenImage2512
        case .zImage: base = .zImageTurbo
        case .zImageBase: base = .zImageBase
        }
        var spec = base
        spec.id = id
        spec.name = id.name.replacingOccurrences(of: "-", with: " ")
        spec.publisher = id.owner
        spec.style = family.displayName
        spec.summary = "\(family.displayName) model added from Hugging Face."
        spec.license = "See the model page"
        spec.licenseURL = hf(id.description)
        spec.isCustom = true
        return spec
    }

    /// The spec of an installed model (its family comes from the install manifest).
    public static func spec(for installed: InstalledModel) -> ImageModelSpec {
        spec(for: installed.id, family: ImageFamily(modelType: installed.manifest.modelType))
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

/// The files of a FLUX.2 / Qwen-Image pipeline: `model_index.json` and every config, tokenizer file and
/// safetensors weight of its components (other weight formats are skipped).
public enum DiffusersFiles {
    static let components: Set<String> = ["transformer", "text_encoder", "tokenizer", "vae", "scheduler"]
    static let extensions: Set<String> = ["json", "safetensors", "txt", "jinja", "model"]
    static let required = [
        "model_index.json", "scheduler/scheduler_config.json", "transformer/config.json", "vae/config.json",
        "text_encoder/config.json",
    ]

    public static func select(from all: [HubFile]) -> (files: [HubFile]?, missing: [String]) {
        let picked = all.filter { f in
            if f.path == "model_index.json" { return true }
            let parts = f.path.split(separator: "/")
            guard parts.count == 2, components.contains(String(parts[0])) else { return false }
            return extensions.contains((f.path as NSString).pathExtension.lowercased())
        }
        let paths = Set(picked.map(\.path))
        var missing = required.filter { !paths.contains($0) }
        for folder in ["transformer", "text_encoder", "vae"] where !paths.contains(where: { $0.hasPrefix(folder + "/") && $0.hasSuffix(".safetensors") }) {
            missing.append("\(folder)/*.safetensors")
        }
        if !paths.contains(where: { $0.hasPrefix("tokenizer/") }) { missing.append("tokenizer/") }
        return (missing.isEmpty ? picked : nil, missing)
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
    /// Seed of each image when they aren't consecutive (random per image); nil = seed, seed+1, …
    public var seeds: [UInt64]?

    /// Seed of image `index` of the batch.
    public func seed(at index: Int) -> UInt64 {
        if let seeds, index < seeds.count { return seeds[index] }
        return seed &+ UInt64(index)
    }

    /// Seeds for `count` images: the first is `seed`, the others random.
    public static func randomSeeds(first seed: UInt64, count: Int) -> [UInt64] {
        [seed] + (1..<max(count, 1)).map { _ in randomSeed() }
    }

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
    /// Replaces the LoRAs on the loaded model without reloading it. nil = not supported (reload instead).
    func setLoRAs(_ loras: [LoRAFile]) async throws -> LoRALoadReport?
    func unload() async
    /// Streams progress and images. Cancelling the consuming task stops at the next step.
    func generate(_ request: ImageRequest) -> AsyncThrowingStream<ImageEvent, Error>
}

extension ImageEngine {
    public func setLoRAs(_ loras: [LoRAFile]) async throws -> LoRALoadReport? { nil }
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
