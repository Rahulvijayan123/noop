import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// Pure tests for the dense intraday series: bucket layout, the additive parity of steps and calories with
/// the daily kernels, the gates on HRV / respiratory rate / resting heart rate, and the publish payload.
final class IntradaySeriesTests: XCTestCase {
    /// A multiple of 300, so epoch-aligned and day-aligned buckets coincide in the fixtures.
    private let day0 = 1_790_000_100
    private var day1: Int { day0 + 86_400 }
    private let profile = UserProfile(weightKg: 70, heightCm: 175, age: 30, sex: "male")

    // MARK: - Fixtures

    private func hr(_ from: Int, _ to: Int, bpm: Int, every: Int = 1) -> [HRSample] {
        stride(from: from, to: to, by: every).map { HRSample(ts: $0, bpm: bpm) }
    }

    private func still(_ from: Int, _ to: Int) -> [GravitySample] {
        stride(from: from, to: to, by: 1).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
    }

    private func moving(_ from: Int, _ to: Int) -> [GravitySample] {
        stride(from: from, to: to, by: 1).map { t in
            t.isMultiple(of: 2) ? GravitySample(ts: t, x: 0, y: 0, z: 1) : GravitySample(ts: t, x: 0.6, y: 0, z: 0.8)
        }
    }

    private func beats(_ from: Int, seconds: Int, rr: (Int) -> Double) -> [RRInterval] {
        var out: [RRInterval] = []
        var t = Double(from)
        var i = 0
        while t < Double(from + seconds) {
            let ms = Int(rr(i).rounded())
            out.append(RRInterval(ts: Int(t), rrMs: ms))
            t += Double(ms) / 1000.0
            i += 1
        }
        return out
    }

    /// RMSSD is exactly 40 ms: every successive difference is +-40.
    private func alternating(_ i: Int) -> Double { i.isMultiple(of: 2) ? 800 : 840 }

    private func inputs(hr: [HRSample] = [], rr: [RRInterval] = [], gravity: [GravitySample] = [],
                        steps: [StepSample] = [], restingHR: Int? = 52, tuning: IntradaySeries.Tuning = .init(),
                        start: Int? = nil, end: Int? = nil) -> IntradaySeries.Inputs {
        IntradaySeries.Inputs(dayStart: start ?? day0, dayEnd: end ?? day1, hr: hr, rr: rr, gravity: gravity,
                              steps: steps, profile: profile, restingHR: restingHR, tuning: tuning)
    }

    private func point(_ series: [IntradaySeries.Metric: [IntradaySeries.Point]], _ metric: IntradaySeries.Metric,
                       bucket: Int) -> IntradaySeries.Point? {
        series[metric]?.first { $0.ts == day0 + bucket * IntradaySeries.bucketSeconds(for: metric) }
    }

    private func sum(_ series: [IntradaySeries.Metric: [IntradaySeries.Point]], _ metric: IntradaySeries.Metric,
                     from: Int, to: Int) -> Double {
        series[metric]!.filter { $0.ts >= from && $0.ts < to }.reduce(0) { $0 + $1.value }
    }

    // MARK: - Layout

    func testBucketsPartitionALocalDayWhateverItsLength() throws {
        let ny = TimeZone(identifier: "America/New_York")!
        let spring = try XCTUnwrap(DayScorer.dayStartUnix("2026-03-08", tz: ny))
        let fall = try XCTUnwrap(DayScorer.dayStartUnix("2026-11-01", tz: ny))
        let normal = try XCTUnwrap(DayScorer.dayStartUnix("2026-06-15", tz: ny))
        for (start, buckets) in [(spring, 276), (fall, 300), (normal, 288)] {
            let end = DayScorer.nextDayStartUnix(after: start, tz: ny)
            let layout = IntradaySeries.Layout(dayStart: start, dayEnd: end)
            XCTAssertEqual(layout.count, buckets)
            XCTAssertEqual(layout.start(0), start)
            XCTAssertEqual(layout.start(layout.count - 1) + layout.length(layout.count - 1), end)
            XCTAssertEqual(layout.index(end - 1), layout.count - 1)
        }
    }

    func testAnOddLengthDayEndsInAShortBucket() {
        let layout = IntradaySeries.Layout(dayStart: day0, dayEnd: day0 + 650)
        XCTAssertEqual(layout.count, 3)
        XCTAssertEqual(layout.length(2), 50)
    }

