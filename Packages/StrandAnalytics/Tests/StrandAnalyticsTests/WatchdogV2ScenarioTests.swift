import XCTest
import WhoopStore
import WhoopProtocol
@testable import StrandAnalytics

/// End-to-end synthetic scenarios through the real Watchdog pipeline (window build → on-device prior →
/// detectors → five-check verifier → severity → notify policy), one tick per minute (audit 2026-10-07).
///
/// SYNTHETIC: these measure the decision logic's false alerts, misses and delays on controlled physiology.
/// They are not clinical validation. Results are printed as a table (copied into docs/BASELINE_WATCHDOG_V2.md).
/// Set NARA_SCENARIO_EXPORT=<dir> to also export each scenario's minute series + ground truth as JSON for the
/// server-model harness (Tools/AnomalyService/validation).
final class WatchdogV2ScenarioTests: XCTestCase {

    // MARK: Scenario model

    enum State: String {
        case seated, walking, running, recovery, asleep, offWrist, artifact
        /// Resistance set: arm moves (≈0.18 g), the strap's optics are in motion mode (sentinel on most seconds).
        case liftSet
        /// Between sets or leg work on an arm-worn strap: the strap is still while heart rate stays high.
        case liftRest
        /// Seated, with an isolated arm movement (≈0.07 g) every fourth minute.
        case seatedFidget
    }

    struct Segment {
        var fromMin: Int
        var toMin: Int
        var state: State
        /// Mean HR for the segment (recovery: start value, decays to `hrEnd`).
        var hr: Double
        var hrEnd: Double? = nil
        var rmssd: Double = 45
        var spo2: Double? = nil
        var temp: Double? = nil
    }

    struct Truth {
        var fromMin: Int
        var toMin: Int
        var label: String
        /// The scenario expects a verified alert inside this window (else: it must stay silent).
        var expectAlert: Bool
    }

    struct Scenario {
        var name: String
        var minutes: Int
        var segments: [Segment]
        var truth: [Truth] = []
        /// Simulated server-model windows (for the corroboration ablation only; the real-model run uses the
        /// exported data, see the class comment).
        var models: [WatchdogModelCandidate] = []
        var seed: UInt64 = 1
    }

    struct RNG {
        var s: UInt64
        mutating func u() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double((s >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
        }
        mutating func n() -> Double {
            let a = max(u(), 1e-12), b = u()
            return (-2 * log(a)).squareRoot() * cos(2 * .pi * b)
        }
    }

    static let t0 = 1_790_000_000 - (1_790_000_000 % 300)

    // MARK: Generator (1 Hz)

    struct Tape {
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        var temp: [WatchdogScalarSample] = []
        var motion: [WatchdogScalarSample] = []
        var spo2: [WatchdogScalarSample] = []
        var imu: [WatchdogIMUSample] = []
        var steps: [StepSample] = []
        var sleep: [WatchdogSleepInterval] = []
        var wristEvents: [WatchdogQualityFeed.WristEvent] = []
        var badMinutes: Set<Int> = []     // artifact minutes (optical sentinel, low beat coverage)
        var offMinutes: Set<Int> = []
    }

