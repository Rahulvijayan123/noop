import XCTest
@testable import Strand

/// A hosted-compute build has no offline mode to fall back to, so cloud sync is not a preference there:
/// it is on as soon as the build is configured, and nothing stored on the phone can turn it off or point
/// it somewhere else. In every other build a signed-in account always syncs, and a phone nobody is signed
/// into follows the flag that signing in sets.
final class CloudHostedBuildTests: XCTestCase {

    private let enabledKey = "noop.cloud.enabled.override"
    private let endpointKey = "noop.cloud.endpoint.override"
    private let activeOwnerKey = "noop.cloud.account.active"
    private let owner = "c0ffee00-0000-4000-8000-00000000c0de"
    private var policyKey: String { "noop.cloud.syncPolicy.v1.\(owner)" }
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in [enabledKey, endpointKey, activeOwnerKey, policyKey] {
            saved[key] = defaults.object(forKey: key)
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        CloudPushSettings.bundleStringOverride = nil
        let defaults = UserDefaults.standard
        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func configureBuild(hosted: Bool, configured: Bool = true) {
        CloudPushSettings.bundleStringOverride = { key in
            switch key {
            case CloudPushSettings.endpointInfoKey:
                return configured ? "https://example.supabase.co/functions/v1/push" : ""
            case CloudPushSettings.publishableKeyInfoKey:
                return configured ? "sb_publishable_abcdef0123456789" : ""
            case CloudPushSettings.finalHostedComputeInfoKey:
                return hosted ? "YES" : "NO"
            default:
                return nil
            }
        }
    }

    func testAHostedBuildIsOnWithoutAnyChoice() {
        configureBuild(hosted: true)
        XCTAssertTrue(CloudPushSettings.isEnabled, "a fresh hosted install starts synced, with nothing to turn on")
    }

    func testAStoredOptOutDoesNotTurnAHostedBuildOff() {
        configureBuild(hosted: true)
        UserDefaults.standard.set(false, forKey: enabledKey)
        XCTAssertTrue(CloudPushSettings.isEnabled, "a preference left by an older opt-in build is ignored")
    }

    func testAHostedBuildCannotBeSwitchedOff() {
        configureBuild(hosted: true)
        CloudPushSettings.setEnabled(false)
        XCTAssertTrue(CloudPushSettings.isEnabled)
        XCTAssertNil(UserDefaults.standard.object(forKey: enabledKey), "the refusal leaves no override behind")
    }

    func testAHostedBuildIgnoresAnEndpointOverride() {
        configureBuild(hosted: true)
        UserDefaults.standard.set("https://elsewhere.example/functions/v1/push", forKey: endpointKey)
        XCTAssertEqual(CloudPushSettings.receiverURL?.host, "example.supabase.co",
                       "uploads go to the project the build was cut for, whatever is stored on the phone")
        XCTAssertEqual(CloudPushSettings.canonicalProjectURL, "https://example.supabase.co")
    }

    func testAHostedBuildWithoutACloudConfigurationStaysOff() {
        configureBuild(hosted: true, configured: false)
        XCTAssertFalse(CloudPushSettings.isConfigured)
        XCTAssertFalse(CloudPushSettings.isEnabled, "with no receiver there is nothing to upload to")
    }

    func testOtherBuildsFollowTheStoredFlagWhileSignedOut() {
        configureBuild(hosted: false)
        XCTAssertFalse(CloudPushSettings.isEnabled, "carrying a receiver is not consent to upload")

        CloudPushSettings.setEnabled(true)
        XCTAssertTrue(CloudPushSettings.isEnabled)
        CloudPushSettings.setEnabled(false)
        XCTAssertFalse(CloudPushSettings.isEnabled)
    }

    func testASignedInAccountIsSyncedAndCannotBeSwitchedOff() {
        configureBuild(hosted: false)
        UserDefaults.standard.set(false, forKey: enabledKey)   // an older build's "off"
        UserDefaults.standard.set(owner, forKey: activeOwnerKey)

        XCTAssertTrue(CloudPushSettings.signedInSyncIsMandatory, "required until the server says otherwise")
        XCTAssertTrue(CloudPushSettings.isEnabled, "signed in means synced, whatever an older build stored")
        XCTAssertFalse(CloudPushSettings.isUserSwitchable, "so no screen offers a switch")
        XCTAssertFalse(CloudPushSettings.setEnabled(false), "switching off is refused while signed in")
        XCTAssertTrue(CloudPushSettings.isEnabled)

        // Signing out is what stops it.
        UserDefaults.standard.removeObject(forKey: activeOwnerKey)
        XCTAssertFalse(CloudPushSettings.isEnabled)
        XCTAssertTrue(CloudPushSettings.isUserSwitchable)
    }

    func testASignedInAccountInAnUnconfiguredBuildStaysOff() {
        configureBuild(hosted: false, configured: false)
        UserDefaults.standard.set(owner, forKey: activeOwnerKey)
        XCTAssertFalse(CloudPushSettings.isEnabled)
    }

    func testARelaxedPolicyBringsTheOptInBackForThatAccountOnly() {
        configureBuild(hosted: false)
        UserDefaults.standard.set(owner, forKey: activeOwnerKey)
        CloudSyncPolicyStore.shared.record(CloudSyncPolicy(required: false, staleAfterHours: 24), forOwner: owner)

        XCTAssertFalse(CloudPushSettings.signedInSyncIsMandatory)
        XCTAssertFalse(CloudPushSettings.isEnabled, "a relaxed account is opt-in again")
        XCTAssertTrue(CloudPushSettings.isUserSwitchable)
        XCTAssertTrue(CloudPushSettings.setEnabled(true))
        XCTAssertTrue(CloudPushSettings.isEnabled)
        XCTAssertTrue(CloudPushSettings.setEnabled(false))
        XCTAssertFalse(CloudPushSettings.isEnabled)
        XCTAssertTrue(CloudPushSettings.syncRequired(forOwner: "d0d0d0d0-0000-4000-8000-00000000d0d0"),
                      "another account's unknown policy is still required")
    }

    func testTheSyncPolicyIsReadFromEveryReplyThatCarriesIt() throws {
        XCTAssertEqual(CloudSyncPolicy.parse(["required": false, "staleAfterHours": 48]),
                       CloudSyncPolicy(required: false, staleAfterHours: 48))
        XCTAssertEqual(CloudSyncPolicy.parse(["staleAfterHours": 0]), .assumed,
                       "a missing flag is required, and an impossible window falls back")
        XCTAssertNil(CloudSyncPolicy.parse("required"))
        let body = Data(#"{"type":"capabilities","syncPolicy":{"required":true,"staleAfterHours":12}}"#.utf8)
        XCTAssertEqual(CloudSyncPolicy.parse(replyBody: body), CloudSyncPolicy(required: true, staleAfterHours: 12))

        let status = Data(#"{"ok":true,"configured":true,"syncPolicy":{"required":true,"staleAfterHours":24},"sync":{"required":true,"lastUploadAt":"2026-10-07T00:05:00.123Z","stale":true,"staleAfterHours":24}}"#.utf8)
        let parsed = try XCTUnwrap(CoachAPI.syncStatus(fromStatusBody: status))
        XCTAssertEqual(parsed.policy, .assumed)
        XCTAssertEqual(parsed.health?.stale, true)
        XCTAssertEqual(parsed.health?.lastUploadAt?.timeIntervalSince1970 ?? 0, 1_791_331_500.123, accuracy: 0.01)
        XCTAssertNil(CoachAPI.syncStatus(fromStatusBody: Data(#"{"ok":true,"configured":true}"#.utf8)),
                     "an older server sends neither")
        let never = Data(#"{"sync":{"required":true,"lastUploadAt":null,"stale":true}}"#.utf8)
        XCTAssertEqual(CoachAPI.syncStatus(fromStatusBody: never)?.health,
                       CloudSyncHealth(required: true, lastUploadAt: nil, stale: true))
    }

    func testOtherBuildsStillHonourADeveloperEndpointOverride() {
        configureBuild(hosted: false)
        UserDefaults.standard.set("https://dev.example/functions/v1/push", forKey: endpointKey)
        XCTAssertEqual(CloudPushSettings.receiverURL?.host, "dev.example")
    }
}
