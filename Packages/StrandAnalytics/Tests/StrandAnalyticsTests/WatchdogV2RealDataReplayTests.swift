import XCTest
import WhoopStore
import WhoopProtocol
@testable import StrandAnalytics

/// Replays a real phone history (owner's own WHOOP 5/MG, exported read-only to CSV) through the v2 Watchdog
/// pipeline every 5 minutes and reports what it would have shown and sent. Skipped unless NARA_REPLAY_DIR points
/// at the export (hr.csv, rr.csv, temp.csv, gravity.csv, steps.csv, sleep.csv, events.csv, optional
/// server_daily.csv and intervals.json). No real data is committed.
final class WatchdogV2RealDataReplayTests: XCTestCase {

    func loadCSV(_ path: String) -> [[Substring]] {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return s.split(whereSeparator: \.isNewline).map { $0.split(separator: ",", omittingEmptySubsequences: false) }
    }

    func testReplayRealHistory() throws {
        guard let dir = ProcessInfo.processInfo.environment["NARA_REPLAY_DIR"] else {
            throw XCTSkip("NARA_REPLAY_DIR not set")
        }
        func p(_ f: String) -> String { (dir as NSString).appendingPathComponent(f) }
        let hr = loadCSV(p("hr.csv")).compactMap { r -> HRSample? in
            guard r.count >= 2, let t = Int(r[0]), let b = Int(r[1]) else { return nil }
            return HRSample(ts: t, bpm: b)
        }
        // R-R pinned to one transport (v18 history, srcChannel 5, when present) — the de-dup rule of the
        // reliability work; suspect/fill rows dropped.
        var rrRows = loadCSV(p("rr.csv")).compactMap { r -> (Int, Int, Int, Int, Int)? in
            guard r.count >= 5, let t = Int(r[0]), let ms = Int(r[1]), let seq = Int(r[2]), let ch = Int(r[3]),
                  let sus = Int(r[4]) else { return nil }
            return (t, ms, seq, ch, sus)
        }
        let hasCh5 = rrRows.contains { $0.3 == 5 }
        rrRows = rrRows.filter { (hasCh5 ? $0.3 == 5 : true) && $0.4 == 0 && $0.1 != 500 && $0.1 != 333 }
        let rr = rrRows.map { RRInterval(ts: $0.0, rrMs: $0.1) }
        let temp = loadCSV(p("temp.csv")).compactMap { r -> WatchdogScalarSample? in
            guard r.count >= 2, let t = Int(r[0]), let raw = Double(r[1]) else { return nil }
            return WatchdogScalarSample(ts: t, value: raw / 100)
        }
        let imu = loadCSV(p("gravity.csv")).compactMap { r -> WatchdogIMUSample? in
            guard r.count >= 5, let t = Int(r[0]), let x = Double(r[1]), let y = Double(r[2]), let z = Double(r[3]) else { return nil }
            return WatchdogIMUSample(ts: t, x: x, y: y, z: z, dynAccel: Double(r[4]))
        }
        let motion = imu.compactMap { s in s.dynAccel.map { WatchdogScalarSample(ts: s.ts, value: min(1, $0 / 0.4)) } }
        let steps = loadCSV(p("steps.csv")).compactMap { r -> StepSample? in
            guard r.count >= 3, let t = Int(r[0]), let c = Int(r[1]), let k = Int(r[2]) else { return nil }
            return StepSample(ts: t, counter: c, activityClass: k)
        }
        let sleep = loadCSV(p("sleep.csv")).compactMap { r -> WatchdogSleepInterval? in
            guard r.count >= 2, let a = Int(r[0]), let b = Int(r[1]) else { return nil }
            return WatchdogSleepInterval(startUnix: a, endUnix: b)
        }
        let wrist = loadCSV(p("events.csv")).compactMap { r -> WatchdogQualityFeed.WristEvent? in
            guard r.count >= 2, let t = Int(r[0]) else { return nil }
            if r[1].hasPrefix("WRIST_ON") { return .init(ts: t, on: true) }
            if r[1].hasPrefix("WRIST_OFF") { return .init(ts: t, on: false) }
            return nil
        }
        let resets = loadCSV(p("events.csv")).compactMap { r -> Int? in
            guard r.count >= 2, let t = Int(r[0]) else { return nil }
            return r[1].hasPrefix("WRIST") ? nil : t
        }
        XCTAssertFalse(hr.isEmpty)

        // Layer 1 references: sleep series from the server nightly history; context strata from intervals.
        var evaluations: [LBEvaluation] = []
        let daily = loadCSV(p("server_daily.csv")).dropFirst()
        let lastDay = daily.compactMap { $0.first.map(String.init) }.filter { $0.count == 10 }.max() ?? "2026-10-07"
        func obs(_ col: Int) -> [LBDailyObservation] {
            daily.compactMap { r in
                guard r.count > col, r[0].count == 10, let v = Double(r[col]) else { return nil }
                return LBDailyObservation(day: String(r[0]), value: v, qualityStatus: .ok)
            }
        }
        for (s, col) in [(LBSeries.sleepRHR, 2), (.sleepHRVLn, 3), (.sleepResp, 4), (.sleepTemp, 5)] {
            evaluations.append(LongitudinalBaseline.evaluate(asOf: lastDay, series: s, observations: obs(col)))
        }
        var intervalRows: [ActivityContextIntervalRow] = []
        if let data = FileManager.default.contents(atPath: p("intervals.json")),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            intervalRows = arr.map { d in
                ActivityContextIntervalRow(startTs: d["startTs"] as! Int, endTs: d["endTs"] as! Int,
                    activityClass: d["activityClass"] as! String, confidence: (d["confidence"] as? Double) ?? 0,
                    evidenceQuality: (d["evidenceQuality"] as? Double) ?? 0, posture: d["posture"] as? String,
                    locomotion: d["locomotion"] as? String, sleepState: d["sleepState"] as! String,
                    wearState: d["wearState"] as! String, intensity: d["intensity"] as? Double,
                    hrSamples: d["hrSamples"] as! Int, hrMean: d["hrMean"] as? Double, rmssd: d["rmssd"] as? Double,
                    rrBeats: d["rrBeats"] as! Int, rrDiffSqSumMs2: (d["rrDiffSqSumMs2"] as? Double) ?? 0,
                    rrDiffCount: (d["rrDiffCount"] as? Int) ?? 0)
            }
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            let strata = LongitudinalBaseline.ContextMaterializer.observations(rows: intervalRows, calendar: cal)
            for (s, o) in strata {
                evaluations.append(LongitudinalBaseline.evaluate(asOf: lastDay, series: s, observations: o))
            }
        }
        let prompt = UniTSPrompt.from(evaluations: evaluations)

