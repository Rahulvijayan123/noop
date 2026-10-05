import XCTest
@testable import Strand
import WhoopProtocol

/// What a strap's saved history may become once it is paired to a new owner.
///
/// The rule these pin is asymmetric on purpose. Keeping a stranger's days costs a new owner a polluted
/// account; discarding the owner's own unsynced days costs them data that is gone for good once the strap
/// frees it. So only a definite "this account has no such strap" ever discards while someone is signed in, and
/// everything uncertain waits.
final class HistoryOwnershipTests: XCTestCase {

    private let t0 = 1_790_000_000

    private func facts(
        cloud: Bool = true, account: Bool = true, serial: Bool = true,
        continuity: Bool? = false, probe: HistoryProbe? = nil,
        firstSeen: Int? = nil, now: Int? = nil
    ) -> HistoryIntakeFacts {
        HistoryIntakeFacts(cloudEnabled: cloud, accountRunning: account, serialConfirmed: serial,
                           localContinuity: continuity, probe: probe,
                           firstSeenAt: firstSeen ?? t0, now: now ?? t0 + 5)
    }

    // MARK: - the decision

    func testNothingAppliesWhenTheCloudIsOff() {
        let out = HistoryOwnershipPolicy.decide(existing: nil, facts: facts(cloud: false, probe: .absent))
        XCTAssertEqual(out.intake, .keep)
        XCTAssertNil(out.record, "a local-only phone has no account to decide for, so nothing is remembered")
    }

    func testAStrapThePhoneAlreadyKnowsIsKept() {
        let out = HistoryOwnershipPolicy.decide(existing: nil, facts: facts(continuity: true, probe: .absent))
        XCTAssertEqual(out.intake, .keep, "local history outranks a server that has not heard of the strap yet")
        XCTAssertEqual(out.record?.kind, .keep)
    }

    func testAnUnreadableStoreIsNeverEvidenceOfNewness() {
        let out = HistoryOwnershipPolicy.decide(existing: nil, facts: facts(continuity: nil, probe: .absent))
        XCTAssertEqual(out.intake, .hold)
        XCTAssertNil(out.record)
    }

    func testAnAccountThatHoldsTheStrapKeepsItsHistory() {
        let out = HistoryOwnershipPolicy.decide(existing: nil, facts: facts(probe: .holds))
        XCTAssertEqual(out.intake, .keep)
        XCTAssertEqual(out.record?.kind, .keep)
    }

    func testAnAccountWithNoSuchStrapDiscardsEverythingBeforeItWasFirstSeen() {
        let out = HistoryOwnershipPolicy.decide(existing: nil, facts: facts(probe: .absent, firstSeen: t0 - 90, now: t0))
        XCTAssertEqual(out.intake, .discard(before: t0 - 90))
        XCTAssertEqual(out.record?.fence, t0 - 90, "the fence is the pairing, not the moment the question was answered")
    }

    func testAnAccountThatCannotBeAskedNeverDiscards() {
        for probe in [HistoryProbe.unreachable, nil] {
            let out = HistoryOwnershipPolicy.decide(existing: nil, facts: facts(probe: probe))
            XCTAssertEqual(out.intake, .hold)
            XCTAssertNil(out.record)
        }
    }

    func testAStrapWhoseSerialIsNotYetReadWaits() {
        let out = HistoryOwnershipPolicy.decide(existing: nil, facts: facts(serial: false, probe: .absent))
        XCTAssertEqual(out.intake, .hold, "an unconfirmed serial cannot be looked up, and a guess must not discard")
    }

    func testAStrapThatNeverConfirmsItsSerialIsEventuallyKeptRatherThanStarved() {
        let patience = HistoryOwnershipPolicy.unknownSerialPatience
        let early = HistoryOwnershipPolicy.decide(existing: nil,
            facts: facts(serial: false, firstSeen: t0, now: t0 + patience - 1))
        XCTAssertEqual(early.intake, .hold)
        let late = HistoryOwnershipPolicy.decide(existing: nil,
            facts: facts(serial: false, firstSeen: t0, now: t0 + patience))
        XCTAssertEqual(late.intake, .keep)
        XCTAssertEqual(late.record?.kind, .keep)
    }

