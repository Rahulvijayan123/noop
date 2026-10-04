import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore

/// A new owner's offload, end to end through the real chunk state machine.
///
/// The strap frees a chunk only when it is acknowledged, and it is acknowledged only after what it held has
/// been written. So "clean strap" means every chunk is still acknowledged, in order, while nothing dated before
/// the pairing is written, journaled, archived or kept as raw bytes. Each test builds a protocol-correct
/// HISTORY_END (the same builder `BackfillMetaForgeryTests` uses) so the trim cursor and the ack are the real
/// ones, and injects the decoder's output so the dates under test are exact.
@MainActor
final class BackfillerFenceTests: XCTestCase {

    private final class SpyStore: BackfillStoreWriting {
        var inserted: [Streams] = []
        var cursors: [String: Int] = [:]
        var rawBatches = 0
        var failInserts = false

        struct Failure: Error {}

        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            if failInserts { throw Failure() }
            inserted.append(streams)
            return (streams.hr.count, streams.rr.count, streams.events.count, streams.battery.count,
                    streams.spo2.count, streams.skinTemp.count, streams.resp.count, streams.gravity.count)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws { rawBatches += 1 }
        func setCursor(_ name: String, _ value: Int) async throws { cursors[name] = value }
        func cursor(_ name: String) async throws -> Int? { cursors[name] }

        var keptHeartRate: [Int] { inserted.flatMap { $0.hr.map(\.ts) } }
    }

    private let fence = 1_790_000_000

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func historyEndFrame(trim: UInt32) -> [UInt8] {
        frameFromPayload(le32(1_700_000_000) + [0, 0] + le32(0) + le32(trim), type: 49, seq: 0, cmd: 2)
    }

    /// A console frame: it classifies as an ordinary offload frame, so the chunk has something in it.
    private func dataFrame() -> [UInt8] {
        frameFromPayload([0x01, 0x02, 0x03], type: 50, seq: 0, cmd: 0)
    }

    private func heartRate(at stamps: [Int]) -> Streams {
        Streams(hr: stamps.map { HRSample(ts: $0, bpm: 60) },
                battery: stamps.map { BatterySample(ts: $0, soc: 50, mv: nil) })
    }

    private struct Rig {
        let backfiller: Backfiller
        let store: SpyStore
        let acks: Acks
        let chunks: Chunks
    }
    private final class Acks { var trims: [UInt32] = [] }
    private final class Chunks { var outcomes: [(decoded: Bool, console: Bool)] = [] }

    private func makeRig(_ produce: @escaping () -> Streams, intake: HistoryIntake,
                         enableRawCapture: Bool = false) -> Rig {
        let store = SpyStore()
        let acks = Acks()
        let chunks = Chunks()
        let backfiller = Backfiller(
            store: store, deviceId: "test",
            ackTrim: { trim, _ in acks.trims.append(trim) },
            enableRawCapture: enableRawCapture,
            onChunk: { decoded, console in chunks.outcomes.append((decoded, console)) },
            extract: { _, _, _, _, _, _ in produce() })
        backfiller.intake = intake
        backfiller.begin(family: .whoop4)
        return Rig(backfiller: backfiller, store: store, acks: acks, chunks: chunks)
    }

    private func offload(_ rig: Rig, trim: UInt32) async {
        await rig.backfiller.ingest(dataFrame())
        await rig.backfiller.ingest(historyEndFrame(trim: trim))
    }

    // MARK: - control

    func testWithoutAFenceEverythingTheStrapOffersIsKept() async {
        let rig = makeRig({ self.heartRate(at: [self.fence - 500, self.fence + 5]) }, intake: .keep)
        await offload(rig, trim: 100)
        XCTAssertEqual(rig.store.keptHeartRate, [fence - 500, fence + 5])
        XCTAssertEqual(rig.acks.trims, [100])
        XCTAssertEqual(rig.backfiller.sessionDiscarded.dropped, 0)
    }

