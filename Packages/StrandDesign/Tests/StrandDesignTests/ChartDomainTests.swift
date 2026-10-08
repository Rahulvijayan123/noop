import XCTest
import SwiftUI
@testable import StrandDesign

/// The value axis: fixed where the metric has a scale, fitted otherwise, never hiding a reading, and ticks
/// that land on round numbers and never print the same label twice.
final class ChartDomainTests: XCTestCase {

    // MARK: Fixed

    func testAFixedScaleIsKeptWhenEveryValueFitsIt() {
        XCTAssertEqual(ChartDomain.fixed(0...100).resolve([12, 96]), 0...100)
        XCTAssertEqual(ChartDomain.fixed(0...100).resolve([]), 0...100)
        XCTAssertEqual(ChartDomain.fixed(85...100).resolve([95, 99]), 85...100)
    }

    /// A night at 82 % oxygen is the reading that matters most; a fixed 85...100 axis must not drop it.
    func testAFixedScaleWidensJustEnoughToShowAnOutlier() {
        let domain = ChartDomain.fixed(85...100).resolve([82, 97])
        XCTAssertEqual(domain.upperBound, 100)
        XCTAssertLessThanOrEqual(domain.lowerBound, 82)
        XCTAssertEqual(domain.lowerBound, 80, "widened to the axis's own 5-point step")
    }

    // MARK: Fitted

    func testAFittedAxisIsAtLeastItsMinimumSpanAndEndsOnRoundSteps() {
        let domain = ChartDomain.fitted(minSpan: 20).resolve([60, 62])
        XCTAssertEqual(domain, 40...80)
        XCTAssertGreaterThanOrEqual(domain.upperBound - domain.lowerBound, 20)
    }

    func testIncludingZeroAnchorsTheFloor() {
        let domain = ChartDomain.fitted(minSpan: 1_000, includeZero: true).resolve([4_200, 9_800])
        XCTAssertEqual(domain.lowerBound, 0)
        XCTAssertGreaterThanOrEqual(domain.upperBound, 9_800)
    }

    func testANonNegativeSeriesNeverGetsANegativeAxis() {
        XCTAssertEqual(ChartDomain.fitted(minSpan: 20).resolve([3, 5]).lowerBound, 0)
    }

    func testAClampKeepsTheAxisInsideItsNaturalLimit() {
        let domain = ChartDomain.fitted(minSpan: 5, clampTo: 0...100).resolve([97, 99.5])
        XCTAssertEqual(domain.upperBound, 100)
        XCTAssertLessThanOrEqual(domain.lowerBound, 97)
    }

    func testNoDataGivesAnHonestEmptyAxis() {
        XCTAssertEqual(ChartDomain.fitted(minSpan: 20).resolve([]), 0...20)
    }

    func testNonFiniteValuesAreIgnored() {
        XCTAssertEqual(ChartDomain.fixed(0...100).resolve([.nan, 50]), 0...100)
        XCTAssertEqual(ChartDomain.fitted(minSpan: 20).resolve([.nan, .infinity, 60, 62]),
                       ChartDomain.fitted(minSpan: 20).resolve([60, 62]))
    }

    // MARK: Symmetric

    func testASymmetricAxisIsCentredOnZero() {
        XCTAssertEqual(ChartDomain.symmetric(minMagnitude: 0.5).resolve([0.2, -0.3]), -0.5...0.5)
        let wide = ChartDomain.symmetric(minMagnitude: 0.5).resolve([1.3])
        XCTAssertEqual(wide.lowerBound, -wide.upperBound)
        XCTAssertGreaterThanOrEqual(wide.upperBound, 1.3)
    }

    // MARK: Ticks

    func testFixedScalesGetRoundTicksOnBothEnds() {
        XCTAssertEqual(ChartTicks.nice(in: 0...100), [0, 25, 50, 75, 100])
        XCTAssertEqual(ChartTicks.nice(in: 85...100), [85, 90, 95, 100])
        XCTAssertEqual(ChartTicks.nice(in: 50...100), [50, 75, 100])
        XCTAssertEqual(ChartTicks.nice(in: 0...3), [0, 1, 2, 3])
        XCTAssertEqual(ChartTicks.nice(in: 0...21), [0, 10, 20])
    }

