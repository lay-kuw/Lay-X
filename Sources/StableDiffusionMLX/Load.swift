// Copyright © 2024 Apple Inc.
// Vendored from ml-explore/mlx-swift-examples (MIT, see LICENSE-mlx-swift-examples.txt) and adapted for Lay X:
// weights are read from a local folder (downloaded by Lay X) instead of the Hugging Face cache.

import Foundation
import MLX
import MLXNN

// port of https://github.com/ml-explore/mlx-examples/blob/main/stable_diffusion/stable_diffusion/model_io.py

/// Errors that can occur when loading stable diffusion models.
public enum StableDiffusionError: LocalizedError {
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let filename):
            return "The model file “\(filename)” is missing. Download the model again in Lay X."
        }
    }
}

/// A local folder holding a model's files at their repository-relative paths.
public struct ModelDirectory: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
}

/// Configuration for loading stable diffusion weights.
///
/// These options can be tuned to conserve memory.
public struct LoadConfiguration: Sendable {

    /// convert weights to float16
    public var float16 = true

    /// quantize weights
    public var quantize = false

    /// LoRA adapters merged into the weights while loading (Lay X addition).
    public var loras: LoRASet?

    public var dType: DType {
        float16 ? .float16 : .float32
    }

    public init(float16: Bool = true, quantize: Bool = false, loras: LoRASet? = nil) {
        self.float16 = float16
        self.quantize = quantize
        self.loras = loras
    }
}

/// Parameters for evaluating a stable diffusion prompt and generating latents
/// Lay X: a run of prompt text and its emphasis (1 = normal).
public struct WeightedText: Sendable, Hashable {
    public var text: String
    public var weight: Float
    public init(_ text: String, _ weight: Float = 1) {
        self.text = text
        self.weight = weight
    }
}

public struct EvaluateParameters: Sendable {

    /// `cfg` value from the preset
    public var cfgWeight: Float

    /// number of steps -- default is from the preset
    public var steps: Int

    /// number of images to generate at a time
    public var imageCount = 1
    public var decodingBatchSize = 1

    /// size of the latent tensor -- the result image is a factor of 8 larger than this
    public var latentSize = [64, 64]

    public var seed: UInt64
    public var prompt = ""
    public var negativePrompt = ""
    /// Lay X: the prompts as weighted runs (emphasis syntax already parsed); nil = `prompt` at weight 1.
    public var promptSegments: [WeightedText]?
    public var negativeSegments: [WeightedText]?

    public init(
        cfgWeight: Float, steps: Int, imageCount: Int = 1, decodingBatchSize: Int = 1,
        latentSize: [Int] = [64, 64], seed: UInt64? = nil, prompt: String = "",
        negativePrompt: String = ""
    ) {
        self.cfgWeight = cfgWeight
        self.steps = steps
        self.imageCount = imageCount
        self.decodingBatchSize = decodingBatchSize
        self.latentSize = latentSize
        self.seed = seed ?? UInt64(Date.timeIntervalSinceReferenceDate * 1000)
        self.prompt = prompt
        self.negativePrompt = negativePrompt
    }
}

/// File types for ``StableDiffusionConfiguration/files``. Used by the presets to provide
/// relative file paths for different types of files.
enum FileKey {
    case unetConfig
    case unetWeights
    case textEncoderConfig
    case textEncoderWeights
    case textEncoderConfig2
    case textEncoderWeights2
    case vaeConfig
    case vaeWeights
    case diffusionConfig
    case tokenizerVocabulary
    case tokenizerMerges
    case tokenizerVocabulary2
    case tokenizerMerges2
}