    static func generate(_ sc: Scenario) -> Tape {
        var r = RNG(s: sc.seed &* 0x9E3779B97F4A7C15 &+ 7)
        var tape = Tape()
        var drift = 0.0
        var beatClock = Double(t0) * 1000
        var stepCounter = 0
        var prevOff = false
        for sec in 0..<(sc.minutes * 60) {
            let t = t0 + sec
            let minute = sec / 60
            guard let seg = sc.segments.first(where: { minute >= $0.fromMin && minute < $0.toMin }) else { continue }
            drift = 0.995 * drift + 0.1 * r.n()
            let off = seg.state == .offWrist
            if off != prevOff { tape.wristEvents.append(.init(ts: t, on: !off)) }
            prevOff = off
            if off { tape.offMinutes.insert(minute); continue }
            var hr: Double
            switch seg.state {
            case .recovery:
                let frac = Double(minute - seg.fromMin) / Double(max(1, seg.toMin - seg.fromMin))
                let end = seg.hrEnd ?? seg.hr
                hr = end + (seg.hr - end) * exp(-4 * frac)
            default:
                hr = seg.hr
            }
            hr += 2.0 * drift + 1.2 * r.n()
            if seg.state == .artifact, r.u() < 0.08 { hr += 40 * r.u() }
            hr = max(30, min(220, hr))
            tape.hr.append(HRSample(ts: t, bpm: Int(hr.rounded())))
            // Beats: RR around 60000/HR with successive differences of SD ≈ rmssd.
            let target = 60_000 / hr
            while beatClock < Double(t + 1) * 1000 {
                let rrMs = max(300, min(2000, target + seg.rmssd / 2.0.squareRoot() * r.n()))
                beatClock += rrMs
                if seg.state == .artifact && r.u() < 0.5 { continue }   // missed beats
                tape.rr.append(RRInterval(ts: Int(beatClock / 1000), rrMs: Int(rrMs.rounded())))
            }
            let dyn: Double
            let occ: Double
            switch seg.state {
            case .seated: dyn = 0.004 + 0.002 * abs(r.n()); occ = 0.04
            case .walking: dyn = 0.11 + 0.03 * abs(r.n()); occ = 0.45
            case .running: dyn = 0.35 + 0.05 * abs(r.n()); occ = 0.85
            case .recovery: dyn = 0.006 + 0.003 * abs(r.n()); occ = 0.05
            case .asleep: dyn = 0.002 + 0.001 * abs(r.n()); occ = 0.0
            case .artifact: dyn = 0.12 + 0.05 * abs(r.n()); occ = 0.2
            case .offWrist: dyn = 0; occ = 0
            case .liftSet: dyn = 0.18 + 0.05 * abs(r.n()); occ = 0.45
            case .liftRest: dyn = 0.008 + 0.003 * abs(r.n()); occ = 0.05
            case .seatedFidget:
                let fidget = (minute - seg.fromMin) % 4 == 3
                dyn = fidget ? 0.07 + 0.01 * abs(r.n()) : 0.004 + 0.002 * abs(r.n())
                occ = fidget ? 0.2 : 0.04
            }
            tape.imu.append(WatchdogIMUSample(ts: t, x: 0, y: 0, z: 1, dynAccel: dyn))
            tape.motion.append(WatchdogScalarSample(ts: t, value: occ))
            tape.temp.append(WatchdogScalarSample(ts: t, value: seg.temp ?? (seg.state == .asleep ? 34.6 : 33.6)))
            if let s = seg.spo2 ?? (seg.state == .asleep ? 96.5 : nil), sec % 4 == 0 {
                tape.spo2.append(WatchdogScalarSample(ts: t, value: s + 0.6 * r.n()))
            }
            let spm = seg.state == .walking ? 105 : (seg.state == .running ? 165 : 0)
            if spm > 0, r.u() < Double(spm) / 60 {
                stepCounter += 1
                tape.steps.append(StepSample(ts: t, counter: stepCounter, activityClass: seg.state == .running ? 2 : 1))
            }
            if seg.state == .artifact || seg.state == .liftSet { tape.badMinutes.insert(minute) }
        }
        var open: Int?
        for m in 0..<sc.minutes {
            let asleep = sc.segments.first { m >= $0.fromMin && m < $0.toMin }?.state == .asleep
            if asleep, open == nil { open = m }
            if !asleep, let o = open { tape.sleep.append(.init(startUnix: t0 + o * 60, endUnix: t0 + m * 60)); open = nil }
        }
        if let o = open { tape.sleep.append(.init(startUnix: t0 + o * 60, endUnix: t0 + sc.minutes * 60)) }
        return tape
    }

    // MARK: Personal references (established Layer 1 strata)

