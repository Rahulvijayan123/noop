import Foundation
import StrandAnalytics

/// Disposable on-host cache for the raw-IMU lane: the downloaded objects and the model's answer for each
/// serve request.
///
/// A raw-IMU job covers one UTC day and is re-run every time another object of that day turns ready. With
/// the phone uploading a 300 s object every few minutes, re-downloading every object and re-running the
/// model over the whole day each time would grow quadratically over the day. Neither is needed:
///  - an object is immutable and named by the digest of its decoded bytes, so its wire bytes are kept and
///    re-verified (decompress + digest) instead of downloaded again;
///  - a serve request is a pure function of its seconds, its head/tail context and the model, so its
///    windows are kept under a digest of exactly those. Request chunks are aligned to the start of their
///    run, so only the run that grew (normally the newest) produces a request the cache has not seen.
///
/// Nothing here is authoritative. A missing, unreadable or corrupt entry is a miss; the cache can be deleted
/// at any time (and should be after a model redeploy that keeps the same version string). Entries older
/// than `maxAgeSeconds` are pruned.
struct ActivityLocalCache {
    let directory: URL
    var maxAgeSeconds: TimeInterval = 3 * 86_400

    /// nil when no directory is configured or it cannot be created, which turns caching off.
    init?(path: String?, maxAgeSeconds: TimeInterval = 3 * 86_400) {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        do {
            for sub in ["objects", "inference"] {
                try FileManager.default.createDirectory(at: url.appendingPathComponent(sub, isDirectory: true),
                                                        withIntermediateDirectories: true)
            }
        } catch {
            FileHandle.standardError.write(
                "frwhoop-worker: activity cache disabled (\(path) not writable: \(error))\n".data(using: .utf8)!)
            return nil
        }
        self.directory = url
        self.maxAgeSeconds = maxAgeSeconds
    }

    // MARK: Objects

    /// The cached wire (compressed) bytes of the object whose decoded digest is `digest`.
    func object(digest: String) -> Data? {
        guard let url = file("objects", digest, "zst") else { return nil }
        return try? Data(contentsOf: url)
    }

    func storeObject(_ wire: Data, digest: String) {
        guard let url = file("objects", digest, "zst") else { return }
        write(wire, to: url)
    }

    func removeObject(digest: String) {
        guard let url = file("objects", digest, "zst") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Inference

    /// Digest of everything a serve answer depends on: the model, preprocessing, transition-expert and
    /// gait-expert versions and the exact request body (range, seconds, head and tail context).
    /// `activity-infer-3`: answers now carry HART's `fine` distribution, which older entries lack.
    static func inferenceKey(request: ActivityPythonService.RunRequest, modelVersion: String,
                             preprocessingVersion: String, transitionVersion: String = "none",
                             gaitVersion: String? = nil) -> String {
        var data = Data()
        func add(_ text: String) { data.append(contentsOf: Array(text.utf8)); data.append(0x0A) }
        add("activity-infer-3")
        add(modelVersion)
        add(preprocessingVersion)
        add(transitionVersion)
        if let gaitVersion { add("g:" + gaitVersion) }
        add("\(request.startTs)-\(request.endTs)")
        add("h\(request.headB64.count)"); request.headB64.forEach(add)
        add("c\(request.columnsB64.count)"); request.columnsB64.forEach(add)
        add("t\(request.tailB64.count)"); request.tailB64.forEach(add)
        return sha256Hex(data)
    }

    func inference(key: String) -> ActivityPythonService.InferResult? {
        guard let url = file("inference", key, "json"), let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(InferenceEntry.self, from: data) else { return nil }
        return entry.result
    }

    /// Only a successful answer is kept: an error is about the service at that moment, not the request.
    func storeInference(_ result: ActivityPythonService.InferResult, key: String) {
        guard result.ok, let url = file("inference", key, "json"),
              let data = try? JSONEncoder().encode(InferenceEntry(result)) else { return }
        write(data, to: url)
    }

    // MARK: Housekeeping

    /// Delete entries not written for `maxAgeSeconds`. Returns how many were removed.
    @discardableResult
    func prune(now: Date = Date()) -> Int {
        let fm = FileManager.default
        var removed = 0
        for sub in ["objects", "inference"] {
            let dir = directory.appendingPathComponent(sub, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names {
                let url = dir.appendingPathComponent(name)
                guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) > maxAgeSeconds else { continue }
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
            }
        }
        return removed
    }

    // MARK: Private

    /// Entries are named by a lowercase hex digest only, so a key can never reach outside the directory.
    private func file(_ sub: String, _ key: String, _ ext: String) -> URL? {
        guard key.count == 64, key.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            return nil
        }
        return directory.appendingPathComponent(sub, isDirectory: true).appendingPathComponent("\(key).\(ext)")
    }

