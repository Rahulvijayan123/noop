import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// The physiology-context lane without a database: configuration, job and window parsing, the mapping of
/// published products to measurements with their actual supports, the causal cutoff, the publish payload and
/// determinism. These assert plumbing only; the context systems' values belong to their own suites.
final class ContextLaneTests: XCTestCase {
    typealias PC = PhysiologyContext

    // 2026-10-03T00:00:00Z
    let dayStart = 1_790_985_600
    var dayEnd: Int { dayStart + 86_400 }

    private func baseEnv(_ extra: [String: String] = [:]) -> [String: String] {
        ["FRWHOOP_DB_URL": "postgres://u:p@host:5432/postgres", "FRWHOOP_B2_KEY_ID": "key",
         "FRWHOOP_B2_APPLICATION_KEY": "secret", "FRWHOOP_INGEST_SECRET": "ingest"].merging(extra) { $1 }
    }

    private func job(mode: PC.ProcessingMode = .retrospective, claimedAt: Int? = nil, override: Int? = nil,
                     day: String = "2026-10-03", tz: String = "UTC") -> ContextInputs.Job {
        ContextInputs.Job(userId: "u", deviceId: "d", day: day, mode: mode, inputRevision: 3, leaseToken: "t",
                          timezoneId: tz, cutoffOverride: override, claimedAt: claimedAt ?? (dayStart + 40 * 3_600))
    }

    private func windows(_ day: String = "2026-10-03", _ tz: String = "UTC") throws -> ContextInputs.Windows {
        try XCTUnwrap(ContextInputs.windows(day: day, timezoneId: tz))
    }

    // MARK: - Configuration

    func testTheLaneIsOffByDefault() throws {
        let c = try WorkerConfig(environment: baseEnv())
        XCTAssertFalse(c.contextEnabled)
        XCTAssertFalse(c.contextLaneRuns)
        XCTAssertEqual(c.contextBudget, 2)
        XCTAssertEqual(c.contextLeaseSeconds, 300)
        XCTAssertEqual(c.contextEnqueueIntervalSeconds, 120)
    }

    func testOnlyTheExactValueOneEnablesTheLane() throws {
        for value in ["true", "yes", "on", "01", " 1", "TRUE", ""] {
            let c = try WorkerConfig(environment: baseEnv(["FRWHOOP_CONTEXT_ENABLED": value]))
            XCTAssertFalse(c.contextLaneRuns, "'\(value)' must not enable the lane")
        }
        let on = try WorkerConfig(environment: baseEnv([
            "FRWHOOP_CONTEXT_ENABLED": "1", "FRWHOOP_CONTEXT_BUDGET": "5", "FRWHOOP_CONTEXT_LEASE_SECONDS": "600",
            "FRWHOOP_CONTEXT_ENQUEUE_INTERVAL_SECONDS": "30"]))
        XCTAssertTrue(on.contextLaneRuns)
        XCTAssertEqual(on.contextBudget, 5)
        XCTAssertEqual(on.contextLeaseSeconds, 600)
        XCTAssertEqual(on.contextEnqueueIntervalSeconds, 30)
    }

    func testDisableLanesTurnsTheLaneOffWithoutTouchingTheOthers() throws {
        let c = try WorkerConfig(environment: baseEnv([
            "FRWHOOP_CONTEXT_ENABLED": "1", "FRWHOOP_DISABLE_LANES": "projection, Context ,series"]))
        XCTAssertTrue(c.contextEnabled)
        XCTAssertFalse(c.contextLaneRuns)
        XCTAssertEqual(c.disabledLanes, ["projection", "context", "series"])
        // Unrelated lanes keep their defaults.
        XCTAssertFalse(c.activityEnabled)
        XCTAssertNil(c.inferenceURL)
        XCTAssertEqual(c.scoringBudget, 4)
    }

    func testBadKnobsFallBackToSafeValues() throws {
        let c = try WorkerConfig(environment: baseEnv([
            "FRWHOOP_CONTEXT_ENABLED": "1", "FRWHOOP_CONTEXT_BUDGET": "0", "FRWHOOP_CONTEXT_LEASE_SECONDS": "5",
            "FRWHOOP_CONTEXT_ENQUEUE_INTERVAL_SECONDS": "x"]))
        XCTAssertEqual(c.contextBudget, 1)
        XCTAssertEqual(c.contextLeaseSeconds, 30)
        XCTAssertEqual(c.contextEnqueueIntervalSeconds, 120)
    }

    func testQueueAgeIncludesTheContextQueueOnlyWhenAsked() {
        let off = queueAgeQuery(includeActivity: true)
        XCTAssertFalse(off.contains("physiology_context_jobs"))
        let on = queueAgeQuery(includeActivity: true, includeContext: true)
        XCTAssertTrue(on.contains("public.physiology_context_jobs"))
        XCTAssertTrue(on.contains("'context'"))
        XCTAssertEqual(on.components(separatedBy: "union all").count,
                       off.components(separatedBy: "union all").count + 1)
        XCTAssertEqual(on.components(separatedBy: "from q").count, 2)
        // The default keeps the existing callers' query byte-identical.
        XCTAssertEqual(queueAgeQuery(includeActivity: false), queueAgeQuery(includeActivity: false, includeContext: false))
    }

    func testCountersCoverTheContractedTelemetry() {
        let keys = Set(ContextLane.Stats().counters.keys)
        for k in ["claimed", "published", "unchanged", "failed", "cascaded", "build_ms_total", "build_ms_max",
                  "build_ms_mean", "doc_bytes_total", "doc_bytes_max", "doc_bytes_mean", "inputs_rows_max",
                  "context_tables_missing", "causal_history_after_cutoff"] {
            XCTAssertTrue(keys.contains(k), k)
        }
    }

    // MARK: - Jobs and cutoffs

