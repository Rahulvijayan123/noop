import XCTest
import WhoopProtocol
@testable import frwhoop_worker

/// DayScoring candidate-input assembly (observation-identity dedup, the exact HRV
/// provider payload) and the ACTIVE-promotion plumbing. All pure: no DB, no HTTP.
final class DayScoringCandidateInputTests: XCTestCase {

    private func beat(_ ts: Int, _ rrMs: Int, channel: RRSourceChannel? = .whoop5Historical,
                      ord: Int? = 0, seq: Int = 0) -> RRInterval {
        RRInterval(ts: ts, rrMs: rrMs, srcChannel: channel, ord: ord, seq: seq)
    }

    private func hrSample(_ ts: Int, _ bpm: Int) -> HRSample { HRSample(ts: ts, bpm: bpm) }

    /// The pre-sleep-input shape: hrv enabled and assembled.
    private func inputs(_ beats: [RRInterval], inputRows: Int? = nil) -> DayScorer.CandidateInputs {
        makeInputs(beats: beats, enabled: ["hrv"], inputRows: inputRows)
    }

    /// The full assembly shape, so each metric's payload can be asserted in
    /// isolation. `enabled` drives both the mode gate and what was assembled.
    private func makeInputs(beats: [RRInterval] = [],
                            hr: [HRSample] = [],
                            enabled: Set<String>,
                            inputRows: Int? = nil,
                            edits: [DayScorer.CandidateSleepEdit] = [],
                            window: (start: Int, end: Int)? = (1_772_006_400, 1_772_035_200),
                            profileVersion: String? = "profile1:abc",
                            correctionsVersion: String? = nil,
                            age: Int? = 34, gender: Int? = 1,
                            assembled: Bool = true) -> DayScorer.CandidateInputs {
        let deduped = DayScorer.dedupByObservationIdentity(beats)
        return DayScorer.CandidateInputs(
            userId: "u", deviceId: "d", day: "2026-10-01", inputRevision: 3,
            intervalStart: 1_772_006_400, intervalEnd: 1_772_035_200,
            claimSealedAt: Date(), status: "available",
            canonicalAvgHrv: 48.0, canonicalSdnn: 61.0,
            profileVersion: profileVersion,
            // Derived exactly as production derives it, so a test cannot assert a
            // version that the real assembly would never produce.
            correctionsVersion: correctionsVersion ?? DayScorer.correctionsVersion(edits),
            enabledMetrics: enabled, assembled: assembled,
            hrvBeats: DayScorer.candidateBeats(deduped),
            hrvInputRows: inputRows ?? beats.count,
            hrvTimestampResolution: "whole_seconds",
            hrSamples: DayScorer.candidateHRSamples(hr),
            rrRows: DayScorer.candidateRRRows(deduped),
            sleepWindowStart: window?.start, sleepWindowEnd: window?.end,
            sleepEdits: edits, age: age, gender: gender)
    }

    private func edit(_ start: Int, _ end: Int, entity: String = "sleep-1",
                      revision: Int64 = 7) -> DayScorer.CandidateSleepEdit {
        DayScorer.CandidateSleepEdit(
            entity: entity, revision: revision,
            payload: .object(["start": .int(start), "end": .int(end),
                              "originalStart": .int(start - 600), "originalEnd": .int(end + 600),
                              "isNap": .bool(false), "dismissed": .bool(false)]))
    }

    // MARK: - Observation-identity dedup

    func testEqualIntervalsInTheSameSecondAreKeptDistinct() {
        // Two GENUINE beats can share a second and an interval; `seq` is the
        // storage identity that separates them (spec section 5).
        let beats = [beat(1_772_006_400, 800, ord: 0, seq: 1),
                     beat(1_772_006_400, 800, ord: 1, seq: 2)]
        let deduped = DayScorer.dedupByObservationIdentity(beats)
        XCTAssertEqual(deduped.count, 2, "same-second equal intervals are different observations")
    }

    func testByteIdenticalRetransmissionCollapses() {
        let beats = [beat(1_772_006_400, 800, ord: 3, seq: 7),
                     beat(1_772_006_400, 800, ord: 3, seq: 7),
                     beat(1_772_006_400, 800, ord: 3, seq: 7)]
        XCTAssertEqual(DayScorer.dedupByObservationIdentity(beats).count, 1)
    }

