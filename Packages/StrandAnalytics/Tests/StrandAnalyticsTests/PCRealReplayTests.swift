import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Opt-in replay of real, de-identified night exports (HR 1 Hz, whole-second R-R, gravity) through the context
/// engine. Nothing is committed: point `PC_REAL_REPLAY_DIR` at a directory of `<night>/{hr,rr,grav}.csv` (+ `window`)
/// exports. Skips when unset. Asserts arithmetic and integration invariants only — it says nothing about accuracy.
final class PCRealReplayTests: XCTestCase {
    typealias PC = PhysiologyContext

    struct Night {
        var name: String
        var hr: [HRSample]
        var rr: [RRInterval]
        var gravity: [GravitySample]
        var window: (start: Int, end: Int)?
    }

    static var replayDir: URL? {
        ProcessInfo.processInfo.environment["PC_REAL_REPLAY_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static func rows(_ url: URL) -> [[Substring]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.split(separator: ",") }
    }

    static func loadNights() -> [Night] {
        guard let dir = replayDir,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted().compactMap { name in
            let d = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let hr = rows(d.appendingPathComponent("hr.csv")).compactMap { r -> HRSample? in
                guard r.count >= 2, let ts = Int(r[0]), let bpm = Int(r[1]) else { return nil }
                return HRSample(ts: ts, bpm: bpm)
            }
            // Storage identity: seq is the occurrence index of an equal value within the same second.
            var seen: [String: Int] = [:]
            let rr = rows(d.appendingPathComponent("rr.csv")).compactMap { r -> RRInterval? in
                guard r.count >= 2, let ts = Int(r[0]), let ms = Int(r[1]) else { return nil }
                let key = "\(ts)|\(ms)"
                let seq = seen[key, default: 0]
                seen[key] = seq + 1
                return RRInterval(ts: ts, rrMs: ms, srcChannel: nil, ord: nil, seq: seq)
            }
            let grav = rows(d.appendingPathComponent("grav.csv")).compactMap { r -> GravitySample? in
                guard r.count >= 4, let ts = Int(r[0]), let x = Double(r[1]), let y = Double(r[2]),
                      let z = Double(r[3]) else { return nil }
                return GravitySample(ts: ts, x: x, y: y, z: z)
            }
            let window = (try? String(contentsOf: d.appendingPathComponent("window"), encoding: .utf8))
                .flatMap { text -> (Int, Int)? in
                    let p = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Int($0) }
                    return p.count >= 2 ? (p[0], p[1]) : nil
                }
            guard !hr.isEmpty || !grav.isEmpty else { return nil }
            return Night(name: name, hr: hr, rr: rr, gravity: grav, window: window)
        }
    }

    /// Build a DayInput for the local day that owns the night's end, the way the worker would.
    static func ownerDay(_ n: Night, timezoneId: String) -> String {
        PC.localTime(at: max(n.hr.last?.ts ?? 0, n.gravity.last?.ts ?? 0), timezoneId: timezoneId).localDay
    }

