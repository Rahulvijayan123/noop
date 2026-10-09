import XCTest
import WhoopStore
import WhoopProtocol
@testable import StrandAnalytics

/// Replays the owner's real gym evenings (phone export, read-only; same layout as WatchdogV2RealDataReplayTests) through
/// the Watchdog every minute, with and without the exercise-session context (rule exercise-session-1), in two reference
/// states: the references the real history supports today ("learning"), and references established from the owner's
/// own data (the state a few weeks on, when personal deviations can fire). Skipped unless NARA_REPLAY_DIR is set.
/// No real data is committed.
final class WatchdogGymReplayTests: XCTestCase {

    struct Export {
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        var temp: [WatchdogScalarSample] = []
        var imu: [WatchdogIMUSample] = []
        var motion: [WatchdogScalarSample] = []
        var steps: [StepSample] = []
        var sleep: [WatchdogSleepInterval] = []
        var wrist: [WatchdogQualityFeed.WristEvent] = []
        var resets: [Int] = []
        var daily: [[Substring]] = []
        var intervals: [ActivityContextIntervalRow] = []
    }

    static func csv(_ path: String) -> [[Substring]] {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return s.split(whereSeparator: \.isNewline).map { $0.split(separator: ",", omittingEmptySubsequences: false) }
    }

