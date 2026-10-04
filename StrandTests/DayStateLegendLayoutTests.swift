import XCTest
import SwiftUI
import AppKit
import StrandAnalytics
@testable import Strand

/// The day-state legend used to be a single row of single-line labels. With every state present it asked
/// for more width than a phone has (about 358.3 pt where 358 was on offer), which made the whole Heart rate
/// page a third of a point wider than the screen. A page wider than its viewport slides sideways under a drag.
@MainActor
final class DayStateLegendLayoutTests: XCTestCase {
    func testLegendNeverAsksForMoreWidthThanItIsGiven() {
        for width in [120.0, 200.0, 280.0] {
            let host = NSHostingController(rootView: DayStateLegend(states: DayState.displayOrder))
            let size = host.sizeThatFits(in: CGSize(width: width, height: 10_000))
            XCTAssertLessThanOrEqual(size.width, width + 0.5,
                                     "legend asked for \(size.width) pt where \(width) pt was on offer")
        }
    }

    func testLegendWrapsOntoMoreRowsWhenNarrower() {
        let wide = NSHostingController(rootView: DayStateLegend(states: DayState.displayOrder))
            .sizeThatFits(in: CGSize(width: 600, height: 10_000))
        let narrow = NSHostingController(rootView: DayStateLegend(states: DayState.displayOrder))
            .sizeThatFits(in: CGSize(width: 200, height: 10_000))
        XCTAssertGreaterThan(narrow.height, wide.height)
    }
}
