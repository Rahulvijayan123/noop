import XCTest
import NoopPush
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

/// V17 against real services (supabase/tests/e2e/stack.sh): sign-up through Supabase Auth, upload through `push`,
/// the real worker scores the day AND runs the context lane, the app reads the stored context through the real
/// `scores` route with its own repository and builds the card model; then an exposure recorded on the phone is
/// uploaded with the app's sync, corrected, and both revisions show up in the context the worker recomputes.
/// Nothing between the app's code and the database is faked. Skips without the `NARA_E2E_*` environment.
@MainActor
final class NaraContextEndToEndTests: XCTestCase {
    typealias PC = PhysiologyContext

    private var env: E2EEnvironment!
    private var mailbox: E2EMailbox!
    private var server: E2EServer!
    private var phones: [E2EPhone] = []
    private var cloudEnabledBefore: Any?
    private static let enabledOverrideKey = "noop.cloud.enabled.override"
    private let captureSeconds = 1800

    override func setUp() async throws {
        env = try E2EEnvironment.load()
        mailbox = E2EMailbox(env: env)
        server = E2EServer(env: env)
        let endpoint = env.pushEndpoint.absoluteString
        let key = env.publishableKey
        CloudPushSettings.bundleStringOverride = { name in
            switch name {
            case CloudPushSettings.endpointInfoKey: return endpoint
            case CloudPushSettings.publishableKeyInfoKey: return key
            default: return nil
            }
        }
        cloudEnabledBefore = UserDefaults.standard.object(forKey: Self.enabledOverrideKey)
    }

    override func tearDown() async throws {
        for phone in phones { await phone.tearDown() }
        phones = []
        CloudPushSettings.bundleStringOverride = nil
        if let cloudEnabledBefore {
            UserDefaults.standard.set(cloudEnabledBefore, forKey: Self.enabledOverrideKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.enabledOverrideKey)
        }
    }

    private func utcDay(_ seconds: Int) -> String {
        PC.localTime(at: seconds, timezoneId: "UTC").localDay
    }

    /// Poll the stored context through the real route until `ready` accepts it.
    private func context(_ repo: PhysiologyContextRepository, day: String, deviceIds: [String],
                         metric: PC.MetricKind?, timeout: TimeInterval = 240,
                         ready: @escaping (PhysiologyContextDay) -> Bool) async throws -> PhysiologyContextDay {
        var last: PhysiologyContextRead<PhysiologyContextDay>?
        var lastError: Error?
        let ok = await e2eWait(timeout: timeout, interval: 3) {
            do {
                let read = try await repo.dayContext(day: day, deviceIds: deviceIds, metric: metric)
                last = read
                if case .loaded(let value) = read { return ready(value) }
                return false
            } catch {
                lastError = error
                return false
            }
        }
        guard ok, case .loaded(let value)? = last else {
            throw E2EError("no stored context within \(Int(timeout)) s (last \(String(describing: last)), error \(String(describing: lastError)))")
        }
        return value
    }

