
import Foundation
import CZlib
import CZstd

/// Lane 4: derived-result archiving to private object storage.
///
/// `scoring_archive_jobs_v2` (created by every v2 snapshot publication):
/// claim -> upload the exact payload text bytes (compression none; the
/// completion contract requires byte-identical JSON) ->
/// `complete_scoring_archive_v2` registers the derived object manifest.
///
/// `physiology_archive_outbox` (created by every fenced legacy publication):
/// lease one pending row -> compress the stored
/// `server_physiology_results.payload` with zstd -> upload at the outbox
/// object key -> register the derived object manifest (the same shape the
/// historical derived archives use) -> mark the outbox row uploaded.
struct ArchiveLane {
    let db: PostgresClient
    let storage: B2Storage

    struct Stats {
        var uploaded = 0
        var failed = 0
        var lastError: String?
    }
    var stats = Stats()

    mutating func drain(budget: Int) {
        for _ in 0..<max(1, budget) {
            do {
                if try archiveOneSnapshot() { stats.uploaded += 1; continue }
                if try archiveOneOutbox() { stats.uploaded += 1; continue }
                return
            } catch {
                stats.failed += 1
                stats.lastError = String(describing: error)
                return
            }
        }
    }

    /// Returns true when one v2 snapshot archive was uploaded.
    private func archiveOneSnapshot() throws -> Bool {
        let rows = try db.query("select * from public.claim_scoring_archive_v2(300)", [])
        guard let r = rows.first else { return false }
        let key = r["object_key"] ?? ""
        let token = r["lease_token"] ?? ""
        let payload = r["payload_text"] ?? ""
        guard !key.isEmpty, !token.isEmpty, !payload.isEmpty else { return false }
        let bytes = Data(payload.utf8)
        try storage.upload(objectKey: key, bytes: bytes, contentType: "application/json")
        let sha = sha256Hex(bytes)
        _ = try db.callFunctionForJSON(
            "SELECT public.complete_scoring_archive_v2($1::uuid,$2::text,$3::bigint,$4::text,3650)::text",
            [token, sha, String(bytes.count), "FRWHOOP"])
        return true
    }

    /// Returns true when one physiology outbox row was archived.
    private func archiveOneOutbox() throws -> Bool {
        let rows = try db.query("""
            WITH claimed AS (
              SELECT id, user_id, device_id, period_day, algorithm_version, input_revision, object_key
              FROM public.physiology_archive_outbox
              WHERE status IN ('pending','retry') AND coalesce(next_attempt_at, '-infinity'::timestamptz) <= now()
                AND (lease_expires_at IS NULL OR lease_expires_at <= now())
              ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED
            )
            UPDATE public.physiology_archive_outbox o
              SET status='uploading', lease_token=gen_random_uuid(),
                  lease_expires_at=now()+interval '5 minutes', attempts=attempts+1
            FROM claimed WHERE o.id = claimed.id
            RETURNING o.id::text, o.lease_token::text, o.user_id::text, o.device_id::text,
                      o.period_day::text, o.algorithm_version::text, o.input_revision::text, o.object_key
            """, [])
        guard let r = rows.first else { return false }
        let id = r["id"] ?? ""
        let key = r["object_key"] ?? ""
        let uid = r["user_id"] ?? ""
        let dev = r["device_id"] ?? ""
        let period = r["period_day"] ?? ""
        let version = r["algorithm_version"] ?? ""
        let revision = r["input_revision"] ?? ""
        guard !id.isEmpty, !key.isEmpty, !uid.isEmpty, !dev.isEmpty,
              !period.isEmpty, !version.isEmpty, !revision.isEmpty else { return false }
        // Load the stored payload for this exact publication.
        let payloadRows = try db.query("""
            SELECT payload::text FROM public.server_physiology_results
            WHERE user_id=$1::uuid AND device_id=$2::uuid AND period_day=$3::date
              AND algorithm_version=$4::text AND input_revision=$5::bigint
            """, [uid, dev, period, version, revision])
        guard let payload = payloadRows.first?["payload"], !payload.isEmpty else {
            throw WorkerError.malformed("outbox row without stored payload")
        }
        let raw = Data(payload.utf8)
        let compressed = try zstdCompress(raw)
        let wireSHA = sha256Hex(compressed)
        let contentSHA = sha256Hex(raw)
        try storage.upload(objectKey: key, bytes: compressed, contentType: "application/json")
        // Register the derived manifest (the historical archive shape).
        _ = try db.callFunctionForJSON("""
            INSERT INTO public.object_manifests
              (user_id, device_id, object_class, object_kind, provider, bucket, object_key,
               period_day, compressed_bytes, uncompressed_bytes, content_type, format, compression,
               sha256, sha256_source, algorithm_version, status, retention_class, expires_at,
               uploaded_at, verified_at, batch_id, source_id)
            VALUES ($1::uuid, $2::uuid, 'derived', 'derived_scores', 'b2', 'FRWHOOP', $3::text,
              $4::date, $5::bigint, $6::bigint, 'application/json', 'json_zstd_frwhoop_derived_v2', 'zstd',
              $7::text, 'server_verified', $8::text, 'ready', 'derived', now()+interval '90 days',
              now(), now(), NULL, NULL)
            ON CONFLICT (object_key) DO NOTHING
            """, [uid, dev, key, String(compressed.count), String(raw.count),
                  wireSHA, version])
        // Mark the outbox row done.
        try db.exec("""
        UPDATE public.physiology_archive_outbox
        SET status='done', uploaded_at=now(), verified_at=now(), content_sha256='$1',
            lease_token=NULL, lease_expires_at=NULL, last_error=NULL
        WHERE id='$2'
        """.replacingOccurrences(of: "$1", with: contentSHA).replacingOccurrences(of: "$2", with: id))
        return true
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