    func testClaimRowParsesAndTheCutoffFollowsTheMode() throws {
        var row: [String: String] = ["user_id": "u1", "device_id": "d1", "day": "2026-10-03", "mode": "causal_live",
                                     "input_revision": "7", "lease_token": "tok", "timezone_id": "Europe/Berlin",
                                     "cutoff_override": "", "claimed_at": "1791000000"]
        var j = try XCTUnwrap(ContextInputs.parseJob(row))
        XCTAssertEqual(j.mode, .causalLive)
        XCTAssertEqual(j.timezoneId, "Europe/Berlin")
        XCTAssertEqual(j.cutoff, 1_791_000_000, "causal_live decides at the claim time")
        XCTAssertEqual(j.generatedAt, 1_791_000_000)

        row["cutoff_override"] = "1790990000"
        j = try XCTUnwrap(ContextInputs.parseJob(row))
        XCTAssertEqual(j.cutoff, 1_790_990_000, "a replay decides at its override")
        XCTAssertEqual(j.generatedAt, 1_791_000_000, "generatedAt stays the claim time")

        row["mode"] = "retrospective"
        j = try XCTUnwrap(ContextInputs.parseJob(row))
        XCTAssertEqual(j.cutoff, 1_791_000_000, "retrospective uses the claim time")

        row["timezone_id"] = "Not/AZone"
        XCTAssertEqual(ContextInputs.parseJob(row)?.timezoneId, "UTC")
        for (key, bad) in [("mode", "live"), ("day", "2026-10-3"), ("input_revision", "0"), ("lease_token", ""),
                           ("claimed_at", "")] {
            var r = row
            r[key] = bad
            XCTAssertNil(ContextInputs.parseJob(r), "\(key)=\(bad)")
        }
    }

    func testWindowsCoverTheContractedReadSpans() throws {
        let w = try windows()
        XCTAssertEqual(w.dayWindow, PC.Interval(dayStart, dayEnd))
        XCTAssertEqual(w.read, PC.Interval(dayStart - 30 * 3_600, dayEnd + 6 * 3_600))
        XCTAssertEqual(w.exposure, PC.Interval(dayStart - 4 * 86_400, dayEnd + 86_400))
        XCTAssertEqual(w.historyFrom, "2026-04-26", "D-160: the change detector's full burn-in (R-F2)")
        XCTAssertEqual(w.boutsFrom, "2026-09-30")
        XCTAssertEqual(w.priorSleepFrom, "2026-09-19")
        XCTAssertEqual(w.previousDay, "2026-10-02")
        XCTAssertEqual(w.utcFrom, "2026-10-01")
        XCTAssertEqual(w.utcTo, "2026-10-04")
        XCTAssertNil(ContextInputs.windows(day: "2026-13-40", timezoneId: "UTC"))
    }

    func testDSTDaysKeepTheirTrueLength() throws {
        let fallBack = try windows("2026-11-01", "America/Los_Angeles")
        XCTAssertEqual(fallBack.dayWindow.duration, 25 * 3_600)
        let springForward = try windows("2026-03-08", "America/Los_Angeles")
        XCTAssertEqual(springForward.dayWindow.duration, 23 * 3_600)
        XCTAssertEqual(springForward.read.duration, 23 * 3_600 + 36 * 3_600)
    }

    // MARK: - Series supports (contracts §7.2)

    func testSeriesPointsCarryTheirActualSupport() throws {
        let day = PC.Interval(dayStart, dayEnd)
        let b = dayStart + 10 * 3_600
        let hrv = try XCTUnwrap(ContextInputs.seriesSupport(.hrv, bucket: b, dayWindow: day))
        XCTAssertEqual(hrv.support, PC.Interval(b, b + 300))
        XCTAssertNil(hrv.display)
        let rest = try XCTUnwrap(ContextInputs.seriesSupport(.restingHR, bucket: b, dayWindow: day))
        XCTAssertEqual(rest.support, PC.Interval(b - 3_300, b + 300), "trailing 12 five-minute bins")
        XCTAssertEqual(rest.display, PC.Interval(b, b + 300))
        let resp = try XCTUnwrap(ContextInputs.seriesSupport(.respRate, bucket: b, dayWindow: day))
        XCTAssertEqual(resp.support, PC.Interval(b - 60, b + 60), "trailing two one-minute buckets")
        XCTAssertEqual(resp.display, PC.Interval(b, b + 60))
        XCTAssertNil(ContextInputs.seriesSupport(.steps, bucket: b, dayWindow: day))
        XCTAssertNil(ContextInputs.seriesSupport(.calories, bucket: b, dayWindow: day))
    }

    func testSupportsAreClippedToTheDayLikeTheBuilderClipsItsInputs() throws {
        let day = PC.Interval(dayStart, dayEnd)
        let early = try XCTUnwrap(ContextInputs.seriesSupport(.restingHR, bucket: dayStart + 600, dayWindow: day))
        XCTAssertEqual(early.support, PC.Interval(dayStart, dayStart + 900))
        let first = try XCTUnwrap(ContextInputs.seriesSupport(.respRate, bucket: dayStart, dayWindow: day))
        XCTAssertEqual(first.support, PC.Interval(dayStart, dayStart + 60))
        // A day that is not a multiple of five minutes ends with a short bucket.
        let odd = PC.Interval(dayStart, dayStart + 86_400 - 120)
        let last = try XCTUnwrap(ContextInputs.seriesSupport(.hrv, bucket: odd.end - 180, dayWindow: odd))
        XCTAssertEqual(last.support, PC.Interval(odd.end - 180, odd.end))
        XCTAssertNil(ContextInputs.seriesSupport(.hrv, bucket: dayStart - 300, dayWindow: day))
    }

