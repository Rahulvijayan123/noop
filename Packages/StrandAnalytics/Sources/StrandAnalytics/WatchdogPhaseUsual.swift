import Foundation

public enum WatchdogPhase: String, Equatable, Sendable, Codable, CaseIterable {
    case sleep, late, morning, midday, evening
}

public enum WatchdogActivityFamily: String, Equatable, Sendable, Codable, CaseIterable {
    case still, walk, endurance, resistance, postWorkout = "post_workout", other
}

public struct WatchdogPhaseKey: Equatable, Hashable, Sendable, Codable {
    public var phase: WatchdogPhase
    public var family: WatchdogActivityFamily
    public init(phase: WatchdogPhase, family: WatchdogActivityFamily) {
        self.phase = phase
        self.family = family
    }
    public var id: String { "\(phase.rawValue)×\(family.rawValue)" }
}

public struct WatchdogPhaseEntry: Equatable, Sendable, Codable {
    public var center: [Double]
    public var mad: [Double]
    public var nDays: Int
    public var updatedDay: String

    public init(center: [Double] = Array(repeating: 0, count: 6),
                mad: [Double] = Array(repeating: 0, count: 6),
                nDays: Int = 0, updatedDay: String = "") {
        self.center = center
        self.mad = mad
        self.nDays = nDays
        self.updatedDay = updatedDay
    }
}

public struct WatchdogPhaseUsualStore: Equatable, Sendable, Codable {
    public var entries: [String: WatchdogPhaseEntry]
    public static let empty = WatchdogPhaseUsualStore(entries: [:])
    public init(entries: [String: WatchdogPhaseEntry] = [:]) { self.entries = entries }

    public static let matureDays = 7
    public static let blendSidecar = 0.70
    public static let dailyGain = 0.15

