import Foundation

/// Read-only usual prompt. Never written back into Layer 1.
public struct UniTSPrompt: Equatable, Sendable {
    public var hr: Double?
    public var rhr: Double?
    public var hrv: Double?
    /// Established awake-rest HRV (ms). Never averaged with sleep. Nil unless that copy is shown.
    public var hrvAwake: Double?
    /// `hrv` came from overnight sleep HRV. No sleep÷wake multiplier; live rest stays that sleep usual until a shown awake copy exists.
    public var hrvAnchoredInSleep: Bool
    public var source: WatchdogPromptSource
    public var temp: Double?
    public var resp: Double?
    public var spo2: Double?
    /// Personal residual scale in native units (Layer 1 display MAD). Floors apply in `UniTSRuntime`.
    public var scaleHR: Double
    public var scaleRHR: Double
    public var scaleHRV: Double
    public var scaleTemp: Double
    public var scaleResp: Double
    public var scaleSpO2: Double

    public init(hr: Double? = nil, rhr: Double? = nil, hrv: Double? = nil,
                hrvAwake: Double? = nil, hrvAnchoredInSleep: Bool = false,
                source: WatchdogPromptSource = .awakeRest,
                temp: Double? = nil, resp: Double? = nil, spo2: Double? = nil,
                scaleHR: Double = WatchdogConfig.hrScale,
                scaleRHR: Double = WatchdogConfig.hrScale,
                scaleHRV: Double = WatchdogConfig.hrvScale,
                scaleTemp: Double = WatchdogConfig.tempScale,
                scaleResp: Double = WatchdogConfig.respScale,
                scaleSpO2: Double = WatchdogConfig.spo2Scale) {
        self.hr = hr
        self.rhr = rhr
        self.hrv = hrv
        self.hrvAwake = hrvAwake
        self.hrvAnchoredInSleep = hrvAnchoredInSleep
        self.source = source
        self.temp = temp
        self.resp = resp
        self.spo2 = spo2
        self.scaleHR = scaleHR
        self.scaleRHR = scaleRHR
        self.scaleHRV = scaleHRV
        self.scaleTemp = scaleTemp
        self.scaleResp = scaleResp
        self.scaleSpO2 = scaleSpO2
    }

    /// One Layer 1 copy for both hat and TRUST. Long wins if shown; else week. Held copies older than 7 days are not current.
    public static func shownCopy(_ ev: LBEvaluation) -> (center: Double, trust: Int)? {
        func accept(_ copy: LBCopySnapshot?, trust: Int, show: Bool) -> (Double, Int)? {
            guard show, let copy, trust >= LongitudinalBaseline.trustHideThreshold else { return nil }
            if copy.held, !heldFresh(lastUpdate: copy.lastUpdate, asOf: ev.asOf) { return nil }
            return (copy.centerDisplay, trust)
        }
        if let long = accept(ev.copyLong, trust: ev.usualTrustPctLong, show: ev.showLong) { return long }
        if let week = accept(ev.copy7, trust: ev.usualTrustPct7, show: ev.show7) { return week }
        return nil
    }

    static func heldFresh(lastUpdate: String?, asOf: String) -> Bool {
        guard let lastUpdate else { return false }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        guard let a = f.date(from: String(asOf.prefix(10))),
              let b = f.date(from: String(lastUpdate.prefix(10))) else { return false }
        return abs(a.timeIntervalSince(b)) <= 7 * 86400
    }

