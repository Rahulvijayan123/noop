import Foundation
import WhoopProtocol

/// v2 calibration. Quiet-window residual coverage, not this-window scatter. Engineering, not clinical.
public enum WatchdogCalibration: Sendable {
    public static let version = "prior-untuned"
    public static let quietCoverage = 0.95
    public static let coldStartGain = 2.5
    public static let tNote = 1.0
    public static let tActive = 1.6
    /// Spacing prior on WatchdogScores.severityJoint (clipped sum). Not wearer-fit.
    public static let tSevere = 2.4
    public static let persistTicks = 2
    public static let escalateDelta = 0.5
    public static let rearmTicks = 15
    public static let forecastAlpha = 0.5
    public static let maxEmptyMinutes = 6
    public static let forecastHorizon = 5

    public static func sigmaScale(_ channel: WatchdogWindow.Channel) -> Double {
        switch channel {
        case .hr: return 1.0
        case .rhr: return 1.0
        case .hrv: return 1.0
        case .temp: return 1.0
        case .resp: return 1.0
        case .spo2: return 1.0
        case .motion: return 1.0
        }
    }

    public static func applySigma(_ raw: [Double], channel: WatchdogWindow.Channel, coldStart: Bool) -> [Double] {
        let g = (coldStart ? coldStartGain : 1.0) * sigmaScale(channel)
        return raw.map { $0 * g }
    }
}

public enum WatchdogPopulationPriors: Sendable {
    public static let hr = 60.0
    public static let rhr = 60.0
    public static let hrv = 40.0
    public static let temp = 33.0
    public static let resp = 14.0
    public static let spo2 = 97.0

    public static func value(_ channel: WatchdogWindow.Channel) -> Double {
        switch channel {
        case .hr: return hr
        case .rhr: return rhr
        case .hrv: return hrv
        case .temp: return temp
        case .resp: return resp
        case .spo2: return spo2
        case .motion: return 0
        }
    }
}

public enum WatchdogPromptSource: String, Equatable, Sendable, Codable {
    case population
    case sleep
    case awakeRest
    case mixed
}

public enum WatchdogActivityClass: String, Equatable, Sendable, CaseIterable {
    case still, stand, walk, run, cycleLike, resistance, artifact, unknown

    public static var count: Int { allCases.count }

    public var index: Int {
        Self.allCases.firstIndex(of: self) ?? (Self.count - 1)
    }

    public static func unknownLogits(minutes: Int = WatchdogConfig.seqLen) -> [[Double]] {
        (0..<minutes).map { _ in
            var row = Array(repeating: 0.0, count: count)
            row[WatchdogActivityClass.unknown.index] = 1
            return row
        }
    }

    public static func labels(logits: [[Double]]) -> [String] {
        logits.map { row in
            guard let i = row.enumerated().max(by: { $0.element < $1.element })?.offset,
                  i < allCases.count else { return unknown.rawValue }
            return allCases[i].rawValue
        }
    }
}

public enum WatchdogQuality: Sendable {
    public static func bucketCoverage(_ window: WatchdogWindow) -> Double {
        guard window.seqLen > 0 else { return 0 }
        return Double(window.hr.filter { $0 != nil }.count) / Double(window.seqLen)
    }

    public static func maxEmptyMinutes(_ hr: [Double?]) -> Int {
        var best = 0
        var run = 0
        for v in hr {
            if v == nil {
                run += 1
                best = max(best, run)
            } else {
                run = 0
            }
        }
        return best
    }

    public static func freshnessLimit(_ family: DeviceFamily) -> Int {
        family == .whoop5 ? WatchdogConfig.whoop5FreshnessSeconds : WatchdogConfig.whoop4FreshnessSeconds
    }

