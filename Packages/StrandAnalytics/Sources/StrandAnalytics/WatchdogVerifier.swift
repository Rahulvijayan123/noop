import Foundation
import WhoopStore

// WatchdogVerifier.swift — candidate detectors + the five-check verifier (docs/BASELINE_WATCHDOG_V2.md §4).
//
//   minute quality ──┐
//   minute context ──┼─▶ detectors (safety extreme · personal deviation · server model) ─▶ candidates
//   Layer 1 strata ──┘                                                                       │
//                                                         verify(baseline, activity, quality, significance,
//                                                                independence) ─▶ verdict (alert/hold/suppress)
//
// Nothing here notifies; `Watchdog.combine` turns verdicts into severity and hands alerts to the notify policy.

// MARK: - Per-minute quality

public enum WatchdogSignalQuality {
    /// Thresholds (owner's WHOOP 5/MG, 2026-10 real-data analysis — scratch `quality-metadata.md`):
    /// sentinel-free optical seconds with plausible beat coverage are GOOD; > 25 % sentinel seconds or beat
    /// coverage < 0.5 are POOR; mean dynamic acceleration ≥ 0.05 g is moving (beat coverage collapses there).
    public static let minV18Rows = 50
    public static let goodCoverageLo = 0.9
    public static let goodCoverageHi = 1.1
    public static let poorCoverageLo = 0.5
    public static let overCount = 1.3
    public static let poorSentinelFrac = 0.25
    public static let artifactSentinelFrac = 0.10
    public static let stillDyn = 0.01
    public static let movingDyn = 0.05
    public static let minHrSecondsOn = 30
    public static let wristOffLookback = 24 * 3600

    public static func assess(window: WatchdogWindow) -> [WatchdogMinuteQuality] {
        let q = window.quality
        let n = window.hr.count
        let grid = WatchdogConfig.gridSeconds
        // Wear spans from events (24 h lookback): OFF from a WRIST_OFF until the next WRIST_ON.
        let events = (q.wristEvents + q.liveWristEvents).sorted { $0.ts < $1.ts }
        func lastWristEvent(before t: Int) -> WatchdogQualityFeed.WristEvent? {
            events.last { $0.ts <= t && t - $0.ts <= wristOffLookback }
        }
        let lastReset = q.resetEvents.max()
        var out: [WatchdogMinuteQuality] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let m = window.startUnix + i * grid
            let mEnd = m + grid
            var reasons: [String] = []

            // On-body.
            let hrSecs = q.hrSecondsByMinute[m] ?? (window.hr[i] != nil ? -1 : 0)   // -1: present, count unknown
            let v18 = q.v18.filter { $0.ts >= m && $0.ts < mEnd }
            let baselineZero = v18.contains { $0.baselineZero }
            let temp = i < window.temp.count ? window.temp[i] : nil
            var onBody: WDOnBody = .unknown
            if let ev = lastWristEvent(before: mEnd), !ev.on {
                onBody = .off; reasons.append("wrist_off_event")
            } else if baselineZero && window.hr[i] == nil {
                onBody = .off; reasons.append("optical_baseline_zero")
            } else if q.charging == true {
                onBody = .off; reasons.append("charging")
            } else {
                let hrOK = hrSecs >= minHrSecondsOn || (hrSecs == -1 && window.hr[i] != nil)
                let tempOK = temp.map { $0 >= 28 && $0 <= 42 } ?? (v18.count > 0 && !baselineZero)
                // After a strap reset with no WRIST_ON since, wear is unknown until HR has been present for the
                // 5 minutes before this one (sustained recovery, WristWearRecovery rule).
                var recovered = true
                if let r = lastReset, r <= mEnd, m - r <= wristOffLookback {
                    let onSince = events.contains { $0.on && $0.ts >= r && $0.ts <= mEnd }
                    let sustained = (max(0, i - 5)..<i).allSatisfy { window.hr[$0] != nil } && i >= 5
                    recovered = onSince || sustained
                    if !recovered { reasons.append("strap_reset_unrecovered") }
                }
                if hrOK && tempOK && recovered { onBody = .on } else if !hrOK { reasons.append("hr_absent") }
                else if !tempOK { reasons.append("skin_temp_unconfirmed") }
            }

            // Signal.
            let sentinelFrac = v18.isEmpty ? nil : Double(v18.filter(\.sentinel).count) / Double(v18.count)
            let coverage = q.rrCoverageByMinute[m]
            let pileup = q.rrPileupSeconds.contains { $0 >= m && $0 < mEnd }
            let saturated = q.saturationEvents.contains { abs($0 - m - grid / 2) <= grid }
            let contactLost = q.contacts.last { $0.ts <= mEnd }?.state == "supported_not_detected"
            var signal: WDSignal = .unknown
            if pileup || saturated || contactLost
                || (sentinelFrac.map { $0 > poorSentinelFrac } ?? false)
                || (coverage.map { $0 < poorCoverageLo || $0 > overCount } ?? false) {
                signal = .poor
                if pileup { reasons.append("rr_pileup") }
                if saturated { reasons.append("optical_saturation") }
                if contactLost { reasons.append("contact_not_detected") }
                if sentinelFrac.map({ $0 > poorSentinelFrac }) ?? false { reasons.append("optical_sentinel") }
                if coverage.map({ $0 < poorCoverageLo }) ?? false { reasons.append("beat_coverage_low") }
                if coverage.map({ $0 > overCount }) ?? false { reasons.append("beat_overcount") }
            } else if let c = coverage, c >= goodCoverageLo, c <= goodCoverageHi,
                      (sentinelFrac == nil && v18.isEmpty) || (v18.count >= minV18Rows && sentinelFrac == 0) {
                signal = .good
                if v18.isEmpty { reasons.append("beat_coverage_only") }
            } else if coverage != nil || sentinelFrac != nil {
                signal = .degraded
            } else {
                reasons.append("no_signal_metadata")
            }

            // Motion.
            let dyn = window.imu.filter { $0.ts >= m && $0.ts < mEnd }.compactMap(\.dynAccel)
            var motion: WDMotion = .unknown
            if !dyn.isEmpty {
                let mean = dyn.reduce(0, +) / Double(dyn.count)
                if mean >= movingDyn {
                    let badOptics = (sentinelFrac.map { $0 > artifactSentinelFrac } ?? false)
                        || (coverage.map { $0 < 0.8 } ?? false)
                    motion = badOptics ? .artifact : .moving
                } else {
                    motion = .still
                }
            } else if i < window.motion.count, let occ = window.motion[i] {
                // No dynamic-acceleration samples (WHOOP 4.0 gravity, or an unfilled 5.0 minute): use the
                // window's occupancy, the activity embedding's own motion scalar. WatchdogService leaves it nil
                // when it cannot be measured (a 5.0 unit gravity vector is not "still").
                motion = occ >= WatchdogConfig.chairStillOccupancy ? .moving : .still
                reasons.append("motion_from_occupancy")
            } else {
                reasons.append("no_motion_sample")
            }
            out.append(WatchdogMinuteQuality(minuteUnix: m, onBody: onBody, signal: signal, motion: motion,
                                             placement: q.placement, reasons: reasons))
        }
        return out
    }
}

