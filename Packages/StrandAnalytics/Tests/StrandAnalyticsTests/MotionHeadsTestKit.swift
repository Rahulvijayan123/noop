import Foundation
@testable import StrandAnalytics

/// Synthetic Inertia-1 bundles and windows for the motion-head tests. Nothing here is a real model: every
/// bundle is either a synthetic `inertia1` stand-in for the evidence math or an explicit `standin`.
enum MotionHeadsKit {

    static let bundleSha = String(repeating: "ab", count: 32)
    static let checkpointSha = String(repeating: "cd", count: 32)

    /// Uniform-ish calibration prior over `classes` (deterministic, sums to 1).
    static func prior(_ classes: [String]) -> [String: Double] {
        var out: [String: Double] = [:]
        let n = Double(classes.count)
        for c in classes { out[c] = 1 / n }
        return out
    }

    static func spec(_ head: MotionHead, supported: [String]? = nil, prior customPrior: [String: Double]? = nil,
                     status: [String: MotionHeadClassStatus] = [:], tau: Double = 0.8,
                     mergeInto: [String: String] = [:], covers: [String: [String]] = [:]) -> MotionHeadSpec {
        let classes = supported ?? head.classOrder
        let p: [String: Double]
        if let customPrior { p = customPrior }
        else if head.isCategorical { p = prior(classes) }
        else { p = Dictionary(uniqueKeysWithValues: classes.map { ($0, 0.05) }) }
        var st: [String: MotionHeadClassStatus] = [:]
        for c in classes { st[c] = status[c] ?? .strong }
        var t: [String: Double] = [:]
        for c in classes { t[c] = tau }
        return MotionHeadSpec(classOrder: head.classOrder, prior: p, status: st, tau: t, mergeInto: mergeInto, covers: covers)
    }

    static func bundle(kind: MotionHeadsEncoderKind = .inertia1, tier: MotionHeadsEvidenceTier = .candidate,
                       windowS: Int = 10, hopS: Int = 5,
                       heads: [MotionHead: MotionHeadSpec]? = nil, sha: String = bundleSha) -> MotionHeadsBundleInfo {
        MotionHeadsBundleInfo(
            encoderId: kind == .inertia1 ? "inertia-1/ar_transformer-small/\(windowS)s@20hz"
                : kind == .actinet ? "actinet/harnet30-c24-mw/30s@20hz" : "standin:handcrafted-stats-v1",
            encoderKind: kind, encoderVersion: "test-1", checkpointSha256: kind.isPinned ? checkpointSha : nil,
            headsVersion: "test-bundle-1", bundleSha256: sha, evidenceTierMax: tier, windowS: windowS, hopS: hopS,
            heads: heads ?? [.posture: spec(.posture), .locomotion: spec(.locomotion),
                             .armBehavior: spec(.armBehavior), .transition: spec(.transition)],
            ood: MotionHeadsOODInfo(method: "knn", threshold: 1.25))
    }

    /// A distribution over `classes` that puts `p` on `top` and spreads the rest evenly.
    static func peaked(_ classes: [String], _ top: String, _ p: Double) -> [String: Double] {
        var out: [String: Double] = [:]
        let rest = (1 - p) / Double(classes.count - 1)
        for c in classes { out[c] = c == top ? p : rest }
        return out
    }

    static func window(endingAt e: Int, windowS: Int = 10, posture: [String: Double]? = nil,
                       locomotion: [String: Double]? = nil, arm: [String: Double]? = nil,
                       transition: [String: Double]? = nil, intensity: Double? = 0.2,
                       ood: Bool = false) -> MotionHeadsWindow {
        MotionHeadsWindow(startTs: e - windowS, endTs: e, posture: posture, locomotion: locomotion, armBehavior: arm,
                          transition: transition, movementIntensity: intensity, oodScore: ood ? 3.0 : 0.4, isOOD: ood)
    }

    /// Attach a window to every `hopS`-th observed second (the way the track builder does, one per hop).
    static func attach(_ observations: [ActivityObservation], hopS: Int = 5,
                       make: (Int) -> MotionHeadsWindow?) -> [ActivityObservation] {
        observations.map { o in
            var o = o
            if o.wear != .offWrist, o.ts % hopS == 0 { o.motionHeads = make(o.ts) }
            return o
        }
    }

    /// The decoder config with Inertia evidence from `bundle` (and the test-only override when asked).
    static func config(_ bundle: MotionHeadsBundleInfo = bundle(), base: ActivityDecoderConfig = ActivityDecoderConfig(),
                       locomotion: Double = 0.25, posture: Double = 0.25, arm: Double = 0.25,
                       redundancy: Double = 0.5, standInOverride: Bool = false,
                       mode: MotionHeadsEvidenceConfig.Mode = .candidate) -> ActivityDecoderConfig {
        var c = base
        c.motionHeads = MotionHeadsEvidenceConfig(mode: mode, bundle: bundle, locomotionWeight: locomotion,
                                                  postureWeight: posture, armWeight: arm,
                                                  hartRedundancy: redundancy,
                                                  allowStandInEvidenceForTesting: standInOverride)
        return c
    }

    /// States as JSON lines with the motion-heads provenance key removed: the comparison for "Inertia on but
    /// contributing nothing" against "Inertia off".
    static func statesWithoutProvenance(_ states: [ActivityContextState]) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try states.map { s -> String in
            var copy = s
            copy.versions.motionHeads = nil
            return String(decoding: try e.encode(copy), as: UTF8.self)
        }.joined(separator: "\n")
    }

    /// Per-mode posterior mass from a snapshot (sums the Erlang phases).
    static func modeMass(_ snapshot: ActivityDecoderSnapshot) -> [Double] {
        var out: [Double] = []
        var cursor = 0
        for m in 0..<BodyMode.count {
            let k = ActivityContextModel.profiles[m].phases
            out.append(snapshot.body[cursor..<(cursor + k)].reduce(0, +))
            cursor += k
        }
        return out
    }

    static let postureSet: [BodyMode] = [.bedRest, .seated, .upright, .vehicle, .sitToStand, .standToSit,
                                         .lyingDown, .gettingUp]

    /// A complete `motion-heads-1` response line for `bundle` + `windows` (JSON object text).
    static func responseJSON(_ bundle: MotionHeadsBundleInfo, _ windows: [MotionHeadsWindow],
                             mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        let bundleData = try JSONEncoder().encode(bundle)
        var obj = try JSONSerialization.jsonObject(with: bundleData) as! [String: Any]
        obj["id"] = "req-1"
        obj["op"] = "infer"
        obj["ok"] = true
        obj["schema"] = "motion-heads-1"
        obj["windows"] = try windows.map { w -> [String: Any] in
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(w)) as! [String: Any]
        }
        obj["n_dropped_nonfinite"] = 0
        obj["duration_ms"] = 3
        mutate(&obj)
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }
}

extension MotionHeadsEvidenceConfig {
    /// The candidate defaults (INERTIA1.md §7), as the worker builds them. A test-target copy of the worker's
    /// helper, so the package itself exposes no API that only tests and the worker call.
    static func candidate(bundle: MotionHeadsBundleInfo, expectedBundleSHA256: String? = nil) -> MotionHeadsEvidenceConfig {
        MotionHeadsEvidenceConfig(mode: .candidate, bundle: bundle, expectedBundleSHA256: expectedBundleSHA256)
    }
}
