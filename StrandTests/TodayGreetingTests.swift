import XCTest
@testable import Strand

final class TodayGreetingTests: XCTestCase {
    func testTheWordFollowsTheHour() {
        XCTAssertEqual(LiquidTodayView.greeting(hour: 5, displayName: ""), "Good morning")
        XCTAssertEqual(LiquidTodayView.greeting(hour: 11, displayName: ""), "Good morning")
        XCTAssertEqual(LiquidTodayView.greeting(hour: 12, displayName: ""), "Good afternoon")
        XCTAssertEqual(LiquidTodayView.greeting(hour: 16, displayName: ""), "Good afternoon")
        XCTAssertEqual(LiquidTodayView.greeting(hour: 17, displayName: ""), "Good evening")
        XCTAssertEqual(LiquidTodayView.greeting(hour: 23, displayName: ""), "Good evening")
        XCTAssertEqual(LiquidTodayView.greeting(hour: 2, displayName: ""), "Good evening")
    }

    func testTheNameIsTheFirstWordOnly() {
        XCTAssertEqual(LiquidTodayView.greeting(hour: 9, displayName: "Rahul"), "Good morning, Rahul")
        XCTAssertEqual(LiquidTodayView.greeting(hour: 9, displayName: "  Rahul Vijayan "), "Good morning, Rahul")
        XCTAssertEqual(LiquidTodayView.greeting(hour: 9, displayName: "   "), "Good morning")
    }
}