    public static func from(evaluations: [LBEvaluation]) -> UniTSPrompt {
        func center(_ series: LBSeries) -> Double? {
            guard let ev = evaluations.first(where: { $0.series == series }) else { return nil }
            if let shown = shownCopy(ev) { return shown.center }
            guard let copy = ev.copyLong ?? ev.copy7 else { return nil }
            if copy.held, !heldFresh(lastUpdate: copy.lastUpdate, asOf: ev.asOf) { return nil }
            return copy.centerDisplay
        }
        func shownCenter(_ series: LBSeries) -> Double? {
            guard let ev = evaluations.first(where: { $0.series == series }) else { return nil }
            return shownCopy(ev)?.center
        }
        let sleepHRV = center(.sleepHRVLn)
        let awakeHRV = shownCenter(.awakeRestHRVLn)
        // Sleep HRV / sleep SpO₂ usuals are 24-hour: live daytime minutes still compare to
        // those recorded overnight copies. They are not wiped just because it is wake.
        // Instant HR usual is daytime rest / all-day HR. Sleep RHR never fills this slot.
        let hr = shownCenter(.awakeRestHR) ?? shownCenter(.continuousHR)
        // Still RHR usual is overnight / still-gated only. Daytime HR never fills this slot.
        let rhr = shownCenter(.sleepRHR) ?? center(.sleepRHR)
        let source: WatchdogPromptSource
        if hr == nil && rhr == nil && sleepHRV == nil {
            source = .population
        } else if hr != nil && rhr != nil {
            source = .mixed
        } else if hr != nil {
            source = .awakeRest
        } else {
            source = .sleep
        }
        return UniTSPrompt(
            hr: hr,
            rhr: rhr,
            hrv: sleepHRV,
            hrvAwake: awakeHRV,
            hrvAnchoredInSleep: sleepHRV != nil && awakeHRV == nil,
            source: source,
            temp: center(.sleepTemp),
            resp: center(.sleepResp),
            spo2: center(.sleepSpO2Mean),
            scaleHR: displayMAD(evaluations, .awakeRestHR, shownOnly: true)
                ?? displayMAD(evaluations, .continuousHR, shownOnly: true)
                ?? WatchdogConfig.hrScale,
            scaleRHR: displayMAD(evaluations, .sleepRHR, shownOnly: false)
                ?? WatchdogConfig.hrScale,
            scaleHRV: (awakeHRV != nil ? displayMAD(evaluations, .awakeRestHRVLn, shownOnly: true) : nil)
                ?? displayMAD(evaluations, .sleepHRVLn, shownOnly: false)
                ?? WatchdogConfig.hrvScale,
            scaleTemp: displayMAD(evaluations, .sleepTemp, shownOnly: false) ?? WatchdogConfig.tempScale,
            scaleResp: displayMAD(evaluations, .sleepResp, shownOnly: false) ?? WatchdogConfig.respScale,
            scaleSpO2: displayMAD(evaluations, .sleepSpO2Mean, shownOnly: false) ?? WatchdogConfig.spo2Scale
        )
    }

    /// Half the Layer 1 usual band in display units, divided by k → 1 MAD. Same copy as the prompt; never averaged.
    static func displayMAD(_ evaluations: [LBEvaluation], _ series: LBSeries, shownOnly: Bool) -> Double? {
        guard let ev = evaluations.first(where: { $0.series == series }) else { return nil }
        if shownOnly {
            guard shownCopy(ev) != nil else { return nil }
        }
        let copy: LBCopySnapshot?
        if ev.showLong, let c = ev.copyLong, shownCopy(ev)?.trust == ev.usualTrustPctLong {
            copy = c
        } else if ev.show7 {
            copy = ev.copy7
        } else {
            copy = ev.copyLong ?? ev.copy7
        }
        guard let copy else { return nil }
        let half = max(copy.bandHiDisplay - copy.centerDisplay, copy.centerDisplay - copy.bandLoDisplay)
        let k = max(ev.kBandUsed, 1)
        let mad = half / k
        return mad.isFinite && mad > 0 ? mad : nil
    }
}

public struct UniTSResidual: Equatable, Sendable {
    public var energy: [WatchdogWindow.Channel: Double]
    public var rangeHalf: [WatchdogWindow.Channel: Double]
    /// Per-minute predicted half-width around \(\hat{x}_t\) (native units).
    public var scaleHR: [Double]
    public var scaleRHR: [Double]
    public var scaleHRV: [Double]
    public var scaleTemp: [Double]
    public var scaleResp: [Double]
    public var scaleSpO2: [Double]
    public var reconstructedHR: [Double?]
    public var reconstructedRHR: [Double?]
    public var reconstructedHRV: [Double?]
    public var reconstructedTemp: [Double?]
    public var reconstructedResp: [Double?]
    public var reconstructedSpO2: [Double?]
    public var modelVersion: String
    public var jointEnergy: Double

