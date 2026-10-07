import Foundation
import SwiftUI

// MetricInsightStore.swift — the explanation card's view of `POST {scores}/insights` (MetricInsight.swift).
//
// One state per metric, kept in memory so re-opening a metric shows its last explanation at once while it is asked
// for again. Every read ends in a definite state: a pending analysis is polled at the server's suggested interval
// (clamped to 5...30 s) for at most ~90 s, after which the card says the explanation is unavailable right now and
// keeps any earlier explanation it had, marked as not current. Nothing here can block or hide the metric's value or
// chart: those come from the phone's own data.
//
// Isolation between accounts: `reset()` (from `AppModel.cloudAccountEnded`) forgets everything and drops any answer
// still in flight, and a change of running account seen at request time clears the cache as well, so one account's
// explanation is never shown to another on the same device.

@MainActor
final class MetricInsightStore: ObservableObject {
    static let shared = MetricInsightStore()

    enum Phase: Equatable, Sendable {
        /// The first request is in flight and nothing is cached.
        case loading
        /// The explanation describes the metric's latest measured data.
        case ready
        /// An analysis is queued or running; polling.
        case pending
        /// The server has no measured nights to explain.
        case notEnoughData
        /// No explanation now: the analysis failed or hit its daily bound, the server is older, a request failed, or
        /// polling ran out.
        case unavailable
        /// Cloud mode is on but nobody is signed in.
        case signedOut
        /// Local-only install: there is no server to explain anything, so the card is not shown.
        case hidden
    }

    struct State: Equatable, Sendable {
        var phase: Phase
        /// The explanation to show, current or earlier. It already passed the wording guard.
        var insight: MetricInsight?
        /// True only when `insight` describes the latest data (a `ready` answer that is not stale).
        var insightIsCurrent: Bool

        static let loading = State(phase: .loading, insight: nil, insightIsCurrent: false)

        /// Whether `insight` describes the latest night the PHONE has measured, not only the latest the server had.
        ///
        /// The value and the chart come from the phone's own series, the explanation from the server's nights through
        /// `insight.dataThrough`. When the phone holds a measured night after that day, the explanation is about
        /// earlier nights and must not read as current. Without a `dataThrough` (or a local night) the server's own
        /// answer decides (`insightIsCurrent`: ready and not stale).
        func isCurrent(latestMeasuredDay: String?) -> Bool {
            guard insightIsCurrent, let insight else { return false }
            guard let latest = latestMeasuredDay.flatMap(PhysiologyContextDates.date),
                  let through = insight.dataThrough.flatMap(PhysiologyContextDates.date) else { return true }
            return latest <= through
        }
    }

    /// What the store reads its preconditions, transport and clock from (injectable for tests).
    struct Environment {
        var cloudEnabled: @MainActor () -> Bool
        var signedIn: @MainActor () -> Bool
        /// The running account's scope; nil until the account's cloud path is up.
        var runningScope: @MainActor () -> CloudDataScope?
        var fetch: @MainActor (CloudDataScope, MetricInsightMetric) async -> MetricInsightFetchResult
        var now: @MainActor () -> Date
        /// Waits `seconds`; throws when the waiting task is cancelled.
        var sleep: @MainActor (TimeInterval) async throws -> Void

