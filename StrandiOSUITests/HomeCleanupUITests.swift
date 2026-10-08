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

    func testTappingACardOpensItsExplanation() {
        launch(["--demo-seed", "--demo-tab", "0"])
        let baseline = app.buttons["Baseline"]
        XCTAssertTrue(baseline.waitForExistence(timeout: 20))
        baseline.tap()

        let done = app.buttons["cardExplainer.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the pop-up did not open")
        XCTAssertTrue(app.staticTexts["What it is"].exists)
        XCTAssertTrue(app.staticTexts["How Nara measures it"].exists)
        attach("card-explainer-baseline")

        // Its detail page is one button away, and opens after the pop-up closes.
        let open = app.buttons["cardExplainer.openDetails"]
        XCTAssertTrue(open.exists)
        open.tap()
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(done.exists)
    }

    func testAMetricTileExplainsItselfWithStudies() {
        launch(["--demo-seed", "--demo-tab", "0"])
        let hrv = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'HRV'")).firstMatch
        XCTAssertTrue(hrv.waitForExistence(timeout: 20))
        hrv.tap()
        XCTAssertTrue(app.buttons["cardExplainer.done"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Studies"].exists)
        attach("card-explainer-hrv")
        app.buttons["cardExplainer.done"].tap()
        XCTAssertFalse(app.buttons["cardExplainer.done"].waitForExistence(timeout: 2))
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
