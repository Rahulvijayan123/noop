import XCTest
import CZstd
import WhoopProtocol
@testable import frwhoop_worker

/// W1: the typed raw-input layer for the sensor-biomarker lane
/// (`SensorBiomarkerInputs`): verified object resolution for a (user, device,
/// UTC day), NPB1 IMU + PPG object decode with digest verification, physical
/// reconstruction with units/timing, PPG anchor/delta reconstruction with
/// fail-closed withholding, and the CONTRACTS §4 sidecar request input.
///
/// Fixtures live under `Resources/sensor_biomarkers/` (see the README there);
/// they are small synthetic byte payloads with explicit expected values, plus
/// the two already-published real WhoopProtocol v26 frames.
final class SensorBiomarkerInputsTests: XCTestCase {

    // MARK: - Fixture loading

    private func sensorJSON(_ name: String) throws -> [String: Any] {
        let data = try SensorFixturePaths.data(SensorFixturePaths.sensor(name))
        return try XCTUnwrap((try JSONSerialization.jsonObject(with: data)) as? [String: Any],
                             "fixture \(name) is not a JSON object")
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

    private func sha256HexLocal(_ data: Data) -> String {
        // Reuses the worker's own global helper (same CCrypto-backed SHA-256);
        // the point of the cross-check is the digest value, not a second API.
        sha256Hex(data)
    }

    private func object(id: String, kind: String, key: String, digest: String,
                        start: Int64? = nil, end: Int64? = nil) -> SensorBiomarkerInputs.InputObject {
        SensorBiomarkerInputs.InputObject(id: id, objectKind: kind, objectKey: key,
                                          digest: digest, startTs: start, endTs: end)
    }

    private func row(_ dict: [String: String]) -> [String: String] { dict }

    /// Build a `PpgWaveformInput` from one `sensor_biomarkers_ppg_records.json`
    /// record (including the optional side-channel optical config).
    private func ppgInput(from r: [String: Any]) -> SensorBiomarkerInputs.PpgWaveformInput {
        SensorBiomarkerInputs.PpgWaveformInput(
            rowId: Int64(r["rowId"] as? Int ?? 0),
            ts: Int64(r["ts"] as! Int),
            samples: (r["samples"] as! [Int]).map { Int16(clamping: $0) },
            burstIndex: (r["burstIndex"] as? Int).map { Int32($0) },
            baseCode: (r["baseCode"] as? Int).map { Int32($0) },
            config: (r["config"] as? [String: Any]).map { cfg in
                SensorBiomarkerInputs.PpgOpticalConfig(
                    sourceA: cfg["sourceA"] as? Int, driveA: cfg["driveA"] as? Int,
                    sourceB: cfg["sourceB"] as? Int, driveB: cfg["driveB"] as? Int,
                    rangeA: cfg["rangeA"] as? Int, offsetA: cfg["offsetA"] as? Int,
                    rangeB: cfg["rangeB"] as? Int, offsetB: cfg["offsetB"] as? Int)
            })
    }

    // MARK: - Object resolution (pure)

    func testObjectResolutionSQLAndParams() throws {
        XCTAssertTrue(SensorBiomarkerInputs.objectResolutionSQL.contains(
            "durability_receipt->>'state' = 'verified_indexed'"), "the SQL must gate on verified_indexed")
        XCTAssertTrue(SensorBiomarkerInputs.objectResolutionSQL.contains(
            "m.status = 'ready'"), "the SQL must gate on status = ready")
        XCTAssertTrue(SensorBiomarkerInputs.objectResolutionSQL.contains(
            "object_manifests"), "the SQL must read object_manifests (the ActivityLane table)")
        // rawImuSession AND ppgWaveformSample are both resolved (CONTRACTS §5).
        XCTAssertTrue(SensorBiomarkerInputs.objectResolutionSQL.contains("any($3::text[])"))
        XCTAssertEqual(SensorBiomarkerInputs.supportedKinds,
                       [SensorBiomarkerInputs.kindRawImuSession,
                        SensorBiomarkerInputs.kindPpgWaveformSample])
        // A UTC day resolves to [start, start+86400); the SQL overlaps the day.
        let params = try XCTUnwrap(SensorBiomarkerInputs.objectResolutionParams(
            userId: "u", deviceId: "d", day: "2026-10-06"))
        XCTAssertEqual(params.count, 5)
        XCTAssertEqual(params[0], "u")
        XCTAssertEqual(params[1], "d")
        XCTAssertEqual(params[2], "{\"rawImuSession\",\"ppgWaveformSample\"}")
        XCTAssertEqual(params[3], "2026-10-07T00:00:00Z")   // day end, exclusive
        XCTAssertEqual(params[4], "2026-10-06T00:00:00Z")   // day start, inclusive
        XCTAssertNil(SensorBiomarkerInputs.objectResolutionParams(userId: "u", deviceId: "d", day: "not-a-day"))
    }

    func testParseObjectRowsResolvesVerifiedObjects() throws {
        let rows = [
            row(["id": "11111111-1111-4111-8111-111111111111", "object_key": "v3/research/imu-a",
                 "object_kind": "rawImuSession", "status": "ready", "receipt_state": "verified_indexed",
                 "sha256": String(repeating: "a", count: 64), "user_id": "U", "device_id": "D",
                 "start_ts": "100", "end_ts": "200"]),
            row(["id": "22222222-2222-4222-8222-222222222222", "object_key": "v3/research/ppg-a",
                 "object_kind": "ppgWaveformSample", "status": "ready", "receipt_state": "verified_indexed",
                 "sha256": String(repeating: "b", count: 64), "user_id": "U", "device_id": "D",
                 "start_ts": "150", "end_ts": "250"]),
        ]
        let resolved = try SensorBiomarkerInputs.parseObjectRows(rows, userId: "U", deviceId: "D")
        XCTAssertEqual(resolved.imu.count, 1)
        XCTAssertEqual(resolved.ppg.count, 1)
        XCTAssertEqual(resolved.imu[0].objectKey, "v3/research/imu-a")
        XCTAssertEqual(resolved.ppg[0].objectKey, "v3/research/ppg-a")
        XCTAssertEqual(resolved.imu[0].digest, String(repeating: "a", count: 64))
        XCTAssertEqual(resolved.imu[0].startTs, 100)
        XCTAssertEqual(resolved.ppg[0].endTs, 250)
        XCTAssertFalse(resolved.isEmpty)
    }

    func testParseObjectRowsSortsDeterministically() throws {
        let mk = { (id: String, kind: String, start: String) in
            self.row(["id": id, "object_key": "k/" + id, "object_kind": kind,
                      "status": "ready", "receipt_state": "verified_indexed",
                      "sha256": String(repeating: "c", count: 64), "user_id": "U", "device_id": "D",
                      "start_ts": start, "end_ts": start])
        }
        let rows = [mk("33333333-3333-4333-8333-333333333333", "rawImuSession", "300"),
                    mk("11111111-1111-4111-8111-111111111111", "rawImuSession", "100"),
                    mk("22222222-2222-4222-8222-222222222222", "rawImuSession", "100"),
                    mk("44444444-4444-4444-8444-444444444444", "ppgWaveformSample", "100")]
        let resolved = try SensorBiomarkerInputs.parseObjectRows(rows, userId: "U", deviceId: "D")
        // imu sorted by (start, id); ppg in its own list.
        XCTAssertEqual(resolved.imu.map(\.id),
                       ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222",
                        "33333333-3333-4333-8333-333333333333"])
        XCTAssertEqual(resolved.ppg.count, 1)
    }

