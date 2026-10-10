#if DEBUG
import SwiftUI
import StrandDesign

/// Isolated screenshot fixture. Every request is handled in memory; no cloud URL or credential is used.
struct PersonalEventDetectionDemo: View {
    var showDetail = false
    @StateObject private var manual: ManualEventCenter
    @StateObject private var detection: EventDetectionCenter
    init(showDetail: Bool = false) {
        self.showDetail = showDetail
        let identity = CloudPushIdentity(ownerId: "11111111-1111-4111-8111-111111111111",
            sourceId: "33333333-3333-4333-8333-333333333333", tokenId: "fixture", uploadToken: "fixture")
        let manual = ManualEventCenter(store: try! ManualEventStore(path: ":memory:"), automaticallySync: false,
            identity: { identity }, endpoint: { nil })
        manual.bindAccount()
        let type = manual.types.first { $0.label == "Walking" }!
        let now = Date().timeIntervalSince1970
        let event = ManualEventEntry(id: UUID(), kind: .event, label: type.label, symbol: type.symbol, typeId: type.id,
            startUnixSeconds: now - 900, endUnixSeconds: now - 600, note: "Walk after lunch",
            deviceId: "55555555-5555-4555-8555-555555555555")
        _ = manual.save(event, for: identity.ownerId)
        let types = manual.types
        let fixtureIdentity = ["userId": identity.ownerId, "sourceId": identity.sourceId]
        DetectionDemoProtocol.reply = { request in
            if request.url?.path.hasSuffix("physiology") == true {
                func points(_ value: (Double) -> Double, support: Int) -> [[String: Double]] {
                    stride(from: -2700, through: 0, by: support).map { i in
                        ["time": now + Double(i), "value": value(Double(i)), "support": Double(support)]
                    }
                }
                return ["identity": fixtureIdentity,
                    "heartRate": points({ 66 + ($0 > -900 && $0 < -600 ? 25 : 0) + 4 * sin($0 / 130) }, support: 60),
                    "hrv": points({ 46 + 6 * sin($0 / 400) }, support: 300),
                    "movement": points({ $0 > -900 && $0 < -600 ? 0.22 : 0.03 }, support: 4)]
            }
            return ["identity": fixtureIdentity, "settings": types.map { t -> [String: Any] in
                ["type_id": t.id.uuidString, "enabled": t.id == type.id, "revision": 1,
                 "state": t.id == type.id ? "active" : "off", "detail": ["reason": "Sample detector status"]]
            }, "detections": [["id": "66666666-6666-4666-8666-666666666666", "type_id": type.id.uuidString,
                "device_id": event.deviceId!, "start_at": now - 300, "end_at": now - 180,
                "model_id": "77777777-7777-4777-8777-777777777777", "status": "pending", "historical": false]],
                "negativeReviews": [], "next": NSNull()]
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DetectionDemoProtocol.self]
        let detection = EventDetectionCenter(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            session: URLSession(configuration: config), automaticallySync: false, syncManual: {},
            identity: { identity }, endpoint: { URL(string: "https://fixture.invalid/event-detection") })
        detection.bindAccount()
        _manual = StateObject(wrappedValue: manual); _detection = StateObject(wrappedValue: detection)
    }
    var body: some View {
        Group {
            if showDetail, let event = PersonalEventPresentation.events(manual: manual, detection: detection).first(where: { $0.origin == .reported }) {
                EventDetailView(event: event, detection: detection, manual: manual)
            } else {
                ScreenScaffold(title: "Events", trailing: { EmptyView() }) {
                    Text("Sample data · Layout preview").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    EventDetectionSection(manual: manual, detection: detection)
                }
            }
        }.task { await detection.sync() }
    }
}

private final class DetectionDemoProtocol: URLProtocol {
    static var reply: ((URLRequest) -> [String: Any])!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = try! JSONSerialization.data(withJSONObject: Self.reply(request))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
