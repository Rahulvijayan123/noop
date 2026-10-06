import XCTest
@testable import StrandAnalytics

/// System D: bouts from heart-rate independent evidence, response, recovery and censoring (V07, V08).
/// Every expected number is worked out by hand from the piecewise-constant fixture in the comments, not read back
/// from the implementation.
final class PCExertionBoutsTests: XCTestCase {
    typealias PC = PhysiologyContext

    static let day = "2026-10-01"
    static let identity = PC.DayIdentity(deviceScope: "dev-1", day: day, timezoneId: "UTC",
                                         dayWindow: PC.Engine.dayInterval(day, timezoneId: "UTC"))
    static var dayStart: Int { identity.dayWindow.start }
    /// 10:00 local (UTC).
    static var t0: Int { dayStart + 10 * 3600 }
    static var retroCutoff: Int { identity.dayWindow.end + 40 * 3600 }

    // MARK: Fixture builders

    static func track(_ segs: [(Int, Int, String?)], source: PC.ActivitySource = .strapMotion) -> PC.ResolvedTrack {
        PC.IntervalAlgebra.resolve(segs.enumerated().map { i, s in
            PC.LabelRecord(interval: .init(s.0, s.1), label: s.2, tieBreak: "r\(i)")
        }, source: source, heartRateDependent: false)
    }

    /// 1 Hz samples, piecewise constant over `[start, end)`.
    static func heart(_ segs: [(Int, Int, Int)]) -> [PC.HeartRateObservation] {
        segs.flatMap { s in (s.0..<s.1).map { PC.HeartRateObservation(ts: $0, bpm: s.2) } }
    }

    static func detect(strap: PC.ResolvedTrack, hart: PC.ResolvedTrack = .empty(.hartEpochs),
                       hr: [PC.HeartRateObservation], workouts: [PC.WorkoutInput] = [], breaks: [PC.Interval] = [],
                       steps: [PC.StepObservation] = [], mode: PC.ProcessingMode = .retrospective,
                       cutoff: Int? = nil, config: PC.ExertionConfig = .init()) -> [PC.ExertionBout] {
        PC.ExertionBouts.detect(identity: identity, hart: hart, strap: strap, workouts: workouts,
                                observations: PC.SanitizedObservations(heartRate: hr, steps: steps, breaks: breaks),
                                mode: mode, cutoff: cutoff ?? retroCutoff, config: config)
    }

    /// Still 30 min, stepping 10 min [t0, t0+600), still afterwards. HR 70 before, 110 during, then
    /// 95 [end, end+90), 85 [end+90, end+200), 75 [end+200, end+450), 72 after.
    static let end = t0 + 600
    static func standardTrack(after: [(Int, Int, String?)]? = nil) -> PC.ResolvedTrack {
        track([(t0 - 1800, t0, "still"), (t0, end, "stepping")] + (after ?? [(end, end + 3600, "still")]))
    }
    static func standardHeart() -> [PC.HeartRateObservation] {
        heart([(t0 - 1800, t0, 70), (t0, end, 110), (end, end + 90, 95), (end + 90, end + 200, 85),
               (end + 200, end + 450, 75), (end + 450, end + 3000, 72)])
    }

    // MARK: Detection is heart-rate independent

    func testHeartRateRiseWithoutLocomotionCreatesNoBout() {
        // HR jumps 70 → 130 for 20 minutes while the strap says still throughout, and the HR-threshold workout
        // detector reported a workout over the rise. Neither is locomotion evidence.
        let t0 = Self.t0
        let hr = Self.heart([(t0 - 3600, t0, 70), (t0, t0 + 1200, 130), (t0 + 1200, t0 + 7200, 70)])
        let detected = PC.WorkoutInput(id: "auto-1", interval: .init(t0, t0 + 1200), source: "detected")
        XCTAssertEqual(Self.detect(strap: Self.track([(t0 - 3600, t0 + 7200, "still")]), hr: hr,
                                   workouts: [detected]), [])
        XCTAssertEqual(Self.detect(strap: .empty(.strapMotion), hr: hr, workouts: [detected]), [])
    }

