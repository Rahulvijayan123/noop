import XCTest
@testable import Strand

/// A transport stub that answers per `deviceId`, so the repository's real request, parse and cache path runs
/// with no network and the tests can see which ids it was asked about.
private final class DeviceRoutingStub: URLProtocol {
    static var routes: [String: (status: Int, body: [String: Any])] = [:]
    static var asked: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let device = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "deviceId" })?.value ?? ""
        DeviceRoutingStub.asked.append(device)
        let route = DeviceRoutingStub.routes[device] ?? (status: 404, body: [:])
        let data = (try? JSONSerialization.data(withJSONObject: route.body)) ?? Data()
        let http = HTTPURLResponse(url: request.url!, statusCode: route.status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeviceRoutingStub.self]
        return URLSession(configuration: config)
    }
}

/// Which device id the cloud path files a strap under, and reads its results from.
///
/// The field failure these pin: the strap's earlier days sat on the server under its own `whoop-<serial>`
/// device while a reinstalled app uploaded and read only its throwaway `installation:…:my-whoop` one, so
/// yesterday and the days before it were stored, scored and published but never asked for.
final class CloudDeviceIdentityTests: XCTestCase {

    private let serial = "MGB0214654"

    // MARK: id translation

    func testLegacySeedWithAKnownSerialFilesUnderTheStrapsOwnDevice() {
        XCTAssertEqual(CloudDeviceIdentity.cloudId(localId: "my-whoop", serial: serial), "whoop-MGB0214654")
    }

    func testTheSerialIsNormalisedAndTheSeedMatchedCaseInsensitively() {
        XCTAssertEqual(CloudDeviceIdentity.cloudId(localId: "My-Whoop", serial: "  mgb0214654 \n"),
                       "whoop-MGB0214654")
    }

    func testASerialThatCannotIdentifyAStrapLeavesTheIdAlone() {
        for bad in [nil, "", "   ", "ABC", "MGB 0214654", "MGB/0214654", "unknown device"] as [String?] {
            XCTAssertEqual(CloudDeviceIdentity.cloudId(localId: "my-whoop", serial: bad), "my-whoop",
                           "serial \(String(describing: bad)) must not produce a canonical id")
        }
    }

    func testOnlyTheLegacySeedIsTranslated() {
        // A `whoop-<…>` id already is, or adopts, the strap's own id through the registry; any other source is
        // not a WHOOP at all.
        XCTAssertEqual(CloudDeviceIdentity.cloudId(localId: "whoop-ABCDEF123", serial: serial), "whoop-ABCDEF123")
        XCTAssertEqual(CloudDeviceIdentity.cloudId(localId: "whoop-1B2C3D4E-0000-4000-8000-000000000000",
                                                   serial: serial),
                       "whoop-1B2C3D4E-0000-4000-8000-000000000000")
        XCTAssertEqual(CloudDeviceIdentity.cloudId(localId: "oura-ring", serial: serial), "oura-ring")
    }

    func testReadCandidatesLeadWithTheStrapAndKeepTheLocalIdAsAFallback() {
        XCTAssertEqual(CloudDeviceIdentity.readCandidates(localId: "my-whoop", serial: serial),
                       ["whoop-MGB0214654", "my-whoop"])
        XCTAssertEqual(CloudDeviceIdentity.readCandidates(localId: "my-whoop", serial: nil), ["my-whoop"])
        XCTAssertEqual(CloudDeviceIdentity.readCandidates(localId: "whoop-ABCDEF123", serial: serial),
                       ["whoop-ABCDEF123"], "an id that is already the strap's own is not asked twice")
    }

    // MARK: remembered serial

