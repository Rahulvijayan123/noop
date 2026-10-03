import XCTest
@testable import frwhoop_worker
import StrandAnalytics

/// Pure tests for the worker's C10 `daily.activity_context` document path
/// through the SHARED StrandAnalytics policy: lane window/session mapping ->
/// `ActivityContextPolicy.buildEpochs` (one fold per day) -> daySummary /
/// snapshotStatus / ActivityContextJoin contexts -> `ActivityContextDocument`
/// JSON (C10 exact keys) + day stamping. Also covers the scoring-lane
/// stored-row rebuild path (`ActivityLane.activityDocument(epochs:)`).
///
/// The shared policy's own behavior (hysteresis, exertion, abstention
/// details) is pinned by the StrandAnalytics test suite; these tests pin the
/// worker glue: the C10 JSON contract, grid uniqueness across run gaps, no
/// fill, day-boundary clipping, session mapping, and the day key.
final class ActivityLaneDocumentTests: XCTestCase {

    // 2026-09-15 00:00:00 UTC — a UTC midnight, so the absolute 30-s grid and
    // the 900-s HRV slots align with [dayStart, dayEnd).
    private let dayStart = 1_789_430_400

    // MARK: - Fixtures

    private func stationaryProbs() -> [String: Double] {
        ["stationary": 0.9, "walking": 0.05, "running": 0.03,
         "other_movement": 0.02, "unknown": 0.0]
    }

    private func walkingProbs() -> [String: Double] {
        ["walking": 0.85, "stationary": 0.1, "running": 0.03,
         "other_movement": 0.02, "unknown": 0.0]
    }

    /// 4-s windows, 2-s hop covering [start, end), as the Python service emits
    /// (C10 serve protocol: windows fully inside the run, `start`/`end` are
    /// Double seconds).
    private func serviceWindows(label: String, probs: [String: Double],
                                start: Int, end: Int) -> [ActivityPythonService.WindowPrediction] {
        var out: [ActivityPythonService.WindowPrediction] = []
        var t = start
        while t + 4 <= end {
            out.append(ActivityPythonService.WindowPrediction(
                start: Double(t), end: Double(t + 4), label: label, probs: probs, baseline: false))
            t += 2
        }
        return out
    }

    private func makeDocument(windows: [ActivityPythonService.WindowPrediction],
                              sleep: [(start: Int, end: Int)] = [],
                              exercise: [(start: Int, end: Int)] = [],
                              dayEnd: Int? = nil,
                              inputRevision: Int64 = 7) throws -> [String: Any] {
        try ActivityLane.activityDocument(
            windows: windows,
            sleepIntervals: sleep, exerciseIntervals: exercise,
            dayStart: dayStart, dayEnd: dayEnd ?? dayStart + 86_400,
            inputRevision: inputRevision,
            modelVersion: "hart-activity-1",
            preprocessingVersion: "activity-preprocess-1",
            dataThrough: dayStart + 60)
    }

    // MARK: - C10 document from lane windows