    func testDifferentChannelOrIntervalOrSecondIsADifferentObservation() {
        let beats = [beat(1_772_006_400, 800, channel: .whoop5Historical, seq: 1),
                     beat(1_772_006_400, 800, channel: .whoop5Standard, seq: 1),
                     beat(1_772_006_400, 812, channel: .whoop5Historical, seq: 1),
                     beat(1_772_006_401, 800, channel: .whoop5Historical, seq: 1)]
        XCTAssertEqual(DayScorer.dedupByObservationIdentity(beats).count, 4)
    }

    func testDedupKeepsTheFirstOccurrenceInOrder() {
        let beats = [beat(10, 800, seq: 1), beat(11, 810, seq: 2), beat(10, 800, seq: 1)]
        let deduped = DayScorer.dedupByObservationIdentity(beats)
        XCTAssertEqual(deduped.map(\.ts), [10, 11])
    }

    // MARK: - Beat ordering and timestamps

    func testBeatsAreOrderedBySecondThenSequenceThenOrdinal() {
        let beats = [beat(1_772_006_401, 800, ord: 0, seq: 0),
                     beat(1_772_006_400, 810, ord: 5, seq: 2),
                     beat(1_772_006_400, 820, ord: 9, seq: 1)]
        let ordered = DayScorer.candidateBeats(beats)
        XCTAssertEqual(ordered.map(\.rrMs), [820, 810, 800])
        XCTAssertEqual(ordered.map(\.ts), [1_772_006_400, 1_772_006_400, 1_772_006_401])
    }

    func testIntervalEndFollowsTheStoreConvention() {
        let ordered = DayScorer.candidateBeats([beat(1_772_006_400, 850, seq: 1)])
        XCTAssertEqual(ordered[0].tsEndSeconds, 1_772_006_400.85, accuracy: 1e-9)
        XCTAssertEqual(ordered[0].ts, 1_772_006_400)
        XCTAssertEqual(ordered[0].rrMs, 850)
        XCTAssertEqual(ordered[0].srcChannel, RRSourceChannel.whoop5Historical.rawValue)
    }

    func testSubSecondReconstructionAccumulatesWithinOneBucket() {
        let beats = [beat(1_772_006_400, 800, ord: 0, seq: 1),
                     beat(1_772_006_400, 900, ord: 1, seq: 2),
                     beat(1_772_006_401, 700, ord: 0, seq: 3)]
        let ordered = DayScorer.candidateBeats(beats)
        XCTAssertEqual(ordered[0].tsEndReconstructedSeconds, 1_772_006_400.8, accuracy: 1e-9)
        XCTAssertEqual(ordered[1].tsEndReconstructedSeconds, 1_772_006_401.7, accuracy: 1e-9)
        // A new second restarts the accumulation from that second's own ts.
        XCTAssertEqual(ordered[2].tsEndReconstructedSeconds, 1_772_006_401.7, accuracy: 1e-9)
    }

    // MARK: - The HRV provider payload

    func testHrvInputCarriesBeatsWindowConfigAndIdentity() throws {
        let subject = inputs([beat(1_772_006_400, 800, ord: 0, seq: 1),
                              beat(1_772_006_400, 800, ord: 1, seq: 2),
                              beat(1_772_006_401, 790, ord: 0, seq: 3)])
        let payload = try XCTUnwrap(subject.input(for: "hrv"))
        guard case .object(let root) = payload else { return XCTFail("input must be an object") }
        guard case .array(let beats)? = root["beats"] else { return XCTFail("beats must be an array") }
        XCTAssertEqual(beats.count, 3)
        guard case .object(let window)? = root["window"] else { return XCTFail("window missing") }
        XCTAssertEqual(window["start_sec"]?.doubleValue, 1_772_006_400)
        XCTAssertEqual(window["end_sec"]?.doubleValue, 1_772_035_200)
        XCTAssertEqual(window["inclusive"], .bool(true))
        XCTAssertEqual(root["timestamp_convention"], .string("interval_end_seconds"))
        XCTAssertEqual(root["timestamp_resolution"], .string("whole_seconds"))
        guard case .object(let identity)? = root["observation_identity"] else {
            return XCTFail("observation_identity missing")
        }
        XCTAssertEqual(identity["input_rows"]?.doubleValue, 3)
        XCTAssertEqual(identity["deduped_rows"]?.doubleValue, 3)
        XCTAssertEqual(identity["bucket_seconds"]?.doubleValue, 1)
    }