// MARK: - Per-minute context

public enum WatchdogMinuteContextKind: String, Equatable, Sendable, Codable {
    case asleep
    case awakeStill = "awake_still"
    case walking
    case active
    case unknown
}

public struct WatchdogMinuteContext: Equatable, Sendable, Codable {
    public var minuteUnix: Int
    public var kind: WatchdogMinuteContextKind
    /// Posture from the stored activity classification (strict rule); nil = unknown posture.
    public var posture: LBPosture?
    /// Seconds since the end of the last effort / walking minute (nil = none in view).
    public var sinceEffortS: Int?
    public var sinceWalkingS: Int?
    /// A posture change or a sleep edge within the last few minutes.
    public var recentTransition: Bool
}

public enum WatchdogContextResolver {
    public static func resolve(window: WatchdogWindow, quality: [WatchdogMinuteQuality],
                               carryLastWorkoutEndUnix: Int) -> [WatchdogMinuteContext] {
        let n = window.hr.count
        let grid = WatchdogConfig.gridSeconds
        let labels = WatchdogActivityClass.labels(logits: window.activityLogits)
        let intervals = window.quality.contextIntervals.sorted { $0.startTs < $1.startTs }
        var lastEffortEnd = carryLastWorkoutEndUnix > 0 ? carryLastWorkoutEndUnix : nil
        var lastWalkEnd: Int? = nil
        var prevPosture: LBPosture?? = nil
        var prevKind: WatchdogMinuteContextKind? = nil
        var lastTransitionAt: Int? = nil
        var out: [WatchdogMinuteContext] = []
        for i in 0..<n {
            let m = window.startUnix + i * grid
            let mid = m + grid / 2
            let raw = i < labels.count ? labels[i] : WatchdogActivityClass.unknown.rawValue
            let cls = WatchdogActivityClass.allCases.first { $0.rawValue == raw } ?? .unknown
            let feat = i < window.activityFeatures.count ? window.activityFeatures[i] : []
            let asleep = window.sleepIntervals.contains { $0.contains(mid) }
                || (!feat.isEmpty && WatchdogActivityFeatures.sleepBit(feat) == 1)
            let interval = intervals.last { $0.startTs <= mid && $0.endTs > mid }
            let loco = feat.isEmpty ? 0 : WatchdogActivityFeatures.stepLocomotion(feat)
            let motion = i < quality.count ? quality[i].motion : .unknown
            var kind: WatchdogMinuteContextKind
            if asleep {
                kind = .asleep
            } else if WatchdogEventGeometry.isExercise(cls) && cls != .walk || motion == .artifact {
                kind = cls == .artifact || motion == .artifact ? .unknown : .active
            } else if cls == .walk || loco >= 0.5 || interval?.locomotion == "walking" {
                kind = .walking
            } else if (cls == .still || cls == .stand || cls == .unknown) && motion == .still {
                // An abstaining classifier with MEASURED stillness is still (same rule as WatchdogLiveTail);
                // unmeasured motion never is.
                kind = .awakeStill
            } else if motion == .still, interval.map({ $0.sleepState == "awake" && ($0.locomotion ?? "stationary") == "stationary" }) ?? false {
                kind = .awakeStill
            } else if motion == .moving {
                kind = .active
            } else {
                kind = .unknown
            }
            if kind == .active { lastEffortEnd = m + grid }
            if kind == .walking { lastWalkEnd = m + grid }
            let posture: LBPosture? = (kind == .awakeStill) ? interval.flatMap(LongitudinalBaseline.ContextMaterializer.posture(of:)) : nil
            if let pk = prevKind, pk != kind { lastTransitionAt = m }
            if kind == .awakeStill, let pp = prevPosture, pp != posture { lastTransitionAt = m }
            prevKind = kind
            prevPosture = .some(posture)
            out.append(WatchdogMinuteContext(
                minuteUnix: m, kind: kind, posture: posture,
                sinceEffortS: lastEffortEnd.map { m - $0 }, sinceWalkingS: lastWalkEnd.map { m - $0 },
                recentTransition: lastTransitionAt.map { m - $0 < 3 * 60 } ?? false))
        }
        return out
    }
}

