import XCTest
@testable import Strand

/// A hosted-compute build has no offline mode to fall back to, so cloud sync is not a preference there:
/// it is on as soon as the build is configured, and nothing stored on the phone can turn it off or point
/// it somewhere else. Every other build keeps cloud as an opt-in.
final class CloudHostedBuildTests: XCTestCase {

    private let enabledKey = "noop.cloud.enabled.override"
    private let endpointKey = "noop.cloud.endpoint.override"
    private var savedEnabled: Any?
    private var savedEndpoint: Any?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedEnabled = defaults.object(forKey: enabledKey)
        savedEndpoint = defaults.object(forKey: endpointKey)
        defaults.removeObject(forKey: enabledKey)
        defaults.removeObject(forKey: endpointKey)
    }

    override func tearDown() {
        CloudPushSettings.bundleStringOverride = nil
        let defaults = UserDefaults.standard
        for (key, value) in [(enabledKey, savedEnabled), (endpointKey, savedEndpoint)] {
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
        XCTAssertFalse(CloudPushSettings.isUserSwitchable, "so no screen offers a switch")
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
        XCTAssertFalse(CloudPushSettings.isUserSwitchable)
    }

    func testOtherBuildsKeepCloudAsAnOptIn() {
        configureBuild(hosted: false)
        XCTAssertFalse(CloudPushSettings.isEnabled, "carrying a receiver is not consent to upload")
        XCTAssertTrue(CloudPushSettings.isUserSwitchable)

        CloudPushSettings.setEnabled(true)
        XCTAssertTrue(CloudPushSettings.isEnabled)
        CloudPushSettings.setEnabled(false)
        XCTAssertFalse(CloudPushSettings.isEnabled)
    }

    func testOtherBuildsStillHonourADeveloperEndpointOverride() {
        configureBuild(hosted: false)
        UserDefaults.standard.set("https://dev.example/functions/v1/push", forKey: endpointKey)
        XCTAssertEqual(CloudPushSettings.receiverURL?.host, "dev.example")
    }
}
