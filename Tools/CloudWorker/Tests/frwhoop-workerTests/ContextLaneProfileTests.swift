import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// Build cost and document size of the context lane for a representative full day and for the largest day the
/// read window admits, next to the scoring computation on the same streams (spec §15: profile representative and
/// worst-supported day sizes against the baseline worker).
///
/// Opt-in: set FRWHOOP_CONTEXT_PROFILE=1 (skipped otherwise; it is slow in a debug build). Time it in release, as
/// the worker runs: `swift test -c release -Xswiftc -enable-testing --filter ContextLaneProfileTests`. Numbers are
/// printed as `context-profile:` lines and recorded in docs/physiology-context/notes/worker.md. While the context
/// systems are skeletons the build cost is the lane's own work (causal view, transport selection, series
/// recomputation, envelopes, fingerprint, encoding); rerun after integration.
final class ContextLaneProfileTests: XCTestCase {
    typealias PC = PhysiologyContext

    let dayStart = 1_790_985_600  // 2026-10-03T00:00:00Z

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["FRWHOOP_CONTEXT_PROFILE"] == "1" else {
            throw XCTSkip("set FRWHOOP_CONTEXT_PROFILE=1 to profile the context lane")
        }
    }

    private func ms(_ body: () throws -> Void) rethrows -> Double {
        let t = Date()
        try body()
        return Date().timeIntervalSince(t) * 1000
    }

    private func job(_ mode: PC.ProcessingMode) -> ContextInputs.Job {
        ContextInputs.Job(userId: "u", deviceId: "d", day: "2026-10-03", mode: mode, inputRevision: 1,
                          leaseToken: "t", timezoneId: "UTC", cutoffOverride: nil,
                          claimedAt: mode == .causalLive ? dayStart + 20 * 3_600 : dayStart + 56 * 3_600)
    }

    /// `ContextInputs.historyDays` (160) days of history (12 series a day), 3 days of bouts, 10 frozen references,
    /// 14 prior nights.
    private func addHistory(_ l: inout ContextInputs.Loaded, mode: PC.ProcessingMode) {
        for d in 1...ContextInputs.historyDays {
            let key = ContextInputs.shiftDay("2026-10-03", by: -d)!
            for s in 0..<12 {
                l.historyValues.append(PC.DailyValue(day: key, seriesKey: "series.\(s)", regimeKey: "r\(s % 3)",
                                                     metric: .hrvRmssd, value: 40 + Double(s), units: "ms",
                                                     supportCount: 3, supportUnit: "windows", supportS: 900,
                                                     mode: mode, finality: .final))
            }
            if d <= 3 {
                for b in 0..<5 {
                    let start = dayStart - d * 86_400 + 36_000 + b * 3_600
                    l.historyBouts.append(PC.ExertionBout(id: "bout-\(d)-\(b)", interval: PC.Interval(start, start + 900),
                                                          day: key, kind: "walking", status: .complete, durationS: 900))
                }
            }
            if d <= 14 {
                let payload = ContextDaySim.snapshotPayload(sessions: [(dayStart - d * 86_400 - 3_600,
                                                                        dayStart - d * 86_400 + 7 * 3_600)])
                l.otherSnapshots.append(ContextInputs.parseSnapshot(day: key, payloadText: payload,
                                                                    resultRevision: Int64(100 - d), inputRevision: 0,
                                                                    availableAt: dayStart - d * 86_400 + 8 * 3_600)!)
            }
        }
        for f in 0..<10 {
            l.frozen.append(PC.FrozenReference(id: "f\(f)", seriesKey: "series.\(f)", regimeKey: "r0", version: 1,
                                               fromDay: "2026-07-01", toDay: "2026-07-14", supportDays: 14,
                                               center: 45, scale: 6, transform: "ln", selectionRule: "first_14",
                                               createdForDay: "2026-07-15", policyFingerprint: "x"))
        }
    }

    private func representative() -> (ContextInputs.Loaded, ContextDaySim) {
        let sim = ContextDaySim.representativeDay(dayStart: dayStart)
        var l = sim.loaded()
        let payload = ContextDaySim.snapshotPayload(sessions: [(dayStart - 3_600, dayStart + 7 * 3_600),
                                                               (dayStart + 23 * 3_600, dayStart + 24 * 3_600)])
        l.snapshot = ContextInputs.parseSnapshot(day: "2026-10-03", payloadText: payload, resultRevision: 7,
                                                 inputRevision: 3, availableAt: dayStart + 8 * 3_600)
        l.device = .init(family: "WHOOP 5.0 / MG", firmware: "50.36", sourceKind: "noop_push")
        addHistory(&l, mode: .retrospective)
        return (l, sim)
    }

    /// Every stream at 1 Hz across the whole 60 h read window, both R-R transports, HART epochs and decoder runs
    /// over all of it, 200 exposure revisions, 40 wear events.
    private func worstCase() -> (ContextInputs.Loaded, ContextDaySim) {
        var sim = ContextDaySim(seed: 5)
        sim.duplicateTransport = true
        let h = 3_600
        let start = dayStart - 30 * h
        let phases: [(ContextDaySim.Phase, Int)] = [(.sit, 6), (.sleep, 8), (.sit, 3), (.walk, 1), (.sit, 11),
                                                    (.sleep, 8), (.sit, 3), (.walk, 1), (.sit, 10), (.sleep, 9)]
        var t = start
        for (p, hours) in phases { sim.run(p, from: t, to: t + hours * h); t += hours * h }
        var l = sim.loaded()
        l.skin = (start..<t).map { .init(ts: $0, raw: 3_300 + ($0 % 50), availableAt: $0 + 120) }
        l.bandSleep = (start..<t).map { .init(ts: $0, state: ($0 / 1_800) % 3, availableAt: $0 + 120) }
        l.wearEvents = (0..<40).map { i in
            .init(ts: start + i * 5_000, state: i % 2 == 0 ? .offWrist : .onWrist,
                  kind: i % 2 == 0 ? "WRIST_OFF" : "WRIST_ON", availableAt: start + i * 5_000 + 60)
        }
        for e in stride(from: start, to: t, by: 30) {
            let motion: MotionLabel = (e / 600) % 7 == 0 ? .walking : .stationary
            l.epochs.append(PC.ActivityEpochInput(epoch: ActivityEpoch(
                startTs: e, endTs: e + 30, motion: motion, posture: .unknown, exercise: .unknown, sleepState: .unknown,
                exertion: .unknown, wear: .unknown, confidence: 0.8, observedS: 30, validS: 28), revision: 3,
                availableAt: e + 600))
        }
        for r in stride(from: start, to: t, by: 108) {
            l.intervals.append(PC.ActivityIntervalInput(interval: PC.Interval(r, r + 108),
                                                        activityClass: (r / 1_080) % 4 == 0 ? "walking" : "sitting",
                                                        confidence: 0.7, revision: 9, availableAt: r + 900))
        }
        for i in 0..<200 {
            l.exposures.append(PC.ExposureEventRevision(
                eventId: "e\(i / 2)", revision: 1 + i % 2, kind: .caffeine, label: "coffee",
                occurred: PC.Interval(dayStart - 3 * 86_400 + i * 1_800, dayStart - 3 * 86_400 + i * 1_800 + 1),
                timePrecision: .exact, recordedAt: dayStart - 3 * 86_400 + i * 1_800 + 60,
                receivedAt: dayStart - 3 * 86_400 + i * 1_800 + 90, source: .userEntered, confirmation: .confirmed,
                doseAmount: 95, doseUnit: "mg", doseProvenance: "user_entered"))
        }
        l.placements = [PC.PlacementInput(start: start, end: nil, placement: "wrist", source: "user", revision: 1,
                                          recordedAt: start)]
        let payload = ContextDaySim.snapshotPayload(sessions: [(dayStart - 16 * h, dayStart - 8 * h),
                                                               (dayStart + 10 * h, dayStart + 10 * h + 1_800),
                                                               (dayStart + 21 * h, dayStart + 29 * h)])
        l.snapshot = ContextInputs.parseSnapshot(day: "2026-10-03", payloadText: payload, resultRevision: 7,
                                                 inputRevision: 3, availableAt: dayStart + 29 * h)
        l.device = .init(family: "WHOOP 5.0 / MG", firmware: "50.36", sourceKind: "noop_push")
        addHistory(&l, mode: .retrospective)
        return (l, sim)
    }

    /// The scoring lane's own computation on the same streams (`AnalyticsEngine.analyzeDay` + `IntradaySeries.build`,
    /// as `DayScorer.scoreAndBuildPayloads` runs them), excluding its database reads.
    private func scoringCompute(_ sim: ContextDaySim) -> Double {
        let hr = sim.hr.map { HRSample(ts: $0.ts, bpm: $0.bpm) }
        let rr = DayScorer.oneTransportPerHour(sim.rr.map {
            RRInterval(ts: $0.ts, rrMs: $0.rr, srcChannel: RRSourceChannel(rawValue: $0.ch), seq: $0.seq) })
        let gravity = sim.gravity.map { GravitySample(ts: $0.ts, x: $0.x, y: $0.y, z: $0.z, dynAccel: $0.dyn) }
        let steps = sim.steps.map { StepSample(ts: $0.ts, counter: $0.counter, activityClass: $0.cls) }
        let inDay = { (ts: Int) in ts >= self.dayStart && ts < self.dayStart + 86_400 }
        let tz = TimeZone(identifier: "UTC")!
        return ms {
            let result = AnalyticsEngine.analyzeDay(
                day: "2026-10-03", hr: hr, rr: rr, gravity: gravity, steps: steps,
                dayHr: hr.filter { inDay($0.ts) }, daySteps: steps.filter { inDay($0.ts) },
                dayGravity: gravity.filter { inDay($0.ts) }, profile: UserProfile(),
                dayWindow: LocalDayWindows(timeZone: tz).window(ofDayKey: "2026-10-03"))
            _ = IntradaySeries.build(IntradaySeries.Inputs(
                dayStart: dayStart, dayEnd: dayStart + 86_400, hr: hr.filter { inDay($0.ts) }, rr: rr,
                gravity: gravity.filter { inDay($0.ts) }, steps: steps.filter { inDay($0.ts) },
                profile: UserProfile(), restingHR: result.daily.restingHr, energy: result.energy))
        }
    }

    private func profile(_ name: String, _ loaded: ContextInputs.Loaded, _ sim: ContextDaySim,
                         modes: [PC.ProcessingMode] = [.retrospective, .causalLive]) throws {
        let w = try XCTUnwrap(ContextInputs.windows(day: "2026-10-03", timezoneId: "UTC"))
        for mode in modes {
            let j = job(mode)
            var assembled: ContextInputs.Assembled!
            var doc: PC.DayDocument!
            var built: ContextLane.Built!
            let assembleMS = ms { assembled = ContextInputs.assemble(loaded, job: j, windows: w) }
            let buildMS = ms { doc = PC.Engine.buildDay(assembled.input, history: assembled.history) }
            let encodeMS = try ms { built = try ContextLane.publishPayload(document: doc, snapshot: loaded.snapshot) }
            let plainBytes = try PC.encoder().encode(doc).count
            print("context-profile: case=\(name) mode=\(mode.rawValue) rows=\(loaded.rowCount) "
                  + "hr=\(loaded.heartRate.count) beats=\(loaded.beatIntervals.count) "
                  + "beats_selected=\(assembled.input.beatIntervals.count) motion=\(loaded.motion.count) "
                  + "measurements=\(assembled.measurementCount) envelopes=\(doc.envelopes.count) "
                  + "assemble_ms=\(Int(assembleMS)) build_ms=\(Int(buildMS)) encode_ms=\(Int(encodeMS)) "
                  + "total_ms=\(Int(assembleMS + buildMS + encodeMS)) plain_doc_bytes=\(plainBytes) "
                  + "summary_bytes=\(built.summaryBytes) table_bytes=\(built.tableBytes) "
                  + "max_table_bytes=\(built.maxTableBytes) "
                  + "payload_bytes=\(built.payloadText.utf8.count)")
            XCTAssertGreaterThan(doc.envelopes.count, 0)
        }
        print("context-profile: case=\(name) scoring_compute_ms=\(Int(scoringCompute(sim)))")
    }

    func testRepresentativeFullDay() throws {
        let (l, sim) = representative()
        try profile("representative_day", l, sim)
    }

    func testLargestReadWindow() throws {
        let (l, sim) = worstCase()
        try profile("largest_read_window", l, sim)
    }
}
