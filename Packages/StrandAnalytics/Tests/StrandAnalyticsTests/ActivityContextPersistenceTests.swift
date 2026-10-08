import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

/// The hand-off between the analytics model and the database: a decoded day goes in as intervals and a
/// ledger row, and what comes back out is the same context, readable by version.
final class ActivityContextPersistenceTests: XCTestCase {
    private let t0 = 1_760_000_000
    private let dev = "my-whoop"

    private func fullInterval() -> ActivityContextInterval {
        ActivityContextInterval(
            start: t0, end: t0 + 300, activityClass: .briskWalking, confidence: 0.81,
            runnerUp: .walking, runnerUpConfidence: 0.19, evidenceQuality: 0.9,
            posture: .uprightStationary, locomotion: .briskWalking, armBehavior: .activeGesturing,
            sleep: .awake, wear: .onWrist, intensity: 0.62, stepTicks: 610, cadenceSpm: 121.5,
            hrSamples: 298, hrMean: 112.4, hrMin: 98, hrMax: 131, hrSlope: 3.25,
            rmssd: 31.5, rrBeats: 540, respRateBpm: 17.2, respBreaths: 83)
    }

    func testEveryFieldSurvivesTheRowRoundTrip() {
        let original = fullInterval()
        XCTAssertEqual(ActivityContextInterval(row: original.storeRow), original)
        let bare = ActivityContextInterval(start: t0, end: t0 + 60, activityClass: .unknown, confidence: 0.1)
        XCTAssertEqual(ActivityContextInterval(row: bare.storeRow), bare)
    }

    func testEveryClassAndContextCodeHasAStablePersistedForm() {
        // The stored strings are the enums' raw values; if one is renamed this fails before a database
        // full of the old spelling does.
        XCTAssertEqual(ActivityClass.allCases.map(\.rawValue).sorted(), [
            "brisk_walking", "cycling", "fidgeting", "light_activity", "lying_down", "off_wrist", "running",
            "sitting", "sitting_desk", "sleeping", "standing", "stationary", "unknown", "vigorous_activity",
            "walking",
        ])
        for cls in ActivityClass.allCases {
            var iv = ActivityContextInterval(start: 0, end: 10, activityClass: cls, confidence: 0.5)
            iv.runnerUp = cls
            XCTAssertEqual(ActivityContextInterval(row: iv.storeRow).activityClass, cls)
            XCTAssertEqual(ActivityContextInterval(row: iv.storeRow).runnerUp, cls)
        }
    }

    func testCodesFromANewerBuildReadAsUnknownInsteadOfDroppingTheTime() {
        let row = ActivityContextIntervalRow(
            startTs: t0, endTs: t0 + 120, activityClass: "kayaking", confidence: 0.7, runnerUp: "rowing",
            posture: "floating", locomotion: "paddling", armBehavior: "stroking",
            sleepState: "dozing", wearState: "submerged")
        let iv = ActivityContextInterval(row: row)
        XCTAssertEqual(iv.activityClass, .unknown)
        XCTAssertNil(iv.runnerUp)
        XCTAssertNil(iv.posture)
        XCTAssertNil(iv.locomotion)
        XCTAssertNil(iv.armBehavior)
        XCTAssertEqual(iv.sleep, .unknown)
        XCTAssertEqual(iv.wear, .unknown)
        XCTAssertEqual(iv.durationSeconds, 120, "the time is still accounted for")
        XCTAssertEqual(iv.confidence, 0.7)
    }

    /// `iv` with the context fields that `ActivityContextIntervalRow` does not (yet) carry put back to their defaults.
    static func rowFieldsOnly(_ iv: ActivityContextInterval) -> ActivityContextInterval {
        var out = iv
        out.inBed = false; out.uncertainty = 0; out.experts = []; out.transitionCount = 0
        out.absorbedClasses = []; out.absorbedSeconds = 0; out.precededByGapS = nil; out.settlingSeconds = 0
        return out
    }