    func testSeriesMethodsMatchTheContract() {
        XCTAssertEqual(ContextInputs.hrvSeriesMethod.id, "series.hrv_rmssd.5min")
        XCTAssertEqual(ContextInputs.hrvSeriesMethod.windowS, 300)
        XCTAssertEqual(ContextInputs.restingSeriesMethod.id, "series.resting_hr.60min_min5")
        XCTAssertEqual(ContextInputs.restingSeriesMethod.aggregation, .minimumOfBins)
        XCTAssertEqual(ContextInputs.restingSeriesMethod.windowS, 3_600)
        XCTAssertEqual(ContextInputs.respSeriesMethod.id, "series.resp_rate.2min")
        XCTAssertEqual(ContextInputs.respSeriesMethod.windowS, 120)
        for m in [ContextInputs.hrvSeriesMethod, ContextInputs.restingSeriesMethod, ContextInputs.respSeriesMethod] {
            XCTAssertEqual(m.algorithmVersion, IntradaySeries.algorithmVersion)
        }
    }

    func testSeriesPointsBecomeMeasurementsWithSourceAndAvailability() throws {
        let day = PC.Interval(dayStart, dayEnd)
        let b = dayStart + 3_600
        let points: [IntradaySeries.Metric: [IntradaySeries.Point]] = [
            .hrv: [.init(ts: b, value: 41.2, samples: 120, coverage: 0.4, motion: 0)],
            .restingHR: [.init(ts: b, value: 55, samples: 290, coverage: 0.75, motion: 0)],
            .respRate: [.init(ts: b + 60, value: 14.2, samples: 20, coverage: 0.6, motion: nil)],
            .steps: [.init(ts: b, value: 10, samples: 30, coverage: 1, motion: 0)],
        ]
        var index = ContextInputs.AvailabilityIndex()
        index.add(ts: b + 10, at: b + 200)
        index.add(ts: b - 3_000, at: b - 2_000)
        index.add(ts: b + 400, at: b + 999_999)  // outside every support below except none
        let snap = ContextInputs.Snapshot(day: "2026-10-03", resultRevision: 88, inputRevision: 12, availableAt: 0,
                                          status: nil, sessions: [], values: [:], restingHRInt: nil)
        let ms = ContextInputs.measurements(fromSeries: points, dayWindow: day, snapshot: snap, availability: index)
        XCTAssertEqual(ms.count, 3, "steps are not contextualized")
        let hrv = try XCTUnwrap(ms.first { $0.metric == .hrvRmssd })
        XCTAssertEqual(hrv.source, PC.SourceRef(product: .metricSeries, key: "hrv_rmssd_ms@\(b)", inputRevision: 12,
                                                resultRevision: 88))
        XCTAssertEqual(hrv.value, 41.2)
        XCTAssertEqual(hrv.sampleCount, 120)
        XCTAssertEqual(hrv.availableAt, b + 200)
        let rest = try XCTUnwrap(ms.first { $0.metric == .restingHeartRate })
        XCTAssertEqual(rest.support, PC.Interval(b - 3_300, b + 300))
        XCTAssertEqual(rest.availableAt, b + 200, "the latest row inside the whole trailing support")
        let resp = try XCTUnwrap(ms.first { $0.metric == .respiratoryRate })
        XCTAssertEqual(resp.support, PC.Interval(b, b + 120))
        XCTAssertEqual(resp.displayBucket, PC.Interval(b + 60, b + 120))
    }

    // MARK: - Snapshot

    func testSnapshotParsingAndNightlyMeasurements() throws {
        let night = (start: dayStart - 3_600, end: dayStart + 7 * 3_600)
        let nap = (start: dayStart + 14 * 3_600, end: dayStart + 14 * 3_600 + 1_800)
        let payload = ContextDaySim.snapshotPayload(sessions: [nap, night])
        let s = try XCTUnwrap(ContextInputs.parseSnapshot(day: "2026-10-03", payloadText: payload, resultRevision: 41,
                                                          inputRevision: 9, availableAt: dayStart + 8 * 3_600))
        XCTAssertEqual(s.sessions.map(\.start), [night.start, nap.start], "sorted by time")
        XCTAssertEqual(s.sessions.first?.stages.count, 2)
        XCTAssertEqual(s.restingHRInt, 53)
        let ms = ContextInputs.snapshotMeasurements(s, offsetSec: 0)
        XCTAssertEqual(Set(ms.map(\.method.id)), [
            "snapshot.hrv_rmssd.night", "snapshot.hrv_sdnn.night", "snapshot.resting_hr.night",
            "snapshot.resp_rate.night", "snapshot.skin_temp.night", "snapshot.spo2_candidate.night"])
        let rest = try XCTUnwrap(ms.first { $0.metric == .restingHeartRate })
        XCTAssertEqual(rest.support, PC.Interval(night.start, night.end), "the scorer's primary session")
        XCTAssertEqual(rest.sessionId, "sleep-dev-\(night.start)")
        XCTAssertEqual(rest.method.windowS, night.end - night.start)
        XCTAssertEqual(rest.method.aggregation, .session)
        XCTAssertEqual(rest.source, PC.SourceRef(product: .scoringSnapshot, key: "daily.resting_hr_bpm",
                                                 inputRevision: 9, resultRevision: 41))
        XCTAssertEqual(rest.availableAt, dayStart + 8 * 3_600)
        let hrv = try XCTUnwrap(ms.first { $0.metric == .hrvRmssd })
        XCTAssertEqual(hrv.support, PC.Interval(night.start, night.end),
                       "pooled metrics: the main-sleep group, never a hull spanning the awake hours before the nap")
        XCTAssertEqual(hrv.sessionId, "sleep-dev-\(night.start)")
        XCTAssertEqual(hrv.source.key, "daily.hrv_rmssd_ms#aggregate_pools_sessions_outside_support=1",
                       "the canonical aggregate also pooled the nap: recorded on the source")
        XCTAssertEqual(ms.first { $0.metric == .spo2Candidate }?.sampleCount, 240)
        XCTAssertNil(ms.first { $0.method.id.contains("dev") }, "a deviation is not a measurement")

        let sleep = ContextInputs.sleepInputs(s)
        XCTAssertEqual(sleep.first?.sourceDay, "2026-10-03")
        XCTAssertEqual(sleep.first?.availableAt, dayStart + 8 * 3_600)
        XCTAssertEqual(sleep.first?.detector, "frwhoop-server-1")
        XCTAssertEqual(sleep.first?.stages.first?.stage, "light")
    }

