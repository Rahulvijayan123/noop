import XCTest

/// Drives Sana's interactive cards on the `--demo-screen genui` pages: a live calculator re-evaluates as its
/// slider moves, a form sends its answers as one message and then locks, and a plain action button sends its
/// message.
final class CoachGenUIUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ page: String) {
        app.launchArguments = ["--demo-seed", "--demo-screen", page]
        app.launch()
    }

    private var sent: XCUIElement { app.staticTexts["genuiDemo.sent"] }

    func testCardsRenderWithTheChartPlacedInside() {
        launch("genui")
        XCTAssertTrue(app.staticTexts["Your HRV this week"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["58 ms"].exists)
        XCTAssertTrue(labelled("Keep the 22:45 bedtime").exists)
        XCTAssertFalse(labelled("root =").exists)
    }

    private func labelled(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testABoundSliderUpdatesTheCardLive() {
        launch("genui")
        let result = labelled("L a day")
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.contains("2.3 L"), result.label)

        let slider = app.sliders["Body weight"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(labelled("4.6 L a day")
            .waitForExistence(timeout: 5), result.label)
        XCTAssertEqual(sent.label, "Nothing sent yet")
    }

    func testAFormSendsItsAnswersOnceAndLocks() {
        launch("genui2")
        XCTAssertTrue(app.staticTexts["Build your week"].waitForExistence(timeout: 10))

        let days = app.steppers["Training days"]
        XCTAssertEqual(days.value as? String, "4 days")
        days.buttons["Increment"].tap()
        app.buttons["Strength"].tap()

        let submit = app.buttons["coachCard.button.Build my plan"]
        XCTAssertTrue(submit.exists)
        submit.tap()

        XCTAssertTrue(sent.label.hasPrefix("Build my plan"), sent.label)
        XCTAssertTrue(sent.label.contains("• Training days: 5 days"), sent.label)
        XCTAssertTrue(sent.label.contains("• Main goal: Strength"), sent.label)
        XCTAssertTrue(sent.label.contains("• Time per session: 45 min"), sent.label)

        XCTAssertFalse(submit.isEnabled)
        XCTAssertTrue(app.staticTexts["Sent"].exists)
        XCTAssertFalse(app.buttons["Endurance"].isEnabled)
    }

    func testAnActionButtonSendsItsMessage() {
        launch("genui2")
        let helped = app.buttons["coachCard.button.That helped"]
        XCTAssertTrue(helped.waitForExistence(timeout: 10))
        if !helped.isHittable { app.swipeUp() }
        helped.tap()
        XCTAssertEqual(sent.label, "The box breathing helped. What next?")
        XCTAssertTrue(labelled("Inhale").exists)
    }

    /// The sandboxed HTML tool: its slider recomputes in the web view, and its button asks through the bridge.
    func testASandboxedToolRunsAndAsksAfterATap() {
        launch("genui3")
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 15))
        let slider = web.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        XCTAssertTrue(web.staticTexts["21:15"].waitForExistence(timeout: 5))
        let from = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let to = slider.coordinate(withNormalizedOffset: CGVector(dx: 1.2, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: to)
        XCTAssertTrue(web.staticTexts["10:00"].waitForExistence(timeout: 5))
        XCTAssertTrue(web.staticTexts["0:45"].exists)
        XCTAssertEqual(sent.label, "Nothing sent yet")

        web.buttons["Plan my evening around this"].tap()
        let asked = NSPredicate(format: "label == %@", "Plan my evening for a 0:45 bedtime")
        expectation(for: asked, evaluatedWith: sent)
        waitForExpectations(timeout: 5)
    }
}