    func testParseObjectRowsRejectsMixedOwner() {
        let rows = [row(["id": "11111111-1111-4111-8111-111111111111", "object_key": "k",
                         "object_kind": "rawImuSession", "status": "ready", "receipt_state": "verified_indexed",
                         "sha256": String(repeating: "a", count: 64), "user_id": "OTHER", "device_id": "D"])]
        XCTAssertThrowsError(try SensorBiomarkerInputs.parseObjectRows(rows, userId: "U", deviceId: "D")) { error in
            XCTAssertEqual(error as? SensorBiomarkerInputs.ResolutionError,
                           .mixedOwner("11111111-1111-4111-8111-111111111111"))
        }
    }

    func testParseObjectRowsRejectsMixedDevice() {
        let rows = [row(["id": "11111111-1111-4111-8111-111111111111", "object_key": "k",
                         "object_kind": "rawImuSession", "status": "ready", "receipt_state": "verified_indexed",
                         "sha256": String(repeating: "a", count: 64), "user_id": "U", "device_id": "OTHER"])]
        XCTAssertThrowsError(try SensorBiomarkerInputs.parseObjectRows(rows, userId: "U", deviceId: "D")) { error in
            XCTAssertEqual(error as? SensorBiomarkerInputs.ResolutionError,
                           .mixedDevice("11111111-1111-4111-8111-111111111111"))
        }
    }

    func testParseObjectRowsRejectsUnverifiedStates() {
        let base: [String: String] = ["id": "11111111-1111-4111-8111-111111111111", "object_key": "k",
                                      "object_kind": "rawImuSession", "sha256": String(repeating: "a", count: 64),
                                      "user_id": "U", "device_id": "D"]
        // status pending -> rejected.
        var pending = base
        pending["status"] = "pending"
        pending["receipt_state"] = "verified_indexed"
        XCTAssertThrowsError(try SensorBiomarkerInputs.parseObjectRows([pending], userId: "U", deviceId: "D")) { e in
            XCTAssertEqual(e as? SensorBiomarkerInputs.ResolutionError,
                           .notReady("11111111-1111-4111-8111-111111111111"))
        }
        // verified but NOT indexed -> rejected.
        var notIndexed = base
        notIndexed["status"] = "ready"
        notIndexed["receipt_state"] = "client_claimed"
        XCTAssertThrowsError(try SensorBiomarkerInputs.parseObjectRows([notIndexed], userId: "U", deviceId: "D")) { e in
            XCTAssertEqual(e as? SensorBiomarkerInputs.ResolutionError,
                           .notVerifiedIndexed("11111111-1111-4111-8111-111111111111"))
        }
    }

    func testParseObjectRowsRejectsMissingDigestAndUnknownKind() throws {
        let base: [String: String] = ["id": "11111111-1111-4111-8111-111111111111", "object_key": "k",
                                      "object_kind": "rawImuSession", "status": "ready",
                                      "receipt_state": "verified_indexed", "user_id": "U", "device_id": "D"]
        var noDigest = base
        noDigest["sha256"] = ""
        XCTAssertThrowsError(try SensorBiomarkerInputs.parseObjectRows([noDigest], userId: "U", deviceId: "D")) { e in
            XCTAssertEqual(e as? SensorBiomarkerInputs.ResolutionError,
                           .missingDigest("11111111-1111-4111-8111-111111111111"))
        }
        var badKind = base
        badKind["object_kind"] = "rawBatch"
        badKind["sha256"] = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try SensorBiomarkerInputs.parseObjectRows([badKind], userId: "U", deviceId: "D")) { e in
            XCTAssertEqual(e as? SensorBiomarkerInputs.ResolutionError, .unknownKind("rawBatch"))
        }
        // No rows -> empty resolution (the lane answers artifact_unavailable), not an error.
        let empty = try SensorBiomarkerInputs.parseObjectRows([], userId: "U", deviceId: "D")
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - Verified object loading + digest

    func testImuVerifiedLoadDecodesAndDigestChecks() throws {
        let fixture = try sensorJSON("sensor_biomarkers_imu.json")
        let wire = Data(base64Encoded: try XCTUnwrap(fixture["zstd_base64"] as? String))!
        let digest = try XCTUnwrap(fixture["decoded_sha256"] as? String)
        let object = object(id: "imu-1", kind: SensorBiomarkerInputs.kindRawImuSession,
                            key: "v3/research/imu-1", digest: digest)
        let records = try SensorBiomarkerInputs.decodeImuObject(wire: wire, object: object)
        XCTAssertEqual(records.count, fixture["record_count"] as? Int)
        // The digest that was verified is the DECODED-content digest (the
        // worker verifies sha256(decompressed) — never the wire bytes), and it
        // equals the fixture's independently recorded value.
        let decoded = try VerificationLane.zstdDecompress(wire)
        XCTAssertEqual(sha256HexLocal(decoded), fixture["decoded_sha256"] as? String)
    }

    func testImuDigestMismatchNeverBecomesData() throws {
        let fixture = try sensorJSON("sensor_biomarkers_imu.json")
        let wire = Data(base64Encoded: try XCTUnwrap(fixture["zstd_base64"] as? String))!
        let object = object(id: "imu-bad", kind: SensorBiomarkerInputs.kindRawImuSession,
                            key: "v3/research/imu-bad", digest: String(repeating: "e", count: 64))
        XCTAssertThrowsError(try SensorBiomarkerInputs.decodeImuObject(wire: wire, object: object)) { error in
            guard case .digestMismatch(let id, _, _) = error as! SensorBiomarkerInputs.LoadError else {
                return XCTFail("expected digestMismatch, got \(error)")
            }
            XCTAssertEqual(id, "imu-bad")
        }
    }

    func testPpgVerifiedLoadDecodesAndDigestChecks() throws {
        let fixture = try sensorJSON("sensor_biomarkers_ppg_wire.json")
        let objects = try XCTUnwrap(fixture["objects"] as? [[String: Any]])
        for entry in objects {
            let wire = Data(base64Encoded: try XCTUnwrap(entry["gzip_base64"] as? String))!
            let digest = try XCTUnwrap(entry["decoded_sha256"] as? String)
            let object = object(id: "ppg-" + (entry["name"] as! String),
                                kind: SensorBiomarkerInputs.kindPpgWaveformSample,
                                key: "v3/research/" + (entry["name"] as! String), digest: digest)
            let records = try SensorBiomarkerInputs.decodePpgObject(wire: wire, object: object)
            XCTAssertEqual(records.count, entry["record_count"] as? Int,
                           "record count for \(entry["name"]!)")
            let expectedTS = try XCTUnwrap(entry["expected_ts"] as? [Int64])
            XCTAssertEqual(records.map(\.ts), expectedTS, "ts order for \(entry["name"]!)")
        }
    }

    func testPpgDigestMismatchNeverBecomesData() throws {
        let fixture = try sensorJSON("sensor_biomarkers_ppg_wire.json")
        let objects = try XCTUnwrap(fixture["objects"] as? [[String: Any]])
        let entry = try XCTUnwrap(objects.first)
        let wire = Data(base64Encoded: try XCTUnwrap(entry["gzip_base64"] as? String))!
        let object = object(id: "ppg-bad", kind: SensorBiomarkerInputs.kindPpgWaveformSample,
                            key: "v3/research/ppg-bad", digest: String(repeating: "f", count: 64))
        XCTAssertThrowsError(try SensorBiomarkerInputs.decodePpgObject(wire: wire, object: object)) { error in
            guard case .digestMismatch = error as! SensorBiomarkerInputs.LoadError else {
                return XCTFail("expected digestMismatch, got \(error)")
            }
        }
    }

