import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// BW2 reliability: stored + live R-R de-duplication before HRV, and live packet ingest.
final class WatchdogRRMergeTests: XCTestCase {

    // MARK: - R-R merge

    private func beat(_ ts: Int, _ ms: Int, ch: RRSourceChannel? = .whoop5Historical, ord: Int? = nil,
                      seq: Int = 0) -> RRInterval {
        RRInterval(ts: ts, rrMs: ms, srcChannel: ch, ord: ord, seq: seq)
    }

    private let noHR: (Int) -> Double? = { _ in nil }

    func testLiveTwinsOfStoredBeatsAreNotDoubleCounted() {
        // Stored history 0…99 s at ~1 beat/s; the live ring re-reports the same beats 2 s late, then runs on.
        let stored = (0..<100).map { beat(1_000 + $0, 1_000) }
        let live = (0..<130).map { beat(1_002 + $0, 1_000, ch: nil) }
        let merged = WatchdogRRMerge.merge(stored: stored, live: live, hrBpmAt: noHR)
        // Live beats at or before maxStored(1099) + 4 = 1103 are twins.
        XCTAssertEqual(merged.splicedAfterTs, 1_103)
        XCTAssertEqual(merged.liveSpliced, live.filter { $0.ts > 1_103 }.count)
        XCTAssertEqual(merged.liveTwinsDropped, live.filter { $0.ts <= 1_103 }.count)
        XCTAssertEqual(merged.duplicatesRemoved, merged.liveTwinsDropped)
        XCTAssertEqual(merged.beats.count, 100 + merged.liveSpliced)
        XCTAssertEqual(merged.transport, RRSourceChannel.whoop5Historical.rawValue)
        // Never more than one beat per second here: no double counting anywhere in the train.
        XCTAssertEqual(Set(merged.beats.map(\.ts)).count, merged.beats.count)
        XCTAssertEqual(merged.beats.map(\.ts), merged.beats.map(\.ts).sorted())
    }

    func testLiveOnlyWindowSplicesEverything() {
        let live = (0..<10).map { beat(2_000 + $0, 900, ch: nil) }
        let merged = WatchdogRRMerge.merge(stored: [], live: live, hrBpmAt: noHR)
        XCTAssertEqual(merged.beats.count, 10)
        XCTAssertNil(merged.transport)
        XCTAssertEqual(merged.splicedAfterTs, 1_999)
        XCTAssertEqual(merged.duplicatesRemoved, 0)
    }

    func testIdentityIsTsRrSeqNeverOrd() {
        // Same (ts, rrMs, seq) but different ord: one beat. Same second, equal value, different seq: two beats.
        let stored = [beat(10, 800, ord: 1), beat(10, 800, ord: 2), beat(10, 800, ord: 3, seq: 1)]
        let merged = WatchdogRRMerge.merge(stored: stored, live: [], hrBpmAt: noHR)
        XCTAssertEqual(merged.beats.count, 2)
        XCTAssertEqual(merged.duplicatesRemoved, 1)
    }

    func testStoredTrainIsPinnedToOneWhoop5Transport() {
        // ch5 history and ch7 standard BLE both present: keep the lowest (5), drop the twin transport.
        let ch5 = (0..<20).map { beat(100 + $0, 1_000, ch: .whoop5Historical) }
        let ch7 = (0..<20).map { beat(102 + $0, 1_000, ch: .whoop5Standard) }
        let merged = WatchdogRRMerge.merge(stored: ch5 + ch7, live: [], hrBpmAt: noHR)
        XCTAssertEqual(merged.beats.count, 20)
        XCTAssertTrue(merged.beats.allSatisfy { $0.srcChannel == .whoop5Historical })
        XCTAssertEqual(merged.otherTransportDropped, 20)
        XCTAssertEqual(merged.duplicatesRemoved, 20)
        XCTAssertEqual(merged.transport, 5)
    }

    func testWhoop4WindowKeepsTheStoresHourlyChoice() {
        // Hour A has history (8) and standard (10): history wins. Hour B has only standard: it stays.
        let hourA = 3_600 * 500
        let hourB = hourA + 3_600
        let stored = [beat(hourB - 10, 900, ch: .whoop4Historical), beat(hourB - 9, 900, ch: .whoop4Standard),
                      beat(hourB + 5, 900, ch: .whoop4Standard)]
        let merged = WatchdogRRMerge.merge(stored: stored, live: [], hrBpmAt: noHR)
        XCTAssertEqual(merged.beats.map(\.ts), [hourB - 10, hourB + 5])
        XCTAssertEqual(merged.otherTransportDropped, 1)
    }