    func testSnapshotWithoutSessionsOrValuesYieldsNoMeasurement() throws {
        let empty = try XCTUnwrap(ContextInputs.parseSnapshot(day: "d", payloadText: "{\"sleep\":[],\"daily\":{}}",
                                                              resultRevision: 1, inputRevision: 1, availableAt: 0))
        XCTAssertTrue(ContextInputs.snapshotMeasurements(empty, offsetSec: 0).isEmpty)
        XCTAssertNil(ContextInputs.parseSnapshot(day: "d", payloadText: "[1]", resultRevision: 1, inputRevision: 1,
                                                 availableAt: 0))
        // A missing value stays missing (never zero); a NaN-free payload is required by JSON anyway.
        let partial = ContextDaySim.snapshotPayload(sessions: [(dayStart - 3_600, dayStart + 3_600)],
                                                    daily: ["resting_hr_bpm": 50])
        let s = try XCTUnwrap(ContextInputs.parseSnapshot(day: "d", payloadText: partial, resultRevision: 1,
                                                          inputRevision: 1, availableAt: 0))
        XCTAssertEqual(ContextInputs.snapshotMeasurements(s, offsetSec: 0).map(\.metric), [.restingHeartRate])
    }

    // MARK: - Row parsers

    func testRowParsersRejectWhatTheContractCannotHold() {
        XCTAssertNil(ContextInputs.parsePlacement(["s": "100", "e": "100", "placement": "wrist", "revision": "1"]))
        let open = ContextInputs.parsePlacement(["s": "100", "e": "", "placement": "bicep", "source": "user",
                                                 "revision": "2", "at": "50"])
        XCTAssertEqual(open, PC.PlacementInput(start: 100, end: nil, placement: "bicep", source: "user", revision: 2,
                                               recordedAt: 50, scope: "device"))
        XCTAssertNil(ContextInputs.parseRun(["s": "10", "e": "5", "revision": "1"]))
        XCTAssertEqual(ContextInputs.parseRun(["s": "10", "e": "20", "class": "walking", "confidence": "1.7",
                                               "revision": "4", "at": "30"])?.confidence, 1)
        XCTAssertNil(ContextInputs.parseExposure(["event_id": "e", "revision": "1", "kind": "teleport", "s": "1",
                                                  "e": "2", "time_precision": "exact", "recorded_at": "1",
                                                  "source": "user_entered", "confirmation": "confirmed"]))
        let ok = ContextInputs.parseExposure(["event_id": "e", "revision": "2", "kind": "caffeine", "label": "coffee",
                                              "s": "100", "e": "101", "time_precision": "exact",
                                              "recorded_at": "150", "received_at": "160", "source": "user_entered",
                                              "confirmation": "confirmed", "dose_amount": "95", "dose_unit": "mg"])
        XCTAssertEqual(ok?.availableAt, 160)
        XCTAssertEqual(ok?.doseAmount, 95)
        let epoch = ContextInputs.parseEpoch(["s": "0", "e": "30", "motion_label": "walking", "posture": "standing",
                                              "exercise_session": "unknown", "sleep_state": "awake",
                                              "exertion_context": "active", "wear_state": "on_wrist",
                                              "confidence": "0.8", "observed_s": "30", "valid_s": "28",
                                              "revision": "5", "at": "100"])
        XCTAssertEqual(epoch?.epoch.motion, .walking)
        XCTAssertEqual(epoch?.revision, 5)
        XCTAssertEqual(epoch?.availableAt, 100)
    }

    // MARK: - R-R transport selection

    func testTransportSelectionKeepsOneChannelPerHourWithItsAvailability() {
        var beats: [PC.BeatIntervalObservation] = []
        for i in 0..<200 {
            beats.append(.init(ts: dayStart + i, rrMs: 1_000, seq: 0, channel: 5, availableAt: dayStart + i + 600))
            if i % 2 == 0 {
                beats.append(.init(ts: dayStart + i, rrMs: 1_000, seq: 0, channel: 7, availableAt: dayStart + i + 1))
            }
        }
        let kept = ContextInputs.selectTransports(beats)
        XCTAssertEqual(kept.count, 200)
        XCTAssertTrue(kept.allSatisfy { $0.channel == 5 })
        XCTAssertEqual(kept.first?.availableAt, dayStart + 600)
        // Single-transport input passes through untouched.
        let single = beats.filter { $0.channel == 5 }
        XCTAssertEqual(ContextInputs.selectTransports(single), single)
    }

    // MARK: - Causal cutoff (V10) and assembly

    private func fullDayLoaded(snapshot: Bool = true) -> ContextInputs.Loaded {
        var l = ContextDaySim.representativeDay(dayStart: dayStart).loaded()
        if snapshot {
            let payload = ContextDaySim.snapshotPayload(sessions: [(dayStart - 3_600, dayStart + 7 * 3_600)])
            l.snapshot = ContextInputs.parseSnapshot(day: "2026-10-03", payloadText: payload, resultRevision: 41,
                                                     inputRevision: 9, availableAt: dayStart + 7 * 3_600 + 300)
        }
        l.device = .init(family: "WHOOP 5.0 / MG", firmware: "50.36", sourceKind: "noop_push")
        return l
    }

