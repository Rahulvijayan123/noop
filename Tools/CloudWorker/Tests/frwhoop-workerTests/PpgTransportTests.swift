import XCTest
import WhoopProtocol
@testable import frwhoop_worker

/// The worker end of the protocol 1.5 PPG transport (docs/model-integration/ppg-transport.md):
/// the shared golden written by NoopPush (`ppg_anchor_v3_golden.json`, the phone encoder's bytes)
/// decodes with its anchor, configuration and clock identity intact; legacy anchor-less objects stay
/// withheld; mixed old/new objects reconcile without duplicate seconds; gaps and configuration or
/// clock changes never produce cross-boundary runs or segments; and the request the lane posts is
/// pinned as `sensor_biomarkers_request_envelope.json` for the sidecar tests.
final class PpgTransportTests: XCTestCase {

    // MARK: - Fixtures

    private func goldenPath() throws -> String {
        let candidates = [
            "../../Packages/NoopPush/Tests/NoopPushTests/Resources/ppg_anchor_v3_golden.json",
            "Packages/NoopPush/Tests/NoopPushTests/Resources/ppg_anchor_v3_golden.json",
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) { return c }
        throw XCTSkip("ppg_anchor_v3_golden.json not found from \(FileManager.default.currentDirectoryPath)")
    }

