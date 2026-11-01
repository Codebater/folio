// swift-tools-version: 6.0
// Neural voices through FluidAudio (Apache-2.0). Apple platforms only, so it
// lives outside the root package that also builds on Linux and Windows.
import PackageDescription

let package = Package(
    name: "FolioNeural",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FolioNeural", targets: ["FolioNeural"]),
        .executable(name: "folio-neural-check", targets: ["FolioNeuralCheck"]),
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.18.0"),
    ],
    targets: [
        .target(
            name: "FolioNeural",
            dependencies: [
                .product(name: "FolioCore", package: "folio"),
                .product(name: "FolioAudio", package: "folio"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(
            name: "FolioNeuralCheck",
            dependencies: ["FolioNeural", .product(name: "FolioAudio", package: "folio")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
