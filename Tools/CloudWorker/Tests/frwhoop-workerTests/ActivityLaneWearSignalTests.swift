import XCTest
@testable import frwhoop_worker
import StrandAnalytics
import WhoopProtocol

/// Wear-signal-quality wiring in the activity lane (feat/wear-signal-quality V1).
///
/// These tests pin the worker glue ONLY: how the day job's already-loaded inputs (WRIST events,
/// HR samples, IMU window features) become per-epoch `WearSignalEvidence`, how one
/// `WearSignalTemporalState` is threaded through a day in time order, and how the resulting
/// six-state `wsq` rides the C10 epoch JSON additively. The engine's own ladder behavior is pinned
/// by StrandAnalytics.WearSignalQualityTests; here we assert the server-side resolution: interval
/// semantics (no 45-s freshness), durable-off active until a sustained-HR run closes it, the
/// three-state `wear` (and its `wear_state` column/CHECK) untouched, and `ppgSqi` nil because the
/// activity lane does not load PPG waveform rows.
final class ActivityLaneWearSignalTests: XCTestCase {

    // 2026-09-15 00:00:00 UTC — a UTC midnight, same grid anchor as ActivityContextBuilderTests.
    private let dayStart = 1_789_430_400

    // MARK: - Fixtures

    private func stationaryProbs() -> [String: Double] {
        ["stationary": 0.9, "walking": 0.05, "running": 0.03,
         "other_movement": 0.02, "unknown": 0.0]
    }

    /// Quiet stationary windows over [start, end): gyro 1 dps, accel 0.05 g — below both quiet bars.
    private func quietWindows(from start: Int, to end: Int) -> [ActivityPythonService.WindowPrediction] {
        windows(from: start, to: end, accelRmsG: 0.05, gyroRmsDps: 1.0)
    }

    /// High-motion stationary windows over [start, end): gyro 40 dps, accel 3 g — above the high bar.
    private func activeWindows(from start: Int, to end: Int) -> [ActivityPythonService.WindowPrediction] {
        windows(from: start, to: end, accelRmsG: 3.0, gyroRmsDps: 40.0)
    }

    private func windows(from start: Int, to end: Int, accelRmsG: Double,
                         gyroRmsDps: Double) -> [ActivityPythonService.WindowPrediction] {
        var out: [ActivityPythonService.WindowPrediction] = []
        var t = start
        while t + 4 <= end {
            out.append(ActivityPythonService.WindowPrediction(
                start: Double(t), end: Double(t + 4), label: "stationary",
                probs: stationaryProbs(), baseline: false,
                features: ["accel_rms_g": accelRmsG, "gyro_rms_dps": gyroRmsDps, "jerk_rms": 0.01]))
            t += 2
        }
        return out
    }

    private func hr(_ from: Int, to: Int, bpm: Int = 60, step: Int = 1) -> [HRSample] {
        var out: [HRSample] = []
        var t = from
        while t < to {
            out.append(HRSample(ts: t, bpm: bpm))
            t += step
        }
        return out
    }

    /// The epochs of a built C10 document as dictionaries.
    private func docEpochs(_ doc: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(doc["epochs"] as? [[String: Any]])
    }

    /// Build the C10 document the live lane builds, with the day's wear intervals and HR stream.
    private func makeDocument(windows: [ActivityPythonService.WindowPrediction],
                              wearEvents: [(ts: Int, kind: String)] = [],
                              hrSamples: [HRSample] = [],
                              dayEnd: Int? = nil,
                              inputRevision: Int64 = 7) throws -> [String: Any] {
        let end = dayEnd ?? dayStart + 3_600
        let intervals = ActivityLane.wearIntervals(fromEvents: wearEvents,
                                                   from: dayStart, to: end)
        return try ActivityLane.activityDocument(
            windows: windows,
            sleepIntervals: [], exerciseIntervals: [],
            dayStart: dayStart, dayEnd: end,
            inputRevision: inputRevision,
            modelVersion: "hart-activity-1",
            preprocessingVersion: "activity-preprocess-1",
            dataThrough: dayStart + 60,
            wearIntervals: intervals,
            hrSamples: hrSamples)
    }

    // MARK: - Epoch JSON round-trip

