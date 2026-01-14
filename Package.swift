// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentRunKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "AgentRunKit", targets: ["AgentRunKit"])
    ],
    targets: [
        .target(name: "AgentRunKit"),
        .testTarget(name: "AgentRunKitTests", dependencies: ["AgentRunKit"])
    ]
)
