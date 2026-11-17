// Lay X addition: imports a single-file SDXL checkpoint (SGM / "original" layout, as shared on Civitai and
// produced by ComfyUI / A1111) into the diffusers layout the pipeline loads. Pure key renaming and
// reshaping — no network, no Python.

import Foundation
import MLX

public enum SDXLCheckpointError: Error, LocalizedError {
    case notSDXL(String)
    case missingTemplate

    public var errorDescription: String? {
        switch self {
        case .notSDXL(let why): "This file isn’t an SDXL checkpoint (\(why))."
        case .missingTemplate: "An SDXL model in diffusers format is needed for the tokenizer and configs."
        }
    }
}

public enum SDXLCheckpoint {
    /// Weight files written into the diffusers folder.
    public static let outputFiles = [
        "unet/diffusion_pytorch_model.fp16.safetensors", "vae/diffusion_pytorch_model.fp16.safetensors",
        "text_encoder/model.fp16.safetensors", "text_encoder_2/model.fp16.safetensors",
    ]

    /// Converts `file` into a diffusers folder at `output`. Configs, schedulers and tokenizers are copied from
    /// `template` (an installed SDXL model in diffusers layout); weights come from the checkpoint (fp16).
    public static func convert(file: URL, template: URL, to output: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: template.appendingPathComponent("tokenizer_2/vocab.json").path) else {
            throw SDXLCheckpointError.missingTemplate
        }
        let arrays = try loadArrays(url: file)
        var unet: [String: MLXArray] = [:], vae: [String: MLXArray] = [:]
        var clipL: [String: MLXArray] = [:], clipG: [String: MLXArray] = [:]
        for (key, value) in arrays {
            if key.hasPrefix("model.diffusion_model.") {
                if let k = unetKey(String(key.dropFirst("model.diffusion_model.".count))) { unet[k] = value }
            } else if key.hasPrefix("first_stage_model.") {
                if let (k, v) = vaeEntry(String(key.dropFirst("first_stage_model.".count)), value) { vae[k] = v }
            } else if key.hasPrefix("conditioner.embedders.0.transformer.") {
                let k = String(key.dropFirst("conditioner.embedders.0.transformer.".count))
                if !k.hasSuffix("position_ids") { clipL[k] = value }
            } else if key.hasPrefix("conditioner.embedders.1.model.") {
                for (k, v) in openCLIPEntries(String(key.dropFirst("conditioner.embedders.1.model.".count)), value) { clipG[k] = v }
            }
        }
        guard unet.count > 1500 else { throw SDXLCheckpointError.notSDXL("no SDXL UNet weights") }
        guard unet["add_embedding.linear_1.weight"] != nil else { throw SDXLCheckpointError.notSDXL("no SDXL size conditioning") }
        guard vae.count > 200 else { throw SDXLCheckpointError.notSDXL("no VAE weights") }
        guard clipL.count > 100, clipG.count > 100 else { throw SDXLCheckpointError.notSDXL("missing a text encoder") }

