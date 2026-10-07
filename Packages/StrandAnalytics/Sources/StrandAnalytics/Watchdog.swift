import Foundation
import WhoopProtocol

public enum WatchdogSeverity: String, Equatable, Sendable, Codable {
    case withinLimits
    case note
    case candidate
    case active
    case severe
    case dataUnavailable
}

public enum WatchdogEpisodeState: String, Equatable, Sendable, Codable {
    case withinLimits
    case candidate
    case active
    case recovering
    case resolved
    case dataUnavailable
}

/// Held TRUST for temp / breathing / SpO₂ until that vital’s last reading changes.
public struct WatchdogSparseTrustHold: Equatable, Sendable, Codable {
    public var tempTrust: Int
    public var tempObs: Double?
    public var respTrust: Int
    public var respObs: Double?
    public var spo2Trust: Int
    public var spo2Obs: Double?

    public static let empty = WatchdogSparseTrustHold()

    public init(tempTrust: Int = 0, tempObs: Double? = nil,
                respTrust: Int = 0, respObs: Double? = nil,
                spo2Trust: Int = 0, spo2Obs: Double? = nil) {
        self.tempTrust = tempTrust
        self.tempObs = tempObs
        self.respTrust = respTrust
        self.respObs = respObs
        self.spo2Trust = spo2Trust
        self.spo2Obs = spo2Obs
    }
}

public struct WatchdogSignalEvidence: Equatable, Sendable, Codable {
    public var name: String
    public var observed: Double?
    public var usual: Double?
    public var reconstructed: Double?
    public var energy: Double
    public var unit: String
    public var trustPct: Int
    /// Native-unit half-width of the live in-range band around reconstruction.
    public var rangeHalf: Double

    public init(name: String, observed: Double?, usual: Double?, reconstructed: Double?,
                energy: Double, unit: String, trustPct: Int = 0, rangeHalf: Double = 0) {
        self.name = name
        self.observed = observed
        self.usual = usual
        self.reconstructed = reconstructed
        self.energy = energy
        self.unit = unit
        self.trustPct = trustPct
        self.rangeHalf = rangeHalf
    }
}

public struct WatchdogCarry: Equatable, Sendable, Codable {
    public var episodeId: String?
    public var consecutiveMismatchTicks: Int
    public var lastNotifiedAt: Int?
    public var consecutiveQuietTicks: Int
    public var priorState: WatchdogEpisodeState?
    public var lastHeldResp: Double?
    public var lastHeldHRV: Double?
    public var lastHeldTemp: Double?
    public var lastHeldSpO2: Double?
    /// Last TRUST for sparse vitals. HR coverage must not move these between readings.
    public var sparseTrust: WatchdogSparseTrustHold
    public var lastJointEnergy: Double
    public var lastSafety: Bool
    public var lastForecastHR: [Double]
    public var lastForecastHRV: [Double]
    public var lastForecastTemp: [Double]
    public var lastForecastResp: [Double]
    public var lastForecastRHR: [Double]
    public var lastForecastSpO2: [Double]
    public var consecutiveInRangeTicks: Int
    public var quietAbsHR: Double
    public var quietAbsRHR: Double
    public var quietAbsHRV: Double
    public var quietAbsTemp: Double
    public var quietAbsResp: Double
    public var quietAbsSpO2: Double
    public var quietN: Int
    public var lastForecastUnix: Int
    /// Civil seconds the last cube columns belong to (`now+60…now+300` at emit). Holds do not slide these.
    public var lastForecastHorizonUnix: [Int]
    /// Last `lastForecast*` arrays came from a real 6×5 student cube, not a hold.
    public var forecastStudentOk: Bool
    public var quietJointEma: Double
    public var lastReconEnergy: Double
    public var dirEma: [Double]
    public var earlyTicks: Int
    public var sessionAbs: [Double]
    public var sessionN: Int
    public var sessionUnix: Int
    /// Last-paired observed vitals (bpm, ms, °C, /min, %). Never residuals.
    public var sessionNative: [Double]
    public var sessionNativeN: Int
    /// Per-channel native counts. A missing vital does not mature a 0 usual.
    public var sessionNativeCount: [Int]
    /// Last consumed grid minute per channel. The same sparse sample is not a new n.
    public var lastNativeMinute: [Int]
    /// Band-eligible ticks per phase×still key for the civil day.
    public var sessionKeyTicks: [String: Int]
    /// Per-key native EMA so morning and evening do not share one mixed vector.
    public var sessionNativeByKey: [String: [Double]]
    public var sessionNativeCountByKey: [String: [Int]]
    public var lastWorkoutEndUnix: Int
    public var phaseUsual: WatchdogPhaseUsualStore
    public var bandQ: [Double]
    public var bandAnchor: [Double]
    public var bandN: Int
    public var bandReady: Bool
    public var bandScale: [Double]
    /// Per existing PhaseKey.id. Legacy bandQ/N/scale/ready mirror the current key.
    public var bandByKey: [String: WatchdogBandState]
    public var lastBandKey: String
    public var sessionLastUnix: Int
    public var lastCivilDay: String
    public var lastEventLabel: String
    public var lastActivityFamily: String
    public var lastEventFamily: String
    public var lastForecastJoint: Double
    public var familyStableTicks: Int
    /// Unix second the current LiveTail family began. C3/C4 use wall time, not ticks.
    public var familyChangedUnix: Int
    public var reconAboveTicks: Int
    public var forecastAboveTicks: Int
    public var lastEventStartUnix: Int
    public var lastCutReason: String
    public var eventMemory: WatchdogEventMemory
    /// Last TimesFM cube origin: student | hold | inject. `official` unused until convert pins exist.
    public var lastForecastSource: String
    /// Last 30 student / inject path J values. Hold does not append.
    public var forecastJRing: [Double]
    /// Episode id that already sent its first severe page. Empty = none.
    public var notifiedSevereEpisodeId: String
    /// Last civil minute that advanced persist / quiet counters.
    public var lastPersistMinute: Int
    /// Last measurement civil minute that counted as a persist observation.
    public var lastPersistObsMinute: Int
    public var notifyDelivery: String
    /// First unix the current safety extreme was seen. 0 = none. Survives thin / UniTS-fail ticks.
    public var safetyFirstUnix: Int
    public var safetyExtreme: Double
    public var safetyChannel: String

    public static let empty = WatchdogCarry()