    func testNobodySignedInGetsTheGraceThenTheStrapIsNewToThePhone() {
        let grace = HistoryOwnershipPolicy.signedOutGrace
        let waiting = HistoryOwnershipPolicy.decide(existing: nil,
            facts: facts(account: false, serial: false, firstSeen: t0, now: t0 + grace - 1))
        XCTAssertEqual(waiting.intake, .hold, "an account starts within seconds of launch; give it the chance")
        let done = HistoryOwnershipPolicy.decide(existing: nil,
            facts: facts(account: false, serial: false, firstSeen: t0, now: t0 + grace))
        XCTAssertEqual(done.intake, .discard(before: t0))
    }

    func testADecisionOnceTakenIsFinalWhateverTheFactsSayLater() {
        let kept = HistoryOwnershipRecord(kind: .keep, decidedAt: t0, fence: nil, reason: "r", discardedRecords: 0)
        XCTAssertEqual(HistoryOwnershipPolicy.decide(existing: kept, facts: facts(probe: .absent)).intake, .keep)
        let dropped = HistoryOwnershipRecord(kind: .discard, decidedAt: t0, fence: t0 - 10, reason: "r", discardedRecords: 4)
        let out = HistoryOwnershipPolicy.decide(existing: dropped, facts: facts(continuity: true, probe: .holds))
        XCTAssertEqual(out.intake, .discard(before: t0 - 10), "a fence that moved would let through what was already refused")
        XCTAssertEqual(out.record, dropped)
    }

    func testADiscardWithoutAFenceCannotBeActedOn() {
        let broken = HistoryOwnershipRecord(kind: .discard, decidedAt: t0, fence: nil, reason: "r", discardedRecords: 0)
        XCTAssertEqual(broken.intake, .hold)
    }

    // MARK: - the persisted record

