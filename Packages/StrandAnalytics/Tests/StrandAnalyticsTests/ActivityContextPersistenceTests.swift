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
            rmssd: 31.5, rrBeats: 540, rrDiffSqSumMs2: 535_491.25, rrDiffCount: 539, respRateBpm: 17.2, respBreaths: 83,
            inBed: false, uncertainty: 0.27, experts: ["encoder", "hart_fine"], transitionCount: 3,
            absorbedClasses: [.lightActivity, .unknown], absorbedSeconds: 14, precededByGapS: 4, settlingSeconds: 0,
            detail: .stairs, detailConfidence: 0.66, precedingClass: .sittingDesk, settledFrom: nil)
    }

    /// A still row with every settled statistic, after a walk.
    private func settledInterval() -> ActivityContextInterval {
        ActivityContextInterval(
            start: t0 + 300, end: t0 + 900, activityClass: .sitting, confidence: 0.7, sleep: .awake, wear: .onWrist,
            intensity: 0.18, hrSamples: 600, hrMean: 74.2, hrMin: 66, hrMax: 101, rmssd: 41.3, rrBeats: 640,
            rrDiffSqSumMs2: 1_091_602.5, rrDiffCount: 639, inBed: false, uncertainty: 0.4, experts: [],
            transitionCount: 0, absorbedClasses: [], absorbedSeconds: 0, precededByGapS: 0, settlingSeconds: 120,
            detail: nil, precedingClass: .walking, settledFrom: t0 + 420, hrMeanSettled: 69.8, hrSamplesSettled: 480,
            rmssdSettled: 45.9, rrDiffSqSumMs2Settled: 1_071_123.75, rrDiffCountSettled: 508)
    }

    func testEveryFieldSurvivesTheRowRoundTrip() {
        let original = fullInterval()
        XCTAssertEqual(ActivityContextInterval(row: original.storeRow), original)
        XCTAssertEqual(ActivityContextInterval(row: settledInterval().storeRow), settledInterval())
        var ride = settledInterval()
        ride.detail = .inVehicle; ride.detailConfidence = 0.8; ride.hrMeanSettled = nil; ride.hrSamplesSettled = nil
        XCTAssertEqual(ActivityContextInterval(row: ride.storeRow), ride)
        let bare = ActivityContextInterval(start: t0, end: t0 + 60, activityClass: .unknown, confidence: 0.1)
        XCTAssertEqual(ActivityContextInterval(row: bare.storeRow), bare, "not recorded stays not recorded (NULL)")
    }

    func testListColumnsKeepEmptyApartFromNotRecorded() {
        let row = fullInterval().storeRow
        XCTAssertEqual(row.experts, "encoder,hart_fine")
        XCTAssertEqual(row.absorbedClasses, "light_activity,unknown")
        XCTAssertEqual(row.detail, "stairs")
        XCTAssertEqual(row.precedingClass, "sitting_desk")
        XCTAssertEqual(settledInterval().storeRow.experts, "", "recorded: no expert spoke")
        XCTAssertEqual(settledInterval().storeRow.absorbedClasses, "")
        XCTAssertNil(ActivityContextInterval(start: t0, end: t0 + 60, activityClass: .unknown, confidence: 0.1).storeRow.experts)
        // A code from a newer build: an absorbed class reads as unknown (the time is still accounted for), a
        // detail or preceding class as not recorded.
        var newer = row
        newer.absorbedClasses = "kayaking,sitting"; newer.detail = "on_a_boat"; newer.precedingClass = "rowing"
        let back = ActivityContextInterval(row: newer)
        XCTAssertEqual(back.absorbedClasses, [.unknown, .sitting])
        XCTAssertNil(back.detail)
        XCTAssertNil(back.precedingClass)
    }

    func testTransitionRowsCarryTheEventsOnsetAndSourceAndReadBackAsTheSameEvents() {
        let events = [
            ActivityTransitionEvent(kind: .sitToStandLike, probability: 0.62, ts: t0 + 100, onsetTs: t0 + 94,
                                    source: ActivityTransitionEvent.sourceTransitionExpert),
            ActivityTransitionEvent(kind: .walkStop, probability: 0.9, ts: t0 + 400, onsetTs: t0 + 397,
                                    source: ActivityTransitionEvent.sourceDecoder),
            ActivityTransitionEvent(kind: .standToSitLike, probability: 0.3, ts: t0 + 500),
        ]
        let rows = ActivityContextPersistence.transitionRows(events, from: t0, to: t0 + 1_000, decoderVersion: "hsmm-1.8")
        XCTAssertEqual(rows.map(\.onsetTs), [t0 + 94, t0 + 397, nil])
        XCTAssertEqual(rows.map(\.source), ["transition_expert", "hsmm", nil])
        XCTAssertEqual(ActivityContextPersistence.events(rows), events)
        var newer = rows
        newer.append(ActivityContextTransitionRow(ts: t0 + 600, kind: "cartwheel", probability: 0.9, decoderVersion: "hsmm-9"))
        XCTAssertEqual(ActivityContextPersistence.events(newer), events, "a kind this build does not know is left out")
    }

    func testTheDaysHRVWindowsSeeThePreviousDaysLastMinutesOfEvents() {
        let dayStart = t0 + 86_400
        let previous = [
            ActivityTransitionEvent(kind: .walkStop, probability: 0.9, ts: dayStart - 3_600),
            ActivityTransitionEvent(kind: .sitToStandLike, probability: 0.7, ts: dayStart - 90),
            ActivityTransitionEvent(kind: .walkStop, probability: 0.9, ts: dayStart - 30),
        ]
        let own = [ActivityTransitionEvent(kind: .standToSitLike, probability: 0.6, ts: dayStart + 400)]
        let merged = ActivityContextPersistence.hrvEvents(day: own, previous: previous, dayStart: dayStart)
        XCTAssertGreaterThanOrEqual(ActivityContextPersistence.hrvEventLookbackS, 120)
        XCTAssertEqual(merged.map(\.ts), [dayStart - 90, dayStart - 30, dayStart + 400],
                       "the tail inside the lookback, then the day's own")
        XCTAssertEqual(ActivityContextPersistence.hrvEvents(day: own, previous: [], dayStart: dayStart), own)
        // The day's first window: a walk ended 30 s before midnight, so it is still recovering, not steady.
        let beats = stride(from: dayStart - 600, to: dayStart + 600, by: 1).map { RRInterval(ts: $0, rrMs: 1_000 + ($0 % 2) * 40) }
        let first = HRVWindowBuilder.build(kind: .canonical5m, dayStart: dayStart, dayEnd: dayStart + 300, rr: beats,
                                           transitionEvents: merged).first
        let blind = HRVWindowBuilder.build(kind: .canonical5m, dayStart: dayStart, dayEnd: dayStart + 300, rr: beats,
                                           transitionEvents: own).first
        XCTAssertEqual(first?.secondsSinceTransition, 30)
        XCTAssertNotEqual(first?.phase, .steadyState, "30 s after the walk ended is still recovery")
        XCTAssertNil(blind?.secondsSinceTransition, "without the tail the window cannot see what came just before it")
        XCTAssertEqual(blind?.phase, .steadyState)
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

    func testADecodedDayRoundTripsThroughTheStoreAndTheLookupAgrees() async throws {
        var sim = ActivitySim(start: t0)
        sim.desk(600); sim.walk(180); sim.desk(600); sim.run(120); sim.still(300)
        let input = sim.trackInput()
        let track = ActivityContextTrackBuilder.build(input)
        let document = ActivityContextDayDocument(track: track, input: input, generatedAt: t0 + 5_000)
        // Beat-to-beat data over the whole span (the sim has none), so still rows carry RMSSD and settled RMSSD.
        let beats = stride(from: t0, to: t0 + 1_900, by: 1).map { RRInterval(ts: $0, rrMs: 900 + ($0 % 3) * 30) }
        let intervals = ActivityContextIntervalBuilder.build(document: document, hr: input.hr, steps: input.steps, rr: beats)
        XCTAssertFalse(intervals.isEmpty)
        // Every context field is set somewhere on the day, so the comparison below exercises each column.
        XCTAssertTrue(intervals.allSatisfy { $0.transitionCount != nil && $0.uncertainty != nil && $0.settlingSeconds != nil
            && $0.inBed != nil && $0.experts != nil && $0.absorbedClasses != nil && $0.absorbedSeconds != nil })
        XCTAssertTrue(intervals.contains { $0.precedingClass != nil })
        XCTAssertTrue(intervals.contains { $0.settledFrom != nil && $0.hrMeanSettled != nil && $0.rmssdSettled != nil },
                      "a desk stretch after the walk has settled statistics")
        XCTAssertTrue(intervals.contains { ($0.settlingSeconds ?? 0) > 0 })

        let store = try await WhoopStore.inMemory()
        let ledger = ActivityContextPersistence.dayRow(day: "2025-10-09", document: document,
                                                      intervalCount: intervals.count, computedAt: t0 + 6_000)
        let transitions = ActivityContextPersistence.transitionRows(document.events, from: document.dayStart,
                                                                     to: document.dayEnd, decoderVersion: document.versions.decoder)
        try await store.replaceActivityContext(deviceId: dev, day: ledger, intervals: intervals.map(\.storeRow),
                                               transitions: transitions)

        // Every context field the builder produced reads back identical: nothing is defaulted on the way.
        let rows = try await store.activityContextIntervals(deviceId: dev, from: document.dayStart, to: document.dayEnd)
        XCTAssertEqual(rows.map(ActivityContextInterval.init(row:)), intervals)
        let events = try await store.activityContextTransitions(deviceId: dev, from: document.dayStart, to: document.dayEnd)
        XCTAssertFalse(events.isEmpty, "the walk and the run start and stop")
        XCTAssertEqual(events, transitions)
        XCTAssertTrue(events.allSatisfy { $0.source != nil }, "every event says what flagged it")
        XCTAssertTrue(events.contains { $0.onsetTs != nil })
        XCTAssertEqual(ActivityContextPersistence.events(events).count, events.count)

        let live = ActivityContextLookup(intervals: intervals)
        let storedLookup = ActivityContextLookup(rows: rows)
        for ts in stride(from: t0 - 30, to: t0 + 1_900, by: 7) {
            XCTAssertEqual(storedLookup.interval(at: ts), live.interval(at: ts), "t0+\(ts - t0)")
            let fromStore = try await store.activityContextInterval(deviceId: dev, at: ts)
            XCTAssertEqual(fromStore.map(ActivityContextInterval.init(row:)), live.interval(at: ts), "t0+\(ts - t0)")
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
            computedAt: t0, featureSchema: ActivityContextVersions.featureSchema, configTag: "r55m190")
        XCTAssertTrue(ActivityContextPersistence.isCurrent(current))
        XCTAssertTrue(ActivityContextPersistence.isCurrent(current, configTag: "r55m190"))
        XCTAssertFalse(ActivityContextPersistence.isCurrent(current, configTag: "r52m190"), "another decoder config")
        var older = current; older.featureSchema = nil
        XCTAssertFalse(ActivityContextPersistence.isCurrent(older), "derived before the ledger recorded its feature schema")
        older = current; older.featureSchema = "feat-0"
        XCTAssertFalse(ActivityContextPersistence.isCurrent(older))
        older = current; older.taxonomyVersion = "act-class-0"
        XCTAssertFalse(ActivityContextPersistence.isCurrent(older))
        older = current; older.decoderVersion = "hsmm-1.1"
        XCTAssertFalse(ActivityContextPersistence.isCurrent(older))
        older = current; older.ontologyVersion = "1.0"
        XCTAssertFalse(ActivityContextPersistence.isCurrent(older))
        older = current; older.intervalVersion = "ctx-int-0"
        XCTAssertFalse(ActivityContextPersistence.isCurrent(older))
    }

    func testTheLedgerCarriesTheDocumentsWholeProvenanceAndFinality() throws {
        var sim = ActivitySim(start: t0)
        sim.desk(120)
        let input = sim.trackInput()
        var document = ActivityContextDayDocument(track: ActivityContextTrackBuilder.build(input), input: input, generatedAt: t0 + 500)
        document.versions.encoderId = "hart"
        document.versions.encoderVersion = "hart-v1.2"
        document.versions.motionHeads = "inertia-1:abc:def"
        document.versions.gaitQuality = "eldernet:437a38b:01b2:ff"
        document.sleepKnownOutsideSessions = true
        let end = t0 + 86_400
        let early = ActivityContextPersistence.dayRow(day: "2025-10-09", document: document, intervalCount: 1,
                                                      computedAt: t0 + 500, dayEnd: end, configTag: "r55m190",
                                                      inputFingerprint: "fp", writtenAt: end + 60)
        XCTAssertEqual(early.featureSchema, document.versions.featureSchema)
        XCTAssertEqual(early.encoderId, "hart")
        XCTAssertEqual(early.encoderVersion, "hart-v1.2")
        XCTAssertEqual(early.motionHeads, "inertia-1:abc:def")
        XCTAssertEqual(early.gaitQuality, "eldernet:437a38b:01b2:ff")
        XCTAssertEqual(early.configTag, "r55m190")
        XCTAssertEqual(early.inputFingerprint, "fp")
        XCTAssertEqual(early.decodeMode, "causal")
        XCTAssertEqual(early.sleepKnownOutsideSessions, true)
        XCTAssertEqual(early.finality, "provisional", "the night running into the next morning is not staged yet")
        let settled = ActivityContextPersistence.dayRow(day: "2025-10-09", document: document, intervalCount: 1,
                                                        computedAt: t0 + 500, dayEnd: end,
                                                        writtenAt: end + ActivityContextPersistence.sleepSettleS)
        XCTAssertEqual(settled.finality, "final")
        document.sleepKnownOutsideSessions = false
        let live = ActivityContextPersistence.dayRow(day: "2025-10-09", document: document, intervalCount: 1,
                                                     computedAt: t0 + 500, dayEnd: end, writtenAt: end + 86_400)
        XCTAssertEqual(live.finality, "provisional", "a day decoded live read time outside sleep as unknown")
    }

    func testTransitionEventsBecomeRowsForTheirDayOnly() {
        let events = [
            ActivityTransitionEvent(kind: .sitToStandLike, probability: 0.6, ts: t0 + 10),
            ActivityTransitionEvent(kind: .sitToStandLike, probability: 0.9, ts: t0 + 10),
            ActivityTransitionEvent(kind: .standToSitLike, probability: 0.7, ts: t0 + 20),
            ActivityTransitionEvent(kind: .walkStart, probability: 0.8, ts: t0 - 1),
            ActivityTransitionEvent(kind: .walkStop, probability: 0.8, ts: t0 + 100),
        ]
        let rows = ActivityContextPersistence.transitionRows(events, from: t0, to: t0 + 100, decoderVersion: "hsmm-x")
        XCTAssertEqual(rows, [
            ActivityContextTransitionRow(ts: t0 + 10, kind: "sit_to_stand_like", probability: 0.9, decoderVersion: "hsmm-x"),
            ActivityContextTransitionRow(ts: t0 + 20, kind: "stand_to_sit_like", probability: 0.7, decoderVersion: "hsmm-x"),
        ])
    }

    func testServingStatusSeparatesStaleLabelsFromAnOldDerivationKey() {
        let current = ActivityContextDayRow(
            day: "2025-10-09", dayStart: t0, dayEnd: t0 + 86_400,
            taxonomyVersion: ActivityClassVersions.taxonomy, decoderVersion: ActivityContextVersions.decoder,
            ontologyVersion: ActivityContextVersions.ontology, intervalVersion: ActivityClassVersions.interval,
            computedAt: t0, featureSchema: ActivityContextVersions.featureSchema, configTag: "r55")
        XCTAssertEqual(ActivityContextPersistence.servingStatus(current, configTag: "r55"), .current)
        XCTAssertEqual(ActivityContextPersistence.servingStatus(current, configTag: "r52"), .refreshing)
        var legacy = current; legacy.featureSchema = nil
        XCTAssertEqual(ActivityContextPersistence.servingStatus(legacy), .refreshing)
        var old = current; old.decoderVersion = "hsmm-0.1"
        XCTAssertEqual(ActivityContextPersistence.servingStatus(old), .stale)
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
