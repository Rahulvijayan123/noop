// swift-tools-version:5.9
import PackageDescription

// frwhoop-worker — the hosted compute worker for the FRWHOOP cloud pipeline.
//
// This is a fork-scoped component (see FORK_SCOPE.md): upstream NOOP is
// offline-only; this fork intentionally adds the user-owned hosted compute
// pipeline. The worker is a Linux-first Swift executable that drains the
// Supabase work queues (projection, verification, scoring) over a direct
// Postgres connection, downloads immutable raw objects from private object
// storage, decodes the NOOP push protocol batches, and publishes day-score
// results computed with the exact StrandAnalytics math the phone app uses.
//
// No secrets are compiled in: everything comes from the environment.
let package = Package(
    name: "frwhoop-worker",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/StrandAnalytics"),
        .package(path: "../../Packages/WhoopProtocol"),
        .package(path: "../../Packages/WhoopStore"),
    ],
    targets: [
        .systemLibrary(name: "CLibPQ", pkgConfig: "libpq"),
        .systemLibrary(name: "CZlib", pkgConfig: "zlib"),
        .systemLibrary(name: "CCrypto", pkgConfig: "openssl"),
        .executableTarget(
            name: "frwhoop-worker",
            dependencies: [
                "CLibPQ",
                "CZlib",
                "CCrypto",
                .product(name: "StrandAnalytics", package: "StrandAnalytics"),
                .product(name: "WhoopProtocol", package: "WhoopProtocol"),
                .product(name: "WhoopStore", package: "WhoopStore"),
            ]
        ),
        .testTarget(name: "frwhoop-workerTests", dependencies: ["frwhoop-worker"]),
    ]
)
