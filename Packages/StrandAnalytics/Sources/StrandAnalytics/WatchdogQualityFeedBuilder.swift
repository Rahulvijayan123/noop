import Foundation
import WhoopProtocol
import WhoopStore

/// Pure per-record parsing for `WatchdogQualityFeed` (the sensor metadata the verification stage reads).
///
/// The rule throughout: missing stays missing. A record that carries no evidence about a property contributes
/// nothing, so an empty array or a nil means UNKNOWN downstream, never "fine".
public enum WatchdogQualityFeedBuilder {
    /// WRIST / reset events are read this far back, not just over the 30-minute window: an open WRIST_OFF from
    /// hours ago still means the strap is off until something closes it.
    public static let wearLookbackSeconds = 24 * 3600
    /// A stored battery LEVEL row (it repeats every few minutes while linked) only speaks for this long.
    public static let chargingLevelFreshSeconds = 60 * 60
    /// Event-kind prefixes this feed reads (kinds are stored as "NAME(code)").
    public static let wristOnPrefix = "WRIST_ON"
    public static let wristOffPrefix = "WRIST_OFF"
    public static let resetPrefixes = ["BOOT", "RTC_LOST", "BLE_SYSTEM_RESET"]
    public static let saturationPrefixes = ["CH1_SATURATION", "CH2_SATURATION", "ACCELEROMETER_SATURATION",
                                            "ACCEL_SATURATION", "AFE_RESET"]
    public static let chargingOnPrefix = "CHARGING_ON"
    public static let chargingOffPrefix = "CHARGING_OFF"
    /// Every prefix above, for a store read filtered by kind.
    public static var eventPrefixes: [String] {
        [wristOnPrefix, wristOffPrefix, chargingOnPrefix, chargingOffPrefix] + resetPrefixes + saturationPrefixes
    }

    // MARK: v18 aux (WHOOP 5/MG history)

    /// One `V18Second` per aux record that carries optical evidence. A record with neither the amplitude pair,
    /// the flag byte nor both baselines says nothing about optics and is skipped (UNKNOWN, not good).
    /// - `sentinel`: opticalAmpA == 128 or opticalAmpB == 128 (the record-level bad-second marker), or
    ///   hrQualityFlags present with bit 7 clear (HR/R-R not valid).
    /// - `baselineZero`: opticalBaselineA == 0 && opticalBaselineB == 0 (both present): off-wrist optics.
    /// - `spo2Pct`: aux byte @82 when 70…100.
    public static func v18Seconds(_ samples: [V18AuxSample]) -> [WatchdogQualityFeed.V18Second] {
        var byTs: [Int: WatchdogQualityFeed.V18Second] = [:]
        for s in samples {
            let ampKnown = s.opticalAmpA != nil || s.opticalAmpB != nil
            let flagKnown = s.hrQualityFlags != nil
            let baselineKnown = s.opticalBaselineA != nil && s.opticalBaselineB != nil
            guard ampKnown || flagKnown || baselineKnown else { continue }
            let ampSentinel = s.opticalAmpA == 128 || s.opticalAmpB == 128
            let flagInvalid = s.hrQualityFlags.map { $0 & 0x80 == 0 } ?? false
            let baselineZero = baselineKnown && s.opticalBaselineA == 0 && s.opticalBaselineB == 0
            let spo2 = s.auxByte82.flatMap { (70...100).contains($0) ? $0 : nil }
            byTs[s.ts] = WatchdogQualityFeed.V18Second(ts: s.ts, sentinel: ampSentinel || flagInvalid,
                                                        baselineZero: baselineZero, spo2Pct: spo2)
        }
        return byTs.values.sorted { $0.ts < $1.ts }
    }

    /// Unix second → record index for every v18 record that carries one.
    public static func v18RecordIndex(_ samples: [V18AuxSample]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for s in samples { if let i = s.recordIndex { out[s.ts] = i } }
        return out
    }

    // MARK: Events

    public static func wristEvents(_ events: [WhoopEvent]) -> [WatchdogQualityFeed.WristEvent] {
        var seen = Set<String>()
        var out: [WatchdogQualityFeed.WristEvent] = []
        for e in events.sorted(by: { $0.ts < $1.ts }) {
            let on: Bool
            if e.kind.hasPrefix(wristOnPrefix) { on = true }
            else if e.kind.hasPrefix(wristOffPrefix) { on = false }
            else { continue }
            guard seen.insert("\(e.ts)#\(on)").inserted else { continue }
            out.append(.init(ts: e.ts, on: on))
        }
        return out
    }

    public static func resetEventTimes(_ events: [WhoopEvent]) -> [Int] {
        times(events, prefixes: resetPrefixes)
    }

    public static func saturationEventTimes(_ events: [WhoopEvent]) -> [Int] {
        times(events, prefixes: saturationPrefixes)
    }

