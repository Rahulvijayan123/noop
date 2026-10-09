import XCTest
@testable import Strand

/// The phone's side of the supplemental sensor-biomarker documents (spec-31 §8/§9, CONTRACTS §1/§2/§6):
/// parsing what the server publishes, the (owner, device, day) cache, the bounded retry, the flag,
/// and the compact rendering decisions. The numbers themselves are the server's; nothing here computes one.
final class SensorBiomarkerTests: XCTestCase {

    private let ownerA = "11111111-1111-4111-8111-111111111111"
    private let ownerB = "99999999-9999-4999-8999-999999999999"
    private let source = "22222222-2222-4222-8222-222222222222"
    private let day = "2026-10-06"

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-sensor-biomarkers-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        BiomarkerStub.body = [:]
        BiomarkerStub.rawData = nil
        BiomarkerStub.status = 200
        BiomarkerStub.statuses = []
        BiomarkerStub.requests = []
        SensorBiomarkerFeature.setEnabled(false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        SensorBiomarkerFeature.setEnabled(false)
    }

    // MARK: - Settings page days

    func testSettingsPageStepsUtcDays() {
        // 2026-10-07 02:30 UTC is still Oct 6 in the US; the server's day key is the UTC one.
        let now = Date(timeIntervalSince1970: 1_791_340_200)
        XCTAssertEqual(SensorBiomarkersView.day(daysBack: 0, now: now), "2026-10-07")
        XCTAssertEqual(SensorBiomarkersView.day(daysBack: 1, now: now), "2026-10-06")
        XCTAssertEqual(SensorBiomarkersView.day(daysBack: 7, now: now), "2026-09-30")
    }

    // MARK: - Fixtures

    private func identity(owner: String? = nil) -> CloudPushIdentity {
        CloudPushIdentity(ownerId: owner ?? ownerA, sourceId: source, tokenId: "t", uploadToken: "noop_x")
    }

    private func repository(owner: String? = nil, session: URLSession? = nil,
                            directory: URL? = nil, maxRetries: Int = 2) -> SensorBiomarkerRepository {
        SensorBiomarkerRepository(
            session: session ?? BiomarkerStub.session(),
            endpoint: URL(string: "https://example.invalid/functions/v1/scores")!,
            directory: directory ?? self.directory,
            identity: { self.identity(owner: owner) },
            maxRetries: maxRetries,
            retryDelay: { _ in 0 },
            sleep: { _ in })
    }

    private func measurement(_ value: Any, unit: String? = nil, denominator: String? = nil,
                             count: Int? = nil, nativeRate: Double? = nil,
                             configuration: String? = nil) -> [String: Any] {
        var dict: [String: Any] = ["value": value]
        if let unit { dict["unit"] = unit }
        if let denominator { dict["denominator"] = denominator }
        if let count { dict["count"] = count }
        if let nativeRate { dict["native_rate_hz"] = nativeRate }
        if let configuration { dict["configuration"] = configuration }
        return dict
    }

    private func family(status: String, observed: Double? = 3600, eligible: Double? = 3600,
                        reason: String? = nil, nativeRate: Double? = nil, configuration: String? = nil,
                        measurements: [String: Any] = [:]) -> [String: Any] {
        var dict: [String: Any] = [
            "status": status,
            "release_tier": "descriptive",
            "provider_revision": "imu-biomarkers/1.0.0",
        ]
        if let observed { dict["observed_seconds"] = observed }
        if let eligible { dict["eligible_seconds"] = eligible }
        if let reason { dict["reason"] = reason }
        if let nativeRate { dict["native_rate_hz"] = nativeRate }
        if let configuration { dict["configuration"] = configuration }
        if !measurements.isEmpty { dict["measurements"] = measurements }
        return dict
    }

    private func document(day: String = "2026-10-06",
                          start: String = "2026-10-06T00:00:00Z",
                          end: String = "2026-10-07T00:00:00Z",
                          families: [String: Any]) -> [String: Any] {
        [
            "schema_version": 1,
            "analysis_version": "sensor-biomarkers/1.0.0",
            "input_revision": "sha256:abc123",
            "interval_start_utc": start,
            "interval_end_utc": end,
            "processed_at_utc": "2026-10-07T00:05:00Z",
            "families": families,
        ]
    }