    private func freshDefaults() -> UserDefaults {
        let suite = "noop.tests.cloud-strap-serial.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testTheFirstSerialIsLearnedAndSurvivesARelaunch() {
        let defaults = freshDefaults()
        let store = CloudStrapSerialStore(defaults: defaults)
        XCTAssertEqual(store.cloudId(forLocalId: "my-whoop"), "my-whoop", "nothing is known before the strap connects")

        XCTAssertEqual(store.record(serial: serial, forLocalId: "my-whoop"), .learned)
        XCTAssertEqual(store.cloudId(forLocalId: "my-whoop"), "whoop-MGB0214654")
        XCTAssertEqual(store.readCandidates(forLocalId: "my-whoop"), ["whoop-MGB0214654", "my-whoop"])

        // The serial arrives over BLE only after a connection, but uploads start before the strap reconnects.
        let relaunched = CloudStrapSerialStore(defaults: defaults)
        XCTAssertEqual(relaunched.cloudId(forLocalId: "my-whoop"), "whoop-MGB0214654")
    }

    func testTheSameSerialAgainIsANoOpEvenWhenWrittenDifferently() {
        let store = CloudStrapSerialStore(defaults: freshDefaults())
        store.record(serial: serial, forLocalId: "my-whoop")
        XCTAssertEqual(store.record(serial: serial, forLocalId: "my-whoop"), .unchanged)
        XCTAssertEqual(store.record(serial: " mgb0214654 ", forLocalId: "MY-WHOOP"), .unchanged)
        XCTAssertFalse(store.hasReplacedStrap(forLocalId: "my-whoop"))
    }

    func testADifferentStrapInTheSameSlotIsReportedAndKeptApart() {
        let store = CloudStrapSerialStore(defaults: freshDefaults())
        store.record(serial: serial, forLocalId: "my-whoop")
        XCTAssertEqual(store.record(serial: "MGB9999999", forLocalId: "my-whoop"), .replaced(previous: serial))
        XCTAssertEqual(store.cloudId(forLocalId: "my-whoop"), "whoop-MGB9999999")
        XCTAssertTrue(store.hasReplacedStrap(forLocalId: "my-whoop"),
                      "rows banked for the earlier strap must never be replayed under the new one")
    }

    func testAnUnusableSerialIsNeverStored() {
        let store = CloudStrapSerialStore(defaults: freshDefaults())
        for bad in ["", "ABC", "MGB 0214654", "not a serial"] {
            XCTAssertEqual(store.record(serial: bad, forLocalId: "my-whoop"), .unchanged)
        }
        XCTAssertNil(store.serial(forLocalId: "my-whoop"))
        XCTAssertEqual(store.cloudId(forLocalId: "my-whoop"), "my-whoop")
    }

    func testForgettingAStrapReturnsTheSlotToItsLocalId() {
        let defaults = freshDefaults()
        let store = CloudStrapSerialStore(defaults: defaults)
        store.record(serial: serial, forLocalId: "my-whoop")
        store.record(serial: "MGB9999999", forLocalId: "my-whoop")
        store.forget(localId: "my-whoop")
        XCTAssertEqual(store.cloudId(forLocalId: "my-whoop"), "my-whoop")
        XCTAssertFalse(store.hasReplacedStrap(forLocalId: "my-whoop"))
        XCTAssertEqual(CloudStrapSerialStore(defaults: defaults).cloudId(forLocalId: "my-whoop"), "my-whoop")
    }

    // MARK: reading a day from the first device that has it

    private func result(_ revision: String = "r1") -> HostedDayResult {
        HostedDayResult(day: "2026-10-03", object: ["daily": [String: Any](), "result_revision": revision])!
    }

    func testTheFirstCandidateWithAResultWinsAndStopsTheSearch() async {
        var asked: [String] = []
        let outcome = await HostedDayRead.read(day: "2026-10-03", candidates: ["whoop-A1B2C3", "my-whoop"]) { id in
            asked.append(id)
            return self.result()
        }
        XCTAssertEqual(asked, ["whoop-A1B2C3"])
        XCTAssertEqual(outcome.servedBy, "whoop-A1B2C3")
        XCTAssertNotNil(outcome.result)
    }

