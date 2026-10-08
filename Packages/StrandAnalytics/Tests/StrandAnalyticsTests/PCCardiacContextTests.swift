import XCTest
@testable import StrandAnalytics

/// Spec-02 cardiac context: awake vs sleep HR (`DayNightHeartRate`), the policy fingerprint for the pulse detector,
/// and the engine → canonical JSON → decoder round trip of both new blocks (old documents still decode).
final class PCCardiacContextTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias F = PCSleepFixture
    let config = PC.SleepConfig()
    let day = "2026-10-01", prev = "2026-09-30"

    func summary(night: (Int, Int)?, hr: [PC.HeartRateObservation], mode: PC.ProcessingMode = .retrospective,
                 cutoff: Int? = nil, available: Int? = nil, config: PC.SleepConfig = .init()) -> PC.SleepRhythmSummary {
        let id = F.identity(day)
        let c = cutoff ?? id.dayWindow.end + 40 * 3600
        let sessions = night.map { [F.session("night", $0.0, $0.1, available: available)] } ?? []
        let eps = PC.SleepRhythm.episodes(sessions: sessions, identity: id, mode: mode, cutoff: c, config: config)
        return PC.SleepRhythm.summary(episodes: eps, priorSleep: [], identity: id,
                                      observations: .init(heartRate: hr.sorted { $0.ts < $1.ts }), mode: mode,
                                      cutoff: c, config: config)
    }

    func contrast(_ s: PC.SleepRhythmSummary) -> PC.RhythmDescriptor? {
        s.rhythm.first { $0.name == PC.SleepRhythm.dayNightContrastName }
    }

    // MARK: Awake vs sleep HR

    /// Night 23:00–07:00 at 55 bpm, day 07:00–21:00 at 75 (LA). Sleep: 28 800 samples over 28 800 eligible s.
    /// Awake: 50 400 samples (07:00–21:00); eligible = the 24 h day minus the 7 h of the night inside it = 61 200 s.
    func testBothMediansCoverageAndDipFromTheContrastSeries() throws {
        let night = (F.at(prev, 23), F.at(day, 7))
        let s = summary(night: night, hr: F.hr(night.0, night.1, bpm: 55) + F.hr(night.1, F.at(day, 21), bpm: 75))
        let d = try XCTUnwrap(s.dayNightHeartRate)
        XCTAssertEqual(d.state, .supported)
        XCTAssertEqual(d.awakeMedianBpm, 75)
        XCTAssertEqual(d.sleepMedianBpm, 55)
        XCTAssertEqual(d.differenceBpm, 20)
        XCTAssertEqual(try XCTUnwrap(d.percentDip), 100.0 * 20 / 75, accuracy: 1e-12)
        XCTAssertEqual(d.percentDipDefinition, "100*(awake_median_bpm-sleep_median_bpm)/awake_median_bpm")
        XCTAssertEqual(d.awakeSamples, 50_400)
        XCTAssertEqual(d.sleepSamples, 28_800)
        XCTAssertEqual(d.awakeEligibleS, 61_200)
        XCTAssertEqual(d.sleepEligibleS, 28_800)
        XCTAssertEqual(try XCTUnwrap(d.awakeCoverage), 50_400.0 / 61_200.0, accuracy: 1e-12)
        XCTAssertEqual(d.sleepCoverage, 1)
        XCTAssertEqual(d.method, "pc-day-night-hr-1")
        XCTAssertEqual(d.units, "bpm")
        XCTAssertEqual(d.minSamplesPerSide, 1800)
        XCTAssertEqual(d.awakeWindow, F.identity(day).dayWindow)
        XCTAssertTrue(d.reasons.contains(PC.SleepRhythm.percentDipDefinition))
        XCTAssertTrue(d.reasons.contains(PC.SleepRhythm.labelsReadHeartRate))
        XCTAssertFalse(d.reasons.contains(PC.SleepRhythm.awakeHrInsufficient))
        // The difference is exactly the value the existing contrast publishes (unchanged: 20, as before spec-02).
        XCTAssertEqual(contrast(s)?.value, 20)
        XCTAssertEqual(contrast(s)?.sampleCount, 50_400 + 28_800)
    }

    /// Mixed values, medians worked by hand. Awake: 2000 × 70 then 2001 × 90 → n = 4001, middle (index 2000) = 90.
    /// Sleep: 1000 × 50 then 1000 × 60 → n = 2000, (50 + 60) / 2 = 55. Dip = 100 × 35 / 90. Implausible samples
    /// (25 and 230 bpm) are left out of both sides, exactly as the contrast leaves them out.
    func testMediansOfMixedValuesAndImplausibleSamples() throws {
        let night = (F.at(prev, 23), F.at(day, 7))
        let n0 = night.0
        let w0 = F.at(day, 9)
        let hr = F.hr(n0, n0 + 1000, bpm: 50) + F.hr(n0 + 1000, n0 + 2000, bpm: 60) + F.hr(n0 + 2000, n0 + 2100, bpm: 25)
            + F.hr(w0, w0 + 2000, bpm: 70) + F.hr(w0 + 2000, w0 + 4001, bpm: 90) + F.hr(w0 + 5000, w0 + 5100, bpm: 230)
        let s = summary(night: night, hr: hr)
        let d = try XCTUnwrap(s.dayNightHeartRate)
        XCTAssertEqual(d.awakeMedianBpm, 90)
        XCTAssertEqual(d.sleepMedianBpm, 55)
        XCTAssertEqual(d.differenceBpm, 35)
        XCTAssertEqual(try XCTUnwrap(d.percentDip), 3500.0 / 90.0, accuracy: 1e-12)
        XCTAssertEqual(d.awakeSamples, 4001)
        XCTAssertEqual(d.sleepSamples, 2000)
        XCTAssertEqual(contrast(s)?.value, d.differenceBpm)
    }

    /// One side below `rhythmMinSamples` (1800): that side is nil with its reason, the other side is still
    /// reported, the difference and dip are nil, and the existing contrast is nil exactly as before.
    func testAnInsufficientSideIsNullWithItsReason() throws {
        let night = (F.at(prev, 23), F.at(day, 7))
        let w0 = F.at(day, 9)
        let s = summary(night: night, hr: F.hr(night.0, night.1, bpm: 55) + F.hr(w0, w0 + 1799, bpm: 75))
        let d = try XCTUnwrap(s.dayNightHeartRate)
        XCTAssertEqual(d.state, .partial)
        XCTAssertNil(d.awakeMedianBpm)
        XCTAssertEqual(d.sleepMedianBpm, 55)
        XCTAssertNil(d.differenceBpm)
        XCTAssertNil(d.percentDip)
        XCTAssertEqual(d.awakeSamples, 1799)
        XCTAssertTrue(d.reasons.contains(PC.SleepRhythm.awakeHrInsufficient))
        XCTAssertFalse(d.reasons.contains(PC.SleepRhythm.percentDipDefinition))
        XCTAssertNil(contrast(s)?.value)
        XCTAssertTrue(contrast(s)?.reasons.contains(PC.SleepRhythm.rhythmSamplesInsufficient) ?? false)

        // No sleep at all: the sleep side has no eligible time (coverage nil, not 0).
        let noNight = try XCTUnwrap(summary(night: nil, hr: F.hr(w0, w0 + 3600, bpm: 75)).dayNightHeartRate)
        XCTAssertEqual(noNight.state, .partial)
        XCTAssertEqual(noNight.awakeMedianBpm, 75)
        XCTAssertNil(noNight.sleepMedianBpm)
        XCTAssertNil(noNight.sleepCoverage)
        XCTAssertEqual(noNight.sleepEligibleS, 0)
        XCTAssertTrue(noNight.reasons.contains(PC.SleepRhythm.sleepHrInsufficient))
        XCTAssertTrue(noNight.reasons.contains(PC.SleepRhythm.noMainSleep))

        // No HR at all: unavailable, both reasons, samples 0.
        let empty = try XCTUnwrap(summary(night: night, hr: []).dayNightHeartRate)
        XCTAssertEqual(empty.state, .unavailable)
        XCTAssertEqual(empty.awakeSamples, 0)
        XCTAssertEqual(empty.awakeCoverage, 0)
        XCTAssertTrue(empty.reasons.contains(PC.SleepRhythm.awakeHrInsufficient))
        XCTAssertTrue(empty.reasons.contains(PC.SleepRhythm.sleepHrInsufficient))
    }

    /// A live document: the awake side stops at the cutoff; a main sleep still in progress gives no sleep side.
    func testCausalWindowAndUnfinishedNight() throws {
        let id = F.identity(day)
        let night = (F.at(prev, 23), F.at(day, 7))
        let cutoff = F.at(day, 12)
        let s = summary(night: night, hr: F.hr(night.0, night.1, bpm: 55) + F.hr(night.1, cutoff, bpm: 75),
                        mode: .causalLive, cutoff: cutoff)
        let d = try XCTUnwrap(s.dayNightHeartRate)
        XCTAssertEqual(d.awakeWindow, PC.Interval(id.dayWindow.start, cutoff))
        XCTAssertEqual(d.awakeEligibleS, 5 * 3600)
        XCTAssertEqual(d.awakeSamples, 5 * 3600)
        XCTAssertEqual(d.differenceBpm, 20)

        let early = F.at(day, 6, 50)
        // Published 30 s after its end and read 60 s after it: inside the completion margin, so not complete.
        let open = summary(night: (night.0, early), hr: F.hr(night.0, early, bpm: 55), mode: .causalLive,
                           cutoff: early + 60, available: early + 30)
        let o = try XCTUnwrap(open.dayNightHeartRate)
        XCTAssertNil(o.sleepMedianBpm)
        XCTAssertNil(o.sleepCoverage)
        XCTAssertTrue(o.reasons.contains(PC.SleepRhythm.mainSleepIncomplete))
        XCTAssertNil(contrast(open)?.value)
    }

    /// Duplicate samples weigh as the contrast weighs them (each sample once); coverage counts distinct seconds,
    /// so it never exceeds 1.
    func testDuplicatesNeverPushCoverageAboveOne() throws {
        let night = (F.at(prev, 23), F.at(day, 7))
        let hr = F.hr(night.0, night.1, bpm: 55) + F.hr(night.0, night.1, bpm: 55)
            + F.hr(night.1, F.at(day, 9), bpm: 75)
        let d = try XCTUnwrap(summary(night: night, hr: hr).dayNightHeartRate)
        XCTAssertEqual(d.sleepSamples, 2 * 28_800)
        XCTAssertEqual(d.sleepCoverage, 1)
    }

    // MARK: Policy fingerprint

    func testEveryPulseParameterMovesTheFingerprintAndNothingElseDoes() {
        let base = PC.Policy()
        XCTAssertEqual(base.fingerprint, PC.Policy().fingerprint, "stable for an unchanged policy")
        typealias C = PC.PulseEpisodeConfig
        let edits: [(String, (inout C) -> Void)] = [
            ("version", { $0.version = "pc-pulse-x" }),
            ("highEnterBpm", { $0.highEnterBpm += 1 }), ("highExitBpm", { $0.highExitBpm += 1 }),
            ("lowEnterBpm", { $0.lowEnterBpm += 1 }), ("lowExitBpm", { $0.lowExitBpm += 1 }),
            ("minDurationS", { $0.minDurationS += 1 }), ("exitHoldS", { $0.exitHoldS += 1 }),
            ("maxGapS", { $0.maxGapS += 1 }), ("accelerationRiseBpm", { $0.accelerationRiseBpm += 1 }),
            ("accelerationBaselineS", { $0.accelerationBaselineS += 1 }),
            ("accelerationRiseWithinS", { $0.accelerationRiseWithinS += 1 }),
            ("accelerationMovementWindowS", { $0.accelerationMovementWindowS += 1 }),
            ("minQualifiedExposureS", { $0.minQualifiedExposureS += 1 }),
            ("hrPlausibleMinBpm", { $0.hrPlausibleMinBpm += 1 }), ("hrPlausibleMaxBpm", { $0.hrPlausibleMaxBpm += 1 }),
            ("flatlineMaxStepS", { $0.flatlineMaxStepS += 1 }), ("flatlineMaxS", { $0.flatlineMaxS += 1 }),
            ("settleStillS", { $0.settleStillS += 1 }), ("postBoutExclusionS", { $0.postBoutExclusionS += 1 }),
            ("maxUnknownFraction", { $0.maxUnknownFraction += 0.01 }),
            ("accelerationBaselineMinS", { $0.accelerationBaselineMinS += 1 }),
            ("lookbackS", { $0.lookbackS += 1 }), ("lookaheadS", { $0.lookaheadS += 1 }),
        ]
        // Every stored field of the config is exercised (a new field must be added here).
        XCTAssertEqual(Set(edits.map(\.0)), Set(Mirror(reflecting: C()).children.compactMap(\.label)))
        var seen = Set([base.fingerprint])
        for (name, edit) in edits {
            var p = base
            edit(&p.pulse)
            XCTAssertNotEqual(p.fingerprint, base.fingerprint, name)
            seen.insert(p.fingerprint)
        }
        XCTAssertEqual(seen.count, edits.count + 1, "distinct keys")

        var dn = base
        dn.sleep.dayNightHeartRateVersion = "pc-day-night-hr-x"
        XCTAssertNotEqual(dn.fingerprint, base.fingerprint, "the day/night definition version is keyed")

        // Respiratory recovery does not compute in this build: its version neither moves the key nor is claimed.
        XCTAssertFalse(PC.Policy.respiratoryRecoveryComputes)
        var resp = base
        resp.exertion.respiratoryRecoveryVersion = "pc-resp-recovery-x"
        XCTAssertEqual(resp.fingerprint, base.fingerprint)
        XCTAssertNil(base.versions.respiratoryRecovery)
        XCTAssertEqual(base.versions.pulse, "pc-pulse-1")
        // …while the exertion config it sits in still keys everything else.
        var ex = base
        ex.exertion.hrGapMaxS += 1
        XCTAssertNotEqual(ex.fingerprint, base.fingerprint)
    }

    // MARK: Engine → JSON → decoder

    /// One LA day through the engine: a night 23:00–07:00 at 52/53, the day at 72/73 with a 20-minute
    /// stretch at 105/106 (14:00–14:20), strap motion still everywhere except 10:00–10:02, where HR rises.
    func engineInput() -> PC.DayInput {
        let id = F.identity(day)
        let n0 = F.at(prev, 23), n1 = F.at(day, 7)
        let e0 = F.at(day, 14), mv = F.at(day, 10)
        let start = F.at(prev, 22), end = F.at(day, 22)
        var hr: [PC.HeartRateObservation] = []
        var motion: [PC.MotionObservation] = []
        for t in start..<end {
            let k = t - start
            var bpm = (t >= n0 && t < n1 ? 52 : 72) + k % 2
            if t >= e0 && t < e0 + 1200 { bpm = 105 + k % 2 }
            if t >= mv + 3 && t < mv + 60 { bpm = 90 }
            hr.append(.init(ts: t, bpm: bpm))
            let moving = t >= mv && t < mv + 120
            motion.append(.init(ts: t, dynAccelG: moving ? 0.5 : 0.001))
        }
        return PC.DayInput(identity: id, mode: .retrospective, availabilityCutoff: id.dayWindow.end + 40 * 3600,
                           generatedAt: id.dayWindow.end + 40 * 3600, heartRate: hr, motion: motion,
                           sleepSessions: [F.session("night", n0, n1)],
                           regime: .init(scoringAlgorithmVersion: "frwhoop-server-1"))
    }

    func testEngineOutputRoundTripsThroughTheCanonicalCodersAndStorage() throws {
        let doc = PC.Engine.buildDay(engineInput(), history: .empty)
        let pulse = try XCTUnwrap(doc.pulseEpisodes)
        XCTAssertEqual(pulse.state, .supported)
        let high = try XCTUnwrap(pulse.episodes.first { $0.kind == PC.PulseEpisodes.kindHigh })
        XCTAssertEqual(high.interval, PC.Interval(F.at(day, 14), F.at(day, 14, 20)))
        XCTAssertEqual(high.context, "awake")
        XCTAssertEqual(high.censoring, [])
        XCTAssertEqual(pulse.accelerationEvents.count, 1)
        XCTAssertEqual(pulse.accelerationEvents.first?.context, "awake")
        let dn = try XCTUnwrap(doc.sleep.dayNightHeartRate)
        XCTAssertEqual(dn.state, .supported)
        XCTAssertEqual(dn.sleepMedianBpm, 52.5)
        XCTAssertEqual(doc.header.versions.pulse, "pc-pulse-1")
        XCTAssertNil(doc.header.versions.respiratoryRecovery)

        let data = try PC.encoder().encode(doc)
        let decoded = try PC.decoder().decode(PC.DayDocument.self, from: data)
        XCTAssertEqual(decoded, doc)
        XCTAssertEqual(decoded.pulseEpisodes, pulse)
        XCTAssertEqual(decoded.sleep.dayNightHeartRate, dn)
        XCTAssertEqual(try PC.encoder().encode(decoded), data)
        // The wire keys the edge function passes through and the app decodes.
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["pulse_episodes"])
        XCTAssertNotNil((json["sleep"] as? [String: Any])?["day_night_heart_rate"])

        // The stored form the worker publishes (summary + envelope tables) keeps both blocks.
        let (summary, tables) = PC.StoredDocument.split(doc)
        let s2 = try PC.decoder().decode(PC.DayDocument.self, from: PC.encoder().encode(summary))
        XCTAssertEqual(s2.pulseEpisodes, pulse)
        XCTAssertEqual(s2.sleep.dayNightHeartRate, dn)
        let t2 = try tables.map { try PC.decoder().decode(PC.EnvelopeTable.self, from: PC.encoder().encode($0)) }
        XCTAssertEqual(PC.StoredDocument.join(summary: s2, tables: t2), doc)

        // Deterministic.
        XCTAssertEqual(try PC.encoder().encode(PC.Engine.buildDay(engineInput(), history: .empty)), data)
    }

    func testDocumentsWithoutTheNewKeysStillDecode() throws {
        let doc = PC.Engine.buildDay(engineInput(), history: .empty)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: PC.encoder().encode(doc)) as? [String: Any])
        json.removeValue(forKey: "pulse_episodes")
        var sleep = try XCTUnwrap(json["sleep"] as? [String: Any])
        sleep.removeValue(forKey: "day_night_heart_rate")
        json["sleep"] = sleep
        var header = try XCTUnwrap(json["header"] as? [String: Any])
        var versions = try XCTUnwrap(header["versions"] as? [String: Any])
        versions.removeValue(forKey: "pulse")
        header["versions"] = versions
        json["header"] = header
        let old = try PC.decoder().decode(PC.DayDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.pulseEpisodes)
        XCTAssertNil(old.sleep.dayNightHeartRate)
        XCTAssertNil(old.header.versions.pulse)
        XCTAssertEqual(old.sleep.rhythm, doc.sleep.rhythm)
        XCTAssertEqual(old.envelopes, doc.envelopes)
    }

    func testNewReasonCodesAreRegistered() {
        for code in [PC.SleepRhythm.percentDipDefinition, PC.SleepRhythm.awakeHrInsufficient,
                     PC.SleepRhythm.sleepHrInsufficient] {
            XCTAssertTrue(PC.SleepRhythm.reasonCodes.contains(code), code.rawValue)
        }
        XCTAssertEqual(PC.SleepRhythm.reasonCodes.count, Set(PC.SleepRhythm.reasonCodes).count)
    }
}
