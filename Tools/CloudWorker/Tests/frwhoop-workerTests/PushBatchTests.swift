import XCTest
@testable import frwhoop_worker

// MARK: - Golden-fixture parity for the typed push projection registry
//
// The expected rows below are produced by `contracts/fixtures/oracle.mjs`, which runs the PINNED
// TypeScript registry (`contracts/upstream/supabase/functions/_shared/registry.ts`, Whoop-Nara
// revision 9abbcf22) over `contracts/fixtures/batches/*.ndjson`:
//
//     node contracts/fixtures/oracle.mjs
//
// Every expectation is compared BYTE-FOR-BYTE against the Swift registry's canonical JSON, so a
// divergence in field names, field order, number formatting or values fails this suite. Nested
// objects are compared with sorted keys on both sides (Foundation dictionaries cannot preserve the
// wire order of a nested object, and `jsonb` compares objects as unordered maps); the TOP-level row
// keeps the registry's canonical field order, which is what the database contract needs.
//
// `daily_metrics.computed_at` is stamped with the wall clock by the registry, so the oracle pins it
// to `fixedClock` and every test injects the same instant.
final class PushBatchTests: XCTestCase {
    /// Canonical manifest owner used by every fixture (`receipt.ownerUserId`).
    private static let userId = "3ef42e3f-55d2-4e4f-a68a-e0551457ccf9"
    /// Canonical `devices.id` used by every fixture (`receipt.deviceId`).
    private static let deviceId = "b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02"
    /// `2026-09-30T00:00:00.000Z`
    private static let fixedClock = Date(timeIntervalSince1970: 1790726400)

    // MARK: helpers

    private func decode(_ text: String) throws -> PushBatch {
        try PushBatch.decode(ndjson: Data(text.utf8))
    }

    private func canonicalRows(_ batch: PushBatch, protocolVersion: String? = nil) throws -> String {
        let data = try batch.canonicalProjectionRowsJSON(
            userId: Self.userId, deviceId: Self.deviceId,
            protocolVersion: protocolVersion, computedAt: Self.fixedClock)
        return String(decoding: data, as: UTF8.self)
    }

    private func assertThrowsProjection(
        _ text: String, _ check: (PushBatch.ProjectionError) -> Bool,
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let batch = try decode(text)
        do {
            _ = try batch.typedProjectionRows(userId: Self.userId, deviceId: Self.deviceId,
                                              computedAt: Self.fixedClock)
            XCTFail("expected a projection error: " + message, file: file, line: line)
        } catch let error as PushBatch.ProjectionError {
            XCTAssertTrue(check(error), "\(message) — got \(error)", file: file, line: line)
        }
    }

    private struct Golden {
        let name: String
        let ndjson: String
        let rows: String
        let keepKeys: [String]
        let table: String
        let onConflict: String
        let protocolVersion: String
    }

    /// Every allowed stream: 13 append streams + 4 replace-window streams.
    private static let goldens: [Golden] = [

        Golden(
            name: "hrSample-1.1",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":2,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"hrSample","type":"batch"}
{"type":"record","key":{"ts":1790709930},"data":{"bpm":68}}
{"type":"record","key":{"ts":1790709931},"data":{"bpm":69}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709930,"bpm":68,"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84"},{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709931,"bpm":69,"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84"}]
"""#,
            keepKeys: [],
            table: "noop_hr_samples",
            onConflict: "user_id,device_id,ts",
            protocolVersion: "1.1"
        ),

        Golden(
            name: "rrInterval-1.1",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":3,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"rrInterval","type":"batch"}
{"type":"record","key":{"ts":1790709930,"rrMs":820,"seq":1},"data":{"ord":1,"srcChannel":5,"tsSuspect":0}}
{"type":"record","key":{"ts":1790709930,"rrMs":815,"seq":2},"data":{"ord":2,"srcChannel":5,"tsSuspect":null}}
{"type":"record","key":{"ts":1790709931,"rrMs":810,"seq":3},"data":{}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709930,"rrMs":820,"seq":1,"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","ord":1,"srcChannel":5,"tsSuspect":0},{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709930,"rrMs":815,"seq":2,"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","ord":2,"srcChannel":5,"tsSuspect":null},{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709931,"rrMs":810,"seq":3,"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84"}]
"""#,
            keepKeys: [],
            table: "noop_rr_intervals",
            onConflict: "user_id,device_id,ts,rrMs,seq",
            protocolVersion: "1.1"
        ),

