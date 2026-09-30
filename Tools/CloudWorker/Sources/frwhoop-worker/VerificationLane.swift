import Foundation
import CZlib
import CZstd

/// Lane 2: object verification — arrival reconciliation + legacy verification debt.
///
/// The edge ingest path verifies objects synchronously and enqueues debt only
/// when that path defers. Production currently carries zero pending debt rows;
/// the dominant failure mode is "uploaded but never verified/indexed" arrivals:
/// raw, ready manifests with no `verified_indexed` durability receipt. This
/// lane owns BOTH:
///
///  1. `reconcile(budget:)` — the generic pending-object arrival reconciler.
///     It scans for uploaded-but-unverified raw objects, downloads each wire
///     object, re-verifies the exact bytes against the manifest checksums,
///     copies the exact verified bytes to the canonical `verified/` key (the DB
///     rewrites the manifest's object_key to that key), and registers the
///     receipt through `noop_commit_object_receipt`. Missing objects are
///     DEFERRED ARRIVALS (never a row failure). Byte mismatches are DIGEST
///     MISMATCH and remembered in a bounded in-memory negative cache.
///
///  2. `claimOne()` — the legacy verification-debt path (kept, defects fixed):
///     claims a lease through `noop_claim_object_verification`, re-checks the
///     exact object bytes against the manifest checksums, and settles the debt
///     through `noop_finish_object_verification` with the CORRECT arguments per
///     outcome (verified / digest mismatch / object missing / not-yet-arrived),
///     checking the returned boolean instead of ignoring it.
struct VerificationLane {
    let db: PostgresClient
    let storage: B2Storage

    struct Stats {
        var claimed = 0          // debt claims attempted
        var completed = 0        // total successes (reconciled + debt completed)
        var failed = 0           // hard failures
        var lastCompletedAt: Date?
        var lastError: String?
        // Per-outcome counters (main.swift reports these in the heartbeat).
        var reconciled = 0       // arrivals committed via noop_commit_object_receipt
        var deferred = 0         // arrivals deferred (object not in storage yet)
        var digestMismatch = 0   // arrivals/verifications whose bytes did not match
        var debtCompleted = 0    // debt rows completed (or retry-parked after verified)
        var debtFailed = 0       // debt rows whose finish call lost the lease / threw
    }
    var stats = Stats()

    init(db: PostgresClient, storage: B2Storage) {
        self.db = db
        self.storage = storage
        self.stats = Stats()
        self.negativeCache = [:]
        self.negativeCacheOrder = []
    }

    // MARK: - Negative cache

    /// Bounded in-memory negative cache of object ids that produced a digest
    /// mismatch, so the lane does not re-download them every cycle. Eviction is
    /// FIFO: when the cache exceeds `negativeCacheLimit`, the oldest inserted
    /// entry is dropped.
    static let negativeCacheLimit = 512
    private var negativeCache: [String: String] = [:]   // objectId -> reason
    private var negativeCacheOrder: [String] = []

    private mutating func rememberNegative(_ objectId: String, reason: String) {
        if negativeCache[objectId] != nil { return }
        negativeCache[objectId] = reason
        negativeCacheOrder.append(objectId)
        while negativeCacheOrder.count > Self.negativeCacheLimit {
            let oldest = negativeCacheOrder.removeFirst()
            negativeCache.removeValue(forKey: oldest)
        }
    }

    // MARK: - Entry point

    /// One bounded cycle: arrival reconciliation first, then the legacy debt
    /// path. Both are bounded by `budget`.
    mutating func drain(budget: Int) {
        reconcile(budget: max(1, budget))
        for _ in 0..<max(1, budget) {
            do {
                if try claimOne() {
                    stats.claimed += 1
                } else {
                    return
                }
            } catch {
                stats.failed += 1
                stats.lastError = String(describing: error)
                return
            }
        }
    }

    // MARK: - Arrival reconciliation

