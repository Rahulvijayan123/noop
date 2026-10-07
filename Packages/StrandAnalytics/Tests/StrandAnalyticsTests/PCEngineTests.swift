import XCTest
@testable import StrandAnalytics

/// Engine-level contract tests: determinism, JSON round trip, causal cutoff, history guard.
final class PCEngineTests: XCTestCase {
    typealias PC = PhysiologyContext

    static let day = "2026-10-01"
    static let tzId = "America/Los_Angeles"

    static func identity() -> PC.DayIdentity {
        PC.DayIdentity(deviceScope: "dev-1", day: day, timezoneId: tzId,
                       dayWindow: PC.Engine.dayInterval(day, timezoneId: tzId))
    }

    static func input(mode: PC.ProcessingMode = .retrospective, cutoff: Int? = nil,
                      extraHR: [PC.HeartRateObservation] = []) -> PC.DayInput {
        let id = identity()
        let start = id.dayWindow.start
        var hr: [PC.HeartRateObservation] = []
        for t in stride(from: start + 3600, to: start + 3600 * 3, by: 1) {
            hr.append(.init(ts: t, bpm: 60 + (t % 7), availableAt: t + 120))
        }
        hr += extraHR
        let series = PC.MeasurementInput(
            metric: .hrvRmssd,
            method: .init(id: "series.hrv_rmssd.5min", algorithmVersion: "frwhoop-series-2", aggregation: .window,
                          windowS: 300, units: "ms"),
            source: .init(product: .metricSeries, key: "hrv_rmssd_ms@\(start + 3900)"),
            value: 42, support: .init(start + 3900, start + 4200), sampleCount: 300, coverage: 1,
            availableAt: start + 4500)
        return PC.DayInput(identity: id, mode: mode, availabilityCutoff: cutoff ?? (id.dayWindow.end + 40 * 3600),
                           generatedAt: id.dayWindow.end + 40 * 3600, heartRate: hr, measurements: [series],
                           regime: .init(scoringAlgorithmVersion: "frwhoop-server-1",
                                         seriesAlgorithmVersion: "frwhoop-series-2"))
    }

    func testDocumentIsDeterministicAndRoundTripsThroughJSON() throws {
        let a = PC.Engine.buildDay(Self.input(), history: .empty)
        let b = PC.Engine.buildDay(Self.input(), history: .empty)
        let ea = try PC.encoder().encode(a)
        let eb = try PC.encoder().encode(b)
        XCTAssertEqual(ea, eb)
        let decoded = try PC.decoder().decode(PC.DayDocument.self, from: ea)
        XCTAssertEqual(decoded, a)
        XCTAssertEqual(try PC.encoder().encode(decoded), ea)
        XCTAssertEqual(a.header.interpretation.finality, .final)
        XCTAssertEqual(a.header.schemaVersion, PC.schemaVersion)
        XCTAssertFalse(a.header.policyFingerprint.isEmpty)
    }

    func testEveryEnvelopeHasItsWholeSupportAndADeterministicId() {
        let doc = PC.Engine.buildDay(Self.input(), history: .empty)
        let hrv = doc.envelopes.filter { $0.metric == .hrvRmssd }
        XCTAssertEqual(hrv.count, 1)
        XCTAssertEqual(hrv[0].support.duration, 300)
        XCTAssertEqual(hrv[0].id, "series.hrv_rmssd.5min@\(hrv[0].support.start)-\(hrv[0].support.end)")
        // Derived heart-rate windows: 2 h of samples → 24 windows of 5 minutes.
        let hr = doc.envelopes.filter { $0.metric == .heartRate }
        XCTAssertEqual(hr.count, 24)
        XCTAssertTrue(hr.allSatisfy { $0.support.duration == 300 && $0.source.product == .contextDerived })
        for e in doc.envelopes { XCTAssertTrue(PC.IntervalAlgebra.reconciles(e.activity)) }
    }

    func testCausalReplayAtTheSameCutoffIgnoresLaterData() throws {
        let id = Self.identity()
        let cutoff = id.dayWindow.start + 3600 * 2
        let original = PC.Engine.buildDay(Self.input(mode: .causalLive, cutoff: cutoff), history: .empty)
        // Late rows: a backfill whose sensor time is inside the window but which arrived after the cutoff,
        // plus rows from after the cutoff.
        let late = (0..<600).map { PC.HeartRateObservation(ts: id.dayWindow.start + 3600 + $0, bpm: 140,
                                                            availableAt: cutoff + 10) }
        let replay = PC.Engine.buildDay(Self.input(mode: .causalLive, cutoff: cutoff, extraHR: late),
                                        history: .empty)
        XCTAssertEqual(original.header.inputFingerprint, replay.header.inputFingerprint)
        XCTAssertEqual(try PC.encoder().encode(original), try PC.encoder().encode(replay))
        XCTAssertEqual(original.header.interpretation.mode, .causalLive)
        XCTAssertEqual(original.header.interpretation.finality, .provisional)
        // A measurement whose support ends after the cutoff is not part of the live document.
        XCTAssertTrue(original.envelopes.allSatisfy { $0.support.end <= cutoff })
    }