    static func references() -> [LBEvaluation] {
        let asOf = "2026-09-30"
        let tE = LongitudinalBaseline.isoEpochDay(asOf)!
        var r = RNG(s: 77)
        func series(_ s: LBSeries, mean: Double, sd: Double, within: Double?, coverage: Double = 300) -> LBEvaluation {
            let obs: [LBDailyObservation] = (1...70).map { i in
                let x = mean + sd * r.n()
                let native = s.usesLog ? exp(x) : x
                return LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(tE - i), value: native,
                                          qualityStatus: .ok, coverage: coverage, withinDayScale: within)
            }
            return LongitudinalBaseline.evaluate(asOf: asOf, series: s, observations: obs)
        }
        return [
            series(.sleepRHR, mean: 52, sd: 2, within: nil),
            series(.sleepHRVLn, mean: log(62), sd: 0.12, within: nil),
            series(.sleepTemp, mean: 34.6, sd: 0.25, within: nil),
            series(.sleepResp, mean: 14.5, sd: 0.5, within: nil),
            series(.sleepSpO2Mean, mean: 96.5, sd: 0.6, within: nil),
            series(.sleepHR, mean: 55, sd: 2, within: 3),
            series(.awakeRestHR, mean: 68, sd: 2.5, within: 4),
            series(.awakeRestHRVLn, mean: log(45), sd: 0.12, within: 0.18),
            series(.walkingHR, mean: 104, sd: 4, within: 5),
            series(.continuousHR, mean: 72, sd: 3, within: nil),
        ]
    }

    // MARK: Runner

    struct TickOut {
        var minute: Int
        var severity: WatchdogSeverity
        var notify: Bool
        var decisions: [String]
    }

    /// Per-minute evidence for rule exercise-session-1 from the tape (no decoder intervals in the synthetic tape).
    static func evidenceMinutes(_ tape: Tape) -> [Int: ExerciseSessionMinute] {
        var dyn: [Int: (Double, Int)] = [:], hr: [Int: (Double, Int)] = [:], walk: [Int: Int] = [:], steps: [Int: Int] = [:]
        for g in tape.imu { if let d = g.dynAccel { let m = g.ts - g.ts % 60; dyn[m, default: (0, 0)].0 += d; dyn[m, default: (0, 0)].1 += 1 } }
        for h in tape.hr { let m = h.ts - h.ts % 60; hr[m, default: (0, 0)].0 += Double(h.bpm); hr[m, default: (0, 0)].1 += 1 }
        for st in tape.steps {
            let m = st.ts - st.ts % 60
            steps[m, default: 0] += 1
            if st.activityClass == 1 || st.activityClass == 2 { walk[m, default: 0] += 1 }
        }
        var out: [Int: ExerciseSessionMinute] = [:]
        for m in Set(dyn.keys).union(hr.keys) {
            let d = dyn[m].map { $0.0 / Double($0.1) }
            let h = hr[m].map { $0.0 / Double($0.1) }
            out[m] = ExerciseSessionRule.minute(minuteUnix: m, hr: h, dynMean: d, walkRunTicks: walk[m] ?? 0,
                                                stepTicks: steps[m] ?? 0, interval: nil)
        }
        return out
    }