    func testADecodedDayRoundTripsThroughTheStoreAndTheLookupAgrees() async throws {
        var sim = ActivitySim(start: t0)
        sim.desk(600); sim.walk(180); sim.desk(600); sim.run(120); sim.still(300)
        let input = sim.trackInput()
        let track = ActivityContextTrackBuilder.build(input)
        let document = ActivityContextDayDocument(track: track, input: input, generatedAt: t0 + 5_000)
        let intervals = ActivityContextIntervalBuilder.build(document: document, hr: input.hr, steps: input.steps)
        XCTAssertFalse(intervals.isEmpty)

        let store = try await WhoopStore.inMemory()
        let ledger = ActivityContextPersistence.dayRow(day: "2025-10-09", document: document,
                                                      intervalCount: intervals.count, computedAt: t0 + 6_000)
        try await store.replaceActivityContext(deviceId: dev, day: ledger, intervals: intervals.map(\.storeRow))

        let rows = try await store.activityContextIntervals(deviceId: dev, from: document.dayStart, to: document.dayEnd)
        // The ctx-int-2 context fields (in-bed, uncertainty, experts, transitions, absorbed fragments, gap, settling)
        // have no store columns until the WhoopStore row carries them; everything the row does carry round-trips.
        func stored(_ iv: ActivityContextInterval?) -> ActivityContextInterval? { iv.map(Self.rowFieldsOnly) }
        XCTAssertEqual(rows.map(ActivityContextInterval.init(row:)).map(Self.rowFieldsOnly), intervals.map(Self.rowFieldsOnly))

        let live = ActivityContextLookup(intervals: intervals)
        let storedLookup = ActivityContextLookup(rows: rows)
        for ts in stride(from: t0 - 30, to: t0 + 1_900, by: 7) {
            XCTAssertEqual(stored(storedLookup.interval(at: ts)), stored(live.interval(at: ts)), "t0+\(ts - t0)")
            let fromStore = try await store.activityContextInterval(deviceId: dev, at: ts)
            XCTAssertEqual(stored(fromStore.map(ActivityContextInterval.init(row:))), stored(live.interval(at: ts)), "t0+\(ts - t0)")
        }

        // The per-day class totals the database computes equal the in-memory composition.
        let day = try await store.activityContextDay(deviceId: dev, day: "2025-10-09")
        XCTAssertEqual(day?.intervalCount, intervals.count)
        let classSeconds = try await store.activityContextDayClassSeconds(deviceId: dev, from: "2025-10-09", to: "2025-10-09")
        let composition = live.composition(from: document.dayStart, to: document.dayEnd).seconds
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: classSeconds.map { ($0.activityClass, $0.seconds) }),
                       Dictionary(uniqueKeysWithValues: composition.map { ($0.key.rawValue, $0.value) }))
    }

    func testTheLedgerIsStampedWithTheVersionsThatProducedTheDay() throws {
        var sim = ActivitySim(start: t0)
        sim.desk(120)
        let input = sim.trackInput()
        let document = ActivityContextDayDocument(track: ActivityContextTrackBuilder.build(input), input: input, generatedAt: t0 + 500)
        let ledger = ActivityContextPersistence.dayRow(day: "2025-10-09", document: document, intervalCount: 3, computedAt: t0 + 600)
        XCTAssertEqual(ledger.taxonomyVersion, ActivityClassVersions.taxonomy)
        XCTAssertEqual(ledger.decoderVersion, ActivityContextVersions.decoder)
        XCTAssertEqual(ledger.ontologyVersion, ActivityContextVersions.ontology)
        XCTAssertEqual(ledger.intervalVersion, ActivityClassVersions.interval)
        XCTAssertEqual(ledger.dayStart, document.dayStart)
        XCTAssertEqual(ledger.dayEnd, document.dayEnd)
        XCTAssertEqual(ledger.dataThrough, document.dataThrough)
        XCTAssertEqual(ledger.observedSeconds, document.observedSeconds)
        XCTAssertEqual(ledger.intervalCount, 3)
        XCTAssertEqual(ledger.computedAt, t0 + 600)
        XCTAssertTrue(ActivityContextPersistence.isCurrent(ledger))
    }

    func testAnyChangedVersionMakesAStoredDayStale() {
        let current = ActivityContextDayRow(
            day: "2025-10-09", dayStart: t0, dayEnd: t0 + 86_400,
            taxonomyVersion: ActivityClassVersions.taxonomy, decoderVersion: ActivityContextVersions.decoder,
            ontologyVersion: ActivityContextVersions.ontology, intervalVersion: ActivityClassVersions.interval,
            computedAt: t0)
        XCTAssertTrue(ActivityContextPersistence.isCurrent(current))
        var older = current; older.taxonomyVersion = "act-class-0"
        XCTAssertFalse(ActivityContextPersistence.isCurrent(older))
        older = current; older.decoderVersion = "hsmm-1.1"
        XCTAssertFalse(ActivityContextPersistence.isCurrent(older))
        older = current; older.ontologyVersion = "1.0"
        XCTAssertFalse(ActivityContextPersistence.isCurrent(older))
        older = current; older.intervalVersion = "ctx-int-0"
        XCTAssertFalse(ActivityContextPersistence.isCurrent(older))
    }

    func testClippingKeepsOneDaysRowsInsideItsRange() {
        let a = ActivityContextInterval(start: t0, end: t0 + 100, activityClass: .sitting, confidence: 0.6, hrMean: 61)
        let b = ActivityContextInterval(start: t0 + 100, end: t0 + 300, activityClass: .walking, confidence: 0.9, hrMean: 99)
        let c = ActivityContextInterval(start: t0 + 300, end: t0 + 400, activityClass: .sitting, confidence: 0.7)
        let clipped = ActivityContextPersistence.clipped([a, b, c], from: t0 + 40, to: t0 + 320)
        XCTAssertEqual(clipped.map { [$0.start, $0.end] }, [[t0 + 40, t0 + 100], [t0 + 100, t0 + 300], [t0 + 300, t0 + 320]])
        XCTAssertEqual(clipped.map(\.hrMean), [61, 99, nil], "statistics stay as measured; only the bounds move")
        XCTAssertEqual(ActivityContextPersistence.clipped([a, b, c], from: t0, to: t0 + 400), [a, b, c])
        XCTAssertTrue(ActivityContextPersistence.clipped([a, b, c], from: t0 + 400, to: t0 + 900).isEmpty,
                      "an interval ending exactly at `from` is outside")
        XCTAssertTrue(ActivityContextPersistence.clipped([a], from: t0 + 50, to: t0 + 50).isEmpty)
    }

    func testContextFromSeveralOwnersMergesIntoOneNonOverlappingTimeline() {
        func iv(_ s: Int, _ e: Int, _ c: ActivityClass) -> ActivityContextInterval {
            ActivityContextInterval(start: t0 + s, end: t0 + e, activityClass: c, confidence: 0.7)
        }
        let active = [iv(100, 200, .walking), iv(400, 500, .sitting)]
        let canonical = [iv(0, 100, .sitting), iv(150, 450, .standing), iv(500, 600, .running), iv(600, 700, .sitting)]
        let merged = ActivityContextPersistence.merged([active, canonical])
        XCTAssertEqual(merged.map { [$0.start - t0, $0.end - t0] }, [[0, 100], [100, 200], [400, 500], [500, 600], [600, 700]])
        XCTAssertEqual(merged.map(\.activityClass), [.sitting, .walking, .sitting, .running, .sitting],
                       "where two owners describe the same instants the first list wins, and the later one is dropped whole")
        for (a, b) in zip(merged, merged.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start) }
        XCTAssertEqual(ActivityContextPersistence.merged([]), [])
        XCTAssertEqual(ActivityContextPersistence.merged([[], active]), active)
        XCTAssertEqual(ActivityContextPersistence.merged([active, active]), active, "the same rows read twice are one timeline")
    }

    func testBuilderOutputAlwaysSatisfiesTheStoresRules() async throws {
        // The builder's own cap sits inside the store's, and its output is ordered and non-overlapping: a
        // day built from any run list must be accepted, not rejected at write time.
        let runs = fixtureTimeline(from: t0, [(.desk, 4_000), (.walking, 45), (.standing, 20), (.running, 1_500), (.asleep, 20_000)])
        let intervals = ActivityContextIntervalBuilder.build(runs: runs)
        let store = try await WhoopStore.inMemory()
        let ledger = ActivityContextDayRow(
            day: "2025-10-09", dayStart: t0, dayEnd: t0 + 86_400, taxonomyVersion: ActivityClassVersions.taxonomy,
            decoderVersion: ActivityContextVersions.decoder, ontologyVersion: ActivityContextVersions.ontology,
            intervalVersion: ActivityClassVersions.interval, computedAt: t0)
        try await store.replaceActivityContext(deviceId: dev, day: ledger, intervals: intervals.map(\.storeRow))
        let back = try await store.activityContextIntervals(deviceId: dev, from: t0, to: t0 + 86_400)
        XCTAssertEqual(back.count, intervals.count)
        XCTAssertLessThanOrEqual(ActivityContextIntervalBuilder.Config().maxIntervalS, ActivityContextStore.maxIntervalSeconds)
    }
}
