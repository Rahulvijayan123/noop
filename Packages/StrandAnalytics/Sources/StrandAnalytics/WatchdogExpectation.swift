import Foundation

/// What each Watchdog minute is drawn and scored against: the person's own established Layer 1 reference for that
/// minute's context. Never a model. The real TimesFM 3.0 / UniTS run on the VPS and reach the phone only as
/// candidates (`WatchdogDetectors.server`); nothing on the phone imitates them.
///
/// Per minute, from `WatchdogContextResolver` (activity classification + sleep + posture):
/// * HR / HRV: exactly the series the personal-deviation detector uses (`WatchdogLiveReferences`): sleep HR; awake
///   still by posture (supine / seated / upright, falling back to pooled awake rest); walking HR.
/// * RHR (the resting-HR stream): the HR reference while asleep or awake still.
/// * Temperature / respiration: the sleep references while asleep. Awake values have no reference (room, clothing,
///   talking dominate), so nothing is drawn.
/// * SpO₂: sleep mean while asleep, awake-rest mean while awake still.
/// * No expectation (nil) while vigorous, during recovery (30 min after vigorous, 10 min after walking — the Layer 1
///   steady-state rule), for 2 minutes after a posture / sleep transition, in unknown context, or when the matching
///   reference is not yet established. A person's baseline has to be learned before it can be drawn; until then the
///   Watchdog shows the measurement without an expected band.
///
/// Scale per minute = √(between-day² + within-day²) of the reference (within-day unknown → assumed equal to the
/// between-day spread: conservative). HRV references are on ln: center e^c, half-width e^c·sinh(s).
public enum WatchdogExpectation {
    public static let version = "baseline-\(LongitudinalBaseline.V2.paramSet)"
    static let recoveryAfterEffortS = 30 * 60
    static let recoveryAfterWalkingS = 10 * 60

    static func series(kind: WatchdogMinuteContextKind, posture: LBPosture?, channel: String) -> [LBSeries] {
        switch (kind, channel) {
        case (_, "HR"), (_, "HRV"):
            return WatchdogLiveReferences.series(kind: kind, posture: posture, channel: channel)
        case (.asleep, "RHR"), (.awakeStill, "RHR"):
            return WatchdogLiveReferences.series(kind: kind, posture: posture, channel: "HR")
        case (.asleep, "Temp"): return [.sleepTemp]
        case (.asleep, "Resp"): return [.sleepResp]
        case (.asleep, "SpO2"): return [.sleepSpO2Mean]
        case (.awakeStill, "SpO2"): return [.awakeRestSpO2Mean]
        default: return []
        }
    }

    /// True when a still minute is not yet at steady state (or the context is not one with a reference).
    static func settling(_ c: WatchdogMinuteContext) -> Bool {
        if c.recentTransition { return true }
        guard c.kind == .awakeStill else { return false }
        if let e = c.sinceEffortS, e < recoveryAfterEffortS { return true }
        if let w = c.sinceWalkingS, w < recoveryAfterWalkingS { return true }
        return false
    }

    public struct Track: Equatable, Sendable {
        public var center: [Double?]
        public var scale: [Double?]
        public var series: [LBSeries?]
    }

    /// Per-minute expected center / scale for one channel ("HR", "RHR", "HRV", "Temp", "Resp", "SpO2").
    public static func track(channel: String, context: [WatchdogMinuteContext],
                             evaluations: [LBEvaluation]) -> Track {
        var cache: [String: WatchdogLiveReference?] = [:]
        var center = [Double?](repeating: nil, count: context.count)
        var scale = [Double?](repeating: nil, count: context.count)
        var used = [LBSeries?](repeating: nil, count: context.count)
        for (i, c) in context.enumerated() where !settling(c) {
            let key = "\(c.kind.rawValue)|\(c.posture?.rawValue ?? "-")"
            let ref: WatchdogLiveReference?
            if let hit = cache[key] {
                ref = hit
            } else {
                ref = WatchdogLiveReferences.lookup(evaluations,
                                                    series: series(kind: c.kind, posture: c.posture, channel: channel))
                cache[key] = ref
            }
            guard let ref else { continue }
            if channel == "HRV" {
                let mid = exp(ref.center)
                center[i] = mid
                scale[i] = mid * sinh(ref.scale)
            } else {
                center[i] = ref.center
                scale[i] = ref.scale
            }
            used[i] = ref.series
        }
        return Track(center: center, scale: scale, series: used)
    }