    public init(episodeId: String? = nil, consecutiveMismatchTicks: Int = 0,
                lastNotifiedAt: Int? = nil, consecutiveQuietTicks: Int = 0,
                priorState: WatchdogEpisodeState? = nil,
                lastHeldResp: Double? = nil, lastHeldHRV: Double? = nil,
                lastHeldTemp: Double? = nil, lastHeldSpO2: Double? = nil,
                sparseTrust: WatchdogSparseTrustHold = .empty,
                lastJointEnergy: Double = 0, lastSafety: Bool = false,
                lastForecastHR: [Double] = [], lastForecastHRV: [Double] = [],
                lastForecastTemp: [Double] = [], lastForecastResp: [Double] = [],
                lastForecastRHR: [Double] = [], lastForecastSpO2: [Double] = [],
                consecutiveInRangeTicks: Int = 0,
                quietAbsHR: Double = 0, quietAbsRHR: Double = 0, quietAbsHRV: Double = 0,
                quietAbsTemp: Double = 0, quietAbsResp: Double = 0, quietAbsSpO2: Double = 0,
                quietN: Int = 0, lastForecastUnix: Int = 0,
                lastForecastHorizonUnix: [Int] = [],
                forecastStudentOk: Bool = false,
                quietJointEma: Double = 0,
                lastReconEnergy: Double = 0,
                dirEma: [Double] = Array(repeating: 0, count: 6),
                earlyTicks: Int = 0,
                sessionAbs: [Double] = Array(repeating: 0, count: 6),
                sessionN: Int = 0, sessionUnix: Int = 0,
                sessionNative: [Double] = Array(repeating: 0, count: 6),
                sessionNativeN: Int = 0,
                sessionNativeCount: [Int] = Array(repeating: 0, count: 6),
                lastNativeMinute: [Int] = Array(repeating: 0, count: 6),
                sessionKeyTicks: [String: Int] = [:],
                sessionNativeByKey: [String: [Double]] = [:],
                sessionNativeCountByKey: [String: [Int]] = [:],
                lastWorkoutEndUnix: Int = 0,
                phaseUsual: WatchdogPhaseUsualStore = .empty,
                bandQ: [Double] = Array(repeating: 0, count: 6),
                bandAnchor: [Double] = Array(repeating: 1, count: 6),
                bandN: Int = 0, bandReady: Bool = false,
                bandScale: [Double] = Array(repeating: 1, count: 6),
                bandByKey: [String: WatchdogBandState] = [:],
                lastBandKey: String = "",
                sessionLastUnix: Int = 0,
                lastCivilDay: String = "",
                lastEventLabel: String = "", lastActivityFamily: String = "",
                lastEventFamily: String = "",
                lastForecastJoint: Double = 0, familyStableTicks: Int = 0,
                familyChangedUnix: Int = 0,
                reconAboveTicks: Int = 0, forecastAboveTicks: Int = 0,
                lastEventStartUnix: Int = 0, lastCutReason: String = "",
                eventMemory: WatchdogEventMemory = .empty,
                lastForecastSource: String = "hold",
                forecastJRing: [Double] = [],
                notifiedSevereEpisodeId: String = "",
                lastPersistMinute: Int = 0,
                lastPersistObsMinute: Int = 0,
                notifyDelivery: String = "",
                safetyFirstUnix: Int = 0,
                safetyExtreme: Double = 0,
                safetyChannel: String = "") {
        self.episodeId = episodeId
        self.consecutiveMismatchTicks = consecutiveMismatchTicks
        self.lastNotifiedAt = lastNotifiedAt
        self.consecutiveQuietTicks = consecutiveQuietTicks
        self.priorState = priorState
        self.lastHeldResp = lastHeldResp
        self.lastHeldHRV = lastHeldHRV
        self.lastHeldTemp = lastHeldTemp
        self.lastHeldSpO2 = lastHeldSpO2
        self.sparseTrust = sparseTrust
        self.lastJointEnergy = lastJointEnergy
        self.lastSafety = lastSafety
        self.lastForecastHR = lastForecastHR
        self.lastForecastHRV = lastForecastHRV
        self.lastForecastTemp = lastForecastTemp
        self.lastForecastResp = lastForecastResp
        self.lastForecastRHR = lastForecastRHR
        self.lastForecastSpO2 = lastForecastSpO2
        self.consecutiveInRangeTicks = consecutiveInRangeTicks
        self.quietAbsHR = quietAbsHR
        self.quietAbsRHR = quietAbsRHR
        self.quietAbsHRV = quietAbsHRV
        self.quietAbsTemp = quietAbsTemp
        self.quietAbsResp = quietAbsResp
        self.quietAbsSpO2 = quietAbsSpO2
        self.quietN = quietN
        self.lastForecastUnix = lastForecastUnix
        self.lastForecastHorizonUnix = lastForecastHorizonUnix
        self.forecastStudentOk = forecastStudentOk
        self.quietJointEma = quietJointEma
        self.lastReconEnergy = lastReconEnergy
        self.dirEma = dirEma
        self.earlyTicks = earlyTicks
        self.sessionAbs = sessionAbs
        self.sessionN = sessionN
        self.sessionUnix = sessionUnix
        self.sessionNative = sessionNative
        self.sessionNativeN = sessionNativeN
        self.sessionNativeCount = sessionNativeCount
        self.lastNativeMinute = lastNativeMinute
        self.sessionKeyTicks = sessionKeyTicks
        self.sessionNativeByKey = sessionNativeByKey
        self.sessionNativeCountByKey = sessionNativeCountByKey
        self.lastWorkoutEndUnix = lastWorkoutEndUnix
        self.phaseUsual = phaseUsual
        self.bandQ = bandQ
        self.bandAnchor = bandAnchor
        self.bandN = bandN
        self.bandReady = bandReady
        self.bandScale = bandScale
        self.bandByKey = bandByKey
        self.lastBandKey = lastBandKey
        self.sessionLastUnix = sessionLastUnix
        self.lastCivilDay = lastCivilDay
        self.lastEventLabel = lastEventLabel
        self.lastActivityFamily = lastActivityFamily
        self.lastEventFamily = lastEventFamily
        self.lastForecastJoint = lastForecastJoint
        self.familyStableTicks = familyStableTicks
        self.familyChangedUnix = familyChangedUnix
        self.reconAboveTicks = reconAboveTicks
        self.forecastAboveTicks = forecastAboveTicks
        self.lastEventStartUnix = lastEventStartUnix
        self.lastCutReason = lastCutReason
        self.eventMemory = eventMemory
        self.lastForecastSource = lastForecastSource
        self.forecastJRing = forecastJRing
        self.notifiedSevereEpisodeId = notifiedSevereEpisodeId
        self.lastPersistMinute = lastPersistMinute
        self.lastPersistObsMinute = lastPersistObsMinute
        self.notifyDelivery = notifyDelivery
        self.safetyFirstUnix = safetyFirstUnix
        self.safetyExtreme = safetyExtreme
        self.safetyChannel = safetyChannel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodeId = try c.decodeIfPresent(String.self, forKey: .episodeId)
        consecutiveMismatchTicks = try c.decodeIfPresent(Int.self, forKey: .consecutiveMismatchTicks) ?? 0
        lastNotifiedAt = try c.decodeIfPresent(Int.self, forKey: .lastNotifiedAt)
        consecutiveQuietTicks = try c.decodeIfPresent(Int.self, forKey: .consecutiveQuietTicks) ?? 0
        priorState = try c.decodeIfPresent(WatchdogEpisodeState.self, forKey: .priorState)
        lastHeldResp = try c.decodeIfPresent(Double.self, forKey: .lastHeldResp)
        lastHeldHRV = try c.decodeIfPresent(Double.self, forKey: .lastHeldHRV)
        lastHeldTemp = try c.decodeIfPresent(Double.self, forKey: .lastHeldTemp)
        lastHeldSpO2 = try c.decodeIfPresent(Double.self, forKey: .lastHeldSpO2)
        sparseTrust = try c.decodeIfPresent(WatchdogSparseTrustHold.self, forKey: .sparseTrust) ?? .empty
        lastJointEnergy = try c.decodeIfPresent(Double.self, forKey: .lastJointEnergy) ?? 0
        lastSafety = try c.decodeIfPresent(Bool.self, forKey: .lastSafety) ?? false
        lastForecastHR = try c.decodeIfPresent([Double].self, forKey: .lastForecastHR) ?? []
        lastForecastHRV = try c.decodeIfPresent([Double].self, forKey: .lastForecastHRV) ?? []
        lastForecastTemp = try c.decodeIfPresent([Double].self, forKey: .lastForecastTemp) ?? []
        lastForecastResp = try c.decodeIfPresent([Double].self, forKey: .lastForecastResp) ?? []
        lastForecastRHR = try c.decodeIfPresent([Double].self, forKey: .lastForecastRHR) ?? []
        lastForecastSpO2 = try c.decodeIfPresent([Double].self, forKey: .lastForecastSpO2) ?? []
        consecutiveInRangeTicks = try c.decodeIfPresent(Int.self, forKey: .consecutiveInRangeTicks) ?? 0
        quietAbsHR = try c.decodeIfPresent(Double.self, forKey: .quietAbsHR) ?? 0
        quietAbsRHR = try c.decodeIfPresent(Double.self, forKey: .quietAbsRHR) ?? 0
        quietAbsHRV = try c.decodeIfPresent(Double.self, forKey: .quietAbsHRV) ?? 0
        quietAbsTemp = try c.decodeIfPresent(Double.self, forKey: .quietAbsTemp) ?? 0
        quietAbsResp = try c.decodeIfPresent(Double.self, forKey: .quietAbsResp) ?? 0
        quietAbsSpO2 = try c.decodeIfPresent(Double.self, forKey: .quietAbsSpO2) ?? 0
        quietN = try c.decodeIfPresent(Int.self, forKey: .quietN) ?? 0
        lastForecastUnix = try c.decodeIfPresent(Int.self, forKey: .lastForecastUnix) ?? 0
        lastForecastHorizonUnix = try c.decodeIfPresent([Int].self, forKey: .lastForecastHorizonUnix) ?? []
        forecastStudentOk = try c.decodeIfPresent(Bool.self, forKey: .forecastStudentOk) ?? false
        quietJointEma = try c.decodeIfPresent(Double.self, forKey: .quietJointEma) ?? 0
        lastReconEnergy = try c.decodeIfPresent(Double.self, forKey: .lastReconEnergy) ?? 0
        dirEma = try c.decodeIfPresent([Double].self, forKey: .dirEma) ?? Array(repeating: 0, count: 6)
        earlyTicks = try c.decodeIfPresent(Int.self, forKey: .earlyTicks) ?? 0
        sessionAbs = try c.decodeIfPresent([Double].self, forKey: .sessionAbs) ?? Array(repeating: 0, count: 6)
        sessionN = try c.decodeIfPresent(Int.self, forKey: .sessionN) ?? 0
        sessionUnix = try c.decodeIfPresent(Int.self, forKey: .sessionUnix) ?? 0
        sessionNative = try c.decodeIfPresent([Double].self, forKey: .sessionNative) ?? Array(repeating: 0, count: 6)
        sessionNativeN = try c.decodeIfPresent(Int.self, forKey: .sessionNativeN) ?? 0
        sessionNativeCount = try c.decodeIfPresent([Int].self, forKey: .sessionNativeCount)
            ?? Array(repeating: 0, count: 6)
        lastNativeMinute = try c.decodeIfPresent([Int].self, forKey: .lastNativeMinute)
            ?? Array(repeating: 0, count: 6)
        sessionKeyTicks = try c.decodeIfPresent([String: Int].self, forKey: .sessionKeyTicks) ?? [:]
        sessionNativeByKey = try c.decodeIfPresent([String: [Double]].self, forKey: .sessionNativeByKey) ?? [:]
        sessionNativeCountByKey = try c.decodeIfPresent([String: [Int]].self, forKey: .sessionNativeCountByKey) ?? [:]
        lastWorkoutEndUnix = try c.decodeIfPresent(Int.self, forKey: .lastWorkoutEndUnix) ?? 0
        phaseUsual = try c.decodeIfPresent(WatchdogPhaseUsualStore.self, forKey: .phaseUsual) ?? .empty
        phaseUsual.dropResidualScaleCenters()
        bandQ = try c.decodeIfPresent([Double].self, forKey: .bandQ) ?? Array(repeating: 0, count: 6)
        bandAnchor = try c.decodeIfPresent([Double].self, forKey: .bandAnchor) ?? Array(repeating: 1, count: 6)
        bandN = try c.decodeIfPresent(Int.self, forKey: .bandN) ?? 0
        bandReady = try c.decodeIfPresent(Bool.self, forKey: .bandReady) ?? false
        bandScale = try c.decodeIfPresent([Double].self, forKey: .bandScale) ?? Array(repeating: 1, count: 6)
        bandByKey = try c.decodeIfPresent([String: WatchdogBandState].self, forKey: .bandByKey) ?? [:]
        lastBandKey = try c.decodeIfPresent(String.self, forKey: .lastBandKey) ?? ""
        sessionLastUnix = try c.decodeIfPresent(Int.self, forKey: .sessionLastUnix) ?? 0
        lastCivilDay = try c.decodeIfPresent(String.self, forKey: .lastCivilDay) ?? ""
        lastEventLabel = try c.decodeIfPresent(String.self, forKey: .lastEventLabel) ?? ""
        lastActivityFamily = try c.decodeIfPresent(String.self, forKey: .lastActivityFamily) ?? ""
        lastEventFamily = try c.decodeIfPresent(String.self, forKey: .lastEventFamily) ?? ""
        lastForecastJoint = try c.decodeIfPresent(Double.self, forKey: .lastForecastJoint) ?? 0
        familyStableTicks = try c.decodeIfPresent(Int.self, forKey: .familyStableTicks) ?? 0
        familyChangedUnix = try c.decodeIfPresent(Int.self, forKey: .familyChangedUnix) ?? 0
        reconAboveTicks = try c.decodeIfPresent(Int.self, forKey: .reconAboveTicks) ?? 0
        forecastAboveTicks = try c.decodeIfPresent(Int.self, forKey: .forecastAboveTicks) ?? 0
        lastEventStartUnix = try c.decodeIfPresent(Int.self, forKey: .lastEventStartUnix) ?? 0
        lastCutReason = try c.decodeIfPresent(String.self, forKey: .lastCutReason) ?? ""
        eventMemory = try c.decodeIfPresent(WatchdogEventMemory.self, forKey: .eventMemory) ?? .empty
        lastForecastSource = try c.decodeIfPresent(String.self, forKey: .lastForecastSource) ?? "hold"
        forecastJRing = try c.decodeIfPresent([Double].self, forKey: .forecastJRing) ?? []
        notifiedSevereEpisodeId = try c.decodeIfPresent(String.self, forKey: .notifiedSevereEpisodeId) ?? ""
        lastPersistMinute = try c.decodeIfPresent(Int.self, forKey: .lastPersistMinute) ?? 0
        lastPersistObsMinute = try c.decodeIfPresent(Int.self, forKey: .lastPersistObsMinute) ?? 0
        notifyDelivery = try c.decodeIfPresent(String.self, forKey: .notifyDelivery) ?? ""
        safetyFirstUnix = try c.decodeIfPresent(Int.self, forKey: .safetyFirstUnix) ?? 0
        safetyExtreme = try c.decodeIfPresent(Double.self, forKey: .safetyExtreme) ?? 0
        safetyChannel = try c.decodeIfPresent(String.self, forKey: .safetyChannel) ?? ""
    }

    public mutating func resetSessionAbsOnly() {
        sessionAbs = Array(repeating: 0, count: 6)
        sessionN = 0
        sessionUnix = 0
    }

    public mutating func resetSessionBuffers() {
        resetSessionAbsOnly()
        sessionNative = Array(repeating: 0, count: 6)
        sessionNativeN = 0
        sessionNativeCount = Array(repeating: 0, count: 6)
        lastNativeMinute = Array(repeating: 0, count: 6)
        sessionKeyTicks = [:]
        sessionNativeByKey = [:]
        sessionNativeCountByKey = [:]
        sessionLastUnix = 0
    }

    /// Minutes toward the green band for this vital.
    /// Current key only. A set `lastBandKey` with no state is 0 (do not borrow still’s 14).
    /// Empty `lastBandKey` (restart before the first tick) may use the stored max so reopen does not reset.
    public func presentMinutes(channel: Int) -> Int {
        guard channel >= 0 else { return 0 }
        if lastBandKey.isEmpty {
            return bandByKey.values.map { channel < $0.nPresent.count ? $0.nPresent[channel] : 0 }.max() ?? 0
        }
        guard let state = bandByKey[lastBandKey], channel < state.nPresent.count else { return 0 }
        return state.nPresent[channel]
    }

