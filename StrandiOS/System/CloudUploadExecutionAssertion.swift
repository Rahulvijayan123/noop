import UIKit

/// Keeps the app running while a cloud upload that started off screen finishes.
///
/// The strap's Bluetooth link wakes the process roughly once a second, but a wake is a short window: an
/// upload that is still waiting on the receiver when the window closes would be paused with the process
/// and finish late. Holding a UIKit background task for the length of the upload asks the system for the
/// time to apply the receipt, and it is released on every path, including expiry.
enum CloudUploadExecutionAssertion {
    private final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var identifier: UIBackgroundTaskIdentifier = .invalid

        func store(_ id: UIBackgroundTaskIdentifier) {
            lock.lock(); identifier = id; lock.unlock()
        }

        func take() -> UIBackgroundTaskIdentifier {
            lock.lock(); defer { lock.unlock() }
            let id = identifier
            identifier = .invalid
            return id
        }
    }

    static let begin: @Sendable (String) async -> (@Sendable () -> Void) = { name in
        let token = Token()
        await MainActor.run {
            let application = UIApplication.shared
            token.store(application.beginBackgroundTask(withName: name) {
                let id = token.take()
                if id != .invalid { application.endBackgroundTask(id) }
            })
        }
        return {
            Task { @MainActor in
                let id = token.take()
                if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
            }
        }
    }
}
