import XCTest
import Foundation
import CZlib
@testable import frwhoop_worker

/// Pure tests (no DB, no network) for the F13-gzip-hardened `Inflator`.
///
/// Fixtures are built in-process so they do not depend on external tools:
///  - STORED-block members (no compression) with a CORRECT 4-byte ISIZE and a
///    zlib-computed CRC32 in the 8-byte trailer;
///  - DEFLATE members produced by zlib's `compress2` wrapped in a hand-built
///    gzip header/trailer, exercising the real deflate path.
final class GunzipTests: XCTestCase {

    // MARK: - fixture builders

    /// RFC1952 gzip header: magic 1f 8b, CM=8 (deflate), FLG=0 (no extras,
    /// name, comment), MTIME=0, XFL=0, OS=0xff. Exactly 10 bytes.
    private func gzipHeader() -> [UInt8] {
        [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff]
    }

    private func appendLE32(_ gz: inout Data, _ value: UInt32) {
        gz.append(UInt8(value & 0xff))
        gz.append(UInt8((value >> 8) & 0xff))
        gz.append(UInt8((value >> 16) & 0xff))
        gz.append(UInt8((value >> 24) & 0xff))
    }

    /// CRC32 via zlib (the same primitive the worker uses for its independent
    /// trailer check).
    private func crc32(_ data: Data) -> UInt32 {
        let value: UInt = data.withUnsafeBytes { raw in
            CZlib.crc32(0, raw.bindMemory(to: UInt8.self).baseAddress, uInt(raw.count))
        }
        return UInt32(truncatingIfNeeded: value)
    }

    /// One gzip member holding `payload` in a STORED (uncompressed) deflate
    /// block, with a correct 8-byte trailer (CRC32 + 4-byte ISIZE).
    private func storedMember(_ payload: Data) -> Data {
        var gz = Data(gzipHeader())
        // STORED block: BFINAL=1, BTYPE=00 -> 0x01, then LEN (LE16) + NLEN (~LEN).
        gz.append(0x01)
        gz.append(UInt8(payload.count & 0xff))
        gz.append(UInt8((payload.count >> 8) & 0xff))
        let nlen = (~payload.count) & 0xffff
        gz.append(UInt8(nlen & 0xff))
        gz.append(UInt8((nlen >> 8) & 0xff))
        gz.append(payload)
        appendLE32(&gz, crc32(payload))
        appendLE32(&gz, UInt32(payload.count))
        return gz
    }

    /// One gzip member holding `payload` DEFLATE-compressed by zlib's
    /// `compress2` (real compression path) inside a hand-built header/trailer.
    ///
    /// `compress2` emits a zlib (RFC1950) stream: 2-byte header + raw DEFLATE
    /// + 4-byte Adler-32. A gzip member carries raw DEFLATE (RFC1952 §2.2), so
    /// the zlib wrapper is verified and stripped before the gzip header and the
    /// correct CRC32 + ISIZE trailer are attached.
    private func deflatedMember(_ payload: Data) throws -> Data {
        let bound = Int(compressBound(uLong(payload.count)))
        var deflated = [UInt8](repeating: 0, count: bound)
        var destLen = uLong(bound)
        // Copy to a stable contiguous [UInt8] array so the pointer handed to
        // compress2 stays valid and deterministic across compilations.
        let payloadBytes = [UInt8](payload)
        let rc = payloadBytes.withUnsafeBufferPointer { srcBuf -> Int32 in
            deflated.withUnsafeMutableBufferPointer { dstBuf -> Int32 in
                CZlib.compress2(dstBuf.baseAddress, &destLen, srcBuf.baseAddress, uLong(payloadBytes.count), 6)
            }
        }
        XCTAssertEqual(rc, Z_OK, "compress2 failed with status \(rc)")
        let wrapped = Data(deflated[0..<Int(destLen)])
        XCTAssertTrue(wrapped.count >= 6, "zlib-wrapped output too small")
        // Sanity-check the wrapper before stripping: header byte 0x78 and the
        // trailing 4 bytes equal Adler-32(payload).
        XCTAssertEqual(wrapped[0], 0x78, "unexpected zlib header byte")
        XCTAssertEqual(adler32(payload), readUInt32BE(wrapped, at: wrapped.count - 4),
                       "zlib Adler-32 trailer mismatch")
        let rawDeflate = wrapped.dropFirst(2).dropLast(4)
        var gz = Data(gzipHeader())
        gz.append(contentsOf: rawDeflate)
        appendLE32(&gz, crc32(payload))
        appendLE32(&gz, UInt32(payload.count))
        return gz
    }

    /// Adler-32 via zlib. Note zlib's adler32 uses the passed initial value
    /// as-is (the standard "+1" seed is only applied when the buffer is NULL),
    /// so a fresh checksum must start from 1.
    private func adler32(_ data: Data) -> UInt32 {
        let value: UInt = data.withUnsafeBytes { raw in
            CZlib.adler32(1, raw.bindMemory(to: UInt8.self).baseAddress, uInt(raw.count))
        }
        return UInt32(truncatingIfNeeded: value)
    }

    private func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.index(data.startIndex, offsetBy: offset)
        return (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16)
            | (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
    }

