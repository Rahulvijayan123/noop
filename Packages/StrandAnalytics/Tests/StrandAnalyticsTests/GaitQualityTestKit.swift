import Foundation
@testable import StrandAnalytics

/// Synthetic ElderNet models and windows for the gait-quality tests. Nothing here is the real model: the weight
/// digests are made up, and the windows are whatever a test needs.
enum GaitKit {

    static let commit = "437a38bcc69f42717fe73c1f7dbea7e1f7a50d23"
    static let version = "eldernet-437a38b"

    /// One made-up sha256 per head (deterministic).
    static func weights(_ seed: String = "a") -> [String: String] {
        let digits = Array("0123456789abcdef")
        var out: [String: String] = [:]
        for (i, name) in GaitQualityWire.weightNames.enumerated() {
            let c = digits[(Int(seed.unicodeScalars.first!.value) + i) % 16]
            out[name] = String(repeating: String(c), count: 64)
        }
        return out
    }

    static func model(hopS: Int = 5, threshold: Double = 0.5, version: String = version, seed: String = "a",
                      calibration: [String: GaitQualityCalibrationEntry]? = nil) -> GaitQualityModelInfo {
        GaitQualityModelInfo(modelVersion: version, weights: weights(seed), upstreamCommit: commit, hopS: hopS,
                             calibration: calibration, gaitThreshold: threshold)
    }

    /// A window ending at `e` with gait probability `p` (is_gait follows the 0.5 threshold) and, on gait, metrics.
    static func window(endingAt e: Int, p: Double, threshold: Double = 0.5, speed: Double? = 1.2,
                       cadence: Double? = 108, stride: Double? = 1.3, regularity: Double? = 0.8,
                       steps: Double? = 18) -> GaitQualityWindow {
        let gait = p >= threshold
        return GaitQualityWindow(startTs: e - 10, endTs: e, gaitProb: p, isGait: gait,
                                 speedMps: gait ? speed : nil, cadenceSpm: gait ? cadence : nil,
                                 strideM: gait ? stride : nil, regularity: gait ? regularity : nil,
                                 steps: gait ? steps : nil)
    }

    static func prefiltered(endingAt e: Int) -> GaitQualityWindow {
        GaitQualityWindow(startTs: e - 10, endTs: e, gaitProb: 0, isGait: false, prefiltered: true)
    }

    /// Attach a window to every `hopS`-th observed second (the way the track builder does, one per hop).
    static func attach(_ observations: [ActivityObservation], hopS: Int = 5,
                       make: (Int) -> GaitQualityWindow?) -> [ActivityObservation] {
        observations.map { o in
            var o = o
            if o.wear != .offWrist, o.ts % hopS == 0 { o.gaitQuality = make(o.ts) }
            return o
        }
    }

    /// The decoder config with ElderNet evidence from `model`.
    static func config(_ model: GaitQualityModelInfo = model(), base: ActivityDecoderConfig = ActivityDecoderConfig(),
                       mode: GaitQualityEvidenceConfig.Mode = .candidate, prior: Double = 0.2,
                       gait: Double = 0.25, brisk: Double = 0, rule: GaitQualityEvidenceConfig.BriskRule = .cadence,
                       hartRedundancy: Double = 0.65, inertiaRedundancy: Double = 0.65, budget: Double = 0.5,
                       pinVersion: String? = nil, pinDigest: String? = nil) -> ActivityDecoderConfig {
        var c = base
        c.gaitQuality = GaitQualityEvidenceConfig(mode: mode, model: model, gaitPrior: prior, gaitWeight: gait,
                                                  briskWeight: brisk, briskRule: rule,
                                                  hartRedundancy: hartRedundancy, inertiaRedundancy: inertiaRedundancy,
                                                  accelerometerBudget: budget, expectedModelVersion: pinVersion,
                                                  expectedWeightsDigest: pinDigest)
        return c
    }

    /// A complete `gait-quality-1` response line for `model` + `windows` (JSON object text, sorted keys).
    static func responseJSON(_ model: GaitQualityModelInfo, _ windows: [GaitQualityWindow],
                             mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as! [String: Any]
        obj["id"] = "req-1"
        obj["op"] = "infer"
        obj["ok"] = true
        obj["schema"] = "gait-quality-1"
        obj["windows"] = try windows.map { w -> [String: Any] in
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(w)) as! [String: Any]
        }
        obj["n_dropped_nonfinite"] = 0
        obj["duration_ms"] = 4
        mutate(&obj)
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    /// States as JSON lines with the gait provenance and the gait block removed: "ElderNet on but contributing
    /// nothing" against "ElderNet off".
    static func statesWithoutGait(_ states: [ActivityContextState]) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try states.map { s -> String in
            var copy = s
            copy.versions.gaitQuality = nil
            copy.gait = nil
            return String(decoding: try e.encode(copy), as: UTF8.self)
        }.joined(separator: "\n")
    }

    /// Decode one response line the way the worker does: `JSONDecoder` + the strict `init(from:)`, with text that is
    /// not JSON at all reported as `.notJSON` (nonfinite when it carries a NaN / Infinity token).
    static func decode(_ data: Data) throws -> GaitQualityResponse {
        do {
            return try JSONDecoder().decode(GaitQualityResponse.self, from: data)
        } catch is DecodingError {
            let text = String(decoding: data, as: UTF8.self)
            let nonfinite = text.range(of: #"[:\[,]\s*-?(NaN|Infinity)"#, options: .regularExpression) != nil
            throw GaitQualityResponseError.notJSON(nonfinite: nonfinite)
        }
    }

    /// The synthetic fixture this package's tests decode (`Goldens/ElderNet/`), written per ELDERNET.md §4.
    static func syntheticFixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Goldens/ElderNet/synthetic_gait_quality_response.json")
        return try Data(contentsOf: url)
    }
}