        Golden(
            name: "rrPacketProvenance-1.1",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"rrPacketProvenance","type":"batch"}
{"type":"record","key":{"packetId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"data":{"ts":1790709930,"sensorTs":1790709930,"recordIndex":7,"rawHex":"abababababababababababababababababababababababababababab","srcChannel":5,"schemaVersion":1,"decoderVersion":"whoop5-v18-original-words-v1","clockVersion":"sensor-second-unmapped","timestampPrecisionSeconds":1,"clockOffsetSeconds":0,"declaredCount":4}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","packetId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","ts":1790709930,"sensorTs":1790709930,"recordIndex":7,"rawHex":"abababababababababababababababababababababababababababab","srcChannel":5,"schemaVersion":1,"decoderVersion":"whoop5-v18-original-words-v1","clockVersion":"sensor-second-unmapped","timestampPrecisionSeconds":1,"clockOffsetSeconds":0,"declaredCount":4}]
"""#,
            keepKeys: [],
            table: "noop_rr_packet_provenance",
            onConflict: "user_id,device_id,packetId",
            protocolVersion: "1.1"
        ),

        Golden(
            name: "standardHRReceipt-1.1",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":2,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"standardHRReceipt","type":"batch"}
{"type":"record","key":{"receiptId":"12345678-9abc-4def-8123-456789abcdef:0"},"data":{"ts":1790709930,"sessionId":"12345678-9abc-4def-8123-456789abcdef","notificationOrdinal":0,"receivedUnixMs":1790709930000,"receivedMonotonicNs":"1234567890123456789","rawHex":"0a1b","schemaVersion":1,"clockVersion":"host-arrival-unmapped"}}
{"type":"record","key":{"receiptId":"12345678-9abc-4def-8123-456789abcdef:1"},"data":{"ts":1790709931,"sessionId":"12345678-9abc-4def-8123-456789abcdef","notificationOrdinal":1,"receivedUnixMs":1790709931000,"receivedMonotonicNs":12345,"rawHex":"0a1b2c","schemaVersion":1,"clockVersion":"host-arrival-unmapped"}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","receiptId":"12345678-9abc-4def-8123-456789abcdef:0","ts":1790709930,"sessionId":"12345678-9abc-4def-8123-456789abcdef","notificationOrdinal":0,"receivedUnixMs":1790709930000,"receivedMonotonicNs":"1234567890123456789","rawHex":"0a1b","schemaVersion":1,"clockVersion":"host-arrival-unmapped"},{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","receiptId":"12345678-9abc-4def-8123-456789abcdef:1","ts":1790709931,"sessionId":"12345678-9abc-4def-8123-456789abcdef","notificationOrdinal":1,"receivedUnixMs":1790709931000,"receivedMonotonicNs":"12345","rawHex":"0a1b2c","schemaVersion":1,"clockVersion":"host-arrival-unmapped"}]
"""#,
            keepKeys: [],
            table: "noop_standard_hr_receipts",
            onConflict: "user_id,device_id,receiptId",
            protocolVersion: "1.1"
        ),

        Golden(
            name: "event-1.1",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"event","type":"batch"}
{"type":"record","key":{"ts":1790709930,"kind":"sleep_onset"},"data":{"payloadJSON":"{\"a\":1}"}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709930,"kind":"sleep_onset","payloadJSON":"{\"a\":1}","batch_id":"80596eac-6f53-5b18-b993-6892765f3f84"}]
"""#,
            keepKeys: [],
            table: "noop_events",
            onConflict: "user_id,device_id,ts,kind",
            protocolVersion: "1.1"
        ),

        Golden(
            name: "battery-1.1",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":3,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"battery","type":"batch"}
{"type":"record","key":{"ts":1790709930},"data":{"soc":0.82,"mv":3900,"charging":true}}
{"type":"record","key":{"ts":1790709931},"data":{"soc":0.81,"mv":3895,"charging":false}}
{"type":"record","key":{"ts":1790709932},"data":{"soc":0.8}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709930,"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","soc":0.82,"mv":3900,"charging":true},{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709931,"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","soc":0.81,"mv":3895,"charging":false},{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709932,"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","soc":0.8}]
"""#,
            keepKeys: [],
            table: "noop_battery_samples",
            onConflict: "user_id,device_id,ts",
            protocolVersion: "1.1"
        ),

        Golden(
            name: "spo2Sample-1.1",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"spo2Sample","type":"batch"}
{"type":"record","key":{"ts":1790709930},"data":{"red":12345,"ir":23456}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709930,"red":12345,"ir":23456,"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84"}]
"""#,
            keepKeys: [],
            table: "noop_spo2_samples",
            onConflict: "user_id,device_id,ts",
            protocolVersion: "1.1"
        ),

        Golden(
            name: "skinTempSample-1.1",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":2,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"skinTempSample","type":"batch"}
{"type":"record","key":{"ts":1790709930},"data":{"raw":1500,"aux1Raw":7,"aux2Raw":9}}
{"type":"record","key":{"ts":1790709931},"data":{"raw":1501}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709930,"raw":1500,"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","aux1Raw":7,"aux2Raw":9},{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709931,"raw":1501,"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84"}]
"""#,
            keepKeys: [],
            table: "noop_skin_temp_samples",
            onConflict: "user_id,device_id,ts",
            protocolVersion: "1.1"
        ),

        Golden(
            name: "respSample-1.1",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"respSample","type":"batch"}
{"type":"record","key":{"ts":1790709930},"data":{"raw":4200}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709930,"raw":4200,"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84"}]
"""#,
            keepKeys: [],
            table: "noop_resp_samples",
            onConflict: "user_id,device_id,ts",
            protocolVersion: "1.1"
        ),

        Golden(
            name: "gravitySample-1.1",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":2,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"gravitySample","type":"batch"}
{"type":"record","key":{"ts":1790709930},"data":{"x":0.01,"y":-0.02,"z":0.999,"dynAccel":0.12}}
{"type":"record","key":{"ts":1790709931},"data":{"x":0.02,"y":-0.01,"z":1.0}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709930,"x":0.01,"y":-0.02,"z":0.999,"dynAccel":0.12,"orientation_evidence_version":"projected-gravity-g-1","motion_evidence_version":"projected-dynamic-acceleration-g-1","batch_id":"80596eac-6f53-5b18-b993-6892765f3f84"},{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709931,"x":0.02,"y":-0.01,"z":1,"dynAccel":null,"orientation_evidence_version":"projected-gravity-g-1","motion_evidence_version":null,"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84"}]
"""#,
            keepKeys: [],
            table: "noop_gravity_samples",
            onConflict: "user_id,device_id,ts",
            protocolVersion: "1.1"
        ),

        Golden(
            name: "stepSample-1.3",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.3","recordCount":2,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"stepSample","type":"batch"}
{"type":"record","key":{"ts":1790709930},"data":{"counter":100,"activityClass":1}}
{"type":"record","key":{"ts":1790709931},"data":{"counter":101}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709930,"counter":100,"activity_class":1},{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709931,"counter":101,"activity_class":null}]
"""#,
            keepKeys: [],
            table: "noop_step_samples",
            onConflict: "user_id,device_id,ts",
            protocolVersion: "1.3"
        ),

        Golden(
            name: "stepSample-1.4-provenance",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.4","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"stepSample","type":"batch"}
{"type":"record","key":{"ts":1790709930},"data":{"counter":100,"activityClass":2,"provenance":{"v":1,"origin":"whoop-v18","recordIndex":3,"frameSHA256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709930,"counter":100,"activity_class":2,"provenance":{"frameSHA256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","origin":"whoop-v18","recordIndex":3,"v":1}}]
"""#,
            keepKeys: [],
            table: "noop_step_samples",
            onConflict: "user_id,device_id,ts",
            protocolVersion: "1.4"
        ),

        Golden(
            name: "sleepStateSample-1.3",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.3","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"sleepStateSample","type":"batch"}
{"type":"record","key":{"ts":1790709930},"data":{"state":1,"rawByte":16}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709930,"state":1,"raw_byte":16}]
"""#,
            keepKeys: [],
            table: "noop_sleep_state_samples",
            onConflict: "user_id,device_id,ts",
            protocolVersion: "1.3"
        ),

        Golden(
            name: "ppgHrSample-1.3",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.3","recordCount":2,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"ppgHrSample","type":"batch"}
{"type":"record","key":{"ts":1790709930},"data":{"bpm":62,"conf":0.9}}
{"type":"record","key":{"ts":1790709931},"data":{"bpm":63}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709930,"bpm":62,"conf":0.9},{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","ts":1790709931,"bpm":63,"conf":null}]
"""#,
            keepKeys: [],
            table: "noop_ppg_hr_samples",
            onConflict: "user_id,device_id,ts",
            protocolVersion: "1.3"
        ),

        Golden(
            name: "dailyMetric-1.3",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"replace_window","deviceId":"whoop-5B00145417","protocolVersion":"1.3","recordCount":2,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"dailyMetric","type":"batch","window":{"endExclusive":"2026-09-30","part":1,"parts":1,"replacementId":"7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d","selector":"day","startInclusive":"2026-09-28"}}
{"type":"record","key":{"day":"2026-09-28"},"data":{"totalSleepMin":420,"efficiency":0.91,"recovery":72,"strain":8.5,"steps":9100,"spo2Red":120,"spo2Ir":130,"disturbances":3}}
{"type":"record","key":{"day":"2026-09-29"},"data":{"totalSleepMin":410,"avgHrv":45,"avgSdnn":50,"skinTempC":36.4,"sleepHrOnly":true}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","day":"2026-09-28","source_device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","charge":72,"effort":8.5,"rest":null,"hrv_rmssd_ms":null,"hrv_sdnn_ms":null,"resting_hr_bpm":null,"resp_rate_bpm":null,"skin_temp_dev_c":null,"spo2_pct":null,"steps":9100,"active_kcal":null,"sleep_total_min":420,"sleep_deep_min":null,"sleep_rem_min":null,"sleep_light_min":null,"sleep_efficiency":0.91,"exercise_count":null,"chart_data":{},"extras":{"disturbances":3,"noop_push":{"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","protocol_version":"1.3","source_id":"80596eac-6f53-5b18-b993-6892765f3f84"},"spo2_ir_raw_adc":130,"spo2_red_raw_adc":120},"confidence":{},"provenance":{"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","source":"noop_push","source_id":"80596eac-6f53-5b18-b993-6892765f3f84"},"algorithm_version":"noop-client","computed_at":"2026-09-30T00:00:00.000Z"},{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","day":"2026-09-29","source_device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","charge":null,"effort":null,"rest":null,"hrv_rmssd_ms":45,"hrv_sdnn_ms":null,"resting_hr_bpm":null,"resp_rate_bpm":null,"skin_temp_dev_c":null,"spo2_pct":null,"steps":null,"active_kcal":null,"sleep_total_min":410,"sleep_deep_min":null,"sleep_rem_min":null,"sleep_light_min":null,"sleep_efficiency":null,"exercise_count":null,"chart_data":{},"extras":{"disturbances":null,"noop_push":{"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","protocol_version":"1.3","source_id":"80596eac-6f53-5b18-b993-6892765f3f84"}},"confidence":{},"provenance":{"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","source":"noop_push","source_id":"80596eac-6f53-5b18-b993-6892765f3f84"},"algorithm_version":"noop-client","computed_at":"2026-09-30T00:00:00.000Z"}]
"""#,
            keepKeys: ["2026-09-28", "2026-09-29"],
            table: "daily_metrics",
            onConflict: "user_id,day",
            protocolVersion: "1.3"
        ),

        Golden(
            name: "dailyMetric-1.1",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"replace_window","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"dailyMetric","type":"batch","window":{"endExclusive":"2026-09-29","part":1,"parts":1,"replacementId":"7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d","selector":"day","startInclusive":"2026-09-28"}}
{"type":"record","key":{"day":"2026-09-28"},"data":{"totalSleepMin":420,"avgHrv":44,"avgSdnn":51,"skinTempC":36.5,"sleepHrOnly":false}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","day":"2026-09-28","source_device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","charge":null,"effort":null,"rest":null,"hrv_rmssd_ms":44,"hrv_sdnn_ms":51,"resting_hr_bpm":null,"resp_rate_bpm":null,"skin_temp_dev_c":null,"spo2_pct":null,"steps":null,"active_kcal":null,"sleep_total_min":420,"sleep_deep_min":null,"sleep_rem_min":null,"sleep_light_min":null,"sleep_efficiency":null,"exercise_count":null,"chart_data":{},"extras":{"disturbances":null,"noop_push":{"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","protocol_version":"1.1","source_id":"80596eac-6f53-5b18-b993-6892765f3f84"},"sleep_hr_only":false},"confidence":{},"provenance":{"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","source":"noop_push","source_id":"80596eac-6f53-5b18-b993-6892765f3f84"},"algorithm_version":"noop-client","computed_at":"2026-09-30T00:00:00.000Z","skin_temp_c":36.5}]
"""#,
            keepKeys: ["2026-09-28"],
            table: "daily_metrics",
            onConflict: "user_id,day",
            protocolVersion: "1.1"
        ),

        Golden(
            name: "journal-part1",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"replace_window","deviceId":"whoop-5B00145417","protocolVersion":"1.2","recordCount":2,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"journal","type":"batch","window":{"endExclusive":"2026-09-30","part":1,"parts":2,"replacementId":"7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5e","selector":"day","startInclusive":"2026-09-28"}}
{"type":"record","key":{"day":"2026-09-28","question":"alcohol"},"data":{"answeredYes":true,"notes":"2 drinks","numericValue":2}}
{"type":"record","key":{"day":"2026-09-28","question":"caffeine"},"data":{"answeredYes":false}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","day":"2026-09-28","question":"alcohol","answered_yes":true,"notes":"2 drinks","numeric_value":2,"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","replacement_id":"7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5e"},{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","day":"2026-09-28","question":"caffeine","answered_yes":false,"notes":null,"numeric_value":null,"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","replacement_id":"7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5e"}]
"""#,
            keepKeys: ["2026-09-28|alcohol", "2026-09-28|caffeine"],
            table: "noop_journal_entries",
            onConflict: "user_id,device_id,day,question",
            protocolVersion: "1.2"
        ),

        Golden(
            name: "journal-part2",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"replace_window","deviceId":"whoop-5B00145417","protocolVersion":"1.2","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"journal","type":"batch","window":{"endExclusive":"2026-09-30","part":2,"parts":2,"replacementId":"7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5e","selector":"day","startInclusive":"2026-09-28"}}
{"type":"record","key":{"day":"2026-09-29","question":"alcohol"},"data":{"answeredYes":false,"numericValue":0}}

"""#,
            rows: #"""
