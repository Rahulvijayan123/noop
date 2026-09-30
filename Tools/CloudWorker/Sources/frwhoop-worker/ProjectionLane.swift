
import Foundation

/// Lane 1: raw-object projection debt.
///
/// Cycle: `noop_claim_projection_debt()` -> manifest + lease; download the
/// verified object from private storage; verify the wire checksum; decode the
/// gzip NDJSON push batch; map records to projection rows; commit atomically
/// through `noop_commit_push_projection` (applies rows, saves the phone ACK,
/// clears the WAL, completes the debt).
struct ProjectionLane {
    let db: PostgresClient
    let storage: B2Storage

    struct Stats {
        var claimed = 0
        var completed = 0
        var failed = 0
        var lastCompletedAt: Date?
        var lastError: String?
    }
    var stats = Stats()

    mutating func drain(budget: Int) {
        var consecutiveFailures = 0
        for _ in 0..<max(1, budget) {
            do {
                if try claimOne() {
                    stats.claimed += 1
                    stats.completed += 1
                    stats.lastCompletedAt = Date()
                    consecutiveFailures = 0
                } else {
                    return // nothing claimable
                }
            } catch let e as WorkerError {
                if case .objectMissing = e {
                    // Expected-object deferral: leave the debt for the
                    // reconciler; do not burn retries on a missing upload.
                    stats.lastError = "object missing (deferred)"
                    return
                }
                stats.failed += 1
                stats.lastError = String(describing: e)
                consecutiveFailures += 1
                if consecutiveFailures >= 8 { return }
            } catch {
                stats.failed += 1
                stats.lastError = String(describing: error)
                consecutiveFailures += 1
                if consecutiveFailures >= 8 { return }
            }
        }
    }