    func testRespiratoryStepsAndCaloriesAreMinuteBucketsAndHRVAndRestingHRStayFiveMinute() {
        XCTAssertEqual(IntradaySeries.bucketSeconds(for: .hrv), 300)
        XCTAssertEqual(IntradaySeries.bucketSeconds(for: .restingHR), 300)
        for metric in [IntradaySeries.Metric.respRate, .steps, .calories] {
            XCTAssertEqual(IntradaySeries.bucketSeconds(for: metric), 60)
        }
        let layout = IntradaySeries.Layout(dayStart: day0, dayEnd: day1, width: IntradaySeries.fineBucketSeconds)
        XCTAssertEqual(layout.count, 1_440)
        XCTAssertLessThanOrEqual(layout.count, 1_500, "the database caps a metric at 1,500 points per payload")
    }

    func testEmptyInputsGiveEmptySeriesForEveryMetric() {
        let series = IntradaySeries.build(inputs())
        XCTAssertEqual(Set(series.keys), Set(IntradaySeries.Metric.allCases))
        XCTAssertTrue(series.values.allSatisfy { $0.isEmpty })
    }

    func testDataOutsideTheDayIsIgnored() {
        let series = IntradaySeries.build(inputs(hr: hr(day0 - 600, day0, bpm: 60) + hr(day1, day1 + 600, bpm: 60)))
        XCTAssertTrue(series[.calories]!.isEmpty)
        XCTAssertTrue(series[.restingHR]!.isEmpty)
    }

    // MARK: - Steps

    private func counterSamples(_ from: Int, _ to: Int, start: Int, perSecond: (Int) -> Int,
                                activityClass: (Int) -> Int? = { _ in 1 }) -> [StepSample] {
        var counter = start
        var out: [StepSample] = []
        for t in from..<to {
            counter = (counter + perSecond(t)) & 0xFFFF
            out.append(StepSample(ts: t, counter: counter, activityClass: activityClass(t)))
        }
        return out
    }

    func testStepBucketsSumToTheDailyTotalAcrossWrapsGapsAndJumps() throws {
        var samples = counterSamples(day0, day0 + 1_800, start: 65_400) { t in (t / 60).isMultiple(of: 2) ? 2 : 0 }
        // A 200 s dropout that held 100 plausible ticks, and a reboot-sized jump the kernel rejects.
        let last = samples.last!
        samples.append(StepSample(ts: last.ts + 200, counter: (last.counter + 100) & 0xFFFF, activityClass: 1))
        let afterGap = samples.last!
        samples.append(StepSample(ts: afterGap.ts + 1, counter: (afterGap.counter + 700) & 0xFFFF, activityClass: 1))
        samples += counterSamples(afterGap.ts + 2, afterGap.ts + 900, start: samples.last!.counter) { _ in 1 }

        let expected = try XCTUnwrap(StepsCounter.stepsInWindow(samples))
        let series = IntradaySeries.build(inputs(steps: samples))
        let sum = series[.steps]!.reduce(0) { $0 + $1.value }
        XCTAssertEqual(sum, Double(expected), accuracy: 1e-9)
        XCTAssertGreaterThan(series[.steps]!.count, 3)
    }

    func testStepBucketsKeepBoutBlocksAndStillSumToTheDailyTotal() throws {
        // The strap credits the first six steps of a bout as one still-labelled record, then 2 ticks a second.
        var counter = 1_000
        var samples: [StepSample] = []
        func quiet(_ from: Int, _ to: Int) {
            for t in from..<to { samples.append(StepSample(ts: t, counter: counter, activityClass: 0)) }
        }
        func bout(at start: Int, smoothSeconds: Int) {
            counter += 6
            samples.append(StepSample(ts: start, counter: counter, activityClass: 0))
            for t in (start + 1)...(start + smoothSeconds) {
                counter += 2
                samples.append(StepSample(ts: t, counter: counter, activityClass: 1))
            }
        }
        quiet(day0, day0 + 60)
        bout(at: day0 + 60, smoothSeconds: 5)      // the block is the first second of minute 1
        quiet(day0 + 66, day0 + 300)
        bout(at: day0 + 300, smoothSeconds: 5)
        quiet(day0 + 306, day0 + 600)

        let series = IntradaySeries.build(inputs(steps: samples))
        XCTAssertEqual(StepsCounter.stepsInWindow(samples), 32)
        XCTAssertEqual(series[.steps]!.reduce(0) { $0 + $1.value }, 32, accuracy: 1e-9)
        XCTAssertEqual(point(series, .steps, bucket: 1)?.value, 16, "block 6 + five 2-tick seconds")
        XCTAssertEqual(point(series, .steps, bucket: 5)?.value, 16)
        XCTAssertEqual(point(series, .steps, bucket: 0)?.value, 0)
    }

