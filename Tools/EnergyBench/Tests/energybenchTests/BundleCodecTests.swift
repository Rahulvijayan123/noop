import XCTest
import WhoopProtocol
@testable import energybench

final class BundleCodecTests: XCTestCase {

    private func stream(t0: Int = 1_000, n: Int, scale: Double? = nil, _ v: String) -> DayBundle.Stream {
        DayBundle.Stream(t0: t0, n: n, scale: scale, v: v)
    }

    func testHeartRateDecodesDeltasOntoTheStartTime() throws {
        let hr = try StreamCodec.heartRate(stream(n: 4, "0 60,1 61,1 62,5 70"))
        XCTAssertEqual(hr.map(\.ts), [1_000, 1_001, 1_002, 1_007])
        XCTAssertEqual(hr.map(\.bpm), [60, 61, 62, 70])
    }

    func testGravityDecodesScaledValuesAndAnEmptyDynIsNil() throws {
        let g = try StreamCodec.gravity(stream(n: 2, scale: 10_000, "0 9817 -1738 506 129,1 9820 -1649 565 "))
        XCTAssertEqual(g[0].x, 0.9817, accuracy: 1e-9)
        XCTAssertEqual(g[0].y, -0.1738, accuracy: 1e-9)
        XCTAssertEqual(g[0].dynAccel ?? -1, 0.0129, accuracy: 1e-9)
        XCTAssertNil(g[1].dynAccel, "an empty dyn field is a missing value, not zero")
        XCTAssertEqual(g[1].ts, 1_001)
    }

    func testStepsDecodeTheCounterAndAnEmptyActivityClassIsNil() throws {
        let s = try StreamCodec.steps(stream(n: 3, "0 12056 0,1 12057 1,1 12057 "))
        XCTAssertEqual(s.map(\.counter), [12056, 12057, 12057])
        XCTAssertEqual(s.map(\.activityClass), [0, 1, nil])
    }

    func testADeclaredCountThatDisagreesWithTheItemsIsRejected() {
        XCTAssertThrowsError(try StreamCodec.heartRate(stream(n: 5, "0 60,1 61"))) { error in
            guard case BundleError.countMismatch(let name, let declared, let actual) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertEqual(name, "hr"); XCTAssertEqual(declared, 5); XCTAssertEqual(actual, 2)
        }
    }

    func testMalformedItemsAreRejectedRatherThanGuessed() {
        XCTAssertThrowsError(try StreamCodec.heartRate(stream(n: 1, "0 sixty")))
        XCTAssertThrowsError(try StreamCodec.heartRate(stream(n: 1, "0 60 99")))
        XCTAssertThrowsError(try StreamCodec.gravity(stream(n: 1, scale: 10_000, "0 1 2 3")))
        XCTAssertThrowsError(try StreamCodec.steps(stream(n: 1, "0 12")))
    }

    func testBundleLoadsFromJSONAndRefusesAnotherFormat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("energybench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func json(format: String) -> String {
            """
            {"format":"\(format)","day":"2026-09-22","tz_offset_seconds":-25200,"day_start":1790060400,
             "profile":{"weight_kg":70,"height_cm":175,"age":30.5,"sex":"male"},"resting_hr":51,
             "sleep":[{"start":1790060400,"end":1790070000,"resting_hr":50,"nap":false}],
             "hr":{"t0":1790060400,"n":2,"v":"0 60,1 61"}}
            """
        }
        let good = dir.appendingPathComponent("good.json")
        try json(format: DayBundle.format).write(to: good, atomically: true, encoding: .utf8)
        let bundle = try DayBundle.load(good)
        XCTAssertEqual(bundle.day, "2026-09-22")
        XCTAssertEqual(bundle.tzOffsetSeconds, -25_200)
        XCTAssertEqual(bundle.profile.age, 30.5)
        XCTAssertEqual(bundle.sleep.first?.restingHr, 50)
        XCTAssertNil(bundle.gravity)
        XCTAssertNil(bundle.asOf)

        let bad = dir.appendingPathComponent("bad.json")
        try json(format: "energy-bench-day-v0").write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DayBundle.load(bad))
    }
}