    // MARK: - a new owner

    func testRecordsFromBeforeThePairingAreAcknowledgedButNotKept() async {
        let rig = makeRig({ self.heartRate(at: [self.fence - 7_200, self.fence - 60]) }, intake: .discard(before: fence))
        await offload(rig, trim: 200)
        XCTAssertEqual(rig.store.keptHeartRate, [], "nothing of the previous owner's reaches the store")
        XCTAssertEqual(rig.store.inserted.map(\.isEmpty), [true])
        XCTAssertEqual(rig.acks.trims, [200], "the chunk is still acknowledged: that is how the strap frees it")
        XCTAssertEqual(rig.store.cursors["strap_trim"], 200, "and the cursor still moves on, so a restart does not re-offer it")
        XCTAssertEqual(rig.backfiller.sessionDiscarded.dropped, 4, "two heart-rate and two battery records")
        XCTAssertEqual(rig.backfiller.sessionDiscarded.oldest, fence - 7_200)
        XCTAssertEqual(rig.backfiller.sessionDiscarded.newest, fence - 60)
    }

    func testAChunkThatStraddlesThePairingKeepsOnlyTheNewOwnersRecords() async {
        let rig = makeRig({ self.heartRate(at: [self.fence - 30, self.fence, self.fence + 30]) }, intake: .discard(before: fence))
        await offload(rig, trim: 300)
        XCTAssertEqual(rig.store.keptHeartRate, [fence, fence + 30], "a record dated at the pairing instant is the new owner's")
        XCTAssertEqual(rig.acks.trims, [300])
        XCTAssertEqual(rig.backfiller.sessionDiscarded.dropped, 2)
    }

    func testEveryChunkOfTheDrainIsAcknowledgedInOrder() async {
        final class Queue { var chunks: [Streams] = [] }
        let queue = Queue()
        queue.chunks = [heartRate(at: [fence - 9_000]), heartRate(at: [fence - 4_000]), heartRate(at: [fence + 2])]
        let rig = makeRig({ queue.chunks.isEmpty ? Streams() : queue.chunks.removeFirst() }, intake: .discard(before: fence))
        await offload(rig, trim: 10)
        await offload(rig, trim: 20)
        await offload(rig, trim: 30)
        XCTAssertEqual(rig.acks.trims, [10, 20, 30])
        XCTAssertEqual(rig.store.keptHeartRate, [fence + 2])
        XCTAssertEqual(rig.backfiller.sessionDiscarded.dropped, 4)
        XCTAssertEqual(rig.backfiller.lastAckedTrim, 30)
    }

    func testTheDiscardIsReportedChunkByChunk() async {
        final class Reports { var all: [HistoryFenceReport] = [] }
        let reports = Reports()
        let rig = makeRig({ self.heartRate(at: [self.fence - 10]) }, intake: .discard(before: fence))
        rig.backfiller.onHistoryDiscarded = { reports.all.append($0) }
        await offload(rig, trim: 1)
        XCTAssertEqual(reports.all, [HistoryFenceReport(dropped: 2, oldest: fence - 10, newest: fence - 10)])
    }

    func testADrainedChunkIsNotReportedAsConsoleOutput() async {
        let rig = makeRig({ self.heartRate(at: [self.fence - 10]) }, intake: .discard(before: fence))
        await offload(rig, trim: 1)
        XCTAssertEqual(rig.chunks.outcomes.count, 1)
        XCTAssertTrue(rig.chunks.outcomes[0].decoded, "it held sensor records; they were just not this owner's")
        XCTAssertFalse(rig.chunks.outcomes[0].console, "else the strap would be told it 'banked no sensor history'")
    }

