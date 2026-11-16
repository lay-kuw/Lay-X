import CoreGraphics
import Foundation
import ImageIO
import LayXCore
import MLX
import StableDiffusionMLX
import UniformTypeIdentifiers

/// Image generation on MLX (vendored Stable Diffusion port). Weights are read from the local model folder only.
/// Calls are serialised by the actor and, in the app, by the inference coordinator's GPU gate.
public actor MLXImageEngine: ImageEngine {
    private var generator: StableDiffusionMLX.ModelContainer<TextToImageGenerator>?
    private var configuration: StableDiffusionConfiguration?

    public init() {}

    /// Every supported model is an SDXL pipeline in diffusers layout; files are picked from the folder.
    public func load(_ spec: ImageModelSpec, directory: URL, loras: [LoRAFile]) async throws -> LoRALoadReport {
        await unload()
        let config = StableDiffusionConfiguration.sdxl(
            id: spec.id.description, directory: directory, defaultSteps: spec.defaultSteps, defaultCFG: Float(spec.defaultCFG))
        do {
            let set = loras.isEmpty ? nil : try LoRASet(files: loras.map { ($0.url, Float($0.scale)) })
            let container = try StableDiffusionMLX.ModelContainer<TextToImageGenerator>.createTextToImageGenerator(
                directory: ModelDirectory(url: directory), configuration: config,
                loadConfiguration: LoadConfiguration(float16: true, quantize: false, loras: set))
            try await container.perform { $0.ensureLoaded() }
            generator = container
            configuration = config
            Memory.clearCache()
            return LoRALoadReport(appliedLayers: set?.report.appliedLayers ?? 0, skippedLayers: set?.report.skippedLayers ?? 0)
        } catch {
            Memory.clearCache()
            throw ImageEngineError.loadFailed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    public func unload() async {
        generator = nil
        configuration = nil
        Memory.clearCache()
    }

    public nonisolated func generate(_ request: ImageRequest) -> AsyncThrowingStream<ImageEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ImageEvent.self)
        let task = Task { await self.run(request, continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func run(_ request: ImageRequest, _ continuation: AsyncThrowingStream<ImageEvent, Error>.Continuation) async {
        guard let generator, let configuration else {
            continuation.finish(throwing: ImageEngineError.notLoaded)
            return
        }
        do {
            // One image at a time (seed, seed+1, …): lower peak memory than a batch, and each appears as soon
            // as it is ready.
            for index in 0..<request.count {
                try Task.checkCancellation()
                var parameters = configuration.defaultParameters()
                parameters.prompt = request.prompt
                parameters.negativePrompt = request.negativePrompt
                parameters.steps = request.steps
                parameters.cfgWeight = Float(request.cfg)
                parameters.seed = request.seed &+ UInt64(index)
                parameters.latentSize = [request.size.height / 8, request.size.width / 8]
                parameters.imageCount = 1
                let seed = parameters.seed
                let total = request.effectiveSteps
                let source = try request.source.map { try Self.sourcePixels($0, size: request.size) }
                let strength = Float(request.strength)
                continuation.yield(.progress(index: index, step: 0, total: total))
                let png: Data = try await generator.perform { [parameters] model in
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
                        continuation.yield(.progress(index: index, step: step, total: total))
                    }
                    guard let last else { throw ImageEngineError.generationFailed("no steps were run") }
                    if Task.isCancelled { throw CancellationError() }
                    let decoded = model.decode(xt: last)
                    let raster = (decoded * 255).asType(.uint8).squeezed()
                    eval(raster)
                    guard let png = Self.pngData(StableDiffusionMLX.Image(raster).asCGImage()) else {
                        throw ImageEngineError.generationFailed("the image couldn’t be encoded")
                    }
                    return png
                }
                Memory.clearCache()
                continuation.yield(.image(index: index, png: png, seed: seed))
            }
            continuation.finish()
        } catch {
            Memory.clearCache()
            continuation.finish(throwing: error is CancellationError ? CancellationError()
                                : (error as? ImageEngineError) ?? ImageEngineError.generationFailed("\(error)"))
        }
    }

    struct Pixels: Sendable {
        var bytes: [UInt8]
        var width: Int
        var height: Int
    }

    /// Decodes the source picture and center-crops / scales it to `size` (RGB, 8-bit).
    static func sourcePixels(_ data: Data, size: ImageSize) throws -> Pixels {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ImageEngineError.generationFailed("the source image couldn’t be read")
        }
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
}
