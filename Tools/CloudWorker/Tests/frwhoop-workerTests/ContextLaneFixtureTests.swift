import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// Deterministic strap streams for the context-lane tests: 1 Hz heart rate and gravity, a step counter, and
/// beat-by-beat R-R (whole-second timestamps, `seq` per equal value in a second) with respiratory sinus
/// arrhythmia, so the series builder publishes real HRV, resting-HR and respiratory points.
///
/// The physiology is plausible, not validated: these fixtures exercise plumbing (supports, availability,
/// ordering, persistence), never the values of the context systems.
struct ContextDaySim {
    enum Phase { case sleep, sit, walk, gap }

    private(set) var hr: [(ts: Int, bpm: Int, at: Int)] = []
    private(set) var rr: [(ts: Int, rr: Int, seq: Int, ch: Int, at: Int)] = []
    private(set) var gravity: [(ts: Int, x: Double, y: Double, z: Double, dyn: Double, at: Int)] = []
    private(set) var steps: [(ts: Int, counter: Int, cls: Int, at: Int)] = []
    private var seed: UInt64
    private var counter = 4_000
    private var beatClock = 0.0
    /// Availability lag: a row is stored `lag` seconds after its sensor time (an upload cadence).
    var lag = 120
    /// Also write every beat through a second transport (live BLE, channel 7) at half the density.
    var duplicateTransport = false

    init(seed: UInt64 = 11) { self.seed = seed }

    private mutating func rand() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double((seed >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }

    /// Append `[start, end)` of one phase.
    mutating func run(_ phase: Phase, from start: Int, to end: Int) {
        guard end > start else { return }
        if phase == .gap { beatClock = Double(end); return }
        if beatClock < Double(start) { beatClock = Double(start) }
        var seqInSecond: [Int: [Int: Int]] = [:]
        for ts in start..<end {
            let base: Double
            let dyn: Double
            let ticks: Int
            switch phase {
            case .sleep: base = 54; dyn = 0.004 + rand() * 0.002; ticks = 0
            case .sit: base = 66; dyn = 0.008 + rand() * 0.004; ticks = 0
            case .walk: base = 104; dyn = 0.12 + rand() * 0.05; ticks = ts % 2 == 0 ? 2 : 1
            case .gap: base = 0; dyn = 0; ticks = 0
            }
            let bpm = Int((base + (rand() - 0.5) * 4).rounded())
            hr.append((ts, bpm, ts + lag))
            let angle = (phase == .walk ? (rand() - 0.5) * 20 : 0) * .pi / 180
            gravity.append((ts, 0.2, cos(angle) * 0.9, sin(angle) * 0.9 + 0.35, dyn, ts + lag))
            counter = (counter + ticks) & 0xFFFF
            steps.append((ts, counter, phase == .walk ? 1 : 0, ts + lag))
            // Beats inside this second: RSA (~15 breaths/min) on top of the mean interval.
            while beatClock < Double(ts + 1) {
                let mean = 60_000.0 / base
                let rsa = (phase == .walk ? 8.0 : 45.0) * sin(2 * .pi * beatClock / 4.0)
                let ms = Int((mean + rsa + (rand() - 0.5) * 12).rounded())
                let beatTs = Int(beatClock.rounded(.down))
                if beatTs >= start {
                    let n = seqInSecond[beatTs, default: [:]][ms, default: 0]
                    seqInSecond[beatTs, default: [:]][ms] = n + 1
                    rr.append((beatTs, ms, n, RRSourceChannel.whoop5Historical.rawValue, beatTs + lag))
                    if duplicateTransport && beatTs % 2 == 0 {
                        rr.append((beatTs, ms, n, RRSourceChannel.whoop5Standard.rawValue, beatTs + 5))
                    }
                }
                beatClock += Double(ms) / 1000.0
            }
        }
    }

    /// Append another simulation's rows (a later span).
    mutating func append(_ other: ContextDaySim) {
        hr += other.hr; rr += other.rr; gravity += other.gravity; steps += other.steps
    }

    /// A day in the life: asleep until 07:00, sitting with walks through the day, a gap off-wrist, asleep from
    /// 23:00. `dayStart` is local midnight.
    static func representativeDay(dayStart: Int, seed: UInt64 = 11, duplicateTransport: Bool = false)
        -> ContextDaySim {
        var sim = ContextDaySim(seed: seed)
        sim.duplicateTransport = duplicateTransport
        let h = 3_600
        sim.run(.sleep, from: dayStart, to: dayStart + 7 * h)
        sim.run(.sit, from: dayStart + 7 * h, to: dayStart + 8 * h)
        sim.run(.walk, from: dayStart + 8 * h, to: dayStart + 8 * h + 1_200)
        sim.run(.sit, from: dayStart + 8 * h + 1_200, to: dayStart + 12 * h)
        sim.run(.walk, from: dayStart + 12 * h, to: dayStart + 12 * h + 1_800)
        sim.run(.sit, from: dayStart + 12 * h + 1_800, to: dayStart + 18 * h)
        sim.run(.walk, from: dayStart + 18 * h, to: dayStart + 18 * h + 2_400)
        sim.run(.sit, from: dayStart + 18 * h + 2_400, to: dayStart + 23 * h)
        sim.run(.sleep, from: dayStart + 23 * h, to: dayStart + 24 * h)
        return sim
    }

    /// The streams as the lane loads them.
    func loaded() -> ContextInputs.Loaded {
        var l = ContextInputs.Loaded()
        l.heartRate = hr.map { .init(ts: $0.ts, bpm: $0.bpm, availableAt: $0.at) }
        l.beatIntervals = rr.sorted { ($0.ts, $0.seq, $0.rr, $0.ch) < ($1.ts, $1.seq, $1.rr, $1.ch) }
            .map { .init(ts: $0.ts, rrMs: $0.rr, seq: $0.seq, channel: $0.ch, availableAt: $0.at) }
        l.motion = gravity.map { .init(ts: $0.ts, dynAccelG: $0.dyn, x: $0.x, y: $0.y, z: $0.z, availableAt: $0.at) }
        l.steps = steps.map { .init(ts: $0.ts, counter: $0.counter, activityClass: $0.cls, availableAt: $0.at) }
        return l
    }

    /// A scoring snapshot payload in the shape `DayScorer` publishes (sleep[] + daily nightly values).
    static func snapshotPayload(sessions: [(start: Int, end: Int)], daily: [String: Any] = [
        "hrv_rmssd_ms": 48.5, "hrv_sdnn_ms": 61.0, "resting_hr_bpm": 53, "resp_rate_bpm": 14.6,
        "skin_temp_c": 33.4, "skin_temp_dev_c": 0.1, "spo2_candidate_pct": 96.0, "spo2_candidate_samples": 240,
    ], deviceId: String = "dev") -> String {
        func iso(_ ts: Int) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
        }
        let sleep: [[String: Any]] = sessions.map { s in
            ["id": "sleep-\(deviceId)-\(s.start)", "start_at": iso(s.start), "end_at": iso(s.end), "is_nap": false,
             "efficiency": 0.91,
             "stages": [["start": s.start, "end": s.start + 1_800, "stage": "light"],
                        ["start": s.start + 1_800, "end": s.end, "stage": "deep"]]]
        }
        let obj: [String: Any] = ["sleep": sleep, "daily": daily, "dataThrough": iso(sessions.last?.end ?? 0),
                                  "timezone": "UTC", "status": "available"]
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
                      as: UTF8.self)
    }
}