    public func channelBandReady(_ channel: Int) -> Bool {
        presentMinutes(channel: channel) >= WatchdogBand.firstMinutes
    }

    mutating func migrateLegacyBandIfNeeded(into key: WatchdogPhaseKey) {
        guard bandByKey.isEmpty, bandN > 0 else { return }
        bandByKey[key.id] = WatchdogBandState(q: bandQ, anchor: bandAnchor, n: bandN,
                                              ready: bandReady, scale: bandScale, lastUnix: 0)
    }

    mutating func mirrorBand(_ state: WatchdogBandState, key: String) {
        bandQ = state.q
        bandAnchor = state.anchor
        bandN = state.n
        bandReady = state.ready
        bandScale = state.scale
        lastBandKey = key
    }
}

public struct WatchdogResult: Equatable, Sendable, Codable {
    public var severity: WatchdogSeverity
    public var episodeState: WatchdogEpisodeState
    public var episodeId: String?
    public var headline: String
    public var episodeLine: String
    public var monitoringCurrent: Bool
    public var monitoringLabel: String
    public var mode: String
    public var unavailable: WatchdogUnavailable?
    public var coverage: Double
    public var hrSource: String
    public var family: String
    public var lastTickUnix: Int
    public var windowStartUnix: Int
    public var horizonHR: [Double]
    public var horizonHRV: [Double]
    public var horizonTemp: [Double]
    public var horizonResp: [Double]
    public var horizonRHR: [Double]
    public var horizonSpO2: [Double]
    public var reconstructedHR: [Double]
    public var reconstructedHRV: [Double]
    public var reconstructedTemp: [Double]
    public var reconstructedResp: [Double]
    public var reconstructedRHR: [Double]
    public var reconstructedSpO2: [Double]
    /// Per-minute UniTS predicted half-width (same units as the reconstructed strip).
    public var rangeHR: [Double]
    public var rangeHRV: [Double]
    public var rangeTemp: [Double]
    public var rangeResp: [Double]
    public var rangeRHR: [Double]
    public var rangeSpO2: [Double]
    public var signals: [WatchdogSignalEvidence]
    public var contributing: [String]
    public var qualityLine: String
    public var versionLine: String
    public var shouldNotify: Bool
    public var carry: WatchdogCarry
    public var modelVersion: String
    public var trustPct: Int
    public var jointEnergy: Double
    public var forecastEnergy: Double
    public var fusedEnergy: Double
    public var promptSource: WatchdogPromptSource
    public var notifyReason: String
    public var activityLabel: String
    public var activityDetail: String
    public var sigmaAdaptive: Bool
    public var qualityGate: String
    public var earlyFlag: Bool
    public var direction: [Double]
    public var directionMarks: [String]
    public var eventLabel: String
    public var calibrationSource: String
    public var cutReason: String
    public var eventExplained: Bool
    /// student | hold | inject. Production never sets inject or official.
    public var forecastSource: String
    /// Same door as the live card **Off**: candidate+ / safety / personal-off. Not Layer 1 HOW OFF.
    public var liveOff: Bool
    public var personalOff: Bool
    /// Holistic alert from per-vital labels. Not a change to any one graph.
    public var physiologyOff: Bool
}

public enum Watchdog {
    public static func evaluate(window: Result<WatchdogWindow, WatchdogUnavailable>,
                                prompt: UniTSPrompt,
                                evaluations: [LBEvaluation] = [],
                                dayLog: LBDayLog? = nil,
                                nowUnix: Int,
                                liveIntervalMinutes: Int = WatchdogConfig.defaultLiveIntervalMinutes,
                                previous: WatchdogCarry = .empty,
                                inject: WatchdogInject? = nil,
                                sleepSessionOpen: Bool = false,
                                sleepIntervals: [WatchdogSleepInterval] = [],
                                skipForecast: Bool = false,
                                liveAlerts: Bool = true) -> WatchdogResult {
        var carry = previous
        carry.phaseUsual.dropResidualScaleCenters()
        if let inject {
            return applyInject(inject, nowUnix: nowUnix, interval: liveIntervalMinutes, carry: &carry,
                               liveAlerts: liveAlerts)
        }
        switch window {
        case .failure(let reason):
            carry.consecutiveMismatchTicks = 0
            rememberSafety(hit: nil, nowUnix: nowUnix, carry: &carry)
            return unavailable(reason, nowUnix: nowUnix, interval: liveIntervalMinutes, carry: carry)
        case .success(let raw):
            var rawWin = raw
            let sleepNow = sleepSessionOpen
                || sleepIntervals.contains(where: { $0.contains(nowUnix) })
            rawWin.bindActivityContext(lastWorkoutEndUnix: carry.lastWorkoutEndUnix,
                                       sleepIntervals: sleepIntervals)
            var openTail = WatchdogLiveTail.resolve(rawWin)
            let workoutEnd = max(carry.lastWorkoutEndUnix, openTail.lastEffortEndUnix)
            if workoutEnd != rawWin.lastWorkoutEndUnix {
                rawWin.bindActivityContext(lastWorkoutEndUnix: workoutEnd,
                                           sleepIntervals: sleepIntervals)
                openTail = WatchdogLiveTail.resolve(rawWin)
            }
            if let reason = WatchdogQuality.gate(rawWin, tail: openTail) {
                if reason != .wristOff, safetyCap(window: rawWin) {
                    return safetyDuringQualityFail(window: rawWin, nowUnix: nowUnix,
                                                   interval: liveIntervalMinutes, carry: carry,
                                                   liveAlerts: liveAlerts)
                }
                carry.consecutiveMismatchTicks = 0
                rememberSafety(hit: nil, nowUnix: nowUnix, carry: &carry)
                return unavailable(reason, nowUnix: nowUnix, interval: liveIntervalMinutes, carry: carry)
            }
            let win = openTail.applyLookbacks(rawWin)
            let clsRaw = WatchdogActivityClass.labels(logits: win.activityLogits).last ?? "unknown"
            let cls = WatchdogActivityClass.allCases.first(where: { $0.rawValue == clsRaw }) ?? .unknown
            let evidenced = WatchdogEventGeometry.evidencedClass(window: win, tail: openTail, logitCls: cls)
            let phase = WatchdogPhaseUsualStore.phase(nowUnix: nowUnix, sleepBit: sleepNow)
            let fam = WatchdogPhaseUsualStore.family(label: .normalStillAwake, cls: evidenced)
            let blendFam: WatchdogActivityFamily = openTail.stillNow ? .still : fam
            let livePrompt = carry.phaseUsual.blendPrompt(prompt, key: WatchdogPhaseKey(phase: phase, family: blendFam))
            var modelWin = win
            modelWin.maskStaleChannels()
            let residual: UniTSResidual
            do {
                residual = try UniTSRuntime().reconstruct(modelWin, prompt: livePrompt, tail: openTail)
            } catch {
                if safetyCap(window: win) {
                    return safetyDuringQualityFail(window: win, nowUnix: nowUnix,
                                                   interval: liveIntervalMinutes, carry: carry,
                                                   liveAlerts: liveAlerts)
                }
                rememberSafety(hit: nil, nowUnix: nowUnix, carry: &carry)
                return unavailable(.empty, nowUnix: nowUnix, interval: liveIntervalMinutes, carry: carry)
            }
            return combine(window: modelWin, display: win, residual: residual, prompt: livePrompt,
                           evaluations: evaluations,
                           dayLog: dayLog, nowUnix: nowUnix, interval: liveIntervalMinutes, carry: &carry,
                           sleepSessionOpen: sleepSessionOpen, skipForecast: skipForecast,
                           liveAlerts: liveAlerts)
        }
    }

    /// Yesterday’s confounder only while that sleep session is still open.
    public static func liveDayLog(today: LBDayLog?, yesterday: LBDayLog?, sleepOpen: Bool) -> LBDayLog? {
        if today?.confoundsUsual == true { return today }
        if sleepOpen, yesterday?.confoundsUsual == true { return yesterday }
        return today
    }

    /// Live card **Off**. Same door as severity / safety / personal-off. Not a painted-band leftover.
    public static func liveOff(severity: WatchdogSeverity, safety: Bool, personalOff: Bool) -> Bool {
        if safety { return true }
        if personalOff { return true }
        switch severity {
        case .candidate, .active, .severe: return true
        case .withinLimits, .note, .dataUnavailable: return false
        }
    }

    public static func liveOff(_ result: WatchdogResult) -> Bool { result.liveOff }

    /// Band / tape / IMU may learn. Detection already ran in `evaluate`.
    public static func shouldTrainUsual(result: WatchdogResult, dayLog: LBDayLog?) -> Bool {
        guard result.unavailable == nil else { return false }
        switch result.severity {
        case .candidate, .active, .severe, .dataUnavailable:
            return false
        case .withinLimits, .note:
            break
        }
        return dayLog?.confoundsUsual != true
    }

    public enum WatchdogInject: String, Sendable {
        case quiet
        case severe
        case walk
        case learning
        case wristOff
    }

