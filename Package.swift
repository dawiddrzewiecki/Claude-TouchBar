// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeTouchBar",
    platforms: [.macOS(.v13)],
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
