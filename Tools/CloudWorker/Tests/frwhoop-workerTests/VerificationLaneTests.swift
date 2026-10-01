import XCTest
@testable import frwhoop_worker

/// Pure-logic tests for VerificationLane: verified-key derivation, digest-scope
/// resolution, the gzip-vs-not decision, and deferred/digest-mismatch/success
/// classification. No DB, no B2.
final class VerificationLaneTests: XCTestCase {

    // MARK: - Verified key derivation

    func testVerifiedKeyHistoricalShapeSatisfiesDBPattern() {
        // Historical upload key (v3 core event push).
        let uploadKey = "v3/core/users/9f33375b-e029-480f-9ebb-a99e5ff22ac9/devices/5512f20c-4b30-5d63-a943-48e3e2aa5f79/event/2026/09/20/07/f8b02b1b-34c1-4aa5-be84-8079a3195f19.ndjson.gz"
        let objectId = "f8b02b1b-34c1-4aa5-be84-8079a3195f19"
        let userId = "9f33375b-e029-480f-9ebb-a99e5ff22ac9"
        guard let key = VerificationLane.verifiedKey(forDownloadKey: uploadKey, objectId: objectId) else {
            return XCTFail("verifiedKey returned nil")
        }
        XCTAssertTrue(key.contains("/verified/\(objectId)/"))
        XCTAssertTrue(key.hasPrefix("v3/core/users/\(userId)/"))
        // Historical shape: <dir>/verified/<objectId>/<newUUID>/<filename>
        XCTAssertTrue(key.hasSuffix("/\(objectId).ndjson.gz"))
        XCTAssertTrue(VerificationLane.verifiedKeyMatchesPattern(key, userId: userId, objectId: objectId))
    }

    func testVerifiedKeyKeepsExistingVerifiedKey() {
        let already = "v3/core/users/u1/devices/d1/hrSample/2026/09/27/00/verified/abc/def/abc.ndjson.gz"
        let key = VerificationLane.verifiedKey(forDownloadKey: already, objectId: "abc")
        XCTAssertEqual(key, already)
    }

    func testVerifiedKeyRejectsPathWithoutUsersSegment() {
        // A download key with no /users/<uid>/ segment cannot satisfy the DB
        // LIKE pattern; derivation still produces a key, but the pattern check
        // must reject it (the commit RPC would raise).
        let key = "bucket/raw/2026/09/01/00/x.ndjson.gz"
        guard let derived = VerificationLane.verifiedKey(forDownloadKey: key, objectId: "oid") else {
            return XCTFail("derivation should succeed")
        }
        XCTAssertFalse(VerificationLane.verifiedKeyMatchesPattern(derived, userId: "u1", objectId: "oid"))
    }

    // MARK: - Digest scope resolution (real formats)

    func testDigestScopeResolutionRealFormats() {
        // DB rule: coalesce(digest_scope, format like 'ndjson%' ? 'wire' : 'decoded')
        XCTAssertEqual(VerificationLane.effectiveDigestScope(format: "ndjson_gzip_noop_push_v1", digestScope: nil), "wire")
        XCTAssertEqual(VerificationLane.effectiveDigestScope(format: "protobuf_zstd_noop_push_v1", digestScope: nil), "decoded")
        XCTAssertEqual(VerificationLane.effectiveDigestScope(format: "bin_gzip_noop_push_v1", digestScope: nil), "decoded")
        XCTAssertEqual(VerificationLane.effectiveDigestScope(format: "ndjson_gzip_frames_v1", digestScope: nil), "wire")
        // An explicit digest_scope wins.
        XCTAssertEqual(VerificationLane.effectiveDigestScope(format: "ndjson_gzip_noop_push_v1", digestScope: "decoded"), "decoded")
        XCTAssertEqual(VerificationLane.effectiveDigestScope(format: nil, digestScope: "wire"), "wire")
    }

    // MARK: - Gzip vs not decision

