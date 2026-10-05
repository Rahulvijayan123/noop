import Foundation
import XCTest
@testable import StrandAnalytics

/// System F change detection: transient / recurring / persistent episodes, frozen-vs-rolling visibility, drift,
/// sparse / missing / constant histories, regime boundaries, leakage (V10, V11, V12) and multi-signal dependence
/// (V13). Series come from the seeded synthetic generator (deterministic) or explicit patterns.
final class PCChangeDetectionTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias Ref = PhysiologyContext.ContextReferences
    typealias CD = PhysiologyContext.ChangeDetection
    typealias E = PhysiologyContext.Evaluation

    static let spec = E.SeriesSpec.rmssd
    static var first: Int { Ref.dayNumber(spec.firstDay)! }
    static func day(_ i: Int) -> String { Ref.dayKey(first + i) }

    static func values(_ s: E.Scenario, seed: UInt64) -> [PC.DailyValue] {
        E.dailyValues(E.generate(s, seed: seed), spec: spec)
    }

    static func values(pattern xs: [Double?]) -> [PC.DailyValue] { E.dailyValues(xs, spec: spec) }

    /// The engine's flow for day `i`: compare (registering frozen references), then episodes with the stored and
    /// newly registered frozen references.
    static func run(_ all: [PC.DailyValue], at i: Int, frozen: [PC.FrozenReference] = [],
                    boundaries: [PC.RegimeBoundary] = [], change: PC.ChangeConfig = .init(),
                    reference: PC.ReferenceConfig = .init())
        -> (episodes: [PC.ChangeEpisode], comparisons: [PC.ReferenceComparison], frozen: [PC.FrozenReference]) {
        let d = day(i)
        let today = all.filter { $0.day == d }
        let history = all.filter { $0.day < d }
        let c = Ref.compare(today, history: history, frozen: frozen, day: d, policyFingerprint: "fp", config: reference)
        let f = frozen + c.newFrozen
        let eps = CD.episodes(today: today, history: history, frozen: f, boundaries: boundaries, day: d,
                              mode: .retrospective, finality: .final, policyFingerprint: "fp", change: change,
                              reference: reference)
        return (eps, c.comparisons, f)
    }

    static func contains(_ e: PC.ChangeEpisode, _ i: Int) -> Bool { e.startDay <= day(i) && e.lastDay >= day(i) }

    static func scenario(days: Int, phi: Double = 0) -> E.Scenario {
        var s = E.Scenario(); s.days = days; s.phi = phi; return s
    }

    // MARK: V11

    /// Quiet deterministic day-to-day variation (≈ ±0.8 SD, no trend, weak autocorrelation).
    static func quiet(_ n: Int) -> [Double?] { (0..<n).map { Double(($0 * 37) % 7 - 3) / 3.75 } }

    func testIsolatedArtifactIsTransientRawIsPreservedAndTheReferenceIsNotContaminated() throws {
        var xs = Self.quiet(100)
        let without = Self.values(pattern: xs)
        xs[70] = 10
        let with = Self.values(pattern: xs)
        let out = Self.run(with, at: 99)
        let around = out.episodes.filter { Self.contains($0, 70) && $0.direction != 0 }
        XCTAssertEqual(around.map(\.state), [.transientDeviation], "\(out.episodes)")
        XCTAssertEqual(around.first?.direction, 1)
        XCTAssertEqual(around.first?.startDay, Self.day(70))
        XCTAssertEqual(around.first?.durationDays, 1)
        XCTAssertFalse(out.episodes.contains { $0.state == .persistentShift })
        XCTAssertEqual(Self.run(without, at: 99).episodes.map(\.state), [.usualVariation])
        // Raw value preserved and scored as an extreme distance on its own day.
        let artifact = try XCTUnwrap(with.first { $0.day == Self.day(70) })
        XCTAssertEqual(artifact.value, exp(Self.spec.center + Self.spec.sigma * 10), accuracy: 1e-9)
        let a70 = Self.run(with, at: 70).comparisons.first { $0.view == .rolling }!
        XCTAssertEqual(a70.value, artifact.value)
        XCTAssertGreaterThan(try XCTUnwrap(a70.robustZ), 5)
        // The days after it see (almost) the same reference as without the artifact (median, 50 % breakdown).
        for i in [71, 80, 90] {
            let cw = Self.run(with, at: i).comparisons.first { $0.view == .rolling }!
            let cb = Self.run(without, at: i).comparisons.first { $0.view == .rolling }!
            XCTAssertLessThan(abs(cw.transformedCenter! - cb.transformedCenter!), 0.25 * Self.spec.sigma, "day \(i)")
            XCTAssertLessThan(cw.scale! / cb.scale!, 1.35, "day \(i)")
        }
    }

    func testSustainedStepIsAPersistentShiftWithItsDelayAndMagnitude() throws {
        var s = Self.scenario(days: 100); s.stepDay = 70; s.stepSigma = -3
        let out = Self.run(Self.values(s, seed: 12), at: 79)
        let shift = try XCTUnwrap(out.episodes.first { $0.state == .persistentShift && $0.direction == -1 && $0.ongoing },
                                  "\(out.episodes)")
        // The CUSUM change-point estimate (first day of the S > 0 run) can precede the step when noise had
        // already started a run; it never follows the alarm.
        XCTAssertGreaterThanOrEqual(shift.startDay, Self.day(60))
        XCTAssertLessThanOrEqual(shift.startDay, Self.day(71))
        let alarm = try XCTUnwrap(shift.alarmDay)
        XCTAssertGreaterThanOrEqual(alarm, Self.day(70))
        XCTAssertLessThanOrEqual(alarm, Self.day(76))
        XCTAssertEqual(shift.detectionDelayDays, Ref.dayNumber(alarm)! - Ref.dayNumber(shift.startDay)!)
        XCTAssertEqual(shift.detector, "cusum")
        XCTAssertTrue(shift.reasons.contains(CD.detectorCusum))
        XCTAssertTrue(shift.reasons.contains(CD.frozenAndRollingAgree))
        XCTAssertTrue(shift.reasons.contains(CD.descriptiveOnly))
        // Magnitude in original units: 3 SD of 0.12 ln below 45 ms is about −13.6 ms.
        XCTAssertLessThan(try XCTUnwrap(shift.frozenMagnitude), -8)
        XCTAssertLessThan(try XCTUnwrap(shift.rollingMagnitude), -5)
        XCTAssertLessThan(try XCTUnwrap(shift.medianFrozenZ), -2)
        XCTAssertEqual(shift.units, "ms")
        XCTAssertEqual(shift.transform, "ln")
        XCTAssertGreaterThan(shift.supportDays, 0)
    }

    func testRollingAdaptsWhileTheFrozenDeviationStaysVisible() throws {
        var s = Self.scenario(days: 100); s.stepDay = 50; s.stepSigma = -4
        let out = Self.run(Self.values(s, seed: 13), at: 99)
        let rolling = try XCTUnwrap(out.comparisons.first { $0.view == .rolling })
        let frozen = try XCTUnwrap(out.comparisons.first { $0.view == .frozen })
        XCTAssertLessThan(abs(try XCTUnwrap(rolling.robustZ)), 2.5, "the 28-day reference now describes the new level")
        XCTAssertLessThan(try XCTUnwrap(frozen.robustZ), -2, "the historical reference still shows the shift")
        let shift = try XCTUnwrap(out.episodes.first { $0.state == .persistentShift && $0.direction == -1 && $0.ongoing },
                                  "\(out.episodes)")
        XCTAssertTrue(shift.reasons.contains(CD.rollingAdaptedFrozenDeviationPersists) || shift.detector == "frozen_persistence",
                      "\(shift.reasons)")
        XCTAssertLessThan(try XCTUnwrap(shift.frozenMagnitude), -10)
        XCTAssertEqual(shift.frozenReferenceId, out.frozen.first?.id)
    }

    func testGradualDriftKeepsTheFrozenDeviationAndTheRawTrendVisible() throws {
        var s = Self.scenario(days: 100); s.driftStartDay = 40; s.driftSigmaPerDay = -0.06
        let out = Self.run(Self.values(s, seed: 14), at: 99)
        let rolling = try XCTUnwrap(out.comparisons.first { $0.view == .rolling }?.robustZ)
        let frozen = try XCTUnwrap(out.comparisons.first { $0.view == .frozen }?.robustZ)
        XCTAssertLessThan(frozen, -2)
        XCTAssertLessThan(frozen, rolling - 1, "fixed reference shows more of the drift than the adaptive one")
        XCTAssertTrue(out.episodes.contains { $0.state == .persistentShift && $0.direction == -1 && $0.ongoing },
                      "\(out.episodes)")
        // Raw trend: Theil–Sen over the window, ms per week. True slope mid-drift ≈ 45·e^(−0.12·1.8)·0.12·0.06·7.
        let trend = try XCTUnwrap(out.episodes.compactMap(\.trendPerWeek).first)
        let truth = -45 * exp(-0.12 * 1.8) * 0.12 * 0.06 * 7
        XCTAssertLessThan(trend, 0)
        XCTAssertGreaterThan(trend / truth, 0.3)
        XCTAssertLessThan(trend / truth, 1.5)
        XCTAssertTrue(out.episodes.allSatisfy { $0.trendDays > 0 })
    }

    // MARK: V12

    func testSparseHistoryIsInsufficientEvidenceWithoutDistances() throws {
        let vals = Self.values(pattern: [0.1, -0.2, 0.0])
        let out = Self.run(vals, at: 2)
        XCTAssertEqual(out.episodes.count, 1)
        let e = out.episodes[0]
        XCTAssertEqual(e.state, .insufficientEvidence)
        XCTAssertEqual(e.direction, 0)
        XCTAssertTrue(e.reasons.contains(CD.tooFewSupportedDays))
        XCTAssertTrue(e.reasons.contains(CD.noReference))
        XCTAssertNil(e.medianRollingZ)
        XCTAssertTrue(out.comparisons.allSatisfy { $0.robustZ == nil })
        XCTAssertNoThrow(try PC.encoder().encode(out.episodes))
    }

    func testMissingDaysAreSkippedNotZeroFilledAndALongGapResetsTheDetector() throws {
        // Every other day missing: only present days are scored; calendar durations stay calendar days.
        var xs: [Double?] = (0..<80).map { $0 % 2 == 0 ? 0.3 * Double(($0 * 7) % 5 - 2) / 2 : nil }
        let sparse = Self.run(Self.values(pattern: xs), at: 78)
        let status = try XCTUnwrap(sparse.episodes.first { $0.direction == 0 })
        XCTAssertEqual(status.state, .usualVariation)
        XCTAssertLessThanOrEqual(status.supportDays, 40)
        XCTAssertGreaterThan(status.durationDays, status.supportDays)
        // A shift that ends in a 10-day gap: the episode closes at the gap (no bridging across it).
        xs = (0..<100).map { Double(($0 * 7) % 5 - 2) * 0.2 }
        for i in 50..<56 { xs[i] = -4 }
        for i in 56..<66 { xs[i] = nil }
        let gap = Self.run(Self.values(pattern: xs), at: 99)
        let shift = try XCTUnwrap(gap.episodes.first { $0.state == .persistentShift && $0.direction == -1 }, "\(gap.episodes)")
        XCTAssertTrue(shift.reasons.contains(CD.gapReset), "\(shift.reasons)")
        XCTAssertLessThanOrEqual(shift.lastDay, Self.day(55))
        XCTAssertFalse(shift.ongoing)
    }

    func testConstantSeriesIsUsualVariationWithFlooredFiniteDistances() throws {
        let vals = Self.values(pattern: Array(repeating: 0.0, count: 60))
        let out = Self.run(vals, at: 59)
        XCTAssertEqual(out.episodes.map(\.state), [.usualVariation])
        let rolling = try XCTUnwrap(out.comparisons.first { $0.view == .rolling })
        XCTAssertEqual(rolling.robustZ, 0)
        XCTAssertTrue(rolling.scaleFloored)
        XCTAssertEqual(rolling.scale, 0.05)
        XCTAssertNoThrow(try PC.encoder().encode(out.episodes))
        XCTAssertNoThrow(try PC.encoder().encode(out.comparisons))
    }

    // MARK: V10 and determinism

    func testAppendingFutureDaysNeverChangesAnEarlierDaysEpisodes() throws {
        var s = Self.scenario(days: 140, phi: 0.3); s.stepDay = 60; s.stepSigma = -2.5
        let all = Self.values(s, seed: 15)
        let d = Self.day(80)
        let today = all.filter { $0.day == d }
        let past = all.filter { $0.day < d }
        let frozen = Self.run(all, at: 80).frozen
        func eps(_ h: [PC.DailyValue]) -> [PC.ChangeEpisode] {
            CD.episodes(today: today, history: h, frozen: frozen, boundaries: [], day: d, mode: .retrospective,
                        finality: .final, policyFingerprint: "fp", change: .init(), reference: .init())
        }
        let a = eps(past), b = eps(all)               // `all` also holds days 81…139
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(try PC.encoder().encode(a), try PC.encoder().encode(b))
        // Frozen references from the future are not used either.
        let future = PC.FrozenReference(id: "frz_future", seriesKey: Self.spec.seriesKey, regimeKey: Self.spec.regimeKey,
                                        version: 1, fromDay: Self.day(90), toDay: Self.day(110), supportDays: 14,
                                        center: 1, scale: 0.1, transform: "ln", selectionRule: "x",
                                        createdForDay: Self.day(111), policyFingerprint: "fp")
        let c = CD.episodes(today: today, history: past, frozen: frozen + [future], boundaries: [], day: d,
                            mode: .retrospective, finality: .final, policyFingerprint: "fp", change: .init(),
                            reference: .init())
        XCTAssertEqual(c, a)
    }

    func testEpisodeIdsAreDeterministicAndInputOrderDoesNotMatter() throws {
        var s = Self.scenario(days: 100); s.stepDay = 70; s.stepSigma = -3
        let vals = Self.values(s, seed: 12)
        let a = Self.run(vals, at: 79).episodes
        var g = E.SeededGenerator(seed: 3)
        let b = Self.run(vals.shuffled(using: &g), at: 79).episodes
        XCTAssertEqual(a, b)
        for e in a {
            XCTAssertEqual(e.id, "ep_" + PC.fnv1a("\(e.seriesKey)|\(e.regimeKey)|\(e.startDay)|\(e.direction)|fp"))
        }
        XCTAssertEqual(Set(a.map(\.id)).count, a.count)
        let decoded = try PC.decoder().decode([PC.ChangeEpisode].self, from: PC.encoder().encode(a))
        XCTAssertEqual(decoded, a)
    }

    // MARK: Regimes

    func testRegimeBoundarySplitsTheSeriesAndIsReportedSeparately() throws {
        var s = Self.scenario(days: 90); s.stepDay = 60; s.stepSigma = -4
        let vals = Self.values(s, seed: 16)
        let boundary = PC.RegimeBoundary(at: (Self.first + 60) * 86_400 + 3600, kind: "placement",
                                         fromValue: "wrist", toValue: "bicep")
        let with = Self.run(vals, at: 70, boundaries: [boundary]).episodes
        let shift = try XCTUnwrap(with.first { $0.state == .persistentShift && $0.direction == -1 }, "\(with)")
        XCTAssertGreaterThanOrEqual(shift.startDay, Self.day(60), "never merged across the boundary")
        XCTAssertTrue(shift.reasons.contains(CD.coincidesWithRegimeBoundary))
        let without = Self.run(vals, at: 70).episodes
        let plain = try XCTUnwrap(without.first { $0.state == .persistentShift && $0.direction == -1 })
        XCTAssertFalse(plain.reasons.contains(CD.coincidesWithRegimeBoundary))
        // A new regime key is its own series: its days are never scored against the old regime.
        let a = vals.filter { $0.day < Self.day(60) }
        let b = vals.filter { $0.day >= Self.day(60) }.map { v -> PC.DailyValue in var w = v; w.regimeKey = "bicep"; return w }
        let split = Self.run(a + b, at: 70).episodes
        XCTAssertTrue(split.filter { $0.regimeKey == "bicep" }.allSatisfy { $0.state == .insufficientEvidence })
        XCTAssertTrue(split.filter { $0.regimeKey == Self.spec.regimeKey }.allSatisfy { $0.lastDay < Self.day(60) })
    }

    // MARK: Recurrence and detector choice

    func testRepeatedIsolatedExcursionsFormOneRecurringEpisode() throws {
        var xs: [Double?] = (0..<90).map { $0 % 2 == 0 ? 0.3 : -0.3 }
        for i in [55, 63, 71] { xs[i] = -4 }
        let out = Self.run(Self.values(pattern: xs), at: 89).episodes
        let rec = try XCTUnwrap(out.first { $0.state == .recurringEpisode }, "\(out)")
        XCTAssertEqual(rec.direction, -1)
        XCTAssertEqual(rec.occurrences, 3)
        XCTAssertEqual(rec.startDay, Self.day(55))
        XCTAssertEqual(rec.lastDay, Self.day(71))
        XCTAssertFalse(out.contains { $0.state == .persistentShift })
        XCTAssertFalse(out.contains { $0.state == .transientDeviation && $0.direction == -1 })
    }

    func testPersistenceRuleCanBeSelectedAndIsComparedWithTheCusum() throws {
        var s = Self.scenario(days: 100); s.stepDay = 70; s.stepSigma = -3
        var change = PC.ChangeConfig(); change.detector = "persistence"
        let out = Self.run(Self.values(s, seed: 12), at: 79, change: change).episodes
        let shift = try XCTUnwrap(out.first { $0.state == .persistentShift && $0.direction == -1 }, "\(out)")
        XCTAssertEqual(shift.detector, "persistence")
        XCTAssertTrue(shift.reasons.contains(CD.detectorPersistence))
        XCTAssertTrue(shift.reasons.contains(CD.alternativeDetectorAgrees))
    }

    // MARK: Registry and policy

    func testEveryEmittedReasonCodeIsRegisteredAndThePolicyRoundTrips() throws {
        let registry = Set(Ref.reasonCodes + CD.reasonCodes)
        var emitted = Set<PC.ReasonCode>()
        var s = Self.scenario(days: 120, phi: 0.3); s.stepDay = 60; s.stepSigma = -3; s.artifactDays = [30]
        s.missingRate = 0.2
        for seed in 0..<6 as Range<UInt64> {
            let vals = Self.values(s, seed: 100 + seed)
            for i in [10, 59, 75, 119] {
                let out = Self.run(vals, at: i)
                out.episodes.forEach { emitted.formUnion($0.reasons) }
                out.comparisons.forEach { emitted.formUnion($0.reasons) }
            }
        }
        var xs = Self.quiet(90); for i in [55, 63, 71] { xs[i] = -4 }
        Self.run(Self.values(pattern: xs), at: 89).episodes.forEach { emitted.formUnion($0.reasons) }
        XCTAssertTrue(emitted.isSubset(of: registry), "unregistered: \(emitted.subtracting(registry).sorted())")
        XCTAssertEqual(registry.count, Ref.reasonCodes.count + CD.reasonCodes.count, "codes are unique")
        // Every reference / change tunable survives the canonical snake_case JSON round trip.
        var policy = PC.Policy()
        policy.change.cusumH = 6.5; policy.reference.frozenRegistrationModes = [.retrospective, .causalLive]
        let data = try PC.encoder().encode(policy)
        XCTAssertEqual(try PC.decoder().decode(PC.Policy.self, from: data), policy)
    }

    // MARK: V13 multi-signal

    static func comparison(_ series: String, z: Double?, view: PC.ReferenceView = .rolling,
                           status: PC.ReferenceStatus = .ready) -> PC.ReferenceComparison {
        PC.ReferenceComparison(day: day(0), seriesKey: series, regimeKey: "r", view: view, referenceId: nil,
                               status: status, supportDays: 20, fromDay: nil, toDay: nil, value: 1, center: 1,
                               scale: 1, scaleFloored: false, signedDifference: 0, transformedDifference: nil,
                               robustZ: z, centerUncertainty: nil, transform: "identity", pooledContribution: 0,
                               reasons: [])
    }

    static var notes: [PC.DependenceNote] {
        PC.Engine.dependenceNotes(sleep: .unavailable([]))
    }

    func testHrvAndRespiratoryRateDeviatingTogetherAreOneIndependentGroup() throws {
        let cs = [Self.comparison("hrv_rmssd.sleep_night", z: -3.2), Self.comparison("resp_rate.sleep_night", z: 3.0),
                  Self.comparison("resting_hr.sleep_night", z: 0.5),
                  Self.comparison("hrv_rmssd.sleep_night", z: -6, view: .frozen)]
        let out = CD.multiSignal(comparisons: cs, dependence: Self.notes, day: Self.day(0), config: .init())
        let m = try XCTUnwrap(out.first)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(m.deviatingSeries, ["hrv_rmssd.sleep_night", "resp_rate.sleep_night"])
        XCTAssertEqual(m.independentGroupCount, 1)
        XCTAssertTrue(m.dependenceGroups.contains("beat_intervals"))
        XCTAssertTrue(m.reasons.contains(CD.sharedInputsNotIndependent))
        XCTAssertTrue(m.reasons.contains(CD.selectionReadsHeartRate))
        XCTAssertEqual(m.components.count, 1)
    }

    func testOnlySeriesWithoutSharedDeclaredInputsCountAsSeparateGroups() throws {
        let cs = [Self.comparison("hrv_rmssd.sleep_night", z: -3), Self.comparison("functional.bouts_per_worn_hour", z: -3),
                  Self.comparison("hrv_rmssd.stable_awake_5min.band_06_12", z: -9, view: .conditioned),
                  Self.comparison("heart_rate.stable_awake_5min", z: 8, status: .insufficient)]
        let m = try XCTUnwrap(CD.multiSignal(comparisons: cs, dependence: Self.notes, day: Self.day(0), config: .init()).first)
        XCTAssertEqual(m.deviatingSeries, ["functional.bouts_per_worn_hour", "hrv_rmssd.sleep_night"])
        XCTAssertEqual(m.independentGroupCount, 2)
        XCTAssertTrue(m.reasons.contains(CD.groupsNotProvenIndependent))
        XCTAssertFalse(m.reasons.contains(CD.sharedInputsNotIndependent))
        // Stable-awake HRV and a functional feature share the stillness selection (strap motion): one group.
        let shared = [Self.comparison("hrv_rmssd.stable_awake_5min", z: -3), Self.comparison("functional.bouts_per_worn_hour", z: -3)]
        XCTAssertEqual(CD.multiSignal(comparisons: shared, dependence: Self.notes, day: Self.day(0), config: .init())
                        .first?.independentGroupCount, 1)
        // Nothing deviating: an explicit empty summary; nothing compared: no summary.
        let calm = CD.multiSignal(comparisons: [Self.comparison("hrv_rmssd.sleep_night", z: 0.2)], dependence: Self.notes,
                                  day: Self.day(0), config: .init())
        XCTAssertEqual(calm.first?.independentGroupCount, 0)
        XCTAssertEqual(calm.first?.reasons, [CD.noDeviatingSeries])
        XCTAssertTrue(CD.multiSignal(comparisons: [], dependence: Self.notes, day: Self.day(0), config: .init()).isEmpty)
    }
}
