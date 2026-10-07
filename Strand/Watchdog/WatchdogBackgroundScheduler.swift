#if os(iOS)
import BackgroundTasks
import Foundation

/// Best-effort BGAppRefresh for the same Watchdog `tick` as the foreground 20 s loop.
/// Does not claim a 20 s cadence while locked. Forecast may be skipped (UniTS + safety still run).
enum WatchdogBackgroundScheduler {
    private static var runHandler: (@Sendable () async -> Void)?

    private static var taskIdentifier: String {
        Bundle.main.bundleIdentifier.map { "\($0).watchdog" } ?? "noop.watchdog"
    }

    static func register(run: @escaping @Sendable () async -> Void) {
        runHandler = run
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            var work: Task<Void, Never>?
            refresh.expirationHandler = {
                work?.cancel()
                refresh.setTaskCompleted(success: false)
            }
            work = Task {
                await runHandler?()
                if Task.isCancelled { return }
                scheduleIfNeeded()
                refresh.setTaskCompleted(success: true)
            }
        }
    }

    static func scheduleIfNeeded() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
