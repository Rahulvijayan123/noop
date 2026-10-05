import XCTest
@testable import StrandAnalytics

/// System E: exposure timing (spec §11, V09, V15). Expected values are worked out by hand from the fixture times,
/// not read back from the implementation.
final class PCExposureTests: XCTestCase {
    typealias PC = PhysiologyContext

    static let tz = "America/Los_Angeles"
    static let day = "2026-10-01"
    /// 2026-10-01 00:00 America/Los_Angeles (UTC-7).
    static let d0 = 1_790_838_000
    static let h = 3600

    static func identity(_ day: String = day) -> PC.DayIdentity {
        PC.DayIdentity(deviceScope: "dev-1", day: day, timezoneId: tz,
                       dayWindow: PC.Engine.dayInterval(day, timezoneId: tz))
    }

    static func rev(_ id: String = "e1", _ revision: Int = 1, kind: PC.ExposureKind = .caffeine,
                    label: String = "coffee", at start: Int, end: Int? = nil, precision: PC.TimePrecision = .exact,
                    recordedAt: Int? = nil, receivedAt: Int? = nil, source: PC.ExposureSource = .userEntered,
                    confirmation: PC.ExposureConfirmation = .confirmed, dose: Double? = nil,
                    unit: String? = nil) -> PC.ExposureEventRevision {
        PC.ExposureEventRevision(eventId: id, revision: revision, kind: kind, label: label,
                                 occurred: PC.Interval(start, end ?? start + 1), timePrecision: precision,
                                 recordedAt: recordedAt ?? start + 60, receivedAt: receivedAt, source: source,
                                 confirmation: confirmation, doseAmount: dose, doseUnit: unit,
                                 doseProvenance: dose == nil ? nil : "user_entered")
    }

    /// A measurement envelope with a heart-rate independent composition of `locomotionS` walking seconds.
    static func envelope(start: Int, width: Int = 300, value: Double?, metric: PC.MetricKind = .heartRate,
                         methodId: String = "context.heart_rate.5min_mean", state: PC.ValidityState = .valid,
                         regime: String = "regime-a", locomotionS: Double = 0) -> PC.MeasurementEnvelope {
        let support = PC.Interval(start, start + width)
        let w = Double(width)
        var labels = [PC.LabelShare(label: "still", seconds: w - locomotionS, share: (w - locomotionS) / w)]
        if locomotionS > 0 { labels.append(PC.LabelShare(label: "walking", seconds: locomotionS, share: locomotionS / w)) }
        let activity = PC.ActivityComposition(interval: support, intervalS: width, source: .strapMotion,
                                              heartRateDependent: false, labels: labels, unknownS: 0, uncoveredS: 0,
                                              transitions: 0, mixed: false, dominantLabel: nil, resolvedOverlapS: 0,
                                              reasons: [])
        let method = PC.MethodRef(id: methodId, algorithmVersion: "test", aggregation: .mean, windowS: width,
                                  units: "bpm")
        return PC.MeasurementEnvelope(
            id: PC.MeasurementEnvelope.makeId(method: method, support: support), metric: metric, method: method,
            source: PC.SourceRef(product: .contextDerived, key: "k@\(start)"), value: value, support: support,
            displayBucket: nil, localTime: PC.localTime(at: start, timezoneId: tz),
            validity: PC.SignalValidity(state: state, reasons: []), regimeKey: regime, activity: activity,
            decoderActivity: nil,
            preceding: PC.PrecedingHistory(lookback: PC.Interval(start - 1800, start), source: .strapMotion,
                                           stillRunS: 0, stillRunEndedBy: nil, secondsSinceSupportedActivity: nil,
                                           lastSupportedActivityLabel: nil, coveredS: 0, transitions: 0),
            sleepWear: .unknown,
            history: PC.HistoryContext(wake: .unknown([]), recentBouts: [], exertion: [], exposures: [],
                                       exposureCoverage: []),
            eligibility: [], comparisons: [], finality: .provisional)
    }