    func testPpgWireObjectsCarryNoAnchor() throws {
        // The ppgWaveformSample wire does not carry the absolute optical anchor
        // (it is a phone-side DB column), so every wire record decodes with
        // baseCode == nil and those seconds are withheld missing_ppg_anchor —
        // never sent as amplitudes.
        let fixture = try sensorJSON("sensor_biomarkers_ppg_wire.json")
        let objects = try XCTUnwrap(fixture["objects"] as? [[String: Any]])
        var allInputs: [SensorBiomarkerInputs.PpgWaveformInput] = []
        for entry in objects {
            let wire = Data(base64Encoded: try XCTUnwrap(entry["gzip_base64"] as? String))!
            let digest = try XCTUnwrap(entry["decoded_sha256"] as? String)
            let object = object(id: "p", kind: SensorBiomarkerInputs.kindPpgWaveformSample,
                                key: "k", digest: digest)
            let records = try SensorBiomarkerInputs.decodePpgObject(wire: wire, object: object)
            allInputs.append(contentsOf: records.map { SensorBiomarkerInputs.PpgWaveformInput(wireRecord: $0) })
        }
        XCTAssertTrue(allInputs.allSatisfy { $0.baseCode == nil },
                      "the v1/v2 wire never carries baseCode")
        let reconstruction = SensorBiomarkerInputs.reconstructPPG(records: allInputs)
        XCTAssertTrue(reconstruction.seconds.allSatisfy { $0.withheldReason != nil },
                      "anchor-less wire records must never emit amplitudes")
        // 11 unique seconds: 9 withhold as missing_ppg_anchor; ts 1005 carries 25
        // deltas (unsupported_native_rate, detected) and ts 1006 is an empty slot.
        XCTAssertEqual(reconstruction.seconds.count, 11)
        XCTAssertEqual(reconstruction.reasonCounts[SensorBiomarkerInputs.reasonMissingPpgAnchor], 9)
        XCTAssertEqual(reconstruction.reasonCounts[SensorBiomarkerInputs.reasonUnsupportedNativeRate], 1)
        XCTAssertEqual(reconstruction.reasonCounts[SensorBiomarkerInputs.reasonArtifactUnavailable], 1)
        XCTAssertTrue(reconstruction.runs.isEmpty, "no emitted seconds -> no runs")
        XCTAssertNil(reconstruction.nativeRateHz, "25-delta records make the native rate unverified")
    }

    func testPpgCodecRejectsCorruptWire() throws {
        let fixture = try sensorJSON("sensor_biomarkers_ppg_wire.json")
        let objects = try XCTUnwrap(fixture["objects"] as? [[String: Any]])
        let entry = try XCTUnwrap(objects.first)
        var bytes = Data(base64Encoded: try XCTUnwrap(entry["gzip_base64"] as? String))!
        bytes = try Inflator.gunzip(bytes)   // decoded NPB1 bytes
        let codec = SensorBiomarkerInputs.PpgCodec.self
        // wrong magic
        var badMagic = bytes
        badMagic[0] = 0x41
        XCTAssertThrowsError(try codec.unpack(badMagic)) { e in
            XCTAssertEqual(e as? SensorBiomarkerInputs.PpgCodec.CodecError, .notNpb1)
        }
        // unsupported version (formats 1-3 decode; 4 is unknown)
        var badVersion = bytes
        badVersion[4] = 4
        XCTAssertThrowsError(try codec.unpack(badVersion)) { e in
            XCTAssertEqual(e as? SensorBiomarkerInputs.PpgCodec.CodecError, .unsupportedVersion(4))
        }
        // wrong kind
        var badKind = bytes
        badKind[5] = 4
        XCTAssertThrowsError(try codec.unpack(badKind)) { e in
            XCTAssertEqual(e as? SensorBiomarkerInputs.PpgCodec.CodecError, .unsupportedKind(4))
        }
        // truncation
        XCTAssertThrowsError(try codec.unpack(bytes.prefix(bytes.count - 5))) { e in
            guard case .truncated = e as! SensorBiomarkerInputs.PpgCodec.CodecError else {
                return XCTFail("expected truncated, got \(e)")
            }
        }
        // trailing bytes
        XCTAssertThrowsError(try codec.unpack(bytes + Data([0]))) { e in
            guard case .trailingBytes(1) = e as! SensorBiomarkerInputs.PpgCodec.CodecError else {
                return XCTFail("expected trailingBytes(1), got \(e)")
            }
        }
        // empty object
        var empty = Data("NPB1".utf8)
        empty.append(contentsOf: [1, 1, 0, 0, 0, 0])
        XCTAssertThrowsError(try codec.unpack(empty)) { e in
            XCTAssertEqual(e as? SensorBiomarkerInputs.PpgCodec.CodecError, .emptyObject)
        }
    }

    // MARK: - IMU decode

    func testImuSamplesConversionTimestampsAndGravity() throws {
        let fixture = try sensorJSON("sensor_biomarkers_imu.json")
        let wire = Data(base64Encoded: try XCTUnwrap(fixture["zstd_base64"] as? String))!
        let digest = try XCTUnwrap(fixture["decoded_sha256"] as? String)
        let object = object(id: "imu", kind: SensorBiomarkerInputs.kindRawImuSession,
                            key: "k", digest: digest)
        let records = try SensorBiomarkerInputs.decodeImuObject(wire: wire, object: object)
        XCTAssertEqual(records.count, 4)

        // First record: stationary, az = 4096 counts = exactly 1.0 g,
        // gz = 16384 counts = exactly 1000.0 deg/s (2000/32768 * 16384).
        let first = try XCTUnwrap(records.first)
        let samples = SensorBiomarkerInputs.imuSamples(record: first)
        XCTAssertEqual(samples.count, SensorBiomarkerInputs.imuNativeRateHz)
        let expected = fixture["expected"] as! [String: Any]
        let firstExpected = expected["first"] as! [String: Any]
        let s0 = samples[0]
        XCTAssertEqual(s0.t, Double(first.ts) + 0.0 / 100.0)
        XCTAssertEqual(s0.ax, 0.0, accuracy: 1e-9)
        XCTAssertEqual(s0.ay, 0.0, accuracy: 1e-9)
        XCTAssertEqual(s0.az, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s0.gx, 0.0, accuracy: 1e-6)
        XCTAssertEqual(s0.gy, 0.0, accuracy: 1e-6)
        XCTAssertEqual(s0.gz, 1000.0, accuracy: 1e-9)
        // 100 Hz timestamps: sample i at ts + i/100.
        XCTAssertEqual(samples[50].t, Double(first.ts) + 0.5, accuracy: 1e-9)
        XCTAssertEqual(samples[99].t, Double(first.ts) + 0.99, accuracy: 1e-9)
        // The scales are the decoder's own (1/4096 g, 2000/32768 deg/s) —
        // integer -> physical conversion is exact for these count values.
        let accelScale = try XCTUnwrap(expected["accel_scale"] as? Double)
        let gyroScale = try XCTUnwrap(expected["gyro_scale"] as? Double)
        XCTAssertEqual(s0.az, Double(4096) * accelScale, accuracy: 1e-12)
        XCTAssertEqual(s0.gz, Double(16384) * gyroScale, accuracy: 1e-9)

        // Known gravity orientation: stationary seconds give |a| ≈ 1 g.
        let orientTS = (expected["orient_ts"] as! Int64)
        let orientRecord = try XCTUnwrap(records.first { $0.ts == orientTS })
        let orientSamples = SensorBiomarkerInputs.imuSamples(record: orientRecord)
        for sample in orientSamples {
            let magnitude = (sample.ax * sample.ax + sample.ay * sample.ay + sample.az * sample.az).squareRoot()
            XCTAssertEqual(magnitude, expected["orient_magnitude_g"] as! Double, accuracy: 1e-6,
                           "stationary wrist keeps |accel| ~ 1 g")
        }
    }

