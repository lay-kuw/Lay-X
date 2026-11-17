import CoreGraphics
import Flux2VAE
import Foundation
import ImageIO
import Klein
import LayXCore
import MLX
import QwenImageEdit
import StableDiffusionMLX
import Tokenizers
import UniformTypeIdentifiers

/// Image generation on MLX. Weights are read from the local model folder only.
/// - SDXL: vendored Stable Diffusion port; LoRAs merged at load.
/// - FLUX.2 klein 4B: `Klein` (Qwen3-4B encoder resident); LoRAs attached at run time; a source image is a reference.
/// - Qwen-Image: `QwenImageEdit`'s text-to-image generator (bf16 or pre-quantized int8); the 7B text encoder is
///   loaded per prompt and released before denoising; LoRAs attached at run time.
/// Calls are serialised by the actor and, in the app, by the inference coordinator's GPU gate.
public actor MLXImageEngine: ImageEngine {
    private enum Loaded {
        case sdxl(StableDiffusionMLX.ModelContainer<TextToImageGenerator>, StableDiffusionConfiguration)
        case klein(KleinRuntime)
        case qwen(QwenRuntime)
    }

    private var loaded: Loaded?

    public init() {}

    public func load(_ spec: ImageModelSpec, directory: URL, loras: [LoRAFile]) async throws -> LoRALoadReport {
        await unload()
        do {
            switch spec.family {
            case .sdxl:
                let config = StableDiffusionConfiguration.sdxl(
                    id: spec.id.description, directory: directory, defaultSteps: spec.defaultSteps, defaultCFG: Float(spec.defaultCFG))
                let set = loras.isEmpty ? nil : try LoRASet(files: loras.map { ($0.url, Float($0.scale)) })
                let container = try StableDiffusionMLX.ModelContainer<TextToImageGenerator>.createTextToImageGenerator(
                    directory: ModelDirectory(url: directory), configuration: config,
                    loadConfiguration: LoadConfiguration(float16: true, quantize: false, loras: set))
                try await container.perform { $0.ensureLoaded() }
                loaded = .sdxl(container, config)
                Memory.clearCache()
                return LoRALoadReport(appliedLayers: set?.report.appliedLayers ?? 0, skippedLayers: set?.report.skippedLayers ?? 0)
            case .flux2Klein, .flux2KleinBase:
                let runtime = try await KleinRuntime(directory: directory)
                loaded = .klein(runtime)
                Memory.clearCache()
                return try runtime.setLoRAs(loras)
            case .qwenImage:
                let runtime = try QwenRuntime(directory: directory)
                loaded = .qwen(runtime)
                Memory.clearCache()
                return try runtime.setLoRAs(loras)
            }
        } catch {
            loaded = nil
            Memory.clearCache()
            throw ImageEngineError.loadFailed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    public func setLoRAs(_ loras: [LoRAFile]) async throws -> LoRALoadReport? {
        do {
            switch loaded {
            case .klein(let runtime): return try runtime.setLoRAs(loras)
            case .qwen(let runtime): return try runtime.setLoRAs(loras)
            case .sdxl, nil: return nil
            }
        } catch {
            throw ImageEngineError.loadFailed("the LoRA couldn’t be applied: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
    }

    public func unload() async {
        loaded = nil
        Memory.clearCache()
    }

    public nonisolated func generate(_ request: ImageRequest) -> AsyncThrowingStream<ImageEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ImageEvent.self)
        let task = Task { await self.run(request, continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func run(_ request: ImageRequest, _ continuation: AsyncThrowingStream<ImageEvent, Error>.Continuation) async {
        guard let loaded else {
            continuation.finish(throwing: ImageEngineError.notLoaded)
            return
        }
        do {
            // One image at a time (seed, seed+1, …): lower peak memory than a batch, and each appears as soon
            // as it is ready.
            for index in 0..<request.count {
                try Task.checkCancellation()
                let seed = request.seed(at: index)
                let total = request.effectiveSteps
                continuation.yield(.progress(index: index, step: 0, total: total))
                let onStep: @Sendable (Int, Int) -> Void = { step, steps in
                    continuation.yield(.progress(index: index, step: step, total: steps))
                }
                let png: Data
                switch loaded {
                case .sdxl(let generator, let configuration):
                    png = try await Self.runSDXL(request, seed: seed, generator: generator, configuration: configuration, onStep: onStep)
                case .klein(let runtime):
                    png = try runtime.generate(request, seed: seed, onStep: onStep)
                case .qwen(let runtime):
                    png = try await runtime.generate(request, seed: seed, onStep: onStep)
                }
                Memory.clearCache()
                continuation.yield(.image(index: index, png: png, seed: seed))
            }
            continuation.finish()
        } catch {
            Memory.clearCache()
            let cancelled = error is CancellationError || Task.isCancelled
            continuation.finish(throwing: cancelled ? CancellationError()
                                : (error as? ImageEngineError) ?? ImageEngineError.generationFailed((error as? LocalizedError)?.errorDescription ?? "\(error)"))
        }
    }

    // MARK: SDXL

    private static func runSDXL(_ request: ImageRequest, seed: UInt64,
                                generator: StableDiffusionMLX.ModelContainer<TextToImageGenerator>,
                                configuration: StableDiffusionConfiguration,
                                onStep: @escaping @Sendable (Int, Int) -> Void) async throws -> Data {
        var parameters = configuration.defaultParameters()
        parameters.prompt = request.prompt
        parameters.negativePrompt = request.negativePrompt
        parameters.steps = request.steps
        parameters.cfgWeight = Float(request.cfg)
        parameters.seed = seed
        parameters.latentSize = [request.size.height / 8, request.size.width / 8]
        parameters.imageCount = 1
        let total = request.effectiveSteps
        let source = try request.source.map { try sourcePixels($0, size: request.size) }
        let strength = Float(request.strength)
        return try await generator.perform { [parameters] model in
            var last: MLXArray?
            var step = 0
            let latents: DenoiseIterator
            if let source {
                guard let i2i = model as? ImageToImageGenerator else {
                    throw ImageEngineError.generationFailed("this model can’t start from an image")
                }
                // RGB bytes → [-1, 1]
                let pixels = MLXArray(source.bytes, [source.height, source.width, 3])
                latents = i2i.generateLatents(image: (pixels.asType(.float32) / 255) * 2 - 1,
                                              parameters: parameters, strength: strength)
            } else {
                latents = model.generateLatents(parameters: parameters)
            }
            for xt in latents {
                if Task.isCancelled { throw CancellationError() }
                eval(xt)
                last = xt
                step += 1
                onStep(step, total)
            }
            guard let last else { throw ImageEngineError.generationFailed("no steps were run") }
            if Task.isCancelled { throw CancellationError() }
            let decoded = model.decode(xt: last)
            let raster = (decoded * 255).asType(.uint8).squeezed()
            eval(raster)
            guard let png = pngData(StableDiffusionMLX.Image(raster).asCGImage()) else {
                throw ImageEngineError.generationFailed("the image couldn’t be encoded")
            }
            return png
        }
    }

    // MARK: Pixels

    struct Pixels: Sendable {
        var bytes: [UInt8]
        var width: Int
        var height: Int
    }

    static func cgImage(_ data: Data) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ImageEngineError.generationFailed("the source image couldn’t be read")
        }
        return image
    }

    /// Decodes the source picture and center-crops / scales it to `size` (RGB, 8-bit).
    static func sourcePixels(_ data: Data, size: ImageSize) throws -> Pixels {
        let image = try cgImage(data)
        let w = size.width, h = size.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let scale = max(Double(w) / Double(image.width), Double(h) / Double(image.height))
        let dw = Double(image.width) * scale, dh = Double(image.height) * scale
        let ok = rgba.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: (Double(w) - dw) / 2, y: (Double(h) - dh) / 2, width: dw, height: dh))
            return true
        }
        guard ok else { throw ImageEngineError.generationFailed("the source image couldn’t be prepared") }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = rgba[i * 4]; rgb[i * 3 + 1] = rgba[i * 4 + 1]; rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return Pixels(bytes: rgb, width: w, height: h)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Layers adapted by these LoRAs (one down/A matrix per layer; the largest file when several overlap).
    /// The swappers already refused any LoRA with tensors that don't map onto the model.
    static func loraLayerCount(_ loras: [LoRAFile]) -> Int {
        loras.map { lora -> Int in
            guard let handle = try? FileHandle(forReadingFrom: lora.url) else { return 0 }
            defer { try? handle.close() }
            guard let lengthData = try? handle.read(upToCount: 8), lengthData.count == 8 else { return 0 }
            let length = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
            guard length < 100_000_000, let json = try? handle.read(upToCount: Int(length)),
                  let header = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return 0 }
            return header.keys.filter { $0.contains("lora_A") || $0.contains("lora_down") || $0.contains("lora.down") }.count
        }.max() ?? 0
    }

    /// Interleaved RGB8 → PNG.
    static func pngData(rgb: [UInt8], width: Int, height: Int) throws -> Data {
        guard rgb.count == width * height * 3, width > 0, height > 0 else { throw CancellationError() }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = rgb[i * 3]; rgba[i * 4 + 1] = rgb[i * 3 + 1]; rgba[i * 4 + 2] = rgb[i * 3 + 2]
        }
        let image: CGImage? = rgba.withUnsafeMutableBytes { ptr in
            CGContext(data: ptr.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)?.makeImage()
        }
        guard let image, let png = pngData(image) else {
            throw ImageEngineError.generationFailed("the image couldn’t be encoded")
        }
        return png
    }
}