    /// 5-minute heart-rate envelopes from `from` to `to` (exclusive), value 60 + index % 5.
    static func hrEnvelopes(from: Int, to: Int, regime: String = "regime-a") -> [PC.MeasurementEnvelope] {
        stride(from: from, to: to, by: 300).enumerated().map {
            envelope(start: $0.element, value: Double(60 + $0.offset % 5), regime: regime)
        }
    }

    static func engineInput(mode: PC.ProcessingMode, cutoff: Int,
                            exposures: [PC.ExposureEventRevision]) -> PC.DayInput {
        let id = identity()
        let start = id.dayWindow.start
        let hr = stride(from: start + 7 * h, to: start + 11 * h, by: 1).map {
            PC.HeartRateObservation(ts: $0, bpm: 60 + ($0 % 7), availableAt: $0 + 60)
        }
        return PC.DayInput(identity: id, mode: mode, availabilityCutoff: cutoff, generatedAt: cutoff, heartRate: hr,
                           regime: .init(scoringAlgorithmVersion: "frwhoop-server-1"), exposures: exposures)
    }

    // MARK: - V09 late entry

    func testLateEntryIsInvisibleToAnEarlierCausalViewButUsedRetrospectively() {
        // Coffee at 08:00, entered at 20:00, received 20:05.
        let r = Self.rev(at: Self.d0 + 8 * Self.h, recordedAt: Self.d0 + 20 * Self.h,
                         receivedAt: Self.d0 + 20 * Self.h + 300)
        XCTAssertTrue(PC.Exposures.current([r], mode: .causalLive, cutoff: Self.d0 + 12 * Self.h).isEmpty)
        XCTAssertEqual(PC.Exposures.current([r], mode: .causalLive, cutoff: Self.d0 + 21 * Self.h).count, 1)
        let retro = PC.Exposures.current([r], mode: .retrospective, cutoff: Self.d0 + 12 * Self.h)
        XCTAssertEqual(retro.map(\.eventId), ["e1"])
        // Occurrence and availability stay distinct.
        XCTAssertEqual(retro[0].occurred.start, Self.d0 + 8 * Self.h)
        XCTAssertEqual(retro[0].availableAt, Self.d0 + 20 * Self.h + 300)
        // Without a server receipt the entry time is the availability.
        let unsent = Self.rev(at: Self.d0 + 8 * Self.h, recordedAt: Self.d0 + 9 * Self.h)
        XCTAssertTrue(PC.Exposures.current([unsent], mode: .causalLive, cutoff: Self.d0 + 9 * Self.h - 1).isEmpty)
        XCTAssertEqual(PC.Exposures.current([unsent], mode: .causalLive, cutoff: Self.d0 + 9 * Self.h).count, 1)
    }