    func testImuGapSplitsRunsNeverFills() throws {
        let fixture = try sensorJSON("sensor_biomarkers_imu.json")
        let wire = Data(base64Encoded: try XCTUnwrap(fixture["zstd_base64"] as? String))!
        let digest = try XCTUnwrap(fixture["decoded_sha256"] as? String)
        let object = object(id: "imu", kind: SensorBiomarkerInputs.kindRawImuSession,
                            key: "k", digest: digest)
        let records = try SensorBiomarkerInputs.decodeImuObject(wire: wire, object: object)
        let timeline = try SensorBiomarkerInputs.imuTimeline(records)
        XCTAssertEqual(timeline.seconds, [1_758_001_000, 1_758_001_001, 1_758_001_002, 1_758_001_004])
        let runs = SensorBiomarkerInputs.imuRuns(timeline)
        XCTAssertEqual(runs.count, 2, "second 1758001003 is missing -> two runs, no fill")
        XCTAssertEqual(runs[0], ActivityLane.Run(start: 1_758_001_000, end: 1_758_001_003))
        XCTAssertEqual(runs[1], ActivityLane.Run(start: 1_758_001_004, end: 1_758_001_005))
    }

    func testImuSegmentsEndpointOwnershipAndTimestamps() throws {
        let cols = [Int16](repeating: 0, count: 600)
        let records = (100..<1000).map { ts in
            Npb1ImuDecoder.Record(rowId: Int64(ts), ts: Int64(ts), columns: cols)
        }
        let timeline = try SensorBiomarkerInputs.imuTimeline(records)
        let run = ActivityLane.Run(start: 100, end: 1000)
        let segments = SensorBiomarkerInputs.imuSegments(run: run, timeline: timeline, maxDuration: 300)
        XCTAssertEqual(segments.count, 3)
        // Exactly 300 s of 100 Hz per segment, contiguous and endpoint-owned.
        for segment in segments {
            XCTAssertEqual(segment.durationS, 300)
            XCTAssertEqual(segment.accelG.count, 300 * 100)
            XCTAssertEqual(segment.gyroDps.count, 300 * 100)
        }
        XCTAssertEqual(segments[0].startUnix, 100)
        XCTAssertEqual(segments[1].startUnix, 400)
        XCTAssertEqual(segments[2].startUnix, 700)
        // Endpoint ownership: segment 1 covers [100, 400); its last sample is at
        // 399 + 99/100 and its first at 100. Segment 2 starts at 400. No shared
        // endpoint sample and no omitted second.
        let firstSegment = segments[0]
        let s0 = SensorBiomarkerInputs.imuSamples(record: Npb1ImuDecoder.Record(
            rowId: 100, ts: 100, columns: [Int16](repeating: 0, count: 600)))[0]
        XCTAssertEqual(s0.t, Double(firstSegment.startUnix), accuracy: 1e-9)
    }

    func testSegmentSeamsLandOnTwentySecondBoundaries() throws {
        // A run starting off-grid: inner seams snap down to UTC multiples of 20 s so no 5 s epoch
        // or 4 s window straddles two requests; the run's own edges are kept.
        let cols = [Int16](repeating: 0, count: 600)
        let records = (103..<1001).map { Npb1ImuDecoder.Record(rowId: Int64($0), ts: Int64($0), columns: cols) }
        let timeline = try SensorBiomarkerInputs.imuTimeline(records)
        let segments = SensorBiomarkerInputs.imuSegments(
            run: ActivityLane.Run(start: 103, end: 1001), timeline: timeline, maxDuration: 300)
        XCTAssertEqual(segments.map(\.startUnix), [103, 400, 700, 1000])
        XCTAssertEqual(segments.map(\.durationS), [297, 300, 300, 1])
    }

    func testClipSlicesRunsToAnHour() {
        let runs = [ActivityLane.Run(start: 3_000, end: 4_000), ActivityLane.Run(start: 7_300, end: 7_400)]
        XCTAssertEqual(SensorBiomarkerInputs.clip(runs, from: 3_600, to: 7_200),
                       [ActivityLane.Run(start: 3_600, end: 4_000)])
        XCTAssertEqual(SensorBiomarkerInputs.clip(runs, from: 0, to: 3_600),
                       [ActivityLane.Run(start: 3_000, end: 3_600)])
    }

    // MARK: - PPG reconstruction (independent expected values)

    private func refAbsolute(base: Int, deltas: [Int]) -> [Int] {
        var out = [base]
        var acc = base
        for d in deltas { acc += d; out.append(acc) }
        return out
    }

    func testPpgReconstructionMatchesIndependentlyComputedAbsolutes() throws {
        let fixture = try sensorJSON("sensor_biomarkers_ppg_records.json")
        let records = try XCTUnwrap(fixture["records"] as? [[String: Any]])
        let expectedAbsolutes = try XCTUnwrap(fixture["expected_absolutes"] as? [String: [Int]])
        let inputs = records.map { ppgInput(from: $0) }
        let reconstruction = SensorBiomarkerInputs.reconstructPPG(records: inputs)
        // The fixture's expected windows cover exactly the EMITTED seconds;
        // every other second is withheld by design and must not appear here.
        XCTAssertEqual(Set(expectedAbsolutes.keys), Set(reconstruction.seconds.filter { $0.withheldReason == nil }.map { String($0.ts) }))
        for second in reconstruction.seconds {
            guard let window = expectedAbsolutes[String(second.ts)] else { continue }
            // The anchor + 24 deltas are 25 distinct samples on the uniform 25 Hz grid; every one
            // is emitted (ppg-transport.md, timing evidence).
            XCTAssertEqual(second.samples.count, 25, "emitted second \(second.ts) must be 25 samples")
            XCTAssertEqual(second.samples.map(Int.init), window,
                           "second \(second.ts) must equal the independently computed absolutes")
            XCTAssertEqual(second.samples[0], Int32(window[0]), "sample 0 is the baseCode")
        }
        // Cross-check the same window via the shared WhoopProtocol helper.
        let clean = reconstruction.seconds.first { $0.ts == 1000 }
        XCTAssertEqual(clean?.samples.count, 25)
        let whoopWindow = try XCTUnwrap(ppgWaveformAbsolute(
            baseCode: 378_307,
            deltas: Array(repeating: [10, -5], count: 12).flatMap { $0 }))
        XCTAssertEqual(clean!.samples.map(Int.init), whoopWindow)
        XCTAssertEqual(reconstruction.grid, .uniform25)
        XCTAssertEqual(SensorBiomarkerInputs.ppgNativeRateHz, 25)
    }

    func testPpgMissingAnchorNeverEmitted() throws {
        let fixture = try sensorJSON("sensor_biomarkers_ppg_records.json")
        let records = try XCTUnwrap(fixture["records"] as? [[String: Any]])
        let inputs = records.map { ppgInput(from: $0) }
        let reconstruction = SensorBiomarkerInputs.reconstructPPG(records: inputs)
        let missing = try XCTUnwrap(reconstruction.seconds.first { $0.ts == 1002 })
        XCTAssertEqual(missing.withheldReason, SensorBiomarkerInputs.reasonMissingPpgAnchor)
        XCTAssertTrue(missing.samples.isEmpty, "a delta-only record is never interpreted as amplitudes")
        XCTAssertEqual(reconstruction.reasonCounts[SensorBiomarkerInputs.reasonMissingPpgAnchor], 1)
        // And the WhoopProtocol reconstruction helper itself returns nil for nil base.
        XCTAssertNil(ppgWaveformAbsolute(baseCode: nil, deltas: [1, 2, 3]))
    }

