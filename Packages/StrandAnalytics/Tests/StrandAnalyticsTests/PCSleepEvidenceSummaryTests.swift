import XCTest
@testable import StrandAnalytics

/// Sleep/wake + wear evidence (V02 / V10 quiet motion), the day summary (loss, timing, travel, rhythm proxies) and
/// dependence notes (V13).
final class PCSleepEvidenceSummaryTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias F = PCSleepFixture
    let config = PC.SleepConfig()
    let day = "2026-10-01", prev = "2026-09-30", next = "2026-10-02"

    func nightEpisodes(mode: PC.ProcessingMode, cutoff: Int, extra: [PC.SleepSessionInput] = []) -> [PC.SleepEpisode] {
        let night = F.session("night", F.at(prev, 23), F.at(day, 7), available: F.at(day, 7, 20))
        return PC.SleepRhythm.episodes(sessions: [night] + extra, identity: F.identity(day), mode: mode,
                                       cutoff: cutoff, config: config)
    }

    // MARK: Sleep / wake evidence

    func testQuietMotionWithoutSessionsIsUnknownSleepAndWear() {
        let support = PC.Interval(F.at(day, 14), F.at(day, 14, 5))
        let still = stride(from: F.at(day, 13), to: F.at(day, 15), by: 1).map {
            PC.MotionObservation(ts: $0, dynAccelG: 0.0005)
        }
        let ctx = PC.SleepRhythm.sleepWear(for: support, episodes: [],
                                           observations: .init(motion: still), config: config)
        XCTAssertEqual(ctx.sleepState, .unknown)
        XCTAssertEqual(ctx.wearState, .unknown)
        XCTAssertTrue(ctx.sleepEvidence.isEmpty)
        XCTAssertTrue(ctx.wearEvidence.isEmpty)
        XCTAssertFalse(ctx.sleepDependsOnHeartSignals)
        XCTAssertTrue(ctx.reasons.contains(PC.SleepRhythm.noDetectorOutput))
        XCTAssertTrue(ctx.reasons.contains(PC.SleepRhythm.noWearEvidence))

        // With a detected night elsewhere, quiet motion and no heart rate still cannot establish wake or wear.
        let eps = nightEpisodes(mode: .causalLive, cutoff: F.at(day, 18))
        let ctx2 = PC.SleepRhythm.sleepWear(for: support, episodes: eps, observations: .init(motion: still),
                                            config: config)
        XCTAssertEqual(ctx2.sleepState, .unknown)
        XCTAssertEqual(ctx2.wearState, .unknown)
        XCTAssertTrue(ctx2.reasons.contains(PC.SleepRhythm.detectorInputMissing))
    }

    func testAwakeNeedsHeartRateCoverageOutsideDetectedSleepAndIsHeartDependent() {
        let cutoff = F.at(day, 18)
        let eps = nightEpisodes(mode: .causalLive, cutoff: cutoff)
        let obs = PC.SanitizedObservations(heartRate: F.hr(F.at(prev, 23), cutoff, bpm: 62))
        let noon = PC.Interval(F.at(day, 12), F.at(day, 12, 5))
        let ctx = PC.SleepRhythm.sleepWear(for: noon, episodes: eps, observations: obs, config: config)
        XCTAssertEqual(ctx.sleepState, .awake)
        XCTAssertEqual(ctx.sleepEvidence, [PC.SleepRhythm.evidenceOutsideDetectedSleep])
        XCTAssertTrue(ctx.sleepDependsOnHeartSignals)
        XCTAssertEqual(ctx.wearState, .worn)
        XCTAssertEqual(ctx.wearEvidence, [PC.SleepRhythm.evidenceHeartRateSignal])
        XCTAssertTrue(ctx.wearDependsOnHeartSignals)
        XCTAssertTrue(ctx.reasons.contains(PC.SleepRhythm.wearFromHeartSignal))

        // Inside the night: asleep from the detected session.
        let night = PC.Interval(F.at(day, 3), F.at(day, 3, 5))
        let asleep = PC.SleepRhythm.sleepWear(for: night, episodes: eps, observations: obs, config: config)
        XCTAssertEqual(asleep.sleepState, .asleep)
        XCTAssertEqual(asleep.sleepEvidence, [PC.SleepRhythm.evidenceDetectedSleep])
        XCTAssertTrue(asleep.sleepDependsOnHeartSignals)

        // Straddling the wake: mixed.
        let wakeEdge = PC.Interval(F.at(day, 6, 57), F.at(day, 7, 3))
        XCTAssertEqual(PC.SleepRhythm.sleepWear(for: wakeEdge, episodes: eps, observations: obs,
                                                config: config).sleepState, .mixed)

        // Within the detector's reporting lag before the data end, absence of a session is not wake.
        let recent = PC.Interval(F.at(day, 17), F.at(day, 17, 5))
        let lag = PC.SleepRhythm.sleepWear(for: recent, episodes: eps, observations: obs, config: config)
        XCTAssertEqual(lag.sleepState, .unknown)
        XCTAssertTrue(lag.reasons.contains(PC.SleepRhythm.detectorLagWindow))
        XCTAssertEqual(lag.wearState, .worn)

        // A heart-rate gap over the support: the detector could not have confirmed sleep there.
        let gappy = PC.SanitizedObservations(heartRate: obs.heartRate.filter { !noon.contains($0.ts) })
        let gap = PC.SleepRhythm.sleepWear(for: noon, episodes: eps, observations: gappy, config: config)
        XCTAssertEqual(gap.sleepState, .unknown)
        XCTAssertTrue(gap.reasons.contains(PC.SleepRhythm.detectorInputMissing))
    }

    func testRetrospectiveAfternoonNeedsTheNextOwnerDaySessions() {
        let cutoff = F.identity(day).dayWindow.end + 40 * 3600
        let obs = PC.SanitizedObservations(heartRate: F.hr(F.at(prev, 23), F.at(next, 6), bpm: 62, step: 2))
        let afternoon = PC.Interval(F.at(day, 15), F.at(day, 15, 5))
        // Only this day's sessions: a session owned by the next day could still cover the afternoon.
        let only = nightEpisodes(mode: .retrospective, cutoff: cutoff)
        let unread = PC.SleepRhythm.sleepWear(for: afternoon, episodes: only, observations: obs, config: config)
        XCTAssertEqual(unread.sleepState, .unknown)
        XCTAssertTrue(unread.reasons.contains(PC.SleepRhythm.ownerDaysUnread))
        // With the next night's session read, the afternoon is positively awake.
        let nextNight = F.session("next", F.at(day, 23, 30), F.at(next, 6, 30), sourceDay: next)
        let both = nightEpisodes(mode: .retrospective, cutoff: cutoff, extra: [nextNight])
        let read = PC.SleepRhythm.sleepWear(for: afternoon, episodes: both, observations: obs, config: config)
        XCTAssertEqual(read.sleepState, .awake)
    }

    func testIncompleteNightEndIsNotPresumedAwake() {
        let cutoff = F.at(day, 3)
        let partial = F.session("night", F.at(prev, 23), F.at(day, 2, 50), available: F.at(day, 2, 55))
        let eps = PC.SleepRhythm.episodes(sessions: [partial], identity: F.identity(day), mode: .causalLive,
                                          cutoff: cutoff, config: config)
        let obs = PC.SanitizedObservations(heartRate: F.hr(F.at(prev, 22), cutoff))
        let ctx = PC.SleepRhythm.sleepWear(for: .init(F.at(day, 2, 45), F.at(day, 2, 59)), episodes: eps,
                                           observations: obs, config: config)
        XCTAssertNotEqual(ctx.sleepState, .awake)
        XCTAssertNotEqual(ctx.sleepState, .mixed)
        XCTAssertTrue(ctx.reasons.contains(PC.SleepRhythm.overlapsIncompleteEpisode))
    }

    func testBandSleepStateAddsEvidenceAndConflictsAreNotResolvedSilently() {
        let support = PC.Interval(F.at(day, 14), F.at(day, 14, 10))
        let bandAsleep = stride(from: support.start, to: support.end, by: 30).map {
            PC.BandSleepStateObservation(ts: $0, state: 2)
        }
        // No detector output: the band's own asleep state is the only (vendor-derived) evidence.
        let band = PC.SleepRhythm.sleepWear(for: support, episodes: [],
                                            observations: .init(bandSleepStates: bandAsleep), config: config)
        XCTAssertEqual(band.sleepState, .asleep)
        XCTAssertEqual(band.sleepEvidence, [PC.SleepRhythm.evidenceBandSleepState])
        XCTAssertTrue(band.reasons.contains(PC.SleepRhythm.bandStateInputsUndocumented))
        // The detector covered the time and found no sleep while the band says asleep: not forced either way.
        let cutoff = F.at(day, 18)
        let eps = nightEpisodes(mode: .causalLive, cutoff: cutoff)
        let obs = PC.SanitizedObservations(heartRate: F.hr(F.at(prev, 23), cutoff), bandSleepStates: bandAsleep)
        let conflict = PC.SleepRhythm.sleepWear(for: support, episodes: eps, observations: obs, config: config)
        XCTAssertEqual(conflict.sleepState, .unknown)
        XCTAssertTrue(conflict.reasons.contains(PC.SleepRhythm.sleepSourcesDisagree))
    }

    func testWearEventsAndBreaks() {
        let support = PC.Interval(F.at(day, 14), F.at(day, 14, 5))
        let off = [PC.WearEventObservation(ts: F.at(day, 13), state: .offWrist, kind: "WRIST_OFF")]
        let notWorn = PC.SleepRhythm.sleepWear(for: support, episodes: [], observations: .init(wearEvents: off),
                                               config: config)
        XCTAssertEqual(notWorn.wearState, .notWorn)
        XCTAssertEqual(notWorn.wearEvidence, [PC.SleepRhythm.evidenceWearEvents])
        XCTAssertFalse(notWorn.wearDependsOnHeartSignals)
        // On-wrist event with motion data (no heart rate): worn from wear events, not from motion.
        let on = [PC.WearEventObservation(ts: F.at(day, 13), state: .onWrist, kind: "WRIST_ON")]
        let motion = stride(from: F.at(day, 13), to: F.at(day, 15), by: 10).map {
            PC.MotionObservation(ts: $0, dynAccelG: 0.001)
        }
        let worn = PC.SleepRhythm.sleepWear(for: support, episodes: [],
                                            observations: .init(motion: motion, wearEvents: on), config: config)
        XCTAssertEqual(worn.wearState, .worn)
        XCTAssertEqual(worn.wearEvidence, [PC.SleepRhythm.evidenceWearEvents])
        // A disconnection between the event and the support ends the event's validity.
        let broken = PC.SleepRhythm.sleepWear(
            for: support, episodes: [],
            observations: .init(motion: motion, wearEvents: on,
                                breaks: [.init(F.at(day, 13, 30), F.at(day, 13, 40))]), config: config)
        XCTAssertEqual(broken.wearState, .unknown)
        // An off-wrist event contradicted by a heart-rate signal: worn, with the disagreement recorded.
        let contradicted = PC.SleepRhythm.sleepWear(
            for: support, episodes: [],
            observations: .init(heartRate: F.hr(support.start, support.end), wearEvents: off), config: config)
        XCTAssertEqual(contradicted.wearState, .worn)
        XCTAssertTrue(contradicted.reasons.contains(PC.SleepRhythm.wearSourcesDisagree))
    }

    // MARK: Summary — loss, timing, travel

    func priorNights(_ count: Int, tz: String = F.la, onset: (Int, Int) = (23, 0), wake: (Int, Int) = (7, 0),
                     minuteOffsets: [Int]? = nil) -> [PC.SleepSessionInput] {
        (1...count).map { k in
            let d = F.shift(day, -k, tz: tz)
            let o = minuteOffsets?[k - 1] ?? 0
            let start = F.at(F.shift(d, -1, tz: tz), onset.0, onset.1, tz: tz) + o * 60
            let end = F.at(d, wake.0, wake.1, tz: tz) + o * 60
            return F.session("p\(k)", start, end, sourceDay: d)
        }
    }

    func testRecentSleepLossAgainstPriorNightsMedian() {
        let id = F.identity(day)
        let cutoff = id.dayWindow.end + 40 * 3600
        let night = F.session("night", F.at(day, 1, 0), F.at(day, 7))
        let eps = PC.SleepRhythm.episodes(sessions: [night], identity: id, mode: .retrospective, cutoff: cutoff,
                                          config: config)
        let s = PC.SleepRhythm.summary(episodes: eps, priorSleep: priorNights(7), identity: id,
                                       observations: .init(), mode: .retrospective, cutoff: cutoff, config: config)
        XCTAssertEqual(s.sleepLoss.state, .available)
        XCTAssertEqual(s.sleepLoss.currentS, 6 * 3600)
        XCTAssertEqual(s.sleepLoss.priorMedianS, 8 * 3600)
        XCTAssertEqual(s.sleepLoss.differenceS, -2 * 3600)
        XCTAssertEqual(s.sleepLoss.lossS, 2 * 3600)
        XCTAssertEqual(s.sleepLoss.supportNights, 7)
        // Too few prior nights: unknown, never zero.
        let thin = PC.SleepRhythm.summary(episodes: eps, priorSleep: priorNights(3), identity: id,
                                          observations: .init(), mode: .retrospective, cutoff: cutoff,
                                          config: config)
        XCTAssertEqual(thin.sleepLoss.state, .unknown)
        XCTAssertNil(thin.sleepLoss.lossS)
        XCTAssertEqual(thin.sleepLoss.reasons, [PC.SleepRhythm.priorNightsInsufficient])
        XCTAssertEqual(thin.timing.state, .unknown)
        XCTAssertNil(thin.timing.priorMidpointSdS)
        // Live, mid-night: the main sleep is incomplete, so no loss is claimed.
        let partial = F.session("night", F.at(day, 1, 0), F.at(day, 4), available: F.at(day, 4, 2))
        let liveEps = PC.SleepRhythm.episodes(sessions: [partial], identity: id, mode: .causalLive,
                                              cutoff: F.at(day, 4, 5), config: config)
        let live = PC.SleepRhythm.summary(episodes: liveEps, priorSleep: priorNights(7), identity: id,
                                          observations: .init(), mode: .causalLive, cutoff: F.at(day, 4, 5),
                                          config: config)
        XCTAssertEqual(live.sleepLoss.reasons, [PC.SleepRhythm.mainSleepIncomplete])
        XCTAssertNil(live.totalSleepS, "no final length while the night is running")
        XCTAssertTrue(live.reasons.contains(PC.SleepRhythm.sleepInProgress))
        XCTAssertEqual(live.mainSleep?.complete, false)
        XCTAssertNil(live.timing.midpoint)
        XCTAssertNotNil(live.timing.onset)
        XCTAssertEqual(live.finality, .provisional)
    }

    func testTimingChangeIsCircularAcrossMidnightWithARegularityDescriptor() {
        let id = F.identity(day)
        let cutoff = id.dayWindow.end + 40 * 3600
        // Prior midpoints 23:50, 00:10, 23:40, 00:20, 00:00 (sleep 20:00–04:00 shifted by the offsets).
        let prior = priorNights(5, onset: (20, 0), wake: (4, 0), minuteOffsets: [-10, 10, -20, 20, 0])
        // Today 20:30–05:30: midpoint 01:00, wake 05:30.
        let night = F.session("night", F.at(prev, 20, 30), F.at(day, 5, 30))
        let eps = PC.SleepRhythm.episodes(sessions: [night], identity: id, mode: .retrospective, cutoff: cutoff,
                                          config: config)
        let t = PC.SleepRhythm.summary(episodes: eps, priorSleep: prior, identity: id, observations: .init(),
                                       mode: .retrospective, cutoff: cutoff, config: config).timing
        XCTAssertEqual(t.state, .available)
        XCTAssertEqual(t.priorMedianMidpointS, 0, "circular median of times around midnight")
        XCTAssertEqual(t.midpointChangeS, 3600)
        XCTAssertEqual(t.priorMedianWakeS, 4 * 3600)
        XCTAssertEqual(t.wakeChangeS, 5400)
        XCTAssertEqual(t.midpoint?.secondsOfDay, 3600)
        XCTAssertEqual(t.midpoint?.timezoneId, F.la)
        // sqrt(mean of squared offsets) = sqrt(200) min ≈ 849 s for this small spread.
        XCTAssertNotNil(t.priorMidpointSdS)
        XCTAssertTrue((800...900).contains(t.priorMidpointSdS ?? 0))
        XCTAssertTrue(t.changeVerifiable)
        XCTAssertTrue(t.reasons.contains(PC.SleepRhythm.priorZoneAssumedSame))
        XCTAssertFalse(t.reasons.contains(PC.SleepRhythm.timezoneHistoryUnknown))
    }

    func testTravelShiftByWholeHoursIsFlaggedUnverifiable() {
        // Prior week in London 23:00–07:00 local; today in New York 23:00–07:00 local.
        let id = F.identity(day, tz: F.ny)
        let cutoff = id.dayWindow.end + 40 * 3600
        let prior = priorNights(7, tz: F.london)
        let night = F.session("night", F.at(prev, 23, tz: F.ny), F.at(day, 7, tz: F.ny))
        let eps = PC.SleepRhythm.episodes(sessions: [night], identity: id, mode: .retrospective, cutoff: cutoff,
                                          config: config)
        let s = PC.SleepRhythm.summary(episodes: eps, priorSleep: prior, identity: id, observations: .init(),
                                       mode: .retrospective, cutoff: cutoff, config: config)
        // On New York's clock the London nights ran 18:00–02:00: a clean +5 h shift of midpoint and wake.
        XCTAssertEqual(s.timing.midpointChangeS, 5 * 3600)
        XCTAssertEqual(s.timing.wakeChangeS, 5 * 3600)
        XCTAssertFalse(s.timing.changeVerifiable)
        XCTAssertTrue(s.timing.reasons.contains(PC.SleepRhythm.timezoneHistoryUnknown))
        XCTAssertFalse(s.reasons.contains(PC.SleepRhythm.noMainSleep))
        // Duration-based loss does not depend on the zone.
        XCTAssertEqual(s.sleepLoss.differenceS, 0)

        // Same zone, a genuine 2.5 h later night: verifiable.
        let laId = F.identity(day)
        let late = F.session("late", F.at(day, 1, 40), F.at(day, 9, 20))
        let laEps = PC.SleepRhythm.episodes(sessions: [late], identity: laId, mode: .retrospective,
                                            cutoff: cutoff, config: config)
        let shifted = PC.SleepRhythm.summary(episodes: laEps, priorSleep: priorNights(7), identity: laId,
                                             observations: .init(), mode: .retrospective, cutoff: cutoff,
                                             config: config)
        XCTAssertEqual(shifted.timing.midpointChangeS, 9000)
        XCTAssertTrue(shifted.timing.changeVerifiable)
        XCTAssertFalse(shifted.timing.reasons.contains(PC.SleepRhythm.timezoneHistoryUnknown))
    }

    // MARK: Fragmentation, rhythm proxy, phase, dependence (V13), JSON

    func testStageFragmentationIsAuxiliaryAndRhythmIsAProxyWithDependenceNotes() throws {
        let id = F.identity(day)
        let cutoff = id.dayWindow.end + 40 * 3600
        let s0 = F.at(prev, 23), s1 = F.at(day, 7)
        let stages: [PC.StageSpan] = [
            .init(interval: .init(s0, s0 + 900), stage: "wake"),
            .init(interval: .init(s0 + 900, s0 + 4 * 3600), stage: "light"),
            .init(interval: .init(s0 + 4 * 3600, s0 + 4 * 3600 + 600), stage: "wake"),
            .init(interval: .init(s0 + 4 * 3600 + 600, s1 - 600), stage: "deep"),
            .init(interval: .init(s1 - 600, s1), stage: "wake"),
        ]
        let night = F.session("night", s0, s1, stages: stages)
        let eps = PC.SleepRhythm.episodes(sessions: [night], identity: id, mode: .retrospective, cutoff: cutoff,
                                          config: config)
        let hr = F.hr(s0, s1, bpm: 55) + F.hr(s1, F.at(day, 21), bpm: 75)
        let s = PC.SleepRhythm.summary(episodes: eps, priorSleep: [], identity: id,
                                       observations: .init(heartRate: hr), mode: .retrospective, cutoff: cutoff,
                                       config: config)
        XCTAssertEqual(s.fragmentation?.basis, PC.SleepRhythm.stageBasis)
        XCTAssertEqual(s.fragmentation?.wakeSegments, 1, "only the wake with sleep on both sides")
        XCTAssertEqual(s.fragmentation?.wakeS, 900 + 600 + 600)
        XCTAssertEqual(s.mainSleep?.stageAsleepS, 8 * 3600 - 2100)
        XCTAssertEqual(s.mainSleep?.durationS, 8 * 3600, "duration comes from the episode, not the stages")

        let contrast = try XCTUnwrap(s.rhythm.first { $0.name == PC.SleepRhythm.dayNightContrastName })
        XCTAssertEqual(contrast.value, 20)
        XCTAssertTrue(contrast.isProxy)
        XCTAssertTrue(contrast.dependsOnHeartSignals)
        XCTAssertTrue(contrast.reasons.contains(PC.SleepRhythm.labelsReadHeartRate))
        XCTAssertEqual(s.phase.state, "unavailable")
        XCTAssertEqual(s.phase.reasons, [PC.SleepRhythm.endogenousPhaseUnmeasured])

        // V13: sleep labels read heart signals; wear evidence can be heart-derived; the proxy reads HR.
        let detector = try XCTUnwrap(s.dependence.first { $0.group == "sleep_detector" })
        XCTAssertEqual(detector.note, PC.SleepRhythm.sleepLabelsReadHeartSignals)
        for m in ["sleep_wake", "sleep_stages", "heart_rate", "hrv_rmssd", "respiratory_rate"] {
            XCTAssertTrue(detector.members.contains(m), m)
        }
        XCTAssertTrue(s.dependence.contains { $0.group == "wear_heart_signal" })
        XCTAssertTrue(s.dependence.contains { $0.group == "rhythm_proxy" })

        // Lossless JSON through the layer's canonical coder.
        let data = try PC.encoder().encode(s)
        XCTAssertEqual(try PC.decoder().decode(PC.SleepRhythmSummary.self, from: data), s)
    }

    func testEmptyDayIsUnavailableNotZeroAndPhaseNeverBlocks() throws {
        let id = F.identity(day)
        let s = PC.SleepRhythm.summary(episodes: [], priorSleep: [], identity: id, observations: .init(),
                                       mode: .causalLive, cutoff: F.at(day, 12), config: config)
        XCTAssertNil(s.mainSleepId)
        XCTAssertNil(s.totalSleepS)
        XCTAssertNil(s.mainSleep)
        XCTAssertEqual(s.sleepLoss.state, .unknown)
        XCTAssertTrue(s.reasons.contains(PC.SleepRhythm.noSleepEpisodes))
        XCTAssertTrue(s.reasons.contains(PC.SleepRhythm.noMainSleep))
        XCTAssertFalse(s.dependence.isEmpty, "the detector dependence is structural")
        XCTAssertEqual(s.phase, .unavailable)
        _ = try PC.encoder().encode(s)
    }

    // MARK: Engine integration

    func testEngineDocumentCarriesSleepContextAndRoundTrips() throws {
        let id = F.identity(day)
        let cutoff = F.at(day, 18)
        let hr = F.hr(F.at(prev, 23), cutoff, bpm: 64)
        let night = F.session("night", F.at(prev, 23), F.at(day, 7), available: F.at(day, 7, 20))
        let input = PC.DayInput(identity: id, mode: .causalLive, availabilityCutoff: cutoff, generatedAt: cutoff,
                                heartRate: hr, sleepSessions: [night],
                                regime: .init(scoringAlgorithmVersion: "frwhoop-server-1"))
        let doc = PC.Engine.buildDay(input, history: .empty)
        XCTAssertEqual(doc.sleep.mainSleepId, "night")
        let noon = try XCTUnwrap(doc.envelopes.first { $0.support.start == F.at(day, 12) && $0.metric == .heartRate })
        XCTAssertEqual(noon.sleepWear.sleepState, .awake)
        XCTAssertEqual(noon.history.wake.secondsSinceWake, 5 * 3600)
        let early = try XCTUnwrap(doc.envelopes.first { $0.support.start == F.at(day, 3) && $0.metric == .heartRate })
        XCTAssertEqual(early.sleepWear.sleepState, .asleep)
        XCTAssertTrue(doc.dependence.contains { $0.note == PC.SleepRhythm.sleepLabelsReadHeartSignals })
        let data = try PC.encoder().encode(doc)
        XCTAssertEqual(try PC.decoder().decode(PC.DayDocument.self, from: data), doc)
    }
}
