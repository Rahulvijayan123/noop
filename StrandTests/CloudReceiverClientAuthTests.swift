import XCTest
@testable import Strand

/// The two account calls on the wire: what the phone sends to be given an upload credential, and what it
/// will and will not believe in reply. The server decides ownership from the Supabase token alone, so the
/// request must carry no user id; the reply is checked against what was asked before anything is stored.
final class CloudReceiverClientAuthTests: XCTestCase {

    private let owner = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let stranger = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let source = "a0a0a0a0-a0a0-4a0a-8a0a-a0a0a0a0a0a0"
    private let endpoint = URL(string: "https://example.supabase.co/functions/v1/push")!

    override func setUp() {
        super.setUp()
        ReceiverStub.reset()
    }

    override func tearDown() {
        ReceiverStub.reset()
        CloudPushSettings.bundleStringOverride = nil
        super.tearDown()
    }

    private func client() -> CloudReceiverClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReceiverStub.self]
        return CloudReceiverClient(session: URLSession(configuration: configuration), endpoint: endpoint,
                                   publishableKey: "sb_publishable_test_key")
    }

    private func grantJSON(user: String? = nil, source: String? = nil, action: String = "created",
                           token: String? = "noop_abcdef", extra: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = [
            "type": "installationProvisioning",
            "protocolVersion": "1.2",
            "userId": user ?? owner,
            "sourceId": source ?? self.source,
            "tokenId": UUID().uuidString.lowercased(),
            "action": action,
            "expiresAt": "2027-10-03T12:00:00.000Z",
        ]
        if let token { body["installationToken"] = token }
        for (key, value) in extra { body[key] = value }
        return body
    }

    // MARK: provisioning

    func testProvisioningSendsTheSessionTokenAndNoUserId() async throws {
        ReceiverStub.respond(status: 201, json: grantJSON())

        let grant = try await client().provisionInstallation(accessToken: "supabase.jwt.token", expectedOwnerId: owner,
                                                             sourceId: source.uppercased(), platform: .ios,
                                                             appVersion: "1.2 (34)", currentToken: nil)

        let request = try XCTUnwrap(ReceiverStub.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://example.supabase.co/functions/v1/push/installations/provision")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer supabase.jwt.token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_test_key")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-noop-installation-token"), "first time: nothing to present")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-noop-fleet-token"), "no shared token on the tester path")

        let body = try XCTUnwrap(ReceiverStub.jsonBody(of: request))
        XCTAssertEqual(Set(body.keys), ["sourceId", "platform", "appVersion"],
                       "the body names the installation only; ownership comes from the verified token")
        XCTAssertEqual(body["sourceId"] as? String, source, "the source id is sent normalised")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["appVersion"] as? String, "1.2 (34)")

        XCTAssertEqual(grant.userId, owner)
        XCTAssertEqual(grant.sourceId, source)
        XCTAssertEqual(grant.action, .created)
        XCTAssertEqual(grant.installationToken, "noop_abcdef")
        XCTAssertNotNil(grant.expiresAt)
    }

    func testAPresentedCredentialTravelsInItsOwnHeaderNotTheBearer() async throws {
        ReceiverStub.respond(status: 200, json: grantJSON(action: "reused", token: nil))

        let grant = try await client().provisionInstallation(accessToken: "supabase.jwt.token", expectedOwnerId: owner,
                                                             sourceId: source, platform: .macos,
                                                             appVersion: "1.0", currentToken: "noop_current")

        let request = try XCTUnwrap(ReceiverStub.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-noop-installation-token"), "noop_current")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer supabase.jwt.token",
                       "the bearer stays the proof of the account")
        XCTAssertEqual(grant.action, .reused)
        XCTAssertNil(grant.installationToken, "a still-valid credential is not sent back")
    }

    func testAReplyForAnotherAccountOrSourceIsNeverBelieved() async throws {
        ReceiverStub.respond(status: 201, json: grantJSON(user: stranger))
        await assertFails(.ownershipMismatch) {
            _ = try await self.client().provisionInstallation(accessToken: "t", expectedOwnerId: self.owner,
                                                              sourceId: self.source, platform: .ios,
                                                              appVersion: "1.0", currentToken: nil)
        }

        ReceiverStub.reset()
        ReceiverStub.respond(status: 201, json: grantJSON(source: "c0c0c0c0-c0c0-4c0c-8c0c-c0c0c0c0c0c0"))
        await assertFails(.ownershipMismatch) {
            _ = try await self.client().provisionInstallation(accessToken: "t", expectedOwnerId: self.owner,
                                                              sourceId: self.source, platform: .ios,
                                                              appVersion: "1.0", currentToken: nil)
        }
    }

    func testAMalformedGrantIsRefused() async throws {
        // A new or rotated credential must come with its token, and the token must look like one of ours.
        for body in [grantJSON(action: "created", token: nil),
                     grantJSON(action: "rotated", token: nil),
                     grantJSON(action: "created", token: "sb_secret_looks_wrong"),
                     grantJSON(action: "bogus")] {
            ReceiverStub.reset()
            ReceiverStub.respond(status: 200, json: body)
            await assertFails(.malformedResponse) {
                _ = try await self.client().provisionInstallation(accessToken: "t", expectedOwnerId: self.owner,
                                                                  sourceId: self.source, platform: .ios,
                                                                  appVersion: "1.0", currentToken: nil)
            }
        }
        ReceiverStub.reset()
        ReceiverStub.respond(status: 200, data: Data("<html>gateway</html>".utf8))
        await assertFails(.malformedResponse) {
            _ = try await self.client().provisionInstallation(accessToken: "t", expectedOwnerId: self.owner,
                                                              sourceId: self.source, platform: .ios,
                                                              appVersion: "1.0", currentToken: nil)
        }
    }

    func testServerRefusalsMapToTheirDocumentedCases() async throws {
        let cases: [(Int, String?, TimeInterval?, CloudReceiverError)] = [
            (401, "invalid_token", nil, .sessionRejected),
            (403, "email_not_confirmed", nil, .emailNotConfirmed),
            (409, "installation_unavailable", nil, .installationUnavailable),
            (403, "installation_retired", nil, .installationRetired),
            (403, "installation_revoked", nil, .installationRevoked),
            (403, "account_retired", nil, .accountRetired),
            (409, "installation_limit", nil, .installationLimit),
            (429, "provision_rate_limited", 300, .rateLimited(retryAfter: 300)),
            (503, nil, nil, .serverFault(503)),
        ]
        for (status, code, retryAfter, expected) in cases {
            ReceiverStub.reset()
            var json: [String: Any] = ["error": "refused"]
            if let code { json["code"] = code }
            ReceiverStub.respond(status: status, json: json, retryAfter: retryAfter)
            await assertFails(expected, "\(status) \(code ?? "-")") {
                _ = try await self.client().provisionInstallation(accessToken: "t", expectedOwnerId: self.owner,
                                                                  sourceId: self.source, platform: .ios,
                                                                  appVersion: "1.0", currentToken: nil)
            }
        }
    }

    func testTransientFailuresAreRetryableAndTheRestAreNot() {
        XCTAssertTrue(CloudReceiverError.rateLimited(retryAfter: nil).isTransient)
        XCTAssertTrue(CloudReceiverError.serverFault(502).isTransient)
        XCTAssertTrue(CloudReceiverError.transport.isTransient)
        for permanent: CloudReceiverError in [.sessionRejected, .emailNotConfirmed, .installationRevoked,
                                              .installationRetired, .accountRetired, .ownershipMismatch,
                                              .installationUnavailable, .installationLimit] {
            XCTAssertFalse(permanent.isTransient, "\(permanent) must not be retried blindly")
        }
    }

    func testANetworkFailureIsTransport() async {
        ReceiverStub.fail(with: URLError(.notConnectedToInternet))
        await assertFails(.transport) {
            _ = try await self.client().provisionInstallation(accessToken: "t", expectedOwnerId: self.owner,
                                                              sourceId: self.source, platform: .ios,
                                                              appVersion: "1.0", currentToken: nil)
        }
    }

    func testAnUnsafeAppVersionIsNotSent() async {
        for version in ["", "   ", String(repeating: "9", count: 65), "1.0\n(2)", "1.0\u{7f}"] {
            ReceiverStub.reset()
            ReceiverStub.respond(status: 201, json: grantJSON())
            await assertFails(.malformedResponse, "version \(version.debugDescription)") {
                _ = try await self.client().provisionInstallation(accessToken: "t", expectedOwnerId: self.owner,
                                                                  sourceId: self.source, platform: .ios,
                                                                  appVersion: version, currentToken: nil)
            }
            XCTAssertTrue(ReceiverStub.requests.isEmpty, "nothing is sent with a version the server would reject")
        }
    }

    func testAnUnconfiguredBuildFailsBeforeAnyNetworkCall() async {
        let unconfigured = CloudReceiverClient(session: URLSession(configuration: .ephemeral), endpoint: nil,
                                               publishableKey: nil)
        CloudPushSettings.bundleStringOverride = { _ in "" }
        do {
            _ = try await unconfigured.provisionInstallation(accessToken: "t", expectedOwnerId: owner, sourceId: source,
                                                            platform: .ios, appVersion: "1.0", currentToken: nil)
            XCTFail("expected notConfigured")
        } catch {
            XCTAssertEqual(error as? CloudReceiverError, .notConfigured)
        }
    }

    // MARK: wearable confirmation

    private func identity(provisioning: CloudPushIdentity.Provisioning = .supabaseAuth) -> CloudPushIdentity {
        CloudPushIdentity(ownerId: owner, sourceId: source, tokenId: UUID().uuidString, uploadToken: "noop_install",
                          provisioning: provisioning)
    }

    func testConfirmingAStrapUsesTheInstallationCredentialAndTheSerialEvidence() async throws {
        ReceiverStub.respond(status: 200, json: ["userId": owner, "sourceId": source, "deviceId": "whoop-mgb0214654",
                                                 "state": "confirmed"])

        let deviceId = try await client().confirmWearable(identity: identity(), provisionalExternalDeviceId: "my-whoop",
                                                          serial: "MGB0214654")

        XCTAssertEqual(deviceId, "whoop-mgb0214654")
        let request = try XCTUnwrap(ReceiverStub.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.supabase.co/functions/v1/push/wearables/confirm")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer noop_install")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-noop-fleet-token"))
        let body = try XCTUnwrap(ReceiverStub.jsonBody(of: request))
        XCTAssertEqual(Set(body.keys), ["provisionalExternalDeviceId", "evidence"], "no user id in the body")
        XCTAssertEqual(body["provisionalExternalDeviceId"] as? String, "my-whoop")
        let evidence = try XCTUnwrap(body["evidence"] as? [String: Any])
        XCTAssertEqual(evidence["method"] as? String, "device_information_serial_v1")
        XCTAssertEqual(evidence["serial"] as? String, "MGB0214654")
        XCTAssertEqual((evidence["receiptSha256"] as? String)?.count, 64)
    }

    func testAConfirmationNamingAnotherAccountIsRefused() async {
        ReceiverStub.respond(status: 200, json: ["userId": stranger, "sourceId": source, "deviceId": "whoop-x",
                                                 "state": "confirmed"])
        await assertFails(.ownershipMismatch) {
            _ = try await self.client().confirmWearable(identity: self.identity(), provisionalExternalDeviceId: "my-whoop",
                                                        serial: "MGB0214654")
        }
    }

    func testAStrapAlreadyOwnedByAnotherAccountIsReportedNotRetried() async {
        ReceiverStub.respond(status: 409, json: ["code": "device_owner_conflict", "error": "taken"])
        do {
            _ = try await client().confirmWearable(identity: identity(), provisionalExternalDeviceId: "my-whoop",
                                                   serial: "MGB0214654")
            XCTFail("expected a refusal")
        } catch let error as CloudReceiverError {
            XCTAssertEqual(error, .rejected(code: "device_owner_conflict", status: 409))
            XCTAssertFalse(error.isTransient)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testARevokedCredentialOnConfirmationIsACredentialRejection() async {
        ReceiverStub.respond(status: 401, json: ["error": "unauthorized"])
        await assertFails(.credentialRejected) {
            _ = try await self.client().confirmWearable(identity: self.identity(), provisionalExternalDeviceId: "my-whoop",
                                                        serial: "MGB0214654")
        }
    }

    // MARK: helpers

    private func assertFails(_ expected: CloudReceiverError, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line,
                             _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("expected \(expected) \(message)", file: file, line: line)
        } catch let error as CloudReceiverError {
            XCTAssertEqual(error, expected, message, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error) \(message)", file: file, line: line)
        }
    }
}