    func testDetectedWorkoutIsAnnotationNotSource() {
        let t0 = Self.t0
        let detected = PC.WorkoutInput(id: "auto-1", interval: .init(t0 - 120, t0 + 300), source: "detected")
        let bouts = Self.detect(strap: Self.standardTrack(), hr: Self.standardHeart(), workouts: [detected])
        XCTAssertEqual(bouts.count, 1)
        XCTAssertEqual(bouts[0].interval, .init(t0, Self.end))           // the detected start is not used
        XCTAssertEqual(bouts[0].kind, "stepping")
        XCTAssertTrue(bouts[0].reasons.contains(PC.ExertionBouts.overlapsDetectedWorkout))
        XCTAssertEqual(bouts[0].workoutIds, [])
    }

    // MARK: A complete bout

    func testWalkingBoutResponseAndCompleteRecovery() throws {
        let bouts = Self.detect(strap: Self.standardTrack(), hr: Self.standardHeart())
        XCTAssertEqual(bouts.count, 1)
        let b = bouts[0]
        XCTAssertEqual(b.id, PC.fnv1a("bout|dev-1|\(Self.t0)"))
        XCTAssertEqual(b.interval, .init(Self.t0, Self.end))
        XCTAssertEqual(b.day, Self.day)
        XCTAssertEqual(b.kind, "stepping")
        XCTAssertEqual(b.status, .complete)
        XCTAssertEqual(b.durationS, 600)
        XCTAssertEqual(b.locomotionS, 600)
        XCTAssertEqual(b.finality, .final)
        XCTAssertEqual(b.confidence.kind, .heuristicScore)
        XCTAssertEqual(try XCTUnwrap(b.confidence.value), 1.0, accuracy: 1e-12)
        XCTAssertEqual(b.sourceEvidence, ["strap_motion"])
        XCTAssertEqual(b.pauses, [])
        let comp = try XCTUnwrap(b.composition)
        XCTAssertEqual(comp.dominantLabel, "stepping")
        XCTAssertTrue(PC.IntervalAlgebra.reconciles(comp))

        // Pre-bout: 1800 s of stillness fills the lookback; reference = median of 70s over [t0-180, t0-30).
        let pre = try XCTUnwrap(b.preBout)
        XCTAssertEqual(pre.state, "rested")
        XCTAssertEqual(pre.preceding.stillRunS, 1800)
        XCTAssertEqual(pre.hrWindow, .init(Self.t0 - 180, Self.t0 - 30))
        XCTAssertEqual(pre.hrSamples, 150)
        XCTAssertEqual(pre.hrReferenceBpm, 70)

        // Response: median 110, p95 110, rise +40 bpm; respiratory response explicitly unavailable.
        let r = try XCTUnwrap(b.response)
        XCTAssertEqual(r.hrMedianBpm, 110)
        XCTAssertEqual(r.hrPeakBpm, 110)
        XCTAssertEqual(r.hrRiseBpm, 40)
        XCTAssertEqual(r.hrPeakRiseBpm, 40)
        XCTAssertEqual(r.endHrBpm, 110)
        XCTAssertEqual(r.hrCoverage, 1, accuracy: 1e-12)
        XCTAssertEqual(r.respiratory.state, .unavailable)
        XCTAssertEqual(r.respiratory.reasons, [PC.ExertionBouts.respirationUnavailableDuringMovement])

        // Recovery: +60 → 95 (decline 15, 15/40), +120 → 85 (25, 25/40), +300 → 75 (35, 35/40),
        // +600 → 72 (38, 38/40). 75 - 70 = 5 ≤ 5 → returned at +300.
        let rec = try XCTUnwrap(b.recovery)
        XCTAssertEqual(rec.censoring, [])
        XCTAssertNil(rec.truncatedAt)
        let expected: [(Int, Double, Double, Double)] = [(60, 95, 15, 0.375), (120, 85, 25, 0.625),
                                                         (300, 75, 35, 0.875), (600, 72, 38, 0.95)]
        XCTAssertEqual(rec.observations.map(\.offsetS), expected.map(\.0))
        for (o, e) in zip(rec.observations, expected) {
            XCTAssertEqual(o.state, .observed)
            XCTAssertEqual(o.samples, 31)
            XCTAssertEqual(o.hrBpm, e.1)
            XCTAssertEqual(o.declineBpm, e.2)
            XCTAssertEqual(try XCTUnwrap(o.fractionRecovered), e.3, accuracy: 1e-12)
            XCTAssertEqual(o.window, .init(Self.end + o.offsetS - 15, Self.end + o.offsetS + 16))
        }
        XCTAssertEqual(rec.timeToReturnS, 300)
        XCTAssertEqual(rec.hrv.state, .unavailable)
        XCTAssertEqual(rec.respiratory.state, .unavailable)

        let key = try XCTUnwrap(b.matchKey)
        XCTAssertEqual(key.key, "stepping.cadence_unavailable.d600_1800s.rested")
        XCTAssertEqual(key.workloadLimitations, ["speed_unavailable", "grade_unavailable",
                                                 "external_load_unavailable", "ambient_unavailable"])
        XCTAssertEqual(b.cadence?.state, .unavailable)
        XCTAssertTrue(b.cadence?.reasons.contains(PC.ExertionBouts.cadenceUnavailable) ?? false)
    }

