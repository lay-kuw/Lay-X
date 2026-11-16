import Foundation

/// An image model Lay X knows how to run (downloaded once, then used offline).
public struct ImageModelSpec: Sendable, Hashable, Identifiable {
    public var id: ModelRepoID
    public var name: String
    public var publisher: String
    /// Repository-relative files the pipeline loads (exactly these are downloaded).
    public var files: [String]
    /// Download size (approximate, for display before the file list is fetched).
    public var downloadBytes: Int64
    /// Memory needed while loaded and generating (weights + activations), used for memory arbitration.
    public var runtimeBytes: Int64
    public var modelType: String
    public var resolution: Int
    public var defaultSteps: Int
    public var stepChoices: [Int]
    public var supportsNegativePrompt: Bool
    public var license: String
    public var licenseURL: URL

    /// SDXL Turbo (Stability AI): 512×512, 1–4 steps, no classifier-free guidance.
    public static let sdxlTurbo = ImageModelSpec(
        id: ModelRepoID("stabilityai/sdxl-turbo")!,
        name: "SDXL Turbo", publisher: "Stability AI",
        files: [
            "model_index.json",
            "scheduler/scheduler_config.json",
            "text_encoder/config.json", "text_encoder/model.fp16.safetensors",
            "text_encoder_2/config.json", "text_encoder_2/model.fp16.safetensors",
            "tokenizer/merges.txt", "tokenizer/vocab.json",
            "tokenizer_2/merges.txt", "tokenizer_2/vocab.json",
            "unet/config.json", "unet/diffusion_pytorch_model.fp16.safetensors",
            "vae/config.json", "vae/diffusion_pytorch_model.fp16.safetensors",
        ],
        downloadBytes: 6_950_000_000,
        runtimeBytes: 9_500_000_000,
        modelType: "sdxl-turbo",
        resolution: 512, defaultSteps: 2, stepChoices: [1, 2, 3, 4],
        supportsNegativePrompt: false,
        license: "Stability AI Community License",
        licenseURL: URL(string: "https://huggingface.co/stabilityai/sdxl-turbo/blob/main/LICENSE.md")!)

    public static let catalog: [ImageModelSpec] = [.sdxlTurbo]
    public static func spec(_ id: String) -> ImageModelSpec? { catalog.first { $0.id.description == id } }

    public var downloadProfile: DownloadProfile { .image(modelType: modelType, files: files) }
}

public struct ImageRequest: Sendable, Hashable {
    public var prompt: String
    public var negativePrompt: String
    public var steps: Int
    public var seed: UInt64
    public var count: Int
    public var size: Int

    public init(prompt: String, negativePrompt: String = "", steps: Int, seed: UInt64, count: Int = 1, size: Int = 512) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.steps = steps
        self.seed = seed
        self.count = count
        self.size = size
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
            String(format: "Not enough free memory for the image model (needs about %.0f GB, %.0f GB free). Close other apps or unload the chat model.", need, have)
        }
    }
}

/// Image generation backend (MLX in the app; scripted in tests).
public protocol ImageEngine: Sendable {
    func load(_ spec: ImageModelSpec, directory: URL) async throws
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
    public var width: Int
    public var height: Int
    /// File name inside the images folder.
    public var file: String
    public var duration: Double

    public init(id: UUID = UUID(), createdAt: Date = Date(), prompt: String, negativePrompt: String = "", modelID: String,
                seed: UInt64, steps: Int, width: Int, height: Int, file: String, duration: Double) {
        self.id = id
        self.createdAt = createdAt
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.modelID = modelID
        self.seed = seed
        self.steps = steps
        self.width = width
        self.height = height
        self.file = file
        self.duration = duration
    }
}