    func testStepBucketsApplyTheCalibratedTicksPerStep() throws {
        let samples = counterSamples(day0, day0 + 900, start: 100) { _ in 2 }
        var calibrated = profile
        calibrated.stepTicksPerStep = 2.5
        var input = inputs(steps: samples)
        input.profile = calibrated
        let sum = IntradaySeries.build(input)[.steps]!.reduce(0) { $0 + $1.value }
        XCTAssertEqual(sum, Double(try XCTUnwrap(StepsCounter.stepsInWindow(samples))) / 2.5, accuracy: 1e-9)
        calibrated.stepTicksPerStep = 0.1
        input.profile = calibrated
        let floored = IntradaySeries.build(input)[.steps]!.reduce(0) { $0 + $1.value }
        XCTAssertEqual(floored, Double(try XCTUnwrap(StepsCounter.stepsInWindow(samples))) / 0.5, accuracy: 1e-9,
                       "the daily total floors the divisor at 0.5, so the buckets must too")
    }

    func testUnclassedBucketInsideAClassedDayCountsNothingJustLikeTheDailyTotal() throws {
        let classed = counterSamples(day0, day0 + 300, start: 0) { _ in 1 }
        let unclassed = counterSamples(day0 + 300, day0 + 600, start: classed.last!.counter + 1, perSecond: { _ in 1 },
                                       activityClass: { _ in nil })
        let samples = classed + unclassed
        let series = IntradaySeries.build(inputs(steps: samples))
        XCTAssertEqual(point(series, .steps, bucket: 5)?.value, 0, "the first minute after the classed run")
        XCTAssertEqual(series[.steps]!.reduce(0) { $0 + $1.value }, Double(try XCTUnwrap(StepsCounter.stepsInWindow(samples))),
                       accuracy: 1e-9)

        let legacySamples = samples.map { StepSample(ts: $0.ts, counter: $0.counter) }
        let legacy = IntradaySeries.build(inputs(steps: legacySamples))
        let legacyTotal = Double(try XCTUnwrap(StepsCounter.stepsInWindow(legacySamples)))
        XCTAssertEqual(legacy[.steps]!.reduce(0) { $0 + $1.value }, legacyTotal, accuracy: 1e-9,
                       "a wholly unclassed day keeps the counter-only estimate")
        XCTAssertGreaterThan(legacyTotal, series[.steps]!.reduce(0) { $0 + $1.value })
    }

    func testAMeasuredZeroIsReportedAsZeroNotMissing() {
        let samples = counterSamples(day0, day0 + 600, start: 5) { _ in 0 }
        let series = IntradaySeries.build(inputs(steps: samples))
        XCTAssertEqual(series[.steps]!.map(\.value), [Double](repeating: 0, count: 10))
    }

    // MARK: - Calories

    private func wanderingHeartRate(_ from: Int, _ to: Int) -> [HRSample] {
        var state: UInt64 = 0x9E3779B97F4A7C15
        var bpm = 62.0
        var out: [HRSample] = []
        for t in from..<to {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let step = Double(Int(state >> 33) % 7 - 3)
            bpm = min(165, max(48, bpm + step))
            if (t / 700) % 5 == 3 { bpm = max(bpm, 140) }
            if t % 997 < 40 { continue }
            out.append(HRSample(ts: t, bpm: Int(bpm)))
            if t % 211 == 0 { out.append(HRSample(ts: t, bpm: Int(bpm) + 9)) }
        }
        return out
    }

