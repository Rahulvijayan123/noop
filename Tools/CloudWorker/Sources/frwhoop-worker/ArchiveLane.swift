import Foundation
import CZlib
import CZstd

/// Lane 4: derived-result archiving to private object storage.
///
/// `scoring_archive_jobs_v2` (created by every v2 snapshot publication):
/// claim -> renew the lease -> upload the exact payload text bytes (compression
/// none; the completion contract requires byte-identical JSON) ->
/// `complete_scoring_archive_v2` registers the derived object manifest. The
/// completion BOOLEAN is authoritative: `false` means the lease expired or the
/// job was already completed, so it is never counted as a success. A completion
/// that RAISES (mismatch/immutable conflict/invalid receipt) releases the lease
/// through `fail_scoring_archive_v2` so the job backs off (dead-letter at 12).
///
/// `physiology_archive_outbox` (created by every fenced legacy publication):
/// lease one pending row, compress the stored
/// `server_physiology_results.payload` with zstd, upload at the outbox object
/// key, then register the derived object manifest AND complete the outbox row in
/// ONE transaction. The outbox completion is fenced on the lease token this
/// worker still holds and on an unexpired lease, so worker A can never finish
/// worker B's claim; when the fence fails the whole transaction (including the
/// manifest insert) is rolled back. The registered object's identity is validated
/// against the bytes that were actually uploaded (sha256, compressed size,
/// uncompressed size, owner, bucket, format) so a pre-existing object with
/// different content can never be silently accepted.
///
/// Every value is passed as a bound parameter: no value is interpolated into SQL.
struct ArchiveLane {
    let db: PostgresClient
    let storage: B2Storage
    var leaseSeconds: Int = 300
    var snapshotRetentionDays: Int = 3650
    var outboxRetentionDays: Int = 90

    struct Stats {
        var uploaded = 0
        /// The DB refused the completion (lease expired / already completed).
        var notCompleted = 0
        /// The lease we held was no longer current: the transition was rolled back.
        var leaseLost = 0
        var failed = 0
        var lastError: String?
        var lastErrorKind: PGErrorKind?
    }
    var stats = Stats()

    mutating func drain(budget: Int) {
        var consecutiveFailures = 0
        for _ in 0..<max(1, budget) {
            do {
                try db.ensureConnected()
            } catch {
                record(error)
                return
            }
            do {
                if try archiveOneSnapshot() { consecutiveFailures = 0; continue }
                if try archiveOneOutbox() { consecutiveFailures = 0; continue }
                return
            } catch let e as PostgresClient.Error where e.kind == .connectionLost {
                record(e)
                return
            } catch {
                stats.failed += 1
                record(error)
                consecutiveFailures += 1
                if consecutiveFailures >= 8 { return }
            }
        }
    }

    private mutating func record(_ error: Error) {
        stats.lastError = String(describing: error).prefix(2000).description
        stats.lastErrorKind = (error as? PostgresClient.Error)?.kind ?? .other
    }

    // MARK: - v2 snapshot archives

    /// Returns true when one v2 snapshot archive was uploaded.
    private mutating func archiveOneSnapshot() throws -> Bool {
        let rows = try db.query(
            "select * from public.claim_scoring_archive_v2($1::integer)",
            [String(leaseSeconds)])
        guard let r = rows.first else { return false }
        let key = r["object_key"] ?? ""
        let token = r["lease_token"] ?? ""
        let payload = r["payload_text"] ?? ""
        guard !key.isEmpty, !token.isEmpty, !payload.isEmpty else { return false }

        // Renew before the upload: a 300 s lease must not expire while the object
        // is in flight, because the completion transition requires a live lease.
        _ = try db.callFunctionForJSON(
            "SELECT public.renew_scoring_archive_v2($1::uuid, $2::integer)::text",
            [token, String(leaseSeconds)])

        let bytes = Data(payload.utf8)
        let sha = sha256Hex(bytes)
        try storage.upload(objectKey: key, bytes: bytes, contentType: "application/json")
        stats.uploaded += 1

        do {
            let result = try db.callFunctionForJSON(
                "SELECT public.complete_scoring_archive_v2($1::uuid,$2::text,$3::bigint,$4::text,$5::integer)::text",
                [token, sha, String(bytes.count), storage.bucketName, String(snapshotRetentionDays)])
            if isTrue(result) { return true }
            // false = the lease expired or the job was already completed by another
            // worker. The bytes are uploaded but the job is NOT complete: report it
            // and release the lease through the bounded failure path.
            stats.notCompleted += 1
            _ = try? db.callFunctionForJSON(
                "SELECT public.fail_scoring_archive_v2($1::uuid, $2::text)::text",
                [token, "complete_returned_false"])
            return true
        } catch {
            // The completion raised (archive_snapshot_mismatch,
            // invalid_archive_receipt, immutable_archive_conflict). Release the
            // lease so the job backs off instead of staying leased for 300 s.
            _ = try? db.callFunctionForJSON(
                "SELECT public.fail_scoring_archive_v2($1::uuid, $2::text)::text",
                [token, "complete_raised:\(String(describing: error).prefix(500))"])
            throw error
        }
    }