    /// HR/RHR use the family packet clock. Sparse vitals use their own cadence.
    public static func channelFreshnessSeconds(channel: Int, family: DeviceFamily) -> Int {
        switch channel {
        case 0, 1: return freshnessLimit(family)
        case 2: return 5 * 60
        case 3: return 8 * 60
        case 4, 5: return 6 * 60
        default: return freshnessLimit(family)
        }
    }

    public static func lastFiniteMinuteUnix(_ series: [Double?], startUnix: Int) -> Int? {
        for i in stride(from: series.count - 1, through: 0, by: -1) {
            if series[i] != nil {
                return startUnix + i * WatchdogConfig.gridSeconds
            }
        }
        return nil
    }

    public static func channelFresh(_ series: [Double?], startUnix: Int, nowUnix: Int,
                                   channel: Int, family: DeviceFamily) -> Bool {
        guard let t = lastFiniteMinuteUnix(series, startUnix: startUnix) else { return false }
        return nowUnix - t <= channelFreshnessSeconds(channel: channel, family: family)
    }

    public static func gate(_ window: WatchdogWindow, tail: WatchdogLiveTail? = nil) -> WatchdogUnavailable? {
        if bucketCoverage(window) + 1e-9 < WatchdogConfig.minCoverage { return .coverage }
        if window.newestAgeSeconds > freshnessLimit(window.family) { return .stale }
        if maxEmptyMinutes(window.hr) >= WatchdogCalibration.maxEmptyMinutes { return .gap }
        let live = tail ?? WatchdogLiveTail.resolve(window)
        if live.thinRestCoverage(window.hr) { return .coverage }
        return nil
    }
}

public enum WatchdogSafety: Sendable {
    public static func fired(_ window: WatchdogWindow) -> Bool {
        Watchdog.safetyCap(window: window)
    }
}

public enum WatchdogAdaptive: Sendable {
    public static let quietEma = 0.08
    public static let artifactGain = 1.7

    public static func apply(_ residual: UniTSResidual, window: WatchdogWindow,
                             lastHR: (obs: Double, hat: Double)?,
                             lastRHR: (obs: Double, hat: Double)?,
                             lastHRV: (obs: Double, hat: Double)?,
                             lastTemp: (obs: Double, hat: Double)?,
                             lastResp: (obs: Double, hat: Double)?,
                             lastSpO2: (obs: Double, hat: Double)?,
                             carry: inout WatchdogCarry,
                             tail: WatchdogLiveTail? = nil) -> UniTSResidual {
        var out = residual
        let live = tail ?? WatchdogLiveTail.resolve(window)
        let artifact = WatchdogActivityRuntime.isArtifact(window.activityLogits, from: live.startIndex)
        func absr(_ p: (obs: Double, hat: Double)?) -> Double? {
            guard let p else { return nil }
            return abs(p.obs - p.hat)
        }
        func lastZ(_ p: (obs: Double, hat: Double)?, scale: [Double]) -> Double {
            guard let a = absr(p) else { return 0 }
            return a / max(scale.last ?? 1, 0.01)
        }
        let lastBandZ = max(
            lastZ(lastHR, scale: residual.scaleHR),
            lastZ(lastRHR, scale: residual.scaleRHR),
            lastZ(lastHRV, scale: residual.scaleHRV),
            lastZ(lastTemp, scale: residual.scaleTemp),
            lastZ(lastResp, scale: residual.scaleResp),
            lastZ(lastSpO2, scale: residual.scaleSpO2)
        )
        let tailJoint = live.energy(obs: window.hr, hat: residual.reconstructedHR,
                                    scale: residual.scaleHR, floor: WatchdogConfig.hrScale)
        if live.period == .rest, live.previousPeriod == .effort {
            carry.quietAbsHR = 0; carry.quietAbsRHR = 0; carry.quietAbsHRV = 0
            carry.quietAbsTemp = 0; carry.quietAbsResp = 0; carry.quietAbsSpO2 = 0
            carry.quietN = 0
        }
        if tailJoint < WatchdogCalibration.tNote || lastBandZ < 1.0 {
            let a = quietEma
            func mix(_ held: inout Double, _ pair: (obs: Double, hat: Double)?) {
                guard let x = absr(pair) else { return }
                held = (1 - a) * held + a * x
            }
            mix(&carry.quietAbsHR, lastHR)
            mix(&carry.quietAbsRHR, lastRHR)
            mix(&carry.quietAbsHRV, lastHRV)
            mix(&carry.quietAbsTemp, lastTemp)
            mix(&carry.quietAbsResp, lastResp)
            mix(&carry.quietAbsSpO2, lastSpO2)
            carry.quietN += 1
        }
        let art = artifact ? artifactGain : 1.0
        func bump(_ scale: [Double]) -> [Double] {
            scale.map { $0 * art }
        }
        out.scaleHR = bump(out.scaleHR)
        out.scaleRHR = bump(out.scaleRHR)
        out.scaleHRV = bump(out.scaleHRV)
        out.scaleTemp = bump(out.scaleTemp)
        out.scaleResp = bump(out.scaleResp)
        out.scaleSpO2 = bump(out.scaleSpO2)
        out.rangeHalf[.hr] = out.scaleHR.last ?? residual.rangeHalf(for: .hr)
        out.rangeHalf[.rhr] = out.scaleRHR.last ?? residual.rangeHalf(for: .rhr)
        out.rangeHalf[.hrv] = out.scaleHRV.last ?? residual.rangeHalf(for: .hrv)
        out.rangeHalf[.temp] = out.scaleTemp.last ?? residual.rangeHalf(for: .temp)
        out.rangeHalf[.resp] = out.scaleResp.last ?? residual.rangeHalf(for: .resp)
        out.rangeHalf[.spo2] = out.scaleSpO2.last ?? residual.rangeHalf(for: .spo2)
        out.jointEnergy = residual.jointEnergy
        return out
    }
}

