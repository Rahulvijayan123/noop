import Foundation

/// Equal-weight signed direction of the six vitals. No channel is privileged.
///
/// `joint` is the tanh × breadth **label** fold (capped at 2.0). Severity uses
/// `severityJoint` — a clipped sum that can pass `tSevere` (2.4) when several
/// distinct vitals are off.
public struct WatchdogDirectionResult: Equatable, Sendable {
    public var d: [Double]
    public var mask: [Bool]
    public var weights: [Double]
    public var rms: Double
    public var breadth: Double
    public var joint: Double
    /// Σ min(|r_k|, 1.0) over present vitals except RHR. Compared to tNote / tActive / tSevere.
    public var severityJoint: Double
    public var marks: [String]

    public static let empty = WatchdogDirectionResult(
        d: Array(repeating: 0, count: 6),
        mask: Array(repeating: false, count: 6),
        weights: Array(repeating: 0, count: 6),
        rms: 0, breadth: 0, joint: 0, severityJoint: 0,
        marks: Array(repeating: "·", count: 6)
    )
}

public enum WatchdogDirection: Sendable {
    public static let channelCount = 6
    public static let soft = 0.40
    public static let beta = 1.0
    public static let ema = 0.5
    public static let names = ["HR", "RHR", "HRV", "Temp", "Resp", "SpO2"]

    /// `rawR[k]` is signed residual or nil if absent. `rhrAllowed` false masks RHR.
    public static func compute(rawR: [Double?], rhrAllowed: Bool, artifact: Bool,
                               dirEma: inout [Double]) -> WatchdogDirectionResult {
        var r = rawR
        if r.count < channelCount { r.append(contentsOf: Array(repeating: nil, count: channelCount - r.count)) }
        if dirEma.count < channelCount { dirEma.append(contentsOf: Array(repeating: 0.0, count: channelCount - dirEma.count)) }
        var mask = [Bool](repeating: false, count: channelCount)
        var d = [Double](repeating: 0, count: channelCount)
        for k in 0..<channelCount {
            if k == 1 && !rhrAllowed { continue }
            guard let rk = r[k], rk.isFinite else { continue }
            mask[k] = true
            dirEma[k] = ema * dirEma[k] + (1 - ema) * rk
            d[k] = tanh(dirEma[k])
        }
        let n = mask.filter { $0 }.count
        var w = [Double](repeating: 0, count: channelCount)
        guard n > 0 else { return .empty }
        let inv = 1.0 / Double(n)
        for k in 0..<channelCount where mask[k] { w[k] = inv }
        var meanSq = 0.0
        var breadth = 0.0
        var marks = [String](repeating: "·", count: channelCount)
        for k in 0..<channelCount where mask[k] {
            meanSq += w[k] * d[k] * d[k]
            if abs(d[k]) >= soft {
                breadth += w[k]
                marks[k] = d[k] > 0 ? "↑" : "↓"
            }
        }
        let D = sqrt(max(0, meanSq))
        var J = D * (1 + beta * breadth)
        if artifact { J *= 0.72 }
        var absR = [Double](repeating: 0, count: channelCount)
        for k in 0..<channelCount where mask[k] {
            absR[k] = abs(r[k] ?? 0)
        }
        let severityJ = WatchdogScores.severityJoint(absR: absR, mask: mask, artifact: artifact)
        return WatchdogDirectionResult(d: d, mask: mask, weights: w, rms: D, breadth: breadth,
                                       joint: J, severityJoint: severityJ, marks: marks)
    }

    public static func signedR(obs: Double?, hat: Double?, scale: Double) -> Double? {
        guard let obs, let hat, obs.isFinite, hat.isFinite else { return nil }
        return (obs - hat) / max(scale, 0.01)
    }
}