    func testFillValuesRejectedOnlyBelow100Bpm() {
        let stored = [beat(10, 500), beat(11, 333), beat(12, 500), beat(13, 333)]
        let hr: (Int) -> Double? = { ts in ts < 12 ? 62 : 140 }
        let merged = WatchdogRRMerge.merge(stored: stored, live: [], hrBpmAt: hr)
        XCTAssertEqual(merged.fillRejected, 2)
        XCTAssertEqual(merged.beats.map(\.ts), [12, 13])
    }

    func testFillJudgedFromNeighbouringBeatsWhenNoHeartRate() {
        // No HR sample at all: the neighbours (~1000 ms = 60 bpm) say 500 is a fill.
        var stored = (0..<6).map { beat(100 + $0, 1_000) }
        stored.insert(beat(103, 500, seq: 1), at: 4)
        let merged = WatchdogRRMerge.merge(stored: stored, live: [], hrBpmAt: noHR)
        XCTAssertEqual(merged.fillRejected, 1)
        XCTAssertFalse(merged.beats.contains { $0.rrMs == 500 })
        // A lone 500 with no neighbours and no HR stays: nothing says it is a fill.
        let lone = WatchdogRRMerge.merge(stored: [beat(500, 500)], live: [], hrBpmAt: noHR)
        XCTAssertEqual(lone.beats.count, 1)
        XCTAssertEqual(lone.fillRejected, 0)
    }

    func testLiveFillValuesAreRejectedToo() {
        let live = [beat(50, 333, ch: nil), beat(51, 950, ch: nil)]
        let merged = WatchdogRRMerge.merge(stored: [], live: live, hrBpmAt: { _ in 63 })
        XCTAssertEqual(merged.fillRejected, 1)
        XCTAssertEqual(merged.beats.map(\.rrMs), [950])
    }

    func testPileupSecondsAreFlagged() {
        let stored = [beat(10, 1_000), beat(10, 1_100, seq: 1), beat(10, 1_200, seq: 2), beat(11, 900)]
        let merged = WatchdogRRMerge.merge(stored: stored, live: [], hrBpmAt: noHR)
        XCTAssertEqual(merged.pileupSeconds, [10])
        XCTAssertEqual(merged.beats.count, 4, "pileups are flagged, not removed")
    }

    func testOrderInsideASecondIsKept() {
        let stored = [beat(10, 900, ord: 0), beat(10, 700, ord: 1, seq: 1), beat(9, 800)]
        let merged = WatchdogRRMerge.merge(stored: stored, live: [], hrBpmAt: noHR)
        XCTAssertEqual(merged.beats.map(\.rrMs), [800, 900, 700])
    }

    func testHrLookupUsesNearbySeconds() {
        let lookup = WatchdogRRMerge.hrLookup([HRSample(ts: 100, bpm: 70), HRSample(ts: 105, bpm: 10)])
        XCTAssertEqual(lookup(100), 70)
        XCTAssertEqual(lookup(102), 70)
        XCTAssertNil(lookup(103))
        XCTAssertNil(lookup(105), "implausible bpm is not a concurrent heart rate")
    }

    // MARK: - Live ingest

    func testLivePacketKeepsEveryIntervalInOrder() {
        let beats = WatchdogLiveTape.rrBeats(packet: [800, 820], receivedUnix: 1_000, lastRingBeat: nil)
        XCTAssertEqual(beats.map(\.rrMs), [800, 820])
        XCTAssertEqual(beats.map(\.ts), [999, 1_000])
        // Two equal beats in the same second are both kept, with distinct seq.
        let same = WatchdogLiveTape.rrBeats(packet: [400, 400], receivedUnix: 2_000, lastRingBeat: nil)
        XCTAssertEqual(same.count, 2)
        XCTAssertEqual(same.map(\.ts), [2_000, 2_000])
        XCTAssertEqual(same.map(\.seq), [0, 1])
    }

