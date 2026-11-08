// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AdaptiveReader",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ReaderCore", targets: ["ReaderCore"]),
        .executable(name: "AdaptiveReader", targets: ["AdaptiveReader"])
    ],
    targets: [
        .target(name: "ReaderCore"),
        .executableTarget(name: "AdaptiveReader", dependencies: ["ReaderCore"]),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"])
    ]
)