    static func run(_ sc: Scenario, models: [WatchdogModelCandidate]? = nil,
                    refs: [LBEvaluation], exercise: Bool = true) -> [TickOut] {
        let tape = generate(sc)
        let evidence = exercise ? evidenceMinutes(tape) : [:]
        let prompt = UniTSPrompt.from(evaluations: refs)
        var carry = WatchdogCarry.empty
        var out: [TickOut] = []
        for minute in 31..<sc.minutes {
            let now = t0 + minute * 60
            let lo = now - WatchdogConfig.contextSeconds
            func cut<T>(_ xs: [T], _ ts: (T) -> Int) -> [T] { xs.filter { ts($0) >= lo && ts($0) < now } }
            let feed = WatchdogFeed(family: .whoop5, hrSource: .v18, nowUnix: now,
                                    hr: cut(tape.hr, \.ts), rr: cut(tape.rr, \.ts),
                                    skinTempC: cut(tape.temp, \.ts), motion: cut(tape.motion, \.ts),
                                    spo2Pct: cut(tape.spo2, \.ts), imu: cut(tape.imu, \.ts),
                                    steps: cut(tape.steps, \.ts))
            var window = WatchdogWindowBuilder.build(feed)
            if case .success(var w) = window {
                var q = WatchdogQualityFeed()
                q.placement = "wrist"
                q.charging = false
                q.wristEvents = tape.wristEvents.filter { $0.ts < now && now - $0.ts < 86_400 }
                let hrByMin = Dictionary(grouping: feed.hr, by: { ($0.ts - w.startUnix) / 60 })
                let rrByMin = Dictionary(grouping: feed.rr, by: { ($0.ts - w.startUnix) / 60 })
                for i in 0..<w.hr.count {
                    let m = w.startUnix + i * 60
                    let absMinute = (m - t0) / 60
                    q.hrSecondsByMinute[m] = hrByMin[i]?.count ?? 0
                    let rrSum = Double(rrByMin[i]?.reduce(0) { $0 + $1.rrMs } ?? 0)
                    if rrSum > 0 { q.rrCoverageByMinute[m] = rrSum / 60_000 }
                    if tape.badMinutes.contains(absMinute) {
                        for s in stride(from: m, to: m + 60, by: 1) {
                            q.v18.append(.init(ts: s, sentinel: s % 3 == 0, baselineZero: false))
                        }
                    }
                }
                w.quality = q
                if exercise {
                    let hist = stride(from: max(t0, now - WatchdogExerciseContext.historySeconds), to: now, by: 60)
                        .compactMap { evidence[$0] }
                    w.exercise = WatchdogExerciseContext.build(minutes: hist, windowStart: w.startUnix,
                                                               seqLen: w.hr.count, nowUnix: now, evaluations: refs,
                                                               hrMax: 195, hrMaxFromFormula: true)
                }
                window = .success(w)
            }
            let sleepOpen = tape.sleep.contains { $0.contains(now) }
            let r = Watchdog.evaluate(window: window, prompt: prompt, evaluations: refs, nowUnix: now,
                                      previous: carry, sleepSessionOpen: sleepOpen,
                                      sleepIntervals: tape.sleep.filter { $0.startUnix < now },
                                      modelCandidates: models ?? sc.models)
            carry = r.carry
            if r.shouldNotify { carry.notifyDelivery = "sent"; carry.notifiedSevereEpisodeId = carry.episodeId ?? "" }
            out.append(TickOut(minute: minute, severity: r.severity, notify: r.shouldNotify,
                               decisions: (r.verdicts ?? []).map { "\($0.candidate.kind.rawValue):\($0.decision.rawValue)" }))
        }
        return out
    }

    struct Metrics {
        var notifications = 0
        var falseNotifications = 0
        var severeMinutesOutside = 0
        var heldMinutesOutside = 0
        var detected = 0
        var expected = 0
        var delays: [Int] = []
    }

    static func score(_ sc: Scenario, _ ticks: [TickOut]) -> Metrics {
        var m = Metrics()
        func inTruth(_ minute: Int) -> Truth? {
            sc.truth.first { minute >= $0.fromMin && minute < $0.toMin + 15 }
        }
        for t in ticks {
            let gt = inTruth(t.minute)
            if t.notify {
                m.notifications += 1
                if gt?.expectAlert != true { m.falseNotifications += 1 }
            }
            if gt?.expectAlert != true {
                if t.severity == .severe { m.severeMinutesOutside += 1 }
                if t.severity == .candidate || t.severity == .note { m.heldMinutesOutside += 1 }
            }
        }
        for gt in sc.truth where gt.expectAlert {
            m.expected += 1
            if let first = ticks.first(where: { $0.minute >= gt.fromMin && $0.minute < gt.toMin + 15 && $0.severity == .severe }) {
                m.detected += 1
                m.delays.append(first.minute - gt.fromMin)
            }
        }
        return m
    }

    // MARK: Scenarios

