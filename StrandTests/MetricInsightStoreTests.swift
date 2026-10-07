import XCTest
@testable import Strand

/// The injected world the store runs in: preconditions, a scripted transport, and a clock that the injected sleep
/// advances, so polling runs instantly and deterministically.
@MainActor
private final class InsightHarness {
    var cloud = true
    var signedIn = true
    var scope: CloudDataScope? = CloudDataScope(ownerId: "owner-a", sourceId: "source-a")
    /// Answers in order; the last one repeats.
    var answers: [MetricInsightFetchResult] = []
    var requests: [(scope: CloudDataScope, metric: MetricInsightMetric)] = []
    var sleeps: [TimeInterval] = []
    var now = Date(timeIntervalSince1970: 1_791_341_011)
    /// When set, each fetch waits here until the test resumes it.
    var holdFetch = false
    var held: CheckedContinuation<Void, Never>?
    /// Run after each recorded fetch, before it answers (e.g. to change the account mid-flight).
    var duringFetch: (() -> Void)?
    var sleepError: Error?
    /// Run at each sleep, before the clock moves (e.g. to make the account ready).
    var duringSleep: (() -> Void)?

    func store() -> MetricInsightStore {
        MetricInsightStore(environment: .init(
            cloudEnabled: { self.cloud },
            signedIn: { self.signedIn },
            runningScope: { self.scope },
            fetch: { scope, metric in
                self.requests.append((scope, metric))
                if self.holdFetch { await withCheckedContinuation { self.held = $0 } }
                self.duringFetch?()
                guard !self.answers.isEmpty else { return .failed(.transport) }
                return self.answers.count > 1 ? self.answers.removeFirst() : self.answers[0]
            },
            now: { self.now },
            sleep: { seconds in
                self.sleeps.append(seconds)
                self.duringSleep?()
                if let error = self.sleepError { throw error }
                self.now = self.now.addingTimeInterval(seconds)
            }))
    }
}

/// The explanation card's state machine: what each server answer shows, bounded polling, the old-server and
/// failure paths, the wording guard, and that nothing read for one account survives into the next.
@MainActor
final class MetricInsightStoreTests: XCTestCase {

    typealias F = MetricInsightFixtures
    private let rhr = MetricInsightMetric.restingHeartRate

    private func answer(_ status: String, insight: [String: Any]? = nil, reason: String? = nil,
                        retryAfter: Int? = nil) -> MetricInsightFetchResult {
        .response(F.decoded(F.response(status: status, insight: insight, reason: reason, retryAfter: retryAfter))!)
    }

    // MARK: - Answers

    func testReadyIsShownAsCurrent() async {
        let h = InsightHarness()
        h.answers = [answer("ready", insight: F.insight())]
        let s = h.store()
        await s.refresh(rhr)
        let state = s.state(for: rhr)
        XCTAssertEqual(state?.phase, .ready)
        XCTAssertTrue(state?.insightIsCurrent == true)
        XCTAssertEqual(state?.insight?.headline, "Resting heart rate is back near your usual range")
        XCTAssertEqual(h.requests.count, 1, "a settled answer is not polled")
        XCTAssertEqual(h.requests.first?.metric, rhr)
        XCTAssertTrue(h.sleeps.isEmpty)
    }

    func testPendingPollsAtTheSuggestedIntervalThenShowsReady() async {
        let h = InsightHarness()
        h.answers = [answer("pending", retryAfter: 10), answer("pending", retryAfter: 10),
                     answer("ready", insight: F.insight())]
        let s = h.store()
        await s.refresh(rhr)
        XCTAssertEqual(h.requests.count, 3)
        XCTAssertEqual(h.sleeps, [10, 10])
        XCTAssertEqual(s.state(for: rhr)?.phase, .ready)
        XCTAssertTrue(s.state(for: rhr)?.insightIsCurrent == true)
    }

    func testPendingWithoutAnInsightIsTheQuietPlaceholderState() async {
        let h = InsightHarness()
        h.answers = [answer("pending", retryAfter: 10)]
        h.sleepError = CancellationError()   // the screen leaves during the first wait
        let s = h.store()
        await s.refresh(rhr)
        XCTAssertEqual(s.state(for: rhr), MetricInsightStore.State(phase: .pending, insight: nil,
                                                                  insightIsCurrent: false))
        XCTAssertEqual(h.requests.count, 1, "a cancelled wait stops polling")
    }

