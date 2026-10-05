import Foundation
import XCTest
@testable import StrandAnalytics

/// The synthetic evaluation harness: determinism, generator properties, the CUSUM against published known-parameter
/// ARL values, and bounds on false episodes, detection delay, drift visibility and artifact handling for the default
/// policy. Fixed seeds; these are arithmetic checks on synthetic series, not physiological accuracy.
final class PCEvaluationTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias E = PhysiologyContext.Evaluation

    static let seed: UInt64 = 20_261_005

    func testHarnessIsDeterministicForASeed() {
        let a = E.evaluateNull(phi: 0.3, replicates: 30, resamples: 100, seed: Self.seed)
        let b = E.evaluateNull(phi: 0.3, replicates: 30, resamples: 100, seed: Self.seed)
        XCTAssertEqual(a, b)
        let c = E.evaluateNull(phi: 0.3, replicates: 30, resamples: 100, seed: Self.seed + 1)
        XCTAssertNotEqual(a.excursions.events, c.excursions.events)
        XCTAssertEqual(E.evaluateStep(phi: 0.3, magnitudeSigma: -2, replicates: 20, resamples: 50, seed: Self.seed),
                       E.evaluateStep(phi: 0.3, magnitudeSigma: -2, replicates: 20, resamples: 50, seed: Self.seed))
    }

    func testGeneratorHasTheRequestedMarginalSpreadAutocorrelationAndMissingness() {
        var s = E.Scenario(); s.days = 40_000; s.phi = 0.5; s.missingRate = 0.3; s.artifactDays = [10, 20, 30]
        let xs = E.generate(s, seed: 1)
        let present = xs.compactMap { $0 }
        let all = E.generate({ var t = s; t.missingRate = 0; t.artifactDays = []; return t }(), seed: 1).map { $0! }
        let m: Double = all.reduce(0, +) / Double(all.count)
        let dev: [Double] = all.map { $0 - m }
        let ss: Double = dev.map { $0 * $0 }.reduce(0, +)
        let sd: Double = (ss / Double(all.count - 1)).squareRoot()
        var lag: Double = 0
        for i in 1..<dev.count { lag += dev[i] * dev[i - 1] }
        let r1: Double = lag / ss
        XCTAssertEqual(sd, 1, accuracy: 0.05)
        XCTAssertEqual(r1, 0.5, accuracy: 0.03)
        XCTAssertEqual(Double(xs.count - present.count) / Double(xs.count), 0.3, accuracy: 0.02)
        XCTAssertTrue([10, 20, 30].allSatisfy { xs[$0] != nil })
        var c = E.Scenario(); c.days = 50; c.constant = true
        XCTAssertTrue(E.generate(c, seed: 2).allSatisfy { $0 == 0 })
    }

    func testSmallSampleMadFactorIsUnbiasedAtGaussianData() {
        for n in [3, 5, 7, 10, 28] {
            let r = E.madFactorCheck(n: n, replicates: 20_000, seed: E.streamSeed(Self.seed, "mad", n))
            XCTAssertEqual(r.corrected, 1, accuracy: 0.03, "n=\(n)")
        }
        // Rousseeuw & Croux 1993, Table 1: the raw normal-consistent MAD averages 0.911 σ at n = 10.
        XCTAssertEqual(E.madFactorCheck(n: 10, replicates: 20_000, seed: 3).raw, 0.911, accuracy: 0.015)
    }

    func testCusumReproducesKnownParameterArlUnderAutocorrelation() {
        // Research note 8 (our computation there): two-sided k = 0.5, h = 4 → ARL0 ≈ 168–172 (iid), ≈ 54 (φ = 0.3),
        // ≈ 35 (φ = 0.5). 300 replicates → standard error ≈ ARL / 17.
        let iid = E.knownParameterARL(phi: 0, k: 0.5, h: 4, replicates: 300, seed: Self.seed)
        let p3 = E.knownParameterARL(phi: 0.3, k: 0.5, h: 4, replicates: 300, seed: Self.seed)
        let p5 = E.knownParameterARL(phi: 0.5, k: 0.5, h: 4, replicates: 300, seed: Self.seed)
        XCTAssertEqual(iid.censored, 0)
        XCTAssertEqual(iid.mean, 170, accuracy: 30)
        XCTAssertEqual(p3.mean, 54, accuracy: 12)
        XCTAssertEqual(p5.mean, 35, accuracy: 9)
    }

    func testNullFalseEpisodeRateIsBoundedAndDoesNotDependOnAutocorrelation() {
        let rates = [0.0, 0.3, 0.5].map { E.evaluateNull(phi: $0, replicates: 120, resamples: 100, seed: Self.seed) }
        for r in rates {
            XCTAssertLessThan(r.primary.perWeek, 0.06, "φ=\(r.phi)")
            XCTAssertLessThanOrEqual(r.primary.ciLow, r.primary.perWeek)
            XCTAssertGreaterThanOrEqual(r.primary.ciHigh, r.primary.perWeek)
        }
        // The autocorrelation adjustment keeps the rate roughly flat in φ ...
        XCTAssertLessThan(rates[2].primary.perWeek, 2 * max(0.01, rates[0].primary.perWeek))
        // ... whereas the unadjusted classic CUSUM (k = 0.5, h = 4) multiplies false episodes as φ grows.
        var classic = PC.ChangeConfig()
        classic.cusumAutocorrelationAdjustment = false; classic.cusumK = 0.5; classic.cusumH = 4; classic.cusumClampZ = 1e6
        let c0 = E.evaluateNull(phi: 0, replicates: 120, change: classic, resamples: 50, seed: Self.seed)
        let c5 = E.evaluateNull(phi: 0.5, replicates: 120, change: classic, resamples: 50, seed: Self.seed)
        XCTAssertGreaterThan(c5.primary.perWeek, 2 * c0.primary.perWeek)
        XCTAssertGreaterThan(c5.primary.perWeek, 2 * rates[2].primary.perWeek)
    }

    func testStepsAreDetectedWithBoundedDelayAndTheCusumBeatsThePersistenceRule() {
        let two = E.evaluateStep(phi: 0.3, magnitudeSigma: -2, replicates: 120, resamples: 100, seed: Self.seed)
        XCTAssertLessThan(two.primary.missedShare, 0.12)
        XCTAssertLessThanOrEqual(try XCTUnwrap(two.primary.medianDelay), 9)
        XCTAssertLessThan(two.primary.missedShare, two.alternative.missedShare, "persistence rule misses more")
        XCTAssertGreaterThan(two.rollingAdaptedShare, 0.8, "the 28-day reference absorbs a sustained step")
        let one = E.evaluateStep(phi: 0.3, magnitudeSigma: -1, replicates: 120, resamples: 100, seed: Self.seed)
        XCTAssertLessThan(one.primary.missedShare, 0.65)
        XCTAssertGreaterThan(one.primary.missedShare, two.primary.missedShare)
    }

    func testDriftKeepsTheFrozenDeviationVisibleAndReportsTheTrend() {
        let d = E.evaluateDrift(phi: 0.3, perDaySigma: -0.05, replicates: 60, seed: Self.seed)
        XCTAssertLessThan(d.finalFrozenZ, -2)
        XCTAssertGreaterThan(d.finalRollingZ, d.finalFrozenZ + 1)
        XCTAssertGreaterThan(d.ongoingPersistentShare, 0.7)
        XCTAssertGreaterThan(d.trendRatio, 0.4)
        XCTAssertLessThan(d.trendRatio, 1.3)
    }

    func testIsolatedArtifactIsMostlyTransientAndBarelyMovesTheReference() {
        let a = E.evaluateArtifact(phi: 0.3, magnitudeSigma: 8, replicates: 150, seed: Self.seed)
        XCTAssertGreaterThan(a.transientShare, 0.8)
        XCTAssertLessThan(a.maxCenterShiftSigma, 0.2)
        XCTAssertLessThan(a.maxScaleRatio, 1.3)
        XCTAssertLessThan(a.persistentShare, a.persistentShareWithoutArtifact + 0.08)
        XCTAssertTrue(a.rawPreserved)
    }

    func testBlockBootstrapWidensForDependentData() throws {
        var s = E.Scenario(); s.days = 400; s.phi = 0.8
        let units = (0..<20).map { r in E.generate(s, seed: E.streamSeed(9, "boot", r)).map { $0! } }
        let iid = try XCTUnwrap(E.stationaryBootstrapMeanCI(units, meanBlock: 1, resamples: 400, seed: 1))
        let block = try XCTUnwrap(E.stationaryBootstrapMeanCI(units, meanBlock: 20, resamples: 400, seed: 1))
        XCTAssertGreaterThan(block.hi - block.lo, 1.8 * (iid.hi - iid.lo))
        XCTAssertLessThan(block.lo, 0)
        XCTAssertGreaterThan(block.hi, 0)
        let p = try XCTUnwrap(E.percentileBootstrapCI((0..<200).map(Double.init), statistic: { PC.RobustStats.median($0) },
                                                      resamples: 400, seed: 2))
        XCTAssertLessThan(p.lo, 99.5)
        XCTAssertGreaterThan(p.hi, 99.5)
        XCTAssertNil(E.stationaryBootstrapMeanCI([], meanBlock: 4, resamples: 10, seed: 1))
    }
}
