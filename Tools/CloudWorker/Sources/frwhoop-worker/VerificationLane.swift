
import Foundation

/// Lane 2: object verification debt (fallback).
///
/// The edge ingest path verifies objects synchronously and enqueues debt only
/// when that path defers. Production currently carries zero pending rows; this
/// lane keeps the worker correct if deferrals appear: it claims a lease,
/// re-checks the exact object bytes against the manifest checksums, and
/// reports success (receipt already registered) or a classified failure.
struct VerificationLane {
    let db: PostgresClient
    let storage: B2Storage

    mutating func drain(budget: Int) {
        for _ in 0..<max(1, budget) {
            do {
                guard try claimOne() else { return }
            } catch {
                return
            }
        }
    }

    /// Returns true when one item was processed.
    private func claimOne() throws -> Bool {
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
        let wire: Data
        do {
            wire = try storage.download(objectKey: objectKey)
        } catch let e as WorkerError {
            if case .objectMissing = e {
                _ = try? db.callFunctionForJSON(
                    "SELECT public.noop_finish_object_verification($1::uuid, $2::uuid, $3::text, 404, true, 0)::text",
                    [objectId, token, "object_missing"])
            }
            return true
        }
        let wireSHA = sha256Hex(wire)
        let expected = (manifest["wire_sha256"] as? String) ?? ""
        let compressedBytes = (manifest["compressed_bytes"] as? Int) ?? wire.count
        if !expected.isEmpty && wireSHA != expected || compressedBytes != wire.count {
            _ = try? db.callFunctionForJSON(
                "SELECT public.noop_finish_object_verification($1::uuid, $2::uuid, $3::text, 422, true, 0)::text",
                [objectId, token, "digest_mismatch"])
            return true
        }
        // Bytes verified. Success path needs a registered receipt; if the
        // receipt already exists this completes the debt row, otherwise leave
        // the row to the reconciler (which owns re-driving the copy flow).
        _ = try? db.callFunctionForJSON(
            "SELECT public.noop_finish_object_verification($1::uuid, $2::uuid, NULL, 503, true, 0)::text",
            [objectId, token])
        return true
    }
}
