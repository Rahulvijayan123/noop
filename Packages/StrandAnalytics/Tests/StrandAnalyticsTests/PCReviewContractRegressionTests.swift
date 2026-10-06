import XCTest
@testable import StrandAnalytics

/// Independent contract review scratch tests (docs/physiology-context/notes/review-contract.md).
///
/// Tests named `testRC..._` demonstrate a finding and are EXPECTED TO FAIL on 28f5e602 unless the name ends in
/// `_holds` (those document behaviour the review checked and found correct). Not for commit.
/// Regression tests from the independent contract review (notes/review-contract.md), kept so the repaired defects
/// stay repaired. Originally scratch tests in the review worktree.
final class PCReviewContractRegressionTests: XCTestCase {
    typealias PC = PhysiologyContext

    static let day = "2026-10-01"
    static let identity = PC.DayIdentity(deviceScope: "dev-1", day: day, timezoneId: "UTC",
                                         dayWindow: PC.Engine.dayInterval(day, timezoneId: "UTC"))
    static var s: Int { identity.dayWindow.start }
    static var lateCutoff: Int { identity.dayWindow.end + 40 * 3600 }
    static let regime = PC.DeviceRegimeInput(scoringAlgorithmVersion: "frwhoop-server-1",
                                             seriesAlgorithmVersion: "frwhoop-series-2")
    static let hrvSeries = PC.MethodRef(id: "series.hrv_rmssd.5min", algorithmVersion: "frwhoop-series-2",
                                        aggregation: .window, windowS: 300, units: "ms")

    static func input(mode: PC.ProcessingMode = .retrospective, cutoff: Int? = nil,
                      hr: [PC.HeartRateObservation] = [], rr: [PC.BeatIntervalObservation] = [],
                      measurements: [PC.MeasurementInput] = [], sleep: [PC.SleepSessionInput] = [],
                      workouts: [PC.WorkoutInput] = []) -> PC.DayInput {
        PC.DayInput(identity: identity, mode: mode, availabilityCutoff: cutoff ?? lateCutoff,
                    generatedAt: lateCutoff, heartRate: hr, beatIntervals: rr, measurements: measurements,
                    sleepSessions: sleep, workouts: workouts, regime: regime)
    }

    // MARK: RC-01 (spec §7 / V03) — plausible extremes vanish from the engine's derived HR windows

    func testRC01_extremeHeartRateIsKeptInDerivedWindows() {
        let t0 = Self.s + 10 * 3600                                  // on the 5-minute grid
        var hr: [PC.HeartRateObservation] = []
        for ts in t0..<(t0 + 300) { hr.append(.init(ts: ts, bpm: 26)) }            // inside the 20–250 contract
        for ts in (t0 + 300)..<(t0 + 600) { hr.append(.init(ts: ts, bpm: ts % 2 == 0 ? 228 : 100)) }
        let doc = PC.Engine.buildDay(Self.input(hr: hr), history: .empty)
        let w1 = doc.envelopes.first { $0.metric == .heartRate && $0.support.start == t0 }
        let w2 = doc.envelopes.first { $0.metric == .heartRate && $0.support.start == t0 + 300 }
        XCTAssertNotNil(w1, "5 min of 26 bpm (accepted by the input contract) produced NO heart-rate measurement")
        XCTAssertEqual(w2?.value ?? -1, 164, accuracy: 0.5,
                       "the 228 bpm half of the window was dropped from the mean (value \(w2?.value ?? -1))")
    }

    // MARK: RC-02 (spec §7, §12 / V04) — bout and functional daily values get an arbitrary regime key