// MARK: - FLUX.2 klein

/// A loaded FLUX.2 klein 4B pipeline (DiT, VAE + encoder for references, Qwen3-4B conditioner).
final class KleinRuntime {
    let generator: KleinGenerator
    let swapper: KleinLoRASwapper
    private var applied: [LoRAFile] = []

    init(directory: URL) async throws {
        let path = directory.path
        let transformer = try KleinWeights.loadTransformer(snapshotPath: path, dtype: .bfloat16)
        swapper = KleinLoRASwapper(model: transformer, dtype: .bfloat16)
        let vaeDir = directory.appendingPathComponent("vae")
        let vae = try Flux2VAEWeights.loadVAE(directory: vaeDir, dtype: .float32)
        let vaeEncoder = try KleinWeights.loadVAEEncoder(snapshotPath: path, dtype: .float32)
        // Batch-norm statistics of the latent space (reference images are normalised with them).
        var bnMean: MLXArray?, bnVar: MLXArray?
        let vaeFiles = (try? FileManager.default.contentsOfDirectory(at: vaeDir, includingPropertiesForKeys: nil)) ?? []
        for file in vaeFiles where file.pathExtension == "safetensors" {
            let arrays = try MLX.loadArrays(url: file)
            bnMean = bnMean ?? arrays["bn.running_mean"]
            bnVar = bnVar ?? arrays["bn.running_var"]
        }
        guard let bnMean, let bnVar else { throw ImageEngineError.loadFailed("the VAE has no latent statistics (bn.running_mean)") }
        let mean = bnMean.asType(.float32).reshaped(1, -1, 1, 1)
        let std = MLX.sqrt(bnVar.asType(.float32).reshaped(1, -1, 1, 1) + 1e-4)
        eval(mean, std)
        let encoder = try KleinWeights.loadTextEncoder(snapshotPath: path, dtype: .bfloat16)
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory.appendingPathComponent("tokenizer"))
        generator = KleinGenerator(transformer: transformer, vae: vae,
                                   textEncoder: KleinTextEncoder(encoder: encoder, tokenizer: tokenizer),
                                   transformerDtype: .bfloat16, vaeEncoder: vaeEncoder, bnMean: mean, bnStd: std)
    }

    func setLoRAs(_ loras: [LoRAFile]) throws -> LoRALoadReport {
        if loras != applied {
            do {
                try swapper.set(loras.map { ($0.url, Float($0.scale)) })
            } catch {
                applied = []
                swapper.detach()
                throw error
            }
            applied = loras
        }
        return LoRALoadReport(appliedLayers: loras.isEmpty ? 0 : MLXImageEngine.loraLayerCount(loras))
    }

    func generate(_ request: ImageRequest, seed: UInt64, onStep: @escaping @Sendable (Int, Int) -> Void) throws -> Data {
        let w = request.size.width / 16 * 16, h = request.size.height / 16 * 16
        let guided = request.cfg > 1
        let guidance = Float(guided ? request.cfg : 1)
        let negative = guided ? request.negativePrompt : nil
        let result: (pixels: [UInt8], width: Int, height: Int)
        if let source = request.source {
            let reference = KleinReference.pixels(try MLXImageEngine.cgImage(source),
                                                  maxArea: KleinReference.maxArea(outputWidth: w, outputHeight: h))
            result = generator.generateEdit(prompt: request.prompt, referenceImages: [reference], width: w, height: h,
                                            steps: request.steps, seed: seed, negativePrompt: negative,
                                            guidanceScale: guidance, onStep: onStep)
        } else {
            result = generator.generate(prompt: request.prompt, width: w, height: h, steps: request.steps, seed: seed,
                                        negativePrompt: negative, guidanceScale: guidance, onStep: onStep)
        }
        // Empty pixels = the run stopped at a step boundary because the task was cancelled.
        if Task.isCancelled || result.pixels.isEmpty { throw CancellationError() }
        return try MLXImageEngine.pngData(rgb: result.pixels, width: result.width, height: result.height)
    }
}