    func testHrvConfigDefaultsMatchTheShippedProductionRules() throws {
        let subject = inputs([beat(1_772_006_400, 800, seq: 1)])
        let payload = try XCTUnwrap(subject.input(for: "hrv"))
        guard case .object(let config)? = payload.member("config") else {
            return XCTFail("config missing")
        }
        // Defaults are the shipped code's rules (hrv-neurokit findings 5a/5d), so a
        // shadow comparison is apples-to-apples with the canonical nightly value.
        XCTAssertEqual(config["window_sec"]?.doubleValue, 300)
        XCTAssertEqual(config["min_clean_beats"]?.doubleValue, 20)
        XCTAssertEqual(config["splice_tolerance_s"]?.doubleValue, 3.0)
        XCTAssertEqual(config["rr_min_ms"]?.doubleValue, 300)
        XCTAssertEqual(config["rr_max_ms"]?.doubleValue, 2000)
        XCTAssertEqual(config["malik_threshold"]?.doubleValue, 0.20)
        XCTAssertEqual(config["malik_radius"]?.doubleValue, 2)
        // 1.0 - (ceiling - 1.0) in binary floating point, so compare with a tolerance.
        XCTAssertEqual(try XCTUnwrap(config["coverage_floor"]?.doubleValue), 0.9, accuracy: 1e-9)
        XCTAssertEqual(config["coverage_ceiling"]?.doubleValue, 1.10)
        XCTAssertEqual(config["beat_accuracy_tolerance_s"]?.doubleValue, 0.5)
        XCTAssertEqual(config["beat_accuracy_min_fraction"]?.doubleValue, 0.5)
        XCTAssertEqual(config["max_rejected_fraction"], .null, "the nightly path has no artifact gate")
        XCTAssertEqual(config["aggregation"], .string("mean_over_windows"))
        XCTAssertEqual(config["pooling"], .string("sum_sq_and_pairs"))
    }

    func testObservationIdentityReportsPreAndPostDedupCounts() throws {
        let beats = [beat(1_772_006_400, 800, seq: 1), beat(1_772_006_400, 800, seq: 1),
                     beat(1_772_006_401, 810, seq: 2)]
        let subject = inputs(beats)
        let payload = try XCTUnwrap(subject.input(for: "hrv"))
        XCTAssertEqual(payload.member("observation_identity")?.doubleValue, nil)
        guard case .object(let identity)? = payload.member("observation_identity") else {
            return XCTFail("observation_identity missing")
        }
        XCTAssertEqual(identity["input_rows"]?.doubleValue, 3, "rows read")
        XCTAssertEqual(identity["deduped_rows"]?.doubleValue, 2, "rows the provider receives")
    }

    func testMetricsAreEmptyWithoutBeatsAndUnknownMetricsHaveNoInput() {
        let empty = inputs([])
        XCTAssertTrue(empty.metrics.isEmpty)
        XCTAssertNil(empty.input(for: "hrv"))
        XCTAssertNil(empty.input(for: "sleep_stage"))
        XCTAssertNil(empty.input(for: "respiration"))
        let populated = inputs([beat(1_772_006_400, 800, seq: 1)])
        XCTAssertEqual(populated.metrics, ["hrv"])
        XCTAssertNil(populated.input(for: "sleep_boundary"))
    }

    // MARK: - S-1: the HRV aggregation must be explicit