    func testHistoryFromTheSameDayOrLaterIsDropped() {
        let v = PC.DailyValue(day: Self.day, seriesKey: "hrv_rmssd.sleep_night", regimeKey: "r", metric: .hrvRmssd,
                              value: 50, units: "ms", supportCount: 1, supportUnit: "night", supportS: 1,
                              mode: .retrospective, finality: .final)
        let doc = PC.Engine.buildDay(Self.input(), history: .init(dailyValues: [v]))
        XCTAssertTrue(doc.statusReasons.contains(PC.Engine.historyFromFutureDropped))
    }

    func testStoredFormIsLosslessAndRoundTripsThroughJSON() throws {
        let doc = PC.Engine.buildDay(Self.input(), history: .empty)
        let (summary, tables) = PC.StoredDocument.split(doc)
        XCTAssertTrue(summary.envelopes.isEmpty)
        XCTAssertEqual(summary.envelopeIndex?.map(\.envelopeCount).reduce(0, +), doc.envelopes.count)
        let s2 = try PC.decoder().decode(PC.DayDocument.self, from: PC.encoder().encode(summary))
        let t2 = try tables.map { try PC.decoder().decode(PC.EnvelopeTable.self, from: PC.encoder().encode($0)) }
        XCTAssertEqual(PC.StoredDocument.join(summary: s2, tables: t2), doc)
    }

    func testRetrospectiveFinalityChangesTheInputFingerprint() {
        // Same data; one rebuild before the day is 30 h closed (provisional), one after (final). The final rebuild
        // must not be an "unchanged" publish, or the stored row would stay provisional forever.
        let id = Self.identity()
        let early = PC.Engine.buildDay(Self.input(cutoff: id.dayWindow.end + 3600), history: .empty)
        let late = PC.Engine.buildDay(Self.input(cutoff: id.dayWindow.end + 31 * 3600), history: .empty)
        XCTAssertEqual(early.header.interpretation.finality, .provisional)
        XCTAssertEqual(late.header.interpretation.finality, .final)
        XCTAssertNotEqual(early.header.inputFingerprint, late.header.inputFingerprint)
        // Two final rebuilds at different cutoffs are still the same input.
        let later = PC.Engine.buildDay(Self.input(cutoff: id.dayWindow.end + 50 * 3600), history: .empty)
        XCTAssertEqual(late.header.inputFingerprint, later.header.inputFingerprint)
    }

    func testPolicyChangeChangesTheFingerprint() {
        var p = PC.Policy()
        let a = p.fingerprint
        p.join.precedingLookbackS += 1
        XCTAssertNotEqual(a, p.fingerprint)
    }
}