    private func golden() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: try goldenPath()))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func vector(_ name: String) throws -> [String: Any] {
        let vectors = try XCTUnwrap(try golden()["vectors"] as? [[String: Any]])
        return try XCTUnwrap(vectors.first { $0["name"] as? String == name })
    }

    private func object(_ v: [String: Any], id: String) throws -> SensorBiomarkerInputs.InputObject {
        let manifest = try XCTUnwrap(v["manifest"] as? [String: Any])
        return SensorBiomarkerInputs.InputObject(
            id: id, objectKind: SensorBiomarkerInputs.kindPpgWaveformSample, objectKey: "v3/research/\(id)",
            digest: try XCTUnwrap(v["decoded_sha256"] as? String),
            startTs: (manifest["startTs"] as? NSNumber)?.int64Value, endTs: (manifest["endTs"] as? NSNumber)?.int64Value,
            protocolVersion: manifest["protocolVersion"] as? String, schemaVersion: v["schema_version"] as? Int)
    }

    private func wire(_ v: [String: Any]) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(v["wire_base64"] as? String)))
    }

    private func inputs(_ name: String) throws -> [SensorBiomarkerInputs.PpgWaveformInput] {
        let v = try vector(name)
        return try SensorBiomarkerInputs.decodePpgObject(wire: try wire(v), object: try object(v, id: name))
            .map(SensorBiomarkerInputs.PpgWaveformInput.init(wireRecord:))
    }

    // MARK: - Golden decode

    func testPhoneGoldenDecodesWithAnchorConfigAndClockIntact() throws {
        let v = try vector("phone_real_frames")
        let records = try SensorBiomarkerInputs.decodePpgObject(wire: try wire(v), object: try object(v, id: "phone"))
        let rows = try XCTUnwrap(v["rows"] as? [[String: Any]])
        XCTAssertEqual(records.count, rows.count)
        for (record, row) in zip(records, rows) {
            XCTAssertEqual(record.format, 3)
            XCTAssertEqual(record.ts, (row["ts"] as? NSNumber)?.int64Value)
            XCTAssertEqual(record.rowId, (row["rowId"] as? NSNumber)?.int64Value)
            XCTAssertEqual(record.anchor.map(Int.init), row["anchor"] as? Int)
            XCTAssertEqual(record.burstIndex.map(Int.init), row["burstIndex"] as? Int)
            XCTAssertEqual(record.clockSource, .strapRecordSecond)
            XCTAssertNil(record.subsecQ15, "the phone keeps no header phase today")
            XCTAssertNil(record.frontEndFlags)
            XCTAssertEqual(record.deltaAtRail, (row["sampleFlags"] as? Int) == 1)
        }

        let reconstruction = SensorBiomarkerInputs.reconstructPPG(records: records.map(SensorBiomarkerInputs.PpgWaveformInput.init(wireRecord:)))
        let byTs = Dictionary(uniqueKeysWithValues: reconstruction.seconds.map { ($0.ts, $0) })
        // The real burst-1 frame: all 25 points of its window, sample 0 = the strap's base code.
        let realWindow = try XCTUnwrap(ppgWaveformAbsolute(baseCode: 378_307, deltas: [
            -1432, -1332, -1139, -954, -629, -436, -326, -294, -147, -170, -43, -5,
            -201, -918, -1563, -1833, -1313, -930, -616, -293, -422, -380, -235, -164]))
        XCTAssertEqual(byTs[1_780_917_232]?.samples.map(Int.init), realWindow)
        XCTAssertEqual(byTs[1_780_917_233]?.withheldReason, nil)
        XCTAssertEqual(byTs[1_780_917_234]?.withheldReason, SensorBiomarkerInputs.reasonSaturatedDelta)
        XCTAssertEqual(byTs[1_780_918_392]?.samples.first, 434_252)
        XCTAssertEqual(reconstruction.secondsByFormat[3], 4)
        // Runs: burst 1 for two seconds (the rail second ends it), burst 2 alone.
        XCTAssertEqual(reconstruction.runs.map(\.runId), ["ppg-1780917232", "ppg-1780918392"])
        XCTAssertEqual(reconstruction.runs.map { $0.end - $0.start }, [2, 1])
        XCTAssertEqual(reconstruction.runs.map(\.config.burstIndex), [1, 2])
        XCTAssertTrue(reconstruction.runs.allSatisfy { $0.config.identity == "unknown" && !$0.config.known })
        XCTAssertTrue(reconstruction.runs.allSatisfy { $0.clock == .init(source: .strapRecordSecond, subsecQ15: nil) })
        let segments = SensorBiomarkerInputs.ppgSegments(run: reconstruction.runs[0], secondsByTs: byTs)
        XCTAssertEqual(segments.map(\.samples.count), [50])
        XCTAssertEqual(Array(segments[0].samples.prefix(25)).map(Int.init), realWindow,
                       "the second record's anchor follows the 25th point directly; nothing dropped")
    }

    func testAllMemberGoldenWithholdsHonestlyInsideFormat3() throws {
        let reconstruction = SensorBiomarkerInputs.reconstructPPG(records: try inputs("all_members"))
        let byTs = Dictionary(uniqueKeysWithValues: reconstruction.seconds.map { ($0.ts, $0) })
        let full = try XCTUnwrap(byTs[1_800_000_000])
        XCTAssertNil(full.withheldReason)
        XCTAssertEqual(full.clock.phaseSeconds, 3932.0 / 32768.0)
        XCTAssertEqual(full.config.frontEndFlags, 0x80)
        XCTAssertEqual(full.config.burstIndex, 7)
        XCTAssertEqual(byTs[1_800_000_001]?.withheldReason, SensorBiomarkerInputs.reasonMissingPpgAnchor,
                       "format 3 without an anchor is still withheld, never reconstructed from deltas")
        XCTAssertEqual(byTs[1_800_000_002]?.withheldReason, SensorBiomarkerInputs.reasonSaturatedDelta)
        XCTAssertEqual(byTs[1_800_000_002]?.outOfDomain, true, "a u32-max anchor is outside the optical domain")
        XCTAssertEqual(byTs[1_800_000_003]?.withheldReason, SensorBiomarkerInputs.reasonUnsupportedNativeRate)
        XCTAssertNil(reconstruction.nativeRateHz, "a 25-delta record makes the native rate unverified")
        XCTAssertEqual(reconstruction.runs.count, 1)
    }

    func testLegacyTwinStillWithholdsMissingAnchor() throws {
        let twin = try inputs("phone_real_frames_legacy_v2")
        XCTAssertTrue(twin.allSatisfy { $0.baseCode == nil && $0.format == 2 && $0.clockSource == .unknown })
        let reconstruction = SensorBiomarkerInputs.reconstructPPG(records: twin)
        XCTAssertEqual(reconstruction.reasonCounts[SensorBiomarkerInputs.reasonMissingPpgAnchor], 4)
        XCTAssertEqual(reconstruction.reasonCounts[SensorBiomarkerInputs.reasonSaturatedDelta], nil,
                       "an anchor-less second is withheld for the anchor before anything else, rail or not")
        XCTAssertEqual(reconstruction.seconds.count, 4)
        XCTAssertTrue(reconstruction.runs.isEmpty)
    }

    func testMixedOldAndNewObjectsReconcileWithoutDuplicateSeconds() throws {
        let anchored = try inputs("phone_real_frames"), twin = try inputs("phone_real_frames_legacy_v2")
        let alone = SensorBiomarkerInputs.reconstructPPG(records: anchored)
        for order in [twin + anchored, anchored + twin, twin + anchored + twin] {
            let mixed = SensorBiomarkerInputs.reconstructPPG(records: order)
            XCTAssertEqual(mixed.seconds.map(\.ts), alone.seconds.map(\.ts), "one record per second")
            XCTAssertEqual(mixed.seconds.map(\.samples), alone.seconds.map(\.samples))
            XCTAssertEqual(mixed.runs, alone.runs)
            XCTAssertTrue(mixed.conflictingDuplicateSeconds.isEmpty, "the same deltas are one observation")
            XCTAssertGreaterThanOrEqual(mixed.supersededDuplicateSeconds, 4)
            XCTAssertEqual(mixed.secondsByFormat, [3: 4], "the anchored copy wins every second")
        }
        // A copy with different deltas is a real conflict: kept deterministically, reported.
        var changed = twin
        changed[0] = .init(rowId: 1, ts: twin[0].ts, samples: twin[0].samples.map { $0 &+ 1 },
                           burstIndex: twin[0].burstIndex, format: 2)
        let conflict = SensorBiomarkerInputs.reconstructPPG(records: anchored + changed)
        XCTAssertEqual(conflict.conflictingDuplicateSeconds, [1_780_917_232])
        XCTAssertEqual(conflict.seconds.count, 4)
    }

    func testObjectWhoseFormatDisagreesWithItsSchemaFailsClosed() throws {
        let v = try vector("phone_real_frames")
        var mislabelled = try object(v, id: "lie")
        mislabelled.schemaVersion = 2
        XCTAssertThrowsError(try SensorBiomarkerInputs.decodePpgObject(wire: try wire(v), object: mislabelled)) { error in
            XCTAssertEqual(error as? SensorBiomarkerInputs.LoadError,
                           .formatMismatch(objectId: "lie", schema: 2, format: 3))
        }
        var unrecorded = try object(v, id: "legacy-row")
        unrecorded.schemaVersion = nil
        XCTAssertEqual(try SensorBiomarkerInputs.decodePpgObject(wire: try wire(v), object: unrecorded).count, 4)
    }

    func testCodecRejectsCorruptFormat3() throws {
        let v = try vector("all_members")
        let bytes = try Inflator.gunzip(try wire(v))
        XCTAssertEqual(bytes.map { String(format: "%02x", $0) }.joined(), v["decoded_hex"] as? String)
        // First record: header 10 | rowId 8 | ts 8 | index 1+8 | burst 1+4 -> hasAnchor at 40.
        for (offset, value) in [(40, UInt8(2)), (45, 2), (46, 2), (49, 2), (51, 1)] {
            var bad = bytes
            bad[offset] = value
            XCTAssertThrowsError(try SensorBiomarkerInputs.PpgCodec.unpack(bad), "offset \(offset)")
        }
        for size in [10, 39, 52, bytes.count - 1] {
            XCTAssertThrowsError(try SensorBiomarkerInputs.PpgCodec.unpack(bytes.prefix(size)), "size \(size)")
        }
    }

    // MARK: - Property: no cross-boundary runs or segments

    /// SplitMix64: a seeded, platform-independent generator so a failure is reproducible.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testGapsConfigurationAndClockChangesNeverCrossARunOrSegment() throws {
        for seed in UInt64(1)...60 {
            var rng = SplitMix(state: seed)
            var records: [SensorBiomarkerInputs.PpgWaveformInput] = []
            var ts: Int64 = 1_780_000_000 + Int64.random(in: 0..<3600, using: &rng)
            var burst: Int32 = 1, phase: UInt16? = nil
            for _ in 0..<Int.random(in: 20...400, using: &rng) {
                switch Int.random(in: 0..<100, using: &rng) {
                case 0..<6: ts += Int64.random(in: 2...30, using: &rng)            // a gap
                case 6..<10: burst += 1                                             // a new burst
                case 10..<13: phase = UInt16.random(in: 0..<32_768, using: &rng)    // a phase change
                default: break
                }
                let roll = Int.random(in: 0..<100, using: &rng)
                var deltas = (0..<24).map { _ in Int16.random(in: -400...400, using: &rng) }
                if roll < 4 { deltas[Int.random(in: 0..<24, using: &rng)] = Int16.max }  // saturated
                let anchor: Int32? = roll >= 4 && roll < 9 ? nil : Int32.random(in: 100_000...300_000, using: &rng)
                let count = roll == 99 ? 25 : 24
                if count == 25 { deltas.append(1) }
                records.append(.init(rowId: ts, ts: ts, samples: deltas, burstIndex: burst, baseCode: anchor,
                                     clockSource: .strapRecordSecond, subsecQ15: phase, format: 3))
                ts += 1
            }
            let reconstruction = SensorBiomarkerInputs.reconstructPPG(records: records.shuffled(using: &rng))
            let byTs = Dictionary(uniqueKeysWithValues: reconstruction.seconds.map { ($0.ts, $0) })
            let emitted = Set(reconstruction.seconds.filter { $0.withheldReason == nil }.map(\.ts))
            var covered = Set<Int64>()
            for run in reconstruction.runs {
                for t in run.start..<run.end {
                    let second = try XCTUnwrap(byTs[t], "seed \(seed): run \(run.runId) spans missing second \(t)")
                    XCTAssertNil(second.withheldReason, "seed \(seed): run \(run.runId) spans withheld second \(t)")
                    XCTAssertEqual(second.config, run.config, "seed \(seed): configuration changes inside \(run.runId)")
                    XCTAssertEqual(second.clock, run.clock, "seed \(seed): clock changes inside \(run.runId)")
                    XCTAssertTrue(covered.insert(t).inserted, "seed \(seed): second \(t) in two runs")
                }
                // A run is maximal: the neighbours are absent, withheld, or of another config/clock.
                for t in [run.start - 1, run.end] {
                    if let n = byTs[t], n.withheldReason == nil {
                        XCTAssertTrue(n.config != run.config || n.clock != run.clock, "seed \(seed): \(run.runId) not maximal")
                    }
                }
            }
            XCTAssertEqual(covered, emitted, "seed \(seed): every emitted second lands in exactly one run")

            // Segments through hour clipping and a random cap: contiguous within a run, never across.
            let cap = Int.random(in: 1...300, using: &rng)
            var lastByRun: [String: SensorBiomarkerInputs.PpgSegment] = [:]
            var sampleSeconds = 0
            let first = reconstruction.runs.first?.start ?? 0, last = reconstruction.runs.last?.end ?? 0
            for hour in stride(from: first - first % 3600, to: last, by: 3600) {
                for piece in SensorBiomarkerInputs.clip(reconstruction.runs, from: hour, to: hour + 3600) {
                    for segment in SensorBiomarkerInputs.ppgSegments(run: piece, secondsByTs: byTs, maxDuration: cap) {
                        XCTAssertEqual(segment.samples.count, segment.durationS * 25, "seed \(seed)")
                        XCTAssertLessThanOrEqual(segment.durationS, cap)
                        XCTAssertEqual(segment.config, piece.config)
                        if let previous = lastByRun[segment.runId] {
                            XCTAssertEqual(previous.startUnix + Int64(previous.durationS), segment.startUnix,
                                           "seed \(seed): segments of \(segment.runId) must be contiguous")
                            XCTAssertEqual(previous.config, segment.config)
                            XCTAssertEqual(previous.clock, segment.clock)
                        }
                        lastByRun[segment.runId] = segment
                        sampleSeconds += segment.durationS
                    }
                }
            }
            XCTAssertEqual(sampleSeconds, emitted.count, "seed \(seed): no sample in two segments, none lost")
        }
    }

    // MARK: - The request the lane posts

    /// Regenerate with FRWHOOP_SENSOR_ENVELOPE_OUTPUT=<path>; the sidecar tests read the committed copy.
    func testRequestEnvelopeGolden() throws {
        let v = try vector("phone_real_frames")
        let object = try object(v, id: "33333333-3333-4333-8333-333333333333")
        let ppg = SensorBiomarkerInputs.reconstructPPG(records: try inputs("phone_real_frames"))
        let byTs = Dictionary(uniqueKeysWithValues: ppg.seconds.map { ($0.ts, $0) })
        // Two seconds of stationary IMU over the first PPG run (az = 1 g), so both modalities appear.
        var columns = [Int16](repeating: 0, count: 600)
        for i in 200..<300 { columns[i] = 4096 }
        let imu = try SensorBiomarkerInputs.imuTimeline([1_780_917_232, 1_780_917_233].map {
            Npb1ImuDecoder.Record(rowId: $0, ts: $0, columns: columns) })
        let job = SensorBiomarkerLane.SensorBiomarkerJob(
            userId: "11111111-1111-4111-8111-111111111111", deviceId: "22222222-2222-4222-8222-222222222222",
            day: "2026-06-08", analysisVersion: SensorBiomarkerLane.analysisVersion,
            fingerprint: String(repeating: "a", count: 64), inputRevision: 1,
            leaseToken: "44444444-4444-4444-8444-444444444444",
            families: ["movement", "ppg_quality", "pulse_shape", "rhythm_shadow"], objectIds: [], digests: [])
        let placement = [SensorBiomarkerInputs.PlacementInterval(start: 1_780_900_000, end: nil, placement: "wrist",
                                                                 source: "user", deviceScoped: false)]
        let hour: Int64 = 1_780_916_400
        let requests = try SensorBiomarkerInputs.buildRequests(
            imuRuns: SensorBiomarkerInputs.clip(SensorBiomarkerInputs.imuRuns(imu), from: hour, to: hour + 3600),
            ppgRuns: SensorBiomarkerInputs.clip(ppg.runs, from: hour, to: hour + 3600),
            imuTimeline: imu, ppgSecondsByTs: byTs, objects: [object], deviceID: job.deviceId,
            dayUTC: job.day, families: job.families, placement: placement)
        XCTAssertEqual(requests.count, 1)
        let body = try SensorBiomarkerLane.inferenceBody(job: job, built: requests[0])

        // The members the shared contract promises (docs/model-integration/README.md).
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try XCTUnwrap(parsed["input"] as? [String: Any])
        XCTAssertEqual(input["families"] as? [String], job.families)
        let section = try XCTUnwrap(input["ppg"] as? [String: Any])
        XCTAssertEqual(section["native_rate_hz"] as? Int, 25)
        let segments = try XCTUnwrap(section["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.map { $0["run_id"] as? String }, ["ppg-1780917232", "ppg-1780918392"])
        for segment in segments {
            let clock = try XCTUnwrap(segment["clock"] as? [String: Any])
            XCTAssertEqual(clock["samples_per_second"] as? Int, section["native_rate_hz"] as? Int)
            XCTAssertEqual(clock["packet_timing_verified"] as? Bool, false)
            XCTAssertTrue(clock["phase_s"] is NSNull)
            let config = try XCTUnwrap(segment["config"] as? [String: Any])
            XCTAssertEqual(config["identity"] as? String, "unknown")
            XCTAssertEqual(config["known"] as? Bool, false)
            XCTAssertEqual(config["stable"] as? Bool, true)
            XCTAssertEqual((segment["samples"] as? [Any])?.count, (segment["duration_s"] as? Int).map { $0 * 25 })
        }
        let coverage = try XCTUnwrap(input["coverage"] as? [String: Any])
        let ppgCoverage = try XCTUnwrap(coverage["ppg"] as? [String: Any])
        XCTAssertEqual(ppgCoverage["expected_seconds"] as? Int, 4)
        XCTAssertEqual(ppgCoverage["eligible_seconds"] as? Int, 3)
        XCTAssertEqual(ppgCoverage["withheld"] as? [String: Int], ["saturated_delta": 1])
        XCTAssertEqual((input["placement"] as? [String: Any])?["body_location"] as? String, "wrist")
        XCTAssertEqual(input["watch_side"] as? String, "unknown")

        if let path = ProcessInfo.processInfo.environment["FRWHOOP_SENSOR_ENVELOPE_OUTPUT"] {
            try body.write(to: URL(fileURLWithPath: path), options: .atomic)
        } else {
            let path = "Tests/frwhoop-workerTests/Resources/sensor_biomarkers/sensor_biomarkers_request_envelope.json"
            guard FileManager.default.fileExists(atPath: path) else {
                throw XCTSkip("\(path) not found from \(FileManager.default.currentDirectoryPath)")
            }
            XCTAssertEqual(body, try Data(contentsOf: URL(fileURLWithPath: path)),
                           "the committed envelope must be exactly what the lane posts")
        }
    }
}