    /// The C10 epoch JSON carries `wsq` exactly when the state is known; an epoch without it stays
    /// absent (additive key), and both old (no-`wsq`) and new documents decode losslessly.
    func testEpochJSONRoundTripIncludesWsqWhenSetAndOmitsWhenNil() throws {
        let withState = ActivityEpoch(startTs: dayStart, endTs: dayStart + 30, motion: .stationary,
                                      posture: .unknown, exercise: .unknown, sleepState: .unknown,
                                      exertion: .unknown, wear: .onWrist, wearSignal: .offWrist,
                                      confidence: 0.9, observedS: 30, validS: 30)
        let withoutState = ActivityEpoch(startTs: dayStart + 30, endTs: dayStart + 60, motion: .stationary,
                                         posture: .unknown, exercise: .unknown, sleepState: .unknown,
                                         exertion: .unknown, wear: .onWrist,
                                         confidence: 0.9, observedS: 30, validS: 30)
        let doc = try ActivityLane.activityDocument(
            epochs: [withState, withoutState], sleepIntervals: [],
            dayStart: dayStart, dayEnd: dayStart + 60,
            inputRevision: 7, modelVersion: "hart-activity-1",
            preprocessingVersion: "activity-preprocess-1", dataThrough: dayStart + 60)
        let epochs = try docEpochs(doc)
        XCTAssertEqual(epochs[0]["wsq"] as? String, "off_wrist")
        XCTAssertEqual(epochs[0]["w"] as? String, "on_wrist", "three-state wear is untouched")
        XCTAssertFalse(epochs[1].keys.contains("wsq"), "nil wearSignal must not emit the key")

        // Decode the document back through the shared Codable: the state round-trips.
        let data = try JSONSerialization.data(withJSONObject: doc)
        let decoded = try JSONDecoder().decode(ActivityContextDocument.self, from: data)
        XCTAssertEqual(decoded.epochs[0].wearSignal, .offWrist)
        XCTAssertNil(decoded.epochs[1].wearSignal)

        // A pre-V1 document (no `wsq` key anywhere) still decodes: old rows/documents are nil.
        var oldObject = doc
        oldObject["epochs"] = try docEpochs(doc).map { epoch -> [String: Any] in
            var e = epoch
            e.removeValue(forKey: "wsq")
            return e
        }
        let old = try JSONSerialization.data(withJSONObject: oldObject)
        let oldDoc = try JSONDecoder().decode(ActivityContextDocument.self, from: old)
        XCTAssertEqual(oldDoc.epochs.count, 2)
        XCTAssertNil(oldDoc.epochs[0].wearSignal)
        XCTAssertNil(oldDoc.epochs[1].wearSignal)
    }

    // MARK: - Lane fold with a WRIST_OFF day

    /// A day with an explicit WRIST_ON -> WRIST_OFF pair: epochs inside the off interval classify
    /// `off_wrist` in BOTH the six-state `wsq` and the three-state `w`; epochs in the on interval
    /// keep `w == on_wrist` and never classify off-wrist (quiet IMU + HR alone is not enough).
    func testWristOffDayEpochsClassifyOffWristThreeStateWearUnchanged() throws {
        let events: [(ts: Int, kind: String)] = [
            (dayStart, "WRIST_ON"),
            (dayStart + 600, "WRIST_OFF"),
        ]
        let windows = quietWindows(from: dayStart, to: dayStart + 1_800)
        // HR only while on-wrist: an off strap streams no HR, so the durable off interval has no
        // sustained-HR recovery and every epoch inside it stays off_wrist.
        let doc = try makeDocument(windows: windows, wearEvents: events,
                                   hrSamples: hr(dayStart, to: dayStart + 600))
        let epochs = try docEpochs(doc)
        let onInterval = epochs.filter { ($0["s"] as? Int ?? 0) < dayStart + 600 }
        let offInterval = epochs.filter { ($0["s"] as? Int ?? 0) >= dayStart + 600 }
        XCTAssertFalse(onInterval.isEmpty)
        XCTAssertFalse(offInterval.isEmpty)

        for e in offInterval {
            XCTAssertEqual(e["w"] as? String, "off_wrist")
            XCTAssertEqual(e["wsq"] as? String, "off_wrist",
                           "durable off interval resolves off_wrist")
        }
        for e in onInterval {
            XCTAssertEqual(e["w"] as? String, "on_wrist")
            XCTAssertNotEqual(e["wsq"] as? String, "off_wrist",
                              "an explicit on interval is never off-wrist")
        }
    }

    /// The same day with the WRIST_OFF but NO HR at all: the off interval still classifies
    /// off_wrist (durable events are the authority; HR absence never changes that), and the
    /// on-interval epochs abstain to unknown — absence of evidence is never a guess.
    func testWristOffWithoutAnyHrStillOffWristInInterval() throws {
        let events: [(ts: Int, kind: String)] = [
            (dayStart, "WRIST_ON"),
            (dayStart + 600, "WRIST_OFF"),
        ]
        let doc = try makeDocument(windows: quietWindows(from: dayStart, to: dayStart + 900),
                                   wearEvents: events)
        let epochs = try docEpochs(doc)
        for e in epochs where (e["s"] as? Int ?? 0) >= dayStart + 600 {
            XCTAssertEqual(e["wsq"] as? String, "off_wrist")
        }
        for e in epochs where (e["s"] as? Int ?? 0) < dayStart + 600 {
            XCTAssertFalse(e.keys.contains("wsq"),
                           "no-HR on interval abstains (engine unknown), never off — absent key")
            XCTAssertEqual(e["w"] as? String, "on_wrist")
        }
    }

