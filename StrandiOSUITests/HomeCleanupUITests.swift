import XCTest

/// The Today greeting, the card pop-up, the trimmed Browse list, the metrics guide and the plain Sana header.
final class HomeCleanupUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ args: [String]) {
        app.launchArguments = args
        app.launch()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTodayOpensWithAGreetingAndNoDayNavigation() {
        launch(["--demo-seed", "--demo-tab", "0"])
        let greeting = app.staticTexts["today.greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 20))
        XCTAssertTrue(greeting.label.hasPrefix("Good morning") || greeting.label.hasPrefix("Good afternoon")
                      || greeting.label.hasPrefix("Good evening"), "greeting was \(greeting.label)")
        XCTAssertFalse(app.buttons["Previous day"].exists)
        XCTAssertFalse(app.buttons["Next day"].exists)
        XCTAssertFalse(app.buttons["Return to today"].exists)
        attach("today-greeting")
    }

    func testTappingAMetricOpensItsDetailPageWithAnAboutSection() {
        launch(["--demo-seed", "--demo-tab", "0"])
        let hrv = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'HRV'")).firstMatch
        XCTAssertTrue(hrv.waitForExistence(timeout: 20))
        hrv.tap()
        // The detail page, not a pop-up: it has a back button and an About section.
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10))
        let about = app.buttons["About"]
        var swipes = 0
        while !about.isHittable && swipes < 14 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(about.exists, "the detail page has no About section")
        app.swipeUp()
        attach("metric-detail-about")
    }

    func testTheHeartRateCardOpensYourDay() {
        launch(["--demo-seed", "--demo-tab", "0"])
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Heart rate'")).firstMatch
        var swipes = 0
        while !card.exists && swipes < 12 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.tap()
        XCTAssertTrue(app.staticTexts["Your health and activity at a glance."].waitForExistence(timeout: 10),
                      "the heart rate card should open the day view")
        attach("heart-rate-day")
    }

    func testBrowseHasOnlyTheKeptRows() {
        launch(["--demo-seed", "--demo-screen", "browse"])
        XCTAssertTrue(app.staticTexts["Health"].waitForExistence(timeout: 20))
        for kept in ["Trends", "Explore", "Compare", "Week in review", "Workouts", "Lift Log",
                     "How your metrics work"] {
            XCTAssertTrue(app.staticTexts[kept].exists, "\(kept) is missing")
        }
        for removed in ["Hydration", "Live", "Live session", "Stress", "Breathe", "Intervals", "Rhythm",
                        "Insights", "What Moves You", "Intelligence", "Lab Book", "Coupled view",
                        "Data sources", "Your Data, Fused", "Mi Band", "Nara Limitations", "Updates",
                        "Charge", "Effort", "Recovery"] {
            XCTAssertFalse(app.staticTexts[removed].exists, "\(removed) should be gone")
        }
        attach("browse")
    }

    func testTheMetricsGuideListsRealMetricsWithStudies() {
        launch(["--demo-seed", "--demo-screen", "scoringguide"])
        XCTAssertTrue(app.staticTexts["Heart-rate variability"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Studies"].exists)
        XCTAssertFalse(app.staticTexts["Charge: how recovered are you?"].exists)
        XCTAssertFalse(app.staticTexts["Effort: how hard did your heart work?"].exists)
        XCTAssertFalse(app.staticTexts["Rest: how restorative was your sleep?"].exists)
        attach("metrics-guide")
    }

    func testSanaHeaderIsJustTheName() {
        launch(["--demo-seed", "--demo-tab", "4"])
        XCTAssertTrue(app.staticTexts["Sana"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Your health assistant"].exists)
        XCTAssertFalse(app.staticTexts["coachThreadTitle"].exists)
        attach("sana-header")
    }
}