    static func scenarios() -> [Scenario] {
        let normalSeated = Segment(fromMin: 0, toMin: 0, state: .seated, hr: 68)
        func seg(_ a: Int, _ b: Int, _ s: State, _ hr: Double, end: Double? = nil, rmssd: Double = 45,
                 spo2: Double? = nil) -> Segment {
            Segment(fromMin: a, toMin: b, state: s, hr: hr, hrEnd: end, rmssd: rmssd, spo2: spo2)
        }
        _ = normalSeated
        /// Resistance training: 1-minute sets and 2-minute rests (strap still) from `a` to `b`.
        func gym(_ a: Int, _ b: Int, set: Double, rest: Double) -> [Segment] {
            stride(from: a, to: b, by: 3).flatMap { m -> [Segment] in
                [Segment(fromMin: m, toMin: min(m + 1, b), state: .liftSet, hr: set, rmssd: 6),
                 Segment(fromMin: min(m + 1, b), toMin: min(m + 3, b), state: .liftRest, hr: rest, rmssd: 10)]
            }.filter { $0.toMin > $0.fromMin }
        }
        let modelBoth = { (from: Int, to: Int, channels: [String]) -> WatchdogModelCandidate in
            WatchdogModelCandidate(candidateKey: "sim-\(from)", startUnix: t0 + from * 60, endUnix: t0 + to * 60,
                                   channels: channels, modelP: ["timesfm-3.0": 1e-4, "units-x128": 5e-4],
                                   flaggedBy: ["timesfm-3.0", "units-x128"], direction: 1, score: 4,
                                   severity: "candidate", status: "candidate",
                                   modelVersions: ["timesfm-3.0": "sim", "units-x128": "sim"],
                                   computedAtUnix: t0 + to * 60)
        }
        return [
            Scenario(name: "quiet_seated_8h", minutes: 480, segments: [seg(0, 480, .seated, 68)], seed: 11),
            Scenario(name: "walking_bouts", minutes: 300, segments: [
                seg(0, 60, .seated, 68), seg(60, 85, .walking, 104, rmssd: 20), seg(85, 150, .seated, 70),
                seg(150, 165, .walking, 108, rmssd: 18), seg(165, 300, .seated, 68)], seed: 12),
            Scenario(name: "exercise_and_recovery", minutes: 300, segments: [
                seg(0, 60, .seated, 68), seg(60, 105, .running, 152, rmssd: 6),
                seg(105, 150, .recovery, 118, end: 74, rmssd: 25), seg(150, 300, .seated, 70)], seed: 13),
            Scenario(name: "sleep_night_8h", minutes: 540, segments: [
                seg(0, 40, .seated, 66), seg(40, 520, .asleep, 54, rmssd: 62), seg(520, 540, .seated, 70)], seed: 14),
            Scenario(name: "motion_artifacts", minutes: 300, segments: [
                seg(0, 60, .seated, 68), seg(60, 75, .artifact, 72), seg(75, 140, .seated, 68),
                seg(140, 150, .artifact, 70), seg(150, 300, .seated, 68)], seed: 15),
            Scenario(name: "off_wrist", minutes: 240, segments: [
                seg(0, 80, .seated, 68), seg(80, 130, .offWrist, 0), seg(130, 240, .seated, 68)], seed: 16),
            Scenario(name: "resting_tachy_+27_no_model", minutes: 300, segments: [
                seg(0, 90, .seated, 68), seg(90, 210, .seated, 95, rmssd: 22), seg(210, 300, .seated, 69)],
                truth: [Truth(fromMin: 90, toMin: 210, label: "resting tachycardia (sub-safety)", expectAlert: false)],
                seed: 17),
            Scenario(name: "resting_tachy_+27_model_corroborated", minutes: 300, segments: [
                seg(0, 90, .seated, 68), seg(90, 210, .seated, 95, rmssd: 22), seg(210, 300, .seated, 69)],
                truth: [Truth(fromMin: 90, toMin: 210, label: "resting tachycardia + server model", expectAlert: true)],
                models: [modelBoth(95, 210, ["HR", "HRV"])], seed: 17),
            Scenario(name: "model_window_during_exercise", minutes: 300, segments: [
                seg(0, 60, .seated, 68), seg(60, 105, .running, 152, rmssd: 6),
                seg(105, 150, .recovery, 118, end: 74, rmssd: 25), seg(150, 300, .seated, 70)],
                models: [modelBoth(62, 110, ["HR"])], seed: 13),
            Scenario(name: "safety_tachy_132_rest", minutes: 200, segments: [
                seg(0, 80, .seated, 68), seg(80, 140, .seated, 132, rmssd: 10), seg(140, 200, .seated, 70)],
                truth: [Truth(fromMin: 80, toMin: 140, label: "resting HR 132 sustained", expectAlert: true)], seed: 18),
            Scenario(name: "safety_brady_36_awake", minutes: 200, segments: [
                seg(0, 80, .seated, 66), seg(80, 120, .seated, 36, rmssd: 60), seg(120, 200, .seated, 66)],
                truth: [Truth(fromMin: 80, toMin: 120, label: "awake HR 36 sustained", expectAlert: true)], seed: 19),
            Scenario(name: "hypoxaemia_asleep_86", minutes: 300, segments: [
                seg(0, 30, .seated, 66), seg(30, 140, .asleep, 54, rmssd: 60),
                seg(140, 170, .asleep, 58, rmssd: 50, spo2: 85.5), seg(170, 280, .asleep, 54, rmssd: 60),
                seg(280, 300, .seated, 68)],
                truth: [Truth(fromMin: 140, toMin: 170, label: "SpO2 86% asleep", expectAlert: true)], seed: 20),
            Scenario(name: "short_hr_spike_rest", minutes: 200, segments: [
                seg(0, 100, .seated, 68), seg(100, 104, .seated, 135, rmssd: 10), seg(104, 200, .seated, 68)],
                seed: 21),
            // Real-shaped gym evenings (owner data 2026-10-06…08: 64–153 min sessions, HR p50 95–117, p90 115–146,
            // half the minutes still to the strap). Sets and rests, a 12-minute still-arm leg block at 128–134 bpm,
            // then a recovery tail.
            Scenario(name: "gym_resistance_sets_with_leg_work", minutes: 300,
                     segments: [seg(0, 60, .seated, 70)] + gym(60, 105, set: 136, rest: 116)
                        + [seg(105, 117, .liftRest, 131, rmssd: 8)] + gym(117, 135, set: 138, rest: 118)
                        + [seg(135, 175, .recovery, 112, end: 74, rmssd: 30), seg(175, 300, .seated, 71)],
                     seed: 22),
            Scenario(name: "gym_cardio_then_long_tail", minutes: 300,
                     segments: [seg(0, 60, .seated, 72), seg(60, 125, .walking, 132, rmssd: 8),
                                seg(125, 215, .recovery, 104, end: 80, rmssd: 30), seg(215, 300, .seated, 74)],
                     seed: 23),
            // Genuine problems during and after exercise must still reach the person.
            Scenario(name: "gym_hr_above_ceiling", minutes: 240,
                     segments: [seg(0, 60, .seated, 70)] + gym(60, 99, set: 140, rest: 118)
                        + [seg(99, 108, .liftRest, 206, rmssd: 4)] + gym(108, 130, set: 140, rest: 118)
                        + [seg(130, 170, .recovery, 112, end: 74, rmssd: 30), seg(170, 240, .seated, 71)],
                     truth: [Truth(fromMin: 99, toMin: 108, label: "HR 206 sustained inside a session", expectAlert: true)],
                     seed: 24),
            Scenario(name: "post_gym_failure_to_recover", minutes: 260,
                     segments: [seg(0, 60, .seated, 70)] + gym(60, 120, set: 136, rest: 116)
                        + [seg(120, 200, .liftRest, 129, rmssd: 9), seg(200, 260, .seated, 75)],
                     truth: [Truth(fromMin: 135, toMin: 200, label: "HR stays 129 at rest after the session", expectAlert: true)],
                     seed: 25),
            Scenario(name: "resting_tachy_132_with_fidgets", minutes: 220,
                     segments: [seg(0, 80, .seated, 68), seg(80, 150, .seatedFidget, 132, rmssd: 10),
                                seg(150, 220, .seated, 70)],
                     truth: [Truth(fromMin: 80, toMin: 150, label: "resting HR 132 with isolated arm movement", expectAlert: true)],
                     seed: 26),
        ]
    }