    func testPendingWithAStaleInsightShowsItAsNotCurrent() async {
        let h = InsightHarness()
        h.answers = [answer("pending", insight: F.insight(stale: true), retryAfter: 10)]
        h.sleepError = CancellationError()
        let s = h.store()
        await s.refresh(rhr)
        XCTAssertEqual(s.state(for: rhr)?.phase, .pending)
        XCTAssertEqual(s.state(for: rhr)?.insight?.stale, true)
        XCTAssertFalse(s.state(for: rhr)?.insightIsCurrent ?? true)
    }

    func testThePollIntervalIsClamped() {
        XCTAssertEqual(MetricInsightStore.pollDelay(retryAfterS: 1), 5)
        XCTAssertEqual(MetricInsightStore.pollDelay(retryAfterS: 0), 5)
        XCTAssertEqual(MetricInsightStore.pollDelay(retryAfterS: -4), 5)
        XCTAssertEqual(MetricInsightStore.pollDelay(retryAfterS: 12), 12)
        XCTAssertEqual(MetricInsightStore.pollDelay(retryAfterS: 60), 30)
        XCTAssertEqual(MetricInsightStore.pollDelay(retryAfterS: nil), 10)
    }

    func testPendingPastThePollBudgetBecomesUnavailableKeepingTheStaleInsight() async {
        let h = InsightHarness()
        h.answers = [answer("pending", insight: F.insight(stale: true), retryAfter: 60)]   // clamped to 30
        let s = h.store()
        await s.refresh(rhr)
        // Requests at 0, 30, 60 and 90 s; the next would land past the 90 s budget.
        XCTAssertEqual(h.requests.count, 4)
        XCTAssertEqual(h.sleeps, [30, 30, 30])
        let state = s.state(for: rhr)
        XCTAssertEqual(state?.phase, .unavailable)
        XCTAssertEqual(state?.insight?.headline, "Resting heart rate is back near your usual range",
                       "the earlier explanation stays on screen")
        XCTAssertFalse(state?.insightIsCurrent ?? true, "still marked as not current")

        // Without an earlier explanation the budget ends in the plain unavailable state.
        let bare = InsightHarness()
        bare.answers = [answer("pending", retryAfter: 5)]
        let t = bare.store()
        await t.refresh(rhr)
        XCTAssertEqual(bare.requests.count, 19, "0, 5, ..., 90 s")
        XCTAssertEqual(t.state(for: rhr), MetricInsightStore.State(phase: .unavailable, insight: nil,
                                                                  insightIsCurrent: false))
    }

    func testNoMeasuredDataSaysSoWithoutAnyExplanation() async {
        let h = InsightHarness()
        h.answers = [answer("ready", insight: F.insight()), answer("unavailable", reason: "no_measured_data")]
        let s = h.store()
        await s.refresh(rhr)
        await s.refresh(rhr)
        XCTAssertEqual(s.state(for: rhr), MetricInsightStore.State(phase: .notEnoughData, insight: nil,
                                                                  insightIsCurrent: false),
                       "an explanation of nights that are no longer measured is not kept")
    }

    func testAnalysisFailedAndDailyLimitAreUnavailableWithTheStaleInsight() async {
        for reason in ["analysis_failed", "daily_limit", "something_new"] {
            let h = InsightHarness()
            h.answers = [answer("unavailable", insight: F.insight(stale: true), reason: reason)]
            let s = h.store()
            await s.refresh(rhr)
            XCTAssertEqual(s.state(for: rhr)?.phase, .unavailable, reason)
            XCTAssertEqual(s.state(for: rhr)?.insight?.stale, true, reason)
            XCTAssertFalse(s.state(for: rhr)?.insightIsCurrent ?? true, reason)
            XCTAssertEqual(h.requests.count, 1, reason)
        }
        // An unknown status reads like unavailable.
        let h = InsightHarness()
        h.answers = [answer("queued")]
        let s = h.store()
        await s.refresh(rhr)
        XCTAssertEqual(s.state(for: rhr)?.phase, .unavailable)
    }

    // MARK: - Old servers and failures

