import XCTest
@testable import Strand

private final class ProbeStub: URLProtocol {
    static var status = 200
    static var body: [String: Any] = ["days": [], "next_cursor": 0]
    static var failure: URLError?
    static var requests: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        ProbeStub.requests.append(request.url!)
        if let failure = ProbeStub.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let data = (try? JSONSerialization.data(withJSONObject: ProbeStub.body)) ?? Data()
        let http = HTTPURLResponse(url: request.url!, statusCode: ProbeStub.status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func reset() {
        status = 200
        body = ["days": [], "next_cursor": 0]
        failure = nil
        requests = []
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProbeStub.self]
        return URLSession(configuration: config)
    }
}

/// Asking the server whether the signed-in account already holds a strap.
///
/// This answer decides whether a strap's saved days are discarded, so it has to tell "no, this account has no
/// such strap" apart from "I could not ask", and it must not disturb the change feed the app reads from.
final class HistoryProbeTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-history-probe-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ProbeStub.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func repository() -> ServerScoreRepository {
        ServerScoreRepository(
            session: ProbeStub.session(),
            endpoint: URL(string: "https://example.invalid/functions/v1/scores")!,
            directory: directory,
            identity: { CloudPushIdentity(ownerId: "11111111-1111-4111-8111-111111111111",
                                          sourceId: "22222222-2222-4222-8222-222222222222",
                                          tokenId: "t", uploadToken: "noop_x") })
    }

    func testARegisteredDeviceIsHeldEvenWhenItHasNoResultsYet() async throws {
        let held = try await repository().holdsDevice("whoop-MGB0214654")
        XCTAssertTrue(held)
    }

    func testTheQuestionIsStatelessAndCheap() async throws {
        _ = try await repository().holdsDevice("whoop-MGB0214654")
        let items = URLComponents(url: try XCTUnwrap(ProbeStub.requests.first), resolvingAgainstBaseURL: false)?.queryItems ?? []
        let names = Set(items.map(\.name))
        XCTAssertEqual(items.first(where: { $0.name == "deviceId" })?.value, "whoop-MGB0214654")
        XCTAssertEqual(items.first(where: { $0.name == "limit" })?.value, "1")
        XCTAssertFalse(names.contains("cursor"), "it must not read from, or move, the app's change cursor")
        XCTAssertFalse(names.contains("scopeRevision"))
        XCTAssertTrue(try XCTUnwrap(ProbeStub.requests.first).path.hasSuffix("/days"))
    }

    func testTheServerSayingThereIsNoSuchDeviceIsADefiniteNo() async throws {
        ProbeStub.status = 409
        ProbeStub.body = ["error": "device_registration_pending"]
        let held = try await repository().holdsDevice("whoop-MGB0214654")
        XCTAssertFalse(held)
    }

    func testAnyOtherFailureIsAnErrorAndNeverANo() async {
        for status in [401, 403, 409, 429, 500, 503] {
            ProbeStub.reset()
            ProbeStub.status = status
            ProbeStub.body = ["error": status == 409 ? "something_else" : "nope"]
            do {
                _ = try await repository().holdsDevice("whoop-MGB0214654")
                XCTFail("HTTP \(status) is not an answer about the strap")
            } catch {
                // expected: the caller reads a thrown error as "could not ask" and waits
            }
        }
    }

    func testAnOfflinePhoneCannotAnswerAndSaysSo() async {
        ProbeStub.failure = URLError(.notConnectedToInternet)
        do {
            _ = try await repository().holdsDevice("whoop-MGB0214654")
            XCTFail("no connection must not read as 'the account has no such strap'")
        } catch {
            // expected
        }
    }
}