    /// The Watchdog's per-minute expectation and deviation energies for this window.
    public static func residual(window: WatchdogWindow, evaluations: [LBEvaluation],
                                carryLastWorkoutEndUnix: Int, tail: WatchdogLiveTail? = nil) -> UniTSResidual {
        let live = tail ?? WatchdogLiveTail.resolve(window)
        let quality = WatchdogSignalQuality.assess(window: window)
        let context = WatchdogContextResolver.resolve(window: window, quality: quality,
                                                      carryLastWorkoutEndUnix: carryLastWorkoutEndUnix)
        let n = window.hr.count
        func fit(_ t: Track) -> Track {
            func pad<T>(_ xs: [T?]) -> [T?] {
                xs.count >= n ? Array(xs.prefix(n)) : xs + Array(repeating: nil, count: n - xs.count)
            }
            return Track(center: pad(t.center), scale: pad(t.scale), series: pad(t.series))
        }
        let hr = fit(track(channel: "HR", context: context, evaluations: evaluations))
        let rhr = fit(track(channel: "RHR", context: context, evaluations: evaluations))
        let hrv = fit(track(channel: "HRV", context: context, evaluations: evaluations))
        let temp = fit(track(channel: "Temp", context: context, evaluations: evaluations))
        let resp = fit(track(channel: "Resp", context: context, evaluations: evaluations))
        let spo2 = fit(track(channel: "SpO2", context: context, evaluations: evaluations))
        func scales(_ t: Track, floor: Double) -> [Double] { t.scale.map { max(floor, $0 ?? floor) } }
        let sHR = scales(hr, floor: WatchdogConfig.hrScale)
        let sRHR = scales(rhr, floor: WatchdogConfig.hrScale)
        let sHRV = scales(hrv, floor: WatchdogConfig.hrvScale)
        let sTemp = scales(temp, floor: WatchdogConfig.tempScale)
        let sResp = scales(resp, floor: WatchdogConfig.respScale)
        let sSpO2 = scales(spo2, floor: WatchdogConfig.spo2Scale)

        let hrScore = UniTSRuntime.score(live.maskScored(window.hr, window: window), hr.center,
                                         floor: WatchdogConfig.hrScale, personal: 0, predicted: sHR)
        let rhrObs = WatchdogWindowBuilder.maskLookback(live.maskScored(window.rhr, window: window),
                                                        keepSeconds: WatchdogConfig.rhrLookbackSeconds)
        let rhrScore = UniTSRuntime.score(rhrObs, rhr.center, floor: WatchdogConfig.hrScale, personal: 0,
                                          predicted: sRHR)
        let hrvScore = UniTSRuntime.score(live.maskScored(window.hrv, window: window), hrv.center,
                                          floor: WatchdogConfig.hrvScale, personal: 0, predicted: sHRV)
        let tempScore = UniTSRuntime.score(live.maskScored(window.temp, window: window), temp.center,
                                           floor: WatchdogConfig.tempScale, personal: 0, predicted: sTemp)
        let respScore = UniTSRuntime.score(live.maskScored(window.resp, window: window), resp.center,
                                           floor: WatchdogConfig.respScale, personal: 0, predicted: sResp)
        let spo2Score = UniTSRuntime.score(live.maskScored(window.spo2, window: window), spo2.center,
                                           floor: WatchdogConfig.spo2Scale, personal: 0, predicted: sSpO2)
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
            energy: energy, rangeHalf: rangeHalf,
            scaleHR: sHR, scaleRHR: sRHR, scaleHRV: sHRV, scaleTemp: sTemp, scaleResp: sResp, scaleSpO2: sSpO2,
            reconstructedHR: hr.center, reconstructedRHR: rhr.center, reconstructedHRV: hrv.center,
            reconstructedTemp: temp.center, reconstructedResp: resp.center, reconstructedSpO2: spo2.center,
            modelVersion: version, jointEnergy: joint, sleepPhase: UniTSRuntime.windowInSleep(window))
    }
}
