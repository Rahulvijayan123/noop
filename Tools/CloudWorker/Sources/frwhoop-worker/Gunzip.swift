
import Foundation
import CZlib

/// RFC1952 gzip decode through the system zlib, bounded by a hard output cap
/// so a corrupt object cannot exhaust worker memory.
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
        // Handle multi-member gzip streams (rare, but legal).
        while remaining > 0 {
            var stream = z_stream()
            let initStatus = CZlib.inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            if initStatus != Z_OK {
                throw WorkerError.io("inflateInit failed \(initStatus)")
            }
            defer { CZlib.inflateEnd(&stream) }
            var finished = false
            stream.next_in = src
            stream.avail_in = uInt(remaining)
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
                }
                if let bad = failedStatus {
                    throw WorkerError.io("inflate failed \(bad)")
                }
                if produced > 0 {
                    output.append(contentsOf: outChunk[0..<produced])
                    if output.count > maxOutputBytes {
                        throw WorkerError.io("inflated output exceeds cap")
                    }
                }
                if stream.avail_out > 0 && !finished && stream.avail_in == 0 {
                    break
                }
            }
            let consumedThisMember = Int(stream.total_in)
            src += consumedThisMember
            remaining -= consumedThisMember
            if remaining < 2 { break }
            // Peek: a following gzip member starts with 1f 8b; otherwise stop.
            if !(src[0] == 0x1f && src[1] == 0x8b) { break }
        }
        return output
    }
}

/// Errors surfaced by worker lanes: enough structure to classify retryable.
enum WorkerError: Error {
    case io(String)
    case malformed(String)
    case retryable(String)
    case objectMissing
}
