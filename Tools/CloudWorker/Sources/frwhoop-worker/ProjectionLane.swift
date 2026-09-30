import Foundation

/// Lane 1: raw-object projection debt.
///
/// Cycle: `noop_claim_projection_debt()` -> manifest + lease; download the
/// verified object from private storage; verify the wire checksum; decode the
/// gzip NDJSON push batch; map records to projection rows; commit atomically
/// through `noop_commit_push_projection` (applies rows, saves the phone ACK,
/// clears the WAL, completes the debt).
///
/// Failure accounting (F8): the lane distinguishes outcomes that a retry cannot
/// fix from ones it can.
///   * A non-projectable object kind/format is DETERMINISTIC. The deployed
///     `noop_fail_projection_debt` only backs the row off (failures capped at 16,
///     `not_before` up to one hour) and has no dead-letter state, so the previous
///     "throw retryable" path re-claimed the same rows forever: the live worker
///     logged `projection last error: retryable("non-projectable kind/format
///     physiology/ndjson_gzip_v3")` with `projection.failed=513` and never made
///     progress. The lane now records the row's bounded failure once, counts it as
///     `skipped` (not as a lane error), and moves on to the next claimable item.
///   * A missing object is DEFERRED: the upload has not arrived yet, so the debt
///     must not burn a retry. (`B2Storage` now throws `WorkerError.objectMissing`,
///     which makes this branch reachable; it used to throw its own error type, so
///     the branch was dead code.)
///   * A digest mismatch or a rejected commit is a real failure and is recorded
///     through the same bounded fail path.
struct ProjectionLane {
    let db: PostgresClient
    let storage: B2Storage

    struct Stats {
        var claimed = 0
        var completed = 0
        var failed = 0
        /// Rows the worker cannot project by contract (archive-only kinds).
        var skipped = 0
        /// Rows whose object has not arrived in storage yet.
        var deferred = 0
        var lastCompletedAt: Date?
        var lastError: String?
        var lastErrorKind: PGErrorKind?
    }
    var stats = Stats()

    private enum Outcome {
        case empty
        case projected
        case skipped
        case deferred
    }

    mutating func drain(budget: Int) {
        var consecutiveFailures = 0
        for _ in 0..<max(1, budget) {
            let outcome: Outcome
            do {
                outcome = try claimOne()
            } catch let e as PostgresClient.Error where e.kind == .connectionLost {
                record(e)
                return
            } catch {
                stats.failed += 1
                record(error)
                consecutiveFailures += 1
                if consecutiveFailures >= 8 { return }
                continue
            }
            switch outcome {
            case .empty:
                return
            case .projected:
                stats.claimed += 1
                stats.completed += 1
                stats.lastCompletedAt = Date()
                consecutiveFailures = 0
            case .skipped:
                stats.claimed += 1
                stats.skipped += 1
                consecutiveFailures = 0
            case .deferred:
                stats.claimed += 1
                stats.deferred += 1
                consecutiveFailures = 0
            }
        }
    }

    private mutating func record(_ error: Error) {
        stats.lastError = String(describing: error).prefix(2000).description
        stats.lastErrorKind = (error as? PostgresClient.Error)?.kind ?? .other
    }

    /// Object kinds the receiving registry can project. Research archive kinds
    /// (physiology, frames, imu_raw, events, ...) and non-NDJSON formats are
    /// archive-only: they carry no projectable batch.
    private static let projectableKinds: Set<String> = [
        "hrSample", "rrInterval", "event", "battery", "spo2Sample",
        "skinTempSample", "respSample", "gravitySample", "stepSample",
        "sleepStateSample", "ppgHrSample", "standardHRReceipt",
        "rrPacketProvenance", "dailyMetric", "journal", "sleepSession",
        "workout",
    ]

    private mutating func claimOne() throws -> Outcome {
        // 1. Claim (service-role claim; 2-minute lease).
        guard let claimJSON = try db.callFunctionForJSON(
            "SELECT public.noop_claim_projection_debt()::text", []) else {
            return .empty
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
            // Without a verified receipt the object is not projectable yet. The
            // claim function filters on that state, so this is a real anomaly:
            // record the bounded failure and release the lease.
            try? failDebt(objectId, leaseToken)
            throw WorkerError.malformed("projection claim without verified receipt")
        }
        guard let receiptKey = receipt["objectKey"] as? String else {
            try? failDebt(objectId, leaseToken)
            throw WorkerError.malformed("projection claim receipt without objectKey")
        }

        // 2. Only the push-protocol streams carry a projectable batch. Check this
        //    BEFORE downloading: a deterministic kind/format mismatch must not cost
        //    a download or loop forever.
        guard let kind = manifest["object_kind"] as? String,
              Self.projectableKinds.contains(kind),
              format.hasPrefix("ndjson") else {
            // Bounded failure for the DB's own backoff policy, then skip: this row
            // is deterministic, so it is not a lane error and must not stop the
            // lane from making progress on other rows.
            try? failDebt(objectId, leaseToken)
            stats.lastError = "non-projectable kind/format \(manifest["object_kind"] ?? "?")/\(format)"
            stats.lastErrorKind = .deterministic
            return .skipped
        }

        // 3. Download + wire checksum.
        let wire: Data
        do {
            wire = try storage.download(objectKey: objectKey)
        } catch let e as WorkerError {
            if case .objectMissing = e {
                // Expected-object deferral: leave the debt for the reconciler; do
                // not burn retries on a missing upload.
                stats.lastError = "object missing (deferred)"
                return .deferred
            }
            throw e
        } catch let e as B2Storage.Error where e.message == "object_missing" {
            stats.lastError = "object missing (deferred)"
            return .deferred
        }
        let wireSHA = sha256Hex(wire)
        guard let expectedWire = manifest["wire_sha256"] as? String, !expectedWire.isEmpty,
              wireSHA == expectedWire else {
            try? failDebt(objectId, leaseToken)
            throw WorkerError.malformed("wire checksum mismatch for \(objectKey)")
        }

        let body = try Inflator.gunzip(wire)

        // 4. Integrity: the decoded body must match the verified content sha.
        let computedBodySHA = sha256Hex(body)
        guard computedBodySHA == contentSha else {
            try? failDebt(objectId, leaseToken)
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
            try? failDebt(objectId, leaseToken)
            throw error
        }
        return .projected
    }

    /// Record the bounded failure through the deployed RPC so the row backs off
    /// (failures capped at 16, `not_before` up to one hour).
    private func failDebt(_ objectId: String, _ leaseToken: String) throws {
        _ = try db.callFunctionForJSON(
            "SELECT public.noop_fail_projection_debt($1::uuid, $2::uuid)::text",
            [objectId, leaseToken])
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
