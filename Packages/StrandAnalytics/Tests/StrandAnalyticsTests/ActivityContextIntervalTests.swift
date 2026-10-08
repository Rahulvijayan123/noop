import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Runs → timestamp-aligned intervals, the physiology measured inside them, and the as-of lookup that
/// downstream systems join observations through.
final class ActivityContextIntervalTests: XCTestCase {

    private typealias Posture = HeadProbabilities<PostureClass>

    private let t0 = 1_760_000_000

    private typealias Kind = RunKind

    private func run(_ kind: Kind, _ from: Int, _ to: Int, quality: Double = 0.8,
                     intensity: Double? = 0.3, line: UInt = #line) -> ActivityContextRun {
        fixtureRun(kind, from, to, quality: quality, intensity: intensity, line: line)
    }

    private func build(_ runs: [ActivityContextRun], hr: [HRSample] = [], steps: [StepSample] = [],
                       rr: [RRInterval] = [], config: ActivityContextIntervalBuilder.Config = .init())
        -> [ActivityContextInterval] {
        ActivityContextIntervalBuilder.build(runs: runs, hr: hr, steps: steps, rr: rr, config: config)
    }

    // MARK: Shaping

    func testRunsOfOneSituationMergeIntoOneIntervalWithDurationWeightedQuality() throws {
        let out = build([run(.desk, t0, t0 + 100, quality: 0.9), run(.desk, t0 + 100, t0 + 400, quality: 0.7)])
        let iv = try XCTUnwrap(out.first)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(iv.start, t0)
        XCTAssertEqual(iv.end, t0 + 400)
        XCTAssertEqual(iv.activityClass, .sittingDesk)
        XCTAssertEqual(iv.evidenceQuality, (0.9 * 100 + 0.7 * 300) / 400, accuracy: 0.002)
        XCTAssertEqual(iv.posture, .seatedLikely)
        XCTAssertEqual(iv.locomotion, .stationary)
        XCTAssertEqual(iv.armBehavior, .deskLike)
        XCTAssertEqual(iv.sleep, .awake)
        XCTAssertEqual(iv.wear, .onWrist)
    }

    func testAGapLargerThanTheMergeGapKeepsIntervalsApart() {
        XCTAssertEqual(build([run(.desk, t0, t0 + 120), run(.desk, t0 + 128, t0 + 300)]).count, 1,
                       "8 s of missing data inside one situation is not a break")
        let apart = build([run(.desk, t0, t0 + 120), run(.desk, t0 + 150, t0 + 300)])
        XCTAssertEqual(apart.map { [$0.start, $0.end] }, [[t0, t0 + 120], [t0 + 150, t0 + 300]],
                       "a 30 s hole is data the decoder never saw; it stays a hole")
    }

    func testDifferentClassSleepOrWearNeverMerge() {
        XCTAssertEqual(build([run(.desk, t0, t0 + 200), run(.walking, t0 + 200, t0 + 400)]).map(\.activityClass),
                       [.sittingDesk, .walking])
        XCTAssertEqual(build([run(.asleep, t0, t0 + 300), run(.off, t0 + 300, t0 + 600)]).map(\.activityClass),
                       [.sleeping, .offWrist])
        // Same class label, different sleep context: a daytime nap run after a logged session is its own row.
        var napping = run(.sitting, t0 + 200, t0 + 400)
        napping.sleep = .unknown
        XCTAssertEqual(build([run(.sitting, t0, t0 + 200), napping]).count, 2)
    }

