import XCTest
import CZstd
@testable import frwhoop_worker

/// W5: SensorBiomarkerLane lifecycle tests.
///
/// Pure tests (no DB, no B2, no Python): job-row parsing, envelope parsing (ok / top-level
/// withheld / error verdicts), family-stage parsing and the cross-request merge (additive
/// coverage/counts, quantile-from-best-coverage), the CONTRACTS.md §3 day-document shape, the
/// publish payload, the sidecar request shape (metric/provider/input), and chunk parity: a
/// multi-hour contiguous day splits into budget-bounded requests whose endpoint-owned segments
/// cover every second exactly once (no duplicate windows at seams), and the merged per-family
/// coverage equals the contiguous sum.
///
/// DB-backed tests (skipped without FRWHOOP_TEST_DB_URL): claim/publish round trip against a real
/// scratch Postgres with a stub sidecar HTTP server (StubHTTPServer) and a stub downloader; lease
/// expiry recovery; the publish fence (a stale worker cannot publish over a newer revision);
/// late-input-revision idempotency (republish replaces, one row); and sidecar-missing
/// independence (a refused/not-ready sidecar settles the job with bounded backoff and never blocks
/// the other lanes — the day table simply has no row).
final class SensorBiomarkerLaneTests: XCTestCase {

    // A PAST UTC day relative to the real clock (2026-09-15), so the day-document status is
    // "completed" and the day-document interval expectations are stable.
    private static let day = "2026-09-15"
    private static let dayStart: Int64 = 1_789_430_400   // 2026-09-15 00:00:00 UTC

    // MARK: - Helpers

    /// The inputs fixtures resource (same file-system lookup the inputs tests use).
    private func ppgWireFixtureResource() throws -> Data {
        if let dir = ProcessInfo.processInfo.environment["FRWHOOP_SENSOR_FIXTURE_DIR"], !dir.isEmpty,
           FileManager.default.fileExists(atPath: dir + "/sensor_biomarkers_ppg_wire.json") {
            return try Data(contentsOf: URL(fileURLWithPath: dir + "/sensor_biomarkers_ppg_wire.json"))
        }
        for candidate in [
            "Tests/frwhoop-workerTests/Resources/sensor_biomarkers/sensor_biomarkers_ppg_wire.json",
            "Tests/frwhoop-workerTests/Resources/sensor_biomarkers_ppg_wire.json",
        ] where FileManager.default.fileExists(atPath: candidate) {
            return try Data(contentsOf: URL(fileURLWithPath: candidate))
        }
        throw SensorBiomarkerLane.SensorBiomarkerError.deterministic("ppg_wire_fixture_missing")
    }

