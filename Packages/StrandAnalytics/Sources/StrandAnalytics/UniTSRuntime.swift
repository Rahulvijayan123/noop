import Foundation

/// Read-only usual prompt. Never written back into Layer 1.
public struct UniTSPrompt: Equatable, Sendable {
    public var hr: Double?
    public var rhr: Double?
    public var hrv: Double?
    /// Established awake-rest HRV (ms). Never averaged with sleep. Nil unless that copy is shown.
    public var hrvAwake: Double?
    /// `hrv` came from overnight sleep HRV and no awake-rest copy is shown. Live AWAKE minutes are then compared
    /// to `daytimeHRV`, the EXPLICIT sleep-scaled fallback (D4-08), with a wider relative sigma (unscaled sleep MAD
    /// on a 0.65x centre, plus the cold-start widening); never silently the sleep usual. Sleep-phase minutes use `hrv`.
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
    /// The tick is in the SLEEP phase (D4-08). Sleep-phase minutes compare to the overnight usual (`hrv`) with its
    /// own MAD; only awake minutes use the `daytimeHRV` fallback. `UniTSRuntime.reconstruct` also sets this from
    /// the window (a bound sleep interval open at `nowUnix`), so a caller that does not set it is still phased.
    public var sleepPhase: Bool

    public init(hr: Double? = nil, rhr: Double? = nil, hrv: Double? = nil,
                hrvAwake: Double? = nil, hrvAnchoredInSleep: Bool = false,
                source: WatchdogPromptSource = .awakeRest,
                temp: Double? = nil, resp: Double? = nil, spo2: Double? = nil,
                scaleHR: Double = WatchdogConfig.hrScale,
                scaleRHR: Double = WatchdogConfig.hrScale,
                scaleHRV: Double = WatchdogConfig.hrvScale,
                scaleTemp: Double = WatchdogConfig.tempScale,
                scaleResp: Double = WatchdogConfig.respScale,
                scaleSpO2: Double = WatchdogConfig.spo2Scale,
                sleepPhase: Bool = false) {
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
        self.sleepPhase = sleepPhase
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
        // Sleep SpO₂ usual is 24-hour: live daytime minutes still compare to the overnight copy. Sleep HRV
        // is carried as `hrv` but a daytime minute reads it only through `daytimeHRV` (sleep-scaled,
        // flagged, widened sigma) until an awake-rest copy is shown (D4-08).
        // Instant HR usual is daytime REST HR only. Sleep RHR never fills this slot, and neither does the
        // continuous (24-h, sleep + effort minutes) mean: with no awake-rest copy the slot stays nil, so
        // the population prior and the cold-start (widened) HR sigma apply instead (D4-08).
        let hr = shownCenter(.awakeRestHR)
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
                ?? WatchdogConfig.hrScale,
            scaleRHR: displayMAD(evaluations, .sleepRHR, shownOnly: false)
                ?? WatchdogConfig.hrScale,
            // The sleep MAD is carried UNSCALED in ms. In the sleep phase it is the overnight usual's own
            // dispersion; on an awake tick it rides the 0.65x fallback centre, which makes it ~1.5x wider in
            // relative terms (the intended widening for an unestablished regime), on top of the cold-start sigma.
            scaleHRV: (awakeHRV != nil ? displayMAD(evaluations, .awakeRestHRVLn, shownOnly: true) : nil)
                ?? displayMAD(evaluations, .sleepHRVLn, shownOnly: false)
                ?? WatchdogConfig.hrvScale,
            scaleTemp: displayMAD(evaluations, .sleepTemp, shownOnly: false) ?? WatchdogConfig.tempScale,
            scaleResp: displayMAD(evaluations, .sleepResp, shownOnly: false) ?? WatchdogConfig.respScale,
            scaleSpO2: displayMAD(evaluations, .sleepSpO2Mean, shownOnly: false) ?? WatchdogConfig.spo2Scale
        )
    }

    /// Population awake-rest ÷ overnight RMSSD ratio for the explicit daytime-HRV fallback (D4-08). A seated
    /// daytime RMSSD runs well below the overnight (recumbent, vagally dominant) value, so comparing a daytime
    /// minute with the sleep usual itself reads a persistent, stress-like deficit. TUNING SEAM: a population
    /// prior (~0.6-0.7), used ONLY until the person's own awake-rest copy is shown.
    public static let awakeToSleepHRVRatio: Double = 0.65

    /// The HRV a live daytime minute is compared against: the shown awake-rest usual; else the SLEEP usual
    /// scaled by `awakeToSleepHRVRatio` (an explicit, flagged fallback: `daytimeHRVFallbackUsed`, and the HRV
    /// sigma is widened via `hrvAnchoredInSleep`); else nil (the population prior applies).
    public var daytimeHRV: Double? {
        hrvAwake ?? hrv.map { $0 * Self.awakeToSleepHRVRatio }
    }

    /// True when `daytimeHRV` is the sleep-scaled fallback rather than an awake-rest usual (provenance).
    public var daytimeHRVFallbackUsed: Bool { hrvAwake == nil && hrv != nil }

    /// The phase-correct HRV centre for THIS tick: the overnight usual in the sleep phase (the awake usual only if
    /// no sleep copy exists, as before); `daytimeHRV` on an awake tick. Every UniTS HRV seed / fill / coupling base
    /// reads this, never `daytimeHRV` directly, so a sleeping RMSSD is never judged against the 0.65x daytime centre.
    public var hrvCentre: Double? {
        sleepPhase ? (hrv ?? hrvAwake) : daytimeHRV
    }

    /// True when this tick's HRV centre is the sleep-scaled daytime fallback (awake tick, no awake-rest copy).
    public var hrvCentreFallbackUsed: Bool { !sleepPhase && daytimeHRVFallbackUsed }

    /// Copy with `sleepPhase` set when either the caller or the window says the tick is asleep.
    func phased(_ window: WatchdogWindow) -> UniTSPrompt {
        guard !sleepPhase, UniTSRuntime.windowInSleep(window) else { return self }
        var p = self
        p.sleepPhase = true
        return p
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
    /// The residual was built for a sleep-phase tick (see `UniTSPrompt.sleepPhase`); `paintRanges` re-phases from it.
    public var sleepPhase: Bool = false

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

/// Per-vital reconstruction (UniTS AD job). Frozen physiological priors, no on-device training.
/// Each channel has its own coupling to motion / time; they are never one shared slope.
public struct UniTSRuntime: Sendable {
    public init() {}

    public func reconstruct(_ window: WatchdogWindow, prompt: UniTSPrompt,
                            tail: WatchdogLiveTail? = nil) throws -> UniTSResidual {
        let prompt = prompt.phased(window)
        let live = tail ?? WatchdogLiveTail.resolve(window)
        let features = window.resolvedActivityFeatures()
        let occ = live.clipEffortOccupancy(Self.physiologyOccupancy(window, features: features))
        if let residual = Self.coreMLResidual(window: window, prompt: prompt,
                                              occupancy: occ, activity: features, tail: live) {
            return residual
        }
        return Self.priorResidual(window: window, prompt: prompt, occupancy: occ, tail: live)
    }

    /// Core ML UniTS-AD checkpoint: both \(\hat{x}\) and \(\sigma\) come from one inference.
    static func coreMLResidual(window: WatchdogWindow, prompt: UniTSPrompt, occupancy: [Double],
                               activity: [[Double]] = [],
                               tail: WatchdogLiveTail? = nil) -> UniTSResidual? {
        let bases = resolvedBases(window: window, prompt: prompt)
        let personal = [prompt.scaleHR, prompt.scaleRHR, prompt.scaleHRV,
                        prompt.scaleTemp, prompt.scaleResp, prompt.scaleSpO2]
        var occ = occupancy
        if occ.count < WatchdogConfig.seqLen {
            occ.append(contentsOf: Array(repeating: occ.last ?? 0, count: WatchdogConfig.seqLen - occ.count))
        }
        if occ.count > WatchdogConfig.seqLen { occ = Array(occ.prefix(WatchdogConfig.seqLen)) }
        let pred = UniTSCoreMLSession.shared.predict(
            occupancy: occ,
            prompt: bases.map { $0 ?? 0 },
            personalScale: personal,
            observed: packObserved(window, bases: bases),
            activity: activity,
            presentMask: packPresentMask(window)
        )
        guard let pred else { return nil }
        func hat(_ channel: Int, valid: Bool) -> [Double?] {
            guard valid, channel < pred.hat.count else {
                return Array(repeating: nil, count: WatchdogConfig.seqLen)
            }
            return pred.hat[channel].map { Optional($0) }
        }
        func scale(_ channel: Int) -> [Double] {
            guard channel < pred.sigma.count else {
                return Array(repeating: personal[channel], count: WatchdogConfig.seqLen)
            }
            return pred.sigma[channel]
        }
        let modelHR = hat(0, valid: bases[0] != nil)
        let priorHR = reconstructHR(observed: window.hr, prompt: prompt.hr, occupancy: occupancy)
        let hatHR = liveHrHat(model: modelHR, prior: priorHR, observed: window.hr)
        let modelRHR = hat(1, valid: bases[1] != nil)
        let priorRHR = reconstructRHR(observed: window.rhr, prompt: prompt.rhr)
        let hatRHR = liveHrHat(model: modelRHR, prior: priorRHR, observed: window.rhr)
        let modelHRV = hat(2, valid: bases[2] != nil)
        let priorHRV = reconstructHRV(observed: window.hrv, prompt: prompt, occupancy: occupancy)
        let hatHRV = liveHrvHat(model: modelHRV, prior: priorHRV, observed: window.hrv)
        let modelTemp = hat(3, valid: bases[3] != nil)
        let priorTemp = reconstructTemp(observed: window.temp, prompt: prompt.temp, occupancy: occupancy)
        let hatTemp = liveTempHat(model: modelTemp, prior: priorTemp, observed: window.temp)
        let hatResp = hat(4, valid: bases[4] != nil)
        let hatSpO2 = hat(5, valid: bases[5] != nil)
        return finishResidual(
            window: window, prompt: prompt,
            hatHR: hatHR, hatRHR: hatRHR, hatHRV: hatHRV,
            hatTemp: hatTemp, hatResp: hatResp, hatSpO2: hatSpO2,
            scaleHR: scale(0), scaleRHR: scale(1), scaleHRV: scale(2),
            scaleTemp: scale(3), scaleResp: scale(4), scaleSpO2: scale(5),
            modelVersion: WatchdogConfig.modelVersion,
            tail: tail
        )
    }

    static func priorResidual(window: WatchdogWindow, prompt: UniTSPrompt, occupancy: [Double],
                              tail: WatchdogLiveTail? = nil) -> UniTSResidual {
        physicsResidual(window: window, prompt: prompt, occupancy: occupancy, tail: tail)
    }

    /// Physics prior used as Core ML input / load-fail fallback. Not the v2 detector.
    static func physicsResidual(window: WatchdogWindow, prompt: UniTSPrompt, occupancy: [Double],
                                tail: WatchdogLiveTail? = nil) -> UniTSResidual {
        let prompt = prompt.phased(window)
        let hatHR = reconstructHR(observed: window.hr, prompt: prompt.hr, occupancy: occupancy)
        let hatRHR = reconstructRHR(observed: window.rhr, prompt: prompt.rhr)
        let hatHRV = reconstructHRV(observed: window.hrv, prompt: prompt, occupancy: occupancy)
        let hatTemp = reconstructTemp(observed: window.temp, prompt: prompt.temp, occupancy: occupancy)
        let hatResp = reconstructResp(observed: window.resp, prompt: prompt.resp, occupancy: occupancy)
        let hatSpO2 = reconstructSpO2(observed: window.spo2, prompt: prompt.spo2, occupancy: occupancy)

        let hrBase = prompt.hr ?? WatchdogPopulationPriors.hr
        let hrvBase = prompt.hrvCentre ?? WatchdogPopulationPriors.hrv
        let respBase = prompt.resp ?? WatchdogPopulationPriors.resp
        let hrSmooth = trailingMean(occupancy, taps: WatchdogConfig.hrMotionSmoothMinutes)
        let hrvSmooth = trailingMean(occupancy, taps: WatchdogConfig.hrvMotionSmoothMinutes)
        let tempLag = trailingMean(occupancy, taps: WatchdogConfig.tempLagMinutes)
        let respSmooth = trailingMean(occupancy, taps: WatchdogConfig.respSmoothMinutes)

        let scaleHR = predictedScale(
            hat: hatHR, floor: WatchdogConfig.hrScale, personal: prompt.scaleHR,
            reconFraction: WatchdogConfig.hrReconFraction,
            coupling: hrSmooth.map { WatchdogConfig.hrEffortUncert * hrBase * pow(max(0, $0), WatchdogConfig.hrMotionPower) })
        let scaleRHR = predictedScale(
            hat: hatRHR, floor: WatchdogConfig.hrScale, personal: prompt.scaleRHR,
            reconFraction: WatchdogConfig.rhrReconFraction,
            coupling: Array(repeating: 0, count: hatRHR.count))
        let scaleHRV = predictedScale(
            hat: hatHRV, floor: WatchdogConfig.hrvScale, personal: prompt.scaleHRV,
            reconFraction: WatchdogConfig.hrvReconFraction,
            coupling: hrvSmooth.map { WatchdogConfig.hrvDropUncertMs * $0 * (hrvBase / WatchdogConfig.hrvDropRefMs) })
        let scaleTemp = predictedScale(
            hat: hatTemp, floor: WatchdogConfig.tempScale, personal: prompt.scaleTemp,
            reconFraction: WatchdogConfig.tempReconFraction,
            coupling: tempLag.map { WatchdogConfig.tempGainUncert * $0 })
        let scaleResp = predictedScale(
            hat: hatResp, floor: WatchdogConfig.respScale, personal: prompt.scaleResp,
            reconFraction: WatchdogConfig.respReconFraction,
            coupling: respSmooth.map { WatchdogConfig.respEffortUncert * respBase * pow(max(0, $0), WatchdogConfig.respMotionPower) })
        let scaleSpO2 = predictedScale(
            hat: hatSpO2, floor: WatchdogConfig.spo2Scale, personal: prompt.scaleSpO2,
            reconFraction: WatchdogConfig.spo2ReconFraction,
            coupling: Array(repeating: 0, count: hatSpO2.count))
        return finishResidual(
            window: window, prompt: prompt,
            hatHR: hatHR, hatRHR: hatRHR, hatHRV: hatHRV,
            hatTemp: hatTemp, hatResp: hatResp, hatSpO2: hatSpO2,
            scaleHR: scaleHR, scaleRHR: scaleRHR, scaleHRV: scaleHRV,
            scaleTemp: scaleTemp, scaleResp: scaleResp, scaleSpO2: scaleSpO2,
            modelVersion: WatchdogConfig.fallbackModelVersion,
            tail: tail
        )
    }

    /// A bound sleep interval is open at the window's `nowUnix` (the Watchdog's `sleepNow` interval test).
    static func windowInSleep(_ window: WatchdogWindow) -> Bool {
        window.sleepIntervals.contains { $0.contains(window.nowUnix) }
    }

    static func resolvedBases(window: WatchdogWindow, prompt: UniTSPrompt) -> [Double?] {
        let prompt = prompt.phased(window)
        return [
            prompt.hr ?? WatchdogPopulationPriors.hr,
            prompt.rhr ?? WatchdogPopulationPriors.rhr,
            prompt.hrvCentre ?? WatchdogPopulationPriors.hrv,
            prompt.temp ?? WatchdogPopulationPriors.temp,
            prompt.resp ?? WatchdogPopulationPriors.resp,
            prompt.spo2 ?? WatchdogPopulationPriors.spo2
        ]
    }

    static func packObserved(_ window: WatchdogWindow, bases: [Double?]) -> [[Double]] {
        func fill(_ xs: [Double?], _ base: Double?) -> [Double] {
            let seed = base ?? 0
            return (0..<WatchdogConfig.seqLen).map { i in
                if i < xs.count, let v = xs[i] { return v }
                return seed
            }
        }
        return [
            fill(window.hr, bases[0]),
            fill(window.rhr, bases[1]),
            fill(window.hrv, bases[2]),
            fill(window.temp, bases[3]),
            fill(window.resp, bases[4]),
            fill(window.spo2, bases[5])
        ]
    }

    /// 1 = measured minute. Required on student Core ML (`present_mask`); holes stay prompt-filled.
    static func packPresentMask(_ window: WatchdogWindow) -> [[Double]] {
        func mask(_ xs: [Double?]) -> [Double] {
            (0..<WatchdogConfig.seqLen).map { i in
                (i < xs.count && xs[i] != nil) ? 1 : 0
            }
        }
        return [mask(window.hr), mask(window.rhr), mask(window.hrv),
                mask(window.temp), mask(window.resp), mask(window.spo2)]
    }

    static func finishResidual(window: WatchdogWindow, prompt: UniTSPrompt,
                               hatHR: [Double?], hatRHR: [Double?], hatHRV: [Double?],
                               hatTemp: [Double?], hatResp: [Double?], hatSpO2: [Double?],
                               scaleHR: [Double], scaleRHR: [Double], scaleHRV: [Double],
                               scaleTemp: [Double], scaleResp: [Double], scaleSpO2: [Double],
                               modelVersion: String,
                               tail: WatchdogLiveTail? = nil) -> UniTSResidual {
        let live = tail ?? WatchdogLiveTail.resolve(window)
        let sHR = WatchdogCalibration.applySigma(scaleHR, channel: .hr, coldStart: prompt.hr == nil)
        let sRHR = WatchdogCalibration.applySigma(scaleRHR, channel: .rhr, coldStart: prompt.rhr == nil)
        let sHRV = WatchdogCalibration.applySigma(scaleHRV, channel: .hrv,
                                                 coldStart: prompt.source == .population || prompt.hrvAnchoredInSleep)
        let sTemp = WatchdogCalibration.applySigma(scaleTemp, channel: .temp,
                                                  coldStart: prompt.temp == nil || prompt.source == .population)
        let sResp = WatchdogCalibration.applySigma(scaleResp, channel: .resp,
                                                  coldStart: prompt.resp == nil || prompt.source == .population)
        let sSpO2 = WatchdogCalibration.applySigma(scaleSpO2, channel: .spo2,
                                                  coldStart: prompt.spo2 == nil || prompt.source == .population)
        let hrScore = score(live.maskScored(window.hr, window: window), hatHR,
                            floor: WatchdogConfig.hrScale, personal: prompt.scaleHR, predicted: sHR)
        let rhrObs = WatchdogWindowBuilder.maskLookback(live.maskScored(window.rhr, window: window),
                                                        keepSeconds: WatchdogConfig.rhrLookbackSeconds)
        let rhrHat = WatchdogWindowBuilder.maskLookback(hatRHR, keepSeconds: WatchdogConfig.rhrLookbackSeconds)
        let rhrPredicted = WatchdogWindowBuilder.maskLookback(sRHR.map { Optional($0) },
                                                             keepSeconds: WatchdogConfig.rhrLookbackSeconds)
            .map { $0 ?? WatchdogConfig.hrScale }
        let rhrScore = score(rhrObs, rhrHat, floor: WatchdogConfig.hrScale, personal: prompt.scaleRHR, predicted: rhrPredicted)
        let hrvScore = score(live.maskScored(window.hrv, window: window), hatHRV,
                             floor: WatchdogConfig.hrvScale, personal: prompt.scaleHRV, predicted: sHRV)
        let tempScore = score(live.maskScored(window.temp, window: window), hatTemp,
                              floor: WatchdogConfig.tempScale, personal: prompt.scaleTemp, predicted: sTemp)
        let respScore = score(live.maskScored(window.resp, window: window), hatResp,
                              floor: WatchdogConfig.respScale, personal: prompt.scaleResp, predicted: sResp)
        let spo2Score = score(live.maskScored(window.spo2, window: window), hatSpO2,
                              floor: WatchdogConfig.spo2Scale, personal: prompt.scaleSpO2, predicted: sSpO2)
        var energy: [WatchdogWindow.Channel: Double] = [:]
        var rangeHalf: [WatchdogWindow.Channel: Double] = [:]
        energy[.hr] = hrScore.energy; rangeHalf[.hr] = hrScore.rangeHalf
        energy[.rhr] = rhrScore.energy; rangeHalf[.rhr] = rhrScore.rangeHalf
        energy[.hrv] = hrvScore.energy; rangeHalf[.hrv] = hrvScore.rangeHalf
        energy[.temp] = tempScore.energy; rangeHalf[.temp] = tempScore.rangeHalf
        energy[.resp] = respScore.energy; rangeHalf[.resp] = respScore.rangeHalf
        energy[.spo2] = spo2Score.energy; rangeHalf[.spo2] = spo2Score.rangeHalf
        energy[.motion] = 0
        rangeHalf[.motion] = 0
        let joint = WatchdogScores.joint(energies: [hrScore.energy, rhrScore.energy, hrvScore.energy,
                                                    tempScore.energy, respScore.energy, spo2Score.energy])
        return UniTSResidual(
            energy: energy,
            rangeHalf: rangeHalf,
            scaleHR: sHR,
            scaleRHR: sRHR,
            scaleHRV: sHRV,
            scaleTemp: sTemp,
            scaleResp: sResp,
            scaleSpO2: sSpO2,
            reconstructedHR: hatHR,
            reconstructedRHR: hatRHR,
            reconstructedHRV: hatHRV,
            reconstructedTemp: hatTemp,
            reconstructedResp: hatResp,
            reconstructedSpO2: hatSpO2,
            modelVersion: modelVersion,
            jointEnergy: joint,
            sleepPhase: prompt.sleepPhase
        )
    }

    /// Instant HR: this half-hour’s still center, plus class-effort occupancy.
    /// A shown Layer 1 usual only seeds that center. Effort minutes do not drag it up.
    static func reconstructHR(observed: [Double?], prompt: Double?, occupancy: [Double]) -> [Double?] {
        let smooth = trailingMean(occupancy, taps: WatchdogConfig.hrMotionSmoothMinutes)
        let seed = prompt ?? WatchdogPopulationPriors.hr
        let center = shortTermHrCenter(observed: observed, occupancy: smooth, seed: seed, hasPrompt: prompt != nil)
        let target: [Double?] = zip(center, smooth).map { rest, occ in
            guard let rest else { return nil }
            let lift = WatchdogConfig.hrEffortFraction * rest * pow(max(0, occ), WatchdogConfig.hrMotionPower)
            return clamp(rest + lift, lo: 35, hi: 190)
        }
        return track(target, alpha: WatchdogConfig.hrTrackAlpha)
    }

    /// Still minutes update the rest center. A walk keeps the last still value and is lifted separately.
    static func shortTermHrCenter(observed: [Double?], occupancy: [Double], seed: Double,
                                  hasPrompt: Bool) -> [Double?] {
        let a = WatchdogConfig.hrCenterAlpha
        var last: Double? = hasPrompt ? seed : nil
        let n = max(observed.count, occupancy.count)
        return (0..<n).map { i in
            let value = i < observed.count ? observed[i] : nil
            let occ = i < occupancy.count ? occupancy[i] : 0
            if let value, value.isFinite, occ < WatchdogConfig.hrRestCenterMaxOccupancy {
                if let prev = last {
                    last = (1 - a) * prev + a * value
                } else {
                    last = value
                }
            }
            return last
        }
    }

    /// Resting HR is still-gated. The center follows those still minutes.
    /// A sleep usual seeds it; it is not a flat overnight line for the whole strip.
    static func reconstructRHR(observed: [Double?], prompt: Double?) -> [Double?] {
        let seed = prompt ?? WatchdogPopulationPriors.rhr
        let center = shortTermRestCenter(observed: observed, seed: seed, hasPrompt: prompt != nil,
                                         alpha: WatchdogConfig.rhrCenterAlpha)
        return center.map { value in
            value.map { clamp($0, lo: 35, hi: 120) }
        }
    }

    static func shortTermRestCenter(observed: [Double?], seed: Double, hasPrompt: Bool,
                                    alpha: Double) -> [Double?] {
        var last: Double? = hasPrompt ? seed : nil
        return observed.map { value in
            if let value, value.isFinite {
                if let prev = last {
                    last = (1 - alpha) * prev + alpha * value
                } else {
                    last = value
                }
            }
            return last
        }
    }

    /// A stuck model heart-rate line is replaced by the short-term prior, same door HRV and skin use.
    static func liveHrHat(model: [Double?], prior: [Double?], observed: [Double?]) -> [Double?] {
        let hats = model.compactMap { $0 }
        let obs = observed.compactMap { $0 }
        guard hats.count >= 8, obs.count >= 5 else { return prior }
        let span = (hats.max() ?? 0) - (hats.min() ?? 0)
        if span < WatchdogConfig.hrModelFlatSpanBpm { return prior }
        return model
    }

    /// Live RMSSD hat: slow center of *this* half-hour, then occupancy drop.
    /// A sleep usual may seed the first minutes; it is not a flat live line. TimesFM is not this line.
    static func reconstructHRV(observed: [Double?], prompt: UniTSPrompt, occupancy: [Double]) -> [Double?] {
        let smooth = trailingMean(occupancy, taps: WatchdogConfig.hrvMotionSmoothMinutes)
        let seed = prompt.hrvCentre ?? WatchdogPopulationPriors.hrv
        let center = shortTermHrvCenter(observed: observed, seed: seed)
        let target: [Double?] = zip(center, smooth).map { rest, occ in
            let drop = WatchdogConfig.hrvExerciseDropMs * occ * (rest / WatchdogConfig.hrvDropRefMs)
            return clamp(rest - drop, lo: WatchdogConfig.rmssdLow, hi: WatchdogConfig.rmssdHigh)
        }
        return track(target, alpha: WatchdogConfig.hrvTrackAlpha)
    }

    /// Causal EMA of observed RMSSD. Empty minutes hold the last center (reconstruction, not a new sample).
    static func shortTermHrvCenter(observed: [Double?], seed: Double) -> [Double] {
        let a = WatchdogConfig.hrvCenterAlpha
        var last = seed
        return observed.map { value in
            if let value, value.isFinite {
                last = (1 - a) * last + a * value
            }
            return last
        }
    }

    /// UniTS-AD reconstructs toward a constant prompt, so hat HRV is often flat. If the model
    /// barely moves while this window has live RMSSD, use the short-term prior for the card.
    static func liveHrvHat(model: [Double?], prior: [Double?], observed: [Double?]) -> [Double?] {
        let hats = model.compactMap { $0 }
        let obs = observed.compactMap { $0 }
        guard hats.count >= 8, obs.count >= 5 else { return prior }
        let span = (hats.max() ?? 0) - (hats.min() ?? 0)
        if span < WatchdogConfig.hrvModelFlatSpanMs { return prior }
        return model
    }

    /// Personal wrist-skin setpoint (same *structure* as a body-temp usual: your center,
    /// relative change, realistic width). Still °C at the wrist — not core, not wrist+4.
    /// Sleep prompt seeds if shown; otherwise the first finite sample *is* the center.
    /// This window’s skin then updates the center. Activity still lowers expected skin.
    static func reconstructTemp(observed: [Double?], prompt: Double?, occupancy: [Double]) -> [Double?] {
        let lagged = trailingMean(occupancy, taps: WatchdogConfig.tempLagMinutes)
        let seed = prompt ?? WatchdogPopulationPriors.temp
        let center = shortTermTempCenter(observed: observed, seed: seed, hasPrompt: prompt != nil)
        let target: [Double?] = zip(center, lagged).map { rest, occ in
            guard let rest else { return nil }
            return clamp(rest + WatchdogConfig.tempMotionGain * occ, lo: 28, hi: 38)
        }
        return track(target, alpha: WatchdogConfig.tempTrackAlpha)
    }

    /// Causal personal skin center. Nil until the first sample when there is no Layer 1 usual,
    /// so a 32.2 °C wrist is not judged against population 33.0.
    static func shortTermTempCenter(observed: [Double?], seed: Double, hasPrompt: Bool) -> [Double?] {
        let a = WatchdogConfig.tempCenterAlpha
        var last: Double? = hasPrompt ? seed : nil
        return observed.map { value in
            if let value, value.isFinite {
                if let prev = last {
                    last = (1 - a) * prev + a * value
                } else {
                    last = value
                }
            }
            return last
        }
    }

    /// Painted corridor only. Never narrower than the Off residual scale.
    public static func paintRange(score: [Double], hat: [Double?],
                                 floor: Double, personal: Double,
                                 reconFraction: Double, coupling: [Double],
                                 companion: [Double]) -> [Double] {
        let prior = predictedScale(hat: hat, floor: floor, personal: personal,
                                   reconFraction: reconFraction, coupling: coupling)
        return zipMax(zipMax(score, liveAdaptiveScale(model: score, prior: prior)), companion)
    }

    public static func paintRanges(residual: UniTSResidual, occupancy: [Double],
                                  prompt: UniTSPrompt)
    -> (hr: [Double], rhr: [Double], hrv: [Double], temp: [Double], resp: [Double], spo2: [Double]) {
        var prompt = prompt
        if residual.sleepPhase { prompt.sleepPhase = true }
        let hrBase = prompt.hr ?? WatchdogPopulationPriors.hr
        let hrvBase = prompt.hrvCentre ?? WatchdogPopulationPriors.hrv
        let respBase = prompt.resp ?? WatchdogPopulationPriors.resp
        let hrSmooth = trailingMean(occupancy, taps: WatchdogConfig.hrMotionSmoothMinutes)
        let hrvSmooth = trailingMean(occupancy, taps: WatchdogConfig.hrvMotionSmoothMinutes)
        let tempLag = trailingMean(occupancy, taps: WatchdogConfig.tempLagMinutes)
        let respSmooth = trailingMean(occupancy, taps: WatchdogConfig.respSmoothMinutes)
        let companions = companionScale(
            hatHR: residual.reconstructedHR, hatHRV: residual.reconstructedHRV,
            hatResp: residual.reconstructedResp, occupancy: occupancy, prompt: prompt)
        return (
            paintRange(score: residual.scaleHR, hat: residual.reconstructedHR,
                       floor: WatchdogConfig.hrScale, personal: prompt.scaleHR,
                       reconFraction: WatchdogConfig.hrReconFraction,
                       coupling: hrSmooth.map { WatchdogConfig.hrEffortUncert * hrBase * pow(max(0, $0), WatchdogConfig.hrMotionPower) },
                       companion: companions.hr),
            paintRange(score: residual.scaleRHR, hat: residual.reconstructedRHR,
                       floor: WatchdogConfig.hrScale, personal: prompt.scaleRHR,
                       reconFraction: WatchdogConfig.rhrReconFraction,
                       coupling: Array(repeating: 0, count: residual.scaleRHR.count),
                       companion: Array(repeating: 0, count: residual.scaleRHR.count)),
            paintRange(score: residual.scaleHRV, hat: residual.reconstructedHRV,
                       floor: WatchdogConfig.hrvScale, personal: prompt.scaleHRV,
                       reconFraction: WatchdogConfig.hrvReconFraction,
                       coupling: hrvSmooth.map { WatchdogConfig.hrvDropUncertMs * $0 * (hrvBase / WatchdogConfig.hrvDropRefMs) },
                       companion: companions.hrv),
            paintRange(score: residual.scaleTemp, hat: residual.reconstructedTemp,
                       floor: WatchdogConfig.tempScale, personal: prompt.scaleTemp,
                       reconFraction: WatchdogConfig.tempReconFraction,
                       coupling: tempLag.map { WatchdogConfig.tempGainUncert * $0 },
                       companion: companions.temp),
            paintRange(score: residual.scaleResp, hat: residual.reconstructedResp,
                       floor: WatchdogConfig.respScale, personal: prompt.scaleResp,
                       reconFraction: WatchdogConfig.respReconFraction,
                       coupling: respSmooth.map { WatchdogConfig.respEffortUncert * respBase * pow(max(0, $0), WatchdogConfig.respMotionPower) },
                       companion: companions.resp),
            paintRange(score: residual.scaleSpO2, hat: residual.reconstructedSpO2,
                       floor: WatchdogConfig.spo2Scale, personal: prompt.scaleSpO2,
                       reconFraction: WatchdogConfig.spo2ReconFraction,
                       coupling: Array(repeating: 0, count: residual.scaleSpO2.count),
                       companion: Array(repeating: 0, count: residual.scaleSpO2.count))
        )
    }

    /// Motion-gated companion widths. A rest HRV crash does not widen HR.
    public static func companionScale(hatHR: [Double?], hatHRV: [Double?], hatResp: [Double?],
                               occupancy: [Double], prompt: UniTSPrompt)
    -> (hr: [Double], hrv: [Double], temp: [Double], resp: [Double]) {
        let n = WatchdogConfig.seqLen
        let hrBase = prompt.hr ?? WatchdogPopulationPriors.hr
        let hrvBase = prompt.hrvCentre ?? WatchdogPopulationPriors.hrv
        let respBase = prompt.resp ?? WatchdogPopulationPriors.resp
        let occ = occupancy.count >= n ? occupancy : occupancy + Array(repeating: occupancy.last ?? 0,
                                                                       count: max(0, n - occupancy.count))
        var hr = Array(repeating: 0.0, count: n)
        var hrv = Array(repeating: 0.0, count: n)
        var temp = Array(repeating: 0.0, count: n)
        var resp = Array(repeating: 0.0, count: n)
        for i in 0..<n {
            let o = max(0, min(1, occ[i]))
            let hrvHat = i < hatHRV.count ? hatHRV[i] : nil
            let hrHat = i < hatHR.count ? hatHR[i] : nil
            let respHat = i < hatResp.count ? hatResp[i] : nil
            let hrvDrop = max(0, (hrvBase - (hrvHat ?? hrvBase)) / max(hrvBase, 1))
            let hrLift = max(0, ((hrHat ?? hrBase) - hrBase) / max(hrBase, 1))
            let respLift = max(0, ((respHat ?? respBase) - respBase) / max(respBase, 1))
            hr[i] = WatchdogConfig.hrvToHrUncert * hrvDrop * hrBase * o
                + WatchdogConfig.hrToRespUncert * respLift * hrBase * o
            hrv[i] = WatchdogConfig.hrToHrvUncert * hrLift * hrvBase * o
            temp[i] = WatchdogConfig.hrToTempUncert * hrLift * o
            resp[i] = WatchdogConfig.hrToRespUncert * hrLift * respBase * o
        }
        return (hr, hrv, temp, resp)
    }

    static func zipMax(_ a: [Double], _ b: [Double]) -> [Double] {
        let n = max(a.count, b.count)
        return (0..<n).map { i in
            max(i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
        }
    }

    /// Student σ is often a flat rail. If it barely moves, use the occupancy / |hat| prior
    /// (same width logic as live HRV).
    static func liveAdaptiveScale(model: [Double], prior: [Double]) -> [Double] {
        let finite = model.filter { $0.isFinite && $0 > 0 }
        guard finite.count >= 8, prior.count == model.count, !prior.isEmpty else {
            return prior.count == model.count && !prior.isEmpty ? prior : model
        }
        let lo = finite.min() ?? 0
        let hi = finite.max() ?? 0
        let mid = max((lo + hi) / 2, 0.01)
        if (hi - lo) < max(0.12 * mid, 0.35) { return prior }
        return model
    }

    static func liveTempHat(model: [Double?], prior: [Double?], observed: [Double?]) -> [Double?] {
        let hats = model.compactMap { $0 }
        let obs = observed.compactMap { $0 }
        guard hats.count >= 8, obs.count >= 2 else { return prior }
        let span = (hats.max() ?? 0) - (hats.min() ?? 0)
        if span < WatchdogConfig.tempModelFlatSpanC { return prior }
        return model
    }

    /// Breathing: this person's rest rate plus occupancy × 60% of that rest, then EMA.
    static func reconstructResp(observed: [Double?], prompt: Double?, occupancy: [Double]) -> [Double?] {
        let smooth = trailingMean(occupancy, taps: WatchdogConfig.respSmoothMinutes)
        let base = prompt ?? WatchdogPopulationPriors.resp
        let target: [Double?] = zip(observed, smooth).map { _, occ in
            let lift = WatchdogConfig.respEffortFraction * base * pow(max(0, occ), WatchdogConfig.respMotionPower)
            return clamp(base + lift, lo: WatchdogConfig.respLow, hi: WatchdogConfig.respHigh)
        }
        return track(target, alpha: WatchdogConfig.respTrackAlpha)
    }

    /// SpO₂ expected is this person's usual, or the window median until a copy exists.
    /// Motion is not a predicted desaturation; observed is not mixed into \(\hat{x}\) when a usual exists.
    static func reconstructSpO2(observed: [Double?], prompt: Double?, occupancy: [Double]) -> [Double?] {
        _ = occupancy
        let base = prompt ?? WatchdogPopulationPriors.spo2
        let target: [Double?] = observed.map { _ in
            return clamp(base, lo: 88, hi: 100)
        }
        return track(target, alpha: WatchdogConfig.spo2TrackAlpha)
    }

    /// Causal EMA so each minute keeps a memory of the last prediction (small baseline changes).
    static func track(_ target: [Double?], alpha: Double) -> [Double?] {
        let a = min(1, max(0.05, alpha))
        var last: Double?
        return target.map { value -> Double? in
            guard let value else { return last }
            if let prev = last {
                let next = (1 - a) * prev + a * value
                last = next
                return next
            }
            last = value
            return value
        }
    }

    /// Kept for tests / call sites that still pass a single slope.
    static func generate(_ observed: [Double?], prompt: Double?, motion: [Double?],
                         motionGain: Double, requireObserved: Bool = true) -> [Double?] {
        let fallback = median(observed.compactMap { $0 })
        let base = prompt ?? fallback
        return zip(observed, motion).map { value, occ in
            if requireObserved, value == nil { return nil }
            guard let base else { return nil }
            let activity = occ ?? 0
            return base + motionGain * max(0, activity)
        }
    }

    static func occupancy(_ window: WatchdogWindow) -> [Double] {
        physiologyOccupancy(window, features: window.resolvedActivityFeatures())
    }

    static func physiologyOccupancy(_ window: WatchdogWindow, features: [[Double]]) -> [Double] {
        if !features.isEmpty {
            return features.map { WatchdogActivityFeatures.priorOccupancy($0) }
        }
        return WatchdogActivityRuntime.effortOccupancy(motion: window.motion, logits: window.activityLogits)
    }

    static func occupancy(_ motion: [Double?]) -> [Double] {
        motion.map { max(0, min(1, $0 ?? 0)) }
    }

    static func trailingMean(_ xs: [Double], taps: Int) -> [Double] {
        let n = max(1, taps)
        guard !xs.isEmpty else { return [] }
        var out = Array(repeating: 0.0, count: xs.count)
        var run = 0.0
        var q: [Double] = []
        q.reserveCapacity(n)
        for i in 0..<xs.count {
            q.append(xs[i])
            run += xs[i]
            if q.count > n { run -= q.removeFirst() }
            out[i] = run / Double(q.count)
        }
        return out
    }

    static func clamp(_ x: Double, lo: Double, hi: Double) -> Double {
        min(hi, max(lo, x))
    }

    /// Last minute where both live and reconstruction exist. Do not pair a held/latest
    /// reading with a later occupancy-only hat — that falsely flags a gap as off.
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
    static func predictedScale(hat: [Double?], floor: Double, personal: Double,
                               reconFraction: Double, coupling: [Double]) -> [Double] {
        hat.enumerated().map { i, h in
            let recon = abs(h ?? 0) * max(0, reconFraction)
            let coup = i < coupling.count ? max(0, coupling[i]) : 0
            return max(floor, personal, recon, coup)
        }
    }

    /// Location vs reconstruction. `predicted` is the per-minute UniTS band; if nil, scale is
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

    static func mae(_ observed: [Double?], _ hat: [Double?], scale: Double) -> Double {
        var sum = 0.0
        var n = 0
        for (o, h) in zip(observed, hat) {
            guard let o, let h, scale > 0 else { continue }
            sum += abs(o - h) / scale
            n += 1
        }
        return n == 0 ? 0 : sum / Double(n)
    }

    static func median(_ xs: [Double]) -> Double? {
        let s = xs.sorted()
        guard !s.isEmpty else { return nil }
        let m = s.count / 2
        if s.count % 2 == 1 { return s[m] }
        return (s[m - 1] + s[m]) / 2
    }
}
