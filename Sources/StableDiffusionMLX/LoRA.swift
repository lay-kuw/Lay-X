// Lay X addition (not part of the upstream mlx-swift-examples port): LoRA adapters for SDXL, merged into the
// weights while they are loaded. Supports kohya (`lora_unet_….lora_down/up`, `.alpha`) and diffusers / PEFT
// (`unet.….lora_A/B`, `….lora.down/up`, `…to_q_lora.down`) naming, for linear and convolution layers.

import Foundation
import MLX

public enum LoRAComponent: Sendable, Hashable {
    case unet, textEncoder1, textEncoder2
}

/// What a set of LoRA files changed (for the UI).
public struct LoRAReport: Sendable, Hashable {
    public var appliedLayers = 0
    /// LoRA layers whose target wasn't found or didn't fit (wrong base model, unsupported LyCORIS type…).
    public var skippedLayers = 0
}

/// Parsed LoRA files. Not Sendable by nature (holds MLXArrays); created and used inside one load.
public final class LoRASet: @unchecked Sendable {
    struct Pair {
        var down: MLXArray?
        var up: MLXArray?
        var alpha: Float?
        var scale: Float
    }

    /// component → underscore module name (e.g. `down_blocks_1_attentions_0_proj_in`) → adapters
    private var pairs: [LoRAComponent: [String: [Pair]]] = [:]
    public private(set) var report = LoRAReport()

    /// - Parameter files: LoRA safetensors with their strengths.
    public init(files: [(url: URL, scale: Float)]) throws {
        for (url, scale) in files {
            let arrays = try loadArrays(url: url)
            var local: [LoRAComponent: [String: Pair]] = [:]
            for (key, value) in arrays {
                guard let (component, module, role) = Self.classify(key) else { continue }
                var p = local[component, default: [:]][module] ?? Pair(scale: scale)
                switch role {
                case .down: p.down = value
                case .up: p.up = value
                case .alpha: p.alpha = value.asType(.float32).item(Float.self)
                }
                local[component, default: [:]][module] = p
            }
            for (component, modules) in local {
                for (module, pair) in modules where pair.down != nil && pair.up != nil {
                    pairs[component, default: [:]][module, default: []].append(pair)
                }
            }
        }
    }

    enum Role { case down, up, alpha }

    /// Splits a LoRA tensor name into (component, underscore module name, role).
    static func classify(_ rawKey: String) -> (LoRAComponent, String, Role)? {
        var key = rawKey
        let role: Role
        let suffixes: [(String, Role)] = [
            (".lora_down.weight", .down), (".lora_up.weight", .up), (".alpha", .alpha),
            (".lora_A.weight", .down), (".lora_B.weight", .up),
            (".lora_A.default.weight", .down), (".lora_B.default.weight", .up),
            (".lora.down.weight", .down), (".lora.up.weight", .up),
            ("_lora.down.weight", .down), ("_lora.up.weight", .up),
        ]
        guard let (suffix, r) = suffixes.first(where: { key.hasSuffix($0.0) }) else { return nil }
        role = r
        key.removeLast(suffix.count)

        let component: LoRAComponent
        let prefixes: [(String, LoRAComponent)] = [
            ("lora_unet_", .unet), ("lora_te1_", .textEncoder1), ("lora_te2_", .textEncoder2),
            ("unet.", .unet), ("text_encoder_2.", .textEncoder2), ("text_encoder.", .textEncoder1),
            ("base_model.model.", .unet),
        ]
        guard let (prefix, c) = prefixes.first(where: { key.hasPrefix($0.0) }) else { return nil }
        component = c
        key.removeFirst(prefix.count)
        // Older diffusers attention-processor names.
        key = key.replacingOccurrences(of: ".processor.", with: ".")
        if key.hasSuffix(".to_out") { key += ".0" }
        var module = key.replacingOccurrences(of: ".", with: "_")
        if component == .unet, let converted = sgmToDiffusers(module) { module = converted }
        return (component, module, role)
    }

    /// kohya SDXL LoRAs often use the original (SGM) UNet layout: `input_blocks_4_1_…`, `middle_block_1_…`,
    /// `output_blocks_3_1_…`. Maps those block prefixes (and resnet layer names) to diffusers names.
    static func sgmToDiffusers(_ module: String) -> String? {
        let parts = module.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        func resnetTail(_ rest: [String]) -> String {
            let t = rest.joined(separator: "_")
            for (sgm, diff) in [("in_layers_2", "conv1"), ("out_layers_3", "conv2"), ("emb_layers_1", "time_emb_proj"),
                                ("skip_connection", "conv_shortcut"), ("in_layers_0", "norm1"), ("out_layers_0", "norm2")]
                where t == sgm { return diff }
            return t
        }
        if module.hasPrefix("input_blocks_"), parts.count > 3, let n = Int(parts[2]), let kind = Int(parts[3]), n >= 1 {
            let block = (n - 1) / 3, layer = (n - 1) % 3
            let rest = Array(parts[4...])
            if layer == 2 { return "down_blocks_\(block)_downsamplers_0_conv" }
            return kind == 0 ? "down_blocks_\(block)_resnets_\(layer)_\(resnetTail(rest))"
                             : "down_blocks_\(block)_attentions_\(layer)_\(rest.joined(separator: "_"))"
        }
        if module.hasPrefix("middle_block_"), parts.count > 2, let kind = Int(parts[2]) {
            let rest = Array(parts[3...])
            switch kind {
            case 0: return "mid_block_resnets_0_\(resnetTail(rest))"
            case 1: return "mid_block_attentions_0_\(rest.joined(separator: "_"))"
            case 2: return "mid_block_resnets_1_\(resnetTail(rest))"
            default: return nil
            }
        }
        if module.hasPrefix("output_blocks_"), parts.count > 3, let n = Int(parts[2]), let kind = Int(parts[3]) {
            let block = n / 3, layer = n % 3
            let rest = Array(parts[4...])
            switch kind {
            case 0: return "up_blocks_\(block)_resnets_\(layer)_\(resnetTail(rest))"
            case 1 where block < 2: return "up_blocks_\(block)_attentions_\(layer)_\(rest.joined(separator: "_"))"
            default: return "up_blocks_\(block)_upsamplers_0_conv"
            }
        }
        return nil
    }

    /// Adds `scale · (alpha/rank) · up·down` to every matching weight (diffusers key names) of `component`.
    func apply(to weights: inout [String: MLXArray], component: LoRAComponent) {
        guard let modules = pairs[component], !modules.isEmpty else { return }
        var matched = Set<String>()
        for (key, base) in weights where key.hasSuffix(".weight") {
            let module = String(key.dropLast(".weight".count)).replacingOccurrences(of: ".", with: "_")
            guard let adapters = modules[module] else { continue }
            var merged = base.asType(.float32)
            var used = false
            for a in adapters {
                guard let down = a.down, let up = a.up else { continue }
                let rank = down.dim(0)
                let scale = a.scale * (a.alpha ?? Float(rank)) / Float(rank)
                let delta = matmul(up.reshaped(up.dim(0), -1).asType(.float32), down.reshaped(rank, -1).asType(.float32)) * scale
                guard delta.size == base.size else { continue }
                merged = merged + delta.reshaped(base.shape)
                used = true
            }
            if used {
                weights[key] = merged.asType(base.dtype)
                matched.insert(module)
            }
        }
        report.appliedLayers += matched.count
        report.skippedLayers += modules.count - matched.count
    }
}