    func testLivePacketNeverStampsBeforeTheRing() {
        let last = RRInterval(ts: 1_000, rrMs: 700, seq: 2)
        let beats = WatchdogLiveTape.rrBeats(packet: [1_500, 600], receivedUnix: 1_000, lastRingBeat: last)
        XCTAssertEqual(beats.map(\.ts), [1_000, 1_000])
        XCTAssertEqual(beats.map(\.seq), [3, 4])
        let merged = WatchdogRRMerge.merge(stored: [], live: [last] + beats, hrBpmAt: { _ in 80 })
        XCTAssertEqual(merged.beats.map(\.rrMs), [700, 1_500, 600])
    }

    func testLivePacketSkipsImplausibleIntervals() {
        let beats = WatchdogLiveTape.rrBeats(packet: [0, 120, 900, 4_000], receivedUnix: 50, lastRingBeat: nil)
        XCTAssertEqual(beats.map(\.rrMs), [900])
    }

    // MARK: - Real data (owner's WHOOP 5/MG export; skipped unless WATCHDOG_REALDATA_DIR is set)

    /// Reads `rr_<window>.csv` (ts,rrMs,srcChannel,ord,seq,tsSuspect for ch5+ch7) and `hr_<window>.csv`
    /// exported from a read-only copy of the database. Simulates the live situation: history (ch5) has landed
    /// for the first 20 minutes only, and the live ring (ch7, receipt-stamped) covers the whole window.
    func testRealWindowDeduplication() throws {
        guard let dir = ProcessInfo.processInfo.environment["WATCHDOG_REALDATA_DIR"] else {
            throw XCTSkip("WATCHDOG_REALDATA_DIR not set")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("rr_") }
        XCTAssertFalse(files.isEmpty)
        for file in files.sorted() {
            let window = Int(file.dropFirst(3).dropLast(4))!
            let rows = try String(contentsOfFile: dir + "/" + file, encoding: .utf8)
                .split(separator: "\n").map { $0.split(separator: ",").map { Int($0)! } }
            let hrRows = try String(contentsOfFile: dir + "/hr_\(window).csv", encoding: .utf8)
                .split(separator: "\n").map { $0.split(separator: ",").map { Int($0)! } }
            let hr = hrRows.map { HRSample(ts: $0[0], bpm: $0[1]) }
            func rr(_ r: [Int]) -> RRInterval {
                RRInterval(ts: r[0], rrMs: r[1], srcChannel: RRSourceChannel(rawValue: r[2]),
                           ord: r[3] < 0 ? nil : r[3], seq: r[4])
            }
            let clean = rows.filter { $0[5] != 1 }
            let ch5 = clean.filter { $0[2] == 5 }.map(rr)
            let ch7 = clean.filter { $0[2] == 7 }.map { r in RRInterval(ts: r[0], rrMs: r[1], seq: r[4]) }
            let start = window
            let end = window + 1_800
            let landed = start + 1_200
            let stored = ch5.filter { $0.ts < landed }
            let live = ch7

            let old = stored + live
            let merged = WatchdogRRMerge.merge(stored: stored, live: live, hrBpmAt: WatchdogRRMerge.hrLookup(hr))
            let reference = ch5

            func coverage(_ beats: [RRInterval]) -> Double {
                Double(beats.filter { $0.ts >= start && $0.ts < end }.map(\.rrMs).reduce(0, +)) / 1_800_000
            }
            func rmssd(_ beats: [RRInterval]) -> Double {
                let pts = HRVAnalyzer.rollingRmssd(rr: beats.filter { $0.ts >= start && $0.ts < end },
                                                   windowSec: 1_800, stepSec: 1_800, minBeatsPerWindow: 8)
                return pts.last?.rmssd ?? .nan
            }
            let oldCov = coverage(old), newCov = coverage(merged.beats), refCov = coverage(reference)
            let oldR = rmssd(old), newR = rmssd(merged.beats), refR = rmssd(reference)
            print(String(format: "[realdata %d] coverage old %.3f new %.3f ref %.3f | RMSSD old %.1f new %.1f ref %.1f | dup %d fill %d pileups %d",
                         window, oldCov, newCov, refCov, oldR, newR, refR, merged.duplicatesRemoved,
                         merged.fillRejected, merged.pileupSeconds.count))
            XCTAssertGreaterThan(oldCov, 1.5, "the old concatenation double-counts")
            XCTAssertEqual(newCov, refCov, accuracy: 0.05)
            XCTAssertLessThan(abs(newR - refR) / refR, abs(oldR - refR) / refR)
        }
    }
}