public enum WatchdogScores: Sendable {
    /// One channel cannot donate more than this to the model severe door.
    public static let severityChannelCap = 1.0
    /// Same damp as the tanh label fold. Artifact must not open model-severe alone.
    public static let severityArtifactGain = 0.72
    /// RHR is a still lookback of HR, not a second metric in the add-up.
    public static let rhrSeverityIndex = 1

    /// Unsigned RMS of present energies. Residual packaging only. Not the live severe door.
    public static func joint(energies: [Double]) -> Double {
        let xs = energies.filter { $0.isFinite }
        guard !xs.isEmpty else { return 0 }
        return sqrt(xs.reduce(0) { $0 + $1 * $1 } / Double(xs.count))
    }

    /// Model combined score vs tNote / tActive / tSevere.
    ///
    /// `J = Σ min(|r_k|, 1.0)` over present channels except RHR, then ×0.72 if artifact.
    /// One vital ≤ 1.0 (cannot hit 2.4). Two ≤ 2.0 (active band). Three near 1.0 can severe.
    public static func severityJoint(absR: [Double], mask: [Bool], artifact: Bool) -> Double {
        let n = min(absR.count, mask.count, WatchdogDirection.channelCount)
        var sum = 0.0
        for k in 0..<n {
            if k == rhrSeverityIndex { continue }
            guard mask[k], absR[k].isFinite else { continue }
            sum += min(max(absR[k], 0), severityChannelCap)
        }
        if artifact { sum *= severityArtifactGain }
        return sum
    }

    public static func fused(recon: Double, forecast: Double) -> Double {
        recon
    }

    public static func severity(recon: Double, forecast: Double = 0, persistTicks: Int, safety: Bool,
                                confounded: Bool, personalOff: Bool) -> WatchdogSeverity {
        if safety { return .severe }
        if confounded {
            return recon >= WatchdogCalibration.tNote ? .candidate : .note
        }
        let persist = persistTicks >= WatchdogCalibration.persistTicks
        if recon >= WatchdogCalibration.tSevere && persist { return .severe }
        if recon >= WatchdogCalibration.tActive && persist { return .active }
        if recon >= WatchdogCalibration.tNote && persist { return .candidate }
        if personalOff && persist { return .candidate }
        if recon >= WatchdogCalibration.tNote || personalOff { return .note }
        _ = forecast
        return .withinLimits
    }