    /// The REAL edge-route envelope (serverScores.ts readSensorBiomarkers, pinned by
    /// supabase/functions/tests/sensor_biomarkers_route_test.ts): one row per stored day,
    /// the row's `document` is the day document, and the requested day absent is an HTTP 404.
    private func routeBody(_ doc: [String: Any], day: String = "2026-10-06") -> [String: Any] {
        [
            "days": [[
                "day": day,
                "analysis_version": "sensor-biomarkers/1.0.0",
                "input_revision": "sha256:\(String(repeating: "a", count: 64))",
                "interval_start_utc": "\(day)T00:00:00Z",
                "interval_end_utc": "2026-10-07T00:00:00Z",
                "status": "completed",
                "families_ok": ["movement", "oscillation"],
                "withheld_reasons": [] as [String],
                "run_ms": 1200,
                "published_at": "\(day)T01:00:00Z",
                "updated_at": "\(day)T01:00:00Z",
                "document": doc,
            ]],
            "identity": [
                "user_id": ownerA,
                "source_id": source,
                "device_ids": [ownerA: "my-whoop"],
            ] as [String: Any],
        ]
    }

    /// The four descriptive families with representative values (independent of the implementation).
    private func fullDocument() -> [String: Any] {
        document(families: [
            "movement": family(status: "ok", measurements: [
                "enmo_median_mg": measurement(12.5, unit: "mg", denominator: "valid 5s epochs", count: 17280),
                "enmo_p95_mg": measurement(85.0, unit: "mg"),
                "low_movement_bout_count": measurement(14),
                "low_movement_bout_median_seconds": measurement(260, unit: "s"),
                "low_movement_bout_max_seconds": measurement(1560, unit: "s"),
                "low_to_moving_transitions_per_observed_hour": measurement(3.2, unit: "transitions/hour"),
                "low_movement_fraction": measurement(0.42, denominator: "classified observed time"),
            ]),
            "oscillation": family(status: "ok", measurements: [
                "wrist_oscillation_power_3_7hz_median": measurement(0.31, unit: "(deg/s)^2"),
                "wrist_oscillation_power_3_7hz_p95": measurement(0.9, unit: "(deg/s)^2"),
            ]),
            "ppg_quality": family(status: "ok", measurements: [
                "template_similarity_median": measurement(0.87),
                "template_similarity_p25": measurement(0.81),
                "valid_waveform_fraction": measurement(0.94),
            ]),
            "pulse_shape": family(status: "ok", nativeRate: 25, configuration: "cfg-1", measurements: [
                "pulse_width50_median_ms": measurement(380, unit: "ms"),
                "pulse_width50_iqr_ms": measurement(92, unit: "ms"),
                "pulse_accepted_count": measurement(1234),
                "pulse_rejected_count": measurement(56),
            ]),
        ])
    }

    private func parse(_ envelope: [String: Any]) throws -> SensorBiomarkerDocument? {
        try SensorBiomarkerRepository.parse(day: day, deviceId: "my-whoop",
                                            envelope: ["sensor_biomarkers": envelope], fetchedAtMs: 0)
    }

    // MARK: - Feature flag

    func testFeatureFlagKeyAndDefaultOn() {
        XCTAssertEqual(SensorBiomarkerFeature.enabledKey, "noop.sensorBiomarkersEnabled")
        let previous = UserDefaults.standard.object(forKey: SensorBiomarkerFeature.enabledKey)
        defer { UserDefaults.standard.set(previous, forKey: SensorBiomarkerFeature.enabledKey) }
        UserDefaults.standard.removeObject(forKey: SensorBiomarkerFeature.enabledKey)
        XCTAssertTrue(SensorBiomarkerFeature.isEnabled, "the flag must be ON by default")
        SensorBiomarkerFeature.setEnabled(false)
        XCTAssertFalse(SensorBiomarkerFeature.isEnabled, "turning it off must store false")
        SensorBiomarkerFeature.setEnabled(true)
        XCTAssertTrue(SensorBiomarkerFeature.isEnabled)
    }

    // MARK: - Parsing

    func testParsesAValidDocument() throws {
        let parsed = try XCTUnwrap(parse(fullDocument()))
        XCTAssertEqual(parsed.day, day)
        XCTAssertEqual(parsed.schemaVersion, 1)
        XCTAssertEqual(parsed.analysisVersion, "sensor-biomarkers/1.0.0")
        XCTAssertEqual(parsed.inputRevision, "sha256:abc123")
        XCTAssertEqual(parsed.intervalStartUTC, "2026-10-06T00:00:00Z")
        XCTAssertEqual(parsed.intervalEndUTC, "2026-10-07T00:00:00Z")

        let movement = try XCTUnwrap(parsed.families["movement"])
        XCTAssertEqual(movement.status, "ok")
        XCTAssertTrue(movement.isUsable)
        XCTAssertEqual(movement.observedSeconds, 3600)
        XCTAssertEqual(movement.eligibleSeconds, 3600)
        let enmo = try XCTUnwrap(movement.measurements["enmo_median_mg"])
        XCTAssertEqual(enmo.value ?? 0, 12.5, accuracy: 1e-9)
        XCTAssertEqual(enmo.unit, "mg")
        XCTAssertEqual(enmo.denominator, "valid 5s epochs")
        XCTAssertEqual(enmo.count, 17280)

        let pulse = try XCTUnwrap(parsed.families["pulse_shape"])
        let width = try XCTUnwrap(pulse.measurements["pulse_width50_median_ms"])
        XCTAssertEqual(width.value ?? 0, 380, accuracy: 1e-9)
        XCTAssertEqual(width.unit, "ms")
        XCTAssertEqual(width.nativeRateHz, 25, "the family's native rate decorates its measurements")
        XCTAssertEqual(width.configuration, "cfg-1")
    }