    // MARK: - Sustained HR closes a durable off interval

    /// A WRIST_OFF with no WRIST_ON, but a sustained 5-min HR run starting 5 min later: epochs
    /// before the run completes stay off_wrist; epochs after it complete are NOT off_wrist
    /// (WristWearRecovery closes the interval), while the three-state `w` keeps the raw
    /// event-derived off_wrist — the two folds are independent by design.
    func testSustainedHrClosesOffIntervalForWearSignalButNotThreeStateWear() throws {
        let events: [(ts: Int, kind: String)] = [
            (dayStart, "WRIST_ON"),
            (dayStart + 600, "WRIST_OFF"),
        ]
        // HR resumes 5 min after the OFF and runs 20 min with no gap: confirmation = 300 s.
        let hrStart = dayStart + 900
        let windows = quietWindows(from: dayStart, to: dayStart + 2_400)
        let doc = try makeDocument(windows: windows, wearEvents: events,
                                   hrSamples: hr(hrStart, to: dayStart + 2_400))
        let epochs = try docEpochs(doc)

        func epoch(at s: Int) -> [String: Any] {
            epochs.first { ($0["s"] as? Int) == s }!
        }

        // Off interval [dayStart+600, dayStart+1200): recovery run [900, 1200) is not yet 300 s
        // complete -> durable off active.
        XCTAssertEqual(epoch(at: dayStart + 600)["wsq"] as? String, "off_wrist")
        XCTAssertEqual(epoch(at: dayStart + 1_170)["wsq"] as? String, "off_wrist")
        // Recovery completes at 1200 (run 900..1200 = 300 s): the interval is closed for the
        // six-state engine, which now abstains (quiet IMU + HR, no optical evidence) — the
        // abstention is emitted as an ABSENT wsq, never a fabricated state.
        let recovered = epoch(at: dayStart + 1_200)
        XCTAssertNotEqual(recovered["wsq"] as? String, "off_wrist")
        XCTAssertFalse(recovered.keys.contains("wsq"))
        XCTAssertEqual(recovered["w"] as? String, "off_wrist",
                       "three-state wear keeps the raw event interval; wear_signal is additive")
    }

    // MARK: - IMU window features

    /// High-motion IMU windows inside an explicit on interval with HR present still abstain
    /// server-side: the lane loads no optical channel, and motion alone is no optical evidence.
    func testHighMotionWornEpochsAbstainWithoutOpticalEvidence() throws {
        let events: [(ts: Int, kind: String)] = [(dayStart, "WRIST_ON")]
        let windows = activeWindows(from: dayStart, to: dayStart + 120)
        let doc = try makeDocument(windows: windows, wearEvents: events,
                                   hrSamples: hr(dayStart, to: dayStart + 120))
        let epochs = try docEpochs(doc)
        XCTAssertFalse(epochs.isEmpty)
        for e in epochs {
            XCTAssertFalse(e.keys.contains("wsq"),
                           "high motion without an optical verdict is never graded good")
            XCTAssertEqual(e["w"] as? String, "on_wrist")
        }
    }

    // MARK: - Evidence resolution (server-side availability)