    /// Returns true when one debt item was claimed and committed.
    private func claimOne() throws -> Bool {
        // 1. Claim (service-role claim; 2-minute lease).
        guard let claimJSON = try db.callFunctionForJSON(
            "SELECT public.noop_claim_projection_debt()::text", []) else {
            return false
        }
        guard let claimData = claimJSON.data(using: .utf8),
              let claim = (try? JSONSerialization.jsonObject(with: claimData)) as? [String: Any],
              let manifest = claim["manifest"] as? [String: Any],
              let leaseToken = claim["leaseToken"] as? String else {
            throw WorkerError.malformed("projection claim response malformed")
        }
        guard let objectId = manifest["id"] as? String,
              let objectKey = manifest["object_key"] as? String,
              let userId = manifest["user_id"] as? String,
              let deviceId = manifest["device_id"] as? String else {
            throw WorkerError.malformed("projection claim manifest missing identity")
        }
        guard let format = manifest["format"] as? String else {
            throw WorkerError.malformed("projection manifest missing format")
        }
        // The commit contract requires the receipt's contentSha256 (sha256 of
        // the UNCOMPRESSED NDJSON) as p_body_sha256.
        guard let receipt = manifest["durability_receipt"] as? [String: Any],
              let contentSha = receipt["contentSha256"] as? String else {
            // Without a verified receipt the object is not projectable yet.
            throw WorkerError.retryable("projection claim without verified receipt")
        }
        guard let receiptKey = receipt["objectKey"] as? String else {
            throw WorkerError.retryable("projection claim receipt without objectKey")
        }

        // 2. Download + wire checksum.
        let wire = try storage.download(objectKey: objectKey)
        let wireSHA = sha256Hex(wire)
        guard let expectedWire = manifest["wire_sha256"] as? String, !expectedWire.isEmpty,
              wireSHA == expectedWire else {
            _ = try? db.callFunctionForJSON(
                "SELECT public.noop_fail_projection_debt($1::uuid, $2::uuid)::text",
                [objectId, leaseToken])
            throw WorkerError.malformed("wire checksum mismatch for \(objectKey)")
        }

        // 3. Only the push-protocol streams carry a projectable batch:
        // the receiving registries map exactly these kinds to target tables.
        // Research archive kinds (physiology, frames, imu_raw, events, ...)
        // and non-NDJSON formats are archive-only: record the bounded
        // failure and let the DB's backoff policy hold the row.
        let projectableKinds: Set<String> = [
            "hrSample", "rrInterval", "event", "battery", "spo2Sample",
            "skinTempSample", "respSample", "gravitySample", "stepSample",
            "sleepStateSample", "ppgHrSample", "standardHRReceipt",
            "rrPacketProvenance", "dailyMetric", "journal", "sleepSession",
            "workout",
        ]
        guard let kind = manifest["object_kind"] as? String, projectableKinds.contains(kind),
              format.hasPrefix("ndjson") else {
            _ = try? db.callFunctionForJSON(
                "SELECT public.noop_fail_projection_debt($1::uuid, $2::uuid)::text",
                [objectId, leaseToken])
            throw WorkerError.retryable("non-projectable kind/format \(manifest["object_kind"] ?? "?")/\(format)")
        }
        let body = try Inflator.gunzip(wire)

        // 4. Integrity: the decoded body must match the verified content sha.
        let computedBodySHA = sha256Hex(body)
        guard computedBodySHA == contentSha else {
            _ = try? db.callFunctionForJSON(
                "SELECT public.noop_fail_projection_debt($1::uuid, $2::uuid)::text",
                [objectId, leaseToken])
            throw WorkerError.malformed("content checksum mismatch for \(objectKey)")
        }

        // 4b. Server re-verification: objects whose receipt was published with
        // a client-claimed digest must be re-registered server-side before the
        // projection commit accepts them. The bytes were just re-verified
        // above, so this re-publishes the immutable receipt with
        // sha256_source=server_verified and a matching signal window.
        let shaSource = (manifest["sha256_source"] as? String) ?? ""
        if shaSource != "server_verified" {
            let wireShaFromReceipt = receipt["wireSha256"] as? String ?? expectedWire
            let ub = (receipt["uncompressedBytes"] as? Int) ?? body.count
            _ = try db.callFunctionForJSON("""
                SELECT public.noop_commit_object_receipt(
                    $1::uuid, $2::uuid, $3::text, $4::text, $5::text, $6::bigint, $7::bigint)::text
                """, [userId, objectId, receiptKey, wireShaFromReceipt, contentSha,
                      String(wire.count), String(ub)])
        }

        let batch = try PushBatch.decode(ndjson: body)
        let rows = try batch.projectionRows(userId: userId, deviceId: deviceId)
        let keepKeys = try batch.keepKeys()

        // 5. Commit (service-role function; verifies receipt, applies rows,
        //    saves the ACK, clears WAL, completes debt). A commit rejection
        //    (e.g. an unprojectable replay manifest) is recorded through the
        //    bounded fail path so the DB's own backoff policy spaces retries.
        let headerData = try JSONSerialization.data(withJSONObject: batch.headerObject)
        let rowsData = try JSONSerialization.data(withJSONObject: rows)
        let keysData = try JSONSerialization.data(withJSONObject: keepKeys)
        do {
            _ = try db.callFunctionForJSON("""
                SELECT public.noop_commit_push_projection(
                    $1::uuid, $2::text, $3::jsonb, $4::jsonb, $5::jsonb, $6::uuid)::text
                """, [objectId, contentSha,
                      String(data: headerData, encoding: .utf8)!,
                      String(data: rowsData, encoding: .utf8)!,
                      String(data: keysData, encoding: .utf8)!,
                      leaseToken])
        } catch {
            _ = try? db.callFunctionForJSON(
                "SELECT public.noop_fail_projection_debt($1::uuid, $2::uuid)::text",
                [objectId, leaseToken])
            throw error
        }
        return true
    }
}

import CCrypto

func sha256Hex(_ data: Data) -> String {
    var digest = [UInt8](repeating: 0, count: 32)
    data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
        _ = SHA256(ptr.baseAddress, ptr.count, &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
}
