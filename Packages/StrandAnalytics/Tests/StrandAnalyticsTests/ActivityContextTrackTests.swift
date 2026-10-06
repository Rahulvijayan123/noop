import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Stored streams → decoder input → persisted document.
final class ActivityContextTrackTests: XCTestCase {

    private func run(_ sim: ActivitySim, sleep: [DayStateSpan] = [], workouts: [DayStateWorkout] = [],
                     offWrist: [DayStateSpan] = [], known: Bool = true) -> (ActivityContextTrack, ActivityContextTrackInput) {
        let input = sim.trackInput(sleep: sleep, workouts: workouts, offWrist: offWrist, sleepKnownOutsideSessions: known)
        return (ActivityContextTrackBuilder.build(input), input)
    }

    // MARK: Alignment of stored streams

    func testStoredStreamsDecodeLikeTheLiveStream() throws {
        var sim = ActivitySim()
        sim.still(30); sim.walk(70); sim.desk(120)
        let (track, input) = run(sim)
        let live = ActivityContextDecoder.runAll(sim.observations)
        // Step counter deltas rebuild the tick stream, so the two decode to the same labels.
        XCTAssertEqual(track.states.map(\.ts), live.map(\.ts))
        XCTAssertEqual(track.states.map(\.displayContext), live.map(\.displayContext))
        XCTAssertEqual(track.observedSeconds, sim.observations.count)
        XCTAssertEqual(track.lastTs, sim.observations.last?.ts)
        XCTAssertEqual(input.steps.count, sim.observations.count)
    }

    func testStepTicksAreCounterDeltasBoundedByTheGaitCeiling() {
        let t0 = 1_760_000_000
        let steps = [StepSample(ts: t0, counter: 100, activityClass: 0),
                     StepSample(ts: t0 + 1, counter: 102, activityClass: 1),
                     StepSample(ts: t0 + 2, counter: 120, activityClass: 1),      // bout credit: 18 ticks in 1 s
                     StepSample(ts: t0 + 3, counter: 65_530, activityClass: 1),   // sync-gap sized jump: rejected
                     StepSample(ts: t0 + 5, counter: 65_532, activityClass: 1),   // 2-s gap, 2 ticks
                     StepSample(ts: t0 + 9, counter: 65_540, activityClass: 1)]   // 4-s gap: not a per-second rate
        let obs = ActivityContextTrackBuilder.observations(for:
            ActivityContextTrackInput(dayStart: t0, dayEnd: t0 + 10, steps: steps))
        let ticks = Dictionary(uniqueKeysWithValues: obs.map { ($0.ts - t0, $0.stepTicks) })
        XCTAssertNil(ticks[0] ?? nil)
        XCTAssertEqual(ticks[1] ?? nil, 2)
        XCTAssertEqual(ticks[2] ?? nil, StepsCounter.maxTicksPerSecond)
        XCTAssertNil(ticks[3] ?? nil)
        XCTAssertEqual(ticks[5] ?? nil, 2)
        XCTAssertNil(ticks[9] ?? nil)
        XCTAssertEqual(obs.first { $0.ts == t0 + 1 }?.strapClass, 1)
    }

    func testSecondsWithoutAnyDataProduceNoObservation() {
        let t0 = 1_760_000_000
        let hr = [HRSample(ts: t0 + 3, bpm: 70), HRSample(ts: t0 + 4, bpm: 71), HRSample(ts: t0 + 9, bpm: 400)]
        let obs = ActivityContextTrackBuilder.observations(for:
            ActivityContextTrackInput(dayStart: t0, dayEnd: t0 + 20, hr: hr))
        XCTAssertEqual(obs.map { $0.ts - t0 }, [3, 4])
        XCTAssertTrue(obs.allSatisfy { $0.wear == .onWrist })
    }

    func testSamplesOutsideTheRequestedDayAreIgnored() {
        let t0 = 1_760_000_000
        let hr = [HRSample(ts: t0 - 5, bpm: 70), HRSample(ts: t0 + 5, bpm: 71), HRSample(ts: t0 + 50, bpm: 72)]
        let obs = ActivityContextTrackBuilder.observations(for:
            ActivityContextTrackInput(dayStart: t0, dayEnd: t0 + 20, hr: hr))
        XCTAssertEqual(obs.map { $0.ts - t0 }, [5])
    }

