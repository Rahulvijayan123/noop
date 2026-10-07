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