    func testHrvPayloadCarriesTopLevelAggregation() throws {
        // The provider's own default is "window" (score the FIRST 5-minute window
        // only). The worker must therefore state the aggregation it wants at the
        // TOP LEVEL, or the candidate is a 5-minute RMSSD presented as the nightly
        // value.
        let subject = inputs([beat(1_772_006_400, 800, seq: 1)])
        let payload = try XCTUnwrap(subject.input(for: "hrv"))
        XCTAssertEqual(payload.member("aggregation"), .string("mean_over_windows"))
        XCTAssertEqual(DayScorer.hrvAggregation, "mean_over_windows")
        // Mirrored into config for payloads that only read config.
        guard case .object(let config)? = payload.member("config") else {
            return XCTFail("config missing")
        }
        XCTAssertEqual(config["aggregation"], .string("mean_over_windows"))
    }

    // MARK: - Sleep candidate inputs (adapter contracts)

    func testSleepBoundaryPayloadMirrorsTheAdapterContract() throws {
        let subject = makeInputs(hr: [hrSample(1_772_006_460, 61), hrSample(1_772_006_400, 58)],
                                 enabled: ["sleep_boundary"])
        let payload = try XCTUnwrap(subject.input(for: "sleep_boundary"))
        guard case .array(let hr)? = payload.member("hr") else { return XCTFail("hr missing") }
        // Ordered by ts, and the compact [ts, bpm] pair form the adapter accepts.
        XCTAssertEqual(hr.count, 2)
        XCTAssertEqual(hr[0], .array([.int(1_772_006_400), .int(58)]))
        XCTAssertEqual(hr[1], .array([.int(1_772_006_460), .int(61)]))
        guard case .object(let window)? = payload.member("window") else {
            return XCTFail("window missing")
        }
        XCTAssertEqual(window["start_utc"], .string("2026-02-25T08:00:00Z"))
        XCTAssertEqual(window["end_utc"], .string("2026-02-25T16:00:00Z"))
        // wake_ts_utc drives the provider's analysis day, so it must be present.
        XCTAssertEqual(payload.member("wake_ts_utc"), .string("2026-02-25T16:00:00Z"))
        // analysis_day is deliberately omitted: the provider raises
        // analysis_day_mismatch when a supplied day disagrees with the wake date.
        XCTAssertNil(payload.member("analysis_day"))
        // No correction on this day -> no user_edit, so the provider scores.
        XCTAssertNil(payload.member("user_edit"))
    }

    func testSleepBoundaryCarriesUserEditSoTheProviderWithholds() throws {
        // A user-corrected session must reach the provider, whose contract is to
        // withhold `blocked_input / user_edit_present` rather than score over it.
        let subject = makeInputs(hr: [hrSample(1_772_006_400, 58)],
                                 enabled: ["sleep_boundary"],
                                 edits: [edit(1_772_007_000, 1_772_030_000)])
        let payload = try XCTUnwrap(subject.input(for: "sleep_boundary"))
        guard case .object(let userEdit)? = payload.member("user_edit") else {
            return XCTFail("user_edit missing")
        }
        XCTAssertNotNil(userEdit["primary"])
        guard case .array(let edits)? = userEdit["edits"] else { return XCTFail("edits missing") }
        XCTAssertEqual(edits.count, 1)
        // The edit's own bounds become the in-bed window for the call.
        guard case .object(let window)? = payload.member("window") else {
            return XCTFail("window missing")
        }
        XCTAssertEqual(window["start_utc"], .string("2026-02-25T08:10:00Z"))
        XCTAssertEqual(window["end_utc"], .string("2026-02-25T14:33:20Z"))
    }

    func testSleepStagePayloadMirrorsTheAdapterContract() throws {
        let subject = makeInputs(beats: [beat(1_772_006_401, 810, ord: 2, seq: 9),
                                         beat(1_772_006_400, 800, ord: 1, seq: 3)],
                                 enabled: ["sleep_stage"])
        let payload = try XCTUnwrap(subject.input(for: "sleep_stage"))
        guard case .array(let rr)? = payload.member("rr") else { return XCTFail("rr missing") }
        XCTAssertEqual(rr.count, 2)
        // [ts, rr_ms, seq, ord, ts_suspect], ordered by (ts, seq, ord).
        XCTAssertEqual(rr[0], .array([.int(1_772_006_400), .int(800), .int(3), .int(1), .int(0)]))
        XCTAssertEqual(rr[1], .array([.int(1_772_006_401), .int(810), .int(9), .int(2), .int(0)]))
        XCTAssertEqual(payload.member("window")?.member("start_utc"),
                       .string("2026-02-25T08:00:00Z"))
        XCTAssertEqual(payload.member("age"), .int(34))
        // sleepecg `SubjectData.gender` is `int | None` (FEMALE=0, MALE=1); a string
        // raises inside the adapter and is swallowed into insufficient_coverage.
        XCTAssertEqual(payload.member("gender"), .int(1))
    }

