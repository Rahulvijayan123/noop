import Foundation

/// A motion-heads row's windows as the server stores them (`mh-col-1`, written by the worker's
/// `ActivityMotionHeadsDays.compact`): per window its start, the OOD flag, the movement intensity in percent and, per
/// head, the index of its top class in the bundle's supported-class order with that class's probability in percent.
///
/// The format keeps only the top class of each head, so the windows read back here carry exactly that: the top class
/// at its stored probability and the rest of the mass spread over the other supported classes in proportion to the
/// bundle's calibration prior, so they say nothing about how those classes compare with each other. A transition
/// event other than the top one reads at its prior (never above the top event). Every window passes
/// `MotionHeadsWindow.validate(against:)` for the bundle, or the whole object is refused.
public struct MotionHeadsColumns: Equatable, Sendable {
    public static let format = "mh-col-1"

    public var bundle: MotionHeadsBundleInfo
    /// In time order (strictly increasing starts).
    public var windows: [MotionHeadsWindow]

    /// nil for anything that is not a well-formed `mh-col-1` object for `bundle`: another format or window length,
    /// a column of the wrong length, a class index outside the head's supported classes, a head the bundle does not
    /// support (or a supported one missing), starts that do not increase.
    public init?(_ object: Any?, bundle: MotionHeadsBundleInfo) {
        guard let o = object as? [String: Any], o["format"] as? String == Self.format,
              let n = Self.int(o["n"]), let w = Self.int(o["w"]), n >= 0, w == bundle.windowS else { return nil }
        func column(_ value: Any?) -> [Int]? {
            guard let a = value as? [Any], a.count == n else { return nil }
            let ints = a.compactMap(Self.int)
            return ints.count == n ? ints : nil
        }
        guard let ds = column(o["ds"]), let x = column(o["x"]), let mi = column(o["mi"]),
              let rawHeads = o["heads"] as? [String: Any] else { return nil }
        let carried = MotionHead.allCases.filter { !(bundle.heads[$0]?.supportedClasses ?? []).isEmpty }
        guard Set(rawHeads.keys) == Set(carried.map(\.rawValue)) else { return nil }
        var heads: [(head: MotionHead, classes: [String], prior: [String: Double], i: [Int], p: [Int])] = []
        for head in carried {
            guard let spec = bundle.heads[head], let h = rawHeads[head.rawValue] as? [String: Any],
                  let i = column(h["i"]), let p = column(h["p"]) else { return nil }
            heads.append((head, spec.supportedClasses, spec.prior, i, p))
        }
        var out: [MotionHeadsWindow] = []
        out.reserveCapacity(n)
        if n > 0 {
            guard var start = Self.int(o["s0"]), start >= 0, ds[0] == 0 else { return nil }
            for k in 0..<n {
                if k > 0 {
                    guard ds[k] > 0 else { return nil }
                    start += ds[k]
                }
                guard x[k] == 0 || x[k] == 1, mi[k] >= -1, mi[k] <= 100 else { return nil }
                var window = MotionHeadsWindow(startTs: start, endTs: start + w,
                                               movementIntensity: mi[k] < 0 ? nil : Double(mi[k]) / 100,
                                               isOOD: x[k] == 1)
                for h in heads {
                    let index = h.i[k]
                    guard index >= -1, index < h.classes.count, (0...100).contains(h.p[k]) else { return nil }
                    guard index >= 0 else { continue }
                    window.setProbabilities(h.head, Self.distribution(head: h.head, classes: h.classes, prior: h.prior,
                                                                      top: h.classes[index],
                                                                      p: Double(h.p[k]) / 100))
                }
                guard (try? window.validate(against: bundle, index: k)) != nil else { return nil }
                out.append(window)
            }
        }
        self.bundle = bundle
        self.windows = out
    }

    /// The windows that END inside `[from, to)`, as the activity decoder reads them.
    public func trackWindows(from: Int, to: Int) -> [MotionHeadsWindow] {
        windows.filter { $0.endTs >= from && $0.endTs < to }
    }

    static func distribution(head: MotionHead, classes: [String], prior: [String: Double], top: String,
                             p: Double) -> [String: Double] {
        var out: [String: Double] = [top: p]
        let others = classes.filter { $0 != top }
        guard head.isCategorical else {
            for c in others { out[c] = min(prior[c] ?? 0, p) }
            return out
        }
        guard !others.isEmpty else { return [top: 1] }
        let mass = others.reduce(0.0) { $0 + (prior[$1] ?? 0) }
        for c in others {
            out[c] = mass > 0 ? (1 - p) * (prior[c] ?? 0) / mass : (1 - p) / Double(others.count)
        }
        return out
    }

    private static func int(_ value: Any?) -> Int? {
        guard let d = (value as? NSNumber)?.doubleValue else { return nil }
        guard d.isFinite, d == d.rounded(), abs(d) < 9e15 else { return nil }
        return Int(exactly: d)
    }
}