// MARK: - Layer 1 reference for a live context

public struct WatchdogLiveReference: Equatable, Sendable {
    public var series: LBSeries
    public var center: Double        // math space (ln for HRV)
    /// √(between-day predictive scale² + within-day scale²), math space.
    public var scale: Double
    public var maturity: LBMaturity
    public var stale: Bool
    public var withinDayKnown: Bool
}

public enum WatchdogLiveReferences {
    /// The Layer 1 series that matches a live context for HR / HRV. nil = no matching reference (abstain).
    public static func series(kind: WatchdogMinuteContextKind, posture: LBPosture?, channel: String) -> [LBSeries] {
        switch (kind, channel) {
        case (.asleep, "HR"): return [.sleepHR]
        case (.awakeStill, "HR"):
            switch posture {
            case .supine?: return [.awakeSupineHR, .awakeRestHR]
            case .seated?: return [.awakeSeatedHR, .awakeRestHR]
            case .upright?: return [.awakeUprightHR, .awakeRestHR]
            case nil: return [.awakeRestHR]
            }
        case (.awakeStill, "HRV"):
            switch posture {
            case .supine?: return [.awakeSupineHRVLn, .awakeRestHRVLn]
            case .seated?: return [.awakeSeatedHRVLn, .awakeRestHRVLn]
            case .upright?: return [.awakeUprightHRVLn, .awakeRestHRVLn]
            case nil: return [.awakeRestHRVLn]
            }
        case (.walking, "HR"): return [.walkingHR]
        default: return []
        }
    }

    /// First series in order whose 60-day copy is established and not stale. A posture stratum that is not yet
    /// established falls back to the pooled awake-rest series (never to a sleep series).
    public static func lookup(_ evaluations: [LBEvaluation], kind: WatchdogMinuteContextKind,
                              posture: LBPosture?, channel: String) -> WatchdogLiveReference? {
        lookup(evaluations, series: series(kind: kind, posture: posture, channel: channel))
    }

    /// First of `series` whose 60-day copy is established and not stale.
    public static func lookup(_ evaluations: [LBEvaluation], series: [LBSeries]) -> WatchdogLiveReference? {
        for s in series {
            guard let ev = evaluations.first(where: { $0.series == s }), ev.establishedLong, !ev.stale,
                  let copy = ev.copyLong else { continue }
            let between = copy.predictiveSpread ?? copy.spread
            // Unknown within-day variability: assume it equals the between-day spread (doubles the variance;
            // conservative) rather than pretending a single minute is a daily mean.
            let within = ev.withinDayScaleLong ?? copy.spread
            return WatchdogLiveReference(series: s, center: copy.center,
                                         scale: (between * between + within * within).squareRoot(),
                                         maturity: ev.maturity, stale: ev.stale,
                                         withinDayKnown: ev.withinDayScaleLong != nil)
        }
        return nil
    }
}

