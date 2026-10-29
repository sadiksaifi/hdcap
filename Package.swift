// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "hdcap",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "hdcap", targets: ["hdcap"]),
        .library(name: "HDCapture", targets: ["HDCapture"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    ],
    targets: [
        .target(name: "HDCapture"),
        .executableTarget(name: "hdcap", dependencies: [
            "HDCapture", .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ], plugins: [.plugin(name: "GitVersionPlugin")]),
        .testTarget(name: "HDCaptureTests", dependencies: ["HDCapture"]),
        .plugin(name: "GitVersionPlugin", capability: .buildTool()),
    ]
)
