import XCTest
@testable import StrandAnalytics

/// Tests for `DetachShadow` — the DETACH-derived non-wear SHADOW (never authoritative).
///
/// The shadow is pure and deterministic; every test replays a fixed synthetic epoch sequence
/// and asserts the exact verdict and (via `@testable`) the rolling-window buffer. The
/// resolution-dependent and raw-temperature thresholds are CALIBRATE placeholders (DETACH's
/// 60-100 Hz per-axis-SD thresholds do not transfer to 4-s/1-Hz aggregates, and raw WHOOP
/// temperature carries per-device offsets) — these tests assert the LOGIC, not the calibration.
final class DetachShadowTests: XCTestCase {

    // MARK: - Helpers

    /// One epoch at 30 s grid `k` with a given energy/temp (nil = missing channel).
    private func epoch(_ k: Int, energy: Double?, temp: Double?) -> DetachShadowEpoch {
        DetachShadowEpoch(epochStart: k * 30, imuEnergyG: energy, skinTempCelsius: temp)
    }

    /// Covered, quiet (below quiescence threshold), cold (below temp band).
    private func quietCold(_ k: Int) -> DetachShadowEpoch { epoch(k, energy: 0.005, temp: 28.0) }

    /// Covered, noisy (above quiescence threshold).
    private func noisy(_ k: Int) -> DetachShadowEpoch { epoch(k, energy: 0.5, temp: 28.0) }

    /// Covered, quiet but warm (above temp band, not falling).
    private func warm(_ k: Int) -> DetachShadowEpoch { epoch(k, energy: 0.005, temp: 33.0) }

    /// Neither channel present (uncovered).
    private func missing(_ k: Int) -> DetachShadowEpoch { epoch(k, energy: nil, temp: nil) }

    /// Energy only — covered requires BOTH channels, so this stays uncovered.
    private func energyOnly(_ k: Int) -> DetachShadowEpoch { epoch(k, energy: 0.005, temp: nil) }

    private func run(_ sequence: [DetachShadowEpoch],
                     config: DetachShadowConfig = .standard,
                     state: inout DetachShadowState) -> [Bool?] {
        sequence.map { DetachShadow.evaluate($0, config: config, state: &state) }
    }

    // MARK: - Version / determinism

    func testVersionIsDetachShadow100() {
        XCTAssertEqual(DetachShadowConfig.standard.version, "detach-shadow-1.0.0")
        XCTAssertEqual(DetachShadowConfig().version, "detach-shadow-1.0.0")
    }

    func testDeterministicSameSequenceSameVerdict() {
        var s1 = DetachShadowState()
        var s2 = DetachShadowState()
        let seq = (0..<20).map { $0 < 15 ? quietCold($0) : noisy($0) }
        let v1 = run(seq, state: &s1)
        let v2 = run(seq, state: &s2)
        XCTAssertEqual(v1, v2)
        XCTAssertEqual(s1.slots, s2.slots)
        XCTAssertEqual(s1.lastCoveredTempCelsius, s2.lastCoveredTempCelsius)
    }

    // MARK: - Verdicts (default 15-window / 12-12-12 config)

    func testAllCoveredQuietColdSpeaksTrue() {
        var state = DetachShadowState()
        let verdicts = run((0..<15).map(quietCold), state: &state)
        // Before the window fills, coverage is too low to speak — abstain until >= 12 covered.
        XCTAssertEqual(Array(verdicts.prefix(11)), Array(repeating: nil, count: 11))
        XCTAssertEqual(verdicts[11], true, "12 covered windows reach the coverage gate")
        XCTAssertEqual(verdicts[14], true)
    }

    func testQuietAloneWithWarmTempIsNotNonWear() {
        var state = DetachShadowState()
        let verdicts = run((0..<15).map(warm), state: &state)
        XCTAssertEqual(verdicts[14], false, "quiet + warm (above band, not falling) is not non-wear")
    }

    func testMotionBreaksQuiescenceAndRollsOut() {
        var state = DetachShadowState()
        // 12 quiet+cold then 3 noisy: 12/15 quiescent -> still a candidate.
        let seqA = (0..<12).map(quietCold) + (12..<15).map(noisy)
        XCTAssertEqual(run(seqA, state: &state).last!, true)
        // 16th epoch (noisy): window now holds 11 quiet + 4 noisy -> quiescence fails.
        let next = DetachShadow.evaluate(noisy(15), state: &state)
        XCTAssertEqual(next, false)
        XCTAssertEqual(state.slots.lazy.filter { $0.quiescent }.count, 11)
    }

    func testWarmRollsOutOnceFallingStops() {
        var state = DetachShadowState()
        // Temps fall 0.5 C per epoch from 36.0 down to ~29.0: falling channel (offset-invariant).
        var seq = [DetachShadowEpoch]()
        for k in 0..<15 {
            seq.append(epoch(k, energy: 0.005, temp: 36.0 - Double(k) * 0.5))
        }
        XCTAssertEqual(run(seq, state: &state).last!, true, "falling temp carries the temp condition")
        // A flat WARM plateau afterwards rolls the falling flags out of the window (cold-but-flat
        // would stay a candidate: below-band ALONE satisfies the temp condition per the rule).
        var plateau = [Bool?]()
        for k in 15..<30 {
            plateau.append(DetachShadow.evaluate(warm(k), state: &state))
        }
        XCTAssertEqual(plateau[2], true, "falling flags just rolled to exactly 12 -> still a candidate")
        XCTAssertEqual(plateau[3], false, "11 falling slots left in the window -> not a candidate")
        XCTAssertEqual(plateau[14], false)
    }

