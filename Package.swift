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
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .target(name: "ReaderCore", dependencies: ["ZIPFoundation"]),
        .executableTarget(name: "ColorResearch", dependencies: ["ReaderCore"]),
        .executableTarget(name: "EPUBResearch", dependencies: ["ReaderCore"]),
        .executableTarget(name: "AdaptiveReaderPreview", dependencies: ["ReaderCore"], path: "Sources/AdaptiveReader", exclude: ["AdaptiveReader.entitlements", "AppInfo.plist"], resources: [.process("Resources")]),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"])
    ]
)