    func testSleepStageGenderIsEncodedForSleepecg() throws {
        // The accepted types come from sleepecg's SubjectData (`gender: int | None`,
        // `Gender.FEMALE = 0`, `Gender.MALE = 1`). Every value of
        // `profiles.sex_model` ('male' | 'female' | 'nonbinary') plus the absent
        // case is pinned here, because a string silently withholds the metric for
        // every user with a sex set.
        XCTAssertEqual(DayScorer.sleepecgGender(sexModel: "male"), 1)
        XCTAssertEqual(DayScorer.sleepecgGender(sexModel: "female"), 0)
        XCTAssertNil(DayScorer.sleepecgGender(sexModel: "nonbinary"))
        XCTAssertNil(DayScorer.sleepecgGender(sexModel: ""))
        XCTAssertNil(DayScorer.sleepecgGender(sexModel: nil))
        XCTAssertNil(DayScorer.sleepecgGender(sexModel: "unknown"))
        // Case/whitespace tolerant, so a stored variant cannot silently withhold.
        XCTAssertEqual(DayScorer.sleepecgGender(sexModel: " Male "), 1)

        // And the payload carries the integer, never the string.
        let male = makeInputs(beats: [beat(1_772_006_400, 800, seq: 1)],
                              enabled: ["sleep_stage"], gender: 1)
        XCTAssertEqual(male.input(for: "sleep_stage")?.member("gender"), .int(1))
        let female = makeInputs(beats: [beat(1_772_006_400, 800, seq: 1)],
                                enabled: ["sleep_stage"], gender: 0)
        XCTAssertEqual(female.input(for: "sleep_stage")?.member("gender"), .int(0))
        let nonbinary = makeInputs(beats: [beat(1_772_006_400, 800, seq: 1)],
                                   enabled: ["sleep_stage"], gender: nil)
        XCTAssertNil(nonbinary.input(for: "sleep_stage")?.member("gender"))
    }

    func testSleepStageOmitsAgeAndGenderWhenUnknown() throws {
        let subject = makeInputs(beats: [beat(1_772_006_400, 800, seq: 1)],
                                 enabled: ["sleep_stage"], age: nil, gender: nil)
        let payload = try XCTUnwrap(subject.input(for: "sleep_stage"))
        XCTAssertNil(payload.member("age"))
        XCTAssertNil(payload.member("gender"))
    }

    // MARK: - Mode gating (DD-2) and the off path

    func testEnabledMetricsIsEmptyWhenEveryModeIsOff() {
        let off = SelectedProvider(providerId: "p", providerVersion: "1",
                                   configVersion: "c", mode: "off")
        XCTAssertTrue(DayScorer.enabledMetrics(from: [:]).isEmpty)
        XCTAssertTrue(DayScorer.enabledMetrics(from: ["hrv": off, "sleep_stage": off]).isEmpty)
        let shadow = SelectedProvider(providerId: "p", providerVersion: "1",
                                      configVersion: "c", mode: "shadow")
        let active = SelectedProvider(providerId: "p2", providerVersion: "1",
                                      configVersion: "c", mode: "active")
        XCTAssertEqual(DayScorer.enabledMetrics(from: ["hrv": off, "sleep_stage": shadow]),
                       ["sleep_stage"])
        XCTAssertEqual(DayScorer.enabledMetrics(from: ["hrv": active, "sleep_boundary": shadow]),
                       ["hrv", "sleep_boundary"])
    }