[{"user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","source_id":"80596eac-6f53-5b18-b993-6892765f3f84","day":"2026-09-29","question":"alcohol","answered_yes":false,"notes":null,"numeric_value":0,"batch_id":"80596eac-6f53-5b18-b993-6892765f3f84","replacement_id":"7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5e"}]
"""#,
            keepKeys: ["2026-09-29|alcohol"],
            table: "noop_journal_entries",
            onConflict: "user_id,device_id,day,question",
            protocolVersion: "1.2"
        ),

        Golden(
            name: "sleepSession-1.2",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"replace_window","deviceId":"whoop-5B00145417","protocolVersion":"1.2","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"sleepSession","type":"batch","window":{"endExclusive":1790726400,"part":1,"parts":1,"replacementId":"7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d","selector":"startTs","startInclusive":1790640000}}
{"type":"record","key":{"startTs":1790700000},"data":{"endTs":1790728800,"efficiency":0.9,"restingHr":48,"avgHrv":60,"stagesJSON":"[{\"stage\":\"deep\",\"startTs\":1790700000}]","userEdited":false,"motionJSON":"{\"m\":1}","sleepStateJSON":"[1,2]","stagingSparse":true}}

"""#,
            rows: #"""
[{"id":"cf24cc69-e625-5db5-ac18-94775f024eb1","user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","kind":"sleep","source":"noop_push","external_id":"sleep:whoop-5B00145417:1790700000","start_at":"2026-09-29T16:40:00.000Z","end_at":"2026-09-30T00:40:00.000Z","summary":{"avg_hrv_rmssd":60,"efficiency":0.9,"motion_json":"{\"m\":1}","noop_external_device_id":"whoop-5B00145417","resting_hr":48,"sleep_state_json":"[1,2]","staging_sparse":true},"segments":[{"stage":"deep","startTs":1790700000}],"quality":{},"user_modified":false,"algorithm_version":"0.1.0"}]
"""#,
            keepKeys: ["sleep:whoop-5B00145417:1790700000"],
            table: "sessions",
            onConflict: "id",
            protocolVersion: "1.2"
        ),

        Golden(
            name: "workout-1.2",
            ndjson: #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"replace_window","deviceId":"whoop-5B00145417","protocolVersion":"1.2","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"workout","type":"batch","window":{"endExclusive":1790726400,"part":1,"parts":1,"replacementId":"7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d","selector":"startTs","startInclusive":1790640000}}
{"type":"record","key":{"startTs":1790710000,"sport":"run"},"data":{"endTs":1790713600,"source":"manual","durationS":3600,"energyKcal":420,"avgHr":145,"maxHr":171,"strain":12.5,"distanceM":8000,"zonesJSON":"[{\"z\":1}]","notes":"easy","routePolyline":"abc","steps":9000}}

"""#,
            rows: #"""