// MARK: - Qwen-Image

/// A loaded Qwen-Image text-to-image pipeline.
final class QwenRuntime {
    private let directory: URL
    private let transformer: QwenImageTransformer2DModel
    private let vae: QwenImageVAE
    private let swapper: QwenImageEditLoRASwapper
    private let encoderWeights: String?
    private let scheduler: Scheduler
    private var generator: QwenImageT2IGenerator
    private var applied: [LoRAFile] = []

    /// The scheduler's time shift: fixed (Flash: 3.0) or, for the full model, from the image's token count.
    struct Scheduler {
        var shift: Float = 3
        var dynamic = false
        var baseSeqLen = 256, maxSeqLen = 8192
        var baseShift: Float = 0.5, maxShift: Float = 0.9

        init(directory: URL) {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("scheduler/scheduler_config.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            shift = (json["shift"] as? NSNumber)?.floatValue ?? 3
            dynamic = json["use_dynamic_shifting"] as? Bool ?? false
            baseSeqLen = json["base_image_seq_len"] as? Int ?? baseSeqLen
            maxSeqLen = json["max_image_seq_len"] as? Int ?? maxSeqLen
            baseShift = (json["base_shift"] as? NSNumber)?.floatValue ?? baseShift
            maxShift = (json["max_shift"] as? NSNumber)?.floatValue ?? maxShift
        }

        /// Exponential time shift exp(mu) equals the static shift formula with shift = exp(mu).
        func shift(for size: ImageSize) -> Float {
            guard dynamic else { return shift }
            let mu = QwenImagePipeline.calculateShift(imageSeqLen: (size.width / 16) * (size.height / 16),
                                                      baseSeqLen: baseSeqLen, maxSeqLen: maxSeqLen,
                                                      baseShift: baseShift, maxShift: maxShift)
            return (exp(mu) * 100).rounded() / 100
        }
    }