    func testRC02_functionalRegimeKeyDoesNotDependOnWhichMeasurementsExist() {
        let base = Self.s + 8 * 3600
        let hr = (base..<(base + 5 * 3600)).map { PC.HeartRateObservation(ts: $0, bpm: 70) }
        func functionalKey(_ extra: [PC.MeasurementInput]) -> String? {
            PC.Engine.buildDay(Self.input(hr: hr, measurements: extra), history: .empty)
                .dailyValues.first { $0.seriesKey.hasPrefix("functional.") }?.regimeKey
        }
        guard let reference = functionalKey([]) else { return XCTFail("no functional daily value") }
        let methods: [(PC.MetricKind, PC.MethodRef)] = [
            (.hrvRmssd, Self.hrvSeries),
            (.respiratoryRate, .init(id: "series.resp_rate.2min", algorithmVersion: "frwhoop-series-2",
                                     aggregation: .window, windowS: 120, units: "breaths_per_min")),
            (.restingHeartRate, .init(id: "series.resting_hr.60min_min5", algorithmVersion: "frwhoop-series-2",
                                      aggregation: .minimumOfBins, windowS: 3600, units: "bpm")),
            (.skinTemperature, .init(id: "snapshot.skin_temp.night", algorithmVersion: "frwhoop-server-1",
                                     aggregation: .session, windowS: 3600, units: "degC")),
            (.hrvSdnn, .init(id: "snapshot.hrv_sdnn.night", algorithmVersion: "frwhoop-server-1",
                             aggregation: .session, windowS: 3600, units: "ms")),
        ]
        var keys: [String: String] = ["(derived HR windows only)": reference]
        for (metric, method) in methods {
            let m = PC.MeasurementInput(metric: metric, method: method,
                                        source: .init(product: .metricSeries, key: "x"), value: 1,
                                        support: .init(base + 600, base + 900))
            if let k = functionalKey([m]) { keys["+ \(method.id)"] = k }
        }
        XCTAssertEqual(Set(keys.values).count, 1,
                       "same device, same placement, same functional data — regime key changes with the day's " +
                       "measurement families: \(keys)")
    }

    // MARK: RC-03 (spec §6.2, §9) — a pooled nightly value over the session hull is not sleep-eligible on nap days

    func testRC03_nightlyValueOverTheSessionHullStaysSleepEligibleOnANapDay() {
        let s = Self.s
        let main = PC.SleepSessionInput(id: "main", interval: .init(s - 2 * 3600, s + 6 * 3600),
                                        availableAt: s + 7 * 3600, sourceDay: Self.day, detector: "frwhoop-server-1")
        let nap = PC.SleepSessionInput(id: "nap", interval: .init(s + 14 * 3600, s + 15 * 3600),
                                       availableAt: s + 16 * 3600, sourceDay: Self.day, detector: "frwhoop-server-1")
        let span = (s - 4 * 3600)..<(s + 18 * 3600)
        let hr = span.map { PC.HeartRateObservation(ts: $0, bpm: 60) }
        let rr = span.map { PC.BeatIntervalObservation(ts: $0, rrMs: $0 % 2 == 0 ? 990 : 1010) }
        func nightly(_ support: PC.Interval) -> PC.MeasurementInput {
            PC.MeasurementInput(metric: .hrvRmssd,
                                method: .init(id: "snapshot.hrv_rmssd.night", algorithmVersion: "frwhoop-server-1",
                                              aggregation: .session, windowS: support.duration, units: "ms"),
                                source: .init(product: .scoringSnapshot, key: "daily.hrv_rmssd_ms"), value: 45,
                                support: support, availableAt: s + 16 * 3600)
        }
        // Repair: the worker now gives nightly values the MAIN-sleep support (never a hull that spans the awake
        // hours before a nap); a hull would rightly not be "a measurement taken during sleep". This keeps the
        // main-session case, which must stay eligible on a nap day.
        for (name, support) in [("main session", main.interval)] {
            let doc = PC.Engine.buildDay(Self.input(hr: hr, rr: rr, measurements: [nightly(support)],
                                                    sleep: [main, nap]), history: .empty)
            let e = doc.envelopes.first { $0.method.id == "snapshot.hrv_rmssd.night" }
            XCTAssertEqual(e?.verdict(.sleepMeasurement)?.state, .eligible,
                           "\(name): sleep state \(String(describing: e?.sleepWear.sleepState)), reasons " +
                           "\(e?.verdict(.sleepMeasurement)?.reasons ?? [])")
            XCTAssertTrue(doc.dailyValues.contains { $0.seriesKey == "hrv_rmssd.sleep_night" },
                          "\(name): nightly HRV has no hrv_rmssd.sleep_night value (nap days drop out of the reference)")
        }
    }

