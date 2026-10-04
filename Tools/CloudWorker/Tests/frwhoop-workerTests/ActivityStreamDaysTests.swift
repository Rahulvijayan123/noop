import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// Stream days without a database: which stored streams count as "something to describe", what the
/// document built from them looks like, the properties a downstream join on a measurement timestamp
/// relies on (runs partition the observed time, exact in-day seconds, confidence in range), and how a
/// claimed row is read. The SQL side is `supabase/functions/tests/activity_context_contract.sql`
/// section 13; the two together are `ActivityStreamDaysDatabaseTests`.
final class ActivityStreamDaysTests: XCTestCase {

    // 2026-09-15 00:00:00 UTC.
    private let dayStart = 1_789_430_400
    private var dayEnd: Int { dayStart + 86_400 }
    private let day = "2026-09-15"

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func build(_ streams: ActivityContextDays.Streams,
                       sleep: [(start: Int, end: Int)] = [], now: Int? = nil) throws -> ActivityContextDays.Built? {
        try ActivityContextDays.buildStreamDay(
            day: day, dayBounds: (dayStart, dayEnd), streams: streams, sleep: sleep, exercise: [],
            now: now ?? dayEnd + 3_600)
    }

    private func runs(_ built: ActivityContextDays.Built) throws -> [[String: Any]] {
        let doc = try XCTUnwrap(try object(built.payloadText)["document"] as? [String: Any])
        return try XCTUnwrap(doc["runs"] as? [[String: Any]])
    }

    /// Sitting, a walk, sitting again, in the middle of the day.
    private func sittingWalkingSitting() -> DaySim {
        var sim = DaySim(start: dayStart + 36_000)
        sim.still(240)
        sim.walk(150)
        sim.still(240)
        return sim
    }

    // MARK: - What counts as something to describe

    func testWearEventsAloneDescribeNothing() throws {
        var streams = ActivityContextDays.Streams()
        streams.events = [WhoopEvent(ts: dayStart + 100, kind: "WRIST_OFF(10)", payload: [:])]
        XCTAssertTrue(streams.isEmpty)
        XCTAssertNil(try build(streams))
    }

    func testAnyOneMeasurementStreamMakesTheDayWorthDescribing() {
        XCTAssertTrue(ActivityContextDays.Streams().isEmpty)
        XCTAssertFalse(ActivityContextDays.Streams(hr: [HRSample(ts: dayStart + 5, bpm: 60)]).isEmpty)
        XCTAssertFalse(ActivityContextDays.Streams(
            gravity: [GravitySample(ts: dayStart + 5, x: 0, y: 0, z: 1, dynAccel: 0)]).isEmpty)
        XCTAssertFalse(ActivityContextDays.Streams(
            steps: [StepSample(ts: dayStart + 5, counter: 1, activityClass: 0)]).isEmpty)
    }

    func testADayWithNoMeasurementsBuildsNoDocument() throws {
        XCTAssertNil(try build(ActivityContextDays.Streams()))
    }

    // MARK: - The document

    func testTheDocumentIsStampedAsAStreamLineageWithNoEncoder() throws {
        let built = try XCTUnwrap(try build(sittingWalkingSitting().streams))
        let payload = try object(built.payloadText)
        XCTAssertEqual(payload["day"] as? String, day)
        XCTAssertEqual(payload["model_version"] as? String, ActivityContextDays.streamsModelVersion)
        XCTAssertEqual(payload["preprocessing_version"] as? String, ActivityContextDays.streamsPreprocessingVersion)
        let doc = try XCTUnwrap(payload["document"] as? [String: Any])
        XCTAssertEqual(doc["schema_version"] as? Int, ActivityContextVersions.schema)
        XCTAssertEqual(doc["day_start"] as? Int, dayStart)
        XCTAssertEqual(doc["day_end"] as? Int, dayEnd)
        XCTAssertNil(doc["snapshot"])
        let versions = try XCTUnwrap(doc["versions"] as? [String: Any])
        XCTAssertEqual(versions["decoder"] as? String, ActivityContextVersions.decoder)
        XCTAssertEqual(versions["ontology"] as? String, ActivityContextVersions.ontology)
        XCTAssertNil(versions["encoder"] as? String, "no model ran, so none is claimed in the provenance")
        let latest = try XCTUnwrap(doc["latest"] as? [String: Any])
        let evidence = try XCTUnwrap(latest["evidence"] as? [String: Any])
        XCTAssertEqual(evidence["encoder"] as? Bool, false)
        XCTAssertEqual(evidence["hr"] as? Bool, true)
        XCTAssertEqual(ActivityContextDays.streamsAlgorithmVersion, "streams-activity-1")
    }

