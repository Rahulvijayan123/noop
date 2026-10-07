import XCTest
@testable import Strand
import WhoopProtocol

final class WatchdogNaraSignalTests: XCTestCase {
    func testAsleepCodeMergesAndIgnoresOtherStates() {
        let samples = [
            SleepStateSample(ts: 100, state: 0),
            SleepStateSample(ts: 101, state: 1),
            SleepStateSample(ts: 110, state: 2),
            SleepStateSample(ts: 140, state: 2),
            SleepStateSample(ts: 200, state: 3),
            SleepStateSample(ts: 400, state: 2),
        ]
        let intervals = WatchdogService.asleepIntervals(from: samples)
        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(intervals[0].startUnix, 110)
        XCTAssertEqual(intervals[0].endUnix, 141)
        XCTAssertEqual(intervals[1].startUnix, 400)
        XCTAssertEqual(intervals[1].endUnix, 401)
    }

    func testStillSecondDownsamplesToUnitGravity() {
        let n = Whoop5RawImu.sampleCount
        var columns = [Int16](repeating: 0, count: n * 6)
        let oneG = Int16(4096)
        for i in 0..<n {
            columns[2 * n + i] = oneG
        }
        let record = ImuStoredRecord(ts: 1_700_000_000, receivedAtMs: 0, columns: columns)
        let samples = WatchdogGravityFill.fromRawIMU([record])
        XCTAssertEqual(samples.count, 1)
        let sample = samples[0]
        XCTAssertEqual(sample.ts, 1_700_000_000)
        XCTAssertEqual(sample.x, 0, accuracy: 1e-6)
        XCTAssertEqual(sample.y, 0, accuracy: 1e-6)
        XCTAssertEqual(sample.z, 1, accuracy: 1e-6)
        XCTAssertEqual(sample.dynAccel ?? -1, 0, accuracy: 1e-6)
    }

    func testShortFrameIsDropped() {
        let record = ImuStoredRecord(ts: 10, receivedAtMs: 0, columns: [Int16](repeating: 1, count: 10))
        XCTAssertTrue(WatchdogGravityFill.fromRawIMU([record]).isEmpty)
    }
}
