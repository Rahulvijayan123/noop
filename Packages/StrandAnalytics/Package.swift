// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrandAnalytics",
    platforms: [.macOS(.v13), .iOS(.v16), .watchOS(.v10)],
    products: [.library(name: "StrandAnalytics", targets: ["StrandAnalytics"])],
    dependencies: [
        .package(path: "../WhoopProtocol"),
        .package(path: "../WhoopStore"),
    ],
    targets: [
        // The day decoder walks 86,400 observations a day through an HSMM. Unoptimised (an Xcode Debug build on a
        // phone) that is ~28x slower than Release (about 17 s against 0.6 s for a cold day on a Mac), which is
        // what made the Heart rate page crawl in development builds. Optimise this module in Debug too; the
        // DEBUG define and `-enable-testing` are unaffected, so assertions and `@testable import` still work.
        .target(name: "StrandAnalytics", dependencies: ["WhoopProtocol", "WhoopStore"],
                swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        // WhoopStore is declared on the TEST target as well as the library: the Oura respiration
        // scoring-exclusion tests assert on `OuraRespScale` (the seam that keeps the ring's 0x6A rows
        // out of the stager), and a transitively-visible module is not something a test should rely on.
        .testTarget(name: "StrandAnalyticsTests", dependencies: ["StrandAnalytics", "WhoopStore"]),
    ]
)
