import XCTest
@testable import NoopPush

final class PushSourceWakeSchedulerTests: XCTestCase {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 0
        private var owner = "a"
        private var attempts: [TimeInterval] = []
        private var continuations = 0
        func set(time: TimeInterval? = nil, owner: String? = nil) {
            lock.lock(); defer { lock.unlock() }
            if let time { self.time = time }; if let owner { self.owner = owner }
        }
        func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
        func current(_ value: String) -> Bool { lock.lock(); defer { lock.unlock() }; return owner == value }
        func attempt() { lock.lock(); defer { lock.unlock() }; attempts.append(time) }
        func handoff() { lock.lock(); defer { lock.unlock() }; continuations += 1 }
        func observed() -> ([TimeInterval], Int) { lock.lock(); defer { lock.unlock() }; return (attempts, continuations) }
    }
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
        func open() { opened = true; let saved = waiters; waiters = []; saved.forEach { $0.resume() } }
    }

    func testSparseCommitUsesItsT1ToT3OpportunityAfterT0CompletedRun() async {
        let state = State(), scheduler = PushSourceWakeScheduler<String>(clock: { state.now() })
        let first = await scheduler.request(key: "writer-a", sourceReady: false, interval: 10,
            isCurrent: { state.current("a") }, run: { state.attempt() }, continueDurably: { state.handoff() })
        await first?.value
        state.set(time: 1)
        let periodic = await scheduler.request(key: "writer-a", sourceReady: false, interval: 10,
            isCurrent: { state.current("a") }, run: { XCTFail("poll remains throttled") }, continueDurably: {})
        XCTAssertNil(periodic)
        let source = await scheduler.request(key: "writer-a", sourceReady: true, interval: 10,
            isCurrent: { state.current("a") }, run: {
                XCTAssertLessThan(state.now(), 3, "sparse source must use its admitted opportunity")
                state.attempt()
            }, continueDurably: { state.handoff() })
        await source?.value
        XCTAssertEqual(state.observed().0, [0, 1])
        XCTAssertEqual(state.observed().1, 2)
    }

    func testInFlightHintsCoalesceButDoNotRunOldWriterAfterOwnerReplacement() async {
        let state = State(), scheduler = PushSourceWakeScheduler<String>(), gate = Gate()
        let entered = expectation(description: "old run entered")
        let first = await scheduler.request(key: "writer-a-generation-1", sourceReady: true, interval: 10,
            isCurrent: { state.current("a") }, run: { state.attempt(); entered.fulfill(); await gate.wait() },
            continueDurably: { XCTFail("retired owner cannot schedule replacement work") })
        await fulfillment(of: [entered], timeout: 2)
        _ = await scheduler.request(key: "writer-a-generation-1", sourceReady: true, interval: 10,
            isCurrent: { state.current("a") }, run: { XCTFail("old trailing writer ran") }, continueDurably: {})
        state.set(time: 1, owner: "b")
        let replacement = await scheduler.request(key: "writer-b-generation-2", sourceReady: true, interval: 10,
            isCurrent: { state.current("b") }, run: { state.attempt() }, continueDurably: { state.handoff() })
        await replacement?.value
        await gate.open(); await first?.value
        XCTAssertEqual(state.observed().0, [0, 1]); XCTAssertEqual(state.observed().1, 1)
    }

    func testCancellationRetainsNoTrailingInProcessTask() async {
        let state = State(), scheduler = PushSourceWakeScheduler<String>(), gate = Gate()
        let entered = expectation(description: "source run entered")
        let first = await scheduler.request(key: "writer", sourceReady: true, interval: 10,
            isCurrent: { true }, run: { state.attempt(); entered.fulfill(); await gate.wait() }, continueDurably: {})
        await fulfillment(of: [entered], timeout: 2)
        _ = await scheduler.request(key: "writer", sourceReady: true, interval: 10,
            isCurrent: { true }, run: { XCTFail("cancelled trailing hint ran") }, continueDurably: {})
        await scheduler.cancel(key: "writer"); await gate.open(); await first?.value
        let reopened = await scheduler.request(key: "writer", sourceReady: true, interval: 10,
            isCurrent: { true }, run: { state.attempt() }, continueDurably: { state.handoff() })
        await reopened?.value
        XCTAssertEqual(state.observed().0.count, 2); XCTAssertEqual(state.observed().1, 1)
    }

    func testContinuousHintsAreBoundedToTwoPassesThenDurableHandoff() async {
        let state = State(), scheduler = PushSourceWakeScheduler<String>()
        let first = await scheduler.request(key: "writer", sourceReady: true, interval: 10,
            isCurrent: { true }, run: {
                state.attempt()
                for _ in 0..<50 {
                    _ = await scheduler.request(key: "writer", sourceReady: true, interval: 10,
                        isCurrent: { true }, run: {
                            state.attempt()
                            _ = await scheduler.request(key: "writer", sourceReady: true, interval: 10,
                                isCurrent: { true }, run: { XCTFail("unbounded third pass") }, continueDurably: {})
                        }, continueDurably: { state.handoff() })
                }
            }, continueDurably: { state.handoff() })
        await first?.value
        XCTAssertEqual(state.observed().0.count, 2); XCTAssertEqual(state.observed().1, 1)
    }

    func testDeferredPreparationStillHandsDurableDebtOffWithoutBackoffTimer() async {
        let state = State(), scheduler = PushSourceWakeScheduler<String>(clock: { state.now() })
        for time in [0.0, 1.0] {
            state.set(time: time)
            let task = await scheduler.request(key: "writer", sourceReady: true, interval: 10,
                isCurrent: { true }, run: { /* network/storage admission denied; rows stay committed */ },
                continueDurably: { state.handoff() })
            await task?.value
        }
        XCTAssertTrue(state.observed().0.isEmpty); XCTAssertEqual(state.observed().1, 2)
    }
}
