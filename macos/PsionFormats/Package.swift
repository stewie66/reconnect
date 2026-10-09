// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PsionFormats",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PsionFormats", targets: ["PsionFormats"])],
    targets: [
        .target(name: "PsionFormats"),
        .testTarget(name: "PsionFormatsTests", dependencies: ["PsionFormats"]),
    ]
)