    func testAnOlderServerIsUnavailableNotAnError() async {
        let h = InsightHarness()
        h.answers = [.unsupportedServer]
        let s = h.store()
        await s.refresh(rhr)
        XCTAssertEqual(s.state(for: rhr), MetricInsightStore.State(phase: .unavailable, insight: nil,
                                                                  insightIsCurrent: false))
        XCTAssertEqual(h.requests.count, 1)
        XCTAssertTrue(h.sleeps.isEmpty, "a 405 is not retried")
    }

    func testATransportOrServerErrorIsUnavailableAndKeepsWhatWasShown() async {
        for failure in [MetricInsightFetchResult.failed(.transport), .failed(.http(500)), .failed(.http(503)),
                        .failed(.malformed), .failed(.missingIdentity)] {
            let h = InsightHarness()
            h.answers = [answer("ready", insight: F.insight()), failure]
            let s = h.store()
            await s.refresh(rhr)
            await s.refresh(rhr)
            let state = s.state(for: rhr)
            XCTAssertEqual(state?.phase, .unavailable, "\(failure)")
            XCTAssertEqual(state?.insight?.headline, "Resting heart rate is back near your usual range", "\(failure)")
            XCTAssertFalse(state?.insightIsCurrent ?? true, "\(failure)")
        }
        let h = InsightHarness()
        h.answers = [.failed(.transport)]
        let s = h.store()
        await s.refresh(rhr)
        XCTAssertEqual(s.state(for: rhr), MetricInsightStore.State(phase: .unavailable, insight: nil,
                                                                  insightIsCurrent: false))
    }

    func testACancelledRequestChangesNothing() async {
        let h = InsightHarness()
        h.answers = [answer("ready", insight: F.insight()), .cancelled]
        let s = h.store()
        await s.refresh(rhr)
        let before = s.state(for: rhr)
        await s.refresh(rhr)
        XCTAssertEqual(s.state(for: rhr), before)
    }

    // MARK: - Wording guard

    func testAnExplanationThatTripsTheWordingGuardIsNotShown() async {
        let h = InsightHarness()
        h.answers = [answer("ready", insight: F.insight(headline: "Your stress is showing in your heart rate"))]
        let s = h.store()
        await s.refresh(rhr)
        XCTAssertEqual(s.state(for: rhr), MetricInsightStore.State(phase: .unavailable, insight: nil,
                                                                  insightIsCurrent: false))

        // A rejected newer explanation falls back to the clean one already shown, marked as not current.
        let warm = InsightHarness()
        warm.answers = [answer("ready", insight: F.insight()),
                        answer("pending", insight: F.insight(observed: ["Signs of illness."]), retryAfter: 10)]
        warm.sleepError = CancellationError()
        let t = warm.store()
        await t.refresh(rhr)
        await t.refresh(rhr)
        XCTAssertEqual(t.state(for: rhr)?.phase, .pending)
        XCTAssertEqual(t.state(for: rhr)?.insight?.observed, ["Last night was 52 bpm.", "Your 30-night median is 54 bpm."])
        XCTAssertFalse(t.state(for: rhr)?.insightIsCurrent ?? true)
    }

    // MARK: - Preconditions

    func testLocalOnlyHidesTheCardAndSignedOutSaysSo() async {
        let off = InsightHarness()
        off.cloud = false
        let s = off.store()
        await s.refresh(rhr)
        XCTAssertEqual(s.state(for: rhr)?.phase, .hidden)

        let out = InsightHarness()
        out.signedIn = false
        out.scope = nil
        let t = out.store()
        await t.refresh(rhr)
        XCTAssertEqual(t.state(for: rhr)?.phase, .signedOut)
        XCTAssertTrue(off.requests.isEmpty && out.requests.isEmpty, "nothing is sent")
    }