    func testNullDocumentIsNoDataNotAnError() throws {
        let parsed = try SensorBiomarkerRepository.parse(
            day: day, deviceId: "my-whoop", envelope: ["sensor_biomarkers": NSNull()], fetchedAtMs: 0)
        XCTAssertNil(parsed, "an explicit null is a no-data state, never an error")
    }

    func testNullMeasurementValueIsAnAbsenceNotAZero() throws {
        let doc = document(families: [
            "movement": family(status: "ok", measurements: [
                "enmo_median_mg": measurement(NSNull()),
            ]),
        ])
        let parsed = try XCTUnwrap(parse(doc))
        let median = try XCTUnwrap(parsed.families["movement"]?.measurements["enmo_median_mg"])
        XCTAssertNil(median.value, "a null value must stay absent, never become a fabricated zero")
    }

    func testMalformedEnvelopesAreRejected() {
        XCTAssertThrowsError(try SensorBiomarkerRepository.parse(day: day, deviceId: "my-whoop",
                                                                 envelope: [:], fetchedAtMs: 0))
        XCTAssertThrowsError(try SensorBiomarkerRepository.parse(day: day, deviceId: "my-whoop",
                                                                 envelope: ["sensor_biomarkers": "garbage"], fetchedAtMs: 0))
        // A document object without families is malformed.
        XCTAssertThrowsError(try SensorBiomarkerRepository.parse(day: day, deviceId: "my-whoop",
                                                                 envelope: ["sensor_biomarkers": ["schema_version": 1]], fetchedAtMs: 0))
    }

    func testAnOversizedDocumentIsRejected() throws {
        // A denominator string large enough that the document exceeds the 256 KiB budget.
        let blob = String(repeating: "x", count: 300 * 1024)
        let doc = document(families: [
            "movement": family(status: "ok", measurements: [
                "enmo_median_mg": measurement(12.5, unit: "mg", denominator: blob),
            ]),
        ])
        do {
            _ = try parse(doc)
            XCTFail("an oversized document must be rejected")
        } catch let error as SensorBiomarkerRepository.ReadError {
            guard case .oversized = error else {
                return XCTFail("expected an oversized rejection, got \(error)")
            }
        }
    }

    func testOneBadFamilyDoesNotCostTheRest() throws {
        let doc = document(families: [
            "movement": family(status: "ok", measurements: [
                "enmo_median_mg": measurement(12.5, unit: "mg"),
            ]),
            "oscillation": "not a family object",
        ])
        let parsed = try XCTUnwrap(parse(doc))
        XCTAssertNotNil(parsed.families["movement"], "a valid family survives a malformed sibling")
        XCTAssertNil(parsed.families["oscillation"])
    }

    func testRefreshTreatsTheRoutes404AsNoDataNeverAnError() async throws {
        // The route 404s when the requested day has no stored document (serverScores.ts):
        // the refresh must settle as "no data" - one request, no retry, no failed state.
        BiomarkerStub.status = 404
        let repo = repository()
        let fetched = try await repo.refresh(day: day, deviceId: "my-whoop")
        XCTAssertNil(fetched)
        XCTAssertEqual(BiomarkerStub.requests.count, 1, "a 404 is never retried")
    }