    func testTheWalkIsRecognisedFromTheStoredStreamsAlone() throws {
        let sim = sittingWalkingSitting()
        let built = try XCTUnwrap(try build(sim.streams))
        let labels = try runs(built).compactMap { $0["display_context"] as? String }
        XCTAssertTrue(labels.contains { $0 == "Walking" || $0 == "Brisk walking" }, "\(labels)")
        XCTAssertGreaterThan(built.observedSeconds, 0)
    }

    // MARK: - What a downstream join relies on

    func testRunsAreSortedExactAndNeverOverlap() throws {
        var sim = sittingWalkingSitting()
        sim.gap(300)
        sim.still(120)
        sim.walk(60)
        let built = try XCTUnwrap(try build(sim.streams))
        let all = try runs(built)
        XCTAssertGreaterThan(all.count, 1)
        var previousEnd = dayStart
        for run in all {
            let s = try XCTUnwrap(run["s"] as? Int), e = try XCTUnwrap(run["e"] as? Int)
            XCTAssertGreaterThanOrEqual(s, previousEnd, "runs must not overlap: \(run)")
            XCTAssertGreaterThan(e, s)
            XCTAssertLessThanOrEqual(e, dayEnd)
            previousEnd = e
            let confidence = try XCTUnwrap(run["overall_confidence"] as? Double)
            let uncertainty = try XCTUnwrap(run["overall_uncertainty"] as? Double)
            XCTAssertTrue((0...1).contains(confidence), "confidence \(confidence)")
            XCTAssertTrue((0...1).contains(uncertainty), "uncertainty \(uncertainty)")
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(run["n"] as? Int), 1)
        }
    }

    func testAMeasurementTakenWhileTheStrapWasOnLandsInExactlyOneRun() throws {
        let sim = sittingWalkingSitting()
        let built = try XCTUnwrap(try build(sim.streams))
        let spans = try runs(built).map { (try XCTUnwrap($0["s"] as? Int), try XCTUnwrap($0["e"] as? Int)) }
        var unlabelled = 0
        for sample in sim.hr {
            let hits = spans.filter { $0.0 <= sample.ts && sample.ts < $0.1 }.count
            XCTAssertLessThanOrEqual(hits, 1, "second \(sample.ts) sits in two runs")
            if hits == 0 { unlabelled += 1 }
        }
        // The decoder needs a few seconds of evidence before it publishes the first state.
        XCTAssertLessThanOrEqual(Double(unlabelled) / Double(sim.hr.count), 0.05,
                                 "\(unlabelled) of \(sim.hr.count) measurements have no state")
    }

    func testTheWalkingSecondsAreLabelledWalking() throws {
        var sim = DaySim(start: dayStart + 36_000)
        sim.still(240)
        let walkStart = sim.ts
        sim.walk(150)
        sim.still(240)
        let built = try XCTUnwrap(try build(sim.streams))
        let all = try runs(built)
        func label(at ts: Int) -> String? {
            all.first { ($0["s"] as? Int ?? .max) <= ts && ts < ($0["e"] as? Int ?? .min) }?["display_context"] as? String
        }
        let midWalk = walkStart + 75
        XCTAssertTrue(["Walking", "Brisk walking"].contains(label(at: midWalk) ?? "-"),
                      "second \(midWalk - walkStart) of the walk was \(label(at: midWalk) ?? "unlabelled")")
        let earlySitting = dayStart + 36_000 + 120
        XCTAssertFalse(["Walking", "Brisk walking", "Running"].contains(label(at: earlySitting) ?? "-"),
                       "the opening sitting must not be called walking")
    }

    func testTheRunThatReachesMidnightIsClippedToTheDay() throws {
        var sim = DaySim(start: dayEnd - 240)
        sim.still(240)
        let built = try XCTUnwrap(try build(sim.streams))
        let last = try XCTUnwrap(try runs(built).last)
        XCTAssertLessThanOrEqual(try XCTUnwrap(last["e"] as? Int), dayEnd)
    }

    // MARK: - Sleep and the live day

    func testTimeOutsideLoggedSleepIsOnlyAwakeOnceTheDayHadTimeToBeScored() throws {
        let streams = sittingWalkingSitting().streams
        func known(at now: Int) throws -> Bool? {
            let doc = try XCTUnwrap(try object(try XCTUnwrap(try build(streams, now: now)).payloadText)["document"]
                                    as? [String: Any])
            return doc["sleep_known_outside"] as? Bool
        }
        XCTAssertEqual(try known(at: dayEnd - 3_600), false, "a day still in progress")
        XCTAssertEqual(try known(at: dayEnd + ActivityContextDays.streamsSleepSettleSeconds - 1), false)
        XCTAssertEqual(try known(at: dayEnd + ActivityContextDays.streamsSleepSettleSeconds), true)
    }

    func testAnOpenWristOffSpanOnTheLiveDayStopsAtNow() throws {
        var sim = DaySim(start: dayStart + 36_000)
        sim.still(300)
        var streams = sim.streams
        let offAt = dayStart + 36_000 + 200
        streams.events = [WhoopEvent(ts: offAt, kind: "WRIST_OFF(10)", payload: [:])]
        let now = dayStart + 36_000 + 600
        let built = try XCTUnwrap(try build(streams, now: now))
        let off = try runs(built).filter { ($0["display_context"] as? String) == "Off wrist" }
        XCTAssertFalse(off.isEmpty, "the strap came off at \(offAt)")
        for run in off {
            XCTAssertLessThanOrEqual(try XCTUnwrap(run["e"] as? Int), now + 10,
                                     "an off-wrist span that has not ended must not describe the future")
        }
    }

    func testLoggedSleepIsCarriedIntoTheDocument() throws {
        var sim = DaySim(start: dayStart + 3_600)
        sim.still(600)
        let sleep = [(start: dayStart + 3_500, end: dayStart + 4_300)]
        let built = try XCTUnwrap(try build(sim.streams, sleep: sleep))
        let sleeps = try runs(built).compactMap { $0["sleep"] as? String }
        XCTAssertTrue(sleeps.contains("asleep"), "\(sleeps)")
    }

    // MARK: - Claimed rows

    private func streamRow(_ overrides: [String: String] = [:]) -> [String: String] {
        var row: [String: String] = [
            "user_id": "11111111-1111-4111-8111-111111111111",
            "device_id": "22222222-2222-4222-8222-222222222222",
            "day": "2026-09-15", "algorithm_version": "streams-activity-1",
            "input_object_ids": "{}", "input_digests": "{}",
            "fingerprint": String(repeating: "a", count: 64), "input_revision": "3",
            "lease_token": "33333333-3333-4333-8333-333333333333",
        ]
        for (k, v) in overrides { row[k] = v }
        return row
    }

    func testAClaimedStreamRowNeedsNoInputObjects() throws {
        let job = try XCTUnwrap(ActivityLane.parseStreamJob(streamRow()))
        XCTAssertEqual(job.day, "2026-09-15")
        XCTAssertEqual(job.inputRevision, 3)
        XCTAssertEqual(job.algorithmVersion, ActivityContextDays.streamsAlgorithmVersion)
        XCTAssertTrue(job.objectIds.isEmpty && job.digests.isEmpty)
        XCTAssertEqual(job.leaseToken, "33333333-3333-4333-8333-333333333333")
    }

    func testAStreamRowIsNotAnImuJobAndAnImuRowIsNotAStreamJob() {
        XCTAssertNil(ActivityLane.parseJob(streamRow()), "the raw-IMU path needs input objects")
        var imu = streamRow(["algorithm_version": "hart-activity-1"])
        imu["input_object_ids"] = "{d0000000-0000-4000-8000-0000000000d1}"
        imu["input_digests"] = "{\(String(repeating: "a", count: 64))}"
        XCTAssertNotNil(ActivityLane.parseJob(imu))
        XCTAssertNil(ActivityLane.parseStreamJob(imu), "a raw-IMU row must never be processed as a stream day")
    }

    func testAMalformedStreamRowIsRefused() {
        XCTAssertNil(ActivityLane.parseStreamJob(streamRow(["lease_token": ""])))
        XCTAssertNil(ActivityLane.parseStreamJob(streamRow(["input_revision": "0"])))
        XCTAssertNil(ActivityLane.parseStreamJob(streamRow(["input_revision": "x"])))
        XCTAssertNil(ActivityLane.parseStreamJob(streamRow(["day": ""])))
        XCTAssertNil(ActivityLane.parseStreamJob(streamRow(["user_id": ""])))
        XCTAssertNil(ActivityLane.parseStreamJob(streamRow(["algorithm_version": ""])))
    }

    // MARK: - The calls the lane makes

    func testTheLaneCallsUseBareIntervalLiteralsPostgresCanParse() {
        // Bound as text and cast server-side: a quoted `'7 days'::interval` is not an interval literal
        // (it made every reconcile call fail silently before this was pinned).
        for literal in [ActivityLane.reconcileLookback, ActivityLane.streamLookback, ActivityLane.streamMinRebuildInterval] {
            XCTAssertFalse(literal.contains("'") || literal.contains(":"), literal)
            XCTAssertNotNil(literal.split(separator: " ").first.flatMap { Int($0) }, literal)
        }
        XCTAssertTrue(ActivityLane.streamEnqueueSQL.contains("$3::interval"))
        XCTAssertFalse(ActivityLane.streamEnqueueSQL.contains("$4"))
        XCTAssertTrue(ActivityLane.reconcileSQL.contains("$1::interval"))
    }
}