    static func combine(window: WatchdogWindow,
                        display: WatchdogWindow? = nil,
                        residual: UniTSResidual,
                        prompt: UniTSPrompt,
                        evaluations: [LBEvaluation],
                        dayLog: LBDayLog?,
                        nowUnix: Int,
                        interval: Int,
                        carry: inout WatchdogCarry,
                        sleepSessionOpen: Bool = false,
                        skipForecast: Bool = false,
                        liveAlerts: Bool = true) -> WatchdogResult {
        let shown = display ?? window
        let confounded = dayLog?.confoundsUsual == true
        let tail = WatchdogLiveTail.resolve(window)
        if tail.lastEffortEndUnix > carry.lastWorkoutEndUnix {
            carry.lastWorkoutEndUnix = tail.lastEffortEndUnix
        }
        if tail.period == .rest, tail.previousPeriod == .effort {
            carry.dirEma = Array(repeating: 0, count: 6)
        }
        func freshPair(_ obs: [Double?], _ hat: [Double?], channel: Int) -> (obs: Double, hat: Double)? {
            let pair = UniTSRuntime.lastPaired(obs, hat, from: tail.startIndex)
            guard pair != nil else { return nil }
            let age = WatchdogQuality.channelFreshnessSeconds(channel: channel, family: window.family)
            guard WatchdogQuality.channelFresh(obs, startUnix: window.startUnix, nowUnix: nowUnix,
                                               channel: channel, family: window.family) else {
                return nil
            }
            _ = age
            return pair
        }
        let lastHR = freshPair(window.hr, residual.reconstructedHR, channel: 0)
        let lastRHR = freshPair(window.rhr, residual.reconstructedRHR, channel: 1)
        let lastHRV = freshPair(window.hrv, residual.reconstructedHRV, channel: 2)
        let lastTemp = freshPair(window.temp, residual.reconstructedTemp, channel: 3)
        let lastResp = freshPair(window.resp, residual.reconstructedResp, channel: 4)
        let lastSpO2 = freshPair(window.spo2, residual.reconstructedSpO2, channel: 5)
        let clsRaw = WatchdogActivityClass.labels(logits: window.activityLogits).last ?? "unknown"
        let logitCls = WatchdogActivityClass.allCases.first(where: { $0.rawValue == clsRaw }) ?? .unknown
        let cls = WatchdogEventGeometry.evidencedClass(window: window, tail: tail, logitCls: logitCls)
        let famName = WatchdogEventGeometry.family(of: cls)
        if carry.lastActivityFamily.isEmpty {
            carry.lastActivityFamily = famName
            if WatchdogEventGeometry.isExercise(cls) {
                carry.familyChangedUnix = nowUnix
                carry.familyStableTicks = 1
            } else {
                carry.familyChangedUnix = nowUnix - WatchdogEventLabeler.familyHoldSeconds
                carry.familyStableTicks = WatchdogEventLabeler.familyHoldSeconds / WatchdogConfig.tickSeconds
            }
        } else if famName == carry.lastActivityFamily {
            carry.familyStableTicks += 1
        } else {
            if WatchdogEventGeometry.isExercise(
                WatchdogActivityClass.allCases.first(where: { WatchdogEventLabeler.family(of: $0) == carry.lastActivityFamily }) ?? .unknown
            ) && !WatchdogEventGeometry.isExercise(cls) {
                carry.lastWorkoutEndUnix = max(carry.lastWorkoutEndUnix, nowUnix)
            }
            carry.familyChangedUnix = nowUnix
            carry.familyStableTicks = 1
            carry.lastActivityFamily = famName
        }
        var adapted = WatchdogAdaptive.apply(residual, window: window,
                                             lastHR: lastHR, lastRHR: lastRHR, lastHRV: lastHRV,
                                             lastTemp: lastTemp, lastResp: lastResp, lastSpO2: lastSpO2,
                                             carry: &carry, tail: tail)
        if carry.sessionUnix > 0 && nowUnix - carry.sessionUnix > 4 * 3600 {
            carry.resetSessionAbsOnly()
        }
        let rhrAllowed = tail.stillNow
        let rawR: [Double?] = [
            WatchdogDirection.signedR(obs: lastHR?.obs, hat: lastHR?.hat, scale: adapted.scaleHR.last ?? 1),
            WatchdogDirection.signedR(obs: lastRHR?.obs, hat: lastRHR?.hat, scale: adapted.scaleRHR.last ?? 1),
            WatchdogDirection.signedR(obs: lastHRV?.obs, hat: lastHRV?.hat, scale: adapted.scaleHRV.last ?? 1),
            WatchdogDirection.signedR(obs: lastTemp?.obs, hat: lastTemp?.hat, scale: adapted.scaleTemp.last ?? 1),
            WatchdogDirection.signedR(obs: lastResp?.obs, hat: lastResp?.hat, scale: adapted.scaleResp.last ?? 1),
            WatchdogDirection.signedR(obs: lastSpO2?.obs, hat: lastSpO2?.hat, scale: adapted.scaleSpO2.last ?? 1)
        ]
        let artifact = WatchdogActivityRuntime.isArtifact(window.activityLogits, from: tail.startIndex)
        let direction = WatchdogDirection.compute(rawR: rawR, rhrAllowed: rhrAllowed, artifact: artifact,
                                                  dirEma: &carry.dirEma)
        let labelJ = direction.joint
        let reconJ = direction.severityJoint
        adapted.jointEnergy = reconJ
        let present = rawR.map { $0 != nil }
        var absR = [Double](repeating: 0, count: 6)
        for k in 0..<min(6, rawR.count) {
            if let r = rawR[k] { absR[k] = abs(r) }
        }
        let safety = WatchdogSafety.fired(window)
        rememberSafety(hit: safetyHit(window: window), nowUnix: nowUnix, carry: &carry)
        let previousSafety = carry.lastSafety
        let previousFused = carry.lastJointEnergy
        let eHR = tail.energy(obs: window.hr, hat: adapted.reconstructedHR,
                              scale: adapted.scaleHR, floor: WatchdogConfig.hrScale)
        let eRHR = tail.energy(obs: window.rhr, hat: adapted.reconstructedRHR,
                               scale: adapted.scaleRHR, floor: WatchdogConfig.hrScale)
        let eHRV = tail.energy(obs: window.hrv, hat: adapted.reconstructedHRV,
                               scale: adapted.scaleHRV, floor: WatchdogConfig.hrvScale)
        let eTemp = tail.energy(obs: window.temp, hat: adapted.reconstructedTemp,
                                scale: adapted.scaleTemp, floor: WatchdogConfig.tempScale)
        let eResp = tail.energy(obs: window.resp, hat: adapted.reconstructedResp,
                                scale: adapted.scaleResp, floor: WatchdogConfig.respScale)
        let eSpO2 = tail.energy(obs: window.spo2, hat: adapted.reconstructedSpO2,
                                scale: adapted.scaleSpO2, floor: WatchdogConfig.spo2Scale)
        carry.quietJointEma = 0
        let forecast = WatchdogForecastRuntime().step(window: window, residual: adapted, prompt: prompt,
                                                     carry: carry, nowUnix: nowUnix, tail: tail,
                                                     skipForecast: skipForecast)
        let fcUsual = WatchdogForecastRuntime.pathCenter(residual: adapted, prompt: prompt)
        let fcScale = [
            adapted.scaleHR.last ?? WatchdogConfig.hrScale,
            adapted.scaleRHR.last ?? WatchdogConfig.hrScale,
            adapted.scaleHRV.last ?? WatchdogConfig.hrvScale,
            adapted.scaleTemp.last ?? WatchdogConfig.tempScale,
            adapted.scaleResp.last ?? WatchdogConfig.respScale,
            adapted.scaleSpO2.last ?? WatchdogConfig.spo2Scale
        ]
        let fcPath = WatchdogForecastRuntime.pathScore(forecast, usual: fcUsual, scales: fcScale,
                                                       artifact: artifact)
        let forecastLabelJ = fcPath.labelJoint
        let forecastJ = fcPath.severityJoint
        if labelJ >= WatchdogCalibration.tNote { carry.reconAboveTicks += 1 } else { carry.reconAboveTicks = 0 }
        if forecastLabelJ >= WatchdogCalibration.tNote { carry.forecastAboveTicks += 1 } else { carry.forecastAboveTicks = 0 }
        let postWorkout = tail.postWorkout(carryEndUnix: carry.lastWorkoutEndUnix, nowUnix: nowUnix)
        let sleepBit = sleepSessionOpen
            || WatchdogEventLabeler.sleepIntervalOpen(window.sleepIntervals, unix: nowUnix)
            || (window.activityFeatures.last.map { WatchdogActivityFeatures.sleepBit($0) == 1 } ?? false)
        let sleepEdge = WatchdogEventLabeler.sleepIntervalEdge(window.sleepIntervals, unix: nowUnix)
        let eventAge = carry.lastEventStartUnix > 0 ? nowUnix - carry.lastEventStartUnix : 0
        let spo2Hot = eSpO2 >= WatchdogCalibration.tNote
        let familyHeld = WatchdogEventLabeler.familyHeld(nowUnix: nowUnix, changedUnix: carry.familyChangedUnix)
        let sig = WatchdogEventMemory.signature(
            d: direction.d, reconJ: labelJ, forecastJ: forecastLabelJ,
            cls: cls, spo2Abs: absR[5])
        let decision = WatchdogEventGeometry.resolve(
            cls: cls,
            familyStableTicks: carry.familyStableTicks,
            previousFamily: carry.lastEventFamily,
            reconJ: labelJ,
            forecastJ: forecastLabelJ,
            previousReconJ: carry.lastReconEnergy,
            previousForecastJ: carry.lastForecastJoint,
            reconAboveTicks: carry.reconAboveTicks,
            forecastAboveTicks: carry.forecastAboveTicks,
            safety: safety,
            artifact: artifact,
            postWorkout: postWorkout,
            sleep: sleepBit,
            hrHot: eHR >= WatchdogCalibration.tNote,
            breadth: direction.breadth,
            eventAgeSeconds: eventAge,
            spo2Hot: spo2Hot,
            maxAbsR: absR.max() ?? 0,
            signature: sig,
            memory: &carry.eventMemory,
            familyHeld: familyHeld,
            sleepEdge: sleepEdge,
            familyChangedUnix: carry.familyChangedUnix,
            nowUnix: nowUnix
        )
        if decision.label != .mixedRejected {
            if decision.cut {
                if decision.cutReason == "class-hold", carry.familyChangedUnix > 0 {
                    carry.lastEventStartUnix = carry.familyChangedUnix
                } else {
                    carry.lastEventStartUnix = nowUnix
                }
                carry.lastEventFamily = famName
            } else if carry.lastEventStartUnix == 0 {
                carry.lastEventStartUnix = nowUnix
                if carry.lastEventFamily.isEmpty { carry.lastEventFamily = famName }
            }
        } else if carry.lastEventStartUnix == 0 {
            carry.lastEventStartUnix = nowUnix
        }
        carry.lastCutReason = decision.cutReason
        carry.lastEventLabel = decision.label.rawValue
        carry.lastActivityFamily = famName
        carry.lastForecastJoint = forecastLabelJ
        carry.lastForecastSource = forecast.source
        if forecast.source == "student" || forecast.source == "inject" {
            carry.forecastJRing.append(forecastLabelJ)
            if carry.forecastJRing.count > 30 {
                carry.forecastJRing.removeFirst(carry.forecastJRing.count - 30)
            }
        }
        var eventHint = decision.label
        var hot: [String] = []
        if eHR >= WatchdogCalibration.tNote { hot.append("HR") }
        if eRHR >= WatchdogCalibration.tNote { hot.append("RHR") }
        if eHRV >= WatchdogCalibration.tNote { hot.append("HRV") }
        if eTemp >= WatchdogCalibration.tNote { hot.append("Temp") }
        if eResp >= WatchdogCalibration.tNote { hot.append("Resp") }
        if eSpO2 >= WatchdogCalibration.tNote { hot.append("SpO2") }
        let personalOff = evaluations.contains {
            $0.alertEligible && LongitudinalBaseline.isOffUsual(z: $0.zLong, k: $0.kBandUsed)
        } || personalNativeOff(hrBpm: lastHR?.obs, hrvMs: lastHRV?.obs, evaluations: evaluations)
        let persistMinute = nowUnix - nowUnix % WatchdogConfig.gridSeconds
        let obsMinute = latestValidObsMinute(window: window)
        let vitalMarks = WatchdogPhysiologyAlert.marks(absR: absR, mask: present)
        let physiologyOff = WatchdogPhysiologyAlert.shouldAlert(
            marks: vitalMarks, safety: safety, personalOff: personalOff)
        if persistMinute > carry.lastPersistMinute,
           let obs = obsMinute, obs > carry.lastPersistObsMinute {
            if reconJ >= WatchdogCalibration.tNote || personalOff {
                carry.consecutiveMismatchTicks += 1
                carry.consecutiveInRangeTicks = 0
                carry.consecutiveQuietTicks = 0
            } else {
                carry.consecutiveMismatchTicks = 0
                carry.consecutiveInRangeTicks += 1
                carry.consecutiveQuietTicks = carry.consecutiveInRangeTicks
            }
            carry.lastPersistMinute = persistMinute
            carry.lastPersistObsMinute = obs
        }
        let persistTicks = carry.consecutiveMismatchTicks

        let severity = WatchdogScores.severity(recon: reconJ, forecast: forecastJ, persistTicks: persistTicks,
                                               safety: safety, confounded: confounded, personalOff: personalOff)
        if severity == .severe && !safety {
            switch eventHint {
            case .normalStillAwake, .normalSleep, .forecastDriftOnly,
                 .workoutWalk, .workoutRun, .workoutCycle, .workoutLift, .postWorkout:
                eventHint = direction.breadth >= 0.34 ? .abnormalMultiDirection : .abnormalStillTachycardia
            default:
                break
            }
        }
        if WatchdogEventLabeler.earlyAllowed(eventHint) && forecastLabelJ >= WatchdogCalibration.tNote
            && severity != .severe && severity != .active {
            carry.earlyTicks += 1
        } else {
            carry.earlyTicks = 0
        }

        let hadEpisode = carry.episodeId != nil
        if severity == .withinLimits || severity == .note {
            // keep episode id while recovering
        } else if carry.episodeId == nil {
            carry.episodeId = "wd-\(nowUnix)"
        }
        let openedEpisode = !hadEpisode && carry.episodeId != nil
            && (severity == .candidate || severity == .active || severity == .severe)

        let state = nextState(severity: severity, carry: &carry)
        let (notify, reason) = WatchdogNotifyPolicy.decision(severity: severity, openedEpisode: openedEpisode,
                                                            safety: safety, previousSafety: previousSafety,
                                                            fused: reconJ, previousFused: previousFused,
                                                            recon: reconJ, previousRecon: previousFused,
                                                            eventLabel: eventHint,
                                                            episodeId: carry.episodeId,
                                                            notifiedSevereEpisodeId: carry.notifiedSevereEpisodeId,
                                                            lastNotifiedAt: carry.lastNotifiedAt,
                                                            nowUnix: nowUnix,
                                                            notifyDelivery: carry.notifyDelivery)
        let allowNotify = notify && liveAlerts && (safety || physiologyOff)
        if allowNotify {
            carry.lastNotifiedAt = nowUnix
            carry.notifyDelivery = "queued"
            // notifiedSevereEpisodeId is stamped only after a successful send.
        }
        carry.lastJointEnergy = reconJ
        carry.lastReconEnergy = labelJ
        carry.lastSafety = safety
        if forecast.studentOk {
            if forecast.ranStudent { carry.lastForecastUnix = nowUnix }
            carry.forecastStudentOk = true
            carry.lastForecastHR = forecast.nextHR
            carry.lastForecastHRV = forecast.nextHRV
            carry.lastForecastTemp = forecast.nextTemp
            carry.lastForecastResp = forecast.nextResp
            carry.lastForecastRHR = forecast.nextRHR
            carry.lastForecastSpO2 = forecast.nextSpO2
            if forecast.horizonUnix.count == WatchdogCalibration.forecastHorizon {
                carry.lastForecastHorizonUnix = forecast.horizonUnix
            }
        } else {
            carry.forecastStudentOk = false
        }

        let trustCoverage = (tail.endedPeriod && tail.stillNow)
            ? tail.hrCoverage(window.hr) : window.coverage
        let trustHR = predictionTrust(energy: eHR, usual: prompt.hr, coverage: trustCoverage,
                                      usualTrust: layer1UsualTrust(evaluations, matching: [.awakeRestHR, .continuousHR]),
                                      persistTicks: persistTicks, hot: hot.contains("HR"),
                                      hat: lastHR?.hat)
        let trustRHR = predictionTrust(energy: eRHR, usual: prompt.rhr, coverage: trustCoverage,
                                       usualTrust: layer1UsualTrust(evaluations, matching: [.sleepRHR]),
                                       persistTicks: persistTicks, hot: hot.contains("RHR"),
                                       hat: lastRHR?.hat)
        let trustHRV = predictionTrust(energy: eHRV, usual: prompt.hrvAwake ?? prompt.hrv, coverage: trustCoverage,
                                       usualTrust: layer1UsualTrust(evaluations, matching: prompt.hrvAwake != nil
                                                                 ? [.awakeRestHRVLn] : [.sleepHRVLn]),
                                       persistTicks: persistTicks, hot: hot.contains("HRV"),
                                       hat: lastHRV?.hat)
        let tempC = sparseCoverage(window.temp, startUnix: window.startUnix, nowUnix: nowUnix,
                                   channel: 3, family: window.family)
        let respC = sparseCoverage(window.resp, startUnix: window.startUnix, nowUnix: nowUnix,
                                   channel: 4, family: window.family)
        let spo2C = sparseCoverage(window.spo2, startUnix: window.startUnix, nowUnix: nowUnix,
                                   channel: 5, family: window.family)
        let trustTemp = holdSparseTrust(
            computed: predictionTrust(energy: eTemp, usual: prompt.temp, coverage: tempC,
                                      usualTrust: layer1UsualTrust(evaluations, matching: [.sleepTemp]),
                                      persistTicks: persistTicks, hot: hot.contains("Temp"),
                                      hat: lastTemp?.hat),
            obs: lastTemp?.obs,
            stillInWindow: shown.temp.contains { $0 != nil },
            heldTrust: &carry.sparseTrust.tempTrust,
            heldObs: &carry.sparseTrust.tempObs)
        let trustResp = holdSparseTrust(
            computed: predictionTrust(energy: eResp, usual: prompt.resp, coverage: respC,
                                      usualTrust: layer1UsualTrust(evaluations, matching: [.sleepResp]),
                                      persistTicks: persistTicks, hot: hot.contains("Resp"),
                                      hat: lastResp?.hat),
            obs: lastResp?.obs,
            stillInWindow: shown.resp.contains { $0 != nil },
            heldTrust: &carry.sparseTrust.respTrust,
            heldObs: &carry.sparseTrust.respObs)
        let trustSpO2 = holdSparseTrust(
            computed: predictionTrust(energy: eSpO2, usual: prompt.spo2, coverage: spo2C,
                                      usualTrust: layer1UsualTrust(evaluations, matching: [.sleepSpO2Mean]),
                                      persistTicks: persistTicks, hot: hot.contains("SpO2"),
                                      hat: lastSpO2?.hat),
            obs: lastSpO2?.obs,
            stillInWindow: shown.spo2.contains { $0 != nil },
            heldTrust: &carry.sparseTrust.spo2Trust,
            heldObs: &carry.sparseTrust.spo2Obs)

        let sessionPhase = WatchdogPhaseUsualStore.phase(nowUnix: nowUnix,
                                                        sleepBit: sleepSessionOpen || sleepBit)
        let bandFam = WatchdogPhaseUsualStore.bandFamily(label: eventHint, cls: cls,
                                                          tailPeriod: tail.period)
        let phaseKey = WatchdogPhaseKey(phase: sessionPhase, family: bandFam)
        carry.migrateLegacyBandIfNeeded(into: WatchdogPhaseKey(phase: sessionPhase, family: .still))
        if !carry.lastBandKey.isEmpty, carry.lastBandKey != phaseKey.id {
            carry.quietAbsHR = 0; carry.quietAbsRHR = 0; carry.quietAbsHRV = 0
            carry.quietAbsTemp = 0; carry.quietAbsResp = 0; carry.quietAbsSpO2 = 0
            carry.quietN = 0
        }
        let recovering = carry.lastWorkoutEndUnix > 0
            && nowUnix - carry.lastWorkoutEndUnix < WatchdogEventLabeler.postWorkoutSeconds
        let presentMax = zip(absR, present).compactMap { $0.1 ? $0.0 : nil }.max() ?? 0
        let bandLearn = WatchdogBand.learnable(eventHint) && bandFam != .other && !safety
            && reconJ < WatchdogCalibration.tNote && !hot.contains("HR")
            && presentMax < WatchdogBand.residualCap && !confounded && !recovering
            && !personalOff
            && severity != .candidate && severity != .active && severity != .severe
        let sessionElig = WatchdogEventLabeler.sidecarEligible(eventHint) && !safety
            && reconJ < WatchdogCalibration.tNote && !hot.contains("HR")
            && presentMax < WatchdogBand.residualCap && !confounded && !recovering
            && !personalOff
            && severity != .candidate && severity != .active && severity != .severe
        if sessionElig {
            if carry.sessionAbs.count < 6 { carry.sessionAbs = Array(repeating: 0, count: 6) }
            if carry.sessionNative.count < 6 { carry.sessionNative = Array(repeating: 0, count: 6) }
            if carry.sessionNativeCount.count < 6 { carry.sessionNativeCount = Array(repeating: 0, count: 6) }
            let a = 0.12
            if carry.lastNativeMinute.count < 6 { carry.lastNativeMinute = Array(repeating: 0, count: 6) }
            let priorMinute = carry.lastNativeMinute
            let series: [[Double?]] = [window.hr, window.rhr, window.hrv, window.temp, window.resp, window.spo2]
            for k in 0..<6 where present[k] {
                let minute = WatchdogQuality.lastFiniteMinuteUnix(series[k], startUnix: window.startUnix) ?? 0
                guard minute > carry.lastNativeMinute[k] else { continue }
                carry.sessionAbs[k] = (1 - a) * carry.sessionAbs[k] + a * absR[k]
            }
            let nativeObs: [Double?] = [lastHR?.obs, lastRHR?.obs, lastHRV?.obs,
                                        lastTemp?.obs, lastResp?.obs, lastSpO2?.obs]
            for k in 0..<6 {
                guard let obs = nativeObs[k], obs.isFinite else { continue }
                let minute = WatchdogQuality.lastFiniteMinuteUnix(series[k], startUnix: window.startUnix) ?? 0
                guard minute > carry.lastNativeMinute[k] else { continue }
                if carry.sessionNativeCount[k] == 0 {
                    carry.sessionNative[k] = obs
                } else {
                    carry.sessionNative[k] = (1 - a) * carry.sessionNative[k] + a * obs
                }
                carry.sessionNativeCount[k] += 1
                carry.lastNativeMinute[k] = minute
            }
            let sessionKey = WatchdogPhaseKey(phase: sessionPhase, family: .still)
            carry.sessionLastUnix = nowUnix
            var keyed = carry.sessionNativeByKey[sessionKey.id] ?? Array(repeating: 0, count: 6)
            var keyedCount = carry.sessionNativeCountByKey[sessionKey.id] ?? Array(repeating: 0, count: 6)
            if keyed.count < 6 { keyed = Array(repeating: 0, count: 6) }
            if keyedCount.count < 6 { keyedCount = Array(repeating: 0, count: 6) }
            for k in 0..<6 {
                guard let obs = nativeObs[k], obs.isFinite else { continue }
                let minute = WatchdogQuality.lastFiniteMinuteUnix(series[k], startUnix: window.startUnix) ?? 0
                guard minute > priorMinute[k] else { continue }
                if keyedCount[k] == 0 {
                    keyed[k] = obs
                } else {
                    keyed[k] = (1 - a) * keyed[k] + a * obs
                }
                keyedCount[k] += 1
            }
            carry.sessionNativeByKey[sessionKey.id] = keyed
            carry.sessionNativeCountByKey[sessionKey.id] = keyedCount
            let advanced = (0..<6).contains { $0 < carry.lastNativeMinute.count
                && $0 < priorMinute.count && carry.lastNativeMinute[$0] > priorMinute[$0] }
            if advanced {
                carry.sessionN += 1
                carry.sessionNativeN += 1
                carry.sessionKeyTicks[sessionKey.id, default: 0] += 1
            }
            carry.sessionUnix = nowUnix
        }
        var bandState = carry.bandByKey[phaseKey.id] ?? .empty
        var bandGain: [Double]
        let seriesForMinutes: [[Double?]] = [window.hr, window.rhr, window.hrv,
                                             window.temp, window.resp, window.spo2]
        let sampleMinute = seriesForMinutes.map {
            WatchdogQuality.lastFiniteMinuteUnix($0, startUnix: window.startUnix) ?? 0
        }
        if WatchdogBand.learnable(eventHint), bandFam != .other {
            bandGain = WatchdogBand.update(&bandState, absResidual: absR, eligible: bandLearn,
                                          nowUnix: nowUnix, present: present,
                                          sampleMinute: sampleMinute)
            carry.bandByKey[phaseKey.id] = bandState
            carry.mirrorBand(bandState, key: phaseKey.id)
        } else {
            bandGain = Array(repeating: 1.0, count: 6)
            carry.lastBandKey = phaseKey.id
        }
        if bandState.ready {
            if carry.sessionN >= 8 {
                for k in 0..<6 {
                    guard WatchdogBand.channelReady(bandState, k) else { continue }
                    guard k < carry.sessionAbs.count else { continue }
                    let g = min(1.05, max(0.95, 1.0 + 0.02 * (carry.sessionAbs[k] - 0.4)))
                    bandGain[k] = min(WatchdogBand.clampHi, max(WatchdogBand.clampLo, bandGain[k] * g))
                }
            }
            if WatchdogBand.channelReady(bandState, 0) {
                adapted.scaleHR = WatchdogBand.apply([bandGain[0]], to: adapted.scaleHR)
            }
            if WatchdogBand.channelReady(bandState, 1) {
                adapted.scaleRHR = WatchdogBand.apply([bandGain[1]], to: adapted.scaleRHR)
            }
            if WatchdogBand.channelReady(bandState, 2) {
                adapted.scaleHRV = WatchdogBand.apply([bandGain[2]], to: adapted.scaleHRV)
            }
            if WatchdogBand.channelReady(bandState, 3) {
                adapted.scaleTemp = WatchdogBand.apply([bandGain[3]], to: adapted.scaleTemp)
            }
            if WatchdogBand.channelReady(bandState, 4) {
                adapted.scaleResp = WatchdogBand.apply([bandGain[4]], to: adapted.scaleResp)
            }
            if WatchdogBand.channelReady(bandState, 5) {
                adapted.scaleSpO2 = WatchdogBand.apply([bandGain[5]], to: adapted.scaleSpO2)
            }
        }
        adapted.rangeHalf[.hr] = adapted.scaleHR.last ?? adapted.rangeHalf[.hr] ?? 0
        adapted.rangeHalf[.rhr] = adapted.scaleRHR.last ?? adapted.rangeHalf[.rhr] ?? 0
        adapted.rangeHalf[.hrv] = adapted.scaleHRV.last ?? adapted.rangeHalf[.hrv] ?? 0
        adapted.rangeHalf[.temp] = adapted.scaleTemp.last ?? adapted.rangeHalf[.temp] ?? 0
        adapted.rangeHalf[.resp] = adapted.scaleResp.last ?? adapted.rangeHalf[.resp] ?? 0
        adapted.rangeHalf[.spo2] = adapted.scaleSpO2.last ?? adapted.rangeHalf[.spo2] ?? 0

        let signals: [WatchdogSignalEvidence] = [
            .init(name: "HR", observed: lastHR?.obs, usual: prompt.hr,
                  reconstructed: lastHR?.hat, energy: eHR, unit: "bpm", trustPct: trustHR,
                  rangeHalf: adapted.rangeHalf(for: .hr)),
            .init(name: "RHR", observed: lastRHR?.obs, usual: prompt.rhr,
                  reconstructed: lastRHR?.hat, energy: eRHR, unit: "bpm", trustPct: trustRHR,
                  rangeHalf: adapted.rangeHalf(for: .rhr)),
            .init(name: "HRV", observed: lastHRV?.obs, usual: prompt.hrvAwake ?? prompt.hrv,
                  reconstructed: lastHRV?.hat, energy: eHRV, unit: "ms", trustPct: trustHRV,
                  rangeHalf: adapted.rangeHalf(for: .hrv)),
            .init(name: "Temp", observed: lastTemp?.obs ?? last(shown.temp), usual: prompt.temp,
                  reconstructed: lastTemp?.hat, energy: eTemp, unit: "°C", trustPct: trustTemp,
                  rangeHalf: adapted.rangeHalf(for: .temp)),
            .init(name: "Resp", observed: lastResp?.obs ?? last(shown.resp), usual: prompt.resp,
                  reconstructed: lastResp?.hat, energy: eResp, unit: "/min", trustPct: trustResp,
                  rangeHalf: adapted.rangeHalf(for: .resp)),
            .init(name: "SpO2", observed: lastSpO2?.obs ?? last(shown.spo2), usual: prompt.spo2,
                  reconstructed: lastSpO2?.hat, energy: eSpO2, unit: "%", trustPct: trustSpO2,
                  rangeHalf: adapted.rangeHalf(for: .spo2)),
            .init(name: "Motion", observed: last(window.motion), usual: nil,
                  reconstructed: nil, energy: 0, unit: "", trustPct: 0)
        ]

        carry.lastHeldResp = nil
        carry.lastHeldHRV = nil
        carry.lastHeldTemp = nil
        carry.lastHeldSpO2 = nil

        let scoredTrusts = signals.filter {
            $0.name != "Motion" && $0.observed != nil && $0.reconstructed != nil && $0.trustPct > 0
        }.map(\.trustPct)
        let pageTrust: Int
        if hot.isEmpty {
            pageTrust = scoredTrusts.min() ?? Int((window.coverage * 100).rounded())
        } else {
            pageTrust = signals.filter { hot.contains($0.name) && $0.trustPct > 0 }.map(\.trustPct).min()
                ?? scoredTrusts.min() ?? 0
        }
        if pageTrust < WatchdogForecastRuntime.earlyTrustFloor {
            carry.earlyTicks = 0
        }
        let early = WatchdogForecastRuntime.wearerEarly(
            pathJ: forecastLabelJ,
            allowed: WatchdogEventLabeler.earlyAllowed(eventHint),
            severity: severity,
            trustPct: pageTrust,
            persistTicks: carry.earlyTicks,
            forecastSource: forecast.source)

        let civil = Self.civilDay(nowUnix)
        if carry.lastCivilDay.isEmpty { carry.lastCivilDay = civil }
        if civil != carry.lastCivilDay {
            for key in WatchdogPhaseUsualStore.qualifyingStillKeys(ticks: carry.sessionKeyTicks) {
                let native = carry.sessionNativeByKey[key.id] ?? carry.sessionNative
                let counts = carry.sessionNativeCountByKey[key.id] ?? carry.sessionNativeCount
                let present = (0..<6).map { $0 < counts.count && counts[$0] >= 8 }
                if present[0] || present[3] {
                    carry.phaseUsual.writeDay(key: key, dayMedian: native,
                                              present: present, civilDay: carry.lastCivilDay)
                }
            }
            carry.resetSessionBuffers()
            carry.lastCivilDay = civil
        }

        var copy = copyFor(severity: severity, state: state, confounded: confounded)
        if early && severity != .severe {
            copy = ("This stretch is leaving the expected path.",
                    "Early · leaving the expected path · not a diagnosis")
        } else if direction.breadth >= 0.5 && reconJ >= WatchdogCalibration.tNote && severity != .severe {
            copy = (copy.headline, "Several readings moving together · not a diagnosis")
        }

        let painted = UniTSRuntime.paintRanges(
            residual: adapted, occupancy: UniTSRuntime.occupancy(shown), prompt: prompt)

        return WatchdogResult(
            severity: severity,
            episodeState: state,
            episodeId: carry.episodeId,
            headline: copy.headline,
            episodeLine: copy.episodeLine,
            monitoringCurrent: window.newestAgeSeconds <= 180,
            monitoringLabel: window.newestAgeSeconds <= 180 ? "CURRENT" : "WAITING",
            mode: "live",
            unavailable: nil,
            coverage: window.coverage,
            hrSource: window.hrSource.rawValue,
            family: window.family.rawValue,
            lastTickUnix: nowUnix,
            windowStartUnix: window.startUnix,
            horizonHR: shown.hr.map { $0 ?? .nan },
            horizonHRV: shown.hrv.map { $0 ?? .nan },
            horizonTemp: shown.temp.map { $0 ?? .nan },
            horizonResp: shown.resp.map { $0 ?? .nan },
            horizonRHR: shown.rhr.map { $0 ?? .nan },
            horizonSpO2: shown.spo2.map { $0 ?? .nan },
            reconstructedHR: adapted.reconstructedHR.map { $0 ?? .nan },
            reconstructedHRV: adapted.reconstructedHRV.map { $0 ?? .nan },
            reconstructedTemp: adapted.reconstructedTemp.map { $0 ?? .nan },
            reconstructedResp: adapted.reconstructedResp.map { $0 ?? .nan },
            reconstructedRHR: adapted.reconstructedRHR.map { $0 ?? .nan },
            reconstructedSpO2: adapted.reconstructedSpO2.map { $0 ?? .nan },
            rangeHR: painted.hr,
            rangeHRV: painted.hrv,
            rangeTemp: painted.temp,
            rangeResp: painted.resp,
            rangeRHR: painted.rhr,
            rangeSpO2: painted.spo2,
            signals: signals,
            contributing: hot,
            qualityLine: String(format: "HR fill %.0f%% · %@ · %@ · tick %ds",
                                window.coverage * 100,
                                WatchdogActivityRuntime.displayName(
                                    WatchdogActivityClass.labels(logits: window.activityLogits).last ?? "unknown"),
                                adapted.modelVersion == WatchdogConfig.fallbackModelVersion
                                    ? "prior fallback" : adapted.modelVersion,
                                WatchdogConfig.tickSeconds),
            versionLine: "\(WatchdogConfig.configVersion) · \(adapted.modelVersion)+\(WatchdogForecastRuntime.modelVersion) · episode \(carry.episodeId ?? "none")",
            shouldNotify: allowNotify,
            carry: carry,
            modelVersion: adapted.modelVersion,
            trustPct: pageTrust,
            jointEnergy: reconJ,
            forecastEnergy: forecastJ,
            fusedEnergy: reconJ,
            promptSource: prompt.source,
            notifyReason: reason,
            activityLabel: WatchdogActivityClass.labels(logits: window.activityLogits).last ?? WatchdogActivityClass.unknown.rawValue,
            activityDetail: WatchdogActivityRuntime.displayName(
                WatchdogActivityClass.labels(logits: window.activityLogits).last ?? WatchdogActivityClass.unknown.rawValue),
            sigmaAdaptive: bandState.ready,
            qualityGate: "bucket-v1",
            earlyFlag: early,
            direction: direction.d,
            directionMarks: direction.marks,
            eventLabel: eventHint.rawValue,
            calibrationSource: WatchdogCalibration.version,
            cutReason: decision.cutReason,
            eventExplained: decision.explained,
            forecastSource: forecast.source,
            liveOff: liveOff(severity: severity, safety: safety, personalOff: personalOff),
            personalOff: personalOff,
            physiologyOff: physiologyOff
        )
    }