    func testEngineLiveDocumentIgnoresLateEntriesAndRetrospectiveCountsThem() throws {
        let cutoff = Self.d0 + 10 * Self.h
        let early = Self.rev("early", at: Self.d0 + 7 * Self.h, receivedAt: Self.d0 + 7 * Self.h + 120)
        // Wine at 09:00, entered the next morning: available only after the day ended.
        let late = Self.rev("late", kind: .alcohol, label: "wine", at: Self.d0 + 9 * Self.h,
                            recordedAt: Self.d0 + 33 * Self.h, receivedAt: Self.d0 + 33 * Self.h + 5)
        // A correction of `early` that arrives after the live cutoff.
        let correction = Self.rev("early", 2, at: Self.d0 + 7 * Self.h + 1800, receivedAt: Self.d0 + 15 * Self.h,
                                  dose: 80, unit: "mg")
        let live = PC.Engine.buildDay(Self.engineInput(mode: .causalLive, cutoff: cutoff, exposures: [early]),
                                      history: .empty)
        let liveWithFuture = PC.Engine.buildDay(
            Self.engineInput(mode: .causalLive, cutoff: cutoff, exposures: [early, late, correction]),
            history: .empty)
        // Byte-identical: a late entry or later correction never reaches an earlier live decision (V09/V10).
        XCTAssertEqual(try PC.encoder().encode(live), try PC.encoder().encode(liveWithFuture))
        XCTAssertEqual(live.exposures.events.map(\.eventId), ["early"])
        XCTAssertEqual(live.exposures.events.first?.revision, 1)
        XCTAssertEqual(live.exposures.revisionsNotYetAvailable, 0)
        XCTAssertEqual(live.exposures.lateRevisions, 0)
        // An envelope after the coffee references it; nothing references the late wine.
        let after = live.envelopes.first { $0.support.start >= Self.d0 + 8 * Self.h }
        XCTAssertEqual(after?.history.exposures.map(\.eventId), ["early"])
        XCTAssertEqual(after?.history.exposures.first?.relation, PC.Exposures.relationPrecedes)

        let retro = PC.Engine.buildDay(
            Self.engineInput(mode: .retrospective, cutoff: Self.d0 + 70 * Self.h, exposures: [early, late, correction]),
            history: .empty)
        XCTAssertEqual(Set(retro.exposures.events.map { $0.eventId }), Set(["early", "late"]))
        let corrected = retro.exposures.events.first { $0.eventId == "early" }
        XCTAssertEqual(corrected?.revision, 2)
        XCTAssertEqual(corrected?.revisionCount, 2)
        XCTAssertEqual(corrected?.doseAmount, 80)
        XCTAssertEqual(retro.exposures.lateRevisions, 1)
        XCTAssertTrue(retro.exposures.reasons.contains(PC.Exposures.lateEntriesIncluded))
        let decoded = try PC.decoder().decode(PC.DayDocument.self, from: PC.encoder().encode(retro))
        XCTAssertEqual(decoded, retro)
    }

    // MARK: - V09 correction, V15 invalidation

    func testCorrectionReplacesCurrentStateKeepsHistoryAndInvalidatesOldAndNewDays() {
        let r1 = Self.rev(at: Self.d0 + 8 * Self.h, receivedAt: Self.d0 + 8 * Self.h + 60, dose: 100, unit: "mg")
        // Two days later in a different spot with a different dose.
        let r2 = Self.rev("e1", 2, at: Self.d0 + 2 * 24 * Self.h + 14 * Self.h, receivedAt: Self.d0 + 60 * Self.h,
                          dose: 200, unit: "mg")
        let now = PC.Exposures.current([r2, r1], mode: .retrospective, cutoff: 0)
        XCTAssertEqual(now.count, 1)
        XCTAssertEqual(now[0].revision, 2)
        XCTAssertEqual(now[0].revisionCount, 2)
        XCTAssertEqual(now[0].doseAmount, 200)
        XCTAssertEqual(now[0].occurred.start, r2.occurred.start)
        // A live view before the correction arrived still sees revision 1.
        let before = PC.Exposures.current([r1, r2], mode: .causalLive, cutoff: Self.d0 + 59 * Self.h)
        XCTAssertEqual(before.first?.revision, 1)
        XCTAssertEqual(before.first?.revisionCount, 1)
        XCTAssertEqual(before.first?.doseAmount, 100)

        // Old occurrence 10-01 08:00 minus the 24 h aligned window → 09-30; new end 10-03 14:00:01 + 72 h → 10-06.
        let days = PC.Exposures.affectedDays(revision: r2, previous: r1, timezoneId: Self.tz, config: .init())
        XCTAssertEqual(days, ["2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04", "2026-10-05",
                              "2026-10-06"])
        // A first revision only covers its own reach.
        XCTAssertEqual(PC.Exposures.affectedDays(revision: r1, previous: nil, timezoneId: Self.tz, config: .init()),
                       ["2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04"])
    }