    func testCalorieBucketsSumToTheDailyEnergyEstimate() {
        let samples = wanderingHeartRate(day0, day0 + 14_400)
        for resting in [52, nil] as [Int?] {
            let hrmax = StrainScorer.tanakaHRmax(age: profile.age)
            let expected = Calories.estimateDayEnergy(samples, profile: profile, hrmax: hrmax,
                                                      restingHR: resting.map(Double.init)).totalKcal
            let series = IntradaySeries.build(inputs(hr: samples, restingHR: resting))
            let sum = series[.calories]!.reduce(0) { $0 + $1.value }
            XCTAssertEqual(sum, expected, accuracy: 1e-4, "resting HR \(String(describing: resting))")
            XCTAssertGreaterThan(expected, 100)
        }
    }

    func testExerciseBucketsOutBurnRestingOnes() {
        let samples = hr(day0, day0 + 300, bpm: 60) + hr(day0 + 300, day0 + 600, bpm: 160)
        let series = IntradaySeries.build(inputs(hr: samples))
        let rest = point(series, .calories, bucket: 0)!
        let exercise = point(series, .calories, bucket: 5)!
        XCTAssertGreaterThan(exercise.value, rest.value * 2)
        XCTAssertEqual(rest.samples, 60)
        XCTAssertEqual(rest.coverage, 1.0, accuracy: 1e-9)
        XCTAssertEqual(series[.calories]!.count, 10, "one point per minute")
        XCTAssertGreaterThan(sum(series, .calories, from: day0 + 300, to: day0 + 600),
                             sum(series, .calories, from: day0, to: day0 + 300) * 2)
    }

    func testAMinuteOfCaloriesAppearsAsSoonAsItsHeartRateDoes() {
        let series = IntradaySeries.build(inputs(hr: hr(day0, day0 + 130, bpm: 62)))
        XCTAssertEqual(series[.calories]!.map(\.ts), [day0, day0 + 60, day0 + 120])
    }

    func testSparseHeartRateStillAccountsForTheWholeObservedSpan() {
        let samples = hr(day0, day0 + 900, bpm: 62, every: 30)
        let expected = Calories.estimateDayEnergy(samples, profile: profile,
                                                  hrmax: StrainScorer.tanakaHRmax(age: profile.age), restingHR: 52).totalKcal
        let sum = IntradaySeries.build(inputs(hr: samples))[.calories]!.reduce(0) { $0 + $1.value }
        XCTAssertEqual(sum, expected, accuracy: 1e-5)
    }

    // MARK: - Heart rate variability

    func testHRVMatchesTheKernelOnAQuietBucket() throws {
        let rr = beats(day0, seconds: 300, rr: alternating)
        let series = IntradaySeries.build(inputs(rr: rr, gravity: still(day0, day0 + 300)))
        let p = try XCTUnwrap(point(series, .hrv, bucket: 0))
        XCTAssertEqual(p.value, 40.0, accuracy: 0.05)
        XCTAssertEqual(p.value, try XCTUnwrap(HRVAnalyzer.analyze(rawRR: rr.map { Double($0.rrMs) }).rmssd), accuracy: 0.05)
        XCTAssertEqual(p.samples, rr.count)
        XCTAssertEqual(p.coverage, 1.0, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(p.motion), 0, accuracy: 1e-9)
    }

    func testHRVSkipsADropoutInsteadOfSplicingAcrossIt() throws {
        // Two runs at different heart rates with 60 s of nothing between them. Differenced across the gap
        // the join would add one ~200 ms step; each run alone has RMSSD 40.
        let first = beats(day0, seconds: 100, rr: alternating)
        let second = beats(day0 + 160, seconds: 140) { i in i.isMultiple(of: 2) ? 1000 : 1040 }
        let series = IntradaySeries.build(inputs(rr: first + second, gravity: still(day0, day0 + 300)))
        let p = try XCTUnwrap(point(series, .hrv, bucket: 0))
        XCTAssertEqual(p.value, 40.0, accuracy: 0.1)
        XCTAssertLessThan(p.coverage, 1.0)
    }

    func testHRVNeedsEnoughCleanBeatsAndEnoughOfTheBucket() {
        func hrv(seconds: Int) -> IntradaySeries.Point? {
            point(IntradaySeries.build(inputs(rr: beats(day0, seconds: seconds, rr: alternating),
                                              gravity: still(day0, day0 + 300))), .hrv, bucket: 0)
        }
        XCTAssertNil(hrv(seconds: 30), "fewer than 45 beats")
        XCTAssertNil(hrv(seconds: 45), "enough beats, but only 15% of the bucket is beat-time")
        XCTAssertNotNil(hrv(seconds: 75))
    }

