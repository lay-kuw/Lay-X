import Foundation
import LayXCore
import MLX

/// Smallest possible GPU round-trip. Used by `LayX --mlx-selftest` to prove the Metal library is bundled.
public enum MLXSelfTest {
    public static func run() -> Float {
        let a = MLXArray([1, 2, 3] as [Float]) * 2
        return a.sum().item(Float.self)
    }
}

/// MLX-backed `InferenceEngine`. Stage A: interface only — real loading/generation lands in Stage B.
public actor MLXEngine: InferenceEngine {
    public init() {}

    public func load(_ model: ModelReference, progress: @escaping @Sendable (Double) -> Void) async throws -> LoadedModelInfo {
        throw InferenceError.loadFailed("MLX loading is implemented in Stage B")
    }

    public func unload() async {}

    public nonisolated func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: InferenceError.noModelLoaded) }
    }
}