        // Non-weight files (configs, scheduler, tokenizers) from the template.
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let wanted = ["model_index.json", "scheduler", "unet", "vae", "text_encoder", "text_encoder_2", "tokenizer", "tokenizer_2"]
        for item in wanted {
            let src = template.appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { continue }
            let dst = output.appendingPathComponent(item)
            if isDir.boolValue {
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                for name in try fm.contentsOfDirectory(atPath: src.path) where !name.hasSuffix(".safetensors") && !name.hasSuffix(".bin")
                    && !name.hasPrefix(".") {
                    try? fm.removeItem(at: dst.appendingPathComponent(name))
                    try fm.copyItem(at: src.appendingPathComponent(name), to: dst.appendingPathComponent(name))
                }
            } else {
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
            }
        }
        func save(_ weights: [String: MLXArray], _ path: String) throws {
            let half = weights.mapValues { $0.dtype == .float16 ? $0 : $0.asType(.float16) }
            try MLX.save(arrays: half, url: output.appendingPathComponent(path))
        }
        try save(unet, outputFiles[0])
        try save(vae, outputFiles[1])
        try save(clipL, outputFiles[2])
        try save(clipG, outputFiles[3])
    }

    // MARK: UNet (SGM → diffusers)

    static func unetKey(_ key: String) -> String? {
        for (sgm, diffusers) in [("time_embed.0.", "time_embedding.linear_1."), ("time_embed.2.", "time_embedding.linear_2."),
                                 ("label_emb.0.0.", "add_embedding.linear_1."), ("label_emb.0.2.", "add_embedding.linear_2."),
                                 ("input_blocks.0.0.", "conv_in."), ("out.0.", "conv_norm_out."), ("out.2.", "conv_out.")]
            where key.hasPrefix(sgm) {
            return diffusers + key.dropFirst(sgm.count)
        }
        let parts = key.split(separator: ".", maxSplits: 3).map(String.init)
        guard parts.count == 4 || (parts.count == 3 && parts[0] == "middle_block") else { return nil }
        func resnet(_ rest: String) -> String {
            for (sgm, diffusers) in [("in_layers.0.", "norm1."), ("in_layers.2.", "conv1."), ("emb_layers.1.", "time_emb_proj."),
                                     ("out_layers.0.", "norm2."), ("out_layers.3.", "conv2."), ("skip_connection.", "conv_shortcut.")]
                where rest.hasPrefix(sgm) {
                return diffusers + rest.dropFirst(sgm.count)
            }
            return rest
        }
        switch parts[0] {
        case "input_blocks":
            guard let n = Int(parts[1]), let kind = Int(parts[2]), n >= 1 else { return nil }
            let block = (n - 1) / 3, layer = (n - 1) % 3, rest = parts[3]
            if layer == 2 { return "down_blocks.\(block).downsamplers.0.conv." + rest.replacingOccurrences(of: "op.", with: "") }
            return kind == 0 ? "down_blocks.\(block).resnets.\(layer).\(resnet(rest))"
                             : "down_blocks.\(block).attentions.\(layer).\(rest)"
        case "middle_block":
            let sub = key.split(separator: ".", maxSplits: 2).map(String.init)
            guard sub.count == 3, let kind = Int(sub[1]) else { return nil }
            switch kind {
            case 0: return "mid_block.resnets.0.\(resnet(sub[2]))"
            case 1: return "mid_block.attentions.0.\(sub[2])"
            case 2: return "mid_block.resnets.1.\(resnet(sub[2]))"
            default: return nil
            }
        case "output_blocks":
            guard let n = Int(parts[1]), let kind = Int(parts[2]) else { return nil }
            let block = n / 3, layer = n % 3, rest = parts[3]
            if kind == 0 { return "up_blocks.\(block).resnets.\(layer).\(resnet(rest))" }
            if rest.hasPrefix("conv.") { return "up_blocks.\(block).upsamplers.0.conv." + rest.dropFirst("conv.".count) }
            return "up_blocks.\(block).attentions.\(layer).\(rest)"
        default:
            return nil
        }
    }

    // MARK: VAE (LDM → diffusers)

    static func vaeEntry(_ key: String, _ value: MLXArray) -> (String, MLXArray)? {
        var k = key
        let upBlocks = 4
        func resnet(_ s: String) -> String { s.replacingOccurrences(of: "nin_shortcut.", with: "conv_shortcut.") }
        for side in ["encoder", "decoder"] {
            k = k.replacingOccurrences(of: "\(side).norm_out.", with: "\(side).conv_norm_out.")
            k = k.replacingOccurrences(of: "\(side).mid.block_1.", with: "\(side).mid_block.resnets.0.")
            k = k.replacingOccurrences(of: "\(side).mid.block_2.", with: "\(side).mid_block.resnets.1.")
            k = k.replacingOccurrences(of: "\(side).mid.attn_1.", with: "\(side).mid_block.attentions.0.")
        }
        let parts = k.split(separator: ".").map(String.init)
        if parts.count > 4, parts[0] == "encoder", parts[1] == "down", let i = Int(parts[2]) {
            let tail = parts[4...].joined(separator: ".")
            if parts[3] == "block", parts.count > 5, let j = Int(parts[4]) {
                k = "encoder.down_blocks.\(i).resnets.\(j).\(resnet(parts[5...].joined(separator: ".")))"
            } else if parts[3] == "downsample" {
                k = "encoder.down_blocks.\(i).downsamplers.0.\(tail)"
            }
        } else if parts.count > 4, parts[0] == "decoder", parts[1] == "up", let i = Int(parts[2]) {
            let b = upBlocks - 1 - i
            let tail = parts[4...].joined(separator: ".")
            if parts[3] == "block", parts.count > 5, let j = Int(parts[4]) {
                k = "decoder.up_blocks.\(b).resnets.\(j).\(resnet(parts[5...].joined(separator: ".")))"
            } else if parts[3] == "upsample" {
                k = "decoder.up_blocks.\(b).upsamplers.0.\(tail)"
            }
        } else if k.contains(".mid_block.resnets.") {
            k = resnet(k)
        }
        var v = value
        if k.contains(".mid_block.attentions.0.") {
            for (ldm, diffusers) in [(".norm.", ".group_norm."), (".q.", ".to_q."), (".k.", ".to_k."), (".v.", ".to_v."),
                                     (".proj_out.", ".to_out.0.")] {
                k = k.replacingOccurrences(of: ".attentions.0" + ldm, with: ".attentions.0" + diffusers)
            }
            // 1×1 convolutions in the checkpoint, linear layers in diffusers.
            if v.ndim == 4, k.hasSuffix("weight") { v = v.reshaped(v.dim(0), v.dim(1)) }
        }
        return (k, v)
    }

    // MARK: OpenCLIP ViT-bigG → CLIPTextModelWithProjection

    static func openCLIPEntries(_ key: String, _ value: MLXArray) -> [(String, MLXArray)] {
        switch key {
        case "token_embedding.weight": return [("text_model.embeddings.token_embedding.weight", value)]
        case "positional_embedding": return [("text_model.embeddings.position_embedding.weight", value)]
        case "ln_final.weight": return [("text_model.final_layer_norm.weight", value)]
        case "ln_final.bias": return [("text_model.final_layer_norm.bias", value)]
        case "text_projection": return [("text_projection.weight", value.transposed())]
        case "logit_scale": return []
        default: break
        }
        let prefix = "transformer.resblocks."
        guard key.hasPrefix(prefix) else { return [] }
        let rest = key.dropFirst(prefix.count)
        guard let dot = rest.firstIndex(of: "."), let n = Int(rest[..<dot]) else { return [] }
        let tail = String(rest[rest.index(after: dot)...])
        let base = "text_model.encoder.layers.\(n)."
        if tail == "attn.in_proj_weight" || tail == "attn.in_proj_bias" {
            let parts = split(value, parts: 3, axis: 0)
            let suffix = tail.hasSuffix("weight") ? "weight" : "bias"
            return [(base + "self_attn.q_proj.\(suffix)", parts[0]), (base + "self_attn.k_proj.\(suffix)", parts[1]),
                    (base + "self_attn.v_proj.\(suffix)", parts[2])]
        }
        for (clip, hf) in [("ln_1.", "layer_norm1."), ("ln_2.", "layer_norm2."), ("attn.out_proj.", "self_attn.out_proj."),
                           ("mlp.c_fc.", "mlp.fc1."), ("mlp.c_proj.", "mlp.fc2.")] where tail.hasPrefix(clip) {
            return [(base + hf + tail.dropFirst(clip.count), value)]
        }
        return []
    }
}
