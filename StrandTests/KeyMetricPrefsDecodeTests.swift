import XCTest
@testable import Strand

/// #1518: `decodeEnabled` trimmed the whole string but not each token, so a single space cost the user a
/// tile they had enabled.
///
/// `KeyMetric(rawValue:)` matches exactly, so `"charge, effort"` decoded to `[charge]` — the space made
/// `" effort"` unparseable and the loop dropped it silently. Kotlin's twin already trimmed per token
/// (`KeyMetric.fromRaw(token.trim())`), as does `DashboardCards.decodeEnabled`, so Swift was the only
/// decoder of the three that could lose an enabled tile.
///
/// Latent rather than live: `encode` joins rawValues with no spaces and this key is not carried in
/// `.noopbak`, so nothing in the app writes a spaced value today. These pin the contract anyway, because
/// the cost of the assumption is silent and the fix is a single call.
final class KeyMetricPrefsDecodeTests: XCTestCase {

    /// The regression: spaced tokens are real selections and must survive.
    func testSpacedTokensStillDecode() {
        XCTAssertEqual(KeyMetricPrefs.decodeEnabled("charge, effort"),
                       KeyMetricPrefs.decodeEnabled("charge,effort"))
    }

    /// Order is the user's saved order and must be preserved through the trim.
    func testOrderSurvivesTrimming() {
        let spaced = KeyMetricPrefs.decodeEnabled("effort , charge")
        let tight = KeyMetricPrefs.decodeEnabled("effort,charge")
        XCTAssertEqual(spaced, tight)
        XCTAssertEqual(spaced.first, tight.first)
    }

    /// De-duplication still keys on the metric, not the raw text, so a spaced repeat is still a repeat.
    func testSpacedDuplicateIsStillDeduped() {
        XCTAssertEqual(KeyMetricPrefs.decodeEnabled("charge, charge").count, 1)
    }

    /// An unknown token is still dropped — trimming must not turn junk into a match.
    func testUnknownTokensAreStillDropped() {
        XCTAssertEqual(KeyMetricPrefs.decodeEnabled("charge, notAMetric"),
                       KeyMetricPrefs.decodeEnabled("charge"))
    }

    /// An empty or whitespace-only string still yields the full default order (a fresh install).
    func testBlankStringStillYieldsTheDefaultOrder() {
        XCTAssertEqual(KeyMetricPrefs.decodeEnabled("   "), KeyMetric.defaultOrder)
        XCTAssertEqual(KeyMetricPrefs.decodeEnabled(""), KeyMetric.defaultOrder)
    }

    /// `.skinTemp` is a persisted case whose raw token must stay byte-identical to Kotlin's
    /// `KeyMetric.SKIN_TEMP.raw`. It began outside `defaultOrder`, which also kept it out of the layout
    /// editor (the editor's universe IS `defaultOrder`), so nobody could ever switch it on. It is now a
    /// default tile, sitting right after Blood Oxygen, and a fresh install shows it.
    func testSkinTempRawTokenRoundTripsAndIsADefaultTile() throws {
        XCTAssertEqual(KeyMetric(rawValue: "skinTemp"), .skinTemp)
        XCTAssertEqual(KeyMetric.skinTemp.rawValue, "skinTemp")
        XCTAssertTrue(KeyMetric.defaultOrder.contains(.skinTemp))
        XCTAssertTrue(KeyMetricPrefs.decodeEnabled("").contains(.skinTemp))
        let blood = try XCTUnwrap(KeyMetric.defaultOrder.firstIndex(of: .bloodOxygen))
        XCTAssertEqual(KeyMetric.defaultOrder.firstIndex(of: .skinTemp), blood + 1)
        XCTAssertEqual(Set(KeyMetric.defaultOrder), Set(KeyMetric.allCases),
                       "the editor offers only defaultOrder, so a case outside it can never be switched on")
        XCTAssertEqual(KeyMetric.defaultOrder.count, KeyMetric.allCases.count, "no tile listed twice")
    }

    // MARK: - one-time migration of a layout saved before Skin Temp was a default

    private func isolatedDefaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "KeyMetricPrefsDecodeTests.\(name)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testSavedLayoutGainsBloodOxygenAndSkinTempAtTheEnd() {
        XCTAssertEqual(KeyMetricPrefs.layoutAddingBloodOxygenAndSkinTemp(savedLayout: "effort,charge,steps"),
                       "effort,charge,steps,bloodOxygen,skinTemp")
    }

    func testSavedLayoutOnlyGainsWhatIsMissing() {
        XCTAssertEqual(KeyMetricPrefs.layoutAddingBloodOxygenAndSkinTemp(savedLayout: "charge,skinTemp,steps"),
                       "charge,skinTemp,steps,bloodOxygen")
        XCTAssertEqual(KeyMetricPrefs.layoutAddingBloodOxygenAndSkinTemp(savedLayout: "bloodOxygen,charge"),
                       "bloodOxygen,charge,skinTemp")
    }

    func testLayoutAlreadyShowingBothOrNotSavedIsLeftAlone() {
        XCTAssertNil(KeyMetricPrefs.layoutAddingBloodOxygenAndSkinTemp(savedLayout: "skinTemp,bloodOxygen,charge"))
        XCTAssertNil(KeyMetricPrefs.layoutAddingBloodOxygenAndSkinTemp(savedLayout: ""),
                     "a blank layout already decodes to defaultOrder, which has both")
        XCTAssertNil(KeyMetricPrefs.layoutAddingBloodOxygenAndSkinTemp(savedLayout: "   "))
    }

    func testMigrationRewritesTheSavedLayoutOnceAndThenLeavesTheUsersChoiceAlone() throws {
        let defaults = try isolatedDefaults()
        defaults.set("charge,effort", forKey: KeyMetricPrefs.layoutKey)
        XCTAssertTrue(KeyMetricPrefs.migrateSkinTempAndBloodOxygenShown(defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: KeyMetricPrefs.layoutKey), "charge,effort,bloodOxygen,skinTemp")

        // The user then hides Skin Temp in the editor. A second launch must not put it back.
        defaults.set("charge,effort,bloodOxygen", forKey: KeyMetricPrefs.layoutKey)
        XCTAssertFalse(KeyMetricPrefs.migrateSkinTempAndBloodOxygenShown(defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: KeyMetricPrefs.layoutKey), "charge,effort,bloodOxygen")
    }

    func testMigrationOnAFreshInstallWritesNoLayoutButStillStampsTheFlag() throws {
        let defaults = try isolatedDefaults()
        XCTAssertFalse(KeyMetricPrefs.migrateSkinTempAndBloodOxygenShown(defaults: defaults))
        XCTAssertNil(defaults.string(forKey: KeyMetricPrefs.layoutKey), "unset stays unset so the default order applies")
        XCTAssertTrue(defaults.bool(forKey: KeyMetricPrefs.skinTempBloodOxygenMigrationKey))
        XCTAssertTrue(KeyMetricPrefs.decodeEnabled(defaults.string(forKey: KeyMetricPrefs.layoutKey) ?? "")
            .contains(.skinTemp))
    }
}
