#if os(iOS)
import BackgroundTasks
import Foundation

/// Best-effort BGAppRefresh for the same Watchdog `tick` as the foreground 20 s loop.
/// Does not claim a 20 s cadence while locked. Forecast may be skipped (UniTS + safety still run).
///
/// The handler completes the task only after the tick (and any push delivery inside it) has finished, reports
/// success only when a tick actually ran, and re-arms the next request on start, on completion and on expiry,
/// so neither an expiry nor a skipped tick ends the chain.
enum WatchdogBackgroundScheduler {
    /// Seconds of a refresh task's ~30 s budget a cold launch may spend waiting for the service to start.
    static let startBudgetSeconds: Double = 20

    private static var runHandler: (@Sendable () async -> Bool)?

    private static var taskIdentifier: String {
        Bundle.main.bundleIdentifier.map { "\($0).watchdog" } ?? "noop.watchdog"
    }

    /// `run` returns true when a tick ran to completion.
    static func register(run: @escaping @Sendable () async -> Bool) {
        runHandler = run
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            // Re-arm first: a crash or a kill mid-tick must not end the chain.
            scheduleIfNeeded()
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let completion = TaskCompletion(refresh)
            let work = Task {
                let ran = await runHandler?() ?? false
                scheduleIfNeeded()
                completion.complete(success: ran && !Task.isCancelled)
            }
            refresh.expirationHandler = {
                work.cancel()
                scheduleIfNeeded()
                completion.complete(success: false)
            }
        }
    }

    static func scheduleIfNeeded() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// `setTaskCompleted` exactly once, whether the work or the expiration handler gets there first.
    private final class TaskCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var task: BGTask?
        init(_ task: BGTask) { self.task = task }
        func complete(success: Bool) {
            lock.lock()
            let t = task
            task = nil
            lock.unlock()
            t?.setTaskCompleted(success: success)
        }
    }
}
#endif
