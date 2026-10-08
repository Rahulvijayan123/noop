#if DEBUG
import Foundation

// MARK: - DEBUG-only launch arguments for repeatable UI screenshots
//
// Nothing outside a simulator can tap or scroll the app without a full Xcode selected, so UI verification
// drives it from the host with `simctl launch` arguments instead: which tab to open, which page to push, how
// much demo history to seed and how long to hold the first load. Every argument is optional and an absent one
// changes nothing. The whole file is `#if DEBUG`, so Release builds do not contain it.
enum DemoLaunch {
    /// `--demo-days N`: how many days of history `AppleDemoSeeder` writes (default 120). `0` writes none, which
    /// with `--demo-seed` still skips the first-run gates: the signed-in-but-empty account.
    static var seedDays: Int { max(0, intArg("--demo-days") ?? 120) }

    /// `--demo-tab N`: the tab selected at launch (0 Today, 1 Monitor, 2 Events, 3 Sleep, 4 Sana).
    static var initialTab: Int? { intArg("--demo-tab") }

    /// `--demo-push <route>`: one first-hop page pushed onto the launch tab, named as in `TabRoute`
    /// (`sleep`, `heartRateDay`, `metric:hrv`, `metric:resting_hr:my-whoop`, ...).
    static var initialRoute: TabRoute? {
        guard let raw = stringArg("--demo-push") else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 2).map(String.init)
        switch parts[0] {
        case "metric" where parts.count == 3: return .metricSourced(key: parts[1], source: parts[2])
        case "metric" where parts.count == 2: return .metric(parts[1])
        case "fullDayChart": return .fullDayChart
        case "heartRateDay": return .heartRateDay
        case "metricExplorer": return .metricExplorer
        case "workouts": return .workouts
        case "dataSources": return .dataSources
        case "stress": return .stress
        case "sleep": return .sleep
        case "health": return .health
        case "hydration": return .hydration
        case "coupled": return .coupled
        case "medication": return .medication
        case "watchdog": return .watchdog
        case "layer1": return .layer1
        case "baselineCharts": return .baselineCharts
        case "pipelineDiagnostics": return .pipelineDiagnostics
        case "browse": return .browse
        default: return nil
        }
    }

    /// `--demo-load-delay S`: every `Repository.refresh` waits until S seconds after launch, so the screens'
    /// loading state stays up long enough to be captured. Fixed at first read, so it measures from launch.
    static let loadReleaseDate: Date? = doubleArg("--demo-load-delay").map { Date().addingTimeInterval($0) }

    static func intArg(_ name: String) -> Int? { stringArg(name).flatMap { Int($0) } }
    static func doubleArg(_ name: String) -> Double? { stringArg(name).flatMap { Double($0) } }
    static func stringArg(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
#endif