    func testHRVIsWithheldWhileTheWristIsMoving() {
        let rr = beats(day0, seconds: 300, rr: alternating)
        XCTAssertNotNil(point(IntradaySeries.build(inputs(rr: rr, gravity: still(day0, day0 + 300))), .hrv, bucket: 0))
        let series = IntradaySeries.build(inputs(rr: rr, gravity: moving(day0, day0 + 300)))
        XCTAssertNil(point(series, .hrv, bucket: 0))
        // Without a motion channel there is nothing to gate on, so the bucket is judged on its beats alone.
        XCTAssertNotNil(point(IntradaySeries.build(inputs(rr: rr)), .hrv, bucket: 0))
    }

    func testHRVRefusesADuplicatedFeed() {
        let rr = beats(day0, seconds: 300, rr: alternating)
        let doubled = rr.flatMap { [$0, $0] }
        let series = IntradaySeries.build(inputs(rr: doubled, gravity: still(day0, day0 + 300)))
        XCTAssertNil(point(series, .hrv, bucket: 0), "beat-time twice the wall clock is a double-counted feed")
        XCTAssertNil(point(series, .respRate, bucket: 0))
    }

    func testHRVRefusesAnImplausibleValue() {
        let rr = beats(day0, seconds: 300) { i in i.isMultiple(of: 2) ? 1050 : 1450 }
        let series = IntradaySeries.build(inputs(rr: rr, gravity: still(day0, day0 + 300)))
        XCTAssertNil(point(series, .hrv, bucket: 0), "an RMSSD of 400 ms is outside the 5-250 ms band the baselines accept")
    }

    // MARK: - Respiratory rate

    private func breathing(_ from: Int, seconds: Int, perMinute: Double) -> [RRInterval] {
        var t = Double(from)
        var out: [RRInterval] = []
        while t < Double(from + seconds) {
            let rr = 900.0 + 60.0 * sin(2 * Double.pi * (t - Double(from)) * perMinute / 60.0)
            out.append(RRInterval(ts: Int(t), rrMs: Int(rr.rounded())))
            t += rr / 1000.0
        }
        return out
    }

    func testRespiratoryRateIsOnePointPerMinuteOverATwoMinuteWindow() throws {
        let rr = breathing(day0, seconds: 900, perMinute: 15)
        let series = IntradaySeries.build(inputs(rr: rr, gravity: still(day0, day0 + 900)))
        let points = series[.respRate]!
        XCTAssertGreaterThanOrEqual(points.count, 13, "a point for nearly every one of the 15 minutes")
        XCTAssertTrue(points.allSatisfy { ($0.ts - day0) % 60 == 0 })
        let p = try XCTUnwrap(point(series, .respRate, bucket: 8))
        XCTAssertEqual(p.value, 15.0, accuracy: 2.0)
        XCTAssertGreaterThan(p.samples, 15, "the window pools about two minutes of breaths")
        XCTAssertGreaterThanOrEqual(p.coverage, 0.33)
        XCTAssertEqual(try XCTUnwrap(p.motion), 0, accuracy: 1e-9)
    }

    func testFasterBreathingReadsHigher() throws {
        func rate(_ perMinute: Double) throws -> Double {
            let rr = breathing(day0, seconds: 900, perMinute: perMinute)
            let series = IntradaySeries.build(inputs(rr: rr, gravity: still(day0, day0 + 900)))
            return try XCTUnwrap(point(series, .respRate, bucket: 8)).value
        }
        let slow = try rate(10)
        let fast = try rate(20)
        XCTAssertGreaterThan(fast, slow + 4)
    }