    /// Single parameterized scan for pending arrivals: uploaded-but-unverified
    /// raw objects, oldest first, bounded by the budget. Values are passed as
    /// $n parameters (never string-interpolated).
    // Cursor-parameterized scan (audit P1-6): the previous head-first scan
    // (ORDER BY created_at, no cursor) re-served the same oldest deferred
    // candidates forever while newer verifiable arrivals never progressed.
    // The cursor advances past processed rows and wraps at exhaustion.
    static func candidateSQL(afterCursor: Bool) -> String {
        let cursorClause = afterCursor ? "AND created_at > $2::timestamptz" : ""
        return """
        SELECT id::text, user_id::text, device_id::text, object_class, object_kind,
               provider, bucket, object_key, upload_object_key, period_day::text,
               compressed_bytes::text, uncompressed_bytes::text, content_type, format,
               compression, sha256, status, wire_sha256, digest_scope,
               durability_receipt::text, sample_count::text, start_at::text,
               end_at::text, created_at::text
        FROM public.object_manifests
        WHERE object_class = 'raw'
          AND status = 'ready'
          AND (durability_receipt IS NULL OR durability_receipt->>'state' IS DISTINCT FROM 'verified_indexed')
          AND coalesce(compressed_bytes, 0) > 0
          AND object_key IS NOT NULL
          AND object_kind IS NOT NULL
          \(cursorClause)
        ORDER BY created_at
        LIMIT $1::int
        """
    }
    /// created_at watermark of the last processed page (per-process cursor).
    private var reconcileCursor: String?

    mutating func reconcile(budget: Int) {
        let afterCursor = reconcileCursor != nil
        let params: [String] = afterCursor
            ? [String(budget), reconcileCursor!]
            : [String(budget)]
        let rows: [[String: String]]
        do {
            rows = try db.query(Self.candidateSQL(afterCursor: afterCursor), params)
        } catch {
            stats.failed += 1
            stats.lastError = "reconcile scan: \(error)"
            return
        }
        guard !rows.isEmpty else {
            // Page exhausted: wrap the cursor so the next cycle rescans from
            // the oldest (new arrivals + recovered deferred objects).
            reconcileCursor = nil
            return
        }
        for row in rows {
            processCandidate(row)
        }
        // Advance the cursor to this page's last created_at.
        if let last = rows.last?["created_at"], !last.isEmpty {
            reconcileCursor = last
        }
    }

    /// Classify + process one candidate row. Internal so the live verification
    /// harness (and unit tests) can drive specific rows without a scan.
    mutating func processCandidate(_ row: [String: String]) {
        let objectId = row["id"] ?? ""
        guard !objectId.isEmpty else { return }
        if negativeCache[objectId] != nil {
            // Already proven bad this process; do not re-download.
            return
        }
        do {
            let outcome = try reconcileSingle(row)
            switch outcome {
            case .reconciled:
                stats.reconciled += 1
                stats.completed += 1
                stats.lastCompletedAt = Date()
            case .deferred:
                stats.deferred += 1
            case .digestMismatch(let reason):
                stats.digestMismatch += 1
                stats.lastError = "digest mismatch \(objectId): \(reason)"
                rememberNegative(objectId, reason: reason)
            }
        } catch {
            stats.failed += 1
            stats.lastError = "reconcile \(objectId): \(error)"
        }
    }

    private enum ReconcileOutcome {
        case reconciled
        case deferred
        case digestMismatch(String)
    }