/// Stable diffusion configuration -- this selects the model to load.
///
/// Use the preset values:
/// - ``presetSDXLTurbo``
/// - ``presetStableDiffusion21Base``
///
/// or use the enum (convenient for command line tools):
///
/// - ``Preset/sdxlTurbo``
/// - ``Preset/sdxlTurbo``
///
/// Call ``download(client:progressHandler:)`` to download the weights, then
/// ``textToImageGenerator(client:configuration:)`` or
/// ``imageToImageGenerator(client:configuration:)`` to produce the ``ImageGenerator``.
///
/// The ``ImageGenerator`` has a method to generate the latents:
/// - ``TextToImageGenerator/generateLatents(parameters:)``
/// - ``ImageToImageGenerator/generateLatents(image:parameters:strength:)``
///
/// Evaluate each of the latents from that iterator and use the decoder to turn the last latent
/// into an image:
///
/// - ``ImageGenerator/decode(xt:)``
///
/// Finally use ``Image`` to save it to a file or convert to a CGImage for display.
public struct StableDiffusionConfiguration: Sendable {
    public let id: String
    let files: [FileKey: String]
    public let defaultParameters: @Sendable () -> EvaluateParameters
    let factory:
        @Sendable (ModelDirectory, StableDiffusionConfiguration, LoadConfiguration) throws ->
            StableDiffusion

    /// Repository-relative paths of every file this configuration loads.
    public var requiredFiles: [String] { Array(files.values).sorted() }

    public func textToImageGenerator(client: ModelDirectory, configuration: LoadConfiguration)
        throws -> TextToImageGenerator?
    {
        try factory(client, self, configuration) as? TextToImageGenerator
    }

    public func imageToImageGenerator(
        client: ModelDirectory, configuration: LoadConfiguration
    )
        throws -> ImageToImageGenerator?
    {
        try factory(client, self, configuration) as? ImageToImageGenerator
    }

