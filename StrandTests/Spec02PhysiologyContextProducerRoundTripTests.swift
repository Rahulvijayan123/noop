import XCTest
import StrandAnalytics
@testable import Strand

/// Spec-02 producer → app round trip for the physiology context day document. The real engine
/// (`PhysiologyContext.Engine.buildDay`) runs on one Los Angeles day that yields awake-vs-asleep heart rate, a
/// sustained high pulse episode, an HR rise with movement, and a walk followed by a measured breathing-rate return. The
/// document is stored as the worker stores it (`StoredDocument.split` → `PhysiologyContext.encoder()`), served in the
/// `scores/context` envelope, parsed by the app's repository path (`PhysiologyContextRepository.parseDay` → the lenient
/// day decoder), and rendered by the detail and history models. The bouts go through the history route parser.
final class Spec02PhysiologyContextProducerRoundTripTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias W = PhysiologyContextWording

    static let tz = "America/Los_Angeles"
    static let day = "2026-10-01"
    static let prev = "2026-09-30"
    static let gb = Locale(identifier: "en_GB")

    static func at(_ day: String, _ h: Int, _ m: Int = 0) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        let p = day.split(separator: "-").map { Int($0)! }
        return Int(cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: h, minute: m))!
            .timeIntervalSince1970)
    }

    /// A `series.resp_rate.2min` estimate centred on minute `b` (support `[b − 60, b + 60)`), as the context inputs
    /// read the metric series.
    static func rr(_ b: Int, _ bpm: Double) -> PC.MeasurementInput {
        PC.MeasurementInput(metric: .respiratoryRate,
                            method: PC.MethodRef(id: "series.resp_rate.2min", algorithmVersion: "frwhoop-series-2",
                                                 aggregation: .window, windowS: 120, units: "breaths_per_min"),
                            source: PC.SourceRef(product: .metricSeries, key: "resp_rate_bpm@\(b)"), value: bpm,
                            support: .init(b - 60, b + 60))
    }

    /// Night 23:00–07:00 at 52/53 bpm, the day at 72/73. 10:00–10:02 movement with an HR rise (an acceleration with
    /// movement). 14:00–14:20 at 105/106 while still (a sustained high pulse). 16:00–16:10 a walk (step counter + wrist
    /// motion) at 110 bpm, 75 bpm afterwards; breathing estimates at 14 br/min before it, 20 br/min for the first
    /// minutes after it, then back near 14.5.
    static func input() -> PC.DayInput {
        let window = PC.Engine.dayInterval(day, timezoneId: tz)
        let identity = PC.DayIdentity(deviceScope: "whoop-RT", day: day, timezoneId: tz, dayWindow: window)
        let n0 = at(prev, 23), n1 = at(day, 7)
        let e0 = at(day, 14), mv = at(day, 10)
        let w0 = at(day, 16), w1 = w0 + 600
        let start = at(prev, 22), end = at(day, 22)
        var hr: [PC.HeartRateObservation] = []
        var motion: [PC.MotionObservation] = []
        for t in start..<end {
            let k = t - start
            var bpm = (t >= n0 && t < n1 ? 52 : 72) + k % 2
            if t >= e0 && t < e0 + 1200 { bpm = 105 + k % 2 }
            if t >= mv + 3 && t < mv + 60 { bpm = 90 }
            if t >= w0 && t < w1 { bpm = 110 }
            if t >= w1 && t < w1 + 3600 { bpm = 75 }
            hr.append(.init(ts: t, bpm: bpm))
            let moving = (t >= mv && t < mv + 120) || (t >= w0 && t < w1)
            motion.append(.init(ts: t, dynAccelG: moving ? 0.5 : 0.001))
        }
        // Step counter: +3 steps every 2 s through the walk.
        let steps = stride(from: w0, through: w1, by: 2).enumerated().map { i, t in
            PC.StepObservation(ts: t, counter: 1000 + 3 * i)
        }
        // Breathing estimates: before the walk (supports inside [w0 − 900, w0)), and after it.
        var respiration = stride(from: w0 - 840, through: w0 - 60, by: 60).map { rr($0, 14) }
        respiration += stride(from: w1 + 60, through: w1 + 1080, by: 60).map { b in
            rr(b, b + 60 - w1 <= 420 ? 20 : 14.5)
        }
        return PC.DayInput(identity: identity, mode: .retrospective, availabilityCutoff: window.end + 40 * 3600,
                           generatedAt: window.end + 40 * 3600, heartRate: hr, motion: motion, steps: steps,
                           measurements: respiration,
                           sleepSessions: [PC.SleepSessionInput(id: "night", interval: .init(n0, n1), isNap: nil,
                                                                stages: [], availableAt: n1 + 600, sourceDay: nil,
                                                                detector: "frwhoop-server-1")],
                           regime: .init(scoringAlgorithmVersion: "frwhoop-server-1"))
    }

    /// The engine's document and the app's reading of it through the route envelope.
    static func produce() throws -> (doc: PC.DayDocument, day: PhysiologyContextDay) {
        let doc = PC.Engine.buildDay(input(), history: .empty)
        let (summary, tables) = PC.StoredDocument.split(doc)
        let encoder = PC.encoder()
        let document = try JSONSerialization.jsonObject(with: encoder.encode(summary))
        let envelopeTables = try tables.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) }
        let context: [String: Any] = ["status": "available", "mode": "retrospective", "context_revision": 3,
                                      "finality": "final", "document": document, "envelope_tables": envelopeTables]
        // Through JSON bytes, as the route serves it.
        let wire = try JSONSerialization.data(withJSONObject: ["context": context])
        let served = try XCTUnwrap((try JSONSerialization.jsonObject(with: wire) as? [String: Any])?["context"]
                                   as? [String: Any])
        let parsed = PhysiologyContextRepository.parseDay(context: served, day: day, deviceId: "whoop-RT", metric: nil,
                                                          fetchedAtMs: 0)
        return (doc, parsed)
    }

    func testTheAppDecodesEveryNewMemberAsTheEngineWroteIt() throws {
        let (doc, day) = try Self.produce()
        let app = try XCTUnwrap(day.document)
        XCTAssertNotNil(app.full, "the whole document decodes")
        XCTAssertEqual(app.undecodedMembers, [])
        XCTAssertEqual(app.full, doc)
        let dn = try XCTUnwrap(doc.sleep.dayNightHeartRate)
        XCTAssertEqual(dn.state, .supported)
        XCTAssertEqual(app.dayNightHeartRate, dn)
        let pulse = try XCTUnwrap(doc.pulseEpisodes)
        XCTAssertEqual(app.pulseEpisodes, pulse, "the lenient member reads pulse_episodes")
        XCTAssertFalse(pulse.episodes.isEmpty)
        let bout = try XCTUnwrap(doc.bouts.first { $0.recovery?.respiratoryRecovery != nil })
        XCTAssertEqual(app.bouts.first { $0.id == bout.id }, bout)
        XCTAssertEqual(doc.header.versions.pulse, "pc-pulse-1")
    }

    func testAwakeAndAsleepHeartRateShowTheEngineValues() throws {
        let (doc, day) = try Self.produce()
        let dn = try XCTUnwrap(doc.sleep.dayNightHeartRate)
        let model = MeasurementContextDetailModel.build(day: day, metric: .restingHeartRate, isStale: false,
                                                        locale: Self.gb)
        let s = try XCTUnwrap(model.sections.first { $0.id == "dayNightHeartRate" })
        func row(_ id: String) -> ContextDetailRow? { s.rows.first { $0.id == id } }
        XCTAssertEqual(row("awake")?.value, W.value(try XCTUnwrap(dn.awakeMedianBpm), units: "bpm", locale: Self.gb))
        XCTAssertEqual(row("asleep")?.value, W.value(try XCTUnwrap(dn.sleepMedianBpm), units: "bpm", locale: Self.gb))
        let awakeCoverage = try XCTUnwrap(dn.awakeCoverage)
        XCTAssertTrue(row("awake")?.note?.hasPrefix(
            "\(W.percent(awakeCoverage, locale: Self.gb)) of \(W.duration(dn.awakeEligibleS)) observed") == true,
                      row("awake")?.note ?? "")
        let sleepCoverage = try XCTUnwrap(dn.sleepCoverage)
        XCTAssertTrue(row("asleep")?.note?.hasPrefix(
            "\(W.percent(sleepCoverage, locale: Self.gb)) of \(W.duration(dn.sleepEligibleS)) observed") == true,
                      row("asleep")?.note ?? "")
        XCTAssertEqual(row("difference")?.value,
                       W.signedDifference(try XCTUnwrap(dn.differenceBpm), units: "bpm", locale: Self.gb))
        XCTAssertEqual(row("dip")?.value, W.value(try XCTUnwrap(dn.percentDip), units: "percent", locale: Self.gb))
    }

    func testPulseEpisodesShowTheEngineValues() throws {
        let (doc, day) = try Self.produce()
        let p = try XCTUnwrap(doc.pulseEpisodes)
        let model = MeasurementContextDetailModel.build(day: day, metric: .restingHeartRate, isStale: false,
                                                        locale: Self.gb)
        let s = try XCTUnwrap(model.sections.first { $0.id == "pulseEpisodes" })
        func row(_ id: String) -> ContextDetailRow? { s.rows.first { $0.id == id } }
        XCTAssertEqual(row("exposure")?.value, W.duration(p.qualifiedInactiveS))
        XCTAssertEqual(row("high")?.value, W.episodeCount(p.highEpisodeCount, seconds: p.highEpisodeS))
        XCTAssertEqual(row("low")?.value, W.episodeCount(p.lowEpisodeCount, seconds: p.lowEpisodeS))
        let high = try XCTUnwrap(p.episodes.first { $0.kind == "sustained_high" })
        let episode = try XCTUnwrap(row("episode-\(high.id)"))
        let zone = TimeZone(identifier: Self.tz)!
        XCTAssertEqual(episode.title, "Sustained high pulse, \(W.timeRange(high.interval, zone: zone, locale: Self.gb))")
        XCTAssertEqual(episode.value, "median \(W.value(try XCTUnwrap(high.medianBpm), units: "bpm", locale: Self.gb))"
                       + " \u{00B7} highest \(W.value(try XCTUnwrap(high.extremeBpm), units: "bpm", locale: Self.gb))")
        XCTAssertTrue(episode.note?.hasPrefix("\(W.pulseContext(high.context)) \u{00B7} \(W.duration(high.durationS))")
                      == true, episode.note ?? "")
        XCTAssertEqual(row("accelerations")?.value, "\(p.accelerationEvents.count)")
        let t = Dictionary(p.thresholds.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(row("threshold-high")?.value,
                       "\u{2265} \(W.value(try XCTUnwrap(t["high_enter_bpm"]), units: "bpm", locale: Self.gb))")
        XCTAssertEqual(row("threshold-low")?.value,
                       "\u{2264} \(W.value(try XCTUnwrap(t["low_enter_bpm"]), units: "bpm", locale: Self.gb))")
        XCTAssertEqual(model.diagnostics.first { $0.id == "d-pulse" }?.value, "\(p.version) \(p.state.rawValue)")
        for text in model.allText { XCTAssertNil(W.containsForbiddenTerm(text), text) }
    }

    func testTheBreathingReturnAfterTheWalkShowsTheEngineValues() throws {
        let (doc, _) = try Self.produce()
        let bout = try XCTUnwrap(doc.bouts.first { $0.recovery?.respiratoryRecovery != nil })
        let r = try XCTUnwrap(bout.recovery?.respiratoryRecovery)
        XCTAssertEqual(r.state, "returned")
        // The history route serves the stored bout payloads (the worker's encoding of each bout).
        let payload = try JSONSerialization.jsonObject(with: PC.encoder().encode(bout))
        let wire = try JSONSerialization.data(withJSONObject: ["bouts": [payload], "episodes": [], "daily_values": []])
        let served = try XCTUnwrap(try JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let history = PhysiologyContextRepository.parseHistory(served, from: Self.prev, to: Self.day,
                                                               deviceId: "whoop-RT", mode: .retrospective,
                                                               fetchedAtMs: 0)
        XCTAssertEqual(history.bouts.first?.recovery?.respiratoryRecovery, r)
        let model = PhysiologyContextHistoryModel.build(history, metric: .restingHeartRate,
                                                        zone: TimeZone(identifier: Self.tz)!, locale: Self.gb)
        let last = try XCTUnwrap(r.lastAboveOffsetS), back = try XCTUnwrap(r.returnedAtOffsetS)
        let level = W.value(try XCTUnwrap(r.referenceBpm), units: "breaths_per_min", locale: Self.gb)
        XCTAssertEqual(model.bouts.first?.breathing,
                       "Breathing rate back near the earlier level between \(W.duration(last)) and "
                       + "\(W.duration(back)) after (\(level))")
    }
}