    func testDisabledInputsAssembleNothing() {
        // The off path: no dedup, no ordering, no payload for any metric.
        let disabled = DayScorer.CandidateInputs.disabled(
            userId: "u", deviceId: "d", day: "2026-10-01", inputRevision: 3,
            intervalStart: 1_772_006_400, intervalEnd: 1_772_035_200,
            claimSealedAt: Date(), status: "available",
            canonicalAvgHrv: 48.0, canonicalSdnn: 61.0)
        XCTAssertFalse(disabled.assembled)
        XCTAssertTrue(disabled.enabledMetrics.isEmpty)
        XCTAssertTrue(disabled.hrvBeats.isEmpty)
        XCTAssertTrue(disabled.hrSamples.isEmpty)
        XCTAssertTrue(disabled.rrRows.isEmpty)
        XCTAssertTrue(disabled.metrics.isEmpty)
        for metric in CandidateStage.metrics {
            XCTAssertNil(disabled.input(for: metric), "\(metric) must have no payload when off")
        }
    }

    func testAssemblyIsGatedByEnabledMetric() {
        // hrv enabled: no HR or R-R rows were assembled for the sleep metrics.
        let hrvOnly = makeInputs(beats: [beat(1_772_006_400, 800, seq: 1)],
                                 hr: [hrSample(1_772_006_400, 58)], enabled: ["hrv"])
        XCTAssertEqual(hrvOnly.metrics, ["hrv"])
        XCTAssertNil(hrvOnly.input(for: "sleep_boundary"))
        XCTAssertNil(hrvOnly.input(for: "sleep_stage"))

        // sleep_boundary enabled: the HR stream was assembled, the R-R rows were not.
        let boundaryOnly = makeInputs(hr: [hrSample(1_772_006_400, 58)],
                                      enabled: ["sleep_boundary"])
        XCTAssertEqual(boundaryOnly.metrics, ["sleep_boundary"])
        XCTAssertNil(boundaryOnly.input(for: "hrv"))
        XCTAssertNil(boundaryOnly.input(for: "sleep_stage"))

        // All three enabled: every metric produces a payload.
        let all = makeInputs(beats: [beat(1_772_006_400, 800, seq: 1)],
                             hr: [hrSample(1_772_006_400, 58)],
                             enabled: ["hrv", "sleep_boundary", "sleep_stage"])
        XCTAssertEqual(all.metrics, ["hrv", "sleep_boundary", "sleep_stage"])
    }

    func testAssembledFlagOffSuppressesPayloadsEvenWhenEnabled() {
        // `assembled == false` (lane off) wins over the enabled set.
        let subject = makeInputs(beats: [beat(1_772_006_400, 800, seq: 1)],
                                 enabled: ["hrv"], assembled: false)
        XCTAssertTrue(subject.metrics.isEmpty)
        XCTAssertNil(subject.input(for: "hrv"))
    }

    // MARK: - Corrections / profile versions

    func testCorrectionsVersionIsNoneWithoutEditsAndChangesWithContent() {
        XCTAssertEqual(DayScorer.correctionsVersion([]), "none")
        let a = DayScorer.correctionsVersion([edit(1_772_007_000, 1_772_030_000)])
        let b = DayScorer.correctionsVersion([edit(1_772_007_100, 1_772_030_000)])
        let c = DayScorer.correctionsVersion([edit(1_772_007_000, 1_772_030_000, revision: 8)])
        XCTAssertTrue(a.hasPrefix("sleep_edit1:"))
        XCTAssertNotEqual(a, b, "a changed edit must change the version")
        XCTAssertNotEqual(a, c, "a changed revision must change the version")
        XCTAssertEqual(a, DayScorer.correctionsVersion([edit(1_772_007_000, 1_772_030_000)]),
                       "the same edits must produce the same version")
    }

    func testSleepEditsAreOrderedNewestFirst() {
        let newer = edit(1, 2, entity: "a", revision: 9)
        let older = edit(1, 2, entity: "b", revision: 4)
        let subject = makeInputs(hr: [hrSample(1, 60)], enabled: ["sleep_boundary"],
                                 edits: [newer, older])
        XCTAssertEqual(subject.sleepEdits.first?.revision, 9)
        XCTAssertEqual(subject.correctionsVersion, DayScorer.correctionsVersion([newer, older]))
    }

    // MARK: - ACTIVE promotion plumbing