    func testSleepSpansBecomeAsleepAndOutsideIsAwakeOnlyWhenKnown() throws {
        let t0 = 1_760_000_000
        let hr = (0..<60).map { HRSample(ts: t0 + $0, bpm: 60) }
        let span = DayStateSpan(start: t0 + 20, end: t0 + 40)
        let known = ActivityContextTrackBuilder.observations(for:
            ActivityContextTrackInput(dayStart: t0, dayEnd: t0 + 60, hr: hr, sleep: [span], sleepKnownOutsideSessions: true))
        XCTAssertEqual(known[10].sleep, .awake)
        XCTAssertEqual(known[25].sleep, .asleep)
        XCTAssertEqual(known[45].sleep, .awake)
        let live = ActivityContextTrackBuilder.observations(for:
            ActivityContextTrackInput(dayStart: t0, dayEnd: t0 + 60, hr: hr, sleep: [span], sleepKnownOutsideSessions: false))
        XCTAssertEqual(live[10].sleep, .unknown)
        XCTAssertEqual(live[25].sleep, .asleep)
    }

    func testWorkoutsAndOffWristSpansAreMarked() throws {
        let t0 = 1_760_000_000
        let hr = (0..<80).map { HRSample(ts: t0 + $0, bpm: 90) }
        let obs = ActivityContextTrackBuilder.observations(for: ActivityContextTrackInput(
            dayStart: t0, dayEnd: t0 + 80, hr: hr,
            workouts: [DayStateWorkout(start: t0 + 10, end: t0 + 30, sport: "Run")],
            offWrist: [DayStateSpan(start: t0 + 50, end: t0 + 70)]))
        XCTAssertFalse(obs[5].loggedWorkout)
        XCTAssertTrue(obs[15].loggedWorkout)
        XCTAssertFalse(obs[35].loggedWorkout)
        XCTAssertEqual(obs[55].wear, .offWrist)
        XCTAssertNil(obs[55].hrBpm)   // an off-wrist second carries no sensor values
        XCTAssertEqual(obs[75].wear, .onWrist)
        XCTAssertEqual(obs.count, 80)
    }

    func testOffWristSpansWithNoRecordsStillPublishOffWristStates() throws {
        let t0 = 1_760_000_000
        var sim = ActivitySim(start: t0)
        sim.walk(60)
        let walkEnd = sim.ts
        let input = sim.trackInput(start: t0, end: walkEnd + 300,
                                   offWrist: [DayStateSpan(start: walkEnd, end: walkEnd + 300)])
        let track = ActivityContextTrackBuilder.build(input)
        let tail = track.states.filter { $0.ts >= walkEnd + 10 }
        XCTAssertFalse(tail.isEmpty)
        XCTAssertTrue(tail.allSatisfy { $0.displayContext == "Off wrist" && $0.wear.state == .offWrist })
    }

    func testSleepSessionDrivesAsleepLabelsFromStoredStreams() throws {
        var sim = ActivitySim()
        let start = sim.ts
        sim.still(30)
        let sleepStart = sim.ts
        var o = ActivitySim.Options(); o.hr = 54
        sim.still(400, dyn: 0.006, opt: o)
        let sleepEnd = sim.ts
        sim.still(30)
        let (track, _) = run(sim, sleep: [DayStateSpan(start: sleepStart, end: sleepEnd)])
        let mid = try XCTUnwrap(track.states.last { $0.ts < sleepEnd - 10 })
        XCTAssertEqual(mid.sleep.state, .asleep)
        XCTAssertEqual(mid.displayContext, "Asleep")
        XCTAssertGreaterThan(mid.posture[.recumbent], 0.8)
        XCTAssertGreaterThan(start, 0)
    }