    func testCausalAssemblyOnlySeesWhatWasAvailableAtTheClaim() throws {
        let cutoff = dayStart + 12 * 3_600
        let live = job(mode: .causalLive, claimedAt: cutoff)
        let a = ContextInputs.assemble(fullDayLoaded(), job: live, windows: try windows())
        XCTAssertEqual(a.input.mode, .causalLive)
        XCTAssertEqual(a.input.availabilityCutoff, cutoff)
        XCTAssertEqual(a.input.generatedAt, cutoff)
        XCTAssertTrue(a.input.heartRate.allSatisfy { $0.ts < cutoff && ($0.availableAt ?? 0) <= cutoff })
        XCTAssertTrue(a.input.beatIntervals.allSatisfy { $0.ts < cutoff && ($0.availableAt ?? 0) <= cutoff })
        XCTAssertTrue(a.input.measurements.allSatisfy { ($0.availableAt ?? 0) <= cutoff },
                      "series points are computed from visible rows only")
        // Rows are stored 120 s after their sensor time: the last two minutes before the cutoff are not visible.
        XCTAssertEqual(a.input.heartRate.last?.ts, cutoff - 120)
        let excluded = Dictionary(uniqueKeysWithValues: a.causalExcluded.map { ($0.name, $0.value) })
        XCTAssertGreaterThan(excluded["causal_excluded_observations"] ?? 0, 0)

        let retro = ContextInputs.assemble(fullDayLoaded(), job: job(mode: .retrospective, claimedAt: cutoff),
                                           windows: try windows())
        XCTAssertEqual(retro.input.heartRate.count, 86_400, "retrospective keeps every stored row")
        XCTAssertTrue(retro.causalExcluded.isEmpty)
        XCTAssertGreaterThan(retro.input.measurements.count, a.input.measurements.count)
    }

    func testRowsAppendedAfterTheCutoffDoNotChangeAReplay() throws {
        let cutoff = dayStart + 12 * 3_600
        let replay = job(mode: .causalLive, claimedAt: dayStart + 50 * 3_600, override: cutoff)
        let before = fullDayLoaded()
        var after = before
        // Late uploads: earlier sensor times, stored after the cutoff, plus a snapshot republished later.
        after.heartRate += (0..<600).map { PC.HeartRateObservation(ts: dayStart + 11 * 3_600 + $0, bpm: 140,
                                                                    availableAt: cutoff + 10) }
        after.heartRate.sort { $0.ts < $1.ts }
        after.wearEvents.append(.init(ts: dayStart + 3_600, state: .offWrist, kind: "WRIST_OFF", availableAt: cutoff + 1))
        // Records stored after the cutoff: an exposure entered late, a placement declared later, a later HART
        // revision and decoder run. Neither their content nor their count may reach the replayed document (the
        // input revisions included).
        after.exposures.append(PC.ExposureEventRevision(
            eventId: "late", revision: 1, kind: .caffeine, label: "coffee",
            occurred: PC.Interval(dayStart + 7 * 3_600, dayStart + 7 * 3_600 + 1), timePrecision: .exact,
            recordedAt: dayStart + 7 * 3_600, receivedAt: cutoff + 30, source: .userEntered, confirmation: .confirmed))
        after.placements.append(PC.PlacementInput(start: dayStart + 6 * 3_600, end: nil, placement: "bicep",
                                                  source: "user", revision: 9, recordedAt: cutoff + 40,
                                                  scope: "device"))
        after.epochs.append(PC.ActivityEpochInput(
            epoch: ActivityEpoch(startTs: dayStart + 9 * 3_600, endTs: dayStart + 9 * 3_600 + 30, motion: .walking,
                                 posture: .unknown, exercise: .unknown, sleepState: .unknown, exertion: .unknown,
                                 wear: .unknown, confidence: 0.9, observedS: 30, validS: 30),
            revision: 7, availableAt: cutoff + 50))
        after.intervals.append(PC.ActivityIntervalInput(interval: PC.Interval(dayStart + 9 * 3_600, dayStart + 10 * 3_600),
                                                        activityClass: "walking", confidence: 0.8, sleep: nil, wear: nil,
                                                        revision: 4, availableAt: cutoff + 60))
        let w = try windows()
        let ia = ContextInputs.assemble(before, job: replay, windows: w).input
        let ib = ContextInputs.assemble(after, job: replay, windows: w).input
        XCTAssertEqual(ia.inputRevisions, ib.inputRevisions, "revisions count only what was available at the cutoff")
        let a = PC.Engine.buildDay(ia, history: .empty)
        let b = PC.Engine.buildDay(ib, history: .empty)
        XCTAssertEqual(a.header.inputFingerprint, b.header.inputFingerprint)
        XCTAssertEqual(try PC.encoder().encode(a), try PC.encoder().encode(b), "byte-identical at the cutoff")
        XCTAssertEqual(a.header.interpretation.availabilityCutoff, cutoff)
        XCTAssertEqual(a.header.interpretation.generatedAt, dayStart + 50 * 3_600)
    }

    func testPriorSleepPublishedAfterACausalCutoffIsNotRead() throws {
        var l = fullDayLoaded()
        let payload = ContextDaySim.snapshotPayload(sessions: [(dayStart - 54 * 3_600, dayStart - 46 * 3_600)])
        l.otherSnapshots = [
            try XCTUnwrap(ContextInputs.parseSnapshot(day: "2026-10-01", payloadText: payload, resultRevision: 5,
                                                      inputRevision: 0, availableAt: dayStart + 20 * 3_600)),
        ]
        let w = try windows()
        let live = ContextInputs.assemble(l, job: job(mode: .causalLive, claimedAt: dayStart + 12 * 3_600), windows: w)
        XCTAssertTrue(live.history.priorSleep.isEmpty)
        let retro = ContextInputs.assemble(l, job: job(mode: .retrospective, claimedAt: dayStart + 12 * 3_600),
                                           windows: w)
        XCTAssertEqual(retro.history.priorSleep.count, 1)
    }