    /// Asserts that `gunzip` throws a WorkerError.io whose message contains
    /// `needle`.
    private func assertThrowsIO(_ data: Data, containing needle: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Inflator.gunzip(data), file: file, line: line) { error in
            guard case WorkerError.io(let message) = error else {
                XCTFail("expected WorkerError.io, got \(error)", file: file, line: line)
                return
            }
            XCTAssertTrue(message.contains(needle),
                          "expected error containing '\(needle)', got '\(message)'",
                          file: file, line: line)
        }
    }

    // MARK: - valid streams

    func testValidSingleMemberStored() throws {
        let payload = Data("frwhoop".utf8)
        let out = try Inflator.gunzip(storedMember(payload))
        XCTAssertEqual(out, payload)
    }

    func testValidSingleMemberDeflated() throws {
        let payload = Data("frwhoop".utf8)
        let out = try Inflator.gunzip(try deflatedMember(payload))
        XCTAssertEqual(out, payload)
    }

    func testValidMultiMember() throws {
        let a = Data("member-one-".utf8)
        let b = Data("member-two!".utf8)
        // Concatenated gzip members (legal gzip): both must decompress.
        var stream = storedMember(a)
        stream.append(storedMember(b))
        let out = try Inflator.gunzip(stream)
        XCTAssertEqual(out, a + b)
    }

    func testRealShapedNDJSONBatchStored() throws {
        let ndjson = """
        {"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","endCursor":{"keySha256":"bb72","rowId":32668},"protocolVersion":"1.1","recordCount":2,"sourceId":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","startCursor":{"keySha256":"fc95","rowId":32636},"stream":"hrSample","type":"batch"}
        {"data":{"bpm":68},"key":{"ts":1790709930},"type":"record"}
        {"data":{"bpm":69},"key":{"ts":1790709931},"type":"record"}
        """.data(using: .utf8)!
        let out = try Inflator.gunzip(storedMember(ndjson))
        XCTAssertEqual(out, ndjson)
    }

    func testRealShapedNDJSONBatchDeflated() throws {
        let ndjson = """
        {"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","endCursor":{"keySha256":"bb72","rowId":32668},"protocolVersion":"1.1","recordCount":2,"sourceId":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","startCursor":{"keySha256":"fc95","rowId":32636},"stream":"hrSample","type":"batch"}
        {"data":{"bpm":68},"key":{"ts":1790709930},"type":"record"}
        {"data":{"bpm":69},"key":{"ts":1790709931},"type":"record"}
        """.data(using: .utf8)!
        let out = try Inflator.gunzip(try deflatedMember(ndjson))
        XCTAssertEqual(out, ndjson)
    }

    // MARK: - truncated streams

    func testTruncatedStreamThrows() throws {
        let full = storedMember(Data("frwhoop".utf8))
        // Drop the whole 8-byte trailer: inflate runs out of input before the
        // deflate stream can be finished and validated.
        assertThrowsIO(Data(full[0..<(full.count - 8)]), containing: "truncated")
        // Drop just the last 3 bytes (partial trailer) — also truncated.
        assertThrowsIO(Data(full[0..<(full.count - 3)]), containing: "truncated")
        // Cut mid-payload.
        assertThrowsIO(Data(full[0..<14]), containing: "truncated")
        // A bare header with no deflate data.
        assertThrowsIO(Data(full[0..<10]), containing: "truncated")
    }

    func testTruncatedDeflatedStreamThrows() throws {
        let full = try deflatedMember(Data("frwhoop".utf8))
        // Truncate the DEFLATE-compressed member mid-stream.
        assertThrowsIO(Data(full[0..<(full.count - 9)]), containing: "truncated")
    }

    // MARK: - corrupt trailers (requirement 2)

    func testCorruptedCRCThrows() throws {
        var gz = storedMember(Data("frwhoop".utf8))
        // Flip a bit in the CRC32 field (bytes count-8..<count-4).
        gz[gz.count - 8] ^= 0x01
        assertThrowsIO(gz, containing: "inflate failed")
    }

    func testCorruptedISIZEThrows() throws {
        var gz = storedMember(Data("frwhoop".utf8))
        // Flip a bit in the ISIZE field (bytes count-4..<count).
        gz[gz.count - 1] ^= 0x01
        assertThrowsIO(gz, containing: "inflate failed")
    }

    // MARK: - trailing bytes (requirement 3)

    func testTrailingGarbageThrows() throws {
        var gz = storedMember(Data("frwhoop".utf8))
        gz.append(contentsOf: [0xde, 0xad, 0xbe, 0xef])
        assertThrowsIO(gz, containing: "trailing bytes after gzip stream")
    }

    func testSingleTrailingByteThrows() throws {
        var gz = storedMember(Data("frwhoop".utf8))
        gz.append(0x00)
        assertThrowsIO(gz, containing: "trailing bytes after gzip stream")
    }

    func testTrailingGarbageAfterMultiMemberThrows() throws {
        var gz = storedMember(Data("a".utf8))
        gz.append(storedMember(Data("b".utf8)))
        gz.append(contentsOf: [0xff, 0xff])
        assertThrowsIO(gz, containing: "trailing bytes after gzip stream")
    }

    // MARK: - output cap (requirement 5)

    func testOutputCapExceededThrows() throws {
        // 65 MiB of 'A' deflates to a few KB, but decompressing it exceeds the
        // 64 MiB per-object cap, which must throw rather than allocate unbounded.
        let big = Data(repeating: 0x41, count: 64 * 1024 * 1024 + 1)
        assertThrowsIO(try deflatedMember(big), containing: "exceeds cap")
    }

    // MARK: - empty input (requirement 6)

    func testEmptyInputReturnsEmpty() throws {
        // Kept from the previous behaviour: an empty object yields empty output.
        // The only production caller (ProjectionLane) only calls gunzip on a
        // verified non-empty wire object, so returning Data() is inert and
        // preserves the existing contract.
        let out = try Inflator.gunzip(Data())
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - non-gzip input

    func testNonGzipInputThrows() throws {
        assertThrowsIO(Data("this is not gzip at all".utf8), containing: "not a gzip stream")
    }
}
