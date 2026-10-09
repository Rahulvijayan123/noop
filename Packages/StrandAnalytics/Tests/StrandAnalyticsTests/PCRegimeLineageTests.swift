import Foundation
import XCTest
@testable import StrandAnalytics

/// D4-09: context strata of the stable-awake references (seated / lying awake / standing still, from confident,
/// heart-rate free posture claims only) and the predecessor-regime fallback after a strap change (compatible
/// regimes only, flagged, wider, shrunk away as the new device's own support grows, never mixed into its own
/// statistics, strictly causal). Expected values are computed independently in the tests.
final class PCRegimeLineageTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias Ref = PhysiologyContext.ContextReferences
    typealias T = PCReferenceTests

    static let parent = "heart_rate.stable_awake_5min"
    static let upright = parent + ".ctx_upright_stationary"
    static let recumbent = parent + ".ctx_recumbent_awake"
    static let seated = parent + ".ctx_seated"

    // MARK: Versions (INT-C review)

    func testPolicyVersionsDistinguishTheNewEventPlacementAndStrata() {
        XCTAssertEqual(PC.Eligibility.version, "pc-eligibility-5")
        XCTAssertEqual(PC.EligibilityConfig().version, "pc-eligibility-5")
        XCTAssertEqual(PC.IntervalAlgebra.version, "pc-join-3")
        XCTAssertEqual(PC.JoinConfig().version, "pc-join-3")
        XCTAssertEqual(PC.ReferenceConfig().version, "pc-reference-4")
        XCTAssertEqual(PC.ContextReferences.version, "pc-reference-4")
        XCTAssertEqual(PC.PostureConfig().version, "pc-posture-2")
        let v = PC.Policy.default.versions
        XCTAssertEqual(v.eligibility, "pc-eligibility-5")
        XCTAssertEqual(v.join, "pc-join-3")
        // A document decided under the old placement has a different policy fingerprint.
        var old = PC.Policy.default
        old.eligibility.version = "pc-eligibility-4"
        old.join.version = "pc-join-2"
        XCTAssertNotEqual(old.fingerprint, PC.Policy.default.fingerprint)
    }

    // MARK: Context stratum (posture evidence -> stratum)

    static let day = "2026-03-10"
    static var window: PC.Interval { PC.Engine.dayInterval(day, timezoneId: "UTC") }

    static func decoderTrack(_ runs: [(String, Double, Bool?, String)]) -> (PC.ResolvedTrack, PC.ResolvedTrack) {
        let start = window.start + 8 * 3600
        let inputs = runs.enumerated().map { i, r in
            PC.ActivityIntervalInput(interval: .init(start + i * 300, start + (i + 1) * 300), activityClass: r.0,
                                     confidence: r.1, revision: 1, inBed: r.2, decoderVersion: r.3,
                                     algorithmVersion: "streams-activity-1")
        }
        let track = PC.IntervalAlgebra.resolve(PC.IntervalAlgebra.records(fromIntervals: inputs),
                                               source: .decoderIntervals, heartRateDependent: true)
        return (track, PC.PostureEvidence.inBedTrack(inputs))
    }

    static func gravity(_ s: PC.PostureStratum) -> PC.PostureContext {
        PC.PostureContext(version: "pc-posture-2", stratum: s, basis: s == .unknown ? [] : ["forearm_gravity"],
                          gravityS: 300, forearmFlatShare: s == .recumbentLikely ? 1 : 0, inBedS: nil,
                          heartRateDependent: false, reasons: [])
    }

    static func stratum(_ cls: String, confidence: Double = 0.85, inBed: Bool? = false, decoder: String = "hsmm-1.9",
                        gravity g: PC.PostureStratum = .unknown) -> PC.PostureContext {
        let (track, bed) = decoderTrack([(cls, confidence, inBed, decoder)])
        let start = window.start + 8 * 3600
        return PC.PostureEvidence.withContext(gravity(g), over: .init(start, start + 300), decoder: track,
                                              inBed: bed, config: .init())
    }

    /// Every code the engine emits is in a registry (the app's wording coverage iterates them).
    func testEmittedContextAndFeatureCodesAreRegistered() {
        XCTAssertTrue(PC.PostureEvidence.reasonCodes.contains(PC.PostureEvidence.sittingStandingNotSeparatedByWrist))
        XCTAssertTrue(PC.Functional.reasonCodes.contains(PC.FeatureRegistry.noValidatedDefinition))
        let emitted = Self.stratum("standing", decoder: "hsmm-1.10").contextReasons ?? []
        for code in emitted { XCTAssertTrue(PC.PostureEvidence.reasonCodes.contains(code), "\(code)") }
    }

    /// A ride never keys a seated stratum (review r5): an "In a vehicle" run is class `sitting` at a confidence the
    /// vehicle mass carries past tau, but heart rate in a moving vehicle is not seated rest.
    func testARideNeverKeysTheSeatedStratum() {
        let (track, bed) = Self.decoderTrack([("sitting", 0.95, false, "hsmm-1.9")])
        let start = Self.window.start + 8 * 3600
        let support = PC.Interval(start, start + 300)
        let parked = PC.PostureEvidence.withContext(Self.gravity(.unknown), over: support, decoder: track, inBed: bed,
                                                    config: .init())
        XCTAssertEqual(parked.context, .seated)
        let ride = PC.PostureEvidence.withContext(Self.gravity(.unknown), over: support, decoder: track, inBed: bed,
                                                  config: .init(), vehicle: [support])
        XCTAssertEqual(ride.context, .unknown)
        XCTAssertTrue(ride.contextReasons?.contains(PC.PostureEvidence.contextInVehicleNotUsed) == true)
        XCTAssertTrue(PC.PostureEvidence.reasonCodes.contains(PC.PostureEvidence.contextInVehicleNotUsed))
        // Part of the window in the car: the parked share is below the stratum's 90 % and it abstains too.
        let partly = PC.PostureEvidence.withContext(Self.gravity(.unknown), over: support, decoder: track, inBed: bed,
                                                    config: .init(), vehicle: [.init(start + 240, start + 300)])
        XCTAssertEqual(partly.context, .unknown)
    }

    func testContextStratumComesOnlyFromConfidentHeartRateFreePostureClaims() {
        XCTAssertEqual(Self.stratum("standing").context, .uprightStationary)
        XCTAssertEqual(Self.stratum("sitting_desk").context, .seated)
        XCTAssertEqual(Self.stratum("lying_down").context, .recumbentAwake)
        XCTAssertEqual(Self.stratum("standing").contextBasis, [PC.PostureEvidence.basisDecoderPosture])
        XCTAssertEqual(Self.stratum("standing").contextConfidence, 0.85)
        // Below tau (the wrist-only cap is 0.75): unknown, and why.
        let weak = Self.stratum("standing", confidence: 0.75)
        XCTAssertEqual(weak.context, .unknown)
        XCTAssertTrue(weak.contextReasons?.contains(PC.PostureEvidence.contextBelowConfidenceFloor) == true)
        // A decoder whose posture head read heart rate.
        let old = Self.stratum("sitting", decoder: "hsmm-1.7")
        XCTAssertEqual(old.context, .unknown)
        XCTAssertTrue(old.contextReasons?.contains(PC.PostureEvidence.contextDecoderReadsHeartRate) == true)
        XCTAssertEqual(Self.stratum("sitting", decoder: "hsmm-1.10").context, .seated, "versions compare numerically")
        // hsmm-1.8 stored sit / stand runs at up to ~0.9 whenever a learned source merely spoke (presence lifted
        // the cap to 1.0), and its lie-down path read a lower heart rate: neither may key a stratum (review r5).
        for cls in ["sitting", "standing", "lying_down"] {
            let v18 = Self.stratum(cls, confidence: 0.9, decoder: "hsmm-1.8")
            XCTAssertEqual(v18.context, .unknown, cls)
            XCTAssertTrue(v18.contextReasons?.contains(PC.PostureEvidence.contextDecoderReadsHeartRate) == true, cls)
        }
        // The heart-rate confirmed in-bed window is never context evidence.
        let bed = Self.stratum("lying_down", inBed: true)
        XCTAssertEqual(bed.context, .unknown)
        XCTAssertTrue(bed.contextReasons?.contains(PC.PostureEvidence.contextInBedNotUsed) == true)
        // Never against the forearm's own reading.
        let conflict = Self.stratum("standing", gravity: .recumbentLikely)
        XCTAssertEqual(conflict.context, .unknown)
        XCTAssertTrue(conflict.contextReasons?.contains(PC.PostureEvidence.contextConflictsWithGravity) == true)
        let agree = Self.stratum("lying_down", gravity: .recumbentLikely)
        XCTAssertEqual(agree.context, .recumbentAwake)
        XCTAssertEqual(agree.contextBasis, [PC.PostureEvidence.basisDecoderPosture, PC.PostureEvidence.basisForearmGravity])
        // Not a posture claim at all.
        XCTAssertEqual(Self.stratum("stationary").context, .unknown)
        XCTAssertFalse(agree.heartRateDependent)
    }

    // MARK: Context strata in the references

    /// One day of 5-minute HR windows: `n` per context stratum at the given bpm, plus unknown windows.
    static func contextDay(_ day: String, _ windows: [(PC.ContextStratum, Int, Double)]) -> [PC.DailyValue] {
        let identity = PC.DayIdentity(deviceScope: "dev-1", day: day, timezoneId: "UTC",
                                      dayWindow: PC.Engine.dayInterval(day, timezoneId: "UTC"))
        var envs: [PC.MeasurementEnvelope] = []
        var h = 0.0
        for (s, n, bpm) in windows {
            for _ in 0..<n {
                let start = identity.dayWindow.start + Int((8 + h) * 3600)
                var e = T.envelope(.heartRate, method: "context.heart_rate.5min_mean", units: "bpm", value: bpm,
                                   support: .init(start, start + 300), verdicts: [(.stableAwakeRest, .eligible)])
                var p = gravity(.unknown)
                p.context = s
                e.posture = p
                envs.append(e)
                h += 0.5
            }
        }
        return Ref.dailyValues(envelopes: envs, identity: identity, mode: .retrospective, finality: .final,
                               config: .init())
    }

    func testContextStrataAreSeparateDailyValuesAndUnknownStaysInTheParent() throws {
        let d = Self.contextDay("2026-03-09", [(.uprightStationary, 4, 76), (.recumbentAwake, 3, 60),
                                               (.seated, 2, 66), (.unknown, 3, 68)])
        func v(_ k: String) -> PC.DailyValue? { d.first { $0.seriesKey == k } }
        XCTAssertEqual(v(Self.upright)?.value, 76)
        XCTAssertEqual(v(Self.recumbent)?.value, 60)
        XCTAssertNil(v(Self.seated), "two windows are below the stratum minimum: the parent keeps them")
        XCTAssertFalse(d.contains { $0.seriesKey.hasSuffix(".ctx_unknown") })
        XCTAssertEqual(try XCTUnwrap(v(Self.parent)).supportCount, 12)
        XCTAssertTrue(v(Self.upright)!.reasons.contains(Ref.contextStratum))
        XCTAssertEqual(Ref.parentSeries(of: Self.upright), Self.parent)
        XCTAssertTrue(Ref.isStratum(Self.recumbent))
    }

    func testContextStrataSeparateAStandingReferenceFromALyingOne() throws {
        // 20 days: standing still at 76 bpm, lying awake at 60, the pooled parent at 68 (its mix varies).
        var hist: [PC.DailyValue] = []
        hist += T.history(20, series: Self.upright) { i in 76 + Double(i % 3) - 1 }
        hist += T.history(20, series: Self.recumbent) { i in 60 + Double(i % 3) - 1 }
        hist += T.history(20, series: Self.parent) { i in 68 + Double(i % 5) - 2 }
        let today = [T.value(T.day, 76, series: Self.upright), T.value(T.day, 61, series: Self.recumbent)]
        let cs = T.compare(today, hist).comparisons
        let up = try XCTUnwrap(T.view(cs, .conditioned, series: Self.upright))
        let down = try XCTUnwrap(T.view(cs, .conditioned, series: Self.recumbent))
        // Child weight 20 / 27: centers stay with their own posture, far apart.
        XCTAssertGreaterThan(try XCTUnwrap(up.center), 73.5)
        XCTAssertLessThan(try XCTUnwrap(down.center), 62.5)
        XCTAssertLessThan(up.pooledContribution, 0.3)
        XCTAssertLessThan(down.pooledContribution, 0.3)
        XCTAssertTrue(up.reasons.contains(Ref.contextStratum))
        // The standing minute is ordinary against its own posture, not "high" against a pooled reference.
        XCTAssertLessThan(abs(try XCTUnwrap(up.robustZ)), 2)
        let pooled = try XCTUnwrap(T.view(T.compare([T.value(T.day, 76, series: Self.parent)], hist).comparisons,
                                          .rolling, series: Self.parent))
        XCTAssertGreaterThan(try XCTUnwrap(pooled.robustZ), 2)
    }

    // MARK: Predecessor regime

    static let series = "heart_rate.stable_awake_5min"

    static func device(firmware: String? = nil) -> PC.DeviceRegimeInput {
        PC.DeviceRegimeInput(vendor: "whoop", sourceKind: "push", firmware: firmware, scoringAlgorithmVersion: "s")
    }

    /// `n` predecessor days ending `gap` days before the strap change (`ownDays` before the scored day).
    static func predecessor(_ n: Int, ownDays: Int, family: String? = "whoop5", successor: String? = "whoop5",
                            firmware: String? = nil,
                            quality: Double? = nil, value: @escaping (Int) -> Double = { 66 + Double($0 % 3) - 1 })
        -> PC.PredecessorRegimeHistory {
        let change = Ref.dayKey(Ref.dayNumber(T.day)! - ownDays)
        var vs = T.history(n, endingBefore: change, series: series, value)
        if let q = quality {
            vs += T.history(n, endingBefore: change, series: Ref.opticalValidShareSeries) { _ in q }
                .map { var v = $0; v.regimeKey = "coverage"; return v }
        }
        return PC.PredecessorRegimeHistory(deviceScope: "old-strap", vendor: "whoop", sourceKind: "push",
                                           hardwareFamily: family, successorHardwareFamily: successor,
                                           firmware: firmware, dailyValues: vs)
    }

    static func own(_ n: Int, quality: Double? = nil) -> [PC.DailyValue] {
        var vs = T.history(n, series: series) { i in 70 + Double(i % 3) - 1 }
        if let q = quality {
            vs += T.history(max(n, 1), series: Ref.opticalValidShareSeries) { _ in q }
                .map { var v = $0; v.regimeKey = "coverage"; return v }
        }
        return vs
    }

    static func rolling(own n: Int, _ p: PC.PredecessorRegimeHistory?, device: PC.DeviceRegimeInput = device(),
                        today: [PC.DailyValue] = [], config: PC.ReferenceConfig = .init()) -> PC.ReferenceComparison? {
        let lineage = p.map { Ref.RegimeLineage(device: device, predecessors: [$0]) }
        let cs = Ref.compare([T.value(T.day, 72, series: series)] + today, history: own(n), frozen: [], day: T.day,
                             policyFingerprint: "fp", config: config, lineage: lineage).comparisons
        return T.view(cs, .rolling, series: series)
    }

    func testAStrapChangeWithACompatiblePredecessorBorrowsItFlaggedAndWider() throws {
        let p = Self.predecessor(20, ownDays: 0)
        let c = try XCTUnwrap(Self.rolling(own: 0, p))
        XCTAssertEqual(c.status, .provisional)
        XCTAssertEqual(c.predecessorScope, "old-strap")
        XCTAssertTrue(c.reasons.contains(Ref.predecessorRegime))
        XCTAssertTrue(c.reasons.contains(Ref.predecessorRegimeOnly))
        XCTAssertTrue(c.reasons.contains(Ref.predecessorFirmwareUnknown), "firmware has no effective-dated source")
        XCTAssertEqual(c.pooledContribution, 1)
        XCTAssertEqual(c.supportDays, 0, "the device's own support is still zero")
        XCTAssertEqual(c.parentSupportDays, 20)
        XCTAssertEqual(try XCTUnwrap(c.center), 66, accuracy: 1e-9)
        XCTAssertNotNil(c.robustZ)
        // Without a predecessor the same day has no reference at all.
        let none = try XCTUnwrap(Self.rolling(own: 0, nil))
        XCTAssertEqual(none.status, .insufficient)
        XCTAssertNil(none.predecessorScope)
        // Wider than the same 20 days would be as the device's own history: scale and center uncertainty.
        let asOwn = try XCTUnwrap(T.view(T.compare([T.value(T.day, 72, series: Self.series)],
                                                   T.history(20, series: Self.series) { 66 + Double($0 % 3) - 1 })
                                            .comparisons, .rolling, series: Self.series))
        XCTAssertGreaterThan(try XCTUnwrap(c.scale), try XCTUnwrap(asOwn.scale))
        XCTAssertGreaterThan(try XCTUnwrap(c.centerUncertainty), try XCTUnwrap(asOwn.centerUncertainty))
    }

    func testThePredecessorDecaysAsTheDevicesOwnSupportGrowsAndIsDroppedWhenReady() throws {
        var shares: [Double] = []
        for n in [0, 3, 7, 10, 13] {
            let c = try XCTUnwrap(Self.rolling(own: n, Self.predecessor(20, ownDays: n)))
            XCTAssertEqual(c.predecessorScope, "old-strap", "own \(n)")
            XCTAssertEqual(c.status, .provisional)
            XCTAssertEqual(c.pooledContribution, n == 0 ? 1 : 7 / (Double(n) + 7), accuracy: 1e-9, "own \(n)")
            XCTAssertEqual(c.supportDays, n)
            shares.append(c.pooledContribution)
        }
        XCTAssertEqual(shares, shares.sorted(by: >))
        // Ready on its own: the predecessor is not used and not mentioned.
        let ready = try XCTUnwrap(Self.rolling(own: 14, Self.predecessor(20, ownDays: 14)))
        XCTAssertEqual(ready.status, .ready)
        XCTAssertNil(ready.predecessorScope)
        XCTAssertEqual(ready.pooledContribution, 0)
        XCTAssertFalse(ready.reasons.contains(Ref.predecessorRegime))
    }

    func testAnIncompatiblePredecessorIsNeverUsed() throws {
        let cases: [(PC.PredecessorRegimeHistory, PC.DeviceRegimeInput, PC.ReasonCode)] = [
            (Self.predecessor(20, ownDays: 0, family: "whoop4"), Self.device(), Ref.predecessorFamilyDiffers),
            (Self.predecessor(20, ownDays: 0, family: nil), Self.device(), Ref.predecessorFamilyUnknown),
            (Self.predecessor(20, ownDays: 0, successor: nil), Self.device(), Ref.predecessorFamilyUnknown),
            (Self.predecessor(20, ownDays: 0, firmware: "40.1"), Self.device(firmware: "41.2"),
             Ref.predecessorFirmwareDiffers),
        ]
        for (p, d, reason) in cases {
            let c = try XCTUnwrap(Self.rolling(own: 0, p, device: d))
            XCTAssertNil(c.predecessorScope, "\(reason)")
            XCTAssertEqual(c.status, .insufficient, "\(reason)")
            XCTAssertNil(c.robustZ)
            XCTAssertTrue(c.reasons.contains(Ref.predecessorIncompatible), "\(reason)")
            XCTAssertTrue(c.reasons.contains(reason), "\(reason): \(c.reasons)")
            XCTAssertFalse(c.reasons.contains(Ref.predecessorRegime))
        }
        // Another source (an Oura ring before a WHOOP strap).
        var ring = Self.predecessor(20, ownDays: 0)
        ring.vendor = "oura"; ring.sourceKind = "oura"
        let r = try XCTUnwrap(Self.rolling(own: 0, ring))
        XCTAssertNil(r.predecessorScope)
        XCTAssertTrue(r.reasons.contains(Ref.predecessorSourceDiffers))
        // Materially different signal quality.
        let poor = Self.predecessor(20, ownDays: 0, quality: 0.95)
        let today = [PC.DailyValue(day: T.day, seriesKey: Ref.opticalValidShareSeries, regimeKey: "coverage",
                                   metric: nil, value: 0.5, units: "share", supportCount: 100, supportUnit: "window",
                                   supportS: 30_000, mode: .retrospective, finality: .final)]
        let q = try XCTUnwrap(Self.rolling(own: 0, poor, today: today))
        XCTAssertNil(q.predecessorScope)
        XCTAssertTrue(q.reasons.contains(Ref.predecessorSignalQualityDiffers))
        // Similar quality is fine.
        var similar = today; similar[0].value = 0.9
        XCTAssertEqual(try XCTUnwrap(Self.rolling(own: 0, poor, today: similar)).predecessorScope, "old-strap")
        // A different regime key (another placement or method) holds no values of this series and regime.
        var bicep = Self.predecessor(20, ownDays: 0)
        bicep.dailyValues = bicep.dailyValues.map { var v = $0; v.regimeKey = "bicep"; return v }
        let b = try XCTUnwrap(Self.rolling(own: 0, bicep))
        XCTAssertNil(b.predecessorScope)
        XCTAssertTrue(b.reasons.contains(Ref.predecessorInsufficient))
    }

    func testSignalQualityIsJudgedOnThePredecessorsOwnLastDays() throws {
        // Review R8: the predecessor's quality values end two weeks before the scored day (a strap change 13 days
        // ago, its last quality rows two days before that). They must still be compared with the new strap's.
        var p = Self.predecessor(20, ownDays: 13, quality: 0.95)
        let cut = Ref.dayNumber(T.day)! - 15
        p.dailyValues = p.dailyValues.filter {
            $0.seriesKey != Ref.opticalValidShareSeries || Ref.dayNumber($0.day)! < cut
        }
        let cs = Ref.compare([T.value(T.day, 72, series: Self.series)], history: Self.own(13, quality: 0.5),
                             frozen: [], day: T.day, policyFingerprint: "fp", config: .init(),
                             lineage: .init(device: Self.device(), predecessors: [p])).comparisons
        let c = try XCTUnwrap(T.view(cs, .rolling, series: Self.series))
        XCTAssertNil(c.predecessorScope)
        XCTAssertTrue(c.reasons.contains(Ref.predecessorSignalQualityDiffers), "\(c.reasons)")
        // With no quality on either side the borrow stands, and says the quality was not compared.
        let unknown = try XCTUnwrap(Self.rolling(own: 3, Self.predecessor(20, ownDays: 3)))
        XCTAssertEqual(unknown.predecessorScope, "old-strap")
        XCTAssertTrue(unknown.reasons.contains(Ref.predecessorSignalQualityUnknown))
    }

    func testInsufficientSupportOnBothSidesAbstains() throws {
        let c = try XCTUnwrap(Self.rolling(own: 2, Self.predecessor(4, ownDays: 2)))
        XCTAssertEqual(c.status, .insufficient)
        XCTAssertNil(c.robustZ)
        XCTAssertNil(c.predecessorScope)
        XCTAssertTrue(c.reasons.contains(Ref.predecessorInsufficient))
        // A stale predecessor (its newest value long before the change) is not used either.
        let stale = try XCTUnwrap(Self.rolling(own: 0, Self.predecessor(20, ownDays: 60)))
        XCTAssertNil(stale.predecessorScope)
        XCTAssertTrue(stale.reasons.contains(Ref.predecessorStale))
    }

    func testThePredecessorNeverEntersTheDevicesOwnStatisticsOrOtherViews() throws {
        let p = Self.predecessor(20, ownDays: 3)
        let cs = Ref.compare([T.value(T.day, 72, series: Self.series)], history: Self.own(3), frozen: [], day: T.day,
                             policyFingerprint: "fp", config: .init(),
                             lineage: .init(device: Self.device(), predecessors: [p]))
        // Recent and frozen are the device's own: no predecessor, no frozen registration from it.
        let recent = try XCTUnwrap(T.view(cs.comparisons, .recent, series: Self.series))
        XCTAssertNil(recent.predecessorScope)
        XCTAssertEqual(recent.supportDays, 3)
        XCTAssertTrue(cs.newFrozen.isEmpty)
        let frozen = try XCTUnwrap(T.view(cs.comparisons, .frozen, series: Self.series))
        XCTAssertNil(frozen.predecessorScope)
        XCTAssertNotEqual(frozen.status, .ready)
    }

    func testNoLeakageAcrossTheAsOfDay() throws {
        let p = Self.predecessor(20, ownDays: 0)
        var leaky = p
        // Values from the scored day on (the predecessor still worn later, a back-filled row): extreme, and ignored.
        leaky.dailyValues += [T.value(T.day, 140, series: Self.series),
                              T.value(Ref.dayKey(Ref.dayNumber(T.day)! + 3), 150, series: Self.series)]
        let a = try XCTUnwrap(Self.rolling(own: 0, p))
        let b = try XCTUnwrap(Self.rolling(own: 0, leaky))
        XCTAssertEqual(a, b)
        // The engine drops them before the references see them.
        let h = PC.HistoryInput(predecessors: [leaky])
        let earlier = PC.Engine.strictlyEarlier(h, than: T.day, dayStart: Self.window.start, mode: .retrospective)
        XCTAssertEqual(earlier.value.predecessors.first?.dailyValues.count, p.dailyValues.count)
        XCTAssertEqual(earlier.dropped, 2)
        // A history without predecessors encodes exactly as before they existed.
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PC.HistoryInput())) as! [String: Any]
        XCTAssertNil(plain["predecessors"])
    }
}
