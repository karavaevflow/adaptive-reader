// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AdaptiveReader",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ReaderCore", targets: ["ReaderCore"]),
        .executable(name: "AdaptiveReaderPreview", targets: ["AdaptiveReaderPreview"])
    ],
    targets: [
        .target(name: "ReaderCore"),
        .executableTarget(name: "ColorResearch", dependencies: ["ReaderCore"]),
        .executableTarget(name: "AdaptiveReaderPreview", dependencies: ["ReaderCore"], path: "Sources/AdaptiveReader", exclude: ["AdaptiveReader.entitlements"], resources: [.process("Resources")]),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"])
    ]
)
