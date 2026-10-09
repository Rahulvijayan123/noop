#if os(iOS)
import UIKit
import UserNotifications

/// Tells the person when Nara stops syncing because it was closed.
///
/// iOS relaunches a Bluetooth app that the system terminated, but never one the person swiped away in the
/// app switcher: until it is opened again, the strap banks to flash and nothing reaches the phone. On
/// 2026-10-08 that was eight hours (02:03 to 10:12), and the morning then had to move the whole night over
/// Bluetooth and up to the server before the Sleep tab could show it.
///
/// Nothing can keep a swiped-away app running, so the next best thing is saying so while the night can still
/// be saved. When the scene is discarded with a strap connected, a notification is armed for a little later.
/// A scene can also be discarded while the process keeps running in the background for Bluetooth; in that
/// case the process is still here a few seconds later and withdraws the notification. Any launch withdraws it
/// too, so it never outlives the gap it reports.
@MainActor
enum SyncStoppedNotifier {
    static let identifier = "nara.sync-stopped"
    /// Long enough for a process that is merely losing its scene to withdraw the notification first.
    static let deliverAfterSeconds: TimeInterval = 60
    /// How long a surviving process waits before concluding it survived.
    static let survivalCheckSeconds: UInt64 = 15

    /// Only a scene loss with a strap on the link loses data; with no strap connected there is nothing to sync.
    static func shouldArm(strapConnected: Bool) -> Bool { strapConnected }

    static func sceneDidDisconnect() {
        guard shouldArm(strapConnected: AppModel.shared?.live.connected == true) else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Nara stopped syncing")
        content.body = String(localized: "Nara was closed, so your strap can't sync until you open it again. Open Nara to keep tonight's sleep syncing. It doesn't need to stay on screen.")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: deliverAfterSeconds, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))

        // If this process survives the scene, it is still syncing: withdraw the notification. The background
        // task keeps a surviving process running for the check; a terminated one never gets here, which is
        // exactly when the notification should be delivered.
        let application = UIApplication.shared
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = application.beginBackgroundTask(withName: "sync-stopped-check") {
            application.endBackgroundTask(taskID)
            taskID = .invalid
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: survivalCheckSeconds * 1_000_000_000)
            withdraw()
            if taskID != .invalid {
                application.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
    }

    /// Called at every launch: whatever closed the app, it is running again.
    static func withdraw() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
#endif