    func testGzipDecision() {
        XCTAssertTrue(VerificationLane.isGzip(format: "ndjson_gzip_noop_push_v1", compression: "gzip"))
        XCTAssertTrue(VerificationLane.isGzip(format: "ndjson_gzip_frames_v1", compression: "gzip"))
        XCTAssertTrue(VerificationLane.isGzip(format: "bin_gzip_noop_push_v1", compression: "gzip"))
        XCTAssertTrue(VerificationLane.isGzip(format: "ndjson_gzip_v1", compression: "gzip"))
        XCTAssertFalse(VerificationLane.isGzip(format: "protobuf_zstd_noop_push_v1", compression: "zstd"))
        XCTAssertTrue(VerificationLane.isGzip(format: nil, compression: "gzip"))
        XCTAssertFalse(VerificationLane.isGzip(format: nil, compression: "zstd"))
        XCTAssertFalse(VerificationLane.isGzip(format: "protobuf_zstd_noop_push_v1", compression: nil))
    }

    // MARK: - Classification: success / deferred / digest mismatch

    func testVerifyWireScopeGzipSuccess() throws {
        // Build a valid gzip of "frwhoop" (STORE block, like PushBatchTests).
        let payload = Data("frwhoop-test-payload\n".utf8)
        let gz = hexData("1f8b08000000000002ff4b2b2acfc8cf2fd02d492d2ed12d48acccc94f4ce102002dfd727615000000")
        let sha = sha256Hex(gz)
        let metrics = try VerificationLane.verifyWireBytes(
            wire: gz,
            format: "ndjson_gzip_noop_push_v1",
            compression: "gzip",
            digestScope: nil,
            sha256: sha,          // wire scope: manifest sha256 IS the wire digest
            wireSHA256: nil,
            compressedBytes: gz.count,
            uncompressedBytes: payload.count,
            receipt: nil)
        XCTAssertEqual(metrics.wireSHA, sha)
        XCTAssertEqual(metrics.contentSHA, sha256Hex(payload))
        XCTAssertEqual(metrics.compressedBytes, gz.count)
        XCTAssertEqual(metrics.uncompressedBytes, payload.count)
    }

    func testVerifyWireScopeGzipMismatchThrows() {
        let payload = Data("frwhoop-test-payload\n".utf8)
        let gz = hexData("1f8b08000000000002ff4b2b2acfc8cf2fd02d492d2ed12d48acccc94f4ce102002dfd727615000000")
        XCTAssertThrowsError(try VerificationLane.verifyWireBytes(
            wire: gz,
            format: "ndjson_gzip_noop_push_v1",
            compression: "gzip",
            digestScope: nil,
            sha256: sha256Hex(Data("other".utf8)),  // wrong expected wire digest
            wireSHA256: nil,
            compressedBytes: gz.count,
            uncompressedBytes: payload.count,
            receipt: nil)) { error in
            guard let vf = error as? VerificationLane.VerificationFailure else {
                return XCTFail("expected VerificationFailure, got \(error)")
            }
            XCTAssertEqual(vf.reason, "wire sha mismatch")
        }
    }

    func testVerifyDecodedScopeGzipSuccess() throws {
        // bin_gzip decoded scope: manifest sha256 IS the DECODED digest.
        let payload = Data("frwhoop-test-payload\n".utf8)
        let gz = hexData("1f8b08000000000002ff4b2b2acfc8cf2fd02d492d2ed12d48acccc94f4ce102002dfd727615000000")
        let contentSHA = sha256Hex(payload)
        let metrics = try VerificationLane.verifyWireBytes(
            wire: gz,
            format: "bin_gzip_noop_push_v1",
            compression: "gzip",
            digestScope: nil,
            sha256: contentSHA,
            wireSHA256: nil,
            compressedBytes: gz.count,
            uncompressedBytes: payload.count,
            receipt: nil)
        XCTAssertEqual(metrics.contentSHA, contentSHA)
    }