    func testAScoredDayGetsStoredContextThatAnExposureCorrectionRevises() async throws {
        let phone = try E2EPhone(env: env, label: "ctx", restoring: nil, withoutAuthSession: false)
        phones.append(phone)
        let account = try await phone.signUp(mailbox: mailbox)
        let identity = try XCTUnwrap(phone.store.identity(forOwner: account.userId))

        // Upload half an hour of strap data and confirm the strap, exactly as the scoring scenario does.
        let end = Int(Date().timeIntervalSince1970) - 120
        let provisional = "e2e-ctx-strap"
        try await phone.capture(E2EPhone.liveRecords(bpm: 60, rrPattern: [1000, 1040], seconds: captureSeconds,
                                                     endingAt: end, deviceId: provisional))
        let paired = await phone.controller.confirmWearableIfNeeded(provisionalDeviceId: provisional,
                                                                    serial: "E2E-CTX-0001")
        XCTAssertTrue(paired)
        // No wait on the dense series here: on this stack the scorer can complete a day without an HRV series
        // (a pre-existing HR-device aliasing issue makes it read 0 HR rows; see validation.md). The context lane
        // runs off scoring completions, so waiting for the stored context is the honest end-to-end condition.

        // The worker's context lane publishes the scored day; read it the way the app does.
        let repoDir = FileManager.default.temporaryDirectory.appendingPathComponent("nara-e2e-ctx-\(UUID().uuidString.prefix(8))")
        let repo = PhysiologyContextRepository(session: .shared, endpoint: env.scoresEndpoint, directory: repoDir,
                                               identity: { identity })
        let day = utcDay(end)
        let devices = [provisional, "whoop-E2E-CTX-0001"]
        let whole = try await context(repo, day: day, deviceIds: devices, metric: nil, timeout: 480) {
            $0.status == .available && !($0.document?.envelopes.isEmpty ?? true)
        }
        let all = try XCTUnwrap(whole.document?.full, "the stored summary + every table rebuild into the engine's document")
        XCTAssertNil(all.envelopeIndex, "every table came back")
        XCTAssertEqual(all.header.identity.day, day)
        print("PC_E2E_CONTEXT revision=\(whole.contextRevision ?? -1) envelopes=\(all.envelopes.count) "
              + "metrics=\(Set(all.envelopes.map(\.metric.rawValue)).sorted()) status=\(all.status.rawValue) "
              + "mode=\(all.header.interpretation.mode.rawValue) reasons=\(all.statusReasons.map(\.rawValue))")
        let metric = try XCTUnwrap(all.envelopes.map(\.metric).first)
        // A metric read returns only that metric's table.
        let first = try await context(repo, day: day, deviceIds: devices, metric: metric) {
            $0.status == .available && !($0.document?.envelopes.isEmpty ?? true)
        }
        let doc = try XCTUnwrap(first.document?.full)
        XCTAssertTrue(doc.envelopes.allSatisfy { $0.metric == metric }, "the metric filter returned one table")
        XCTAssertNotNil(doc.envelopeIndex, "a subset read keeps the full index")
        for e in all.envelopes {
            XCTAssertTrue(PC.IntervalAlgebra.reconciles(e.activity), e.id)
            XCTAssertEqual(e.activity.intervalS, e.support.duration, "composition over the whole support")
        }
        XCTAssertEqual(first.pairing?.consistent, true, "context paired with the latest scoring snapshot")
        let summary = MeasurementContextSummary.build(day: first, metric: metric)
        print("PC_E2E_CARD metric=\(metric.rawValue) state=\(summary.statePhrase) support=\(summary.supportText ?? "-") "
              + "eligibility=\(summary.eligibilityText ?? "-") coverage=\(summary.coverageText ?? "-") "
              + "reference=\(summary.referenceText ?? "-")")
        XCTAssertNotNil(summary.envelopeId, "the card has a real headline measurement")
        XCTAssertNotNil(summary.supportText)
        XCTAssertNil(summary.allText.compactMap(PhysiologyContextWording.containsForbiddenTerm).first)
        let firstRevision = try XCTUnwrap(first.contextRevision)

        // An exposure recorded on the phone (caffeine 15 minutes before the end of the upload).
        let whoop = try await WhoopStore.inMemory()
        let store = try ExposureEventStore(dbQueue: whoop.registryWriter)
        let eventId = UUID().uuidString.lowercased()
        let at = end - 900
        let r1 = PC.ExposureEventRevision(eventId: eventId, revision: 1, kind: .caffeine, label: "coffee",
                                          occurred: .init(at, at + 1), timePrecision: .exact, recordedAt: at + 60,
                                          source: .userEntered, confirmation: .confirmed, doseAmount: 80,
                                          doseUnit: "mg", doseProvenance: "user_entered")
        XCTAssertTrue(try store.record(r1, owner: identity.ownerId))
        let scores = env.scoresEndpoint
        let sync = ExposureEventSyncClient(store: store, session: .shared, endpoint: { scores },
                                          identity: { identity }, isOwner: { _ in true })
        let up1 = await sync.sync()
        XCTAssertNil(up1.stopped, "first upload: \(up1)")

        // The server invalidates the affected day; the worker recomputes; the new context lists the event.
        let second = try await context(repo, day: day, deviceIds: devices, metric: metric) { value in
            (value.contextRevision ?? 0) > firstRevision
                && (value.document?.full?.exposures.events.contains { $0.eventId == eventId && $0.revision == 1 } ?? false)
        }
        let afterFirst = try XCTUnwrap(second.document?.full)
        XCTAssertTrue(afterFirst.envelopes.contains { $0.history.exposures.contains { $0.eventId == eventId } },
                      "measurements after the event carry a reference to it")

        // A correction (dose and time) is a new revision of the same event; history is preserved.
        let r2 = PC.ExposureEventRevision(eventId: eventId, revision: 2, kind: .caffeine, label: "coffee",
                                          occurred: .init(at - 600, at - 599), timePrecision: .exact,
                                          recordedAt: at + 300, source: .userEntered, confirmation: .confirmed,
                                          doseAmount: 160, doseUnit: "mg", doseProvenance: "user_entered")
        XCTAssertTrue(try store.record(r2, owner: identity.ownerId))
        let up2 = await sync.sync()
        XCTAssertNil(up2.stopped, "correction upload: \(up2)")
        let third = try await context(repo, day: day, deviceIds: devices, metric: metric) { value in
            value.document?.full?.exposures.events.contains { $0.eventId == eventId && $0.revision == 2 } ?? false
        }
        let corrected = try XCTUnwrap(third.document?.full?.exposures.events.first { $0.eventId == eventId })
        XCTAssertEqual(corrected.doseAmount, 160)
        XCTAssertEqual(corrected.occurred.start, at - 600)
        XCTAssertEqual(corrected.revisionCount, 2, "both revisions were available to the recompute")
        let (status, history) = try await server.scores("exposures",
                                                        query: "from=\(at - 3600)&to=\(at + 3600)&history=1",
                                                        bearer: identity.uploadToken)
        XCTAssertEqual(status, 200)
        let revisions = (history["revisions"] as? [[String: Any]]) ?? []
        XCTAssertEqual(Set(revisions.compactMap { $0["revision"] as? Int }), [1, 2], "revision history kept: \(history)")

        // History route: bouts / episodes / daily values for the range answer for this owner.
        let hist = try await repo.history(from: day, to: day, deviceIds: devices)
        if case .loaded = hist {} else { XCTFail("history route: \(hist)") }
    }
}