// MARK: - Detectors

public enum WatchdogDetectors {
    /// Personal deviation: 5-minute wall-clock blocks of one context; a candidate when the last
    /// `personalBlocks` consecutive blocks all sit ≥ `personalZ` robust scales from the matched reference in
    /// the same direction. The block statistic is the median of ≥ 4 minute values.
    public static let blockSeconds = 300
    public static let personalBlocks = 3
    public static let personalZ = 2.5
    /// Within-episode block autocorrelation used for the combined p (conservative).
    public static let blockRho = 0.5

    public struct Block: Equatable, Sendable {
        public var start: Int
        public var kind: WatchdogMinuteContextKind
        public var posture: LBPosture?
        public var hr: Double?
        public var lnHrv: Double?
        public var minuteIdx: [Int]
    }

    static func blocks(window: WatchdogWindow, context: [WatchdogMinuteContext],
                       quality: [WatchdogMinuteQuality]) -> [Block] {
        var byBlock: [Int: [Int]] = [:]
        for (i, c) in context.enumerated() {
            byBlock[c.minuteUnix - ((c.minuteUnix % blockSeconds) + blockSeconds) % blockSeconds, default: []].append(i)
        }
        var out: [Block] = []
        for (start, idx) in byBlock.sorted(by: { $0.key < $1.key }) {
            guard idx.count >= 4 else { continue }
            let kinds = Set(idx.map { context[$0].kind })
            let postures = Set(idx.map { context[$0].posture.map(\.rawValue) ?? "-" })
            guard kinds.count == 1, let kind = kinds.first, postures.count == 1 else { continue }
            let usable = idx.filter {
                quality[$0].onBody != .off && quality[$0].signal != .poor && quality[$0].motion != .artifact
                    && !context[$0].recentTransition
            }
            let hrs = usable.compactMap { window.hr[$0] }
            let hr = hrs.count >= 4 ? PhysiologyContext.RobustStats.median(hrs) : nil
            let hrvAtEnd = usable.last.flatMap { i in i < window.hrv.count ? window.hrv[i] : nil }
            let lnHrv = hrvAtEnd.flatMap { $0 > 0 ? log($0) : nil }
            out.append(Block(start: start, kind: kind, posture: context[idx[0]].posture, hr: hr,
                             lnHrv: usable.count >= 4 ? lnHrv : nil, minuteIdx: idx))
        }
        return out
    }

    public static func personal(window: WatchdogWindow, context: [WatchdogMinuteContext],
                                quality: [WatchdogMinuteQuality],
                                evaluations: [LBEvaluation]) -> [WatchdogCandidate] {
        let bs = blocks(window: window, context: context, quality: quality)
        var out: [WatchdogCandidate] = []
        for channel in ["HR", "HRV"] {
            // The newest run of consecutive blocks of one context.
            guard let last = bs.last else { continue }
            var run: [Block] = [last]
            for b in bs.dropLast().reversed() {
                guard b.start == run.first!.start - blockSeconds, b.kind == last.kind, b.posture == last.posture
                else { break }
                run.insert(b, at: 0)
            }
            guard run.count >= personalBlocks,
                  let ref = WatchdogLiveReferences.lookup(evaluations, kind: last.kind, posture: last.posture,
                                                          channel: channel) else { continue }
            let recent = Array(run.suffix(personalBlocks))
            let zs: [Double] = recent.compactMap { b in
                let x = channel == "HR" ? b.hr : b.lnHrv
                return x.map { ($0 - ref.center) / max(ref.scale, 1e-9) }
            }
            guard zs.count == personalBlocks else { continue }
            let sameSign = zs.allSatisfy { $0 > 0 } || zs.allSatisfy { $0 < 0 }
            guard sameSign, zs.allSatisfy({ abs($0) >= personalZ }) else { continue }
            // Stouffer over correlated blocks: Var(Σz) = n + 2ρΣ_{i<j}ρ^{j-i-1}… ≈ n(1+ρ)/(1−ρ) (AR(1) bound).
            let n = Double(zs.count)
            let comb = zs.reduce(0, +) / (n * (1 + blockRho) / (1 - blockRho)).squareRoot()
            let p = 2 * (1 - LongitudinalBaseline.Stats.normalCDF(abs(comb)))
            let dir = zs[0] > 0 ? 1 : -1
            out.append(WatchdogCandidate(
                kind: .personalDeviation, id: "pd-\(channel)-\(recent.first!.start)",
                channels: [channel], startUnix: recent.first!.start,
                lastUnix: recent.last!.start + blockSeconds, direction: dir,
                magnitude: zs.map(abs).min() ?? 0, p: p, reference: ref.series.rawValue,
                detail: ["context": last.kind.rawValue, "posture": last.posture?.rawValue ?? "unknown",
                         "maturity": ref.maturity.rawValue,
                         "within_day_scale": ref.withinDayKnown ? "measured" : "assumed",
                         "block_z": zs.map { String(format: "%.2f", $0) }.joined(separator: ",")]))
        }
        return out
    }