    // MARK: V07 — disconnect, continued movement, cutoff

    func testV07RecoveryInterruptedByDisconnectIsCensoredWithoutTimeToReturn() throws {
        let end = Self.end
        let hr = Self.standardHeart().filter { !($0.ts >= end + 100 && $0.ts < end + 400) }
        let bouts = Self.detect(strap: Self.standardTrack(), hr: hr, breaks: [.init(end + 100, end + 400)])
        let rec = try XCTUnwrap(bouts.first?.recovery)
        // Last sample before the gap is end+99: the follow-up is truncated there.
        XCTAssertEqual(rec.truncatedAt, end + 99)
        XCTAssertEqual(rec.censoring.first, PC.ExertionBouts.censorDisconnect)
        XCTAssertEqual(rec.observations.map(\.state), [.observed, .censored, .censored, .censored])
        XCTAssertEqual(rec.observations[0].hrBpm, 95)                    // window ends at end+75 < end+99
        XCTAssertTrue(rec.observations.dropFirst().allSatisfy { $0.hrBpm == nil && $0.reasons == ["disconnect"] })
        XCTAssertNil(rec.timeToReturnS)                                    // 95 is 25 above the reference
        XCTAssertEqual(bouts[0].status, .censored)
        // RC-06: the censoring cause is the first reason (the history row shows `reasons.first`).
        XCTAssertEqual(bouts[0].reasons.first, PC.ExertionBouts.censorDisconnect)
        XCTAssertEqual(Array(bouts[0].reasons.dropFirst()), bouts[0].reasons.dropFirst().sorted())
        // The response is kept although recovery is censored.
        XCTAssertEqual(bouts[0].response?.hrRiseBpm, 40)
    }

    func testV07WorkoutEndingInsideADisconnectHasNoRecoveryAtAll() throws {
        // Logged workout [t0, t0+900); stepping [t0, t0+600); every stream is missing over [t0+600, t0+1500)
        // (recorded break), so neither the end HR nor any follow-up reading exists.
        let t0 = Self.t0
        let strap = Self.track([(t0 - 1800, t0, "still"), (t0, t0 + 600, "stepping"),
                                (t0 + 1500, t0 + 4000, "still")])
        let hr = Self.heart([(t0 - 1800, t0, 70), (t0, t0 + 600, 110), (t0 + 1500, t0 + 4000, 75)])
        let workout = PC.WorkoutInput(id: "w1", interval: .init(t0, t0 + 900), kind: "run", source: "manual")
        let bouts = Self.detect(strap: strap, hr: hr, workouts: [workout], breaks: [.init(t0 + 600, t0 + 1500)])
        XCTAssertEqual(bouts.count, 1)
        let b = bouts[0]
        XCTAssertEqual(b.interval, .init(t0, t0 + 900))
        XCTAssertEqual(b.kind, "workout")
        XCTAssertEqual(b.workoutIds, ["w1"])
        XCTAssertEqual(b.sourceEvidence, ["strap_motion", "logged_workout"])
        XCTAssertEqual(b.confidence, .notApplicable)
        XCTAssertEqual(b.status, .censored)
        XCTAssertNil(b.response?.endHrBpm)
        XCTAssertTrue(b.reasons.contains(PC.ExertionBouts.endedAtEvidenceGap))
        let rec = try XCTUnwrap(b.recovery)
        XCTAssertEqual(rec.truncatedAt, t0 + 900)
        XCTAssertEqual(rec.censoring, [PC.ExertionBouts.censorDisconnect])
        XCTAssertTrue(rec.observations.allSatisfy { $0.state == .censored && $0.hrBpm == nil })
        XCTAssertNil(rec.timeToReturnS)
        XCTAssertNil(rec.anchorHrBpm)
    }