    static func dayInput(_ n: Night, timezoneId: String, mode: PC.ProcessingMode, cutoff: Int?,
                         day fixedDay: String? = nil) -> PC.DayInput {
        let lastTs = max(n.hr.last?.ts ?? 0, n.gravity.last?.ts ?? 0)
        let day = fixedDay ?? ownerDay(n, timezoneId: timezoneId)
        let window = PC.Engine.dayInterval(day, timezoneId: timezoneId)
        let offset = TimeZone(identifier: timezoneId)?.secondsFromGMT(for: Date(timeIntervalSince1970: Double(window.start))) ?? 0
        let sessions = SleepStager.detectSleep(hr: n.hr, rr: n.rr, gravity: n.gravity, tzOffsetSeconds: offset,
                                               useSleepStagerV2: true)
        // Availability: the strap offloads in batches; model a 15-minute upload lag.
        let lag = 900
        let hr = n.hr.map { PC.HeartRateObservation(ts: $0.ts, bpm: $0.bpm, availableAt: $0.ts + lag) }
        let beats = n.rr.map { PC.BeatIntervalObservation(ts: $0.ts, rrMs: $0.rrMs, seq: $0.seq, availableAt: $0.ts + lag) }
        let motion = n.gravity.map { PC.MotionObservation(ts: $0.ts, dynAccelG: $0.dynAccel, x: $0.x, y: $0.y, z: $0.z,
                                                          availableAt: $0.ts + lag) }
        var measurements: [PC.MeasurementInput] = []
        var sleepInputs: [PC.SleepSessionInput] = []
        for (i, s) in sessions.enumerated() {
            let id = "replay-\(n.name)-\(i)"
            let available = s.end + lag
            sleepInputs.append(PC.SleepSessionInput(
                id: id, interval: .init(s.start, s.end), isNap: nil, efficiency: s.efficiency, hrOnly: s.hrOnly,
                stages: s.stages.map { PC.StageSpan(interval: .init($0.start, $0.end), stage: $0.stage) },
                availableAt: available, sourceDay: day, detector: "replay-sleepstager-v2"))
            if let hrv = s.avgHRV {
                measurements.append(PC.MeasurementInput(
                    metric: .hrvRmssd,
                    method: .init(id: "snapshot.hrv_rmssd.night", algorithmVersion: "replay-sleepstager-v2",
                                  aggregation: .meanOverWindows, windowS: s.end - s.start, units: "ms"),
                    source: .init(product: .scoringSnapshot, key: "replay.session.\(i).avg_hrv"),
                    value: hrv, support: .init(s.start, s.end), availableAt: available, sessionId: id))
            }
            if let rhr = s.restingHR {
                measurements.append(PC.MeasurementInput(
                    metric: .restingHeartRate,
                    method: .init(id: "snapshot.resting_hr.night", algorithmVersion: "replay-sleepstager-v2",
                                  aggregation: .minimumOfBins, windowS: s.end - s.start, units: "bpm"),
                    source: .init(product: .scoringSnapshot, key: "replay.session.\(i).resting_hr"),
                    value: Double(rhr), support: .init(s.start, s.end), availableAt: available, sessionId: id))
            }
        }
        // 5-minute RMSSD windows on the local-midnight grid (gap-aware, as the series does; no motion gate here —
        // validity and eligibility decide).
        var byBucket: [Int: [RRInterval]] = [:]
        for b in n.rr { byBucket[window.start + Int(floor(Double(b.ts - window.start) / 300)) * 300, default: []].append(b) }
        for b in byBucket.keys.sorted() {
            let beats = byBucket[b]!
            guard beats.count >= 20 else { continue }
            let clean = HRVAnalyzer.cleanRRGapAware(beats.map { Double($0.rrMs) })
            guard let r = HRVAnalyzer.rmssdGapAware(clean.nn, clean.contiguous), r.isFinite else { continue }
            measurements.append(PC.MeasurementInput(
                metric: .hrvRmssd,
                method: .init(id: "replay.hrv_rmssd.5min", algorithmVersion: "replay-1", aggregation: .window,
                              windowS: 300, units: "ms"),
                source: .init(product: .contextDerived, key: "replay.hrv@\(b)"),
                value: r, support: .init(b, b + 300), sampleCount: beats.count, availableAt: b + 300 + lag))
        }
        let generated = (n.gravity.last?.ts ?? lastTs) + 40 * 3600
        return PC.DayInput(identity: .init(deviceScope: "replay", day: day, timezoneId: timezoneId, dayWindow: window),
                           mode: mode, availabilityCutoff: cutoff ?? generated, generatedAt: cutoff ?? generated,
                           heartRate: hr, beatIntervals: beats, motion: motion, measurements: measurements,
                           sleepSessions: sleepInputs, regime: .init(scoringAlgorithmVersion: "replay"))
    }