    public static func severity(fused: Double, persistTicks: Int, safety: Bool, confounded: Bool,
                                personalOff: Bool) -> WatchdogSeverity {
        severity(recon: fused, persistTicks: persistTicks, safety: safety,
                 confounded: confounded, personalOff: personalOff)
    }

    public static func shouldNotify(severity: WatchdogSeverity, openedEpisode: Bool,
                                    safety: Bool, previousSafety: Bool,
                                    fused: Double, previousFused: Double) -> (Bool, String) {
        WatchdogNotifyPolicy.decision(severity: severity, openedEpisode: openedEpisode,
                                      safety: safety, previousSafety: previousSafety,
                                      fused: fused, previousFused: previousFused,
                                      recon: fused, previousRecon: previousFused)
    }
}

/// Wearer push: **extreme only**. Daily event testing over-sent when every cut / Early / Test
/// Centre bell felt like a page. Forecast, workouts, and in-range events never notify.
public enum WatchdogNotifyPolicy: Sendable {
    public static func extremeFamily(_ label: WatchdogEventLabel) -> Bool {
        switch label {
        case .safetyBound, .abnormalStillTachycardia, .abnormalMultiDirection, .abnormalSpo2Still:
            return true
        default:
            return false
        }
    }

    public static func inFlight(_ delivery: String) -> Bool { delivery == "queued" }

    public static func retryable(_ delivery: String) -> Bool {
        delivery == "failed" || delivery == "denied"
    }

    public static func decision(severity: WatchdogSeverity, openedEpisode: Bool,
                                safety: Bool, previousSafety: Bool,
                                fused: Double, previousFused: Double,
                                recon: Double = 0, previousRecon: Double = 0,
                                eventLabel: WatchdogEventLabel = .abnormalMultiDirection,
                                episodeId: String? = nil,
                                notifiedSevereEpisodeId: String = "",
                                lastNotifiedAt: Int? = nil,
                                nowUnix: Int = 0,
                                notifyDelivery: String = "") -> (Bool, String) {
        _ = fused
        _ = previousFused
        _ = openedEpisode
        if inFlight(notifyDelivery) { return (false, "in-flight") }
        let safetyEdge = safety && !previousSafety
        guard severity == .severe || safetyEdge else { return (false, "not-severe") }
        let eid = episodeId ?? ""
        let firstSevere = notifiedSevereEpisodeId.isEmpty
            || (!eid.isEmpty && notifiedSevereEpisodeId != eid)
        if firstSevere, retryable(notifyDelivery) {
            let cooled = lastNotifiedAt.map { nowUnix - $0 >= WatchdogConfig.notifyCooldownSeconds } ?? true
            if !cooled { return (false, "retry-wait") }
            return (true, "retry")
        }
        if firstSevere {
            return (true, safetyEdge ? "safety" : "first-severe")
        }
        if safetyEdge { return (true, "safety") }
        guard extremeFamily(eventLabel) else { return (false, "not-extreme-family") }
        let cooled = lastNotifiedAt.map { nowUnix - $0 >= WatchdogConfig.notifyCooldownSeconds } ?? true
        if recon >= previousRecon + WatchdogCalibration.escalateDelta {
            if !cooled { return (false, "cooldown") }
            return (true, "escalate")
        }
        return (false, "stable-episode")
    }
}

/// Bundled Core ML is `student`. `official` is unused — convert is not on the phone.
public enum WatchdogForecastSource: String, Equatable, Sendable, Codable {
    case student
    case hold
    case inject
    case official
}

