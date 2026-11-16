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

    static func configuration(for spec: ImageModelSpec) -> StableDiffusionConfiguration? {
        switch spec.modelType {
        case "sdxl-turbo": StableDiffusionConfiguration.presetSDXLTurbo
        default: nil
        }
    }

    public func load(_ spec: ImageModelSpec, directory: URL) async throws {
        await unload()
        guard let config = Self.configuration(for: spec) else {
            throw ImageEngineError.loadFailed("unsupported image model \(spec.modelType)")
        }
        do {
            let container = try StableDiffusionMLX.ModelContainer<TextToImageGenerator>.createTextToImageGenerator(
                directory: ModelDirectory(url: directory), configuration: config,
                loadConfiguration: LoadConfiguration(float16: true, quantize: false))
            try await container.perform { $0.ensureLoaded() }
            generator = container
            configuration = config
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
                parameters.seed = request.seed &+ UInt64(index)
                parameters.latentSize = [request.size / 8, request.size / 8]
                parameters.imageCount = 1
                let seed = parameters.seed
                let total = parameters.steps
                continuation.yield(.progress(index: index, step: 0, total: total))
                let png: Data = try await generator.perform { [parameters] model in
                    var last: MLXArray?
                    var step = 0
                    for xt in model.generateLatents(parameters: parameters) {
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

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