    func testAffectedDaysFollowLocalDaysAcrossTheDSTChange() {
        // 2026-10-31 12:00 PDT; DST ends 2026-11-01. 72 h after 12:00:01 PDT is 11:00:01 PST on 11-03.
        let t = 1_793_473_200
        XCTAssertEqual(PC.localTime(at: t, timezoneId: Self.tz).localDay, "2026-10-31")
        let r = Self.rev(at: t)
        XCTAssertEqual(PC.Exposures.affectedDays(revision: r, previous: nil, timezoneId: Self.tz, config: .init()),
                       ["2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02", "2026-11-03"])
        // A day-only answer reaches the day four days on (its range ends at the next midnight).
        let journal = Self.rev(at: Self.d0, end: Self.d0 + 24 * Self.h, precision: .dayOnly,
                               source: .journalDayAnswer)
        let days = PC.Exposures.affectedDays(revision: journal, previous: nil, timezoneId: Self.tz, config: .init())
        XCTAssertEqual(days.first, "2026-09-30")
        XCTAssertEqual(days.last, "2026-10-05")
        var capped = PC.ExposureConfig()
        capped.maxAffectedDays = 2
        XCTAssertEqual(PC.Exposures.affectedDays(revision: r, previous: nil, timezoneId: Self.tz, config: capped),
                       ["2026-10-30", "2026-10-31"])
    }

    // MARK: - Retraction

    func testRetractionLeavesCurrentStateButKeepsHistory() {
        let r1 = Self.rev(at: Self.d0 + 8 * Self.h, receivedAt: Self.d0 + 8 * Self.h)
        // A delete carries an empty range here on purpose: a retraction must never fall back to revision 1.
        var r2 = Self.rev("e1", 2, at: Self.d0 + 8 * Self.h, receivedAt: Self.d0 + 12 * Self.h,
                          confirmation: .retracted)
        r2.occurred = PC.Interval(0, 0)
        XCTAssertTrue(PC.Exposures.current([r1, r2], mode: .retrospective, cutoff: 0).isEmpty)
        XCTAssertEqual(PC.Exposures.current([r1, r2], mode: .causalLive, cutoff: Self.d0 + 11 * Self.h).count, 1)
        // Re-adding after a retraction is a new revision and the event is current again, history counted.
        let r3 = Self.rev("e1", 3, at: Self.d0 + 9 * Self.h, receivedAt: Self.d0 + 13 * Self.h)
        let back = PC.Exposures.current([r1, r2, r3], mode: .retrospective, cutoff: 0)
        XCTAssertEqual(back.first?.revision, 3)
        XCTAssertEqual(back.first?.revisionCount, 3)
    }

    // MARK: - Unrecorded, denied, confirmed, candidate