/// One TimesFM (or hold-display) horizon. Wearer Early only when `source == official`.
public struct WatchdogForecastStep: Equatable, Sendable {
    public var energy: Double
    public var nextHR: [Double]
    public var nextHRV: [Double]
    public var nextTemp: [Double]
    public var nextResp: [Double]
    public var nextRHR: [Double]
    public var nextSpO2: [Double]
    public var ranStudent: Bool
    public var studentOk: Bool
    public var source: String
    /// Civil seconds for cube columns 0…4: now+60 … now+300. Not the last observed minutes.
    public var horizonUnix: [Int]

    public static let empty = WatchdogForecastStep(
        energy: 0, nextHR: [], nextHRV: [], nextTemp: [], nextResp: [],
        nextRHR: [], nextSpO2: [], ranStudent: false, studentOk: false, source: "hold",
        horizonUnix: [])

    public static func horizonUnix(nowUnix: Int) -> [Int] {
        let h = WatchdogCalibration.forecastHorizon
        return (1...h).map { nowUnix + $0 * WatchdogConfig.gridSeconds }
    }

    /// Held cubes keep the emit timestamps. Do not recompute from the current wall second.
    public static func persistHorizon(carry: WatchdogCarry, nowUnix: Int, holding: Bool) -> [Int] {
        if holding {
            if carry.lastForecastHorizonUnix.count == WatchdogCalibration.forecastHorizon {
                return carry.lastForecastHorizonUnix
            }
            if carry.lastForecastUnix > 0 {
                return horizonUnix(nowUnix: carry.lastForecastUnix)
            }
            return []
        }
        return horizonUnix(nowUnix: nowUnix)
    }

    public var cube: [[Double]] {
        [nextHR, nextRHR, nextHRV, nextTemp, nextResp, nextSpO2]
    }
}

public struct WatchdogForecastPathScore: Equatable, Sendable {
    public var labelJoint: Double
    public var severityJoint: Double
    public var hotChannels: Int
    public var stepsAboveNote: Int
    public var complete: Bool
    public static let zero = WatchdogForecastPathScore(
        labelJoint: 0, severityJoint: 0, hotChannels: 0, stepsAboveNote: 0, complete: false)
}

/// TimesFM-style on-device forecast student (patched causal decoder).
/// Teacher recipe is google-research/timesfm (`google/timesfm-3.0-pytorch`);
/// the App Store binary loads `TimesFM3_Student.mlpackage`, not the 330M weights.
public struct WatchdogForecastRuntime: Sendable {
    public static let modelVersion = WatchdogConfig.forecastModelVersion
    /// Test hook. `nil` = live Core ML. `.some(nil)` = force fail. `.some(cube)` = inject 6×5.
    static var testPredict: [[Double]]??

    public static let earlyTrustFloor = 35