    func testTheDayCarriesTheNeighbouringNightsAndHistoryTheEarlierOnes() throws {
        var l = fullDayLoaded()
        func snap(_ day: String, _ sessions: [(Int, Int)], at: Int, nap: Bool = false) throws -> ContextInputs.Snapshot {
            var payload = ContextDaySim.snapshotPayload(sessions: sessions)
            if nap { payload = payload.replacingOccurrences(of: "\"is_nap\":false", with: "\"is_nap\":true") }
            return try XCTUnwrap(ContextInputs.parseSnapshot(day: day, payloadText: payload, resultRevision: 5,
                                                             inputRevision: 0, availableAt: at))
        }
        let h = 3_600
        l.otherSnapshots = [
            try snap("2026-10-01", [(dayStart - 49 * h, dayStart - 41 * h)], at: dayStart - 40 * h),
            try snap("2026-10-02", [(dayStart - 25 * h, dayStart - 17 * h)], at: dayStart - 16 * h, nap: true),
            try snap("2026-10-04", [(dayStart + 23 * h, dayStart + 31 * h)], at: dayStart + 32 * h),
        ]
        let w = try windows()
        let retro = ContextInputs.assemble(l, job: job(mode: .retrospective, claimedAt: dayStart + 40 * h), windows: w)
        XCTAssertEqual(retro.input.sleepSessions.map(\.sourceDay), ["2026-10-02", "2026-10-03", "2026-10-04"])
        XCTAssertEqual(retro.input.sleepSessions.first?.isNap, true, "an explicit nap flag is kept")
        XCTAssertNil(retro.input.sleepSessions[1].isNap, "the scorer's constant false is not information")
        XCTAssertEqual(retro.input.sleepSessions.last?.availableAt, dayStart + 32 * h)
        XCTAssertEqual(retro.input.sleepSessions.last?.timezoneId, "UTC")
        XCTAssertEqual(retro.input.sleepSessions.last?.dataThrough, dayStart + 31 * h, "the snapshot's dataThrough")
        XCTAssertEqual(retro.history.priorSleep.map(\.sourceDay), ["2026-10-01"], "history is D-14 … D-2")
        // A live decision at noon cannot see the D+1 night (published later).
        let live = ContextInputs.assemble(l, job: job(mode: .causalLive, claimedAt: dayStart + 12 * h), windows: w)
        XCTAssertEqual(live.input.sleepSessions.map(\.sourceDay), ["2026-10-02", "2026-10-03"])
    }

    func testAssemblyIsIndependentOfRowArrivalOrder() throws {
        let ordered = fullDayLoaded()
        var shuffled = ordered
        var rng = SeededGenerator(seed: 3)
        shuffled.heartRate.shuffle(using: &rng)
        shuffled.beatIntervals.shuffle(using: &rng)
        shuffled.motion.shuffle(using: &rng)
        shuffled.steps.shuffle(using: &rng)
        let w = try windows()
        let j = job()
        let a = ContextInputs.assemble(ordered, job: j, windows: w)
        let b = ContextInputs.assemble(shuffled, job: j, windows: w)
        XCTAssertEqual(a.input, b.input)
        let da = try ContextLane.publishPayload(document: PC.Engine.buildDay(a.input, history: a.history),
                                                snapshot: ordered.snapshot)
        let db = try ContextLane.publishPayload(document: PC.Engine.buildDay(b.input, history: b.history),
                                                snapshot: shuffled.snapshot)
        XCTAssertEqual(da.payloadText, db.payloadText, "byte-identical publish payloads")
    }

    func testAssembledInputCarriesIdentityRegimeAndRevisions() throws {
        let a = ContextInputs.assemble(fullDayLoaded(), job: job(), windows: try windows())
        XCTAssertEqual(a.input.identity, PC.DayIdentity(deviceScope: "d", day: "2026-10-03", timezoneId: "UTC",
                                                         dayWindow: PC.Interval(dayStart, dayEnd)))
        XCTAssertEqual(a.input.regime.vendor, "whoop")
        XCTAssertNil(a.input.regime.deviceFamily, "a mutable devices column is never stamped on a day (RC-13)")
        XCTAssertNil(a.input.regime.firmware, "no firmware history: unknown for every day (RC-13)")
        XCTAssertEqual(a.input.regime.sourceKind, "noop_push")
        XCTAssertEqual(a.input.regime.scoringAlgorithmVersion, "frwhoop-server-1")
        XCTAssertEqual(a.input.regime.seriesAlgorithmVersion, IntradaySeries.algorithmVersion)
        XCTAssertEqual(a.input.sleepSessions.count, 1)
        let revisions = Dictionary(uniqueKeysWithValues: a.input.inputRevisions.map { ($0.input, $0.revision) })
        XCTAssertEqual(revisions["scoring_snapshot"], "41")
        XCTAssertEqual(revisions["scoring_input"], "9")
        XCTAssertEqual(a.input.inputRevisions, a.input.inputRevisions.sorted { ($0.input, $0.revision) < ($1.input, $1.revision) })
        let methods = Set(a.input.measurements.map(\.method.id))
        XCTAssertTrue(methods.isSuperset(of: ["series.hrv_rmssd.5min", "series.resting_hr.60min_min5",
                                              "series.resp_rate.2min", "snapshot.hrv_rmssd.night"]), "\(methods)")
        XCTAssertEqual(a.input.measurements, a.input.measurements.sorted { ($0.support, $0.method.id) < ($1.support, $1.method.id) })
    }

    // MARK: - Publish payload