    func testUnrecordedDeniedAndConfirmedAreDifferentStates() {
        let noAlcohol = Self.rev("j1", kind: .alcohol, label: "did you drink any alcohol?", at: Self.d0,
                                 end: Self.d0 + 24 * Self.h, precision: .dayOnly, source: .journalDayAnswer,
                                 confirmation: .denied)
        let coffee = Self.rev("c1", at: Self.d0 + 8 * Self.h)
        let events = PC.Exposures.current([noAlcohol, coffee], mode: .retrospective, cutoff: 0)
        let support = PC.Interval(Self.d0 + 12 * Self.h, Self.d0 + 12 * Self.h + 300)
        let status = Dictionary(uniqueKeysWithValues: PC.Exposures.categoryStatus(
            for: support, events: events, config: .init()).map { ($0.kind, $0) })
        XCTAssertEqual(status.count, PC.ExposureKind.allCases.count)
        XCTAssertEqual(status[.caffeine]?.status, "recorded")
        XCTAssertEqual(status[.alcohol]?.status, "denied")
        // The "no" covers 12 h 05 min of the 72 h window ending at the support end; the rest is unrecorded.
        XCTAssertEqual(status[.alcohol]?.deniedCoverage ?? -1, Double(12 * 3600 + 300) / Double(72 * 3600),
                       accuracy: 1e-9)
        XCTAssertEqual(status[.medication]?.status, "unrecorded")
        XCTAssertNil(status[.medication]?.deniedCoverage)
        XCTAssertEqual(status[.meal]?.status, "unrecorded")

        let refs = PC.Exposures.refs(for: support, events: events, config: .init())
        XCTAssertEqual(refs.map(\.eventId), ["j1", "c1"])
        XCTAssertEqual(refs[0].relation, "overlaps")
        XCTAssertEqual(refs[0].confirmation, .denied)
        XCTAssertEqual(refs[1].relation, "precedes")
        XCTAssertEqual(refs[1].secondsSinceOccurrence, 4 * 3600 - 1)

        // Over the day itself the denial covers everything; nothing is recorded for the next day.
        let summary = PC.Exposures.daySummary(revisions: [noAlcohol, coffee], events: events, envelopes: [],
                                              bouts: [], identity: Self.identity(), mode: .retrospective,
                                              cutoff: Self.d0 + 70 * Self.h, config: .init())
        let dayStatus = Dictionary(uniqueKeysWithValues: summary.categoryStatus.map { ($0.kind, $0) })
        XCTAssertEqual(dayStatus[.alcohol]?.deniedCoverage, 1)
        let next = PC.Exposures.daySummary(revisions: [], events: [], envelopes: [], bouts: [],
                                           identity: Self.identity("2026-10-02"), mode: .retrospective,
                                           cutoff: Self.d0 + 70 * Self.h, config: .init())
        XCTAssertTrue(next.categoryStatus.allSatisfy { $0.status == "unrecorded" })
        XCTAssertEqual(next.reasons, [PC.Exposures.noExposureRecords])
    }

    func testACandidateIsNeverPromotedToConfirmed() {
        let proposed = Self.rev("p1", kind: .meal, label: "meal?", at: Self.d0 + 12 * Self.h,
                                receivedAt: Self.d0 + 12 * Self.h, source: .inferredCandidate,
                                confirmation: .confirmed)
        let events = PC.Exposures.current([proposed], mode: .retrospective, cutoff: 0)
        XCTAssertEqual(events.first?.confirmation, .candidate)
        let support = PC.Interval(Self.d0 + 13 * Self.h, Self.d0 + 13 * Self.h + 300)
        let meal = PC.Exposures.categoryStatus(for: support, events: events, config: .init())
            .first { $0.kind == .meal }
        XCTAssertEqual(meal?.status, "candidate_only")
        XCTAssertEqual(PC.Exposures.refs(for: support, events: events, config: .init()).first?.confirmation,
                       .candidate)
        let summary = PC.Exposures.daySummary(revisions: [proposed], events: events,
                                              envelopes: Self.hrEnvelopes(from: Self.d0 + 9 * Self.h,
                                                                          to: Self.d0 + 15 * Self.h),
                                              bouts: [], identity: Self.identity(), mode: .retrospective,
                                              cutoff: Self.d0 + 70 * Self.h, config: .init())
        XCTAssertTrue(summary.aligned.isEmpty, "a candidate is not aligned as if it happened")
        XCTAssertTrue(summary.reasons.contains(PC.Exposures.candidateNotConfirmed))
        // A person confirming it is a new revision from a confirming source.
        var confirmed = proposed
        confirmed.revision = 2
        confirmed.source = .userEntered
        XCTAssertEqual(PC.Exposures.current([proposed, confirmed], mode: .retrospective, cutoff: 0)
                        .first?.confirmation, .confirmed)
    }

    // MARK: - Refs

