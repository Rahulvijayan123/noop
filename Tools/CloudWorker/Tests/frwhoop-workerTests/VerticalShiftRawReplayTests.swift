import XCTest
import Foundation
@testable import frwhoop_worker
@testable import StrandAnalytics

/// Opt-in: run the measured-shift detector over downloaded `rawImuSession` objects (`NARA_RAW_IMU_DIR`: the raw
/// `<id>.bin` wire objects, zstd NPB1) and print every candidate movement with its measurement, plus the accepted
/// shifts. Skipped when the variable is unset.
final class VerticalShiftRawReplayTests: XCTestCase {
    func testReplayDownloadedRawImu() throws {
        guard let dir = ProcessInfo.processInfo.environment["NARA_RAW_IMU_DIR"] else { throw XCTSkip("NARA_RAW_IMU_DIR not set") }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".bin") }.sorted()
        var records: [Npb1ImuDecoder.Record] = []
        for f in files {
            let wire = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(f))
            records += try Npb1ImuDecoder.decode(try VerificationLane.zstdDecompress(wire))
        }
        // Overlapping uploads of the same seconds: keep the first copy of each second.
        var seen = Set<Int64>()
        records = records.filter { seen.insert($0.ts).inserted }
        let timeline = try ActivityLane.buildTimeline(records: records)
        let runs = ActivityLane.splitRuns(seconds: timeline.seconds)
        let fmt = DateFormatter(); fmt.dateFormat = "MM-dd HH:mm:ss"; fmt.timeZone = TimeZone(identifier: "America/Los_Angeles")
        func t(_ s: Double) -> String { fmt.string(from: Date(timeIntervalSince1970: s)) }
        print("RAW seconds \(timeline.count) runs \(runs.count)")
        let n = 100
        for run in runs where run.end - run.start >= 6 {
            var raw: [ActivityVerticalShift.Sample] = []
            var index: [Int64: Int] = [:]
            for (i, s) in timeline.seconds.enumerated() { index[s] = i }
            for s in run.start..<run.end {
                guard let i = index[s] else { continue }
                let o = timeline.columnOffset(index: i)
                for k in 0..<n {
                    func c(_ a: Int) -> Double { Double(timeline.columns[o + a * n + k]) }
                    raw.append(.init(ax: c(0) / 4096, ay: c(1) / 4096, az: c(2) / 4096,
                                     gx: c(3) * 2000 / 32768, gy: c(4) * 2000 / 32768, gz: c(5) * 2000 / 32768))
                }
            }
            print("RAW run \(t(Double(run.start)))–\(t(Double(run.end)))")
            // Every candidate, measured.
            let fs = 50.0
            var acc: [(Double, Double, Double)] = [], gyr: [(Double, Double, Double)] = []
            var i = 0
            while i + 2 <= raw.count {
                acc.append(((raw[i].ax + raw[i+1].ax) / 2, (raw[i].ay + raw[i+1].ay) / 2, (raw[i].az + raw[i+1].az) / 2))
                gyr.append(((raw[i].gx + raw[i+1].gx) / 2 * .pi / 180, (raw[i].gy + raw[i+1].gy) / 2 * .pi / 180,
                            (raw[i].gz + raw[i+1].gz) / 2 * .pi / 180))
                i += 2
            }
            let g = ActivityVerticalShift.gravityDirection(acc, gyr, fs: fs)
            for seg in ActivityVerticalShift.segment(acc, fs: fs) {
                let m = ActivityVerticalShift.measure(acc, g, fs: fs, from: seg.0, to: seg.1)
                print(String(format: "RAW   cand %@ dur %.1fs dh %+.3f vpeak %+.2f padV %.3f",
                             t(Double(run.start) + Double(seg.0) / fs), Double(seg.1 - seg.0) / fs,
                             m?.dh ?? .nan, m?.vpeak ?? .nan, m?.padVelocity ?? .nan))
            }
            for e in ActivityVerticalShift.detect(raw, sampleRateHz: 100, startTs: Double(run.start)) {
                print(String(format: "RAW   SHIFT %@ dh %+.3f q %.2f", t(Double(e.startTs)), e.displacementM, e.quality))
            }
        }
    }
}
