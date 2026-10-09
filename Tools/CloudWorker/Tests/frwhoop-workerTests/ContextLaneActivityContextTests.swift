import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// The lane's activity-context inputs without a database (D3-02, D3-10, D3-11, D3-16, D5-04, D5-07, D5-13, D6-15):
/// row parsers, the per-day lineage and document-ranking SQL, the causal view of transition events and the
/// provenance recorded in `inputRevisions`.
final class ContextLaneActivityContextTests: XCTestCase {
    typealias PC = PhysiologyContext

    // 2026-10-03T00:00:00Z
    let dayStart = 1_790_985_600

    func job(mode: PC.ProcessingMode = .retrospective, override: Int? = nil) -> ContextInputs.Job {
        ContextInputs.Job(userId: "u", deviceId: "d", day: "2026-10-03", mode: mode, inputRevision: 3, leaseToken: "t",
                          timezoneId: "UTC", cutoffOverride: override, claimedAt: dayStart + 40 * 3_600)
    }

    func windows() throws -> ContextInputs.Windows {
        try XCTUnwrap(ContextInputs.windows(day: "2026-10-03", timezoneId: "UTC"))
    }

    func testEpochRowsCarryWearSignalAndModelProvenance() throws {
        let row: [String: String] = [
            "s": "100", "e": "130", "motion_label": "stationary", "posture": "unknown", "exercise_session": "false",
            "sleep_state": "awake", "exertion_context": "resting_candidate", "wear_state": "on_wrist",
            "wear_signal": "on_wrist_loose", "confidence": "0.81", "observed_s": "30", "valid_s": "30",
            "model_version": "hart-wisdm-v0", "preprocessing_version": "1.0.0", "revision": "9", "at": "200"]
        let e = try XCTUnwrap(ContextInputs.parseEpoch(row))
        XCTAssertEqual(e.epoch.wearSignal, .onWristLoose)
        XCTAssertEqual(e.modelVersion, "hart-wisdm-v0")
        XCTAssertEqual(e.provenance, "hart-wisdm-v0@1.0.0")
        // A NULL column (older rows) is missing evidence, never "good".
        var old = row
        old["wear_signal"] = ""
        XCTAssertNil(try XCTUnwrap(ContextInputs.parseEpoch(old)).epoch.wearSignal)
    }

    func testRunAndTransitionRowsCarryTheirDocument() throws {
        let run = try XCTUnwrap(ContextInputs.parseRun([
            "s": "100", "e": "400", "class": "lying_down", "confidence": "0.7", "sleep": "awake", "wear": "on_wrist",
            "in_bed": "true", "algorithm_version": "streams-activity-1", "decoder_version": "hsmm-1.7",
            "revision": "12", "at": "500"]))
        XCTAssertEqual(run.inBed, true)
        XCTAssertEqual(run.provenance, "streams-activity-1/hsmm-1.7")
        // A document that writes `in_bed` sends "false" for a run without it; an older document (decoder before
        // hsmm-1.3) sends "": the document did not say, never "observed out of bed".
        var row = ["s": "100", "e": "400", "class": "sitting", "confidence": "0.7", "revision": "3", "in_bed": "false"]
        XCTAssertEqual(ContextInputs.parseRun(row)?.inBed, false)
        row["in_bed"] = ""
        XCTAssertNil(ContextInputs.parseRun(row)?.inBed)
        row["in_bed"] = nil
        XCTAssertNil(ContextInputs.parseRun(row)?.inBed)
        let ev = try XCTUnwrap(ContextInputs.parseTransition([
            "ts": "250", "kind": "sit_to_stand_like", "probability": "0.62", "algorithm_version": "streams-activity-1",
            "decoder_version": "hsmm-1.7", "revision": "12", "at": "500"]))
        XCTAssertEqual(ev.ts, 250)
        XCTAssertEqual(ev.probability, 0.62, accuracy: 1e-9)
        XCTAssertEqual(ev.availableAt, 500)
        XCTAssertNil(ev.onsetTs, "older documents carry no onset")
        XCTAssertNil(ev.source)
        XCTAssertNil(ContextInputs.parseTransition(["ts": "250", "kind": "", "revision": "1"]))
    }