    func testEncoderAndImuWindowsReachTheDecoder() throws {
        var sim = ActivitySim()
        sim.still(20); sim.walk(60)
        var windows: [ActivityWindowPrediction] = []
        var imu: [ImuWindowFeatures] = []
        for o in sim.observations where o.ts % 2 == 0 {
            windows.append(ActivityWindowPrediction(startTs: o.ts - 4, endTs: o.ts, label: .walking,
                                                    probs: ["walking": 0.9, "stationary": 0.05, "running": 0.02, "other_movement": 0.03]))
            imu.append(ImuWindowFeatures(startTs: o.ts - 4, endTs: o.ts, accelRmsG: 0.14, gyroRmsDps: 60, jerkRms: 0.2,
                                         cadenceHz: 1.9, cadenceStrength: 0.7, orientationChangeDeg: 6))
        }
        var input = sim.trackInput()
        input.encoderWindows = windows; input.imuWindows = imu
        input.encoderId = "hart-tspulse"; input.encoderVersion = "v9"
        let track = ActivityContextTrackBuilder.build(input)
        let end = try XCTUnwrap(track.states.last)
        XCTAssertTrue(end.evidence.encoder)
        XCTAssertTrue(end.evidence.imu)
        XCTAssertEqual(end.versions.encoderId, "hart-tspulse")
        XCTAssertEqual(end.versions.encoderVersion, "v9")
        XCTAssertEqual(end.locomotion.top?.0, .walking)
    }

    // MARK: Continuation

    func testBuildingInTwoPiecesWithASnapshotEqualsBuildingOnce() throws {
        var sim = ActivitySim()
        sim.desk(200); sim.walk(60); sim.still(30); sim.postureShift(netDegrees: 70, seconds: 3); sim.desk(120)
        let all = sim.trackInput()
        let whole = ActivityContextTrackBuilder.build(all)

        let cut = sim.observations[300].ts
        var first = all; first.dayEnd = cut
        var second = all; second.dayStart = cut
        let a = ActivityContextTrackBuilder.build(first)
        let b = ActivityContextTrackBuilder.build(second, resuming: a.snapshot)
        XCTAssertEqual(b.restore, .resumed)
        let joined = a.appending(b)
        XCTAssertEqual(joined.states.map(\.ts), whole.states.map(\.ts))
        for (x, y) in zip(joined.states, whole.states) {
            XCTAssertEqual(x.displayContext, y.displayContext)
            XCTAssertEqual(x.overallConfidence, y.overallConfidence, accuracy: 1e-9)
            XCTAssertEqual(x.locomotion, y.locomotion)
        }
        XCTAssertEqual(joined.events, whole.events)
        XCTAssertEqual(joined.lastTs, whole.lastTs)
        XCTAssertEqual(joined.snapshot, whole.snapshot)
    }

    func testEventsAreListedOncePerOccurrence() throws {
        var sim = ActivitySim()
        sim.still(30); sim.walk(60); sim.still(60)
        let (track, _) = run(sim)
        XCTAssertEqual(track.events.filter { $0.kind == .walkStart }.count, 1)
        XCTAssertEqual(track.events.filter { $0.kind == .walkStop }.count, 1)
        XCTAssertEqual(track.events.map(\.ts), track.events.map(\.ts).sorted())
    }

    // MARK: Runs and the persisted document

    private func mixedDay() -> (sim: ActivitySim, sleep: DayStateSpan) {
        var sim = ActivitySim()
        sim.still(60); sim.desk(900); sim.postureShift(netDegrees: -75, seconds: 3); sim.walk(180)
        sim.still(30); sim.postureShift(netDegrees: 70, seconds: 3); sim.desk(1200)
        sim.run(120); sim.walk(60)
        let sleepStart = sim.ts
        sim.sleeping(1800)
        return (sim, DayStateSpan(start: sleepStart, end: sim.ts))
    }

    func testCoalescingKeepsADayCompactAndLossless() throws {
        let day = mixedDay()
        let (track, _) = run(day.sim, sleep: [day.sleep])
        let runs = ActivityContextRuns.coalesce(track.states)
        XCTAssertLessThan(runs.count, track.states.count / 5, "a steady day collapses to far fewer runs than ticks")
        XCTAssertEqual(runs.map(\.count).reduce(0, +), track.states.count)
        XCTAssertEqual(runs.first?.start, track.states.first?.ts)
        // Runs tile time in order without overlap.
        for (a, b) in zip(runs, runs.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start + 5) }
        XCTAssertTrue(runs.allSatisfy { $0.end > $0.start })

