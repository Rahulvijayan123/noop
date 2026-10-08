import XCTest

/// The floating glass tab bar with Liquid Glass on (the default): the Sana composer clears it, and the bar is
/// itself a slider, its selected-tab lens dragging through the tabs.
final class GlassTabBarUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--demo-seed", "--demo-tab", "4"]
        app.launch()
    }

    func testTheSanaComposerSitsAboveTheGlassBar() {
        let field = app.textFields["coachMessageField"].exists ? app.textFields["coachMessageField"]
                                                                : app.textViews["coachMessageField"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        let sana = app.buttons["tab.sana"]
        XCTAssertTrue(sana.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(field.frame.maxY, sana.frame.minY + 1, "the composer is under the tab bar")

        field.tap()
        app.typeText("Hello")
        XCTAssertEqual(field.value as? String, "Hello")
    }

    func testDraggingTheBarSlidesThroughTheTabs() {
        let sana = app.buttons["tab.sana"]
        XCTAssertTrue(sana.waitForExistence(timeout: 15))
        XCTAssertTrue(sana.isSelected)

        func center(_ id: String) -> XCUICoordinate {
            app.buttons[id].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        }

        // Drag the lens from Sana across to Today.
        center("tab.sana").press(forDuration: 0.1, thenDragTo: center("tab.today"))
        XCTAssertTrue(app.buttons["tab.today"].isSelected)
        XCTAssertFalse(app.buttons["tab.sana"].isSelected)

        // And back to the middle: Events.
        center("tab.today").press(forDuration: 0.1, thenDragTo: center("tab.events"))
        XCTAssertTrue(app.buttons["tab.events"].isSelected)

        // A plain tap still selects a tab.
        app.buttons["tab.sleep"].tap()
        XCTAssertTrue(app.buttons["tab.sleep"].isSelected)
    }
}
