import XCTest
@testable import StrandAnalytics

/// Shared fixtures for the System C (sleep & rhythm) tests.
enum PCSleepFixture {
    typealias PC = PhysiologyContext

    static let la = "America/Los_Angeles"
    static let ny = "America/New_York"
    static let london = "Europe/London"

    /// Wall-clock time in a zone → Unix seconds (hours 0...23 only; never an ambiguous fall-back hour).
    static func at(_ day: String, _ h: Int, _ m: Int = 0, tz: String = la) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        let p = day.split(separator: "-").map { Int($0)! }
        let date = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: h, minute: m))!
        return Int(date.timeIntervalSince1970)
    }

    static func identity(_ day: String, tz: String = la) -> PC.DayIdentity {
        PC.DayIdentity(deviceScope: "dev-1", day: day, timezoneId: tz,
                       dayWindow: PC.Engine.dayInterval(day, timezoneId: tz))
    }

    static func session(_ id: String, _ start: Int, _ end: Int, available: Int? = nil,
                        useDefaultAvailability: Bool = true, nap: Bool? = nil, sourceDay: String? = nil,
                        stages: [PC.StageSpan] = []) -> PC.SleepSessionInput {
        PC.SleepSessionInput(id: id, interval: .init(start, end), isNap: nap, stages: stages,
                             availableAt: available ?? (useDefaultAvailability ? end + 600 : nil),
                             sourceDay: sourceDay, detector: "frwhoop-server-1")
    }

    static func hr(_ from: Int, _ to: Int, bpm: Int = 60, step: Int = 1) -> [PC.HeartRateObservation] {
        stride(from: from, to: to, by: step).map { PC.HeartRateObservation(ts: $0, bpm: bpm, availableAt: $0 + 60) }
    }

    static func shift(_ day: String, _ n: Int, tz: String = la) -> String {
        PC.SleepRhythm.shiftDay(day, by: n, timezoneId: tz)
    }
}