    private func isolatedDefaults() -> UserDefaults {
        let name = "noop-history-ownership-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private let serialKey = "whoop-mgb0214654"
    private let slotKey = "slot-my-whoop"

    func testADecisionIsPerAccountAndPerStrap() {
        let store = HistoryOwnershipStore(defaults: isolatedDefaults())
        let record = HistoryOwnershipRecord(kind: .keep, decidedAt: t0, fence: nil, reason: "r", discardedRecords: 0)
        store.save(record, owner: "AAA", strap: [serialKey])
        XCTAssertEqual(store.record(owner: "aaa", strap: [serialKey]), record, "owner ids compare case-insensitively")
        XCTAssertNil(store.record(owner: "bbb", strap: [serialKey]), "another account on the same phone decides for itself")
        XCTAssertNil(store.record(owner: "aaa", strap: ["whoop-other"]), "another strap is decided for itself")
    }

    func testADecisionMadeBeforeTheSerialWasKnownFollowsTheStrapOnceItIs() {
        let store = HistoryOwnershipStore(defaults: isolatedDefaults())
        let record = HistoryOwnershipRecord(kind: .discard, decidedAt: t0, fence: t0 - 5, reason: "r", discardedRecords: 0)
        store.save(record, owner: "aaa", strap: [slotKey])
        XCTAssertEqual(store.record(owner: "aaa", strap: [serialKey, slotKey]), record)
        XCTAssertEqual(store.record(owner: "aaa", strap: [serialKey]), record, "the lookup copied it onto the serial")
    }

    func testTheDiscardedCountAccumulatesOnTheDecision() {
        let store = HistoryOwnershipStore(defaults: isolatedDefaults())
        store.addDiscarded(10, owner: "aaa", strap: [serialKey])
        XCTAssertNil(store.record(owner: "aaa", strap: [serialKey]), "a count without a decision is not a decision")
        store.save(HistoryOwnershipRecord(kind: .discard, decidedAt: t0, fence: t0, reason: "r", discardedRecords: 0),
                   owner: "aaa", strap: [serialKey, slotKey])
        store.addDiscarded(120, owner: "aaa", strap: [serialKey, slotKey])
        store.addDiscarded(30, owner: "aaa", strap: [serialKey, slotKey])
        XCTAssertEqual(store.record(owner: "aaa", strap: [serialKey])?.discardedRecords, 150)
        XCTAssertEqual(store.record(owner: "aaa", strap: [slotKey])?.discardedRecords, 150)
    }

    func testTheFirstSightingIsKeptAndSharedBetweenSlotAndSerial() {
        let store = HistoryOwnershipStore(defaults: isolatedDefaults())
        XCTAssertEqual(store.firstSeen(strap: [slotKey], now: t0), t0)
        XCTAssertEqual(store.firstSeen(strap: [slotKey], now: t0 + 3_600), t0, "later sightings do not move the fence")
        XCTAssertEqual(store.firstSeen(strap: [serialKey, slotKey], now: t0 + 7_200), t0,
                       "learning the serial must not restart the clock")
        XCTAssertEqual(store.firstSeen(strap: [serialKey], now: t0 + 9_000), t0)
        XCTAssertEqual(store.firstSeen(strap: ["whoop-other"], now: t0 + 9_000), t0 + 9_000)
    }

    func testAnAbandonedPairingStartsOverInsteadOfDraggingTheFenceBackwards() {
        let store = HistoryOwnershipStore(defaults: isolatedDefaults())
        _ = store.firstSeen(strap: [slotKey], now: t0)
        let later = t0 + HistoryOwnershipPolicy.staleSighting
        XCTAssertEqual(store.firstSeen(strap: [slotKey], now: later), later)
    }

    func testAPairingThatKeepsBeingSeenKeepsItsFence() {
        let store = HistoryOwnershipStore(defaults: isolatedDefaults())
        var now = t0
        _ = store.firstSeen(strap: [slotKey], now: now)
        for _ in 0..<6 {
            now += 6 * 3_600
            _ = store.firstSeen(strap: [slotKey], now: now)
        }
        XCTAssertEqual(store.firstSeen(strap: [slotKey], now: now), t0, "36 hours of use is one pairing")
    }

    func testStrapKeysNameTheSerialFirstAndTheSlotAlways() {
        XCTAssertEqual(HistoryOwnershipStore.strapKey(serial: "MGB0214654", localId: "my-whoop"),
                       ["whoop-mgb0214654", "slot-my-whoop"])
        XCTAssertEqual(HistoryOwnershipStore.strapKey(serial: nil, localId: "My-Whoop"), ["slot-my-whoop"])
        XCTAssertEqual(HistoryOwnershipStore.strapKey(serial: "", localId: "my-whoop"), ["slot-my-whoop"],
                       "a serial that cannot identify a strap names nothing")
    }

    // MARK: - the fence on decoded records

    private func everyStream(at ts: Int) -> Streams {
        Streams(hr: [HRSample(ts: ts, bpm: 60)],
                rr: [RRInterval(ts: ts, rrMs: 900)],
                spo2: [SpO2Sample(ts: ts, red: 1, ir: 2)],
                skinTemp: [SkinTempSample(ts: ts, raw: 3)],
                resp: [RespSample(ts: ts, raw: 4)],
                gravity: [GravitySample(ts: ts, x: 0, y: 0, z: 1)],
                steps: [StepSample(ts: ts, counter: 5)],
                sleepState: [SleepStateSample(ts: ts, state: 1)],
                ppgHr: [PpgHrSample(ts: ts, bpm: 61, conf: 0.9)],
                ppgWaveform: [PpgWaveformSample(ts: ts, samples: [1, 2, 3])],
                v18Aux: [V18AuxSample(ts: ts, slotValues: [1])],
                events: [WhoopEvent(ts: ts, kind: "BOOT(1)", payload: [:])],
                battery: [BatterySample(ts: ts, soc: 50, mv: 3_900)])
    }

    private func merged(_ a: Streams, _ b: Streams) -> Streams {
        Streams(hr: a.hr + b.hr, rr: a.rr + b.rr, spo2: a.spo2 + b.spo2, skinTemp: a.skinTemp + b.skinTemp,
                resp: a.resp + b.resp, gravity: a.gravity + b.gravity, steps: a.steps + b.steps,
                sleepState: a.sleepState + b.sleepState, ppgHr: a.ppgHr + b.ppgHr,
                ppgWaveform: a.ppgWaveform + b.ppgWaveform, v18Aux: a.v18Aux + b.v18Aux,
                events: a.events + b.events, battery: a.battery + b.battery)
    }

    func testTheFenceRemovesEveryKindOfRecordDatedBeforeIt() {
        let cut = everyStream(at: t0 - 1).discardingRecords(before: t0)
        XCTAssertTrue(cut.streams.isEmpty, "a previous owner's SpO2, skin temperature and steps are theirs too")
        XCTAssertEqual(cut.report.dropped, 13)
        XCTAssertEqual(cut.report.oldest, t0 - 1)
        XCTAssertEqual(cut.report.newest, t0 - 1)
    }

    func testTheFenceKeepsEveryKindOfRecordAtOrAfterIt() {
        let atFence = everyStream(at: t0).discardingRecords(before: t0)
        XCTAssertEqual(atFence.streams, everyStream(at: t0), "a record dated exactly at the fence is the new owner's")
        XCTAssertEqual(atFence.report.dropped, 0)
        XCTAssertNil(atFence.report.oldest)
        let after = everyStream(at: t0 + 600).discardingRecords(before: t0)
        XCTAssertEqual(after.streams, everyStream(at: t0 + 600))
    }

    func testAChunkThatStraddlesTheFenceIsSplitRecordByRecord() {
        let chunk = merged(everyStream(at: t0 - 7_200), everyStream(at: t0 + 5))
        let cut = chunk.discardingRecords(before: t0)
        XCTAssertEqual(cut.streams, everyStream(at: t0 + 5))
        XCTAssertEqual(cut.report.dropped, 13)
        XCTAssertEqual(cut.report.oldest, t0 - 7_200)
    }

    func testTheReportSpansEverythingAChunkLost() {
        var chunk = Streams(hr: [HRSample(ts: t0 - 300, bpm: 60), HRSample(ts: t0 - 100, bpm: 61)])
        chunk.battery = [BatterySample(ts: t0 - 900, soc: 40, mv: nil)]
        let cut = chunk.discardingRecords(before: t0)
        XCTAssertEqual(cut.report.dropped, 3)
        XCTAssertEqual(cut.report.oldest, t0 - 900)
        XCTAssertEqual(cut.report.newest, t0 - 100)
    }

    func testReportsAddUp() {
        var total = HistoryFenceReport()
        total.absorb(HistoryFenceReport(dropped: 2, oldest: 100, newest: 200))
        total.absorb(HistoryFenceReport())
        total.absorb(HistoryFenceReport(dropped: 3, oldest: 50, newest: 150))
        XCTAssertEqual(total, HistoryFenceReport(dropped: 5, oldest: 50, newest: 200))
    }

    func testTheSessionLineNamesTheSpanAndSaysNothingWasKept() {
        let day = 1_790_000_000
        let line = Backfiller.sessionDiscardLine(HistoryFenceReport(dropped: 412, oldest: day, newest: day + 90_000))
        XCTAssertTrue(line.contains("412 record(s)"), line)
        XCTAssertTrue(line.contains("without keeping them"), line)
        XCTAssertTrue(line.contains(" to "), line)
        XCTAssertFalse(line.contains("\u{2014}"))
    }

    // MARK: - asking the server

    func testOnlyTheRegistrationAnswerMeansTheAccountHasNoSuchStrap() {
        XCTAssertTrue(ServerScoreRepository.isUnregisteredDevice(status: 409, body: "{\"error\":\"device_registration_pending\"}"))
        XCTAssertFalse(ServerScoreRepository.isUnregisteredDevice(status: 409, body: "{\"error\":\"something_else\"}"))
        XCTAssertFalse(ServerScoreRepository.isUnregisteredDevice(status: 500, body: "device_registration_pending"))
        XCTAssertFalse(ServerScoreRepository.isUnregisteredDevice(status: 401, body: nil))
        XCTAssertFalse(ServerScoreRepository.isUnregisteredDevice(status: 409, body: nil))
    }
}