        // Sorted arrays + binary search for the 30-minute slices.
        func slice<T>(_ xs: [T], _ ts: (T) -> Int, _ lo: Int, _ hi: Int) -> [T] {
            var a = 0, b = xs.count
            while a < b { let m = (a + b) / 2; if ts(xs[m]) < lo { a = m + 1 } else { b = m } }
            var e = a
            while e < xs.count && ts(xs[e]) < hi { e += 1 }
            return Array(xs[a..<e])
        }
        let start = (hr.first!.ts / 300 + 7) * 300
        let end = hr.last!.ts
        var carry = WatchdogCarry.empty
        var severityCount: [String: Int] = [:]
        var verdictCount: [String: Int] = [:]
        var notifications: [(Int, String)] = []
        var quality: [String: Int] = [:]
        var ticks = 0
        var heldExamples: [String] = []
        let clock = Date()
        var now = start
        while now <= end {
            let lo = now - WatchdogConfig.contextSeconds
            let feedHR = slice(hr, \.ts, lo, now)
            if feedHR.count < 60 { now += 300; continue }
            let feedRR = slice(rr, \.ts, lo, now)
            let feed = WatchdogFeed(family: .whoop5, hrSource: .v18, nowUnix: now, hr: feedHR, rr: feedRR,
                                    skinTempC: slice(temp, \.ts, lo, now), motion: slice(motion, \.ts, lo, now),
                                    imu: slice(imu, \.ts, lo, now), steps: slice(steps, \.ts, lo, now))
            var window = WatchdogWindowBuilder.build(feed)
            if case .success(var w) = window {
                var q = WatchdogQualityFeed()
                q.wristEvents = wrist.filter { $0.ts < now && now - $0.ts < 86_400 }
                q.resetEvents = resets.filter { $0 < now && now - $0 < 86_400 }
                for i in 0..<w.hr.count {
                    let m = w.startUnix + i * 60
                    q.hrSecondsByMinute[m] = slice(feedHR, \.ts, m, m + 60).count
                    let beats = slice(feedRR, \.ts, m, m + 60)
                    if !beats.isEmpty { q.rrCoverageByMinute[m] = Double(beats.reduce(0) { $0 + $1.rrMs }) / 60_000 }
                }
                q.contextIntervals = intervalRows.filter { $0.endTs > lo - 600 && $0.startTs < now }
                w.quality = q
                let qa = WatchdogSignalQuality.assess(window: w)
                for m in qa { quality["\(m.onBody.rawValue)/\(m.signal.rawValue)/\(m.motion.rawValue)", default: 0] += 1 }
                window = .success(w)
            }
            let sleepOpen = sleep.contains { $0.contains(now) }
            let r = Watchdog.evaluate(window: window, prompt: prompt, evaluations: evaluations, nowUnix: now,
                                      previous: carry, sleepSessionOpen: sleepOpen,
                                      sleepIntervals: sleep.filter { $0.startUnix < now && $0.endUnix > now - 86_400 })
            carry = r.carry
            if r.shouldNotify {
                notifications.append((now, (r.verdicts ?? []).filter { $0.decision == .alert }.map(\.summary).joined(separator: "; ")))
                carry.notifyDelivery = "sent"; carry.notifiedSevereEpisodeId = carry.episodeId ?? ""
            }
            severityCount[r.severity.rawValue, default: 0] += 1
            for v in r.verdicts ?? [] {
                verdictCount["\(v.candidate.kind.rawValue):\(v.decision.rawValue)", default: 0] += 1
                if v.decision == .hold, heldExamples.count < 8 {
                    heldExamples.append("\(now) \(v.candidate.kind.rawValue) \(v.candidate.channels) " +
                                        v.checks.filter { $0.outcome != .pass && $0.outcome != .notApplicable }
                                            .map { "\($0.check.rawValue)=\($0.outcome.rawValue)(\($0.reason))" }.joined(separator: " "))
                }
            }
            ticks += 1
            now += 300
        }
        let ms = Date().timeIntervalSince(clock) * 1000 / Double(max(ticks, 1))
        var lines = ["REAL-REPLAY ticks=\(ticks) span_days=\(String(format: "%.1f", Double(end - start) / 86_400)) ms_per_tick=\(String(format: "%.1f", ms))"]
        lines.append("severity: " + severityCount.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        lines.append("verdicts: " + verdictCount.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        lines.append("notifications: \(notifications.count)")
        for n in notifications { lines.append("  notify \(n.0) \(n.1)") }
        let totalQ = quality.values.reduce(0, +)
        lines.append("minute quality (onBody/signal/motion) top:")
        for (k, v) in quality.sorted(by: { $0.value > $1.value }).prefix(10) {
            lines.append(String(format: "  %@ %.1f%%", k, 100 * Double(v) / Double(max(totalQ, 1))))
        }
        for dim in 0..<3 {
            var marg: [String: Int] = [:]
            for (k, v) in quality { marg[String(k.split(separator: "/")[dim]), default: 0] += v }
            lines.append(["onBody", "signal", "motion"][dim] + ": " + marg.sorted { $0.key < $1.key }
                .map { String(format: "%@=%.1f%%", $0.key, 100 * Double($0.value) / Double(max(totalQ, 1))) }
                .joined(separator: " "))
        }
        lines.append("evaluations: " + evaluations.map { "\($0.series.rawValue):n=\($0.nLong),\($0.maturity.rawValue)" }.joined(separator: " "))
        for h in heldExamples { lines.append("  held \(h)") }
        print(lines.joined(separator: "\n"))
    }
}
