import Foundation
import UserNotifications
import StrandAnalytics

enum WatchdogNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
            let id = test ? "watchdog-test-\(result.lastTickUnix)" : (result.episodeId ?? "watchdog-severe")
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                delivery?(error == nil ? "sent" : "failed")
            }
        }
    }
}