    // MARK: RC-04 (spec §6.3, §15) — the input fingerprint misses fields that change the document

    func testRC04_inputFingerprintCoversFieldsThatChangeTheDocument() throws {
        let t0 = Self.s + 10 * 3600
        let hr = ((t0 - 1800)..<(t0 + 3600)).map { PC.HeartRateObservation(ts: $0, bpm: 70) }
        func doc(kind: String, resultRevision: Int, stages: [PC.StageSpan]) -> PC.DayDocument {
            let w = PC.WorkoutInput(id: "w1", interval: .init(t0, t0 + 1200), kind: kind, source: "manual")
            let m = PC.MeasurementInput(metric: .hrvRmssd, method: Self.hrvSeries,
                                        source: .init(product: .metricSeries, key: "hrv@\(t0 + 2400)",
                                                      inputRevision: 1, resultRevision: resultRevision),
                                        value: 40, support: .init(t0 + 2400, t0 + 2700))
            let night = PC.SleepSessionInput(id: "n", interval: .init(Self.s - 3600, Self.s + 6 * 3600),
                                             stages: stages, detector: "frwhoop-server-1")
            return PC.Engine.buildDay(Self.input(hr: hr, measurements: [m], sleep: [night], workouts: [w]),
                                      history: .empty)
        }
        let a = doc(kind: "run", resultRevision: 1, stages: [])
        let b = doc(kind: "cycling", resultRevision: 2,
                    stages: [.init(interval: .init(Self.s, Self.s + 3600), stage: "deep")])
        XCTAssertNotEqual(try PC.encoder().encode(a), try PC.encoder().encode(b), "documents differ")
        XCTAssertNotEqual(a.header.inputFingerprint, b.header.inputFingerprint,
                          "workout type, source result revision and sleep stages changed the document but not the " +
                          "input fingerprint — publish_physiology_context_v1 would report 'unchanged' and keep the stale row")
    }

    // MARK: RC-05 (spec §16) — the first eligibility reason (what the card shows) is not the deciding one

    func testRC05_firstEligibilityReasonIsTheDecidingReason() {
        let support = PC.Interval(10_000, 10_300)
        let track = PC.IntervalAlgebra.resolve([PC.LabelRecord(interval: .init(8_000, 10_300), label: "walking",
                                                               tieBreak: "w")],
                                               source: .hartEpochs, heartRateDependent: false)
        let v = PC.Eligibility.evaluate(
            .stableAwakeRest, metric: .hrvRmssd, support: support,
            validity: PC.SignalValidity(state: .degraded, reasons: ["partial_beat_coverage"]),
            activity: PC.IntervalAlgebra.composition(over: support, track: track),
            preceding: PC.IntervalAlgebra.precedingHistory(before: support.start, track: track, lookbackS: 1800),
            sleepWear: PC.SleepWearContext(sleepState: .awake, sleepEvidence: ["outside_detected_sleep"],
                                           sleepDependsOnHeartSignals: true, wearState: .worn,
                                           wearEvidence: ["wear_events"], reasons: []),
            exertion: [], recentBouts: [], config: .init())
        XCTAssertEqual(v.state, .ineligible)
        XCTAssertEqual(v.reasons.first, PC.Eligibility.movementInSupport,
                       "MeasurementContextWording.topReason shows reasons.first = \(String(describing: v.reasons.first)) " +
                       "(a note), not why the walking window failed")
    }

    // MARK: RC-06 (spec §16, V07) — a censored bout's first reason (what the history row shows) is not its censoring

