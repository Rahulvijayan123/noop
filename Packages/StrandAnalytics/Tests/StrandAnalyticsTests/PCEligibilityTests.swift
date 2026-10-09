import XCTest
@testable import StrandAnalytics

/// System B: tri-state eligibility with reasons (V02, V03), dependence declarations, selection accounting and the
/// stable-awake policy sensitivity sweep (spec §8, §14).
final class PCEligibilityTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias F = PCSignalFixtures
    typealias B = PhysiologyContext.Eligibility

    var support: PC.Interval { PC.Interval(F.t0, F.t0 + 300) }

    func verdict(_ kind: PC.ComparisonKind = .stableAwakeRest, track: PC.ResolvedTrack,
                 sleepWear: PC.SleepWearContext = F.awakeWorn, validity: PC.SignalValidity = F.validSignal,
                 bouts: [PC.BoutRef] = [], exertion: [PC.ExertionWindowSummary] = [],
                 support s: PC.Interval? = nil, config: PC.EligibilityConfig = .init()) -> PC.EligibilityVerdict {
        let sup = s ?? support
        return B.evaluate(kind, metric: .hrvRmssd, support: sup, validity: validity,
                          activity: PC.IntervalAlgebra.composition(over: sup, track: track),
                          preceding: PC.IntervalAlgebra.precedingHistory(before: sup.start, track: track, lookbackS: 1800),
                          sleepWear: sleepWear, exertion: exertion, recentBouts: bouts, config: config)
    }

    var quiet: PC.ResolvedTrack { F.track([(F.t0 - 1800, F.t0 + 600, "still")]) }

    // MARK: Comparisons

    func testComparisonsPerMethodFamily() {
        XCTAssertEqual(B.comparisons(for: .hrvRmssd, method: F.method("series.hrv_rmssd.5min")),
                       [.stableAwakeRest, .sleepMeasurement, .activityResponse])
        XCTAssertEqual(B.comparisons(for: .heartRate, method: PC.Engine.heartRateWindowMethod),
                       [.stableAwakeRest, .sleepMeasurement, .activityResponse])
        XCTAssertEqual(B.comparisons(for: .hrvRmssd, method: F.method("snapshot.hrv_rmssd.night", aggregation: .session)),
                       [.sleepMeasurement])
        XCTAssertEqual(B.comparisons(for: .spo2Candidate, method: F.method("series.spo2_candidate.5min")), [])
    }

    // MARK: V02 — quiet motion proves nothing about wear, sleep or rest

    func testQuietMotionWithUnknownWearAndSleepIsUnknownWithExplicitReasons() {
        let v = verdict(track: quiet, sleepWear: .unknown)
        XCTAssertEqual(v.state, .unknown)
        XCTAssertTrue(v.reasons.contains(B.awakeEvidenceUnknown))
        XCTAssertTrue(v.reasons.contains(B.wearEvidenceUnknown))
        XCTAssertFalse(v.reasons.contains(B.stableAwakeLowMovement))
        XCTAssertEqual(v.evidence("stationary_share"), 1, "the stillness is recorded as evidence, not as a verdict")
        // Awake known but wear unknown: still unknown, never eligible.
        var awakeOnly = F.awakeWorn
        awakeOnly.wearState = .unknown
        let w = verdict(track: quiet, sleepWear: awakeOnly)
        XCTAssertEqual(w.state, .unknown)
        XCTAssertEqual(w.reasons, [B.wearEvidenceUnknown])
        // And a quiet sleep measurement is not established by stillness either.
        XCTAssertEqual(verdict(.sleepMeasurement, track: quiet, sleepWear: .unknown).state, .unknown)
    }

    // MARK: V03 — target deviation is preserved

    func testStableAwakeWithElevatedHeartRateAndLowHrvStaysEligibleAndValid() {
        // Two beats per second (120 bpm) with ±3 ms alternation: high HR, RMSSD ≈ 6 ms. The transport order
        // (`ord`) puts the 503 ms beat first in each second, so each whole-second step matches its interval.
        var beats: [PC.BeatIntervalObservation] = []
        for s in 0..<300 {
            beats.append(.init(ts: F.t0 + s, rrMs: 503, seq: 0, ord: 0))
            beats.append(.init(ts: F.t0 + s, rrMs: 497, seq: 0, ord: 1))
        }
        let hr = (0..<300).map { PC.HeartRateObservation(ts: F.t0 + $0, bpm: 120 + $0 % 3) }
        let (o, _) = F.sanitize(F.input(heartRate: hr, beats: beats))
        for metric in [PC.MetricKind.hrvRmssd, .heartRate] {
            let validity = PC.SignalValidityEngine.assess(F.measurement(metric, support, value: metric == .heartRate ? 120 : 6),
                                                          observations: o, motion: quiet, config: .init())
            XCTAssertEqual(validity.state, .valid, "\(metric) \(validity.reasons)")
            let v = verdict(track: quiet, validity: validity)
            XCTAssertEqual(v.state, .eligible, "\(metric) \(v.reasons)")
            XCTAssertEqual(v.reasons.first, B.stableAwakeLowMovement)
            XCTAssertEqual(v.targetDependentGates, [B.signalInvalid])
        }
    }

    func testEvaluateNeverReadsTheValue() {
        // The verdict has no value input at all; two measurements that differ only in value get one verdict.
        let a = verdict(track: quiet)
        let b = verdict(track: quiet)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.state, .eligible)
    }

    // MARK: Stable awake rest — determined failures and unknowns

    func testSleepAndWearEvidenceDecideAndMixedIsIneligible() {
        var s = F.awakeWorn
        s.sleepState = .asleep
        XCTAssertEqual(verdict(track: quiet, sleepWear: s).reasons, [B.asleep])
        XCTAssertEqual(verdict(track: quiet, sleepWear: s).state, .ineligible)
        s.sleepState = .mixed
        XCTAssertEqual(verdict(track: quiet, sleepWear: s).state, .ineligible)
        s = F.awakeWorn
        s.wearState = .notWorn
        XCTAssertEqual(verdict(track: quiet, sleepWear: s).reasons, [B.notWorn])
        s.wearState = .mixed
        XCTAssertEqual(verdict(track: quiet, sleepWear: s).reasons, [B.wearMixed])
        // A determined failure plus an unknown: ineligible, and both are reported.
        s = .unknown
        s.wearState = .notWorn
        let both = verdict(track: quiet, sleepWear: s)
        XCTAssertEqual(both.state, .ineligible)
        XCTAssertEqual(Set(both.reasons), [B.notWorn, B.awakeEvidenceUnknown])
    }

    func testRecentLocomotionExcludesAndOlderLocomotionDoesNot() {
        let recent = F.track([(F.t0 - 1800, F.t0 - 500, "still"), (F.t0 - 500, F.t0 - 400, "walking"),
                              (F.t0 - 400, F.t0 + 600, "still")])
        let r = verdict(track: recent)
        XCTAssertEqual(r.state, .ineligible)
        XCTAssertEqual(r.reasons, [B.recentLocomotion])
        XCTAssertEqual(r.evidence("seconds_since_locomotion"), 400)
        XCTAssertEqual(r.evidence("preceding_still_run_s"), 400)
        let older = F.track([(F.t0 - 1800, F.t0 - 800, "walking"), (F.t0 - 800, F.t0 + 600, "still")])
        let o = verdict(track: older)
        XCTAssertEqual(o.state, .eligible)
        XCTAssertEqual(o.evidence("seconds_since_locomotion"), 800)
    }

    func testMovementInsideTheSupportIsDeterminedButMissingCoverageIsUnknown() {
        let moving = F.track([(F.t0 - 1800, F.t0 + 240, "still"), (F.t0 + 240, F.t0 + 300, "other_movement")])
        let m = verdict(track: moving)   // 20 % movement: even all-stationary elsewhere cannot reach 90 %
        XCTAssertEqual(m.state, .ineligible)
        XCTAssertEqual(m.reasons, [B.movementInSupport])
        let gappy = F.track([(F.t0 - 1800, F.t0 + 200, "still")])   // last 100 s of the support uncovered
        let g = verdict(track: gappy)
        XCTAssertEqual(g.state, .unknown)
        XCTAssertEqual(g.reasons, [B.insufficientActivityCoverage])
        XCTAssertEqual(g.evidence("qualified_coverage")!, 200.0 / 300.0, accuracy: 1e-4)
    }

    func testPrecedingStillnessEndedByMovementIsIneligibleButByAGapIsUnknown() {
        let fidget = F.track([(F.t0 - 1800, F.t0 - 210, "still"), (F.t0 - 210, F.t0 - 200, "other_movement"),
                              (F.t0 - 200, F.t0 + 600, "still")])
        let f = verdict(track: fidget)
        XCTAssertEqual(f.state, .ineligible)
        XCTAssertEqual(f.reasons, [B.insufficientPrecedingStillness])
        let gap = F.track([(F.t0 - 1800, F.t0 - 210, "still"), (F.t0 - 200, F.t0 + 600, "still")])
        let g = verdict(track: gap)
        XCTAssertEqual(g.state, .unknown)
        XCTAssertTrue(g.reasons.contains(B.precedingStillnessUnobserved))
    }

    func testInvalidSignalIsADeclaredTargetDependentGate() {
        let invalid = PC.SignalValidity(state: .invalid, reasons: [PC.SignalValidityEngine.motionContaminated])
        let v = verdict(track: quiet, validity: invalid)
        XCTAssertEqual(v.state, .ineligible)
        XCTAssertEqual(v.reasons, [B.signalInvalid])
        XCTAssertEqual(v.targetDependentGates, [B.signalInvalid])
        let degraded = verdict(track: quiet, validity: .init(state: .degraded, reasons: []))
        XCTAssertEqual(degraded.state, .eligible)
        XCTAssertTrue(degraded.reasons.contains(B.signalDegraded))
        XCTAssertEqual(verdict(track: quiet, validity: .missing()).state, .unknown)
    }

    func testHeartRateDependentActivityIsNeverEligibilityEvidence() {
        let decoder = F.track([(F.t0 - 1800, F.t0 + 600, "sitting")], source: .decoderIntervals, heartRateDependent: true)
        let v = verdict(track: decoder)
        XCTAssertEqual(v.state, .unknown)
        XCTAssertTrue(v.reasons.contains(B.heartRateDependentActivityIgnored))
        XCTAssertTrue(v.reasons.contains(B.activityEvidenceUnavailable))
        XCTAssertTrue(v.dependsOn.contains(B.activityLabelsReadHeartRate))
        XCTAssertNil(v.evidence("stationary_share"))
        XCTAssertEqual(verdict(track: .empty(.none)).reasons, [B.activityEvidenceUnavailable])
    }

    func testRecentBoutsAndExertionHistoryAreEvidenceAndAConfigurableExclusion() {
        let bout = PC.BoutRef(boutId: "b1", kind: "walking", endedAt: F.t0 - 300, secondsBeforeMeasurement: 300,
                              durationS: 900)
        let windows = [24, 48, 72].map { h in
            PC.ExertionWindowSummary(windowH: h, interval: .init(F.t0 - h * 3600, F.t0), boutCount: 1,
                                     locomotionS: 900 * h / 24, observedS: 50_000 * h / 24, reasons: [])
        }
        let v = verdict(track: quiet, bouts: [bout], exertion: windows)
        XCTAssertEqual(v.state, .ineligible)
        XCTAssertEqual(v.reasons, [B.recentExertionBout])
        XCTAssertEqual(v.evidence("seconds_since_last_bout"), 300)
        XCTAssertEqual(v.evidence("exertion_24h_locomotion_s"), 900)
        XCTAssertEqual(v.evidence("exertion_48h_locomotion_s"), 1800)
        XCTAssertEqual(v.evidence("exertion_72h_locomotion_s"), 2700)
        var off = PC.EligibilityConfig()
        off.postBoutExclusionS = 0
        XCTAssertEqual(verdict(track: quiet, bouts: [bout], exertion: windows, config: off).state, .eligible)
        var capped = PC.EligibilityConfig()
        capped.maxLocomotion24hS = 600
        XCTAssertEqual(verdict(track: quiet, exertion: windows, config: capped).reasons, [B.exertionHistoryExceedsLimit])
    }

    func testHeartDerivedEvidenceIsDeclaredInDependsOn() {
        let s = PC.SleepWearContext(sleepState: .awake, sleepEvidence: ["outside_detected_sleep"],
                                    sleepDependsOnHeartSignals: true, wearState: .worn,
                                    wearEvidence: ["heart_rate_signal_present"], reasons: [])
        let v = verdict(track: quiet, sleepWear: s)
        XCTAssertEqual(v.state, .eligible)
        XCTAssertEqual(Set(v.dependsOn), [B.sleepDetectorUsesHeartRate, B.wearFromHeartRateSignal])
    }

    // MARK: RC-05 — deciding reasons first, notes after them

    func testDecidingReasonsComeFirstAndNotesAreSeparated() throws {
        let degraded = PC.SignalValidity(state: .degraded, reasons: [PC.SignalValidityEngine.partialBeatCoverage])
        // A walking window: ineligible for stable awake rest; the degraded signal is only a note.
        let walking = F.track([(F.t0 - 1800, F.t0 + 600, "walking")])
        let walk = verdict(track: walking, validity: degraded)
        XCTAssertEqual(walk.state, .ineligible)
        XCTAssertEqual(walk.reasons.first, B.movementInSupport)
        XCTAssertEqual(walk.notes, [B.signalDegraded])
        XCTAssertEqual(walk.reasons.last, B.signalDegraded, "the note is kept, after the deciding reasons")
        XCTAssertFalse(walk.decidingReasons.contains(B.signalDegraded))
        // Unknown: the undetermined check leads; a fail never hides behind a note.
        let gap = F.track([(F.t0 - 1800, F.t0 - 210, "still"), (F.t0 - 200, F.t0 + 600, "still")])
        let unknown = verdict(track: gap, validity: degraded)
        XCTAssertEqual(unknown.state, .unknown)
        XCTAssertEqual(unknown.reasons.first, B.precedingStillnessUnobserved)
        XCTAssertTrue(unknown.notes.contains(B.signalDegraded))
        XCTAssertTrue(unknown.notes.contains(B.recentLocomotionUnobserved))
        // Eligible: the positive reason leads, also for activity response (where it used to follow the notes).
        let inside = verdict(.activityResponse, track: walking, validity: degraded)
        XCTAssertEqual(inside.state, .eligible)
        XCTAssertEqual(inside.reasons, [B.insideLocomotion, B.signalDegraded])
        XCTAssertEqual(inside.notes, [B.signalDegraded])
        // Asleep while walking: the positive check is demoted to a note behind the deciding fail.
        var asleep = F.awakeWorn
        asleep.sleepState = .asleep
        let sleeping = verdict(.activityResponse, track: walking, sleepWear: asleep)
        XCTAssertEqual(sleeping.reasons, [B.asleep, B.insideLocomotion])
        XCTAssertEqual(sleeping.notes, [B.insideLocomotion])
        // Notes survive the canonical coders; a verdict written before `notes` existed decodes with none.
        let data = try PC.encoder().encode(walk)
        XCTAssertEqual(try PC.decoder().decode(PC.EligibilityVerdict.self, from: data), walk)
        let plain = verdict(track: quiet)
        XCTAssertTrue(plain.notes.isEmpty)
        XCTAssertFalse(String(decoding: try PC.encoder().encode(plain), as: UTF8.self).contains("notes"),
                       "empty notes are not written")
        let old = #"{"comparison":"stable_awake_rest","state":"unknown","reasons":["awake_evidence_unknown"],"evidence":[],"target_dependent_gates":["signal_invalid"],"depends_on":[],"policy_version":"pc-eligibility-1"}"#
        let decoded = try PC.decoder().decode(PC.EligibilityVerdict.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.notes, [])
        XCTAssertEqual(decoded.decidingReasons, [B.awakeEvidenceUnknown])
    }

    // MARK: P1 / RC-21 — target-dependent gates are declared per verdict

    func testTargetDependentGatesAreDeclaredWhenTheyApply() {
        // HRV validity that rejected out-of-kernel-range and ectopic beats of this measurement's own input.
        let screened = PC.SignalValidity(state: .degraded, reasons: [PC.SignalValidityEngine.elevatedRejectedBeats],
                                         diagnostics: [.init("out_of_range_beats", 12), .init("ectopic_rejected", 3)])
        XCTAssertEqual(verdict(track: quiet, validity: screened).targetDependentGates,
                       [B.signalInvalid, B.gateRrKernelRange, B.gateEctopicRejection])
        // Sleep / wake from the HR-confirmed detector and wear from HR presence, for an optical-pulse metric.
        let heart = PC.SleepWearContext(sleepState: .asleep, sleepEvidence: ["detected_sleep_session"],
                                        sleepDependsOnHeartSignals: true, wearState: .worn,
                                        wearEvidence: ["heart_rate_signal_present"], reasons: [],
                                        wearDependsOnHeartSignals: true)
        let night = PC.Interval(F.t0, F.t0 + 6 * 3600)
        let sleep = verdict(.sleepMeasurement, track: .empty(.strapMotion), sleepWear: heart, support: night)
        XCTAssertEqual(sleep.state, .eligible)
        XCTAssertEqual(sleep.targetDependentGates,
                       [B.signalInvalid, B.gateSleepDetectorHrConfirmation, B.gateWearFromHeartRatePresence])
        // Activity response does not require wear, so HR-presence wear is not one of its gates.
        var awake = heart
        awake.sleepState = .awake
        awake.sleepEvidence = ["outside_detected_sleep"]
        XCTAssertEqual(verdict(.activityResponse, track: quiet, sleepWear: awake).targetDependentGates,
                       [B.signalInvalid, B.gateSleepDetectorHrConfirmation])
        // Skin temperature is not read by the detector or by HR presence: dependence recorded, no gate declared.
        let skin = B.evaluate(.sleepMeasurement, metric: .skinTemperature, support: night, validity: F.validSignal,
                              activity: PC.IntervalAlgebra.composition(over: night, track: .empty(.strapMotion)),
                              preceding: PC.IntervalAlgebra.precedingHistory(before: night.start,
                                                                             track: .empty(.strapMotion),
                                                                             lookbackS: 1800),
                              sleepWear: heart, exertion: [], recentBouts: [], config: .init())
        XCTAssertEqual(skin.targetDependentGates, [B.signalInvalid])
        XCTAssertTrue(skin.dependsOn.contains(B.sleepDetectorUsesHeartRate))
        // No HR-derived evidence: only the validity gate.
        XCTAssertEqual(verdict(track: quiet).targetDependentGates, [B.signalInvalid])
    }

    func testSustainedHighHeartRateBeatsDeclareTheKernelRangeGate() {
        // 230 bpm (261 ms beats, inside the 50–30000 ms contract, outside the 300–2000 ms kernel): validity rejects
        // them as a measurement limit, and the verdict declares that the gate read the target's own beats.
        var beats: [PC.BeatIntervalObservation] = []
        for s in 0..<300 {
            for k in 0..<4 { beats.append(.init(ts: F.t0 + s, rrMs: 261, seq: k, ord: k)) }
        }
        let (o, _) = F.sanitize(F.input(beats: beats))
        let validity = PC.SignalValidityEngine.assess(F.measurement(.hrvRmssd, support), observations: o,
                                                      motion: quiet, config: .init())
        XCTAssertTrue(validity.reasons.contains(PC.SignalValidityEngine.beatsOutsideKernelRange))
        XCTAssertGreaterThan(validity.diagnostic("out_of_range_beats") ?? 0, 0)
        let v = verdict(track: quiet, validity: validity)
        XCTAssertTrue(v.targetDependentGates.contains(B.gateRrKernelRange), "\(v.targetDependentGates)")
        XCTAssertEqual(v.targetDependentGates.first, B.signalInvalid)
    }

    func testEngineDeclaresTheSleepDetectorGateOnNightlyHeartDerivedVerdicts() throws {
        let s = F.dayStart
        let night = PC.SleepSessionInput(id: "n", interval: .init(s, s + 6 * 3600), availableAt: s + 7 * 3600,
                                         sourceDay: F.day, detector: "frwhoop-server-1")
        let span = (s - 3600)..<(s + 8 * 3600)
        var input = F.input(heartRate: span.map { .init(ts: $0, bpm: 55) },
                            beats: span.map { .init(ts: $0, rrMs: $0 % 2 == 0 ? 1080 : 1100) },
                            measurements: [
                                PC.MeasurementInput(metric: .hrvRmssd,
                                                    method: F.method("snapshot.hrv_rmssd.night", aggregation: .session,
                                                                     windowS: 6 * 3600),
                                                    source: .init(product: .scoringSnapshot, key: "daily.hrv"),
                                                    value: 50, support: night.interval, availableAt: s + 7 * 3600),
                            ])
        input.sleepSessions = [night]
        let doc = PC.Engine.buildDay(input, history: .empty)
        let e = try XCTUnwrap(doc.envelopes.first { $0.method.id == "snapshot.hrv_rmssd.night" })
        let v = try XCTUnwrap(e.verdict(.sleepMeasurement))
        XCTAssertTrue(v.targetDependentGates.contains(B.gateSleepDetectorHrConfirmation), "\(v)")
        let row = doc.availability.first { $0.assessment == "sleep_measurement_eligibility" }
        XCTAssertTrue(row?.reasons.contains(PC.SignalValidityEngine.gateSleepDetectorHrConfirmation) ?? false)
        let hrvRow = doc.availability.first { $0.assessment == "hrv_signal_validity" }
        XCTAssertTrue(hrvRow?.reasons.contains(PC.SignalValidityEngine.gateRrKernelRange) ?? false)
        XCTAssertTrue(hrvRow?.reasons.contains(PC.SignalValidityEngine.gateEctopicRejection) ?? false)
    }

    // MARK: Sleep measurement and activity response

    func testSleepMeasurementNeedsASupportedSleepEpisodeNotStaging() {
        let asleep = PC.SleepWearContext(sleepState: .asleep, sleepEvidence: ["detected_sleep_session"],
                                         sleepDependsOnHeartSignals: true, wearState: .worn,
                                         wearEvidence: ["heart_rate_signal_present"], reasons: [])
        let night = PC.Interval(F.t0, F.t0 + 6 * 3600)
        let v = verdict(.sleepMeasurement, track: .empty(.strapMotion), sleepWear: asleep, support: night)
        XCTAssertEqual(v.state, .eligible)
        XCTAssertEqual(v.reasons, [B.insideSupportedSleep])
        XCTAssertTrue(v.dependsOn.contains(B.sleepDetectorUsesHeartRate))
        XCTAssertEqual(verdict(.sleepMeasurement, track: quiet).reasons, [B.notAsleep])
        var mixed = asleep
        mixed.sleepState = .mixed
        XCTAssertEqual(verdict(.sleepMeasurement, track: quiet, sleepWear: mixed).state, .ineligible)
    }

    func testActivityResponseInsideOrAfterABout() {
        let walking = F.track([(F.t0 - 600, F.t0 + 600, "walking")])
        let inside = verdict(.activityResponse, track: walking)
        XCTAssertEqual(inside.state, .eligible)
        XCTAssertEqual(inside.reasons, [B.insideLocomotion])
        let bout = PC.BoutRef(boutId: "b", kind: "walking", endedAt: F.t0 - 600, secondsBeforeMeasurement: 600, durationS: 1200)
        let after = verdict(.activityResponse, track: quiet, bouts: [bout])
        XCTAssertEqual(after.state, .eligible)
        XCTAssertEqual(after.reasons, [B.afterExertionBout])
        let old = PC.BoutRef(boutId: "o", kind: "walking", endedAt: F.t0 - 1200, secondsBeforeMeasurement: 1200, durationS: 600)
        XCTAssertEqual(verdict(.activityResponse, track: quiet, bouts: [old]).reasons, [B.noSupportedExertion])
        XCTAssertEqual(verdict(.activityResponse, track: .empty(.strapMotion)).state, .unknown)
        var asleep = F.awakeWorn
        asleep.sleepState = .asleep
        XCTAssertEqual(verdict(.activityResponse, track: walking, sleepWear: asleep).state, .ineligible)
    }

    // MARK: Selection accounting

    func envelope(_ support: PC.Interval, _ v: PC.EligibilityVerdict) -> PC.MeasurementEnvelope {
        let method = PC.Engine.heartRateWindowMethod
        let empty = PC.ResolvedTrack.empty(.strapMotion)
        return PC.MeasurementEnvelope(
            id: PC.MeasurementEnvelope.makeId(method: method, support: support), metric: .heartRate, method: method,
            source: .init(product: .contextDerived, key: "k"), value: 60, support: support, displayBucket: nil,
            localTime: PC.localTime(at: support.start, timezoneId: "UTC"), validity: F.validSignal, regimeKey: "r",
            activity: PC.IntervalAlgebra.composition(over: support, track: empty), decoderActivity: nil,
            preceding: PC.IntervalAlgebra.precedingHistory(before: support.start, track: empty, lookbackS: 1800),
            sleepWear: .unknown,
            history: .init(wake: .unknown([]), recentBouts: [], exertion: [], exposures: [], exposureCoverage: []),
            eligibility: [v], comparisons: [], finality: .provisional)
    }

    func testSelectionCountsUnionOfEligibleSupportAndRepresentedShareOfObservedTime() {
        let t = F.t0
        let eligible = PC.EligibilityVerdict(comparison: .stableAwakeRest, state: .eligible,
                                             reasons: [B.stableAwakeLowMovement], policyVersion: "p")
        let excluded = PC.EligibilityVerdict(comparison: .stableAwakeRest, state: .ineligible,
                                             reasons: [B.recentLocomotion], policyVersion: "p")
        let unknown = PC.EligibilityVerdict(comparison: .stableAwakeRest, state: .unknown,
                                            reasons: [B.awakeEvidenceUnknown, B.recentLocomotionUnobserved],
                                            policyVersion: "p", notes: [B.recentLocomotionUnobserved])
        let envelopes = [envelope(.init(t, t + 300), eligible), envelope(.init(t + 150, t + 450), eligible),
                         envelope(.init(t + 300, t + 600), excluded), envelope(.init(t + 600, t + 900), unknown)]
        // HR observed every second of [t, t+600) and every other second of [t+600, t+900): 600 + 150 seconds.
        let hr = (0..<600).map { PC.HeartRateObservation(ts: t + $0, bpm: 60) }
            + stride(from: 600, to: 900, by: 2).map { PC.HeartRateObservation(ts: t + $0, bpm: 60) }
        let (o, _) = F.sanitize(F.input(heartRate: hr))
        let s = B.selection(envelopes: envelopes, observations: o, dayWindow: F.identity.dayWindow)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].eligible, 2)
        XCTAssertEqual(s[0].ineligible, 1)
        XCTAssertEqual(s[0].unknown, 1)
        XCTAssertEqual(s[0].eligibleSupportS, 450, "overlapping eligible supports count once")
        XCTAssertEqual(s[0].observedS, 750)
        XCTAssertEqual(s[0].eligibleObservedS, 450)
        XCTAssertEqual(s[0].eligibleShare!, 450.0 / 750.0, accuracy: 1e-12)
        // The two eligible windows overlap (one independent window < the 3 System F needs): nothing entered a
        // reference value, so the represented share is 0 although 60 % of the observed time is eligible.
        XCTAssertEqual(s[0].enteredCount, 0)
        XCTAssertEqual(s[0].enteredObservedS, 0)
        XCTAssertEqual(s[0].representedShare!, 0, accuracy: 1e-12)
        // Only deciding reasons are exclusions; the `recent_locomotion_unobserved` note is not counted.
        XCTAssertEqual(s[0].exclusionReasons.map(\.reason), [B.awakeEvidenceUnknown, B.recentLocomotion])
        XCTAssertTrue(s[0].exclusionReasons.allSatisfy { $0.count == 1 })
    }

    func testSelectionCountsWhatEnteredTheDailyValues() {
        // Five eligible 5-minute HR windows: three valid ones enter `heart_rate.stable_awake_5min`; a degraded one
        // and a 10-minute one are eligible (System B) but System F leaves them out.
        let t = F.t0
        let eligible = PC.EligibilityVerdict(comparison: .stableAwakeRest, state: .eligible,
                                             reasons: [B.stableAwakeLowMovement], policyVersion: "p")
        var envelopes = (0..<4).map { k in envelope(.init(t + k * 300, t + (k + 1) * 300), eligible) }
        envelopes[3].validity = PC.SignalValidity(state: .degraded, reasons: [])
        var long = envelope(.init(t + 1200, t + 1800), eligible)
        long.method = PC.MethodRef(id: "context.heart_rate.10min_mean", algorithmVersion: "x", aggregation: .mean,
                                   windowS: 600, units: "bpm")
        long.id = PC.MeasurementEnvelope.makeId(method: long.method, support: long.support)
        envelopes.append(long)
        let hr = (0..<1800).map { PC.HeartRateObservation(ts: t + $0, bpm: 60) }
        let (o, _) = F.sanitize(F.input(heartRate: hr))
        let s = B.selection(envelopes: envelopes, observations: o, dayWindow: F.identity.dayWindow)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].eligible, 5)
        XCTAssertEqual(s[0].eligibleObservedS, 1800)
        XCTAssertEqual(s[0].eligibleShare!, 1, accuracy: 1e-12)
        XCTAssertEqual(s[0].enteredCount, 3)
        XCTAssertEqual(s[0].enteredSupportS, 900)
        XCTAssertEqual(s[0].enteredObservedS, 900)
        XCTAssertEqual(s[0].representedShare!, 0.5, accuracy: 1e-12)
        // The same accounting from supplied daily values (the engine's), and none for activity response.
        let values = PC.ContextReferences.dailyValues(envelopes: envelopes, identity: F.identity, mode: .retrospective,
                                                      finality: .final, config: .init())
        XCTAssertEqual(B.selection(envelopes: envelopes, observations: o, dayWindow: F.identity.dayWindow,
                                   dailyValues: values), s)
        let response = PC.EligibilityVerdict(comparison: .activityResponse, state: .eligible,
                                             reasons: [B.insideLocomotion], policyVersion: "p")
        let r = B.selection(envelopes: [envelope(.init(t, t + 300), response)], observations: o,
                            dayWindow: F.identity.dayWindow)
        XCTAssertNil(r[0].representedShare, "activity-response series are built from bouts, not envelopes")
        XCTAssertNil(r[0].enteredCount)
        XCTAssertEqual(r[0].eligibleShare!, 300.0 / 1800, accuracy: 1e-12)
    }

    // MARK: Policy sensitivity (spec §8: recheck before changing defaults)

    /// A deterministic synthetic waking day 07:00–20:00 of strap motion: quiet desk time with fidgets whose rate
    /// changes hourly, three walks with step-counter evidence, and a 10-minute disconnection.
    static func syntheticDay() -> (track: PC.ResolvedTrack, windows: [PC.Interval]) {
        let d0 = F.dayStart
        let start = d0 + 7 * 3600, end = d0 + 20 * 3600
        let walks = [PC.Interval(d0 + 9 * 3600, d0 + 9 * 3600 + 1200), PC.Interval(d0 + 12 * 3600 + 1800, d0 + 12 * 3600 + 2700),
                     PC.Interval(d0 + 17 * 3600, d0 + 17 * 3600 + 1800)]
        let gap = PC.Interval(d0 + 14 * 3600, d0 + 14 * 3600 + 600)
        let fidgetRate = [0.001, 0.004, 0.012]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        var motion: [PC.MotionObservation] = []
        var steps: [PC.StepObservation] = []
        var counter = 0
        var fidget = 0
        for ts in start..<end where !gap.contains(ts) {
            let dyn: Double
            if walks.contains(where: { $0.contains(ts) }) {
                dyn = 0.35
                counter = (counter + 2) & 0xFFFF
                steps.append(.init(ts: ts, counter: counter, activityClass: 1))
            } else if fidget > 0 {
                dyn = 0.25; fidget -= 1
            } else {
                if next() < fidgetRate[((ts - start) / 3600) % 3] { fidget = 2 + Int(next() * 5) }
                dyn = 0.003 + 0.002 * next()
            }
            motion.append(.init(ts: ts, dynAccelG: dyn))
        }
        let track = PC.MotionEvidence.strapTrack(motion: motion, steps: steps, window: .init(start, end), config: .init())
        let windows = stride(from: d0 + 8 * 3600, to: end, by: 300).map { PC.Interval($0, $0 + 300) }
        return (track, windows)
    }

    static func eligibleShare(_ day: (track: PC.ResolvedTrack, windows: [PC.Interval]),
                              floor: Double, stillS: Int) -> Double {
        var config = PC.EligibilityConfig()
        config.stationaryFloorShare = floor
        config.minPrecedingStillS = stillS
        let eligible = day.windows.filter { w in
            B.evaluate(.stableAwakeRest, metric: .heartRate, support: w, validity: F.validSignal,
                       activity: PC.IntervalAlgebra.composition(over: w, track: day.track),
                       preceding: PC.IntervalAlgebra.precedingHistory(before: w.start, track: day.track, lookbackS: 1800),
                       sleepWear: F.awakeWorn, exertion: [], recentBouts: [], config: config).state == .eligible
        }.count
        return Double(eligible) / Double(day.windows.count)
    }

    func testStableAwakePolicySensitivitySweep() {
        let day = Self.syntheticDay()
        XCTAssertEqual(day.windows.count, 144)
        let floors = [0.8, 0.9, 0.95]
        let stills = [120, 300, 600]
        var table: [[Double]] = []
        var lines = ["stationary floor \\ preceding still s | " + stills.map(String.init).joined(separator: " | ")]
        for f in floors {
            let row = stills.map { Self.eligibleShare(day, floor: f, stillS: $0) }
            table.append(row)
            lines.append(String(format: "%.2f | ", f) + row.map { String(format: "%.3f", $0) }.joined(separator: " | "))
        }
        print("PC sensitivity (eligible share of 144 synthetic 5-min windows)\n" + lines.joined(separator: "\n"))
        // Stricter policies can only exclude more.
        for i in floors.indices { for j in 1..<stills.count { XCTAssertLessThanOrEqual(table[i][j], table[i][j - 1]) } }
        for j in stills.indices { for i in 1..<floors.count { XCTAssertLessThanOrEqual(table[i][j], table[i - 1][j]) } }
        // Which windows the default excludes, and why (context-selection accounting for the notes).
        var reasonCounts: [String: Int] = [:]
        var stratum: [Int: (eligible: Int, total: Int)] = [:]
        for w in day.windows {
            let v = B.evaluate(.stableAwakeRest, metric: .heartRate, support: w, validity: F.validSignal,
                               activity: PC.IntervalAlgebra.composition(over: w, track: day.track),
                               preceding: PC.IntervalAlgebra.precedingHistory(before: w.start, track: day.track,
                                                                              lookbackS: 1800),
                               sleepWear: F.awakeWorn, exertion: [], recentBouts: [], config: .init())
            let rate = ((w.start - (F.dayStart + 7 * 3600)) / 3600) % 3
            var cur = stratum[rate] ?? (0, 0)
            cur.total += 1
            if v.state == .eligible { cur.eligible += 1 } else { for r in v.reasons { reasonCounts[r.rawValue, default: 0] += 1 } }
            stratum[rate] = cur
        }
        print("PC sensitivity default exclusions: " + reasonCounts.keys.sorted().map { "\($0)=\(reasonCounts[$0]!)" }.joined(separator: ", "))
        print("PC sensitivity default by fidget stratum (0.001/0.004/0.012 per s): " + stratum.keys.sorted().map {
            "\($0): \(stratum[$0]!.eligible)/\(stratum[$0]!.total)" }.joined(separator: ", "))
        // The synthetic day discriminates: the default neither admits nor rejects everything.
        let defaultShare = table[1][1]
        XCTAssertGreaterThan(defaultShare, 0.05)
        XCTAssertLessThan(defaultShare, table[0][0])
    }

    // MARK: Exercise sessions (pc-eligibility-5, rule exercise-session-1's merge and recovery cap)

    func testBoutsAtMostTenMinutesApartAreOneSessionThatExcludesForItsDuration() {
        // Measurement at F.t0. Bout B: 20 min walking ending 15 min before; bout A: 20 min walking before it.
        func ref(_ id: String, minutes: Int, endedMinutesAgo: Int, kind: String = "walking") -> PC.BoutRef {
            PC.BoutRef(boutId: id, kind: kind, endedAt: F.t0 - endedMinutesAgo * 60,
                       secondsBeforeMeasurement: endedMinutesAgo * 60, durationS: minutes * 60)
        }
        let b = ref("b", minutes: 20, endedMinutesAgo: 15)
        // 11 minutes apart (A ends 46 min before): two 20-minute sessions, the 10-minute floor only.
        let apart = [ref("a", minutes: 20, endedMinutesAgo: 46), b]
        let s11 = PC.ExertionBouts.sessions(apart, mergeGapS: 600)
        XCTAssertEqual(s11.map(\.boutIds), [["a"], ["b"]])
        let v11 = verdict(track: quiet, bouts: apart)
        XCTAssertEqual(v11.state, .eligible, "\(v11.reasons)")
        XCTAssertNil(v11.evidence("exertion_session_s"))
        // 10 minutes apart (A ends 45 min before): one session from 65 to 15 min before = 50 min, so 50 min.
        let close = [b, ref("a", minutes: 20, endedMinutesAgo: 45)]
        let s10 = PC.ExertionBouts.sessions(close, mergeGapS: 600)
        XCTAssertEqual(s10, [PC.BoutSession(startedAt: F.t0 - 65 * 60, endedAt: F.t0 - 15 * 60,
                                            secondsBeforeMeasurement: 15 * 60, boutIds: ["a", "b"])])
        let v10 = verdict(track: quiet, bouts: close)
        XCTAssertEqual(v10.state, .ineligible)
        XCTAssertEqual(v10.reasons, [B.recentExertionBout])
        XCTAssertEqual(v10.evidence("exertion_session_s"), 3000)
        XCTAssertEqual(v10.evidence("seconds_since_exertion_session"), 900)
        XCTAssertEqual(v10.evidence("post_bout_exclusion_s"), 3000)
        // The same session ended 51 minutes before the measurement: past its 50 minutes.
        let later = [ref("b", minutes: 20, endedMinutesAgo: 51), ref("a", minutes: 20, endedMinutesAgo: 81)]
        XCTAssertEqual(verdict(track: quiet, bouts: later).state, .eligible)
        // Overlapping bouts are one session too (in start order, then end: y [40, 30), x [40, 10) min before).
        let overlap = PC.ExertionBouts.sessions([ref("x", minutes: 30, endedMinutesAgo: 10),
                                                 ref("y", minutes: 10, endedMinutesAgo: 30)], mergeGapS: 600)
        XCTAssertEqual(overlap.map(\.boutIds), [["y", "x"]])
        XCTAssertEqual(overlap.first?.durationS, 1800)
        XCTAssertEqual(overlap.first?.secondsBeforeMeasurement, 600)
        // Disabled sessions leave the per-bout doses only.
        var off = PC.EligibilityConfig()
        off.sessionExclusionMaxS = 0
        XCTAssertEqual(verdict(track: quiet, bouts: close, config: off).state, .eligible)
    }

    func testSessionExclusionIsItsDurationClampedToThirtyToOneHundredTwentyMinutes() {
        func session(minutes: Int) -> PC.BoutSession {
            PC.BoutSession(startedAt: F.t0 - minutes * 60, endedAt: F.t0, secondsBeforeMeasurement: 0, boutIds: ["s"])
        }
        let c = PC.EligibilityConfig()
        XCTAssertEqual(B.postSessionExclusionS(session(minutes: 29), c), 0, "under 30 min: the bouts' own doses")
        XCTAssertEqual(B.postSessionExclusionS(session(minutes: 30), c), 1800)
        XCTAssertEqual(B.postSessionExclusionS(session(minutes: 60), c), 3600)
        XCTAssertEqual(B.postSessionExclusionS(session(minutes: 103), c), 6180)
        XCTAssertEqual(B.postSessionExclusionS(session(minutes: 150), c), 7200, "capped at 120 min")
        // The session parameters are part of the policy fingerprint.
        for edit in [{ (p: inout PC.Policy) in p.eligibility.sessionMergeGapS += 60 },
                     { $0.eligibility.sessionMinDurationS += 60 }, { $0.eligibility.sessionExclusionMinS += 60 },
                     { $0.eligibility.sessionExclusionMaxS += 60 }] {
            var p = PC.Policy.default
            edit(&p)
            XCTAssertNotEqual(p.fingerprint, PC.Policy.default.fingerprint)
        }
        // A short single walk keeps the 10-minute floor.
        let walk = PC.BoutRef(boutId: "w", kind: "walking", endedAt: F.t0 - 660, secondsBeforeMeasurement: 660,
                              durationS: 600)
        XCTAssertEqual(verdict(track: quiet, bouts: [walk]).state, .eligible)
        var nine = walk
        nine.endedAt = F.t0 - 540
        nine.secondsBeforeMeasurement = 540
        XCTAssertEqual(verdict(track: quiet, bouts: [nine]).reasons, [B.recentExertionBout])
        XCTAssertNil(verdict(track: quiet, bouts: [nine]).evidence("exertion_session_s"))
        // The longer of a bout's dose and its session's exclusion wins: a 40-minute run is a 40-minute session
        // but keeps its 60-minute running dose.
        let run = PC.BoutRef(boutId: "r", kind: "running", endedAt: F.t0 - 50 * 60, secondsBeforeMeasurement: 50 * 60,
                             durationS: 40 * 60)
        let v = verdict(track: quiet, bouts: [run])
        XCTAssertEqual(v.state, .ineligible)
        XCTAssertEqual(v.evidence("post_bout_exclusion_s"), 3600)
        XCTAssertNil(v.evidence("exertion_session_s"), "the 40-minute session alone no longer excludes at 50 min")
    }

    /// The owner's 2026-10-07 evening (PDT): stepping 21:21-21:25, a walk 21:30-21:35, 66 minutes of gym cardio
    /// read as mixed_locomotion 21:45-22:51, the walk home 23:00-23:04. Under pc-eligibility-4 the mixed bout got
    /// the 600 s floor and stable awake rest at 00:40-01:00 was eligible (86-91 bpm in production, audit A). The
    /// bouts are detected from the strap track here, as the engine does.
    func testOwnerGymEveningIsOneSessionAndRestStaysExcludedUntilItsRecoveryCap() throws {
        let tz = "America/Los_Angeles"
        let identity = PC.DayIdentity(deviceScope: "dev-owner", day: "2026-10-07", timezoneId: tz,
                                      dayWindow: PC.Engine.dayInterval("2026-10-07", timezoneId: tz))
        let d0 = identity.dayWindow.start
        XCTAssertEqual(d0, 1_791_356_400, "2026-10-07 00:00 PDT (UTC-7)")
        func at(_ h: Int, _ m: Int) -> Int { d0 + h * 3600 + m * 60 }
        var spans: [(Int, Int, String?)] = [(at(20, 0), at(21, 21), "still"), (at(21, 21), at(21, 25), "stepping"),
                                            (at(21, 25), at(21, 30), "still"), (at(21, 30), at(21, 35), "walking"),
                                            (at(21, 35), at(21, 45), "still")]
        for k in 0..<11 {   // 21:45-22:51: 3 min walking, 3 min stepping (neither holds 80 %: mixed_locomotion)
            spans.append((at(21, 45) + k * 360, at(21, 45) + k * 360 + 180, "walking"))
            spans.append((at(21, 45) + k * 360 + 180, at(21, 45) + (k + 1) * 360, "stepping"))
        }
        spans += [(at(22, 51), at(23, 0), "still"), (at(23, 0), at(23, 4), "walking"), (at(23, 4), at(27, 30), "still")]
        let track = F.track(spans)
        let bouts = PC.ExertionBouts.detect(identity: identity, hart: .empty(.hartEpochs), strap: track, workouts: [],
                                            observations: PC.SanitizedObservations(heartRate: [], steps: [], breaks: []),
                                            mode: .retrospective, cutoff: identity.dayWindow.end + 40 * 3600,
                                            config: .init())
        XCTAssertEqual(bouts.map(\.interval), [.init(at(21, 21), at(21, 25)), .init(at(21, 30), at(21, 35)),
                                               .init(at(21, 45), at(22, 51)), .init(at(23, 0), at(23, 4))])
        XCTAssertEqual(bouts.map(\.kind), ["stepping", "walking", "mixed_locomotion", "walking"])

        func verdict(_ support: PC.Interval, config: PC.EligibilityConfig = .init()) -> PC.EligibilityVerdict {
            B.evaluate(.stableAwakeRest, metric: .heartRate, support: support, validity: F.validSignal,
                       activity: PC.IntervalAlgebra.composition(over: support, track: track),
                       preceding: PC.IntervalAlgebra.precedingHistory(before: support.start, track: track,
                                                                      lookbackS: 1800),
                       sleepWear: F.awakeWorn, exertion: [],
                       recentBouts: PC.ExertionBouts.recentRefs(before: support.start, bouts: bouts, config: .init()),
                       config: config)
        }
        // 00:40-01:00: 96 minutes after the session (21:21-23:04, 103 min) ended, inside its 103-minute exclusion.
        let night = PC.Interval(at(24, 40), at(25, 0))
        let v = verdict(night)
        XCTAssertEqual(v.state, .ineligible)
        XCTAssertEqual(v.reasons, [B.recentExertionBout])
        XCTAssertEqual(v.evidence("exertion_session_s"), 103 * 60)
        XCTAssertEqual(v.evidence("seconds_since_exertion_session"), 96 * 60)
        XCTAssertEqual(v.evidence("post_bout_exclusion_s"), 103 * 60)
        XCTAssertEqual(v.policyVersion, "pc-eligibility-5")
        // pc-eligibility-4 (no sessions): the leak this closes.
        var v4 = PC.EligibilityConfig()
        v4.sessionExclusionMaxS = 0
        XCTAssertEqual(verdict(night, config: v4).state, .eligible)
        // Every 5-minute support from the walk home to 00:47 is excluded; 00:50 is past the cap again.
        for m in stride(from: 15, to: 100, by: 5) {
            let s = PC.Interval(at(23, 4) + m * 60, at(23, 4) + m * 60 + 300)
            XCTAssertEqual(verdict(s).state, .ineligible, "+\(m) min")
        }
        XCTAssertEqual(verdict(PC.Interval(at(23, 4) + 104 * 60, at(23, 4) + 109 * 60)).state, .eligible)
        // 02:30-02:50: long after the exclusion.
        XCTAssertEqual(verdict(PC.Interval(at(26, 30), at(26, 50))).state, .eligible)
    }
}

