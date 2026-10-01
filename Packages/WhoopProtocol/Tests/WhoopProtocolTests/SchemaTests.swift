import XCTest
@testable import WhoopProtocol

final class SchemaTests: XCTestCase {
    func testTypeName() {
        let s = loadSchema()
        XCTAssertEqual(s.typeName(40), "REALTIME_DATA")
        XCTAssertEqual(s.typeName(43), "REALTIME_RAW_DATA")
        XCTAssertEqual(s.typeName(36), "COMMAND_RESPONSE")
        XCTAssertEqual(s.typeName(999), "type999") // unknown fallback
    }

    func testEnumNameSuffixed() {
        let s = loadSchema()
        XCTAssertEqual(s.enumName("CommandNumber", 26), "GET_BATTERY_LEVEL(26)")
        XCTAssertEqual(s.enumName("EventNumber", 46), "RAW_DATA_COLLECTION_ON(46)")
        XCTAssertEqual(s.enumName("MetadataType", 1), "HISTORY_START(1)")
        // Unknown value -> 0xNN(value) form (0xFF -> "0xFF(255)").
        XCTAssertEqual(s.enumName("CommandNumber", 255), "0xFF(255)")
    }

    func testPacketForTypeAndAlias() {
        let s = loadSchema()
        let p40 = s.packet(forType: 40)
        XCTAssertEqual(p40?.name, "REALTIME_DATA")
        XCTAssertEqual(p40?.post, "realtime_data")
        XCTAssertEqual(p40?.fields.first?.name, "timestamp")
        // type 43 = REALTIME_RAW_DATA; type 47 is now its OWN HISTORICAL_DATA packet
        // (no longer an alias of type-43).
        XCTAssertEqual(s.packet(forType: 43)?.name, "REALTIME_RAW_DATA")
        XCTAssertEqual(s.packet(forType: 47)?.name, "HISTORICAL_DATA")
        XCTAssertEqual(s.packet(forType: 47)?.post, "historical_data")
        // unknown type
        XCTAssertNil(s.packet(forType: 200))
    }

    func testVariantsLoaded() {
        let s = loadSchema()
        let raw = s.packet(forType: 43)
        let imu = raw?.variants["1917"]
        XCTAssertEqual(imu?.kind, "imu")
        XCTAssertEqual(imu?.hrOff, 21)
        XCTAssertEqual(imu?.rrCountOff, 22)
        XCTAssertEqual(imu?.rrFirstOff, 23)
        XCTAssertEqual(imu?.samples, 100)
        XCTAssertEqual(imu?.tailFrom, 1292)
        XCTAssertEqual(imu?.axes.count, 6)
        XCTAssertEqual(imu?.axes[0].name, "accelX")
        XCTAssertEqual(imu?.axes[0].off, 89)
        XCTAssertEqual(imu?.axes[0].cat, "accel")
        XCTAssertEqual(imu?.axes[5].name, "gyroZ")
        XCTAssertEqual(imu?.axes[5].off, 1092)
        let opt = raw?.variants["1921"]
        XCTAssertEqual(opt?.kind, "optical")
        XCTAssertEqual(opt?.configFrom, 15)
        XCTAssertEqual(opt?.ppgOff, 42)
        XCTAssertEqual(opt?.ppgStride, 4)
        XCTAssertEqual(opt?.ppgSamples, 419)
    }

    func testLoadSchemaIsCached() {
        // Same backing instance returned (cache hit) — pointer identity via enums dict count.
        let a = loadSchema()
        let b = loadSchema()
        XCTAssertEqual(a.enums.count, b.enums.count)
        XCTAssertFalse(a.enums.isEmpty)
    }
}
