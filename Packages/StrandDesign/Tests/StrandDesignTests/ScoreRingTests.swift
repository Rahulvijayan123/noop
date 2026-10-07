import XCTest
@testable import StrandDesign

/// The ring's arc, centre text and sizing rules. The ring draws whatever it is given, so the only ways it
/// can mislead are an arc past full or below empty, a number shown for a missing score, or a numeral too
/// large for its well; those are pure functions and pinned here.
final class ScoreRingTests: XCTestCase {

    func testFractionIsClampedToZeroThroughOne() {
        XCTAssertEqual(ScoreRing.clampedFraction(0.62), 0.62)
        XCTAssertEqual(ScoreRing.clampedFraction(-0.2), 0)
        XCTAssertEqual(ScoreRing.clampedFraction(1.4), 1)
        XCTAssertEqual(ScoreRing.clampedFraction(0), 0)
        XCTAssertEqual(ScoreRing.clampedFraction(1), 1)
    }

    /// A score divided by a zero or missing scale upstream arrives as NaN or infinity; the ring treats it
    /// as no score rather than drawing a full or empty arc that looks like a real reading.
    func testNonFiniteFractionIsNoScore() {
        XCTAssertNil(ScoreRing.clampedFraction(nil))
        XCTAssertNil(ScoreRing.clampedFraction(.nan))
        XCTAssertNil(ScoreRing.clampedFraction(.infinity))
        XCTAssertNil(ScoreRing.clampedFraction(-.infinity))
    }

    func testMissingScoreShowsADashWhateverTheValueSays() {
        XCTAssertEqual(ScoreRing.displayValue(fraction: nil, value: "62"), "—")
        XCTAssertEqual(ScoreRing.displayValue(fraction: .nan, value: "62"), "—")
        XCTAssertEqual(ScoreRing.displayValue(fraction: 0.5, value: " "), "—")
        XCTAssertEqual(ScoreRing.displayValue(fraction: 0.5, value: "50"), "50")
        // A zero score is a score: it shows its number on an empty track.
        XCTAssertEqual(ScoreRing.displayValue(fraction: 0, value: "0"), "0")
    }

    func testDefaultLineWidthScalesWithTheRingAndHasAFloor() {
        XCTAssertEqual(ScoreRing.defaultLineWidth(diameter: 100), 9, accuracy: 0.001)
        XCTAssertEqual(ScoreRing.defaultLineWidth(diameter: 20), 4)
    }

    /// An 88 pt ring (Today) gets roughly the 28 pt tile numeral and a 140 pt ring the 40 pt hero; nothing
    /// exceeds the hero size or drops below legibility.
    func testNumeralSizeFitsTheWell() {
        let small = ScoreRing.numeralSize(diameter: 88, lineWidth: ScoreRing.defaultLineWidth(diameter: 88))
        XCTAssertEqual(small, 29, accuracy: 1)
        XCTAssertEqual(ScoreRing.numeralSize(diameter: 140, lineWidth: 12.6), 40)
        XCTAssertEqual(ScoreRing.numeralSize(diameter: 400, lineWidth: 36), 40)
        XCTAssertEqual(ScoreRing.numeralSize(diameter: 30, lineWidth: 4), 14)
    }
}