    func testRefsUseTheLookbackFromTheOccurrenceEnd() {
        let support = PC.Interval(Self.d0 + 96 * Self.h, Self.d0 + 96 * Self.h + 300)
        let inside = Self.rev("a", at: Self.d0 + 96 * Self.h + 100)
        let edge = Self.rev("b", at: support.start - 72 * Self.h - 1)          // ends exactly 72 h before
        let tooOld = Self.rev("c", at: support.start - 72 * Self.h - 2)        // ends 72 h + 1 s before
        let later = Self.rev("d", at: support.end + 10)
        let events = PC.Exposures.current([inside, edge, tooOld, later], mode: .retrospective, cutoff: 0)
        let refs = PC.Exposures.refs(for: support, events: events, config: .init())
        XCTAssertEqual(refs.map(\.eventId), ["a", "b"])
        XCTAssertEqual(refs.map(\.secondsSinceOccurrence), [0, 72 * 3600])
        XCTAssertEqual(refs.map(\.relation), ["overlaps", "precedes"])
    }

    // MARK: - Event-aligned summaries

    func testDayOnlyPrecisionGetsNoHourLevelAlignment() {
        let yes = Self.rev("j1", kind: .alcohol, label: "did you drink any alcohol?", at: Self.d0,
                           end: Self.d0 + 24 * Self.h, precision: .dayOnly, source: .journalDayAnswer)
        let wide = Self.rev("w1", kind: .medication, label: "ibuprofen", at: Self.d0 + 6 * Self.h,
                            end: Self.d0 + 11 * Self.h, precision: .approximate)
        let events = PC.Exposures.current([yes, wide], mode: .retrospective, cutoff: 0)
        let summary = PC.Exposures.daySummary(revisions: [yes, wide], events: events,
                                              envelopes: Self.hrEnvelopes(from: Self.d0, to: Self.d0 + 24 * Self.h),
                                              bouts: [], identity: Self.identity(), mode: .retrospective,
                                              cutoff: Self.d0 + 70 * Self.h, config: .init())
        let journal = summary.aligned.first { $0.eventId == "j1" }
        XCTAssertNotNil(journal)
        XCTAssertTrue(journal!.windows.isEmpty)
        XCTAssertTrue(journal!.reasons.contains(PC.Exposures.timeUncertain))
        XCTAssertTrue(journal!.reasons.contains(PC.Exposures.associationOnly))
        XCTAssertTrue(journal!.reasons.contains(PC.Exposures.pharmacologyNotModelled))
        // A 5 h range cannot be split into 3 h sides; the 24 h windows remain, around the whole range.
        let medication = summary.aligned.first { $0.eventId == "w1" }!
        XCTAssertEqual(medication.windows.map(\.widthS), [24 * 3600])
        XCTAssertTrue(medication.reasons.contains(PC.Exposures.timeUncertain))
        XCTAssertEqual(medication.windows[0].before, PC.Interval(Self.d0 - 18 * Self.h, Self.d0 + 6 * Self.h))
        XCTAssertEqual(medication.windows[0].after, PC.Interval(Self.d0 + 11 * Self.h, Self.d0 + 35 * Self.h))
        XCTAssertTrue(medication.windows[0].reasons.contains(PC.Exposures.windowPartiallySearched))
        XCTAssertEqual(medication.windows[0].beforeSearched, PC.Interval(Self.d0, Self.d0 + 6 * Self.h))
        // The overlapping journal "yes" is concurrent with the medication.
        XCTAssertEqual(medication.windows[0].concurrent.map(\.eventId), ["j1"])
    }