    /// Write through a temporary file so a reader never sees half an entry.
    private func write(_ data: Data, to url: URL) {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.moveItem(at: temp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private struct InferenceEntry: Codable {
        struct Window: Codable {
            var s: Double
            var e: Double
            var label: String
            var probs: [String: Double]
            var baseline: Bool
            var feat: [String: Double]
            var calibrated: Bool?
            var transition: Transition?
            var fine: [String: Double]?
        }
        struct Gait: Codable {
            var s: Int, e: Int, p: Double, gait: Bool, pre: Bool
            var cadence: Double?, speed: Double?, stride: Double?, regularity: Double?, steps: Double?
        }
        struct Transition: Codable {
            var probs: [String: Double]
            var label: String
            var confidence: Double
            var abstained: Bool
            var ts: Double?
        }
        var modelVersion: String?
        var preprocessingVersion: String?
        var featureSchema: String?
        var transitionSchema: String?
        var transitionVersion: String?
        var windows: [Window]
        var fineSchema: String?
        var gaitSchema: String?
        var gaitModelVersion: String?
        var gaitStatus: String?
        var gaitWindows: [Gait]?

        init(_ r: ActivityPythonService.InferResult) {
            modelVersion = r.modelVersion
            preprocessingVersion = r.preprocessingVersion
            featureSchema = r.featureSchema
            transitionSchema = r.transitionSchema
            transitionVersion = r.transitionVersion
            windows = r.windows.map {
                Window(s: $0.start, e: $0.end, label: $0.label, probs: $0.probs, baseline: $0.baseline,
                       feat: $0.features, calibrated: $0.calibrated,
                       transition: $0.transition.map {
                           Transition(probs: $0.probs, label: $0.label, confidence: $0.confidence,
                                      abstained: $0.abstained, ts: $0.ts)
                       },
                       fine: $0.fine)
            }
            fineSchema = r.fineSchema
            gaitSchema = r.gaitSchema
            gaitModelVersion = r.gaitModelVersion
            gaitStatus = r.gaitStatus
            gaitWindows = r.gaitWindows.isEmpty ? nil : r.gaitWindows.map {
                Gait(s: $0.startTs, e: $0.endTs, p: $0.gaitProb, gait: $0.isGait, pre: $0.prefiltered,
                     cadence: $0.cadenceSpm, speed: $0.speedMps, stride: $0.strideM, regularity: $0.regularity,
                     steps: $0.steps)
            }
        }

        var result: ActivityPythonService.InferResult {
            ActivityPythonService.InferResult(
                ok: true, modelVersion: modelVersion, preprocessingVersion: preprocessingVersion,
                windows: windows.map {
                    ActivityPythonService.WindowPrediction(
                        start: $0.s, end: $0.e, label: $0.label, probs: $0.probs, baseline: $0.baseline,
                        calibrated: $0.calibrated ?? false, features: $0.feat,
                        transition: $0.transition.map {
                            ActivityPythonService.TransitionOutput(probs: $0.probs, label: $0.label,
                                                                   confidence: $0.confidence,
                                                                   abstained: $0.abstained, ts: $0.ts)
                        },
                        fine: $0.fine)
                },
                error: nil, errorKind: nil, featureSchema: featureSchema,
                transitionSchema: transitionSchema, transitionVersion: transitionVersion,
                fineSchema: fineSchema,
                gaitWindows: (gaitWindows ?? []).map {
                    ActivityGaitWindow(startTs: $0.s, endTs: $0.e, gaitProb: $0.p, isGait: $0.gait, prefiltered: $0.pre,
                                       cadenceSpm: $0.cadence, speedMps: $0.speed, strideM: $0.stride,
                                       regularity: $0.regularity, steps: $0.steps,
                                       modelVersion: gaitModelVersion ?? "unknown")
                },
                gaitSchema: gaitSchema, gaitModelVersion: gaitModelVersion, gaitStatus: gaitStatus)
        }
    }
}
