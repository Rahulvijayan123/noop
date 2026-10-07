import XCTest

/// Drives the iPhone Settings sheet the way a person does: open it from Today, open every row, check each lands
/// on the page its label names, change the preferences, relaunch, and check they come back.
///
/// `--demo-seed` skips the first-run gates so the tab shell is up at launch. The account tests also need the
/// disposable Supabase stack (supabase/tests/e2e/stack.sh) and an app built against it; see
/// supabase/tests/e2e/run_ios_settings_ui.sh, which runs them in two phases with an uninstall in between.
final class SettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--demo-seed"]
    }

    // MARK: - Navigation

    func testEveryRowOpensThePageItNames() {
        app.launch()
        openSettings()

        // Row identifier → something only that page has.
        let pages: [(row: String, marker: XCUIElement)] = [
            ("settings.account", app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier IN %@", ["nara.auth.email", "nara.account.email"])).firstMatch),
            ("settings.name", app.textFields["settings.name.field"]),
            ("settings.dateOfBirth", app.datePickers.firstMatch),
            ("settings.sex", app.buttons["Non-binary"]),
            ("settings.height", app.steppers["Height in centimetres"]),
            ("settings.weight", app.steppers["Weight in kilograms"]),
            ("settings.units", app.buttons["Imperial"]),
            ("settings.appearance", app.buttons["Dark"]),
            ("settings.strap", app.staticTexts["None of these actions delete your recorded data."]),
            ("settings.placement", app.buttons["Bicep"]),
            ("settings.alerts", app.switches["automations.wristAlerts"]),
            ("settings.shortcuts", app.descendants(matching: .any)["automations.doubleTapAction"]),
            ("settings.haptics", app.switches["automations.breathingHaptic"]),
            ("settings.healthInsights", app.switches["automations.rhythm"]),
            ("settings.sensorBiomarkers", app.switches["sensorBiomarkers.toggle"]),
            ("settings.appleHealth", app.descendants(matching: .any)["appleHealth.status"]),
        ]
        for (row, marker) in pages {
            tapRow(row)
            XCTAssertTrue(marker.waitForExistence(timeout: 5), "\(row) did not open its own page")
            assertNoInternalNames(on: row)
            goBack()
        }

        // The rows that used to send people into Monitor, a second copy of Automations or the old explainer.
        for gone in ["Day & night usuals", "Logged treatment start", "Manage automations", "How NOOP works", "Wrist alerts"] {
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", gone)).firstMatch.exists,
                           "\(gone) should not be a Settings row")
        }
        assertNoInternalNames(on: "Settings")
        XCTAssertTrue(element("settings.version").label.contains("("), "version shows the build number")

        // Restore asks before touching anything, and backing out leaves Settings where it was. iOS 26 can show
        // the dialog as a popover without a Cancel button; tapping outside it is the same answer.
        tapRow("settings.restoreBackup")
        let confirm = app.buttons["Choose backup"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists {
            cancel.tap()
        } else {
            app.otherElements["PopoverDismissRegion"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        }
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), "the restore question went away")
        XCTAssertTrue(element("settings.restoreBackup").waitForExistence(timeout: 5))
    }

    // MARK: - Preferences survive a relaunch

    func testLocalPreferencesComeBackAfterARelaunch() {
        app.launch()
        openSettings()

        // Units and appearance.
        tapRow("settings.units")
        app.buttons["Imperial"].tap()
        goBack()
        XCTAssertTrue(element("settings.units").label.contains("Imperial"))
        tapRow("settings.appearance")
        app.buttons["Dark"].tap()
        goBack()
        XCTAssertTrue(waitForLabel(element("settings.appearance"), containing: "Dark"))

        // Wear placement: the row must show the new value as soon as you come back (it used to stay stale).
        tapRow("settings.placement")
        app.buttons["Bicep"].tap()
        goBack()
        XCTAssertTrue(waitForLabel(element("settings.placement"), containing: "Bicep"))

        // Name.
        tapRow("settings.name")
        let field = app.textFields["settings.name.field"]
        field.tap()
        field.clearAndType("UI Test")
        goBack()
        XCTAssertTrue(waitForLabel(element("settings.name"), containing: "UI Test"))

        // Alerts and haptics.
        tapRow("settings.alerts")
        setSwitch(app.switches["automations.wristAlerts"], on: true)
        goBack()
        tapRow("settings.haptics")
        setSwitch(app.switches["automations.breathingHaptic"], on: false)
        setSwitch(app.switches["automations.liftRestHaptic"], on: false)
        goBack()

        // Double-tap: the row says what the gesture does.
        tapRow("settings.shortcuts")
        let picker = app.descendants(matching: .any)["automations.doubleTapAction"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let markMoment = app.buttons["Mark a moment"]
        XCTAssertTrue(markMoment.waitForExistence(timeout: 5))
        markMoment.tap()
        goBack()
        XCTAssertTrue(waitForLabel(element("settings.shortcuts"), containing: "Mark a moment"))

        // Sana off takes the tab away.
        let sana = element("settings.sana")
        scrollTo(sana)
        setSwitch(sana, on: false)
        closeSettings()
        XCTAssertFalse(app.tabBars.buttons["Sana"].exists, "Sana is off")

        // Relaunch.
        app.terminate()
        app.launch()
        XCTAssertFalse(app.tabBars.buttons["Sana"].waitForExistence(timeout: 3), "Sana stays off")
        openSettings()
        XCTAssertTrue(element("settings.units").label.contains("Imperial"))
        XCTAssertTrue(element("settings.appearance").label.contains("Dark"))
        XCTAssertTrue(waitForLabel(element("settings.placement"), containing: "Bicep"))
        XCTAssertTrue(element("settings.name").label.contains("UI Test"))
        XCTAssertTrue(element("settings.shortcuts").label.contains("Mark a moment"))
        XCTAssertEqual(switchValue(element("settings.sana")), false)
        tapRow("settings.alerts")
        XCTAssertEqual(switchValue(app.switches["automations.wristAlerts"]), true)
        goBack()
        tapRow("settings.haptics")
        XCTAssertEqual(switchValue(app.switches["automations.breathingHaptic"]), false)
        XCTAssertEqual(switchValue(app.switches["automations.liftRestHaptic"]), false)
        goBack()

        // Put everything back so the next run starts from the defaults.
        tapRow("settings.units"); app.buttons["Metric"].tap(); goBack()
        tapRow("settings.appearance"); app.buttons["System"].tap(); goBack()
        tapRow("settings.placement"); app.buttons["Wrist"].tap(); goBack()
        tapRow("settings.name"); app.textFields["settings.name.field"].tap()
        app.textFields["settings.name.field"].clearAndType(""); goBack()
        tapRow("settings.alerts"); setSwitch(app.switches["automations.wristAlerts"], on: false); goBack()
        tapRow("settings.haptics")
        setSwitch(app.switches["automations.breathingHaptic"], on: true)
        setSwitch(app.switches["automations.liftRestHaptic"], on: true)
        goBack()
        tapRow("settings.shortcuts")
        app.descendants(matching: .any)["automations.doubleTapAction"].tap()
        app.buttons["Nothing"].tap()
        goBack()
        let sanaAgain = element("settings.sana")
        scrollTo(sanaAgain)
        setSwitch(sanaAgain, on: true)
        closeSettings()
        XCTAssertTrue(app.tabBars.buttons["Sana"].waitForExistence(timeout: 5))
    }

    // MARK: - Account-backed settings (local Supabase stack)

    /// Phase 1: create an account, turn sync on, and edit the profile and the account-wide preferences in
    /// Settings. The runner script then checks the `profiles` and `user_settings` rows and uninstalls the app.
    func testAccountPhase1SaveProfileToSupabase() throws {
        let account = try E2EAccount.fromEnvironment()
        app.launch()
        openSettings()
        tapRow("settings.account")
        signOutIfSignedIn()
        signUp(account)
        enableSync()
        goBack()

        tapRow("settings.name")
        let field = app.textFields["settings.name.field"]
        field.tap()
        field.clearAndType(account.displayName)
        goBack()
        tapRow("settings.sex")
        app.buttons["Female"].tap()
        goBack()
        tapRow("settings.height")
        let height = app.steppers.firstMatch
        XCTAssertTrue(height.waitForExistence(timeout: 5))
        for _ in 0..<4 { height.buttons.element(boundBy: 1).tap() }   // +4 cm
        goBack()
        XCTAssertTrue(waitForLabel(element("settings.height"), containing: "182 cm"),
                      "178 cm default + 4: \(element("settings.height").label)")

        // Preferences that follow the account.
        tapRow("settings.units")
        app.buttons["Imperial"].tap()
        goBack()
        tapRow("settings.alerts")
        setSwitch(app.switches["automations.battery"], on: false)
        goBack()
        tapRow("settings.haptics")
        setSwitch(app.switches["automations.liftRestHaptic"], on: false)
        goBack()
        // The uploads are debounced by two seconds; give them time before the app is torn down.
        sleep(6)
    }

    /// Phase 2, after a fresh install: sign in and check Settings shows what phase 1 saved, profile and
    /// preferences both.
    func testAccountPhase2RestoreProfileFromSupabase() throws {
        let account = try E2EAccount.fromEnvironment()
        app.launch()
        openSettings()
        XCTAssertTrue(element("settings.name").label.contains("Add"), "a fresh install starts empty")
        tapRow("settings.account")
        // An uninstall clears the app's preferences but not the Keychain, on the simulator as on an iPhone, so
        // the session can still be there. A new phone signs in instead; either way the values come back.
        let signedIn = app.staticTexts["nara.account.email"]
        let signInForm = app.segmentedControls["nara.auth.mode"]
        let deadline = Date().addingTimeInterval(20)
        while !signedIn.exists && !signInForm.exists && Date() < deadline { usleep(250_000) }
        if !signedIn.exists { signIn(account) }
        enableSync()
        goBack()
        XCTAssertTrue(waitForLabel(element("settings.name"), containing: account.displayName, timeout: 30),
                      "restored name: \(element("settings.name").label)")
        XCTAssertTrue(element("settings.sex").label.contains("Female"))
        XCTAssertTrue(waitForLabel(element("settings.units"), containing: "Imperial", timeout: 30),
                      "restored units: \(element("settings.units").label)")
        XCTAssertTrue(element("settings.height").label.contains("6′ 0″"), "182 cm in feet and inches")
        tapRow("settings.alerts")
        XCTAssertEqual(switchValue(app.switches["automations.battery"]), false)
        goBack()
        tapRow("settings.haptics")
        XCTAssertEqual(switchValue(app.switches["automations.liftRestHaptic"]), false)
        goBack()
    }

    // MARK: - Account flows

    private func signUp(_ account: E2EAccount) {
        let email = app.textFields["nara.auth.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap(); email.typeText(account.email)
        enterPassword(account.password)
        let since = Date().addingTimeInterval(-2)
        app.buttons["nara.auth.submit"].tap()
        let code = app.textFields["nara.auth.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 20), "the account asked for the emailed code")
        type(account.code(since: since), into: code)
        app.buttons["nara.auth.verify"].tap()
        let start = app.buttons["nara.setup.continue"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        XCTAssertTrue(app.staticTexts["nara.account.email"].waitForExistence(timeout: 20))
    }

    /// The Keychain outlives an uninstall, so the app can come back signed in to an earlier run's account.
    private func signOutIfSignedIn() {
        let signedIn = app.staticTexts["nara.account.email"]
        let form = app.textFields["nara.auth.email"]
        let deadline = Date().addingTimeInterval(20)
        while !signedIn.exists && !form.exists && Date() < deadline { usleep(250_000) }
        guard signedIn.exists else { return }
        let signOut = app.buttons["nara.account.signOut"]
        scrollTo(signOut)
        signOut.tap()
        let confirm = app.sheets["Sign out of Nara?"].buttons["Sign out"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "sign-out asks first")
        confirm.tap()
        XCTAssertTrue(form.waitForExistence(timeout: 20), "signed out")
    }

    private func signIn(_ account: E2EAccount) {
        let mode = app.segmentedControls["nara.auth.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        mode.buttons["Sign in"].tap()
        let email = app.textFields["nara.auth.email"]
        email.tap(); email.typeText(account.email)
        enterPassword(account.password)
        app.buttons["nara.auth.submit"].tap()
        XCTAssertTrue(app.staticTexts["nara.account.email"].waitForExistence(timeout: 20))
        declineSavePassword()
    }

    /// iOS offers to save the password once an account form is submitted; its sheet covers the page.
    private func declineSavePassword(timeout: TimeInterval = 5) {
        let notNow = app.sheets["Save Password?"].buttons["Not Now"]
        if notNow.waitForExistence(timeout: timeout) { notNow.tap() }
    }

    /// Types into a field once it has the keyboard. The Save Password sheet can arrive at any moment and take
    /// the tap, so it is answered and the tap tried again.
    private func type(_ text: String, into field: XCUIElement) {
        for _ in 0..<3 {
            declineSavePassword(timeout: 2)
            field.tap()
            if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true {
                field.typeText(text)
                return
            }
            sleep(1)
        }
        XCTFail("\(field.identifier) never took the keyboard")
    }

    /// The new-password field brings up iOS's "Use Strong Password?" panel in place of the keyboard, which eats
    /// typed text. Pasting from the field's own edit menu is a person's action, so it works with the panel up
    /// and without a paste prompt.
    private func enterPassword(_ text: String) {
        let field = app.secureTextFields["nara.auth.password"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        UIPasteboard.general.string = text
        field.tap()
        field.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the field offers Paste")
        paste.tap()
        XCTAssertEqual((field.value as? String)?.count, text.count, "the whole password went in")
    }

    private func enableSync() {
        let sync = app.switches["nara.account.sync"]
        XCTAssertTrue(sync.waitForExistence(timeout: 10))
        setSwitch(sync, on: true)
    }

    // MARK: - Helpers

    private func openSettings() {
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 20), "the Today gear")
        gear.tap()
        XCTAssertTrue(element("settings.account").waitForExistence(timeout: 10), "Settings opened")
    }

    private func closeSettings() {
        app.navigationBars.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 10))
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func tapRow(_ id: String) {
        let row = element(id)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(id) is in Settings")
        scrollTo(row)
        row.tap()
    }

    private func goBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        // Only the Settings root carries Done.
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout: 5), "back on Settings")
    }

    private func scrollTo(_ target: XCUIElement) {
        var tries = 0
        while !target.isHittable && tries < 8 {
            app.swipeUp(velocity: .slow)
            tries += 1
        }
        tries = 0
        while !target.isHittable && tries < 8 {
            app.swipeDown(velocity: .slow)
            tries += 1
        }
    }

    private func switchValue(_ toggle: XCUIElement) -> Bool? {
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        scrollTo(toggle)
        switch toggle.value as? String {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }

    private func setSwitch(_ toggle: XCUIElement, on: Bool) {
        guard switchValue(toggle) != on else { return }
        let expected = NSPredicate(format: "value == %@", on ? "1" : "0")
        // A SwiftUI toggle row is as wide as the screen; the switch itself sits at the trailing edge. A tap that
        // lands while the page is still sliding in is lost, so it gets one more try.
        for _ in 0..<2 {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let flipped = XCTNSPredicateExpectation(predicate: expected, object: toggle)
            if XCTWaiter().wait(for: [flipped], timeout: 3) == .completed { return }
        }
        XCTFail("\(toggle.identifier) did not turn \(on ? "on" : "off")")
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    private func assertNoInternalNames(on page: String) {
        for word in ["NOOP", "Bonded", "R22", "Puffin", "Protocol"] {
            let hits = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", word))
            XCTAssertEqual(hits.count, 0, "\(page) shows \"\(word)\": \(hits.allElementsBoundByIndex.map(\.label))")
        }
    }
}

/// A throwaway account on the local stack. The runner script passes the address and password; the emailed code
/// is read from the stack's mail sink.
private struct E2EAccount {
    let gateway: URL
    let email: String
    let password: String
    let displayName: String

    static func fromEnvironment() throws -> E2EAccount {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["NARA_E2E_GATEWAY"], let gateway = URL(string: raw),
              let email = env["NARA_UI_EMAIL"], let password = env["NARA_UI_PASSWORD"] else {
            throw XCTSkip("No local stack. Run supabase/tests/e2e/run_ios_settings_ui.sh.")
        }
        return E2EAccount(gateway: gateway, email: email, password: password,
                          displayName: env["NARA_UI_NAME"] ?? "Settings UI")
    }

    func code(since: Date) -> String {
        var components = URLComponents(url: gateway.appendingPathComponent("__e2e/mail"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "to", value: email),
                                 URLQueryItem(name: "since", value: String(Int(since.timeIntervalSince1970 * 1000)))]
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let data = try? Data(contentsOf: components.url!),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let messages = object["messages"] as? [[String: Any]],
               let code = messages.last?["code"] as? String {
                return code
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("no emailed code for \(email)")
        return ""
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        if let current = value as? String, !current.isEmpty, current != placeholderValue {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        if !text.isEmpty { typeText(text) }
    }
}