    func testParseAcceptsTheExactRouteWireFixture() throws {
        // CROSS-LAYER FIXTURE: the exact row JSON the route test (supabase/functions/tests/
        // sensor_biomarkers_route_test.ts docRow) serves, character-for-character in shape:
        // { days: [ { day, analysis_version, ..., document: { ... } } ], identity }.
        let documentJSON: [String: Any] = [
            "schema_version": 1,
            "analysis_version": "sensor-biomarkers/1.0.0",
            "input_revision": "sha256:" + String(repeating: "a", count: 64),
            "interval_start_utc": "2026-10-06T00:00:00Z",
            "interval_end_utc": "2026-10-07T00:00:00Z",
            "processed_at_utc": "2026-10-06T01:00:00Z",
            "families": [
                "movement": [
                    "status": "ok", "release_tier": "descriptive",
                    "provider_revision": "imu-biomarkers/1.0.0",
                    "observed_seconds": 3600, "eligible_seconds": 3000,
                    "contact_state": "on_wrist",
                    "measurements": ["enmo_median_mg": ["value": 12.5, "unit": "mg"]],
                    "reason_counts": [:],
                ],
                "tremor": [
                    "status": "withheld", "release_tier": "research",
                    "provider_revision": "paradigma/1.0.0",
                    "reason": "unknown_wrist_placement",
                    "measurements": [:], "reason_counts": [:],
                ],
            ],
        ]
        let row: [String: Any] = [
            "day": "2026-10-06",
            "analysis_version": "sensor-biomarkers/1.0.0",
            "input_revision": "sha256:" + String(repeating: "a", count: 64),
            "interval_start_utc": "2026-10-06T00:00:00Z",
            "interval_end_utc": "2026-10-07T00:00:00Z",
            "status": "completed",
            "families_ok": ["movement"],
            "withheld_reasons": [] as [String],
            "run_ms": 1200,
            "model_revisions": ["movement": "imu-biomarkers/1.0.0"],
            "published_at": "2026-10-06T01:00:00Z",
            "updated_at": "2026-10-06T01:00:00Z",
            "document": documentJSON,
        ]
        let envelope: [String: Any] = ["days": [row], "identity": ["user_id": ownerA]]
        let parsed = try XCTUnwrap(SensorBiomarkerRepository.parse(
            day: "2026-10-06", deviceId: "my-whoop", envelope: envelope, fetchedAtMs: 0))
        XCTAssertEqual(parsed.analysisVersion, "sensor-biomarkers/1.0.0")
        XCTAssertEqual(parsed.families["movement"]?.measurements["enmo_median_mg"]?.value as? Double, 12.5)
        XCTAssertEqual(parsed.families["tremor"]?.reason, "unknown_wrist_placement")

        // A days envelope without the requested day is a no-data answer, not an error.
        let otherDay = routeBody(documentJSON, day: "2026-10-05")
        XCTAssertNil(try SensorBiomarkerRepository.parse(
            day: "2026-10-06", deviceId: "my-whoop", envelope: otherDay, fetchedAtMs: 0))
        // A days row without a document is malformed.
        XCTAssertThrowsError(try SensorBiomarkerRepository.parse(
            day: "2026-10-06", deviceId: "my-whoop",
            envelope: ["days": [["day": "2026-10-06"]]], fetchedAtMs: 0))
    }

    // MARK: - Fetch + cache