    func testRC06_censoredBoutsFirstReasonIsItsCensoringCause() throws {
        let t0 = Self.s + 10 * 3600
        let hr = ((t0 - 1800)..<(t0 + 4000)).map { PC.HeartRateObservation(ts: $0, bpm: 80) }
        let w1 = PC.WorkoutInput(id: "w1", interval: .init(t0, t0 + 600), kind: "run", source: "manual")
        let w2 = PC.WorkoutInput(id: "w2", interval: .init(t0 + 700, t0 + 1300), kind: "run", source: "manual")
        let doc = PC.Engine.buildDay(Self.input(hr: hr, workouts: [w1, w2]), history: .empty)
        let first = try XCTUnwrap(doc.bouts.first { $0.interval.start == t0 })
        XCTAssertEqual(first.status, .censored)
        XCTAssertEqual(first.recovery?.censoring.first, PC.ExertionBouts.censorNextBout)
        XCTAssertEqual(first.reasons.first, first.recovery?.censoring.first,
                       "PhysiologyContextWording.boutStatus shows 'Follow-up incomplete: \(first.reasons.first?.rawValue ?? "")' " +
                       "(reasons are sorted alphabetically: \(first.reasons))")
    }

    // MARK: RC-07 (spec §6.3 / V10) — a late-available measurement changes the causal document

    func testRC07_lateMeasurementDoesNotChangeTheCausalDocument() throws {
        let start = PCEngineTests.identity().dayWindow.start
        let cutoff = start + 7200
        let original = PCEngineTests.input(mode: .causalLive, cutoff: cutoff)
        var replay = original
        // Sensor time well before the cutoff, but the product became available after it.
        replay.measurements.append(PC.MeasurementInput(
            metric: .hrvRmssd, method: Self.hrvSeries, source: .init(product: .metricSeries, key: "late"),
            value: 30, support: .init(start + 4800, start + 5100), availableAt: cutoff + 60))
        let a = PC.Engine.buildDay(original, history: .empty)
        let b = PC.Engine.buildDay(replay, history: .empty)
        XCTAssertEqual(a.header.inputFingerprint, b.header.inputFingerprint)
        XCTAssertEqual(a.statusReasons, b.statusReasons,
                       "the live document now says a measurement exists after the cut-off: \(b.statusReasons)")
        XCTAssertEqual(try PC.encoder().encode(a), try PC.encoder().encode(b))
    }

    // MARK: RC-08 (contracts §6.1) — stored form: adversarial losslessness

    func testRC08a_storedFormIsLosslessForAnIntMinSecondsSinceWake() {
        var doc = PC.Engine.buildDay(PCEngineTests.input(), history: .empty)
        doc.envelopes[0].history.wake = PC.WakeReference(secondsSinceWake: Int.min, wakeAt: nil,
                                                         referenceEpisodeId: nil, referenceKind: nil, reasons: [])
        let (summary, tables) = PC.StoredDocument.split(doc)
        XCTAssertEqual(PC.StoredDocument.join(summary: summary, tables: tables), doc,
                       "Int.min is the 'no seconds' sentinel of wakeSecondsOverride")
    }

    func testRC08b_joinDoesNotSilentlyDropAMalformedRowAndClaimCompleteness() {
        let doc = PC.Engine.buildDay(PCEngineTests.input(), history: .empty)
        var (summary, tables) = PC.StoredDocument.split(doc)
        tables[0].rows[0].validity = tables[0].validity.count          // index out of its pool
        let joined = PC.StoredDocument.join(summary: summary, tables: tables)
        XCTAssertTrue(joined.envelopes.count == doc.envelopes.count || joined.envelopeIndex != nil,
                      "join dropped \(doc.envelopes.count - joined.envelopes.count) envelope(s) silently and cleared " +
                      "envelopeIndex, i.e. presents the document as complete")
    }

