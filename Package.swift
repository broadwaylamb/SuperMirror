// swift-tools-version:5.0

import PackageDescription

let package = Package(
    name: "SuperMirror",
    products: [
        .library(name: "SuperMirror", targets: ["SuperMirror"]),
    ],
    targets: [
        .target(name: "SuperMirror"),
        .testTarget(name: "SuperMirrorTests", dependencies: ["SuperMirror"]),
    ]
)