    func testV07ContinuedMovementAfterCessationTruncatesRecovery() throws {
        // Stops for 90 s (> 60 s pause, so the walk has ended), then 40 s of stepping (too short for a bout).
        let end = Self.end
        let strap = Self.standardTrack(after: [(end, end + 90, "still"), (end + 90, end + 130, "stepping"),
                                               (end + 130, end + 3600, "still")])
        let bouts = Self.detect(strap: strap, hr: Self.standardHeart())
        XCTAssertEqual(bouts.count, 1)
        let rec = try XCTUnwrap(bouts[0].recovery)
        XCTAssertEqual(rec.truncatedAt, end + 90)
        XCTAssertEqual(rec.censoring, [PC.ExertionBouts.censorContinuedMovement])
        XCTAssertEqual(rec.observations.map(\.state), [.observed, .censored, .censored, .censored])
        XCTAssertEqual(rec.observations[0].hrBpm, 95)
        XCTAssertEqual(rec.observations[1].reasons, [PC.ExertionBouts.censorContinuedMovement])
        XCTAssertNil(rec.timeToReturnS)
        XCTAssertEqual(bouts[0].status, .censored)
    }

    func testV07FollowUpBeyondTheCausalCutoffIsCensoredAndProvisional() throws {
        let end = Self.end
        let cutoff = end + 200
        let strap = Self.track([(Self.t0 - 1800, Self.t0, "still"), (Self.t0, end, "stepping"),
                                (end, cutoff, "still")])
        let hr = Self.standardHeart().filter { $0.ts < cutoff }
        let bouts = Self.detect(strap: strap, hr: hr, mode: .causalLive, cutoff: cutoff)
        let b = try XCTUnwrap(bouts.first)
        XCTAssertEqual(b.status, .censored)
        XCTAssertEqual(b.finality, .provisional)
        let rec = try XCTUnwrap(b.recovery)
        XCTAssertEqual(rec.truncatedAt, cutoff)
        XCTAssertEqual(rec.censoring, [PC.ExertionBouts.censorCutoffReached])
        // +60 and +120 windows end at end+76 / end+136, before the cutoff; +300 and +600 are not observable yet.
        XCTAssertEqual(rec.observations.map(\.state), [.observed, .observed, .censored, .censored])
        XCTAssertEqual(rec.observations.map(\.hrBpm), [95, 85, nil, nil])
        XCTAssertNil(rec.timeToReturnS)
        let values = PC.ExertionBouts.dailyValues(bouts, identity: Self.identity, regimeKey: "r",
                                                  mode: .causalLive, config: .init())
        XCTAssertFalse(values.isEmpty)
        XCTAssertTrue(values.allSatisfy { $0.finality == .provisional && $0.mode == .causalLive })
    }

    func testBoutReachingTheCutoffIsOngoingWithResponseButNoRecovery() throws {
        let t0 = Self.t0
        let cutoff = t0 + 300
        let strap = Self.track([(t0 - 1800, t0, "still"), (t0, cutoff, "stepping")])
        let hr = Self.standardHeart().filter { $0.ts < cutoff }
        let bouts = Self.detect(strap: strap, hr: hr, mode: .causalLive, cutoff: cutoff)
        let b = try XCTUnwrap(bouts.first)
        XCTAssertEqual(b.status, .ongoing)
        XCTAssertEqual(b.interval, .init(t0, cutoff))
        XCTAssertNil(b.recovery)
        XCTAssertEqual(b.finality, .provisional)
        XCTAssertEqual(b.reasons.first, PC.ExertionBouts.boutOngoing, "the status reason leads")
        XCTAssertEqual(b.response?.hrRiseBpm, 40)
        // An unfinished bout contributes no matched response value and no recovery value.
        XCTAssertEqual(PC.ExertionBouts.dailyValues(bouts, identity: Self.identity, regimeKey: "r",
                                                    mode: .causalLive, config: .init()), [])
    }

    // MARK: V08 — nearby bouts and overlapping recovery windows

