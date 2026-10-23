// swift-tools-version: 6.0
// OpenBridge is licensed under the Apache License, Version 2.0.
// See the LICENSE file at the repository root for details.
import PackageDescription

let package = Package(
    name: "OpenBridge",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "OpenBridgeApp", targets: ["OpenBridgeApp"]),
        .library(name: "OpenBridgeUI", targets: ["OpenBridgeUI"]),
    ],
    targets: [
        .executableTarget(
            name: "OpenBridgeApp",
            dependencies: [
                .target(name: "OpenBridgeUI"),
            ],
            path: "Sources/OpenBridgeApp",
            exclude: [
                "README.md",
            ],
            resources: [
                .copy("Resources/OpenBridgeBrandMark.png"),
                .copy("Resources/OpenBridgeMenuBarTemplate.png"),
            ]
        ),
        // Research Observatory shell (#318) lives in its own library target
        // so Xcode Canvas previews work: executable targets require the
        // ENABLE_DEBUG_DYLIB build layout that SwiftPM cannot express
        // (Xcode 26 preview restriction). Library targets preview natively.
        .target(
            name: "OpenBridgeUI",
            path: "Sources/OpenBridgeUI",
            resources: [.copy("Resources/Fonts")]
        ),
        .testTarget(
            name: "OpenBridgeAppTests",
            dependencies: [
                .target(name: "OpenBridgeApp"),
                .target(name: "OpenBridgeUI"),
            ],
            path: "Tests/OpenBridgeAppTests"
        ),
    ]
)