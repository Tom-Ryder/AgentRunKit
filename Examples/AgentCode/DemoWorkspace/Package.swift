// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DemoWorkspace",
    products: [
        .library(name: "DemoWorkspace", targets: ["DemoWorkspace"])
    ],
    targets: [
        .target(name: "DemoWorkspace"),
        .testTarget(name: "DemoWorkspaceTests", dependencies: ["DemoWorkspace"])
    ]
)
