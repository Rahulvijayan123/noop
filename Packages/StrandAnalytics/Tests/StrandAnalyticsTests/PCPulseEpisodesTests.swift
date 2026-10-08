import XCTest
@testable import StrandAnalytics

/// Spec-02 sustained high / low pulse episodes and HR accelerations with movement over qualified inactive HR
/// (`PCPulseEpisodes.swift`). Every expected number is worked out by hand from the piecewise fixtures in the comments,
/// not read back from the implementation.
final class PCPulseEpisodesTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias P = PhysiologyContext.PulseEpisodes

    static let day = "2026-10-01"
    static let identity = PC.DayIdentity(deviceScope: "dev-1", day: day, timezoneId: "UTC",
                                         dayWindow: PC.Engine.dayInterval(day, timezoneId: "UTC"))
    static var dayStart: Int { identity.dayWindow.start }
    static var dayEnd: Int { identity.dayWindow.end }
    /// 10:00 UTC.
    static var t0: Int { dayStart + 10 * 3600 }
    static var retroCutoff: Int { dayEnd + 40 * 3600 }

    // MARK: Fixture builders

    static func track(_ segs: [(Int, Int, String?)]) -> PC.ResolvedTrack {
        PC.IntervalAlgebra.resolve(segs.enumerated().map { i, s in
            PC.LabelRecord(interval: .init(s.0, s.1), label: s.2, tieBreak: "r\(i)")
        }, source: .strapMotion, heartRateDependent: false)
    }

    /// 1 Hz samples over `[start, end)`: constant `bpm`, or alternating `bpm, bpm + 1` from the start (so a long
    /// stretch is not a stuck-signal flatline).
    static func heart(_ segs: [(Int, Int, Int)], alternate: Bool = false) -> [PC.HeartRateObservation] {
        segs.flatMap { s in (s.0..<s.1).map { PC.HeartRateObservation(ts: $0, bpm: s.2 + (alternate ? ($0 - s.0) % 2 : 0)) } }
    }
    static func alt(_ segs: [(Int, Int, Int)]) -> [PC.HeartRateObservation] { heart(segs, alternate: true) }

    static func run(hr: [PC.HeartRateObservation], track: PC.ResolvedTrack, episodes: [PC.SleepEpisode] = [],
                    bouts: [PC.ExertionBout] = [], breaks: [PC.Interval] = [], mode: PC.ProcessingMode = .retrospective,
                    cutoff: Int? = nil, config: PC.PulseEpisodeConfig = .init()) -> PC.PulseEpisodeSummary {
        P.summarize(identity: identity, observations: PC.SanitizedObservations(heartRate: hr, breaks: breaks),
                    hart: .empty(.hartEpochs), strap: track, episodes: episodes, bouts: bouts, mode: mode,
                    cutoff: cutoff ?? retroCutoff, config: config)!
    }

    static var stillAround: PC.ResolvedTrack { track([(t0 - 3600, t0 + 7200, "still")]) }
    static func calm(_ a: Int, _ b: Int) -> [PC.HeartRateObservation] { alt([(a, b, 70)]) }

    // MARK: Sustained high, hysteresis, minimum duration

    /// Still throughout. HR 70/71 [t0-1800, t0), 105 [t0, t0+300), 90 [t0+300, t0+330) (a 30 s dip, shorter than
    /// the 60 s exit hold), 105 [t0+330, t0+900), 70/71 [t0+900, t0+2700).
    /// → one episode [t0, t0+900): 900 qualified s, 870×105 + 30×90 → median 105, max 105, no censoring.
    func testSustainedHighWithABriefDipIsOneEpisode() throws {
        let t0 = Self.t0
        let hr = Self.calm(t0 - 1800, t0) + Self.heart([(t0, t0 + 300, 105), (t0 + 300, t0 + 330, 90),
                                                         (t0 + 330, t0 + 900, 105)]) + Self.calm(t0 + 900, t0 + 2700)
        let s = Self.run(hr: hr, track: Self.stillAround)
        XCTAssertEqual(s.state, .supported)
        XCTAssertEqual(s.episodes.count, 1)
        let e = try XCTUnwrap(s.episodes.first)
        XCTAssertEqual(e.kind, P.kindHigh)
        XCTAssertEqual(e.interval, PC.Interval(t0, t0 + 900))
        XCTAssertEqual(e.durationS, 900)
        XCTAssertEqual(e.qualifiedS, 900)
        XCTAssertEqual(e.medianBpm, 105)
        XCTAssertEqual(e.extremeBpm, 105)
        XCTAssertEqual(e.censoring, [])
        XCTAssertEqual(e.coverage, 1)
        XCTAssertEqual(e.context, "unknown", "no sleep evidence → unknown, never presumed awake")
        XCTAssertEqual(e.evidenceSource, "strap_motion")
        XCTAssertEqual(e.reasons, [P.pulseEpisodeHigh])
        XCTAssertEqual(s.qualifiedInactiveS, 4500)
        XCTAssertEqual(s.highEpisodeCount, 1)
        XCTAssertEqual(s.highEpisodeS, 900)
        XCTAssertEqual(s.lowEpisodeCount, 0)
        XCTAssertEqual(s.lowEpisodeS, 0)
        XCTAssertEqual(s.units, "bpm")
        XCTAssertEqual(s.window, Self.identity.dayWindow)
        for code in [P.notRhythmClassification, P.causeNotAttributed, P.pulseEpisodeHigh] {
            XCTAssertTrue(s.reasons.contains(code), code.rawValue)
        }
        XCTAssertEqual(s.thresholds.first { $0.name == "high_enter_bpm" }?.value, 100)
        XCTAssertEqual(s.thresholds.count, 22)
    }

    /// A dip held for 70 s (≥ the 60 s hold) ends the episode at the dip's first sample: 105 [t0, t0+700),
    /// 90 [t0+700, t0+770), 105 [t0+770, t0+1470), calm after → [t0, t0+700) and [t0+770, t0+1470).
    func testAHeldExitEndsTheEpisodeAtTheFirstExitSample() {
        let t0 = Self.t0
        let hr = Self.calm(t0 - 1800, t0) + Self.heart([(t0, t0 + 700, 105), (t0 + 700, t0 + 770, 90),
                                                         (t0 + 770, t0 + 1470, 105)]) + Self.calm(t0 + 1470, t0 + 3000)
        let s = Self.run(hr: hr, track: Self.stillAround)
        XCTAssertEqual(s.episodes.map(\.interval), [PC.Interval(t0, t0 + 700), PC.Interval(t0 + 770, t0 + 1470)])
        XCTAssertEqual(s.episodes.map(\.qualifiedS), [700, 700])
        XCTAssertTrue(s.episodes.allSatisfy { $0.censoring.isEmpty })
    }

    /// Hysteresis: alternating 101 / 99 for 900 s enters once at 101 and never exits (99 ≥ the 95 exit) → one
    /// episode, median (99 + 101) / 2 = 100, max 101. A 300 s excursion to 105 is below the 600 s minimum → none.
    func testCrossingTheThresholdBrieflyOrRepeatedlyDoesNotCreateEpisodes() throws {
        let t0 = Self.t0
        let oscillating = (t0..<(t0 + 900)).map { PC.HeartRateObservation(ts: $0, bpm: ($0 - t0) % 2 == 0 ? 101 : 99) }
        let s = Self.run(hr: Self.calm(t0 - 1800, t0) + oscillating + Self.calm(t0 + 900, t0 + 2700),
                         track: Self.stillAround)
        XCTAssertEqual(s.episodes.count, 1)
        let e = try XCTUnwrap(s.episodes.first)
        XCTAssertEqual(e.interval, PC.Interval(t0, t0 + 900))
        XCTAssertEqual(e.medianBpm, 100)
        XCTAssertEqual(e.extremeBpm, 101)

        let brief = Self.run(hr: Self.calm(t0 - 1800, t0) + Self.heart([(t0, t0 + 300, 105)])
                                 + Self.calm(t0 + 300, t0 + 2700), track: Self.stillAround)
        XCTAssertEqual(brief.episodes, [])
        XCTAssertEqual(brief.highEpisodeCount, 0, "evaluated, none found: 0, not nil")
    }

    func testMinimumDurationIsInQualifiedSeconds() {
        let t0 = Self.t0
        for (length, expected) in [(599, 0), (600, 1)] {
            let hr = Self.calm(t0 - 1800, t0) + Self.heart([(t0, t0 + length, 105)]) + Self.calm(t0 + length, t0 + 2700)
            XCTAssertEqual(Self.run(hr: hr, track: Self.stillAround).episodes.count, expected, "\(length) s")
        }
    }

    // MARK: Censoring: gaps, breaks, qualification loss, cutoff — never bridged

    /// 105 [t0, t0+700), no samples for 60 s, 105 [t0+760, t0+1460), calm after → two episodes, the first
    /// right-censored and the second left-censored by the gap; never one 1460 s episode.
    func testAGapCensorsAndIsNeverBridged() {
        let t0 = Self.t0
        let hr = Self.calm(t0 - 1800, t0) + Self.heart([(t0, t0 + 700, 105), (t0 + 760, t0 + 1460, 105)])
            + Self.calm(t0 + 1460, t0 + 3000)
        let s = Self.run(hr: hr, track: Self.stillAround)
        XCTAssertEqual(s.episodes.map(\.interval), [PC.Interval(t0, t0 + 700), PC.Interval(t0 + 760, t0 + 1460)])
        XCTAssertEqual(s.episodes.map(\.censoring), [[P.episodeCensoredGap], [P.episodeCensoredGap]])
        XCTAssertEqual(s.highEpisodeS, 1400)
    }

    /// A one-second break at t0+700 inside continuous 105/106: the sample at t0+700 is adjacent to neither
    /// neighbour → [t0, t0+700) censored, [t0+700] alone (too short), [t0+701, t0+1400) censored at its start.
    func testABreakSeparatesSamplesOneSecondApart() {
        let t0 = Self.t0
        let hr = Self.calm(t0 - 1800, t0) + Self.alt([(t0, t0 + 1400, 105)]) + Self.calm(t0 + 1400, t0 + 3000)
        let s = Self.run(hr: hr, track: Self.stillAround, breaks: [PC.Interval(t0 + 700, t0 + 701)])
        XCTAssertEqual(s.episodes.map(\.interval), [PC.Interval(t0, t0 + 700), PC.Interval(t0 + 701, t0 + 1400)])
        XCTAssertEqual(s.episodes.map(\.qualifiedS), [700, 699])
        XCTAssertEqual(s.episodes.map(\.censoring), [[P.episodeCensoredGap], [P.episodeCensoredGap]])
    }

    /// Movement [t0+700, t0+760) while HR stays 105/106: the movement and the 300 s settle after it are not
    /// inactive → [t0, t0+700) right-censored and [t0+1060, t0+1800) left-censored by the qualification loss.
    func testLossOfInactiveQualificationCensors() throws {
        let t0 = Self.t0
        let track = Self.track([(t0 - 3600, t0 + 700, "still"), (t0 + 700, t0 + 760, "other_movement"),
                                (t0 + 760, t0 + 5000, "still")])
        let hr = Self.calm(t0 - 1800, t0) + Self.alt([(t0, t0 + 1800, 105)]) + Self.calm(t0 + 1800, t0 + 3600)
        let s = Self.run(hr: hr, track: track)
        XCTAssertEqual(s.episodes.map(\.interval), [PC.Interval(t0, t0 + 700), PC.Interval(t0 + 1060, t0 + 1800)])
        XCTAssertEqual(s.episodes.map(\.censoring),
                       [[P.episodeCensoredQualification], [P.episodeCensoredQualification]])
        XCTAssertEqual(s.episodes.map(\.medianBpm), [105.5, 105.5])
        XCTAssertEqual(s.episodes.map(\.extremeBpm), [106, 106])
        // Exposure: calm 1800 + 700 + 740 + calm 1800, minus the first 300 s of the still run that starts at
        // t0-3600 (settled from t0-3300, before the HR starts) → 5040.
        XCTAssertEqual(s.qualifiedInactiveS, 1800 + 700 + 740 + 1800)
    }

    /// Stillness starting at t0 with HR already 105/106: only seconds after the 300 s settle are inactive.
    func testStillnessMustSettleBeforeHeartRateQualifies() {
        let t0 = Self.t0
        let s = Self.run(hr: Self.alt([(t0, t0 + 1000, 105)]) + Self.calm(t0 + 1000, t0 + 2800),
                         track: Self.track([(t0, t0 + 3600, "still")]))
        XCTAssertEqual(s.episodes.map(\.interval), [PC.Interval(t0 + 300, t0 + 1000)])
        XCTAssertEqual(s.episodes.first?.censoring, [P.episodeCensoredQualification])
    }

    /// A bout ending at t0-300 excludes its 600 s follow-up: HR 105/106 from t0 qualifies only from t0+300.
    func testABoutsFollowUpIsNeverInactive() {
        let t0 = Self.t0
        let bout = PC.ExertionBout(id: "b", interval: .init(t0 - 900, t0 - 300), day: Self.day, kind: "walking",
                                   status: .complete, durationS: 600)
        let s = Self.run(hr: Self.alt([(t0, t0 + 1000, 105)]) + Self.calm(t0 + 1000, t0 + 2800),
                         track: Self.stillAround, bouts: [bout])
        XCTAssertEqual(s.episodes.map(\.interval), [PC.Interval(t0 + 300, t0 + 1000)])
    }

    /// A live document whose cutoff falls inside an episode: right-censored `cutoff_reached`, still reported.
    func testAnEpisodeReachingTheLiveCutoffIsCensored() {
        let t0 = Self.t0
        let cutoff = t0 + 800
        let s = Self.run(hr: Self.calm(t0 - 1800, t0) + Self.alt([(t0, cutoff, 105)]), track: Self.stillAround,
                         mode: .causalLive, cutoff: cutoff)
        XCTAssertEqual(s.episodes.map(\.interval), [PC.Interval(t0, cutoff)])
        XCTAssertEqual(s.episodes.first?.censoring, [PC.ExertionBouts.censorCutoffReached])
        XCTAssertEqual(s.window, PC.Interval(Self.dayStart, cutoff))
        XCTAssertEqual(s.evaluatedSpan?.end, cutoff)
    }

    // MARK: Signal qualification, duplicates, no data

    /// A constant 105 for 1000 s (one value for ≥ 900 s at 1 s steps) is a stuck signal: not qualified at all.
    func testAStuckSignalIsNotQualified() {
        let t0 = Self.t0
        let s = Self.run(hr: Self.calm(t0 - 1800, t0) + Self.heart([(t0, t0 + 1000, 105)]) + Self.calm(t0 + 1000, t0 + 2800),
                         track: Self.stillAround)
        XCTAssertEqual(s.episodes, [])
        XCTAssertEqual(s.qualifiedInactiveS, 1800 + 1800)
    }

    /// Exact duplicates change nothing; two different values in one second disqualify that second.
    func testDuplicates() {
        let t0 = Self.t0
        let base = Self.calm(t0 - 1800, t0) + Self.alt([(t0, t0 + 1500, 105)]) + Self.calm(t0 + 1500, t0 + 3300)
        let once = Self.run(hr: base, track: Self.stillAround)
        let twice = Self.run(hr: base + base.reversed(), track: Self.stillAround)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(once.episodes.map(\.interval), [PC.Interval(t0, t0 + 1500)])

        let conflict = Self.run(hr: base + [PC.HeartRateObservation(ts: t0 + 700, bpm: 50)], track: Self.stillAround)
        XCTAssertEqual(conflict.episodes.map(\.interval), [PC.Interval(t0, t0 + 700), PC.Interval(t0 + 701, t0 + 1500)])
        XCTAssertEqual(conflict.episodes.map(\.censoring),
                       [[P.episodeCensoredQualification], [P.episodeCensoredQualification]])
        XCTAssertEqual(conflict.qualifiedInactiveS, once.qualifiedInactiveS - 1)
    }

    func testNoDataIsUnavailableWithAReasonNotZero() {
        let none = Self.run(hr: [], track: Self.stillAround)
        XCTAssertEqual(none.state, .unavailable)
        XCTAssertNil(none.highEpisodeCount)
        XCTAssertNil(none.lowEpisodeCount)
        XCTAssertNil(none.highEpisodeS)
        XCTAssertNil(none.accelerationEventsPerAwakeHour)
        XCTAssertEqual(none.qualifiedInactiveS, 0)
        XCTAssertTrue(none.reasons.contains(P.qualifiedInactiveHrInsufficient))
        XCTAssertTrue(none.reasons.contains(P.notRhythmClassification))

        // HR without any HR-independent motion evidence: nothing is "inactive".
        let t0 = Self.t0
        let blind = Self.run(hr: Self.alt([(t0, t0 + 3600, 105)]), track: .empty(.strapMotion))
        XCTAssertEqual(blind.state, .unavailable)
        XCTAssertEqual(blind.episodes, [])
        XCTAssertTrue(blind.reasons.contains(PC.Engine.activityUnavailable))
        XCTAssertTrue(blind.reasons.contains(P.qualifiedInactiveHrInsufficient))

        // Some exposure, under the hour the counts need for rates: partial, counts present.
        let short = Self.run(hr: Self.calm(t0, t0 + 1200), track: Self.stillAround)
        XCTAssertEqual(short.state, .partial)
        XCTAssertEqual(short.qualifiedInactiveS, 1200)
        XCTAssertEqual(short.highEpisodeCount, 0)
        XCTAssertTrue(short.reasons.contains(P.qualifiedInactiveHrInsufficient))
    }

    // MARK: Sustained low, sleep context, day ownership

    /// Inside a detected sleep episode: 37/38 for 1200 s between 50/51 → one low episode, asleep, min 37.
    func testSustainedLowDuringSleepCarriesTheSleepContext() throws {
        let t0 = Self.t0
        let night = PC.SleepEpisode(id: "n", interval: .init(t0 - 7200, t0 + 7200), kind: .mainSleep,
                                    ownerDay: Self.day, complete: true, finality: .final, durationS: 14_400)
        let hr = Self.alt([(t0 - 1800, t0, 50), (t0, t0 + 1200, 37), (t0 + 1200, t0 + 3000, 50)])
        let s = Self.run(hr: hr, track: Self.stillAround, episodes: [night])
        XCTAssertEqual(s.episodes.count, 1)
        let e = try XCTUnwrap(s.episodes.first)
        XCTAssertEqual(e.kind, P.kindLow)
        XCTAssertEqual(e.interval, PC.Interval(t0, t0 + 1200))
        XCTAssertEqual(e.extremeBpm, 37)
        XCTAssertEqual(e.medianBpm, 37.5)
        XCTAssertEqual(e.context, "asleep")
        XCTAssertEqual(e.reasons, [P.pulseEpisodeLow])
        XCTAssertEqual(s.qualifiedAsleepS, 4800)
        XCTAssertEqual(s.qualifiedAwakeS, 0)
        XCTAssertTrue(s.reasons.contains(PC.SleepRhythm.labelsReadHeartRate), "the sleep context reads HR")
    }

    /// An episode that began before midnight belongs to the previous day; one that begins before the day ends
    /// keeps its full length past midnight (retrospective lookahead).
    func testEpisodesBelongToTheDayOfTheirStart() {
        let ds = Self.dayStart, de = Self.dayEnd
        let track = Self.track([(ds - 7200, ds + 7200, "still"), (de - 7200, de + 7200, "still")])
        let hr = Self.calm(ds - 3600, ds - 400) + Self.alt([(ds - 400, ds + 800, 105)]) + Self.calm(ds + 800, ds + 3600)
            + Self.calm(de - 3600, de - 300) + Self.alt([(de - 300, de + 600, 105)]) + Self.calm(de + 600, de + 3600)
        let s = Self.run(hr: hr, track: track)
        XCTAssertEqual(s.episodes.map(\.interval), [PC.Interval(de - 300, de + 600)])
        XCTAssertEqual(s.episodes.first?.censoring, [])
        XCTAssertEqual(s.episodes.first?.durationS, 900)
    }

    // MARK: Heart-rate acceleration with movement

    /// Still 30 min, movement [t0, t0+60). HR (offset k = t - t0): k < 3 alternates 60 (even k) / 61 (odd k);
    /// 66 at k = 3, 4; 70 at k = 5…7; 75 at k = 8…59; then 62/63.
    /// Baseline [t0-75, t0-15): 30 × 60 + 30 × 61 → 60.5. Threshold 70.5 → first crossing k = 8. Rise onset = last
    /// sample ≤ 60.5 before it: k = 2 (60). Peak 75 at k = 8 → rise 14.5 bpm in 6 s; movement onset at k = 0 is
    /// 2 s before the rise onset (offset −2).
    static func accelerationFixture(rise: (Int) -> Int?) -> [PC.HeartRateObservation] {
        let t0 = Self.t0
        return ((t0 - 1800)..<(t0 + 1800)).compactMap { t in
            let k = t - t0
            if let v = rise(k) { return PC.HeartRateObservation(ts: t, bpm: v) }
            return nil
        }
    }
    static func standardRise(_ k: Int) -> Int? {
        switch k {
        case ..<3: return k & 1 == 0 ? 60 : 61
        case 3...4: return 66
        case 5...7: return 70
        case 8..<60: return 75
        default: return k & 1 == 0 ? 62 : 63
        }
    }
    static var movementTrack: PC.ResolvedTrack {
        track([(t0 - 3600, t0, "still"), (t0, t0 + 60, "other_movement"), (t0 + 60, t0 + 3600, "still")])
    }

    func testAccelerationWithMovementIsDescriptiveWithBaselineRiseAndOffset() throws {
        let t0 = Self.t0
        let s = Self.run(hr: Self.accelerationFixture(rise: Self.standardRise), track: Self.movementTrack)
        XCTAssertEqual(s.accelerationEvents.count, 1)
        let e = try XCTUnwrap(s.accelerationEvents.first)
        XCTAssertEqual(e.ts, t0 + 2)
        XCTAssertEqual(e.baselineBpm, 60.5)
        XCTAssertEqual(e.peakBpm, 75)
        XCTAssertEqual(e.riseBpm, 14.5)
        XCTAssertEqual(e.riseS, 6)
        XCTAssertEqual(e.movementOffsetS, -2)
        XCTAssertEqual(e.baselineSamples, 60)
        XCTAssertEqual(e.context, "unknown")
        XCTAssertTrue(s.reasons.contains(P.hrAccelerationWithMovement))
        XCTAssertTrue(s.reasons.contains(P.causeNotAttributed))
        XCTAssertTrue(s.reasons.contains(P.notRhythmClassification))
        XCTAssertEqual(s.episodes, [], "75 bpm is not a sustained high")
    }

    func testAccelerationNeedsMovementARapidRiseAndContinuousData() {
        // Same HR, no movement: nothing.
        let still = Self.run(hr: Self.accelerationFixture(rise: Self.standardRise), track: Self.stillAround)
        XCTAssertEqual(still.accelerationEvents, [])
        // Movement, flat HR: nothing.
        let flat = Self.run(hr: Self.accelerationFixture { $0 & 1 == 0 ? 60 : 61 }, track: Self.movementTrack)
        XCTAssertEqual(flat.accelerationEvents, [])
        // Slow rise (1 bpm per 3 s from k = 0: crossing at k = 33, onset k = 2 → 31 s > 15 s): nothing.
        let slow = Self.run(hr: Self.accelerationFixture { k in k < 0 ? (k & 1 == 0 ? 60 : 61) : 60 + k / 3 },
                            track: Self.movementTrack)
        XCTAssertEqual(slow.accelerationEvents, [])
        // A 20 s hole in the HR across the rise: never bridged.
        let holed = Self.run(hr: Self.accelerationFixture { k in (0..<20).contains(k) ? nil : Self.standardRise(k) },
                             track: Self.movementTrack)
        XCTAssertEqual(holed.accelerationEvents, [])
    }

    func testAccelerationRatesNeedAnHourOfQualifiedExposureInTheirContext() throws {
        let t0 = Self.t0
        let night = PC.SleepEpisode(id: "n", interval: .init(t0 - 4 * 3600, t0 + 4 * 3600), kind: .mainSleep,
                                    ownerDay: Self.day, complete: true, finality: .final, durationS: 8 * 3600)
        let track = Self.track([(t0 - 4 * 3600, t0, "still"), (t0, t0 + 60, "other_movement"),
                                (t0 + 60, t0 + 4 * 3600, "still")])
        let hr = Self.alt([(t0 - 3 * 3600, t0 - 1800, 60)]) + Self.accelerationFixture(rise: Self.standardRise)
            + Self.alt([(t0 + 1800, t0 + 3 * 3600, 62)])
        let s = Self.run(hr: hr, track: track, episodes: [night])
        XCTAssertEqual(s.accelerationEvents.map(\.context), ["asleep"])
        XCTAssertGreaterThanOrEqual(s.qualifiedAsleepS, 3600)
        let rate = try XCTUnwrap(s.accelerationEventsPerAsleepHour)
        XCTAssertEqual(rate, 1 / (Double(s.qualifiedAsleepS) / 3600), accuracy: 1e-12)
        XCTAssertNil(s.accelerationEventsPerAwakeHour, "no awake exposure → no rate, not 0")
    }

    // MARK: Encoding and codes

    func testSummaryRoundTripsAndOldShapesDecode() throws {
        let s = Self.run(hr: Self.accelerationFixture(rise: Self.standardRise) + Self.alt([(Self.t0 + 1800, Self.t0 + 2700, 105)]),
                         track: Self.track([(Self.t0 - 3600, Self.t0, "still"), (Self.t0, Self.t0 + 60, "other_movement"),
                                            (Self.t0 + 60, Self.t0 + 7200, "still")]))
        XCTAssertFalse(s.episodes.isEmpty)
        XCTAssertFalse(s.accelerationEvents.isEmpty)
        let data = try PC.encoder().encode(s)
        XCTAssertEqual(try PC.decoder().decode(PC.PulseEpisodeSummary.self, from: data), s)
        // The foundation shape (no units / window / coverage / evidence fields) still decodes.
        let old = #"{"acceleration_events":[{"baseline_bpm":60,"context":"awake","movement_offset_s":0,"peak_bpm":75,"rise_bpm":15,"rise_s":5,"ts":1}],"episodes":[{"censoring":[],"context":"awake","duration_s":600,"extreme_bpm":105,"id":"x","interval":{"end":601,"start":1},"kind":"sustained_high","median_bpm":105,"qualified_s":600,"reasons":[]}],"qualified_asleep_s":0,"qualified_awake_s":600,"qualified_inactive_s":600,"reasons":[],"state":"partial","thresholds":[],"version":"pc-pulse-1"}"#
        let decoded = try PC.decoder().decode(PC.PulseEpisodeSummary.self, from: Data(old.utf8))
        XCTAssertNil(decoded.units)
        XCTAssertNil(decoded.highEpisodeCount)
        XCTAssertNil(decoded.episodes.first?.coverage)
        XCTAssertNil(decoded.accelerationEvents.first?.baselineSamples)
        XCTAssertEqual(P.reasonCodes.count, Set(P.reasonCodes).count)
        for code in P.reasonCodes {
            for word in ["tachy", "brady", "arrhythm", "fibrillation", "afib", "apnea", "disease"] {
                XCTAssertFalse(code.rawValue.contains(word), "\(code) is clinical wording")
            }
        }
    }
}