    /// The strap's daytime R-R comes in runs with holes between them. Each hole used to spoil every 300 s
    /// window it touched, which left roughly one daytime bucket in four with a rate; read per run, most
    /// minutes that sit near a run have one.
    func testRespiratoryRateSurvivesDropoutsThatEmptiedTheOldFiveMinuteWindows() {
        var rr: [RRInterval] = []
        for k in 0..<10 { rr += breathing(day0 + k * 110, seconds: 70, perMinute: 15) }
        XCTAssertTrue(SleepStager.respRateFromRR(rr, start: day0, end: day0 + 1_100).isNaN,
                      "this stream has no clean 300 s window for the nightly kernel")
        let series = IntradaySeries.build(inputs(rr: rr, gravity: still(day0, day0 + 1_100)))
        let points = series[.respRate]!
        XCTAssertGreaterThanOrEqual(points.count, 8)
        for p in points {
            XCTAssertEqual(p.value, 15.0, accuracy: 3.0, "minute at +\(p.ts - day0) s")
            if p.ts > day0 { XCTAssertLessThan(p.coverage, 1.0, "a window that spans a hole is not fully covered") }
        }
    }

    func testRespiratoryRateIsWithheldWhileMovingOrWithoutNewBeats() {
        let rr = breathing(day0, seconds: 600, perMinute: 15)
        let moved = IntradaySeries.build(inputs(rr: rr, gravity: moving(day0, day0 + 600)))
        XCTAssertTrue(moved[.respRate]!.isEmpty, "a moving wrist gets no respiratory rate")
        // Once the beats stop, no minute may repeat the previous window's answer.
        let gap = IntradaySeries.build(inputs(rr: rr, gravity: still(day0, day0 + 900)))
        XCTAssertNotNil(point(gap, .respRate, bucket: 8))
        XCTAssertNil(point(gap, .respRate, bucket: 10))
        XCTAssertNil(point(gap, .respRate, bucket: 12))
        XCTAssertTrue(gap[.respRate]!.allSatisfy { $0.ts < day0 + 600 })
    }

    func testRespiratoryRateIgnoresBeatsOutsideTheDay() {
        let before = breathing(day0 - 600, seconds: 600, perMinute: 15)
        let series = IntradaySeries.build(inputs(rr: before, gravity: still(day0, day0 + 600)))
        XCTAssertTrue(series[.respRate]!.isEmpty)
    }

    // MARK: - Resting heart rate

    func testRestingHeartRateIsTheLowestQuietBinOfTheTrailingHour() throws {
        // Quiet bins 0,1,2,5,6 at 60,58,56,70,66; every other bin is a walk at a deceptively low 40.
        let quiet: [Int: Int] = [0: 60, 1: 58, 2: 56, 5: 70, 6: 66]
        var samples: [HRSample] = []
        var gravity: [GravitySample] = []
        for bucket in 0..<12 {
            let from = day0 + bucket * 300
            samples += hr(from, from + 300, bpm: quiet[bucket] ?? 40)
            gravity += quiet[bucket] != nil ? still(from, from + 300) : moving(from, from + 300)
        }
        let series = IntradaySeries.build(inputs(hr: samples, gravity: gravity))
        XCTAssertNil(point(series, .restingHR, bucket: 0), "one quiet bin is not enough")
        XCTAssertNil(point(series, .restingHR, bucket: 1))
        XCTAssertEqual(try XCTUnwrap(point(series, .restingHR, bucket: 2)).value, 56, accuracy: 1e-9)
        let walking = try XCTUnwrap(point(series, .restingHR, bucket: 3))
        XCTAssertEqual(walking.value, 56, accuracy: 1e-9, "a walking bin carries the floor of the quiet ones before it")
        XCTAssertGreaterThan(try XCTUnwrap(walking.motion), 0.9)
        let last = try XCTUnwrap(point(series, .restingHR, bucket: 11))
        XCTAssertEqual(last.value, 56, accuracy: 1e-9)
        XCTAssertEqual(last.coverage, 5.0 / 12.0, accuracy: 1e-3)
        XCTAssertEqual(last.samples, 300)
    }

    func testRestingHeartRateForgetsABinOnceItLeavesTheTrailingHour() throws {
        var samples: [HRSample] = []
        for bucket in 0..<20 {
            let from = day0 + bucket * 300
            samples += hr(from, from + 300, bpm: bucket < 3 ? 50 : 70)
        }
        let series = IntradaySeries.build(inputs(hr: samples, gravity: still(day0, day0 + 6_000)))
        XCTAssertEqual(try XCTUnwrap(point(series, .restingHR, bucket: 5)).value, 50, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(point(series, .restingHR, bucket: 19)).value, 70, accuracy: 1e-9)
    }