    func testAnEmptyOrFailingCandidateFallsThroughToTheNext() async {
        let outcome = await HostedDayRead.read(day: "2026-10-03", candidates: ["a", "b", "c"]) { id in
            switch id {
            case "a": return nil
            case "b": throw ServerScoreRepository.ReadError.http(409, "{\"error\":\"device_registration_pending\"}")
            default: return self.result()
            }
        }
        XCTAssertEqual(outcome.servedBy, "c")
        XCTAssertEqual(outcome.attempts.map { $0.attempt }, [.noResult, .failed("http-409"), .result])
    }

    func testADayNobodyHasIsReportedWithEveryAttempt() async {
        let outcome = await HostedDayRead.read(day: "2026-10-03", candidates: ["a", "b"]) { id in
            if id == "b" { throw URLError(.timedOut) }
            return nil
        }
        XCTAssertNil(outcome.result)
        XCTAssertNil(outcome.servedBy)
        XCTAssertEqual(outcome.attempts.map { $0.attempt }, [.noResult, .failed("network-1001")])
        XCTAssertEqual(outcome.failureTokens, ["network-1001"])
    }

    func testFailureTokensNeverCarryABodyAnIdOrASerial() {
        let leaky = ServerScoreRepository.ReadError.http(500, "device whoop-MGB0214654 for rahul@example.com")
        let token = HostedDayRead.failureToken(for: leaky)
        XCTAssertEqual(token, "http-500")
        XCTAssertFalse(token.contains("MGB"))
        XCTAssertEqual(HostedDayRead.failureToken(for: ServerScoreRepository.ReadError.missingIdentity), "no-identity")
        XCTAssertEqual(HostedDayRead.failureToken(for: ServerScoreRepository.ReadError.malformed("whoop-MGB0214654")),
                       "malformed")
        XCTAssertEqual(HostedDayRead.failureToken(for: CancellationError()), "cancelled")
        XCTAssertEqual(HostedDayRead.failureToken(for: NSError(domain: "x", code: 1)), "error")
    }

    // MARK: sync summary

    private func outcome(_ day: String, _ attempts: [HostedDayRead.Attempt]) -> HostedDayRead.Outcome {
        let ids = ["whoop-A1B2C3", "my-whoop"]
        let paired = attempts.enumerated().map { (deviceId: ids[$0.offset], attempt: $0.element) }
        let served = paired.first { $0.attempt == .result }?.deviceId
        return HostedDayRead.Outcome(day: day, result: served == nil ? nil : result(), servedBy: served,
                                     attempts: paired)
    }

    func testAnUneventfulPassSaysNothing() {
        let outcomes = [outcome("2026-10-02", [.result]), outcome("2026-10-03", [.result])]
        XCTAssertNil(HostedDayRead.summaryLine(outcomes: outcomes, written: 0, candidateCount: 2))
    }

    func testAPassThatStoredDaysSaysSo() {
        let outcomes = [outcome("2026-10-02", [.result]), outcome("2026-10-03", [.result])]
        let line = HostedDayRead.summaryLine(outcomes: outcomes, written: 2, candidateCount: 2)
        XCTAssertEqual(line, "Cloud: server results — 2/2 day(s) available · 2 stored · asked 2 ids")
    }

    func testDaysThatCameFromTheFallbackAndDaysThatCouldNotBeReadAreNamed() {
        let outcomes = [
            outcome("2026-10-01", [.noResult, .result]),
            outcome("2026-10-02", [.result]),
            outcome("2026-10-03", [.failed("http-409"), .failed("http-409")]),
            outcome("2026-10-04", [.noResult, .noResult]),
        ]
        let line = HostedDayRead.summaryLine(outcomes: outcomes, written: 0, candidateCount: 2)
        XCTAssertEqual(line, "Cloud: server results — 2/4 day(s) available · 1 from the installation id · "
            + "1 with no result · 1 unreadable (http-409×1) · asked 2 ids")
        XCTAssertFalse(line?.contains("MGB") ?? true)
    }

