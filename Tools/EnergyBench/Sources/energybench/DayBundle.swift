import Foundation
import WhoopProtocol

// DayBundle.swift — the `energy-bench-day-v1` file format and its decoder.
//
// One bundle is one LOCAL day of one wearer: the strap streams in a compact delta-encoded text form (one
// "dt a b …" item per sample, comma separated, first dt = 0) plus the few scalars the app would have had
// at hand (profile, scored sleep, resting HR). `scripts/assemble_day_bundles.py` writes them from raw
// export queries; nothing here knows or cares which database they came from.

struct DayBundle: Decodable {
    struct Profile: Decodable {
        let weightKg: Double
        let heightCm: Double
        let age: Double
        let sex: String
    }

    struct SleepRow: Decodable {
        let start: Int
        let end: Int
        let restingHr: Int?
        let nap: Bool?
    }

    struct Stream: Decodable {
        let t0: Int
        let n: Int
        /// Integer scale of the encoded values (gravity is stored ×10⁴). nil = 1.
        let scale: Double?
        let v: String
    }

    static let format = "energy-bench-day-v1"

    let format: String
    let day: String
    let tzOffsetSeconds: Int
    let dayStart: Int
    /// The last second the recording covers, for a day still in progress. nil for a complete day.
    let asOf: Int?
    let profile: Profile
    let restingHr: Double?
    let sleep: [SleepRow]
    let hr: Stream
    let gravity: Stream?
    let steps: Stream?

    static func load(_ url: URL) throws -> DayBundle {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let bundle = try decoder.decode(DayBundle.self, from: Data(contentsOf: url))
        guard bundle.format == Self.format else {
            throw BundleError.unsupportedFormat(bundle.format)
        }
        return bundle
    }
}

enum BundleError: Error, CustomStringConvertible {
    case unsupportedFormat(String)
    case malformed(stream: String, item: Int)
    case countMismatch(stream: String, declared: Int, actual: Int)

    var description: String {
        switch self {
        case .unsupportedFormat(let f): return "unsupported bundle format \"\(f)\" (want \(DayBundle.format))"
        case .malformed(let s, let i): return "\(s) stream: malformed item \(i)"
        case .countMismatch(let s, let d, let a): return "\(s) stream: declared n=\(d) but decoded \(a)"
        }
    }
}

/// Decoders for the delta-encoded streams. Each walks the text once; `dt` accumulates onto `t0`.
enum StreamCodec {
    private static func rows(_ s: DayBundle.Stream, fields: Int, name: String,
                             _ body: (_ ts: Int, _ f: [Substring], _ index: Int) throws -> Void) throws {
        var ts = s.t0
        var index = 0
        for item in s.v.split(separator: ",", omittingEmptySubsequences: true) {
            let f = item.split(separator: " ", omittingEmptySubsequences: false)
            guard f.count == fields, let dt = Int(f[0]) else { throw BundleError.malformed(stream: name, item: index) }
            ts += dt
            try body(ts, f, index)
            index += 1
        }
        guard index == s.n else { throw BundleError.countMismatch(stream: name, declared: s.n, actual: index) }
    }

    static func heartRate(_ s: DayBundle.Stream) throws -> [HRSample] {
        var out: [HRSample] = []
        out.reserveCapacity(s.n)
        try rows(s, fields: 2, name: "hr") { ts, f, i in
            guard let bpm = Int(f[1]) else { throw BundleError.malformed(stream: "hr", item: i) }
            out.append(HRSample(ts: ts, bpm: bpm))
        }
        return out
    }

    static func gravity(_ s: DayBundle.Stream) throws -> [GravitySample] {
        let scale = s.scale ?? 1
        var out: [GravitySample] = []
        out.reserveCapacity(s.n)
        try rows(s, fields: 5, name: "gravity") { ts, f, i in
            guard let x = Int(f[1]), let y = Int(f[2]), let z = Int(f[3]) else {
                throw BundleError.malformed(stream: "gravity", item: i)
            }
            let dyn = Int(f[4]).map { Double($0) / scale }
            out.append(GravitySample(ts: ts, x: Double(x) / scale, y: Double(y) / scale, z: Double(z) / scale,
                                     dynAccel: dyn))
        }
        return out
    }

    static func steps(_ s: DayBundle.Stream) throws -> [StepSample] {
        var out: [StepSample] = []
        out.reserveCapacity(s.n)
        try rows(s, fields: 3, name: "steps") { ts, f, i in
            guard let counter = Int(f[1]) else { throw BundleError.malformed(stream: "steps", item: i) }
            out.append(StepSample(ts: ts, counter: counter, activityClass: Int(f[2])))
        }
        return out
    }
}
