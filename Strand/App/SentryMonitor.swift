import Foundation
import Sentry

/// Crash, error, slow-transaction and app-hang reporting.
///
/// Inert unless the build bakes in a DSN (`NOOP_SENTRY_DSN` → `NOOPSentryDSN` in Info.plist), so a clean
/// checkout still sends nothing. No PII, screenshots, view hierarchy or request bodies are captured.
enum SentryMonitor {
    /// Apple's definition of a hang: the main thread unresponsive for more than 250 ms (Xcode Organizer and
    /// MetricKit use the same bar). Sentry's default is 2 s.
    static let hangThreshold: TimeInterval = 0.25

    static func start() {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "NOOPSentryDSN") as? String) ?? ""
        let dsn = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https:/$()/", with: "https://")
        guard !dsn.isEmpty else { return }
        // A unit-test host reports its own test-induced stalls (XCTest runs the suite on the main thread):
        // on 2026-10-08 that was 67 of the 122 issues in the project, none from a user's phone.
        guard NSClassFromString("XCTestCase") == nil else { return }

        SentrySDK.start { options in
            options.dsn = dsn
            #if targetEnvironment(simulator)
            options.environment = "simulator"
            #elseif DEBUG
            options.environment = "debug"
            #else
            options.environment = "production"
            #endif
            options.releaseName = Self.releaseName()
            options.sendDefaultPii = false
            #if os(iOS)
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            #endif

            options.enableCrashHandler = true
            // Off in the simulator: UI tests drive it through XCTAutomationSupport accessibility snapshots,
            // which stall the main thread for seconds (21 of the 122 issues on 2026-10-08).
            #if targetEnvironment(simulator)
            options.enableAppHangTracking = false
            #else
            options.enableAppHangTracking = true
            #endif
            options.appHangTimeoutInterval = hangThreshold
            // Report hangs that only delay some frames, not just full stalls, and app kills by the
            // watchdog. iOS-only: the pinned Sentry 9.30.0 binary framework exposes this option on
            // iOS but not on macOS, so an unconditional set breaks the macOS build.
            #if os(iOS)
            options.enableReportNonFullyBlockingAppHangs = true
            #endif
            options.enableWatchdogTerminationTracking = true
            options.enableAutoSessionTracking = true

            options.tracesSampleRate = 1.0
            options.enableAutoPerformanceTracing = true
            // Off: file I/O tracing wraps every NSData/FileManager read and write in a span while a transaction is
            // open, and UI transactions stay open up to 30 s. The strap log writes a line or two a second and the
            // IMU and score caches write constantly, so it added work to those paths and buried the spans that
            // matter. The app has no Core Data (it uses GRDB), so that integration had nothing to trace.
            options.enableFileIOTracing = false
            options.enableCoreDataTracing = false
            options.enableNetworkTracking = true
            #if os(iOS)
            options.enableUIViewControllerTracing = true
            options.enableTimeToFullDisplayTracing = true
            options.enablePreWarmedAppStartTracing = true
            #endif
            options.enableMetricKit = true
            options.beforeSend = { event in
                // A "hang" whose main thread is idle in its run loop is the tracker's, not the app's.
                SentryHangFilter.shouldDrop(event) ? nil : event
            }
        }
        // Which commit a report came from: the release name is the same for every phone build of a version.
        let revision = (Bundle.main.object(forInfoDictionaryKey: "NOOPSourceRevision") as? String) ?? ""
        if !revision.isEmpty {
            SentrySDK.configureScope { $0.setTag(value: revision, key: "source_revision") }
        }
    }

    private static func releaseName() -> String {
        let info = Bundle.main.infoDictionary
        let id = Bundle.main.bundleIdentifier ?? "nara"
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "0"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"
        return "\(id)@\(version)+\(build)"
    }
}