    // Safety extremes (absolute bounds; sustained; quality checks happen in the verifier).
    /// Resting tachycardia: minute-mean HR > 120 for ≥ 10 consecutive awake, still minutes (Apple Watch's
    /// high-heart-rate notification uses a user threshold 100–150 bpm sustained 10 min while inactive).
    public static let tachyBpm = 120.0
    /// Bradycardia awake: < 40 bpm for ≥ 10 min (Apple low-HR notification threshold); asleep: < 30 bpm.
    public static let bradyAwakeBpm = 40.0
    public static let bradyAsleepBpm = 30.0
    public static let hrSustainMinutes = 10
    /// Hypoxaemia: median SpO₂ ≤ 88 % (the long-term-oxygen threshold, GOLD COPD) sustained ≥ 5 min of readings.
    /// Wrist SpO₂ error is ~±3–4 %, so this is a candidate that still needs good signal and stillness.
    public static let spo2Pct = 88.0
    public static let spo2SustainMinutes = 5
    /// Respiration from a respiration waveform only (never from beats): < 6 or > 30 /min for ≥ 10 min.
    public static let respLow = 6.0
    public static let respHigh = 30.0

    public static func safety(window: WatchdogWindow, context: [WatchdogMinuteContext]) -> [WatchdogCandidate] {
        var out: [WatchdogCandidate] = []
        let n = window.hr.count
        guard n > 0 else { return out }
        func trailing(_ need: Int, _ pass: (Int) -> Bool) -> Bool {
            guard n >= need else { return false }
            return ((n - need)..<n).allSatisfy(pass)
        }
        let start10 = window.startUnix + (n - hrSustainMinutes) * WatchdogConfig.gridSeconds
        if trailing(hrSustainMinutes, { i in
            (window.hr[i] ?? 0) > tachyBpm && context[i].kind == .awakeStill }) {
            let v = (n - hrSustainMinutes..<n).compactMap { window.hr[$0] }.min() ?? 0
            out.append(WatchdogCandidate(kind: .safetyExtreme, id: "sx-tachy-\(start10)", channels: ["HR"],
                                         startUnix: start10, lastUnix: window.nowUnix, direction: 1,
                                         magnitude: v, reference: "rest_hr_gt_\(Int(tachyBpm))"))
        }
        if trailing(hrSustainMinutes, { i in
            guard let h = window.hr[i] else { return false }
            return context[i].kind == .asleep ? h < bradyAsleepBpm : h < bradyAwakeBpm }) {
            let v = (n - hrSustainMinutes..<n).compactMap { window.hr[$0] }.max() ?? 0
            out.append(WatchdogCandidate(kind: .safetyExtreme, id: "sx-brady-\(start10)", channels: ["HR"],
                                         startUnix: start10, lastUnix: window.nowUnix, direction: -1,
                                         magnitude: v, reference: "hr_lt_\(Int(bradyAwakeBpm))_awake_\(Int(bradyAsleepBpm))_asleep"))
        }
        let spo2Mins = (0..<n).filter { i in i < window.spo2.count && window.spo2[i] != nil }
        if spo2Mins.count >= spo2SustainMinutes {
            let tail = Array(spo2Mins.suffix(spo2SustainMinutes))
            let vals = tail.compactMap { window.spo2[$0] }
            if let med = PhysiologyContext.RobustStats.median(vals), med <= spo2Pct,
               tail.last! >= n - 3, vals.allSatisfy({ $0 <= spo2Pct + 2 }),
               tail.allSatisfy({ context[$0].kind == .asleep || context[$0].kind == .awakeStill }) {
                let s = window.startUnix + tail.first! * WatchdogConfig.gridSeconds
                out.append(WatchdogCandidate(kind: .safetyExtreme, id: "sx-spo2-\(s)", channels: ["SpO2"],
                                             startUnix: s, lastUnix: window.nowUnix, direction: -1,
                                             magnitude: med, reference: "spo2_le_\(Int(spo2Pct))"))
            }
        }
        if !window.respFromBeats, trailing(hrSustainMinutes, { i in
            guard i < window.resp.count, let r = window.resp[i] else { return false }
            return (r < respLow || r > respHigh) && (context[i].kind == .awakeStill || context[i].kind == .asleep) }) {
            let vals = (n - hrSustainMinutes..<n).compactMap { window.resp[$0] }
            let med = PhysiologyContext.RobustStats.median(vals) ?? 0
            out.append(WatchdogCandidate(kind: .safetyExtreme, id: "sx-resp-\(start10)", channels: ["Resp"],
                                         startUnix: start10, lastUnix: window.nowUnix,
                                         direction: med > respHigh ? 1 : -1, magnitude: med,
                                         reference: "resp_waveform_lt_\(Int(respLow))_gt_\(Int(respHigh))"))
        }
        return out
    }

