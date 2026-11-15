// swift-tools-version:5.9
// Lay X — Design Preview (Glass Studio). Mock data only: no MLX, no networking, no file writes.
import PackageDescription

let package = Package(
    name: "LayXDesignPreview",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LayXDesignPreview",
            path: "Sources/LayXDesignPreview"
        )
    ]
)
