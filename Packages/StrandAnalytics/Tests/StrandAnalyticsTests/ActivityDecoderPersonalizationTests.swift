import XCTest
@testable import StrandAnalytics

final class ActivityDecoderPersonalizationTests: XCTestCase {

    func testNoProfileKeepsTheDecoderDefaults() {
        let config = ActivityDecoderConfig.personalized(restingHeartRate: nil, maxHeartRate: nil)
        XCTAssertEqual(config, ActivityDecoderConfig())
        XCTAssertEqual(config.restingHeartRate, 60)
        XCTAssertEqual(config.maxHeartRate, 190)
    }

    func testPlausibleValuesAreAppliedAndQuantised() {
        let config = ActivityDecoderConfig.personalized(restingHeartRate: 52, maxHeartRate: 187)
        XCTAssertEqual(config.restingHeartRate, 51, "52 bpm rounds to the 3 bpm grid")
        XCTAssertEqual(config.maxHeartRate, 185, "187 bpm rounds to the 5 bpm grid")
        // Everything else about the decoder is left alone.
        var expected = ActivityDecoderConfig()
        expected.restingHeartRate = 51
        expected.maxHeartRate = 185
        XCTAssertEqual(config, expected)
    }

    func testImplausibleInputsAreIgnoredIndependently() {
        let lowRest = ActivityDecoderConfig.personalized(restingHeartRate: 20, maxHeartRate: 180)
        XCTAssertEqual(lowRest.restingHeartRate, 60, "a resting rate below 35 is a sensor artefact")
        XCTAssertEqual(lowRest.maxHeartRate, 180)
        let highRest = ActivityDecoderConfig.personalized(restingHeartRate: 130, maxHeartRate: nil)
        XCTAssertEqual(highRest.restingHeartRate, 60)
        let lowMax = ActivityDecoderConfig.personalized(restingHeartRate: 55, maxHeartRate: 100)
        XCTAssertEqual(lowMax.maxHeartRate, 190, "a maximum below 140 is not a maximum")
        XCTAssertEqual(lowMax.restingHeartRate, 54)
    }

    func testAReserveTooNarrowToTrustFallsBackToTheDefaultMaximum() {
        let config = ActivityDecoderConfig.personalized(restingHeartRate: 95, maxHeartRate: 145)
        XCTAssertGreaterThanOrEqual(config.maxHeartRate - config.restingHeartRate, ActivityDecoderConfig.minimumHeartRateReserve)
    }

    func testBoundsAreInclusive() {
        XCTAssertEqual(ActivityDecoderConfig.personalized(restingHeartRate: 36, maxHeartRate: 140).restingHeartRate, 36)
        XCTAssertEqual(ActivityDecoderConfig.personalized(restingHeartRate: 99, maxHeartRate: 220).maxHeartRate, 220)
    }

    func testTheCacheTagTracksTheReferenceButNotWithinOneQuantum() {
        let a = ActivityDecoderConfig.personalized(restingHeartRate: 51, maxHeartRate: 185)
        let b = ActivityDecoderConfig.personalized(restingHeartRate: 52, maxHeartRate: 186)
        let c = ActivityDecoderConfig.personalized(restingHeartRate: 55, maxHeartRate: 185)
        XCTAssertEqual(a.cacheTag, b.cacheTag, "a one-beat wobble must not discard every cached day")
        XCTAssertNotEqual(a.cacheTag, c.cacheTag)
        XCTAssertNotEqual(a.cacheTag, ActivityDecoderConfig().cacheTag)
        XCTAssertEqual(ActivityDecoderConfig().cacheTag, "r60m190")
    }

    func testTheCacheTagIsSafeInAFileName() {
        for rest in stride(from: 36.0, through: 99.0, by: 7) {
            let tag = ActivityDecoderConfig.personalized(restingHeartRate: rest, maxHeartRate: 190).cacheTag
            XCTAssertNotNil(tag.range(of: "^r[0-9]+m[0-9]+$", options: .regularExpression), tag)
        }
    }
}