    func testPpgSaturatedDeltaBothRailsWithheld() throws {
        let fixture = try sensorJSON("sensor_biomarkers_ppg_records.json")
        let records = try XCTUnwrap(fixture["records"] as? [[String: Any]])
        let inputs = records.map { ppgInput(from: $0) }
        let reconstruction = SensorBiomarkerInputs.reconstructPPG(records: inputs)
        let plusRail = try XCTUnwrap(reconstruction.seconds.first { $0.ts == 1004 })
        XCTAssertEqual(plusRail.withheldReason, SensorBiomarkerInputs.reasonSaturatedDelta)
        XCTAssertTrue(plusRail.saturatedDelta)
        XCTAssertFalse(plusRail.outOfDomain)
        let minusRail = try XCTUnwrap(reconstruction.seconds.first { $0.ts == 1005 })
        XCTAssertEqual(minusRail.withheldReason, SensorBiomarkerInputs.reasonSaturatedDelta)
        XCTAssertTrue(minusRail.saturatedDelta)
        // Both rails count via the shared predicate.
        XCTAssertTrue(isSaturatedPpgDelta(Int(Int16.min)))
        XCTAssertTrue(isSaturatedPpgDelta(Int(Int16.max)))
        XCTAssertFalse(isSaturatedPpgDelta(5))
        XCTAssertEqual(reconstruction.reasonCounts[SensorBiomarkerInputs.reasonSaturatedDelta], 3,
                       "rails 1004/1005 plus the out-of-domain 1010")
    }

    func testPpgOutOfDomainWithheld() throws {
        let fixture = try sensorJSON("sensor_biomarkers_ppg_records.json")
        let records = try XCTUnwrap(fixture["records"] as? [[String: Any]])
        let inputs = records.map { ppgInput(from: $0) }
        let reconstruction = SensorBiomarkerInputs.reconstructPPG(records: inputs)
        let out = try XCTUnwrap(reconstruction.seconds.first { $0.ts == 1010 })
        XCTAssertEqual(out.withheldReason, SensorBiomarkerInputs.reasonSaturatedDelta)
        XCTAssertTrue(out.outOfDomain)
        XCTAssertFalse(out.saturatedDelta)
        // The signed 20-bit rails are the Whoop5RawOptical constants.
        XCTAssertEqual(SensorBiomarkerInputs.opticalSampleMin, -524_288)
        XCTAssertEqual(SensorBiomarkerInputs.opticalSampleMax, 524_287)
        // base 524287 + 10 crosses the positive rail -> the reconstruction is
        // physically impossible and must not be sent.
        XCTAssertGreaterThan(524_287 + 10, SensorBiomarkerInputs.opticalSampleMax)
    }

    func testPpgUnsupportedRateDetectedAndWithheld() throws {
        let fixture = try sensorJSON("sensor_biomarkers_ppg_records.json")
        let records = try XCTUnwrap(fixture["records"] as? [[String: Any]])
        let inputs = records.map { ppgInput(from: $0) }
        let reconstruction = SensorBiomarkerInputs.reconstructPPG(records: inputs)
        let rate = try XCTUnwrap(reconstruction.seconds.first { $0.ts == 1007 })
        XCTAssertEqual(rate.withheldReason, SensorBiomarkerInputs.reasonUnsupportedNativeRate)
        XCTAssertEqual(rate.deltaCount, 25)
        // Detected and reported, never assumed: the fixture's 25-delta record
        // shows up in detectedDeltaCounts and makes nativeRateHz unverified.
        XCTAssertEqual(reconstruction.detectedDeltaCounts[24], 9)
        XCTAssertEqual(reconstruction.detectedDeltaCounts[25], 1)
        XCTAssertEqual(reconstruction.detectedDeltaCounts[0], 1)
        XCTAssertNil(reconstruction.nativeRateHz, "mixed rates -> no assumed native rate")
    }

    func testPpgEmptySlotAndDarkBlockWithheld() throws {
        let fixture = try sensorJSON("sensor_biomarkers_ppg_records.json")
        let records = try XCTUnwrap(fixture["records"] as? [[String: Any]])
        let inputs = records.map { ppgInput(from: $0) }
        let reconstruction = SensorBiomarkerInputs.reconstructPPG(records: inputs)
        let empty = try XCTUnwrap(reconstruction.seconds.first { $0.ts == 1008 })
        XCTAssertEqual(empty.withheldReason, SensorBiomarkerInputs.reasonArtifactUnavailable)
        XCTAssertEqual(empty.deltaCount, 0)
        let dark = try XCTUnwrap(reconstruction.seconds.first { $0.ts == 1011 })
        XCTAssertEqual(dark.withheldReason, SensorBiomarkerInputs.reasonArtifactUnavailable)
        XCTAssertTrue(dark.darkBlock, "drive == 0 marks the block dark")
        XCTAssertTrue(dark.samples.isEmpty, "a dark block is never a pulsatile channel")
    }

    func testPpgConfigChangeBreaksRuns() throws {
        let fixture = try sensorJSON("sensor_biomarkers_ppg_records.json")
        let records = try XCTUnwrap(fixture["records"] as? [[String: Any]])
        let inputs = records.map { ppgInput(from: $0) }
        let reconstruction = SensorBiomarkerInputs.reconstructPPG(records: inputs)
        // Emitted seconds: 1000-1001 (burst 1), 1003 (burst 1, flat),
        // 1006 (burst 2). The burstIndex change must break pooling into
        // separate runs; the missing-anchor second 1002 splits too.
        let runs = reconstruction.runs
        XCTAssertEqual(runs.map(\.start), [1000, 1003, 1006])
        XCTAssertEqual(runs.map(\.end), [1002, 1004, 1007])
        // The burst counter splits runs but never names a configuration: v26 reports no gain,
        // drive or channel, so every run's configuration is "unknown" and not known.
        XCTAssertEqual(runs.map(\.config.burstIndex), [1, 1, 2])
        XCTAssertEqual(Set(runs.map(\.configIdentity)), ["unknown"])
        XCTAssertTrue(runs.allSatisfy { !$0.config.known })
        XCTAssertEqual(runs.map(\.runId), ["ppg-1000", "ppg-1003", "ppg-1006"])
        // Every emitted second lands in exactly one run.
        let covered = runs.flatMap { ($0.start..<$0.end).map { $0 } }
        XCTAssertEqual(covered, [1000, 1001, 1003, 1006])
    }

