import XCTest
import NoopPush
import WhoopProtocol
@testable import Strand

/// The signed-in path as a tester would meet it, against real services: Supabase Auth issuing and emailing the
/// verification code, the `push` Edge function minting the installation credential, real Postgres with its
/// row-level security, the scoring worker, and the `scores` readback. Nothing between the app's own code and the
/// database is faked. See supabase/tests/e2e/README.md for the stack these need.
///
/// Two straps are in play. Each beats at a different rate with a different beat-to-beat pattern, so what the
/// worker publishes (resting heart rate, RMSSD) says whose data it is: any mix-up between the accounts shows
/// up as the wrong number, not just a wrong row count.
@MainActor
final class NaraEndToEndTests: XCTestCase {

    private struct Strap {
        let provisional: String
        let serial: String
        let bpm: Int
        let rr: [Int]
        /// RMSSD of the two-interval pattern: the absolute difference between neighbours.
        let rmssd: Double
    }

    private let strapA = Strap(provisional: "e2e-strap-a", serial: "E2E-A-0001", bpm: 60, rr: [1000, 1040], rmssd: 40)
    private let strapB = Strap(provisional: "e2e-strap-b", serial: "E2E-B-0001", bpm: 80, rr: [710, 790], rmssd: 80)
    private let captureSeconds = 1800

    private var env: E2EEnvironment!
    private var mailbox: E2EMailbox!
    private var server: E2EServer!
    private var phones: [E2EPhone] = []
    private var cloudEnabledBefore: Any?

    private static let enabledOverrideKey = "noop.cloud.enabled.override"

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

    private func makePhone(_ label: String, restoring other: E2EPhone? = nil,
                           withoutAuthSession: Bool = false) throws -> E2EPhone {
        let phone = try E2EPhone(env: env, label: label, restoring: other, withoutAuthSession: withoutAuthSession)
        phones.append(phone)
        return phone
    }

    private var nowSeconds: Int { Int(Date().timeIntervalSince1970) }

    private func records(_ strap: Strap, endingAt end: Int, seconds: Int? = nil, bpm: Int? = nil) -> [CloudJournalRecord] {
        E2EPhone.liveRecords(bpm: bpm ?? strap.bpm, rrPattern: strap.rr, seconds: seconds ?? captureSeconds,
                             endingAt: end, deviceId: strap.provisional)
    }

