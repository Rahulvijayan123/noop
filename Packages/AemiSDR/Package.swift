// swift-tools-version:6.2

import PackageDescription

// Vendored from https://github.com/Aemi-Studio/AemiSDR (MIT / MPL-2.0, see LICENSE-MIT and LICENSE),
// upstream commit 56bd2ed5834ec777c6cb6b7af6f896a587b20c23. Differences from upstream are listed in
// VENDORED.md; the short version is no `aemi` dependency, no shader build plugin, and platform
// minimums lowered to the app's deployment targets.

private let swiftSettings: [SwiftSetting] = [
    .strictMemorySafety(),
    .enableExperimentalFeature("StrictConcurrency"),
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "AemiSDR",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "AemiSDR", targets: ["AemiSDR"])
    ],
    targets: [
        .target(
            name: "AemiSDR",
            // The .metal sources are kept for reference and recompiled by Tools/compile-shaders.sh.
            // Compiling them here as well would emit a redundant default.metallib and require the
            // Metal toolchain on every machine that builds the app.
            exclude: ["Shaders"],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        )
    ]
)