    func testVerifyDecodedScopeZstdSuccess() throws {
        // protobuf_zstd decoded scope: manifest sha256 is the DECODED digest.
        let payload = Data("protobuf-bytes".utf8)
        // A pre-built zstd frame of `payload` (generated with the zstd CLI).
        let z = Data([0x28, 0xb5, 0x2f, 0xfd, 0x24, 0x0e, 0x71, 0x00, 0x00,
                      0x70, 0x72, 0x6f, 0x74, 0x6f, 0x62, 0x75, 0x66, 0x2d,
                      0x62, 0x79, 0x74, 0x65, 0x73, 0xa3, 0xe2, 0x19, 0x78])
        let contentSHA = sha256Hex(payload)
        let metrics = try VerificationLane.verifyWireBytes(
            wire: z,
            format: "protobuf_zstd_noop_push_v1",
            compression: "zstd",
            digestScope: nil,
            sha256: contentSHA,
            wireSHA256: nil,
            compressedBytes: z.count,
            uncompressedBytes: payload.count,
            receipt: nil)
        XCTAssertEqual(metrics.contentSHA, contentSHA)
        XCTAssertEqual(metrics.uncompressedBytes, payload.count)
    }

    func testVerifyWireCountMismatchThrows() {
        let payload = Data("frwhoop-test-payload\n".utf8)
        let gz = hexData("1f8b08000000000002ff4b2b2acfc8cf2fd02d492d2ed12d48acccc94f4ce102002dfd727615000000")
        let sha = sha256Hex(gz)
        XCTAssertThrowsError(try VerificationLane.verifyWireBytes(
            wire: gz,
            format: "ndjson_gzip_noop_push_v1",
            compression: "gzip",
            digestScope: nil,
            sha256: sha,
            wireSHA256: nil,
            compressedBytes: gz.count + 1,   // wrong wire byte count
            uncompressedBytes: payload.count,
            receipt: nil)) { error in
            guard let vf = error as? VerificationLane.VerificationFailure else {
                return XCTFail("expected VerificationFailure, got \(error)")
            }
            XCTAssertTrue(vf.reason.hasPrefix("compressed_bytes"))
        }
    }

    func testVerifyReceiptAuthoritative() {
        let payload = Data("frwhoop-test-payload\n".utf8)
        let gz = hexData("1f8b08000000000002ff4b2b2acfc8cf2fd02d492d2ed12d48acccc94f4ce102002dfd727615000000")
        let sha = sha256Hex(gz)
        // Receipt claims a different wireSha256 -> must fail even though the
        // manifest's own digests match.
        XCTAssertThrowsError(try VerificationLane.verifyWireBytes(
            wire: gz,
            format: "ndjson_gzip_noop_push_v1",
            compression: "gzip",
            digestScope: nil,
            sha256: sha,
            wireSHA256: nil,
            compressedBytes: gz.count,
            uncompressedBytes: payload.count,
            receipt: ["wireSha256": sha256Hex(Data("bogus".utf8))])) { error in
            guard let vf = error as? VerificationLane.VerificationFailure else {
                return XCTFail("expected VerificationFailure, got \(error)")
            }
            XCTAssertTrue(vf.reason.contains("wire sha mismatch"))
        }
    }

    // MARK: - Missing-object detection

    func testMissingObjectDetection() {
        XCTAssertTrue(VerificationLane.isMissingObject(WorkerError.objectMissing))
        XCTAssertTrue(VerificationLane.isMissingObject(B2Storage.Error(message: "object_missing")))
        XCTAssertFalse(VerificationLane.isMissingObject(WorkerError.io("boom")))
        XCTAssertFalse(VerificationLane.isMissingObject(B2Storage.Error(message: "b2 download HTTP 500")))
    }

    // MARK: - Helpers





    /// Parse a lowercase hex string into Data (self-contained; PushBatchTests'
    /// hexString helper is file-private).
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
}