    func testRC08c_joinKeepsTheOrderOfEnvelopesSharingSupportAndMethodId() {
        var doc = PC.Engine.buildDay(PCEngineTests.input(), history: .empty)
        let a = doc.envelopes.first { $0.metric == .hrvRmssd }!
        var b = a
        b.metric = .heartRate                                        // a later MetricKind table sorts first
        // The engine emits envelopes in canonical order (support, method id, metric); join restores that order.
        doc.envelopes = [a, b].sorted(by: PC.StoredDocument.documentOrder)
        let (summary, tables) = PC.StoredDocument.split(doc)
        XCTAssertEqual(PC.StoredDocument.join(summary: summary, tables: tables), doc)
    }

    func testRC08d_precedesZeroSecondsNegativeOffsetsAndOverrides_holds() throws {
        var doc = PC.Engine.buildDay(PCEngineTests.input(), history: .empty)
        let anchor = doc.envelopes[0].support.start
        doc.envelopes[0].history.exposures = [
            PC.ExposureRef(eventId: "e0", revision: 1, kind: .caffeine, label: "c", relation: "precedes",
                           secondsSinceOccurrence: 0, timePrecision: .exact, confirmation: .confirmed),
            PC.ExposureRef(eventId: "e1", revision: 2, kind: .meal, label: "m", relation: "overlaps",
                           secondsSinceOccurrence: 17, timePrecision: .approximate, confirmation: .denied),
        ]
        doc.envelopes[0].history.wake = PC.WakeReference(secondsSinceWake: -5, wakeAt: anchor + 99,
                                                         referenceEpisodeId: "x", referenceKind: .nap, reasons: [])
        doc.envelopes[0].history.recentBouts = [PC.BoutRef(boutId: "b", kind: "walking", endedAt: anchor + 50,
                                                           secondsBeforeMeasurement: -50, durationS: 60)]
        doc.envelopes[0].activity.interval = .init(anchor - 900, anchor - 600)
        let (summary, tables) = PC.StoredDocument.split(doc)
        let s2 = try PC.decoder().decode(PC.DayDocument.self, from: PC.encoder().encode(summary))
        let t2 = try tables.map { try PC.decoder().decode(PC.EnvelopeTable.self, from: PC.encoder().encode($0)) }
        XCTAssertEqual(PC.StoredDocument.join(summary: s2, tables: t2), doc)
    }

    // MARK: RC-11 (spec §6.1, §13 / V14) — no motion evidence becomes "zero activity per worn hour"

    func testRC11_missingMotionEvidenceIsNotZeroActivity() {
        // 6 h of heart rate (wear evidence) and NO motion stream, HART epochs or steps at all.
        let base = Self.s + 8 * 3600
        let hr = (base..<(base + 6 * 3600)).map { PC.HeartRateObservation(ts: $0, bpm: 72) }
        let doc = PC.Engine.buildDay(Self.input(hr: hr), history: .empty)
        XCTAssertTrue(doc.functional.reasons.contains(PC.Functional.activityEvidenceUnavailable))
        let zeros = doc.dailyValues.filter { $0.seriesKey.hasPrefix("functional.") }
            .map { "\($0.seriesKey)=\($0.value)" }
        XCTAssertTrue(zeros.isEmpty, "no activity evidence, yet functional values were published: \(zeros)")
        let computed = doc.features.filter { $0.state == PC.FeatureRegistry.stateComputed }
            .map { "\($0.featureId)=\($0.value ?? -1)" }
        XCTAssertTrue(computed.isEmpty, "features computed without activity evidence: \(computed)")
    }

    // MARK: RC-12 (spec §6.2) — fully tied epoch records resolve by input order