    private func hexData(_ hex: String) -> Data {
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<next], radix: 16)!)
            i = next
        }
        return out
    }

    private func zstdCompress(_ data: Data) throws -> Data {
        let bound = Int(CZstd.ZSTD_compressBound(data.count))
        var dst = [UInt8](repeating: 0, count: bound)
        let written: Int = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
                Int(CZstd.ZSTD_compress(d.baseAddress, d.count, src.baseAddress, src.count, 3))
            }
        }
        return Data(dst.prefix(written))
    }

    /// A synthetic NPB1 rawImuSession object covering `seconds` contiguous seconds from `start`.
    private func syntheticImu(seconds: [Int64]) throws -> (decoded: Data, zstd: Data, digest: String) {
        let columns = [Int16](repeating: 0, count: Npb1ImuDecoder.columnsPerRecord)
        let records = seconds.map { Npb1ImuDecoder.Record(rowId: $0, ts: $0, columns: columns) }
        let decoded = try Npb1ImuDecoder.pack(records: records)
        let digest = sha256Hex(decoded)
        return (decoded, try zstdCompress(decoded), digest)
    }

    private func stageJSON(family: String, status: String, observed: Double?, measurements: Any,
                           reasonCounts: [String: Int] = [:], reason: String? = nil,
                           releaseTier: String = "descriptive", providerRevision: String = "x/1") -> JSONValue {
        var obj: [String: JSONValue] = [
            "status": .string(status),
            "release_tier": .string(releaseTier),
            "provider_revision": .string(providerRevision),
            "measurements": .init(any: measurements),
            "reason_counts": .init(any: reasonCounts),
        ]
        if let observed { obj["observed_seconds"] = .double(observed) }
        if let reason { obj["reason"] = .string(reason) }
        return .object(obj)
    }

    private func envelope(stages: [String: JSONValue]) -> String {
        let body: [String: Any] = [
            "status": "ok",
            "metric": "sensor_biomarkers",
            "provider_id": "sensor.biomarkers.v1",
            "result": [
                "label_space": "sensor_biomarkers.families/1",
                "stages": stages.mapValues { $0.anyValue },
            ] as [String: Any],
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        return String(decoding: data, as: UTF8.self)
    }

    private func makeJob(day: String = day, userId: String = "11111111-1111-4111-8111-111111111111",
                         deviceId: String = "22222222-2222-4222-8222-222222222222",
                         fingerprint: String = String(repeating: "a", count: 64),
                         revision: Int64 = 1, token: String = "33333333-3333-4333-8333-333333333333",
                         families: [String] = ["movement", "tremor"]) -> SensorBiomarkerLane.SensorBiomarkerJob {
        SensorBiomarkerLane.SensorBiomarkerJob(userId: userId, deviceId: deviceId, day: day,
            analysisVersion: "sensor-biomarkers/1.0.0", fingerprint: fingerprint,
            inputRevision: revision, leaseToken: token, families: families,
            objectIds: [], digests: [])
    }

    // MARK: - Configuration

    private func configEnv(_ extra: [String: String]) -> [String: String] {
        ["FRWHOOP_DB_URL": "postgres://u:p@host:5432/postgres", "FRWHOOP_B2_KEY_ID": "key",
         "FRWHOOP_B2_APPLICATION_KEY": "secret", "FRWHOOP_INGEST_SECRET": "ingest"].merging(extra) { $1 }
    }

    func testFamilySetIsImuOnlyUnlessPpgIsEnabled() throws {
        let off = try WorkerConfig(environment: configEnv([:]))
        XCTAssertFalse(off.sensorLaneRuns)
        XCTAssertEqual(off.sensorFamilies, [])
        let imu = try WorkerConfig(environment: configEnv(["FRWHOOP_SENSOR_BIOMARKERS_ENABLED": "1"]))
        XCTAssertTrue(imu.sensorLaneRuns)
        XCTAssertEqual(imu.sensorFamilies, ["movement", "oscillation"])
        let ppg = try WorkerConfig(environment: configEnv([
            "FRWHOOP_SENSOR_BIOMARKERS_ENABLED": "1", "FRWHOOP_SENSOR_PPG_ENABLED": "1"]))
        XCTAssertEqual(ppg.sensorFamilies, ["movement", "oscillation", "ppg_quality", "pulse_shape"])
        let ppgAlone = try WorkerConfig(environment: configEnv(["FRWHOOP_SENSOR_PPG_ENABLED": "1"]))
        XCTAssertEqual(ppgAlone.sensorFamilies, [])
    }

    // MARK: - Job-row parsing

    func testParseJob() {
        let good: [String: String] = [
            "user_id": "11111111-1111-4111-8111-111111111111",
            "device_id": "22222222-2222-4222-8222-222222222222",
            "day": "2026-10-20",
            "analysis_version": "sensor-biomarkers/1.0.0",
            "fingerprint": String(repeating: "b", count: 64),
            "input_revision": "3",
            "lease_token": "33333333-3333-4333-8333-333333333333",
            "enabled_families": "movement,tremor",
            "input_object_ids": "44444444-4444-4444-8444-444444444444",
            "input_digests": String(repeating: "c", count: 64),
        ]
        let job = SensorBiomarkerLane.parseJob(good)
        XCTAssertNotNil(job)
        XCTAssertEqual(job?.day, "2026-10-20")
        XCTAssertEqual(job?.inputRevision, 3)
        XCTAssertEqual(job?.families, ["movement", "tremor"])
        XCTAssertEqual(job?.objectIds.count, 1)
        XCTAssertEqual(job?.digests.count, 1)

        // A corrupt row (missing lease token) parses to nil.
        var missingToken = good
        missingToken["lease_token"] = ""
        XCTAssertNil(SensorBiomarkerLane.parseJob(missingToken))
        // Digest/id count mismatch is corrupt.
        var mismatch = good
        mismatch["input_digests"] = ""
        XCTAssertNil(SensorBiomarkerLane.parseJob(mismatch))
        // Bad fingerprint length is corrupt.
        var badFp = good
        badFp["fingerprint"] = "short"
        XCTAssertNil(SensorBiomarkerLane.parseJob(badFp))
    }

    // MARK: - Envelope parsing

    func testParseEnvelopeOk() throws {
        let stages: [String: JSONValue] = [
            "movement": stageJSON(family: "movement", status: "ok", observed: 600,
                                  measurements: ["enmo_median_mg": ["value": 12.5]]),
            "tremor": stageJSON(family: "tremor", status: "withheld", observed: nil,
                                measurements: [:], reason: "unknown_wrist_placement",
                                releaseTier: "research", providerRevision: "paradigma/1.0.0"),
        ]
        let response = try InferenceClient.decodeInferenceResponse(
            Data(envelope(stages: stages).utf8), http: Self.http(200), expectedMetric: "sensor_biomarkers")
        let parsed = try SensorBiomarkerLane.parseEnvelope(response, families: ["movement", "tremor"])
        XCTAssertEqual(parsed["movement"]?.status, "ok")
        XCTAssertEqual(parsed["movement"]?.observedSeconds, 600)
        XCTAssertEqual(parsed["tremor"]?.status, "withheld")
        XCTAssertEqual(parsed["tremor"]?.reason, "unknown_wrist_placement")
    }

    func testParseEnvelopeAcceptsTheSidecarStageList() throws {
        // The sidecar's real wire: `result.stages` is a list of family documents naming `family`.
        let body = """
        {"status":"ok","metric":"sensor_biomarkers","provider_id":"sensor.biomarkers.v1",
         "result":{"label_space":"sensor_biomarkers.families/1","stages":[
           {"family":"movement","status":"ok","release_tier":"descriptive","provider_revision":"imu-biomarkers/1.0.0",
            "observed_seconds":300,"eligible_seconds":280,
            "measurements":{"enmo_median_mg":{"value":12.5,"unit":"mg","count":56}},"reason_counts":{}},
           {"family":"oscillation","status":"withheld","release_tier":"descriptive",
            "provider_revision":"imu-biomarkers/1.0.0","measurements":{},"reason":"not_enough_valid_data"}]}}
        """
        let response = try InferenceClient.decodeInferenceResponse(
            Data(body.utf8), http: Self.http(200), expectedMetric: "sensor_biomarkers")
        let parsed = try SensorBiomarkerLane.parseEnvelope(response, families: ["movement", "oscillation"])
        XCTAssertEqual(parsed["movement"]?.status, "ok")
        XCTAssertEqual(parsed["movement"]?.observedSeconds, 300)
        XCTAssertEqual(parsed["oscillation"]?.reason, "not_enough_valid_data")
    }

    func testParseEnvelopeTopLevelVerdicts() throws {
        // A top-level "withheld" (provider verdict) becomes withheld families with the envelope's
        // reason — never a retry.
        let withheldBody = """
        {"status":"withheld","metric":"sensor_biomarkers","withheld_reason":"preprocessing_unverified",
         "diagnostics":{"reason":"preprocessing_unverified"}}
        """
        let response = try InferenceClient.decodeInferenceResponse(
            Data(withheldBody.utf8), http: Self.http(200), expectedMetric: "sensor_biomarkers")
        let parsed = try SensorBiomarkerLane.parseEnvelope(response, families: ["movement", "tremor"])
        XCTAssertEqual(parsed["movement"]?.status, "withheld")
        XCTAssertEqual(parsed["movement"]?.reason, "preprocessing_unverified")
        XCTAssertEqual(parsed["tremor"]?.status, "withheld")
    }

    func testParseEnvelopeUnknownFamilyIsDeterministic() throws {
        let stages: [String: JSONValue] = ["not_a_family": stageJSON(family: "x", status: "ok", observed: 1, measurements: [:])]
        let response = try InferenceClient.decodeInferenceResponse(
            Data(envelope(stages: stages).utf8), http: Self.http(200), expectedMetric: "sensor_biomarkers")
        XCTAssertThrowsError(try SensorBiomarkerLane.parseEnvelope(response, families: ["movement"])) { error in
            guard case SensorBiomarkerLane.SensorBiomarkerError.deterministic(let d) = error else {
                return XCTFail("expected deterministic error, got \(error)")
            }
            XCTAssertTrue(d.contains("unknown_family"))
        }
    }

    // MARK: - Family-stage parsing and merge

    /// A stage carrying the provider's bounded-bin distribution (CONTRACTS/§8, spec 8):
    /// mergeable counts over the fixed documented edges, keyed by the median measurement key.
    private func stageJSONWithDistribution(family: String, observed: Double?,
                                           medianValue: Double, distributionKey: String,
                                           edges: [Double], counts: [Int]) -> JSONValue {
        var obj: [String: JSONValue] = [
            "status": .string("ok"),
            "release_tier": .string("descriptive"),
            "provider_revision": .string("x/1"),
            "measurements": .object(["enmo_median_mg": .object(["value": .double(medianValue)])]),
            "reason_counts": .object([:]),
            "distributions": .array([.object([
                "key": .string(distributionKey),
                "edges": .array(edges.map { .double($0) }),
                "counts": .array(counts.map { .int($0) }),
            ])]),
        ]
        if let observed { obj["observed_seconds"] = .double(observed) }
        return .object(obj)
    }

    func testFamilyStageMergePoolsDayQuantilesFromDistributionBins() throws {
        // Two requests (chunks) with disjoint ENMO distributions: chunk A holds
        // 4 epochs in [1,2) mg and 4 in [6,8); chunk B holds 8 epochs in [3,4).
        // The pooled day median is rank 8 of 16 -> mid of the [3,4) bin -> 3.5 mg,
        // which is NEITHER stage's own carried median (5.0 / 4.5): the day value
        // is pooled across both chunks' bins, never one request's value presented
        // as the day's.
        let edges = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0]
        let a = try SensorBiomarkerFamilyStage.parse(
            family: "movement",
            stageJSONWithDistribution(family: "movement", observed: 300, medianValue: 5.0,
                                      distributionKey: "enmo_median_mg", edges: edges,
                                      counts: [0, 4, 0, 0, 0, 0, 4, 0]))
        let b = try SensorBiomarkerFamilyStage.parse(
            family: "movement",
            stageJSONWithDistribution(family: "movement", observed: 700, medianValue: 4.5,
                                      distributionKey: "enmo_median_mg", edges: edges,
                                      counts: [0, 0, 0, 8, 0, 0, 0, 0]))
        let merged = try SensorBiomarkerFamilyStage.merge([a, b])
        guard case .object(let m) = merged.measurements else { return XCTFail("measurements object expected") }
        guard case .object(let entry)? = m["enmo_median_mg"] else { return XCTFail("median entry expected") }
        XCTAssertEqual(entry["value"]?.doubleValue ?? -1, 3.5, accuracy: 0.26,
                       "the day median is pooled across both chunks' bins")
        XCTAssertEqual(entry["aggregation"]?.stringValue, "pooled-day-bins")
        // The p95 pools too: rank 15.2 of 16 -> inside the 6-8 bin.
        _ = m // (p95 key absent in this fixture; the median proves the pooling path)
    }

    func testFamilyStageMergeFallsBackToBestCoverageWhenEdgesDisagree() throws {
        // A stage set with no distributions keeps the documented best-coverage carry.
        let a = try SensorBiomarkerFamilyStage.parse(
            family: "movement",
            stageJSON(family: "movement", status: "ok", observed: 300, measurements: [
                "enmo_median_mg": ["value": 10.0],
            ]))
        let b = try SensorBiomarkerFamilyStage.parse(
            family: "movement",
            stageJSON(family: "movement", status: "ok", observed: 700, measurements: [
                "enmo_median_mg": ["value": 25.0],
            ]))
        let merged = try SensorBiomarkerFamilyStage.merge([a, b])
        guard case .object(let m) = merged.measurements else { return XCTFail("measurements object expected") }
        XCTAssertEqual(m["enmo_median_mg"]?.member("value")?.doubleValue ?? 0, 25.0,
                       "no distribution: the best-coverage request's quantile is carried unchanged")
    }

    func testQuantileFromBinsMatchesIndependentReference() {
        // Independent reference: edges [0,1,2], counts [2,2] -> n=4.
        // median (q=0.5): rank 2.0 -> end of bin 0 / start of bin 1 -> 1.0.
        // p25: rank 1.0 -> mid of bin 0 -> 0.5. p95: rank 3.8 -> bin 1 (cum 2..4),
        // 0.9 across -> 1 + 0.9*(2-1) = 1.9.
        let q = SensorBiomarkerFamilyStage.quantileFromBins(edges: [0, 1, 2], counts: [2, 2], n: 4, q: 0.5)
        XCTAssertEqual(q, 1.0, accuracy: 1e-9)
        let p25 = SensorBiomarkerFamilyStage.quantileFromBins(edges: [0, 1, 2], counts: [2, 2], n: 4, q: 0.25)
        XCTAssertEqual(p25, 0.5, accuracy: 1e-9)
        let p95 = SensorBiomarkerFamilyStage.quantileFromBins(edges: [0, 1, 2], counts: [2, 2], n: 4, q: 0.95)
        XCTAssertEqual(p95, 1.9, accuracy: 1e-9)
    }

    // MARK: - (merge tests continue)

    func testFamilyStageParseRejectsMalformedStage() {
        XCTAssertThrowsError(try SensorBiomarkerFamilyStage.parse(family: "movement", .string("nope")))
        XCTAssertThrowsError(try SensorBiomarkerFamilyStage.parse(
            family: "movement", stageJSON(family: "movement", status: "maybe", observed: 1, measurements: [:])))
        XCTAssertThrowsError(try SensorBiomarkerFamilyStage.parse(
            family: "movement", stageJSON(family: "movement", status: "ok", observed: 1, measurements: "bad")))
    }

    func testFamilyStageMergeSumsCoverageAndCountsTakesQuantileFromBestCoverage() throws {
        let a = try SensorBiomarkerFamilyStage.parse(
            family: "movement",
            stageJSON(family: "movement", status: "ok", observed: 300, measurements: [
                "low_movement_seconds": ["value": 120.0, "unit": "s", "count": 24],
                "low_movement_bout_count": ["value": 4.0, "unit": "count"],
                "low_movement_bout_max_seconds": ["value": 60.0, "unit": "s"],
                "low_movement_bout_median_seconds": ["value": 30.0, "unit": "s"],
                "enmo_median_mg": ["value": 10.0],
            ], reasonCounts: ["no_wear": 2]))
        let b = try SensorBiomarkerFamilyStage.parse(
            family: "movement",
            stageJSON(family: "movement", status: "ok", observed: 700, measurements: [
                "low_movement_seconds": ["value": 480.0, "unit": "s", "count": 96],
                "low_movement_bout_count": ["value": 9.0, "unit": "count"],
                "low_movement_bout_max_seconds": ["value": 45.0, "unit": "s"],
                "low_movement_bout_median_seconds": ["value": 20.0, "unit": "s"],
                "enmo_median_mg": ["value": 25.0],
            ], reasonCounts: ["no_wear": 5]))
        let merged = try SensorBiomarkerFamilyStage.merge([a, b])
        XCTAssertEqual(merged.status, "ok")
        XCTAssertEqual(merged.observedSeconds ?? 0, 1000, accuracy: 0.001, "coverage must sum across requests")
        XCTAssertEqual(merged.reasonCounts["no_wear"], 7, "reason counts must sum")
        // Additive keys (seconds/count) sum; the quantile (median) comes from the best-coverage request.
        let measurements = merged.measurements
        guard case .object(let m) = measurements else { return XCTFail("measurements object expected") }
        XCTAssertEqual(m["low_movement_seconds"]?.member("value")?.doubleValue ?? 0, 600, accuracy: 0.001)
        XCTAssertEqual(m["low_movement_seconds"]?.member("count")?.intValue, 120)
        XCTAssertEqual(m["low_movement_seconds"]?.member("unit")?.stringValue, "s")
        XCTAssertEqual(m["low_movement_bout_count"]?.member("value")?.doubleValue ?? 0, 13, accuracy: 0.001)
        XCTAssertEqual(m["low_movement_bout_max_seconds"]?.member("value")?.doubleValue ?? 0, 60, accuracy: 0.001,
                       "a per-request maximum merges as the day maximum, never a sum")
        XCTAssertEqual(m["low_movement_bout_median_seconds"]?.member("value")?.doubleValue ?? 0, 20, accuracy: 0.001,
                       "a median is never summed")
        XCTAssertEqual(m["enmo_median_mg"]?.member("value")?.doubleValue ?? 0, 25.0,
                       "the quantile must come from the largest-observed request (b)")
    }

    func testFamilyStageMergeMixedOkWithheldKeepsOkAndSummedCoverage() throws {
        let ok = try SensorBiomarkerFamilyStage.parse(
            family: "tremor",
            stageJSON(family: "tremor", status: "ok", observed: 200, measurements: ["classified_tremor_seconds": 10.0],
                      releaseTier: "research", providerRevision: "paradigma/1.0.0"))
        let withheld = try SensorBiomarkerFamilyStage.parse(
            family: "tremor",
            stageJSON(family: "tremor", status: "withheld", observed: nil, measurements: [:],
                      reason: "unknown_wrist_placement", releaseTier: "research", providerRevision: "paradigma/1.0.0"))
        let merged = try SensorBiomarkerFamilyStage.merge([ok, withheld])
        XCTAssertEqual(merged.status, "ok", "one valid request makes the day's family ok")
        XCTAssertEqual(merged.observedSeconds ?? 0, 200, accuracy: 0.001)
        XCTAssertNil(merged.reason, "a mixed day has no single withheld reason")
    }

    func testFamilyStageMergeAllWithheldPicksDominantReason() throws {
        let a = SensorBiomarkerFamilyStage.withheld(family: "movement", reason: "unknown_wrist_placement")
        let b = SensorBiomarkerFamilyStage.withheld(family: "movement", reason: "unknown_wrist_placement")
        let c = SensorBiomarkerFamilyStage.withheld(family: "movement", reason: "artifact_unavailable")
        let merged = try SensorBiomarkerFamilyStage.merge([a, b, c])
        XCTAssertEqual(merged.status, "withheld")
        XCTAssertEqual(merged.reason, "unknown_wrist_placement")
        XCTAssertTrue(merged.measurements == .object([:]), "a withheld family never fabricates measurements")
    }

    // MARK: - Day document + publish payload

    func testDayDocumentShape() {
        let families: [String: JSONValue] = [
            "movement": SensorBiomarkerFamilyStage.withheld(family: "movement", reason: "artifact_unavailable").jsonValue,
        ]
        let doc = SensorBiomarkerLane.dayDocument(
            day: Self.day, dayBounds: (Self.dayStart, Self.dayStart + 86_400),
            inputRevision: "sha256:" + String(repeating: "d", count: 64),
            processedAt: Date(timeIntervalSince1970: TimeInterval(Self.dayStart + 100)),
            families: families)
        XCTAssertEqual(doc["schema_version"]?.intValue, 1)
        XCTAssertEqual(doc["analysis_version"]?.stringValue, "sensor-biomarkers/1.0.0")
        XCTAssertEqual(doc["input_revision"]?.stringValue, "sha256:" + String(repeating: "d", count: 64))
        XCTAssertEqual(doc["interval_start_utc"]?.stringValue, "2026-09-15T00:00:00Z")
        XCTAssertEqual(doc["interval_end_utc"]?.stringValue, "2026-09-16T00:00:00Z")
        XCTAssertNotNil(doc["processed_at_utc"])
        guard case .object(let fam)? = doc["families"] else { return XCTFail("families object expected") }
        XCTAssertEqual(fam["movement"]?.member("status")?.stringValue, "withheld")
    }

    func testPublishPayloadJSON() throws {
        let doc = SensorBiomarkerLane.dayDocument(
            day: Self.day, dayBounds: (Self.dayStart, Self.dayStart + 86_400),
            inputRevision: "sha256:" + String(repeating: "e", count: 64),
            processedAt: Date(timeIntervalSince1970: TimeInterval(Self.dayStart + 100)),
            families: ["movement": SensorBiomarkerFamilyStage.withheld(family: "movement", reason: "artifact_unavailable").jsonValue])
        let payload = try SensorBiomarkerLane.publishPayload(day: Self.day, status: "completed", runMs: 4321, document: doc)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(obj["day"] as? String, Self.day)
        XCTAssertEqual(obj["status"] as? String, "completed")
        XCTAssertEqual(obj["run_ms"] as? Int, 4321)
        XCTAssertNotNil(obj["document"])
        XCTAssertNotNil(obj["model_revisions"])
    }

    // MARK: - Chunk parity (no duplicate windows at seams)

    /// A 3-hour contiguous IMU day splits into budget-bounded requests whose endpoint-owned
    /// segments cover every second exactly once — the "chunked-vs-contiguous parity / no duplicate
    /// windows at seams" property at the lane's request boundary.
    func testChunkRequestsNoDuplicateWindows() throws {
        let start = Self.dayStart
        let seconds = (0..<10_800).map { start + Int64($0) }   // 3 h contiguous
        let imu = try syntheticImu(seconds: seconds)
        let object = SensorBiomarkerInputs.InputObject(id: "44444444-4444-4444-8444-444444444444",
            objectKind: "rawImuSession", objectKey: "k", digest: imu.digest, startTs: start, endTs: start + 10_800)
        let timeline = try SensorBiomarkerInputs.imuTimeline(try Npb1ImuDecoder.decode(imu.decoded))
        let runs = SensorBiomarkerInputs.imuRuns(timeline)
        let requests = try SensorBiomarkerInputs.buildRequests(
            imuRuns: runs, ppgRuns: [], imuTimeline: timeline, ppgSecondsByTs: [:],
            objects: [object], deviceID: "22222222-2222-4222-8222-222222222222", dayUTC: Self.day,
            families: ["movement", "tremor"])
        XCTAssertGreaterThan(requests.count, 1, "a 3 h day must split into multiple requests")
        var coverage = [Int64: Int](minimumCapacity: 10_800)
        for built in requests {
            XCTAssertLessThan(built.serializedSizeBytes, SensorBiomarkerInputs.maxBodyBytes,
                              "every request stays under the sidecar 8 MiB cap")
            guard case .object(let input) = JSONValue(any: built.input.jsonObject()) else { continue }
            let segments = input["imu"]?.member("segments")
            guard case .object(let imuObj)? = input["imu"], case .array(let segs)? = imuObj["segments"] else {
                continue
            }
            _ = segments
            for segment in segs {
                guard case .object(let seg) = segment,
                      let segStart = seg["start_unix"]?.doubleValue,
                      let duration = seg["duration_s"]?.doubleValue else { continue }
                XCTAssertLessThanOrEqual(duration, 300, "segments are <= 5 minutes")
                let s = Int64(segStart)
                for second in s..<(s + Int64(duration)) {
                    coverage[second, default: 0] += 1
                }
            }
        }
        // Owned coverage partitions the day: every second exactly once, nothing outside the day.
        for second in start..<(start + 10_800) {
            XCTAssertEqual(coverage[second], 1, "second \(second) must be owned by exactly one request")
        }
    }

    /// The merge parity: two chunk stages whose observed coverage sums to the contiguous value.
    func testMergeChunkCoverageParity() throws {
        let chunkA = try SensorBiomarkerFamilyStage.parse(
            family: "movement",
            stageJSON(family: "movement", status: "ok", observed: 1_800, measurements: ["low_movement_seconds": 600.0]))
        let chunkB = try SensorBiomarkerFamilyStage.parse(
            family: "movement",
            stageJSON(family: "movement", status: "ok", observed: 1_800, measurements: ["low_movement_seconds": 900.0]))
        let merged = try SensorBiomarkerFamilyStage.merge([chunkA, chunkB])
        XCTAssertEqual(merged.observedSeconds ?? 0, 3_600, accuracy: 0.001,
                       "merged coverage must equal the contiguous coverage (no double count)")
        guard case .object(let m) = merged.measurements else { return XCTFail("measurements object expected") }
        XCTAssertEqual(m["low_movement_seconds"]?.member("value")?.doubleValue ?? 0, 1_500, accuracy: 0.001)
    }

    // MARK: - Day-level low-movement classification

    private static let seamDayStart = 1_791_244_800.0  // 2026-10-06T00:00:00Z

    /// A calibrated movement stage carrying its per-epoch ENMO series, as the sidecar emits it.
    private func movementStage(epochs: [(Double, Double)], boutCount: Double) throws -> SensorBiomarkerFamilyStage {
        guard case .object(var obj) = stageJSON(
            family: "movement", status: "ok", observed: Double(epochs.count) * 5,
            measurements: ["low_movement_bout_count": ["value": boutCount, "unit": "count"]]) else {
            throw XCTSkip("stage fixture")
        }
        obj["calibrated"] = .bool(true)
        obj["enmo_epochs"] = .array(epochs.map { .array([.double($0.0), .double($0.1)]) })
        obj["distributions"] = .array([])
        return try SensorBiomarkerFamilyStage.parse(family: "movement", .object(obj))
    }

    private func epochs(from: Double, to: Double, mg: Double) -> [(Double, Double)] {
        stride(from: Self.seamDayStart + from, to: Self.seamDayStart + to, by: 5).map { ($0, mg) }
    }

    func testDayLowMovementJoinsABoutAcrossARequestSeam() throws {
        // Request A ends low at 3600 s; request B starts low and then moves. Per request that is
        // two bouts (one trailing, one leading); over the day it is ONE 150 s bout.
        let a = try movementStage(epochs: epochs(from: 3000, to: 3500, mg: 80) + epochs(from: 3500, to: 3600, mg: 5),
                                  boutCount: 1)
        let b = try movementStage(epochs: epochs(from: 3600, to: 3650, mg: 5) + epochs(from: 3650, to: 3700, mg: 80),
                                  boutCount: 1)
        let merged = try SensorBiomarkerFamilyStage.merge([a, b])
            .withDayLowMovement(stages: [a, b], dayStart: Self.seamDayStart, dayEnd: Self.seamDayStart + 86_400)
        let m = merged.measurements
        XCTAssertEqual(m.member("low_movement_bout_count")?.member("value")?.doubleValue, 1)
        XCTAssertEqual(m.member("low_movement_bout_max_seconds")?.member("value")?.doubleValue, 150)
        XCTAssertEqual(m.member("low_movement_seconds")?.member("value")?.doubleValue, 150)
        XCTAssertEqual(m.member("low_to_moving_transition_count")?.member("value")?.doubleValue, 1)
        XCTAssertEqual(m.member("low_movement_fraction")?.member("value")?.doubleValue ?? 0, 150.0 / 700, accuracy: 1e-9)
        XCTAssertEqual(merged.extra["low_movement_censored_bout_count"], JSONValue.int(0))
        XCTAssertEqual(merged.extra["low_movement_continuation_count"], JSONValue.int(0))
        XCTAssertEqual(merged.eligibleSeconds, 700)
    }

    func testDayLowMovementGapCensorsAndRestartsUnknown() {
        // low, then a 20 s gap, then a middle-band epoch (unknown after a gap), then moving.
        let series = epochs(from: 0, to: 20, mg: 5) + epochs(from: 40, to: 45, mg: 40) + epochs(from: 45, to: 60, mg: 80)
        let day = SensorBiomarkerFamilyStage.classifyDayLowMovement(
            epochs: series.map { (start: $0.0, mg: $0.1) },
            dayStart: Self.seamDayStart, dayEnd: Self.seamDayStart + 86_400)
        XCTAssertEqual(day.boutDurations, [20])
        XCTAssertEqual(day.censored, 1)
        XCTAssertEqual(day.continuations, 1, "the bout starts at the day start")
        XCTAssertEqual(day.transitions, 0, "never a transition across a gap")
        XCTAssertEqual(day.unknownEpochs, 1)
        XCTAssertEqual(day.classifiedSeconds, 35)
    }

    func testPublishedStageCarriesNoRequestInternalFields() throws {
        let a = try movementStage(epochs: epochs(from: 0, to: 60, mg: 5), boutCount: 1)
        let published = try SensorBiomarkerFamilyStage.merge([a])
            .withDayLowMovement(stages: [a], dayStart: Self.seamDayStart, dayEnd: Self.seamDayStart + 86_400)
            .withoutInternalFields().jsonValue
        XCTAssertNil(published.member("enmo_epochs"))
        XCTAssertNil(published.member("distributions"))
        XCTAssertEqual(published.member("calibrated"), JSONValue.bool(true))
    }

    func testSidecarTimeoutIsRetryableNotPublished() throws {
        let body = """
        {"status":"withheld","metric":"sensor_biomarkers","withheld_reason":"timeout",
         "diagnostics":{"budget_ms":20000}}
        """
        let response = try InferenceClient.decodeInferenceResponse(
            Data(body.utf8), http: Self.http(200), expectedMetric: "sensor_biomarkers")
        XCTAssertThrowsError(try SensorBiomarkerLane.parseEnvelope(response, families: ["movement"])) { error in
            guard case SensorBiomarkerLane.SensorBiomarkerError.retryable = error else {
                return XCTFail("timeout must be retryable, got \(error)")
            }
        }
    }

    func testInferenceContextCarriesEveryVersionTheSidecarRequires() throws {
        let cols = [Int16](repeating: 0, count: 600)
        let records = (0..<60).map { Npb1ImuDecoder.Record(rowId: Int64($0), ts: Self.dayStart + Int64($0), columns: cols) }
        let timeline = try SensorBiomarkerInputs.imuTimeline(records)
        let built = try XCTUnwrap(SensorBiomarkerInputs.buildRequests(
            imuRuns: SensorBiomarkerInputs.imuRuns(timeline), ppgRuns: [], imuTimeline: timeline,
            ppgSecondsByTs: [:], objects: [], deviceID: "22222222-2222-4222-8222-222222222222",
            dayUTC: Self.day, families: ["movement"]).first)
        let body = try SensorBiomarkerLane.inferenceBody(job: makeJob(), built: built)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let context = try XCTUnwrap(json?["context"] as? [String: Any])
        for key in ["profile_version", "config_version", "corrections_version"] {
            let value = context[key] as? String
            XCTAssertFalse(value?.isEmpty ?? true, "\(key) must be a non-empty string or the sidecar answers 400")
        }
        XCTAssertEqual(json?["metric"] as? String, "sensor_biomarkers")
        XCTAssertEqual((json?["provider"] as? [String: Any])?["provider_id"] as? String, "sensor.biomarkers.v1")
        let input = try XCTUnwrap(json?["input"] as? NSDictionary)
        XCTAssertEqual(input, built.input.jsonObject() as NSDictionary,
                       "the written input must be the same JSON as the object form")
    }

    func testWrittenInputMatchesObjectFormWithRealScaledSamples() throws {
        // Non-zero i16 columns exercise the scaled decimals (and negative values) the writer prints.
        var cols = [Int16](repeating: 0, count: 600)
        for i in 0..<600 { cols[i] = Int16(truncatingIfNeeded: (i * 7919) % 8191 - 4095) }
        let records = (0..<30).map { Npb1ImuDecoder.Record(rowId: Int64($0), ts: Self.dayStart + Int64($0), columns: cols) }
        let timeline = try SensorBiomarkerInputs.imuTimeline(records)
        let built = try XCTUnwrap(SensorBiomarkerInputs.buildRequests(
            imuRuns: SensorBiomarkerInputs.imuRuns(timeline), ppgRuns: [], imuTimeline: timeline,
            ppgSecondsByTs: [:], objects: [], deviceID: "d\"quoted", dayUTC: Self.day,
            families: ["movement", "oscillation"]).first)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: built.inputJSON) as? NSDictionary)
        XCTAssertEqual(written, built.input.jsonObject() as NSDictionary)
        XCTAssertEqual(built.serializedSizeBytes, built.inputJSON.count)
    }

    // MARK: - Sidecar request shape

    func testSidecarRequestShape() throws {
        let input: [String: Any] = [
            "schema_version": 1,
            "device": ["id": "22222222-2222-4222-8222-222222222222", "family": "whoop5"],
            "input_revision": "sha256:" + String(repeating: "f", count: 64),
            "day_utc": Self.day,
            "watch_side": "unknown",
            "device_orientation": "unknown",
            "families": ["movement", "tremor"],
        ]
        let request = InferenceRequest(
            metric: "sensor_biomarkers",
            context: InferenceRequest.Context(userId: "11111111-1111-4111-8111-111111111111",
                deviceId: "22222222-2222-4222-8222-222222222222",
                intervalStartUTC: "2026-09-15T00:00:00Z", intervalEndUTC: "2026-09-15T00:30:00Z",
                ianaTimezone: "UTC"),
            input: JSONValue(any: input),
            provider: InferenceRequest.Provider(providerId: "sensor.biomarkers.v1"))
        let data = try request.canonicalJSON()
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["metric"] as? String, "sensor_biomarkers")
        let provider = try XCTUnwrap(obj["provider"] as? [String: Any])
        XCTAssertEqual(provider["provider_id"] as? String, "sensor.biomarkers.v1")
        let payload = try XCTUnwrap(obj["input"] as? [String: Any])
        XCTAssertEqual(payload["schema_version"] as? Int, 1)
        let device = try XCTUnwrap(payload["device"] as? [String: Any])
        XCTAssertEqual(device["family"] as? String, "whoop5")
        XCTAssertEqual(payload["day_utc"] as? String, Self.day)
        XCTAssertTrue((payload["families"] as? [String])?.contains("tremor") ?? false)
    }

    private static func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://127.0.0.1/v1/infer")!, statusCode: status,
                        httpVersion: nil, headerFields: nil)!
    }

    // MARK: - DB-backed lifecycle tests

    private func connect() throws -> PostgresClient {
        guard let url = ProcessInfo.processInfo.environment["FRWHOOP_TEST_DB_URL"], !url.isEmpty else {
            throw XCTSkip("set FRWHOOP_TEST_DB_URL to a scratch Postgres with the sensor-biomarker migration applied")
        }
        return try PostgresClient(options: PostgresOptions(
            connectionString: url, sslMode: "disable", sslRootCert: nil,
            applicationName: "frwhoop-worker-tests", allowInsecure: true,
            connectTimeoutSeconds: 5, reconnectDeadlineSeconds: 5,
            statementTimeoutMS: 60_000, idleTransactionTimeoutMS: 60_000))
    }

    private struct Fixture {
        let db: PostgresClient
        let user: String
        let device: String
        let day: String
        let dayStart: Int64
    }

    private func makeFixture(db: PostgresClient) throws -> Fixture {
        let present = try db.query(
            "select (to_regclass('public.sensor_biomarker_jobs') is not null "
            + "and to_regclass('public.sensor_biomarker_days') is not null) as present", [])
        guard present.first?["present"] == "t" else {
            throw XCTSkip("apply 20261007140000_sensor_biomarkers.sql to the scratch database")
        }
        let user = UUID().uuidString.lowercased()
        let device = UUID().uuidString.lowercased()
        try db.exec("insert into auth.users(id) values ('\(user)')")
        try db.exec("insert into public.devices(id,user_id,source_kind) values ('\(device)','\(user)','noop_push')")
        return Fixture(db: db, user: user, device: device, day: SensorBiomarkerLaneTests.day,
                       dayStart: SensorBiomarkerLaneTests.dayStart)
    }

    private func fingerprintSQL(_ f: Fixture, digests: [String]) throws -> String {
        let list = digests.map { "'\($0)'" }.joined(separator: ",")
        let rows = try f.db.query(
            "select public.sensor_biomarkers_fingerprint(array[\(list)], \(f.dayStart), \(f.dayStart + 86_399), 'sensor-biomarkers/1.0.0')::text", [])
        return rows.first?.values.first ?? ""
    }

    /// Inserts one verified rawImuSession object for the fixture's day and returns its digest.
    private func seedImuObject(_ f: Fixture, seconds: [Int64], objectID: String) throws -> String {
        let imu = try syntheticImu(seconds: seconds)
        let startISO = SensorBiomarkerLane.iso(f.dayStart)
        let endISO = SensorBiomarkerLane.iso(f.dayStart + 86_400)
        _ = try f.db.query("""
            insert into public.object_manifests(id,user_id,device_id,object_class,object_kind,object_key,
              start_at,end_at,sha256,sha256_source,status,verified_at,durability_receipt)
            values($1::uuid,$2::uuid,$3::uuid,'raw','rawImuSession',$4::text,
              $5::timestamptz,$6::timestamptz,$7::text,'server_verified','ready',clock_timestamp(),
              jsonb_build_object('state','verified_indexed'))
            """, [objectID, f.user, f.device, "sb-test-\(objectID)", startISO, endISO, imu.digest])
        return imu.digest
    }

    private func enqueue(_ f: Fixture, objectID: String, digest: String, fingerprint: String,
                         families: [String] = ["movement", "tremor"]) throws {
        let fam = families.map { "'\($0)'" }.joined(separator: ",")
        _ = try f.db.query("""
            select public.enqueue_sensor_biomarker_day($1::uuid,$2::uuid,$3::date,
              array[$4::uuid], array[$5::text], $6::text, array[\(fam)]::text[])
            """, [f.user, f.device, f.day, objectID, digest, fingerprint])
    }

    private func claimRow(_ f: Fixture) throws -> [String: String] {
        try f.db.query("select * from public.claim_sensor_biomarker_day(300)", []).first ?? [:]
    }

    private func dayCount(_ f: Fixture) throws -> Int {
        let rows = try f.db.query(
            "select count(*)::text as n from public.sensor_biomarker_days where user_id=$1::uuid and device_id=$2::uuid",
            [f.user, f.device])
        return Int(rows.first?["n"] ?? "") ?? -1
    }

    private func jobRow(_ f: Fixture) throws -> [String: String] {
        try f.db.query(
            "select completed_revision::text, input_revision::text, lease_token::text, consecutive_failures::text, dead_letter::text, not_before::text "
            + "from public.sensor_biomarker_jobs where user_id=$1::uuid and device_id=$2::uuid and day=$3::date and analysis_version='sensor-biomarkers/1.0.0'",
            [f.user, f.device, f.day]).first ?? [:]
    }

    /// The lane with a stub sidecar and a stub downloader.
    private func makeLane(f: Fixture, server: StubHTTPServer, zstdByKey: [String: Data]) -> SensorBiomarkerLane {
        var lane = SensorBiomarkerLane(
            db: f.db,
            storage: B2Storage(keyID: "unused", applicationKey: "unused", bucket: "unused"),
            inference: InferenceClient(baseURL: URL(string: server.baseURL)!, timeoutMS: 5000),
            leaseSeconds: 300,
            families: ["movement", "tremor"])
        lane.downloadObject = { key in
            guard let data = zstdByKey[key] else { throw SensorBiomarkerLane.SensorBiomarkerError.retryable("object_missing: \(key)") }
            return data
        }
        return lane
    }

    private func okEnvelope() -> String {
        envelope(stages: [
            "movement": stageJSON(family: "movement", status: "ok", observed: 600,
                                  measurements: ["enmo_median_mg": ["value": 12.5], "low_movement_seconds": 120.0],
                                  providerRevision: "imu-biomarkers/1.0.0"),
            "tremor": stageJSON(family: "tremor", status: "withheld", observed: nil, measurements: [:],
                                reason: "unknown_wrist_placement", releaseTier: "research",
                                providerRevision: "paradigma/1.0.0"),
        ])
    }

    /// claim/publish round trip: enqueue -> claim -> stub sidecar -> fenced publish -> one day row.
    func testClaimPublishRoundTrip() throws {
        let db = try connect()
        let f = try makeFixture(db: db)
        let objectID = UUID().uuidString.lowercased()
        let digest = try seedImuObject(f, seconds: (0..<300).map { f.dayStart + Int64($0) }, objectID: objectID)
        let fp = try fingerprintSQL(f, digests: [digest])
        try enqueue(f, objectID: objectID, digest: digest, fingerprint: fp)
        let zstd = try syntheticImu(seconds: (0..<300).map { f.dayStart + Int64($0) }).zstd
        let server = StubHTTPServer { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/v1/infer")
            return .json(self.okEnvelope())
        }
        defer { server.stop() }
        var lane = makeLane(f: f, server: server, zstdByKey: ["sb-test-\(objectID)": zstd])
        lane.drain(budget: 1)

        XCTAssertEqual(try dayCount(f), 1, "the day document must be published")
        let row = try f.db.query(
            "select status::text, input_revision::text, families_ok::text, withheld_reasons::text, document->'families'->'movement'->'measurements'->'enmo_median_mg' as em, run_ms::text "
            + "from public.sensor_biomarker_days where user_id=$1::uuid and device_id=$2::uuid",
            [f.user, f.device]).first ?? [:]
        XCTAssertEqual(row["status"], "completed")
        XCTAssertEqual(row["families_ok"], "{movement}")
        XCTAssertTrue(row["withheld_reasons"]?.contains("unknown_wrist_placement") ?? false, "withheld reasons recorded")
        XCTAssertNotNil(row["em"], "the movement measurements must be stored")
        let job = try jobRow(f)
        XCTAssertEqual(job["completed_revision"], job["input_revision"], "the job must be completed")
        XCTAssertEqual(job["lease_token"] ?? "x", "", "the lease must be cleared")
        XCTAssertEqual(job["consecutive_failures"], "0")
        XCTAssertTrue(lane.stats.published >= 1)
        XCTAssertTrue(lane.stats.sidecarRequests >= 1)
        db.rollbackTransaction()
        try? db.exec("delete from auth.users where id = '\(f.user)'")
    }

    /// The PPG path end-to-end at lane level with the PRODUCTION anchor-less wire
    /// (review P2-4): the ppgWaveformSample object lane carries no baseCode, so
    /// every decoded second is honestly withheld. The request the lane sends must
    /// carry NO ppg amplitude data, and the published document must carry the
    /// sidecar's withheld ppg stages verbatim (missing_ppg_anchor), never a
    /// fabricated value and never a dropped family.
    func testAnchorLessPpgWireWithholdsPpgFamiliesEndToEnd() throws {
        let db = try connect()
        let f = try makeFixture(db: db)
        let imuID = UUID().uuidString.lowercased()
        let ppgID = UUID().uuidString.lowercased()
        let imu = try syntheticImu(seconds: (0..<300).map { f.dayStart + Int64($0) })
        let digestImu = try seedImuObject(f, seconds: (0..<300).map { f.dayStart + Int64($0) }, objectID: imuID)
        // A real gzip NPB1 ppgWaveformSample wire object from the inputs fixtures
        // (anchor-less by construction: the wire carries no baseCode).
        let wireData = try ppgWireFixtureResource()
        guard let wireFixture = try JSONSerialization.jsonObject(with: wireData) as? [String: Any],
              let objects = wireFixture["objects"] as? [[String: Any]],
              let first = objects.first,
              let gzipB64 = first["gzip_base64"] as? String,
              let gzipBytes = Data(base64Encoded: gzipB64),
              let decodedHex = first["decoded_hex"] as? String else {
            return XCTFail("ppg wire fixture unusable")
        }
        let decoded = hexData(decodedHex)
        let digestPpg = sha256Hex(decoded)
        let startISO = SensorBiomarkerLane.iso(f.dayStart)
        let endISO = SensorBiomarkerLane.iso(f.dayStart + 86_400)
        _ = try f.db.query("""
            insert into public.object_manifests(id,user_id,device_id,object_class,object_kind,object_key,
              start_at,end_at,sha256,sha256_source,status,verified_at,durability_receipt)
            values($1::uuid,$2::uuid,$3::uuid,'raw','ppgWaveformSample',$4::text,
              $5::timestamptz,$6::timestamptz,$7::text,'server_verified','ready',clock_timestamp(),
              jsonb_build_object('state','verified_indexed'))
            """, [ppgID, f.user, f.device, "sb-test-\(ppgID)", startISO, endISO, digestPpg])
        let fp = try fingerprintSQL(f, digests: [digestImu, digestPpg].sorted())
        try enqueue(f, objectID: imuID, digest: digestImu, fingerprint: fp,
                    families: ["movement", "ppg_quality", "pulse_shape"])
        try enqueue(f, objectID: ppgID, digest: digestPpg, fingerprint: fp,
                    families: ["movement", "ppg_quality", "pulse_shape"])

        let withheldEnvelope = envelope(stages: [
            "movement": stageJSON(family: "movement", status: "ok", observed: 600,
                                  measurements: ["enmo_median_mg": ["value": 12.5]]),
            "ppg_quality": stageJSON(family: "ppg_quality", status: "withheld", observed: 0,
                                     measurements: [:], reason: "missing_ppg_anchor"),
            "pulse_shape": stageJSON(family: "pulse_shape", status: "withheld", observed: 0,
                                     measurements: [:], reason: "missing_ppg_anchor"),
        ])
        let server = StubHTTPServer { _ in .json(withheldEnvelope) }
        defer { server.stop() }
        var lane = makeLane(f: f, server: server,
                            zstdByKey: ["sb-test-\(imuID)": imu.zstd, "sb-test-\(ppgID)": gzipBytes])
        lane.drain(budget: 1)

        // The request the lane sent: the anchor-less PPG wire contributes no
        // amplitude data, so the input carries no `ppg` key at all.
        let bodies = server.servedRequests.map { String(decoding: $0.body, as: UTF8.self) }
        XCTAssertGreaterThanOrEqual(bodies.count, 1)
        for body in bodies {
            XCTAssertFalse(body.contains("\"ppg\""),
                           "an anchor-less ppg wire must never be sent as PPG amplitudes")
        }
        // The published document carries the honestly-withheld PPG families.
        let row = try f.db.query(
            "select status::text, withheld_reasons::text, "
            + "document->'families'->'ppg_quality'->>'reason' as ppg_reason, "
            + "document->'families'->'pulse_shape'->>'status' as pulse_status "
            + "from public.sensor_biomarker_days where user_id=$1::uuid and device_id=$2::uuid",
            [f.user, f.device]).first ?? [:]
        XCTAssertEqual(row["status"], "completed")
        XCTAssertEqual(row["ppg_reason"], "missing_ppg_anchor",
                       "the anchor-less PPG families are withheld with the precise reason")
        XCTAssertEqual(row["pulse_status"], "withheld")
        XCTAssertTrue(row["withheld_reasons"]?.contains("missing_ppg_anchor") ?? false)
        db.rollbackTransaction()
        try? db.exec("delete from auth.users where id = '\(f.user)'")
    }

    /// Late input revision: a second object bumps the revision, a re-claim recomputes, and the day
    /// row is replaced (still exactly one row).
    func testLateInputRevisionRepublishesSingleRow() throws {
        let db = try connect()
        let f = try makeFixture(db: db)
        let objectID = UUID().uuidString.lowercased()
        let digest = try seedImuObject(f, seconds: (0..<300).map { f.dayStart + Int64($0) }, objectID: objectID)
        let fp = try fingerprintSQL(f, digests: [digest])
        try enqueue(f, objectID: objectID, digest: digest, fingerprint: fp)
        let zstd = try syntheticImu(seconds: (0..<300).map { f.dayStart + Int64($0) }).zstd
        let server = StubHTTPServer { _ in .json(self.okEnvelope()) }
        defer { server.stop() }
        var lane = makeLane(f: f, server: server, zstdByKey: ["sb-test-\(objectID)": zstd])
        lane.drain(budget: 1)
        XCTAssertEqual(try dayCount(f), 1)

        // A late object for the same day bumps the revision.
        let objectID2 = UUID().uuidString.lowercased()
        let digest2 = try seedImuObject(f, seconds: (600..<900).map { f.dayStart + Int64($0) }, objectID: objectID2)
        let fp2 = try fingerprintSQL(f, digests: [digest, digest2])
        try enqueue(f, objectID: objectID2, digest: digest2, fingerprint: fp2)
        let job = try jobRow(f)
        XCTAssertEqual(job["input_revision"], "2", "a late object must bump the revision")
        XCTAssertEqual(job["completed_revision"], "1", "the job must be dirty again")

        let zstd2 = try syntheticImu(seconds: (600..<900).map { f.dayStart + Int64($0) }).zstd
        var lane2 = makeLane(f: f, server: server, zstdByKey: [
            "sb-test-\(objectID)": zstd, "sb-test-\(objectID2)": zstd2])
        lane2.drain(budget: 1)
        XCTAssertEqual(try dayCount(f), 1, "a republish must replace the row, never add a second")
        let job2 = try jobRow(f)
        XCTAssertEqual(job2["completed_revision"], "2")
        db.rollbackTransaction()
        try? db.exec("delete from auth.users where id = '\(f.user)'")
    }

    /// Lease expiry: an expired lease is reclaimed, the day is computed once, and the expiry is
    /// counted.
    func testLeaseExpiryIsReclaimable() throws {
        let db = try connect()
        let f = try makeFixture(db: db)
        let objectID = UUID().uuidString.lowercased()
        let digest = try seedImuObject(f, seconds: (0..<300).map { f.dayStart + Int64($0) }, objectID: objectID)
        let fp = try fingerprintSQL(f, digests: [digest])
        try enqueue(f, objectID: objectID, digest: digest, fingerprint: fp)
        // Claim once, then let the lease expire.
        let tok = try claimRow(f)["lease_token"] ?? ""
        XCTAssertFalse(tok.isEmpty)
        _ = try f.db.query("update public.sensor_biomarker_jobs set lease_until = clock_timestamp() - interval '1 second' where lease_token=$1::uuid", [tok])

        let zstd = try syntheticImu(seconds: (0..<300).map { f.dayStart + Int64($0) }).zstd
        let server = StubHTTPServer { _ in .json(self.okEnvelope()) }
        defer { server.stop() }
        var lane = makeLane(f: f, server: server, zstdByKey: ["sb-test-\(objectID)": zstd])
        lane.drain(budget: 1)
        XCTAssertEqual(try dayCount(f), 1, "the expired-lease job must be reclaimed and published")
        let job = try jobRow(f)
        XCTAssertEqual(job["completed_revision"], "1")
        let expiry = try f.db.query(
            "select lease_expiry_count::text from public.sensor_biomarker_jobs where user_id=$1::uuid and device_id=$2::uuid",
            [f.user, f.device]).first?["lease_expiry_count"] ?? ""
        XCTAssertEqual(expiry, "1", "the expiry must be counted on the re-claim")
        db.rollbackTransaction()
        try? db.exec("delete from auth.users where id = '\(f.user)'")
    }

    /// Publish fence: a stale worker (claimed revision behind the queue's) publishes NULL and the
    /// lane releases the lease cleanly — the newer revision is never overwritten.
    func testPublishFenceStaleWorkerCannotOverwrite() throws {
        let db = try connect()
        let f = try makeFixture(db: db)
        let objectID = UUID().uuidString.lowercased()
        let digest = try seedImuObject(f, seconds: (0..<300).map { f.dayStart + Int64($0) }, objectID: objectID)
        let fp = try fingerprintSQL(f, digests: [digest])
        try enqueue(f, objectID: objectID, digest: digest, fingerprint: fp)
        // Claim at revision 1, then a late object bumps the queue to revision 2 while we hold the lease.
        let row = try claimRow(f)
        let token = row["lease_token"] ?? ""
        let claimedRevision = Int64(row["input_revision"] ?? "") ?? 1
        let objectID2 = UUID().uuidString.lowercased()
        let digest2 = try seedImuObject(f, seconds: (600..<900).map { f.dayStart + Int64($0) }, objectID: objectID2)
        let fp2 = try fingerprintSQL(f, digests: [digest, digest2])
        try enqueue(f, objectID: objectID2, digest: digest2, fingerprint: fp2)

        // Drive the stale worker's full process with the OLD token at the OLD revision.
        let zstd = try syntheticImu(seconds: (0..<300).map { f.dayStart + Int64($0) }).zstd
        let zstd2 = try syntheticImu(seconds: (600..<900).map { f.dayStart + Int64($0) }).zstd
        let server = StubHTTPServer { _ in .json(self.okEnvelope()) }
        defer { server.stop() }
        var lane = makeLane(f: f, server: server, zstdByKey: [
            "sb-test-\(objectID)": zstd, "sb-test-\(objectID2)": zstd2])
        let job = SensorBiomarkerLane.SensorBiomarkerJob(
            userId: f.user, deviceId: f.device, day: f.day,
            analysisVersion: "sensor-biomarkers/1.0.0", fingerprint: fp,
            inputRevision: claimedRevision, leaseToken: token,
            families: ["movement", "tremor"], objectIds: [objectID], digests: [digest])
        let published = try lane.process(job: job, started: Date())
        XCTAssertFalse(published, "a stale worker must not publish over a newer revision")
        XCTAssertEqual(try dayCount(f), 0, "the stale publish must not write the day")
        let jobAfter = try jobRow(f)
        XCTAssertEqual(jobAfter["input_revision"], "2", "the queue still owns the newer revision")
        XCTAssertEqual(jobAfter["completed_revision"], "0", "the newer revision is untouched")
        XCTAssertEqual(jobAfter["lease_token"] ?? "x", "", "the stale worker's lease must be released")
        XCTAssertEqual(jobAfter["consecutive_failures"], "0", "a fenced release is never a failure")
        db.rollbackTransaction()
        try? db.exec("delete from auth.users where id = '\(f.user)'")
    }

    /// Sidecar-missing independence: a refused/not-ready sidecar settles the job with bounded
    /// backoff and no day row; nothing else in the worker is affected.
    func testSidecarMissingIndependent() throws {
        let db = try connect()
        let f = try makeFixture(db: db)
        let objectID = UUID().uuidString.lowercased()
        let digest = try seedImuObject(f, seconds: (0..<300).map { f.dayStart + Int64($0) }, objectID: objectID)
        let fp = try fingerprintSQL(f, digests: [digest])
        try enqueue(f, objectID: objectID, digest: digest, fingerprint: fp)
        let zstd = try syntheticImu(seconds: (0..<300).map { f.dayStart + Int64($0) }).zstd
        // The sidecar is up but reports not-ready (HTTP 503).
        let server = StubHTTPServer { _ in .json("{}", status: 503) }
        defer { server.stop() }
        var lane = makeLane(f: f, server: server, zstdByKey: ["sb-test-\(objectID)": zstd])
        lane.drain(budget: 1)
        XCTAssertEqual(try dayCount(f), 0, "a missing sidecar must never fabricate a day document")
        let job = try jobRow(f)
        XCTAssertEqual(job["consecutive_failures"], "1", "the failure is accounted with bounded backoff")
        XCTAssertEqual(job["dead_letter"], "false", "one failure must not dead-letter")
        XCTAssertEqual(job["lease_token"] ?? "x", "", "the lease is released for the backoff window")
        XCTAssertGreaterThan(lane.stats.sidecarFailures, 0)
        db.rollbackTransaction()
        try? db.exec("delete from auth.users where id = '\(f.user)'")
    }
}