    static func twoBouts() -> (PC.ResolvedTrack, [PC.HeartRateObservation], [PC.LabelRecord]) {
        // A = stepping [t0, t0+300), still 200 s, B = stepping [t0+500, t0+800), still afterwards.
        // HR 70 before, 110 in A, 90 between, 110 in B, 80 after B.
        let t0 = Self.t0
        let records = [(t0 - 1800, t0, "still"), (t0, t0 + 300, "stepping"), (t0 + 300, t0 + 500, "still"),
                       (t0 + 500, t0 + 800, "stepping"), (t0 + 800, t0 + 3000, "still")].enumerated().map { i, s in
            PC.LabelRecord(interval: .init(s.0, s.1), label: s.2, tieBreak: "r\(i)")
        }
        let track = PC.IntervalAlgebra.resolve(records, source: .strapMotion, heartRateDependent: false)
        let hr = heart([(t0 - 1800, t0, 70), (t0, t0 + 300, 110), (t0 + 300, t0 + 500, 90),
                        (t0 + 500, t0 + 800, 110), (t0 + 800, t0 + 3000, 80)])
        return (track, hr, records)
    }

    func testV08EarlierRecoveryEndsAtTheNextBoutAndEachOutcomeCountsOnce() throws {
        let t0 = Self.t0
        let (track, hr, _) = Self.twoBouts()
        let bouts = Self.detect(strap: track, hr: hr)
        XCTAssertEqual(bouts.map(\.interval), [.init(t0, t0 + 300), .init(t0 + 500, t0 + 800)])
        let a = bouts[0], b = bouts[1]
        XCTAssertNotEqual(a.id, b.id)

        // A: truncated at B's start (B's first stepping second is also movement; next_bout wins the tie).
        let ra = try XCTUnwrap(a.recovery)
        XCTAssertEqual(ra.truncatedAt, t0 + 500)
        XCTAssertEqual(ra.censoring.first, PC.ExertionBouts.censorNextBout)
        XCTAssertEqual(ra.observations.map(\.state), [.observed, .observed, .censored, .censored])
        XCTAssertEqual(ra.observations.map(\.hrBpm), [90, 90, nil, nil])
        XCTAssertEqual(ra.observations[0].declineBpm, 20)                  // 110 - 90
        XCTAssertEqual(try XCTUnwrap(ra.observations[0].fractionRecovered), 0.5, accuracy: 1e-12)
        for o in ra.observations where o.state == .observed {
            XCTAssertLessThanOrEqual(o.window.end, b.interval.start)       // no reading uses B's time
        }
        XCTAssertEqual(a.status, .censored)

        // B: its pre-bout window [t0+320, t0+470) lies in A's recovery → recent_bout, reference 90.
        let pb = try XCTUnwrap(b.preBout)
        XCTAssertEqual(pb.state, "recent_bout")
        XCTAssertEqual(pb.previousBoutId, a.id)
        XCTAssertEqual(pb.secondsSincePreviousBout, 200)
        XCTAssertEqual(pb.hrReferenceBpm, 90)
        XCTAssertTrue(pb.reasons.contains(PC.ExertionBouts.preBoutInPriorRecovery))
        XCTAssertEqual(b.response?.hrRiseBpm, 20)
        let rb = try XCTUnwrap(b.recovery)
        XCTAssertEqual(rb.censoring, [])
        XCTAssertEqual(rb.observations.map(\.hrBpm), [80, 80, 80, 80])
        XCTAssertEqual(rb.timeToReturnS, 60)                                // 80 is below the (elevated) reference
        XCTAssertEqual(b.status, .complete)

        // Daily values: the two bouts have different match keys (preceding state differs); the first-offset
        // decline pools both, each bout once: median(20, 30) = 25.
        let values = PC.ExertionBouts.dailyValues(bouts, identity: Self.identity, regimeKey: "r",
                                                  mode: .retrospective, config: .init())
        let byKey = Dictionary(uniqueKeysWithValues: values.map { ($0.seriesKey, $0) })
        XCTAssertEqual(byKey["hr_response.stepping.cadence_unavailable.d180_600s.rested"]?.value, 40)
        XCTAssertEqual(byKey["hr_response.stepping.cadence_unavailable.d180_600s.rested"]?.sourceIds, [a.id])
        XCTAssertEqual(byKey["hr_response.stepping.cadence_unavailable.d180_600s.recent_bout"]?.value, 20)
        let recovery = try XCTUnwrap(byKey["hr_recovery_60s.stepping"])
        XCTAssertEqual(recovery.value, 25)
        XCTAssertEqual(recovery.supportCount, 2)
        XCTAssertEqual(recovery.supportUnit, "bout")
        XCTAssertEqual(recovery.sourceIds, [a.id, b.id].sorted())
        XCTAssertEqual(recovery.finality, .final)
        // Feeding the same bouts twice (e.g. history + today) does not count an outcome twice.
        let doubled = PC.ExertionBouts.dailyValues(bouts + bouts, identity: Self.identity, regimeKey: "r",
                                                   mode: .retrospective, config: .init())
        XCTAssertEqual(doubled, values)
    }