    public func step(window: WatchdogWindow, residual: UniTSResidual,
                     prompt: UniTSPrompt = UniTSPrompt(),
                     carry: WatchdogCarry,
                     nowUnix: Int = 0,
                     tail: WatchdogLiveTail? = nil,
                     skipForecast: Bool = false) -> WatchdogForecastStep {
        _ = tail
        let h = WatchdogCalibration.forecastHorizon
        let skipStudent = skipForecast || (nowUnix > 0 && carry.forecastStudentOk
            && carry.lastForecastUnix > 0
            && (nowUnix - carry.lastForecastUnix) < 60
            && Self.completeCube(carry.lastForecastHR, carry.lastForecastRHR, carry.lastForecastHRV,
                                 carry.lastForecastTemp, carry.lastForecastResp, carry.lastForecastSpO2))
        let emitHorizons = WatchdogForecastStep.persistHorizon(carry: carry, nowUnix: nowUnix, holding: skipStudent)
        let backcastHorizons = WatchdogForecastStep.persistHorizon(carry: carry, nowUnix: nowUnix, holding: true)
        var e = 0.0
        if carry.forecastStudentOk {
            e = max(e, Self.backcastEnergy(obs: window.hr, pred: carry.lastForecastHR,
                                           scale: residual.scaleHR, startUnix: window.startUnix,
                                           horizons: backcastHorizons))
            e = max(e, Self.backcastEnergy(obs: window.hrv, pred: carry.lastForecastHRV,
                                           scale: residual.scaleHRV, startUnix: window.startUnix,
                                           horizons: backcastHorizons))
            e = max(e, Self.backcastEnergy(obs: window.temp, pred: carry.lastForecastTemp,
                                           scale: residual.scaleTemp, startUnix: window.startUnix,
                                           horizons: backcastHorizons))
            e = max(e, Self.backcastEnergy(obs: window.resp, pred: carry.lastForecastResp,
                                           scale: residual.scaleResp, startUnix: window.startUnix,
                                           horizons: backcastHorizons))
            e = max(e, Self.backcastEnergy(obs: window.rhr, pred: carry.lastForecastRHR,
                                           scale: residual.scaleRHR, startUnix: window.startUnix,
                                           horizons: backcastHorizons))
            e = max(e, Self.backcastEnergy(obs: window.spo2, pred: carry.lastForecastSpO2,
                                           scale: residual.scaleSpO2, startUnix: window.startUnix,
                                           horizons: backcastHorizons))
        }

        if skipStudent {
            let src = skipForecast
                ? (carry.lastForecastSource.isEmpty ? "hold" : carry.lastForecastSource)
                : (carry.lastForecastSource.isEmpty ? "student" : carry.lastForecastSource)
            return WatchdogForecastStep(energy: e, nextHR: carry.lastForecastHR, nextHRV: carry.lastForecastHRV,
                                        nextTemp: carry.lastForecastTemp, nextResp: carry.lastForecastResp,
                                        nextRHR: carry.lastForecastRHR, nextSpO2: carry.lastForecastSpO2,
                                        ranStudent: false, studentOk: carry.forecastStudentOk
                                            && Self.completeCube(carry.lastForecastHR, carry.lastForecastRHR,
                                                                 carry.lastForecastHRV, carry.lastForecastTemp,
                                                                 carry.lastForecastResp, carry.lastForecastSpO2),
                                        source: src,
                                        horizonUnix: emitHorizons)
        }

        func hold(_ hat: [Double?]) -> [Double] {
            let last = hat.reversed().compactMap { $0 }.first ?? 0
            return Array(repeating: last, count: h)
        }
        func fillHat(_ xs: [Double?], _ base: Double?) -> [Double] {
            let seed = base ?? 0
            var last = seed
            return (0..<WatchdogConfig.seqLen).map { i in
                if i < xs.count, let v = xs[i], v.isFinite {
                    last = v
                    return v
                }
                return last
            }
        }
        let bases = UniTSRuntime.resolvedBases(window: window, prompt: prompt)
        let history = [
            fillHat(residual.reconstructedHR, bases[0]),
            fillHat(residual.reconstructedRHR, bases[1]),
            fillHat(residual.reconstructedHRV, bases[2]),
            fillHat(residual.reconstructedTemp, bases[3]),
            fillHat(residual.reconstructedResp, bases[4]),
            fillHat(residual.reconstructedSpO2, bases[5])
        ]
        let occ = UniTSRuntime.occupancy(window)
        let present = UniTSRuntime.packPresentMask(window)
        let promptVec = [
            bases[0] ?? WatchdogPopulationPriors.hr,
            bases[1] ?? WatchdogPopulationPriors.rhr,
            bases[2] ?? WatchdogPopulationPriors.hrv,
            bases[3] ?? WatchdogPopulationPriors.temp,
            bases[4] ?? WatchdogPopulationPriors.resp,
            bases[5] ?? WatchdogPopulationPriors.spo2
        ]
        let predicted: [[Double]]?
        var predictedSource = WatchdogForecastSource.student.rawValue
        if let override = Self.testPredict {
            predicted = override
            predictedSource = WatchdogForecastSource.inject.rawValue
        } else {
            predicted = TimesFMStudentSession.shared.predict(
                history: history, prompt: promptVec, occupancy: occ, presentMask: present)
            predictedSource = WatchdogForecastSource.student.rawValue
        }
        if let forecast = predicted,
           Self.completeCube(forecast) {
            return WatchdogForecastStep(energy: e, nextHR: forecast[0], nextHRV: forecast[2],
                                        nextTemp: forecast[3], nextResp: forecast[4],
                                        nextRHR: forecast[1], nextSpO2: forecast[5],
                                        ranStudent: true, studentOk: true, source: predictedSource,
                                        horizonUnix: WatchdogForecastStep.horizonUnix(nowUnix: nowUnix))
        }
        return WatchdogForecastStep(energy: e, nextHR: hold(residual.reconstructedHR),
                                    nextHRV: hold(residual.reconstructedHRV),
                                    nextTemp: hold(residual.reconstructedTemp),
                                    nextResp: hold(residual.reconstructedResp),
                                    nextRHR: hold(residual.reconstructedRHR),
                                    nextSpO2: hold(residual.reconstructedSpO2),
                                    ranStudent: false, studentOk: false, source: "hold",
                                    horizonUnix: WatchdogForecastStep.horizonUnix(nowUnix: nowUnix))
    }

