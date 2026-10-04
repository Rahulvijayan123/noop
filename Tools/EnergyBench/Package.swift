// swift-tools-version:5.9
import PackageDescription

// EnergyBench — an offline evaluation harness for the energy-expenditure pipeline.
//
// Replays one local day at a time through the app's own `AnalyticsEngine.analyzeDay` twice — once with the
// previous heart-rate-only estimator (`.legacyHR`, the number the app used to show) and once with the
// multimodel fusion estimator (`.fusion`, the default) — and reports where and why they differ. On top of
// the totals it checks the two properties the fusion estimator exists to deliver:
//
//   1. sustained moderate activity that stays BELOW the old HR gate is now credited, with a plausible MET;
//   2. a light day is not re-inflated the way crediting every elevated reading at the exercise rate was.
//
// The input is a directory of `energy-bench-day-v1` JSON bundles (see README.md and
// scripts/assemble_day_bundles.py). The directory is ALWAYS a command-line argument — no health data lives
// in this repository, and none is written back.
let package = Package(
    name: "energybench",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/StrandAnalytics"),
        .package(path: "../../Packages/WhoopProtocol"),
        // `DayResult.daily` is a WhoopStore `DailyMetric`.
        .package(path: "../../Packages/WhoopStore"),
    ],
    targets: [
        .executableTarget(name: "energybench", dependencies: ["StrandAnalytics", "WhoopProtocol", "WhoopStore"]),
        // The bundle codec, the bout finder and the checks are pure functions over arrays, so they are
        // unit-testable on synthetic days: `swift test` here needs no health data and no `--days` argument.
        .testTarget(name: "energybenchTests", dependencies: ["energybench"]),
    ]
)