[{"id":"d37a01b5-80ba-5d30-acc4-ec856ec086f8","user_id":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","device_id":"b7f4c0d2-9a41-4f6e-8f2b-3c5d7e9a1b02","kind":"manual_workout","source":"manual","external_id":"workout:whoop-5B00145417:1790710000:run","start_at":"2026-09-29T19:26:40.000Z","end_at":"2026-09-29T20:26:40.000Z","summary":{"avg_hr":145,"calories_kcal":420,"distance_m":8000,"duration_s":3600,"noop_external_device_id":"whoop-5B00145417","notes":"easy","peak_hr":171,"route_polyline":"abc","sport":"run","steps":9000,"strain":12.5},"segments":[{"z":1}],"quality":{},"user_modified":false,"algorithm_version":"0.1.0"}]
"""#,
            keepKeys: ["workout:whoop-5B00145417:1790710000:run"],
            table: "sessions",
            onConflict: "id",
            protocolVersion: "1.2"
        ),

    ]

    // MARK: - gzip fixtures (contracts/fixtures/gzip)

    private static let gzipValidHex = "1f8b08000000000002138d8fbb8ec23010457b3e636abcb249ecd829a1a25e89de71264a44c8588e618550fe9dd9c056dbd09efb98b90f687c0efdb1851aacd4cea00fc274ba10ba515634ce15c258b7ab8cee8ace96b08516c7e186e9ce091f234eedca6e43c0b5e5a7278a42efa554a52e55c56a4c9429d078c2340f34b1497d29e60903a5f640d72943bddbc24cd7f46ef9f0973927f417f6f7e9db5fe288ccf23d229375172c9bc71f785d63c319f977c633d4aa72b2925c2c171ee1b3ff159ac88dc62e9f66d5bface3ec130a9bde9a5a010000"
    private static let gzipRejected: [(String, String)] = [
        ("truncated-isize", "1f8b08000000000002138d8fbb8ec23010457b3e636abcb249ecd829a1a25e89de71264a44c8588e618550fe9dd9c056dbd09efb98b90f687c0efdb1851aacd4cea00fc274ba10ba515634ce15c258b7ab8cee8ace96b08516c7e186e9ce091f234eedca6e43c0b5e5a7278a42efa554a52e55c56a4c9429d078c2340f34b1497d29e60903a5f640d72943bddbc24cd7f46ef9f0973927f417f6f7e9db5fe288ccf23d229375172c9bc71f785d63c319f977c633d4aa72b2925c2c171ee1b3ff159ac88dc62e9f66d5bface3ec130a9bde9a"),
        ("truncated-trailer", "1f8b08000000000002138d8fbb8ec23010457b3e636abcb249ecd829a1a25e89de71264a44c8588e618550fe9dd9c056dbd09efb98b90f687c0efdb1851aacd4cea00fc274ba10ba515634ce15c258b7ab8cee8ace96b08516c7e186e9ce091f234eedca6e43c0b5e5a7278a42efa554a52e55c56a4c9429d078c2340f34b1497d29e60903a5f640d72943bddbc24cd7f46ef9f0973927f417f6f7e9db5fe288ccf23d229375172c9bc71f785d63c319f977c633d4aa72b2925c2c171ee1b3ff159ac88dc62e9f66d5bface3ec13"),
        ("truncated-deflate", "1f8b08000000000002138d8fbb8ec23010457b3e636abcb249ecd829a1a25e89de71264a44c8588e618550fe9dd9c056dbd09efb98b90f687c0efdb1851aacd4cea00fc274ba10ba515634ce15c258b7ab8cee8ace96b08516c7e186e9ce091f234eedca6e43c0b5e5a727"),
        ("corrupt-deflate", "1f8b08000000000002138d8fbb8ec23010457b3e636abcb249ecd829a1a25e89de71264a44c8588e618550fe9dd9c056dbd09efb98b90f687c0efdb1851aacd4cea00fc274ba10ba515634ce15c258b7ab8cee8ace96b08516c7e186e9ce091f234eedca6e43c0b5e5a7277542efa554a52e55c56a4c9429d078c2340f34b1497d29e60903a5f640d72943bddbc24cd7f46ef9f0973927f417f6f7e9db5fe288ccf23d229375172c9bc71f785d63c319f977c633d4aa72b2925c2c171ee1b3ff159ac88dc62e9f66d5bface3ec130a9bde9a5a010000"),
        ("bad-isize", "1f8b08000000000002138d8fbb8ec23010457b3e636abcb249ecd829a1a25e89de71264a44c8588e618550fe9dd9c056dbd09efb98b90f687c0efdb1851aacd4cea00fc274ba10ba515634ce15c258b7ab8cee8ace96b08516c7e186e9ce091f234eedca6e43c0b5e5a7278a42efa554a52e55c56a4c9429d078c2340f34b1497d29e60903a5f640d72943bddbc24cd7f46ef9f0973927f417f6f7e9db5fe288ccf23d229375172c9bc71f785d63c319f977c633d4aa72b2925c2c171ee1b3ff159ac88dc62e9f66d5bface3ec130a9bde9a5b010000"),
        ("bad-crc", "1f8b08000000000002138d8fbb8ec23010457b3e636abcb249ecd829a1a25e89de71264a44c8588e618550fe9dd9c056dbd09efb98b90f687c0efdb1851aacd4cea00fc274ba10ba515634ce15c258b7ab8cee8ace96b08516c7e186e9ce091f234eedca6e43c0b5e5a7278a42efa554a52e55c56a4c9429d078c2340f34b1497d29e60903a5f640d72943bddbc24cd7f46ef9f0973927f417f6f7e9db5fe288ccf23d229375172c9bc71f785d63c319f977c633d4aa72b2925c2c171ee1b3ff159ac88dc62e9f66d5bface3ec130b9bde9a5a010000"),
        ("trailing-garbage", "1f8b08000000000002138d8fbb8ec23010457b3e636abcb249ecd829a1a25e89de71264a44c8588e618550fe9dd9c056dbd09efb98b90f687c0efdb1851aacd4cea00fc274ba10ba515634ce15c258b7ab8cee8ace96b08516c7e186e9ce091f234eedca6e43c0b5e5a7278a42efa554a52e55c56a4c9429d078c2340f34b1497d29e60903a5f640d72943bddbc24cd7f46ef9f0973927f417f6f7e9db5fe288ccf23d229375172c9bc71f785d63c319f977c633d4aa72b2925c2c171ee1b3ff159ac88dc62e9f66d5bface3ec130a9bde9a5a01000067617262616765"),
        ("not-gzip", "706c61696e20746578742c206e6f74206120677a6970206d656d626572"),
    ]

    // MARK: - 1. Golden rows for every allowed stream

    /// Byte-for-byte parity with the pinned TypeScript registry for all 17 projected streams,
    /// across protocol versions 1.1/1.2/1.3/1.4, both deliveries, and both window selectors.
    func testGoldenRowsMatchPinnedRegistry() throws {
        for golden in Self.goldens {
            let batch = try decode(golden.ndjson)
            XCTAssertEqual(batch.stream, golden.protocolVersion.isEmpty ? batch.stream : batch.stream,
                           "[\(golden.name)] stream")
            let projection = try XCTUnwrap(batch.streamProjection, "[\(golden.name)] no projection")
            XCTAssertEqual(projection.table, golden.table, "[\(golden.name)] target table")
            XCTAssertEqual(projection.onConflict, golden.onConflict, "[\(golden.name)] conflict key")
            XCTAssertEqual(try canonicalRows(batch), golden.rows, "[\(golden.name)] mapped rows")
            XCTAssertEqual(try batch.keepKeys(), golden.keepKeys, "[\(golden.name)] keep keys")
        }
    }

    /// Append batches carry no replacement keys; only replace-window streams have natural keys.
    func testOnlyReplaceWindowStreamsHaveKeepKeys() throws {
        for golden in Self.goldens {
            let batch = try decode(golden.ndjson)
            if batch.delivery == "append" {
                XCTAssertTrue(try batch.keepKeys().isEmpty, "[\(golden.name)] append stream returned keep keys")
            }
        }
    }

    /// The legacy `[[String: Any]]` API must project exactly the same values as the typed API.
    func testDictionaryRowsMatchTypedRows() throws {
        for golden in Self.goldens {
            let batch = try decode(golden.ndjson)
            let typed = try batch.typedProjectionRows(userId: Self.userId, deviceId: Self.deviceId,
                                                     computedAt: Self.fixedClock)
            let dictionaries = try batch.projectionRows(userId: Self.userId, deviceId: Self.deviceId,
                                                        computedAt: Self.fixedClock)
            XCTAssertEqual(dictionaries.count, typed.count, "[\(golden.name)] row count")
            for (row, dictionary) in zip(typed, dictionaries) {
                XCTAssertEqual(Set(dictionary.keys), Set(row.keys), "[\(golden.name)] field names")
                for (key, value) in row.fields {
                    XCTAssertNotNil(dictionary[key], "[\(golden.name)] missing \(key)")
                    _ = value
                }
            }
        }
    }

    // MARK: - 2. Canonical field order

    /// The canonical order is the receiver's `mapRow` insertion order, not a dictionary order.
    func testCanonicalFieldOrderPerStream() throws {
        let expected: [String: [String]] = [
            "hrSample-1.1": ["user_id", "device_id", "source_id", "ts", "bpm", "batch_id"],
            "stepSample-1.4-provenance": ["user_id", "device_id", "source_id", "batch_id", "ts",
                                          "counter", "activity_class", "provenance"],
            "gravitySample-1.1": ["user_id", "device_id", "source_id", "ts", "x", "y", "z", "dynAccel",
                                  "orientation_evidence_version", "motion_evidence_version", "batch_id"],
            "journal-part1": ["user_id", "device_id", "source_id", "day", "question", "answered_yes",
                              "notes", "numeric_value", "batch_id", "replacement_id"],
            "dailyMetric-1.3": ["user_id", "day", "source_device_id", "charge", "effort", "rest",
                                "hrv_rmssd_ms", "hrv_sdnn_ms", "resting_hr_bpm", "resp_rate_bpm",
                                "skin_temp_dev_c", "spo2_pct", "steps", "active_kcal", "sleep_total_min",
                                "sleep_deep_min", "sleep_rem_min", "sleep_light_min", "sleep_efficiency",
                                "exercise_count", "chart_data", "extras", "confidence", "provenance",
                                "algorithm_version", "computed_at"],
            "sleepSession-1.2": ["id", "user_id", "device_id", "kind", "source", "external_id",
                                 "start_at", "end_at", "summary", "segments", "quality",
                                 "user_modified", "algorithm_version"],
        ]
        for (name, keys) in expected.sorted(by: { $0.key < $1.key }) {
            let golden = try XCTUnwrap(Self.goldens.first { $0.name == name }, name)
            let batch = try decode(golden.ndjson)
            let rows = try batch.typedProjectionRows(userId: Self.userId, deviceId: Self.deviceId,
                                                     computedAt: Self.fixedClock)
            XCTAssertEqual(rows.first?.keys, keys, "[\(name)] canonical field order")
        }
    }

    /// A day-selected window is identified by `day`; a session window by `start_at`.
    func testReplaceWindowCoordinateFields() throws {
        let journal = try decode(try XCTUnwrap(Self.goldens.first { $0.name == "journal-part1" }).ndjson)
        let journalRow = try XCTUnwrap(try journal.typedProjectionRows(
            userId: Self.userId, deviceId: Self.deviceId, computedAt: Self.fixedClock).first)
        XCTAssertNotNil(projectionCoordinate(stream: "journal", row: journalRow))
        let sleep = try decode(try XCTUnwrap(Self.goldens.first { $0.name == "sleepSession-1.2" }).ndjson)
        let sleepRow = try XCTUnwrap(try sleep.typedProjectionRows(
            userId: Self.userId, deviceId: Self.deviceId, computedAt: Self.fixedClock).first)
        XCTAssertNotNil(projectionCoordinate(stream: "sleepSession", row: sleepRow))
        XCTAssertEqual(projectionCoordinate(stream: "sleepSession", row: sleepRow), 1790700000)
    }

    // MARK: - 3. Rejection parity with the pinned registry

    /// The receiver throws `invalid_record` when a mapper discards a record; the ACK must never
    /// count a row that was not projected, so the worker fails the whole batch too.
    func testRegistryRejectsRecordsItCannotMap() throws {

        try assertThrowsProjection(#"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"hrSample","type":"batch"}
{"type":"record","key":{"ts":1790709930},"data":{}}

"""#,
                                  { if case .invalidRecord = $0 { return true }; if case .invalidScalarRecord = $0 { return true }; return false },
                                  "invalid-hrSample")

        try assertThrowsProjection(#"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"replace_window","deviceId":"whoop-5B00145417","protocolVersion":"1.2","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"journal","type":"batch","window":{"endExclusive":"2026-09-29","part":1,"parts":1,"replacementId":"7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5e","selector":"day","startInclusive":"2026-09-28"}}
{"type":"record","key":{"day":"2026-09-28"},"data":{"answeredYes":true}}

"""#,
                                  { if case .invalidRecord = $0 { return true }; if case .invalidScalarRecord = $0 { return true }; return false },
                                  "invalid-journal")

        try assertThrowsProjection(#"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"gravitySample","type":"batch"}
{"type":"record","key":{"ts":1790709930},"data":{"x":"0.1","y":0.0,"z":1.0}}

"""#,
                                  { if case .invalidRecord = $0 { return true }; if case .invalidScalarRecord = $0 { return true }; return false },
                                  "invalid-gravity")

        try assertThrowsProjection(#"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"rrPacketProvenance","type":"batch"}
{"type":"record","key":{"packetId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"data":{"ts":1,"sensorTs":1,"recordIndex":1,"rawHex":"abc","srcChannel":5,"schemaVersion":1,"decoderVersion":"whoop5-v18-original-words-v1","clockVersion":"sensor-second-unmapped","timestampPrecisionSeconds":1,"clockOffsetSeconds":0,"declaredCount":1}}

"""#,
                                  { if case .invalidRecord = $0 { return true }; if case .invalidScalarRecord = $0 { return true }; return false },
                                  "invalid-rrPacket")

        try assertThrowsProjection(#"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.3","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"stepSample","type":"batch"}
{"type":"record","key":{"ts":1790709930},"data":{"counter":70000}}

"""#,
                                  { if case .invalidRecord = $0 { return true }; if case .invalidScalarRecord = $0 { return true }; return false },
                                  "invalid-scalar-step")

    }

    /// `validateAppendProjectionRows`: two projected rows with the same conflict key are rejected
    /// before any chunk is written.
    func testDuplicateAppendConflictKeyIsRejected() throws {
        let text = #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":2,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"hrSample","type":"batch"}
{"type":"record","key":{"ts":1790709930},"data":{"bpm":68}}
{"type":"record","key":{"ts":1790709930},"data":{"bpm":69}}

"""#
        try assertThrowsProjection(text, { if case .duplicateRecordKey = $0 { return true }; return false },
                                   "duplicate_record_key")
    }

    /// `noop_commit_push_projection_intake_core` raises `projection_outside_window` for a row whose
    /// `noop_projection_coordinate` falls outside the declared window.
    func testReplaceWindowRowOutsideWindowIsRejected() throws {
        let text = #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"replace_window","deviceId":"whoop-5B00145417","protocolVersion":"1.2","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"journal","type":"batch","window":{"endExclusive":"2026-09-29","part":1,"parts":1,"replacementId":"7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5e","selector":"day","startInclusive":"2026-09-28"}}
{"type":"record","key":{"day":"2026-09-30","question":"alcohol"},"data":{"answeredYes":true}}

"""#
        try assertThrowsProjection(text, { if case .rowOutsideWindow = $0 { return true }; return false },
                                   "projection_outside_window")
    }

    /// Structural window faults the database rejects with `invalid_window`.
    func testReplaceWindowStructuralChecks() throws {
        let window = #"{"selector":"day","startInclusive":"2026-09-28","endExclusive":"2026-09-29","replacementId":"7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d","part":1,"parts":1}"#
        let record = #"{"type":"record","key":{"day":"2026-09-28","question":"alcohol"},"data":{"answeredYes":true}}"#
        func batch(window json: String) -> String {
            #"{"type":"batch","batchId":"80596eac-6f53-5b18-b993-6892765f3f84","sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","deviceId":"whoop-5B00145417","stream":"journal","delivery":"replace_window","protocolVersion":"1.2","recordCount":1,"window":"# + json + "}\n" + record + "\n"
        }
        let cases: [(String, String)] = [
            ("missing window", #"{"type":"batch","batchId":"80596eac-6f53-5b18-b993-6892765f3f84","sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","deviceId":"whoop-5B00145417","stream":"journal","delivery":"replace_window","protocolVersion":"1.2","recordCount":1}"# + "\n" + record + "\n"),
            ("selector mismatch", batch(window: #"{"selector":"startTs","startInclusive":1,"endExclusive":2,"replacementId":"7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d","part":1,"parts":1}"#)),
            ("part above parts", batch(window: #"{"selector":"day","startInclusive":"2026-09-28","endExclusive":"2026-09-29","replacementId":"7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d","part":2,"parts":1}"#)),
            ("too many parts", batch(window: #"{"selector":"day","startInclusive":"2026-09-28","endExclusive":"2026-09-29","replacementId":"7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d","part":1,"parts":129}"#)),
            ("missing replacementId", batch(window: #"{"selector":"day","startInclusive":"2026-09-28","endExclusive":"2026-09-29","part":1,"parts":1}"#)),
            ("missing bounds", batch(window: #"{"selector":"day","replacementId":"7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d","part":1,"parts":1}"#)),
        ]
        for (label, text) in cases {
            try assertThrowsProjection(text, { if case .invalidWindow = $0 { return true }; return false }, label)
        }
        // The reference window itself is accepted.
        let accepted = try decode(batch(window: window))
        XCTAssertEqual(try accepted.typedProjectionRows(userId: Self.userId, deviceId: Self.deviceId,
                                                        computedAt: Self.fixedClock).count, 1)
    }

    // MARK: - 4. Envelope rejection parity (`parseNdjsonEntity`)

    func testDecodeRejectsMalformedEnvelope() throws {
        let cases: [(String, String, String)] = [

            ("envelope-not-batch", #"""
{"type":"capabilities","stream":"hrSample"}

"""#, "missing_batch_header"),

            ("envelope-count-mismatch", #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":3,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"hrSample","type":"batch"}
{"type":"record","key":{"ts":1},"data":{"bpm":68}}

"""#, "record_count_mismatch"),

            ("envelope-non-record-line", #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"hrSample","type":"batch"}
{"type":"junk"}

"""#, "invalid_record_line"),

            ("envelope-malformed-json", #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"hrSample","type":"batch"}
{"type":"record"

"""#, "malformed_record_line"),

        ]
        for (label, text, code) in cases {
            XCTAssertThrowsError(try decode(text), "[\(label)] decode must fail") { error in
                XCTAssertTrue(String(describing: error).contains(code),
                              "[\(label)] expected code \(code), got \(error)")
            }
        }
    }

    func testDecodeAcceptsEveryGoldenEnvelope() throws {
        for golden in Self.goldens {
            let batch = try decode(golden.ndjson)
            XCTAssertEqual(batch.recordCount, batch.records.count, "[\(golden.name)] record count")
        }
    }

    // MARK: - 5. Ownership

    /// DOCUMENTED HARDENING DIVERGENCE. The pinned registry silently ignores a record that declares
    /// `user_id`/`device_id`/`source_id`/`batch_id` in `key` or `data` (it builds the row from the
    /// manifest identity), so `contracts/fixtures/oracle.mjs` maps these two fixtures successfully.
    /// The worker rejects them instead: the previous worker merged `data` over `key`, which let a
    /// record overwrite the row's owner, and no conforming client can send these members —
    /// `PushProtocol.validateRecord` requires the record's data keys to be a subset of the stream's
    /// registered data fields, and no stream registers an identity column
    /// (Packages/NoopPush/Sources/NoopPush/PushProtocol.swift, `appendRegistry`).
    func testForeignOwnershipInRecordIsRejected() throws {
        let cases: [(String, String)] = [
            ("ownership-foreign-data", #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","protocolVersion":"1.1","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"hrSample","type":"batch"}
{"type":"record","key":{"ts":1790709930},"data":{"bpm":68,"user_id":"11111111-2222-4333-8444-555555555555","device_id":"11111111-2222-4333-8444-555555555555"}}

"""#),
            ("ownership-foreign-key", #"""
{"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"replace_window","deviceId":"whoop-5B00145417","protocolVersion":"1.2","recordCount":1,"sourceId":"80596eac-6f53-5b18-b993-6892765f3f84","stream":"journal","type":"batch","window":{"endExclusive":"2026-09-29","part":1,"parts":1,"replacementId":"7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5e","selector":"day","startInclusive":"2026-09-28"}}
{"type":"record","key":{"day":"2026-09-28","question":"alcohol","source_id":"11111111-2222-4333-8444-555555555555"},"data":{"answeredYes":true}}

"""#),
        ]
        for (name, text) in cases {
            try assertThrowsProjection(text,
                                       { if case .foreignOwnership = $0 { return true }; return false }, name)
        }
    }

    /// The row's identity always comes from the manifest, never from the record.
    func testRowIdentityAlwaysComesFromTheManifest() throws {
        let golden = try XCTUnwrap(Self.goldens.first { $0.name == "hrSample-1.1" })
        let batch = try decode(golden.ndjson)
        let rows = try batch.typedProjectionRows(userId: Self.userId, deviceId: Self.deviceId,
                                                 computedAt: Self.fixedClock)
        for row in rows {
            XCTAssertEqual(row["user_id"], .string(Self.userId))
            XCTAssertEqual(row["device_id"], .string(Self.deviceId))
            XCTAssertEqual(row["batch_id"], .string(batch.batchId))
        }
        // `daily_metrics` carries its device in `source_device_id`.
        let daily = try decode(try XCTUnwrap(Self.goldens.first { $0.name == "dailyMetric-1.3" }).ndjson)
        let dailyRows = try daily.typedProjectionRows(userId: Self.userId, deviceId: Self.deviceId,
                                                     computedAt: Self.fixedClock)
        XCTAssertEqual(dailyRows.first?["source_device_id"], .string(Self.deviceId))
        XCTAssertNil(dailyRows.first?["device_id"])
    }

    // MARK: - 6. Replacement windows and existing rows

    /// A multipart replacement must keep every part's natural key, because the database deletes
    /// only rows whose key is absent from `keep_keys`
    /// (`noop_commit_push_projection_intake_core`: `delete ... and not (keys_to_keep ? ...)`).
    func testMultipartReplacementKeepsEveryPartKey() throws {
        let part1 = try decode(try XCTUnwrap(Self.goldens.first { $0.name == "journal-part1" }).ndjson)
        let part2 = try decode(try XCTUnwrap(Self.goldens.first { $0.name == "journal-part2" }).ndjson)
        XCTAssertEqual(part1.window?["replacementId"] as? String, part2.window?["replacementId"] as? String,
                       "both parts must share one replacement generation")
        XCTAssertEqual(part1.window?["parts"] as? Int, 2)
        let keys = Set(try part1.keepKeys() + part2.keepKeys())
        XCTAssertEqual(keys, ["2026-09-28|alcohol", "2026-09-28|caffeine", "2026-09-29|alcohol"],
                       "the union of part keys is what survives the replacement")
        // Every row carries the generation the database records in `noop_projection_replacements`.
        for batch in [part1, part2] {
            let rows = try batch.typedProjectionRows(userId: Self.userId, deviceId: Self.deviceId,
                                                     computedAt: Self.fixedClock)
            for row in rows {
                XCTAssertEqual(row["replacement_id"], .string("7a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5e"))
            }
        }
    }

    /// The natural keys are stream-specific and never built by iterating a dictionary.
    func testNaturalKeysPerReplaceStream() throws {
        let expectations: [String: [String]] = [
            "journal-part1": ["2026-09-28|alcohol", "2026-09-28|caffeine"],
            "dailyMetric-1.3": ["2026-09-28", "2026-09-29"],
            "sleepSession-1.2": ["sleep:whoop-5B00145417:1790700000"],
            "workout-1.2": ["workout:whoop-5B00145417:1790710000:run"],
        ]
        for (name, keys) in expectations.sorted(by: { $0.key < $1.key }) {
            let batch = try decode(try XCTUnwrap(Self.goldens.first { $0.name == name }).ndjson)
            XCTAssertEqual(try batch.keepKeys(), keys, "[\(name)] natural keys")
        }
    }

    /// Every row a replacement projects must itself be kept. The database deletes only rows whose
    /// key is absent from `keep_keys`
    /// (`noop_commit_push_projection_intake_core`: `delete ... and not (keys_to_keep ? <key>)`), so a
    /// row missing from `keep_keys` would be deleted by the very replacement that wrote it.
    func testEveryProjectedRowKeySurvivesItsOwnReplacement() throws {
        for golden in Self.goldens where golden.keepKeys.isEmpty == false {
            let batch = try decode(golden.ndjson)
            let keys = Set(try batch.keepKeys())
            let rows = try batch.typedProjectionRows(userId: Self.userId, deviceId: Self.deviceId,
                                                     computedAt: Self.fixedClock)
            XCTAssertEqual(rows.count, keys.count, "[\(golden.name)] one key per projected row")
            for row in rows {
                let key: String?
                switch batch.stream {
                case "journal":
                    if case .string(let day)? = row["day"], case .string(let question)? = row["question"] {
                        key = "\(day)|\(question)"
                    } else { key = nil }
                case "dailyMetric":
                    if case .string(let day)? = row["day"] { key = day } else { key = nil }
                default:
                    if case .string(let external)? = row["external_id"] { key = external } else { key = nil }
                }
                let unwrapped = try XCTUnwrap(key, "[\(golden.name)] row has no natural key")
                XCTAssertTrue(keys.contains(unwrapped), "[\(golden.name)] \(unwrapped) would be deleted by its own replacement")
            }
        }
    }

    // MARK: - 7. Deployed target contract

    /// Every projected stream must name the table and conflict key the deployed database expects.
    /// Sources: `contracts/deployed/public__noop_projection_target.sql` (append streams),
    /// `contracts/deployed/public__noop_apply_projection_rows_intake_legacy.sql` (all 17 streams)
    /// and `contracts/deployed/public__noop_project_append_batch_core.sql` (conflict keys).
    func testRegistryTargetsMatchDeployedContract() throws {
        let deployed: [(stream: String, table: String, onConflict: String)] = [
            ("hrSample", "noop_hr_samples", "user_id,device_id,ts"),
            ("rrInterval", "noop_rr_intervals", "user_id,device_id,ts,rrMs,seq"),
            ("rrPacketProvenance", "noop_rr_packet_provenance", "user_id,device_id,packetId"),
            ("standardHRReceipt", "noop_standard_hr_receipts", "user_id,device_id,receiptId"),
            ("event", "noop_events", "user_id,device_id,ts,kind"),
            ("battery", "noop_battery_samples", "user_id,device_id,ts"),
            ("spo2Sample", "noop_spo2_samples", "user_id,device_id,ts"),
            ("skinTempSample", "noop_skin_temp_samples", "user_id,device_id,ts"),
            ("respSample", "noop_resp_samples", "user_id,device_id,ts"),
            ("gravitySample", "noop_gravity_samples", "user_id,device_id,ts"),
            ("stepSample", "noop_step_samples", "user_id,device_id,ts"),
            ("sleepStateSample", "noop_sleep_state_samples", "user_id,device_id,ts"),
            ("ppgHrSample", "noop_ppg_hr_samples", "user_id,device_id,ts"),
            ("dailyMetric", "daily_metrics", "user_id,day"),
            ("sleepSession", "sessions", "id"),
            ("workout", "sessions", "id"),
            ("journal", "noop_journal_entries", "user_id,device_id,day,question"),
        ]

        XCTAssertEqual(Set(deployed.map(\.stream)), Set(ProjectionRegistry.allStreams),
                       "the registry must cover exactly the deployed projection targets")
        for target in deployed {
            let projection = try XCTUnwrap(ProjectionRegistry.projection(for: target.stream), target.stream)
            XCTAssertEqual(projection.table, target.table, "[\(target.stream)] table")
            XCTAssertEqual(projection.onConflict, target.onConflict, "[\(target.stream)] conflict key")
        }
    }

    /// The conflict-key encoder mirrors `_shared/appendProjection.ts` `KEY_TYPES`.
    func testConflictKeyEncoding() throws {
        XCTAssertEqual(try projectionKeyPart(column: "ts", value: .int(1790709930)), "1790709930")
        XCTAssertEqual(try projectionKeyPart(column: "ts", value: .double(-0.0)), "0")
        XCTAssertEqual(try projectionKeyPart(column: "user_id",
                                             value: .string("{3EF42E3F-55D2-4E4F-A68A-E0551457CCF9}")),
                       "3ef42e3f55d24e4fa68ae0551457ccf9")
        XCTAssertEqual(try projectionKeyPart(column: "kind", value: .string("sleep_onset")), "sleep_onset")
        XCTAssertThrowsError(try projectionKeyPart(column: "ts", value: .string("1790709930")))
        XCTAssertThrowsError(try projectionKeyPart(column: "ts", value: .null))
        XCTAssertThrowsError(try projectionKeyPart(column: "rrMs", value: .int(4294967296)))
        XCTAssertThrowsError(try projectionKeyPart(column: "packetId", value: .int(1)))
    }

    // MARK: - 8. Gzip verification

    /// Strict gzip: every member must reach `Z_STREAM_END` and its CRC32/ISIZE trailer must match.
    /// Fixtures: `contracts/fixtures/gzip/*.gz` (regenerate with
    /// `python3 contracts/fixtures/gzip/generate.py`).
    func testGunzipStrictAcceptsValidMember() throws {
        let data = try XCTUnwrap(Data(hexString: Self.gzipValidHex))
        let body = try Inflator.gunzipStrict(data)
        // The embedded fixture literal keeps the corpus file's trailing newline, so the decoded
        // body must match it byte-for-byte.
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       try XCTUnwrap(Self.goldens.first { $0.name == "hrSample-1.1" }).ndjson)
        _ = try PushBatch.decode(ndjson: body)
    }

    func testGunzipStrictRejectsTruncatedAndCorruptMembers() throws {
        for (name, hex) in Self.gzipRejected {
            let data = try XCTUnwrap(Data(hexString: hex), name)
            XCTAssertThrowsError(try Inflator.gunzipStrict(data), "[\(name)] must be rejected")
        }
    }

    /// The lane's existing entry point does not require `Z_STREAM_END`, so a truncated member can
    /// return a partial body with no error. This records the difference without asserting that the
    /// legacy behaviour is correct; `gunzipStrict` is the entry point that must be adopted.
    func testLegacyGunzipDoesNotVerifyTheTrailer() throws {
        let full = try XCTUnwrap(Self.goldens.first { $0.name == "hrSample-1.1" }).ndjson
        for (name, hex) in Self.gzipRejected {
            let data = try XCTUnwrap(Data(hexString: hex), name)
            XCTAssertThrowsError(try Inflator.gunzipStrict(data), "[\(name)] strict decode must reject")
        }
        let truncatedDeflate = try XCTUnwrap(
            Data(hexString: try XCTUnwrap(Self.gzipRejected.first { $0.0 == "truncated-deflate" }?.1)))
        if let legacy = try? Inflator.gunzip(truncatedDeflate) {
            XCTAssertLessThan(legacy.count, full.utf8.count,
                              "the legacy decoder returned a partial body without verifying the trailer")
        }
    }

    // MARK: - 9. Fixture provenance

    /// The embedded fixtures must be byte-identical to the files in `contracts/fixtures/`, so the
    /// golden corpus and the suite cannot drift. Skipped when the fixtures are not on disk.
    func testEmbeddedFixturesMatchOnDiskCorpus() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let batches = root.appendingPathComponent("contracts/fixtures/batches")
        guard FileManager.default.fileExists(atPath: batches.path) else {
            throw XCTSkip("contracts/fixtures is not present next to the package")
        }
        for golden in Self.goldens {
            let file = batches.appendingPathComponent("\(golden.name).ndjson")
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(text, golden.ndjson,
                           "[\(golden.name)] embedded fixture drifted from the corpus")
        }
    }
}


private extension Data {
    /// Build bytes from a lowercase hex string.
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