    func testPpgIdenticalDuplicatesCollapseConflictingNotAveraged() throws {
        let fixture = try sensorJSON("sensor_biomarkers_ppg_wire.json")
        let objects = try XCTUnwrap(fixture["objects"] as? [[String: Any]])
        // Merge the two v2 objects: identical duplicates collapse, the
        // conflicting ts=1009 keeps rowId 2003's samples by capture precedence.
        var all: [SensorBiomarkerInputs.PpgWaveformInput] = []
        for entry in objects where (entry["version"] as? Int) == 2 {
            let wire = Data(base64Encoded: try XCTUnwrap(entry["gzip_base64"] as? String))!
            let digest = try XCTUnwrap(entry["decoded_sha256"] as? String)
            let object = object(id: "p", kind: SensorBiomarkerInputs.kindPpgWaveformSample,
                                key: "k", digest: digest)
            let records = try SensorBiomarkerInputs.decodePpgObject(wire: wire, object: object)
            all.append(contentsOf: records.map { SensorBiomarkerInputs.PpgWaveformInput(wireRecord: $0) })
        }
        let reconstruction = SensorBiomarkerInputs.reconstructPPG(records: all)
        XCTAssertEqual(reconstruction.conflictingDuplicateSeconds, [1009],
                       "the two differing ts=1009 records conflict and are not averaged")
        let ts1009 = try XCTUnwrap(reconstruction.seconds.first { $0.ts == 1009 })
        // Deterministic pick: rowId 2003 (the older capture) wins — never a blend.
        XCTAssertEqual(ts1009.deltaCount, 24)
        XCTAssertNotEqual(ts1009.samples, Array(repeating: 99, count: 24))
        // Identical duplicates collapse without a conflict report.
        XCTAssertFalse(reconstruction.conflictingDuplicateSeconds.contains(1008))
        XCTAssertEqual(reconstruction.seconds.filter { $0.ts == 1008 }.count, 1)
        XCTAssertFalse(reconstruction.conflictingDuplicateSeconds.contains(1007))
    }

