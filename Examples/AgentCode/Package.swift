// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentCode",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "agent-code", targets: ["AgentCode"])
    ],
    dependencies: [
        .package(name: "AgentRunKit", path: "../.."),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.1")
    ],
    targets: [
        .executableTarget(
            name: "AgentCode",
            dependencies: [
                .product(name: "AgentRunKit", package: "AgentRunKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "AgentCodeTests",
            dependencies: ["AgentCode"]
        )
    ]
)
