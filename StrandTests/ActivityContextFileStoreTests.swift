import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import Strand

/// The on-disk cache of decoded ActivityContext days: what is written is what is read back, a damaged file
/// is a miss rather than a crash, old days age out, deleting a device removes its days, and a document read
/// from disk can still resume the decoder.
final class ActivityContextFileStoreTests: XCTestCase {
    private var directory: URL!
    private let dayStart = 1_790_726_400

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acx-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func input(_ day: Int, seconds: Int) -> ActivityContextTrackInput {
        var gravity: [GravitySample] = []
        var hr: [HRSample] = []
        for i in 0..<seconds {
            gravity.append(GravitySample(ts: day + i, x: 0.1, y: 0.2, z: 0.97, dynAccel: 0.01))
            hr.append(HRSample(ts: day + i, bpm: 62))
        }
        return ActivityContextTrackInput(dayStart: day, dayEnd: day + seconds, hr: hr, gravity: gravity,
                                         sleepKnownOutsideSessions: false)
    }

    private func document(_ day: Int, seconds: Int = 240) -> ActivityContextDayDocument {
        ActivityContextDayBuilder.update(cached: nil, input: input(day, seconds: seconds), now: day + seconds).document
    }

    func testADocumentSurvivesAWriteAndRead() throws {
        let store = ActivityContextFileStore(directory: directory)
        let original = document(dayStart)
        store.save(original, source: "my-whoop")

        let first = try XCTUnwrap(store.load(source: "my-whoop", dayStart: dayStart))
        XCTAssertEqual(first.dayStart, original.dayStart)
        XCTAssertEqual(first.dataThrough, original.dataThrough)
        XCTAssertEqual(first.observedSeconds, original.observedSeconds)
        XCTAssertEqual(first.runs.count, original.runs.count)
        XCTAssertEqual(first.summary.labelSeconds, original.summary.labelSeconds)
        XCTAssertEqual(first.contextFingerprint, original.contextFingerprint)
        XCTAssertNotNil(first.snapshot)
        XCTAssertTrue(first.isCurrent)

        // Once rounded for storage, a second pass changes nothing.
        store.save(first, source: "my-whoop")
        XCTAssertEqual(store.load(source: "my-whoop", dayStart: dayStart), first)
    }

    func testAMissIsNil() {
        let store = ActivityContextFileStore(directory: directory)
        XCTAssertNil(store.load(source: "my-whoop", dayStart: dayStart))
    }

    func testADamagedFileIsAMissAndIsRemoved() throws {
        let store = ActivityContextFileStore(directory: directory)
        store.save(document(dayStart), source: "my-whoop")
        let url = store.fileURL(source: "my-whoop", dayStart: dayStart)
        try Data("not a document".utf8).write(to: url)
        XCTAssertNil(store.load(source: "my-whoop", dayStart: dayStart))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // A truncated but correctly headed file is also a miss.
        store.save(document(dayStart), source: "my-whoop")
        let good = try Data(contentsOf: url)
        try good.prefix(good.count / 2).write(to: url)
        XCTAssertNil(store.load(source: "my-whoop", dayStart: dayStart))
    }

    func testSourcesAndDaysDoNotCollide() throws {
        let store = ActivityContextFileStore(directory: directory)
        store.save(document(dayStart), source: "whoop-a")
        store.save(document(dayStart, seconds: 120), source: "whoop-b")
        store.save(document(dayStart + 86_400), source: "whoop-a")
        XCTAssertEqual(try XCTUnwrap(store.load(source: "whoop-a", dayStart: dayStart)).observedSeconds, 240)
        XCTAssertEqual(try XCTUnwrap(store.load(source: "whoop-b", dayStart: dayStart)).observedSeconds, 120)
        XCTAssertNotNil(store.load(source: "whoop-a", dayStart: dayStart + 86_400))
        XCTAssertNil(store.load(source: "whoop-b", dayStart: dayStart + 86_400))
    }

    func testOldDaysAgeOutWhenANewOneIsWritten() throws {
        let store = ActivityContextFileStore(directory: directory)
        let now = Date(timeIntervalSince1970: TimeInterval(dayStart + 100 * 86_400))
        let ancient = dayStart
        let recent = dayStart + 90 * 86_400
        store.save(document(ancient), source: "my-whoop", now: now)
        store.save(document(recent), source: "my-whoop", now: now)
        // The ancient day was only the kept file at its own write; the next write sweeps it.
        XCTAssertNil(store.load(source: "my-whoop", dayStart: ancient))
        XCTAssertNotNil(store.load(source: "my-whoop", dayStart: recent))
    }

    func testDeletingADeviceRemovesItsDaysOnly() throws {
        let store = ActivityContextFileStore(directory: directory)
        store.save(document(dayStart), source: "whoop-a+my-whoop")
        store.save(document(dayStart + 86_400), source: "whoop-a+my-whoop")
        store.save(document(dayStart), source: "whoop-b")
        store.removeAll(forDevice: "whoop-a")
        XCTAssertNil(store.load(source: "whoop-a+my-whoop", dayStart: dayStart))
        XCTAssertNil(store.load(source: "whoop-a+my-whoop", dayStart: dayStart + 86_400))
        XCTAssertNotNil(store.load(source: "whoop-b", dayStart: dayStart))
    }

    func testADocumentReadFromDiskStillResumesTheDecoder() throws {
        let store = ActivityContextFileStore(directory: directory)
        store.save(document(dayStart, seconds: 240), source: "my-whoop")
        let cached = try XCTUnwrap(store.load(source: "my-whoop", dayStart: dayStart))

        let (grown, how) = ActivityContextDayBuilder.update(cached: cached, input: input(dayStart, seconds: 360),
                                                            now: dayStart + 360)
        XCTAssertEqual(how, .resumed(fromTs: dayStart + 240))
        XCTAssertEqual(grown.dataThrough, dayStart + 360)

        let (whole, _) = ActivityContextDayBuilder.update(cached: nil, input: input(dayStart, seconds: 360),
                                                          now: dayStart + 360)
        XCTAssertEqual(grown.summary.labelSeconds, whole.summary.labelSeconds)
        XCTAssertEqual(grown.latest?.displayContext, whole.latest?.displayContext)
    }

    func testTheCacheFolderIsKeptOutOfBackups() throws {
        _ = ActivityContextFileStore(directory: directory)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}
