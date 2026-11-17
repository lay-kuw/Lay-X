// swift-tools-version: 6.2
// Lay X — native, local-first AI for Apple Silicon.
//
// Build with xcodebuild (not `swift build`): MLX's Metal kernels are only compiled by Xcode's build system.
// See scripts/build-app.sh.
import PackageDescription

let package = Package(
    name: "LayX",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "LayX", targets: ["LayXApp"]),
    ],
    dependencies: [
        // FoundationModels bridge trait disabled: Lay X does not use it, and it pulls in a large C++ target.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3", traits: []),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.4.0"),
        // Same version mlx-swift-lm resolves; used directly by the vendored Stable Diffusion port.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        // FLUX.2 klein 4B, Qwen-Image and Z-Image on MLX (Swift ports, MIT). Only their engine-free core libraries are linked;
        // weights are read from the local model folder.
        .package(url: "https://github.com/xocialize/flux2-klein-swift", exact: "0.11.0"),
        .package(url: "https://github.com/xocialize/flux2-vae-mlx-swift", exact: "0.8.0"),
        .package(url: "https://github.com/xocialize/qwen-image-edit-swift", exact: "0.12.0"),
        .package(url: "https://github.com/xocialize/z-image-swift", exact: "0.7.1"),
        .package(url: "https://github.com/hummingbird-project/hummingbird", exact: "2.28.1"),
        .package(url: "https://github.com/apple/swift-log", exact: "1.17.0"),
    ],
    targets: [
        // UI-free domain + services. No third-party dependencies, fully unit-testable.
        .target(
            name: "LayXCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // OpenAI-compatible HTTP server (Hummingbird / SwiftNIO).
        .target(
            name: "LayXServer",
            dependencies: [
                "LayXCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // MLX inference engine. Isolated so the rest of the app and the tests depend only on `InferenceEngine`.
        .target(
            name: "LayXMLX",
            dependencies: [
                "LayXCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                "StableDiffusionMLX",
                .product(name: "Klein", package: "flux2-klein-swift"),
                .product(name: "Flux2VAE", package: "flux2-vae-mlx-swift"),
                .product(name: "QwenImageEdit", package: "qwen-image-edit-swift"),
                .product(name: "ZImage", package: "z-image-swift"),
            ]
        ),
        // Stable Diffusion (SDXL Turbo) on MLX — vendored from ml-explore/mlx-swift-examples (MIT), reads local
        // weights only. Swift 5 mode: upstream code targets the Swift 5 concurrency model.
        .target(
            name: "StableDiffusionMLX",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
            ],
            exclude: ["LICENSE-mlx-swift-examples.txt"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // SwiftUI application (design system ported verbatim from DesignPreview).
        .executableTarget(
            name: "LayXApp",
            dependencies: ["LayXCore", "LayXServer", "LayXMLX"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "LayXCoreTests", dependencies: ["LayXCore"]),
        .testTarget(
            name: "LayXServerTests",
            dependencies: [
                "LayXServer",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)


// `LAYX_CORE_ONLY=1 swift test` builds and tests only the UI/MLX-free targets (no Metal toolchain needed).
if Context.environment["LAYX_CORE_ONLY"] == "1" {
    package.targets.removeAll { ["LayXMLX", "LayXApp", "StableDiffusionMLX"].contains($0.name) }
    package.products.removeAll()
    package.dependencies.removeAll { dependency in
        if case .sourceControl(_, let location, _) = dependency.kind {
            return isMLXDependency(location)
        }
        return false
    }
}

// `LAYX_NO_MLX=1 swift build` compiles the app without the MLX engine (UI iteration without the Metal
// toolchain). The app then reports "MLX engine unavailable in this build" instead of loading models.
if Context.environment["LAYX_NO_MLX"] == "1" {
    package.targets.removeAll { $0.name == "LayXMLX" || $0.name == "StableDiffusionMLX" }
    if let app = package.targets.first(where: { $0.name == "LayXApp" }) {
        app.dependencies.removeAll { if case .byNameItem(let name, _) = $0 { return name == "LayXMLX" }; return false }
    }
    package.dependencies.removeAll { dependency in
        if case .sourceControl(_, let location, _) = dependency.kind {
            return isMLXDependency(location)
        }
        return false
    }
}

func isMLXDependency(_ location: String) -> Bool {
    ["mlx-swift", "swift-transformers", "flux2-klein-swift", "qwen-image-edit-swift", "z-image-swift"].contains { location.contains($0) }
}