        static let live = Environment(
            cloudEnabled: { CloudPushSettings.isEnabled && CloudPushSettings.isConfigured },
            signedIn: { CloudPushIdentityStore.current() != nil },
            runningScope: { CloudPushRuntime.shared.runningScope },
            fetch: { scope, metric in
                await MetricInsightClient(identity: CloudPushRuntime.credentialProvider(for: scope)).request(metric)
            },
            now: { Date() },
            sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) })
    }

    /// Total time a pending analysis is polled for before the card says the explanation is unavailable.
    nonisolated static let pollBudget: TimeInterval = 90
    /// The server's `retry_after_s` is clamped to this range.
    nonisolated static let pollDelayRange: ClosedRange<TimeInterval> = 5...30
    /// The wait used when the server suggests none (its own default).
    nonisolated static let defaultPollDelay: TimeInterval = 10
    /// How often an account that is still connecting is checked again (within the same budget).
    nonisolated static let accountWaitDelay: TimeInterval = 5

    @Published private(set) var states: [MetricInsightMetric: State] = [:]
    /// Bumped by `reset()`. A screen keys its request on it, so a card left open across an account change asks
    /// again for the next account instead of keeping the placeholder.
    @Published private(set) var epoch = 0

    private let environment: Environment
    /// Bumped by `reset()`; an answer is applied only if it is unchanged after its await, so a response read with
    /// one account's credential never lands in the next account's screens.
    private var generation = 0
    /// The account the cached states were read for.
    private var cachedScope: CloudDataScope?

    init(environment: Environment = .live) {
        self.environment = environment
    }

    func state(for metric: MetricInsightMetric) -> State? { states[metric] }

    /// Forget every explanation. Called when the signed-in account ends: what is cached was read with the previous
    /// account's credential and must not be visible to the next one.
    func reset() {
        generation &+= 1
        epoch &+= 1
        states = [:]
        cachedScope = nil
    }

    // MARK: Reads

    /// Ask for the metric's explanation, then keep asking while it is being prepared, at the server's suggested
    /// interval and for at most `pollBudget`. Runs inside the card's `.task`, so leaving the screen cancels it; a
    /// cancelled wait leaves the state as it was, and the next visit starts again.
    func refresh(_ metric: MetricInsightMetric) async {
        let started = generation
        let deadline = environment.now().addingTimeInterval(Self.pollBudget)
        while !Task.isCancelled, started == generation {
            guard let delay = await requestOnce(metric, started: started) else { return }
            guard !Task.isCancelled, started == generation else { return }
            guard environment.now().addingTimeInterval(delay) <= deadline else {
                // Out of time: say so, keeping whatever earlier explanation is shown, marked as not current.
                let shown = states[metric]?.insight
                states[metric] = State(phase: .unavailable, insight: shown, insightIsCurrent: false)
                return
            }
            do { try await environment.sleep(delay) } catch { return }
        }
    }

    /// One request and its state. Returns the wait before the next request while the answer is still being
    /// prepared, nil once it is settled.
    private func requestOnce(_ metric: MetricInsightMetric, started: Int) async -> TimeInterval? {
        guard environment.cloudEnabled() else {
            states[metric] = State(phase: .hidden, insight: nil, insightIsCurrent: false)
            return nil
        }
        guard let scope = environment.runningScope() else {
            if environment.signedIn() {
                // Signed in, but the account's cloud path is still starting: wait for it like a pending analysis.
                if states[metric] == nil { states[metric] = .loading }
                return Self.accountWaitDelay
            }
            states[metric] = State(phase: .signedOut, insight: nil, insightIsCurrent: false)
            return nil
        }
        if let cachedScope, cachedScope != scope { states = [:] }
        cachedScope = scope
        if states[metric] == nil || states[metric]?.phase == .signedOut || states[metric]?.phase == .hidden {
            states[metric] = .loading
        }

        let result = await environment.fetch(scope, metric)
        // Dropped when the account ended (or changed) while the request was out.
        guard started == generation, environment.runningScope() == scope else { return nil }
        switch result {
        case .cancelled:
            return nil
        case .response(let response):
            return apply(response, to: metric)
        case .unsupportedServer, .failed:
            states[metric] = State(phase: .unavailable, insight: states[metric]?.insight, insightIsCurrent: false)
            return nil
        }
    }

    /// The state one server answer puts the card in; the wait before the next request when it is still pending.
    @discardableResult
    func apply(_ response: MetricInsightResponse, to metric: MetricInsightMetric) -> TimeInterval? {
        let shown = states[metric]?.insight
        let received = response.insight.flatMap(Self.renderable)
        switch response.status {
        case .ready:
            if let received, !received.stale {
                states[metric] = State(phase: .ready, insight: received, insightIsCurrent: true)
            } else {
                // A ready answer with nothing showable (missing, or it failed the wording guard).
                states[metric] = State(phase: .unavailable, insight: received ?? shown, insightIsCurrent: false)
            }
            return nil
        case .pending:
            states[metric] = State(phase: .pending, insight: received ?? shown, insightIsCurrent: false)
            return Self.pollDelay(retryAfterS: response.retryAfterS)
        case .unavailable, .unknown:
            if response.reason == .noMeasuredData {
                // Nothing measured: an explanation of earlier data would describe nights that are no longer there.
                states[metric] = State(phase: .notEnoughData, insight: nil, insightIsCurrent: false)
            } else {
                states[metric] = State(phase: .unavailable, insight: received ?? shown, insightIsCurrent: false)
            }
            return nil
        }
    }

    // MARK: Pure rules

    /// The explanation if it may be shown: nil when any of its text trips the wording guard.
    nonisolated static func renderable(_ insight: MetricInsight) -> MetricInsight? {
        insight.wordingViolation == nil ? insight : nil
    }

    /// The server's suggested wait, clamped to `pollDelayRange`.
    nonisolated static func pollDelay(retryAfterS: Int?) -> TimeInterval {
        let suggested = retryAfterS.map(TimeInterval.init) ?? defaultPollDelay
        return min(max(suggested, pollDelayRange.lowerBound), pollDelayRange.upperBound)
    }
}
