import XCTest
@testable import StrandAnalytics

/// System G: functional features with wear denominators (V14) and the feature registry. Expected values are worked
/// out by hand from the fixture described in each test.
final class PCFunctionalTests: XCTestCase {
    typealias PC = PhysiologyContext

    static let day = "2026-10-01"
    static let identity = PC.DayIdentity(deviceScope: "dev-1", day: day, timezoneId: "UTC",
                                         dayWindow: PC.Engine.dayInterval(day, timezoneId: "UTC"))
    static var ds: Int { identity.dayWindow.start }
    static func h(_ hours: Double) -> Int { ds + Int(hours * 3600) }
    static var retroCutoff: Int { identity.dayWindow.end + 40 * 3600 }

    /// Main sleep 00:00–07:00 → 17 h (61 200 s) of waking time.
    static let sleep = PC.SleepRhythmSummary(
        episodes: [PC.SleepEpisode(id: "s1", interval: .init(h(0), h(7)), kind: .mainSleep, ownerDay: day,
                                   complete: true, finality: .final, durationS: 7 * 3600)],
        mainSleepId: "s1", reasons: [], dependence: [])

    static func track(_ segs: [(Int, Int, String?)]) -> PC.ResolvedTrack {
        PC.IntervalAlgebra.resolve(segs.enumerated().map { i, s in
            PC.LabelRecord(interval: .init(s.0, s.1), label: s.2, tieBreak: "r\(i)")
        }, source: .strapMotion, heartRateDependent: false)
    }

    static func heart(_ from: Int, _ to: Int, bpm: Int = 70) -> [PC.HeartRateObservation] {
        (from..<to).map { PC.HeartRateObservation(ts: $0, bpm: bpm) }
    }

    struct Day {
        var strap: PC.ResolvedTrack
        var observations: PC.SanitizedObservations
        var bouts: [PC.ExertionBout]
    }

    static func make(strap: PC.ResolvedTrack, hr: [PC.HeartRateObservation], wear: [PC.WearEventObservation] = [],
                     mode: PC.ProcessingMode = .retrospective, cutoff: Int? = nil) -> Day {
        let obs = PC.SanitizedObservations(heartRate: hr, wearEvents: wear)
        let bouts = PC.ExertionBouts.detect(identity: identity, hart: .empty(.hartEpochs), strap: strap,
                                            workouts: [], observations: obs, mode: mode,
                                            cutoff: cutoff ?? retroCutoff, config: .init())
        return Day(strap: strap, observations: obs, bouts: bouts)
    }

    static func summary(_ d: Day, sleep: PC.SleepRhythmSummary = sleep, mode: PC.ProcessingMode = .retrospective,
                        cutoff: Int? = nil) -> PC.FunctionalDaySummary {
        PC.Functional.daySummary(identity: identity, bouts: d.bouts, hart: .empty(.hartEpochs), strap: d.strap,
                                 observations: d.observations, sleep: sleep, mode: mode,
                                 cutoff: cutoff ?? retroCutoff, config: .init())
    }

    /// Worn all day; walks 10:00–10:30 and 15:00–15:20, still otherwise.
    static func fullWearDay() -> Day {
        make(strap: track([(h(7), h(10), "still"), (h(10), h(10.5), "stepping"), (h(10.5), h(15), "still"),
                           (h(15), h(15) + 1200, "stepping"), (h(15) + 1200, h(24), "still")]),
             hr: heart(h(0), h(24)))
    }

    /// Worn 07:00–13:00 (on-wrist event, HR), then taken off (off-wrist event; the strap lies still on a table).
    static func reducedWearDay() -> Day {
        make(strap: track([(h(7), h(10), "still"), (h(10), h(10.5), "stepping"), (h(10.5), h(24), "still")]),
             hr: heart(h(7), h(13)),
             wear: [.init(ts: h(7), state: .onWrist, kind: "WRIST_ON"),
                    .init(ts: h(13), state: .offWrist, kind: "WRIST_OFF")])
    }