    func testScenarioTable() throws {
        let refs = Self.references()
        var lines = ["scenario                                 notif  false  severe_min_out  held_min_out  detected  delay_min"]
        var summary: [String: Metrics] = [:]
        for sc in Self.scenarios() {
            let ticks = Self.run(sc, refs: refs)
            let m = Self.score(sc, ticks)
            summary[sc.name] = m
            lines.append(String(format: "%-40@ %5d  %5d  %14d  %12d  %4d/%-3d  %@",
                                sc.name as NSString, m.notifications, m.falseNotifications, m.severeMinutesOutside,
                                m.heldMinutesOutside, m.detected, m.expected,
                                m.delays.map(String.init).joined(separator: ",") as NSString))
            if let dir = ProcessInfo.processInfo.environment["NARA_SCENARIO_EXPORT"] {
                try Self.export(sc, to: dir)
            }
        }
        print("WATCHDOG-V2-SCENARIOS\n" + lines.joined(separator: "\n"))
        // Contract: no false notifications in any scenario; every expected alert detected.
        for (name, m) in summary {
            XCTAssertEqual(m.falseNotifications, 0, "\(name) false notifications")
            XCTAssertEqual(m.detected, m.expected, "\(name) missed alert")
        }
        XCTAssertLessThanOrEqual(summary["safety_tachy_132_rest"]?.delays.first ?? 99, 12)
    }

