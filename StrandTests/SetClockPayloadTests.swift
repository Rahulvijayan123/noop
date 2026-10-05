import XCTest
@testable import Strand

/// Pins the dual SET_CLOCK payload forms behind the WHOOP 4 fw-41.17.x clock fix (#120). An un-clocked
/// 41.17.x strap ignores the 8-byte SET_CLOCK form outright (no COMMAND_RESPONSE, RTC unchanged) and
/// latches ONLY the legacy 9-byte `[u32 LE][5 zero]` form; without that form the RTC stays lost and the
/// strap banks no sensor history to flash. Newer firmware is the reverse. sendSetClockBothForms() sends
/// both (legacy gated to WHOOP 4), so either firmware latches. These pin the byte layouts + lengths.
@MainActor
final class SetClockPayloadTests: XCTestCase {

    // 8-byte form: [seconds u32 LE][4 zero subseconds]. Length must be exactly 8.
    func testEightByteFormLayout() {
        let now: UInt32 = 0x11223344
        let p = BLEManager.setClockPayload(now: now)
        XCTAssertEqual(p.count, 8)
        XCTAssertEqual(Array(p[0..<4]), [0x44, 0x33, 0x22, 0x11], "u32 LE seconds")
        XCTAssertEqual(Array(p[4..<8]), [0, 0, 0, 0], "subseconds zeroed")
    }

    // 9-byte legacy form: [seconds u32 LE][5 zero]. Length must be exactly 9 — the wrong length is what
    // distinguishes it for fw 41.17.x. Same seconds bytes as the 8-byte form.
    func testNineByteLegacyFormLayout() {
        let now: UInt32 = 0x11223344
        let p = BLEManager.setClockPayloadLegacy(now: now)
        XCTAssertEqual(p.count, 9)
        XCTAssertEqual(Array(p[0..<4]), [0x44, 0x33, 0x22, 0x11], "u32 LE seconds")
        XCTAssertEqual(Array(p[4..<9]), [0, 0, 0, 0, 0], "five zero pad bytes")
    }

    // Both forms carry the SAME seconds for a given `now`, so whichever the firmware latches sets the
    // same wall time (double-latching is harmless).
    func testBothFormsAgreeOnSeconds() {
        let now: UInt32 = 1_700_000_000
        let a = BLEManager.setClockPayload(now: now)
        let b = BLEManager.setClockPayloadLegacy(now: now)
        XCTAssertEqual(Array(a[0..<4]), Array(b[0..<4]))
    }
}

/// WHOOP 4.0 is retired from this app: 5.0/MG is the only WHOOP model. These pin what that means for the
/// scan (nowhere to rotate to) and for a selection saved before the retirement (it must resolve, not break).
final class WhoopModelFallbackTests: XCTestCase {

    func testThereIsExactlyOneWhoopModelAndItIsTheFiveOhMG() {
        XCTAssertEqual(WhoopModel.allCases, [.whoop5mg])
        XCTAssertEqual(WhoopModel.whoop5mg.displayName, "WHOOP 5.0 / MG")
        XCTAssertEqual(WhoopModel.whoop5mg.deviceFamily, .whoop5)
    }

    /// With one family there is nowhere to rotate to. `BLEManager.startScan` relies on the fallback being the
    /// model itself to skip scheduling a rotation that would only restart the identical scan.
    func testTheScanFallbackIsTheModelItself() {
        XCTAssertEqual(WhoopModel.whoop5mg.fallbackScanModel, .whoop5mg)
    }

    func testASavedFourPointZeroOrAnythingUnknownResolvesToTheSupportedModel() {
        XCTAssertEqual(WhoopModel.resolve("WHOOP 4.0"), .whoop5mg)
        XCTAssertEqual(WhoopModel.resolve("something else"), .whoop5mg)
        XCTAssertEqual(WhoopModel.resolve(nil), .whoop5mg)
        XCTAssertEqual(WhoopModel.resolve("WHOOP 5.0 / MG"), .whoop5mg)
    }

    private func isolatedDefaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "WhoopModelFallbackTests.\(name)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testTheLegacySelectionIsRewrittenOnceAndThenLeftAlone() throws {
        let defaults = try isolatedDefaults()
        defaults.set("WHOOP 4.0", forKey: WhoopModel.storageKey)
        XCTAssertTrue(WhoopModel.migrateLegacySelection(defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: WhoopModel.storageKey), "WHOOP 5.0 / MG")
        XCTAssertFalse(WhoopModel.migrateLegacySelection(defaults: defaults), "idempotent")
    }

    func testMigrationDoesNothingOnAFreshInstallOrACurrentSelection() throws {
        let fresh = try isolatedDefaults("fresh")
        XCTAssertFalse(WhoopModel.migrateLegacySelection(defaults: fresh))
        XCTAssertNil(fresh.string(forKey: WhoopModel.storageKey), "unset stays unset")
        let current = try isolatedDefaults("current")
        current.set("WHOOP 5.0 / MG", forKey: WhoopModel.storageKey)
        XCTAssertFalse(WhoopModel.migrateLegacySelection(defaults: current))
    }
}