    func testRealNightsSatisfyContextInvariants() throws {
        let nights = Self.loadNights()
        try XCTSkipIf(nights.isEmpty, "set PC_REAL_REPLAY_DIR to a directory of night exports")
        let zone = ProcessInfo.processInfo.environment["PC_REAL_REPLAY_TZ"] ?? "America/Los_Angeles"
        var lines: [String] = ["night | envelopes | valid | degraded | invalid | missing | sleep-eligible | awake-eligible | unknown-awake | doc KB | stored KB | build ms"]
        for n in nights {
            let input = Self.dayInput(n, timezoneId: zone, mode: .retrospective, cutoff: nil)
            let t0 = Date()
            let doc = PC.Engine.buildDay(input, history: .empty)
            let ms = Date().timeIntervalSince(t0) * 1000
            let data = try PC.encoder().encode(doc)
            XCTAssertEqual(try PC.decoder().decode(PC.DayDocument.self, from: data), doc, n.name)
            XCTAssertEqual(try PC.encoder().encode(PC.Engine.buildDay(input, history: .empty)), data, "\(n.name) determinism")
            let (summary, tables) = PC.StoredDocument.split(doc)
            XCTAssertEqual(PC.StoredDocument.join(summary: summary, tables: tables), doc, "\(n.name) stored form")
            let storedKB = (try PC.encoder().encode(summary).count + tables.reduce(0) { $0 + ((try? PC.encoder().encode($1).count) ?? 0) }) / 1024
            for e in doc.envelopes {
                XCTAssertTrue(PC.IntervalAlgebra.reconciles(e.activity), "\(n.name) \(e.id)")
                XCTAssertEqual(e.activity.intervalS, e.support.duration)
            }
            let count = { (s: PC.ValidityState) in doc.envelopes.filter { $0.validity.state == s }.count }
            let verdicts = doc.envelopes.flatMap { $0.eligibility }
            let sleepOK = verdicts.filter { $0.comparison == .sleepMeasurement && $0.state == .eligible }.count
            let awakeOK = verdicts.filter { $0.comparison == .stableAwakeRest && $0.state == .eligible }.count
            let awakeUnknown = verdicts.filter { $0.comparison == .stableAwakeRest && $0.state == .unknown }.count
            lines.append("\(n.name) | \(doc.envelopes.count) | \(count(.valid)) | \(count(.degraded)) | \(count(.invalid)) | \(count(.missing)) | \(sleepOK) | \(awakeOK) | \(awakeUnknown) | \(data.count / 1024) | \(storedKB) | \(Int(ms))")

            // Causal replay: a cutoff in the middle of the night, then the same cutoff with all later data present.
            if let mid = n.hr.dropFirst(n.hr.count / 2).first?.ts {
                let partial = PC.Night_filter(n, before: mid)
                let day = Self.ownerDay(n, timezoneId: zone)
                let a = PC.Engine.buildDay(Self.dayInput(partial, timezoneId: zone, mode: .causalLive, cutoff: mid,
                                                         day: day), history: .empty)
                let b = PC.Engine.buildDay(Self.dayInput(n, timezoneId: zone, mode: .causalLive, cutoff: mid,
                                                         day: day), history: .empty)
                // The detector re-runs on more data in `b`; sessions published after the cutoff are excluded by
                // availability, so the causal documents must agree on every envelope available at the cutoff.
                XCTAssertEqual(a.envelopes.map(\.id), b.envelopes.map(\.id), "\(n.name) causal envelope set")
                XCTAssertTrue(b.envelopes.allSatisfy { $0.support.end <= mid })
            }
        }
        print("PC_REAL_REPLAY\n" + lines.joined(separator: "\n"))
    }
}

extension PhysiologyContext {
    /// Test helper: the part of a night observed before `ts`.
    static func Night_filter(_ n: PCRealReplayTests.Night, before ts: Int) -> PCRealReplayTests.Night {
        PCRealReplayTests.Night(name: n.name, hr: n.hr.filter { $0.ts < ts }, rr: n.rr.filter { $0.ts < ts },
                                gravity: n.gravity.filter { $0.ts < ts }, window: n.window)
    }
}