    // MARK: Denominators and features

    func testFullWearDayFeatures() throws {
        let s = Self.summary(Self.fullWearDay())
        XCTAssertEqual(s.evaluated, Self.identity.dayWindow)
        XCTAssertEqual(s.sleepExcludedS, 25200)
        XCTAssertEqual(s.wakingS, 61200)
        XCTAssertEqual(s.observedWearS, 86400)                 // heart signal all day, sleep included
        XCTAssertEqual(s.wornWakingS, 61200)                   // sleep removed from the waking denominator
        XCTAssertEqual(s.wearBasis, "heart_rate_signal")
        XCTAssertEqual(try XCTUnwrap(s.wearShare), 1, accuracy: 1e-12)
        XCTAssertTrue(s.totalsComparable)
        XCTAssertTrue(s.ratesSupported)
        XCTAssertFalse(s.reasons.contains(PC.Functional.insufficientWearCoverage))

        XCTAssertEqual(s.boutCount, 2)
        XCTAssertEqual(s.boutDurationMedianS, 1500)             // (1800 + 1200) / 2
        XCTAssertEqual(try XCTUnwrap(s.boutDurationP90), 1740, accuracy: 1e-9)   // 1200 + 0.9 × 600
        XCTAssertEqual(s.boutDurationMaxS, 1800)
        XCTAssertEqual(s.boutSecondsTotal, 3000)
        XCTAssertEqual(s.locomotionS, 3000)
        XCTAssertEqual(try XCTUnwrap(s.locomotionSecondsPerWornHour), 3000.0 / 17, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.boutsPerWornHour), 2.0 / 17, accuracy: 1e-12)
        XCTAssertEqual(s.pauseCount, 0)
        XCTAssertEqual(s.pausesPerBoutHour, 0)
        // still → walk → still → walk → still.
        XCTAssertEqual(s.restToActiveTransitions, 2)
        XCTAssertEqual(s.activeToRestTransitions, 2)
        XCTAssertEqual(try XCTUnwrap(s.activeToRestPerActiveMin), 2.0 / 50, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(s.restToActivePerRestMin), 2.0 / 970, accuracy: 1e-12)
        // Both bouts are followed by more than an hour of stillness → capped at 3600 s.
        XCTAssertEqual(s.restAfterBoutMedianS, 3600)
        XCTAssertEqual(s.restAfterBoutCount, 2)
        // No step counter on this strap: cadence is unavailable, not zero.
        XCTAssertNil(s.cadenceMeanStepsPerMin)
        XCTAssertTrue(s.reasons.contains(PC.ExertionBouts.cadenceUnavailable))
        XCTAssertTrue(s.limitations.contains(PC.ExertionBouts.wristCadenceNotGaitSpeed))