final class ContextLaneFixtureTests: XCTestCase {
    /// The fixture itself: beats are whole-second, `seq` separates equal values in one second, and the day is
    /// dense enough for the series builder to publish every metric the lane maps.
    func testRepresentativeDayFeedsEverySeriesMetric() throws {
        let dayStart = 1_790_985_600  // 2026-10-03T00:00:00Z
        let sim = ContextDaySim.representativeDay(dayStart: dayStart)
        XCTAssertEqual(sim.hr.count, 86_400)
        XCTAssertGreaterThan(sim.rr.count, 70_000)
        let keys = Set(sim.rr.map { "\($0.ts):\($0.rr):\($0.seq)" })
        XCTAssertEqual(keys.count, sim.rr.count, "beat identity (ts, rrMs, seq) is unique")
        let points = IntradaySeries.build(IntradaySeries.Inputs(
            dayStart: dayStart, dayEnd: dayStart + 86_400,
            hr: sim.hr.map { HRSample(ts: $0.ts, bpm: $0.bpm) },
            rr: sim.rr.map { RRInterval(ts: $0.ts, rrMs: $0.rr, srcChannel: RRSourceChannel(rawValue: $0.ch), seq: $0.seq) },
            gravity: sim.gravity.map { GravitySample(ts: $0.ts, x: $0.x, y: $0.y, z: $0.z, dynAccel: $0.dyn) },
            steps: sim.steps.map { StepSample(ts: $0.ts, counter: $0.counter, activityClass: $0.cls) },
            profile: UserProfile(), restingHR: 53, energy: nil))
        XCTAssertFalse(points[.hrv, default: []].isEmpty)
        XCTAssertFalse(points[.restingHR, default: []].isEmpty)
        XCTAssertFalse(points[.respRate, default: []].isEmpty)
    }
}
