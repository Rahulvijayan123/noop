import XCTest

/// The floating glass tab bar with Liquid Glass on (the default): the Sana composer clears it, and the slider
/// row above it scrubs between tabs.
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
        let bar = app.otherElements["tab.slider"].exists ? app.otherElements["tab.slider"] : app.sliders["tab.slider"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(field.frame.maxY, bar.frame.minY + 1, "the composer is under the tab bar")

        field.tap()
        app.typeText("Hello")
        XCTAssertEqual(field.value as? String, "Hello")
    }

    func testDraggingTheSliderSwitchesTabs() {
        let slider = app.descendants(matching: .any)["tab.slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 15))
        XCTAssertEqual(slider.value as? String, "5 of 5")

        // Drag the thumb from the last stop to the first.
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)))
        XCTAssertEqual(slider.value as? String, "1 of 5")
        XCTAssertTrue(app.buttons["tab.today"].isSelected)

        // Tapping a stop jumps there.
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(slider.value as? String, "3 of 5")
        XCTAssertTrue(app.buttons["tab.events"].isSelected)
    }
}