    func testPublishPayloadHasTheContractedShapeAndEmbedsTheDocumentVerbatim() throws {
        let l = fullDayLoaded()
        let a = ContextInputs.assemble(l, job: job(), windows: try windows())
        let doc = PC.Engine.buildDay(a.input, history: a.history)
        let built = try ContextLane.publishPayload(document: doc, snapshot: l.snapshot)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(built.payloadText.utf8)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["header", "document", "envelope_tables", "scoring_result_revision",
                                       "scoring_input_revision", "daily_values", "bouts", "episodes",
                                       "new_frozen_references"])
        XCTAssertEqual(obj["scoring_result_revision"] as? Int, 41)
        XCTAssertEqual(obj["scoring_input_revision"] as? Int, 9)
        let header = try XCTUnwrap(obj["header"] as? [String: Any])
        XCTAssertEqual(Set(header.keys), ["mode", "day", "finality", "status", "availability_cutoff", "generated_at",
                                          "contract_version", "schema_version", "policy_fingerprint",
                                          "input_fingerprint", "versions"])
        XCTAssertEqual(header["mode"] as? String, "retrospective")
        XCTAssertEqual(header["day"] as? String, "2026-10-03")
        XCTAssertEqual(header["availability_cutoff"] as? Int, dayStart + 40 * 3_600)
        XCTAssertEqual(header["generated_at"] as? Int, dayStart + 40 * 3_600)
        XCTAssertEqual(header["policy_fingerprint"] as? String, PC.Policy.default.fingerprint)
        XCTAssertEqual(header["contract_version"] as? String, PC.contractVersion)
        XCTAssertEqual((header["versions"] as? [String: Any])?["feature_registry"] as? String,
                       PC.FeatureRegistry.version)
        // Stored form (contracts §6.1): `document` is the summary, embedded as the encoder wrote it; the envelopes
        // travel as one interned table per metric, and joining them back gives the document itself.
        let (summary, tables) = PC.StoredDocument.split(doc)
        let summaryBytes = try PC.encoder().encode(summary)
        XCTAssertEqual(built.summaryBytes, summaryBytes.count)
        XCTAssertTrue(built.payloadText.contains("\"document\":" + String(decoding: summaryBytes, as: UTF8.self) + ","))
        let storedSummary = try PC.decoder().decode(PC.DayDocument.self,
                                                    from: JSONSerialization.data(withJSONObject: obj["document"]!))
        XCTAssertTrue(storedSummary.envelopes.isEmpty)
        XCTAssertEqual(storedSummary.envelopeIndex?.map(\.metric), tables.map(\.metric))
        let entries = try XCTUnwrap(obj["envelope_tables"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["metric"] as? String }, tables.map { $0.metric.rawValue })
        XCTAssertEqual(entries.map { $0["envelope_count"] as? Int }, tables.map { $0.rows.count })
        XCTAssertEqual(entries.compactMap { $0["envelope_count"] as? Int }.reduce(0, +), doc.envelopes.count)
        let decodedTables = try entries.map {
            try PC.decoder().decode(PC.EnvelopeTable.self, from: JSONSerialization.data(withJSONObject: $0["table"]!))
        }
        XCTAssertEqual(PC.StoredDocument.join(summary: storedSummary, tables: decodedTables), doc,
                       "summary + tables rebuild the document")
        XCTAssertEqual(built.tableBytes, try tables.map { try PC.encoder().encode($0).count }.reduce(0, +))
        XCTAssertEqual(built.documentBytes, built.summaryBytes + built.tableBytes)
        // The job duration is sent when known.
        let timed = try ContextLane.publishPayload(document: doc, snapshot: l.snapshot, durationMS: 1_234)
        let timedObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(timed.payloadText.utf8)) as? [String: Any])
        XCTAssertEqual(timedObj["duration_ms"] as? Int, 1_234)
    }

    func testOnlyTheJobDaysProductsBecomeNormalizedRows() throws {
        let l = fullDayLoaded()
        let a = ContextInputs.assemble(l, job: job(), windows: try windows())
        var doc = PC.Engine.buildDay(a.input, history: a.history)
        doc.bouts = [
            PC.ExertionBout(id: "today", interval: PC.Interval(dayStart + 30_000, dayStart + 30_900), day: "2026-10-03",
                            kind: "walking", status: .complete, durationS: 900),
            PC.ExertionBout(id: "yesterday", interval: PC.Interval(dayStart - 600, dayStart + 300), day: "2026-10-02",
                            kind: "walking", status: .complete, durationS: 900),
        ]
        doc.dailyValues.append(PC.DailyValue(day: "2026-10-03", seriesKey: "x.live", regimeKey: "r", metric: nil,
                                             value: 1, units: "s", supportCount: 1, supportUnit: "day", supportS: 1,
                                             mode: .causalLive, finality: .provisional))
        let built = try ContextLane.publishPayload(document: doc, snapshot: l.snapshot)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(built.payloadText.utf8)) as? [String: Any])
        XCTAssertEqual((obj["bouts"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["today"])
        XCTAssertFalse(((obj["daily_values"] as? [[String: Any]]) ?? []).contains { $0["series_key"] as? String == "x.live" })
        XCTAssertEqual(built.outOfDay, 2)
        XCTAssertEqual(((obj["document"] as? [String: Any])?["bouts"] as? [Any])?.count, 2, "the document is unchanged")
    }

    func testPayloadWithoutASnapshotSendsNullRevisions() throws {
        let l = fullDayLoaded(snapshot: false)
        let a = ContextInputs.assemble(l, job: job(), windows: try windows())
        let built = try ContextLane.publishPayload(document: PC.Engine.buildDay(a.input, history: a.history),
                                                   snapshot: nil)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(built.payloadText.utf8)) as? [String: Any])
        XCTAssertTrue(obj["scoring_result_revision"] is NSNull)
        XCTAssertTrue(obj["scoring_input_revision"] is NSNull)
    }

    func testPublishResultParsing() {
        let published = ContextLane.parsePublishResult(
            #"{"applied":true,"context_revision":12,"reason":"published","cascaded_days":3}"#)
        XCTAssertEqual(published, .init(applied: true, revision: 12, reason: "published", cascadedDays: 3,
                                        unchanged: false))
        // The RPC reports identical fingerprints as applied=false + reason=unchanged + the existing revision, and
        // completes the job: that is success.
        let same = ContextLane.parsePublishResult(
            #"{"applied":false,"context_revision":12,"reason":"unchanged","cascaded_days":0}"#)
        XCTAssertTrue(same.unchanged)
        XCTAssertTrue(same.applied)
        XCTAssertEqual(same.revision, 12)
        XCTAssertFalse(ContextLane.parsePublishResult(#"{"applied":false,"context_revision":null,"reason":"unchanged"}"#).applied)
        for reason in ["lease_lost", "lease_expired", "stale_revision", "owner_retired"] {
            let r = ContextLane.parsePublishResult(#"{"applied":false,"context_revision":null,"reason":"\#(reason)"}"#)
            XCTAssertFalse(r.applied, reason)
            XCTAssertFalse(r.unchanged, reason)
        }
        XCTAssertEqual(ContextLane.failStatus(#"{"status":"released","consecutive_failures":0}"#), "released")
        XCTAssertEqual(ContextLane.failStatus(nil), "unknown")
        XCTAssertEqual(ContextLane.parsePublishResult(#"{"applied":true,"context_revision":"9","cascaded_days":["a","b"]}"#).cascadedDays, 2)
        let fenced = ContextLane.parsePublishResult(#"{"applied":false,"reason":"stale_lease"}"#)
        XCTAssertFalse(fenced.applied)
        XCTAssertEqual(fenced.reason, "stale_lease")
        XCTAssertFalse(ContextLane.parsePublishResult(nil).applied, "NULL is never success")
        XCTAssertFalse(ContextLane.parsePublishResult("not json").applied)
    }

    // MARK: - Errors

    func testFailureReasonsAreOneBoundedLineWithoutRowData() {
        let e = PostgresClient.Error(
            message: "query failed: status=7 ERROR:  duplicate key 0f1e2d3c-4b5a-6978-8091-a2b3c4d5e6f7\nDETAIL:  Key (user_id)=(secret) already exists.",
            sqlstate: "23505", kind: .deterministic)
        let r = ContextLane.sanitize(e)
        XCTAssertTrue(r.hasPrefix("context_deterministic: "), r)
        XCTAssertFalse(r.contains("DETAIL"))
        XCTAssertFalse(r.contains("secret"))
        XCTAssertTrue(r.contains("<uuid>"))
        XCTAssertFalse(r.contains("\n"))
        XCTAssertLessThanOrEqual(ContextLane.sanitize(reason: String(repeating: "x", count: 5_000)).count, 300)
        XCTAssertEqual(ContextLane.releaseReason(claimedRevision: 4, reason: "stale\nlease"),
                       "context_publish_not_applied:claimed_revision=4:stale")
        XCTAssertTrue(ContextLane.isMissingObject(PostgresClient.Error(message: "x", sqlstate: "42883", kind: .other)))
        XCTAssertFalse(ContextLane.isMissingObject(PostgresClient.Error(message: "x", sqlstate: "23505", kind: .other)))
    }

    func testADocumentOverThePublishCapIsRefusedBeforeItIsSent() {
        XCTAssertNoThrow(try ContextLane.checkDocumentSize(bytes: 16_777_216, envelopes: 10))
        XCTAssertThrowsError(try ContextLane.checkDocumentSize(bytes: 16_777_217, envelopes: 10)) { error in
            XCTAssertTrue(ContextLane.sanitize(error).hasPrefix("context_deterministic: "), "\(error)")
            XCTAssertTrue(ContextLane.sanitize(error).contains("document_too_large"))
        }
    }

    // MARK: - Isolation: the lane's SQL never writes anything scoring or ingest owns

    func testTheLaneSQLOnlyWritesThroughItsOwnRPCs() {
        let statements = [ContextSQL.tablesPresent, ContextSQL.enqueue, ContextSQL.claim, ContextSQL.renew,
                          ContextSQL.fail, ContextSQL.publish, ContextSQL.heartRate, ContextSQL.beatIntervals,
                          ContextSQL.gravity, ContextSQL.steps, ContextSQL.skinTemperature, ContextSQL.wearEvents,
                          ContextSQL.bandSleepState, ContextSQL.latestSnapshot, ContextSQL.snapshotSleepRange,
                          ContextSQL.workouts, ContextSQL.activityEpochs, ContextSQL.activityRuns,
                          ContextSQL.placements, ContextSQL.device, ContextSQL.profile, ContextSQL.exposureRevisions,
                          ContextSQL.historyDailyValues, ContextSQL.historyBouts, ContextSQL.frozenReferences,
                          ContextSQL.historyAfterCutoff]
        for sql in statements {
            let lower = sql.lowercased()
            for forbidden in ["insert ", "update ", "delete ", "scoring_dirty_span", "enqueue_scoring_v2",
                              "publish_scoring", "publish_metric_series", "truncate "] {
                XCTAssertFalse(lower.contains(forbidden), "\(forbidden) in \(sql)")
            }
        }
        for sql in [ContextSQL.heartRate, ContextSQL.beatIntervals, ContextSQL.gravity, ContextSQL.steps,
                    ContextSQL.skinTemperature, ContextSQL.wearEvents, ContextSQL.bandSleepState,
                    ContextSQL.activityEpochs, ContextSQL.workouts] {
            XCTAssertTrue(sql.contains("user_id = $1::uuid and device_id = $2::uuid"), "owner+device scope: \(sql)")
            XCTAssertTrue(sql.lowercased().contains("order by"), "deterministic order: \(sql)")
        }
    }
}

/// A tiny deterministic generator for shuffles.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