    private func utcDay(_ seconds: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    private func isRefusal(_ status: Int) -> Bool { [401, 403].contains(status) }

    // MARK: - one account, signup to readback

    func testSignupToScoredReadbackForOneAccount() async throws {
        let phone = try makePhone("A")
        let account = try await phone.signUp(mailbox: mailbox)
        XCTAssertEqual(phone.controller.bootstrap, .ready, "the verified session linked this phone")

        let identity = try XCTUnwrap(phone.store.identity(forOwner: account.userId))
        XCTAssertEqual(identity.ownerId, account.userId.lowercased(), "the account id is the Supabase user id")
        XCTAssertTrue(identity.uploadToken.hasPrefix("noop_"))

        let installations = try await server.rows(
            "noop_app_installations",
            "user_id=eq.\(identity.ownerId)&select=source_id,provisioning_method,revoked_at,platform,enrollment_code_id")
        XCTAssertEqual(installations.count, 1)
        XCTAssertEqual(installations.first?["source_id"] as? String, identity.sourceId)
        XCTAssertEqual(installations.first?["provisioning_method"] as? String, "supabase_auth")
        XCTAssertTrue(installations.first?["enrollment_code_id"] is NSNull, "no enrollment code was involved")

        let end = nowSeconds - 120
        try await phone.capture(records(strapA, endingAt: end))
        let paired = await phone.controller.confirmWearableIfNeeded(provisionalDeviceId: strapA.provisional,
                                                                    serial: strapA.serial)
        XCTAssertTrue(paired)

        let stored = try await server.count("noop_hr_samples", "user_id=eq.\(identity.ownerId)")
        XCTAssertEqual(stored, captureSeconds, "every captured second reached the account")
        let devices = try await server.devices(of: identity.ownerId)
        XCTAssertEqual(devices.count, 2, "the provisional strap and its serial-confirmed identity")
        XCTAssertTrue(devices.contains { ($0["external_device_id"] as? String) == "installation:\(identity.sourceId):\(strapA.provisional)" })
        XCTAssertTrue(devices.contains { ($0["external_device_id"] as? String)?.contains("whoop-\(strapA.serial)") == true },
                      "the canonical device exists: \(devices)")

        let series = try await phone.scoredSeries(deviceId: strapA.provisional, from: end - captureSeconds - 3600,
                                                  to: nowSeconds + 600) {
            !$0.points(.hrv).isEmpty && !$0.points(.restingHeartRate).isEmpty
        }
        for point in series.points(.hrv) {
            XCTAssertEqual(point.value, strapA.rmssd, accuracy: 1.5, "RMSSD of the 1000/1040 ms pattern")
        }
        for point in series.points(.restingHeartRate) {
            XCTAssertEqual(point.value, Double(strapA.bpm), accuracy: 1.5)
        }
    }

    // MARK: - two accounts, two phones, at the same time

    func testTwoAccountsStayIsolatedFromSignupThroughScoredReadback() async throws {
        let phoneA = try makePhone("A")
        let phoneB = try makePhone("B")
        let accountA = try await phoneA.signUp(mailbox: mailbox)
        let accountB = try await phoneB.signUp(mailbox: mailbox)
        XCTAssertNotEqual(accountA.userId, accountB.userId)
        let identityA = try XCTUnwrap(phoneA.identity)
        let identityB = try XCTUnwrap(phoneB.identity)
        XCTAssertNotEqual(identityA.sourceId, identityB.sourceId, "every account has its own source id")
        XCTAssertNotEqual(identityA.uploadToken, identityB.uploadToken)

        // Both phones capture and upload at once.
        let end = nowSeconds - 120
        async let uploadedA = phoneA.capture(records(strapA, endingAt: end))
        async let uploadedB = phoneB.capture(records(strapB, endingAt: end))
        _ = try await (uploadedA, uploadedB)
        let pairedA = await phoneA.controller.confirmWearableIfNeeded(provisionalDeviceId: strapA.provisional,
                                                                      serial: strapA.serial)
        let pairedB = await phoneB.controller.confirmWearableIfNeeded(provisionalDeviceId: strapB.provisional,
                                                                      serial: strapB.serial)
        XCTAssertTrue(pairedA && pairedB)

        // What the database holds: each account has exactly its own seconds, at its own heart rate.
        let a = identityA.ownerId, b = identityB.ownerId
        for (owner, strap) in [(a, strapA), (b, strapB)] {
            let total = try await server.count("noop_hr_samples", "user_id=eq.\(owner)")
            let foreign = try await server.count("noop_hr_samples", "user_id=eq.\(owner)&bpm=neq.\(strap.bpm)")
            XCTAssertEqual(total, captureSeconds, "\(owner) holds all of its own seconds")
            XCTAssertEqual(foreign, 0, "\(owner) holds nothing recorded at the other strap's rate")
            let sources = try await server.rows("noop_hr_samples", "user_id=eq.\(owner)&select=source_id&limit=1")
            XCTAssertEqual((sources.first?["source_id"] as? String)?.lowercased(),
                           (owner == a ? identityA : identityB).sourceId.lowercased(),
                           "rows carry their own account's source")
        }
        let installations = try await server.rows("noop_app_installations",
                                                  "user_id=in.(\(a),\(b))&select=user_id,source_id")
        XCTAssertEqual(installations.count, 2)
        let deviceRowsA = try await server.devices(of: a)
        let deviceRowsB = try await server.devices(of: b)
        let idsA = Set(deviceRowsA.compactMap { $0["id"] as? String })
        let idsB = Set(deviceRowsB.compactMap { $0["id"] as? String })
        XCTAssertFalse(idsA.isEmpty); XCTAssertFalse(idsB.isEmpty)
        XCTAssertTrue(idsA.isDisjoint(with: idsB), "no device is shared between the accounts")

        // What the worker scored and what each phone reads back.
        let from = end - captureSeconds - 3600
        async let seriesA = phoneA.scoredSeries(deviceId: strapA.provisional, from: from, to: nowSeconds + 600) {
            !$0.points(.hrv).isEmpty && !$0.points(.restingHeartRate).isEmpty
        }
        async let seriesB = phoneB.scoredSeries(deviceId: strapB.provisional, from: from, to: nowSeconds + 600) {
            !$0.points(.hrv).isEmpty && !$0.points(.restingHeartRate).isEmpty
        }
        let (readA, readB) = try await (seriesA, seriesB)
        for point in readA.points(.hrv) { XCTAssertEqual(point.value, strapA.rmssd, accuracy: 1.5, "A's RMSSD") }
        for point in readB.points(.hrv) { XCTAssertEqual(point.value, strapB.rmssd, accuracy: 1.5, "B's RMSSD") }
        for point in readA.points(.restingHeartRate) { XCTAssertEqual(point.value, Double(strapA.bpm), accuracy: 1.5) }
        for point in readB.points(.restingHeartRate) { XCTAssertEqual(point.value, Double(strapB.bpm), accuracy: 1.5) }

        for (owner, strap) in [(a, strapA), (b, strapB)] {
            let published = try await server.rows("server_metric_series",
                                                  "user_id=eq.\(owner)&metric=eq.hrv_rmssd_ms&select=value")
            XCTAssertFalse(published.isEmpty)
            for row in published {
                XCTAssertEqual((row["value"] as? NSNumber)?.doubleValue ?? -1, strap.rmssd, accuracy: 1.5,
                               "\(owner)'s published RMSSD is its own")
            }
        }

        // A phone asking for the other account's strap gets nothing of it.
        let wrongDevice = try await server.scores("series", query: "deviceId=\(strapB.provisional)&from=\(from)&to=\(nowSeconds + 600)",
                                                  bearer: identityA.uploadToken)
        let leakedMetrics = (wrongDevice.1["series"] as? [String: Any])?["metrics"] as? [String: Any] ?? [:]
        let leakedPoints = leakedMetrics.values.compactMap { $0 as? [Any] }.reduce(0) { $0 + $1.count }
        XCTAssertEqual(leakedPoints, 0, "A's credential reads none of B's series (status \(wrongDevice.0))")
        let wrongDays = try await server.scores("days", query: "deviceId=\(strapB.provisional)", bearer: identityA.uploadToken)
        XCTAssertEqual((wrongDays.1["days"] as? [Any])?.count ?? 0, 0, "A's credential lists none of B's days")

        try await assertRowLevelSecurityKeepsAccountsApart(phoneA: phoneA, phoneB: phoneB, a: identityA, b: identityB,
                                                           bDevices: deviceRowsB, strapB: strapB)
        try await assertCrossAccountRequestsAreRefused(phoneA: phoneA, a: identityA, b: identityB, strapA: strapA,
                                                       strapB: strapB, bDevices: deviceRowsB)

        // Nothing above changed what either account holds.
        for (owner, strap) in [(a, strapA), (b, strapB)] {
            let total = try await server.count("noop_hr_samples", "user_id=eq.\(owner)")
            let foreign = try await server.count("noop_hr_samples", "user_id=eq.\(owner)&bpm=neq.\(strap.bpm)")
            XCTAssertEqual(total, captureSeconds)
            XCTAssertEqual(foreign, 0)
        }
    }

    private func assertRowLevelSecurityKeepsAccountsApart(phoneA: E2EPhone, phoneB: E2EPhone, a: CloudPushIdentity,
                                                          b: CloudPushIdentity, bDevices: [[String: Any]],
                                                          strapB: Strap) async throws {
        let jwtA = try await phoneA.accessToken()
        let jwtB = try await phoneB.accessToken()

        // Reads: a signed-in user sees their own rows and none of anyone else's, whatever they ask for.
        let readable = ["noop_hr_samples", "noop_rr_intervals", "devices", "server_metric_series",
                        "server_daily_scores", "noop_wearable_aliases", "noop_app_installations",
                        "noop_ingest_tokens", "scoring_snapshots_v2", "server_physiology_results"]
        for table in readable {
            let theirs = try await visibleCount(table, "user_id=eq.\(b.ownerId)", jwt: jwtA)
            XCTAssertEqual(theirs, 0, "\(table): A can see \(theirs) of B's rows")
            let unfiltered = try await visibleRows(table, "select=user_id&limit=50", jwt: jwtA)
            XCTAssertTrue(unfiltered.allSatisfy { ($0["user_id"] as? String)?.lowercased() == a.ownerId },
                          "\(table): an unfiltered read as A returned someone else's rows")
            let mirrored = try await visibleCount(table, "user_id=eq.\(a.ownerId)", jwt: jwtB)
            XCTAssertEqual(mirrored, 0, "\(table): B can see \(mirrored) of A's rows")
        }
        let ownHr = try await server.count("noop_hr_samples", "", asUser: jwtA)
        XCTAssertEqual(ownHr, captureSeconds, "A sees exactly its own heart-rate seconds")

        // Nothing at all without a session.
        let anonymous = try await server.anonymousRows("noop_hr_samples", "select=user_id&limit=5")
        XCTAssertTrue(anonymous.rows.isEmpty, "an unauthenticated read returned rows")

        // Writes: A cannot create, change or remove B's rows, nor hand its own to B.
        let bDevice = try XCTUnwrap(bDevices.first?["id"] as? String)
        let forgedSample = try await server.write("noop_hr_samples", method: "POST",
            body: ["user_id": b.ownerId, "device_id": bDevice, "source_id": b.sourceId, "ts": nowSeconds, "bpm": 99],
            userJWT: jwtA)
        XCTAssertTrue(isRefusal(forgedSample.status) && forgedSample.rows.isEmpty, "A cannot write a sample into B's account (\(forgedSample.status))")
        let ownSample = try await server.write("noop_hr_samples", method: "POST",
            body: ["user_id": a.ownerId, "device_id": bDevice, "source_id": a.sourceId, "ts": nowSeconds, "bpm": 99],
            userJWT: jwtA)
        XCTAssertTrue(isRefusal(ownSample.status) && ownSample.rows.isEmpty,
                      "clients cannot write sample tables at all, only the upload path does (\(ownSample.status))")
        let forgedDevice = try await server.write("devices", method: "POST",
            body: ["id": UUID().uuidString.lowercased(), "user_id": b.ownerId, "source_kind": "noop_push",
                   "external_device_id": "installation:\(b.sourceId):e2e-forged"], userJWT: jwtA)
        XCTAssertTrue(isRefusal(forgedDevice.status), "A cannot create a device in B's account (\(forgedDevice.status))")
        let renamed = try await server.write("devices", method: "PATCH", query: "id=eq.\(bDevice)",
                                             body: ["nickname": "taken"], userJWT: jwtA)
        XCTAssertTrue(renamed.rows.isEmpty, "A changed a row of B's")
        let removed = try await server.write("devices", method: "DELETE", query: "id=eq.\(bDevice)", userJWT: jwtA)
        XCTAssertTrue(removed.rows.isEmpty, "A deleted a row of B's")
        let ownDevices = try await server.devices(of: a.ownerId)
        let aDevice = try XCTUnwrap(ownDevices.first?["id"] as? String)
        let handedOver = try await server.write("devices", method: "PATCH", query: "id=eq.\(aDevice)",
                                                body: ["user_id": b.ownerId], userJWT: jwtA)
        XCTAssertFalse((200..<300).contains(handedOver.status) && !handedOver.rows.isEmpty,
                       "A handed its own device to B (\(handedOver.status))")
        let stillBs = try await server.devices(of: b.ownerId)
        XCTAssertTrue(stillBs.contains { ($0["id"] as? String) == bDevice }, "B's device is still B's")
        let stillAs = try await server.devices(of: a.ownerId)
        XCTAssertTrue(stillAs.contains { ($0["id"] as? String) == aDevice }, "A's device is still A's")

        // Functions a client can call take a device or a user as an argument; each checks it against the caller.
        let today = utcDay(nowSeconds)
        let score = try await server.callRPC("get_server_score_snapshot_v2",
            ["p_day": today, "p_source": b.sourceId, "p_external_device_id": strapB.provisional], asUser: jwtA)
        XCTAssertTrue(isRefusal(score.status), "A reading B's score through SQL (\(score.status)): \(String(describing: score.body))")
        let readContract = try await server.callRPC("server_scoring_read_contract",
            ["p_user": b.ownerId, "p_day": today, "p_device": bDevice], asUser: jwtA)
        XCTAssertTrue(isRefusal(readContract.status), "A reading B's scoring contract (\(readContract.status))")
        let head = try await server.callRPC("get_scoring_history_input_head_v3",
            ["p_device": bDevice, "p_kind": "profile", "p_entity": "primary"], asUser: jwtA)
        XCTAssertTrue(isRefusal(head.status), "A reading B's history head (\(head.status))")
        let put = try await server.callRPC("put_scoring_history_input_v3",
            ["p_device": bDevice, "p_kind": "profile", "p_entity": "primary", "p_effective_day": today,
             "p_payload": ["heightCm": 180], "p_expected_revision": 0, "p_deleted": false,
             "p_client_id": UUID().uuidString.lowercased(), "p_client_mutation_id": UUID().uuidString.lowercased(),
             "p_client_revision": 1], asUser: jwtA)
        XCTAssertTrue(isRefusal(put.status), "A writing history input for B's device (\(put.status))")
        let burnQuota = try await server.callRPC("noop_push_consume_ingest_quota",
            ["p_user_id": b.ownerId, "p_bytes": 1_000_000_000, "p_max_batches": 1_000_000, "p_max_bytes": 9_000_000_000_000,
             "p_window_seconds": 3600], asUser: jwtA)
        XCTAssertTrue(isRefusal(burnQuota.status) || burnQuota.status == 404,
                      "A charging B's upload quota (\(burnQuota.status))")
        let anonymousBurn = try await server.callRPC("noop_push_consume_ingest_quota",
            ["p_user_id": b.ownerId, "p_bytes": 1, "p_max_batches": 10, "p_max_bytes": 10, "p_window_seconds": 3600],
            asUser: nil, anonymous: true)
        XCTAssertTrue(isRefusal(anonymousBurn.status) || anonymousBurn.status == 404,
                      "an unauthenticated caller charging B's upload quota (\(anonymousBurn.status))")
        let anonymousWorker = try await server.callRPC("http_post_worker", ["fn_path": "/reconcile"], asUser: nil, anonymous: true)
        XCTAssertTrue(isRefusal(anonymousWorker.status) || anonymousWorker.status == 404,
                      "an unauthenticated caller starting a worker (\(anonymousWorker.status))")
    }

    private func assertCrossAccountRequestsAreRefused(phoneA: E2EPhone, a: CloudPushIdentity, b: CloudPushIdentity,
                                                      strapA: Strap, strapB: Strap, bDevices: [[String: Any]]) async throws {
        let jwtA = try await phoneA.accessToken()
        let bDevice = try XCTUnwrap(bDevices.first?["id"] as? String)

        // Registering B's source id under A's account is refused, with or without B's credential, and the
        // refusal is the same as for a source id nobody has: it does not say whose it is.
        let body: [String: Any] = ["sourceId": b.sourceId, "platform": "ios", "appVersion": "e2e (1)"]
        let takeover = try await server.push("installations/provision", bearer: jwtA, body: body)
        XCTAssertEqual(takeover.0, 409)
        XCTAssertEqual(takeover.1["code"] as? String, "installation_unavailable")
        let withTheirToken = try await server.push("installations/provision", bearer: jwtA, body: body,
                                                   headers: ["x-noop-installation-token": b.uploadToken])
        XCTAssertEqual(withTheirToken.0, 409, "B's own credential does not let A claim B's source")
        XCTAssertNil(withTheirToken.1["installationToken"])
        let unknown = try await server.push("installations/provision", bearer: jwtA,
            body: ["sourceId": UUID().uuidString.lowercased(), "platform": "ios", "appVersion": "e2e (1)"])
        XCTAssertEqual(unknown.0, 201, "an unused source id is simply registered")
        let refusedAndUnknownAgree = takeover.1["code"] as? String
        XCTAssertNotNil(refusedAndUnknownAgree)

        // A request cannot name its owner: an extra user id in the body changes nothing.
        let named = try await server.push("installations/provision", bearer: jwtA,
            body: ["sourceId": a.sourceId, "platform": "ios", "appVersion": "e2e (1)", "userId": b.ownerId, "user_id": b.ownerId],
            headers: ["x-noop-installation-token": a.uploadToken])
        XCTAssertEqual(named.1["userId"] as? String, a.ownerId, "the owner comes from the session, not the request")

        // A's credential cannot act on B's strap.
        let handoff = try await server.push("wearables/handoff", bearer: a.uploadToken,
                                            body: ["externalDeviceId": strapB.provisional])
        XCTAssertEqual(handoff.0, 404, "B's strap does not exist in A's account")
        // A serial number is evidence about a strap, not a claim on someone else's account: the canonical device id
        // is derived from the account as well as the serial. A confirming B's serial therefore gets a device of its
        // own, and B's strap, alias and data are exactly as they were.
        let bAliasesBefore = try await server.rows("noop_wearable_aliases", "user_id=eq.\(b.ownerId)&select=*")
        let bDevicesBefore = try await server.devices(of: b.ownerId)
        let claimSerial = try await server.push("wearables/confirm", bearer: a.uploadToken, body: [
            "provisionalExternalDeviceId": "e2e-strap-a-2",
            "evidence": ["method": "device_information_serial_v1", "serial": strapB.serial,
                         "receiptSha256": String(repeating: "ab", count: 32)],
        ])
        if claimSerial.0 == 200 {
            XCTAssertEqual(claimSerial.1["userId"] as? String, a.ownerId, "the confirmation is recorded for the caller")
            XCTAssertEqual(claimSerial.1["sourceId"] as? String, a.sourceId)
            let claimedDevice = try XCTUnwrap(claimSerial.1["deviceId"] as? String)
            XCTAssertNotEqual(claimedDevice, bDevice, "A did not obtain B's device")
            let ownedByA = try await server.rows("devices", "id=eq.\(claimedDevice)&select=user_id")
            XCTAssertEqual(ownedByA.compactMap { $0["user_id"] as? String }, [a.ownerId], "the new device belongs to A")
        } else {
            XCTAssertTrue([409, 422, 503].contains(claimSerial.0), "refused as a conflict, not as a server error (\(claimSerial.0))")
        }
        let bAliasesAfter = try await server.rows("noop_wearable_aliases", "user_id=eq.\(b.ownerId)&select=*")
        XCTAssertEqual(bAliasesAfter.count, bAliasesBefore.count, "B's strap aliases did not change")
        let bDevicesAfter = try await server.devices(of: b.ownerId)
        XCTAssertEqual(Set(bDevicesAfter.compactMap { $0["id"] as? String }),
                       Set(bDevicesBefore.compactMap { $0["id"] as? String }), "B's devices did not change")
        let bAliasOwner = try await server.rows("noop_wearable_aliases", "source_id=eq.\(b.sourceId)&select=user_id")
        XCTAssertEqual(bAliasOwner.compactMap { $0["user_id"] as? String }, [b.ownerId], "B's strap is still B's")
        let bStillHasItsSamples = try await server.count("noop_hr_samples", "user_id=eq.\(b.ownerId)")
        XCTAssertEqual(bStillHasItsSamples, captureSeconds, "B's data is where it was")

        // The identities behind both accounts cannot be re-pointed, even by an operator.
        let moveInstallation = try await server.write("noop_app_installations", method: "PATCH",
                                                      query: "source_id=eq.\(b.sourceId)", body: ["user_id": a.ownerId])
        XCTAssertFalse((200..<300).contains(moveInstallation.status), "an installation changed owner (\(moveInstallation.status))")
        let moveDevice = try await server.write("devices", method: "PATCH", query: "id=eq.\(bDevice)",
                                                body: ["user_id": a.ownerId])
        XCTAssertFalse((200..<300).contains(moveDevice.status), "a device changed owner (\(moveDevice.status))")
        let installations = try await server.rows("noop_app_installations", "source_id=eq.\(b.sourceId)&select=user_id")
        XCTAssertEqual(installations.compactMap { $0["user_id"] as? String }, [b.ownerId])
        let devices = try await server.rows("devices", "id=eq.\(bDevice)&select=user_id")
        XCTAssertEqual(devices.compactMap { $0["user_id"] as? String }, [b.ownerId])
    }

    private func visibleRows(_ table: String, _ query: String, jwt: String) async throws -> [[String: Any]] {
        let status = try await server.readStatus(table, query, asUser: jwt)
        if isRefusal(status) { return [] }
        return try await server.rows(table, query, asUser: jwt)
    }

    private func visibleCount(_ table: String, _ query: String, jwt: String) async throws -> Int {
        try await visibleRows(table, query + "&select=user_id", jwt: jwt).count
    }

    // MARK: - one phone, two accounts

    func testSwitchingAccountsOnOnePhoneNeverRetagsQueuedData() async throws {
        let phone = try makePhone("S")
        let first = try await phone.signUp(mailbox: mailbox)
        let firstEmail = phone.lastEmail, firstPassword = phone.lastPassword
        let identityA = try XCTUnwrap(phone.identity)

        let end = nowSeconds - 300
        let settled = try await phone.capture(records(strapA, endingAt: end, seconds: 120))
        XCTAssertEqual(settled.pendingRecords, 0)

        // A's next seconds are captured but the transport is held back, so they are still in the journal
        // when A signs out: the case a person meets when they sign out between two uploads.
        await phone.runtime.coordinatorIfRunning?.stop()
        let queuedSeconds = 60
        let queued = records(strapA, endingAt: end + 60, seconds: queuedSeconds, bpm: 61)
        let committed = await phone.runtime.submitDurably(queued)
        XCTAssertEqual(committed, queued.count)
        let pendingBeforeSignOut = await phone.runtime.stats().pendingRecords
        XCTAssertEqual(pendingBeforeSignOut, queued.count, "the queued seconds are waiting, not uploaded")

        await phone.controller.signOut()
        XCTAssertNil(phone.runtime.runningScope, "nothing is uploading for anyone while signed out")
        XCTAssertNil(phone.store.identity(forOwner: first.userId), "the signed-out account's credential left the Keychain")
        let heldBack = try await server.count("noop_hr_samples", "user_id=eq.\(identityA.ownerId)&bpm=eq.61")
        XCTAssertEqual(heldBack, 0, "signing out did not push the queue anywhere")

        // B uses the same phone.
        let second = try await phone.signUp(mailbox: mailbox)
        XCTAssertNotEqual(first.userId, second.userId)
        let identityB = try XCTUnwrap(phone.identity)
        XCTAssertNotEqual(identityB.sourceId, identityA.sourceId, "the second account gets its own source id on the same phone")
        XCTAssertNotEqual(identityB.uploadToken, identityA.uploadToken)
        let bSeconds = 90
        try await phone.capture(records(strapB, endingAt: end + 120, seconds: bSeconds))

        let aQueuedUnderB = try await server.count("noop_hr_samples", "user_id=eq.\(identityB.ownerId)&bpm=eq.61")
        XCTAssertEqual(aQueuedUnderB, 0, "A's queued seconds were not uploaded as B's")
        let bTotal = try await server.count("noop_hr_samples", "user_id=eq.\(identityB.ownerId)")
        XCTAssertEqual(bTotal, bSeconds, "B holds only what was captured while B was signed in")
        let bForeign = try await server.count("noop_hr_samples", "user_id=eq.\(identityB.ownerId)&bpm=neq.\(strapB.bpm)")
        XCTAssertEqual(bForeign, 0)
        let aStill = try await server.count("noop_hr_samples", "user_id=eq.\(identityA.ownerId)&bpm=eq.61")
        XCTAssertEqual(aStill, 0, "A's queue is still waiting for A")

        // A comes back: the queue was kept under A and goes to A.
        await phone.controller.signOut()
        try await phone.signIn(email: firstEmail, password: firstPassword)
        let backAgain = try XCTUnwrap(phone.identity)
        XCTAssertEqual(backAgain.ownerId, identityA.ownerId)
        XCTAssertEqual(backAgain.sourceId, identityA.sourceId, "the phone keeps one source id per account")
        let delivered = await e2eWait(timeout: 60, interval: 0.5) {
            phone.runtime.kick()
            return try await self.server.count("noop_hr_samples", "user_id=eq.\(identityA.ownerId)&bpm=eq.61") == queuedSeconds
        }
        XCTAssertTrue(delivered, "A's queued seconds reached A once A signed back in")
        let leakedToB = try await server.count("noop_hr_samples", "user_id=eq.\(identityB.ownerId)&bpm=eq.61")
        XCTAssertEqual(leakedToB, 0)
        let aLeak = try await server.count("noop_hr_samples", "user_id=eq.\(identityA.ownerId)&bpm=eq.\(strapB.bpm)")
        XCTAssertEqual(aLeak, 0, "B's seconds never landed in A's account")
        let sources = try await server.rows("noop_hr_samples", "user_id=eq.\(identityA.ownerId)&bpm=eq.61&select=source_id&limit=1")
        XCTAssertEqual((sources.first?["source_id"] as? String)?.lowercased(), identityA.sourceId.lowercased())
    }

    // MARK: - relaunch and background

    func testRelaunchAndBackgroundUploadDoNotNeedAnAuthSession() async throws {
        CloudPushSettings.setEnabled(true)
        let phone = try makePhone("R")
        let account = try await phone.signUp(mailbox: mailbox)
        let identity = try XCTUnwrap(phone.identity)
        let end = nowSeconds - 300
        try await phone.capture(records(strapA, endingAt: end, seconds: 60))
        _ = await phone.controller.confirmWearableIfNeeded(provisionalDeviceId: strapA.provisional, serial: strapA.serial)
        let eventsBefore = try await server.count("noop_installation_provisioning_events", "user_id=eq.\(account.userId)")
        XCTAssertEqual(eventsBefore, 1, "one registration so far")
        await phone.runtime.stop()

        // The app is relaunched normally: the session and the credential come back, and nothing re-registers.
        let relaunched = try makePhone("R2", restoring: phone)
        await relaunched.controller.start()
        await relaunched.controller.settle()
        XCTAssertEqual(relaunched.controller.bootstrap, .ready)
        XCTAssertEqual(relaunched.identity?.uploadToken, identity.uploadToken, "the same credential survives a restart")
        XCTAssertEqual(relaunched.identity?.tokenId, identity.tokenId)
        let eventsAfter = try await server.count("noop_installation_provisioning_events", "user_id=eq.\(account.userId)")
        XCTAssertEqual(eventsAfter, eventsBefore, "a restart did not register the phone again")
        try await relaunched.capture(records(strapA, endingAt: end + 60, seconds: 60))
        await relaunched.runtime.stop()

        // The process is woken with no readable session (a locked phone, a Bluetooth relaunch): the stored
        // installation credential alone is enough to keep uploading.
        let background = try makePhone("R3", restoring: relaunched, withoutAuthSession: true)
        XCTAssertNil(background.account, "this launch has no Auth session")
        XCTAssertTrue(background.runtime.startIfEnabled(fallbackDeviceId: strapA.provisional),
                      "the runtime starts from the stored credential")
        XCTAssertEqual(background.runtime.runningScope, identity.scope)
        background.runtime.setAppIsActive(false)
        try await background.capture(records(strapA, endingAt: end + 120, seconds: 60))

        let stored = try await server.count("noop_hr_samples", "user_id=eq.\(account.userId)")
        XCTAssertEqual(stored, 180, "all three launches' seconds reached the account")
        let eventsEnd = try await server.count("noop_installation_provisioning_events", "user_id=eq.\(account.userId)")
        XCTAssertEqual(eventsEnd, eventsBefore, "no launch needed to register again")
        let installations = try await server.rows("noop_app_installations", "user_id=eq.\(account.userId)&select=source_id")
        XCTAssertEqual(installations.count, 1)
    }

    // MARK: - fail closed

    func testRevokedInstallationAndDeletedAccountFailClosed() async throws {
        let revoked = try makePhone("V")
        let deleted = try makePhone("D")
        _ = try await revoked.signUp(mailbox: mailbox)
        _ = try await deleted.signUp(mailbox: mailbox)
        let revokedIdentity = try XCTUnwrap(revoked.identity)
        let deletedIdentity = try XCTUnwrap(deleted.identity)
        let end = nowSeconds - 300
        try await revoked.capture(records(strapA, endingAt: end, seconds: 60))
        try await deleted.capture(records(strapB, endingAt: end, seconds: 60))
        let deletedJWT = try await deleted.accessToken()

        // An operator revokes one installation.
        let revokedAt = ISO8601DateFormatter().string(from: Date())
        let changed = try await server.write("noop_app_installations", method: "PATCH",
            query: "source_id=eq.\(revokedIdentity.sourceId)", body: ["revoked_at": revokedAt])
        XCTAssertTrue((200..<300).contains(changed.status), "revoking the installation: \(changed.status)")
        let refused = try await server.push("", bearer: revokedIdentity.uploadToken, method: "POST", body: [:])
        XCTAssertTrue(isRefusal(refused.0), "a revoked installation's credential is refused (\(refused.0))")
        let revokedRead = try await server.scores("days", query: "deviceId=\(strapA.provisional)", bearer: revokedIdentity.uploadToken)
        XCTAssertTrue(isRefusal(revokedRead.0), "and cannot read scores (\(revokedRead.0))")

        let more = records(strapA, endingAt: end + 30, seconds: 30)
        _ = await revoked.runtime.submitDurably(more)
        let stopped = await e2eWait(timeout: 90, interval: 0.5) {
            revoked.runtime.kick()
            if case .blocked = revoked.controller.bootstrap { return revoked.runtime.runningScope == nil }
            return false
        }
        XCTAssertTrue(stopped, "the app stopped uploading for a revoked installation: \(revoked.controller.bootstrap)")
        let afterRevocation = try await server.count("noop_hr_samples", "user_id=eq.\(revokedIdentity.ownerId)")
        XCTAssertEqual(afterRevocation, 60, "nothing was accepted after the revocation")

        // The other account is deleted outright.
        try await server.deleteAuthUser(deletedIdentity.ownerId)
        let upload = try await server.push("", bearer: deletedIdentity.uploadToken, method: "POST", body: [:])
        XCTAssertTrue(isRefusal(upload.0), "a deleted account's credential is refused (\(upload.0))")
        let read = try await server.scores("days", query: "deviceId=\(strapB.provisional)", bearer: deletedIdentity.uploadToken)
        XCTAssertTrue(isRefusal(read.0), "and cannot read scores (\(read.0))")
        let provision = try await server.push("installations/provision", bearer: deletedJWT, body: [
            "sourceId": deletedIdentity.sourceId, "platform": "ios", "appVersion": "e2e (1)"])
        XCTAssertTrue(isRefusal(provision.0), "a deleted account's session cannot register a phone (\(provision.0))")
        let remaining = try await server.count("noop_app_installations", "user_id=eq.\(deletedIdentity.ownerId)")
        XCTAssertEqual(remaining, 0, "the deleted account's installations went with it")

        _ = await deleted.runtime.submitDurably(records(strapB, endingAt: end + 30, seconds: 30))
        let ended = await e2eWait(timeout: 90, interval: 0.5) {
            deleted.runtime.kick()
            return deleted.runtime.runningScope == nil
        }
        XCTAssertTrue(ended, "the app stopped uploading for a deleted account: \(deleted.controller.bootstrap)")
        let leftover = try await server.count("noop_hr_samples", "user_id=eq.\(deletedIdentity.ownerId)")
        XCTAssertEqual(leftover, 0, "no data of a deleted account remains or arrives")
    }
}