    func testThinBinsCannotBecomeTheRestingFloor() {
        let samples = hr(day0, day0 + 4, bpm: 30) + hr(day0 + 300, day0 + 600, bpm: 60) + hr(day0 + 600, day0 + 900, bpm: 61)
            + hr(day0 + 900, day0 + 1_200, bpm: 62)
        let series = IntradaySeries.build(inputs(hr: samples, gravity: still(day0, day0 + 1_200)))
        XCTAssertEqual(point(series, .restingHR, bucket: 3)?.value, 60)
    }

    // MARK: - Payload

    func testPayloadCarriesEveryMetricAndSerialisesToJSON() throws {
        let rr = beats(day0, seconds: 300, rr: alternating)
        let series = IntradaySeries.build(inputs(hr: hr(day0, day0 + 300, bpm: 60), rr: rr, gravity: still(day0, day0 + 300)))
        let payload = IntradaySeries.payload(dayStart: day0, dayEnd: day1, series: series)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
        XCTAssertEqual(payload["algorithm_version"] as? String, IntradaySeries.algorithmVersion)
        XCTAssertEqual(payload["bucket_seconds"] as? Int, 300)
        XCTAssertEqual(payload["metric_bucket_seconds"] as? [String: Int], [
            "hrv_rmssd_ms": 300, "resting_hr_bpm": 300, "resp_rate_bpm": 60, "steps": 60, "calories_kcal": 60,
        ])
        let window = try XCTUnwrap(payload["window"] as? [String: Int])
        XCTAssertEqual(window, ["start": day0, "end": day1])
        let metrics = try XCTUnwrap(payload["metrics"] as? [String: Any])
        XCTAssertEqual(Set(metrics.keys), Set(IntradaySeries.Metric.allCases.map(\.rawValue)))
        XCTAssertEqual((metrics["steps"] as? [Any])?.count, 0, "an empty metric is sent so the database clears its window")
        let hrv = try XCTUnwrap(metrics["hrv_rmssd_ms"] as? [[Any]])
        XCTAssertEqual(hrv.count, 1)
        XCTAssertEqual(hrv[0].count, 5)
        XCTAssertEqual(hrv[0][0] as? Int, day0)
        let text = try jsonText(payload)
        XCTAssertTrue(text.contains("\"hrv_rmssd_ms\""))
    }

    func testNilMotionIsSentAsJSONNull() throws {
        let rr = beats(day0, seconds: 300, rr: alternating)
        let series = IntradaySeries.build(inputs(rr: rr))
        let payload = IntradaySeries.payload(dayStart: day0, dayEnd: day1, series: series)
        let hrv = try XCTUnwrap((payload["metrics"] as? [String: Any])?["hrv_rmssd_ms"] as? [[Any]])
        XCTAssertTrue(hrv[0][4] is NSNull)
        let round = try JSONSerialization.jsonObject(with: Data(try jsonText(payload).utf8)) as? [String: Any]
        XCTAssertNotNil(round)
    }

    func testAFullDayOfDataFillsEveryMetric() {
        let samples = wanderingHeartRate(day0, day1)
        let rr = beats(day0, seconds: 80_000) { i in 820 + 25 * sin(Double(i) / 3) }
        let steps = counterSamples(day0, day1, start: 0) { t in (t / 600).isMultiple(of: 3) ? 1 : 0 }
        let series = IntradaySeries.build(inputs(hr: samples, rr: rr, gravity: still(day0, day1), steps: steps))
        XCTAssertGreaterThan(series[.calories]!.count, 1_400)
        XCTAssertGreaterThan(series[.steps]!.count, 1_400)
        XCTAssertLessThanOrEqual(series[.calories]!.count, 1_500)
        XCTAssertGreaterThan(series[.hrv]!.count, 250)
        XCTAssertGreaterThan(series[.restingHR]!.count, 250)
        for metric in IntradaySeries.Metric.allCases {
            let stamps = series[metric]!.map(\.ts)
            XCTAssertEqual(stamps, stamps.sorted(), "\(metric) points are in time order")
            XCTAssertEqual(Set(stamps).count, stamps.count, "\(metric) has one point per bucket")
            XCTAssertTrue(stamps.allSatisfy { ($0 - day0) % IntradaySeries.bucketSeconds(for: metric) == 0 })
        }
    }

    private func jsonText(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
