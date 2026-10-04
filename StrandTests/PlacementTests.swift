import XCTest
import Foundation
import WhoopStore
import WhoopProtocol
@testable import Strand

/// A transport stub that records the request and answers a canned response, so the real
/// PlacementCloudSync request path runs with no network.
private final class PlacementStub: URLProtocol {
    static var status = 200
    static var body: [String: Any] = [:]
    static var requests: [URLRequest] = []
    static var requestBodies: [Data] = []
    static var responseData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // URLSession delivers the body via httpBodyStream, not httpBody; capture it here so the
        // test can assert on what was actually sent.
        PlacementStub.requestBodies.append(Self.bodyData(of: request))
        PlacementStub.requests.append(request)
        let data = PlacementStub.body.isEmpty
            ? PlacementStub.responseData
            : ((try? JSONSerialization.data(withJSONObject: PlacementStub.body)) ?? Data())
        let http = HTTPURLResponse(url: request.url!, statusCode: PlacementStub.status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var out = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read <= 0 { break }
            out.append(buffer, count: read)
        }
        return out
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlacementStub.self]
        return URLSession(configuration: config)
    }
}

/// G4 manual placement baseline: effective-dated interval folding, corrections, offline journaling,
/// GRDB persistence, five-minute eligibility flags, and the authenticated upload path. The pure
/// logic tests mirror `set_placement_interval` exactly (same correction semantics, no backfill).
final class PlacementTests: XCTestCase {