    func testAlignedWindowsDescribeMeasurementsWithConcurrentEventsAndBehaviourChange() throws {
        let coffee = Self.rev("c1", at: Self.d0 + 10 * Self.h, dose: 95, unit: "mg")
        let meal = Self.rev("m1", kind: .meal, label: "lunch", at: Self.d0 + 11 * Self.h)
        let denied = Self.rev("j1", kind: .alcohol, label: "alcohol", at: Self.d0, end: Self.d0 + 24 * Self.h,
                              precision: .dayOnly, source: .journalDayAnswer, confirmation: .denied)
        let events = PC.Exposures.current([coffee, meal, denied], mode: .retrospective, cutoff: 0)
        var envelopes = Self.hrEnvelopes(from: Self.d0 + 7 * Self.h, to: Self.d0 + 13 * Self.h)
        // One invalid measurement in the before window is left out and counted.
        envelopes.append(Self.envelope(start: Self.d0 + 8 * Self.h, width: 60, value: 140, state: .invalid))
        let walk = PC.ExertionBout(id: "b1", interval: PC.Interval(Self.d0 + 10 * Self.h + 1800, Self.d0 + 11 * Self.h),
                                   day: Self.day, kind: "walking", status: .complete, durationS: 1800)
        let summary = PC.Exposures.daySummary(revisions: [coffee, meal, denied], events: events,
                                              envelopes: envelopes, bouts: [walk], identity: Self.identity(),
                                              mode: .retrospective, cutoff: Self.d0 + 70 * Self.h, config: .init())
        let c = try XCTUnwrap(summary.aligned.first { $0.eventId == "c1" })
        XCTAssertEqual(c.windows.map(\.widthS), [3 * 3600, 24 * 3600])
        XCTAssertTrue(c.reasons.contains(PC.Exposures.associationOnly))
        XCTAssertTrue(c.reasons.contains(PC.Exposures.concurrentEvents))
        let w3 = c.windows[0]
        // Before [07:00, 10:00): 36 five-minute windows; after [10:00:01, 13:00:01): 10:05 … 12:55 = 35. The
        // window holding the coffee second belongs to neither side.
        let hr = try XCTUnwrap(w3.metrics.first { $0.methodId == "context.heart_rate.5min_mean" })
        XCTAssertEqual(hr.beforeCount, 36)
        XCTAssertEqual(hr.afterCount, 35)
        XCTAssertEqual(hr.excludedCount, 1)
        // Values cycle 60…64 by index; 36 before (indices 0…35) → median 62; after (37…71) → median 62.
        XCTAssertEqual(hr.beforeMedian, 62)
        XCTAssertEqual(hr.afterMedian, 62)
        XCTAssertTrue(hr.reasons.isEmpty)
        // The meal is concurrent; the denied alcohol is not an occurrence and is not listed.
        XCTAssertEqual(w3.concurrent.map(\.eventId), ["m1"])
        XCTAssertTrue(w3.reasons.contains(PC.Exposures.concurrentEvents))
        // 30 min of walking after, none before → behaviour change is reported as confounding.
        XCTAssertEqual(w3.behavior.beforeBoutS, 0)
        XCTAssertEqual(w3.behavior.afterBoutS, 1800)
        XCTAssertTrue(w3.reasons.contains(PC.Exposures.behaviorChange))
        XCTAssertFalse(w3.reasons.contains(PC.Exposures.insufficientMeasurements))
        XCTAssertTrue(c.reasons.contains(PC.Exposures.pharmacologyNotModelled))
        // The 24 h window reaches outside the day and the document says so.
        XCTAssertTrue(c.windows[1].reasons.contains(PC.Exposures.windowPartiallySearched))
        // No reason or field names an effect.
        let json = String(decoding: try PC.encoder().encode(summary), as: UTF8.self)
        for word in ["effect", "caused", "causal", "improv", "worse"] {
            XCTAssertFalse(json.lowercased().contains(word), "summary JSON contains \(word)")
        }
    }