    static func times(_ events: [WhoopEvent], prefixes: [String]) -> [Int] {
        Array(Set(events.filter { e in prefixes.contains { e.kind.hasPrefix($0) } }.map(\.ts))).sorted()
    }

    // MARK: Charging

    /// Charging state now, or nil when nothing says.
    ///
    /// Precedence: the live link's flag (set from the strap's own BATTERY_LEVEL / pack edges, nil until the
    /// first event of a session and cleared on disconnect) wins. Otherwise the newest stored evidence: a
    /// CHARGING_ON / CHARGING_OFF edge from the last 24 h (an edge holds until the next one), or a battery
    /// LEVEL row with its charging bit within `chargingLevelFreshSeconds` (a level only speaks for its cadence).
    public static func charging(battery: [BatterySample], events: [WhoopEvent], liveCharging: Bool?,
                                nowUnix: Int) -> Bool? {
        if let liveCharging { return liveCharging }
        var newest: (ts: Int, charging: Bool)?
        func offer(_ ts: Int, _ value: Bool) {
            if newest == nil || ts >= newest!.ts { newest = (ts, value) }
        }
        for e in events where e.ts <= nowUnix && nowUnix - e.ts <= wearLookbackSeconds {
            if e.kind.hasPrefix(chargingOnPrefix) { offer(e.ts, true) }
            else if e.kind.hasPrefix(chargingOffPrefix) { offer(e.ts, false) }
        }
        for row in battery where row.ts <= nowUnix && nowUnix - row.ts <= chargingLevelFreshSeconds {
            if let c = row.charging { offer(row.ts, c) }
        }
        return newest?.charging
    }

    // MARK: Contact, PPG HR

    public static func contacts(_ samples: [StandardHRContactSample]) -> [WatchdogQualityFeed.Contact] {
        samples.sorted { $0.ts < $1.ts }.map { .init(ts: $0.ts, state: $0.contact.rawValue) }
    }

    /// Every PPG-derived HR row with its confidence (the verification stage gates on conf; nothing is
    /// dropped here).
    public static func ppgHr(_ rows: [PpgHrRow]) -> [WatchdogQualityFeed.PpgHr] {
        var byTs: [Int: WatchdogQualityFeed.PpgHr] = [:]
        for r in rows where byTs[r.ts] == nil {
            byTs[r.ts] = .init(ts: r.ts, bpm: r.bpm, conf: r.conf)
        }
        return byTs.values.sorted { $0.ts < $1.ts }
    }

    // MARK: Placement

    /// One stored placement interval, any scope (`deviceId` bare, `installation:<uuid>:<deviceId>`, or nil).
    public struct PlacementRow: Equatable, Sendable {
        public var scope: String?
        public var placement: String
        public var effectiveStart: Int
        public var effectiveEnd: Int?
        public var recordedAt: Int
        public var revision: Int64
        public init(scope: String?, placement: String, effectiveStart: Int, effectiveEnd: Int?,
                    recordedAt: Int, revision: Int64) {
            self.scope = scope; self.placement = placement; self.effectiveStart = effectiveStart
            self.effectiveEnd = effectiveEnd; self.recordedAt = recordedAt; self.revision = revision
        }
        func covers(_ at: Int) -> Bool { effectiveStart <= at && (effectiveEnd.map { $0 > at } ?? true) }
    }

    /// Does `scope` name `deviceId`, bare or installation-scoped?
    public static func scope(_ scope: String?, names deviceId: String) -> Bool {
        guard let scope, !deviceId.isEmpty else { return false }
        if scope == deviceId { return true }
        return scope.hasPrefix("installation:") && scope.hasSuffix(":" + deviceId)
    }

    /// The logged placement covering `at`: "wrist" | "bicep" | "other", or nil when unannotated or "unknown".
    /// Ids are tried in read order (active strap first); for one id the newest declaration wins across its bare
    /// and installation scopes (recordedAt, then revision). Never defaults to wrist.
    public static func placement(at: Int, rows: [PlacementRow], deviceIds: [String]) -> String? {
        for id in deviceIds {
            let covering = rows.filter { scope($0.scope, names: id) && $0.covers(at) }
            guard let newest = covering.max(by: { a, b in
                a.recordedAt == b.recordedAt ? a.revision < b.revision : a.recordedAt < b.recordedAt
            }) else { continue }
            switch newest.placement {
            case "wrist", "bicep", "other": return newest.placement
            default: return nil
            }
        }
        return nil
    }

    // MARK: Per-minute coverage

