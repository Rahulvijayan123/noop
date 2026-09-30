import Foundation
import CZlib

/// RFC1952 gzip decode through the system zlib, bounded by a hard output cap
/// so a corrupt object cannot exhaust worker memory.
///
/// F13 hardening: the decoder is strict about stream integrity.
///  - Every member must terminate with Z_STREAM_END. A stream that runs out of
///    input before a member completes is truncated and rejected; partial
///    output is never returned.
///  - Every member's 8-byte trailer (CRC32 + little-endian ISIZE) is validated
///    independently of zlib. zlib already checks the trailer before reporting
///    Z_STREAM_END, so this is defence in depth: a stream that zlib would
///    accept cannot be silently mangled.
///  - Bytes left over after the final member must begin a new gzip member
///    (magic 1f 8b); anything else is rejected as trailing garbage. A single
///    leftover byte is an error too.
///  - Concatenated (multi-member) gzip streams remain legal: each member is
///    decompressed and validated in turn.
enum Inflator {
    static let maxOutputBytes = 64 * 1024 * 1024 // 64 MiB per object

    static func gunzip(_ input: Data) throws -> Data {
        var data = input
        return try data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Data in
            guard raw.count > 0 else { return Data() }
            return try inflateGzip(base: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: raw.count)
        }
    }

    private static func inflateGzip(base: UnsafeMutablePointer<UInt8>, count: Int) throws -> Data {
        var output = Data()
        var src = base
        var remaining = count
        var memberIndex = 0
        // Multi-member gzip streams (rare, but legal): each pass over this loop
        // decompresses exactly one member and validates its trailer.
        while remaining > 0 {
            // Every member must start with the gzip magic 1f 8b. For the first
            // member a missing magic means the input is not gzip at all; after
            // the first member it means trailing garbage (requirement 3).
            if remaining < 2 || src[0] != 0x1f || src[1] != 0x8b {
                if memberIndex == 0 {
                    throw WorkerError.io("input is not a gzip stream (missing magic 1f 8b)")
                }
                throw WorkerError.io("trailing bytes after gzip stream")
            }
            memberIndex += 1

            var stream = z_stream()
            let initStatus = CZlib.inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            if initStatus != Z_OK {
                throw WorkerError.io("inflateInit failed \(initStatus)")
            }
            defer { CZlib.inflateEnd(&stream) }

            var finished = false
            stream.next_in = src
            stream.avail_in = uInt(remaining)
            // Per-member running values so each member's trailer can be checked
            // against exactly the bytes that member produced.
            var memberCRC: UInt = 0
            var memberBytes = 0
            while !finished {
                var outChunk = [UInt8](repeating: 0, count: 1 << 18)
                var produced = 0
                var failedStatus: Int32? = nil
                outChunk.withUnsafeMutableBufferPointer { buf in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = uInt(buf.count)
                    let status = CZlib.inflate(&stream, Z_NO_FLUSH)
                    if status == Z_STREAM_END { finished = true }
                    else if status != Z_OK && status != Z_BUF_ERROR {
                        failedStatus = status
                    }
                    produced = buf.count - Int(stream.avail_out)
                    if produced > 0 {
                        memberCRC = CZlib.crc32(memberCRC, buf.baseAddress, uInt(produced))
                        memberBytes += produced
                    }
                }
                if let bad = failedStatus {
                    // Z_DATA_ERROR for corrupt input (bad deflate, or a CRC/ISIZE
                    // trailer zlib itself rejects).
                    throw WorkerError.io("inflate failed \(bad)")
                }
                if produced > 0 {
                    output.append(contentsOf: outChunk[0..<produced])
                    if output.count > maxOutputBytes {
                        throw WorkerError.io("inflated output exceeds cap")
                    }
                }
                if stream.avail_out > 0 && !finished && stream.avail_in == 0 {
                    // inflate consumed all available input without reaching
                    // Z_STREAM_END and did not fill the output buffer, so it can
                    // never finish: the member is truncated. Never return
                    // partial output (requirement 1).
                    throw WorkerError.io("truncated gzip stream")
                }
            }

            // Z_STREAM_END: zlib itself verified the member's CRC32 and ISIZE
            // trailer. Verify it independently as well (requirement 2). The
            // trailer is the last 8 bytes the member consumed — at
            // src + total_in - 8 — 4 bytes little-endian CRC32 followed by 4
            // bytes little-endian ISIZE (uncompressed size mod 2^32, RFC 1952
            // §2.3.1). total_in counts header + deflate data + trailer, so the
            // bytes this member consumed span [src, src + total_in) and the
            // trailer is the tail of that span. (Assumption exercised by the
            // multi-member and trailer-corruption tests.)
            let consumed = Int(stream.total_in)
            guard consumed >= 8 else {
                throw WorkerError.io("gzip member shorter than its 8-byte trailer")
            }
            let trailer = src + (consumed - 8)
            let crcField = readUInt32LE(trailer)
            let isizeField = readUInt32LE(trailer + 4)
            let computedCRC = UInt32(truncatingIfNeeded: memberCRC)
            guard crcField == computedCRC else {
                throw WorkerError.io("gzip CRC32 mismatch (trailer \(crcField), computed \(computedCRC))")
            }
            let computedSize = UInt64(memberBytes) & 0xFFFF_FFFF
            guard UInt64(isizeField) == computedSize else {
                throw WorkerError.io("gzip ISIZE mismatch (trailer \(isizeField), expected \(memberBytes))")
            }

            src += consumed
            remaining -= consumed
        }
        return output
    }

    private static func readUInt32LE(_ p: UnsafePointer<UInt8>) -> UInt32 {
        return UInt32(p[0])
            | (UInt32(p[1]) << 8)
            | (UInt32(p[2]) << 16)
            | (UInt32(p[3]) << 24)
    }
}

/// Errors surfaced by worker lanes: enough structure to classify retryable.
enum WorkerError: Error {
    case io(String)
    case malformed(String)
    case retryable(String)
    case objectMissing
}
