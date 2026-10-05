import XCTest
@testable import StrandAnalytics

/// Document size and build time for a fully observed synthetic day (every series family present). Reports the
/// bytes per envelope member so storage decisions are made from measurement, and holds a size budget.
final class PCDocumentSizeTests: XCTestCase {
    typealias PC = PhysiologyContext

    static func fullDay(tz: String = "America/Los_Angeles", day: String = "2026-10-01") -> PC.DayInput {
        let window = PC.Engine.dayInterval(day, timezoneId: tz)
        let start = window.start
        var rng = SplitMix(seed: 7)
        var hr: [PC.HeartRateObservation] = []
        var beats: [PC.BeatIntervalObservation] = []
        var motion: [PC.MotionObservation] = []
        var steps: [PC.StepObservation] = []
        var counter = 1000
        let sleepEnd = start + 7 * 3600
        for t in (start - 3600)..<window.end {
            let asleep = t < sleepEnd
            let walking = !asleep && (t - start) % 7200 < 900          // 15 min walking every 2 h
            let bpm = asleep ? 55 + Int(rng.next() % 4) : (walking ? 105 + Int(rng.next() % 8) : 70 + Int(rng.next() % 6))
            hr.append(.init(ts: t, bpm: bpm, availableAt: t + 600))
            let rr = 60_000 / bpm
            beats.append(.init(ts: t, rrMs: rr + Int(rng.next() % 30) - 15, seq: 0, availableAt: t + 600))
            motion.append(.init(ts: t, dynAccelG: asleep ? 0.002 : (walking ? 0.3 : 0.02), availableAt: t + 600))
            if walking && t % 5 == 0 {
                counter = (counter + 9) % 65536
                steps.append(.init(ts: t, counter: counter, activityClass: 1, availableAt: t + 600))
            }
        }
        func series(_ id: String, metric: PC.MetricKind, bucket: Int, support: (Int) -> PC.Interval, units: String,
                    value: Double) -> [PC.MeasurementInput] {
            stride(from: start, to: window.end, by: bucket).map { b in
                PC.MeasurementInput(metric: metric,
                                    method: .init(id: id, algorithmVersion: "frwhoop-series-2", aggregation: .window,
                                                  windowS: support(b).duration, units: units),
                                    source: .init(product: .metricSeries, key: "\(id)@\(b)"), value: value,
                                    support: support(b), displayBucket: .init(b, b + bucket), sampleCount: 100,
                                    coverage: 1, availableAt: b + bucket + 600)
            }
        }
        var measurements = series("series.hrv_rmssd.5min", metric: .hrvRmssd, bucket: 300,
                                  support: { .init($0, $0 + 300) }, units: "ms", value: 45)
        measurements += series("series.resting_hr.60min_min5", metric: .restingHeartRate, bucket: 300,
                               support: { .init($0 - 3300, $0 + 300) }, units: "bpm", value: 54)
        measurements += series("series.resp_rate.2min", metric: .respiratoryRate, bucket: 60,
                               support: { .init($0 - 60, $0 + 60) }, units: "breaths_per_min", value: 14)
        for (m, field, units, v) in [(PC.MetricKind.hrvRmssd, "hrv_rmssd_ms", "ms", 48.0),
                                     (.restingHeartRate, "resting_hr_bpm", "bpm", 53),
                                     (.respiratoryRate, "resp_rate_bpm", "breaths_per_min", 14.2),
                                     (.skinTemperature, "skin_temp_c", "degC", 33.4),
                                     (.spo2Candidate, "spo2_candidate_pct", "percent", 96)] {
            let name = field.components(separatedBy: "_").dropLast().joined(separator: "_")
            measurements.append(.init(metric: m, method: .init(id: "snapshot.\(name).night",
                                                               algorithmVersion: "frwhoop-server-1",
                                                               aggregation: .session, windowS: 8 * 3600, units: units),
                                      source: .init(product: .scoringSnapshot, key: "daily.\(field)", resultRevision: 9),
                                      value: v, support: .init(start - 3600, sleepEnd), availableAt: sleepEnd + 900,
                                      sessionId: "night-1"))
        }
        let sleep = PC.SleepSessionInput(id: "night-1", interval: .init(start - 3600, sleepEnd), detector: "frwhoop-server-1",
                                         dataThrough: window.end, timezoneId: tz)
        return PC.DayInput(identity: .init(deviceScope: "dev-size", day: day, timezoneId: tz, dayWindow: window),
                           mode: .retrospective, availabilityCutoff: window.end + 40 * 3600,
                           generatedAt: window.end + 40 * 3600, heartRate: hr, beatIntervals: beats, motion: motion,
                           steps: steps, measurements: measurements, sleepSessions: [sleep],
                           placements: [.init(start: start - 86_400, end: nil, placement: "wrist", source: "user", revision: 1)],
                           regime: .init(deviceFamily: "whoop5", scoringAlgorithmVersion: "frwhoop-server-1",
                                         seriesAlgorithmVersion: "frwhoop-series-2"))
    }