    /// Any SDXL checkpoint in diffusers layout (Lay X addition): per component, the fp16 file if present,
    /// otherwise the full-precision one.
    public static func sdxl(id: String, directory: URL, defaultSteps: Int = 30, defaultCFG: Float = 6) -> StableDiffusionConfiguration {
        func pick(_ folder: String, _ base: String) -> String {
            let fp16 = "\(folder)/\(base).fp16.safetensors"
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent(fp16).path) ? fp16 : "\(folder)/\(base).safetensors"
        }
        return StableDiffusionConfiguration(
            id: id,
            files: [
                .unetConfig: "unet/config.json",
                .unetWeights: pick("unet", "diffusion_pytorch_model"),
                .textEncoderConfig: "text_encoder/config.json",
                .textEncoderWeights: pick("text_encoder", "model"),
                .textEncoderConfig2: "text_encoder_2/config.json",
                .textEncoderWeights2: pick("text_encoder_2", "model"),
                .vaeConfig: "vae/config.json",
                .vaeWeights: pick("vae", "diffusion_pytorch_model"),
                .diffusionConfig: "scheduler/scheduler_config.json",
                .tokenizerVocabulary: "tokenizer/vocab.json",
                .tokenizerMerges: "tokenizer/merges.txt",
                .tokenizerVocabulary2: "tokenizer_2/vocab.json",
                .tokenizerMerges2: "tokenizer_2/merges.txt",
            ],
            defaultParameters: { EvaluateParameters(cfgWeight: defaultCFG, steps: defaultSteps) },
            factory: { client, sdConfiguration, loadConfiguration in
                let sd = try StableDiffusionXL(
                    client: client, configuration: sdConfiguration, dType: loadConfiguration.dType,
                    loras: loadConfiguration.loras)
                if loadConfiguration.quantize {
                    quantize(model: sd.textEncoder, filter: { k, m in m is Linear })
                    quantize(model: sd.textEncoder2, filter: { k, m in m is Linear })
                    quantize(model: sd.unet, groupSize: 32, bits: 8)
                }
                return sd
            })
    }

    public enum Preset: String, Codable, CaseIterable, Sendable {
        case base
        case sdxlTurbo = "sdxl-turbo"

        public var configuration: StableDiffusionConfiguration {
            switch self {
            case .base: presetStableDiffusion21Base
            case .sdxlTurbo: presetSDXLTurbo
            }
        }
    }

    /// See https://huggingface.co/stabilityai/sdxl-turbo for the model details and license
    public static let presetSDXLTurbo = StableDiffusionConfiguration(
        id: "stabilityai/sdxl-turbo",
        files: [
            .unetConfig: "unet/config.json",
            .unetWeights: "unet/diffusion_pytorch_model.fp16.safetensors",
            .textEncoderConfig: "text_encoder/config.json",
            .textEncoderWeights: "text_encoder/model.fp16.safetensors",
            .textEncoderConfig2: "text_encoder_2/config.json",
            .textEncoderWeights2: "text_encoder_2/model.fp16.safetensors",
            .vaeConfig: "vae/config.json",
            .vaeWeights: "vae/diffusion_pytorch_model.fp16.safetensors",
            .diffusionConfig: "scheduler/scheduler_config.json",
            .tokenizerVocabulary: "tokenizer/vocab.json",
            .tokenizerMerges: "tokenizer/merges.txt",
            .tokenizerVocabulary2: "tokenizer_2/vocab.json",
            .tokenizerMerges2: "tokenizer_2/merges.txt",
        ],
        defaultParameters: { EvaluateParameters(cfgWeight: 0, steps: 2) },
        factory: { client, sdConfiguration, loadConfiguration in
            let sd = try StableDiffusionXL(
                client: client, configuration: sdConfiguration, dType: loadConfiguration.dType,
                loras: loadConfiguration.loras)
            if loadConfiguration.quantize {
                quantize(model: sd.textEncoder, filter: { k, m in m is Linear })
                quantize(model: sd.textEncoder2, filter: { k, m in m is Linear })
                quantize(model: sd.unet, groupSize: 32, bits: 8)
            }
            return sd
        }
    )

    /// See https://huggingface.co/stabilityai/stable-diffusion-2-1-base for the model details and license
    public static let presetStableDiffusion21Base = StableDiffusionConfiguration(
        id: "stabilityai/stable-diffusion-2-1-base",
        files: [
            .unetConfig: "unet/config.json",
            .unetWeights: "unet/diffusion_pytorch_model.fp16.safetensors",
            .textEncoderConfig: "text_encoder/config.json",
            .textEncoderWeights: "text_encoder/model.fp16.safetensors",
            .vaeConfig: "vae/config.json",
            .vaeWeights: "vae/diffusion_pytorch_model.fp16.safetensors",
            .diffusionConfig: "scheduler/scheduler_config.json",
            .tokenizerVocabulary: "tokenizer/vocab.json",
            .tokenizerMerges: "tokenizer/merges.txt",
        ],
        defaultParameters: { EvaluateParameters(cfgWeight: 7.5, steps: 50) },
        factory: { client, sdConfiguration, loadConfiguration in
            let sd = try StableDiffusionBase(
                client: client, configuration: sdConfiguration, dType: loadConfiguration.dType)
            if loadConfiguration.quantize {
                quantize(model: sd.textEncoder, filter: { k, m in m is Linear })
                quantize(model: sd.unet, groupSize: 32, bits: 8)
            }
            return sd
        }
    )

}

// MARK: - Key Mapping

func keyReplace(_ replace: String, _ with: String) -> @Sendable (String) -> String? {
    return { [replace, with] key in
        if key.contains(replace) {
            return key.replacingOccurrences(of: replace, with: with)
        }
        return nil
    }
}

func dropPrefix(_ prefix: String) -> @Sendable (String) -> String? {
    return { [prefix] key in
        if key.hasPrefix(prefix) {
            return String(key.dropFirst(prefix.count))
        }
        return nil
    }
}

// see map_unet_weights()

let unetRules: [@Sendable (String) -> String?] = [
    // Map up/downsampling
    keyReplace("downsamplers.0.conv", "downsample"),
    keyReplace("upsamplers.0.conv", "upsample"),

    // Map the mid block
    keyReplace("mid_block.resnets.0", "mid_blocks.0"),
    keyReplace("mid_block.attentions.0", "mid_blocks.1"),
    keyReplace("mid_block.resnets.1", "mid_blocks.2"),

    // Map attention layers
    keyReplace("to_k", "key_proj"),
    keyReplace("to_out.0", "out_proj"),
    keyReplace("to_q", "query_proj"),
    keyReplace("to_v", "value_proj"),

    // Map transformer ffn
    keyReplace("ff.net.2", "linear3"),
]

