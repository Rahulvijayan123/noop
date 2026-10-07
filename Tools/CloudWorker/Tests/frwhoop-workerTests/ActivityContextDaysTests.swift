import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// The worker's ActivityContext v2 glue, without a database: service window → decoder input mapping,
/// the feature-schema gate, wear spans from events, and the day document the RPC receives. The decoder's
/// own behaviour (heads, hysteresis, the HSMM) is pinned by the StrandAnalytics suite; the SQL side by
/// `supabase/functions/tests/activity_context_contract.sql`; the two together by
/// `ActivityContextDaysDatabaseTests`.
final class ActivityContextDaysTests: XCTestCase {

    // 2026-09-15 00:00:00 UTC.
    private let dayStart = 1_789_430_400
    private var dayEnd: Int { dayStart + 86_400 }
    private let day = "2026-09-15"

    private func window(start: Double = 100, end: Double = 104, label: String = "walking",
                        probs: [String: Double] = ["walking": 0.9, "stationary": 0.1],
                        baseline: Bool = false,
                        features: [String: Double] = DaySim.walkingFeatures)
        -> ActivityPythonService.WindowPrediction {
        ActivityPythonService.WindowPrediction(start: start, end: end, label: label, probs: probs,
                                               baseline: baseline, features: features)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func build(_ input: ActivityContextTrackInput, generatedAt: Int = 1_789_500_000) throws
        -> ActivityContextDays.Built {
        try ActivityContextDays.build(input: input, day: day, modelVersion: "hart-activity-1",
                                      preprocessingVersion: "activity-preprocess-1", generatedAt: generatedAt)
    }

    // MARK: - Service window → decoder input

    func testImuFeaturesMapAServiceWindow() throws {
        let f = try XCTUnwrap(ActivityContextDays.imuFeatures(window(start: 1_789_430_400, end: 1_789_430_404)))
        XCTAssertEqual(f.startTs, 1_789_430_400)
        XCTAssertEqual(f.endTs, 1_789_430_404)
        XCTAssertEqual(f.accelRmsG, 0.14, accuracy: 1e-12)
        XCTAssertEqual(f.gyroRmsDps, 60, accuracy: 1e-12)
        XCTAssertEqual(f.jerkRms, 0.2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(f.cadenceHz), 1.9, accuracy: 1e-12)
        XCTAssertEqual(f.cadenceStrength, 0.7, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(f.orientationChangeDeg), 6, accuracy: 1e-12)
    }

    func testCadenceAndOrientationMayBeAbsentButTheRestMayNot() throws {
        var feat = DaySim.stationaryFeatures          // no cadence_hz
        feat["orientation_change_deg"] = nil
        let f = try XCTUnwrap(ActivityContextDays.imuFeatures(window(features: feat)))
        XCTAssertNil(f.cadenceHz)
        XCTAssertNil(f.orientationChangeDeg)

        for required in ["accel_rms_g", "gyro_rms_dps", "jerk_rms_gps", "cadence_strength"] {
            var partial = DaySim.walkingFeatures
            partial[required] = nil
            XCTAssertNil(ActivityContextDays.imuFeatures(window(features: partial)),
                         "a window without \(required) carries no usable IMU facts")
        }
        XCTAssertNil(ActivityContextDays.imuFeatures(window(features: [:])))
    }

    func testDegenerateWindowSpansProduceNothing() {
        XCTAssertNil(ActivityContextDays.imuFeatures(window(start: 104, end: 104)))
        XCTAssertNil(ActivityContextDays.imuFeatures(window(start: 110, end: 104)))
        XCTAssertNil(ActivityContextDays.imuFeatures(window(start: .nan, end: 104)))
        XCTAssertNil(ActivityContextDays.imuFeatures(window(start: 100, end: .infinity)))
        XCTAssertNil(ActivityContextDays.encoderWindow(window(start: 104, end: 104)))
        XCTAssertNil(ActivityContextDays.encoderWindow(window(start: .nan, end: 104)))
        XCTAssertNil(ActivityContextDays.encoderWindow(window(start: 0, end: 1e13)))
    }

    func testEncoderWindowKeepsLabelProbabilitiesAndTheBaselineFlag() throws {
        let w = try XCTUnwrap(ActivityContextDays.encoderWindow(
            window(start: 100, end: 104, label: "running", probs: ["running": 0.7, "walking": 0.3], baseline: true)))
        XCTAssertEqual(w.startTs, 100)
        XCTAssertEqual(w.endTs, 104)
        XCTAssertEqual(w.label, .running)
        XCTAssertEqual(w.probs["running"] ?? 0, 0.7, accuracy: 1e-12)
        XCTAssertTrue(w.baseline)

        let unknown = try XCTUnwrap(ActivityContextDays.encoderWindow(window(label: "teleporting")))
        XCTAssertEqual(unknown.label, .unknown, "a label this build does not know is unknown, not a crash")
    }

    // MARK: - Feature schema gate

    private func result(schema: String?, windows: [ActivityPythonService.WindowPrediction])
        -> ActivityPythonService.InferResult {
        ActivityPythonService.InferResult(ok: true, modelVersion: "m", preprocessingVersion: "p",
                                          windows: windows, error: nil, errorKind: nil,
                                          featureSchema: schema)
    }

    func testFeaturesAreKeptOnlyWhenTheServiceNamesTheDecodersSchema() {
        let ws = [window(), window(start: 102, end: 106)]
        let ok = ActivityContextDays.windowsWithCompatibleFeatures(
            result(schema: ActivityContextVersions.featureSchema, windows: ws))
        XCTAssertEqual(ok.map(\.features), ws.map(\.features))

        for schema in [nil, "", "imu-feat-0", "imu-feat-99"] as [String?] {
            let stripped = ActivityContextDays.windowsWithCompatibleFeatures(result(schema: schema, windows: ws))
            XCTAssertEqual(stripped.count, ws.count, "the encoder evidence is still usable")
            XCTAssertTrue(stripped.allSatisfy { $0.features.isEmpty }, "schema \(schema ?? "nil") must not feed the decoder")
            XCTAssertEqual(stripped.map(\.probs), ws.map(\.probs))
            XCTAssertEqual(stripped.map(\.label), ws.map(\.label))
        }
    }

    // MARK: - HART fine + ElderNet gait

    func testFineAndGaitAreGatedOnTheirSchemasAndReachTheDecoderInput() throws {
        var w = window(start: Double(dayStart + 100), end: Double(dayStart + 104))
        w.fine = ["walking": 0.8, "stairs": 0.2]
        let gait = [ActivityGaitWindow(startTs: dayStart + 100, endTs: dayStart + 110, gaitProb: 0.9, isGait: true,
                                       cadenceSpm: 110, modelVersion: "en-1")]
        func result(fine: String?, gaitSchema: String?) -> ActivityPythonService.InferResult {
            ActivityPythonService.InferResult(ok: true, modelVersion: "m", preprocessingVersion: "p", windows: [w],
                                              error: nil, errorKind: nil,
                                              featureSchema: ActivityContextVersions.featureSchema,
                                              fineSchema: fine, gaitWindows: gait, gaitSchema: gaitSchema)
        }
        let good = result(fine: "wisdm-act-1", gaitSchema: "gait-quality-1")
        XCTAssertEqual(ActivityContextDays.windowsWithCompatibleFeatures(good).first?.fine, w.fine)
        XCTAssertEqual(ActivityContextDays.compatibleGaitWindows(good), gait)
        for (fine, g) in [(nil, nil), ("wisdm-act-0", "gait-quality-0")] as [(String?, String?)] {
            let bad = result(fine: fine, gaitSchema: g)
            XCTAssertNil(ActivityContextDays.windowsWithCompatibleFeatures(bad).first?.fine)
            XCTAssertFalse(ActivityContextDays.windowsWithCompatibleFeatures(bad).first?.features.isEmpty ?? true,
                           "a fine-schema mismatch strips only the fine distribution")
            XCTAssertTrue(ActivityContextDays.compatibleGaitWindows(bad).isEmpty)
        }

        let input = ActivityContextDays.trackInput(
            windows: ActivityContextDays.windowsWithCompatibleFeatures(good), streams: .init(), sleep: [], exercise: [],
            dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: "v1",
            gaitWindows: ActivityContextDays.compatibleGaitWindows(good))
        XCTAssertEqual(input.encoderWindows.first?.fineProbs, w.fine)
        XCTAssertEqual(input.gaitWindows, gait)

        let set = ActivityEncoderWindowsStore.windowSet(windows: [w], dayStart: dayStart, dayEnd: dayEnd,
                                                        modelVersion: "m", gaitWindows: gait)
        XCTAssertEqual(set.gaitWindows, gait)
        let doc = try object(try ActivityEncoderWindowsStore.payload(set: set, day: day, dayStart: dayStart,
                                                                    preprocessingVersion: "p"))
        let windowsDoc = try XCTUnwrap(doc["windows"] as? [String: Any])
        XCTAssertEqual(windowsDoc["g_schema"] as? String, "gait-quality-1")
        XCTAssertEqual(windowsDoc["h_schema"] as? String, "wisdm-act-1")
        let back = try XCTUnwrap(ActivityEncoderWindowSet.decode(windowsDoc, encoderId: "hart", encoderVersion: "m"))
        XCTAssertEqual(back.gaitWindows.first?.cadenceSpm, 110)
        XCTAssertEqual(back.windows.first?.fineProbs?["stairs"] ?? -1, 0.2, accuracy: 0.0006)
    }

    // MARK: - Encoder identity

    func testEncoderIdFollowsTheBaselineFlag() {
        func id(_ baselineFlags: [Bool]) -> String {
            let ws = baselineFlags.map { window(baseline: $0) }
            return ActivityContextDays.trackInput(
                windows: ws, streams: .init(), sleep: [], exercise: [],
                dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: "v1").encoderId
        }
        XCTAssertEqual(id([true, true]), "baseline")
        XCTAssertEqual(id([false, false]), "hart")
        XCTAssertEqual(id([true, false]), "hart")
        XCTAssertEqual(id([]), "baseline", "no windows, no trained encoder to credit")
    }

    // MARK: - Streams → decoder input

    func testSleepWorkoutsAndWindowsAreCarriedIntoTheInput() {
        var sim = DaySim(start: dayStart + 3_600)
        sim.still(30)
        let input = ActivityContextDays.trackInput(
            windows: sim.windows, streams: sim.streams,
            sleep: [(start: dayStart + 100, end: dayStart + 200)],
            exercise: [(start: dayStart + 300, end: dayStart + 400, sport: "cycling")],
            dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: "hart-activity-1")
        XCTAssertEqual(input.dayStart, dayStart)
        XCTAssertEqual(input.dayEnd, dayEnd)
        XCTAssertEqual(input.sleep.map { [$0.start, $0.end] }, [[dayStart + 100, dayStart + 200]])
        XCTAssertEqual(input.workouts.map { [$0.start, $0.end] }, [[dayStart + 300, dayStart + 400]])
        XCTAssertEqual(input.workouts.map(\.sport), ["cycling"],
                       "the phone's sport name must survive into the decoder input (audit WS-11-F08)")
        XCTAssertEqual(input.hr.count, 30)
        XCTAssertEqual(input.gravity.count, 30)
        XCTAssertEqual(input.steps.count, 30)
        XCTAssertEqual(input.encoderWindows.count, sim.windows.count)
        XCTAssertEqual(input.imuWindows.count, sim.windows.count)
        XCTAssertEqual(input.encoderVersion, "hart-activity-1")
        XCTAssertFalse(input.sleepKnownOutsideSessions,
                       "time outside a logged night is unknown on the server, never presumed awake")
    }

    /// WS-11-F08: the worker must pass the phone's sport name through to the decoder, and stay
    /// honestly "unspecified" (never a fabricated value) when the row carries none.
    func testWorkoutSportIsPassedThroughOrHonestlyUnspecified() throws {
        var sim = DaySim(start: dayStart + 3_600)
        sim.still(120)

        let withSport = ActivityContextDays.trackInput(
            windows: [], streams: sim.streams, sleep: [],
            exercise: [(start: dayStart + 10, end: dayStart + 90, sport: "Cycling")],
            dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: "streams-activity-1")
        XCTAssertEqual(withSport.workouts.map(\.sport), ["Cycling"],
                       "the row's sport must not be discarded on its way to the decoder")
        XCTAssertEqual(WorkoutKind(sport: try XCTUnwrap(withSport.workouts.first).sport), .cycling,
                       "a cycling workout must read as cycling to the shared decoder, as it does on the phone")

        let noSport = ActivityContextDays.trackInput(
            windows: [], streams: sim.streams, sleep: [],
            exercise: [(start: dayStart + 10, end: dayStart + 90, sport: "")],
            dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: "streams-activity-1")
        XCTAssertEqual(noSport.workouts.map(\.sport), [""],
                       "a row with no sport stays empty, not a guessed name")
        XCTAssertEqual(WorkoutKind(sport: try XCTUnwrap(noSport.workouts.first).sport), .unspecified)
    }

    func testWristEventsBecomeOffWristSpansClippedToTheDaysReach() {
        let events = [
            WhoopEvent(ts: dayStart - 7_200, kind: "WRIST_OFF(10)", payload: [:]),   // a pair that ended before the day
            WhoopEvent(ts: dayStart - 3_600, kind: "WRIST_ON(11)", payload: [:]),
            WhoopEvent(ts: dayStart - 600, kind: "WRIST_OFF(10)", payload: [:]),     // still off when the day began
            WhoopEvent(ts: dayStart + 100, kind: "WRIST_ON(11)", payload: [:]),
            WhoopEvent(ts: dayStart + 5_000, kind: "WRIST_OFF(10)", payload: [:]),
            WhoopEvent(ts: dayStart + 5_900, kind: "WRIST_ON(11)", payload: [:]),
            WhoopEvent(ts: dayStart + 6_000, kind: "BATTERY_LEVEL(3)", payload: [:]),
        ]
        var streams = ActivityContextDays.Streams()
        streams.events = events
        let input = ActivityContextDays.trackInput(
            windows: [], streams: streams, sleep: [], exercise: [],
            dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: "v1")
        XCTAssertEqual(input.offWrist.map { [$0.start, $0.end] },
                       [[dayStart - 600, dayStart + 100], [dayStart + 5_000, dayStart + 5_900]],
                       "the span that closed before the day is not this day's, the one that crossed midnight is")
    }

    /// The day in progress: a strap that came off this morning and has not gone back on is off until now,
    /// not until midnight. Otherwise a live document would claim hours that have not happened.
    func testAnOpenWristOffSpanStopsAtTheHorizon() throws {
        let off = WhoopEvent(ts: dayStart + 40_000, kind: "WRIST_OFF(10)", payload: [:])
        var streams = ActivityContextDays.Streams()
        streams.events = [off]
        func spans(horizon: Int?, events: [WhoopEvent]? = nil) -> [[Int]] {
            var s = streams
            if let events { s.events = events }
            return ActivityContextDays.trackInput(
                windows: [], streams: s, sleep: [], exercise: [],
                dayStart: dayStart, dayEnd: dayEnd, horizon: horizon, sleepKnownOutsideSessions: false, encoderVersion: "v")
                .offWrist.map { [$0.start, $0.end] }
        }
        XCTAssertEqual(spans(horizon: dayStart + 43_000), [[dayStart + 40_000, dayStart + 43_000]])
        XCTAssertEqual(spans(horizon: dayEnd + 5_000), [[dayStart + 40_000, dayEnd]], "never past the day")
        XCTAssertEqual(spans(horizon: nil), [[dayStart + 40_000, dayEnd]], "a finished day")
        XCTAssertEqual(spans(horizon: dayStart + 30_000), [], "not off yet as far as today has gone")
        XCTAssertEqual(spans(horizon: dayStart + 43_000, events: [off, WhoopEvent(ts: dayStart + 41_000, kind: "WRIST_ON(11)", payload: [:])]),
                       [[dayStart + 40_000, dayStart + 41_000]], "an explicit pair is never shortened")

        let input = ActivityContextDays.trackInput(
            windows: [], streams: streams, sleep: [], exercise: [],
            dayStart: dayStart, dayEnd: dayEnd, horizon: dayStart + 40_600, sleepKnownOutsideSessions: false, encoderVersion: "v")
        let built = try build(input)
        let doc = try XCTUnwrap(try object(built.payloadText)["document"] as? [String: Any])
        XCTAssertEqual(doc["day_end"] as? Int, dayEnd, "the document is still the whole UTC day")
        XCTAssertEqual(doc["data_through"] as? Int, dayStart + 40_600, "and covers only what has happened")
        XCTAssertEqual(built.observedSeconds, 600)
    }

    func testAStrapStillOffAtTheEndOfTheDayStaysOffUntilTheDayEnds() {
        var streams = ActivityContextDays.Streams()
        streams.events = [WhoopEvent(ts: dayEnd - 1_800, kind: "WRIST_OFF(10)", payload: [:])]
        let input = ActivityContextDays.trackInput(
            windows: [], streams: streams, sleep: [], exercise: [],
            dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: "v1")
        XCTAssertEqual(input.offWrist.map { [$0.start, $0.end] }, [[dayEnd - 1_800, dayEnd]])
    }

    // MARK: - The document the RPC receives

    func testASittingThenWalkingDayDecodesToTheV2Document() throws {
        var sim = DaySim(start: dayStart + 36_000)
        sim.still(180)
        let walkStart = sim.ts
        sim.walk(120)
        let walkEnd = sim.ts
        sim.still(180)

        let input = ActivityContextDays.trackInput(
            windows: sim.windows, streams: sim.streams, sleep: [], exercise: [],
            dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: "hart-activity-1")
        let built = try build(input)
        let payload = try object(built.payloadText)

        XCTAssertEqual(payload["day"] as? String, day)
        XCTAssertEqual(payload["model_version"] as? String, "hart-activity-1")
        XCTAssertEqual(payload["preprocessing_version"] as? String, "activity-preprocess-1")
        let doc = try XCTUnwrap(payload["document"] as? [String: Any])
        XCTAssertEqual(doc["schema_version"] as? Int, ActivityContextVersions.schema)
        XCTAssertEqual(doc["day_start"] as? Int, dayStart)
        XCTAssertEqual(doc["day_end"] as? Int, dayEnd)
        XCTAssertEqual(doc["sleep_known_outside"] as? Bool, false)
        XCTAssertNil(doc["snapshot"], "the server recomputes the whole day each time; the snapshot is dead weight")
        XCTAssertEqual(doc["observed_s"] as? Int, built.observedSeconds)
        XCTAssertEqual(built.observedSeconds, 480)

        let versions = try XCTUnwrap(doc["versions"] as? [String: Any])
        XCTAssertEqual(versions["schema"] as? Int, ActivityContextVersions.schema)
        XCTAssertEqual(versions["ontology"] as? String, ActivityContextVersions.ontology)
        XCTAssertEqual(versions["decoder"] as? String, ActivityContextVersions.decoder)
        XCTAssertEqual(versions["feature_schema"] as? String, ActivityContextVersions.featureSchema)
        XCTAssertEqual(versions["encoder"] as? String, "hart")
        XCTAssertEqual(versions["encoder_version"] as? String, "hart-activity-1")

        let runs = try XCTUnwrap(doc["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.count, built.runs)
        XCTAssertFalse(runs.isEmpty)
        let walking = runs.filter { ["Walking", "Brisk walking"].contains($0["display_context"] as? String ?? "") }
        XCTAssertFalse(walking.isEmpty, "the walking minutes must be recognised: \(runs.map { $0["display_context"] ?? "nil" })")
        for run in walking {
            let s = try XCTUnwrap(run["s"] as? Int), e = try XCTUnwrap(run["e"] as? Int)
            XCTAssertGreaterThanOrEqual(e, walkStart)
            XCTAssertLessThanOrEqual(s, walkEnd + 10)
        }
        let first = try XCTUnwrap(runs.first)
        XCTAssertFalse(["Walking", "Brisk walking", "Running"].contains(first["display_context"] as? String ?? ""),
                       "the day starts sitting still")

        let latest = try XCTUnwrap(doc["latest"] as? [String: Any])
        let evidence = try XCTUnwrap(latest["evidence"] as? [String: Any])
        XCTAssertEqual(evidence["encoder"] as? Bool, true, "HART/baseline windows reached the decoder")
        XCTAssertEqual(evidence["imu"] as? Bool, true, "and so did the IMU features")
        XCTAssertEqual(evidence["hr"] as? Bool, true)
    }

    func testWithoutServiceWindowsTheDecoderRunsOnTheStoredStreamsAlone() throws {
        var sim = DaySim(start: dayStart + 36_000)
        sim.walk(120)
        let input = ActivityContextDays.trackInput(
            windows: [], streams: sim.streams, sleep: [], exercise: [],
            dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: "hart-activity-1")
        let doc = try XCTUnwrap(try object(try build(input).payloadText)["document"] as? [String: Any])
        let latest = try XCTUnwrap(doc["latest"] as? [String: Any])
        let evidence = try XCTUnwrap(latest["evidence"] as? [String: Any])
        XCTAssertEqual(evidence["encoder"] as? Bool, false)
        XCTAssertEqual(evidence["imu"] as? Bool, false)
        XCTAssertNil((doc["versions"] as? [String: Any])?["encoder"] as? String,
                     "no encoder evidence, no encoder claimed in the provenance")
    }

    func testStrippingTheImuFeaturesChangesWhatTheDecoderSees() throws {
        var sim = DaySim(start: dayStart + 36_000)
        sim.walk(120)
        let withFeatures = ActivityContextDays.trackInput(
            windows: sim.windows, streams: sim.streams, sleep: [], exercise: [],
            dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: "v")
        var stripped = sim.windows
        for i in stripped.indices { stripped[i].features = [:] }
        let without = ActivityContextDays.trackInput(
            windows: stripped, streams: sim.streams, sleep: [], exercise: [],
            dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: "v")
        XCTAssertEqual(withFeatures.imuWindows.count, sim.windows.count)
        XCTAssertTrue(without.imuWindows.isEmpty)
        XCTAssertEqual(without.encoderWindows.count, sim.windows.count, "the encoder windows are unaffected")
    }

    func testThePayloadIsDeterministic() throws {
        var sim = DaySim(start: dayStart + 36_000)
        sim.still(90); sim.walk(60)
        let input = ActivityContextDays.trackInput(
            windows: sim.windows, streams: sim.streams, sleep: [], exercise: [],
            dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: "hart-activity-1")
        let a = try build(input, generatedAt: 1_789_500_000)
        let b = try build(input, generatedAt: 1_789_500_000)
        XCTAssertEqual(a.payloadText, b.payloadText)
        let c = try build(input, generatedAt: 1_789_500_001)
        XCTAssertNotEqual(a.payloadText, c.payloadText, "only generated_at differs")
        XCTAssertEqual(a.runs, c.runs)
    }

    /// The run that is still open when data reaches midnight is stamped one publish interval past its last
    /// state. A day document must not claim the next day's first seconds.
    func testRunsNeverSpillPastTheEndOfTheDay() throws {
        // The decoder publishes on the grid of multiples of five seconds, which midnight sits on, except
        // that the first observation after a gap of two intervals publishes late, off the grid. A run
        // opened by such a tick in the last seconds of the day ends past midnight.
        struct Scenario { var name: String; var build: (inout DaySim) -> Void; var overshoots: Bool }
        let scenarios = [
            Scenario(name: "continuous to midnight", build: { $0.still(240) }, overshoots: false),
            Scenario(name: "late tick after a gap", build: { $0.still(100); $0.gap(26); $0.still(4) }, overshoots: true),
        ]
        for scenario in scenarios {
            var probe = DaySim(start: 0)
            scenario.build(&probe)
            var sim = DaySim(start: dayEnd - probe.ts)
            scenario.build(&sim)
            XCTAssertEqual(sim.ts, dayEnd, scenario.name)
            let input = ActivityContextDays.trackInput(
                windows: sim.windows, streams: sim.streams, sleep: [], exercise: [],
                dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: "hart-activity-1")

            let track = ActivityContextTrackBuilder.build(input)
            let unclipped = ActivityContextDayDocument(track: track, input: input, generatedAt: 0, includeSnapshot: false)
            let spills = (unclipped.runs.last?.end ?? 0) > dayEnd
            XCTAssertEqual(spills, scenario.overshoots, "\(scenario.name): the library's own run end")

            let doc = try XCTUnwrap(try object(try build(input).payloadText)["document"] as? [String: Any])
            let runs = try XCTUnwrap(doc["runs"] as? [[String: Any]])
            XCTAssertFalse(runs.isEmpty, scenario.name)
            for run in runs {
                XCTAssertLessThanOrEqual(try XCTUnwrap(run["e"] as? Int), dayEnd, scenario.name)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(run["s"] as? Int), dayStart, scenario.name)
            }
            XCTAssertLessThanOrEqual(try XCTUnwrap(doc["data_through"] as? Int), dayEnd, scenario.name)
            let summary = try XCTUnwrap(doc["summary"] as? [String: Any])
            let labelled = (summary["label_s"] as? [String: Int] ?? [:]).values.reduce(0, +)
            let unclear = summary["unclear_s"] as? Int ?? 0
            XCTAssertEqual(labelled + unclear,
                           runs.reduce(0) { $0 + (($1["e"] as? Int ?? 0) - ($1["s"] as? Int ?? 0)) },
                           "\(scenario.name): the summary describes the runs that are stored")
        }
    }

    /// Six hours of wear alternating a desk stretch and a walk every few minutes (a busy shape for the run
    /// count; a full day measured 1,075 runs / 450 KB, well inside what the RPC accepts). A full day takes
    /// about 19 s in a debug build (about 0.8 s in release), so the day is kept short here.
    func testBusyWearStaysWithinTheRpcLimits() throws {
        var sim = DaySim(start: dayStart + 8 * 3_600)
        let stop = dayStart + 14 * 3_600
        while sim.ts < stop {
            sim.still(min(240, stop - sim.ts))
            sim.walk(min(90, stop - sim.ts))
        }
        let input = ActivityContextDays.trackInput(
            windows: sim.windows, streams: sim.streams, sleep: [], exercise: [],
            dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: "hart-activity-1")
        let built = try build(input)
        XCTAssertEqual(built.observedSeconds, 6 * 3_600)
        XCTAssertGreaterThan(built.runs, 100, "the transitions must show up as separate runs")
        XCTAssertLessThan(built.runs, 20_000, "the RPC refuses more runs than this")
        XCTAssertLessThan(built.events, 10_000)
        XCTAssertLessThan(built.payloadText.utf8.count, 16 * 1024 * 1024)
    }

    func testADayWithNoDataIsStillAValidDocument() throws {
        let input = ActivityContextDays.trackInput(
            windows: [], streams: .init(), sleep: [], exercise: [],
            dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: "v")
        let built = try build(input)
        XCTAssertEqual(built.runs, 0)
        XCTAssertEqual(built.events, 0)
        XCTAssertEqual(built.observedSeconds, 0)
        let doc = try XCTUnwrap(try object(built.payloadText)["document"] as? [String: Any])
        XCTAssertEqual((doc["runs"] as? [Any])?.count, 0)
        XCTAssertEqual((doc["events"] as? [Any])?.count, 0)
        XCTAssertNil(doc["data_through"], "nothing decoded, nothing covered")
        XCTAssertNil(doc["latest"])
    }

    // MARK: - Logging

    /// Postgres appends DETAIL lines that, for a constraint failure, repeat the whole offending row.
    func testFailureReasonsNeverCarryTheDocument() {
        let leaky = PostgresClient.Error(
            message: "query failed: status=PGRES_FATAL_ERROR ERROR:  new row for relation \"activity_context_days\" violates check constraint \"x\"\nDETAIL:  Failing row contains ({\"runs\": [secret health data]}).\n [sqlstate=23514]",
            sqlstate: "23514", kind: .other)
        let reason = ActivityContextDays.safeReason(leaky)
        XCTAssertTrue(reason.contains("violates check constraint"))
        XCTAssertTrue(reason.contains("sqlstate=23514"))
        XCTAssertFalse(reason.contains("secret"))
        XCTAssertFalse(reason.contains("DETAIL"))
        XCTAssertFalse(reason.contains("\n"))
        XCTAssertLessThanOrEqual(reason.count, 240)

        XCTAssertEqual(ActivityContextDays.safeReason(WorkerError.malformed("boom")).isEmpty, false)
    }

    // MARK: - Sleep outside logged nights (audit D1-02)

    func testAStoredDayCountsAsAwakeOnlyOnceItHasSettled() {
        let settle = ActivityContextDays.streamsSleepSettleSeconds
        XCTAssertFalse(ActivityContextDays.sleepKnown(now: dayEnd - 1, dayEnd: dayEnd), "the day is still running")
        XCTAssertFalse(ActivityContextDays.sleepKnown(now: dayEnd + settle - 1, dayEnd: dayEnd),
                       "the night across midnight may not be logged yet")
        XCTAssertTrue(ActivityContextDays.sleepKnown(now: dayEnd + settle, dayEnd: dayEnd))
    }
}