    /// Held leftover. Early uses `WatchdogForecastRuntime.pathScore` on the 6×5 cube.
    static func forecastSigned(forecast: WatchdogForecastStep) -> [Double?] {
        Array(repeating: forecast.studentOk ? Optional<Double>.none : nil, count: 6)
    }

    static func civilDay(_ unix: Int) -> String {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// Layer 1 TRUST for the series that feed this live channel. Same pick order as the hat
    /// (`matching` first-wins). Two copies of one series are never averaged (`shownCopy`).
    static func layer1UsualTrust(_ evaluations: [LBEvaluation], matching: [LBSeries]) -> Int {
        for series in matching {
            if let ev = evaluations.first(where: { $0.series == series }),
               let shown = UniTSPrompt.shownCopy(ev) {
                return shown.trust
            }
        }
        return 0
    }

    /// Coverage for a sparse vital: fresh finite minutes / strip length. One pair is never 1.0.
    static func sparseCoverage(_ series: [Double?], startUnix: Int, nowUnix: Int,
                               channel: Int, family: DeviceFamily) -> Double {
        guard !series.isEmpty else { return 0 }
        var fresh = 0
        for i in 0..<series.count {
            guard series[i] != nil else { continue }
            let t = startUnix + i * WatchdogConfig.gridSeconds
            if nowUnix - t <= WatchdogQuality.channelFreshnessSeconds(channel: channel, family: family) {
                fresh += 1
            }
        }
        return Double(fresh) / Double(series.count)
    }

    /// Last fresh native vs the **stable** matching usual (logged-ill freeze / long). Not the walking 7-day, not the hat.
    static func personalReference(_ ev: LBEvaluation) -> (center: Double, spread: Double, k: Double)? {
        if let f = ev.usualFreeze, f.spreadLong > 0 {
            return (f.centerLong, f.spreadLong, ev.kBandUsed)
        }
        if ev.establishedLong || ev.showLong,
           let c = ev.copyLong?.center, let s = ev.copyLong?.spread, s > 0 {
            return (c, s, ev.kBandUsed)
        }
        return nil
    }

    static func personalNativeOff(hrvMs: Double?, evaluations: [LBEvaluation]) -> Bool {
        personalNativeOff(hrBpm: nil, hrvMs: hrvMs, evaluations: evaluations)
    }

    static func personalNativeOff(hrBpm: Double?, hrvMs: Double?, evaluations: [LBEvaluation]) -> Bool {
        if let hrvMs, hrvMs > 0 {
            for series in [LBSeries.awakeRestHRVLn, .sleepHRVLn, .continuousHRVLn] {
                guard let ev = evaluations.first(where: { $0.series == series }),
                      let ref = personalReference(ev),
                      let math = LongitudinalBaseline.toMath(hrvMs, series: series) else { continue }
                let z = (math - ref.center) / ref.spread
                if LongitudinalBaseline.isOffUsual(z: z, k: ref.k) { return true }
            }
        }
        if let hrBpm, hrBpm > 0 {
            for series in [LBSeries.awakeRestHR, .sleepRHR, .continuousHR] {
                guard let ev = evaluations.first(where: { $0.series == series }),
                      let ref = personalReference(ev) else { continue }
                let z = (hrBpm - ref.center) / ref.spread
                if LongitudinalBaseline.isOffUsual(z: z, k: ref.k) { return true }
            }
        }
        return false
    }

    /// TRUST for temp / breathing / SpO₂ stays put until that vital’s last observation changes.
    /// Sliding HR coverage and occupancy must not walk the number between samples.
    public static func holdSparseTrust(computed: Int, obs: Double?, stillInWindow: Bool,
                                       heldTrust: inout Int, heldObs: inout Double?) -> Int {
        if !stillInWindow {
            heldTrust = 0
            heldObs = nil
            return computed
        }
        if let obs, obs.isFinite {
            if heldTrust > 0, let prev = heldObs, abs(prev - obs) < 1e-6 {
                return heldTrust
            }
            heldTrust = computed
            heldObs = obs
            return computed
        }
        return heldTrust > 0 ? heldTrust : computed
    }

    /// Live TRUST — how much to believe this vital’s in-range / off call. Not health, not a diagnosis.
    ///
    /// `50×U + 35×C + 15×E`:
    /// - **U** short-term first: UniTS/prior hat for this channel (`0.55`) once the models have
    ///   reconstructed it. A shown Layer 1 usual replaces that with that copy’s TRUST 0…1.
    ///   Layer 1 nights tighten the prompt; they do not gate the half-hour call.
    /// - **C** coverage of this 30-minute (or rest-tail) window.
    /// - **E** evidence vs the reconstruction (`1 − energy/tau` in range; persist×magnitude if off).
    /// - Caps 18 / 28 apply only when there is **no hat and no shown usual** (nothing to compare).
    public static func predictionTrust(energy: Double, usual: Double?, coverage: Double,
                                       usualTrust: Int, persistTicks: Int, hot: Bool,
                                       hat: Double? = nil) -> Int {
        let coverage01 = max(0, min(1, coverage))
        let usual01 = max(0, min(1, Double(usualTrust) / 100.0))
        let hasLayer1 = usual != nil && usualTrust >= LongitudinalBaseline.trustHideThreshold
        let hasShortTerm = hat.map(\.isFinite) ?? false
        let u: Double
        if hasLayer1 {
            u = usual01
        } else if hasShortTerm {
            u = 0.55
        } else {
            u = 0
        }
        let tau = max(WatchdogCalibration.tNote, 0.01)
        let tauSevere = max(WatchdogCalibration.tSevere, 0.01)
        let evidence: Double
        if hot {
            let persist = min(1, Double(max(persistTicks, 0)) / 2.0)
            let magnitude = min(1, energy / tauSevere)
            evidence = 0.40 + 0.60 * magnitude * max(0.35, persist)
        } else {
            evidence = max(0, 1 - energy / tau)
        }
        var score = 50.0 * u + 35.0 * coverage01 + 15.0 * evidence
        if !hasLayer1 && !hasShortTerm {
            score = min(score, usual == nil ? 18 : 28)
        }
        return max(0, min(100, Int(score.rounded())))
    }

    static func safetyCap(window: WatchdogWindow) -> Bool {
        safetyHit(window: window) != nil
    }

    /// Fresh still-rest extrema, not the minute mean and not a UniTS residual.
    static func safetyHit(window: WatchdogWindow) -> (channel: String, value: Double)? {
        let tail = WatchdogLiveTail.resolve(window)
        guard confirmedStillForRestSafety(window) else { return nil }
        func freshLast(_ xs: [Double?], channel: Int) -> Double? {
            guard WatchdogQuality.channelFresh(xs, startUnix: window.startUnix, nowUnix: window.nowUnix,
                                              channel: channel, family: window.family) else {
                return nil
            }
            return tail.last(xs)
        }
        let highHR = window.hrMax.count == window.hr.count ? window.hrMax : window.hr
        let lowHR = window.hrMin.count == window.hr.count ? window.hrMin : window.hr
        if let hr = freshLast(highHR, channel: 0), hr > WatchdogConfig.restHrHigh {
            return ("HR", hr)
        }
        if let hr = freshLast(lowHR, channel: 0), hr > 0, hr < WatchdogConfig.restHrLow {
            return ("HR", hr)
        }
        if let t = freshLast(window.temp, channel: 3), t < WatchdogConfig.tempLowC || t > WatchdogConfig.tempHighC {
            return ("Temp", t)
        }
        if let r = freshLast(window.resp, channel: 4), r < WatchdogConfig.respLow || r > WatchdogConfig.respHigh {
            return ("Resp", r)
        }
        if let h = freshLast(window.hrv, channel: 2), h > 0,
           h < WatchdogConfig.rmssdLow || h > WatchdogConfig.rmssdHigh {
            return ("HRV", h)
        }
        return nil
    }

    static func rememberSafety(hit: (channel: String, value: Double)?, nowUnix: Int,
                               carry: inout WatchdogCarry) {
        if let hit {
            if carry.safetyFirstUnix == 0 { carry.safetyFirstUnix = nowUnix }
            carry.safetyChannel = hit.channel
            carry.safetyExtreme = hit.value
        } else {
            carry.safetyFirstUnix = 0
            carry.safetyChannel = ""
            carry.safetyExtreme = 0
        }
    }

    /// Thin UniTS window still pages when a fresh still-rest vital is out of range.
    static func safetyDuringQualityFail(window: WatchdogWindow, nowUnix: Int, interval: Int,
                                        carry: WatchdogCarry, liveAlerts: Bool) -> WatchdogResult {
        let previousSafety = carry.lastSafety
        var carry = carry
        rememberSafety(hit: safetyHit(window: window), nowUnix: nowUnix, carry: &carry)
        carry.lastSafety = true
        carry.consecutiveQuietTicks = 0
        if carry.episodeId == nil {
            carry.episodeId = "wd-safety-\(nowUnix)"
        }
        let (want, reason) = WatchdogNotifyPolicy.decision(
            severity: .severe, openedEpisode: carry.episodeId != nil,
            safety: true, previousSafety: previousSafety,
            fused: WatchdogCalibration.tSevere, previousFused: 0,
            recon: WatchdogCalibration.tSevere, previousRecon: 0,
            eventLabel: .safetyBound,
            episodeId: carry.episodeId,
            notifiedSevereEpisodeId: carry.notifiedSevereEpisodeId,
            lastNotifiedAt: carry.lastNotifiedAt,
            nowUnix: nowUnix,
            notifyDelivery: carry.notifyDelivery)
        let notify = liveAlerts && want
        if notify {
            carry.lastNotifiedAt = nowUnix
            carry.notifyDelivery = "queued"
        }
        carry.priorState = .active
        return WatchdogResult(
            severity: .severe,
            episodeState: .active,
            episodeId: carry.episodeId,
            headline: "This stretch is far from your usual.",
            episodeLine: safetyEpisodeLine(nowUnix: nowUnix, carry: carry),
            monitoringCurrent: window.newestAgeSeconds <= 180,
            monitoringLabel: window.newestAgeSeconds <= 180 ? "CURRENT" : "WAITING",
            mode: "live",
            unavailable: nil,
            coverage: window.coverage,
            hrSource: window.hrSource.rawValue,
            family: window.family.rawValue,
            lastTickUnix: nowUnix,
            windowStartUnix: window.startUnix,
            horizonHR: window.hr.map { $0 ?? .nan },
            horizonHRV: window.hrv.map { $0 ?? .nan },
            horizonTemp: window.temp.map { $0 ?? .nan },
            horizonResp: window.resp.map { $0 ?? .nan },
            horizonRHR: window.rhr.map { $0 ?? .nan },
            horizonSpO2: window.spo2.map { $0 ?? .nan },
            reconstructedHR: [],
            reconstructedHRV: [],
            reconstructedTemp: [],
            reconstructedResp: [],
            reconstructedRHR: [],
            reconstructedSpO2: [],
            rangeHR: [],
            rangeHRV: [],
            rangeTemp: [],
            rangeResp: [],
            rangeRHR: [],
            rangeSpO2: [],
            signals: [],
            contributing: ["HR"],
            qualityLine: String(format: "Safety · coverage %.0f%% · UniTS skipped", window.coverage * 100),
            versionLine: "\(WatchdogConfig.configVersion) · safety-without-units",
            shouldNotify: notify,
            carry: carry,
            modelVersion: WatchdogConfig.fallbackModelVersion,
            trustPct: 0,
            jointEnergy: WatchdogCalibration.tSevere,
            forecastEnergy: 0,
            fusedEnergy: WatchdogCalibration.tSevere,
            promptSource: .population,
            notifyReason: notify ? reason : (liveAlerts ? reason : "live-alerts-off"),
            activityLabel: WatchdogActivityClass.unknown.rawValue,
            activityDetail: WatchdogActivityRuntime.displayName(WatchdogActivityClass.unknown.rawValue),
            sigmaAdaptive: false,
            qualityGate: "safety-during-quality-fail",
            earlyFlag: false,
            direction: [],
            directionMarks: [],
            eventLabel: WatchdogEventLabel.safetyBound.rawValue,
            calibrationSource: WatchdogCalibration.version,
            cutReason: "safety",
            eventExplained: false,
            forecastSource: "hold",
            liveOff: true,
            personalOff: false,
            physiologyOff: true
        )
    }

    static func safetyEpisodeLine(nowUnix: Int, carry: WatchdogCarry) -> String {
        let held = carry.safetyFirstUnix > 0 ? max(0, nowUnix - carry.safetyFirstUnix) : 0
        let heldBit = held > 0 ? " · held \(held)s" : ""
        let ch = carry.safetyChannel.isEmpty ? "" : " · \(carry.safetyChannel)"
        return "Severe · safety\(ch)\(heldBit) · coverage incomplete · not a diagnosis"
    }

    static func latestValidObsMinute(window: WatchdogWindow) -> Int? {
        var best: Int?
        for xs in [window.hr, window.rhr, window.hrv, window.temp, window.resp, window.spo2] {
            if let t = WatchdogQuality.lastFiniteMinuteUnix(xs, startUnix: window.startUnix) {
                best = max(best ?? t, t)
            }
        }
        return best
    }

    /// Rest-HR extrema page only in the current rest tail. Effort minutes in the same strip do not count.
    static func confirmedStillForRestSafety(_ window: WatchdogWindow) -> Bool {
        WatchdogLiveTail.resolve(window).stillNow
    }

    static func lastActivityClass(_ logits: [[Double]]) -> WatchdogActivityClass {
        let raw = WatchdogActivityClass.labels(logits: logits).last ?? WatchdogActivityClass.unknown.rawValue
        return WatchdogActivityClass.allCases.first(where: { $0.rawValue == raw }) ?? .unknown
    }

    static func nextState(severity: WatchdogSeverity, carry: inout WatchdogCarry) -> WatchdogEpisodeState {
        let prior = carry.priorState
        let open: Set<WatchdogEpisodeState> = [.candidate, .active, .recovering]
        let state: WatchdogEpisodeState
        switch severity {
        case .dataUnavailable:
            carry.consecutiveQuietTicks = 0
            state = .dataUnavailable
        case .candidate:
            carry.consecutiveQuietTicks = 0
            state = .candidate
        case .active, .severe:
            carry.consecutiveQuietTicks = 0
            state = .active
        case .note:
            if open.contains(prior ?? .withinLimits) {
                state = carry.consecutiveInRangeTicks >= 2 ? .resolved : .recovering
            } else {
                state = .withinLimits
            }
        case .withinLimits:
            if open.contains(prior ?? .withinLimits) {
                state = carry.consecutiveInRangeTicks >= 2 ? .resolved : .recovering
            } else {
                state = .withinLimits
            }
        }
        if state == .resolved || (state == .withinLimits && carry.consecutiveMismatchTicks == 0) {
            if carry.consecutiveInRangeTicks >= WatchdogCalibration.rearmTicks {
                carry.episodeId = nil
                carry.notifiedSevereEpisodeId = ""
            }
        }
        carry.priorState = state
        return state
    }

    static func copyFor(severity: WatchdogSeverity, state: WatchdogEpisodeState,
                        confounded: Bool) -> (headline: String, episodeLine: String) {
        if state == .recovering {
            return ("This stretch is settling toward your usual.",
                    "Recovering · waiting for two quiet minutes · not a diagnosis")
        }
        if state == .resolved {
            return ("This stretch looks like you.",
                    "Resolved · episode closed")
        }
        switch severity {
        case .withinLimits:
            return ("This stretch looks like you.",
                    "Within limits · no current deviation detected")
        case .note:
            return ("One odd reading. Noted, not an alert.",
                    "Note · one signal, one window")
        case .candidate:
            return ("A pattern is forming.",
                    confounded
                    ? "Candidate · logged context is holding the page"
                    : "Candidate · waiting for the stretch to persist")
        case .active:
            return ("This stretch is unlike your usual.",
                    "Active · several signals, still not a diagnosis")
        case .severe:
            return ("This stretch is far from your usual.",
                    "Severe · local notice if permitted · not a diagnosis")
        case .dataUnavailable:
            return ("Watching is not current.",
                    "Data unavailable · not recovered")
        }
    }

    static func last(_ xs: [Double?]) -> Double? {
        xs.reversed().first(where: { $0 != nil }) ?? nil
    }

    static func unavailable(_ reason: WatchdogUnavailable, nowUnix: Int, interval: Int,
                            carry: WatchdogCarry) -> WatchdogResult {
        var carry = carry
        carry.consecutiveQuietTicks = 0
        carry.priorState = .dataUnavailable
        if reason == .wristOff {
            carry.lastHeldResp = nil
            carry.lastHeldHRV = nil
            carry.lastHeldTemp = nil
            carry.lastHeldSpO2 = nil
        }
        return WatchdogResult(
            severity: .dataUnavailable,
            episodeState: .dataUnavailable,
            episodeId: carry.episodeId,
            headline: "Watching is not current.",
            episodeLine: "Data unavailable (\(reason.rawValue)) · not recovered",
            monitoringCurrent: false,
            monitoringLabel: reason == .stale ? "STALE" : "NOT CURRENT",
            mode: "live",
            unavailable: reason,
            coverage: 0,
            hrSource: "",
            family: "",
            lastTickUnix: nowUnix,
            windowStartUnix: nowUnix - WatchdogConfig.contextSeconds,
            horizonHR: [],
            horizonHRV: [],
            horizonTemp: [],
            horizonResp: [],
            horizonRHR: [],
            horizonSpO2: [],
            reconstructedHR: [],
            reconstructedHRV: [],
            reconstructedTemp: [],
            reconstructedResp: [],
            reconstructedRHR: [],
            reconstructedSpO2: [],
            rangeHR: [],
            rangeHRV: [],
            rangeTemp: [],
            rangeResp: [],
            rangeRHR: [],
            rangeSpO2: [],
            signals: [],
            contributing: [],
            qualityLine: "Tick \(WatchdogConfig.tickSeconds)s · \(reason.rawValue)",
            versionLine: "\(WatchdogConfig.configVersion) · \(WatchdogConfig.modelVersion)",
            shouldNotify: false,
            carry: carry,
            modelVersion: WatchdogConfig.modelVersion,
            trustPct: 0,
            jointEnergy: 0,
            forecastEnergy: 0,
            fusedEnergy: 0,
            promptSource: .population,
            notifyReason: "unavailable",
            activityLabel: WatchdogActivityClass.unknown.rawValue,
            activityDetail: WatchdogActivityRuntime.displayName(WatchdogActivityClass.unknown.rawValue),
            sigmaAdaptive: false,
            qualityGate: reason.rawValue,
            earlyFlag: false,
            direction: [],
            directionMarks: [],
            eventLabel: reason == .wristOff ? WatchdogEventLabel.wristOff.rawValue : WatchdogEventLabel.gap.rawValue,
            calibrationSource: WatchdogCalibration.version,
            cutReason: "quality",
            eventExplained: false,
            forecastSource: "hold",
            liveOff: false,
            personalOff: false,
            physiologyOff: false
        )
    }

    static func applyInject(_ inject: WatchdogInject, nowUnix: Int, interval: Int,
                            carry: inout WatchdogCarry, liveAlerts: Bool = true) -> WatchdogResult {
        if inject == .wristOff {
            return unavailable(.wristOff, nowUnix: nowUnix, interval: interval, carry: carry)
        }
        let feed: WatchdogFeed
        let prompt: UniTSPrompt
        switch inject {
        case .quiet:
            prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)
            feed = Self.syntheticFeed(now: nowUnix, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        case .severe:
            prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)
            feed = Self.syntheticFeed(now: nowUnix, hr: 132, hrv: 16, temp: 34.3, resp: 22, motion: 0)
        case .walk:
            prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)
            feed = Self.syntheticFeed(now: nowUnix, hr: 98, hrv: 32, temp: 33.4, resp: 22, motion: 0.42,
                                      stepsPerMin: 110)
        case .learning:
            prompt = UniTSPrompt(source: .population)
            feed = Self.syntheticFeed(now: nowUnix, hr: 72, hrv: 90, temp: 33.2, resp: 15, motion: 0)
        case .wristOff:
            prompt = UniTSPrompt()
            feed = Self.syntheticFeed(now: nowUnix, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        }
        let win = WatchdogWindowBuilder.build(feed)
        if inject == .severe { carry.consecutiveMismatchTicks = max(carry.consecutiveMismatchTicks, 1) }
        return evaluate(window: win, prompt: prompt, nowUnix: nowUnix, liveIntervalMinutes: interval,
                        previous: carry, inject: Optional<WatchdogInject>.none, liveAlerts: liveAlerts)
    }