    func testStationaryDayProducesExactC10Document() throws {
        let windows = serviceWindows(label: "stationary", probs: stationaryProbs(),
                                     start: dayStart, end: dayStart + 60)
        let doc = try makeDocument(windows: windows, dayEnd: dayStart + 60)
        XCTAssertEqual(doc["schema_version"] as? Int, 1)
        XCTAssertEqual(doc["ontology_version"] as? String, "v1")
        XCTAssertEqual(doc["model_version"] as? String, "hart-activity-1")
        XCTAssertEqual(doc["preprocessing_version"] as? String, "activity-preprocess-1")
        XCTAssertEqual(doc["input_revision"] as? Int, 7)
        XCTAssertEqual(doc["data_through"] as? String, "2026-09-15T00:01:00Z")
        XCTAssertEqual(doc["status"] as? String, "available")
        XCTAssertEqual(doc["reasons"] as? [String], [])

        let epochs = try XCTUnwrap(doc["epochs"] as? [[String: Any]])
        XCTAssertEqual(epochs.count, 2)
        // Exact C10 epoch keys: s,e,m,p,ex,sl,ec,w,c,os,vs.
        let epochKeys = Set(epochs[0].keys)
        XCTAssertEqual(epochKeys,
                       ["s", "e", "m", "p", "ex", "sl", "ec", "w", "c", "os", "vs"])
        XCTAssertEqual(epochs[0]["s"] as? Int, dayStart)
        XCTAssertEqual(epochs[0]["e"] as? Int, dayStart + 30)
        XCTAssertEqual(epochs[0]["m"] as? String, "stationary")
        XCTAssertEqual(epochs[0]["p"] as? String, "unknown")
        XCTAssertEqual(epochs[0]["ex"] as? String, "unknown")
        XCTAssertEqual(epochs[0]["sl"] as? String, "unknown")
        XCTAssertEqual(epochs[0]["w"] as? String, "unknown")
        XCTAssertEqual(epochs[0]["c"] as? Double ?? 0, 0.9, accuracy: 1e-9)
        // Union coverage: 29 windows x 4 s would be 116 s if double counted;
        // the epoch must report 30.
        XCTAssertEqual(epochs[0]["os"] as? Int, 30)
        XCTAssertEqual(epochs[0]["vs"] as? Int, 30)
        XCTAssertEqual(epochs[1]["os"] as? Int, 30)

        let summary = try XCTUnwrap(doc["summary"] as? [String: Any])
        XCTAssertEqual(summary["supported_s"] as? Int, 60)
        XCTAssertEqual(summary["unknown_share"] as? Double ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(summary["transitions"] as? Int, 0)

        let contexts = try XCTUnwrap(doc["contexts"] as? [String: Any])
        XCTAssertEqual(Set(contexts.keys), ["hrv_slots", "sleep_sessions"])
        // One 15-min slot covers [dayStart, dayStart+60).
        let slots = try XCTUnwrap(contexts["hrv_slots"] as? [[String: Any]])
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots[0]["slot_s"] as? Int, dayStart)
        XCTAssertEqual((slots[0]["shares"] as? [String: Any])?["stationary"] as? Double ?? 0,
                       1.0, accuracy: 1e-9)
        XCTAssertEqual(slots[0]["post_activity"] as? Bool, false)
        XCTAssertEqual((contexts["sleep_sessions"] as? [[String: Any]])?.isEmpty, true)
    }