        // Expanding back keeps the display label of every tick.
        let versions = track.snapshot.versions
        let expanded = ActivityContextRuns.expand(runs, versions: versions)
        let original = Dictionary(uniqueKeysWithValues: track.states.map { ($0.ts, $0.displayContext) })
        var agree = 0
        for s in expanded where original[s.ts] != nil { if original[s.ts]! == s.displayContext { agree += 1 } }
        XCTAssertGreaterThan(Double(agree) / Double(track.states.count), 0.97)
    }

    func testRunsCarryAveragedHeadsNotJustTheFirstTick() throws {
        var sim = ActivitySim()
        sim.still(30); sim.desk(300)
        let (track, _) = run(sim)
        let runs = ActivityContextRuns.coalesce(track.states)
        let long = try XCTUnwrap(runs.max { $0.count < $1.count })
        XCTAssertGreaterThan(long.count, 4)
        XCTAssertEqual(long.posture.total, 1, accuracy: 0.01)
        XCTAssertEqual(long.locomotion.total, 1, accuracy: 0.01)
    }

    func testDayDocumentRoundTripsAsJSON() throws {
        let day = mixedDay()
        let (track, input) = run(day.sim, sleep: [day.sleep])
        let doc = ActivityContextDayDocument(track: track, input: input, generatedAt: 1_760_100_000)
        XCTAssertTrue(doc.isCurrent)
        XCTAssertEqual(doc.schemaVersion, 2)
        XCTAssertEqual(doc.versions.ontology, "v2.0")
        XCTAssertEqual(doc.dataThrough, (track.lastTs ?? 0) + 1)
        XCTAssertEqual(doc.latest?.ts, track.states.last?.ts)
        XCTAssertNotNil(doc.snapshot)

        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(ActivityContextDayDocument.self, from: data)
        XCTAssertEqual(back.runs.count, doc.runs.count)
        XCTAssertEqual(back.snapshot, doc.snapshot)
        XCTAssertEqual(back.summary, doc.summary)
        XCTAssertEqual(back.versions, doc.versions)

        // The persisted size stays small enough to live in a JSON blob next to the daily snapshot.
        XCTAssertLessThan(data.count, 400_000, "a 1.2-hour mixed stream should be tens of KB, got \(data.count)")
    }

    func testRunJSONUsesTheCanonicalPayloadShape() throws {
        var sim = ActivitySim()
        sim.still(30); sim.desk(240)
        let (track, input) = run(sim)
        let doc = ActivityContextDayDocument(track: track, input: input, generatedAt: 1)
        let data = try JSONEncoder().encode(doc)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let runs = try XCTUnwrap(json["runs"] as? [[String: Any]])
        let last = try XCTUnwrap(runs.last)
        for key in ["s", "e", "posture", "locomotion", "arm_behavior", "intensity",
                    "overall_confidence", "display_context", "sleep", "wear"] {
            XCTAssertNotNil(last[key], "missing \(key)")
        }
        let posture = try XCTUnwrap(last["posture"] as? [String: Double])
        XCTAssertGreaterThan(try XCTUnwrap(posture["seated_likely"]), 0.5)
        XCTAssertEqual(last["display_context"] as? String, "Desk sitting")
        XCTAssertEqual(json["schema_version"] as? Int, 2)
        XCTAssertEqual(json["publish_interval_s"] as? Int, 5)
    }

    func testDocumentWithoutSnapshotStillRoundTrips() throws {
        var sim = ActivitySim()
        sim.desk(120)
        let (track, input) = run(sim)
        let doc = ActivityContextDayDocument(track: track, input: input, generatedAt: 1, includeSnapshot: false)
        let back = try JSONDecoder().decode(ActivityContextDayDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertNil(back.snapshot)
        XCTAssertEqual(back.runs.count, doc.runs.count)
    }

    func testDocumentsFromAnotherOntologyOrDecoderAreNotCurrent() throws {
        var sim = ActivitySim()
        sim.desk(60)
        let (track, input) = run(sim)
        var doc = ActivityContextDayDocument(track: track, input: input, generatedAt: 1)
        XCTAssertTrue(doc.isCurrent)
        doc.versions.decoder = "hsmm-0.9"
        XCTAssertFalse(doc.isCurrent)
        doc.versions.decoder = ActivityContextVersions.decoder
        doc.versions.ontology = "v1"
        XCTAssertFalse(doc.isCurrent)
        doc.versions.ontology = ActivityContextVersions.ontology
        doc.schemaVersion = 1
        XCTAssertFalse(doc.isCurrent)
    }

    func testSummaryAccountsForEverySecondOfPublishedTime() throws {
        let day = mixedDay()
        let (track, input) = run(day.sim, sleep: [day.sleep])
        let doc = ActivityContextDayDocument(track: track, input: input, generatedAt: 1)
        let labelled = doc.summary.labelSeconds.values.reduce(0, +)
        let covered = doc.runs.reduce(0) { $0 + ($1.end - $1.start) }
        XCTAssertEqual(labelled + doc.summary.unclearSeconds, covered)
        XCTAssertGreaterThan(doc.summary.labelSeconds["Walking"] ?? 0, 100)
        XCTAssertGreaterThan(doc.summary.labelSeconds["Asleep"] ?? 0, 1000)
        XCTAssertTrue((0...1).contains(doc.summary.meanConfidence))
    }

    // MARK: Keeping a stored day up to date

    private func piecewiseDay() -> (sim: ActivitySim, cut: Int) {
        var sim = ActivitySim()
        sim.desk(300); sim.walk(90); sim.still(40)
        let cut = sim.ts
        sim.desk(300); sim.postureShift(netDegrees: 70, seconds: 3); sim.walk(60)
        return (sim, cut)
    }

    func testFirstUpdateWithoutACacheDecodesTheWholeDay() throws {
        let day = piecewiseDay()
        let input = day.sim.trackInput()
        let (doc, how) = ActivityContextDayBuilder.update(cached: nil, input: input, now: 100)
        XCTAssertEqual(how, .recomputed(reason: "no_cache"))
        let direct = ActivityContextDayDocument(track: ActivityContextTrackBuilder.build(input), input: input, generatedAt: 100)
        XCTAssertEqual(doc, direct)
    }

    func testUpdateWithNothingNewReturnsTheStoredDocument() throws {
        let day = piecewiseDay()
        let input = day.sim.trackInput()
        let (first, _) = ActivityContextDayBuilder.update(cached: nil, input: input, now: 100)
        let (again, how) = ActivityContextDayBuilder.update(cached: first, input: input, now: 200)
        XCTAssertEqual(how, .reused)
        XCTAssertEqual(again.runs, first.runs)
        XCTAssertEqual(again.generatedAt, 100)
    }

    func testUpdateContinuesFromTheStoredDecoderWhenDataIsAppended() throws {
        let day = piecewiseDay()
        let full = day.sim.trackInput()
        var head = full; head.dayEnd = day.cut
        let (cached, _) = ActivityContextDayBuilder.update(cached: nil, input: head, now: 100)

        // Through JSON, as it would come off disk.
        let stored = try JSONDecoder().decode(ActivityContextDayDocument.self, from: JSONEncoder().encode(cached))
        let (resumed, how) = ActivityContextDayBuilder.update(cached: stored, input: full, now: 200)
        XCTAssertEqual(how, .resumed(fromTs: day.cut))

        let (whole, _) = ActivityContextDayBuilder.update(cached: nil, input: full, now: 200)
        XCTAssertEqual(resumed.summary.labelSeconds, whole.summary.labelSeconds)
        XCTAssertEqual(resumed.events, whole.events)
        XCTAssertEqual(resumed.latest?.ts, whole.latest?.ts)
        XCTAssertEqual(resumed.latest?.displayContext, whole.latest?.displayContext)
        XCTAssertEqual(resumed.snapshot, whole.snapshot)
        XCTAssertEqual(resumed.observedSeconds, whole.observedSeconds)
        XCTAssertEqual(resumed.dataThrough, whole.dataThrough)
        XCTAssertLessThanOrEqual(abs(resumed.runs.count - whole.runs.count), 1)
    }

    func testExtendingInManySmallStepsDoesNotLeaveASeamAtEveryStep() throws {
        var sim = ActivitySim()
        sim.desk(900)
        let full = sim.trackInput()
        var doc: ActivityContextDayDocument?
        var t = full.dayStart + 60
        while t <= full.dayEnd {
            var part = full; part.dayEnd = t
            let (next, _) = ActivityContextDayBuilder.update(cached: doc, input: part, now: t)
            doc = next
            t += 60
        }
        let (whole, _) = ActivityContextDayBuilder.update(cached: nil, input: full, now: 1)
        XCTAssertLessThanOrEqual(doc!.runs.count, whole.runs.count + 2,
                                 "steady desk time must not fragment into one run per extension")
        XCTAssertEqual(doc!.summary.labelSeconds, whole.summary.labelSeconds)
    }

    func testLateArrivingDataInsideTheCoveredSpanForcesARecompute() throws {
        let day = piecewiseDay()
        let full = day.sim.trackInput()

        // First pass saw the stream with one second missing (not yet backfilled) and stopped at the cut.
        var early = full
        early.dayEnd = day.cut
        let missing = day.cut - 100
        early.hr.removeAll { $0.ts == missing }
        early.gravity.removeAll { $0.ts == missing }
        early.steps.removeAll { $0.ts == missing }
        let (cached, _) = ActivityContextDayBuilder.update(cached: nil, input: early, now: 100)

        // Later the backfill supplied it and the day grew: continuing from the old decoder would skip it.
        let (updated, how) = ActivityContextDayBuilder.update(cached: cached, input: full, now: 200)
        XCTAssertEqual(how, .recomputed(reason: "late_data"))
        XCTAssertEqual(updated.observedSeconds, ActivityContextTrackBuilder.observations(for: full).count)
        XCTAssertGreaterThan(updated.observedSeconds, cached.observedSeconds)
    }

    // MARK: Invalidation (spec §13): same bounds and count, changed content

    func testRenamingAWorkoutSportWithIdenticalBoundsRecomputes() throws {
        var sim = ActivitySim()
        sim.desk(60)
        let workoutStart = sim.ts
        sim.run(120)
        let workoutEnd = sim.ts
        sim.desk(60)
        let input = sim.trackInput(workouts: [DayStateWorkout(start: workoutStart, end: workoutEnd, sport: "Run")])
        let (cached, _) = ActivityContextDayBuilder.update(cached: nil, input: input, now: 100)

        // The wearer edits the workout's sport with identical bounds: the covered span and the
        // observation count are unchanged, so only the fingerprint — which now carries the sport kind the
        // decoder sees — can see the change. Before the fix the span-only hash read the same and the day
        // was reused with a stale document (WS-10-F04).
        var renamed = input
        renamed.workouts = [DayStateWorkout(start: workoutStart, end: workoutEnd, sport: "Cycling")]
        XCTAssertEqual(ActivityContextTrackBuilder.observations(for: renamed).count,
                       ActivityContextTrackBuilder.observations(for: input).count)
        let (_, how) = ActivityContextDayBuilder.update(cached: cached, input: renamed, now: 200)
        XCTAssertEqual(how, .recomputed(reason: "context_changed"))

        // A rename that maps to the same kind ("Run" -> "Running") is the same evidence to the decoder and
        // must not invalidate the day.
        var sameKind = input
        sameKind.workouts = [DayStateWorkout(start: workoutStart, end: workoutEnd, sport: "Running")]
        let (_, how2) = ActivityContextDayBuilder.update(cached: cached, input: sameKind, now: 300)
        XCTAssertEqual(how2, .reused)
    }

    func testAnEqualCountSampleReplacementRecomputes() throws {
        var sim = ActivitySim()
        sim.desk(60)
        let replace = sim.ts + 30
        sim.desk(120)
        let input = sim.trackInput()
        let (cached, _) = ActivityContextDayBuilder.update(cached: nil, input: input, now: 100)

        // A corrected HR value for one second: the same number of rows, the same spans, different content.
        var corrected = input
        corrected.hr = corrected.hr.map { $0.ts == replace ? HRSample(ts: replace, bpm: 128) : $0 }
        XCTAssertEqual(corrected.hr.count, input.hr.count)
        XCTAssertEqual(ActivityContextTrackBuilder.observations(for: corrected).count,
                       ActivityContextTrackBuilder.observations(for: input).count)
        let (_, how) = ActivityContextDayBuilder.update(cached: cached, input: corrected, now: 200)
        XCTAssertEqual(how, .recomputed(reason: "context_changed"))
    }

    func testReServedEncoderProbabilitiesWithTheSameWindowsRecompute() throws {
        var sim = ActivitySim()
        sim.desk(60); sim.walk(60)
        var input = sim.trackInput()
        func windows(_ p: Double) -> [ActivityWindowPrediction] {
            let start = sim.observations.first!.ts
            return (0..<12).map { i in
                let end = start + (i + 1) * 10
                return ActivityWindowPrediction(startTs: end - 4, endTs: end, label: .walking,
                                                probs: ["walking": p, "stationary": (1 - p) / 2,
                                                        "running": (1 - p) / 2])
            }
        }
        input.encoderWindows = windows(0.91)
        let (cached, _) = ActivityContextDayBuilder.update(cached: nil, input: input, now: 100)

        // The server re-serves the same windows — same count, bounds and labels — with different
        // probabilities. The fingerprint must still move.
        var reserved = input
        reserved.encoderWindows = windows(0.55)
        XCTAssertEqual(reserved.encoderWindows.count, input.encoderWindows.count)
        let (_, how) = ActivityContextDayBuilder.update(cached: cached, input: reserved, now: 200)
        XCTAssertEqual(how, .recomputed(reason: "context_changed"))
    }

    func testUnchangedInputStillReusesTheStoredDay() throws {
        var sim = ActivitySim()
        sim.desk(60); sim.walk(60); sim.desk(60)
        let input = sim.trackInput()
        let (cached, _) = ActivityContextDayBuilder.update(cached: nil, input: input, now: 100)
        // Determinism: the same input hashes the same, so the same document is returned, never re-decoded.
        XCTAssertEqual(ActivityContextDayBuilder.fingerprint(input, through: cached.dataThrough),
                       cached.contextFingerprint)
        let (again, how) = ActivityContextDayBuilder.update(cached: cached, input: input, now: 200)
        XCTAssertEqual(how, .reused)
        XCTAssertEqual(again.generatedAt, cached.generatedAt, "the stored document is returned as it was")
    }

    func testStoredDocumentsFromAnotherVersionOrDayAreRecomputed() throws {
        let day = piecewiseDay()
        let input = day.sim.trackInput()
        let (doc, _) = ActivityContextDayBuilder.update(cached: nil, input: input, now: 100)

        var oldDecoder = doc; oldDecoder.versions.decoder = "hsmm-0.1"
        XCTAssertEqual(ActivityContextDayBuilder.update(cached: oldDecoder, input: input, now: 200).how,
                       .recomputed(reason: "version_changed"))

        var otherDay = input; otherDay.dayStart -= 86_400; otherDay.dayEnd -= 86_400
        XCTAssertEqual(ActivityContextDayBuilder.update(cached: doc, input: otherDay, now: 200).how,
                       .recomputed(reason: "day_changed"))

        var noSnapshot = doc; noSnapshot.snapshot = nil
        XCTAssertEqual(ActivityContextDayBuilder.update(cached: noSnapshot, input: input, now: 200).how,
                       .recomputed(reason: "no_snapshot"))
    }

    func testEditingALoggedNightForcesARecompute() throws {
        var sim = ActivitySim()
        sim.desk(120)
        let sleepStart = sim.ts
        sim.sleeping(300)
        let sleepEnd = sim.ts
        sim.desk(120)
        let night = DayStateSpan(start: sleepStart, end: sleepEnd)
        var input = sim.trackInput(sleep: [night])
        var head = input; head.dayEnd = sleepEnd + 30
        let (cached, _) = ActivityContextDayBuilder.update(cached: nil, input: head, now: 100)

        // The wearer trims the night's start: same data, different context for the covered seconds.
        input.sleep = [DayStateSpan(start: sleepStart + 60, end: sleepEnd)]
        let (_, how) = ActivityContextDayBuilder.update(cached: cached, input: input, now: 200)
        XCTAssertEqual(how, .recomputed(reason: "context_changed"))

        // Adding a workout inside the covered span does the same.
        var withWorkout = sim.trackInput(sleep: [night])
        withWorkout.workouts = [DayStateWorkout(start: sleepStart - 60, end: sleepStart - 20, sport: "Walk")]
        XCTAssertEqual(ActivityContextDayBuilder.update(cached: cached, input: withWorkout, now: 200).how,
                       .recomputed(reason: "context_changed"))
    }

    func testAnOpenSpanThatKeepsGrowingDoesNotInvalidateTheStoredDay() throws {
        var sim = ActivitySim()
        sim.desk(200)
        let start = sim.observations.first!.ts
        let offStart = sim.ts
        var o = ActivitySim.Options(); o.wear = .offWrist
        sim.still(100, opt: o)
        let full = sim.trackInput(offWrist: [DayStateSpan(start: offStart, end: sim.ts)])

        // First pass ran while the off-wrist span was still open (it ended where the data did).
        var early = full
        early.dayEnd = offStart + 40
        early.offWrist = [DayStateSpan(start: offStart, end: offStart + 40)]
        let (cached, _) = ActivityContextDayBuilder.update(cached: nil, input: early, now: 100)
        let (updated, how) = ActivityContextDayBuilder.update(cached: cached, input: full, now: 200)
        XCTAssertEqual(how, .resumed(fromTs: offStart + 40))
        XCTAssertEqual(updated.latest?.displayContext, "Off wrist")
        XCTAssertGreaterThan(start, 0)
    }

    func testFlippingTheSleepContextFlagRecomputes() throws {
        var sim = ActivitySim()
        sim.desk(120)
        let live = sim.trackInput(sleepKnownOutsideSessions: false)
        let (cached, _) = ActivityContextDayBuilder.update(cached: nil, input: live, now: 100)
        XCTAssertFalse(cached.sleepKnownOutsideSessions)
        var finished = live
        finished.sleepKnownOutsideSessions = true
        XCTAssertEqual(ActivityContextDayBuilder.update(cached: cached, input: finished, now: 200).how,
                       .recomputed(reason: "sleep_context_changed"))
    }

    func testEventsKeepTheirPeakProbabilityAcrossAnExtension() throws {
        var sim = ActivitySim()
        sim.desk(240); sim.postureShift(netDegrees: 80, seconds: 3); sim.desk(120)
        let full = sim.trackInput()
        let whole = ActivityContextTrackBuilder.build(full)
        guard let event = whole.events.first(where: { $0.kind == .sitToStandLike || $0.kind == .standToSitLike || $0.kind == .gettingUpLike }) else {
            return XCTFail("the posture shift should flag an event")
        }
        // Cut the stream in the middle of the event's hold window, so both halves see it.
        var head = full; head.dayEnd = event.ts + 6
        let (cached, _) = ActivityContextDayBuilder.update(cached: nil, input: head, now: 1)
        let (resumed, how) = ActivityContextDayBuilder.update(cached: cached, input: full, now: 2)
        XCTAssertEqual(how, .resumed(fromTs: event.ts + 6))
        let same = try XCTUnwrap(resumed.events.first { $0.kind == event.kind && $0.ts == event.ts })
        XCTAssertEqual(same.probability, event.probability, accuracy: 1e-9)
        XCTAssertEqual(resumed.events.filter { $0.kind == event.kind && $0.ts == event.ts }.count, 1)
    }

    // MARK: Episodes

    func testEpisodesJoinRunsThatShareALabel() throws {
        let day = mixedDay()
        let (track, input) = run(day.sim, sleep: [day.sleep])
        let doc = ActivityContextDayDocument(track: track, input: input, generatedAt: 1)
        let episodes = ActivityContextEpisodes.build(doc.runs)
        XCTAssertLessThanOrEqual(episodes.count, doc.runs.count)
        for (a, b) in zip(episodes, episodes.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start + 10)
            XCTAssertFalse(a.label == b.label && a.wear == b.wear && a.sleep == b.sleep && b.start - a.end <= 10,
                           "neighbouring episodes must differ in label or context")
        }
        let asleep = episodes.filter { $0.label == "Asleep" }.reduce(0) { $0 + $1.durationSeconds }
        XCTAssertGreaterThan(asleep, 1000)
        XCTAssertTrue(episodes.allSatisfy { $0.durationSeconds > 0 && (0...1).contains($0.confidence) })
    }

    func testAFullDayDecodesQuickly() throws {
        // 24 h of 1 Hz data (a plausible heavy day): the decoder must stay a background-task cost.
        var sim = ActivitySim()
        for _ in 0..<24 { sim.desk(1500); sim.walk(300); sim.still(900); sim.fidget(600); sim.sleeping(300) }
        XCTAssertGreaterThan(sim.observations.count, 80_000)
        let input = sim.trackInput()
        let started = Date()
        let track = ActivityContextTrackBuilder.build(input)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(track.states.count, 16_000)
        XCTAssertLessThan(elapsed, 60, "debug-build budget; release is far faster")
        let doc = ActivityContextDayDocument(track: track, input: input, generatedAt: 1)
        let bytes = try JSONEncoder().encode(doc).count
        XCTAssertLessThan(bytes, 5_000_000)
    }
}

private extension ActivityContextDecoder {
    static func runAll(_ observations: [ActivityObservation]) -> [ActivityContextState] {
        var d = ActivityContextDecoder()
        return d.run(observations)
    }
}
