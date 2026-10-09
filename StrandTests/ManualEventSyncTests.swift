import XCTest
@testable import Strand

@MainActor
final class ManualEventSyncTests: XCTestCase {
    private let owner = "11111111-1111-4111-8111-111111111111"
    private let source = "33333333-3333-4333-8333-333333333333"

    private func make() throws -> (ManualEventCenter, ManualEventStore, ManualEventEntry) {
        let store = try ManualEventStore(path: ":memory:")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ManualEventURLProtocol.self]
        let identity = CloudPushIdentity(ownerId: owner, sourceId: source, tokenId: UUID().uuidString, uploadToken: "noop_fixture")
        let center = ManualEventCenter(store: store, session: URLSession(configuration: config), automaticallySync: false,
            identity: { identity }, endpoint: { URL(string: "https://example.invalid/manual-events") })
        center.bindAccount()
        try store.markSynced(owner: owner, ids: store.pending(owner: owner).map(\.revisionId))
        let entry = ManualEventEntry(id: UUID(), kind: .event, label: "Walking", typeId: UUID(),
                                    startUnixSeconds: 1791000000, endUnixSeconds: 1791000300)
        XCTAssertTrue(center.save(entry, for: owner))
        return (center, store, entry)
    }

    private func page(identityOwner: String? = nil, revisions: [ManualEventRevision] = [], next: String = "0", more: Bool = false) throws -> Data {
        let revisionsJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(revisions))
        return try JSONSerialization.data(withJSONObject: ["revisions": revisionsJSON, "next": next, "has_more": more,
            "identity": ["userId": identityOwner ?? owner, "sourceId": source]])
    }

    func testMissingAckStaysPendingThenRetryUploadsSameUUID() async throws {
        let (center, store, entry) = try make()
        let emptyPage = try page()
        let ownIdentity = ["userId": owner, "sourceId": source]
        var uploadedIds: [[String]] = []
        ManualEventURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return (200, emptyPage) }
            let body = try JSONSerialization.jsonObject(with: ManualEventURLProtocol.body(request)) as! [String: Any]
            let revisions = body["revisions"] as! [[String: Any]]
            uploadedIds.append(revisions.map { $0["revision_id"] as! String })
            return (200, try JSONSerialization.data(withJSONObject: ["saved": [], "identity": ownIdentity]))
        }
        await center.syncNow()
        XCTAssertTrue(center.pendingIds.contains(entry.id))
        XCTAssertEqual(try store.pending(owner: owner).count, 1)
        ManualEventURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return (200, emptyPage) }
            let body = try JSONSerialization.jsonObject(with: ManualEventURLProtocol.body(request)) as! [String: Any]
            let revisions = body["revisions"] as! [[String: Any]]
            let ids = revisions.map { $0["revision_id"] as! String }
            uploadedIds.append(ids)
            return (200, try JSONSerialization.data(withJSONObject: ["saved": ids, "identity": ownIdentity]))
        }
        await center.syncNow()
        XCTAssertFalse(center.pendingIds.contains(entry.id))
        XCTAssertEqual(uploadedIds.count, 2); XCTAssertEqual(uploadedIds.first, uploadedIds.last)
    }

    func testReplyForAnotherOwnerCannotImportDataOrAcknowledgeWrites() async throws {
        let (center, store, entry) = try make()
        let wrongPage = try page(identityOwner: "22222222-2222-4222-8222-222222222222")
        ManualEventURLProtocol.handler = { _ in (200, wrongPage) }
        await center.syncNow()
        XCTAssertTrue(center.pendingIds.contains(entry.id))
        XCTAssertEqual(try store.cursor(owner: owner), "0")
    }

    func testUnsupportedServerRetainsPendingEventWithVisibleStatus() async throws {
        let (center, store, entry) = try make()
        ManualEventURLProtocol.handler = { _ in (405, Data()) }
        await center.syncNow()
        XCTAssertTrue(center.pendingIds.contains(entry.id))
        XCTAssertEqual(try store.pending(owner: owner).count, 1)
        XCTAssertTrue(center.syncMessage?.contains("not available yet") == true)
    }

    func testPullReadsAllPagesAndRetainsArchivedEntry() async throws {
        let (center, store, entry) = try make()
        let local = try XCTUnwrap(store.pending(owner: owner).first)
        var archive = entry; archive.archived = true; archive.archivedAt = 1791000400
        let remote = ManualEventRevision(revisionId: UUID(), updatedAtMs: local.updatedAtMs + 1, entry: archive)
        let first = try page(revisions: [local], next: "1", more: true)
        let second = try page(revisions: [remote], next: "2")
        var readCount = 0
        ManualEventURLProtocol.handler = { request in
            readCount += 1
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, request.url!.query == "after=0" ? first : second)
        }
        await center.syncNow()
        XCTAssertEqual(readCount, 2); XCTAssertEqual(try store.cursor(owner: owner), "2")
        XCTAssertTrue(center.events.isEmpty); XCTAssertEqual(center.archived.first?.id, entry.id)
        XCTAssertEqual(try store.history(owner: owner).filter { $0.entry.id == entry.id }.count, 2)
    }

    private func ack(saved: [String], rejected: [[String: String]] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["saved": saved, "rejected": rejected,
            "identity": ["userId": owner, "sourceId": source]])
    }

    private func revisionIds(_ request: URLRequest) throws -> [String] {
        let body = try JSONSerialization.jsonObject(with: ManualEventURLProtocol.body(request)) as! [String: Any]
        return (body["revisions"] as! [[String: Any]]).map { $0["revision_id"] as! String }
    }

    func testRefusedRevisionIsSetAsideAndNoLongerBlocksLaterEvents() async throws {
        let (center, store, entry) = try make()
        let emptyPage = try page()
        var later = ManualEventEntry(id: UUID(), kind: .event, label: "Walking", typeId: UUID(),
                                     startUnixSeconds: 1791000600, endUnixSeconds: 1791000900)
        XCTAssertTrue(center.save(later, for: owner))
        let refusedId = try XCTUnwrap(store.pending(owner: owner).first { $0.entry.id == entry.id }).revisionId
        ManualEventURLProtocol.handler = { [self] request in
            if request.httpMethod == "GET" { return (request.url!.path.hasSuffix("/context") ? 404 : 200, emptyPage) }
            let ids = try revisionIds(request)
            return (200, try ack(saved: ids.filter { $0 != refusedId.uuidString },
                                 rejected: [["revision_id": refusedId.uuidString, "reason": "revision_conflict"]]))
        }
        await center.syncNow()
        XCTAssertTrue(try store.pending(owner: owner).isEmpty, "the refusal must not keep the queue busy")
        XCTAssertEqual(center.rejected[entry.id], "revision_conflict")
        XCTAssertNil(center.rejected[later.id])
        XCTAssertEqual(try store.history(owner: owner).filter { $0.entry.id == entry.id }.count, 1, "refused revision is kept")
        // A later edit of the refused event is a new revision and is sent again.
        later.note = "edited"; XCTAssertTrue(center.save(later, for: owner))
        XCTAssertEqual(try store.pending(owner: owner).count, 1)
    }

    func testOlderServerWholeBatchRefusalIsIsolatedOneRevisionAtATime() async throws {
        let (center, store, entry) = try make()
        let good = ManualEventEntry(id: UUID(), kind: .event, label: "Rest", typeId: UUID(),
                                    startUnixSeconds: 1791000600, endUnixSeconds: 1791000900)
        XCTAssertTrue(center.save(good, for: owner))
        let badId = try XCTUnwrap(store.pending(owner: owner).first { $0.entry.id == entry.id }).revisionId.uuidString
        let emptyPage = try page()
        var batchSizes: [Int] = []
        ManualEventURLProtocol.handler = { [self] request in
            if request.httpMethod == "GET" { return (200, emptyPage) }
            let ids = try revisionIds(request)
            batchSizes.append(ids.count)
            // The part-1 server: any invalid revision fails the whole request, and replies name only `saved`.
            if ids.contains(badId) { return (400, Data("{\"error\":\"invalid_manual_events\"}".utf8)) }
            return (200, try JSONSerialization.data(withJSONObject: ["saved": ids, "identity": ["userId": owner, "sourceId": source]]))
        }
        await center.syncNow()
        XCTAssertEqual(batchSizes.first, 2); XCTAssertTrue(batchSizes.dropFirst().allSatisfy { $0 == 1 })
        XCTAssertTrue(try store.pending(owner: owner).isEmpty)
        XCTAssertEqual(center.rejected[entry.id], "http_400")
        XCTAssertNil(center.rejected[good.id]); XCTAssertFalse(center.pendingIds.contains(good.id))
    }

    func testContextIsFetchedForSyncedEventsCachedAndReadBackAfterReopen() async throws {
        let (center, store, entry) = try make()
        let revision = try XCTUnwrap(store.pending(owner: owner).first).revisionId
        let emptyPage = try page()
        var contextQueries: [String] = []
        let context: [String: Any] = [
            "version": "manual-event-context-1", "status": "ready", "final": true, "computed_at": 1791100000,
            "event": ["id": entry.id.uuidString.lowercased(), "revision_id": revision.uuidString.lowercased(),
                      "activity_kind": "walking", "start": 1791000000, "end": 1791000300, "point": false],
            "heart_rate": ["pre": ["n": 1800, "mean": 60], "during": ["n": 300, "mean": 110, "min": 100, "max": 120, "coverage": 1],
                           "trace": ["bin_s": 60, "bins": [[1791000000, 110, 100, 120, 60]]]],
            "comparisons": ["hr_during_minus_pre_bpm": 50, "hr_during_minus_resting_7d_bpm": 55],
            "activity": ["during": ["covered_s": 300, "coverage": 1, "classes": [["class": "walking", "seconds": 250, "confidence": 0.9],
                                                                                  ["class": "standing", "seconds": 50, "confidence": 0.6]]],
                         "agreement": ["status": "agrees", "activity_kind": "walking", "matched_share": 0.833]],
            "series": ["during": ["steps": ["value": 480], "hrv_rmssd_ms": ["value": 30]]],
            "baselines": ["resting_hr_7d": ["value": 55, "buckets": 300]],
            "projections": ["activity_ground_truth": ["status": "projected"]],
            "a_field_from_a_newer_server": ["x": 1]]
        ManualEventURLProtocol.handler = { [self] request in
            if request.httpMethod == "POST" { return (200, try ack(saved: try revisionIds(request))) }
            if request.url!.path.hasSuffix("/context") {
                contextQueries.append(request.url!.query ?? "")
                return (200, try JSONSerialization.data(withJSONObject: ["contexts": [context],
                    "identity": ["userId": owner, "sourceId": source]]))
            }
            return (200, emptyPage)
        }
        await center.syncNow()
        XCTAssertEqual(contextQueries, ["ids=\(entry.id.uuidString.lowercased())"])
        let loaded = try XCTUnwrap(center.contexts[entry.id])
        XCTAssertEqual(loaded.status, .ready); XCTAssertEqual(loaded.heartRate?.during?.mean, 110)
        XCTAssertEqual(loaded.dominantClass?.name, "walking"); XCTAssertEqual(loaded.dominantClass?.share ?? 0, 250.0 / 300, accuracy: 0.001)
        XCTAssertEqual(ManualEventFormat.summary(loaded), "HR 110 bpm · +50 bpm vs before · Walking 83%")
        XCTAssertEqual(ManualEventFormat.metricRows(loaded).map(\.0), ["HRV", "Steps"])
        // A final context is not asked for again; a fresh center reads it from the device.
        await center.syncNow()
        XCTAssertEqual(contextQueries.count, 1)
        let identity = CloudPushIdentity(ownerId: owner, sourceId: source, tokenId: UUID().uuidString, uploadToken: "noop_fixture")
        let reopened = ManualEventCenter(store: store, automaticallySync: false, identity: { identity }, endpoint: { nil })
        reopened.bindAccount()
        XCTAssertEqual(reopened.contexts[entry.id], loaded)
    }

    func testContextReplyForAnotherAccountIsIgnored() async throws {
        let (center, _, entry) = try make()
        let emptyPage = try page()
        ManualEventURLProtocol.handler = { [self] request in
            if request.httpMethod == "POST" { return (200, try ack(saved: try revisionIds(request))) }
            if request.url!.path.hasSuffix("/context") {
                return (200, try JSONSerialization.data(withJSONObject: ["contexts": [["status": "ready",
                    "event": ["id": entry.id.uuidString, "revision_id": UUID().uuidString]]],
                    "identity": ["userId": "22222222-2222-4222-8222-222222222222", "sourceId": source]]))
            }
            return (200, emptyPage)
        }
        await center.syncNow()
        XCTAssertTrue(center.contexts.isEmpty)
    }

    func testAFinalContextIsFetchedAgainAfterTheEventChanges() async throws {
        let (center, store, entry) = try make()
        let emptyPage = try page()
        var asked = 0
        ManualEventURLProtocol.handler = { [self] request in
            if request.httpMethod == "POST" { return (200, try ack(saved: try revisionIds(request))) }
            if request.url!.path.hasSuffix("/context") {
                asked += 1
                let current = try store.latestRevisionIds(owner: owner)[entry.id]!
                return (200, try JSONSerialization.data(withJSONObject: ["contexts": [[
                    "status": "ready", "final": true,
                    "event": ["id": entry.id.uuidString.lowercased(), "revision_id": current.uuidString.lowercased()]]],
                    "identity": ["userId": owner, "sourceId": source]]))
            }
            return (200, emptyPage)
        }
        await center.syncNow()
        XCTAssertEqual(asked, 1); XCTAssertTrue(center.staleContexts.isEmpty)
        var edited = try XCTUnwrap(center.events.first { $0.id == entry.id })
        edited.startUnixSeconds = 1791000060
        XCTAssertTrue(center.save(edited, for: owner))
        XCTAssertTrue(center.staleContexts.contains(entry.id), "the stored context describes the old times")
        await center.syncNow()
        XCTAssertEqual(asked, 2, "a final context of an older revision is asked for again")
        XCTAssertTrue(center.staleContexts.isEmpty)
    }

    func testOneCloudRevisionTheAppCannotStoreDoesNotStopTheSync() async throws {
        let (center, store, entry) = try make()
        let local = try XCTUnwrap(store.pending(owner: owner).first)
        var clash = entry; clash.label = "Different"
        let conflicting = ManualEventRevision(revisionId: local.revisionId, updatedAtMs: local.updatedAtMs, entry: clash)
        let remote = ManualEventEntry(id: UUID(), kind: .event, label: "Rest", typeId: UUID(),
                                      startUnixSeconds: 1791001000, endUnixSeconds: 1791001600)
        let good = ManualEventRevision(revisionId: UUID(), updatedAtMs: local.updatedAtMs + 5, entry: remote)
        let pageData = try page(revisions: [conflicting, good], next: "2")
        var posted = 0
        ManualEventURLProtocol.handler = { [self] request in
            if request.httpMethod == "POST" { posted += 1; return (200, try ack(saved: try revisionIds(request))) }
            return (request.url!.path.hasSuffix("/context") ? 404 : 200, pageData)
        }
        await center.syncNow()
        XCTAssertTrue(center.events.contains { $0.id == remote.id }, "the good revision is stored")
        XCTAssertEqual(center.events.first { $0.id == entry.id }?.label, "Walking", "the local revision is kept")
        XCTAssertEqual(try store.cursor(owner: owner), "2")
        XCTAssertEqual(posted, 1); XCTAssertTrue(try store.pending(owner: owner).isEmpty)
    }

    override func tearDown() { ManualEventURLProtocol.handler = nil; super.tearDown() }
}

private final class ManualEventURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.cannotConnectToHost) }
            let (status, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n))
        }
        return data
    }
}