        let values = PC.Functional.dailyValues(s, regimeKey: "r", mode: .retrospective, finality: .final,
                                               config: .init())
        let byKey = Dictionary(uniqueKeysWithValues: values.map { ($0.seriesKey, $0) })
        XCTAssertEqual(Set(byKey.keys), [
            "functional.active_to_rest_per_min", "functional.bout_count", "functional.bouts_per_worn_hour",
            "functional.locomotion_s", "functional.locomotion_s_per_worn_hour", "functional.median_bout_s",
            "functional.pauses_per_bout_hour", "functional.rest_after_bout_median_s",
        ])
        XCTAssertEqual(try XCTUnwrap(byKey["functional.locomotion_s_per_worn_hour"]).value, 3000.0 / 17,
                       accuracy: 1e-9)
        XCTAssertEqual(byKey["functional.locomotion_s_per_worn_hour"]?.supportS, 61200)
        XCTAssertEqual(byKey["functional.locomotion_s"]?.value, 3000)
        XCTAssertEqual(byKey["functional.bout_count"]?.value, 2)
        XCTAssertEqual(byKey["functional.median_bout_s"]?.supportCount, 2)
        XCTAssertEqual(byKey["functional.median_bout_s"]?.sourceIds, s.boutIds)
        XCTAssertTrue(values.allSatisfy { $0.finality == .final && $0.metric == nil && $0.regimeKey == "r" })
    }

    func testV14ReducedActivityWithReducedWearIsMissingnessNotDecline() throws {
        let full = Self.summary(Self.fullWearDay())
        let s = Self.summary(Self.reducedWearDay())
        // 07:00–13:00 worn = 21 600 s of 61 200 waking seconds (35 %).
        XCTAssertEqual(s.wornWakingS, 21600)
        XCTAssertEqual(s.observedWearS, 21600)                 // still-on-a-table after the off event is not worn
        XCTAssertEqual(s.wearBasis, "heart_rate_signal+wear_events")
        XCTAssertEqual(try XCTUnwrap(s.wearShare), 21600.0 / 61200, accuracy: 1e-12)
        XCTAssertFalse(s.totalsComparable)
        XCTAssertTrue(s.reasons.contains(PC.Functional.insufficientWearCoverage))
        XCTAssertTrue(s.reasons.contains(PC.Functional.wearMissingnessMayBeInformative))
        // The captured total is lower than the full day's …
        XCTAssertEqual(s.locomotionS, 1800)
        XCTAssertLessThan(try XCTUnwrap(s.locomotionS), try XCTUnwrap(full.locomotionS))
        // … but the wear-normalized value is preserved (1800 s / 6 worn hours) and no total is published.
        XCTAssertTrue(s.ratesSupported)
        XCTAssertEqual(try XCTUnwrap(s.locomotionSecondsPerWornHour), 300, accuracy: 1e-9)
        let keys = Set(PC.Functional.dailyValues(s, regimeKey: "r", mode: .retrospective, finality: .final,
                                                 config: .init()).map(\.seriesKey))
        XCTAssertTrue(keys.contains(PC.Functional.seriesLocomotionPerWornHour))
        XCTAssertFalse(keys.contains(PC.Functional.seriesLocomotionTotal))
        XCTAssertFalse(keys.contains(PC.Functional.seriesBoutCount))
    }

    // MARK: RC-11 / RC-20 — a missing activity interval is not sedentary time

    static func values(_ s: PC.FunctionalDaySummary) -> [PC.DailyValue] {
        PC.Functional.dailyValues(s, regimeKey: "r", mode: .retrospective, finality: .final, config: .init())
    }

    func testNoMotionEvidenceGivesNoRatesAndNoZeroValues() {
        // Worn all day (heart signal), but no strap motion, step counter or HART label at all.
        let s = Self.summary(Self.make(strap: .empty(.strapMotion), hr: Self.heart(Self.h(0), Self.h(24))))
        XCTAssertEqual(s.wornWakingS, 61200)
        XCTAssertEqual(s.motionObservedWornWakingS, 0)
        XCTAssertFalse(s.ratesSupported)
        XCTAssertFalse(s.totalsComparable)
        XCTAssertNil(s.locomotionSecondsPerWornHour, "unavailable, not 0 s per worn hour")
        XCTAssertNil(s.boutsPerWornHour)
        XCTAssertTrue(s.reasons.contains(PC.Functional.motionEvidenceUnavailable))
        XCTAssertTrue(s.reasons.contains(PC.Functional.activityEvidenceUnavailable))
        XCTAssertTrue(s.reasons.contains(PC.Functional.insufficientMotionCoverage), "wear alone would allow totals")
        XCTAssertFalse(s.reasons.contains(PC.Functional.insufficientWornTimeForRates), "17 worn hours")
        XCTAssertEqual(Self.values(s), [])
        let evals = PC.FeatureRegistry.evaluate(functional: s, regimes: .empty, availability: [])
        XCTAssertTrue(evals.allSatisfy { $0.state == PC.FeatureRegistry.stateUnavailable })
        let byId = Dictionary(uniqueKeysWithValues: evals.map { ($0.featureId, $0) })
        XCTAssertEqual(byId[PC.Functional.seriesLocomotionPerWornHour]?.missing, [PC.Functional.motionEvidenceUnavailable])
        XCTAssertTrue(byId[PC.Functional.seriesLocomotionTotal]?.missing.contains(PC.Functional.insufficientMotionCoverage) ?? false)
    }

    func testRatesDivideByMotionObservedWornTime() throws {
        // Worn all day; strap motion covers only 07:00–13:00 with one 30-minute walk at 10:00. The rate is per
        // motion-observed worn hour (6 h), not per worn hour (17 h): the 11 unobserved hours are not sedentary.
        let s = Self.summary(Self.make(strap: Self.track([(Self.h(7), Self.h(10), "still"),
                                                          (Self.h(10), Self.h(10.5), "stepping"),
                                                          (Self.h(10.5), Self.h(13), "still")]),
                                       hr: Self.heart(Self.h(0), Self.h(24))))
        XCTAssertEqual(s.wornWakingS, 61200)
        XCTAssertEqual(s.motionObservedWornWakingS, 21600)
        XCTAssertEqual(try XCTUnwrap(s.motionObservedShare), 21600.0 / 61200, accuracy: 1e-12)
        XCTAssertTrue(s.ratesSupported)
        XCTAssertEqual(try XCTUnwrap(s.locomotionSecondsPerWornHour), 1800.0 / 6, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.boutsPerWornHour), 1.0 / 6, accuracy: 1e-12)
        // Wear alone would allow a total, but only 6 of 17 waking hours were observed: no comparable total.
        XCTAssertFalse(s.totalsComparable)
        XCTAssertTrue(s.reasons.contains(PC.Functional.insufficientMotionCoverage))
        let byKey = Dictionary(uniqueKeysWithValues: Self.values(s).map { ($0.seriesKey, $0) })
        XCTAssertEqual(byKey[PC.Functional.seriesLocomotionPerWornHour]?.supportS, 21600)
        XCTAssertNil(byKey[PC.Functional.seriesLocomotionTotal])
        // Below 4 motion-observed hours the rates are unavailable with a reason, even with 17 worn hours.
        let short = Self.summary(Self.make(strap: Self.track([(Self.h(7), Self.h(9), "still"),
                                                              (Self.h(9), Self.h(9) + 600, "stepping")]),
                                           hr: Self.heart(Self.h(0), Self.h(24))))
        XCTAssertEqual(short.motionObservedWornWakingS, 7800)
        XCTAssertFalse(short.ratesSupported)
        XCTAssertNil(short.locomotionSecondsPerWornHour)
        XCTAssertTrue(short.reasons.contains(PC.Functional.insufficientMotionObservedTimeForRates))
        XCTAssertEqual(Self.values(short), [])
    }

    func testStrapMotionWithoutAStepCounterCannotShowLocomotion() throws {
        // WHOOP 4.0: still / movement labels but no step counter and no HART: locomotion is unobservable.
        let strap = Self.track([(Self.h(7), Self.h(10), "still"), (Self.h(10), Self.h(10.5), "other_movement"),
                                (Self.h(10.5), Self.h(24), "still")])
        let hr = Self.heart(Self.h(0), Self.h(24))
        let without = Self.summary(Day(strap: strap, observations: .init(heartRate: hr), bouts: []))
        XCTAssertEqual(without.motionObservedWornWakingS, 0)
        XCTAssertFalse(without.ratesSupported)
        XCTAssertTrue(without.reasons.contains(PC.Functional.locomotionUnobservableWithoutStepCounter))
        XCTAssertFalse(without.reasons.contains(PC.Functional.motionEvidenceUnavailable))
        XCTAssertEqual(Self.values(without), [])
        // The same labels with a reporting step counter that never counts: an observed zero.
        let steps = stride(from: Self.h(7), to: Self.h(24), by: 5).map { PC.StepObservation(ts: $0, counter: 7) }
        let with = Self.summary(Day(strap: strap, observations: .init(heartRate: hr, steps: steps), bouts: []))
        XCTAssertEqual(with.motionObservedWornWakingS, 61200)
        XCTAssertTrue(with.ratesSupported)
        XCTAssertEqual(with.locomotionSecondsPerWornHour, 0)
    }

    func testLocomotionOutsideWornTimeIsInNeitherNumeratorNorDenominator() throws {
        // RC-20: worn 07:00–13:00, then an off-wrist event; the strap later counts a 30-minute "walk" (in a bag).
        let d = Self.make(strap: Self.track([(Self.h(7), Self.h(10), "still"), (Self.h(10), Self.h(10.5), "stepping"),
                                             (Self.h(10.5), Self.h(15), "still"), (Self.h(15), Self.h(15.5), "stepping"),
                                             (Self.h(15.5), Self.h(24), "still")]),
                          hr: Self.heart(Self.h(7), Self.h(13)),
                          wear: [.init(ts: Self.h(7), state: .onWrist, kind: "WRIST_ON"),
                                 .init(ts: Self.h(13), state: .offWrist, kind: "WRIST_OFF")])
        let s = Self.summary(d)
        XCTAssertEqual(s.boutCount, 2, "behaviour is still described")
        XCTAssertEqual(s.wornWakingS, 21600)
        XCTAssertEqual(s.motionObservedWornWakingS, 21600)
        XCTAssertEqual(s.locomotionS, 1800, "the off-wrist walk is not worn time")
        XCTAssertEqual(try XCTUnwrap(s.locomotionSecondsPerWornHour), 1800.0 / 6, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.boutsPerWornHour), 1.0 / 6, accuracy: 1e-12)
    }

    func testNoWearEvidenceGivesNoDenominatorAndNoValues() {
        let d = Self.make(strap: Self.track([(Self.h(7), Self.h(10), "still"), (Self.h(10), Self.h(10.5), "stepping"),
                                             (Self.h(10.5), Self.h(24), "still")]), hr: [])
        let s = Self.summary(d)
        XCTAssertNil(s.observedWearS)
        XCTAssertNil(s.wornWakingS)
        XCTAssertEqual(s.wearBasis, "none")
        XCTAssertFalse(s.totalsComparable)
        XCTAssertFalse(s.ratesSupported)
        XCTAssertTrue(s.reasons.contains(PC.Functional.wearEvidenceUnavailable))
        XCTAssertEqual(s.boutCount, 1)                           // behaviour is still described
        XCTAssertEqual(PC.Functional.dailyValues(s, regimeKey: "r", mode: .retrospective, finality: .final,
                                                 config: .init()), [])
    }

    func testCausalPartialDayIsNeverATotal() throws {
        let cutoff = Self.h(12)
        let d = Self.make(strap: Self.track([(Self.h(7), Self.h(10), "still"), (Self.h(10), Self.h(10.5), "stepping"),
                                             (Self.h(10.5), cutoff, "still")]),
                          hr: Self.heart(Self.h(0), cutoff), mode: .causalLive, cutoff: cutoff)
        let s = Self.summary(d, mode: .causalLive, cutoff: cutoff)
        XCTAssertEqual(s.evaluated, .init(Self.h(0), cutoff))
        XCTAssertEqual(s.wakingS, 18000)                         // 07:00–12:00
        XCTAssertTrue(s.reasons.contains(PC.Functional.dayIncompleteAtCutoff))
        XCTAssertFalse(s.totalsComparable)
        XCTAssertEqual(try XCTUnwrap(s.locomotionSecondsPerWornHour), 1800.0 / 5, accuracy: 1e-9)
        let keys = Set(PC.Functional.dailyValues(s, regimeKey: "r", mode: .causalLive, finality: .provisional,
                                                 config: .init()).map(\.seriesKey))
        XCTAssertFalse(keys.contains(PC.Functional.seriesLocomotionTotal))
        XCTAssertTrue(keys.contains(PC.Functional.seriesLocomotionPerWornHour))
    }

    func testUnknownSleepIsNotSilentlyExcluded() {
        let s = Self.summary(Self.fullWearDay(), sleep: .unavailable([]))
        XCTAssertEqual(s.wakingS, 86400)
        XCTAssertEqual(s.sleepExcludedS, 0)
        XCTAssertTrue(s.reasons.contains(PC.Functional.sleepNotExcluded))
    }

    func testPausesAndCadenceAggregateFromBouts() throws {
        // One walk with a 30 s pause: [10:00, 10:05) stepping, 30 s still, [10:05:30, 10:10) stepping.
        let a = Self.h(10)
        let d = Self.make(strap: Self.track([(Self.h(7), a, "still"), (a, a + 300, "stepping"),
                                             (a + 300, a + 330, "still"), (a + 330, a + 600, "stepping"),
                                             (a + 600, Self.h(24), "still")]),
                          hr: Self.heart(Self.h(0), Self.h(24)))
        let s = Self.summary(d)
        XCTAssertEqual(s.boutCount, 1)
        XCTAssertEqual(s.pauseCount, 1)
        XCTAssertEqual(s.pauseMedianS, 30)
        XCTAssertEqual(try XCTUnwrap(s.pausesPerBoutHour), 1 / (600.0 / 3600), accuracy: 1e-9)
        // The pause is a still stretch inside the bout: two transitions each way on the evidence.
        XCTAssertEqual(s.restToActiveTransitions, 2)
        XCTAssertEqual(s.activeToRestTransitions, 2)
    }

    func testSummaryRoundTripsAndOldJSONDecodes() throws {
        let s = Self.summary(Self.reducedWearDay())
        let data = try PC.encoder().encode(s)
        XCTAssertEqual(try PC.decoder().decode(PC.FunctionalDaySummary.self, from: data), s)
        let old = #"{"day":"2026-10-01","day_s":86400,"reasons":["not_implemented"],"totals_comparable":false,"wear_basis":"none"}"#
        XCTAssertEqual(try PC.decoder().decode(PC.FunctionalDaySummary.self, from: Data(old.utf8)),
                       .unavailable(day: Self.day, dayS: 86400, reasons: ["not_implemented"]))
    }

    // MARK: Feature registry

    func testRegistryDeclaresRequirementsAndValidationStatus() {
        let defs = PC.FeatureRegistry.definitions
        XCTAssertEqual(Set(defs.map(\.id)).count, defs.count)
        XCTAssertEqual(PC.FeatureRegistry.version, "pc-features-1")
        let specialized = defs.filter { $0.tier == "specialized" }
        XCTAssertEqual(Set(specialized.map(\.id)), [
            "specialized.gait_speed", "specialized.stride_length", "specialized.tremor_index",
            "specialized.respiratory_event_index", "specialized.autonomic_index", "specialized.symptom_classifier",
        ])
        for d in specialized {
            XCTAssertEqual(d.validationStatus, .notValidated, d.id)
            XCTAssertFalse(d.requiredSensors.isEmpty, d.id)
            XCTAssertFalse(d.requiredLabels.isEmpty, d.id)
            XCTAssertFalse(d.referenceAssessments.isEmpty, d.id)
            XCTAssertFalse(d.units.isEmpty || d.timing.isEmpty || d.intendedPopulation.isEmpty, d.id)
        }
        for d in defs where d.tier == "general" {
            XCTAssertEqual(d.validationStatus, .technicalVerificationOnly, d.id)
        }
        let symptom = defs.first { $0.id == "specialized.symptom_classifier" }
        XCTAssertTrue(symptom?.limitations.contains("user_reported_symptom_is_observed_report_not_diagnosis") ?? false)
    }

    func testSpecializedFeaturesAreUnavailableWithTheMissingEvidenceNamed() throws {
        let s = Self.summary(Self.fullWearDay())
        let evals = PC.FeatureRegistry.evaluate(functional: s, regimes: .empty, availability: [])
        XCTAssertEqual(evals.count, PC.FeatureRegistry.definitions.count)
        let byId = Dictionary(uniqueKeysWithValues: evals.map { ($0.featureId, $0) })

        let gait = try XCTUnwrap(byId["specialized.gait_speed"])
        XCTAssertEqual(gait.state, "unavailable")
        XCTAssertNil(gait.value)
        for m in ["missing_sensor:gps", "missing_sensor:ankle_or_hip_imu", "missing_placement:ankle_or_hip",
                  "missing_label:reference_gait_speed", "missing_reference_assessment:timed_10m_walk_test",
                  "no_validated_definition"] {
            XCTAssertTrue(gait.missing.contains(PC.ReasonCode(m)), m)
        }
        for e in evals where e.featureId.hasPrefix("specialized.") {
            XCTAssertEqual(e.state, "unavailable", e.featureId)
            XCTAssertNil(e.value, e.featureId)
            XCTAssertFalse(e.missing.isEmpty, e.featureId)
        }

        // A supported PPG waveform and a wrist placement remove those two items, but the respiratory event index
        // stays unavailable: it still lacks a validated SpO2 input and independent PSG labels.
        let availability = [PC.AvailabilityEntry(metric: nil, assessment: "ppg_waveform_quality", source: "strap",
                                                 state: .supported, comparability: "n/a", reasons: [])]
        let regimes = PC.RegimeTimeline(placements: [.init(interval: Self.identity.dayWindow, placement: "wrist",
                                                           placementSource: "user")],
                                        boundaries: [], registry: [])
        let rei = try XCTUnwrap(PC.FeatureRegistry.evaluate(functional: s, regimes: regimes,
                                                            availability: availability)
            .first { $0.featureId == "specialized.respiratory_event_index" })
        XCTAssertEqual(rei.state, "unavailable")
        XCTAssertFalse(rei.missing.contains("missing_sensor:ppg_waveform"))
        XCTAssertFalse(rei.missing.contains("missing_placement:wrist"))
        XCTAssertTrue(rei.missing.contains("missing_sensor:spo2_validated"))
        XCTAssertTrue(rei.missing.contains("missing_label:polysomnography_scored_respiratory_events"))

        // General features are computed from the summary.
        let rate = try XCTUnwrap(byId["functional.locomotion_s_per_worn_hour"])
        XCTAssertEqual(rate.state, "computed")
        XCTAssertEqual(try XCTUnwrap(rate.value), 3000.0 / 17, accuracy: 1e-9)
        XCTAssertEqual(rate.validationStatus, .technicalVerificationOnly)
        let cadence = try XCTUnwrap(byId["functional.cadence_steps_per_min"])
        XCTAssertEqual(cadence.state, "unavailable")
        XCTAssertTrue(cadence.missing.contains(PC.ExertionBouts.cadenceUnavailable))
    }

    func testTotalsAreUnavailableUnderReducedWearWhileRatesAreComputed() throws {
        let evals = PC.FeatureRegistry.evaluate(functional: Self.summary(Self.reducedWearDay()), regimes: .empty,
                                                availability: [])
        let byId = Dictionary(uniqueKeysWithValues: evals.map { ($0.featureId, $0) })
        let total = try XCTUnwrap(byId["functional.locomotion_s"])
        XCTAssertEqual(total.state, "unavailable")
        XCTAssertEqual(total.missing, [PC.Functional.insufficientWearCoverage])
        XCTAssertEqual(try XCTUnwrap(byId["functional.locomotion_s_per_worn_hour"]?.value), 300, accuracy: 1e-9)
    }
}