    public static func phase(nowUnix: Int, sleepBit: Bool) -> WatchdogPhase {
        if sleepBit { return .sleep }
        let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(nowUnix)))
        if hour < 5 { return .late }
        if hour < 12 { return .morning }
        if hour < 17 { return .midday }
        return .evening
    }

    public static func family(label: WatchdogEventLabel, cls: WatchdogActivityClass) -> WatchdogActivityFamily {
        if label == .postWorkout { return .postWorkout }
        switch cls {
        case .still, .stand: return .still
        case .walk: return .walk
        case .run, .cycleLike: return .endurance
        case .resistance: return .resistance
        case .unknown, .artifact: return .other
        }
    }

    /// Band key for the 14-minute lock. Quiet unknown / no-IMU rest is still, not `.other`.
    public static func bandFamily(label: WatchdogEventLabel, cls: WatchdogActivityClass,
                                  tailPeriod: WatchdogPeriod) -> WatchdogActivityFamily {
        let raw = family(label: label, cls: cls)
        if raw == .other, WatchdogBand.learnable(label),
           tailPeriod == .rest || tailPeriod == .unknown {
            return .still
        }
        return raw
    }

    public func mature(_ key: WatchdogPhaseKey) -> WatchdogPhaseEntry? {
        guard let e = entries[key.id], e.nDays >= Self.matureDays else { return nil }
        guard Self.isNativeVitalCenter(e.center) else { return nil }
        return e
    }

    /// Residual-scale centers (typical |r| 0.2–2) must never blend into bpm / °C prompts.
    public static func isNativeVitalCenter(_ center: [Double]) -> Bool {
        guard center.count == 6, center.allSatisfy(\.isFinite) else { return false }
        if center[0] > 0 && center[0] < 8 { return false }
        if center[3] > 0 && center[3] < 20 { return false }
        if center[0] == 0 && center[3] == 0 { return false }
        return true
    }

    public mutating func dropResidualScaleCenters() {
        for (id, e) in entries where !Self.isNativeVitalCenter(e.center) {
            entries[id] = nil
        }
    }

    public static func parseKey(_ id: String) -> WatchdogPhaseKey? {
        let parts = id.split(separator: "×", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let phase = WatchdogPhase(rawValue: parts[0]),
              let family = WatchdogActivityFamily(rawValue: parts[1]) else { return nil }
        return WatchdogPhaseKey(phase: phase, family: family)
    }

    /// Band-eligible still ticks only. Never a leftover workout family.
    public static func qualifyingStillKeys(ticks: [String: Int]) -> [WatchdogPhaseKey] {
        ticks.compactMap { id, n -> WatchdogPhaseKey? in
            guard n >= 12, let key = parseKey(id), key.family == .still else { return nil }
            return key
        }
    }

    public static func dominantStillKey(ticks: [String: Int]) -> WatchdogPhaseKey? {
        let eligible = ticks.compactMap { id, n -> (WatchdogPhaseKey, Int)? in
            guard n >= 12, let key = parseKey(id), key.family == .still else { return nil }
            return (key, n)
        }
        return eligible.max(by: { $0.1 < $1.1 })?.0
    }

    public mutating func writeDay(key: WatchdogPhaseKey, dayMedian: [Double],
                                  present: [Bool]? = nil, civilDay: String) {
        guard key.family != .other else { return }
        guard dayMedian.count == 6, dayMedian.allSatisfy(\.isFinite) else { return }
        let mask = present ?? Array(repeating: true, count: 6)
        guard mask.count == 6 else { return }
        var gated = dayMedian
        for i in 0..<6 where !mask[i] { gated[i] = 0 }
        let hrOk = mask[0] && dayMedian[0] > 0
        let tempOk = mask[3] && dayMedian[3] > 0
        if !hrOk && !tempOk { return }
        guard Self.isNativeVitalCenter(gated) else { return }
        var e = entries[key.id] ?? WatchdogPhaseEntry()
        if e.updatedDay == civilDay { return }
        if e.nDays == 0 {
            e.center = gated
            e.mad = Array(repeating: 0, count: 6)
        } else {
            let prev = e.center
            e.center = (0..<6).map { i in
                guard mask[i], i < e.center.count else { return i < e.center.count ? e.center[i] : 0 }
                if e.center[i] <= 0 { return dayMedian[i] }
                return 0.85 * e.center[i] + Self.dailyGain * dayMedian[i]
            }
            e.mad = (0..<6).map { i in
                guard mask[i], i < e.mad.count, i < prev.count else {
                    return i < e.mad.count ? e.mad[i] : 0
                }
                if prev[i] <= 0 { return 0 }
                return 0.85 * e.mad[i] + Self.dailyGain * abs(dayMedian[i] - prev[i])
            }
        }
        e.nDays += 1
        e.updatedDay = civilDay
        entries[key.id] = e
    }

    public func blendPrompt(_ prompt: UniTSPrompt, key: WatchdogPhaseKey) -> UniTSPrompt {
        let stillKey = WatchdogPhaseKey(phase: key.phase, family: .still)
        let stillE = mature(stillKey)
        let keyE = mature(key)
        if stillE == nil && keyE == nil { return prompt }
        var out = prompt
        func sidecar(_ e: WatchdogPhaseEntry?, _ idx: Int) -> Double? {
            guard let e, idx < e.center.count else { return nil }
            let v = e.center[idx]
            guard v.isFinite, v > 0 else { return nil }
            return v
        }
        func mix(_ layer: Double?, _ s: Double?) -> Double? {
            guard let s else { return layer }
            guard let layer else { return s }
            return (1 - Self.blendSidecar) * layer + Self.blendSidecar * s
        }
        func fill(_ layer: Double?, _ s: Double?) -> Double? {
            layer ?? s
        }
        out.hr = mix(prompt.hr, sidecar(stillE ?? keyE, 0))
        if key.phase == .sleep {
            out.rhr = mix(prompt.rhr, sidecar(keyE, 1))
            out.hrv = mix(prompt.hrv, sidecar(keyE, 2))
            out.temp = mix(prompt.temp, sidecar(keyE, 3))
            out.resp = mix(prompt.resp, sidecar(keyE, 4))
            out.spo2 = mix(prompt.spo2, sidecar(keyE, 5))
        } else {
            if prompt.hrvAwake != nil {
                out.hrvAwake = mix(prompt.hrvAwake, sidecar(stillE, 2))
            }
            out.temp = fill(prompt.temp, sidecar(stillE, 3))
            out.resp = fill(prompt.resp, sidecar(stillE, 4))
            out.spo2 = fill(prompt.spo2, sidecar(stillE, 5))
        }
        return out
    }
}

