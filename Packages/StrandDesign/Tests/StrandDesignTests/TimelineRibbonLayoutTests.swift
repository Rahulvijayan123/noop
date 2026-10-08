import XCTest
@testable import StrandDesign

/// The activity ribbon lines up under an `IntradayChart` by reserving the chart's own value-axis gutter: the
/// widest tick label the chart will print for the same values. These pin that it asks the same axis layout
/// the chart does, and that its height is the sum of its lanes.
final class TimelineRibbonLayoutTests: XCTestCase {

    func testGutterTextIsTheWidestLabelOfTheSameLayout() {
        let axis = ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 40, clampTo: 30...230))
        let values: [Double] = [52, 61, 148, 96]
        let labels = axis.layout(for: values).labels
        let gutter = TimelineRibbon.gutterText(for: axis, values: values)
        XCTAssertTrue(labels.contains(gutter))
        XCTAssertEqual(gutter.count, labels.map(\.count).max())
    }

    func testGutterTextFollowsTheChartsDomain() {
        // A calm day keeps two-digit ticks; a hard one reaches three.
        let axis = ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 40, clampTo: 30...230))
        XCTAssertEqual(TimelineRibbon.gutterText(for: axis, values: [50, 60]).count, 2)
        XCTAssertEqual(TimelineRibbon.gutterText(for: axis, values: [55, 175]).count, 3)
    }

    func testHeightIsTheLanesTicksAndSpacing() {
        let lanes = [
            TimelineRibbon.Lane(id: "a", title: "Activity", segments: [], ticks: [Date()]),
            TimelineRibbon.Lane(id: "w", title: "Walks", segments: [], height: TimelineRibbon.thinLaneHeight),
        ]
        XCTAssertEqual(TimelineRibbon.height(for: lanes),
                       TimelineRibbon.laneHeight + TimelineRibbon.tickHeight + TimelineRibbon.laneSpacing
                       + TimelineRibbon.thinLaneHeight)
        XCTAssertEqual(TimelineRibbon.height(for: []), 0)
    }
}