    /// Process a single candidate row end to end.
    private func reconcileSingle(_ row: [String: String]) throws -> ReconcileOutcome {
        let objectId = row["id"] ?? ""
        let userId = row["user_id"] ?? ""
        let deviceId = row["device_id"] ?? ""
        guard !objectId.isEmpty, !userId.isEmpty, !deviceId.isEmpty else {
            return .digestMismatch("row missing identity")
        }
        // Download key: upload_object_key if present, else the upload key
        // (which is object_key for a receipt-less arrival).
        let downloadKey = row["upload_object_key"]?.isEmpty == false
            ? row["upload_object_key"]!
            : (row["object_key"] ?? "")
        guard !downloadKey.isEmpty else { return .digestMismatch("missing object_key") }

        let wire: Data
        do {
            wire = try storage.download(objectKey: downloadKey)
        } catch {
            if Self.isMissingObject(error) {
                // DEFERRED ARRIVAL: the object is not in storage yet. Do not
                // write anything; count separately; not a failure of the row.
                return .deferred
            }
            throw error
        }

        let receipt = receiptDict(fromText: row["durability_receipt"] ?? "")
        let metrics: VerifiedMetrics
        do {
            metrics = try Self.verifyWireBytes(
                wire: wire,
                format: row["format"],
                compression: row["compression"],
                digestScope: row["digest_scope"],
                sha256: row["sha256"],
                wireSHA256: row["wire_sha256"],
                compressedBytes: Self.parseInt(row["compressed_bytes"]),
                uncompressedBytes: Self.parseInt(row["uncompressed_bytes"]),
                receipt: receipt)
        } catch {
            let reason = (error as? VerificationFailure)?.reason ?? String(describing: error)
            return .digestMismatch(reason)
        }

        // Determine the verified key (historical ingest shape). If the download
        // key already contains '/verified/<objectId>/', keep it.
        let verifiedKey = Self.verifiedKey(forDownloadKey: downloadKey, objectId: objectId)
        guard let verifiedKey else {
            return .digestMismatch("cannot derive verified key")
        }
        // The DB LIKE pattern must hold: %/users/<uid>/%/verified/<objectId>/%
        guard Self.verifiedKeyMatchesPattern(verifiedKey, userId: userId, objectId: objectId) else {
            return .digestMismatch("verified key fails DB pattern")
        }

        // Ensure the exact bytes exist at the verified key: try to download it;
        // if it is missing, UPLOAD the exact verified bytes just validated.
        // This copy is REQUIRED because the DB rewrites the manifest's
        // object_key to the verified key on commit.
        let contentType = row["content_type"]?.isEmpty == false ? row["content_type"]! : "application/octet-stream"
        let alreadyPresent: Bool
        do {
            _ = try storage.download(objectKey: verifiedKey)
            alreadyPresent = true
        } catch {
            if Self.isMissingObject(error) { alreadyPresent = false } else { throw error }
        }
        if !alreadyPresent {
            try storage.upload(objectKey: verifiedKey, bytes: wire, contentType: contentType)
        }

        // Commit the receipt. Values are passed as $n parameters.
        do {
            guard let receiptJSON = try db.callFunctionForJSON("""
                SELECT public.noop_commit_object_receipt(
                    $1::uuid, $2::uuid, $3::text, $4::text, $5::text, $6::bigint, $7::bigint)::text
                """, [userId, objectId, verifiedKey, metrics.wireSHA, metrics.contentSHA,
                      String(metrics.compressedBytes), String(metrics.uncompressedBytes)]) else {
                return .digestMismatch("commit returned NULL jsonb")
            }
            guard let data = receiptJSON.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (obj["state"] as? String) == "verified_indexed" else {
                return .digestMismatch("commit result state != verified_indexed")
            }
            return .reconciled
        } catch let e as PostgresClient.Error {
            let sqlstate = e.sqlstate ?? "?"
            if sqlstate == "42501" || sqlstate == "23514" {
                // Classified failure: log SQLSTATE + message, never success.
                return .digestMismatch("commit rejected sqlstate=\(sqlstate): \(e.message)")
            }
            throw e
        }
    }

    // MARK: - Legacy debt path (defects fixed)