    /// Server model windows still in reach of live verification (ended ≤ 30 min ago).
    public static let serverFreshSeconds = 1800
    /// A server window needs this many of its minutes inside the live 30-minute view to be verified at all.
    public static let serverMinMinutesInView = 5

    /// Server model windows that overlap the last 30 minutes become candidates of their own.
    public static func server(_ models: [WatchdogModelCandidate], nowUnix: Int) -> [WatchdogCandidate] {
        models.filter { $0.status == "candidate" && $0.endUnix >= nowUnix - serverFreshSeconds && $0.startUnix <= nowUnix }
            .map { m in
                WatchdogCandidate(kind: .serverModel, id: "sm-\(m.candidateKey)", channels: m.channels,
                                  startUnix: m.startUnix, lastUnix: m.endUnix, direction: m.direction,
                                  magnitude: m.score, p: m.modelP.values.min(),
                                  reference: m.flaggedBy.sorted().joined(separator: "+"),
                                  detail: m.modelVersions)
            }
    }
}

// MARK: - Verifier

public enum WatchdogAlertVerifier {
    public static func group(of channel: String, respFromBeats: Bool) -> WatchdogSourceGroup {
        switch channel {
        case "HR", "RHR", "HRV": return .beatStream
        case "Resp": return respFromBeats ? .beatStream : .respirationWaveform
        case "SpO2": return .opticalOxygen
        case "Temp": return .thermal
        default: return .beatStream
        }
    }

    /// Server model candidates that support `c`: overlapping in time, sharing a source group, same direction,
    /// flagged by at least one model.
    public static func corroboration(for c: WatchdogCandidate, models: [WatchdogModelCandidate],
                                     respFromBeats: Bool) -> [String] {
        let groups = Set(c.channels.map { group(of: $0, respFromBeats: respFromBeats) })
        var out: [String] = []
        for m in models where m.status == "candidate" && !m.flaggedBy.isEmpty {
            guard m.endUnix >= c.startUnix - 600, m.startUnix <= c.lastUnix + 600 else { continue }
            guard m.direction == 0 || m.direction == c.direction else { continue }
            let mg = Set(m.channels.map { group(of: $0, respFromBeats: respFromBeats) })
            guard !groups.isDisjoint(with: mg) else { continue }
            out.append(contentsOf: m.flaggedBy.map { "\($0):\(m.candidateKey)" })
        }
        return out
    }

    public static let alertSignificance = 1e-3
    public static let minGoodShare = 0.8
    public static let maxPoorShare = 0.2

