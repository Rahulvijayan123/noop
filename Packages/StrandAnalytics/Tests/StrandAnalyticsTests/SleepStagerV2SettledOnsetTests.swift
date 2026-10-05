import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The settled-onset rule: lying awake in bed before the wrist settles is wake, however still and low-HR it
/// was. Reported night: in bed at 01:47, still and 62–68 bpm from 01:52 but repositioning every 4–8 minutes,
/// staged light sleep from 01:52; asleep, by the wearer's account and a 40-minute motionless run, at 02:54.
final class SleepStagerV2SettledOnsetTests: XCTestCase {

    private let start = 1_791_190_077

    /// A wrist that holds still between brief repositionings every `everyMin` minutes (4 s each). With
    /// `everyMin` nil the wrist never moves.
    private func gravity(from t0: Int, durationS: Int, everyMin: Int?) -> [GravitySample] {
        (0..<durationS).map { i -> GravitySample in
            let minute = i / 60
            let shifting = everyMin.map { minute > 0 && minute % $0 == 0 && (i % 60) < 4 } ?? false
            return shifting ? GravitySample(ts: t0 + i, x: 0.35, y: 0.30, z: 0.87)
                            : GravitySample(ts: t0 + i, x: 0, y: 0, z: 1.0)
        }
    }

    private func heartRate(from t0: Int, durationS: Int, base: Int) -> [HRSample] {
        (0..<durationS).map { HRSample(ts: t0 + $0, bpm: base + ($0 / 90) % 3) }
    }

    private func firstSleep(_ segs: [StageSegment]) -> Int? { segs.first { $0.stage != "wake" }?.start }

    private func asleepMinutes(_ segs: [StageSegment]) -> Double {
        segs.filter { $0.stage != "wake" }.reduce(0.0) { $0 + Double($1.end - $1.start) } / 60.0
    }

    // MARK: - the rule on its own

    func testOnsetIsFirstSleepLabelOnceTheWristSettles() {
        let w = SleepStagerV2.settledOnsetEpochs
        // 40 epochs moving every fourth epoch, then settled for good; Viterbi called it all light.
        let settled = (0..<(40 + w)).map { $0 >= 40 || $0 % 4 != 0 }
        let labels = [String](repeating: "light", count: settled.count)
        XCTAssertEqual(SleepStagerV2.settledOnset(settled, labels), 33,
                       "the first run holding at most one move (the one at epoch 36) starts after the epoch-32 move")
    }

    func testOneStirInsideTheRunStillSettles() {
        let w = SleepStagerV2.settledOnsetEpochs
        var settled = [Bool](repeating: true, count: w + 10)
        settled[5] = false
        let labels = ["awake", "awake"] + [String](repeating: "light", count: w + 8)
        XCTAssertEqual(SleepStagerV2.settledOnset(settled, labels), 2,
                       "a single moved epoch is within tolerance; onset is the first sleep label")
    }

    func testWristThatNeverSettlesLeavesTheNightAlone() {
        let w = SleepStagerV2.settledOnsetEpochs
        let settled = (0..<(4 * w)).map { $0 % 8 != 0 }
        XCTAssertNil(SleepStagerV2.settledOnset(settled, [String](repeating: "light", count: settled.count)))
    }

    // MARK: - through the stager

    /// An hour lying awake (still, 64 bpm, shifting every 5 min), then five hours of settled sleep.
    func testLyingAwakeBeforeSettlingIsStagedWake() {
        let awakeS = 60 * 60, sleepS = 5 * 60 * 60
        let settleTs = start + awakeS
        let grav = gravity(from: start, durationS: awakeS, everyMin: 5)
            + gravity(from: settleTs, durationS: sleepS, everyMin: 90)
        let hr = heartRate(from: start, durationS: awakeS, base: 64)
            + heartRate(from: settleTs, durationS: sleepS, base: 58)
        let segs = SleepStagerV2.stageSession(start: start, end: settleTs + sleepS,
                                              grav: grav, hr: hr, rr: [], resp: [])
        // The awake hour's last shift is at minute 55; the wrist is settled from 55:04.
        let lastShiftEnd = start + 55 * 60 + 4
        let onset = try? XCTUnwrap(firstSleep(segs))
        XCTAssertGreaterThanOrEqual(onset ?? 0, lastShiftEnd,
                                    "no sleep before the wrist settles (onset \(String(describing: onset)))")
        XCTAssertLessThanOrEqual(onset ?? .max, settleTs + 5 * 60, "sleep starts soon after it settles")
        XCTAssertGreaterThan(asleepMinutes(segs), 4 * 60, "the settled five hours still stage as sleep")
    }

    func testNightThatSettlesAtOnceKeepsItsOnset() {
        let dur = 6 * 60 * 60
        let segs = SleepStagerV2.stageSession(
            start: start, end: start + dur,
            grav: gravity(from: start, durationS: dur, everyMin: 90),
            hr: heartRate(from: start, durationS: dur, base: 58), rr: [], resp: [])
        let onset = try? XCTUnwrap(firstSleep(segs))
        XCTAssertLessThanOrEqual((onset ?? .max) - start, 5 * 60, "a wearer who settles at once is asleep at once")
    }

    func testRestlessNightIsNotWipedToWake() {
        let dur = 6 * 60 * 60
        let segs = SleepStagerV2.stageSession(
            start: start, end: start + dur,
            grav: gravity(from: start, durationS: dur, everyMin: 5),
            hr: heartRate(from: start, durationS: dur, base: 58), rr: [], resp: [])
        XCTAssertGreaterThan(asleepMinutes(segs), 0,
                             "with no settled run the rule does nothing; it never turns a whole night to wake")
    }
}
