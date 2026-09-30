
import XCTest
@testable import frwhoop_worker

final class PushBatchTests: XCTestCase {
    func testDecodeAppendBatch() throws {
        let ndjson = """
        {"batchId":"80596eac-6f53-5b18-b993-6892765f3f84","delivery":"append","deviceId":"whoop-5B00145417","endCursor":{"keySha256":"bb72","rowId":32668},"protocolVersion":"1.1","recordCount":2,"sourceId":"3ef42e3f-55d2-4e4f-a68a-e0551457ccf9","startCursor":{"keySha256":"fc95","rowId":32636},"stream":"hrSample","type":"batch"}
        {"data":{"bpm":68},"key":{"ts":1790709930},"type":"record"}
        {"data":{"bpm":69},"key":{"ts":1790709931},"type":"record"}
        """.data(using: .utf8)!
        let batch = try PushBatch.decode(ndjson: ndjson)
        XCTAssertEqual(batch.stream, "hrSample")
        XCTAssertEqual(batch.delivery, "append")
        XCTAssertEqual(batch.recordCount, 2)
        XCTAssertEqual(batch.endCursor?.rowId, 32668)
        let rows = try batch.projectionRows(userId: "u1", deviceId: "d1")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["ts"] as? Int, 1790709930)
        XCTAssertEqual(rows[0]["bpm"] as? Int, 68)
        XCTAssertEqual(rows[0]["user_id"] as? String, "u1")
        XCTAssertEqual(rows[0]["batch_id"] as? String, "80596eac-6f53-5b18-b993-6892765f3f84")
    }

    func testDecodeRejectsRecordCountMismatch() throws {
        let ndjson = """
        {"batchId":"b","delivery":"append","deviceId":"d","protocolVersion":"1.0","recordCount":3,"sourceId":"s","stream":"hrSample","type":"batch"}
        {"data":{"bpm":68},"key":{"ts":1},"type":"record"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try PushBatch.decode(ndjson: ndjson))
    }

    func testGunzipRoundTrip() throws {
        // A known gzip stream: zlib compression of "frwhoop" via the system
        // gzip tool is not available in-process; use a hand-built member.
        // gzip header (1f 8b 08 00 ...) + stored deflate block is simplest.
        var gz = Data([0x1f, 0x8b, 0x08, 0x00, 0,0,0,0, 0x00, 0xff])
        let payload = Data("frwhoop".utf8)
        // STORED block: BFINAL=1,BTYPE=00 header byte, then LEN, NLEN, data
        gz.append(0x01)
        gz.append(UInt8(payload.count))
        gz.append(UInt8(payload.count >> 8))
        let nlen = ~payload.count & 0xffff
        gz.append(UInt8(nlen & 0xff))
        gz.append(UInt8((nlen >> 8) & 0xff))
        gz.append(payload)
        // CRC32 of "frwhoop" + size
        gz.append(contentsOf: crc32(payload))
        gz.append(UInt8(payload.count))
        gz.append(UInt8(payload.count >> 8))
        let out = try Inflator.gunzip(gz)
        XCTAssertEqual(out, payload)
    }

    private func crc32(_ data: Data) -> [UInt8] {
        // One-shot CRC via zlib: no public Swift API, compute manually.
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        let v = ~crc
        return [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }
}