/// The canonical context record end to end: posture stratum, decoder transition events, source confidence and
/// provenance, wear-signal quality, causal visibility and the stored form (D3-06/07/10/11, D5-07, D5-13, D6-15).
final class PCEngineContextRecordTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias F = PCSignalFixtures
    typealias B = PhysiologyContext.Eligibility

    static let from = F.dayStart + 8 * 3600
    static let to = F.dayStart + 12 * 3600
    static let eventTs = F.t0 + 60

    static func epochs(confidence: Double = 0.9, looseFrom: Int? = nil) -> [PC.ActivityEpochInput] {
        stride(from: from, to: to, by: 30).map { t in
            let loose = looseFrom.map { t >= $0 && t < $0 + 300 } ?? false
            return PC.ActivityEpochInput(
                epoch: ActivityEpoch(startTs: t, endTs: t + 30, motion: .stationary, posture: .unknown,
                                     exercise: .false, sleepState: .awake, exertion: .restingCandidate,
                                     wear: .onWrist, wearSignal: loose ? .onWristLoose : .onWristGood,
                                     confidence: confidence, observedS: 30, validS: 30),
                revision: 7, availableAt: t + 60, modelVersion: "hart-wisdm-v0", preprocessingVersion: "1.0.0")
        }
    }

    static func input(confidence: Double = 0.9, looseFrom: Int? = nil, events: [PC.TransitionEventInput]? = nil,
                      mode: PC.ProcessingMode = .retrospective, cutoff: Int? = nil) -> PC.DayInput {
        let hr = stride(from: from, to: to, by: 1).map { PC.HeartRateObservation(ts: $0, bpm: 62, availableAt: $0 + 30) }
        // Forearm flat (lying on a sofa), very still.
        let motion = stride(from: from, to: to, by: 1).map {
            PC.MotionObservation(ts: $0, dynAccelG: 0.004, x: 0.1, y: 0.2, z: 0.97, availableAt: $0 + 30)
        }
        var input = F.input(heartRate: hr, motion: motion, mode: mode, cutoff: cutoff)
        input.activityEpochs = epochs(confidence: confidence, looseFrom: looseFrom)
        input.activityIntervals = [PC.ActivityIntervalInput(
            interval: .init(from, to), activityClass: "sitting", confidence: 0.8, revision: 11,
            availableAt: from + 60, inBed: false, decoderVersion: "hsmm-1.7", algorithmVersion: "streams-activity-1")]
        input.activityTransitions = events ?? [
            PC.TransitionEventInput(ts: eventTs, kind: "sit_to_stand_like", probability: 0.8, revision: 11,
                                    availableAt: eventTs + 120, decoderVersion: "hsmm-1.7",
                                    algorithmVersion: "streams-activity-1"),
        ]
        return input
    }

    static func hrWindow(_ doc: PC.DayDocument, at start: Int) -> PC.MeasurementEnvelope? {
        doc.envelopes.first { $0.metric == .heartRate && $0.support.start == start }
    }

    func testEnvelopeCarriesPostureTransitionsConfidenceAndProvenance() throws {
        let doc = PC.Engine.buildDay(Self.input(), history: .empty)
        let w = try XCTUnwrap(Self.hrWindow(doc, at: F.t0))
        XCTAssertEqual(w.posture?.stratum, .recumbentLikely)
        XCTAssertEqual(w.posture?.basis, [PC.PostureEvidence.basisForearmGravity])
        XCTAssertEqual(w.activity.source, .hartEpochs)
        XCTAssertEqual(w.activity.transitionEvents?.postural, 1)
        XCTAssertEqual(w.activity.meanConfidence, 0.9)
        XCTAssertEqual(w.activity.provenance, ["hart-wisdm-v0@1.0.0"])
        XCTAssertEqual(w.decoderActivity?.provenance, ["streams-activity-1/hsmm-1.7"])
        XCTAssertEqual(w.wearSignal?.poorS, 0)
        let v = try XCTUnwrap(w.verdict(.stableAwakeRest))
        XCTAssertEqual(v.state, .ineligible)
        XCTAssertTrue(v.reasons.contains(B.recentPosturalTransition), "\(v.reasons)")
        XCTAssertTrue(v.targetDependentGates.contains(B.gateDecoderTransitionEvents))
        // The next window is past the 120-s settling time: the event is history, not a gate.
        let next = try XCTUnwrap(Self.hrWindow(doc, at: F.t0 + 300))
        XCTAssertEqual(next.preceding.secondsSinceLastPosturalTransition, 240)
        XCTAssertEqual(next.preceding.lastPosturalTransitionKind, "sit_to_stand_like")
        XCTAssertEqual(next.preceding.transitionEvents?.postural, 1)
        XCTAssertEqual(next.activity.transitionEvents?.postural, 0, "observed and quiet")
        XCTAssertFalse(next.verdict(.stableAwakeRest)!.reasons.contains(B.recentPosturalTransition))
        // Lossless stored form with the new records.
        let (summary, tables) = PC.StoredDocument.split(doc)
        XCTAssertEqual(PC.StoredDocument.join(summary: summary, tables: tables), doc)
        let decoded = try PC.decoder().decode(PC.DayDocument.self, from: try PC.encoder().encode(doc))
        XCTAssertEqual(decoded, doc)
    }

    func testLowConfidenceAndPoorWearSignalAreUnknownNotEligible() throws {
        let low = PC.Engine.buildDay(Self.input(confidence: 0.3, events: []), history: .empty)
        let lv = try XCTUnwrap(Self.hrWindow(low, at: F.t0 + 1800)?.verdict(.stableAwakeRest))
        XCTAssertTrue(lv.reasons.contains(B.lowActivityConfidence), "\(lv.reasons)")
        let loose = PC.Engine.buildDay(Self.input(looseFrom: F.t0 + 1800, events: []), history: .empty)
        let w = try XCTUnwrap(Self.hrWindow(loose, at: F.t0 + 1800))
        XCTAssertEqual(w.wearSignal?.poorS, 300)
        XCTAssertTrue(w.verdict(.stableAwakeRest)!.reasons.contains(B.wearSignalPoor))
        XCTAssertFalse(Self.hrWindow(loose, at: F.t0 + 2400)!.verdict(.stableAwakeRest)!.reasons.contains(B.wearSignalPoor))
    }

    func testCausalDocumentNeverSeesAnEventPublishedAfterItsCutoff() throws {
        // Cutoff 10:02: the 10:01 event was published at 10:03.
        let cutoff = F.t0 + 120
        let doc = PC.Engine.buildDay(Self.input(mode: .causalLive, cutoff: cutoff), history: .empty)
        let w = try XCTUnwrap(doc.envelopes.first { $0.metric == .heartRate && $0.support.end <= cutoff })
        XCTAssertEqual(w.activity.transitionEvents?.postural ?? 0, 0)
        XCTAssertNil(w.preceding.secondsSinceLastPosturalTransition)
        // A retrospective rebuild sees it, and an added event changes the input fingerprint.
        let retro = PC.Engine.buildDay(Self.input(events: []), history: .empty)
        let withEvent = PC.Engine.buildDay(Self.input(), history: .empty)
        XCTAssertNotEqual(retro.header.inputFingerprint, withEvent.header.inputFingerprint)
    }
}