    /// Σ R-R ms ÷ 60 000 per window minute (key = `startUnix + i*60`). Minutes between the first and last beat
    /// get a value (0 when they hold none, which is evidence of missed beats); minutes outside that span, or every
    /// minute when there are no beats, are absent (UNKNOWN: the beats may not have arrived yet).
    public static func rrCoverageByMinute(_ beats: [RRInterval], startUnix: Int, endUnix: Int) -> [Int: Double] {
        let inWindow = beats.filter { $0.ts >= startUnix && $0.ts < endUnix }
        guard let first = inWindow.map(\.ts).min(), let last = inWindow.map(\.ts).max() else { return [:] }
        var sums: [Int: Int] = [:]
        for beat in inWindow { sums[minuteKey(beat.ts, startUnix: startUnix), default: 0] += beat.rrMs }
        var out: [Int: Double] = [:]
        var key = minuteKey(first, startUnix: startUnix)
        let lastKey = minuteKey(last, startUnix: startUnix)
        while key <= lastKey {
            out[key] = Double(sums[key] ?? 0) / 60_000
            key += 60
        }
        return out
    }

    /// Distinct seconds with an HR sample per window minute. Minutes with none are absent (= 0).
    public static func hrSecondsByMinute(_ hr: [HRSample], startUnix: Int, endUnix: Int) -> [Int: Int] {
        var seconds: [Int: Set<Int>] = [:]
        for sample in hr where sample.ts >= startUnix && sample.ts < endUnix {
            seconds[minuteKey(sample.ts, startUnix: startUnix), default: []].insert(sample.ts)
        }
        return seconds.mapValues(\.count)
    }

    static func minuteKey(_ ts: Int, startUnix: Int) -> Int {
        startUnix + ((ts - startUnix) / 60) * 60
    }

    // MARK: Motion

    /// Per-second motion occupancy (0…1) for the window's motion channel. `dynAccel` (g) maps through /0.4.
    /// Without `dynAccel` the vector-magnitude fallback `|‖g‖ − 1| / 0.4` is used only on a WHOOP 4, whose
    /// gravity rows are raw accelerometer g. On a WHOOP 5 (and an unknown strap) x/y/z is a unit gravity
    /// vector, so the fallback would read "perfectly still" for every second: that second's motion is UNKNOWN
    /// and is left out.
    public static func motionOccupancy(_ imu: [WatchdogIMUSample], family: DeviceFamily?) -> [WatchdogScalarSample] {
        imu.compactMap { sample in
            if let dyn = sample.dynAccel {
                return WatchdogScalarSample(ts: sample.ts, value: min(1, max(0, dyn / 0.4)))
            }
            guard family == .whoop4 else { return nil }
            let mag = (sample.x * sample.x + sample.y * sample.y + sample.z * sample.z).squareRoot()
            return WatchdogScalarSample(ts: sample.ts, value: min(1, max(0, abs(mag - 1.0) / 0.4)))
        }
    }
}

/// Wear state from WRIST events beyond the 30-minute window.
public enum WatchdogWearEvidence {
    /// The newest WRIST evidence (stored events from the last 24 h plus live events seen on this link) is an OFF
    /// that no later WRIST_ON closed, and the heart rate has not recovered since it (300 s of plausible HR with
    /// gaps ≤ 5 s, `WristWearRecovery.firstSustainedHR`). Returns the OFF's time when it is still open.
    ///
    /// `hr` must cover `[offTs, now]` for a stale OFF to be closable by recovery; the caller reads it from the OFF.
    /// No WRIST evidence at all returns nil: that is UNKNOWN, not off (and not on).
    public static func openWristOffTs(stored: [WatchdogQualityFeed.WristEvent],
                                      live: [WatchdogQualityFeed.WristEvent],
                                      hr: [HRSample], nowUnix: Int,
                                      lookbackSeconds: Int = WatchdogQualityFeedBuilder.wearLookbackSeconds) -> Int? {
        guard let newestOff = latestOpenOffTs(stored: stored, live: live, nowUnix: nowUnix,
                                              lookbackSeconds: lookbackSeconds) else { return nil }
        if WristWearRecovery.firstSustainedHR(hr, after: newestOff, before: nowUnix + 1) != nil { return nil }
        return newestOff
    }

    /// The newest event's time when that event is a WRIST_OFF (ignoring HR), else nil.
    public static func latestOpenOffTs(stored: [WatchdogQualityFeed.WristEvent],
                                       live: [WatchdogQualityFeed.WristEvent], nowUnix: Int,
                                       lookbackSeconds: Int = WatchdogQualityFeedBuilder.wearLookbackSeconds) -> Int? {
        let all = (stored + live).filter { $0.ts <= nowUnix + 5 && nowUnix - $0.ts <= lookbackSeconds }
        // Newest wins; on the same second an ON is taken as the later state (the strap emits OFF→ON, not ON→OFF,
        // when it re-seats inside one second).
        guard let newest = all.max(by: { a, b in a.ts == b.ts ? (a.on == false && b.on == true) : a.ts < b.ts })
        else { return nil }
        return newest.on ? nil : newest.ts
    }
}
