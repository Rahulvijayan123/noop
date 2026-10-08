import XCTest
@testable import WhoopProtocol

/// Intact 5/MG raw sensor records (v20 optical, v21 IMU) are not rejects.
///
/// They decode, and by design carry no heart rate and no gravity, so the decode-outcome test in
/// `rejectedHistoricalRecords` used to archive every one. During raw capture that was about half the frames
/// of every offload chunk, hex-encoded and fsynced ahead of the ack, and it raised the "couldn't be decoded"
/// sync status on every sync. Uses the real captured frames the decode tests already pin.
final class RawSensorRecordArchiveTests: XCTestCase {

    private var realV20: [UInt8] { Whoop5HistoricalV2021Tests.realFrameV20Bytes }
    private var realV21: [UInt8] { Whoop5RawImuTests.realFrameBytes }

    func testRealV20AndV21AreIntactRawSensorRecords() {
        for f in [realV20, realV21] {
            XCTAssertTrue(isIntactWhoop5RawSensorRecord(f, parsed: parseFrame(f, family: .whoop5)))
        }
    }

    func testIntactRawSensorRecordsAreNotRejected() {
        XCTAssertTrue(rejectedHistoricalRecords([realV20, realV21], family: .whoop5).isEmpty)
    }

    /// The skip is bound to the integrity verdict, as v26's is: a corrupt record is still archived.
    func testACorruptRawSensorRecordIsStillArchived() {
        for good in [realV20, realV21] {
            var bad = good
            bad[bad.count - 1] ^= 0xFF   // break the CRC32 trailer
            XCTAssertFalse(isIntactWhoop5RawSensorRecord(bad, parsed: parseFrame(bad, family: .whoop5)))
            XCTAssertEqual(rejectedHistoricalRecords([bad], family: .whoop5), [bad])
        }
    }

    /// Only v20/v21 are raw sensor layouts. The v18 summary record decodes rows and is never one.
    func testOtherLayoutsAreNotRawSensorRecords() {
        XCTAssertEqual(whoop5RawSensorHistoricalVersions, [20, 21])
        XCTAssertTrue(whoop5RawSensorHistoricalVersions.isSubset(of: mappedWhoop5HistoricalVersions))
        var v18 = realV21
        v18[9] = 18
        XCTAssertFalse(isIntactWhoop5RawSensorRecord(v18, parsed: parseFrame(v18, family: .whoop5)))
    }
}