    public static func syntheticFeed(now: Int, hr: Double, hrv: Double, temp: Double,
                                     resp: Double, motion: Double,
                                     family: DeviceFamily = .whoop4,
                                     stepsPerMin: Int = 0) -> WatchdogFeed {
        let start = now - WatchdogConfig.contextSeconds
        var hrs: [HRSample] = []
        var rrs: [RRInterval] = []
        var temps: [WatchdogScalarSample] = []
        var resps: [WatchdogScalarSample] = []
        var mots: [WatchdogScalarSample] = []
        var spo2: [WatchdogScalarSample] = []
        for t in start..<now {
            hrs.append(HRSample(ts: t, bpm: Int(hr.rounded())))
            if t % 1 == 0 {
                let rrMs = Int((60000.0 / max(hr, 30)).rounded())
                rrs.append(RRInterval(ts: t, rrMs: rrMs))
            }
            temps.append(WatchdogScalarSample(ts: t, value: temp))
            resps.append(WatchdogScalarSample(ts: t, value: resp))
            mots.append(WatchdogScalarSample(ts: t, value: motion))
            spo2.append(WatchdogScalarSample(ts: t, value: 97))
        }
        // RMSSD is computed from RR; for inject we also stamp 5-min identity by using a jittered RR for quiet,
        // and a tight RR for low HRV. Low HRV: smaller beat-to-beat diff.
        if hrv < 30 {
            rrs = (start..<now).map { t in
                RRInterval(ts: t, rrMs: Int((60000.0 / max(hr, 30)).rounded()))
            }
        } else {
            rrs = (start..<now).enumerated().map { i, t in
                let jitter = (i % 3 == 0) ? 40 : -20
                return RRInterval(ts: t, rrMs: max(400, Int((60000.0 / max(hr, 30)).rounded()) + jitter))
            }
        }
        var steps: [StepSample] = []
        if stepsPerMin > 0 {
            let every = max(1, 60 / stepsPerMin)
            var counter = 0
            for t in stride(from: start, to: now, by: every) {
                counter += 1
                steps.append(StepSample(ts: t, counter: counter, activityClass: 1))
            }
        }
        return WatchdogFeed(family: family, hrSource: .v18, nowUnix: now,
                            hr: hrs, rr: rrs, skinTempC: temps, respPerMin: resps, motion: mots,
                            spo2Pct: spo2, steps: steps)
    }
}