/// Episodes and wake-relative timing (V06 DST / split / naps / cross-midnight / unfinished nights, V10 replay).
final class PCSleepEpisodeTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias F = PCSleepFixture
    let config = PC.SleepConfig()

    // MARK: V06 — DST

    func testSpringForwardNightIsMeasuredInRealSeconds() {
        let day = "2026-03-08"
        let id = F.identity(day)
        // Independent: 2026-03-08 00:00 UTC = 1772928000; LA midnight (PST) = 08:00 UTC; next midnight is PDT.
        XCTAssertEqual(id.dayWindow, PC.Interval(1_772_956_800, 1_773_039_600))
        XCTAssertEqual(id.dayWindow.duration, 23 * 3600)
        // 23:00 PST (07:00 UTC) → 07:00 PDT (14:00 UTC): 7 real hours, 8 on the wall clock.
        let night = F.session("n", 1_772_953_200, 1_772_978_400)
        XCTAssertEqual(F.at("2026-03-07", 23), 1_772_953_200)
        XCTAssertEqual(F.at(day, 7), 1_772_978_400)
        let eps = PC.SleepRhythm.episodes(sessions: [night], identity: id, mode: .retrospective,
                                          cutoff: id.dayWindow.end + 40 * 3600, config: config)
        XCTAssertEqual(eps.count, 1)
        XCTAssertEqual(eps[0].durationS, 25_200)
        XCTAssertEqual(eps[0].ownerDay, day)
        XCTAssertEqual(eps[0].kind, .mainSleep)
        XCTAssertTrue(eps[0].complete)
        XCTAssertEqual(eps[0].finality, .final)
        // 09:00 PDT = 16:00 UTC: two real hours after the 07:00 PDT wake.
        let wake = PC.SleepRhythm.wakeReference(at: 1_772_985_600, episodes: eps, mode: .retrospective,
                                                cutoff: id.dayWindow.end + 40 * 3600, config: config)
        XCTAssertEqual(wake.secondsSinceWake, 7200)
        XCTAssertEqual(wake.referenceKind, .mainSleep)
        // Local wake time carries the zone and the post-jump offset.
        let summary = PC.SleepRhythm.summary(episodes: eps, priorSleep: [], identity: id,
                                             observations: .init(), mode: .retrospective,
                                             cutoff: id.dayWindow.end + 40 * 3600, config: config)
        XCTAssertEqual(summary.timing.wake?.timezoneId, F.la)
        XCTAssertEqual(summary.timing.wake?.utcOffsetS, -7 * 3600)
        XCTAssertEqual(summary.timing.wake?.secondsOfDay, 7 * 3600)
        XCTAssertEqual(summary.timing.onset?.utcOffsetS, -8 * 3600)
        XCTAssertEqual(summary.mainSleep?.durationS, 25_200)
    }

    func testWakeReferenceAcrossTheSpringJumpUsesRealSeconds() {
        let day = "2026-03-08"
        let id = F.identity(day)
        // Night ends 01:30 PST (09:30 UTC); the measurement is at 03:30 PDT (10:30 UTC): one real hour.
        let night = F.session("n", F.at("2026-03-07", 22), 1_772_962_200)
        let eps = PC.SleepRhythm.episodes(sessions: [night], identity: id, mode: .retrospective,
                                          cutoff: id.dayWindow.end + 40 * 3600, config: config)
        let wake = PC.SleepRhythm.wakeReference(at: 1_772_965_800, episodes: eps, mode: .retrospective,
                                                cutoff: id.dayWindow.end + 40 * 3600, config: config)
        XCTAssertEqual(wake.secondsSinceWake, 3600)
        XCTAssertEqual(wake.wakeAt, 1_772_962_200)
    }

    func testFallBackDayHasTwentyFiveHoursAndANineHourNight() {
        let day = "2026-11-01"
        let id = F.identity(day)
        XCTAssertEqual(id.dayWindow.duration, 25 * 3600)
        // 23:00 PDT Oct 31 (06:00 UTC Nov 1) → 07:00 PST Nov 1 (15:00 UTC): 9 real hours.
        let start = F.at("2026-10-31", 23), end = F.at(day, 7)
        XCTAssertEqual(end - start, 9 * 3600)
        let eps = PC.SleepRhythm.episodes(sessions: [F.session("n", start, end)], identity: id, mode: .retrospective,
                                          cutoff: id.dayWindow.end + 40 * 3600, config: config)
        XCTAssertEqual(eps.first?.durationS, 32_400)
        XCTAssertEqual(eps.first?.ownerDay, day)
    }

    // MARK: V06 — split sleep, naps, cross-midnight ownership

    func testSplitSleepFragmentsAreBothMainSleepWithOneGroup() {
        let day = "2026-10-01", prev = "2026-09-30"
        let id = F.identity(day)
        let a = F.session("a", F.at(prev, 23), F.at(day, 2, 30))
        let b = F.session("b", F.at(day, 3), F.at(day, 7))
        let nap = F.session("nap", F.at(day, 14), F.at(day, 15))
        let cutoff = id.dayWindow.end + 40 * 3600
        let eps = PC.SleepRhythm.episodes(sessions: [nap, b, a], identity: id, mode: .retrospective,
                                          cutoff: cutoff, config: config)
        XCTAssertEqual(eps.map(\.id), ["a", "b", "nap"], "sorted by start")
        XCTAssertEqual(eps[0].kind, .mainSleep)
        XCTAssertEqual(eps[1].kind, .mainSleep)
        XCTAssertEqual(eps[2].kind, .nap)
        XCTAssertNotNil(eps[0].splitGroupId)
        XCTAssertEqual(eps[0].splitGroupId, eps[1].splitGroupId)
        XCTAssertNil(eps[2].splitGroupId)
        XCTAssertTrue(eps[0].reasons.contains(PC.SleepRhythm.splitSleep))

        let s = PC.SleepRhythm.summary(episodes: eps, priorSleep: [], identity: id, observations: .init(),
                                       mode: .retrospective, cutoff: cutoff, config: config)
        XCTAssertEqual(s.mainSleep?.durationS, 3 * 3600 + 1800 + 4 * 3600)
        XCTAssertEqual(s.mainSleep?.fragmentGapS, 1800)
        XCTAssertEqual(s.mainSleep?.span, PC.Interval(F.at(prev, 23), F.at(day, 7)))
        XCTAssertEqual(s.mainSleepId, "b", "longest fragment")
        XCTAssertEqual(s.naps, PC.NapSummary(count: 1, totalS: 3600, episodeIds: ["nap"]))
        XCTAssertEqual(s.totalSleepS, 27_000 + 3600)
        XCTAssertEqual(s.finality, .final)

        // Inside the gap the latest awakening is the first fragment's end, flagged as a split-sleep gap.
        let w = PC.SleepRhythm.wakeReference(at: F.at(day, 2, 45), episodes: eps, mode: .retrospective,
                                             cutoff: cutoff, config: config)
        XCTAssertEqual(w.secondsSinceWake, 900)
        XCTAssertEqual(w.referenceEpisodeId, "a")
        XCTAssertTrue(w.reasons.contains(PC.SleepRhythm.insideSplitSleepGap))
    }

    func testNapsMainSleepAndCrossMidnightOwnershipByEnd() {
        let day = "2026-10-01", prev = "2026-09-30", next = "2026-10-02"
        let id = F.identity(day)
        let night = F.session("night", F.at(prev, 22, 30), F.at(day, 6, 30))
        let nap = F.session("nap", F.at(day, 13), F.at(day, 14, 30))
        let late = F.session("late", F.at(day, 23, 30), F.at(next, 1))
        let cutoff = id.dayWindow.end + 40 * 3600
        let eps = PC.SleepRhythm.episodes(sessions: [late, nap, night], identity: id, mode: .retrospective,
                                          cutoff: cutoff, config: config)
        let byId = Dictionary(uniqueKeysWithValues: eps.map { ($0.id, $0) })
        XCTAssertEqual(byId["night"]?.ownerDay, day, "started the evening before, owned by the day it ends")
        XCTAssertEqual(byId["nap"]?.ownerDay, day)
        XCTAssertEqual(byId["late"]?.ownerDay, next, "starts on the day, ends after midnight")
        XCTAssertEqual(byId["night"]?.kind, .mainSleep)
        XCTAssertEqual(byId["nap"]?.kind, .nap)
        XCTAssertEqual(byId["late"]?.kind, .mainSleep, "the only session of its own day")
        XCTAssertEqual(byId["nap"]?.classificationBasis, PC.SleepRhythm.basisMainNightGroupRule)

        // Afternoon: the reference stays the main-sleep wake, the later nap is reported alongside.
        let w = PC.SleepRhythm.wakeReference(at: F.at(day, 16), episodes: eps, mode: .retrospective,
                                             cutoff: cutoff, config: config)
        XCTAssertEqual(w.secondsSinceWake, (16 * 60 - (6 * 60 + 30)) * 60)
        XCTAssertEqual(w.referenceEpisodeId, "night")
        XCTAssertEqual(w.latestNapEndAt, F.at(day, 14, 30))
        XCTAssertTrue(w.reasons.contains(PC.SleepRhythm.napAfterMainWake))
        // During sleep there is no "time since waking".
        let inside = PC.SleepRhythm.wakeReference(at: F.at(day, 2), episodes: eps, mode: .retrospective,
                                                  cutoff: cutoff, config: config)
        XCTAssertNil(inside.secondsSinceWake)
        XCTAssertEqual(inside.reasons, [PC.SleepRhythm.insideSleepEpisode])
    }

    func testScorerNapTrueIsHonoredAndAnUninformativeFalseIsNot() {
        let day = "2026-10-01", prev = "2026-09-30"
        let id = F.identity(day)
        let cutoff = id.dayWindow.end + 40 * 3600
        // The scorer publishes is_nap = false for everything today: the rule still separates main and nap.
        let night = F.session("night", F.at(prev, 23), F.at(day, 7), nap: false)
        let nap = F.session("nap", F.at(day, 13), F.at(day, 14), nap: false)
        let ruled = PC.SleepRhythm.episodes(sessions: [night, nap], identity: id, mode: .retrospective,
                                            cutoff: cutoff, config: config)
        XCTAssertEqual(ruled.map(\.kind), [.mainSleep, .nap])
        // An explicit nap flag wins even for the longest block of the day.
        let flagged = F.session("night", F.at(prev, 23), F.at(day, 7), nap: true)
        let honored = PC.SleepRhythm.episodes(sessions: [flagged, nap], identity: id, mode: .retrospective,
                                              cutoff: cutoff, config: config)
        XCTAssertEqual(honored[0].kind, .nap)
        XCTAssertEqual(honored[0].classificationBasis, PC.SleepRhythm.basisScorerNapFlag)
        XCTAssertEqual(honored[1].kind, .mainSleep, "the remaining block is the day's main sleep")
    }

    // MARK: V06 / V10 — unfinished nights

    func testUnfinishedNightIsIncompleteLiveAndCompleteRetrospectively() {
        let day = "2026-10-01", prev = "2026-09-30"
        let id = F.identity(day)
        let cutoff = F.at(day, 3)
        // Published at 02:58 with the data ending at 02:55: the night is still running.
        let partial = F.session("night", F.at(prev, 23), F.at(day, 2, 55), available: F.at(day, 2, 58))
        let live = PC.SleepRhythm.episodes(sessions: [partial], identity: id, mode: .causalLive, cutoff: cutoff,
                                           config: config)
        XCTAssertEqual(live.count, 1)
        XCTAssertFalse(live[0].complete)
        XCTAssertEqual(live[0].finality, .provisional)
        XCTAssertLessThanOrEqual(live[0].interval.end, cutoff, "no future end")
        XCTAssertEqual(live[0].interval.end, F.at(day, 2, 55))
        XCTAssertTrue(live[0].reasons.contains(PC.SleepRhythm.sessionReachesCutoff))
        XCTAssertTrue(live[0].reasons.contains(PC.SleepRhythm.classificationProvisional))
        // Its end is not an awakening.
        let w = PC.SleepRhythm.wakeReference(at: F.at(day, 2, 59), episodes: live, mode: .causalLive,
                                             cutoff: cutoff, config: config)
        XCTAssertNil(w.secondsSinceWake)
        XCTAssertEqual(w.reasons, [PC.SleepRhythm.sleepInProgress])

        // The final record (published 07:20) is invisible at 03:00, with or without a known availability.
        let final = F.session("night", F.at(prev, 23), F.at(day, 7), available: F.at(day, 7, 20))
        let finalUnknownAvailability = F.session("night", F.at(prev, 23), F.at(day, 7),
                                                 useDefaultAvailability: false)
        for extra in [final, finalUnknownAvailability] {
            let replay = PC.SleepRhythm.episodes(sessions: [partial, extra], identity: id, mode: .causalLive,
                                                 cutoff: cutoff, config: config)
            XCTAssertEqual(replay, live)
        }

        // Retrospectively the same night is complete, with its final end and a real wake reference.
        let retroCutoff = id.dayWindow.end + 40 * 3600
        let retro = PC.SleepRhythm.episodes(sessions: [partial, final], identity: id, mode: .retrospective,
                                            cutoff: retroCutoff, config: config)
        XCTAssertEqual(retro.count, 1)
        XCTAssertTrue(retro[0].complete)
        XCTAssertEqual(retro[0].interval.end, F.at(day, 7))
        XCTAssertTrue(retro[0].reasons.contains(PC.SleepRhythm.sessionRevisionResolved))
        let rw = PC.SleepRhythm.wakeReference(at: F.at(day, 9), episodes: retro, mode: .retrospective,
                                              cutoff: retroCutoff, config: config)
        XCTAssertEqual(rw.secondsSinceWake, 7200)
    }

    func testRecentWakeIsUsableButFlaggedAsRevisable() {
        let day = "2026-10-01", prev = "2026-09-30"
        let id = F.identity(day)
        let night = F.session("night", F.at(prev, 23), F.at(day, 7), available: F.at(day, 7, 20))
        let cutoff = F.at(day, 8)
        let eps = PC.SleepRhythm.episodes(sessions: [night], identity: id, mode: .causalLive, cutoff: cutoff,
                                          config: config)
        XCTAssertTrue(eps[0].complete, "ended an hour before the cutoff")
        XCTAssertTrue(eps[0].detectorMayExtend)
        let w = PC.SleepRhythm.wakeReference(at: F.at(day, 7, 45), episodes: eps, mode: .causalLive,
                                             cutoff: cutoff, config: config)
        XCTAssertEqual(w.secondsSinceWake, 45 * 60)
        XCTAssertTrue(w.reasons.contains(PC.SleepRhythm.wakeMayBeRevised))
    }

    func testCausalSessionClaimingAnEndAfterTheCutoffIsClipped() {
        let day = "2026-10-01", prev = "2026-09-30"
        let id = F.identity(day)
        let cutoff = F.at(day, 3)
        // A record available before the cutoff that nevertheless claims a 07:00 end (clock skew).
        let odd = F.session("night", F.at(prev, 23), F.at(day, 7), available: F.at(day, 2))
        let eps = PC.SleepRhythm.episodes(sessions: [odd], identity: id, mode: .causalLive, cutoff: cutoff,
                                          config: config)
        XCTAssertEqual(eps[0].interval.end, cutoff)
        XCTAssertFalse(eps[0].complete)
        XCTAssertTrue(eps[0].reasons.contains(PC.SleepRhythm.sessionEndClippedToCutoff))
    }

    func testNoWakeReferenceWithoutAnEarlierCompleteEpisodeOrBeyondTheLookback() {
        let day = "2026-10-01", prev = "2026-09-30"
        let id = F.identity(day)
        let cutoff = id.dayWindow.end + 40 * 3600
        XCTAssertEqual(PC.SleepRhythm.wakeReference(at: F.at(day, 9), episodes: [], mode: .retrospective,
                                                    cutoff: cutoff, config: config).reasons,
                       [PC.SleepRhythm.noCompletedSleepBefore])
        let old = PC.SleepRhythm.episodes(sessions: [F.session("old", F.at(prev, 0), F.at(prev, 6))],
                                          identity: id, mode: .retrospective, cutoff: cutoff, config: config)
        let w = PC.SleepRhythm.wakeReference(at: F.at(day, 9), episodes: old, mode: .retrospective, cutoff: cutoff,
                                             config: config)
        XCTAssertNil(w.secondsSinceWake, "27 h since the last detected wake: no supported reference")
        XCTAssertTrue(w.reasons.contains(PC.SleepRhythm.referenceBeyondLookback))
    }

    // MARK: Revisions

    func testRevisionsAndOverlappingVersionsResolveToTheLatestAvailable() {
        let day = "2026-10-01", prev = "2026-09-30"
        let id = F.identity(day)
        let early = F.session("x", F.at(prev, 23), F.at(day, 5), available: F.at(day, 5, 10))
        let late = F.session("x", F.at(prev, 23), F.at(day, 7), available: F.at(day, 7, 20))
        // A refined onset produced a new id for the same night, published earlier: superseded.
        let otherId = F.session("y", F.at(prev, 22, 50), F.at(day, 6), available: F.at(day, 6, 30))
        let cutoff = id.dayWindow.end + 40 * 3600
        for order in [[early, late, otherId], [otherId, late, early], [late, otherId, early]] {
            let eps = PC.SleepRhythm.episodes(sessions: order, identity: id, mode: .retrospective, cutoff: cutoff,
                                              config: config)
            XCTAssertEqual(eps.count, 1)
            XCTAssertEqual(eps[0].id, "x")
            XCTAssertEqual(eps[0].interval.end, F.at(day, 7))
            XCTAssertTrue(eps[0].reasons.contains(PC.SleepRhythm.sessionRevisionResolved))
            XCTAssertTrue(eps[0].reasons.contains(PC.SleepRhythm.overlappingSessionSuperseded))
        }
        // Live at 06:45 only the 05:00 version and the 06:00 one exist; the later-published one wins.
        let live = PC.SleepRhythm.episodes(sessions: [early, late, otherId], identity: id, mode: .causalLive,
                                           cutoff: F.at(day, 6, 45), config: config)
        XCTAssertEqual(live.map(\.id), ["y"])
    }

    // MARK: V10 — appended future data does not change a causal summary

    func testAppendingLaterSessionsDoesNotChangeTheCausalSummary() throws {
        let day = "2026-10-01", prev = "2026-09-30"
        let id = F.identity(day)
        let cutoff = F.at(day, 12)
        let night = F.session("night", F.at(prev, 23), F.at(day, 7), available: F.at(day, 7, 20))
        let prior = (1...7).map { k -> PC.SleepSessionInput in
            let d = F.shift(day, -k)
            return F.session("p\(k)", F.at(F.shift(d, -1), 23), F.at(d, 7), sourceDay: d)
        }
        let hr = F.hr(F.at(day, 7), cutoff, bpm: 70, step: 5)
        let obs = PC.SanitizedObservations(heartRate: hr)
        func live(_ sessions: [PC.SleepSessionInput]) throws -> Data {
            let eps = PC.SleepRhythm.episodes(sessions: sessions, identity: id, mode: .causalLive, cutoff: cutoff,
                                              config: config)
            let s = PC.SleepRhythm.summary(episodes: eps, priorSleep: prior, identity: id, observations: obs,
                                           mode: .causalLive, cutoff: cutoff, config: config)
            return try PC.encoder().encode(s)
        }
        let base = try live([night])
        // A nap after the cutoff, a nap before it that was published late, and the next night.
        let napAfter = F.session("nap2", F.at(day, 13), F.at(day, 14))
        let napLate = F.session("nap1", F.at(day, 10), F.at(day, 11), available: F.at(day, 12, 30))
        let nextNight = F.session("next", F.at(day, 23), F.at("2026-10-02", 7))
        XCTAssertEqual(try live([night, napAfter, napLate, nextNight]), base)
        // The retrospective view sees them and is a different product.
        let retro = PC.SleepRhythm.episodes(sessions: [night, napAfter, napLate, nextNight], identity: id,
                                            mode: .retrospective, cutoff: id.dayWindow.end + 40 * 3600,
                                            config: config)
        XCTAssertEqual(retro.count, 4)
    }
}