    /// Score cube column `i` against the observation at `horizons[i]`, not the last present minutes.
    public static func backcastEnergy(obs: [Double?], pred: [Double], scale: [Double],
                                      startUnix: Int, horizons: [Int]) -> Double {
        let n = min(pred.count, horizons.count)
        guard n > 0 else { return 0 }
        var z: [Double] = []
        for i in 0..<n {
            guard let o = observationAt(unix: horizons[i], series: obs, startUnix: startUnix) else { continue }
            let slot = slotIndex(unix: horizons[i], startUnix: startUnix)
            let s = (slot != nil && slot! < scale.count) ? max(scale[slot!], 0.01) : 0.01
            z.append(abs(o - pred[i]) / s)
        }
        return z.max() ?? 0
    }

    public static func observationAt(unix: Int, series: [Double?], startUnix: Int) -> Double? {
        guard let i = slotIndex(unix: unix, startUnix: startUnix), i < series.count else { return nil }
        return series[i]
    }

    public static func slotIndex(unix: Int, startUnix: Int) -> Int? {
        let g = WatchdogConfig.gridSeconds
        guard g > 0 else { return nil }
        let delta = unix - startUnix
        guard delta >= 0, delta % g == 0 else { return nil }
        return delta / g
    }

    public static func completeCube(_ planes: [[Double]]) -> Bool {
        let h = WatchdogCalibration.forecastHorizon
        return planes.count == 6 && planes.allSatisfy({ $0.count == h && $0.allSatisfy(\.isFinite) })
    }

    public static func completeCube(_ hr: [Double], _ rhr: [Double], _ hrv: [Double],
                                    _ temp: [Double], _ resp: [Double], _ spo2: [Double]) -> Bool {
        completeCube([hr, rhr, hrv, temp, resp, spo2])
    }

    /// Path leaving the prompt corridor. Not lastObs − pred[0]. Hold cubes score 0.
    public static func pathScore(_ step: WatchdogForecastStep, usual: [Double], scales: [Double],
                                 artifact: Bool = false) -> WatchdogForecastPathScore {
        guard step.studentOk else { return .zero }
        return pathScore(cube: step.cube, usual: usual, scales: scales, artifact: artifact)
    }

