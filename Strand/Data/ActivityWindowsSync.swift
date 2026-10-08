import Foundation

/// One pass of the phone's activity-window readback: HART's windows (`scores/activity-windows`) and ElderNet's gait
/// windows (`scores/gait-windows`). The two are independent server results, so each is fetched whatever became of the
/// other: a HART failure (a server without the route, a timeout) must not leave the gait store a pass behind.
///
/// At most one pass runs at a time, and a new one starts only `minimumInterval` after the last one started; a pass
/// asked for while one is in flight is dropped rather than queued (the next timer or sync pass picks it up).
@MainActor
final class ActivityWindowsSync {
    struct Outcome: Equatable {
        var hartChanged = false
        var gaitChanged = false
        /// Whether each fetch failed (it then changed nothing; the decoder keeps what is stored).
        var hartFailed = false
        var gaitFailed = false
        var changed: Bool { hartChanged || gaitChanged }
    }

    let minimumInterval: TimeInterval
    private(set) var inFlight = false
    private(set) var lastStartedAt: Date?

    init(minimumInterval: TimeInterval) { self.minimumInterval = minimumInterval }

    /// Forget when the last pass started (sign-out, another account), so the next one is not held back. A pass in
    /// flight still finishes; its results are dropped by its own scope checks.
    func reset() { lastStartedAt = nil }

    /// Run `hart` then `gait`, each on its own; nil when a pass is in flight or the last one started too recently.
    /// Each closure returns whether it changed a stored day and throws when its fetch failed.
    func run(now: Date = Date(), hart: () async throws -> Bool, gait: () async throws -> Bool) async -> Outcome? {
        guard !inFlight else { return nil }
        if let last = lastStartedAt, now.timeIntervalSince(last) < minimumInterval { return nil }
        inFlight = true
        lastStartedAt = now
        defer { inFlight = false }
        var outcome = Outcome()
        do { outcome.hartChanged = try await hart() } catch { outcome.hartFailed = true }
        do { outcome.gaitChanged = try await gait() } catch { outcome.gaitFailed = true }
        return outcome
    }
}