    /// The decoder's onset back-date and detector reach the PC input (INT-C / D2-05), and the SQL selects them
    /// from the same chosen document as the event.
    func testTransitionOnsetAndSourceAreReadFromTheDocument() throws {
        let sql = ContextSQL.activityTransitions
        XCTAssertTrue(sql.contains("coalesce(x.value ->> 'onset_ts', '') as onset_ts"), sql)
        XCTAssertTrue(sql.contains("coalesce(x.value ->> 'source', '') as source"), sql)
        var row = ["ts": "250", "kind": "stand_to_sit_like", "probability": "0.7", "revision": "3", "at": "400",
                   "onset_ts": "243", "source": "transition_expert"]
        let ev = try XCTUnwrap(ContextInputs.parseTransition(row))
        XCTAssertEqual(ev.onsetTs, 243)
        XCTAssertEqual(ev.source, "transition_expert")
        XCTAssertEqual(ev.changeTs, 243)
        // An onset after the detection second is not a back-date: dropped. Empty strings are "not said".
        row["onset_ts"] = "251"
        XCTAssertNil(try XCTUnwrap(ContextInputs.parseTransition(row)).onsetTs)
        row["onset_ts"] = ""; row["source"] = ""
        let bare = try XCTUnwrap(ContextInputs.parseTransition(row))
        XCTAssertNil(bare.onsetTs)
        XCTAssertNil(bare.source)
        XCTAssertEqual(bare.changeTs, 250)
    }

    func testEpochSqlReadsOneRevisionPerUtcDayAndRunsAndEventsShareTheRankedDocument() {
        let epochs = ContextSQL.activityEpochs
        XCTAssertTrue(epochs.contains("order by e.result_revision desc limit 1"), "newest revision per day")
        XCTAssertTrue(epochs.contains("e.day = days.day"), "per UTC epoch day, never across the window")
        XCTAssertTrue(epochs.contains("e.computed_at <= to_timestamp(nullif($7, '')::bigint)"), "causal cutoff")
        XCTAssertTrue(epochs.contains("wear_signal") && epochs.contains("model_version"))
        for sql in [ContextSQL.activityRuns, ContextSQL.activityTransitions] {
            XCTAssertTrue(sql.hasPrefix(ContextSQL.chosenActivityDocuments))
            let rank = "order by d.day, (d.decoder_version = $7::text) desc,"
            XCTAssertTrue(sql.contains(rank), "current decoder first")
            let newer = sql.range(of: "(regexp_match(d.decoder_version, '^hsmm-([0-9]+)[.]([0-9]+)$'))::int[] desc nulls last,")
            let through = sql.range(of: "d.data_through desc nulls last,")
            XCTAssertNotNil(newer)
            XCTAssertTrue(newer.map { n in through.map { n.upperBound <= $0.lowerBound } ?? false } ?? false,
                          "then the newer decoder (numeric), then data_through")
            XCTAssertTrue(sql.contains("as says_in_bed"))
            XCTAssertTrue(sql.contains("d.computed_at <= to_timestamp(nullif($8, '')::bigint)"))
            XCTAssertTrue(sql.contains("user_id = $1::uuid and d.device_id = $2::uuid"))
            for forbidden in ["insert ", "update ", "delete ", "truncate "] {
                XCTAssertFalse(sql.lowercased().contains(forbidden))
            }
        }
        XCTAssertTrue(ContextSQL.activityTransitions.contains("c.document -> 'events'"))
    }