    func testCausalAlignmentStopsAtTheCutoffAndThinDataIsInsufficient() {
        let coffee = Self.rev("c1", at: Self.d0 + 10 * Self.h, receivedAt: Self.d0 + 10 * Self.h + 60)
        let events = PC.Exposures.current([coffee], mode: .causalLive, cutoff: Self.d0 + 10 * Self.h + 600)
        let envelopes = Self.hrEnvelopes(from: Self.d0 + 9 * Self.h, to: Self.d0 + 10 * Self.h + 300)
        let summary = PC.Exposures.daySummary(revisions: [coffee], events: events, envelopes: envelopes, bouts: [],
                                              identity: Self.identity(), mode: .causalLive,
                                              cutoff: Self.d0 + 10 * Self.h + 600, config: .init())
        let w3 = summary.aligned[0].windows[0]
        XCTAssertEqual(w3.afterSearched, PC.Interval(Self.d0 + 10 * Self.h + 1, Self.d0 + 10 * Self.h + 600))
        XCTAssertTrue(w3.reasons.contains(PC.Exposures.windowPartiallySearched))
        XCTAssertEqual(w3.metrics.first?.afterCount, 0)
        XCTAssertTrue(w3.reasons.contains(PC.Exposures.insufficientMeasurements))
        XCTAssertTrue(w3.reasons.contains(PC.Exposures.behaviorUnobserved))
        XCTAssertTrue(summary.aligned[0].reasons.contains(PC.Exposures.insufficientMeasurements))
        XCTAssertEqual(summary.revisionsNotYetAvailable, 0)
    }

    func testRegimeChangeAcrossTheEventIsFlagged() {
        let coffee = Self.rev("c1", at: Self.d0 + 10 * Self.h)
        let events = PC.Exposures.current([coffee], mode: .retrospective, cutoff: 0)
        let envelopes = Self.hrEnvelopes(from: Self.d0 + 7 * Self.h, to: Self.d0 + 10 * Self.h, regime: "wrist")
            + Self.hrEnvelopes(from: Self.d0 + 10 * Self.h + 300, to: Self.d0 + 13 * Self.h, regime: "bicep")
        let summary = PC.Exposures.daySummary(revisions: [coffee], events: events, envelopes: envelopes, bouts: [],
                                              identity: Self.identity(), mode: .retrospective,
                                              cutoff: Self.d0 + 70 * Self.h, config: .init())
        let w3 = summary.aligned[0].windows[0]
        XCTAssertTrue(w3.reasons.contains(PC.Exposures.regimeChange))
        XCTAssertTrue(w3.metrics[0].reasons.contains(PC.Exposures.regimeChange))
    }

    // MARK: - Determinism and coding

    func testOrderIsDeterministicAndOlderSummariesDecode() throws {
        let revisions = [
            Self.rev("b", at: Self.d0 + 9 * Self.h), Self.rev("a", at: Self.d0 + 9 * Self.h),
            Self.rev("c", at: Self.d0 + 8 * Self.h), Self.rev("a", 2, at: Self.d0 + 9 * Self.h, dose: 50),
        ]
        let one = PC.Exposures.current(revisions, mode: .retrospective, cutoff: 0)
        let two = PC.Exposures.current(revisions.reversed(), mode: .retrospective, cutoff: 0)
        XCTAssertEqual(one, two)
        XCTAssertEqual(one.map(\.eventId), ["c", "a", "b"])
        // Non-finite doses never reach the encoder.
        let nan = PC.Exposures.current([Self.rev("n", at: Self.d0, dose: .nan, unit: "mg")], mode: .retrospective,
                                       cutoff: 0)
        XCTAssertNil(nan.first?.doseAmount)
        XCTAssertNoThrow(try PC.encoder().encode(nan))

        let skeleton = #"{"category_status":[],"events":[],"reasons":[],"revisions_not_yet_available":0}"#
        let old = try PC.decoder().decode(PC.ExposureDaySummary.self, from: Data(skeleton.utf8))
        XCTAssertEqual(old, .empty)
        let config = try PC.decoder().decode(PC.ExposureConfig.self, from: Data(#"{"lookback_h":48}"#.utf8))
        XCTAssertEqual(config.lookbackH, 48)
        XCTAssertEqual(config.alignedWindowsH, [3, 24])
        let roundTrip = try PC.decoder().decode(PC.ExposureConfig.self, from: PC.encoder().encode(PC.ExposureConfig()))
        XCTAssertEqual(roundTrip, PC.ExposureConfig())
        XCTAssertEqual(Set(PC.Exposures.reasonCodes).count, PC.Exposures.reasonCodes.count)
    }
}