/// One medium-band slot. Keyed by the existing `WatchdogPhaseKey.id` — not a new activity type.
public struct WatchdogBandState: Equatable, Sendable, Codable {
    public var q: [Double]
    public var anchor: [Double]
    public var n: Int
    public var ready: Bool
    public var scale: [Double]
    public var lastUnix: Int
    /// Present updates per channel. Missing vitals do not train q[k] toward 0.
    public var nPresent: [Int]
    /// Last counted civil minute (`unix / 60`) per channel. Same sparse sample is not a new n.
    public var lastMinute: [Int]

    public static let empty = WatchdogBandState()

    public init(q: [Double] = Array(repeating: 0, count: 6),
                anchor: [Double] = Array(repeating: 1, count: 6),
                n: Int = 0, ready: Bool = false,
                scale: [Double] = Array(repeating: 1, count: 6),
                lastUnix: Int = 0,
                nPresent: [Int] = Array(repeating: 0, count: 6),
                lastMinute: [Int] = Array(repeating: 0, count: 6)) {
        self.q = q
        self.anchor = anchor
        self.n = n
        self.ready = ready
        self.scale = scale
        self.lastUnix = lastUnix
        self.nPresent = nPresent
        self.lastMinute = lastMinute
    }

    enum CodingKeys: String, CodingKey {
        case q, anchor, n, ready, scale, lastUnix, nPresent, lastMinute
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        q = try c.decodeIfPresent([Double].self, forKey: .q) ?? Array(repeating: 0, count: 6)
        anchor = try c.decodeIfPresent([Double].self, forKey: .anchor) ?? Array(repeating: 1, count: 6)
        n = try c.decodeIfPresent(Int.self, forKey: .n) ?? 0
        ready = try c.decodeIfPresent(Bool.self, forKey: .ready) ?? false
        scale = try c.decodeIfPresent([Double].self, forKey: .scale) ?? Array(repeating: 1, count: 6)
        lastUnix = try c.decodeIfPresent(Int.self, forKey: .lastUnix) ?? 0
        nPresent = try c.decodeIfPresent([Int].self, forKey: .nPresent) ?? Array(repeating: 0, count: 6)
        if nPresent.count < 6 { nPresent += Array(repeating: 0, count: 6 - nPresent.count) }
        lastMinute = try c.decodeIfPresent([Int].self, forKey: .lastMinute) ?? Array(repeating: 0, count: 6)
        if lastMinute.count < 6 { lastMinute += Array(repeating: 0, count: 6 - lastMinute.count) }
    }
}

/// Green band: small weighted steps. Not frozen, not yanked by one minute.
/// `q` accumulates typical |r| on eligible minutes of one existing PhaseKey.
/// After 14 minutes, `anchor` is that first typical width. Scale is `q / anchor`,
/// stepped by at most `stepMax` and clamped to 0.75…1.40.
public enum WatchdogBand: Sendable {
    public static let version = "band-v2-medium"
    public static let targetLo = 0.90
    public static let targetHi = 0.95
    public static let clampLo = 0.75
    public static let clampHi = 1.40
    public static let firstMinutes = 14
    public static let residualCap = 2.5
    /// |r| allowed into the EMA — a 2.4 still-spike must not own q.
    public static let learnCap = 1.20
    public static let qFloor = 0.08
    /// Max |Δscale| on one eligible tick.
    public static let stepMax = 0.02
    public static let nCap = 14 * 24 * 3
    public static let minuteSeconds = 60