    func testV08IdsAndResultsAreStableAcrossRerunsAndInputOrder() {
        let (_, hr, records) = Self.twoBouts()
        let forward = Self.detect(strap: PC.IntervalAlgebra.resolve(records, source: .strapMotion,
                                                                     heartRateDependent: false), hr: hr)
        let shuffled = Self.detect(strap: PC.IntervalAlgebra.resolve(records.reversed(), source: .strapMotion,
                                                                      heartRateDependent: false),
                                   hr: hr.reversed())
        XCTAssertEqual(forward, shuffled)
        XCTAssertEqual(forward, Self.detect(strap: PC.IntervalAlgebra.resolve(records, source: .strapMotion,
                                                                               heartRateDependent: false), hr: hr))
        XCTAssertEqual(forward.map(\.id), [PC.fnv1a("bout|dev-1|\(Self.t0)"), PC.fnv1a("bout|dev-1|\(Self.t0 + 500)")])
    }

    // MARK: Segmentation

    func testShortPauseMergesButNotAcrossABreak() throws {
        let t0 = Self.t0
        let strap = Self.track([(t0 - 1800, t0, "still"), (t0, t0 + 200, "stepping"), (t0 + 200, t0 + 230, "still"),
                                (t0 + 230, t0 + 400, "stepping"), (t0 + 400, t0 + 2000, "still")])
        let hr = Self.heart([(t0 - 1800, t0 + 2000, 80)])
        let merged = Self.detect(strap: strap, hr: hr)
        XCTAssertEqual(merged.map(\.interval), [.init(t0, t0 + 400)])
        XCTAssertEqual(merged[0].pauses, [.init(t0 + 200, t0 + 230)])
        XCTAssertEqual(merged[0].locomotionS, 370)
        XCTAssertEqual(try XCTUnwrap(merged[0].confidence.value), 370.0 / 400.0, accuracy: 1e-12)

        let split = Self.detect(strap: strap, hr: hr, breaks: [.init(t0 + 210, t0 + 215)])
        XCTAssertEqual(split.map(\.interval), [.init(t0, t0 + 200), .init(t0 + 230, t0 + 400)])
        XCTAssertEqual(split[0].recovery?.truncatedAt, t0 + 210)
        XCTAssertEqual(split[0].recovery?.censoring.first, PC.ExertionBouts.censorDisconnect)
    }

    func testLocomotionShorterThanTheMinimumIsNotABout() {
        let t0 = Self.t0
        let strap = Self.track([(t0 - 600, t0, "still"), (t0, t0 + 45, "stepping"), (t0 + 45, t0 + 600, "still")])
        XCTAssertEqual(Self.detect(strap: strap, hr: Self.heart([(t0 - 600, t0 + 600, 90)])), [])
    }

    func testLoggedWorkoutAbsorbsOverlappingLocomotion() throws {
        let t0 = Self.t0
        let workout = PC.WorkoutInput(id: "w1", interval: .init(t0 + 100, t0 + 700), kind: "walk", source: "manual")
        let strap = Self.track([(t0 - 1800, t0, "still"), (t0, t0 + 600, "stepping"),
                                (t0 + 600, t0 + 3000, "still")])
        let bouts = Self.detect(strap: strap, hr: Self.heart([(t0 - 1800, t0 + 3000, 80)]), workouts: [workout])
        XCTAssertEqual(bouts.map(\.interval), [.init(t0, t0 + 700)])
        XCTAssertEqual(bouts[0].kind, "workout")
        XCTAssertEqual(bouts[0].locomotionS, 600)
        XCTAssertEqual(bouts[0].workoutIds, ["w1"])
        // The logged workout type is part of the match key, so a walk is not pooled with other workout types.
        XCTAssertEqual(bouts[0].matchKey?.activityKind, "workout_walk")
        let values = PC.ExertionBouts.dailyValues(bouts, identity: Self.identity, regimeKey: "r",
                                                  mode: .retrospective, config: .init())
        XCTAssertTrue(values.contains { $0.seriesKey == "hr_recovery_60s.workout_walk" })
    }

