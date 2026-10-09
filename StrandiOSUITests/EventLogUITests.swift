import XCTest

/// Logged events in the Events tab: the latest-reaction card and the timeline show them with their strap
/// curves, and the event page offers heart rate, HRV and movement. Runs on the DEBUG `eventslog` demo, an
/// in-memory account with one logged walk and a sample context (no server).
final class EventLogUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--demo-no-prompts", "--demo-screen", "eventslog"]
        app.launch()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func scroll(to element: XCUIElement, limit: Int = 10) {
        var swipes = 0
        while !element.isHittable && swipes < limit { app.swipeUp(); swipes += 1 }
    }

    func testALoggedEventLeadsTheLatestReactionAndTimelineAndOpensItsCurves() {
        XCTAssertTrue(app.staticTexts["Event log"].waitForExistence(timeout: 20))
        let latest = app.staticTexts["Latest reaction"]
        scroll(to: latest)
        XCTAssertTrue(latest.exists, "a logged event with strap curves leads the latest-reaction card")
        attach("events-latest-reaction")
        let timeline = app.staticTexts["Timeline"]
        scroll(to: timeline)
        XCTAssertTrue(timeline.exists, "logged events fill the timeline")
        XCTAssertFalse(app.staticTexts["No events yet."].exists)
        attach("events-timeline")

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Walk after lunch'")).allElementsBoundByIndex
            .last { $0.isHittable }
        XCTAssertNotNil(row, "the timeline row for the logged walk")
        row?.tap()
        for metric in ["Heart rate", "HRV", "Movement"] {
            XCTAssertTrue(app.buttons[metric].waitForExistence(timeout: 10), "\(metric) curve on the event page")
        }
        attach("event-page-heart-rate")
        app.buttons["Movement"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'mg vs before'")).firstMatch
            .waitForExistence(timeout: 5), "movement reads in milli-g against before, not as a percentage")
        attach("event-page-movement")
    }
}
