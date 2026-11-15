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
        .package(url: "https://github.com/hummingbird-project/hummingbird", exact: "2.28.1"),
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
            ]
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
    package.targets.removeAll { ["LayXMLX", "LayXApp"].contains($0.name) }
    package.products.removeAll()
    package.dependencies.removeAll { dependency in
        if case .sourceControl(_, let location, _) = dependency.kind {
            return location.contains("mlx-swift-lm") || location.contains("swift-transformers")
        }
        return false
    }
}

// `LAYX_NO_MLX=1 swift build` compiles the app without the MLX engine (UI iteration without the Metal
// toolchain). The app then reports "MLX engine unavailable in this build" instead of loading models.
if Context.environment["LAYX_NO_MLX"] == "1" {
    package.targets.removeAll { $0.name == "LayXMLX" }
    if let app = package.targets.first(where: { $0.name == "LayXApp" }) {
        app.dependencies.removeAll { if case .byNameItem(let name, _) = $0 { return name == "LayXMLX" }; return false }
    }
    package.dependencies.removeAll { dependency in
        if case .sourceControl(_, let location, _) = dependency.kind {
            return location.contains("mlx-swift-lm") || location.contains("swift-transformers")
        }
        return false
    }
}