    /// 200 timed exposure events across the read window (an extreme logging day): the stored form must still intern
    /// the per-row exposure references and stay within budget.
    func testExposureHeavyDayStaysWithinTheStoredBudget() throws {
        var input = Self.fullDay()
        let start = input.identity.dayWindow.start
        input.exposures = (0..<200).map { i in
            let t = start - 2 * 86_400 + i * 1_200
            return PC.ExposureEventRevision(eventId: "ev-\(i)", revision: 1, kind: i % 2 == 0 ? .caffeine : .meal,
                                            label: i % 2 == 0 ? "coffee" : "meal", occurred: .init(t, t + 1),
                                            timePrecision: .exact, recordedAt: t + 60, receivedAt: t + 120,
                                            source: .userEntered, confirmation: .confirmed,
                                            doseAmount: i % 2 == 0 ? 80 : nil, doseUnit: i % 2 == 0 ? "mg" : nil)
        }
        let doc = PC.Engine.buildDay(input, history: .empty)
        let (summary, tables) = PC.StoredDocument.split(doc)
        XCTAssertEqual(PC.StoredDocument.join(summary: summary, tables: tables), doc)
        let enc = PC.encoder()
        let sizes = try tables.map { ($0.metric.rawValue, try enc.encode($0).count) }
        let stored = try enc.encode(summary).count + sizes.reduce(0) { $0 + $1.1 }
        print("PC_STORED_EXPOSURES summary=\(try enc.encode(summary).count / 1024)KB "
              + sizes.map { "\($0.0)=\($0.1 / 1024)KB" }.joined(separator: " "))
        XCTAssertLessThan(stored, 4_000_000, "exposure-heavy stored document over budget: \(stored) bytes")
    }

    func testFullDayDocumentSizeAndBuildTime() throws {
        let input = Self.fullDay()
        let t0 = Date()
        let doc = PC.Engine.buildDay(input, history: .empty)
        let buildMs = Date().timeIntervalSince(t0) * 1000
        let enc = PC.encoder()
        let total = try enc.encode(doc).count
        func bytes<T: Encodable>(_ v: T) -> Int { (try? enc.encode(v).count) ?? 0 }
        var parts: [String: Int] = [:]
        for e in doc.envelopes {
            parts["validity", default: 0] += bytes(e.validity)
            parts["activity", default: 0] += bytes(e.activity)
            parts["decoder_activity", default: 0] += e.decoderActivity.map(bytes) ?? 0
            parts["preceding", default: 0] += bytes(e.preceding)
            parts["sleep_wear", default: 0] += bytes(e.sleepWear)
            parts["history", default: 0] += bytes(e.history)
            parts["eligibility", default: 0] += bytes(e.eligibility)
            parts["comparisons", default: 0] += bytes(e.comparisons)
            parts["identity_time", default: 0] += bytes(e.method) + bytes(e.source) + bytes(e.localTime) + 120
        }
        if ProcessInfo.processInfo.environment["PC_DUMP_ENVELOPE"] != nil,
           let e = doc.envelopes.first(where: { $0.method.id == "series.resp_rate.2min" && $0.support.start > input.identity.dayWindow.start + 10 * 3600 }) {
            try enc.encode(e).write(to: URL(fileURLWithPath: "/tmp/pc-envelope.json"))
            try enc.encode(doc).write(to: URL(fileURLWithPath: "/tmp/pc-fullday.json"))
        }
        let report = parts.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value / 1024)KB" }.joined(separator: " ")
        print("PC_DOC_SIZE envelopes=\(doc.envelopes.count) total=\(total / 1024)KB build=\(Int(buildMs))ms \(report)")
        XCTAssertGreaterThan(doc.envelopes.count, 2000)
        // The plain document is large; the STORED form (summary + per-metric interned tables) is what is persisted
        // and served. It must be lossless and within budget.
        let (summary, tables) = PC.StoredDocument.split(doc)
        XCTAssertEqual(PC.StoredDocument.join(summary: summary, tables: tables), doc)
        let summaryBytes = try enc.encode(summary).count
        let tableBytes = try tables.map { ($0.metric.rawValue, try enc.encode($0).count) }
        print("PC_STORED summary=\(summaryBytes / 1024)KB " + tableBytes.map { "\($0.0)=\($0.1 / 1024)KB" }.joined(separator: " "))
        let stored = summaryBytes + tableBytes.reduce(0) { $0 + $1.1 }
        XCTAssertLessThan(stored, 3_000_000, "stored document over budget: \(stored) bytes")
        // A metric page reads the summary and one table.
        for (metric, bytes) in tableBytes where metric != PC.MetricKind.respiratoryRate.rawValue {
            XCTAssertLessThan(summaryBytes + bytes, 600_000, "\(metric) page payload over budget")
        }
        // A subset join keeps only that metric's envelopes and still reports the full index.
        let hrv = PC.StoredDocument.join(summary: summary, tables: tables.filter { $0.metric == .hrvRmssd })
        XCTAssertTrue(hrv.envelopes.allSatisfy { $0.metric == .hrvRmssd })
        XCTAssertEqual(hrv.envelopes, doc.envelopes.filter { $0.metric == .hrvRmssd })
        XCTAssertEqual(hrv.envelopeIndex?.count, tables.count)
    }
}