    func testAnAccountStillConnectingIsWaitedForWithinTheBudget() async {
        let h = InsightHarness()
        h.scope = nil
        h.answers = [answer("ready", insight: F.insight())]
        var checks = 0
        h.duringSleep = {
            checks += 1
            if checks == 2 { h.scope = CloudDataScope(ownerId: "owner-a", sourceId: "source-a") }
        }
        let s = h.store()
        await s.refresh(rhr)
        XCTAssertEqual(h.sleeps, [MetricInsightStore.accountWaitDelay, MetricInsightStore.accountWaitDelay])
        XCTAssertEqual(h.requests.count, 1)
        XCTAssertEqual(s.state(for: rhr)?.phase, .ready)

        // An account that never connects ends unavailable after the budget, never stuck loading.
        let never = InsightHarness()
        never.scope = nil
        let t = never.store()
        await t.refresh(rhr)
        XCTAssertEqual(t.state(for: rhr)?.phase, .unavailable)
        XCTAssertTrue(never.requests.isEmpty)
    }

    // MARK: - Cache and accounts

    func testReopeningShowsTheCachedExplanationWhileRevalidating() async throws {
        let h = InsightHarness()
        h.answers = [answer("ready", insight: F.insight()),
                     answer("ready", insight: F.insight(headline: "Resting heart rate is a little above your usual range"))]
        let s = h.store()
        await s.refresh(rhr)

        h.holdFetch = true
        let reopen = Task { await s.refresh(rhr) }
        for _ in 0..<200 where h.held == nil { await Task.yield() }
        XCTAssertNotNil(h.held, "the revalidation request is out")
        XCTAssertEqual(s.state(for: rhr)?.phase, .ready, "the cached explanation shows at once")
        XCTAssertEqual(s.state(for: rhr)?.insight?.headline, "Resting heart rate is back near your usual range")
        h.held?.resume()
        await reopen.value
        XCTAssertEqual(s.state(for: rhr)?.insight?.headline, "Resting heart rate is a little above your usual range")
    }

    func testResetClearsTheCacheAndDropsAnAnswerStillInFlight() async {
        let h = InsightHarness()
        h.answers = [answer("ready", insight: F.insight())]
        let s = h.store()
        await s.refresh(rhr)
        XCTAssertNotNil(s.state(for: rhr))
        let epoch = s.epoch
        s.reset()
        XCTAssertNil(s.state(for: rhr))
        XCTAssertTrue(s.states.isEmpty)
        XCTAssertGreaterThan(s.epoch, epoch, "an open card asks again for the next account")

        h.holdFetch = true
        let inFlight = Task { await s.refresh(rhr) }
        for _ in 0..<200 where h.held == nil { await Task.yield() }
        XCTAssertNotNil(h.held)
        s.reset()   // the account ends while the request is out
        h.held?.resume()
        await inFlight.value
        XCTAssertNil(s.state(for: rhr), "an answer read with the previous account's credential is dropped")
    }

    func testADifferentRunningAccountNeverSeesTheCachedExplanation() async {
        let h = InsightHarness()
        h.answers = [answer("ready", insight: F.insight()), .failed(.transport)]
        let s = h.store()
        await s.refresh(rhr)
        h.scope = CloudDataScope(ownerId: "owner-b", sourceId: "source-b")
        await s.refresh(rhr)
        XCTAssertEqual(s.state(for: rhr), MetricInsightStore.State(phase: .unavailable, insight: nil,
                                                                  insightIsCurrent: false),
                       "account B's failure must not fall back to account A's explanation")
        XCTAssertEqual(h.requests.last?.scope, CloudDataScope(ownerId: "owner-b", sourceId: "source-b"))

        // And an answer for A that lands after the switch is dropped.
        let mid = InsightHarness()
        mid.answers = [answer("ready", insight: F.insight())]
        mid.duringFetch = { mid.scope = CloudDataScope(ownerId: "owner-b", sourceId: "source-b") }
        let t = mid.store()
        await t.refresh(rhr)
        XCTAssertNil(t.state(for: rhr)?.insight)
    }

    func testMetricsAreCachedSeparately() async {
        let h = InsightHarness()
        h.answers = [answer("ready", insight: F.insight()), answer("unavailable", reason: "no_measured_data")]
        let s = h.store()
        await s.refresh(.restingHeartRate)
        await s.refresh(.hrvRmssd)
        XCTAssertEqual(s.state(for: .restingHeartRate)?.phase, .ready)
        XCTAssertEqual(s.state(for: .hrvRmssd)?.phase, .notEnoughData)
        XCTAssertEqual(h.requests.map(\.metric), [.restingHeartRate, .hrvRmssd])
    }
}