    private func snapshotPayload() -> [String: Any] {
        ["daily": ["hrv_rmssd_ms": 48.0, "sleep_total_min": 420.0],
         "status": "available"]
    }

    private func legacyPayload() -> [String: Any] {
        ["daily_metrics": [["hrv_rmssd_ms": 48.0, "sleep_total_min": 420.0, "day": "2026-10-01"]]]
    }

    func testNoSubstitutionLeavesBothPayloadsUnchanged() {
        let snapshot = snapshotPayload()
        let legacy = legacyPayload()
        let result = DayScorer.applyActiveHrvSubstitution(snapshot: snapshot, legacy: legacy,
                                                          substitution: nil)
        let snapshotDaily = result.snapshot["daily"] as? [String: Any]
        XCTAssertEqual(snapshotDaily?["hrv_rmssd_ms"] as? Double, 48.0)
        XCTAssertNil(snapshotDaily?["hrv_provenance"])
        let legacyDaily = (result.legacy["daily_metrics"] as? [[String: Any]])?.first
        XCTAssertEqual(legacyDaily?["hrv_rmssd_ms"] as? Double, 48.0)
        XCTAssertEqual(legacyDaily?["day"] as? String, "2026-10-01")
    }

    func testActiveSubstitutionReplacesTheValueAndRecordsProvenance() {
        let substitution = CandidateStage.ActiveHrvSubstitution(
            value: 55.5, providerId: "production.runs.v1", providerVersion: "1.0.0",
            adapterVersion: "frwhoop.hrv.rmssd/1", configVersion: "cfg-1",
            inputSHA256: String(repeating: "b", count: 64), mode: "active")
        let result = DayScorer.applyActiveHrvSubstitution(snapshot: snapshotPayload(),
                                                          legacy: legacyPayload(),
                                                          substitution: substitution)
        let snapshotDaily = result.snapshot["daily"] as? [String: Any]
        XCTAssertEqual(snapshotDaily?["hrv_rmssd_ms"] as? Double, 55.5)
        // Every other canonical key is untouched.
        XCTAssertEqual(snapshotDaily?["sleep_total_min"] as? Double, 420.0)
        XCTAssertEqual(result.snapshot["status"] as? String, "available")
        let provenance = snapshotDaily?["hrv_provenance"] as? [String: Any]
        XCTAssertEqual(provenance?["mode"] as? String, "active")
        XCTAssertEqual(provenance?["provider_id"] as? String, "production.runs.v1")
        XCTAssertEqual(provenance?["provider_version"] as? String, "1.0.0")
        XCTAssertEqual(provenance?["adapter_version"] as? String, "frwhoop.hrv.rmssd/1")
        XCTAssertEqual(provenance?["config_version"] as? String, "cfg-1")
        XCTAssertEqual(provenance?["canonical_source"] as? String, "provider")
        XCTAssertEqual(provenance?["fallback"] as? String, "legacy_hrv_analyzer")
        XCTAssertEqual((provenance?["input_sha256"] as? String)?.count, 64)

        let legacyDaily = (result.legacy["daily_metrics"] as? [[String: Any]])?.first
        XCTAssertEqual(legacyDaily?["hrv_rmssd_ms"] as? Double, 55.5)
        XCTAssertEqual(legacyDaily?["sleep_total_min"] as? Double, 420.0)
        XCTAssertEqual(legacyDaily?["day"] as? String, "2026-10-01")
    }

    func testActiveSubstitutionToleratesAnEmptyLegacyDailyList() {
        let substitution = CandidateStage.ActiveHrvSubstitution(
            value: 50.0, providerId: "p", providerVersion: "1", adapterVersion: "a",
            configVersion: "c", inputSHA256: "sha", mode: "active")
        let result = DayScorer.applyActiveHrvSubstitution(snapshot: snapshotPayload(),
                                                          legacy: ["daily_metrics": [[String: Any]]()],
                                                          substitution: substitution)
        XCTAssertEqual((result.snapshot["daily"] as? [String: Any])?["hrv_rmssd_ms"] as? Double, 50.0)
        XCTAssertEqual((result.legacy["daily_metrics"] as? [[String: Any]])?.count, 0)
    }
}