func unetRemap(key: String, value: MLXArray) -> [(String, MLXArray)] {
    var key = key
    var value = value

    for rule in unetRules {
        key = rule(key) ?? key
    }

    // Map transformer ffn
    if key.contains("ff.net.0") {
        let k1 = key.replacingOccurrences(of: "ff.net.0.proj", with: "linear1")
        let k2 = key.replacingOccurrences(of: "ff.net.0.proj", with: "linear2")
        let (v1, v2) = value.split()
        return [(k1, v1), (k2, v2)]
    }

    if key.contains("conv_shortcut.weight") {
        value = value.squeezed()
    }

    // Transform the weights from 1x1 convs to linear
    if value.ndim == 4 && (key.contains("proj_in") || key.contains("proj_out")) {
        value = value.squeezed()
    }

    if value.ndim == 4 {
        value = value.transposed(0, 2, 3, 1)
        value = value.reshaped(-1).reshaped(value.shape)
    }

    return [(key, value)]
}

let clipRules: [@Sendable (String) -> String?] = [
    dropPrefix("text_model."),
    dropPrefix("embeddings."),
    dropPrefix("encoder."),

    // Map attention layers
    keyReplace("self_attn.", "attention."),
    keyReplace("q_proj.", "query_proj."),
    keyReplace("k_proj.", "key_proj."),
    keyReplace("v_proj.", "value_proj."),

    // Map ffn layers
    keyReplace("mlp.fc1", "linear1"),
    keyReplace("mlp.fc2", "linear2"),
]

func clipRemap(key: String, value: MLXArray) -> [(String, MLXArray)] {
    var key = key

    for rule in clipRules {
        key = rule(key) ?? key
    }

    // not used
    if key == "position_ids" {
        return []
    }

    return [(key, value)]
}

let vaeRules: [@Sendable (String) -> String?] = [
    // Map up/downsampling
    keyReplace("downsamplers.0.conv", "downsample"),
    keyReplace("upsamplers.0.conv", "upsample"),

    // Map attention layers
    keyReplace("to_k", "key_proj"),
    keyReplace("to_out.0", "out_proj"),
    keyReplace("to_q", "query_proj"),
    keyReplace("to_v", "value_proj"),

    // Map the mid block
    keyReplace("mid_block.resnets.0", "mid_blocks.0"),
    keyReplace("mid_block.attentions.0", "mid_blocks.1"),
    keyReplace("mid_block.resnets.1", "mid_blocks.2"),

    keyReplace("mid_blocks.1.key.", "mid_blocks.1.key_proj."),
    keyReplace("mid_blocks.1.query.", "mid_blocks.1.query_proj."),
    keyReplace("mid_blocks.1.value.", "mid_blocks.1.value_proj."),
    keyReplace("mid_blocks.1.proj_attn.", "mid_blocks.1.out_proj."),

]

func vaeRemap(key: String, value: MLXArray) -> [(String, MLXArray)] {
    var key = key
    var value = value

    for rule in vaeRules {
        key = rule(key) ?? key
    }

    // Map the quant/post_quant layers
    if key.contains("quant_conv") {
        key = key.replacingOccurrences(of: "quant_conv", with: "quant_proj")
        value = value.squeezed()
    }

    // Map the conv_shortcut to linear
    if key.contains("conv_shortcut.weight") {
        value = value.squeezed()
    }

    if value.ndim == 4 {
        value = value.transposed(0, 2, 3, 1)
        value = value.reshaped(-1).reshaped(value.shape)
    }

    return [(key, value)]
}

func loadWeights(
    url: URL, model: Module, mapper: (String, MLXArray) -> [(String, MLXArray)], dType: DType,
    lora: (LoRASet, LoRAComponent)? = nil
) throws {
    var arrays = try loadArrays(url: url)
    if let (set, component) = lora { set.apply(to: &arrays, component: component) }
    let weights = arrays.flatMap { mapper($0.key, $0.value.asType(dType)) }

    // Note: not using verifier because some shapes change upon load
    try model.update(parameters: ModuleParameters.unflattened(weights), verify: .none)
}