    init(directory: URL) throws {
        self.directory = directory
        let int8DiT = directory.appendingPathComponent("transformer/model-int8.safetensors")
        let int8Encoder = directory.appendingPathComponent("text_encoder/model-int8.safetensors")
        if FileManager.default.fileExists(atPath: int8DiT.path) {
            transformer = try QwenImageEditWeights.loadQuantizedDiT(from: int8DiT)
            encoderWeights = int8Encoder.path
        } else {
            transformer = try QwenImageEditWeights.loadDiTFromPT(directory: directory.appendingPathComponent("transformer"), dtype: .bfloat16)
            encoderWeights = nil
        }
        vae = try QwenImageEditWeights.loadVAE(directory: directory.appendingPathComponent("vae"), dtype: .float32)
        swapper = QwenImageEditLoRASwapper(model: transformer)
        scheduler = Scheduler(directory: directory)
        generator = Self.makeGenerator(directory: directory, encoderWeights: encoderWeights, transformer: transformer, vae: vae,
                                       shift: scheduler.shift(for: .init(1024, 1024)))
        generator.warmup()
    }

    private static func makeGenerator(directory: URL, encoderWeights: String?, transformer: QwenImageTransformer2DModel,
                                      vae: QwenImageVAE, shift: Float) -> QwenImageT2IGenerator {
        QwenImageT2IGenerator(
            encoderProvider: { try await QwenVLPromptEncoder.loadTextOnly(snapshot: directory, quantizedTextModelPath: encoderWeights) },
            transformer: transformer, vae: vae, shift: shift)
    }

    func setLoRAs(_ loras: [LoRAFile]) throws -> LoRALoadReport {
        if loras != applied {
            do {
                try swapper.set(loras.map { ($0.url, Float($0.scale)) })
            } catch {
                applied = []
                swapper.detach()
                throw error
            }
            applied = loras
        }
        return LoRALoadReport(appliedLayers: loras.isEmpty ? 0 : MLXImageEngine.loraLayerCount(loras))
    }

    func generate(_ request: ImageRequest, seed: UInt64, onStep: @escaping @Sendable (Int, Int) -> Void,
                  isolation: isolated (any Actor)? = #isolation) async throws -> Data {
        let shift = scheduler.shift(for: request.size)
        if shift != generator.shift {
            generator = Self.makeGenerator(directory: directory, encoderWeights: encoderWeights, transformer: transformer, vae: vae, shift: shift)
        }
        let guided = request.cfg > 1
        let negative = request.negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await generator.generate(
            prompt: request.prompt, negativePrompt: negative.isEmpty ? " " : negative,
            width: request.size.width, height: request.size.height, steps: request.steps,
            trueCFGScale: Float(guided ? request.cfg : 1), seed: seed, progress: { onStep($0, $1) })
        if Task.isCancelled { throw CancellationError() }
        return try MLXImageEngine.pngData(rgb: result.pixels, width: result.width, height: result.height)
    }
}

// MARK: - Checkpoint import

/// Converts a single-file SDXL checkpoint (Civitai / ComfyUI / A1111 format) into a diffusers model folder.
public enum ImageModelImport {
    /// `template`: an installed SDXL model in diffusers layout (tokenizers and configs are copied from it).
    public static func sdxlCheckpoint(_ file: URL, template: URL, to output: URL) throws {
        do {
            try SDXLCheckpoint.convert(file: file, template: template, to: output)
            Memory.clearCache()
        } catch {
            Memory.clearCache()
            throw error
        }
    }
}