    /// Returns true when one debt item was claimed and settled.
    private mutating func claimOne() throws -> Bool {
        guard let claimJSON = try db.callFunctionForJSON(
            "SELECT public.noop_claim_object_verification()::text", []) else {
            return false
        }
        guard let claimData = claimJSON.data(using: .utf8),
              let claim = (try? JSONSerialization.jsonObject(with: claimData)) as? [String: Any],
              let objectId = claim["objectId"] as? String,
              let token = claim["token"] as? String,
              let manifest = claim["manifest"] as? [String: Any] else {
            return false
        }
        guard let objectKey = manifest["object_key"] as? String else {
            return false
        }
        let startedAt = Date()
        let wire: Data
        do {
            wire = try storage.download(objectKey: objectKey)
        } catch {
            if Self.isMissingObject(error) {
                // Object missing / not-yet-arrived: finish with the correct
                // arguments (failure_code='object_missing', 404, retryable) and
                // CHECK the result instead of ignoring it. The object may still
                // arrive later, so this is a DEFERRAL, not a row failure.
                let settled = try settleDebt(objectId: objectId, token: token,
                                             failureCode: "object_missing",
                                             failureStatus: 404, retryable: true,
                                             verificationMs: 0)
                if settled { stats.deferred += 1 }
                else { stats.debtFailed += 1; stats.failed += 1 }
                return true
            }
            throw error
        }
        let verificationMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        let expectedWire = (manifest["wire_sha256"] as? String) ?? ""
        let compressedBytes = (manifest["compressed_bytes"] as? NSNumber)?.intValue
            ?? Int(manifest["compressed_bytes"] as? String ?? "") ?? wire.count

        let format = manifest["format"] as? String
        let compression = manifest["compression"] as? String
        let scope = Self.effectiveDigestScope(format: format, digestScope: manifest["digest_scope"] as? String)
        let wireSHA = sha256Hex(wire)

        var mismatchReason: String?
        // Wire digest for wire scope.
        if scope == "wire" {
            let expected = expectedWire.isEmpty ? ((manifest["sha256"] as? String) ?? "") : expectedWire
            if !expected.isEmpty && wireSHA != expected {
                mismatchReason = "wire sha mismatch"
            }
        } else if !expectedWire.isEmpty && wireSHA != expectedWire {
            mismatchReason = "wire sha mismatch"
        }
        // Wire byte count.
        if mismatchReason == nil, compressedBytes != wire.count {
            mismatchReason = "compressed size mismatch"
        }
        // Content digest/count for gzip + decoded scope.
        if mismatchReason == nil, Self.isGzip(format: format, compression: compression) {
            if let body = try? Inflator.gunzip(wire) {
                let contentSHA = sha256Hex(body)
                let expectedContent = (manifest["durability_receipt"] as? [String: Any])?["contentSha256"] as? String
                    ?? (scope == "decoded" ? ((manifest["sha256"] as? String) ?? "") : "")
                if !expectedContent.isEmpty && contentSHA != expectedContent {
                    mismatchReason = "content sha mismatch"
                }
                if mismatchReason == nil, let ub = (manifest["uncompressed_bytes"] as? NSNumber)?.intValue, ub != body.count {
                    mismatchReason = "decoded size mismatch"
                }
            } else {
                mismatchReason = "invalid compressed object"
            }
        }

        if let mismatchReason {
            // Digest mismatch: deterministic, settle as a non-retryable failure.
            let settled = try settleDebt(objectId: objectId, token: token,
                                         failureCode: "digest_mismatch",
                                         failureStatus: 422, retryable: false,
                                         verificationMs: verificationMs)
            stats.digestMismatch += 1
            stats.debtFailed += 1
            stats.failed += 1
            stats.lastError = "debt digest mismatch \(objectId): \(mismatchReason)"
            return true
        }

        // Bytes verified. If a receipt now exists the finish call completes the
        // debt; otherwise leave the row to the reconciler by parking it in a
        // retryable state. Correct arguments per the live finish body: NULL
        // failure_code means "not a verification failure".
        let settled = try settleDebt(objectId: objectId, token: token,
                                     failureCode: nil, failureStatus: 503, retryable: true,
                                     verificationMs: verificationMs)
        if settled {
            stats.debtCompleted += 1
            stats.completed += 1
            stats.lastCompletedAt = Date()
        } else {
            stats.debtFailed += 1
            stats.failed += 1
        }
        return true
    }