    func testHartLabelsWinWhereConfidentAndStrapFillsTheRest() throws {
        // HART says walking over [t0, t0+300) only; the strap covers everything and says stepping over
        // [t0, t0+600). Merged evidence: walking 300 s (HART) + stepping 300 s (strap) → mixed kind.
        let t0 = Self.t0
        let hart = Self.track([(t0, t0 + 300, "walking")], source: .hartEpochs)
        let bouts = Self.detect(strap: Self.standardTrack(), hart: hart, hr: Self.standardHeart())
        XCTAssertEqual(bouts.count, 1)
        XCTAssertEqual(bouts[0].interval, .init(t0, t0 + 600))
        XCTAssertEqual(bouts[0].kind, "mixed_locomotion")
        XCTAssertEqual(bouts[0].sourceEvidence, ["hart_epochs", "strap_motion"])
        XCTAssertTrue(bouts[0].reasons.contains(PC.ExertionBouts.mergedHartAndStrap))
        let hartLocomotion = bouts[0].evidenceSeconds.first { $0.name == "hart_epochs_locomotion_s" }?.value
        XCTAssertEqual(hartLocomotion, 300)
    }

    func testDayOwnershipIsTheLocalDayOfTheStart() {
        let ds = Self.dayStart, de = Self.identity.dayWindow.end
        // [ds-300, ds+300) started yesterday; [de-100, de+500) started today and runs past midnight.
        let strap = Self.track([(ds - 2400, ds - 300, "still"), (ds - 300, ds + 300, "stepping"),
                                (ds + 300, de - 100, "still"), (de - 100, de + 500, "stepping"),
                                (de + 500, de + 3000, "still")])
        let bouts = Self.detect(strap: strap, hr: Self.heart([(ds - 2400, de + 3000, 80)]))
        XCTAssertEqual(bouts.map(\.interval), [.init(de - 100, de + 500)])
        XCTAssertEqual(bouts[0].day, Self.day)
    }

    // MARK: Cadence

    func testCadenceFromTheStepCounter() throws {
        // Stepping [t0, t0+180). Counter increments per second: +2 in minute 1, +1 in minute 2, +2 in minute 3
        // (walk class), 0 otherwise (still class). Steps/min: 120, 60, 120 → mean 100,
        // sample SD = sqrt((20² + 40² + 20²) / 2) = sqrt(1200), CV = sqrt(1200) / 100.
        let t0 = Self.t0
        var steps: [PC.StepObservation] = []
        var counter = 65400                                                 // wraps past 65535 in minute 2
        for ts in (t0 - 60)..<(t0 + 300) {
            let rate: Int
            switch ts - t0 {
            case 0..<60, 120..<180: rate = 2
            case 60..<120: rate = 1
            default: rate = 0
            }
            counter = (counter + rate) & 0xFFFF
            steps.append(.init(ts: ts, counter: counter, activityClass: rate > 0 ? 1 : 0))
        }
        let strap = Self.track([(t0 - 1800, t0, "still"), (t0, t0 + 180, "stepping"), (t0 + 180, t0 + 3000, "still")])
        let bouts = Self.detect(strap: strap, hr: Self.heart([(t0 - 1800, t0 + 3000, 90)]), steps: steps)
        let c = try XCTUnwrap(bouts.first?.cadence)
        XCTAssertEqual(c.state, .supported)
        XCTAssertEqual(c.minutes, 3)
        XCTAssertEqual(try XCTUnwrap(c.stepsPerMinMean), 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(c.stepsPerMinCv), 1200.0.squareRoot() / 100, accuracy: 1e-9)
        XCTAssertEqual(c.reasons, [PC.ExertionBouts.uncalibratedStepCounter, PC.ExertionBouts.wristCadenceNotGaitSpeed])
        XCTAssertEqual(bouts[0].matchKey?.key, "stepping.c80_110.d180_600s.rested")
    }

    // MARK: Trailing windows and recent references