    public static func alpha(nElig: Int) -> Double {
        2 / Double(min(max(nElig, 1), nCap) + 1)
    }

    public static func learnable(_ label: WatchdogEventLabel) -> Bool {
        switch label {
        case .normalSleep, .normalStillAwake,
             .workoutWalk, .workoutRun, .workoutCycle, .workoutLift:
            return true
        default:
            return false
        }
    }

    public static func shouldCountMinute(nowUnix: Int, lastUnix: Int) -> Bool {
        lastUnix <= 0 || nowUnix / minuteSeconds > lastUnix / minuteSeconds
    }

    public static func channelReady(_ nPresent: [Int], _ k: Int) -> Bool {
        k < nPresent.count && nPresent[k] >= firstMinutes
    }

    public static func channelReady(_ state: WatchdogBandState, _ k: Int) -> Bool {
        channelReady(state.nPresent, k)
    }

    public static func update(absResidual: [Double], eligible: Bool,
                              q: inout [Double], anchor: inout [Double],
                              n: inout Int, initialized: inout Bool) -> [Double] {
        var scale = Array(repeating: 1.0, count: 6)
        var nPresent = Array(repeating: 0, count: 6)
        var last = 0
        var lastMinute = Array(repeating: 0, count: 6)
        return update(absResidual: absResidual, eligible: eligible, q: &q, anchor: &anchor,
                      n: &n, initialized: &initialized, scale: &scale,
                      nowUnix: 0, lastUnix: &last, nPresent: &nPresent,
                      lastMinute: &lastMinute)
    }

    public static func update(absResidual: [Double], eligible: Bool,
                              q: inout [Double], anchor: inout [Double],
                              n: inout Int, initialized: inout Bool,
                              scale: inout [Double],
                              nowUnix: Int = 0, lastUnix: inout Int) -> [Double] {
        var nPresent = Array(repeating: 0, count: 6)
        var lastMinute = Array(repeating: 0, count: 6)
        return update(absResidual: absResidual, eligible: eligible, q: &q, anchor: &anchor,
                      n: &n, initialized: &initialized, scale: &scale,
                      nowUnix: nowUnix, lastUnix: &lastUnix, nPresent: &nPresent,
                      lastMinute: &lastMinute)
    }

    public static func update(absResidual: [Double], eligible: Bool,
                              q: inout [Double], anchor: inout [Double],
                              n: inout Int, initialized: inout Bool,
                              scale: inout [Double],
                              nowUnix: Int = 0, lastUnix: inout Int,
                              present: [Bool]? = nil,
                              nPresent: inout [Int]) -> [Double] {
        var lastMinute = Array(repeating: 0, count: 6)
        return update(absResidual: absResidual, eligible: eligible, q: &q, anchor: &anchor,
                      n: &n, initialized: &initialized, scale: &scale,
                      nowUnix: nowUnix, lastUnix: &lastUnix, present: present,
                      nPresent: &nPresent, lastMinute: &lastMinute)
    }

