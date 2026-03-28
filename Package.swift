// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentRunKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "AgentRunKit", targets: ["AgentRunKit"]),
        .library(name: "AgentRunKitTesting", targets: ["AgentRunKitTesting"]),
        .library(name: "AgentRunKitMLX", targets: ["AgentRunKitMLX"]),
        .library(name: "AgentRunKitFoundationModels", targets: ["AgentRunKitFoundationModels"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "2.30.0")),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.4.3"),
    ],
    targets: [
        .target(name: "AgentRunKit"),
        .target(name: "AgentRunKitTesting", dependencies: ["AgentRunKit"]),
        .testTarget(name: "AgentRunKitTests", dependencies: ["AgentRunKit", "AgentRunKitTesting"]),
        .target(
            name: "AgentRunKitMLX",
            dependencies: [
                "AgentRunKit",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm")
            ]
        ),
        .testTarget(name: "AgentRunKitMLXTests", dependencies: ["AgentRunKitMLX"]),
        .target(
            name: "AgentRunKitFoundationModels",
            dependencies: ["AgentRunKit"]
        ),
        .testTarget(
            name: "AgentRunKitFoundationModelsTests",
            dependencies: ["AgentRunKitFoundationModels"]
        )
    ]
)