    func testAShortStillnessFlickerInsideOneSituationIsAbsorbed() throws {
        // Desk → sitting for 5 s → desk is one desk session with a wording wobble in the middle.
        let out = build([run(.desk, t0, t0 + 300), run(.sitting, t0 + 300, t0 + 305), run(.desk, t0 + 305, t0 + 605)])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].activityClass, .sittingDesk)
        XCTAssertEqual(out[0].start, t0)
        XCTAssertEqual(out[0].end, t0 + 605)
    }

    func testAShortMovementBurstIsNeverFoldedAway() {
        // Six seconds of walking between two desk spells is exactly what a stand reminder and an HR
        // analysis both want to see.
        let out = build([run(.desk, t0, t0 + 300), run(.walking, t0 + 300, t0 + 306), run(.desk, t0 + 306, t0 + 606)])
        XCTAssertEqual(out.map(\.activityClass), [.sittingDesk, .walking, .sittingDesk])
        XCTAssertEqual(out[1].durationSeconds, 6)
    }

    func testAFragmentNextToADifferentSituationStays() {
        let out = build([run(.desk, t0, t0 + 300), run(.sitting, t0 + 300, t0 + 306), run(.walking, t0 + 306, t0 + 500)])
        XCTAssertEqual(out.map(\.activityClass), [.sittingDesk, .sitting, .walking])
    }

    func testLongStretchesAreCutIntoNearEqualPartsNoLongerThanTheCap() {
        let out = build([run(.desk, t0, t0 + 2_000)])
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.first?.start, t0)
        XCTAssertEqual(out.last?.end, t0 + 2_000)
        for (a, b) in zip(out, out.dropFirst()) { XCTAssertEqual(a.end, b.start, "parts tile the stretch exactly") }
        XCTAssertTrue(out.allSatisfy { $0.durationSeconds <= 900 })
        XCTAssertLessThanOrEqual((out.map(\.durationSeconds).max() ?? 0) - (out.map(\.durationSeconds).min() ?? 0), 1)
        XCTAssertEqual(Set(out.map(\.activityClass)), [.sittingDesk])
        XCTAssertEqual(Set(out.map(\.confidence)).count, 1, "parts of one stretch share its reading")

        // 901 s is two near-equal rows, not a 900 s row and a 1 s sliver.
        XCTAssertEqual(build([run(.desk, t0, t0 + 901)]).map(\.durationSeconds), [451, 450])
        XCTAssertEqual(build([run(.desk, t0, t0 + 900)]).count, 1)
    }

    func testAnEightHourNightIsAboutThirtyRowsNotThirtyThousand() {
        let out = build([run(.asleep, t0, t0 + 8 * 3_600)])
        XCTAssertEqual(out.count, 32)
        XCTAssertTrue(out.allSatisfy { $0.activityClass == .sleeping && $0.sleep == .asleep })
    }

    func testRunnerUpAndHeadSummariesComeFromTheWeightedRuns() throws {
        // A seated reading with some upright mass: the runner-up names the sibling, weighted by duration.
        var seated = run(.sitting, t0, t0 + 100)
        seated.posture = Posture([.seatedLikely: 0.6, .uprightStationary: 0.3, .unknown: 0.1])
        var seatedLong = run(.sitting, t0 + 100, t0 + 400)
        seatedLong.posture = Posture([.seatedLikely: 0.6, .uprightStationary: 0.3, .unknown: 0.1])
        let iv = try XCTUnwrap(build([seated, seatedLong]).first)
        XCTAssertEqual(iv.activityClass, .sitting)
        XCTAssertEqual(iv.runnerUp, .standing)
        XCTAssertEqual(iv.runnerUpConfidence, 0.97 * 0.3, accuracy: 0.01)
        XCTAssertEqual(iv.confidence, 0.97 * 0.6, accuracy: 0.01)
    }

    func testOffWristIntervalHasNoIntensityAndFullConfidence() throws {
        let iv = try XCTUnwrap(build([run(.off, t0, t0 + 600)]).first)
        XCTAssertEqual(iv.activityClass, .offWrist)
        XCTAssertEqual(iv.confidence, 1)
        XCTAssertNil(iv.intensity)
        XCTAssertEqual(iv.wear, .offWrist)
    }

    func testEmptyAndZeroLengthInputsProduceNothing() {
        XCTAssertTrue(build([]).isEmpty)
        XCTAssertTrue(build([run(.desk, t0, t0)]).isEmpty)
    }

    func testInputOrderDoesNotMatter() {
        let a = run(.desk, t0, t0 + 200), b = run(.walking, t0 + 200, t0 + 300), c = run(.desk, t0 + 300, t0 + 600)
        XCTAssertEqual(build([a, b, c]), build([c, a, b]))
    }

    // MARK: Heart rate

    func testHeartRateStatisticsCoverOnlyTheIntervalAndIgnoreImplausibleReadings() throws {
        var hr = (0..<600).map { HRSample(ts: t0 + $0, bpm: 60 + ($0 % 5)) }       // 60...64
        hr.append(HRSample(ts: t0 + 100, bpm: 0))                                   // duplicate second, invalid
        hr.append(HRSample(ts: t0 + 101, bpm: 250))
        hr.append(HRSample(ts: t0 - 50, bpm: 150))                                  // before the interval
        let out = build([run(.desk, t0, t0 + 300), run(.walking, t0 + 300, t0 + 600)], hr: hr)
        let desk = out[0], walk = out[1]
        XCTAssertEqual(desk.hrMin, 60)
        XCTAssertEqual(desk.hrMax, 64)
        XCTAssertEqual(try XCTUnwrap(desk.hrMean), 62, accuracy: 0.1)
        XCTAssertEqual(desk.hrSamples, 300, "the invalid duplicates carry nothing")
        XCTAssertEqual(walk.hrSamples, 300)
        XCTAssertNil(build([run(.desk, t0, t0 + 300)]).first?.hrMean, "no heart rate stored, none claimed")
    }

    func testHeartRateTrendIsLeastSquaresInBeatsPerMinutePerMinute() throws {
        let rising = (0..<600).map { HRSample(ts: t0 + $0, bpm: 70 + $0 / 10) }       // +6 bpm per minute
        let iv = try XCTUnwrap(build([run(.desk, t0, t0 + 600)], hr: rising).first)
        XCTAssertEqual(try XCTUnwrap(iv.hrSlope), 6, accuracy: 0.2)

        let falling = (0..<600).map { HRSample(ts: t0 + $0, bpm: 120 - $0 / 20) }     // -3 per minute
        XCTAssertEqual(try XCTUnwrap(build([run(.desk, t0, t0 + 600)], hr: falling).first?.hrSlope), -3, accuracy: 0.2)

        let flat = (0..<600).map { HRSample(ts: t0 + $0, bpm: 64) }
        XCTAssertEqual(try XCTUnwrap(build([run(.desk, t0, t0 + 600)], hr: flat).first?.hrSlope), 0, accuracy: 0.01)
    }

    func testHeartRateTrendNeedsEnoughSamplesOverEnoughTimeAndIsClamped() throws {
        let sparse = (0..<20).map { HRSample(ts: t0 + $0 * 10, bpm: 70 + $0) }
        XCTAssertNil(build([run(.desk, t0, t0 + 300)], hr: sparse).first?.hrSlope, "20 samples are too few")
        let brief = (0..<60).map { HRSample(ts: t0 + $0, bpm: 70 + $0) }
        XCTAssertNil(build([run(.desk, t0, t0 + 300)], hr: brief).first?.hrSlope, "60 s is too short a span")
        let steep = (0..<200).map { HRSample(ts: t0 + $0, bpm: min(220, 40 + $0)) }  // ~60 bpm/min
        XCTAssertEqual(build([run(.desk, t0, t0 + 300)], hr: steep).first?.hrSlope, 30, "clamped to the artefact ceiling")
    }

    func testEachPartOfALongIntervalCarriesItsOwnHeartRate() throws {
        let hr = (0..<1_800).map { HRSample(ts: t0 + $0, bpm: $0 < 900 ? 62 : 80) }
        let out = build([run(.desk, t0, t0 + 1_800)], hr: hr)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(try XCTUnwrap(out[0].hrMean), 62, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(out[1].hrMean), 80, accuracy: 0.1)
    }

    // MARK: Steps

    private func steps(from: Int, seconds: Int, perSecond: Int, counter start: Int = 1_000) -> [StepSample] {
        (0..<seconds).map { StepSample(ts: from + $0, counter: start + $0 * perSecond, activityClass: 1) }
    }

    func testStepTicksAndCadenceCoverTheSteppingStretches() throws {
        let walking = steps(from: t0, seconds: 120, perSecond: 2)
        let iv = try XCTUnwrap(build([run(.walking, t0, t0 + 120)], steps: walking).first)
        XCTAssertEqual(iv.stepTicks, 2 * 119, "the first sample has no predecessor to difference against")
        XCTAssertEqual(try XCTUnwrap(iv.cadenceSpm), 119, accuracy: 6)

        // The counter keeps ticking after the interval: only the interval's own steps are counted.
        let tail = steps(from: t0, seconds: 400, perSecond: 2)
        XCTAssertEqual(build([run(.walking, t0, t0 + 120)], steps: tail).first?.stepTicks, 2 * 119)
    }

    func testCadenceNeedsTwentySecondsOfSteppingButTicksAlwaysCount() throws {
        let brief = steps(from: t0 + 100, seconds: 12, perSecond: 2)
        let iv = try XCTUnwrap(build([run(.desk, t0, t0 + 300)], steps: brief).first)
        XCTAssertEqual(iv.stepTicks, 22)
        XCTAssertNil(iv.cadenceSpm)
    }

    func testNoStepStreamMeansZeroTicksAndNoCadence() throws {
        let iv = try XCTUnwrap(build([run(.desk, t0, t0 + 300)]).first)
        XCTAssertEqual(iv.stepTicks, 0)
        XCTAssertNil(iv.cadenceSpm)
    }

    // MARK: Beat-to-beat

    /// Respiratory sinus arrhythmia: beat length modulated at a known breathing rate, `ts` advancing with
    /// the beats (beat-accurate, the way the strap's own R-R is).
    private func rsa(perMinute: Double, from: Int, seconds: Int, baseMs: Double = 900, depthMs: Double = 50) -> [RRInterval] {
        var out: [RRInterval] = []
        var t = Double(from)
        let end = Double(from + seconds)
        while t < end {
            let phase = (t - Double(from)) * perMinute / 60.0
            let rr = baseMs + depthMs * sin(2 * Double.pi * phase)
            out.append(RRInterval(ts: Int(t), rrMs: Int(rr.rounded())))
            t += rr / 1000.0
        }
        return out
    }

    func testStillIntervalsGetVariabilityAndRespiratoryRateFromTheirOwnBeats() throws {
        let beats = rsa(perMinute: 15, from: t0, seconds: 600)
        let iv = try XCTUnwrap(build([run(.sitting, t0, t0 + 600)], rr: beats).first)
        let rmssd = try XCTUnwrap(iv.rmssd)
        XCTAssertGreaterThan(rmssd, 15)
        XCTAssertLessThan(rmssd, 120)
        XCTAssertGreaterThanOrEqual(iv.rrBeats, 400)
        XCTAssertEqual(try XCTUnwrap(iv.respRateBpm), 15, accuracy: 1.5)
        XCTAssertGreaterThanOrEqual(iv.respBreaths, 100)
    }

    func testVariabilityIsReadFromTheIntervalsOwnBeatsOnly() throws {
        // Calm for the first ten minutes, a much deeper modulation afterwards: each interval sees its own.
        let beats = rsa(perMinute: 15, from: t0, seconds: 600, depthMs: 20) + rsa(perMinute: 15, from: t0 + 600, seconds: 600, depthMs: 80)
        let out = build([run(.sitting, t0, t0 + 600), run(.standing, t0 + 600, t0 + 1_200)], rr: beats)
        XCTAssertEqual(out.count, 2)
        XCTAssertLessThan(try XCTUnwrap(out[0].rmssd), try XCTUnwrap(out[1].rmssd))
    }

    func testNoVariabilityOrBreathingWhileMovingOrOffWrist() {
        // Realistic motion for each: a committed walk/run carries wrist intensity well above the gate
        // (walking's own strap anchor is ≈0.52; running's is higher), `.off` is excluded by wear regardless
        // of intensity. This is a MOTION gate now (`maxVariabilityIntensity`), not a fixed class list — see
        // `testLowMotionDuringANominallyMovingIntervalStillGetsVariability` for the converse.
        let beats = rsa(perMinute: 15, from: t0, seconds: 600)
        for (kind, intensity) in [(Kind.walking, 0.6), (.running, 0.8), (.off, nil)] {
            let iv = build([run(kind, t0, t0 + 600, intensity: intensity)], rr: beats).first
            XCTAssertNil(iv?.rmssd, "\(kind)")
            XCTAssertNil(iv?.respRateBpm, "\(kind)")
            XCTAssertEqual(iv?.rrBeats, 0)
            XCTAssertEqual(iv?.respBreaths, 0)
        }
    }

    func testLowMotionDuringANominallyMovingIntervalStillGetsVariability() throws {
        // A `walking`-labelled stretch whose wrist was actually still (paused at a light, a treadmill
        // pause the classifier hasn't caught up to yet) is no longer refused on sight: RR trustworthiness
        // is judged by the interval's own measured motion, not by the semantic label stuck on it.
        let beats = rsa(perMinute: 15, from: t0, seconds: 600)
        let iv = try XCTUnwrap(build([run(.walking, t0, t0 + 600, intensity: 0.1)], rr: beats).first)
        XCTAssertNotNil(iv.rmssd, "low measured motion, even under a walking label, should get a reading")
    }

    func testHighMotionDuringANominallyStillIntervalIsExcluded() throws {
        // `lightActivity` was never in the old exclusion list, so a bursty, mislabelled `lightActivity`
        // stretch used to get an RMSSD unconditionally. The motion gate now catches it on its own measured
        // intensity, which the semantic label never could.
        let beats = rsa(perMinute: 15, from: t0, seconds: 600)
        let iv = try XCTUnwrap(build([run(.light, t0, t0 + 600, intensity: 0.7)], rr: beats).first)
        XCTAssertNil(iv.rmssd, "high measured motion should be excluded even under a non-moving-family label")
    }

    func testNilIntensityDoesNotExcludeVariability() throws {
        // Absence of a motion reading is not evidence of motion (the same convention
        // `HRVAnalyzer.beatAccurateFraction` uses for a short series): a still interval that happens to
        // carry no motion stream at all is not penalised for it.
        let beats = rsa(perMinute: 15, from: t0, seconds: 600)
        let iv = try XCTUnwrap(build([run(.sitting, t0, t0 + 600, intensity: nil)], rr: beats).first)
        XCTAssertNotNil(iv.rmssd)
    }

    func testIntervalsUnderAMinuteGetNoVariabilityReading() throws {
        let beats = rsa(perMinute: 15, from: t0, seconds: 600)
        let iv = try XCTUnwrap(build([run(.sitting, t0 + 100, t0 + 140)], rr: beats).first)
        XCTAssertNil(iv.rmssd)
        XCTAssertNil(iv.respRateBpm)
    }

    func testTooFewBeatsGiveNoVariability() throws {
        let sparse = (0..<10).map { RRInterval(ts: t0 + $0 * 6, rrMs: 880 + ($0 % 2) * 40) }
        let iv = try XCTUnwrap(build([run(.sitting, t0, t0 + 300)], rr: sparse).first)
        XCTAssertNil(iv.rmssd)
    }

    func testBankedBeatsAreRefusedRatherThanShown() throws {
        // Many beats stamped on the same second (a banked record) are not beat-to-beat timing.
        var banked: [RRInterval] = []
        for k in 0..<60 {
            for j in 0..<8 { banked.append(RRInterval(ts: t0 + k * 5, rrMs: 850 + ((k + j) % 7) * 12)) }
        }
        let iv = try XCTUnwrap(build([run(.sitting, t0, t0 + 300)], rr: banked).first)
        XCTAssertNil(iv.rmssd, "banked or over-counted beats would read a plausible but wrong RMSSD")
    }

    // MARK: Lookup

    func testLookupFindsTheCoveringIntervalWithHalfOpenBounds() throws {
        let lookup = ActivityContextLookup(intervals: build([run(.desk, t0, t0 + 200), run(.walking, t0 + 200, t0 + 260),
                                                            run(.desk, t0 + 400, t0 + 600)]))
        XCTAssertNil(lookup.interval(at: t0 - 1))
        XCTAssertEqual(lookup.interval(at: t0)?.activityClass, .sittingDesk)
        XCTAssertEqual(lookup.interval(at: t0 + 199)?.activityClass, .sittingDesk)
        XCTAssertEqual(lookup.interval(at: t0 + 200)?.activityClass, .walking, "end is exclusive, start inclusive")
        XCTAssertEqual(lookup.interval(at: t0 + 259)?.activityClass, .walking)
        XCTAssertNil(lookup.interval(at: t0 + 260), "no data, no label: nothing is carried across a hole")
        XCTAssertNil(lookup.interval(at: t0 + 399))
        XCTAssertEqual(lookup.interval(at: t0 + 400)?.activityClass, .sittingDesk)
        XCTAssertNil(lookup.interval(at: t0 + 600))
    }

    func testLookupSortsItsInput() {
        let ivs = build([run(.desk, t0, t0 + 200), run(.walking, t0 + 200, t0 + 260)])
        XCTAssertEqual(ActivityContextLookup(intervals: ivs.reversed()).interval(at: t0 + 210)?.activityClass, .walking)
    }

    func testIntervalsOverlappingAWindow() {
        let lookup = ActivityContextLookup(intervals: build([run(.desk, t0, t0 + 200), run(.walking, t0 + 200, t0 + 260),
                                                            run(.desk, t0 + 400, t0 + 600)]))
        XCTAssertEqual(lookup.intervals(from: t0 + 150, to: t0 + 220).map(\.activityClass), [.sittingDesk, .walking])
        XCTAssertEqual(lookup.intervals(from: t0 + 260, to: t0 + 400).count, 0)
        XCTAssertEqual(lookup.intervals(from: t0 + 250, to: t0 + 401).map(\.activityClass), [.walking, .sittingDesk])
        XCTAssertEqual(lookup.intervals(from: t0, to: t0).count, 0)
        XCTAssertEqual(lookup.intervals(from: t0 - 1_000, to: t0 + 5_000).count, 3)
    }

    func testCompositionClipsToTheWindowAndReportsWhatWasCovered() throws {
        let lookup = ActivityContextLookup(intervals: build([run(.desk, t0, t0 + 200), run(.walking, t0 + 200, t0 + 260),
                                                            run(.desk, t0 + 400, t0 + 600)]))
        let c = lookup.composition(from: t0 + 100, to: t0 + 500)
        XCTAssertEqual(c.seconds, [.sittingDesk: 100 + 100, .walking: 60])
        XCTAssertEqual(c.windowSeconds, 400)
        XCTAssertEqual(c.coveredSeconds, 260)
        XCTAssertEqual(c.dominant, .sittingDesk)
        XCTAssertEqual(c.share(of: .walking), 60.0 / 260.0, accuracy: 1e-9)
        XCTAssertEqual(c.share(of: .running), 0)
        let none = lookup.composition(from: t0 + 260, to: t0 + 400)
        XCTAssertEqual(none.coveredSeconds, 0)
        XCTAssertNil(none.dominant)
        XCTAssertEqual(none.share(of: .sittingDesk), 0)
    }

    func testAttachAnnotatesAnySeriesWithoutCopyingTheContextIntoIt() {
        let lookup = ActivityContextLookup(intervals: build([run(.desk, t0, t0 + 200), run(.walking, t0 + 200, t0 + 260)]))
        let hr = [HRSample(ts: t0 + 10, bpm: 61), HRSample(ts: t0 + 230, bpm: 105), HRSample(ts: t0 + 900, bpm: 64)]
        let tagged = lookup.attach(hr) { $0.ts }
        XCTAssertEqual(tagged.map { $0.context?.activityClass }, [.sittingDesk, .walking, nil])
        XCTAssertEqual(tagged.map(\.item.bpm), [61, 105, 64])
    }

    // MARK: From a decoded day

    func testADecodedDayBecomesContiguousIntervalsThatAgreeWithItsStreams() throws {
        var sim = ActivitySim(start: t0)
        sim.desk(600); sim.walk(180); sim.desk(600); sim.run(120); sim.still(300)
        let input = sim.trackInput()
        let track = ActivityContextTrackBuilder.build(input)
        let document = ActivityContextDayDocument(track: track, input: input, generatedAt: t0 + 5_000)

        let intervals = ActivityContextIntervalBuilder.build(document: document, hr: input.hr, steps: input.steps)
        XCTAssertFalse(intervals.isEmpty)
        for iv in intervals {
            XCTAssertGreaterThan(iv.durationSeconds, 0)
            XCTAssertLessThanOrEqual(iv.durationSeconds, 900)
            XCTAssertTrue((0...1).contains(iv.confidence))
            XCTAssertNotNil(iv.hrMean, "the sim stores a heart rate every second")
        }
        for (a, b) in zip(intervals, intervals.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start) }

        let classes = Set(intervals.map(\.activityClass))
        XCTAssertTrue(classes.contains(.walking), "\(classes)")
        XCTAssertTrue(classes.contains(.running), "\(classes)")
        // The sim's heart rate follows what it is doing (66 seated, 104 walking, 152 running), so each
        // interval's mean must sit with the activity it was labelled with, to within the decoder's lag.
        let walkHR = try XCTUnwrap(intervals.first { $0.activityClass == .walking }?.hrMean)
        let runHR = try XCTUnwrap(intervals.first { $0.activityClass == .running }?.hrMean)
        XCTAssertGreaterThan(walkHR, 95)
        XCTAssertLessThan(walkHR, 108)
        XCTAssertGreaterThan(runHR, 125)
        let seatedHR = intervals.filter { $0.activityClass.isStationaryAwake }.compactMap(\.hrMean)
        XCTAssertFalse(seatedHR.isEmpty)
        XCTAssertTrue(seatedHR.allSatisfy { $0 < 80 }, "\(seatedHR)")
        // Seconds in intervals match the document's own per-class summary to within the folded fragments.
        let fromIntervals = ActivityContextLookup(intervals: intervals)
            .composition(from: document.dayStart, to: document.dayEnd).seconds
        let fromSummary = try XCTUnwrap(document.summary.classSeconds)
        for (cls, s) in fromIntervals {
            XCTAssertEqual(Double(s), Double(fromSummary[cls.rawValue] ?? 0), accuracy: 40, "\(cls)")
        }
        let walking = try XCTUnwrap(intervals.first { $0.activityClass == .walking })
        XCTAssertGreaterThan(walking.stepTicks, 100)
        XCTAssertNotNil(walking.cadenceSpm)
    }
}