/// Stable awake rest: postural settling after a decoder transition event, the source's confidence floor and the
/// per-epoch wear-signal quality (D5-07, D3-06, D3-10, D3-11 / D6-15).
final class PCEligibilityContextTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias F = PCSignalFixtures
    typealias B = PhysiologyContext.Eligibility

    var support: PC.Interval { PC.Interval(F.t0, F.t0 + 300) }
    var quiet: PC.ResolvedTrack { F.track([(F.t0 - 1800, F.t0 + 600, "still")]) }
    /// Decoder document coverage of the whole neighbourhood (the runs the events come from).
    var decoderCoverage: PC.ResolvedTrack {
        F.track([(F.t0 - 3600, F.t0 + 3600, "sitting")], source: .decoderIntervals, heartRateDependent: true)
    }

    func settling(_ events: [PC.TransitionEventInput], coverage: PC.ResolvedTrack? = nil,
                  config: PC.EligibilityConfig = .init()) -> PC.TransitionEventSummary? {
        PC.TransitionEvents.summary(PC.TransitionEvents.prepare(events, causalCutoff: nil),
                                    over: PC.Interval(support.start - config.posturalSettlingS, support.end),
                                    coverage: coverage ?? decoderCoverage)
    }

    func verdict(_ metric: PC.MetricKind = .hrvRmssd, track: PC.ResolvedTrack? = nil,
                 settling: PC.TransitionEventSummary? = nil, wear: PC.WearSignalSummary? = nil,
                 config: PC.EligibilityConfig = .init()) -> PC.EligibilityVerdict {
        let t = track ?? quiet
        return B.evaluate(.stableAwakeRest, metric: metric, support: support, validity: F.validSignal,
                          activity: PC.IntervalAlgebra.composition(over: support, track: t),
                          preceding: PC.IntervalAlgebra.precedingHistory(before: support.start, track: t, lookbackS: 1800),
                          sleepWear: F.awakeWorn, exertion: [], recentBouts: [], config: config,
                          settlingTransitions: settling, wearSignal: wear)
    }

    func event(_ offset: Int, _ kind: ActivityTransitionKind = .sitToStandLike, p: Double = 0.8) -> PC.TransitionEventInput {
        PC.TransitionEventInput(ts: F.t0 + offset, kind: kind.rawValue, probability: p, revision: 1)
    }

    func testPosturalTransitionInTheSupportOrItsSettlingTimeExcludes() {
        // A 10-s stand 60 s before the support: inside the 120-s settling window.
        let before = verdict(settling: settling([event(-60), event(-50, .standToSitLike)]))
        XCTAssertEqual(before.state, .ineligible)
        XCTAssertEqual(before.reasons.first, B.recentPosturalTransition)
        XCTAssertEqual(before.evidence("postural_transitions_settling"), 2)
        // Inside the support itself.
        XCTAssertEqual(verdict(settling: settling([event(150)])).state, .ineligible)
        // A weaker event: whether the posture changed is undetermined.
        let weak = verdict(settling: settling([event(-30, p: 0.3)]))
        XCTAssertEqual(weak.state, .unknown)
        XCTAssertEqual(weak.reasons.first, B.possiblePosturalTransition)
        // Outside the settling window (200 s before) or at the support end: no effect.
        let older = verdict(settling: settling([event(-200), event(300)]))
        XCTAssertEqual(older.state, .eligible, "\(older.reasons)")
        // Locomotion events are not postural (locomotion is gated by the activity track).
        XCTAssertEqual(verdict(settling: settling([event(-60, .walkStop)])).state, .eligible)
    }

    /// The settling gate counts an event over its span `[onsetTs ?? ts, ts]` (INT-C / D2-05), so both window edges
    /// stay conservative: a change that began inside the support but was flagged a few seconds after it still
    /// excludes, and an onset earlier than the settling window never loosens an event flagged inside it (settling
    /// runs from when the change finished, at or after detection).
    func testSettlingCountsTheEventFromItsOnsetToItsDetection() {
        func onset(_ ts: Int, _ onset: Int?) -> PC.TransitionEventInput {
            PC.TransitionEventInput(ts: F.t0 + ts, kind: ActivityTransitionKind.standToSitLike.rawValue,
                                    probability: 0.8, revision: 1, onsetTs: onset.map { F.t0 + $0 }, source: "hsmm")
        }
        // Flagged 3 s after the support ends, began 4 s before it ends.
        XCTAssertEqual(verdict(settling: settling([onset(303, nil)])).state, .eligible)
        XCTAssertEqual(verdict(settling: settling([onset(303, 296)])).state, .ineligible)
        // Flagged 3 s after the support ends and began after it too: outside the window.
        XCTAssertEqual(verdict(settling: settling([onset(303, 301)])).state, .eligible)
        // Flagged 115 s before the support (inside the 120-s settling window): excludes whatever its onset.
        XCTAssertEqual(verdict(settling: settling([onset(-115, nil)])).state, .ineligible)
        XCTAssertEqual(verdict(settling: settling([onset(-115, -125)])).state, .ineligible)
        // Flagged before the settling window: outside it, whatever its onset.
        XCTAssertEqual(verdict(settling: settling([onset(-121, -126)])).state, .eligible)
        // Among several events the span scan still finds one that began before the window ends.
        XCTAssertEqual(verdict(settling: settling([onset(-500, nil), onset(301, 301), onset(305, 299),
                                                   onset(400, nil)])).state, .ineligible)
        // An onset is never after the detection second, nor more than maxOnsetLeadS before it.
        XCTAssertEqual(onset(50, 60).changeTs, F.t0 + 50)
        XCTAssertEqual(onset(50, -500).changeTs, F.t0 + 50 - ActivityTransitionEvent.maxOnsetLeadS)
        // "Seconds since the last postural transition" is measured from detection, never overstated by the onset.
        var activity = PC.IntervalAlgebra.composition(over: support, track: quiet)
        var preceding = PC.IntervalAlgebra.precedingHistory(before: support.start, track: quiet, lookbackS: 1800)
        PC.TransitionEvents.annotate(&activity, &preceding, support: support,
                                     events: PC.TransitionEvents.prepare([onset(-30, -38)], causalCutoff: nil),
                                     coverage: decoderCoverage)
        XCTAssertEqual(preceding.secondsSinceLastPosturalTransition, 30)
        // A change that began inside the support but was flagged after it is counted during the support.
        PC.TransitionEvents.annotate(&activity, &preceding, support: support,
                                     events: PC.TransitionEvents.prepare([onset(303, 296)], causalCutoff: nil),
                                     coverage: decoderCoverage)
        XCTAssertEqual(activity.transitionEvents?.postural, 1)
        // Causal availability is still the detection second: flagged after the cutoff, it is not known yet.
        XCTAssertTrue(PC.TransitionEvents.prepare([onset(303, 296)], causalCutoff: F.t0 + 300).isEmpty)
    }

    /// The new fields are optional on the wire: an input stored before them decodes, and nil fields are not
    /// written (so an input without them keeps its fingerprint).
    func testTransitionEventInputOnsetAndSourceAreOptionalOnTheWire() throws {
        let old = #"{"ts":100,"kind":"walk_start","probability":0.5,"revision":2}"#
        let decoded = try JSONDecoder().decode(PC.TransitionEventInput.self, from: Data(old.utf8))
        XCTAssertNil(decoded.onsetTs)
        XCTAssertNil(decoded.source)
        XCTAssertEqual(decoded.changeTs, 100)
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(encoded.contains("onsetTs") || encoded.contains("source"), encoded)
        let full = PC.TransitionEventInput(ts: 100, kind: "walk_start", probability: 0.5, revision: 2, onsetTs: 95,
                                           source: "transition_expert")
        XCTAssertEqual(try JSONDecoder().decode(PC.TransitionEventInput.self, from: JSONEncoder().encode(full)), full)
    }

    func testTransitionGateIsDeclaredHeartRateDependentAndUnobservedEventsGateNothing() {
        let hr = verdict(.heartRate, settling: settling([]))
        XCTAssertEqual(hr.state, .eligible)
        XCTAssertTrue(hr.targetDependentGates.contains(B.gateDecoderTransitionEvents), "\(hr.targetDependentGates)")
        XCTAssertTrue(hr.dependsOn.contains(B.transitionEventsReadHeartRate))
        // No decoder document over the window: nil summary, nothing recorded (older days stay as they were).
        let none = verdict(.heartRate, settling: nil)
        XCTAssertEqual(none.state, .eligible)
        XCTAssertEqual(none.targetDependentGates, [B.signalInvalid])
        XCTAssertFalse(none.reasons.contains(B.transitionEventsPartlyObserved))
        // A document covering only part of the window: "no event" is recorded as partly observed, not gated.
        let partial = PC.IntervalAlgebra.resolve(
            [PC.LabelRecord(interval: .init(F.t0 + 100, F.t0 + 300), label: "sitting", tieBreak: "p")],
            source: .decoderIntervals, heartRateDependent: true)
        let p = verdict(settling: settling([], coverage: partial))
        XCTAssertEqual(p.state, .eligible)
        XCTAssertTrue(p.notes.contains(B.transitionEventsPartlyObserved))
    }

    func testLowSourceConfidenceMakesStillnessUndetermined() {
        func hart(_ confidence: Double) -> PC.ResolvedTrack {
            PC.IntervalAlgebra.resolve([PC.LabelRecord(interval: .init(F.t0 - 1800, F.t0 + 600), label: "stationary",
                                                       tieBreak: "h", confidence: confidence)],
                                       source: .hartEpochs, heartRateDependent: false)
        }
        let low = verdict(track: hart(0.3))
        XCTAssertEqual(low.state, .unknown)
        XCTAssertEqual(low.reasons, [B.lowActivityConfidence])
        XCTAssertEqual(low.evidence("activity_mean_confidence"), 0.3)
        XCTAssertEqual(verdict(track: hart(0.9)).state, .eligible)
    }

    func testPostBoutExclusionScalesWithTheBoutsDose() {
        func bout(_ kind: String, minutes: Int, endedMinutesAgo: Int) -> PC.BoutRef {
            PC.BoutRef(boutId: "\(kind)\(minutes)", kind: kind, endedAt: F.t0 - endedMinutesAgo * 60,
                       secondsBeforeMeasurement: endedMinutesAgo * 60, durationS: minutes * 60)
        }
        func state(_ bouts: [PC.BoutRef]) -> PC.EligibilityState {
            B.evaluate(.stableAwakeRest, metric: .heartRate, support: support, validity: F.validSignal,
                       activity: PC.IntervalAlgebra.composition(over: support, track: quiet),
                       preceding: PC.IntervalAlgebra.precedingHistory(before: support.start, track: quiet, lookbackS: 1800),
                       sleepWear: F.awakeWorn, exertion: [], recentBouts: bouts, config: .init()).state
        }
        // A short walk: the fixed 10-minute floor, as before.
        XCTAssertEqual(state([bout("walking", minutes: 15, endedMinutesAgo: 9)]), .ineligible)
        XCTAssertEqual(state([bout("walking", minutes: 15, endedMinutesAgo: 11)]), .eligible)
        // A 70-minute walk is light as a bout (the floor only), but it is also a 70-minute session, which excludes
        // for its duration (pc-eligibility-5): bouts carry no intensity, and a gym session can look like this.
        XCTAssertEqual(state([bout("walking", minutes: 70, endedMinutesAgo: 11)]), .ineligible)
        XCTAssertEqual(state([bout("walking", minutes: 70, endedMinutesAgo: 69)]), .ineligible)
        XCTAssertEqual(state([bout("walking", minutes: 70, endedMinutesAgo: 71)]), .eligible)
        XCTAssertEqual(B.postBoutExclusionS(bout("walking", minutes: 120, endedMinutesAgo: 0), .init()), 600)
        // A 40-minute run: 60 minutes; a 75-minute run: 90 minutes.
        XCTAssertEqual(state([bout("running", minutes: 40, endedMinutesAgo: 45)]), .ineligible)
        XCTAssertEqual(state([bout("running", minutes: 40, endedMinutesAgo: 61)]), .eligible)
        XCTAssertEqual(state([bout("running", minutes: 75, endedMinutesAgo: 80)]), .ineligible)
        // An older long run still excludes after a later short walk that no longer does.
        XCTAssertEqual(state([bout("walking", minutes: 5, endedMinutesAgo: 15),
                              bout("running", minutes: 75, endedMinutesAgo: 80)]), .ineligible)
        XCTAssertEqual(B.postBoutExclusionS(bout("workout", minutes: 30, endedMinutesAgo: 0), .init()), 1800)
        // The floor still disables everything.
        var off = PC.EligibilityConfig()
        off.postBoutExclusionS = 0
        XCTAssertEqual(B.evaluate(.stableAwakeRest, metric: .heartRate, support: support, validity: F.validSignal,
                                  activity: PC.IntervalAlgebra.composition(over: support, track: quiet),
                                  preceding: PC.IntervalAlgebra.precedingHistory(before: support.start, track: quiet,
                                                                                 lookbackS: 1800),
                                  sleepWear: F.awakeWorn, exertion: [],
                                  recentBouts: [bout("running", minutes: 75, endedMinutesAgo: 5)], config: off).state,
                       .eligible)
    }

    func testPoorWearSignalMakesTheSupportUnknown() {
        func wear(_ state: WearSignalState, seconds: Int) -> PC.WearSignalSummary? {
            let epochs = [
                PC.ActivityEpochInput(epoch: ActivityEpoch(startTs: F.t0, endTs: F.t0 + 300 - seconds, motion: .stationary,
                                                           posture: .unknown, exercise: .unknown, sleepState: .unknown,
                                                           exertion: .unknown, wear: .onWrist, wearSignal: .onWristGood,
                                                           confidence: 0.9, observedS: 300 - seconds,
                                                           validS: 300 - seconds), revision: 1),
                PC.ActivityEpochInput(epoch: ActivityEpoch(startTs: F.t0 + 300 - seconds, endTs: F.t0 + 300,
                                                           motion: .stationary, posture: .unknown, exercise: .unknown,
                                                           sleepState: .unknown, exertion: .unknown, wear: .onWrist,
                                                           wearSignal: state, confidence: 0.9, observedS: seconds,
                                                           validS: seconds), revision: 1),
            ]
            return PC.WearSignal.summary(over: support, track: PC.WearSignal.track(epochs))
        }
        for state in [WearSignalState.onWristLoose, .motionArtifact, .sensorDropout, .offWrist] {
            let w = wear(state, seconds: 30)
            XCTAssertEqual(w?.poorS, 30)
            let v = verdict(.hrvRmssd, wear: w)
            XCTAssertEqual(v.state, .unknown, "\(state)")
            XCTAssertEqual(v.reasons, [B.wearSignalPoor], "\(state)")
            XCTAssertTrue(v.targetDependentGates.contains(B.gateWearSignalOpticalQuality))
        }
        let good = verdict(.hrvRmssd, wear: wear(.onWristGood, seconds: 30))
        XCTAssertEqual(good.state, .eligible)
        // A tolerance can be configured (default: any poor second).
        var lenient = PC.EligibilityConfig()
        lenient.wearSignalPoorMaxShare = 0.2
        XCTAssertEqual(verdict(.hrvRmssd, wear: wear(.onWristLoose, seconds: 30), config: lenient).state, .eligible)
    }
}