    func testAChunkOfPureConsoleOutputStillReadsAsConsoleOutputUnderAFence() async {
        let rig = makeRig({ Streams() }, intake: .discard(before: fence))
        await offload(rig, trim: 1)
        XCTAssertEqual(rig.chunks.outcomes.count, 1)
        XCTAssertFalse(rig.chunks.outcomes[0].decoded)
        XCTAssertTrue(rig.chunks.outcomes[0].console)
        XCTAssertEqual(rig.backfiller.sessionDiscarded.dropped, 0)
    }

    func testTheTallyOfADrainStartsFromZeroEachSession() async {
        let rig = makeRig({ self.heartRate(at: [self.fence - 10]) }, intake: .discard(before: fence))
        await offload(rig, trim: 1)
        XCTAssertEqual(rig.backfiller.sessionDiscarded.dropped, 2)
        rig.backfiller.begin(family: .whoop4)
        XCTAssertEqual(rig.backfiller.sessionDiscarded.dropped, 0)
    }

    // MARK: - nothing else keeps a copy

    func testRawCaptureNeverKeepsAChunkThatHeldAPreviousOwnersRecords() async {
        let rig = makeRig({ self.heartRate(at: [self.fence - 10]) }, intake: .discard(before: fence), enableRawCapture: true)
        await offload(rig, trim: 1)
        XCTAssertEqual(rig.store.rawBatches, 0)
        XCTAssertEqual(rig.acks.trims, [1])
    }

    func testRawCaptureStillWorksForAChunkThatIsEntirelyTheNewOwners() async {
        let rig = makeRig({ self.heartRate(at: [self.fence + 10, self.fence + 20]) }, intake: .discard(before: fence), enableRawCapture: true)
        await offload(rig, trim: 1)
        XCTAssertEqual(rig.store.rawBatches, 1)
        XCTAssertEqual(rig.backfiller.sessionDiscarded.dropped, 0)
    }

    func testUndecodableRecordsAreNotArchivedFromAChunkThatMayBeThePreviousOwners() async {
        final class Archive { var batches: [[[UInt8]]] = [] }
        // A type-47 frame the decoder cannot read: a genuine reject with no date to test.
        let undecodable = frameFromPayload([UInt8](repeating: 0xEE, count: 40), type: 47, seq: 0, cmd: 0)
        XCTAssertFalse(rejectedHistoricalRecords([undecodable], family: .whoop4).isEmpty,
                       "precondition: this is a record the archive would normally keep")

        func run(_ intake: HistoryIntake) async -> (archive: Archive, acked: UInt32?) {
            let archive = Archive()
            let backfiller = Backfiller(
                store: SpyStore(), deviceId: "test", ackTrim: { _, _ in },
                rejectedSink: { frames, _, _ in archive.batches.append(frames); return true },
                extract: { _, _, _, _, _, _ in Streams() })
            backfiller.intake = intake
            backfiller.begin(family: .whoop4)
            await backfiller.ingest(undecodable)
            await backfiller.ingest(historyEndFrame(trim: 7))
            return (archive, backfiller.lastAckedTrim)
        }

        let kept = await run(.keep)
        XCTAssertEqual(kept.archive.batches.count, 1, "control: without a fence the reject is archived as always")
        let fenced = await run(.discard(before: fence))
        XCTAssertTrue(fenced.archive.batches.isEmpty,
                      "an archive of bytes nobody can date is a copy of the previous owner's data")
        XCTAssertEqual(fenced.acked, 7, "and the chunk is still acknowledged")
    }

    // MARK: - what must not change

    func testAFailedWriteStillWithholdsTheAckUnderAFence() async {
        let rig = makeRig({ self.heartRate(at: [self.fence - 10, self.fence + 10]) }, intake: .discard(before: fence))
        rig.store.failInserts = true
        await offload(rig, trim: 5)
        XCTAssertTrue(rig.acks.trims.isEmpty, "the new owner's record could not be stored, so the strap must keep the chunk")
        XCTAssertTrue(rig.backfiller.persistStalled)
    }
}