    // MARK: - physiology archive outbox

    /// Returns true when one physiology outbox row was archived.
    private mutating func archiveOneOutbox() throws -> Bool {
        let rows = try db.query("""
            WITH claimed AS (
              SELECT id
              FROM public.physiology_archive_outbox
              WHERE status IN ('pending','retry','uploading')
                AND coalesce(next_attempt_at, '-infinity'::timestamptz) <= now()
                AND (lease_expires_at IS NULL OR lease_expires_at <= now())
              ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED
            )
            UPDATE public.physiology_archive_outbox o
              SET status='uploading', lease_token=gen_random_uuid(),
                  lease_expires_at=now()+make_interval(secs => $1::integer),
                  attempts=attempts+1, last_error=NULL
            FROM claimed WHERE o.id = claimed.id
            RETURNING o.id::text, o.lease_token::text, o.user_id::text, o.device_id::text,
                      o.period_day::text, o.algorithm_version::text, o.input_revision::text,
                      o.object_key, o.lease_expires_at::text
            """, [String(leaseSeconds)])
        guard let r = rows.first else { return false }
        let id = r["id"] ?? ""
        let token = r["lease_token"] ?? ""
        let key = r["object_key"] ?? ""
        let uid = r["user_id"] ?? ""
        let dev = r["device_id"] ?? ""
        let period = r["period_day"] ?? ""
        let version = r["algorithm_version"] ?? ""
        let revision = r["input_revision"] ?? ""
        guard !id.isEmpty, !token.isEmpty, !key.isEmpty, !uid.isEmpty, !dev.isEmpty,
              !period.isEmpty, !version.isEmpty, !revision.isEmpty else { return false }

        // Load the stored payload for this exact publication.
        let payloadRows = try db.query("""
            SELECT payload::text AS payload FROM public.server_physiology_results
            WHERE user_id=$1::uuid AND device_id=$2::uuid AND period_day=$3::date
              AND algorithm_version=$4::text AND input_revision=$5::bigint
            """, [uid, dev, period, version, revision])
        guard let payload = payloadRows.first?["payload"], !payload.isEmpty else {
            // Nothing to archive: release the lease so the row can be re-examined
            // instead of sitting leased for the whole lease window.
            try releaseOutboxLease(id: id, token: token, error: "outbox row without stored payload")
            throw WorkerError.malformed("outbox row without stored payload")
        }

        let raw = Data(payload.utf8)
        let compressed = try zstdCompress(raw)
        let wireSHA = sha256Hex(compressed)
        let contentSHA = sha256Hex(raw)

        // Extend the lease across the upload, fenced on the token we hold.
        let renewed = try db.query("""
            UPDATE public.physiology_archive_outbox
               SET lease_expires_at = now() + make_interval(secs => $3::integer)
             WHERE id=$1::bigint AND lease_token=$2::uuid AND lease_expires_at > now()
            RETURNING id::text
            """, [id, token, String(leaseSeconds)])
        guard renewed.first != nil else {
            // Another worker owns the row now. Do not upload for a claim we lost.
            stats.leaseLost += 1
            return false
        }

        try storage.upload(objectKey: key, bytes: compressed, contentType: "application/json")

        // Manifest registration + outbox completion in ONE transaction.
        try db.beginTransaction(.readCommitted)
        do {
            _ = try db.query("""
                INSERT INTO public.object_manifests
                  (user_id, device_id, object_class, object_kind, provider, bucket, object_key,
                   period_day, compressed_bytes, uncompressed_bytes, content_type, format, compression,
                   sha256, sha256_source, algorithm_version, status, retention_class, expires_at,
                   uploaded_at, verified_at, batch_id, source_id)
                VALUES ($1::uuid, $2::uuid, 'derived', 'derived_scores', 'b2', $3::text, $4::text,
                  $5::date, $6::bigint, $7::bigint, 'application/json', 'json_zstd_frwhoop_derived_v2', 'zstd',
                  $8::text, 'server_verified', $9::text, 'ready', 'derived',
                  now()+make_interval(days => $10::integer),
                  now(), now(), NULL, NULL)
                ON CONFLICT (object_key) DO NOTHING
                """, [uid, dev, storage.bucketName, key, period, String(compressed.count),
                      String(raw.count), wireSHA, version, String(outboxRetentionDays)])

            // Validate the object identity that is now registered under this key:
            // a pre-existing row with different bytes must never be accepted.
            let identity = try db.query("""
                SELECT id::text FROM public.object_manifests
                 WHERE object_key=$1::text AND user_id=$2::uuid AND device_id=$3::uuid
                   AND bucket=$4::text AND sha256=$5::text AND compressed_bytes=$6::bigint
                   AND uncompressed_bytes=$7::bigint AND status='ready'
                   AND format='json_zstd_frwhoop_derived_v2' AND compression='zstd'
                """, [key, uid, dev, storage.bucketName, wireSHA, String(compressed.count), String(raw.count)])
            guard identity.first != nil else {
                db.rollbackTransaction()
                try releaseOutboxLease(id: id, token: token,
                                       error: "immutable_archive_conflict: existing object does not match uploaded bytes")
                throw WorkerError.malformed("immutable archive conflict for \(key)")
            }

            // Fenced completion: this worker must still own an unexpired lease.
            let completed = try db.query("""
                UPDATE public.physiology_archive_outbox
                   SET status='verified', uploaded_at=now(), verified_at=now(),
                       content_sha256=$3::text, lease_token=NULL, lease_expires_at=NULL, last_error=NULL
                 WHERE id=$1::bigint AND lease_token=$2::uuid AND lease_expires_at > now()
                RETURNING id::text
                """, [id, token, contentSHA])
            guard completed.first != nil else {
                // Worker A must not be able to finish worker B's claim: roll back
                // the manifest registration together with the completion.
                db.rollbackTransaction()
                stats.leaseLost += 1
                return true
            }
            try db.commitTransaction()
            stats.uploaded += 1
            return true
        } catch {
            db.rollbackTransaction()
            throw error
        }
    }

    /// Release an outbox lease through the fenced update so the row can be retried
    /// (bounded by the outbox's own next_attempt_at policy).
    private func releaseOutboxLease(id: String, token: String, error: String) throws {
        _ = try db.query("""
            UPDATE public.physiology_archive_outbox
               SET status='retry', lease_token=NULL, lease_expires_at=NULL,
                   next_attempt_at = now() + make_interval(secs => 30), last_error=$3::text
             WHERE id=$1::bigint AND lease_token=$2::uuid AND lease_expires_at > now()
            RETURNING id::text
            """, [id, token, String(error.prefix(2000))])
    }

    private func zstdCompress(_ data: Data) throws -> Data {
        let bound = Int(CZstd.ZSTD_compressBound(data.count))
        var dst = [UInt8](repeating: 0, count: bound)
        let written: Int = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
                Int(CZstd.ZSTD_compress(d.baseAddress, d.count, src.baseAddress, src.count, 3))
            }
        }
        guard CZstd.ZSTD_isError(written) == 0, written > 0, written <= bound else {
            throw WorkerError.io("zstd compress failed")
        }
        return Data(dst[0..<written])
    }
}
