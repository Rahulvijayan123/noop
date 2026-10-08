import XCTest
@testable import Strand

/// Lean raw capture: the activity stream keeps live IMU (106) and asks the strap not to bank raw optical
/// (107) or raw IMU (105) to flash, nor stream optical live (108). Pins the wire contract so a later edit
/// cannot turn one of these into an ON write.
final class LeanRawCaptureTests: XCTestCase {

    func testLeanCaptureSendsOnlyOffBodiesForTheThreeSavingAndOpticalControls() {
        let writes = ActivityImuCapture.leanRawCaptureCommands
        XCTAssertEqual(writes.map { $0.command.rawValue }, [107, 108, 105])
        for w in writes {
            XCTAssertEqual(w.payload, [0x01, 0x00], "\(w.command.label) must be a revision-1 OFF write")
        }
        XCTAssertFalse(writes.contains { $0.command == .toggleIMUMode }, "live IMU must never be switched off here")
    }

    func testLeanCaptureIsOnByDefaultAndCanBeTurnedOff() {
        let suite = "LeanRawCaptureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(ActivityImuCapture.leanRawCapture(defaults))
        defaults.set(false, forKey: ActivityImuCapture.leanRawCaptureKey)
        XCTAssertFalse(ActivityImuCapture.leanRawCapture(defaults))
    }
}