    /// Drive noop_finish_object_verification with explicit arguments and CHECK
    /// the returned boolean. Live body (pg_get_functiondef):
    ///   RETURNS boolean; returns false when the debt row is missing / the lease
    ///   token no longer matches / the row is not leased (or is complete). When a
    ///   receipt now exists it marks the row complete; otherwise it records the
    ///   failure with the given code/status/retryable and returns true.
    private func settleDebt(objectId: String, token: String,
                            failureCode: String?,
                            failureStatus: Int,
                            retryable: Bool,
                            verificationMs: Int) throws -> Bool {
        var sql = "SELECT public.noop_finish_object_verification($1::uuid, $2::uuid"
        var params: [String] = [objectId, token]
        if let failureCode {
            sql += ", $3::text, $4::integer, $5::boolean, $6::integer)::text"
            params.append(contentsOf: [failureCode, String(failureStatus), retryable ? "true" : "false", String(verificationMs)])
        } else {
            sql += ", NULL, $3::integer, $4::boolean, $5::integer)::text"
            params.append(contentsOf: [String(failureStatus), retryable ? "true" : "false", String(verificationMs)])
        }
        guard let result = try db.callFunctionForJSON(sql, params) else { return false }
        return result == "true"
    }

    // MARK: - Shared helpers

    /// Detect a missing object robustly. B2Storage.download currently throws its
    /// OWN error type for a 404 (`B2Storage.Error(message: "object_missing")`),
    /// so the old `catch let e as WorkerError { if case .objectMissing }`
    /// branches were dead code. The parent is fixing B2Storage to throw
    /// WorkerError.objectMissing; until then we treat BOTH shapes as missing.
    static func isMissingObject(_ error: Error) -> Bool {
        if let we = error as? WorkerError, case .objectMissing = we { return true }
        if let be = error as? B2Storage.Error, be.message == "object_missing" { return true }
        return false
    }

    private static func parseInt(_ s: String?) -> Int? {
        guard let s, !s.isEmpty else { return nil }
        return Int(s)
    }

    private func receiptDict(fromText text: String) -> [String: Any]? {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }


    /// Bounded zstd decompression for decoded-scope zstd rows (the decoded
    /// digest is authoritative there, so we must decode to verify the content
    /// sha). Mirrors Inflator's output cap. Uses CZstd; no existing helper.
    static func zstdDecompress(_ data: Data) throws -> Data {
        let bound = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
            Int(CZstd.ZSTD_decompressBound(ptr.baseAddress, ptr.count))
        }
        guard bound > 0, bound <= Inflator.maxOutputBytes else {
            throw WorkerError.io("zstd output exceeds cap")
        }
        var dst = [UInt8](repeating: 0, count: bound)
        let written: Int = dst.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (inp: UnsafeRawBufferPointer) -> Int in
                Int(CZstd.ZSTD_decompress(out.baseAddress, out.count, inp.baseAddress, inp.count))
            }
        }
        guard CZstd.ZSTD_isError(written) == 0, written > 0, written <= bound else {
            throw WorkerError.io("zstd decompress failed")
        }
        return Data(dst[0..<written])
    }

    // MARK: - Pure logic (unit-tested, no DB/B2)

    /// The effective digest scope, mirroring the commit RPC:
    /// coalesce(digest_scope, case when format like 'ndjson%' then 'wire' else 'decoded' end).
    static func effectiveDigestScope(format: String?, digestScope: String?) -> String {
        if let ds = digestScope, !ds.isEmpty { return ds }
        return (format?.hasPrefix("ndjson") ?? false) ? "wire" : "decoded"
    }

    /// format LIKE '%gzip%' OR compression='gzip'.
    static func isGzip(format: String?, compression: String?) -> Bool {
        (format?.localizedCaseInsensitiveContains("gzip") ?? false) || compression == "gzip"
    }

    /// format LIKE '%zstd%' OR compression='zstd'.
    static func isZstd(format: String?, compression: String?) -> Bool {
        (format?.localizedCaseInsensitiveContains("zstd") ?? false) || compression == "zstd"
    }

    struct VerifiedMetrics {
        let wireSHA: String
        let contentSHA: String
        let compressedBytes: Int
        let uncompressedBytes: Int
    }

    struct VerificationFailure: Error {
        let reason: String
    }

    /// Verify the exact bytes against the manifest:
    ///  (a) sha256(wire) == coalesce(wire_sha256, sha256 when effective scope is 'wire');
    ///  (b) wire byte count == manifest.compressed_bytes;
    ///  (c) when gzip, gunzip (Inflator.gunzip) and compute sha256 + byte count
    ///      of the UNCOMPRESSED body; require the uncompressed count to equal
    ///      manifest.uncompressed_bytes when that is not null;
    ///  (d) when a durability_receipt exists, its wireSha256/contentSha256/
    ///      compressedBytes/uncompressedBytes are authoritative and must equal
    ///      what was measured.
    /// Throws VerificationFailure on any mismatch.
    static func verifyWireBytes(
        wire: Data,
        format: String?,
        compression: String?,
        digestScope: String?,
        sha256: String?,
        wireSHA256: String?,
        compressedBytes: Int?,
        uncompressedBytes: Int?,
        receipt: [String: Any]?
    ) throws -> VerifiedMetrics {
        let scope = effectiveDigestScope(format: format, digestScope: digestScope)
        let wireSHA = sha256Hex(wire)
        let wireCount = wire.count

        // (b) wire byte count must equal manifest.compressed_bytes.
        if let cb = compressedBytes, cb != wireCount {
            throw VerificationFailure(reason: "compressed_bytes \(wireCount) != manifest \(cb)")
        }

        // (a) wire digest: expected = coalesce(wire_sha256, sha256) for wire scope.
        //     A receipt's wireSha256 is authoritative when present.
        let expectedWire: String?
        if scope == "wire" {
            let a = (wireSHA256 ?? "").isEmpty ? nil : wireSHA256
            let b = (sha256 ?? "").isEmpty ? nil : sha256
            expectedWire = a ?? b
        } else {
            // Decoded scope: sha256 is the DECODED digest, not a wire digest.
            expectedWire = (wireSHA256 ?? "").isEmpty ? nil : wireSHA256
        }
        if let receiptWire = receipt?["wireSha256"] as? String, !receiptWire.isEmpty,
           (expectedWire == nil || receiptWire.lowercased() != expectedWire!.lowercased()) {
            // Receipt's wire sha is authoritative and must match the bytes.
            if receiptWire.lowercased() != wireSHA.lowercased() {
                throw VerificationFailure(reason: "wire sha mismatch (receipt authoritative)")
            }
        }
        if let expectedWire, expectedWire.lowercased() != wireSHA.lowercased() {
            throw VerificationFailure(reason: "wire sha mismatch")
        }
        // A wire-scope row with NO recorded digest (manifest sha256 and
        // wire_sha256 both empty, no receipt) can never be committed: the RPC
        // requires lower(manifest.sha256) == p_wire_sha256, i.e. an empty
        // manifest digest can never match a 64-hex wire digest. Reject early so
        // we do not upload a copy for a guaranteed-failed commit.
        if scope == "wire", expectedWire == nil,
           (receipt?["wireSha256"] as? String)?.isEmpty != false {
            throw VerificationFailure(reason: "no expected wire digest recorded")
        }

        // (c) content body + count. Gzip decodes via Inflator.gunzip (shared
        // helper, do not re-implement). Zstd rows (decoded scope) must also be
        // decoded because their content digest is the manifest sha256.
        let body: Data
        if isGzip(format: format, compression: compression) {
            do { body = try Inflator.gunzip(wire) }
            catch { throw VerificationFailure(reason: "gunzip failed: \(error)") }
        } else if isZstd(format: format, compression: compression) {
            do { body = try zstdDecompress(wire) }
            catch { throw VerificationFailure(reason: "zstd decompress failed: \(error)") }
        } else {
            body = wire
        }
        let contentSHA = sha256Hex(body)
        let contentCount = body.count
        if let ub = uncompressedBytes, ub != contentCount {
            throw VerificationFailure(reason: "uncompressed_bytes \(contentCount) != manifest \(ub)")
        }

        // Decoded scope: manifest.sha256 is the DECODED digest; it must match.
        // A receipt's contentSha256 is authoritative when present.
        let expectedContent: String?
        if scope == "decoded" {
            expectedContent = (sha256 ?? "").isEmpty ? nil : sha256
        } else {
            expectedContent = nil
        }
        if let receiptContent = receipt?["contentSha256"] as? String, !receiptContent.isEmpty,
           receiptContent.lowercased() != contentSHA.lowercased() {
            throw VerificationFailure(reason: "content sha mismatch (receipt authoritative)")
        }
        if let expectedContent, expectedContent.lowercased() != contentSHA.lowercased() {
            throw VerificationFailure(reason: "content sha mismatch (decoded scope)")
        }
        if scope == "decoded", expectedContent == nil,
           (receipt?["contentSha256"] as? String)?.isEmpty != false {
            throw VerificationFailure(reason: "no expected content digest recorded")
        }

        // (d) an existing receipt is authoritative.
        if let receipt {
            if let rw = receipt["wireSha256"] as? String, !rw.isEmpty, rw.lowercased() != wireSHA.lowercased() {
                throw VerificationFailure(reason: "receipt wireSha256 mismatch")
            }
            if let rc = receipt["contentSha256"] as? String, !rc.isEmpty, rc.lowercased() != contentSHA.lowercased() {
                throw VerificationFailure(reason: "receipt contentSha256 mismatch")
            }
            if let rb = receipt["compressedBytes"] as? Int, rb != wireCount {
                throw VerificationFailure(reason: "receipt compressedBytes mismatch")
            }
            if let ru = receipt["uncompressedBytes"] as? Int, ru != contentCount {
                throw VerificationFailure(reason: "receipt uncompressedBytes mismatch")
            }
        }

        return VerifiedMetrics(wireSHA: wireSHA, contentSHA: contentSHA,
                               compressedBytes: wireCount, uncompressedBytes: contentCount)
    }

    /// Derive the verified key the way the historical ingest did:
    /// `<dir>/verified/<objectId>/<newUUID>/<filename>`. If the download key
    /// already contains '/verified/<objectId>/', keep it as-is.
    static func verifiedKey(forDownloadKey key: String, objectId: String) -> String? {
        if key.contains("/verified/\(objectId)/") { return key }
        guard let slash = key.lastIndex(of: "/") else { return nil }
        let dir = String(key[key.startIndex..<slash])
        let filename = String(key[key.index(after: slash)...])
        guard !dir.isEmpty, !filename.isEmpty else { return nil }
        let newUUID = UUID().uuidString.lowercased()
        return "\(dir)/verified/\(objectId)/\(newUUID)/\(filename)"
    }

    /// The commit RPC requires p_verified_key to satisfy
    /// `%/users/<uid>/%/verified/<objectId>/%` (LIKE, so % matches any run).
    static func verifiedKeyMatchesPattern(_ key: String, userId: String, objectId: String) -> Bool {
        // Emulate: key LIKE '%/users/<uid>/%/verified/<objectId>/%'
        guard let usersRange = key.range(of: "/users/\(userId)/") else { return false }
        let afterUsers = key[usersRange.upperBound...]
        return afterUsers.range(of: "/verified/\(objectId)/") != nil
    }
}