    /// The lane resolves evidence only from what the day job loads: live freshness, optical, skin
    /// temp, charging and PPG SQI channels are all nil server-side (documented in the builder);
    /// `durableOffActive` comes from the reconstructed intervals and `hrPresent` from the stream.
    func testServerEvidenceResolutionKeepsUnavailableChannelsNil() {
        let intervals = [
            WearInterval(start: dayStart + 600, end: dayStart + 3_600, wear: .offWrist),
            WearInterval(start: dayStart, end: dayStart + 600, wear: .onWrist),
        ]
        let hrSamples = hr(dayStart, to: dayStart + 120, bpm: 60)
        // No recovery for the off interval (HR stream is before the OFF): the off interval's
        // completion map is empty, so the epoch resolves durable-off active.
        XCTAssertTrue(ActivityLane.recoveryCompletions(wearIntervals: intervals, hrSamples: hrSamples).isEmpty)
        // An epoch inside the off interval, no recovery yet.
        let off = ActivityLane.wearSignalEvidence(
            epochStart: dayStart + 900, epochEnd: dayStart + 930,
            wearIntervals: intervals, recoveryCompletion: nil,
            hrSamples: hrSamples,
            imuMotion: ActivityLane.epochImuMotion(
                epochStart: dayStart + 900, epochEnd: dayStart + 930,
                windows: quietWindows(from: dayStart, to: dayStart + 1_200)))
        XCTAssertEqual(off.durableOffActive, true)
        XCTAssertNil(off.liveWristOffFresh)
        XCTAssertNil(off.liveWristOnFresh)
        XCTAssertNil(off.charging)
        XCTAssertNil(off.tempSkinLike)
        XCTAssertNil(off.opticalBaselineZero)
        XCTAssertNil(off.strapFlagsBad)
        XCTAssertNil(off.strapFlagsValid)
        XCTAssertNil(off.contactNotDetected)
        // PPG waveform rows are not loaded by the activity lane -> SQI stays nil, never guessed.
        XCTAssertNil(off.ppgSqi)
        XCTAssertTrue(off.ppgSqiReasons.isEmpty)

        // An epoch inside the on interval: durable off resolved closed by the WRIST_ON interval.
        let on = ActivityLane.wearSignalEvidence(
            epochStart: dayStart, epochEnd: dayStart + 30,
            wearIntervals: intervals, recoveryCompletion: nil,
            hrSamples: hrSamples,
            imuMotion: ActivityLane.epochImuMotion(epochStart: dayStart, epochEnd: dayStart + 30, windows: quietWindows(from: dayStart, to: dayStart + 600)))
        XCTAssertEqual(on.durableOffActive, false)
        XCTAssertEqual(on.hrPresent, true)
        XCTAssertEqual(on.imuQuiet, true)
        XCTAssertEqual(on.imuHighMotion, false)
    }

    /// `recoveryCompletions` reuses `WristWearRecovery`: an off interval closed by a sustained
    /// HR run gets a completion timestamp, and epochs at/after it resolve closed + recovery met.
    func testRecoveryCompletionResolvedFromSustainedHrRun() {
        let intervals = [WearInterval(start: dayStart, end: dayStart + 3_600, wear: .offWrist)]
        // HR resumes at dayStart+600, 60 bpm every 1 s for 10 minutes.
        let hrSamples = hr(dayStart + 600, to: dayStart + 1_200)
        let completions = ActivityLane.recoveryCompletions(wearIntervals: intervals, hrSamples: hrSamples)
        // Confirmation completes at dayStart + 600 + 300 = dayStart + 900.
        XCTAssertEqual(completions[dayStart], dayStart + 901)

        let before = ActivityLane.wearSignalEvidence(
            epochStart: dayStart + 870, epochEnd: dayStart + 900,
            wearIntervals: intervals, recoveryCompletion: completions[dayStart],
            hrSamples: hrSamples,
            imuMotion: ActivityLane.epochImuMotion(
                epochStart: dayStart + 870, epochEnd: dayStart + 900,
                windows: quietWindows(from: dayStart, to: dayStart + 1_200)))
        XCTAssertEqual(before.durableOffActive, true)
        XCTAssertNil(before.sustainedHrRecoveryMet)

        let after = ActivityLane.wearSignalEvidence(
            epochStart: dayStart + 900, epochEnd: dayStart + 930,
            wearIntervals: intervals, recoveryCompletion: completions[dayStart],
            hrSamples: hrSamples,
            imuMotion: ActivityLane.epochImuMotion(
                epochStart: dayStart + 900, epochEnd: dayStart + 930,
                windows: quietWindows(from: dayStart, to: dayStart + 1_200)))
        XCTAssertEqual(after.durableOffActive, false)
        XCTAssertEqual(after.sustainedHrRecoveryMet, true)
    }

    /// A whole day with no wear event coverage leaves `durableOffActive` nil (interval semantics:
    /// gaps carry no evidence) — the engine abstains rather than guessing.
    func testNoIntervalCoverageIsNilNotFabricated() {
        let evidence = ActivityLane.wearSignalEvidence(
            epochStart: dayStart, epochEnd: dayStart + 30,
            wearIntervals: [], recoveryCompletion: nil, hrSamples: [],
            imuMotion: ActivityLane.epochImuMotion(epochStart: dayStart, epochEnd: dayStart + 30, windows: quietWindows(from: dayStart, to: dayStart + 60)))
        XCTAssertNil(evidence.durableOffActive)
        XCTAssertNil(evidence.sustainedHrRecoveryMet)
        XCTAssertNil(evidence.hrPresent, "no HR stream loaded is missing evidence, not absent HR")
    }
}
