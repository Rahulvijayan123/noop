import Foundation
import CoreML

/// Process-wide TimesFM-style forecast student. Inference only; never trained on device.
final class TimesFMStudentSession: @unchecked Sendable {
    static let shared = TimesFMStudentSession()

    private let lock = NSLock()
    private var model: MLModel?
    private var loadAttempted = false

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        _ = loadIfNeeded()
        return model != nil
    }

    func predict(history: [[Double]], prompt: [Double], occupancy: [Double],
                 presentMask: [[Double]] = []) -> [[Double]]? {
        lock.lock()
        defer { lock.unlock() }
        guard let model = loadIfNeeded() else { return nil }
        do {
            let hist = try UniTSCoreMLSession.cube(history, channels: 6, seq: WatchdogConfig.seqLen)
            let pr = try UniTSCoreMLSession.vector(prompt, shape: [1, 6])
            var occ = occupancy
            if occ.count < WatchdogConfig.seqLen {
                occ.append(contentsOf: Array(repeating: occ.last ?? 0, count: WatchdogConfig.seqLen - occ.count))
            }
            occ = Array(occ.prefix(WatchdogConfig.seqLen))
            let occArr = try UniTSCoreMLSession.vector(occ, shape: [1, NSNumber(value: WatchdogConfig.seqLen)])
            var dict: [String: MLFeatureValue] = [
                "history": MLFeatureValue(multiArray: hist),
                "prompt": MLFeatureValue(multiArray: pr),
                "occupancy": MLFeatureValue(multiArray: occArr)
            ]
            UniTSCoreMLSession.attachPresentMask(dict: &dict, model: model, presentMask: presentMask)
            let input = try MLDictionaryFeatureProvider(dictionary: dict)
            let out = try model.prediction(from: input)
            guard let arr = out.featureValue(for: "forecast")?.multiArrayValue else { return nil }
            return Self.forecastPlanes(arr)
        } catch {
            return nil
        }
    }

    private func loadIfNeeded() -> MLModel? {
        if loadAttempted { return model }
        loadAttempted = true
        #if os(watchOS)
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
        if let url = Bundle.module.url(forResource: "TimesFM3_Student", withExtension: "mlpackage") {
            return url
        }
        if let url = Bundle.main.url(forResource: "TimesFM3_Student", withExtension: "mlpackage", subdirectory: "Watchdog") {
            return url
        }
        return Bundle.main.url(forResource: "TimesFM3_Student", withExtension: "mlpackage")
    }

    private static func forecastPlanes(_ arr: MLMultiArray) -> [[Double]] {
        let horizon = WatchdogCalibration.forecastHorizon
        return (0..<6).map { c in
            (0..<horizon).map { t in
                arr[[0, c, t] as [NSNumber]].doubleValue
            }
        }
    }
}