    public func energy(for channel: WatchdogWindow.Channel) -> Double {
        energy[channel] ?? 0
    }

    public func rangeHalf(for channel: WatchdogWindow.Channel) -> Double {
        rangeHalf[channel] ?? 0
    }

    public func scale(for channel: WatchdogWindow.Channel) -> [Double] {
        switch channel {
        case .hr: return scaleHR
        case .rhr: return scaleRHR
        case .hrv: return scaleHRV
        case .temp: return scaleTemp
        case .resp: return scaleResp
        case .spo2: return scaleSpO2
        case .motion: return []
        }
    }
}

/// Shared scoring / painting helpers for the Watchdog's baseline expectation (`WatchdogExpectation`).
/// Historically this file held an on-device "UniTS" student and a physics prior; both are removed — the phone
/// never imitates a model. The real UniTS / TimesFM run on the VPS (`Tools/AnomalyService`).
public struct UniTSRuntime: Sendable {
    public init() {}

    /// Painted half-width per channel = the reference's own per-minute spread (no motion-coupled widening:
    /// that was part of the removed physics prior).
    public static func paintRanges(residual: UniTSResidual)
    -> (hr: [Double], rhr: [Double], hrv: [Double], temp: [Double], resp: [Double], spo2: [Double]) {
        (residual.scaleHR, residual.scaleRHR, residual.scaleHRV, residual.scaleTemp, residual.scaleResp,
         residual.scaleSpO2)
    }

    /// Last minute where both a measurement and an expectation exist.
    static func lastPaired(_ observed: [Double?], _ hat: [Double?],
                           from index: Int = 0) -> (obs: Double, hat: Double)? {
        let n = min(observed.count, hat.count)
        let lo = min(max(0, index), n)
        guard n > lo else { return nil }
        for i in stride(from: n - 1, through: lo, by: -1) {
            if let o = observed[i], let h = hat[i] { return (obs: o, hat: h) }
        }
        return nil
    }

    /// Predicted half-width around \(\hat{x}_t\): max(floor, Layer 1 MAD, reconstructor SNR × |hat|,
    /// occupancy coefficient uncertainty). Never this window’s residual scatter.
    /// Location vs the expectation. `predicted` is the per-minute reference scale; if nil, scale is
    /// max(floor, personal) only (unit tests of the energy formula).
    static func score(_ observed: [Double?], _ hat: [Double?],
                      floor: Double, personal: Double,
                      predicted: [Double]? = nil) -> (energy: Double, rangeHalf: Double) {
        var weighted: [Double] = []
        weighted.reserveCapacity(observed.count)
        var lastAbs = 0.0
        var lastScale = max(floor, personal)
        var havePair = false
        for i in 0..<observed.count {
            guard i < hat.count, let o = observed[i], let h = hat[i] else { continue }
            let predictedI = predicted.flatMap { i < $0.count ? $0[i] : nil } ?? 0
            let scale = max(floor, personal, predictedI)
            guard scale > 0 else { continue }
            weighted.append((o - h) / scale)
            lastAbs = abs(o - h)
            lastScale = scale
            havePair = true
        }
        guard havePair, lastScale > 0 else { return (0, max(floor, personal)) }
        let loc = median(weighted) ?? 0
        let now = lastAbs / lastScale
        return (max(abs(loc), now), lastScale)
    }

    static func median(_ xs: [Double]) -> Double? {
        let s = xs.sorted()
        guard !s.isEmpty else { return nil }
        let m = s.count / 2
        if s.count % 2 == 1 { return s[m] }
        return (s[m - 1] + s[m]) / 2
    }
}