    func testLegacy24GridStillAvailableBehindTheEnum() throws {
        // The pre-Spec-01 convention, kept for the record behind `PpgGrid.legacy24`: each second
        // emits the first 24 points at ts + i/24 and hands the 25th to the next second, so a run of
        // two seconds has exactly 48 samples with no duplicated endpoint.
        let a = SensorBiomarkerInputs.PpgWaveformInput(
            rowId: 1, ts: 200, samples: [10, -5, 10, -5, 10, -5, 10, -5, 10, -5, 10, -5,
                                         10, -5, 10, -5, 10, -5, 10, -5, 10, -5, 10, -5],
            burstIndex: 1, baseCode: 100_000)
        let b = SensorBiomarkerInputs.PpgWaveformInput(
            rowId: 2, ts: 201, samples: [3, -1, 3, -1, 3, -1, 3, -1, 3, -1, 3, -1,
                                         3, -1, 3, -1, 3, -1, 3, -1, 3, -1, 3, -1],
            burstIndex: 1, baseCode: 100_120)
        let reconstruction = SensorBiomarkerInputs.reconstructPPG(records: [a, b], grid: .legacy24)
        XCTAssertEqual(reconstruction.nativeRateHz, 24)
        let sa = try XCTUnwrap(reconstruction.seconds.first { $0.ts == 200 })
        let sb = try XCTUnwrap(reconstruction.seconds.first { $0.ts == 201 })
        XCTAssertEqual(sa.samples.count, 24)
        XCTAssertEqual(sb.samples.count, 24)
        // Independent reference: second 200's last emitted sample is
        // base + d0 + ... + d22 (NOT base + all 24 deltas, which is the 25th
        // point at ts+1).
        let refA = refAbsolute(base: 100_000, deltas: Array(repeating: [10, -5], count: 12).flatMap { $0 })
        XCTAssertEqual(sa.samples.map(Int.init), Array(refA.prefix(24)))
        XCTAssertEqual(sa.samples.last.map(Int.init), refA[23])
        XCTAssertEqual(sb.samples.first, 100_120)
        // The run spans both seconds and the segment carries exactly 48 samples.
        let runs = reconstruction.runs
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].start, 200)
        XCTAssertEqual(runs[0].end, 202)
        XCTAssertEqual(runs[0].runId, "ppg-200")
        let byTs = Dictionary(uniqueKeysWithValues: reconstruction.seconds.map { ($0.ts, $0) })
        let segments = SensorBiomarkerInputs.ppgSegments(run: runs[0], secondsByTs: byTs, grid: .legacy24)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].samples.count, 48)
        XCTAssertEqual(segments[0].samplesPerSecond, 24)
        // Split at a 1-second cap: two endpoint-owned segments of 24, and the
        // boundary is clean (segment 1 ends at second 200, segment 2 starts at 201).
        let split = SensorBiomarkerInputs.ppgSegments(run: runs[0], secondsByTs: byTs, maxDuration: 1, grid: .legacy24)
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split[0].startUnix, 200)
        XCTAssertEqual(split[1].startUnix, 201)
        XCTAssertEqual(split[0].samples.count, 24)
        XCTAssertEqual(split[1].samples.count, 24)
        XCTAssertEqual(split[1].samples.first, sb.samples.first, "no endpoint sample is duplicated")
    }

    // MARK: - Real v26 frames (CRC gate + reconstruction)

    func testRealV26FrameReconstructsIndependently() throws {
        let fixture = try sensorJSON("sensor_biomarkers_v26_frames.json")
        let frames = try XCTUnwrap(fixture["frames"] as? [[String: Any]])
        let frame = try XCTUnwrap(frames.first)
        let hex = try XCTUnwrap(frame["hex"] as? String)
        let parsed = parseFrame([UInt8](hexData(hex)), family: .whoop5)
        XCTAssertEqual(parsed.crcOK, true)
        XCTAssertEqual(parsed.parsed["hist_version"]?.intValue, 26)
        // The WhoopProtocol decode (extractHistoricalStreams) yields the
        // PpgWaveformSample with the anchor, deltas and burst counter.
        let streams = extractHistoricalStreams([parsed], deviceClockRef: 1_780_917_232,
                                               wallClockRef: 1_780_917_232)
        let sample = try XCTUnwrap(streams.ppgWaveform.first)
        XCTAssertEqual(sample.ts, frame["unix"] as? Int)
        XCTAssertEqual(sample.burstIndex, frame["burst_index"] as? Int)
        XCTAssertEqual(sample.baseCode, frame["base_code"] as? Int)
        XCTAssertEqual(sample.samples, frame["deltas"] as? [Int])
        // Module reconstruction of the real window, verified against the
        // independently computed fixture window (base + running sum).
        let input = SensorBiomarkerInputs.PpgWaveformInput(whoopSample: sample)
        let second = SensorBiomarkerInputs.reconstructSecond(input)
        XCTAssertEqual(second.withheldReason, nil)
        let window = try XCTUnwrap(frame["absolute_window"] as? [Int])
        XCTAssertEqual(second.samples.map(Int.init), window, "all 25 points of the real window are emitted")
        XCTAssertEqual(second.samples.first.map(Int.init), window[0])
        // The known final point of the full 25-sample window (base + all 24
        // deltas) is 362532 on this real capture.
        let full = try XCTUnwrap(ppgWaveformAbsolute(baseCode: sample.baseCode, deltas: sample.samples))
        XCTAssertEqual(full.count, 25)
        XCTAssertEqual(full.last, 362_532)
        XCTAssertEqual(second.samples.last, 362_532)
        XCTAssertEqual(second.clock.source, .strapRecordSecond)
    }

    func testRealV26FrameCorruptedCRCRejectedByWhoopProtocol() throws {
        let fixture = try sensorJSON("sensor_biomarkers_v26_frames.json")
        let frames = try XCTUnwrap(fixture["frames"] as? [[String: Any]])
        let frame = try XCTUnwrap(frames.first)
        var bytes = [UInt8](hexData(try XCTUnwrap(frame["hex"] as? String)))
        // Flip a payload byte -> the trailing CRC32 no longer matches.
        bytes[30] ^= 0xFF
        let parsed = parseFrame(bytes, family: .whoop5)
        XCTAssertEqual(parsed.crcOK, false, "a corrupted v26 record must fail the envelope CRC")
        // WhoopProtocol's decode drops the record entirely: a CRC-failed frame
        // never becomes a PpgWaveformSample, so this module never sees it.
        let streams = extractHistoricalStreams([parsed], deviceClockRef: 1_780_917_232,
                                               wallClockRef: 1_780_917_232)
        XCTAssertTrue(streams.ppgWaveform.isEmpty, "failed-CRC v26 record must not become input")
    }

    // MARK: - Request input (CONTRACTS §4)

    func testInputRevisionCanonicalForm() {
        // Canonical string form: sorted digests joined by '\n', hashed as
        // UTF-8; pinned against an independently computed value.
        let objects = [
            object(id: "a", kind: SensorBiomarkerInputs.kindRawImuSession, key: "k", digest: String(repeating: "aa", count: 32)),
            object(id: "b", kind: SensorBiomarkerInputs.kindRawImuSession, key: "k", digest: String(repeating: "bb", count: 32)),
            object(id: "c", kind: SensorBiomarkerInputs.kindPpgWaveformSample, key: "k", digest: String(repeating: "0f", count: 32)),
        ]
        XCTAssertEqual(SensorBiomarkerInputs.inputRevision(objects: objects),
                       "sha256:4d45a2228131e66272981fa0458502dfe9ea956e65c88e52f269d44e924fdc46")
        // Deterministic under input order.
        XCTAssertEqual(SensorBiomarkerInputs.inputRevision(objects: Array(objects.reversed())),
                       SensorBiomarkerInputs.inputRevision(objects: objects))
        // Empty set is still a stable value (sha256 of ""), never a crash.
        XCTAssertEqual(SensorBiomarkerInputs.inputRevision(objects: []),
                       "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testBuildRequestsCombinedShape() throws {
        // A two-second IMU run and a two-second PPG run over the same span.
        let cols = [Int16](repeating: 0, count: 600)
        let records = [Int64(100), 101].map {
            Npb1ImuDecoder.Record(rowId: $0, ts: $0, columns: cols)
        }
        let timeline = try SensorBiomarkerInputs.imuTimeline(records)
        let ppgA = SensorBiomarkerInputs.PpgWaveformInput(rowId: 1, ts: 100, samples: Array(repeating: 1, count: 24), burstIndex: 1, baseCode: 100_000)
        let ppgB = SensorBiomarkerInputs.PpgWaveformInput(rowId: 2, ts: 101, samples: Array(repeating: 1, count: 24), burstIndex: 1, baseCode: 100_024)
        let reconstruction = SensorBiomarkerInputs.reconstructPPG(records: [ppgA, ppgB])
        let byTs = Dictionary(uniqueKeysWithValues: reconstruction.seconds.map { ($0.ts, $0) })
        let objects = [object(id: "o", kind: SensorBiomarkerInputs.kindRawImuSession,
                              key: "k", digest: String(repeating: "a", count: 64))]
        let requests = try SensorBiomarkerInputs.buildRequests(
            imuRuns: [ActivityLane.Run(start: 100, end: 102)],
            ppgRuns: reconstruction.runs,
            imuTimeline: timeline, ppgSecondsByTs: byTs,
            objects: objects, deviceID: "dev-1", dayUTC: "2026-10-06",
            families: ["movement", "ppg_quality"])
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertGreaterThan(request.serializedSizeBytes, 0)
        let json = request.input.jsonObject()
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertEqual((json["device"] as? [String: Any])?["id"] as? String, "dev-1")
        XCTAssertEqual((json["device"] as? [String: Any])?["family"] as? String, "whoop5")
        XCTAssertEqual(json["day_utc"] as? String, "2026-10-06")
        XCTAssertEqual(json["watch_side"] as? String, "unknown")
        XCTAssertEqual(json["families"] as? [String], ["movement", "ppg_quality"])
        // input_revision = sha256 over the SORTED digest strings; a single
        // "aaaa…" digest hashes to this pinned value (computed independently).
        XCTAssertEqual(json["input_revision"] as? String,
                       "sha256:ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
        let imu = json["imu"] as? [String: Any]
        XCTAssertEqual(imu?["sampling_rate_hz"] as? Int, 100)
        let imuSegments = imu?["segments"] as? [[String: Any]]
        XCTAssertEqual(imuSegments?.count, 1)
        XCTAssertEqual(imuSegments?.first?["duration_s"] as? Int, 2)
        XCTAssertEqual((imuSegments?.first?["accel_g"] as? [[Double]])?.count, 200)
        let ppg = json["ppg"] as? [String: Any]
        XCTAssertEqual(ppg?["native_rate_hz"] as? Int, 25)
        let ppgSegments = ppg?["segments"] as? [[String: Any]]
        XCTAssertEqual(ppgSegments?.count, 1)
        XCTAssertEqual(ppgSegments?.first?["sample_count_per_second"] as? Int, 25)
        XCTAssertEqual((ppgSegments?.first?["samples"] as? [Int32])?.count, 50)
        XCTAssertEqual(ppgSegments?.first?["run_id"] as? String, "ppg-100")
        let config = ppgSegments?.first?["config"] as? [String: Any]
        XCTAssertEqual(config?["stable"] as? Bool, true)
        XCTAssertEqual(config?["identity"] as? String, "unknown")
        XCTAssertEqual(config?["known"] as? Bool, false)
        XCTAssertEqual(config?["burst_index"] as? Int, 1)
        let clock = ppgSegments?.first?["clock"] as? [String: Any]
        XCTAssertEqual(clock?["samples_per_second"] as? Int, 25)
        XCTAssertEqual(clock?["packet_timing_verified"] as? Bool, false)
        XCTAssertEqual(clock?["grid"] as? String, "uniform-25hz-v26-continuity")
        let coverage = json["coverage"] as? [String: Any]
        XCTAssertEqual((coverage?["ppg"] as? [String: Any])?["eligible_seconds"] as? Int, 2)
        XCTAssertEqual((coverage?["imu"] as? [String: Any])?["expected_seconds"] as? Int, 2)
        XCTAssertEqual((json["placement"] as? [String: Any])?["body_location"] as? String, "unknown")
    }

    func testBuildRequestsEndpointOwnershipAcrossChunkBoundary() throws {
        // One run of 302 seconds: segments of 300 then 2; the second segment's
        // first sample is at t = 400, the first segment's last at 399 + 99/100.
        let cols = [Int16](repeating: 0, count: 600)
        let records = (100..<402).map { ts in
            Npb1ImuDecoder.Record(rowId: Int64(ts), ts: Int64(ts), columns: cols)
        }
        let timeline = try SensorBiomarkerInputs.imuTimeline(records)
        let requests = try SensorBiomarkerInputs.buildRequests(
            imuRuns: [ActivityLane.Run(start: 100, end: 402)], ppgRuns: [],
            imuTimeline: timeline, ppgSecondsByTs: [:], objects: [],
            deviceID: "d", dayUTC: "2026-10-06", families: ["movement"])
        XCTAssertEqual(requests.count, 1)
        let imu = requests[0].input.imu
        XCTAssertEqual(imu?.segments.count, 2)
        XCTAssertEqual(imu?.segments[0].durationS, 300)
        XCTAssertEqual(imu?.segments[1].durationS, 2)
        XCTAssertEqual(imu?.segments[0].accelG.count, 300 * 100)
        XCTAssertEqual(imu?.segments[1].accelG.count, 2 * 100)
        // Endpoint ownership: segment 1 covers [100, 400), segment 2 [400, 402).
        XCTAssertEqual(imu?.segments[0].startUnix, 100)
        XCTAssertEqual(imu?.segments[1].startUnix, 400)
    }

    func testBuildRequestsStaysUnderBodyBudget() throws {
        // A 2-hour contiguous IMU run: far more than one request can hold.
        let start: Int64 = 1_758_000_000
        let seconds = (0..<7_200).map { start + Int64($0) }
        var timeline = ActivityLane.ImuTimeline()
        timeline.seconds = seconds
        timeline.columns = [Int16](repeating: 0, count: seconds.count * 600)
        let requests = try SensorBiomarkerInputs.buildRequests(
            imuRuns: [ActivityLane.Run(start: start, end: start + 7_200)], ppgRuns: [],
            imuTimeline: timeline, ppgSecondsByTs: [:], objects: [],
            deviceID: "d", dayUTC: "2026-10-06", families: ["movement"])
        XCTAssertGreaterThan(requests.count, 1, "a 2 h run must split into multiple budget-bounded requests")
        for request in requests {
            XCTAssertLessThan(request.serializedSizeBytes, SensorBiomarkerInputs.maxBodyBytes,
                              "every request stays under the sidecar MAX_BODY_BYTES (8 MiB)")
            XCTAssertLessThanOrEqual(request.serializedSizeBytes, SensorBiomarkerInputs.bodyBudgetBytes)
            // Segments within a request are time-ordered and non-overlapping.
            guard let segments = request.input.imu?.segments else {
                return XCTFail("request missing imu segments")
            }
            for (a, b) in zip(segments, segments.dropFirst()) {
                XCTAssertLessThan(a.startUnix, b.startUnix)
                XCTAssertLessThanOrEqual(a.startUnix + Int64(a.durationS), b.startUnix,
                                         "segments must not overlap")
            }
        }
        // The requests jointly cover the whole run with no duplication.
        let totalSamples = requests.reduce(0) { $0 + ($1.input.imu?.segments.reduce(0) { $0 + $1.accelG.count } ?? 0) }
        XCTAssertEqual(totalSamples, 7_200 * 100)
    }
}

/// The device-day object resolution against a real Postgres: the exact SQL the
/// lane runs must return ONLY the verified (`ready` +
/// `durability_receipt->>'state' = 'verified_indexed'`), correctly-owned,
/// in-day rawImuSession/ppgWaveformSample objects, and the pure parser must
/// turn those rows into typed inputs.
///
/// Needs a scratch Postgres with the object_manifests schema (the
/// production_persistence object_manifests DDL plus the additive
/// durability_receipt/sha256_source columns): set FRWHOOP_TEST_DB_URL, e.g.
/// `postgresql://postgres@localhost:55433/postgres` (skipped otherwise).
final class SensorBiomarkerInputsDatabaseTests: XCTestCase {

    private func connect() throws -> PostgresClient {
        guard let url = ProcessInfo.processInfo.environment["FRWHOOP_TEST_DB_URL"], !url.isEmpty else {
            throw XCTSkip("set FRWHOOP_TEST_DB_URL to a scratch Postgres with the object_manifests schema")
        }
        return try PostgresClient(options: PostgresOptions(
            connectionString: url, sslMode: "disable", sslRootCert: nil,
            applicationName: "frwhoop-worker-tests", allowInsecure: true,
            connectTimeoutSeconds: 5, reconnectDeadlineSeconds: 5,
            statementTimeoutMS: 60_000, idleTransactionTimeoutMS: 60_000))
    }

    func testObjectResolutionSQLFindsOnlyVerifiedIndexedDayObjects() throws {
        let db = try connect()
        let present = try db.query("select (to_regclass('public.object_manifests') is not null) as present", [])
        guard present.first?["present"] == "t" else {
            throw XCTSkip("apply the object_manifests schema to the scratch database")
        }
        let user = UUID().uuidString.lowercased()
        let device = UUID().uuidString.lowercased()
        let otherUser = UUID().uuidString.lowercased()
        let otherDevice = UUID().uuidString.lowercased()
        try db.exec("insert into auth.users(id) values ('\(user)'), ('\(otherUser)')")
        try db.exec("insert into public.devices(id,user_id,source_kind) values "
                    + "('\(device)','\(user)','noop_push'), ('\(otherDevice)','\(otherUser)','noop_push')")
        addTeardownBlock {
            try? db.exec("delete from auth.users where id in ('\(user)','\(otherUser)')")
        }

        let dayStart = 1_780_915_200   // 2026-06-08 00:00:00 UTC
        let day = "2026-06-08"
        let digest = String(repeating: "a", count: 64)
        func insert(_ id: String, _ user: String, _ dev: String, _ kind: String, _ key: String,
                    _ start: Int, _ end: Int, _ status: String, _ receipt: String) throws {
            _ = try db.query("""
                insert into public.object_manifests(id,user_id,device_id,object_kind,object_key,
                    start_at,end_at,sha256,status,durability_receipt,sha256_source)
                values ($1::uuid,$2::uuid,$3::uuid,$4::text,$5::text,
                    to_timestamp($6::double precision), to_timestamp($7::double precision),
                    $8::text,$9::text, jsonb_build_object('state',$10::text), 'server_verified')
                """, [id, user, dev, kind, key, String(start), String(end), digest, status, receipt])
        }
        // Resolves: verified_indexed + ready + in-day, one per kind.
        try insert("11111111-1111-4111-8111-111111111111", user, device, "rawImuSession", "v3/research/imu-in",
                   dayStart + 100, dayStart + 200, "ready", "verified_indexed")
        try insert("22222222-2222-4222-8222-222222222222", user, device, "ppgWaveformSample", "v3/research/ppg-in",
                   dayStart + 150, dayStart + 250, "ready", "verified_indexed")
        // Out of the UTC day -> excluded.
        try insert("33333333-3333-4333-8333-333333333333", user, device, "rawImuSession", "v3/research/imu-out",
                   dayStart + 86_400 + 100, dayStart + 86_400 + 200, "ready", "verified_indexed")
        // Not status=ready -> excluded.
        try insert("44444444-4444-4444-8444-444444444444", user, device, "rawImuSession", "v3/research/imu-uploaded",
                   dayStart + 100, dayStart + 200, "uploaded", "verified_indexed")
        // Verified but NOT indexed -> excluded.
        try insert("55555555-5555-4555-8555-555555555555", user, device, "rawImuSession", "v3/research/imu-unindexed",
                   dayStart + 100, dayStart + 200, "ready", "client_claimed")
        // Another owner/device -> excluded by the SQL's own scope.
        try insert("66666666-6666-4666-8666-666666666666", otherUser, otherDevice, "rawImuSession", "v3/research/other",
                   dayStart + 100, dayStart + 200, "ready", "verified_indexed")

        guard let params = SensorBiomarkerInputs.objectResolutionParams(userId: user, deviceId: device, day: day) else {
            return XCTFail("objectResolutionParams must build for 2026-06-08")
        }
        let rows = try db.query(SensorBiomarkerInputs.objectResolutionSQL, params)
        XCTAssertEqual(rows.count, 2, "only the two verified, indexed, in-day, owned objects resolve")
        let ids = rows.compactMap { $0["id"] }.sorted()
        XCTAssertEqual(ids, ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"])
        let resolved = try SensorBiomarkerInputs.parseObjectRows(rows, userId: user, deviceId: device)
        XCTAssertEqual(resolved.imu.count, 1)
        XCTAssertEqual(resolved.ppg.count, 1)
        XCTAssertEqual(resolved.imu[0].objectKey, "v3/research/imu-in")
        XCTAssertEqual(resolved.ppg[0].objectKey, "v3/research/ppg-in")
        XCTAssertEqual(resolved.imu[0].digest, digest)
        XCTAssertEqual(resolved.imu[0].startTs, Int64(dayStart + 100))
    }
}