    public static func verify(_ c: WatchdogCandidate, all: [WatchdogCandidate], window: WatchdogWindow,
                              quality: [WatchdogMinuteQuality], context: [WatchdogMinuteContext],
                              evaluations: [LBEvaluation], models: [WatchdogModelCandidate]) -> WatchdogVerdict {
        let grid = WatchdogConfig.gridSeconds
        let idx = (0..<quality.count).filter {
            let m = window.startUnix + $0 * grid
            return m + grid > c.startUnix && m <= c.lastUnix
        }
        var checks: [WatchdogCheckResult] = []
        if c.kind == .serverModel, idx.count < WatchdogDetectors.serverMinMinutesInView {
            // The model saw data the live window no longer (or not yet) holds: quality and activity cannot be
            // checked here, so it is not an alert and not shown as Off.
            let checks = WatchdogCheck.allCases.map {
                WatchdogCheckResult(check: $0, outcome: .unknown, reason: "outside the live verification window")
            }
            return WatchdogVerdict(decision: .suppress, candidate: c, checks: checks, independentGroups: 0,
                                   modelCorroboration: [], summary: "Not verifiable from the live window")
        }

        // 1. Baseline.
        switch c.kind {
        case .safetyExtreme:
            checks.append(.init(check: .baseline, outcome: .notApplicable, reason: "absolute physiological bound"))
        case .personalDeviation:
            let ev = evaluations.first { $0.series.rawValue == c.reference }
            if let ev, ev.establishedLong, !ev.stale {
                checks.append(.init(check: .baseline, outcome: .pass,
                                    reason: "matched \(c.reference) (\(ev.maturity.rawValue), n=\(ev.nLong))"))
            } else {
                checks.append(.init(check: .baseline, outcome: .unknown, reason: "reference not established"))
            }
        case .serverModel:
            // The model learned this person's normal itself; we still require an established Layer 1 reference
            // for at least one channel family so "unusual for this person" means something.
            let fams = Set(c.channels.map { $0 == "HRV" ? "hrv" : ($0 == "Temp" ? "temp" : ($0 == "Resp" ? "resp" : ($0 == "SpO2" ? "spo2" : "hr"))) })
            let ok = evaluations.contains { fams.contains($0.series.biometricFamily) && $0.establishedLong && !$0.stale }
            checks.append(.init(check: .baseline, outcome: ok ? .pass : .unknown,
                                reason: ok ? "established Layer 1 reference in channel family" : "no established reference"))
        }

        // 2. Activity.
        let ctx = idx.map { context[$0] }
        let unknownShare = ctx.isEmpty ? 1 : Double(ctx.filter { $0.kind == .unknown }.count) / Double(ctx.count)
        let effortExplains: Bool = ctx.contains { $0.kind == .active || $0.kind == .walking && c.kind != .personalDeviation }
            || ctx.contains { ($0.sinceEffortS.map { $0 >= 0 && $0 < 30 * 60 } ?? false) && c.direction > 0 && c.channels.contains("HR") }
            || ctx.contains { ($0.sinceWalkingS.map { $0 >= 0 && $0 < 10 * 60 } ?? false) && $0.kind != .walking && c.channels.contains("HR") }
        let transition = ctx.contains { $0.recentTransition }
        if ctx.isEmpty {
            checks.append(.init(check: .activity, outcome: .unknown, reason: "no minutes in view"))
        } else if effortExplains {
            checks.append(.init(check: .activity, outcome: .fail, reason: "movement, exercise or recovery explains it"))
        } else if transition && c.kind != .safetyExtreme {
            checks.append(.init(check: .activity, outcome: .fail, reason: "posture or sleep transition"))
        } else if unknownShare > 0.2 {
            checks.append(.init(check: .activity, outcome: .unknown, reason: "activity unknown for \(Int(unknownShare * 100))% of minutes"))
        } else {
            checks.append(.init(check: .activity, outcome: .pass, reason: "still / asleep throughout"))
        }

        // 3. Sensor quality.
        let q = idx.map { quality[$0] }
        if q.isEmpty {
            checks.append(.init(check: .sensorQuality, outcome: .unknown, reason: "no quality metadata"))
        } else {
            let nq = Double(q.count)
            let off = q.contains { $0.onBody == .off }
            let poor = Double(q.filter { $0.signal == .poor }.count) / nq
            let artifact = Double(q.filter { $0.motion == .artifact }.count) / nq
            let on = Double(q.filter { $0.onBody == .on }.count) / nq
            let goodish = Double(q.filter { $0.signal == .good || $0.signal == .degraded }.count) / nq
            let tempNeedsPlacement = c.channels.contains("Temp") && q.first?.placement != "wrist"
            if off {
                checks.append(.init(check: .sensorQuality, outcome: .fail, reason: "strap off the body"))
            } else if poor > maxPoorShare || artifact > maxPoorShare {
                checks.append(.init(check: .sensorQuality, outcome: .fail,
                                    reason: String(format: "poor signal %.0f%%, artifact %.0f%%", poor * 100, artifact * 100)))
            } else if on >= minGoodShare && goodish >= minGoodShare && !tempNeedsPlacement {
                checks.append(.init(check: .sensorQuality, outcome: .pass,
                                    reason: String(format: "on body %.0f%%, signal ok %.0f%%", on * 100, goodish * 100)))
            } else {
                checks.append(.init(check: .sensorQuality, outcome: .unknown,
                                    reason: tempNeedsPlacement ? "placement unknown for skin temperature"
                                        : String(format: "on-body confirmed %.0f%%, signal known %.0f%%", on * 100, goodish * 100)))
            }
        }

        // 4. Significance (sustained + beyond ordinary variation).
        switch c.kind {
        case .safetyExtreme:
            checks.append(.init(check: .significance, outcome: .pass,
                                reason: "sustained beyond the absolute bound (\(c.reference))"))
        case .personalDeviation:
            if let p = c.p, p < alertSignificance {
                checks.append(.init(check: .significance, outcome: .pass,
                                    reason: String(format: "%d×5-min blocks ≥ %.1f scales, p=%.1e", WatchdogDetectors.personalBlocks, WatchdogDetectors.personalZ, p)))
            } else {
                checks.append(.init(check: .significance, outcome: .fail,
                                    reason: String(format: "within ordinary variation (p=%.2g)", c.p ?? 1)))
            }
        case .serverModel:
            let m = models.first { "sm-\($0.candidateKey)" == c.id }
            let both = (m?.flaggedBy.count ?? 0) >= 2
            let durOK = c.lastUnix - c.startUnix >= 15 * 60
            if both && durOK {
                checks.append(.init(check: .significance, outcome: .pass, reason: "both models flag a ≥ 15-min window"))
            } else {
                checks.append(.init(check: .significance, outcome: .unknown,
                                    reason: both ? "window shorter than 15 min" : "only one model flags it"))
            }
        }

        // 5. Independence.
        let respBeats = window.respFromBeats
        let concurrent = all.filter { other in
            other.kind != .serverModel && other.lastUnix >= c.startUnix && other.startUnix <= c.lastUnix
                && (other.direction == c.direction || other.channels.contains("SpO2") || c.channels.contains("SpO2"))
        }
        let groups = Set((concurrent + [c]).flatMap { $0.channels }.map { group(of: $0, respFromBeats: respBeats) })
        let models = corroboration(for: c, models: models, respFromBeats: respBeats)
        switch c.kind {
        case .safetyExtreme:
            checks.append(.init(check: .independence, outcome: .notApplicable, reason: "absolute bound"))
        case .personalDeviation, .serverModel:
            if groups.count >= 2 {
                checks.append(.init(check: .independence, outcome: .pass,
                                    reason: "\(groups.count) independent sensing paths: \(groups.map(\.rawValue).sorted().joined(separator: ", "))"))
            } else if !models.isEmpty && c.kind == .personalDeviation {
                checks.append(.init(check: .independence, outcome: .pass,
                                    reason: "one sensing path, corroborated by \(models.joined(separator: ", "))"))
            } else {
                checks.append(.init(check: .independence, outcome: .unknown,
                                    reason: "single sensing path (\(groups.first?.rawValue ?? "?")) without corroboration"))
            }
        }

        let decision: WatchdogVerdictDecision
        if checks.contains(where: { $0.outcome == .fail }) {
            decision = .suppress
        } else if checks.contains(where: { $0.outcome == .unknown }) {
            decision = .hold
        } else {
            decision = .alert
        }
        let failed = checks.filter { $0.outcome == .fail }.map(\.check.rawValue)
        let unknown = checks.filter { $0.outcome == .unknown }.map(\.check.rawValue)
        let summary: String
        switch decision {
        case .alert: summary = "Verified: \(c.kind.rawValue) \(c.channels.joined(separator: "+"))"
        case .hold: summary = "Unverified (\(unknown.joined(separator: ", ")))"
        case .suppress: summary = "Explained (\(failed.joined(separator: ", ")))"
        }
        return WatchdogVerdict(decision: decision, candidate: c, checks: checks, independentGroups: groups.count,
                               modelCorroboration: models, summary: summary)
    }