    public static func pathScore(cube: [[Double]], usual: [Double], scales: [Double],
                                 artifact: Bool = false) -> WatchdogForecastPathScore {
        let h = WatchdogCalibration.forecastHorizon
        guard completeCube(cube), usual.count >= 6, scales.count >= 6 else { return .zero }
        var labelJs: [Double] = []
        var sevJs: [Double] = []
        var maxAbs = Array(repeating: 0.0, count: 6)
        var stepsAbove = 0
        for t in 0..<h {
            var raw: [Double?] = Array(repeating: nil, count: 6)
            var leaving = 0
            for k in 0..<6 {
                let sig = max(scales[k], 0.01)
                let r = (cube[k][t] - usual[k]) / sig
                raw[k] = r
                maxAbs[k] = max(maxAbs[k], abs(r))
                if k != WatchdogScores.rhrSeverityIndex, abs(r) >= WatchdogCalibration.tNote {
                    leaving += 1
                }
            }
            if leaving >= 2 { stepsAbove += 1 }
            var ema = Array(repeating: 0.0, count: 6)
            let dir = WatchdogDirection.compute(rawR: raw, rhrAllowed: false, artifact: artifact,
                                                dirEma: &ema)
            labelJs.append(dir.joint)
            sevJs.append(dir.severityJoint)
        }
        var hot = 0
        for k in 0..<6 where k != WatchdogScores.rhrSeverityIndex {
            if maxAbs[k] >= WatchdogCalibration.tNote { hot += 1 }
        }
        guard hot >= 2, stepsAbove >= 2 else {
            return WatchdogForecastPathScore(labelJoint: 0, severityJoint: 0,
                                             hotChannels: hot, stepsAboveNote: stepsAbove, complete: true)
        }
        // Tanh fold dilutes two-of-five channels below tNote. Path Early uses the
        // clipped-sum door (RHR out), same add-up as recon severity.
        let sev = median(sevJs)
        return WatchdogForecastPathScore(labelJoint: sev, severityJoint: sev,
                                         hotChannels: hot, stepsAboveNote: stepsAbove, complete: true)
    }

    /// Corridor the path is leaving: last UniTS hat, then the live prompt. Not lastObs.
    public static func pathCenter(residual: UniTSResidual, prompt: UniTSPrompt) -> [Double] {
        func last(_ xs: [Double?], _ fallback: Double) -> Double {
            xs.reversed().compactMap { $0 }.first ?? fallback
        }
        let bases = [
            prompt.hr ?? WatchdogPopulationPriors.hr,
            prompt.rhr ?? WatchdogPopulationPriors.rhr,
            prompt.hrvAwake ?? prompt.hrv ?? WatchdogPopulationPriors.hrv,
            prompt.temp ?? WatchdogPopulationPriors.temp,
            prompt.resp ?? WatchdogPopulationPriors.resp,
            prompt.spo2 ?? WatchdogPopulationPriors.spo2
        ]
        return [
            last(residual.reconstructedHR, bases[0]),
            last(residual.reconstructedRHR, bases[1]),
            last(residual.reconstructedHRV, bases[2]),
            last(residual.reconstructedTemp, bases[3]),
            last(residual.reconstructedResp, bases[4]),
            last(residual.reconstructedSpO2, bases[5])
        ]
    }

    public static func wearerEarly(pathJ: Double, allowed: Bool, severity: WatchdogSeverity,
                                   trustPct: Int, persistTicks: Int,
                                   forecastSource: String = WatchdogForecastSource.student.rawValue) -> Bool {
        // Student / hold cubes stay shadow. Inject is tests only. Official is unused.
        guard forecastSource == WatchdogForecastSource.official.rawValue
                || forecastSource == WatchdogForecastSource.inject.rawValue else { return false }
        guard allowed, severity != .severe, severity != .active else { return false }
        guard trustPct >= earlyTrustFloor else { return false }
        return pathJ >= WatchdogCalibration.tNote && persistTicks >= WatchdogCalibration.persistTicks
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.filter(\.isFinite).sorted()
        guard !s.isEmpty else { return 0 }
        return s[s.count / 2]
    }
}
