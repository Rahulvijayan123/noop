import Foundation
import CoreML

/// Process-wide UniTS Core ML session. Inference only; never trained on device.
final class UniTSCoreMLSession: @unchecked Sendable {
    static let shared = UniTSCoreMLSession()

    private let lock = NSLock()
    private var model: MLModel?
    private var loadAttempted = false

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        _ = loadIfNeeded()
        return model != nil
    }

    var declaresActivityInput: Bool {
        lock.lock()
        defer { lock.unlock() }
        _ = loadIfNeeded()
        return model?.modelDescription.inputDescriptionsByName["activity"] != nil
    }

    func predict(occupancy: [Double], prompt: [Double], personalScale: [Double],
                 observed: [[Double]], activity: [[Double]] = [],
                 presentMask: [[Double]] = []) -> (hat: [[Double]], sigma: [[Double]])? {
        lock.lock()
        defer { lock.unlock() }
        guard let model = loadIfNeeded() else { return nil }
        do {
            let occ = try Self.vector(occupancy, shape: [1, NSNumber(value: WatchdogConfig.seqLen)])
            let pr = try Self.vector(prompt, shape: [1, 6])
            let sc = try Self.vector(personalScale, shape: [1, 6])
            let obs = try Self.cube(observed, channels: 6, seq: WatchdogConfig.seqLen)
            var dict: [String: MLFeatureValue] = [
                "occupancy": MLFeatureValue(multiArray: occ),
                "prompt": MLFeatureValue(multiArray: pr),
                "personal_scale": MLFeatureValue(multiArray: sc),
                "observed": MLFeatureValue(multiArray: obs)
            ]
            Self.attachPresentMask(dict: &dict, model: model, presentMask: presentMask)
            let hasActivity = model.modelDescription.inputDescriptionsByName["activity"] != nil
            if hasActivity, !activity.isEmpty, let act = try? Self.timeFeatures(activity) {
                dict["activity"] = MLFeatureValue(multiArray: act)
            }
            let input = try MLDictionaryFeatureProvider(dictionary: dict)
            let out = try model.prediction(from: input)
            guard let hatArr = out.featureValue(for: "hat")?.multiArrayValue,
                  let sigArr = out.featureValue(for: "sigma")?.multiArrayValue else { return nil }
            return (Self.planes(hatArr), Self.planes(sigArr))
        } catch {
            return nil
        }
    }

    private func loadIfNeeded() -> MLModel? {
        if loadAttempted { return model }
        loadAttempted = true
        #if os(watchOS)
        // `MLModel.compileModel(at:)` is unavailable on watchOS. Watchdog live
        // inference is an iPhone path; the Swift decoder still runs here.
        return nil
        #else
        guard let url = Self.resourceURL() else { return nil }
        do {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .cpuAndNeuralEngine
            let compiled: URL
            if url.pathExtension == "mlmodelc" {
                compiled = url
            } else {
                compiled = try MLModel.compileModel(at: url)
            }
            model = try MLModel(contentsOf: compiled, configuration: cfg)
        } catch {
            model = nil
        }
        return model
        #endif
    }

    static func resourceURL() -> URL? {
        if let url = Bundle.module.url(forResource: "UniTS_AD", withExtension: "mlpackage") {
            return url
        }
        if let url = Bundle.main.url(forResource: "UniTS_AD", withExtension: "mlpackage", subdirectory: "Watchdog") {
            return url
        }
        return Bundle.main.url(forResource: "UniTS_AD", withExtension: "mlpackage")
    }

    /// Students require `present_mask` (1 = measured). Empty caller → all ones.
    static func attachPresentMask(dict: inout [String: MLFeatureValue], model: MLModel,
                                  presentMask: [[Double]]) {
        let names = ["present_mask", "mask", "missing_mask"]
        guard let name = names.first(where: { model.modelDescription.inputDescriptionsByName[$0] != nil })
        else { return }
        let seq = WatchdogConfig.seqLen
        let mask = presentMask.isEmpty ? Array(repeating: Array(repeating: 1.0, count: seq), count: 6) : presentMask
        guard let arr = try? cube(mask, channels: 6, seq: seq) else { return }
        dict[name] = MLFeatureValue(multiArray: arr)
    }

    static func vector(_ xs: [Double], shape: [NSNumber]) throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: shape, dataType: .float32)
        let n = xs.count
        for i in 0..<n {
            arr[i] = NSNumber(value: Float(xs[i]))
        }
        return arr
    }

    static func timeFeatures(_ rows: [[Double]]) throws -> MLMultiArray {
        let seq = WatchdogConfig.seqLen
        let f = WatchdogConfig.activityFeatureWidth
        let arr = try MLMultiArray(shape: [1, NSNumber(value: seq), NSNumber(value: f)], dataType: .float32)
        for t in 0..<seq {
            let row = t < rows.count ? rows[t] : []
            for k in 0..<f {
                let v = k < row.count ? row[k] : 0
                arr[[0, t, k] as [NSNumber]] = NSNumber(value: Float(v))
            }
        }
        return arr
    }

    static func cube(_ planes: [[Double]], channels: Int, seq: Int) throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: [1, NSNumber(value: channels), NSNumber(value: seq)], dataType: .float32)
        for c in 0..<channels {
            let row = c < planes.count ? planes[c] : []
            for t in 0..<seq {
                let v = t < row.count ? row[t] : 0
                arr[[0, c, t] as [NSNumber]] = NSNumber(value: Float(v))
            }
        }
        return arr
    }

    private static func planes(_ arr: MLMultiArray) -> [[Double]] {
        (0..<6).map { c in
            (0..<WatchdogConfig.seqLen).map { t in
                arr[[0, c, t] as [NSNumber]].doubleValue
            }
        }
    }
}
