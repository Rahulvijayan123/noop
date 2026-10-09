import XCTest
@testable import StrandDesign

/// The small layout rules behind the kit's fixed-height components: how a StatGrid breaks its items into
/// rows, what a MetricTile's state line says, how much of a readings list is shown, and the one shared
/// card shadow. Each is a decision a screen would otherwise make differently.
final class KitLayoutRulesTests: XCTestCase {

    // MARK: StatGrid

    func testStatGridFillsRowsAndPadsTheLastOne() {
        XCTAssertEqual(StatGrid.rows(itemCount: 4, columns: 2), [[0, 1], [2, 3]])
        XCTAssertEqual(StatGrid.rows(itemCount: 3, columns: 2), [[0, 1], [2, nil]])
        XCTAssertEqual(StatGrid.rows(itemCount: 3, columns: 3), [[0, 1, 2]])
        XCTAssertEqual(StatGrid.rows(itemCount: 0, columns: 2), [])
    }

    /// Two items in a 4-column grid are two halves, not two quarters with empty space beside them.
    func testStatGridNeverHasMoreColumnsThanItems() {
        XCTAssertEqual(StatGrid.rows(itemCount: 2, columns: 4), [[0, 1]])
    }

    func testStatGridClampsColumnsToOneThroughFour() {
        XCTAssertEqual(StatGrid.rows(itemCount: 5, columns: 9), [[0, 1, 2, 3], [4, nil, nil, nil]])
        XCTAssertEqual(StatGrid.rows(itemCount: 2, columns: 0), [[0], [1]])
    }

    func testStatItemShowsADashWithNoUnitWhenMissing() {
        XCTAssertEqual(StatItem("Low", value: nil, unit: "ms").displayValue, "—")
        XCTAssertNil(StatItem("Low", value: nil, unit: "ms").displayUnit)
        XCTAssertEqual(StatItem("Low", value: "42", unit: "ms").displayUnit, "ms")
    }

    // MARK: MetricTile

    func testMetricTileStateLine() {
        XCTAssertNil(MetricTile.stateLine(state: nil, isEstimate: false))
        XCTAssertNil(MetricTile.stateLine(state: "  ", isEstimate: false))
        XCTAssertEqual(MetricTile.stateLine(state: "Low", isEstimate: false), "Low")
        XCTAssertEqual(MetricTile.stateLine(state: nil, isEstimate: true), "Estimate")
        XCTAssertEqual(MetricTile.stateLine(state: "Low", isEstimate: true), "Low · Estimate")
    }

    // MARK: ReadingsList

    func testReadingsListShowsTheNewestFewAndOffersTheRest() {
        let rows = (0..<10).map { ReadingsList.Row(id: "\($0)", date: "d\($0)", value: "\($0)") }
        XCTAssertEqual(ReadingsList.visibleRows(rows, visibleCount: 7).map(\.id), ["0", "1", "2", "3", "4", "5", "6"])
        XCTAssertTrue(ReadingsList.hasMore(rows, visibleCount: 7))
        XCTAssertFalse(ReadingsList.hasMore(Array(rows.prefix(7)), visibleCount: 7))
        // A zero or negative count still shows the newest reading rather than an empty card.
        XCTAssertEqual(ReadingsList.visibleRows(rows, visibleCount: 0).count, 1)
    }

    // MARK: Surfaces

    /// One shared two-layer lift (a wide ambient shadow and a tight contact shadow) in both schemes, so a card
    /// hovers over the canvas on light and on dark.
    func testCardShadowLiftsInBothSchemes() {
        let light = NoopSurfaceShadow.resolve(elevated: false, dark: false)
        XCTAssertEqual(light.radius, 20)
        XCTAssertEqual(light.y, 9)
        XCTAssertGreaterThan(light.contactRadius, 0)
        let dark = NoopSurfaceShadow.resolve(elevated: false, dark: true)
        XCTAssertGreaterThan(dark.radius, 0)
        XCTAssertNotEqual(dark.color, .clear)
        // Floating surfaces lift a little more than cards, in both schemes.
        XCTAssertGreaterThan(NoopSurfaceShadow.resolve(elevated: true, dark: false).radius, light.radius)
        XCTAssertGreaterThan(NoopSurfaceShadow.resolve(elevated: true, dark: true).radius, dark.radius)
    }

    /// The selected segment's corner is the track's minus the track padding, so the curves are concentric.
    func testSegmentedControlCornersAreConcentric() {
        XCTAssertEqual(NoopMetrics.segmentRadius, NoopMetrics.insetRadius - NoopMetrics.segmentedTrackPadding)
    }
}