    func testTrailingWindowsReportPartialAndUnknownCoverage() throws {
        let ds = Self.dayStart
        let ts = ds + 43200                                                 // 12:00 today
        func bout(_ s: Int, _ e: Int, day: String) -> PC.ExertionBout {
            PC.ExertionBout(id: "b\(s)", interval: .init(s, e), day: day, kind: "walking", status: .complete,
                            durationS: e - s)
        }
        let b1 = bout(ds + 30000, ds + 30600, day: Self.day)                // ended 12 600 s before ts
        let b2 = bout(ds - 20000, ds - 19000, day: "2026-09-30")
        let b3 = bout(ds - 100000, ds - 99000, day: "2026-09-29")
        let b4 = bout(ds + 43000, ds + 43500, day: Self.day)                // in progress at ts
        let b5 = bout(ds - 300000, ds - 299000, day: "2026-09-27")          // older than 72 h
        let bouts = [b1, b2, b3, b4, b5, b1]                                // b1 duplicated
        let coverage = [
            PC.DayCoverage(day: "2026-09-30", interval: .init(ds - 86400, ds), observedS: 43200),
            PC.DayCoverage(day: Self.day, interval: .init(ds, ds + 86400), observedS: 30000,
                           observedIntervals: [.init(ds, ds + 21600), .init(ds + 50000, ds + 58400)]),
        ]
        let w = PC.ExertionBouts.windows(endingAt: ts, bouts: bouts, coverage: coverage, config: .init())
        XCTAssertEqual(w.map(\.windowH), [24, 48, 72])
        // 24 h = [ds-43200, ts): b1 600 + b2 1000 + b4 clipped 200.
        XCTAssertEqual(w[0].interval, .init(ds - 43200, ts))
        XCTAssertEqual(w[0].boutCount, 3)
        XCTAssertEqual(w[0].locomotionS, 1800)
        // Yesterday half overlapped and prorated: 43200 × 0.5 = 21600 within [0, 43200]; today exact 21600.
        XCTAssertEqual(w[0].observedS, 43200)
        XCTAssertEqual(w[0].observedLowerS, 21600)
        XCTAssertEqual(w[0].observedUpperS, 64800)
        XCTAssertEqual(w[0].reasons, [PC.ExertionBouts.observedProratedPartialDay])
        // 48 h and 72 h reach days without coverage: observed is unknown, never zero.
        XCTAssertEqual(w[1].boutCount, 4)
        XCTAssertEqual(w[1].locomotionS, 2800)
        XCTAssertNil(w[1].observedS)
        XCTAssertEqual(w[1].reasons, [PC.ExertionBouts.coverageUnknownForPartOfWindow])
        XCTAssertEqual(w[2].boutCount, 4)
        XCTAssertNil(w[2].observedS)

        let refs = PC.ExertionBouts.recentRefs(before: ts, bouts: bouts, config: .init())
        XCTAssertEqual(refs.map(\.boutId), [b1.id, b2.id, b3.id])
        XCTAssertEqual(refs.map(\.secondsBeforeMeasurement), [12600, 62200, 142200])
    }

    func testFullyObservedWindowWithoutMotionSaysSo() {
        let ds = Self.dayStart
        let coverage = [PC.DayCoverage(day: "2026-09-30", interval: .init(ds - 86400, ds), observedS: 0),
                        PC.DayCoverage(day: Self.day, interval: .init(ds, ds + 86400), observedS: 0,
                                       observedIntervals: [])]
        var config = PC.ExertionConfig()
        config.windowsH = [24]
        let w = PC.ExertionBouts.windows(endingAt: ds + 3600, bouts: [], coverage: coverage, config: config)
        XCTAssertEqual(w.first?.observedS, 0)
        XCTAssertEqual(w.first?.boutCount, 0)
        XCTAssertTrue(w.first?.reasons.contains(PC.ExertionBouts.noMotionObservedInWindow) ?? false)
    }

    // MARK: Encoding

    func testBoutsRoundTripThroughTheCanonicalCodersAndOldJSONDecodes() throws {
        let (track, hr, _) = Self.twoBouts()
        let bouts = Self.detect(strap: track, hr: hr)
        let data = try PC.encoder().encode(bouts)
        XCTAssertEqual(try PC.decoder().decode([PC.ExertionBout].self, from: data), bouts)
        // A bout written before the added fields existed still decodes, with defaults.
        let skeleton = PC.ExertionBout(id: "x", interval: .init(1, 2), day: Self.day, kind: "walking",
                                       status: .complete, durationS: 1)
        let old = #"{"day":"2026-10-01","duration_s":1,"id":"x","interval":{"end":2,"start":1},"kind":"walking","reasons":[],"status":"complete"}"#
        XCTAssertEqual(try PC.decoder().decode(PC.ExertionBout.self, from: Data(old.utf8)), skeleton)
        XCTAssertEqual(PC.ExertionBouts.reasonCodes.count, Set(PC.ExertionBouts.reasonCodes).count)
    }
}