    func testAssembledInputCarriesCausallyVisibleTransitionsAndTheirProvenance() throws {
        var l = ContextInputs.Loaded()
        let t0 = dayStart + 10 * 3_600
        l.heartRate = (0..<600).map { PC.HeartRateObservation(ts: t0 + $0, bpm: 60, availableAt: t0 + $0 + 5) }
        l.epochs = [PC.ActivityEpochInput(
            epoch: ActivityEpoch(startTs: t0, endTs: t0 + 30, motion: .stationary, posture: .unknown, exercise: .false,
                                 sleepState: .awake, exertion: .unknown, wear: .onWrist, wearSignal: .onWristGood,
                                 confidence: 0.9, observedS: 30, validS: 30),
            revision: 5, availableAt: t0 + 40, modelVersion: "hart-wisdm-v0", preprocessingVersion: "1.0.0")]
        l.intervals = [PC.ActivityIntervalInput(interval: .init(t0, t0 + 600), activityClass: "sitting", confidence: 0.8,
                                                revision: 12, availableAt: t0 + 30, inBed: false,
                                                decoderVersion: "hsmm-1.7", algorithmVersion: "streams-activity-1")]
        l.transitions = [
            PC.TransitionEventInput(ts: t0 + 60, kind: "sit_to_stand_like", probability: 0.7, revision: 12,
                                    availableAt: t0 + 30, decoderVersion: "hsmm-1.7",
                                    algorithmVersion: "streams-activity-1"),
            PC.TransitionEventInput(ts: t0 + 400, kind: "stand_to_sit_like", probability: 0.7, revision: 12,
                                    availableAt: t0 + 900, decoderVersion: "hsmm-1.7",
                                    algorithmVersion: "streams-activity-1"),
        ]
        let retro = ContextInputs.assemble(l, job: job(), windows: try windows())
        XCTAssertEqual(retro.input.activityTransitions.count, 2)
        let r = Dictionary(uniqueKeysWithValues: retro.input.inputRevisions.map { ($0.input, $0.revision) })
        XCTAssertEqual(r["activity_days_documents"], "streams-activity-1/hsmm-1.7@12")
        XCTAssertEqual(r["activity_epochs_models"], "hart-wisdm-v0@1.0.0")
        XCTAssertEqual(r["activity_transitions"], "2:12")
        // A causal replay at t0 + 500 cannot see the event published at t0 + 900, nor count it.
        let causal = ContextInputs.assemble(l, job: job(mode: .causalLive, override: t0 + 500), windows: try windows())
        XCTAssertEqual(causal.input.activityTransitions.map(\.ts), [t0 + 60])
        let c = Dictionary(uniqueKeysWithValues: causal.input.inputRevisions.map { ($0.input, $0.revision) })
        XCTAssertEqual(c["activity_transitions"], "1:12")
        // The engine joins the visible event to the measurement that contains it.
        let doc = PC.Engine.buildDay(retro.input, history: retro.history)
        let w = try XCTUnwrap(doc.envelopes.first { $0.metric == .heartRate && $0.support.start == t0 })
        XCTAssertEqual(w.activity.transitionEvents?.postural, 1)
        XCTAssertEqual(w.wearSignal?.coveredS, 30)
    }

    func testSubstitutedNightlyHrvIsAnotherMethod() throws {
        let start = "2026-10-02T23:00:00Z", end = "2026-10-03T07:00:00Z"
        func payload(_ provenance: String) -> String {
            #"{"sleep":[{"id":"s1","start_at":"\#(start)","end_at":"\#(end)","stages":[]}],"daily":{"hrv_rmssd_ms":48,"resting_hr_bpm":52\#(provenance)}}"#
        }
        let native = try XCTUnwrap(ContextInputs.parseSnapshot(day: "2026-10-03", payloadText: payload(""),
                                                               resultRevision: 1, inputRevision: 1, availableAt: 0))
        let substituted = try XCTUnwrap(ContextInputs.parseSnapshot(
            day: "2026-10-03",
            payloadText: payload(#","hrv_provenance":{"mode":"active","provider_id":"oura","provider_version":"2","canonical_source":"provider"}"#),
            resultRevision: 1, inputRevision: 1, availableAt: 0))
        XCTAssertNil(native.hrvProvenance)
        XCTAssertEqual(substituted.hrvProvenance, "provider:oura@2")
        func hrvMethod(_ s: ContextInputs.Snapshot) -> PC.MethodRef? {
            ContextInputs.snapshotMeasurements(s, offsetSec: 0).first { $0.metric == .hrvRmssd }?.method
        }
        XCTAssertEqual(hrvMethod(native)?.algorithmVersion, ContextInputs.scoringAlgorithmVersion)
        XCTAssertEqual(hrvMethod(substituted)?.algorithmVersion, ContextInputs.scoringAlgorithmVersion + "+provider:oura@2")
        // Other nightly fields are untouched.
        let rhr = ContextInputs.snapshotMeasurements(substituted, offsetSec: 0).first { $0.metric == .restingHeartRate }
        XCTAssertEqual(rhr?.method.algorithmVersion, ContextInputs.scoringAlgorithmVersion)
    }
}
