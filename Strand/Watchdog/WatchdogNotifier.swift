import Foundation
import UserNotifications
import StrandAnalytics

enum WatchdogNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// The notification request id a Watchdog push uses (also how a lost delivery is found again).
    static func identifier(for result: WatchdogResult, test: Bool = false) -> String {
        test ? "watchdog-test-\(result.lastTickUnix)" : (result.episodeId ?? "watchdog-severe")
    }

    static func post(_ result: WatchdogResult, test: Bool = false,
                     delivery: ((String) -> Void)? = nil) {
        guard result.shouldNotify || test else {
            delivery?("skipped")
            return
        }
        delivery?("queued")
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                delivery?("denied")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = test ? "Watchdog test" : "Watchdog"
            content.subtitle = String(localized: "Not a diagnosis.")
            content.body = result.headline + " " + result.episodeLine
            content.sound = .default
            content.threadIdentifier = test ? "watchdog-test" : (result.episodeId ?? "watchdog")
            let id = identifier(for: result, test: test)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                delivery?(error == nil ? "sent" : "failed")
            }
        }
    }

    /// Post and wait for the final outcome: "sent" | "failed" | "denied" | "skipped" (never "queued"). The
    /// caller persists the outcome before it finishes, so a background task never completes with the carry
    /// still reading "queued".
    static func deliver(_ result: WatchdogResult) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let once = ResumeOnce(continuation)
            post(result) { status in
                guard status != "queued" else { return }
                once.resume(status)
            }
        }
    }

    /// Request ids of the notifications still shown in Notification Center.
    static func deliveredIdentifiers() async -> Set<String> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Set<String>, Never>) in
            UNUserNotificationCenter.current().getDeliveredNotifications { notes in
                continuation.resume(returning: Set(notes.map(\.request.identifier)))
            }
        }
    }

    /// Resumes a continuation at most once, whichever callback lands first.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Never>?
        init(_ continuation: CheckedContinuation<String, Never>) { self.continuation = continuation }
        func resume(_ value: String) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }
}
