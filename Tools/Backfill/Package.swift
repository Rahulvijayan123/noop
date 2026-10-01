// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "backfill",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/StrandImport"),
        .package(path: "../../Packages/WhoopStore"),
    ],
    targets: [
        .executableTarget(name: "backfill", dependencies: ["StrandImport", "WhoopStore"]),
    ]
)