    func testFallingBelowMinimumDeltaDoesNotCount() {
        var state = DetachShadowState()
        // Temps fall only 0.1 C per epoch (< 0.2 delta) and stay above the band: neither
        // below-band nor falling — never a candidate.
        var seq = [DetachShadowEpoch]()
        for k in 0..<15 { seq.append(epoch(k, energy: 0.005, temp: 33.0 - Double(k) * 0.1)) }
        let verdicts = run(seq, state: &state)
        XCTAssertEqual(verdicts[14], false)
    }

    // MARK: - Coverage / abstention

    func testCoverageBelowMinimumAbstainsEvenWhenQuietCold() {
        var state = DetachShadowState()
        // 10 covered + 5 missing: coverage 10 < 12 -> abstain forever, never a verdict.
        let seq = (0..<10).map(quietCold) + (10..<15).map(missing)
        let verdicts = run(seq, state: &state)
        XCTAssertEqual(verdicts.last!, nil)
        XCTAssertTrue(verdicts.allSatisfy { $0 == nil })
    }

    func testAllMissingChannelsAbstains() {
        var state = DetachShadowState()
        let verdicts = run((0..<15).map(missing), state: &state)
        XCTAssertEqual(verdicts.last!, nil)
        XCTAssertEqual(state.slots.lazy.filter { $0.covered }.count, 0)
    }

    func testMissingTempChannelIsUncovered() {
        var state = DetachShadowState()
        // Energy present, temp missing: uncovered (decision needs BOTH channels).
        let verdicts = run((0..<15).map(energyOnly), state: &state)
        XCTAssertEqual(verdicts.last!, nil)
        XCTAssertEqual(state.slots.lazy.filter { $0.covered }.count, 0)
    }

    func testExactCoverageBoundarySpeaksAtTwelve() {
        // 12 covered + 3 missing: exactly at the gate -> speaks true.
        var s1 = DetachShadowState()
        let seqA = (0..<12).map(quietCold) + (12..<15).map(missing)
        XCTAssertEqual(run(seqA, state: &s1).last!, true)

        // 11 covered + 4 missing: one short -> abstains.
        var s2 = DetachShadowState()
        let seqB = (0..<11).map(quietCold) + (11..<15).map(missing)
        XCTAssertEqual(run(seqB, state: &s2).last!, nil)
    }

    func testAbstentionDoesNotPoisonTheWindow() {
        var state = DetachShadowState()
        // 5 missing epochs (nil while coverage is low), then 15 covered quiet+cold.
        let seq = (0..<5).map(missing) + (5..<20).map(quietCold)
        let verdicts = run(seq, state: &state)
        XCTAssertEqual(verdicts[9], nil, "5 covered of 15 -> abstain")
        XCTAssertEqual(verdicts[14], nil, "10 covered of 15 -> still below the 12-window gate")
        XCTAssertEqual(verdicts[16], true, "12 covered of 15 -> speaks")
        XCTAssertEqual(verdicts[19], true)
        XCTAssertEqual(state.slots.count, 15)
    }

    // MARK: - Rolling-window mechanics

    func testDataGapResetsWindow() {
        var state = DetachShadowState()
        XCTAssertEqual(run((0..<15).map(quietCold), state: &state).last!, true)
        // Next epoch starts 300 s later (> 90 s gap): accumulators reset, 3 noisy epochs only.
        let v = DetachShadow.evaluate(epoch(25, energy: 0.5, temp: 28.0), state: &state)
        XCTAssertEqual(v, nil, "window was reset by the gap; coverage 1 < 12")
        XCTAssertEqual(state.slots.count, 1)
    }

    func testSmallWindowSlotBufferContent() {
        var config = DetachShadowConfig.standard
        config.windowCount = 4
        config.minCoverageWindows = 3
        config.minQuiescentWindows = 3
        var state = DetachShadowState()
        _ = run([quietCold(0), noisy(1), warm(2), missing(3)], config: config, state: &state)
        let slots = state.slots
        XCTAssertEqual(slots.count, 4)
        XCTAssertEqual(slots[0].covered, true);  XCTAssertEqual(slots[0].quiescent, true);  XCTAssertEqual(slots[0].tempCondition, true)
        XCTAssertEqual(slots[1].covered, true);  XCTAssertEqual(slots[1].quiescent, false); XCTAssertEqual(slots[1].tempCondition, true)
        XCTAssertEqual(slots[2].covered, true);  XCTAssertEqual(slots[2].quiescent, true);  XCTAssertEqual(slots[2].tempCondition, false)
        XCTAssertEqual(slots[3].covered, false); XCTAssertEqual(slots[3].quiescent, false); XCTAssertEqual(slots[3].tempCondition, false)
        // Coverage 3 >= 3, quiescent 2 < 3 -> not a candidate (false), never nil.
        XCTAssertEqual(state.lastCoveredTempCelsius, 33.0)
    }
}