    static func load(_ dir: String) -> Export {
        func p(_ f: String) -> String { (dir as NSString).appendingPathComponent(f) }
        var e = Export()
        e.hr = csv(p("hr.csv")).compactMap { r in
            guard r.count >= 2, let t = Int(r[0]), let b = Int(r[1]) else { return nil }
            return HRSample(ts: t, bpm: b)
        }
        var rrRows = csv(p("rr.csv")).compactMap { r -> (Int, Int, Int, Int)? in
            guard r.count >= 5, let t = Int(r[0]), let ms = Int(r[1]), let ch = Int(r[3]), let sus = Int(r[4]) else { return nil }
            return (t, ms, ch, sus)
        }
        let hasCh5 = rrRows.contains { $0.2 == 5 }
        rrRows = rrRows.filter { (hasCh5 ? $0.2 == 5 : true) && $0.3 == 0 && $0.1 != 500 && $0.1 != 333 }
        e.rr = rrRows.map { RRInterval(ts: $0.0, rrMs: $0.1) }
        e.temp = csv(p("temp.csv")).compactMap { r in
            guard r.count >= 2, let t = Int(r[0]), let raw = Double(r[1]) else { return nil }
            return WatchdogScalarSample(ts: t, value: raw / 100)
        }
        e.imu = csv(p("gravity.csv")).compactMap { r in
            guard r.count >= 5, let t = Int(r[0]), let x = Double(r[1]), let y = Double(r[2]), let z = Double(r[3]) else { return nil }
            return WatchdogIMUSample(ts: t, x: x, y: y, z: z, dynAccel: Double(r[4]))
        }
        e.motion = e.imu.compactMap { s in s.dynAccel.map { WatchdogScalarSample(ts: s.ts, value: min(1, $0 / 0.4)) } }
        e.steps = csv(p("steps.csv")).compactMap { r in
            guard r.count >= 3, let t = Int(r[0]), let c = Int(r[1]), let k = Int(r[2]) else { return nil }
            return StepSample(ts: t, counter: c, activityClass: k)
        }
        e.sleep = csv(p("sleep.csv")).compactMap { r in
            guard r.count >= 2, let a = Int(r[0]), let b = Int(r[1]) else { return nil }
            return WatchdogSleepInterval(startUnix: a, endUnix: b)
        }
        let ev = csv(p("events.csv"))
        e.wrist = ev.compactMap { r in
            guard r.count >= 2, let t = Int(r[0]) else { return nil }
            if r[1].hasPrefix("WRIST_ON") { return .init(ts: t, on: true) }
            if r[1].hasPrefix("WRIST_OFF") { return .init(ts: t, on: false) }
            return nil
        }
        e.resets = ev.compactMap { r in
            guard r.count >= 2, let t = Int(r[0]), !r[1].hasPrefix("WRIST") else { return nil }
            return t
        }
        e.daily = Array(csv(p("server_daily.csv")).dropFirst())
        if let data = FileManager.default.contents(atPath: p("intervals.json")),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            e.intervals = arr.map { d in
                ActivityContextIntervalRow(startTs: d["startTs"] as! Int, endTs: d["endTs"] as! Int,
                    activityClass: d["activityClass"] as! String, confidence: (d["confidence"] as? Double) ?? 0,
                    evidenceQuality: (d["evidenceQuality"] as? Double) ?? 0, posture: d["posture"] as? String,
                    locomotion: d["locomotion"] as? String, armBehavior: d["armBehavior"] as? String,
                    sleepState: d["sleepState"] as! String, wearState: d["wearState"] as! String,
                    intensity: d["intensity"] as? Double, hrSamples: d["hrSamples"] as! Int,
                    hrMean: d["hrMean"] as? Double, rmssd: d["rmssd"] as? Double, rrBeats: d["rrBeats"] as! Int,
                    rrDiffSqSumMs2: (d["rrDiffSqSumMs2"] as? Double) ?? 0, rrDiffCount: (d["rrDiffCount"] as? Int) ?? 0,
                    detail: d["detail"] as? String)
            }
        }
        return e
    }

    static func slice<T>(_ xs: [T], _ ts: (T) -> Int, _ lo: Int, _ hi: Int) -> [T] {
        var a = 0, b = xs.count
        while a < b { let m = (a + b) / 2; if ts(xs[m]) < lo { a = m + 1 } else { b = m } }
        var e = a
        while e < xs.count && ts(xs[e]) < hi { e += 1 }
        return Array(xs[a..<e])
    }

    /// References as the real history supports them today.
    static func learningReferences(_ e: Export, asOf: String, calendar: Calendar) -> [LBEvaluation] {
        var out: [LBEvaluation] = []
        func obs(_ col: Int) -> [LBDailyObservation] {
            e.daily.compactMap { r in
                guard r.count > col, r[0].count == 10, let v = Double(r[col]) else { return nil }
                return LBDailyObservation(day: String(r[0]), value: v, qualityStatus: .ok)
            }
        }
        for (s, col) in [(LBSeries.sleepRHR, 2), (.sleepHRVLn, 3), (.sleepResp, 4), (.sleepTemp, 5)] {
            out.append(LongitudinalBaseline.evaluate(asOf: asOf, series: s, observations: obs(col)))
        }
        for (s, o) in LongitudinalBaseline.ContextMaterializer.observations(rows: e.intervals, calendar: calendar) {
            out.append(LongitudinalBaseline.evaluate(asOf: asOf, series: s, observations: o))
        }
        return out
    }

    /// References established from the owner's own values: 40 days at the observed level with a realistic day-to-day
    /// spread, as Layer 1 would hold them once enough days exist.
    static func establishedReferences(asOf: String) -> [LBEvaluation] {
        let tE = LongitudinalBaseline.isoEpochDay(asOf)!
        func series(_ s: LBSeries, _ mean: Double, _ sd: Double, within: Double?) -> LBEvaluation {
            let obs: [LBDailyObservation] = (1...40).map { i in
                let wobble = sd * sin(Double(i) * 1.7) * 1.1
                let x = mean + wobble
                return LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(tE - i),
                                          value: s.usesLog ? exp(x) : x, qualityStatus: .ok, coverage: 300,
                                          withinDayScale: within)
            }
            return LongitudinalBaseline.evaluate(asOf: asOf, series: s, observations: obs)
        }
        // Owner levels (phone + production, 2026-09-29 … 10-08): sleep RHR 46–53, nightly HRV 53–85 ms, awake still HR
        // 65.7 ± 4.9 (audit A), steady walking ~100, session HR p50 95–126 / within-session MAD ~15, recovery ~85.
        return [
            series(.sleepRHR, 49, 2, within: nil),
            series(.sleepHRVLn, log(75), 0.12, within: nil),
            series(.sleepResp, 15.5, 0.5, within: nil),
            series(.sleepTemp, 34.6, 0.25, within: nil),
            series(.sleepHR, 55, 2, within: 3),
            series(.awakeRestHR, 65.7, 2.5, within: 4.9),
            series(.awakeRestHRVLn, log(70), 0.12, within: 0.2),
            series(.walkingHR, 100, 4, within: 6),
            // EXERCISE-BEGIN
            series(.exerciseSessionHR, 108, 7, within: 15),
            series(.exerciseRecoveryHR, 86, 4, within: 7),
            // EXERCISE-END
        ]
    }

    struct EveningResult {
        var notifications: [String] = []
        var severeMinutes = 0
        var heldMinutes = 0
        var verdicts: [String: Int] = [:]
        var kinds: [String: Int] = [:]
    }

    static func replay(_ e: Export, from: Int, to: Int, refs: [LBEvaluation], exercise: Bool,
                       step: Int = 60) -> EveningResult {
        let prompt = UniTSPrompt.from(evaluations: refs)
        var carry = WatchdogCarry.empty
        var out = EveningResult()
        // EXERCISE-BEGIN
        var hrByMin: [Int: (Double, Int)] = [:]
        for h in slice(e.hr, \.ts, from - WatchdogExerciseContext.historySeconds - 60, to) {
            let m = h.ts - h.ts % 60; hrByMin[m, default: (0, 0)].0 += Double(h.bpm); hrByMin[m, default: (0, 0)].1 += 1
        }
        var dynByMin: [Int: (Double, Int)] = [:]
        for g in slice(e.imu, \.ts, from - WatchdogExerciseContext.historySeconds - 60, to) {
            guard let d = g.dynAccel else { continue }
            let m = g.ts - g.ts % 60; dynByMin[m, default: (0, 0)].0 += d; dynByMin[m, default: (0, 0)].1 += 1
        }
        var walkByMin: [Int: Int] = [:], stepsByMin: [Int: Int] = [:]
        for st in slice(e.steps, \.ts, from - WatchdogExerciseContext.historySeconds - 60, to) {
            let m = st.ts - st.ts % 60
            stepsByMin[m, default: 0] += 1
            if st.activityClass == 1 || st.activityClass == 2 { walkByMin[m, default: 0] += 1 }
        }
        let intervals = e.intervals.filter { $0.endTs > from - WatchdogExerciseContext.historySeconds && $0.startTs < to }
        func evidence(_ m: Int) -> ExerciseSessionMinute {
            let mid = m + 30
            return ExerciseSessionRule.minute(minuteUnix: m, hr: hrByMin[m].map { $0.0 / Double($0.1) },
                                              dynMean: dynByMin[m].map { $0.0 / Double($0.1) },
                                              walkRunTicks: walkByMin[m] ?? 0, stepTicks: stepsByMin[m] ?? 0,
                                              interval: intervals.last { $0.startTs <= mid && $0.endTs > mid })
        }
        // EXERCISE-END
        var now = from
        while now <= to {
            let lo = now - WatchdogConfig.contextSeconds
            let feedHR = slice(e.hr, \.ts, lo, now)
            if feedHR.count < 60 { now += step; continue }
            let feedRR = slice(e.rr, \.ts, lo, now)
            let feed = WatchdogFeed(family: .whoop5, hrSource: .v18, nowUnix: now, hr: feedHR, rr: feedRR,
                                    skinTempC: slice(e.temp, \.ts, lo, now), motion: slice(e.motion, \.ts, lo, now),
                                    imu: slice(e.imu, \.ts, lo, now), steps: slice(e.steps, \.ts, lo, now))
            var window = WatchdogWindowBuilder.build(feed)
            if case .success(var w) = window {
                var q = WatchdogQualityFeed()
                q.placement = "bicep"
                q.charging = false
                q.wristEvents = e.wrist.filter { $0.ts < now && now - $0.ts < 86_400 }
                q.resetEvents = e.resets.filter { $0 < now && now - $0 < 86_400 }
                for i in 0..<w.hr.count {
                    let m = w.startUnix + i * 60
                    q.hrSecondsByMinute[m] = slice(feedHR, \.ts, m, m + 60).count
                    let beats = slice(feedRR, \.ts, m, m + 60)
                    if !beats.isEmpty { q.rrCoverageByMinute[m] = Double(beats.reduce(0) { $0 + $1.rrMs }) / 60_000 }
                }
                q.contextIntervals = e.intervals.filter { $0.endTs > lo - 600 && $0.startTs < now }
                w.quality = q
                // EXERCISE-BEGIN
                if exercise {
                    let hist = stride(from: now - WatchdogExerciseContext.historySeconds, to: now - now % 60, by: 60)
                        .map(evidence)
                    w.exercise = WatchdogExerciseContext.build(minutes: hist, windowStart: w.startUnix,
                                                               seqLen: w.hr.count, nowUnix: now, evaluations: refs,
                                                               hrMax: 195, hrMaxFromFormula: true)
                }
                // EXERCISE-END
                let qa = WatchdogSignalQuality.assess(window: w)
                let ctx = WatchdogContextResolver.resolve(window: w, quality: qa, carryLastWorkoutEndUnix: carry.lastWorkoutEndUnix)
                if let k = ctx.last?.kind.rawValue { out.kinds[k, default: 0] += 1 }
                window = .success(w)
            }
            let r = Watchdog.evaluate(window: window, prompt: prompt, evaluations: refs, nowUnix: now,
                                      previous: carry, sleepSessionOpen: e.sleep.contains { $0.contains(now) },
                                      sleepIntervals: e.sleep.filter { $0.startUnix < now && $0.endUnix > now - 86_400 })
            carry = r.carry
            if r.shouldNotify {
                let alerts = (r.verdicts ?? []).filter { $0.decision == .alert }
                out.notifications.append("\(now) " + alerts.map { "\($0.candidate.kind.rawValue)[\($0.candidate.reference)] \($0.summary)" }.joined(separator: "; "))
                carry.notifyDelivery = "sent"; carry.notifiedSevereEpisodeId = carry.episodeId ?? ""
            }
            if r.severity == .severe { out.severeMinutes += 1 }
            if r.severity == .candidate || r.severity == .note { out.heldMinutes += 1 }
            for v in r.verdicts ?? [] {
                out.verdicts["\(v.candidate.kind.rawValue):\(v.decision.rawValue)", default: 0] += 1
            }
            now += step
        }
        return out
    }

    /// Whole days (10-06 12:00 → 10-09 01:00 local, 5-minute ticks) with established references: the sensitivity side
    /// of removing the 30-minute post-movement mute. Prints notifications and held ticks; nothing may notify.
    func testWholeDaysEstablished() throws {
        guard let dir = ProcessInfo.processInfo.environment["NARA_REPLAY_DIR"] else {
            throw XCTSkip("NARA_REPLAY_DIR not set")
        }
        let e = Self.load(dir)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
        let a = Int(f.date(from: "2026-10-06 12:00")!.timeIntervalSince1970)
        let b = Int(f.date(from: "2026-10-09 01:00")!.timeIntervalSince1970)
        let refs = Self.establishedReferences(asOf: "2026-10-08")
        var lines = ["WHOLE-DAYS (5-min ticks, established references)"]
        var modes: [(String, Bool)] = [("no-session", false)]
        // EXERCISE-BEGIN
        modes.append(("session", true))
        // EXERCISE-END
        for (name, ex) in modes {
            let r = Self.replay(e, from: a, to: b, refs: refs, exercise: ex, step: 300)
            lines.append(String(format: "%-12@ notif=%d severe_ticks=%d held_ticks=%d kinds=%@ verdicts=%@", name as NSString,
                                r.notifications.count, r.severeMinutes, r.heldMinutes,
                                r.kinds.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",") as NSString,
                                r.verdicts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") as NSString))
            for n in r.notifications.prefix(6) { lines.append("    notify \(n)") }
            if ex { XCTAssertEqual(r.notifications.count, 0) }
        }
        print(lines.joined(separator: "\n"))
    }

    func testGymEveningsDoNotAlarmAndContextIsExercise() throws {
        guard let dir = ProcessInfo.processInfo.environment["NARA_REPLAY_DIR"] else {
            throw XCTSkip("NARA_REPLAY_DIR not set")
        }
        let e = Self.load(dir)
        XCTAssertFalse(e.hr.isEmpty)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
        // Evenings with gravity (dynamic acceleration) on the phone: 10-06, 10-07, 10-08 (20:30 → 01:30 local).
        let evenings = ["2026-10-06", "2026-10-07", "2026-10-08"].map { d -> (String, Int, Int) in
            let a = Int(f.date(from: "\(d) 20:30")!.timeIntervalSince1970)
            return (d, a, a + 5 * 3600)
        }
        let learning = Self.learningReferences(e, asOf: "2026-10-08", calendar: cal)
        let established = Self.establishedReferences(asOf: "2026-10-08")
        var lines: [String] = ["GYM-REPLAY (minute ticks, 20:30–01:30 PDT)"]
        var totals: [String: (notif: Int, severe: Int)] = [:]
        let modes: [(String, [LBEvaluation], Bool)] = [
            ("learning/no-session", learning, false),
            ("established/no-session", established, false),
            // EXERCISE-BEGIN
            ("learning/session", learning, true),
            ("established/session", established, true),
            // EXERCISE-END
        ]
        for (name, refs, ex) in modes {
            for (day, a, b) in evenings {
                let r = Self.replay(e, from: a, to: b, refs: refs, exercise: ex)
                totals[name, default: (0, 0)].notif += r.notifications.count
                totals[name, default: (0, 0)].severe += r.severeMinutes
                lines.append(String(format: "%-24@ %@  notif=%d severe_min=%d held_min=%d kinds=%@ verdicts=%@",
                                    name as NSString, day as NSString, r.notifications.count, r.severeMinutes,
                                    r.heldMinutes,
                                    r.kinds.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",") as NSString,
                                    r.verdicts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") as NSString))
                for n in r.notifications.prefix(4) { lines.append("    notify \(n)") }
            }
        }
        print(lines.joined(separator: "\n"))
        // EXERCISE-BEGIN
        // The owner's evenings were ordinary workouts (annotated "exertion hard" on 10-06): with the session context
        // nothing may notify, even once every personal reference is established.
        XCTAssertEqual(totals["established/session"]?.notif, 0)
        XCTAssertEqual(totals["learning/session"]?.notif, 0)
        // EXERCISE-END
    }
}