    public static func update(absResidual: [Double], eligible: Bool,
                              q: inout [Double], anchor: inout [Double],
                              n: inout Int, initialized: inout Bool,
                              scale: inout [Double],
                              nowUnix: Int = 0, lastUnix: inout Int,
                              present: [Bool]? = nil,
                              nPresent: inout [Int],
                              lastMinute: inout [Int],
                              sampleMinute: [Int]? = nil) -> [Double] {
        if q.count < 6 { q = Array(repeating: 0, count: 6) }
        if anchor.count < 6 { anchor = Array(repeating: 1, count: 6) }
        if scale.count < 6 { scale = Array(repeating: 1, count: 6) }
        if nPresent.count < 6 { nPresent = Array(repeating: 0, count: 6) }
        if lastMinute.count < 6 { lastMinute += Array(repeating: 0, count: 6 - lastMinute.count) }
        guard eligible, absResidual.count >= 6 else { return scale }
        if absResidual.contains(where: { $0 >= residualCap }) { return scale }
        // Wall-clock gate only when we have no measurement identities.
        if nowUnix > 0, sampleMinute == nil,
           !shouldCountMinute(nowUnix: nowUnix, lastUnix: lastUnix) { return scale }
        let mask = present ?? Array(repeating: true, count: 6)
        guard mask.contains(true) else { return scale }
        if nowUnix > 0, let samples = sampleMinute {
            var anyNew = false
            for k in 0..<6 where mask[k] && k < samples.count {
                if samples[k] / minuteSeconds > lastMinute[k] { anyNew = true }
            }
            if !anyNew { return scale }
        }
        n += 1
        if nowUnix > 0 { lastUnix = nowUnix }
        for k in 0..<6 {
            guard mask[k] else { continue }
            if nowUnix > 0, let samples = sampleMinute, k < samples.count {
                let civil = samples[k] / minuteSeconds
                guard civil > lastMinute[k] else { continue }
                lastMinute[k] = civil
            }
            let x = min(max(absResidual[k], 0), learnCap)
            if nPresent[k] == 0 {
                q[k] = x
            } else {
                let a = alpha(nElig: nPresent[k] + 1)
                q[k] = (1 - a) * q[k] + a * x
            }
            nPresent[k] += 1
        }
        var anyReady = initialized
        for k in 0..<6 {
            if channelReady(nPresent, k) {
                if anchor[k] <= qFloor + 1e-12, q[k] > 0 {
                    anchor[k] = max(q[k], qFloor)
                    scale[k] = 1
                }
                anyReady = true
            }
        }
        initialized = anyReady
        guard initialized else { return scale }
        for k in 0..<6 {
            guard nPresent[k] >= firstMinutes else { continue }
            let desired = min(clampHi, max(clampLo, q[k] / max(anchor[k], qFloor)))
            let prev = scale[k].isFinite && scale[k] > 0 ? scale[k] : 1
            let delta = min(stepMax, max(-stepMax, desired - prev))
            scale[k] = min(clampHi, max(clampLo, prev + delta))
        }
        return scale
    }

    public static func update(absResidual: [Double], eligible: Bool,
                              q: inout [Double], anchor: inout [Double],
                              n: inout Int, initialized: inout Bool,
                              scale: inout [Double]) -> [Double] {
        var last = 0
        var nPresent = Array(repeating: 0, count: 6)
        var lastMinute = Array(repeating: 0, count: 6)
        return update(absResidual: absResidual, eligible: eligible, q: &q, anchor: &anchor,
                      n: &n, initialized: &initialized, scale: &scale,
                      nowUnix: 0, lastUnix: &last, nPresent: &nPresent,
                      lastMinute: &lastMinute)
    }

    public static func update(_ state: inout WatchdogBandState, absResidual: [Double],
                              eligible: Bool, nowUnix: Int, present: [Bool]? = nil,
                              sampleMinute: [Int]? = nil) -> [Double] {
        update(absResidual: absResidual, eligible: eligible, q: &state.q, anchor: &state.anchor,
               n: &state.n, initialized: &state.ready, scale: &state.scale,
               nowUnix: nowUnix, lastUnix: &state.lastUnix, present: present,
               nPresent: &state.nPresent, lastMinute: &state.lastMinute,
               sampleMinute: sampleMinute)
    }

    public static func apply(_ scales: [Double], to values: [Double]) -> [Double] {
        guard let g = scales.first, g.isFinite, g > 0 else { return values }
        return values.map { $0 * g }
    }
}
