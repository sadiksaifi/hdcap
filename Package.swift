// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "hdcap",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "hdcap", targets: ["hdcap"]),
        .executable(name: "hdcap-companion", targets: ["HDCapCompanion"]),
        .library(name: "HDCapture", targets: ["HDCapture"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    ],
    targets: [
        .target(name: "HDCapture"),
        .target(name: "CompanionIPC", dependencies: ["HDCapture"]),
        .executableTarget(name: "hdcap", dependencies: [
            "HDCapture", "CompanionIPC", .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ], plugins: [.plugin(name: "GitVersionPlugin")]),
        .executableTarget(name: "HDCapCompanion", dependencies: ["HDCapture", "CompanionIPC"]),
        .testTarget(name: "HDCaptureTests", dependencies: ["HDCapture"]),
        .testTarget(name: "CompanionIPCTests", dependencies: ["CompanionIPC"]),
        .plugin(name: "GitVersionPlugin", capability: .buildTool()),
    ]
)
