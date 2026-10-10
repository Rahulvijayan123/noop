import XCTest
@testable import Strand

@MainActor
final class PersonalEventDetectionTests: XCTestCase {
    private let owner = "11111111-1111-4111-8111-111111111111"
    private let source = "33333333-3333-4333-8333-333333333333"
    private func identity(_ owner: String) -> CloudPushIdentity {
        CloudPushIdentity(ownerId: owner, sourceId: source, tokenId: UUID().uuidString, uploadToken: "noop_fixture")
    }
    func testRenameUsesTypeIdentityAndDoesNotJoinAnotherOwner() {
        var a = HealthEvent(id: "a", date: Date(), title: "Seizure", symbol: "tag", tone: .normal,
            origin: .reported, typeId: UUID(), ownerId: owner)
        var b = a; b.title = "Seizure / other"; XCTAssertTrue(a.hasSameType(as: b))
        b.ownerId = "other"; XCTAssertFalse(a.hasSameType(as: b))
        b = a; b.typeId = UUID(); XCTAssertFalse(a.hasSameType(as: b))
        a.typeId = nil; b.typeId = nil; XCTAssertFalse(a.hasSameType(as: b))
    }
    func testPhaseMeansUseObservedDurationAndLeaveGapsEmpty() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let metric = PhysiologyMetric(name: "Movement", unit: "g", points: [
            PhysiologyPoint(time: start, value: 1, supportSeconds: 10),
            PhysiologyPoint(time: start.addingTimeInterval(20), value: 3, supportSeconds: 30)])
        let physiology = EventPhysiology(metrics: [metric], windowStart: start.addingTimeInterval(-100),
            eventStart: start, eventEnd: start.addingTimeInterval(50), windowEnd: start.addingTimeInterval(100))
        let stats = EventPhaseStats(physiology: physiology, metric: metric)
        XCTAssertEqual(try XCTUnwrap(stats.mean(.during)), 2.5, accuracy: 0.0001)
        XCTAssertNil(stats.mean(.before)); XCTAssertNil(stats.mean(.after))
    }
    func testUnsupportedCloudRetainsDurableChoiceAcrossRestartAndAccounts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var current: CloudPushIdentity? = identity(owner)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DetectionURLProtocol.self]
        DetectionURLProtocol.handler = { _ in (405, Data()) }
        let center = EventDetectionCenter(directory: directory, session: URLSession(configuration: config), automaticallySync: false,
            syncManual: {}, identity: { current }, endpoint: { URL(string: "https://example.invalid/event-detection") })
        center.bindAccount(); let type = UUID()
        XCTAssertTrue(center.enqueue(EventDetectionCommand(action: "setting", typeId: type, enabled: true), expectedOwner: owner))
        await center.sync(); XCTAssertEqual(center.pending.count, 1)
        XCTAssertEqual(center.status(type), "Waiting to sync")
        XCTAssertTrue(center.message?.contains("not deployed") == true)
        current = identity("22222222-2222-4222-8222-222222222222"); center.bindAccount()
        XCTAssertTrue(center.pending.isEmpty); XCTAssertFalse(center.isEnabled(type))
        XCTAssertFalse(center.enqueue(EventDetectionCommand(action: "setting", typeId: type, enabled: false), expectedOwner: owner))
        current = identity(owner); center.bindAccount(); XCTAssertEqual(center.pending.count, 1)
        let reloaded = EventDetectionCenter(directory: directory, automaticallySync: false, syncManual: {}, identity: { current })
        reloaded.bindAccount(); XCTAssertEqual(reloaded.pending.first?.id, center.pending.first?.id)
    }
    func testWrongOwnerCannotAcknowledgePendingSetting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DetectionURLProtocol.self]
        let current = identity(owner)
        let command = EventDetectionCommand(action: "setting", typeId: UUID(), enabled: true)
        DetectionURLProtocol.handler = { _ in
            (200, try JSONSerialization.data(withJSONObject: ["saved": command.id.uuidString,
                "identity": ["userId": "22222222-2222-4222-8222-222222222222", "sourceId": self.source]]))
        }
        let center = EventDetectionCenter(directory: directory, session: URLSession(configuration: config), automaticallySync: false,
            syncManual: {}, identity: { current }, endpoint: { URL(string: "https://example.invalid/event-detection") })
        center.bindAccount(); XCTAssertTrue(center.enqueue(command, expectedOwner: owner))
        await center.sync(); XCTAssertEqual(center.pending.first?.id, command.id)
    }
}

private final class DetectionURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