    func testDayKeyStampedAndJSONKeysSorted() throws {
        let windows = serviceWindows(label: "stationary", probs: stationaryProbs(),
                                     start: dayStart, end: dayStart + 60)
        var doc = try makeDocument(windows: windows, dayEnd: dayStart + 60)
        let json = try ActivityLane.dayStampedJSONText(doc: &doc, day: "2026-09-15")
        let parsed = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(json.utf8)))
            as? [String: Any])
        // The publish RPC validates `p_payload ->> 'day'` against the job day,
        // so the document must carry the day key at the top level.
        XCTAssertEqual(parsed["day"] as? String, "2026-09-15")
        XCTAssertEqual(parsed["schema_version"] as? Int, 1)
        // .sortedKeys: top-level keys are emitted in lexical order.
        let topKeys = ["contexts", "data_through", "day", "epochs", "input_revision",
                       "model_version", "ontology_version", "preprocessing_version",
                       "reasons", "schema_version", "status", "summary"]
        var previous: String.Index?
        for key in topKeys {
            let range = try XCTUnwrap(json.range(of: "\"\(key)\":"))
            if let prev = previous { XCTAssertLessThan(prev, range.lowerBound) }
            previous = range.lowerBound
        }
    }

    func testGapLeavesEpochAbsentAndNeverFills() throws {
        // Windows only cover the first 20 s of the day -> a single partial
        // epoch; the rest of the grid is absent (never zero-filled).
        let windows = serviceWindows(label: "stationary", probs: stationaryProbs(),
                                     start: dayStart, end: dayStart + 20)
        let doc = try makeDocument(windows: windows, dayEnd: dayStart + 60)
        let epochs = try XCTUnwrap(doc["epochs"] as? [[String: Any]])
        XCTAssertEqual(epochs.count, 1)
        XCTAssertEqual(epochs[0]["s"] as? Int, dayStart)
        XCTAssertEqual(epochs[0]["os"] as? Int, 20)
        XCTAssertFalse(epochs.contains { ($0["s"] as? Int) == dayStart + 30 })
    }

    func testNoWindowsIsNoData() throws {
        let doc = try makeDocument(windows: [])
        XCTAssertEqual(doc["status"] as? String, "no_data")
        XCTAssertEqual(doc["reasons"] as? [String], ["no_epochs"])
        XCTAssertEqual((doc["epochs"] as? [[String: Any]])?.isEmpty, true)
        let contexts = try XCTUnwrap(doc["contexts"] as? [String: Any])
        XCTAssertEqual((contexts["hrv_slots"] as? [[String: Any]])?.isEmpty, true)
        XCTAssertEqual((contexts["sleep_sessions"] as? [[String: Any]])?.isEmpty, true)
    }

    func testAbstentionThresholdsMarkUnknownButRetainObservedCoverage() throws {
        // Max prob 0.7 < 0.80 -> every window abstains: the epoch motion is
        // unknown, validS is 0, but observed coverage is retained.
        var weak = stationaryProbs()
        weak["stationary"] = 0.7
        weak["walking"] = 0.2
        let doc = try makeDocument(
            windows: serviceWindows(label: "stationary", probs: weak,
                                    start: dayStart, end: dayStart + 60),
            dayEnd: dayStart + 60)
        let epochs = try XCTUnwrap(doc["epochs"] as? [[String: Any]])
        XCTAssertEqual(epochs[0]["m"] as? String, "unknown")
        XCTAssertEqual(epochs[0]["vs"] as? Int, 0)
        XCTAssertEqual(epochs[0]["os"] as? Int, 30, "observed coverage is retained even when abstaining")
    }

    // MARK: - Run gap / grid uniqueness (single fold per day)

    func testRunGapInsideBucketKeepsGridUnique() throws {
        // Two runs separated by a 1-s data gap (second dayStart+32 missing)
        // whose windows BOTH fall in the 30-s bucket [dayStart+30, +60). A
        // per-run fold would emit TWO epochs with s == dayStart+30 — breaking
        // the C10 grid AND the activity_context_epochs PK
        // (user_id, device_id, start_ts, fingerprint) that
        // publish_activity_context_v2 inserts into. The single fold must emit
        // exactly one epoch per bucket with the gap second excluded.
        let runA = serviceWindows(label: "walking", probs: walkingProbs(),
                                  start: dayStart, end: dayStart + 32)
        let runB = serviceWindows(label: "stationary", probs: stationaryProbs(),
                                  start: dayStart + 33, end: dayStart + 59)
        let doc = try makeDocument(windows: runA + runB, dayEnd: dayStart + 60)
        let epochs = try XCTUnwrap(doc["epochs"] as? [[String: Any]])
        let starts = epochs.compactMap { $0["s"] as? Int }
        XCTAssertEqual(starts.filter { $0 == dayStart }.count, 1)
        XCTAssertEqual(starts.filter { $0 == dayStart + 30 }.count, 1,
                       "one epoch per 30-s bucket even across a run gap")
        let bucket = try XCTUnwrap(epochs.first { ($0["s"] as? Int) == dayStart + 30 })
        // Bucket seconds: run A 30,31 + run B 33..58 = 28 s; the missing
        // second 32 is never counted.
        XCTAssertEqual(bucket["os"] as? Int, 28)
        XCTAssertEqual(bucket["m"] as? String, "stationary")
    }

    func testLargeGapResetsHysteresis() throws {
        // Run A walking [dayStart, +30), then a >4-s window gap, then run B
        // stationary [dayStart+35, +49). The policy's gap-split
        // (gapResetSeconds = 4) starts a fresh hysteresis segment, so run B
        // establishes stationary immediately instead of inheriting walking.
        let runA = serviceWindows(label: "walking", probs: walkingProbs(),
                                  start: dayStart, end: dayStart + 30)
        let runB = serviceWindows(label: "stationary", probs: stationaryProbs(),
                                  start: dayStart + 35, end: dayStart + 49)
        let doc = try makeDocument(windows: runA + runB, dayEnd: dayStart + 60)
        let epochs = try XCTUnwrap(doc["epochs"] as? [[String: Any]])
        XCTAssertEqual(epochs.count, 2)
        XCTAssertEqual(epochs[0]["m"] as? String, "walking")
        let second = try XCTUnwrap(epochs.first { ($0["s"] as? Int) == dayStart + 30 })
        XCTAssertEqual(second["m"] as? String, "stationary")
        XCTAssertEqual(second["os"] as? Int, 14)
    }

    // MARK: - Session mapping (shared SleepSession / ExerciseSession)

    func testSleepAndExerciseTaggingViaSharedMapping() throws {
        let sleep = [(start: dayStart, end: dayStart + 30)]
        let exercise = [(start: dayStart + 10, end: dayStart + 20)]
        let doc = try makeDocument(
            windows: serviceWindows(label: "stationary", probs: stationaryProbs(),
                                    start: dayStart, end: dayStart + 60),
            sleep: sleep, exercise: exercise, dayEnd: dayStart + 60)
        let epochs = try XCTUnwrap(doc["epochs"] as? [[String: Any]])
        // Epoch 1 overlaps the sleep span -> asleep; overlaps the workout -> true.
        XCTAssertEqual(epochs[0]["sl"] as? String, "asleep")
        XCTAssertEqual(epochs[0]["ex"] as? String, "true")
        // Shared policy: no sleep evidence -> unknown (stillness alone never
        // sets sleep), and no workout overlap -> unknown (absence != false).
        XCTAssertEqual(epochs[1]["sl"] as? String, "unknown")
        XCTAssertEqual(epochs[1]["ex"] as? String, "unknown")
        // contexts.sleep_sessions carries the sleep session with shares.
        let contexts = try XCTUnwrap(doc["contexts"] as? [String: Any])
        let sessions = try XCTUnwrap(contexts["sleep_sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0]["start"] as? Int, dayStart)
        XCTAssertEqual((sessions[0]["shares"] as? [String: Any])?["stationary"] as? Double ?? 0,
                       1.0, accuracy: 1e-9)
    }

    func testSessionMappersConstructMinimalSharedTypes() {
        let sleep = ActivityLane.sleepSession(from: (start: dayStart, end: dayStart + 3600))
        XCTAssertEqual(sleep.start, dayStart)
        XCTAssertEqual(sleep.end, dayStart + 3600)
        XCTAssertTrue(sleep.stages.isEmpty)
        XCTAssertNil(sleep.restingHR)
        XCTAssertNil(sleep.avgHRV)

        let workout = ActivityLane.exerciseSession(from: (start: dayStart, end: dayStart + 1800))
        XCTAssertEqual(workout.start, dayStart)
        XCTAssertEqual(workout.end, dayStart + 1800)
        XCTAssertEqual(workout.durationS, 1800)
        XCTAssertNil(workout.strain)
    }

    // MARK: - Day-boundary clipping

    func testWindowsClippedToDayBoundary() throws {
        // A window straddling dayEnd is clipped to [dayEnd-2, dayEnd) and
        // contributes only inside the day; a window fully outside the day is
        // dropped. No epoch may fall beyond the job day (the publish RPC
        // validates `s >= day_lo AND e <= day_hi`).
        let dayEnd = dayStart + 60
        var windows = serviceWindows(label: "stationary", probs: stationaryProbs(),
                                     start: dayStart, end: dayStart + 58)
        windows.append(ActivityPythonService.WindowPrediction(
            start: Double(dayEnd - 2), end: Double(dayEnd + 2),
            label: "stationary", probs: stationaryProbs(), baseline: false))
        windows.append(ActivityPythonService.WindowPrediction(
            start: Double(dayEnd), end: Double(dayEnd + 4),
            label: "walking", probs: walkingProbs(), baseline: false))
        let doc = try makeDocument(windows: windows, dayEnd: dayEnd)
        let epochs = try XCTUnwrap(doc["epochs"] as? [[String: Any]])
        for e in epochs {
            XCTAssertGreaterThanOrEqual(e["s"] as? Int ?? 0, dayStart)
            XCTAssertLessThanOrEqual(e["e"] as? Int ?? dayEnd + 1, dayEnd)
        }
        // The clipped window adds seconds 58,59 to the final bucket (base
        // windows cover 30..57, the clipped one 58,59 -> a full 30).
        let last = try XCTUnwrap(epochs.first { ($0["s"] as? Int) == dayStart + 30 })
        XCTAssertEqual(last["os"] as? Int, 30)
    }

    // MARK: - Stored-row rebuild (scoring-lane attach path)

    func testStoredEpochRebuildMatchesLiveShape() throws {
        // What DayScoring.attachActivityContext builds from stored
        // activity_context_epochs rows: ActivityEpochs -> shared
        // summary/status/contexts.
        let epochs = [
            ActivityEpoch(startTs: dayStart, endTs: dayStart + 30, motion: .stationary,
                          posture: .unknown, exercise: .unknown, sleepState: .awake,
                          exertion: .unknown, wear: .unknown,
                          confidence: 0.91, observedS: 30, validS: 30),
            ActivityEpoch(startTs: dayStart + 30, endTs: dayStart + 60, motion: .walking,
                          posture: .unknown, exercise: .unknown, sleepState: .awake,
                          exertion: .unknown, wear: .unknown,
                          confidence: 0.85, observedS: 30, validS: 30),
        ]
        let asleep = [(start: dayStart - 3600, end: dayStart + 60 + 3600)]
        let doc = try ActivityLane.activityDocument(
            epochs: epochs, sleepIntervals: asleep,
            dayStart: dayStart, dayEnd: dayStart + 60,
            inputRevision: 7,
            modelVersion: "hart-activity-1",
            preprocessingVersion: "activity-preprocess-1",
            dataThrough: dayStart + 60,
            ontologyVersion: "v1")
        let outEpochs = try XCTUnwrap(doc["epochs"] as? [[String: Any]])
        XCTAssertEqual(outEpochs.count, 2)
        XCTAssertEqual(outEpochs[0]["m"] as? String, "stationary")
        XCTAssertEqual(outEpochs[1]["m"] as? String, "walking")
        let summary = try XCTUnwrap(doc["summary"] as? [String: Any])
        XCTAssertEqual(summary["supported_s"] as? Int, 60)
        XCTAssertEqual(summary["transitions"] as? Int, 1)
        XCTAssertEqual(doc["status"] as? String, "available")
        let contexts = try XCTUnwrap(doc["contexts"] as? [String: Any])
        let sessions = try XCTUnwrap(contexts["sleep_sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0]["start"] as? Int, dayStart)
    }

    // MARK: - Model version provenance (audit P1-3 / P3-6)

    /// The child's reported model/preprocessing versions must flow into the
    /// C10 document exactly; the baseline fallback (what serve reports when
    /// no HART manifest is configured) is stamped only when nothing was
    /// reported — never a hard-coded 'hart-activity-1'.
    func testReportedModelVersionFlowsIntoDocument() throws {
        let windows = serviceWindows(label: "stationary", probs: stationaryProbs(),
                                     start: dayStart, end: dayStart + 60)
        let versions = ActivityLane.resolvedVersions(
            reportedModel: "hart-activity-v1",
            reportedPreprocessing: "hart-activity-preprocess-v1")
        let doc = try ActivityLane.activityDocument(
            windows: windows,
            sleepIntervals: [], exerciseIntervals: [],
            dayStart: dayStart, dayEnd: dayStart + 60,
            inputRevision: 9,
            modelVersion: versions.model,
            preprocessingVersion: versions.preprocessing,
            dataThrough: dayStart + 60)
        XCTAssertEqual(doc["model_version"] as? String, "hart-activity-v1")
        XCTAssertEqual(doc["preprocessing_version"] as? String, "hart-activity-preprocess-v1")
    }

    // MARK: - hrv_slots restricted to published HRV points (audit P3-2)

    private func storedEpochs(_ from: Int, _ to: Int) -> [ActivityEpoch] {
        var out: [ActivityEpoch] = []
        var t = from
        while t < to {
            out.append(ActivityEpoch(
                startTs: t, endTs: min(t + 30, to),
                motion: .stationary, posture: .unknown, exercise: .unknown,
                sleepState: .awake, exertion: .unknown, wear: .unknown,
                confidence: 0.9, observedS: 30, validS: 30))
            t += 30
        }
        return out
    }

    /// The scoring attach path pins `contexts.hrv_slots` to exactly the slots
    /// that have a PUBLISHED HRV point. A slot with activity epochs but no HRV
    /// result must not be emitted (payload bloat; the app would have to
    /// cross-reference).
    func testHrvSlotsPinnedToPublishedHrvPoints() throws {
        // Two 15-min slots of activity, but only slot [dayStart, +900) has an
        // HRV point.
        let epochs = storedEpochs(dayStart, dayStart + 1_800)
        let doc = try ActivityLane.activityDocument(
            epochs: epochs, sleepIntervals: [],
            dayStart: dayStart, dayEnd: dayStart + 1_800,
            inputRevision: 7,
            modelVersion: "hart-activity-1",
            preprocessingVersion: "activity-preprocess-1",
            dataThrough: dayStart + 1_800,
            hrvSlots: [dayStart])
        let contexts = try XCTUnwrap(doc["contexts"] as? [String: Any])
        let slots = try XCTUnwrap(contexts["hrv_slots"] as? [[String: Any]])
        XCTAssertEqual(slots.count, 1, "only the slot with a published HRV point is emitted")
        XCTAssertEqual(slots[0]["slot_s"] as? Int, dayStart)
    }

    /// No published HRV points at all -> `contexts.hrv_slots` is empty, even
    /// though activity epochs cover the whole day (absent/empty, never
    /// activity-covered slots).
    func testHrvSlotsEmptyWhenNoPublishedHrvPoints() throws {
        let epochs = storedEpochs(dayStart, dayStart + 1_800)
        let doc = try ActivityLane.activityDocument(
            epochs: epochs, sleepIntervals: [],
            dayStart: dayStart, dayEnd: dayStart + 1_800,
            inputRevision: 7,
            modelVersion: "hart-activity-1",
            preprocessingVersion: "activity-preprocess-1",
            dataThrough: dayStart + 1_800,
            hrvSlots: [])
        let contexts = try XCTUnwrap(doc["contexts"] as? [String: Any])
        let slots = try XCTUnwrap(contexts["hrv_slots"] as? [[String: Any]])
        XCTAssertTrue(slots.isEmpty)
        // Default (lane path, no HRV knowledge) keeps the epoch-overlap
        // heuristic — every covered slot is still emitted.
        let defaultDoc = try ActivityLane.activityDocument(
            epochs: epochs, sleepIntervals: [],
            dayStart: dayStart, dayEnd: dayStart + 1_800,
            inputRevision: 7,
            modelVersion: "hart-activity-1",
            preprocessingVersion: "activity-preprocess-1",
            dataThrough: dayStart + 1_800)
        let defaultContexts = try XCTUnwrap(defaultDoc["contexts"] as? [String: Any])
        let defaultSlots = try XCTUnwrap(defaultContexts["hrv_slots"] as? [[String: Any]])
        XCTAssertEqual(defaultSlots.count, 2)
    }
}