    func testTickValuesAreExactMultiples() {
        let ticks = ChartTicks.values(in: 0...1, step: 0.1)
        XCTAssertEqual(ticks.count, 11)
        XCTAssertTrue(ticks.contains(0.3), "0.1 * 3 must not print as 0.30000000000000004")
    }

    /// The zero tick of a 0-based axis was a negative zero and printed "-0".
    func testTheZeroTickIsNeverNegative() {
        for domain in [0.0...100, 0...15_000, -1...1] {
            let zero = ChartTicks.values(in: domain, step: ChartTicks.step(span: domain.upperBound - domain.lowerBound, count: 4))
                .first { $0 == 0 }
            XCTAssertEqual(zero?.sign, .plus, "\(domain)")
        }
        XCTAssertFalse(ChartValueAxis(unit: nil, domain: .fixed(0...100)).layout(for: []).labels.contains("-0"))
    }

    func testAFittedAxisTicksUseTheStepThatRoundedIt() {
        let layout = ChartValueAxis(unit: "ms", domain: .fitted(minSpan: 20)).layout(for: [52.3, 71.8])
        XCTAssertEqual(layout.ticks.first, layout.domain.lowerBound)
        XCTAssertEqual(layout.ticks.last, layout.domain.upperBound)
        XCTAssertGreaterThanOrEqual(layout.ticks.count, 3)
        XCTAssertEqual(layout.unit, "ms")
    }

    /// Quarter steps under a whole-number format would print "0, 0, 1": the labels gain the decimals the
    /// step needs instead.
    func testLabelsNeverRepeat() {
        let layout = ChartValueAxis(unit: nil, domain: .fixed(0...1), ticks: [0, 0.25, 0.5, 0.75, 1]).layout(for: [])
        XCTAssertEqual(Set(layout.labels).count, layout.labels.count, "\(layout.labels)")
        XCTAssertTrue(layout.labels[1].contains("25"), "\(layout.labels)")
    }

    func testBelowOneTheStepAvoidsQuarters() {
        XCTAssertEqual(ChartTicks.step(span: 1, count: 4), 0.5)
        XCTAssertEqual(ChartTicks.step(span: 100, count: 4), 25)
    }

    func testADurationAxisTicksOnWholeHours() {
        let layout = ChartValueAxis.durationMinutes().layout(for: [380, 460])
        XCTAssertEqual(layout.domain.lowerBound, 0)
        XCTAssertTrue(layout.ticks.allSatisfy { $0.truncatingRemainder(dividingBy: 60) == 0 }, "\(layout.ticks)")
        XCTAssertEqual(layout.unit, "h")
        XCTAssertEqual(ChartValueAxis.hoursFromMinutes(420), "7")
    }

    func testALayoutLabelsOnlyItsOwnTicks() {
        let layout = ChartYAxisLayout(domain: 0...10, ticks: [0, 5, 10], labels: ["0", "5", "10"], unit: nil)
        XCTAssertEqual(layout.label(for: 5), "5")
        XCTAssertNil(layout.label(for: 4))
    }

    // MARK: Bands

    /// The kit compares like the scorers do: a value belongs to the first band whose bound is ABOVE it.
    func testScoreBandsUseExclusiveUpperBounds() {
        let bands = ScoreBands([
            .init(upperBound: 67, color: .yellow, name: "yellow"),
            .init(upperBound: 34, color: .red, name: "red"),
            .init(upperBound: 101, color: .green, name: "green"),
        ])
        XCTAssertEqual(bands.bands.map(\.name), ["red", "yellow", "green"], "sorted ascending")
        XCTAssertEqual(bands.band(for: 0).name, "red")
        XCTAssertEqual(bands.band(for: 33.9).name, "red")
        XCTAssertEqual(bands.band(for: 34).name, "yellow", "the same `score < 34` RecoveryScorer.band uses")
        XCTAssertEqual(bands.band(for: 67).name, "green")
        XCTAssertEqual(bands.band(for: 250).name, "green", "above every bound is the last band")
        XCTAssertEqual(ScoreBands([]).band(for: 50).name, "", "no bands is a neutral placeholder, not a crash")
    }
}
