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

        SentrySDK.start { options in
            options.dsn = dsn
            #if DEBUG
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
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = hangThreshold
            // Report hangs that only delay some frames, not just full stalls, and app kills by the watchdog.
            // NOTE (sleep-analytics Phase 1, baseline defect on main @ fae049a): the pinned
            // Sentry 9.30.0 PREBUILT binary does not expose `enableReportNonFullyBlockingAppHangs`
            // — on macOS NO slice implements the setter at all (the member exists only in the
            // 9.30.0 SOURCE), so main's direct assignment cannot build against the pinned binary,
            // and an unguarded perform() would raise "unrecognized selector" at launch. Called
            // through a responds(to:)-guarded selector so the toggle turns ON any SDK that
            // actually implements it (a future pin or source build) and is skipped — never a
            // crash — on the pinned macOS binary; every other fae049a option below applies
            // unchanged. Upstream fix: bump the Sentry pin to a release whose binaries carry the
            // member, or link the source product, and restore the direct assignment.
            let nonFullyBlockingHangs = Selector(("setEnableReportNonFullyBlockingAppHangs:"))
            if (options as NSObject).responds(to: nonFullyBlockingHangs) {
                (options as NSObject).perform(nonFullyBlockingHangs, with: true as NSNumber)
            }
            options.enableWatchdogTerminationTracking = true
            options.enableAutoSessionTracking = true

            options.tracesSampleRate = 1.0
            options.enableAutoPerformanceTracing = true
            options.enableFileIOTracing = true
            options.enableCoreDataTracing = true
            options.enableNetworkTracking = true
            #if os(iOS)
            options.enableUIViewControllerTracing = true
            options.enableTimeToFullDisplayTracing = true
            options.enablePreWarmedAppStartTracing = true
            #endif
            options.enableMetricKit = true
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