// MARK: - Loading

func resolve(client: ModelDirectory, configuration: StableDiffusionConfiguration, key: FileKey) throws
    -> URL
{
    guard let filename = configuration.files[key] else {
        preconditionFailure("configuration \(configuration.id) missing key: \(key)")
    }
    let url = client.url.appendingPathComponent(filename)
    if FileManager.default.fileExists(atPath: url.path) { return url }
    throw StableDiffusionError.fileNotFound(filename)
}

func loadConfiguration<T: Decodable>(
    client: ModelDirectory, configuration: StableDiffusionConfiguration, key: FileKey, type: T.Type
) throws -> T {
    let url = try resolve(client: client, configuration: configuration, key: key)
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

func loadUnet(client: ModelDirectory, configuration: StableDiffusionConfiguration, dType: DType,
              loras: LoRASet? = nil) throws
    -> UNetModel
{
    let unetConfiguration = try loadConfiguration(
        client: client, configuration: configuration, key: .unetConfig, type: UNetConfiguration.self
    )
    let model = UNetModel(configuration: unetConfiguration)

    let weightsURL = try resolve(client: client, configuration: configuration, key: .unetWeights)
    try loadWeights(url: weightsURL, model: model, mapper: unetRemap, dType: dType, lora: loras.map { ($0, .unet) })

    return model
}

func loadTextEncoder(
    client: ModelDirectory, configuration: StableDiffusionConfiguration,
    configKey: FileKey = .textEncoderConfig, weightsKey: FileKey = .textEncoderWeights, dType: DType,
    loras: LoRASet? = nil
) throws -> CLIPTextModel {
    let clipConfiguration = try loadConfiguration(
        client: client, configuration: configuration, key: configKey,
        type: CLIPTextModelConfiguration.self)
    let model = CLIPTextModel(configuration: clipConfiguration)

    let weightsURL = try resolve(client: client, configuration: configuration, key: weightsKey)
    try loadWeights(url: weightsURL, model: model, mapper: clipRemap, dType: dType,
                    lora: loras.map { ($0, configKey == .textEncoderConfig2 ? .textEncoder2 : .textEncoder1) })

    return model
}

func loadAutoEncoder(
    client: ModelDirectory, configuration: StableDiffusionConfiguration, dType: DType
) throws
    -> Autoencoder
{
    let autoEncoderConfiguration = try loadConfiguration(
        client: client, configuration: configuration, key: .vaeConfig,
        type: AutoencoderConfiguration.self
    )
    let model = Autoencoder(configuration: autoEncoderConfiguration)

    let weightsURL = try resolve(client: client, configuration: configuration, key: .vaeWeights)
    try loadWeights(url: weightsURL, model: model, mapper: vaeRemap, dType: dType)

    return model
}

func loadDiffusionConfiguration(
    client: ModelDirectory, configuration: StableDiffusionConfiguration
) throws
    -> DiffusionConfiguration
{
    try loadConfiguration(
        client: client, configuration: configuration, key: .diffusionConfig,
        type: DiffusionConfiguration.self)
}

// MARK: - Tokenizer

func loadTokenizer(
    client: ModelDirectory, configuration: StableDiffusionConfiguration,
    vocabulary: FileKey = .tokenizerVocabulary, merges: FileKey = .tokenizerMerges
) throws -> CLIPTokenizer {
    let vocabularyURL = try resolve(client: client, configuration: configuration, key: vocabulary)
    let mergesURL = try resolve(client: client, configuration: configuration, key: merges)

    let vocabulary = try JSONDecoder().decode(
        [String: Int].self, from: Data(contentsOf: vocabularyURL))
    let merges = try String(contentsOf: mergesURL, encoding: .utf8)
        .components(separatedBy: .newlines)
        // first line is a comment
        .dropFirst()
        .filter { !$0.isEmpty }

    return CLIPTokenizer(merges: merges, vocabulary: vocabulary)
}
