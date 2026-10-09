import Foundation
import XCTest
@testable import StrandAnalytics

/// spec-02 respiratory context (docs/spec-02/CONTRACT.md §5.2, §5.5, §6): post-exertion respiratory return with
/// censoring, the explicit stable-awake respiratory adapter, nightly respiratory-rate references that never see the
/// target night or later, policy versioning, wire round trips, and the Python → Swift decoder fixture. Expected
/// values are worked out by hand from the piecewise fixtures in the comments.
final class PCRespiratoryContextTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias Ref = PhysiologyContext.ContextReferences
    typealias Bouts = PhysiologyContext.ExertionBouts

    static let day = "2026-10-01"
    static let identity = PC.DayIdentity(deviceScope: "dev-1", day: day, timezoneId: "UTC",
                                         dayWindow: PC.Engine.dayInterval(day, timezoneId: "UTC"))
    static var t0: Int { identity.dayWindow.start + 10 * 3600 }
    static var end: Int { t0 + 600 }
    static var retroCutoff: Int { identity.dayWindow.end + 40 * 3600 }

    // MARK: Fixtures

    static func track(_ segs: [(Int, Int, String?)]) -> PC.ResolvedTrack {
        PC.IntervalAlgebra.resolve(segs.enumerated().map { i, s in
            PC.LabelRecord(interval: .init(s.0, s.1), label: s.2, tieBreak: "r\(i)")
        }, source: .strapMotion, heartRateDependent: false)
    }

    /// Still 30 min, stepping [t0, end), then `after` (default: still for an hour).
    static func standardTrack(after: [(Int, Int, String?)]? = nil) -> PC.ResolvedTrack {
        track([(t0 - 1800, t0, "still"), (t0, end, "stepping")] + (after ?? [(end, end + 3600, "still")]))
    }

    static func heart() -> [PC.HeartRateObservation] {
        ((t0 - 1800)..<(end + 3000)).map { PC.HeartRateObservation(ts: $0, bpm: $0 < t0 ? 70 : ($0 < end ? 110 : 75)) }
    }

    /// A `series.resp_rate.2min` estimate for minute `b`: support `[b - 60, b + 60)` (ContextInputs).
    static func rr(_ b: Int, _ bpm: Double, method: String = "series.resp_rate.2min") -> PC.MeasurementInput {
        PC.MeasurementInput(metric: .respiratoryRate,
                            method: PC.MethodRef(id: method, algorithmVersion: "t", aggregation: .window,
                                                 windowS: 120, units: "breaths_per_min"),
                            source: PC.SourceRef(product: .metricSeries, key: "resp_rate_bpm@\(b)"), value: bpm,
                            support: .init(b - 60, b + 60))
    }

    /// Pre-bout reference: minutes b in [t0 - 840, t0 - 60] → supports inside [t0 - 900, t0), all 14 br/min.
    static func preBout(_ bpm: Double = 14) -> [PC.MeasurementInput] {
        stride(from: t0 - 840, through: t0 - 60, by: 60).map { rr($0, bpm) }
    }

    /// Post-bout minutes b in [end + 60, end + 1080], value by support-end offset.
    static func post(_ f: (Int) -> Double) -> [PC.MeasurementInput] {
        stride(from: end + 60, through: end + 1080, by: 60).map { rr($0, f($0 + 60 - end)) }
    }

    static func detect(strap: PC.ResolvedTrack = standardTrack(), respiration: [PC.MeasurementInput],
                       cutoff: Int? = nil, mode: PC.ProcessingMode = .retrospective,
                       config: PC.ExertionConfig = .init()) -> [PC.ExertionBout] {
        Bouts.detect(identity: identity, hart: .empty(.hartEpochs), strap: strap, workouts: [],
                     observations: PC.SanitizedObservations(heartRate: heart()), mode: mode,
                     cutoff: cutoff ?? retroCutoff, config: config, respiration: respiration)
    }

    static func recovery(_ bouts: [PC.ExertionBout], _ i: Int = 0) throws -> PC.RespiratoryRecovery {
        try XCTUnwrap(XCTUnwrap(bouts[i].recovery).respiratoryRecovery)
    }

    // MARK: Post-exertion respiratory return

    func testReturnIsIntervalCensoredBetweenLastAboveAndFirstConfirmedWithin() throws {
        // Above (20) through support-end offset 420, then 14.5 (|0.5| <= 2) from offset 480 on. The first within
        // estimate [end+360, end+480) is confirmed by [end+480, end+600) (gap 0).
        let bouts = Self.detect(respiration: Self.preBout() + Self.post { $0 <= 420 ? 20 : 14.5 })
        XCTAssertEqual(bouts.count, 1)
        let r = try Self.recovery(bouts)
        XCTAssertEqual(r.method, "pc-resp-recovery-1")
        XCTAssertEqual(r.state, "returned")
        XCTAssertEqual(r.referenceBpm, 14)
        XCTAssertEqual(r.referenceWindow, .init(Self.t0 - 900, Self.t0))
        XCTAssertEqual(r.referenceSamples, 14)              // b = t0-840 ... t0-60
        XCTAssertEqual(r.referenceIndependentEstimates, 7)  // non-overlapping 120 s supports
        XCTAssertEqual(r.motionSubsidedAt, Self.end)
        XCTAssertEqual(r.firstObservationOffsetS, 120)
        XCTAssertEqual(r.lastAboveOffsetS, 420)
        XCTAssertEqual(r.returnedAtOffsetS, 480)
        XCTAssertNil(r.returnedByOffsetS)
        XCTAssertEqual(r.toleranceBpm, 2)
        XCTAssertEqual(r.units, "breaths_per_min")
        XCTAssertEqual(r.censoring, [])
        XCTAssertEqual(r.followUp, .init(Self.end, Self.end + 1200))
        XCTAssertEqual(r.observations.count, 18)
        XCTAssertEqual(r.observations.first?.aboveReferenceBpm, 6)
        XCTAssertEqual(r.reasons, [Bouts.respiratoryObservationsResumed])
        let channel = try XCTUnwrap(bouts[0].recovery).respiratory
        XCTAssertEqual(channel.state, .supported)
    }

    func testAlreadyWithinAtFirstObservationIsAnUpperBoundNeverAnExactTime() throws {
        let r = try Self.recovery(Self.detect(respiration: Self.preBout() + Self.post { _ in 15.5 }))
        XCTAssertEqual(r.state, "returned_by")
        XCTAssertEqual(r.returnedByOffsetS, 120)
        XCTAssertNil(r.returnedAtOffsetS)
        XCTAssertNil(r.lastAboveOffsetS)
        XCTAssertTrue(r.reasons.contains(Bouts.respiratoryReturnedByFirstObservation))
    }

    func testLateSubsidenceLeavesTheEarlyRecoveryUnknown() throws {
        // Fidgeting for 300 s after the walk: estimates overlapping it are never read (the estimator would have
        // withheld them; here they are supplied and must still be ignored). Observation starts at subsidence.
        let strap = Self.standardTrack(after: [(Self.end, Self.end + 300, "fidgeting"),
                                               (Self.end + 300, Self.end + 3600, "still")])
        let r = try Self.recovery(Self.detect(strap: strap, respiration: Self.preBout() + Self.post { _ in 14 }))
        XCTAssertEqual(r.motionSubsidedAt, Self.end + 300)
        XCTAssertEqual(r.state, "returned_by")
        XCTAssertEqual(r.firstObservationOffsetS, 420)  // first support [end+300, end+420)
        XCTAssertEqual(r.returnedByOffsetS, 420)
        XCTAssertTrue(r.observations.allSatisfy { $0.offsetS >= 420 })
    }

    func testNotReturnedIsRightCensoredAtTheFollowUpEnd() throws {
        let r = try Self.recovery(Self.detect(respiration: Self.preBout() + Self.post { _ in 20 }))
        XCTAssertEqual(r.state, "not_returned")
        XCTAssertEqual(r.reasons, [Bouts.respiratoryObservationsResumed, Bouts.respiratoryNotReturnedInFollowUp])
        XCTAssertNil(r.returnedAtOffsetS)
        XCTAssertNil(r.returnedByOffsetS)
    }

    func testNextBoutTruncatesTheFollowUpAndMovingEstimatesAreIgnored() throws {
        // A second walk at [end+300, end+900): the follow-up stops at its start (next_bout). An estimate during
        // the walk at the reference value must not count as a return.
        let strap = Self.standardTrack(after: [(Self.end, Self.end + 300, "still"),
                                               (Self.end + 300, Self.end + 900, "walking"),
                                               (Self.end + 900, Self.end + 4000, "still")])
        let during = Self.rr(Self.end + 600, 14)
        let bouts = Self.detect(strap: strap, respiration: Self.preBout() + Self.post { _ in 20 } + [during])
        XCTAssertEqual(bouts.count, 2)
        let r = try Self.recovery(bouts, 0)
        XCTAssertEqual(r.censoring, [Bouts.censorNextBout])
        XCTAssertEqual(r.followUp, .init(Self.end, Self.end + 300))
        XCTAssertEqual(r.observations.map(\.offsetS), [120, 180, 240, 300])
        XCTAssertEqual(r.state, "not_returned")
        // The second bout's reference window would lie inside the first bout's respiratory follow-up: no result.
        let second = try Self.recovery(bouts, 1)
        XCTAssertEqual(second.state, "unknown")
        XCTAssertEqual(second.reasons, [Bouts.respiratoryReferenceUnavailable])
        XCTAssertNil(second.referenceBpm)
        XCTAssertEqual(second.observations, [])
    }

    func testNoReferenceGivesNoResult() throws {
        let bouts = Self.detect(respiration: Self.post { _ in 14 })
        let r = try Self.recovery(bouts)
        XCTAssertEqual(r.state, "unknown")
        XCTAssertEqual(r.reasons, [Bouts.respiratoryReferenceUnavailable])
        XCTAssertNil(r.referenceBpm)
        XCTAssertEqual(r.observations, [])
        XCTAssertNil(r.returnedAtOffsetS)
        XCTAssertNil(r.returnedByOffsetS)
        XCTAssertEqual(r.referenceIndependentEstimates, 0)
        let channel = try XCTUnwrap(bouts[0].recovery).respiratory
        XCTAssertEqual(channel.state, .unavailable)
        XCTAssertEqual(channel.reasons, [Bouts.respiratoryReferenceUnavailable])
        // A single pre-bout estimate is not enough support either.
        let one = try Self.recovery(Self.detect(respiration: [Self.rr(Self.t0 - 60, 14)] + Self.post { _ in 14 }))
        XCTAssertEqual(one.reasons, [Bouts.respiratoryReferenceUnavailable])
    }

    func testMovementThatNeverSubsidesLeavesTheReturnUnobserved() throws {
        let strap = Self.standardTrack(after: [(Self.end, Self.end + 3600, "fidgeting")])
        let r = try Self.recovery(Self.detect(strap: strap, respiration: Self.preBout() + Self.post { _ in 14 }))
        XCTAssertEqual(r.state, "unknown")
        XCTAssertNil(r.motionSubsidedAt)
        XCTAssertEqual(r.reasons, [Bouts.respiratoryFollowUpUnobserved])
        XCTAssertEqual(r.censoring, [Bouts.censorContinuedMovement])
        XCTAssertEqual(r.observations, [])
    }

    func testUnobservedEndBoundaryGivesNoResult() throws {
        let strap = Self.track([(Self.t0 - 1800, Self.t0, "still"), (Self.t0, Self.end, "stepping")])
        let r = try Self.recovery(Self.detect(strap: strap, respiration: Self.preBout() + Self.post { _ in 14 }))
        XCTAssertEqual(r.state, "unknown")
        XCTAssertEqual(r.reasons, [Bouts.endedAtEvidenceGap, Bouts.respiratoryFollowUpUnobserved])
    }

    func testCutoffCensorsAndAnUnconfirmedWithinIsUnknown() throws {
        // Causal cutoff at end + 250: one estimate [end, end+120) and overlapping [end+60, end+180),
        // [end+120, end+240) are visible, all within; [end+120, end+240) confirms [end, end+120).
        let cutoff = Self.end + 250
        let visible = (Self.preBout() + Self.post { _ in 14.5 }).filter { $0.support.end <= cutoff }
        let r = try Self.recovery(Self.detect(respiration: visible, cutoff: cutoff, mode: .causalLive))
        XCTAssertEqual(r.censoring, [Bouts.censorCutoffReached])
        XCTAssertEqual(r.state, "returned_by")
        // Only [end, end+120) visible: within, but nothing can confirm it before the cutoff → unknown.
        let early = Self.end + 130
        let r2 = try Self.recovery(Self.detect(respiration: (Self.preBout() + Self.post { _ in 14.5 })
                                                .filter { $0.support.end <= early },
                                              cutoff: early, mode: .causalLive))
        XCTAssertEqual(r2.state, "unknown")
        XCTAssertEqual(r2.reasons, [Bouts.respiratoryObservationsResumed, Bouts.respiratoryReturnUnconfirmed])
    }

    func testOngoingBoutHasNoRecoveryAndNightlyValuesAreNeverRead() throws {
        let ongoing = Self.detect(respiration: Self.preBout() + Self.post { _ in 14 }, cutoff: Self.end + 30,
                                  mode: .causalLive)
        XCTAssertEqual(ongoing.first?.status, .ongoing)
        XCTAssertNil(ongoing.first?.recovery)
        // A nightly snapshot value (long support, `snapshot.*`) never stands in for a window estimate.
        var nightly = Self.rr(Self.t0 - 300, 14, method: "snapshot.resp_rate.night")
        nightly.support = .init(Self.t0 - 600, Self.t0 - 1)
        let r = try Self.recovery(Self.detect(respiration: [nightly] + Self.post { _ in 14 }))
        XCTAssertEqual(r.reasons, [Bouts.respiratoryReferenceUnavailable])
    }

    func testDuplicateAndIrregularEstimatesAreDeterministic() throws {
        // Duplicated supports (a second method / value) keep one estimate per support; irregular minute stamps
        // work because only supports are read.
        var post: [PC.MeasurementInput] = []
        var b = Self.end + 60
        for step in [60, 37, 83, 60, 120, 45, 75, 60] {
            post.append(Self.rr(b, 14.5)); post.append(Self.rr(b, 30, method: "series.resp_rate.zz"))
            b += step
        }
        let r = try Self.recovery(Self.detect(respiration: Self.preBout() + Self.preBout(14) + post.shuffled()))
        let again = try Self.recovery(Self.detect(respiration: (Self.preBout() + post).reversed()))
        XCTAssertEqual(r, again)
        XCTAssertEqual(r.observations.count, 8)
        XCTAssertTrue(r.observations.allSatisfy { $0.bpm == 14.5 })
        XCTAssertEqual(r.state, "returned_by")
    }

    // MARK: Policy, versions, round trips

    func testRespiratoryRecoveryParametersEnterTheFingerprintAndVersion() {
        let base = PC.Policy()
        XCTAssertEqual(base.versions.respiratoryRecovery, "pc-resp-recovery-1")
        var changed = base
        changed.exertion.respiratoryRecovery.toleranceBpm = 3
        XCTAssertNotEqual(base.fingerprint, changed.fingerprint)
        var changedRef = base
        changedRef.reference.stableAwakeRespMinEstimatesPerWindow = 3
        XCTAssertNotEqual(base.fingerprint, changedRef.fingerprint)
        // The HR exertion version (which keys the bout regime) is untouched.
        XCTAssertEqual(base.exertion.version, "pc-exertion-1")
    }

    func testBoutWithRespiratoryRecoveryRoundTripsThroughTheContextCoder() throws {
        let bouts = Self.detect(respiration: Self.preBout() + Self.post { $0 <= 420 ? 20 : 14.5 })
        let data = try PC.encoder().encode(bouts)
        let decoded = try PC.decoder().decode([PC.ExertionBout].self, from: data)
        XCTAssertEqual(decoded, bouts)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for key in ["\"respiratory_recovery\"", "\"returned_at_offset_s\"", "\"reference_independent_estimates\"",
                    "\"motion_subsided_at\""] {
            XCTAssertTrue(json.contains(key), key)
        }
        // A document written before the field existed still decodes (nil, never a fabricated result).
        var old = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var rec = try XCTUnwrap(old[0]["recovery"] as? [String: Any])
        rec.removeValue(forKey: "respiratory_recovery")
        old[0]["recovery"] = rec
        let legacy = try PC.decoder().decode([PC.ExertionBout].self,
                                             from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(legacy[0].recovery?.respiratoryRecovery)
    }

    // MARK: Stable-awake respiratory adapter

    static func rrEnvelope(at s: Int, _ v: Double, regime: String = "r1", validity: PC.ValidityState = .valid,
                           awake: PC.EligibilityState = .eligible) -> PC.MeasurementEnvelope {
        PCReferenceTests.envelope(.respiratoryRate, method: "series.resp_rate.2min", windowS: 120,
                                  units: "breaths_per_min", value: v, support: .init(s, s + 120), regime: regime,
                                  validity: validity, verdicts: [(.stableAwakeRest, awake)])
    }

    /// Four overlapping estimates starting every 60 s inside the 5-minute window at `w` (2 independent).
    static func rrWindow(_ w: Int, _ vs: [Double]) -> [PC.MeasurementEnvelope] {
        vs.enumerated().map { rrEnvelope(at: w + 60 * $0.offset, $0.element) }
    }

    func testStableAwakeRespirationPoolsWholeFiveMinuteWindowsWithEnoughIndependentEstimates() throws {
        let d0 = PCReferenceTests.identity.dayWindow.start
        let w9 = d0 + 9 * 3600, w10 = d0 + 10 * 3600, w11 = d0 + 11 * 3600
        var envs = Self.rrWindow(w9, [15, 16, 15, 17])         // median 15.5
            + Self.rrWindow(w10, [16, 17, 16, 17])             // median 16.5
            + Self.rrWindow(w11, [14, 15, 14, 15])             // median 14.5
        envs.append(Self.rrEnvelope(at: d0 + 12 * 3600, 30))                         // one estimate: no window
        envs.append(Self.rrEnvelope(at: d0 + 13 * 3600 + 240, 30))                   // straddles a window edge
        envs.append(Self.rrEnvelope(at: d0 + 14 * 3600, 30, awake: .ineligible))
        envs.append(Self.rrEnvelope(at: d0 + 14 * 3600 + 120, 30, awake: .ineligible))
        envs.append(Self.rrEnvelope(at: d0 + 15 * 3600, 30, validity: .degraded))
        envs.append(Self.rrEnvelope(at: d0 + 15 * 3600 + 120, 30, validity: .degraded))
        let values = Ref.dailyValues(envelopes: envs, identity: PCReferenceTests.identity, mode: .retrospective,
                                     finality: .final, config: .init())
        let v = try XCTUnwrap(values.first { $0.seriesKey == "resp_rate.stable_awake_5min" })
        XCTAssertEqual(v.value, 15.5)
        XCTAssertEqual(v.supportCount, 3)
        XCTAssertEqual(v.supportUnit, "window")
        XCTAssertEqual(v.supportS, 900)
        XCTAssertEqual(v.units, "breaths_per_min")
        XCTAssertEqual(v.metric, .respiratoryRate)
        XCTAssertEqual(v.sourceIds.count, 12)
        XCTAssertEqual(v.reasons, [Ref.stableAwakeRespirationWindow, Ref.stableAwakeWindows])
        let band = try XCTUnwrap(values.first { $0.seriesKey == "resp_rate.stable_awake_5min.band_06_12" })
        XCTAssertEqual(band.value, 15.5)
        XCTAssertTrue(band.reasons.contains(Ref.timeBandStratum))
        // Two windows are not enough: no value at all (never zero-filled).
        let two = Ref.dailyValues(envelopes: Array(envs.prefix(8)), identity: PCReferenceTests.identity,
                                  mode: .retrospective, finality: .final, config: .init())
        XCTAssertFalse(two.contains { $0.seriesKey.hasPrefix("resp_rate.stable_awake") })
        // Removing the metric from the config removes the series (the adapter is explicit, not implicit).
        var off = PC.ReferenceConfig()
        off.stableAwakeMetrics = [.hrvRmssd, .hrvSdnn, .heartRate]
        XCTAssertFalse(Ref.dailyValues(envelopes: envs, identity: PCReferenceTests.identity, mode: .retrospective,
                                       finality: .final, config: off).contains { $0.metric == .respiratoryRate })
    }

    func testStableAwakeRespirationSelectionAndComparisonUseTheSameMachinery() throws {
        let d0 = PCReferenceTests.identity.dayWindow.start
        let envs = Self.rrWindow(d0 + 9 * 3600, [15, 16, 15, 17]) + Self.rrWindow(d0 + 10 * 3600, [16, 17, 16, 17])
            + Self.rrWindow(d0 + 11 * 3600, [14, 15, 14, 15])
        let values = Ref.dailyValues(envelopes: envs, identity: PCReferenceTests.identity, mode: .retrospective,
                                     finality: .final, config: .init())
        let selection = PC.Eligibility.selection(envelopes: envs, observations: PC.SanitizedObservations(),
                                                 dayWindow: PCReferenceTests.identity.dayWindow, dailyValues: values)
        let s = try XCTUnwrap(selection.first { $0.comparison == .stableAwakeRest && $0.metric == .respiratoryRate })
        XCTAssertEqual(s.enteredCount, 12)
        let history = PCReferenceTests.history(20, series: "resp_rate.stable_awake_5min") { i in 15 + Double(i % 3) * 0.5 }
        let compared = Ref.compare(values, history: history, frozen: [], day: PCReferenceTests.day,
                                   policyFingerprint: "fp", config: .init())
        let rolling = try XCTUnwrap(PCReferenceTests.view(compared.comparisons, .rolling,
                                                          series: "resp_rate.stable_awake_5min"))
        XCTAssertEqual(rolling.supportDays, 20)
        XCTAssertEqual(rolling.status, .ready)
    }

    // MARK: Nightly respiratory rate against prior 7- / 28-day references

    func testNightlyRespiratoryRateReferencesExcludeTheTargetNightAndLaterDays() throws {
        let series = "resp_rate.sleep_night"
        // 40 earlier days: 14.0, 14.5, 15.0 repeating (oldest first); then the target day and a later day at 30.
        var history = PCReferenceTests.history(40, series: series) { i in 14 + Double(i % 3) * 0.5 }
        history.append(PCReferenceTests.value(PCReferenceTests.day, 30, series: series))
        history.append(PCReferenceTests.value(Ref.dayKey(Ref.dayNumber(PCReferenceTests.day)! + 1), 30, series: series))
        let today = PCReferenceTests.value(PCReferenceTests.day, 16, series: series)
        let out = Ref.compare([today], history: history, frozen: [], day: PCReferenceTests.day,
                              policyFingerprint: "fp", config: .init())
        let rolling = try XCTUnwrap(PCReferenceTests.view(out.comparisons, .rolling, series: series))
        let recent = try XCTUnwrap(PCReferenceTests.view(out.comparisons, .recent, series: series))
        // Rolling = the 28 days before the target day, recent = the 7 days before it; both medians are 14.5.
        let t = Ref.dayNumber(PCReferenceTests.day)!
        XCTAssertEqual(rolling.supportDays, 28)
        XCTAssertEqual(rolling.fromDay, Ref.dayKey(t - 28))
        XCTAssertEqual(rolling.toDay, Ref.dayKey(t - 1))
        XCTAssertEqual(rolling.center, 14.5)
        XCTAssertEqual(rolling.signedDifference, 1.5)
        XCTAssertEqual(rolling.status, .ready)
        XCTAssertTrue(rolling.reasons.contains(Ref.futureHistoryIgnored))
        XCTAssertEqual(recent.supportDays, 7)
        XCTAssertEqual(recent.toDay, Ref.dayKey(t - 1))
        XCTAssertEqual(recent.center, 14.5)
        XCTAssertTrue(recent.reasons.contains(Ref.scaleFromRollingView))
        XCTAssertEqual(rolling.transform, "identity")
    }

    func testNightlyRespiratoryRateZeroMadUsesTheExplicitFloor() throws {
        let series = "resp_rate.sleep_night"
        let history = PCReferenceTests.history(14, series: series) { _ in 15 }
        let today = PCReferenceTests.value(PCReferenceTests.day, 16, series: series)
        let out = Ref.compare([today], history: history, frozen: [], day: PCReferenceTests.day,
                              policyFingerprint: "fp", config: .init())
        let rolling = try XCTUnwrap(PCReferenceTests.view(out.comparisons, .rolling, series: series))
        XCTAssertEqual(rolling.scale, 0.3)       // resp_rate. floor: 0.3 breaths/min, never a zero scale
        XCTAssertTrue(rolling.scaleFloored)
        XCTAssertTrue(rolling.reasons.contains(Ref.constantHistory))
        XCTAssertTrue(rolling.reasons.contains(Ref.scaleFloored))
        XCTAssertEqual(try XCTUnwrap(rolling.robustZ), 1 / 0.3, accuracy: 1e-12)
        // Too little support never scores.
        let sparse = Ref.compare([today], history: Array(history.suffix(2)), frozen: [], day: PCReferenceTests.day,
                                 policyFingerprint: "fp", config: .init())
        let r2 = try XCTUnwrap(PCReferenceTests.view(sparse.comparisons, .rolling, series: series))
        XCTAssertEqual(r2.status, .insufficient)
        XCTAssertNil(r2.robustZ)
        XCTAssertEqual(r2.supportDays, 2)
    }

    // MARK: Python → Swift sleep_features decoder

    /// Produced by the Python sidecar (features/respiration.py + features/rebound.py, spec-02) from the fixtures
    /// of tests/test_features_respiration_spec02.py; every new key must decode.
    static let pythonFixture = #"""
{"schema_version":1,"algorithm_version":"nara-sleep-features-1","status":"available","status_reasons":[],"nights":[{"night_id":"n1","start_utc":"2027-01-15T08:00:00Z","end_utc":"2027-01-15T08:20:00Z","is_nap":false,"respiratory_variability":{"status":"available","reasons":[],"estimate_source":"rsa_derived_rr","unobserved_breath_is_not_apnea":true,"algorithm_source":"SleepStager.respBreathTrack(rr)","notes":"RSA-derived estimates; weak RSA, ectopics, medication or missing R-R can erase estimated breaths without airflow stopping; an unobserved breath is not an apnea; not measured ventilation/tidal volume/respiratory effort.","intervals_valid":268,"rate_bpm":13.333333333333334,"sd_interval_s":0.6236702551641189,"cv_interval":0.14039783988574872,"rmssd_interval_s":0.7501560386992854,"valid_run_min":20.0,"quality":{"usable_windows":4,"total_windows":4,"night_run_coverage":1.0},"stage_conditioned":{"wake":{"windows":0,"rate_bpm":null,"cv_interval":null,"sd_interval_s":null,"rmssd_interval_s":null,"median_interval_s":null,"iqr_interval_s":null,"true_intervals":0},"light":{"windows":2,"rate_bpm":17.142857142857142,"cv_interval":0.1255240670673892,"sd_interval_s":0.5016750465679883,"rmssd_interval_s":1.0,"median_interval_s":3.5,"iqr_interval_s":1.0,"true_intervals":149},"deep":{"windows":2,"rate_bpm":12.0,"cv_interval":0.0,"sd_interval_s":0.0,"rmssd_interval_s":0.0,"median_interval_s":5.0,"iqr_interval_s":0.0,"true_intervals":119},"rem":{"windows":0,"rate_bpm":null,"cv_interval":null,"sd_interval_s":null,"rmssd_interval_s":null,"median_interval_s":null,"iqr_interval_s":null,"true_intervals":0}},"outlier_fraction_vs_personal":{"status":"withheld","reasons":["no_personal_baseline"],"fraction":null},"method_version":"resp-variability-2","config":{"distribution_min_windows":2,"distribution_percentiles":[5,10,25,50,75,90,95],"stable_window_s":300,"stable_min_run_coverage":0.8,"stable_min_intervals":20,"stable_max_cv_interval":0.25},"supported_range":{"detector_band_bpm":[6.0,24.0],"min_peak_spacing_s":2.5,"display_rate_range_bpm":[8.0,25.0],"source":"SleepStager.respBreathTrack"},"interval_distribution":{"status":"available","reasons":[],"n_intervals":268,"usable_windows":4,"median_s":4.5,"iqr_s":1.5,"p05_s":3.5,"p10_s":3.5,"p25_s":3.5,"p75_s":5.0,"p90_s":5.0,"p95_s":5.0,"unit":"s","quantile_method":"linear_interpolation","source":"consecutive_intervals_within_usable_runs"},"stable_modulation":{"status":"available","reasons":["unknown_time_never_stable"],"definition_version":"stable-resp-modulation-1","criteria":{"window_s":300.0,"min_run_coverage":0.8,"min_intervals":20.0,"max_cv_interval":0.25},"stable_minutes":20.0,"evaluated_minutes":20.0,"unknown_minutes":0.0,"night_minutes":20.0,"windows_total":4,"windows_evaluated":4,"windows_stable":4,"stable_fraction_of_evaluated":1.0,"stable_fraction_of_night":1.0,"unit":"min"}}}],"rebound":{"definition_version":"sleep-rebound-1","history_revision_digest":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","rules":{"short_below_reference_min":60.0,"fragmented_above_reference_min":30.0,"min_reference_nights":7.0,"min_pairs":3.0},"unit":"min","notes":"Descriptive next-night differences from your own usual night after short or fragmented nights in the history window. Not a cause, a prediction or a probability; nights are as the published snapshot measured them.","descriptive_only":true,"status":"available","reasons":["no_fragmented_nights_observed"],"personal_reference":{"median_asleep_min":420.0,"median_awake_min":30.0,"nights":14,"days_evaluated":14},"after_short":{"pairs":3,"next_night_asleep_diff_min":{"median":60.0,"iqr":10.0,"segments":3},"next_night_awake_diff_min":{"median":0.0,"iqr":0.0,"segments":3},"pair_days":[["2026-09-03","2026-09-04"],["2026-09-07","2026-09-08"],["2026-09-11","2026-09-12"]]},"after_fragmented":{"pairs":0,"next_night_asleep_diff_min":{"median":null,"iqr":null,"segments":0},"next_night_awake_diff_min":{"median":null,"iqr":null,"segments":0},"pair_days":[]},"pairs_evaluated":13}}
"""#

    func testPythonRespiratoryAndReboundBlocksDecode() throws {
        let doc = try JSONDecoder().decode(SleepFeatureDocument.self, from: Data(Self.pythonFixture.utf8))
        let rv = try XCTUnwrap(doc.nights.first?.respiratoryVariability)
        XCTAssertEqual(rv.methodVersion, "resp-variability-2")
        XCTAssertEqual(rv.supportedRange?.detectorBandBpm, [6, 24])
        XCTAssertEqual(rv.supportedRange?.displayRateRangeBpm, [8, 25])
        XCTAssertEqual(rv.supportedRange?.minPeakSpacingS, 2.5)
        let dist = try XCTUnwrap(rv.intervalDistribution)
        XCTAssertEqual(dist.status, .available)
        XCTAssertEqual(dist.nIntervals, 268)
        XCTAssertEqual(dist.medianS, 4.5)
        XCTAssertEqual(dist.iqrS, 1.5)
        XCTAssertEqual(dist.p05S, 3.5)
        XCTAssertEqual(dist.p95S, 5.0)
        XCTAssertEqual(dist.source, "consecutive_intervals_within_usable_runs")
        let sm = try XCTUnwrap(rv.stableModulation)
        XCTAssertEqual(sm.definitionVersion, "stable-resp-modulation-1")
        XCTAssertEqual(sm.criteria?["max_cv_interval"], 0.25)
        XCTAssertEqual(sm.stableMinutes, 20)
        XCTAssertEqual(sm.evaluatedMinutes, 20)
        XCTAssertEqual(sm.unknownMinutes, 0)
        XCTAssertEqual(sm.stableFractionOfNight, 1)
        let light = try XCTUnwrap(rv.light)
        XCTAssertEqual(light.medianIntervalS, 3.5)
        XCTAssertEqual(light.rmssdIntervalS, 1.0)
        XCTAssertEqual(light.iqrIntervalS, 1.0)
        XCTAssertNotNil(light.sdIntervalS)
        XCTAssertNil(rv.rem?.medianIntervalS)
        let rb = try XCTUnwrap(doc.rebound)
        XCTAssertEqual(rb.status, .available)
        XCTAssertEqual(rb.definitionVersion, "sleep-rebound-1")
        XCTAssertEqual(rb.historyRevisionDigest?.count, 64)
        XCTAssertEqual(rb.rules?["min_pairs"], 3)
        XCTAssertEqual(rb.personalReference?.nights, 14)
        XCTAssertEqual(rb.personalReference?.medianAsleepMin, 420)
        XCTAssertEqual(rb.afterShort?.pairs, 3)
        XCTAssertEqual(rb.afterShort?.nextNightAsleepDiffMin?.median, 60)
        XCTAssertEqual(rb.afterShort?.nextNightAsleepDiffMin?.iqr, 10)
        XCTAssertEqual(rb.afterFragmented?.pairs, 0)
        XCTAssertNil(rb.afterFragmented?.nextNightAsleepDiffMin?.median)
        XCTAssertNotNil(rb.notes)
    }
}