    // MARK: Export for the server-model harness

    static func export(_ sc: Scenario, to dir: String) throws {
        let tape = generate(sc)
        var minutes: [[String: Any]] = []
        for m in 0..<sc.minutes {
            let lo = t0 + m * 60, hi = lo + 60
            let hrs = tape.hr.filter { $0.ts >= lo && $0.ts < hi }.map { Double($0.bpm) }
            let rrs = tape.rr.filter { $0.ts >= lo && $0.ts < hi }.map { Double($0.rrMs) }
            var diffs: [Double] = []
            if rrs.count >= 2 { for i in 1..<rrs.count { diffs.append(rrs[i] - rrs[i - 1]) } }
            let rmssd = diffs.count >= 8 ? (diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count)).squareRoot() : nil
            let dyn = tape.imu.filter { $0.ts >= lo && $0.ts < hi }.compactMap(\.dynAccel)
            let temps = tape.temp.filter { $0.ts >= lo && $0.ts < hi }.map(\.value)
            let sp = tape.spo2.filter { $0.ts >= lo && $0.ts < hi }.map(\.value)
            let steps = tape.steps.filter { $0.ts >= lo && $0.ts < hi }.count
            let asleep = tape.sleep.contains { $0.contains(lo + 30) }
            func mean(_ xs: [Double]) -> Any { xs.isEmpty ? NSNull() : xs.reduce(0, +) / Double(xs.count) }
            minutes.append(["ts": lo, "hr": mean(hrs), "hr_n": hrs.count, "rmssd": rmssd ?? NSNull(),
                            "rr_n": rrs.count, "dyn_accel": mean(dyn), "skin_temp": mean(temps),
                            "spo2": mean(sp), "steps": steps, "asleep": asleep,
                            "off_wrist": tape.offMinutes.contains(m), "artifact": tape.badMinutes.contains(m)])
        }
        let obj: [String: Any] = [
            "name": sc.name, "t0": t0, "minutes": minutes,
            "truth": sc.truth.map { ["from": t0 + $0.fromMin * 60, "to": t0 + $0.toMin * 60, "label": $0.label,
                                     "expect_alert": $0.expectAlert] },
            "baseline": ["awake_rest_hr": 68, "awake_rest_hr_scale": 4.7, "sleep_hr": 55, "sleep_hr_scale": 3.6,
                         "awake_rest_rmssd": 45, "walking_hr": 104],
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(sc.name).json"))
    }
}