    private func day(_ offset: Int = 0) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + Double(offset * 86_400))
    }

    private func store() async throws -> (WhoopStore, PlacementStore) {
        let whoop = try await WhoopStore.inMemory()
        let placement = try PlacementStore(dbQueue: whoop.registryWriter)
        return (whoop, placement)
    }

    // MARK: - Pure interval folding

    func testFirstDeclarationIsOpenAndHistoryBeforeItIsUnknown() {
        let t1 = day()
        let (result, changed) = PlacementIntervals.applying([], set: .wrist, at: t1,
                                                            deviceId: "my-whoop", nextRevision: 1)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(changed?.placement, .wrist)
        XCTAssertEqual(changed?.effectiveStart, t1)
        XCTAssertNil(changed?.effectiveEnd, "a fresh declaration is open-ended")
        XCTAssertEqual(changed?.revision, 1)
        // Unannotated history stays UNKNOWN — never backfilled.
        XCTAssertNil(PlacementIntervals.active(result, at: t1.addingTimeInterval(-1), deviceId: "my-whoop"))
        // Half-open: the interval does NOT contain its own end (none here), and contains its start.
        XCTAssertEqual(PlacementIntervals.active(result, at: t1, deviceId: "my-whoop")?.placement, .wrist)
    }

    func testCorrectionClosesOverlappingIntervalAndBumpsRevision() {
        let t1 = day()
        let t2 = day().addingTimeInterval(3600)
        let first = PlacementIntervals.applying([], set: .wrist, at: t1, deviceId: "my-whoop", nextRevision: 1)
        let second = PlacementIntervals.applying(first.intervals, set: .bicep, at: t2,
                                                 deviceId: "my-whoop", nextRevision: 2)
        XCTAssertEqual(second.intervals.count, 2)
        let sorted = second.intervals.sorted { $0.effectiveStart < $1.effectiveStart }
        XCTAssertEqual(sorted[0].placement, .wrist)
        XCTAssertEqual(sorted[0].effectiveEnd, t2, "the overlapping interval is closed at the correction")
        XCTAssertEqual(sorted[1].placement, .bicep)
        XCTAssertNil(sorted[1].effectiveEnd)
        XCTAssertEqual(sorted[1].revision, 2)
        // Half-open boundary: t2 belongs to the new interval, not the old one.
        XCTAssertEqual(PlacementIntervals.active(second.intervals, at: t2, deviceId: "my-whoop")?.placement, .bicep)
        XCTAssertEqual(PlacementIntervals.active(second.intervals, at: t2.addingTimeInterval(-1), deviceId: "my-whoop")?.placement, .wrist)
    }

    func testDeviceScopingNeverTouchesAnotherDevice() {
        let t1 = day()
        let wrist = PlacementIntervals.applying([], set: .wrist, at: t1, deviceId: "whoop-A", nextRevision: 1)
        let bicep = PlacementIntervals.applying(wrist.intervals, set: .bicep, at: t1.addingTimeInterval(600),
                                                deviceId: "whoop-B", nextRevision: 2)
        XCTAssertEqual(bicep.intervals.count, 2)
        let a = bicep.intervals.filter { $0.deviceId == "whoop-A" }
        let b = bicep.intervals.filter { $0.deviceId == "whoop-B" }
        XCTAssertEqual(a.count, 1)
        XCTAssertNil(a[0].effectiveEnd, "device A's open interval is untouched by device B's change")
        XCTAssertEqual(b[0].placement, .bicep)
    }

    func testSameStartDeclarationReplacesInPlace() {
        let t1 = day()
        let first = PlacementIntervals.applying([], set: .wrist, at: t1, deviceId: "my-whoop", nextRevision: 1)
        let replaced = PlacementIntervals.applying(first.intervals, set: .other, at: t1,
                                                   deviceId: "my-whoop", nextRevision: 2)
        XCTAssertEqual(replaced.intervals.count, 1, "same-start declaration replaces, never duplicates")
        XCTAssertEqual(replaced.intervals[0].placement, .other)
        XCTAssertEqual(replaced.intervals[0].revision, 2)
        XCTAssertNil(replaced.intervals[0].effectiveEnd)
    }

    func testFutureDatedIntervalCapsTheNewDeclaration() {
        let t1 = day()
        let future = day().addingTimeInterval(7200)
        // A future-dated declaration exists (only possible via a server pull in practice).
        let base = PlacementIntervals.applying([], set: .bicep, at: future, deviceId: "my-whoop", nextRevision: 1)
        let now = PlacementIntervals.applying(base.intervals, set: .wrist, at: t1,
                                              deviceId: "my-whoop", nextRevision: 2)
        XCTAssertEqual(now.intervals.count, 2)
        let sorted = now.intervals.sorted { $0.effectiveStart < $1.effectiveStart }
        XCTAssertEqual(sorted[0].placement, .wrist)
        XCTAssertEqual(sorted[0].effectiveEnd, future, "the new interval is capped at the next interval")
        XCTAssertEqual(sorted[1].placement, .bicep, "the future-dated interval is never overwritten")
        XCTAssertNil(sorted[1].effectiveEnd)
    }

    func testRevisionIsMonotonicPerOwner() {
        let t1 = day()
        let t2 = day().addingTimeInterval(600)
        let first = PlacementIntervals.applying([], set: .wrist, at: t1, deviceId: "my-whoop", nextRevision: 1)
        let second = PlacementIntervals.applying(first.intervals, set: .bicep, at: t2,
                                                 deviceId: "my-whoop", nextRevision: 2)
        let third = PlacementIntervals.applying(second.intervals, set: .other, at: t2.addingTimeInterval(600),
                                                deviceId: "my-whoop", nextRevision: 3)
        XCTAssertEqual(third.intervals.map(\.revision).max(), 3)
    }

    // MARK: - Wear-state reconstruction

    func testWearReconstructionSimpleFlip() {
        let spans = WearStateSpans.reconstruct(events: [
            (ts: 100, kind: "WRIST_OFF(10)"),
            (ts: 200, kind: "WRIST_ON(9)"),
        ], from: 0, to: 300)
        XCTAssertEqual(spans, [
            WearStateSpans.Span(start: 100, end: 200, state: .off),
            WearStateSpans.Span(start: 200, end: 300, state: .on),
        ])
    }

    func testWearReconstructionCoalescesDuplicatesAndSorts() {
        let spans = WearStateSpans.reconstruct(events: [
            (ts: 150, kind: "WRIST_OFF(10)"),   // out of order: sorts after 100
            (ts: 100, kind: "WRIST_OFF(10)"),   // duplicate OFF while already off
            (ts: 50, kind: "WRIST_ON(9)"),
            (ts: 300, kind: "WRIST_ON(9)"),     // duplicate ON while already on
        ], from: 0, to: 400)
        XCTAssertEqual(spans, [
            WearStateSpans.Span(start: 50, end: 100, state: .on),
            WearStateSpans.Span(start: 100, end: 300, state: .off),
            WearStateSpans.Span(start: 300, end: 400, state: .on),
        ])
    }

    func testWearReconstructionOpenTailAndUnknownGaps() {
        // No events at all → no spans → UNKNOWN (never a guessed state).
        XCTAssertTrue(WearStateSpans.reconstruct(events: [], from: 0, to: 300).isEmpty)
        // A single WRIST_OFF extends to `to` (evidence-backed off-body tail).
        XCTAssertEqual(WearStateSpans.reconstruct(events: [(ts: 100, kind: "WRIST_OFF(10)")], from: 0, to: 300),
                       [WearStateSpans.Span(start: 100, end: 300, state: .off)])
        // Gap before the first event and after the last is UNKNOWN (no span).
        let spans = WearStateSpans.reconstruct(events: [
            (ts: 100, kind: "WRIST_OFF(10)"),
            (ts: 200, kind: "WRIST_ON(9)"),
        ], from: 0, to: 300)
        XCTAssertEqual(spans.map(\.state), [.off, .on])
        XCTAssertEqual(spans[0].start, 100, "the pre-event gap is not painted")
    }

    func testWearReconstructionExcludesPreWindowEvents() {
        let spans = WearStateSpans.reconstruct(events: [
            (ts: 50, kind: "WRIST_OFF(10)"),    // before `from`: must NOT paint the window start
            (ts: 200, kind: "WRIST_ON(9)"),
        ], from: 100, to: 300)
        XCTAssertEqual(spans, [WearStateSpans.Span(start: 200, end: 300, state: .on)])
    }

    // MARK: - PlacementStore (GRDB)

    func testStorePersistsIntervalsAndJournalOffline() async throws {
        let (_, placement) = try await store()
        let t1 = day()
        let t2 = day().addingTimeInterval(3600)
        try placement.setCurrent(.wrist, deviceId: "my-whoop", at: t1)
        try placement.setCurrent(.bicep, deviceId: "my-whoop", at: t2)

        let intervals = try placement.intervals(deviceId: "my-whoop")
        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(intervals.map(\.placement), [.wrist, .bicep])
        XCTAssertEqual(intervals[0].effectiveEnd, t2)

        XCTAssertEqual(try placement.activePlacement(at: t2, deviceId: "my-whoop")?.placement, .bicep)
        // Unannotated history before the first declaration is UNKNOWN.
        XCTAssertNil(try placement.activePlacement(at: t1.addingTimeInterval(-60), deviceId: "my-whoop"))

        let pending = try placement.pendingChanges()
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending.map(\.placement), [.wrist, .bicep])
        XCTAssertEqual(pending[0].effectiveStart, t1, "offline changes keep their original effective time")
        XCTAssertFalse(pending[0].synced)
    }

    func testStoreMarkSyncedAndReconcile() async throws {
        let (_, placement) = try await store()
        let t1 = day()
        let (change, _) = try placement.setCurrent(.wrist, deviceId: "my-whoop", at: t1)
        XCTAssertEqual(try placement.pendingChanges().count, 1)
        try placement.markSynced(ids: [change.id])
        XCTAssertTrue(try placement.pendingChanges().isEmpty)

        // Reconcile from a "server" pull replaces the local model for the device.
        let server = [
            PlacementInterval(deviceId: "my-whoop", placement: .bicep,
                              effectiveStart: t1, effectiveEnd: nil, revision: 5),
        ]
        try placement.replaceIntervals(server, deviceId: "my-whoop")
        XCTAssertEqual(try placement.activePlacement(at: t1, deviceId: "my-whoop")?.placement, .bicep)
        XCTAssertEqual(try placement.activePlacement(at: t1, deviceId: "my-whoop")?.revision, 5)
    }

    func testStoreDeviceScopeIsSeparate() async throws {
        let (_, placement) = try await store()
        let t1 = day()
        try placement.setCurrent(.wrist, deviceId: "whoop-A", at: t1)
        try placement.setCurrent(.bicep, deviceId: "whoop-B", at: t1.addingTimeInterval(600))
        XCTAssertEqual(try placement.intervals(deviceId: "whoop-A").count, 1)
        XCTAssertEqual(try placement.intervals(deviceId: "whoop-B").count, 1)
        XCTAssertEqual(try placement.activePlacement(at: t1.addingTimeInterval(300), deviceId: "whoop-A")?.placement, .wrist)
        XCTAssertEqual(try placement.activePlacement(at: t1.addingTimeInterval(900), deviceId: "whoop-B")?.placement, .bicep)
        // Device-scoped changes never bleed across: whoop-B's declaration leaves whoop-A untouched.
        XCTAssertEqual(try placement.activePlacement(at: t1.addingTimeInterval(900), deviceId: "whoop-A")?.placement, .wrist)
        XCTAssertNil(try placement.activePlacement(at: t1.addingTimeInterval(300), deviceId: "whoop-B"), "no interval yet for whoop-B before its declaration")
    }

    // MARK: - Five-minute eligibility flags

    func testEligibilityUnknownWhereUnannotated() {
        let e = IntradayEligibility.flag(
            windowStart: day(1), windowEnd: day(1).addingTimeInterval(300),
            placementIntervals: [], wearEvents: [])
        XCTAssertEqual(e.placement, .unknown)
        XCTAssertEqual(e.wear, .unknown)
        XCTAssertFalse(e.mixed)
    }

    func testEligibilityPlacementFromIntervals() {
        let t1 = day(1)
        let intervals = [PlacementInterval(deviceId: "my-whoop", placement: .wrist,
                                           effectiveStart: t1, effectiveEnd: nil)]
        let e = IntradayEligibility.flag(
            windowStart: t1.addingTimeInterval(60), windowEnd: t1.addingTimeInterval(360),
            placementIntervals: intervals, wearEvents: [])
        XCTAssertEqual(e.placement, .wrist)
        XCTAssertFalse(e.mixed)
    }

    func testEligibilityMixedPlacementWithinWindow() {
        let t1 = day(1)
        let t2 = t1.addingTimeInterval(150)   // change lands INSIDE the 300-s window
        let intervals = [
            PlacementInterval(deviceId: "my-whoop", placement: .wrist, effectiveStart: t1, effectiveEnd: t2),
            PlacementInterval(deviceId: "my-whoop", placement: .bicep, effectiveStart: t2, effectiveEnd: nil),
        ]
        let e = IntradayEligibility.flag(
            windowStart: t1, windowEnd: t1.addingTimeInterval(300),
            placementIntervals: intervals, wearEvents: [])
        XCTAssertEqual(e.placement, .unknown, "a mixed window never gets a guessed stable label")
        XCTAssertTrue(e.mixed)
    }

    func testEligibilityWearStates() {
        let t1 = day(1)
        let start = Int(t1.timeIntervalSince1970)
        // A fully covered worn window (event exactly at the window start → no leading gap).
        let worn = IntradayEligibility.flag(
            windowStart: t1, windowEnd: t1.addingTimeInterval(300),
            placementIntervals: [], wearEvents: [(ts: start, kind: "WRIST_ON(9)")])
        XCTAssertEqual(worn.wear, .worn)
        XCTAssertFalse(worn.wearMixed)
        // Fully covered off-body window.
        let off = IntradayEligibility.flag(
            windowStart: t1, windowEnd: t1.addingTimeInterval(300),
            placementIntervals: [], wearEvents: [(ts: start, kind: "WRIST_OFF(10)")])
        XCTAssertEqual(off.wear, .offBody)
        XCTAssertFalse(off.wearMixed)
        // F3: an event INSIDE the window leaves an un-evidenced leading portion → mixed (no label).
        let lateOn = IntradayEligibility.flag(
            windowStart: t1, windowEnd: t1.addingTimeInterval(300),
            placementIntervals: [], wearEvents: [(ts: start + 299, kind: "WRIST_ON(9)")])
        XCTAssertEqual(lateOn.wear, .unknown, "a window with an un-evidenced leading portion gets no stable label")
        XCTAssertTrue(lateOn.wearMixed, "partial coverage is a mid-window change")
        // State change inside the window → mixed, no stable label.
        let mixed = IntradayEligibility.flag(
            windowStart: t1, windowEnd: t1.addingTimeInterval(300),
            placementIntervals: [],
            wearEvents: [(ts: start, kind: "WRIST_OFF(10)"),
                         (ts: start + 120, kind: "WRIST_ON(9)")])
        XCTAssertEqual(mixed.wear, .unknown)
        XCTAssertTrue(mixed.mixed)
        XCTAssertTrue(mixed.wearMixed)
        XCTAssertFalse(mixed.placementMixed)
    }

    func testEligibilityPlacementPartialCoverageIsMixed() {
        let t1 = day(1)
        // Interval starts mid-window: leading portion is UNKNOWN → mixed, no label.
        let intervals = [PlacementInterval(deviceId: "my-whoop", placement: .wrist,
                                           effectiveStart: t1.addingTimeInterval(150), effectiveEnd: nil)]
        let e = IntradayEligibility.flag(
            windowStart: t1, windowEnd: t1.addingTimeInterval(300),
            placementIntervals: intervals, wearEvents: [])
        XCTAssertEqual(e.placement, .unknown)
        XCTAssertTrue(e.placementMixed)
        XCTAssertFalse(e.wearMixed)
        // Interval ends mid-window: trailing portion UNKNOWN → mixed too.
        let trailing = [PlacementInterval(deviceId: "my-whoop", placement: .wrist,
                                          effectiveStart: t1, effectiveEnd: t1.addingTimeInterval(150))]
        let e2 = IntradayEligibility.flag(
            windowStart: t1, windowEnd: t1.addingTimeInterval(300),
            placementIntervals: trailing, wearEvents: [])
        XCTAssertEqual(e2.placement, .unknown)
        XCTAssertTrue(e2.placementMixed)
    }

    // MARK: - Additive wire fields

    func testPointParsesAdditiveEligibilityFields() {
        let window = IntradaySeriesWindow(envelope: [
            "from": 100, "to": 400, "bucket_seconds": 300,
            "metrics": [
                "hrv_rmssd_ms": [[100, 42.0, 60, 1.0, 0.1, "wrist", "on_wrist", true]],
            ],
        ])
        let point = window?.points(.hrv).first
        XCTAssertEqual(point?.value, 42.0)
        XCTAssertEqual(point?.placement, .wrist)
        XCTAssertEqual(point?.wear, .worn)
        XCTAssertEqual(point?.mixed, true)
    }

    func testPointIgnoresLegacyRowsWithoutEligibility() {
        // Pre-G4 server rows are [ts, value, samples, coverage, motion] — flags must be nil.
        let window = IntradaySeriesWindow(envelope: [
            "from": 100, "to": 400, "bucket_seconds": 300,
            "metrics": [
                "hrv_rmssd_ms": [[100, 42.0, 60, 1.0, 0.1]],
            ],
        ])
        let point = window?.points(.hrv).first
        XCTAssertEqual(point?.placement, nil)
        XCTAssertEqual(point?.wear, nil)
        XCTAssertEqual(point?.mixed, nil)
    }

    // MARK: - Sync (same authenticated route pattern)

    func testPushPendingUploadsInOrderAndMarksSynced() async throws {
        PlacementStub.status = 200
        PlacementStub.body = [:]
        PlacementStub.requests = []
        PlacementStub.requestBodies = []
        let (_, placement) = try await store()
        let t1 = day()
        try placement.setCurrent(.wrist, deviceId: "my-whoop", at: t1)
        try placement.setCurrent(.bicep, deviceId: "my-whoop", at: t1.addingTimeInterval(3600))

        let sync = PlacementCloudSync(
            session: PlacementStub.session(),
            endpoint: { URL(string: "https://example.invalid/functions/v1/scores")! },
            identity: { CloudPushIdentity(ownerId: "11111111-1111-4111-8111-111111111111",
                                          sourceId: "22222222-2222-4222-8222-222222222222",
                                          tokenId: "t", uploadToken: "noop_x") },
            store: { placement })
        let uploaded = try await sync.pushPending()
        XCTAssertEqual(uploaded, 2)
        XCTAssertTrue(try placement.pendingChanges().isEmpty)
        XCTAssertEqual(PlacementStub.requests.count, 2)
        for (index, req) in PlacementStub.requests.enumerated() {
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer noop_x")
            XCTAssertNil(req.value(forHTTPHeaderField: "x-noop-fleet-token"),
                         "an Auth-provisioned credential needs no shared fleet token")
            XCTAssertEqual(req.httpMethod, "POST")
            let bodyData = index < PlacementStub.requestBodies.count ? PlacementStub.requestBodies[index] : Data()
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            XCTAssertNotNil(body?["placement"])
            XCTAssertNotNil(body?["effective_start"])
            XCTAssertEqual(body?["effective_start"] as? String,
                           PlacementCloudSync.isoUTC(index == 0 ? t1 : t1.addingTimeInterval(3600)))
        }
    }

    func testPushFailureLeavesRowsUnsynced() async throws {
        PlacementStub.status = 500
        PlacementStub.body = [:]
        PlacementStub.requests = []
        PlacementStub.requestBodies = []
        let (_, placement) = try await store()
        try placement.setCurrent(.wrist, deviceId: "my-whoop", at: day())

        let sync = PlacementCloudSync(
            session: PlacementStub.session(),
            endpoint: { URL(string: "https://example.invalid/functions/v1/scores")! },
            identity: { CloudPushIdentity(ownerId: "11111111-1111-4111-8111-111111111111",
                                          sourceId: "22222222-2222-4222-8222-222222222222",
                                          tokenId: "t", uploadToken: "noop_x") },
            store: { placement })
        do {
            _ = try await sync.pushPending()
            XCTFail("expected serverRejected")
        } catch PlacementSyncError.serverRejected {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(try placement.pendingChanges().count, 1, "a failed upload is retried, never dropped")
    }

    // MARK: - Consumer context surface (F2/F4)

    private func point(_ start: Int) -> IntradaySeriesPoint {
        IntradaySeriesPoint(start: start, value: 42, samples: 60, coverage: 1.0, motion: 0)
    }

    func testContextEmptyWithoutPointsOrEvidence() {
        let context = IntradaySeriesContextBuilder.summarize(
            points: [], width: 300, placementIntervals: [], wearEvents: [], contactSamples: [])
        XCTAssertFalse(context.hasAny)
        XCTAssertTrue(context.lines.isEmpty)
    }

    func testContextWearUnknownWhenNoEvidence() {
        let t1 = Int(day(1).timeIntervalSince1970)
        let points = [point(t1), point(t1 + 300)]
        let context = IntradaySeriesContextBuilder.summarize(
            points: points, width: 300, placementIntervals: [], wearEvents: [], contactSamples: [])
        XCTAssertEqual(context.wearLine, "Wear unknown")
        XCTAssertNil(context.placementLine, "no placement evidence → no guessed placement line")
        XCTAssertNil(context.contactLine, "no contact evidence → no contact line")
    }

    func testContextWornAndWristWhenRangeWidelyEvidenced() {
        let t1 = Int(day(1).timeIntervalSince1970)
        // WRIST_ON before the first point covers the whole range (no OFF).
        let points = [point(t1), point(t1 + 300), point(t1 + 600)]
        let intervals = [PlacementInterval(deviceId: "my-whoop", placement: .wrist,
                                           effectiveStart: day(1), effectiveEnd: nil)]
        let context = IntradaySeriesContextBuilder.summarize(
            points: points, width: 300, placementIntervals: intervals,
            wearEvents: [(ts: t1, kind: "WRIST_ON(9)")], contactSamples: [])
        XCTAssertEqual(context.wearLine, "Worn")
        XCTAssertEqual(context.placementLine, "Wrist")
    }

    func testContextMixedPlacementWithinWindow() {
        let t1 = Int(day(1).timeIntervalSince1970)
        let t2 = t1 + 150
        let points = [point(t1)]
        let intervals = [
            PlacementInterval(deviceId: "my-whoop", placement: .wrist,
                              effectiveStart: Date(timeIntervalSince1970: TimeInterval(t1)),
                              effectiveEnd: Date(timeIntervalSince1970: TimeInterval(t2))),
            PlacementInterval(deviceId: "my-whoop", placement: .bicep,
                              effectiveStart: Date(timeIntervalSince1970: TimeInterval(t2)),
                              effectiveEnd: nil),
        ]
        let context = IntradaySeriesContextBuilder.summarize(
            points: points, width: 300, placementIntervals: intervals, wearEvents: [], contactSamples: [])
        XCTAssertEqual(context.placementLine, "Mixed placement in this window")
    }

    func testContextWearVariesWhenKnownAndUnknownPointsMix() {
        let t1 = Int(day(1).timeIntervalSince1970)
        // First point before any event → unknown; later points covered by an ON → worn.
        let points = [point(t1), point(t1 + 300)]
        let context = IntradaySeriesContextBuilder.summarize(
            points: points, width: 300, placementIntervals: [],
            wearEvents: [(ts: t1 + 300, kind: "WRIST_ON(9)")], contactSamples: [])
        XCTAssertEqual(context.wearLine, "Wear varies", "a mix of known and unknown points never gets one guessed label")
    }

    func testContextWearChangedWithinWindow() {
        let t1 = Int(day(1).timeIntervalSince1970)
        let points = [point(t1)]
        // OFF at window start, ON 120 s in → the bucket transitions off→on → mixed.
        let context = IntradaySeriesContextBuilder.summarize(
            points: points, width: 300, placementIntervals: [],
            wearEvents: [(ts: t1, kind: "WRIST_OFF(10)"), (ts: t1 + 120, kind: "WRIST_ON(9)")],
            contactSamples: [])
        XCTAssertEqual(context.wearLine, "Wear changed in this window")
    }

    func testContextContactStateWhenCarried() {
        let t1 = Int(day(1).timeIntervalSince1970)
        let points = [point(t1)]
        let contact = [(ts: t1 + 10, state: ContactEligibility.good)]
        let context = IntradaySeriesContextBuilder.summarize(
            points: points, width: 300, placementIntervals: [], wearEvents: [], contactSamples: contact)
        XCTAssertEqual(context.contactLine, "Contact good")
        // Poor contact.
        let poor = IntradaySeriesContextBuilder.summarize(
            points: points, width: 300, placementIntervals: [], wearEvents: [],
            contactSamples: [(ts: t1 + 10, state: .poor)])
        XCTAssertEqual(poor.contactLine, "Contact poor")
        // Unsupported sensor.
        let unsupported = IntradaySeriesContextBuilder.summarize(
            points: points, width: 300, placementIntervals: [], wearEvents: [],
            contactSamples: [(ts: t1 + 10, state: .unsupported)])
        XCTAssertEqual(unsupported.contactLine, "Contact not supported")
        // No contact in range → no line.
        let none = IntradaySeriesContextBuilder.summarize(
            points: points, width: 300, placementIntervals: [], wearEvents: [], contactSamples: [])
        XCTAssertNil(none.contactLine)
    }

    func testContextServerPublishedFlagsWinPerPoint() {
        let t1 = Int(day(1).timeIntervalSince1970)
        // A server-published point with placement=wrist, wear=on_wrist, mixed=false.
        let published = IntradaySeriesPoint(start: t1, value: 42, samples: 60, coverage: 1.0, motion: 0,
                                            placement: .wrist, wear: .worn, mixed: false)
        let context = IntradaySeriesContextBuilder.summarize(
            points: [published], width: 300, placementIntervals: [], wearEvents: [], contactSamples: [])
        XCTAssertEqual(context.placementLine, "Wrist")
        XCTAssertEqual(context.wearLine, "Worn")
    }

    func testContextServerMixedFlagsBothDimensionsConservatively() {
        let t1 = Int(day(1).timeIntervalSince1970)
        let published = IntradaySeriesPoint(start: t1, value: 42, samples: 60, coverage: 1.0, motion: 0,
                                            placement: .bicep, wear: .unknown, mixed: true)
        let context = IntradaySeriesContextBuilder.summarize(
            points: [published], width: 300, placementIntervals: [], wearEvents: [], contactSamples: [])
        XCTAssertEqual(context.placementLine, "Mixed placement in this window")
        XCTAssertEqual(context.wearLine, "Wear changed in this window")
    }

    // MARK: - F7 tie-break at equal timestamps

    func testWearReconstructionTieBreakOffBeforeOnAtEqualTs() {
        // An OFF+ON pair at the SAME second: the OFF sorts first, so the ON wins and the tail is worn
        // (matches AnalyticsEngine.offWristIntervals: OFF opens, ON closes, zero-length skipped).
        let spans = WearStateSpans.reconstruct(events: [
            (ts: 100, kind: "WRIST_ON(9)"),
            (ts: 100, kind: "WRIST_OFF(10)"),
        ], from: 0, to: 300)
        XCTAssertEqual(spans, [WearStateSpans.Span(start: 100, end: 300, state: .on)])
    }

}