    func testRefreshBuildsTheRouteAuthenticatesParsesAndCaches() async throws {
        BiomarkerStub.body = ["sensor_biomarkers": fullDocument(),
                              "identity": ["userId": ownerA, "sourceId": source]]
        let repo = repository()
        let fetched = try await repo.refresh(day: day, deviceId: "my-whoop")
        let result = try XCTUnwrap(fetched)

        XCTAssertEqual(result.families.count, 4)
        XCTAssertEqual(result.deviceId, "my-whoop")

        let request = try XCTUnwrap(BiomarkerStub.requests.first)
        let url = try XCTUnwrap(request.url)
        XCTAssertTrue(url.path.hasSuffix("/scores/sensor-biomarkers"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
        XCTAssertEqual(query["day"], day)
        XCTAssertEqual(query["deviceId"], "my-whoop")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer noop_x",
                       "the read uses the same installation credential as every other score read")

        // The same document comes back from the cache with no network (fetchedAtMs differs by design:
        // the cache stamps when the read happened, a network read stamps 0).
        BiomarkerStub.status = 500   // a cached read must not touch the network
        let cached = await repo.cachedDay(day: day, deviceId: "my-whoop")
        let cachedDoc = try XCTUnwrap(cached)
        XCTAssertEqual(cachedDoc.families, result.families)
        XCTAssertEqual(cachedDoc.rawJSON, result.rawJSON)
        XCTAssertEqual(cachedDoc.day, result.day)
        XCTAssertEqual(cachedDoc.deviceId, result.deviceId)
        XCTAssertGreaterThan(cachedDoc.fetchedAtMs, 0)
        XCTAssertEqual(BiomarkerStub.requests.count, 1, "a cached read must not hit the network")
    }

    func testCacheIsScopedToOwnerDeviceAndDay() async throws {
        BiomarkerStub.body = routeBody(fullDocument())
        let repoA = repository(owner: ownerA)
        _ = try await repoA.refresh(day: day, deviceId: "my-whoop")

        // A different owner reading the same directory must not see owner A's cache.
        let repoB = repository(owner: ownerB)
        let ownerBCached = await repoB.cachedDay(day: day, deviceId: "my-whoop")
        XCTAssertNil(ownerBCached, "another owner's cache must not be returned")

        // The same owner for a different day or device must not see it either.
        let otherDay = await repoA.cachedDay(day: "2026-10-05", deviceId: "my-whoop")
        XCTAssertNil(otherDay)
        let otherDevice = await repoA.cachedDay(day: day, deviceId: "other-whoop")
        XCTAssertNil(otherDevice)

        // And owner A's cache is still there for owner A (sign-out does not delete it).
        let ownerACached = await repoA.cachedDay(day: day, deviceId: "my-whoop")
        XCTAssertNotNil(ownerACached)
    }

    func testNullDocumentIsNotCached() async throws {
        BiomarkerStub.status = 404
        let repo = repository()
        let result = try await repo.refresh(day: day, deviceId: "my-whoop")
        XCTAssertNil(result, "an explicit no-data answer is nil, not an error")
        let cached = await repo.cachedDay(day: day, deviceId: "my-whoop")
        XCTAssertNil(cached, "nothing is cached for a day the server has no document for")
    }

    func testOversizedNetworkPayloadIsRejectedAndNotCached() async throws {
        let blob = String(repeating: "x", count: 300 * 1024)
        let doc = document(families: [
            "movement": family(status: "ok", measurements: [
                "enmo_median_mg": measurement(12.5, unit: "mg", denominator: blob),
            ]),
        ])
        BiomarkerStub.body = routeBody(doc)
        let repo = repository()
        do {
            _ = try await repo.refresh(day: day, deviceId: "my-whoop")
            XCTFail("an oversized network payload must be rejected")
        } catch let error as SensorBiomarkerRepository.ReadError {
            guard case .oversized = error else { return XCTFail("expected oversized, got \(error)") }
        }
        let cached = await repo.cachedDay(day: day, deviceId: "my-whoop")
        XCTAssertNil(cached, "an oversized payload must never be cached")
    }

    func testInvalidateDropsOneDay() async throws {
        BiomarkerStub.body = routeBody(fullDocument())
        let repo = repository()
        _ = try await repo.refresh(day: day, deviceId: "my-whoop")
        let before = await repo.cachedDay(day: day, deviceId: "my-whoop")
        XCTAssertNotNil(before)
        await repo.invalidate(day: day, deviceId: "my-whoop")
        let after = await repo.cachedDay(day: day, deviceId: "my-whoop")
        XCTAssertNil(after)
    }

    // MARK: - Bounded retry

    func testTransientErrorsAreRetriedAndRecover() async throws {
        BiomarkerStub.statuses = [500, 503, 200]
        BiomarkerStub.body = routeBody(fullDocument())
        let repo = repository()
        let result = try await repo.refresh(day: day, deviceId: "my-whoop")
        XCTAssertNotNil(result)
        XCTAssertEqual(BiomarkerStub.requests.count, 3, "two transient failures then success = three requests")
    }

    func testRetryGivesUpAfterTheBound() async throws {
        BiomarkerStub.statuses = [500, 500, 500, 200]
        BiomarkerStub.body = routeBody(fullDocument())
        let repo = repository(maxRetries: 2)
        do {
            _ = try await repo.refresh(day: day, deviceId: "my-whoop")
            XCTFail("three consecutive 5xx must fail")
        } catch let error as SensorBiomarkerRepository.ReadError {
            guard case .http(let status, _) = error else { return XCTFail("expected http error, got \(error)") }
            XCTAssertEqual(status, 500)
        }
        XCTAssertEqual(BiomarkerStub.requests.count, 3, "one attempt plus two retries, never more")
    }

    func testClientErrorsAreNotRetried() async throws {
        // A 404 is the route's explicit no-data answer (see
        // testRefreshTreatsTheRoutes404AsNoDataNeverAnError), so the never-retried
        // client-error case is pinned with a 403 instead.
        BiomarkerStub.status = 403
        let repo = repository()
        do {
            _ = try await repo.refresh(day: day, deviceId: "my-whoop")
            XCTFail("a 403 must fail")
        } catch let error as SensorBiomarkerRepository.ReadError {
            guard case .http(let status, _) = error else { return XCTFail("expected http error, got \(error)") }
            XCTAssertEqual(status, 403)
        }
        XCTAssertEqual(BiomarkerStub.requests.count, 1, "a 4xx is permanent and must not be retried")
    }

    // MARK: - Store (feature flag + account clearing)

    @MainActor
    private func store(repository repo: SensorBiomarkerRepository?,
                       featureEnabled: Bool = true, cloudEnabled: Bool = true) -> SensorBiomarkerStore {
        SensorBiomarkerStore(environment: .init(
            featureEnabled: { featureEnabled },
            cloudEnabled: { cloudEnabled },
            repository: { repo }))
    }

    @MainActor
    func testStoreFetchesAndShowsTheDocument() async throws {
        BiomarkerStub.body = routeBody(fullDocument())
        let repo = repository()
        let store = self.store(repository: repo)
        await store.load(day: day)
        guard case .available(let document) = store.state(for: day) else {
            return XCTFail("expected an available document, got \(String(describing: store.state(for: day)))")
        }
        XCTAssertEqual(document.families.count, 4)
    }

    @MainActor
    func testStoreNeverFetchesWhenTheFeatureFlagIsOff() async throws {
        BiomarkerStub.body = routeBody(fullDocument())
        let repo = repository()
        let store = self.store(repository: repo, featureEnabled: false)
        await store.load(day: day)
        XCTAssertNil(store.state(for: day), "with the flag off the store must not even start a read")
        XCTAssertTrue(BiomarkerStub.requests.isEmpty, "with the flag off no route may be called")
    }

    @MainActor
    func testStoreSaysCloudOffWithoutFetching() async throws {
        BiomarkerStub.body = routeBody(fullDocument())
        let repo = repository()
        let store = self.store(repository: repo, cloudEnabled: false)
        await store.load(day: day)
        guard case .unavailable = store.state(for: day) else {
            return XCTFail("expected an unavailable state, got \(String(describing: store.state(for: day)))")
        }
        XCTAssertTrue(BiomarkerStub.requests.isEmpty, "a local-only install must not call the route")
    }

    @MainActor
    func testStoreSignOutResetClearsInMemoryState() async throws {
        BiomarkerStub.body = routeBody(fullDocument())
        let repo = repository()
        let store = self.store(repository: repo)
        store.setReadCandidates(["whoop-1234", "my-whoop"])
        await store.load(day: day)
        XCTAssertNotNil(store.state(for: day))
        XCTAssertEqual(store.readDeviceId, "whoop-1234")

        store.reset()
        XCTAssertNil(store.state(for: day), "sign-out must clear what the previous account read")
        XCTAssertEqual(store.readDeviceId, "my-whoop", "sign-out must reset the read candidates")
        XCTAssertTrue(store.states.isEmpty)
    }

    // MARK: - View model: rendering decisions

    private func model(_ envelope: [String: Any]) throws -> SensorBiomarkersViewModel {
        let parsed = try XCTUnwrap(parse(envelope))
        return SensorBiomarkersViewModel.build(document: parsed)
    }

    func testValidDocumentRendersTheDescriptiveCards() throws {
        let model = try model(fullDocument())
        XCTAssertEqual(model.items.map(\.key),
                       ["wrist_movement", "low_movement", "oscillation", "ppg_quality", "pulse_shape"])
        XCTAssertEqual(model.items.map(\.title),
                       ["Wrist movement", "Low-movement bouts", "Wrist oscillation",
                        "Pulse waveform consistency", "Pulse width"])

        let movement = try XCTUnwrap(model.items.first { $0.key == "wrist_movement" })
        XCTAssertNil(movement.unavailableReason)
        XCTAssertEqual(movement.values,
                       ["Median 12.5 mg · 95th percentile 85 mg"], "ENMO renders median/p95 with units")
        XCTAssertEqual(movement.coverage, "Observed 1h")
        XCTAssertEqual(movement.captureInterval, "Oct 6, 00:00–23:59 UTC")
        XCTAssertEqual(movement.definition, "How much your wrist moved, measured from the strap's accelerometer.")

        let bouts = try XCTUnwrap(model.items.first { $0.key == "low_movement" })
        XCTAssertNil(bouts.unavailableReason)
        XCTAssertTrue(bouts.values.contains { $0 == "14 bouts" })
        XCTAssertTrue(bouts.values.contains { $0 == "Median 4m 20s · longest 26m" })
        XCTAssertTrue(bouts.values.contains { $0 == "3.2 transitions per observed hour" })
        XCTAssertTrue(bouts.values.contains { $0 == "Low movement 42% of classified observed time" })
    }

    func testWithheldFamilyRendersAPreciseReasonAndNeverAZero() throws {
        let doc = document(families: [
            "movement": family(status: "withheld", observed: 0, eligible: 0, reason: "unknown_wrist_placement"),
        ])
        let model = try model(doc)
        let item = try XCTUnwrap(model.items.first)
        XCTAssertTrue(item.values.isEmpty, "a withheld family must render no measured values")
        XCTAssertEqual(item.unavailableReason, "The strap's wrist placement wasn't verified.")
        XCTAssertNil(item.coverage)
        XCTAssertNil(item.captureInterval)
        XCTAssertFalse(item.values.contains { $0.contains("0") }, "a withheld family must never show a zero")
    }

    func testErrorFamilyRendersItsOwnMessage() throws {
        let doc = document(families: [
            "ppg_quality": family(status: "error", reason: "some_worker_reason"),
        ])
        let model = try model(doc)
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.unavailableReason, "This couldn't be computed today.")
        XCTAssertTrue(item.values.isEmpty)
    }