    // MARK: the screens' multi-id read

    private let owner = "11111111-1111-4111-8111-111111111111"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-device-identity-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DeviceRoutingStub.routes = [:]
        DeviceRoutingStub.asked = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func repository() -> ServerScoreRepository {
        ServerScoreRepository(
            session: DeviceRoutingStub.session(),
            endpoint: URL(string: "https://example.invalid/functions/v1/scores")!,
            directory: directory,
            identity: { CloudPushIdentity(ownerId: self.owner, sourceId: "22222222-2222-4222-8222-222222222222",
                                          tokenId: "t", uploadToken: "noop_x") })
    }

    private func populated(_ revision: String) -> [String: Any] {
        ["server_scoring": ["day": "2026-10-03", "result_revision": revision,
                            "daily": ["recovery": 71], "hosted_snapshot": [
                                "result_revision": revision, "daily": ["recovery": 71]]]]
    }

    func testTheRepositoryReadsTheStrapsDeviceFirstAndStopsThere() async throws {
        DeviceRoutingStub.routes = ["whoop-MGB0214654": (200, populated("canonical")),
                                    "my-whoop": (200, populated("installation"))]
        let snapshot = try await repository().refresh(day: "2026-10-03", deviceIds: ["whoop-MGB0214654", "my-whoop"])
        XCTAssertEqual(snapshot.deviceId, "whoop-MGB0214654")
        XCTAssertEqual(snapshot.resultRevision, "canonical")
        XCTAssertEqual(DeviceRoutingStub.asked, ["whoop-MGB0214654"])
    }

    func testTheRepositoryFallsBackWhenTheStrapsDeviceHasNothingYet() async throws {
        // The strap's own device exists but is empty for the day; the installation's device holds it.
        DeviceRoutingStub.routes = ["whoop-MGB0214654": (200, ["server_scoring": ["day": "2026-10-03"]]),
                                    "my-whoop": (200, populated("installation"))]
        let snapshot = try await repository().refresh(day: "2026-10-03", deviceIds: ["whoop-MGB0214654", "my-whoop"])
        XCTAssertEqual(snapshot.deviceId, "my-whoop")
        XCTAssertEqual(snapshot.status, .populated)
        XCTAssertEqual(DeviceRoutingStub.asked, ["whoop-MGB0214654", "my-whoop"])
    }

    func testTheRepositoryFallsBackWhenTheStrapsDeviceIsNotRegisteredYet() async throws {
        DeviceRoutingStub.routes = ["whoop-MGB0214654": (409, ["error": "device_registration_pending"]),
                                    "my-whoop": (200, populated("installation"))]
        let snapshot = try await repository().refresh(day: "2026-10-03", deviceIds: ["whoop-MGB0214654", "my-whoop"])
        XCTAssertEqual(snapshot.deviceId, "my-whoop")
    }

    func testWhenNoCandidateAnswersTheFailureIsNotSwallowed() async {
        DeviceRoutingStub.routes = [:]
        do {
            _ = try await repository().refresh(day: "2026-10-03", deviceIds: ["whoop-MGB0214654", "my-whoop"])
            XCTFail("a day nobody could serve must not look like a success")
        } catch let error as ServerScoreRepository.ReadError {
            guard case .http(404, _) = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTheCachedDayIsFoundUnderWhicheverIdWroteIt() async throws {
        DeviceRoutingStub.routes = ["my-whoop": (200, populated("installation"))]
        let repo = repository()
        try await repo.refresh(day: "2026-10-03", deviceId: "my-whoop")
        let cached = await repo.cachedDay(day: "2026-10-03", deviceIds: ["whoop-MGB0214654", "my-whoop"])
        XCTAssertEqual(cached?.deviceId, "my-whoop")
        let none = await repo.cachedDay(day: "2026-10-04", deviceIds: ["whoop-MGB0214654", "my-whoop"])
        XCTAssertNil(none)
    }
}