/// Serves scripted answers to the receiver client and keeps what it was sent.
final class ReceiverStub: URLProtocol {
    private static let lock = NSLock()
    private static var _requests: [URLRequest] = []
    private static var _bodies: [Data] = []
    private static var answer: Answer = .failure(URLError(.badServerResponse))

    private enum Answer {
        case reply(status: Int, data: Data, headers: [String: String])
        case failure(Error)
    }

    static func reset() {
        lock.lock()
        _requests = []
        _bodies = []
        answer = .failure(URLError(.badServerResponse))
        lock.unlock()
    }

    static func respond(status: Int, json: [String: Any], retryAfter: TimeInterval? = nil) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        respond(status: status, data: data, retryAfter: retryAfter)
    }

    static func respond(status: Int, data: Data, retryAfter: TimeInterval? = nil) {
        var headers = ["Content-Type": "application/json"]
        if let retryAfter { headers["Retry-After"] = String(Int(retryAfter)) }
        lock.lock(); answer = .reply(status: status, data: data, headers: headers); lock.unlock()
    }

    static func fail(with error: Error) {
        lock.lock(); answer = .failure(error); lock.unlock()
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    static func jsonBody(of request: URLRequest) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let index = _requests.firstIndex(where: { $0.url == request.url }) else { return nil }
        return (try? JSONSerialization.jsonObject(with: _bodies[index])) as? [String: Any]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
        }
        Self.lock.lock()
        Self._requests.append(request)
        Self._bodies.append(body)
        let answer = Self.answer
        Self.lock.unlock()

        switch answer {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .reply(let status, let data, let headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