    func testUnknownReasonFallsBackToNotEnoughUsableData() throws {
        let doc = document(families: [
            "movement": family(status: "withheld", reason: "some_future_reason_code"),
        ])
        let model = try model(doc)
        XCTAssertEqual(model.items.first?.unavailableReason, "Not enough usable data.")
    }

    func testPartialFamilyShowsAvailableLinesAndNeverInventsMissingOnes() throws {
        // `ok` with only the ENMO median: p95 is absent and must not be invented as anything.
        let doc = document(families: [
            "movement": family(status: "ok", measurements: [
                "enmo_median_mg": measurement(12.5, unit: "mg"),
            ]),
        ])
        let model = try model(doc)
        XCTAssertEqual(model.items.map(\.key), ["wrist_movement"],
                       "the low-movement card needs low-movement measurements, and there are none")
        let item = try XCTUnwrap(model.items.first)
        XCTAssertNil(item.unavailableReason)
        XCTAssertEqual(item.values, ["Median 12.5 mg"], "only the published measurement is shown")
    }

    func testFamilyOkWithoutDisplayMeasurementsFallsBack() throws {
        let doc = document(families: [
            "pulse_shape": family(status: "ok", measurements: [
                "some_diagnostic_key": measurement(1),
            ]),
        ])
        let model = try model(doc)
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.unavailableReason, "Not enough usable data.",
                       "a usable family with none of its display measurements says so plainly")
        XCTAssertTrue(item.values.isEmpty)
    }

    func testPulseShapeCardShowsNativeTimingConfigurationAndCounts() throws {
        let doc = document(families: [
            "pulse_shape": family(status: "ok", nativeRate: 25, configuration: "cfg-1", measurements: [
                "pulse_width50_median_ms": measurement(380, unit: "ms"),
                "pulse_width50_iqr_ms": measurement(92, unit: "ms"),
                "pulse_accepted_count": measurement(1234),
                "pulse_rejected_count": measurement(56),
            ]),
        ])
        let model = try model(doc)
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.values,
                       ["Median 380 ms · IQR 92 ms",
                        "Native timing 25 Hz (40 ms per sample)",
                        "Stable configuration cfg-1",
                        "1234 pulses accepted · 56 rejected"])
    }

    func testOscillationCardShowsBandPowerWithUnits() throws {
        let doc = document(families: [
            "oscillation": family(status: "ok", measurements: [
                "wrist_oscillation_power_3_7hz_median": measurement(0.31, unit: "(deg/s)^2"),
                "wrist_oscillation_power_3_7hz_p95": measurement(0.9, unit: "(deg/s)^2"),
            ]),
        ])
        let model = try model(doc)
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.values, ["Median 0.31 (deg/s)^2 · 95th percentile 0.9 (deg/s)^2"])
    }

    func testTremorArmSwingAndShadowFamiliesAreNeverRendered() throws {
        let doc = document(families: [
            "movement": family(status: "ok", measurements: ["enmo_median_mg": measurement(12.5, unit: "mg")]),
            "tremor": family(status: "ok", measurements: [
                "eligible_rest_seconds": measurement(600),
                "classified_tremor_seconds": measurement(30),
            ]),
            "arm_swing": family(status: "ok", measurements: [
                "arm_swing_bout_count": measurement(8),
            ]),
            "rhythm_shadow": family(status: "withheld", reason: "preprocessing_unverified"),
        ])
        let model = try model(doc)
        XCTAssertEqual(model.items.map(\.key), ["wrist_movement"],
                       "research and shadow families must never reach the normal dashboard")
    }

    func testLowMovementFractionAndTransitionsRender() throws {
        let doc = document(families: [
            "movement": family(status: "ok", observed: 21_600, eligible: 21_600, measurements: [
                "low_movement_fraction": measurement(0.42, denominator: "classified observed time"),
                "low_to_moving_transitions_per_observed_hour": measurement(3.2, unit: "transitions/hour"),
            ]),
        ])
        let model = try model(doc)
        XCTAssertEqual(model.items.map(\.key), ["low_movement"],
                       "no ENMO means no wrist-movement card, but the low-movement card still renders")
        let item = try XCTUnwrap(model.items.first)
        XCTAssertTrue(item.values.contains { $0 == "3.2 transitions per observed hour" })
        XCTAssertTrue(item.values.contains { $0 == "Low movement 42% of classified observed time" })
        XCTAssertEqual(item.coverage, "Observed 6h")
    }

    func testCoverageDistinguishesObservedAndEligible() throws {
        let doc = document(families: [
            "movement": family(status: "ok", observed: 39_600, eligible: 36_000,
                               measurements: ["enmo_median_mg": measurement(12.5, unit: "mg")]),
        ])
        let model = try model(doc)
        XCTAssertEqual(model.items.first?.coverage, "Observed 11h · eligible 10h")
    }

    func testUncalibratedMovementNeverRendersEligibleZero() throws {
        // An uncalibrated movement family (eligible 0, observed positive) must
        // never render "eligible 0s": zero eligible is not coverage, it is the
        // honest statement that nothing was classified.
        let doc = document(families: [
            "movement": family(status: "ok", observed: 21_600, eligible: 0, measurements: [
                "enmo_median_mg": measurement(12.5, unit: "mg"),
            ]),
        ])
        let model = try model(doc)
        XCTAssertEqual(model.items.first?.coverage, "Observed 6h")
    }

    func testCaptureIntervalSpansTwoDaysWhenItMust() throws {
        let doc = document(start: "2026-10-06T00:00:00Z", end: "2026-10-07T06:00:00Z", families: [
            "movement": family(status: "ok", measurements: ["enmo_median_mg": measurement(12.5, unit: "mg")]),
        ])
        let model = try model(doc)
        XCTAssertEqual(model.items.first?.captureInterval, "Oct 6, 00:00 – Oct 7, 06:00 UTC")
    }

    func testReasonVocabularyMapsToPlainLanguage() {
        let cases: [(String?, String)] = [
            (nil, "Not enough usable data."),
            ("unknown_wrist_placement", "The strap's wrist placement wasn't verified."),
            ("unknown_orientation", "The strap's orientation wasn't verified."),
            ("insufficient_eligible_time", "Not enough eligible time was recorded."),
            ("unsupported_native_rate", "The sensor's native sample rate isn't supported for this measurement."),
            ("missing_ppg_anchor", "The pulse waveform was missing its reference anchor."),
            ("saturated_delta", "Part of the pulse waveform was saturated."),
            ("unverified_sample_clock", "The sensor's sample timing couldn't be verified."),
            ("preprocessing_unverified", "The signal preprocessing couldn't be verified."),
            ("no_verified_input", "No verified sensor data reached this measurement."),
            ("model_unavailable", "The model for this measurement isn't available."),
            // Legacy (stored before 2026-10-09): either cause, so neither is claimed.
            ("artifact_unavailable", "This measurement couldn't be computed for this day."),
            ("unverified_optical_dc", "The optical baseline couldn't be verified."),
            ("not_enough_valid_data", "Not enough usable data."),
        ]
        for (reason, expected) in cases {
            XCTAssertEqual(SensorBiomarkersViewModel.reasonText(reason, status: "withheld"), expected,
                           "reason \(reason ?? "nil")")
        }
    }

    func testDurationFormatting() {
        XCTAssertEqual(SensorBiomarkersViewModel.duration(0), "0s")
        XCTAssertEqual(SensorBiomarkersViewModel.duration(42), "42s")
        XCTAssertEqual(SensorBiomarkersViewModel.duration(185), "3m 05s")
        XCTAssertEqual(SensorBiomarkersViewModel.duration(39600), "11h")
        XCTAssertEqual(SensorBiomarkersViewModel.duration(3600), "1h")
    }

    func testSamplePeriodFromNativeRate() {
        XCTAssertEqual(SensorBiomarkersViewModel.samplePeriod(25), "40 ms per sample")
        XCTAssertEqual(SensorBiomarkersViewModel.samplePeriod(24), "42 ms per sample")
    }
}

/// A transport stub that records what the repository asked for, so the real request, parse, retry and
/// cache path runs with no network.
private final class BiomarkerStub: URLProtocol {
    static var body: [String: Any] = [:]
    static var rawData: Data?
    static var status = 200
    /// When non-empty, the next request's status is popped from this queue (for retry tests).
    static var statuses: [Int] = []
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        BiomarkerStub.requests.append(request)
        let status: Int
        if !BiomarkerStub.statuses.isEmpty {
            status = BiomarkerStub.statuses.removeFirst()
        } else {
            status = BiomarkerStub.status
        }
        let data = BiomarkerStub.rawData ?? ((try? JSONSerialization.data(withJSONObject: BiomarkerStub.body)) ?? Data())
        let http = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BiomarkerStub.self]
        return URLSession(configuration: config)
    }
}