    func testRC12_tiedEpochRecordsResolveIndependentlyOfInputOrder() {
        func epoch(_ end: Int, _ motion: MotionLabel) -> PC.ActivityEpochInput {
            PC.ActivityEpochInput(epoch: ActivityEpoch(startTs: 1000, endTs: end, motion: motion, posture: .unknown,
                                                       exercise: .unknown, sleepState: .unknown, exertion: .unknown,
                                                       wear: .unknown, confidence: 0.9, observedS: 30, validS: 30),
                                  revision: 4, availableAt: 2000)
        }
        let a = [epoch(1030, .walking), epoch(1060, .stationary)]
        let r1 = PC.IntervalAlgebra.resolve(PC.IntervalAlgebra.records(fromEpochs: a), source: .hartEpochs,
                                            heartRateDependent: false)
        let r2 = PC.IntervalAlgebra.resolve(PC.IntervalAlgebra.records(fromEpochs: a.reversed()), source: .hartEpochs,
                                            heartRateDependent: false)
        XCTAssertEqual(r1.spans, r2.spans, "tieBreak `epoch:<revision>:<start>` is not unique: \(r1.spans) vs \(r2.spans)")
    }

    // MARK: Checks that hold (evidence for the OK verdicts)

    func testRC09_overlappingEqualRevisionsAndZeroLengthRecords_holds() {
        // Equal revisions, equal availability, overlapping, plus zero-length and inverted records.
        let records = [
            PC.LabelRecord(interval: .init(0, 600), label: "walking", revision: 3, availableAt: 10, tieBreak: "a"),
            PC.LabelRecord(interval: .init(300, 900), label: "stationary", revision: 3, availableAt: 10, tieBreak: "b"),
            PC.LabelRecord(interval: .init(400, 400), label: "running", revision: 9, tieBreak: "z"),
            PC.LabelRecord(interval: .init(800, 700), label: "running", revision: 9, tieBreak: "y"),
        ]
        let t1 = PC.IntervalAlgebra.resolve(records, source: .hartEpochs, heartRateDependent: false)
        let t2 = PC.IntervalAlgebra.resolve(records.reversed(), source: .hartEpochs, heartRateDependent: false)
        XCTAssertEqual(t1, t2, "input order must not matter")
        let support = PC.Interval(-1_000_000_000, 1_000_000_000)    // a huge support crossing many days
        let c = PC.IntervalAlgebra.composition(over: support, track: t1)
        XCTAssertTrue(PC.IntervalAlgebra.reconciles(c))
        XCTAssertEqual(c.labels.reduce(0) { $0 + $1.seconds }, 900, accuracy: 1e-9)
        XCTAssertEqual(c.uncoveredS, Double(support.duration) - 900, accuracy: 1e-6)
        XCTAssertEqual(c.resolvedOverlapS, 300)
        let empty = PC.IntervalAlgebra.composition(over: .init(5, 5), track: t1)
        XCTAssertEqual(empty.reasons, [PC.IntervalAlgebra.invalidInterval])
    }

    func testRC10_equalRRValuesAreDistinctBeatsAndClockResetsBreakAdjacency_holds() {
        let t = Self.s + 3600
        var rr: [PC.BeatIntervalObservation] = []
        for k in 0..<120 { rr.append(.init(ts: t + k, rrMs: 1000, seq: 0, availableAt: t + 200)) }
        // Clock reset inside one delivery: time jumps back 600 s.
        for k in 0..<30 { rr.append(.init(ts: t - 600 + k, rrMs: 1000, seq: 0, availableAt: t + 200)) }
        rr.append(.init(ts: t + 10, rrMs: 1000, seq: 1, availableAt: t + 200))      // second equal beat, same second
        rr.append(.init(ts: t + 10, rrMs: 1000, seq: 0, availableAt: t + 300))      // transport duplicate
        let (o, report) = PC.SignalValidityEngine.sanitize(Self.input(rr: rr), config: .init())
        XCTAssertEqual(o.beatIntervals.filter { $0.ts == t + 10 }.count, 2)
        XCTAssertEqual(report.count("beat_intervals.exact_duplicates_collapsed"), 1)
        XCTAssertTrue(report.reasons.contains(PC.SignalValidityEngine.clockResetDetected))
        XCTAssertTrue(o.breakSeparates(t - 600, t + 5))
    }
}
