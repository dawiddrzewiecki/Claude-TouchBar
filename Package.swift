// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "ClaudeTouchBar",
    platforms: [.macOS(.v10_15)],
    products: [
        .executable(name: "ClaudeTouchBar", targets: ["ClaudeTouchBar"]),
        .executable(name: "cctb", targets: ["cctb"]),
    ],
    targets: [
        .target(name: "ClaudeBarCore"),
        .executableTarget(name: "cctb", dependencies: ["ClaudeBarCore"]),
        .executableTarget(name: "ClaudeTouchBar", dependencies: ["ClaudeBarCore"]),
        .testTarget(name: "ClaudeBarCoreTests", dependencies: ["ClaudeBarCore"]),
    ]
)
