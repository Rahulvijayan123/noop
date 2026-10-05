import XCTest
import SwiftUI
import AppKit
import StrandAnalytics
@testable import Strand

/// A Heart rate page wider than its viewport slides sideways under a drag. The activity boxes carry long titles
/// ("Asleep or lying down", "Still, sitting or standing") and must wrap inside the width they are given.
@MainActor
final class FamilyTileGridLayoutTests: XCTestCase {
    private var everyFamily: [FamilyTotal] {
        ActivityFamily.allCases.enumerated().map {
            FamilyTotal(family: $1, seconds: 36_000 - $0 * 1_000, stretches: 12 + $0)
        }
    }

    func testTilesNeverAskForMoreWidthThanTheyAreGiven() {
        for width in [200.0, 280.0, 358.0] {
            let host = NSHostingController(rootView: FamilyTileGrid(totals: everyFamily) { _ in EmptyView() })
            let size = host.sizeThatFits(in: CGSize(width: width, height: 10_000))
            XCTAssertLessThanOrEqual(size.width, width + 0.5,
                                     "tiles asked for \(size.width) pt where \(width) pt was on offer")
        }
    }
}