    /// Runs every detector and verifies each candidate.
    public static func run(window: WatchdogWindow, evaluations: [LBEvaluation], models: [WatchdogModelCandidate],
                           carryLastWorkoutEndUnix: Int) -> (verdicts: [WatchdogVerdict], quality: [WatchdogMinuteQuality],
                                                             context: [WatchdogMinuteContext]) {
        let quality = WatchdogSignalQuality.assess(window: window)
        let context = WatchdogContextResolver.resolve(window: window, quality: quality,
                                                      carryLastWorkoutEndUnix: carryLastWorkoutEndUnix)
        let candidates = WatchdogDetectors.safety(window: window, context: context)
            + WatchdogDetectors.personal(window: window, context: context, quality: quality, evaluations: evaluations)
            + WatchdogDetectors.server(models, nowUnix: window.nowUnix)
        let verdicts = candidates.map {
            verify($0, all: candidates, window: window, quality: quality, context: context,
                   evaluations: evaluations, models: models)
        }
        return (verdicts, quality, context)
    }
}

// MARK: - Severity from verdicts

extension WatchdogScores {
    /// v2 card severity, derived only from verified candidates:
    ///   severe        — a verified alert (safety extreme, or a personal / model deviation that passed all five checks)
    ///   candidate     — sustained and significant but not yet verified (unknown quality, single sensing path …)
    ///   note          — an open candidate that is neither verified nor significant yet
    ///   withinLimits  — nothing open, or every candidate explained (activity, signal, ordinary variation)
    /// A logged confounder day (alcohol, illness, travel …) caps non-safety alerts at `candidate` (shown, not sent).
    public static func severity(verdicts: [WatchdogVerdict], confounded: Bool) -> WatchdogSeverity {
        if verdicts.contains(where: { $0.decision == .alert && $0.candidate.kind == .safetyExtreme }) { return .severe }
        if verdicts.contains(where: { $0.decision == .alert }) { return confounded ? .candidate : .severe }
        let held = verdicts.filter { $0.decision == .hold }
        if held.contains(where: { v in v.checks.contains { $0.check == .significance && $0.outcome == .pass } }) {
            return .candidate
        }
        if !held.isEmpty { return .note }
        return .withinLimits
    }
}
