import XCTest
import StrandAnalytics
@testable import Strand

/// The phone's copy of the wearer's personal-profile fit: stored per account and strap, and only an adopted
/// fit ever reaches the decoder.
final class ActivityPersonalProfileStoreTests: XCTestCase {

    private final class ScopeBox: @unchecked Sendable {
        var scope: ActivityEncoderWindowStore.Scope?
        init(_ scope: ActivityEncoderWindowStore.Scope?) { self.scope = scope }
    }

    private let alice = ActivityEncoderWindowStore.Scope(ownerId: "OWNER-A", deviceId: "whoop-1")
    private let bob = ActivityEncoderWindowStore.Scope(ownerId: "owner-b", deviceId: "whoop-1")

    private func makeStore(_ box: ScopeBox) -> (ActivityPersonalProfileStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("personal-profile-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (ActivityPersonalProfileStore(directory: dir, scope: { box.scope }), dir)
    }

    private func adopted() -> ActivityPersonalFitResult {
        let profile = ActivityPersonalProfile(
            fittedAt: 1_791_158_400, sessionIds: ["s1", "s2"],
            modes: ["upright": ActivityPersonalModeAdjustment(seconds: 120, hrRel: 0.2)])
        return ActivityPersonalFitResult(status: .adopted, fittedAt: 1_791_158_400, runs: 2, runsNeeded: 2,
                                         profile: profile)
    }

    func testAnAdoptedFitRoundTripsAndReachesTheDecoder() throws {
        let box = ScopeBox(alice)
        let (store, dir) = makeStore(box)
        XCTAssertNil(store.record())
        XCTAssertNil(store.adoptedProfile)

        let record = ActivityPersonalProfileStore.Record(fingerprint: "fp1", result: adopted())
        XCTAssertTrue(store.save(record, scope: alice))
        XCTAssertEqual(store.record(), record)
        XCTAssertEqual(store.adoptedProfile, record.result.profile)

        let reopened = ActivityPersonalProfileStore(directory: dir, scope: { box.scope })
        XCTAssertEqual(reopened.record(), record, "survives a relaunch")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("owner-a/whoop-1/personal-profile.json").path))
    }

    func testARefusedFitNeverReachesTheDecoder() {
        let (store, _) = makeStore(ScopeBox(alice))
        let refused = ActivityPersonalFitResult(status: .notBetter, fittedAt: 1, runs: 3, runsNeeded: 2)
        XCTAssertTrue(store.save(.init(fingerprint: "fp", result: refused), scope: alice))
        XCTAssertEqual(store.record()?.result.status, .notBetter)
        XCTAssertNil(store.adoptedProfile)
    }

    func testAnotherAccountNeverSeesTheProfile() {
        let box = ScopeBox(alice)
        let (store, _) = makeStore(box)
        XCTAssertTrue(store.save(.init(fingerprint: "fp", result: adopted()), scope: alice))
        box.scope = bob
        XCTAssertNil(store.record())
        XCTAssertNil(store.adoptedProfile)
        box.scope = nil
        XCTAssertNil(store.adoptedProfile, "no account, no profile")
        box.scope = alice
        XCTAssertNotNil(store.adoptedProfile)
    }

    func testAFitMadeUnderAnotherScopeIsNotSaved() {
        let box = ScopeBox(bob)
        let (store, _) = makeStore(box)
        XCTAssertFalse(store.save(.init(fingerprint: "fp", result: adopted()), scope: alice))
        box.scope = alice
        XCTAssertNil(store.record())
    }

    // MARK: Refit inputs

    private func label(session: String?, start: Int, end: Int, source: ActivityGroundTruthSource = .guided,
                       updatedAt: Date = Date(timeIntervalSince1970: 1_791_158_400)) -> ActivityGroundTruthLabel {
        ActivityGroundTruthLabel(labelKey: "guided:\(session ?? "x"):\(start)", source: source, sessionId: session,
                                 startTs: start, endTs: end, posture: PostureClass.seatedLikely.rawValue,
                                 createdAt: updatedAt, updatedAt: updatedAt)
    }

    func testGuidedLabelsAreGroupedIntoRunsWithALeadIn() {
        let sessions = Repository.calibrationSessions([
            label(session: "b", start: 5_000, end: 5_040),
            label(session: "a", start: 1_000, end: 1_040),
            label(session: "a", start: 1_100, end: 1_160),
            label(session: nil, start: 2_000, end: 2_040),
            label(session: "c", start: 3_000, end: 3_040, source: .stretchFeedback),
        ])
        XCTAssertEqual(sessions.map(\.id), ["a", "b"])
        XCTAssertEqual(sessions[0].labels.count, 2)
        XCTAssertEqual(sessions[0].from, 1_000 - Repository.personalProfileLeadInS)
        XCTAssertEqual(sessions[0].to, 1_165)
    }

    func testTheFingerprintFollowsLabelEditsAndTheBaseConfig() {
        let original = label(session: "a", start: 1_000, end: 1_040)
        var edited = original
        edited.updatedAt = original.updatedAt.addingTimeInterval(60)
        let config = ActivityDecoderConfig()
        let fp = Repository.personalProfileFingerprint(Repository.calibrationSessions([original]), config: config)
        XCTAssertEqual(fp, Repository.personalProfileFingerprint(Repository.calibrationSessions([original]), config: config))
        XCTAssertNotEqual(fp, Repository.personalProfileFingerprint(Repository.calibrationSessions([edited]), config: config))
        var other = config
        other.restingHeartRate = 52
        XCTAssertNotEqual(fp, Repository.personalProfileFingerprint(Repository.calibrationSessions([original]), config: other))
    }
}
