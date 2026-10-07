import XCTest
import StrandAnalytics
@testable import Strand

/// App-side activity context tests (contract C10 / spec §11): the hosted snapshot parse, the cache
/// round trip, the pure wording / ribbon / selection / detail-sheet data, and the feature-off
/// behavior. The SwiftUI shells (ActivityTimelineView / ActivityContextLine / ActivityContextDetailSheet)
/// are thin renderers over these pure pieces; what is pinned here is every decision they draw.
final class ActivityContextUITests: XCTestCase {

    /// Exact multiple of the 30-s epoch grid (1790748000 / 30 == 59691600).
    private let base = 1_790_748_000

    // MARK: - Helpers

    private func epoch(_ start: Int, motion: MotionLabel, confidence: Double = 0.9,
                       observed: Int = 30, valid: Int = 30) -> ActivityEpoch {
        ActivityEpoch(startTs: start, endTs: start + 30, motion: motion, posture: .unknown,
                      exercise: .unknown, sleepState: .unknown, exertion: .unknown, wear: .unknown,
                      confidence: confidence, observedS: observed, validS: valid)
    }

    private func unknownEpoch(_ start: Int, observed: Int = 30) -> ActivityEpoch {
        // Invariant from ActivityContextTypes: an abstained epoch keeps its observed seconds and
        // validS == 0, so its unknownFraction is 1.
        ActivityEpoch(startTs: start, endTs: start + 30, motion: .unknown, posture: .unknown,
                      exercise: .unknown, sleepState: .unknown, exertion: .unknown, wear: .unknown,
                      confidence: 0, observedS: observed, validS: 0)
    }

    private func document(epochs: [ActivityEpoch], status: ActivityStatus = .available,
                          hrvSlots: [HrvSlotContext] = [],
                          sleepSessions: [SleepSessionContext] = []) -> ActivityContextDocument {
        ActivityContextDocument(schemaVersion: 1, ontologyVersion: "v1",
                                modelVersion: "hart-activity-1", preprocessingVersion: "hart-pre-1",
                                inputRevision: 3, dataThrough: "2026-09-30T13:30:00Z",
                                status: status, reasons: [],
                                epochs: epochs,
                                summary: ActivitySnapshotSummary(supportedS: 60, unknownShare: 0,
                                                                transitions: 0),
                                contexts: ActivityContexts(hrvSlots: hrvSlots,
                                                           sleepSessions: sleepSessions))
    }

    private func summary(shares: [MotionLabel: Double], unknownShare: Double = 0,
                         transitions: Int = 0, recentActivity: Int? = nil,
                         postureSource: String = "none",
                         qualityReasons: [String] = []) -> ActivityContextSummary {
        ActivityContextSummary(shares: shares, unknownShare: unknownShare, transitions: transitions,
                               recentActivity: recentActivity, postureSource: postureSource,
                               qualityReasons: qualityReasons)
    }

    private func hostedEnvelope(daily: [String: Any], revision: Any = "42") -> [String: Any] {
        ["server_scoring": ["hosted_snapshot": [
            "algorithm_version": "frwhoop-server-1", "result_revision": revision, "input_revision": "7",
            "computed_at": "2026-09-30T14:00:00.123456+00:00", "pending": true, "status": "partial",
            "status_reasons": ["gravity_empty"], "daily": daily,
            "sleep": [
                ["id": "s1", "start_at": "2026-09-30T06:00:00Z", "end_at": "2026-09-30T13:30:00Z",
                 "is_nap": false, "efficiency": 0.91, "resting_hr_bpm": 52, "hrv_rmssd_ms": 61.2,
                 "stages": [["start": 1_790_748_000, "end": 1_790_775_000, "stage": "light"]]],
            ],
        ] as [String: Any]]]
    }

    /// The exact C10 `daily.activity_context` shape (epochs + summary + contexts, compact keys).
    private var c10Daily: [String: Any] {
        ["sleep_total_min": 431.5, "hrv_rmssd_ms": 61.2,
         "activity_context": [
            "schema_version": 1, "ontology_version": "v1",
            "model_version": "hart-activity-1", "preprocessing_version": "hart-pre-1",
            "input_revision": 3, "data_through": "2026-09-30T13:30:00Z",
            "status": "available", "reasons": [] as [String],
            "epochs": [
                ["s": base, "e": base + 30, "m": "walking", "p": "unknown", "ex": "unknown",
                 "sl": "unknown", "ec": "active", "w": "unknown", "c": 0.91, "os": 30, "vs": 30],
                ["s": base + 30, "e": base + 60, "m": "stationary", "p": "unknown", "ex": "unknown",
                 "sl": "unknown", "ec": "resting_candidate", "w": "unknown", "c": 0.87, "os": 30, "vs": 30],
            ] as [Any],
            "summary": ["supported_s": 60, "unknown_share": 0.0, "transitions": 1],
            "contexts": [
                "hrv_slots": [
                    ["slot_s": base, "shares": ["walking": 0.5, "stationary": 0.5],
                     "unknown_share": 0.0, "recent_activity_s": NSNull(), "post_activity": false],
                ] as [Any],
                "sleep_sessions": [
                    ["start": base, "end": base + 600, "shares": ["stationary": 0.9],
                     "unknown_share": 0.1],
                ] as [Any],
            ],
        ] as [String: Any]]
    }

    // MARK: - Hosted snapshot parse (C10)

    func testHostedResultParsesTheExactC10ActivityContextDocument() throws {
        let snapshot = ServerScoreRepository.snapshot(day: "2026-09-30", deviceId: "my-whoop",
                                                      envelope: hostedEnvelope(daily: c10Daily),
                                                      fetchedAtMs: 0)
        let result = try XCTUnwrap(snapshot.hostedResult)
        let document = try XCTUnwrap(result.activityContext)

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.ontologyVersion, "v1")
        XCTAssertEqual(document.modelVersion, "hart-activity-1")
        XCTAssertEqual(document.preprocessingVersion, "hart-pre-1")
        XCTAssertEqual(document.inputRevision, 3)
        XCTAssertEqual(document.dataThrough, "2026-09-30T13:30:00Z")
        XCTAssertEqual(document.status, .available)
        XCTAssertTrue(document.reasons.isEmpty)

        XCTAssertEqual(document.epochs.count, 2)
        XCTAssertEqual(document.epochs[0].startTs, base)
        XCTAssertEqual(document.epochs[0].endTs, base + 30)
        XCTAssertEqual(document.epochs[0].motion, .walking)
        XCTAssertEqual(document.epochs[0].posture, .unknown)
        XCTAssertEqual(document.epochs[0].exertion, .active)
        XCTAssertEqual(document.epochs[0].confidence, 0.91, accuracy: 1e-9)
        XCTAssertEqual(document.epochs[0].observedS, 30)
        XCTAssertEqual(document.epochs[0].validS, 30)
        XCTAssertEqual(document.epochs[1].motion, .stationary)

        XCTAssertEqual(document.summary.supportedS, 60)
        XCTAssertEqual(document.summary.unknownShare, 0.0, accuracy: 1e-9)
        XCTAssertEqual(document.summary.transitions, 1)

        XCTAssertEqual(document.contexts.hrvSlots.count, 1)
        let slot = try XCTUnwrap(document.contexts.hrvSlots.first)
        XCTAssertEqual(slot.slotS, base)
        XCTAssertEqual(slot.shares["walking"], 0.5)
        XCTAssertEqual(slot.shares["stationary"], 0.5)
        XCTAssertNil(slot.recentActivityS)
        XCTAssertFalse(slot.postActivity)

        XCTAssertEqual(document.contexts.sleepSessions.count, 1)
        let night = try XCTUnwrap(document.contexts.sleepSessions.first)
        XCTAssertEqual(night.start, base)
        XCTAssertEqual(night.end, base + 600)
        XCTAssertEqual(night.shares["stationary"], 0.9)
        XCTAssertEqual(night.unknownShare, 0.1, accuracy: 1e-9)

        // The shared document is round-trippable: encode -> decode reproduces the same object.
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(ActivityContextDocument.self, from: data)
        XCTAssertEqual(decoded, document)
    }

    func testMalformedActivityContextIsNilAndNeverFatal() throws {
        let malformed: [Any?] = [
            "not an object",                       // wrong type
            ["status": "available"],               // missing required members
            ["epochs": "garbage", "summary": [], "contexts": []],  // wrong member types
            ["schema_version": 1, "epochs": [["s": "x", "e": "y", "m": 1, "c": "z"]]],
        ]
        for bad in malformed {
            var daily = c10Daily
            daily["activity_context"] = bad
            let snapshot = ServerScoreRepository.snapshot(day: "2026-09-30", deviceId: "my-whoop",
                                                          envelope: hostedEnvelope(daily: daily),
                                                          fetchedAtMs: 0)
            let result = try XCTUnwrap(snapshot.hostedResult, "the hosted result must still parse")
            XCTAssertNil(result.activityContext, "malformed activity_context must decode to nil")
            // The rest of the hosted result is untouched by the bad field.
            XCTAssertEqual(result.daily.totalSleepMin, 431.5)
            XCTAssertEqual(result.daily.avgHrv, 61.2)
        }
    }

    func testOldPayloadWithoutActivityContextIsUnchanged() throws {
        let daily: [String: Any] = ["sleep_total_min": 431.5, "hrv_rmssd_ms": 61.2]
        let snapshot = ServerScoreRepository.snapshot(day: "2026-09-30", deviceId: "my-whoop",
                                                      envelope: hostedEnvelope(daily: daily),
                                                      fetchedAtMs: 0)
        let result = try XCTUnwrap(snapshot.hostedResult)
        XCTAssertNil(result.activityContext)
        XCTAssertEqual(result.daily.totalSleepMin, 431.5)
        XCTAssertEqual(result.daily.avgHrv, 61.2)
        XCTAssertEqual(result.sleep.count, 1)
        XCTAssertEqual(result.resultRevision, "42")
    }

    func testActivityContextRidesThroughTheLocalCache() async throws {
        let owner = "11111111-1111-4111-8111-111111111111"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-activity-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repo = ServerScoreRepository(session: ScoreStub.session(),
                                         endpoint: URL(string: "https://example.invalid/functions/v1/scores")!,
                                         directory: directory,
                                         identity: { CloudPushIdentity(ownerId: owner, sourceId: "22222222-2222-4222-8222-222222222222",
                                                                       tokenId: "t", uploadToken: "noop_x") })
        let body = hostedEnvelope(daily: c10Daily)
        ScoreStub.response = ["server_scoring": (body["server_scoring"] as! [String: Any])]
        ScoreStub.status = 200

        let fetched = try await repo.refresh(day: "2026-09-30", deviceId: "my-whoop")
        XCTAssertNotNil(fetched.hostedResult?.activityContext, "network read parses the timeline")
        let readBack = await repo.cachedDay(day: "2026-09-30", deviceId: "my-whoop")
        let cached = try XCTUnwrap(readBack?.hostedResult?.activityContext)
        XCTAssertEqual(cached, fetched.hostedResult?.activityContext,
                       "the cached read must reproduce the exact network timeline (owner+device+revision keyed)")
    }

    // MARK: - Wording (the one-line read-out)

    func testWordingDominantWalking() {
        let s = summary(shares: [.walking: 0.9, .stationary: 0.1])
        XCTAssertEqual(ActivityContextWording.text(for: s), "Walking")
        XCTAssertEqual(ActivityContextWording.dominantLabel(in: s), .walking)
    }

    func testWordingDominantRunning() {
        let s = summary(shares: [.running: 0.85, .walking: 0.15])
        XCTAssertEqual(ActivityContextWording.text(for: s), "Running")
    }

    func testWordingStationaryWithUnknownPosture() {
        // v1 posture is unknown unless user-confirmed: the honest suffix is required.
        let s = summary(shares: [.stationary: 0.95, .walking: 0.05], postureSource: "none")
        XCTAssertEqual(ActivityContextWording.text(for: s), "Low movement; posture unknown")
    }

    func testWordingStationaryWithConfirmedPostureOmitsTheSuffix() {
        let s = summary(shares: [.stationary: 0.95, .walking: 0.05], postureSource: "user_confirmed")
        XCTAssertEqual(ActivityContextWording.text(for: s), "Low movement")
    }

    func testWordingRecentActivityWinsOverCurrentStillness() {
        // Mostly still, but supported activity ended 2 minutes before the interval end.
        let s = summary(shares: [.stationary: 0.9, .walking: 0.1], recentActivity: 120)
        XCTAssertEqual(ActivityContextWording.text(for: s), "Recent activity")
    }

    func testWordingRecentActivityRespectsTheTenMinuteWindow() {
        // Supported activity ended 20 minutes ago: past the post-activity window -> stillness again.
        let s = summary(shares: [.stationary: 0.95, .walking: 0.05],
                        recentActivity: 20 * 60, postureSource: "none")
        XCTAssertEqual(ActivityContextWording.text(for: s), "Low movement; posture unknown")
    }

    func testWordingMixedWhenNoLabelDominates() {
        let s = summary(shares: [.walking: 0.4, .stationary: 0.4, .otherMovement: 0.2])
        XCTAssertEqual(ActivityContextWording.text(for: s), "Mixed activity")
    }

    func testWordingMovementDetectedForOtherMotion() {
        let s = summary(shares: [.otherMovement: 0.8, .stationary: 0.2])
        XCTAssertEqual(ActivityContextWording.text(for: s), "Movement detected")
    }

    func testWordingUnavailableCases() {
        // No overlapping epochs at all.
        XCTAssertEqual(ActivityContextWording.text(for: summary(shares: [:],
                                                                 qualityReasons: ["no_data"])),
                       "Activity unavailable")
        // Nothing supported.
        XCTAssertEqual(ActivityContextWording.text(for: summary(shares: [:])), "Activity unavailable")
        // Mostly abstained -> uncertainty is shown plainly, never a guessed stationary label.
        let s = summary(shares: [.stationary: 0.2], unknownShare: 0.8)
        XCTAssertEqual(ActivityContextWording.text(for: s), "Activity unavailable")
        // Invalid interval.
        XCTAssertEqual(ActivityContextWording.text(for: summary(shares: [.walking: 1.0],
                                                                 qualityReasons: ["invalid_interval"])),
                       "Activity unavailable")
    }

    // MARK: - Ribbon (explicit gaps, no invented stationary)

    func testRibbonGapsAreExplicitAndNeverInventedStationary() {
        // 2 walking buckets, then a 2-bucket gap, then 1 stationary bucket, in a 6-bucket day.
        let epochs = [epoch(base, motion: .walking),
                      epoch(base + 30, motion: .walking),
                      epoch(base + 120, motion: .stationary)]
        let segments = ActivityRibbon.segments(epochs: epochs, dayStart: base, dayEnd: base + 180)
        XCTAssertEqual(segments, [.epoch(.walking), .epoch(.walking),
                                  .gap, .gap,
                                  .epoch(.stationary), .gap])
    }

    func testRibbonOneSegmentPerGridBucketWithNoCoverageNoise() {
        // One hour of data in a 24 h day: exactly 2880 buckets, the uncovered 23 h all gaps.
        let epochs = [epoch(base, motion: .walking),
                      epoch(base + 30, motion: .stationary),
                      epoch(base + 60, motion: .walking),
                      epoch(base + 90, motion: .stationary)]
        let segments = ActivityRibbon.segments(epochs: epochs, dayStart: base,
                                               dayEnd: base + 86_400)
        XCTAssertEqual(segments.count, 86_400 / 30)
        // Gaps are a distinct `.gap` presentation — they can never collide with a stationary epoch,
        // which is the "no invented stationary" contract (spec §8 / C3).
        let gaps = segments.filter { $0 == .gap }.count
        XCTAssertEqual(gaps, 86_400 / 30 - 4, "every missing bucket is an explicit gap")
        let stationary = segments.filter { if case .epoch(let m) = $0 { return m == .stationary } else { return false } }.count
        XCTAssertEqual(stationary, 2, "only the two real stationary epochs paint as stationary")
    }

    func testRibbonMatchesPartialEpochsAtRunEdgesAndHandlesEmptyWindows() {
        // A partial epoch that starts mid-bucket still paints its covered bucket via overlap.
        let partial = ActivityEpoch(startTs: base + 10, endTs: base + 40, motion: .walking,
                                    posture: .unknown, exercise: .unknown, sleepState: .unknown,
                                    exertion: .unknown, wear: .unknown, confidence: 0.9,
                                    observedS: 30, validS: 30)
        let segments = ActivityRibbon.segments(epochs: [partial], dayStart: base, dayEnd: base + 60)
        XCTAssertEqual(segments, [.epoch(.walking), .epoch(.walking)])
        // No epochs at all -> a fully-gap ribbon, never an empty one.
        let empty = ActivityRibbon.segments(epochs: [], dayStart: base, dayEnd: base + 60)
        XCTAssertEqual(empty, [.gap, .gap])
        // Degenerate window -> no segments, no crash.
        XCTAssertEqual(ActivityRibbon.segments(epochs: [partial], dayStart: base, dayEnd: base), [])
    }

    // MARK: - Detail sheet data

    func testDetailSheetDataBuildsSourceConfidenceCoverageAndReasons() throws {
        let epochs = [epoch(base, motion: .walking, confidence: 0.91),
                      epoch(base + 30, motion: .stationary, confidence: 0.87)]
        var doc = document(epochs: epochs)
        // A document-level reason plus join-derived reasons flow into the sheet.
        doc = ActivityContextDocument(schemaVersion: doc.schemaVersion, ontologyVersion: doc.ontologyVersion,
                                      modelVersion: doc.modelVersion,
                                      preprocessingVersion: doc.preprocessingVersion,
                                      inputRevision: doc.inputRevision, dataThrough: doc.dataThrough,
                                      status: doc.status, reasons: ["model_unavailable"],
                                      epochs: doc.epochs, summary: doc.summary, contexts: doc.contexts)
        let data = ActivityContextDetailSheetData.build(document: doc, interval: [base, base + 60])

        XCTAssertEqual(data.wording, "Mixed activity", "half walking / half stationary reads mixed")
        XCTAssertEqual(data.status, .available)
        XCTAssertEqual(data.source, "Server model · hart-activity-1")
        XCTAssertEqual(data.confidence ?? -1, (0.91 + 0.87) / 2, accuracy: 1e-9)
        XCTAssertEqual(data.observedS, 60)
        XCTAssertEqual(data.validS, 60)
        XCTAssertEqual(data.dataThrough, "2026-09-30T13:30:00Z")
        XCTAssertTrue(data.reasons.contains("model_unavailable"))
        XCTAssertEqual(data.postureSource, "none")
        XCTAssertEqual(ActivityContextDetailSheetData.reasonLabel("model_unavailable"), "model_unavailable",
                       "unknown reason codes pass through verbatim rather than crashing")
    }

    func testDetailSheetDataUnavailableForNoOverlapAndUnknownSourceWithoutModelVersion() {
        let doc = document(epochs: [epoch(base, motion: .walking)])
        let data = ActivityContextDetailSheetData.build(document: doc, interval: [base + 10_000, base + 10_030])
        XCTAssertEqual(data.wording, "Activity unavailable")
        XCTAssertEqual(data.confidence, nil)
        XCTAssertEqual(data.observedS, 0)
        XCTAssertEqual(data.validS, 0)
        XCTAssertTrue(data.reasons.contains("no_data"))

        let noModel = ActivityContextDocument(schemaVersion: 1, ontologyVersion: "v1", modelVersion: "",
                                              preprocessingVersion: "p", inputRevision: 1,
                                              dataThrough: "2026-09-30T13:30:00Z", status: .available,
                                              reasons: [], epochs: doc.epochs, summary: doc.summary,
                                              contexts: doc.contexts)
        XCTAssertEqual(ActivityContextDetailSheetData.sourceLabel(for: noModel), "Server model")
    }

    // MARK: - Selection (support interval + day window)

    private let utc = TimeZone(identifier: "UTC")!
    private let pacific = TimeZone(identifier: "America/Los_Angeles")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    /// Unix seconds for a local wall-clock time.
    private func local(_ day: String, _ hour: Int, _ minute: Int = 0, _ tz: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let parts = day.split(separator: "-").map { Int($0)! }
        let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                      hour: hour, minute: minute))!
        return Int(date.timeIntervalSince1970)
    }

    func testNightlyHrvJoinsTheNightNotTheLastDaytimeSlot() throws {
        // D3-01: sleep 23:00-07:00 Pacific, intraday slots at 03:00 and 16:00. The nightly HRV hero must
        // describe the night, never the 16:00 slot that `hrvSlots.last` used to return.
        let day = "2026-10-07"
        let night = (start: local("2026-10-06", 23, 0, pacific), end: local(day, 7, 0, pacific))
        let slot3 = local(day, 3, 0, pacific), slot16 = local(day, 16, 0, pacific)
        let doc = document(epochs: [], hrvSlots: [
            HrvSlotContext(slotS: slot3, shares: ["stationary": 1.0], unknownShare: 0,
                           recentActivityS: nil, postActivity: false),
            HrvSlotContext(slotS: slot16, shares: ["walking": 1.0], unknownShare: 0,
                           recentActivityS: 0, postActivity: false),
        ])
        let window = try XCTUnwrap(ActivityContextSelection.dayWindow(day: day, timeZone: pacific))
        let interval = ActivityContextSelection.interval(metricKey: "hrv", document: doc, dayWindow: window,
                                                         sleepSessions: [night])
        XCTAssertEqual(interval, [night.start, night.end])
        for key in ["rhr", "resp_rate", "spo2", "skin_temp"] {
            XCTAssertEqual(ActivityContextSelection.interval(metricKey: key, document: doc, dayWindow: window,
                                                             sleepSessions: [night]),
                           [night.start, night.end], key)
        }
        // A slot the user selects on the intraday chart still joins on its own 15-min bucket.
        XCTAssertEqual(ActivityContextSelection.interval(metricKey: "hrv", document: doc, dayWindow: window,
                                                         sleepSessions: [night], selectedSlotStart: slot16),
                       [slot16, slot16 + 900])
    }

    func testDayWindowIsTheLocalDayNotUtcMidnight() throws {
        // Pacific (PDT, UTC-7): 2026-10-07 starts at 07:00Z.
        let pdt = try XCTUnwrap(ActivityContextSelection.dayWindow(day: "2026-10-07", timeZone: pacific))
        XCTAssertEqual(pdt[0], local("2026-10-07", 7, 0, utc))
        XCTAssertEqual(pdt[1] - pdt[0], 86_400)
        // UTC+9: 2026-10-07 starts at 15:00Z on the 6th.
        let jst = try XCTUnwrap(ActivityContextSelection.dayWindow(day: "2026-10-07", timeZone: tokyo))
        XCTAssertEqual(jst[0], local("2026-10-06", 15, 0, utc))
        // A DST fall-back day is 25 h long, not 24.
        let fallBack = try XCTUnwrap(ActivityContextSelection.dayWindow(day: "2026-11-01", timeZone: pacific))
        XCTAssertEqual(fallBack[1] - fallBack[0], 25 * 3600)
        XCTAssertNil(ActivityContextSelection.dayWindow(day: "not-a-day", timeZone: pacific))
    }

    func testUtcPlusNineUserGetsTheirOwnNight() throws {
        // A Tokyo user sleeps 23:00-07:00 JST (14:00Z-22:00Z the previous UTC day). Under the old UTC
        // window for "2026-10-07" this night (ending 22:00Z on the 6th) did not overlap at all.
        let day = "2026-10-07"
        let night = (start: local("2026-10-06", 23, 0, tokyo), end: local(day, 7, 0, tokyo))
        let nextNight = (start: local(day, 23, 0, tokyo), end: local("2026-10-08", 7, 0, tokyo))
        let window = try XCTUnwrap(ActivityContextSelection.dayWindow(day: day, timeZone: tokyo))
        let doc = document(epochs: [])
        XCTAssertEqual(ActivityContextSelection.interval(metricKey: "hrv", document: doc, dayWindow: window,
                                                         sleepSessions: [nextNight, night]),
                       [night.start, night.end],
                       "the night that ENDS on the day wins over the one that starts late that evening")
    }

    func testTimeZoneComesFromTheHostedSnapshot() {
        XCTAssertEqual(ActivityContextSelection.timeZone(hostedSnapshot: ["timezone": "Asia/Tokyo"]).identifier,
                       "Asia/Tokyo")
        XCTAssertEqual(ActivityContextSelection.timeZone(hostedSnapshot: ["timezone": "Not/AZone"]),
                       TimeZone.current, "an invalid zone falls back to the device zone, never UTC")
        XCTAssertEqual(ActivityContextSelection.timeZone(hostedSnapshot: nil), TimeZone.current)
    }

    func testNightlyMetricFallsBackToTheDocumentsSleepSessionThenHides() throws {
        let window = try XCTUnwrap(ActivityContextSelection.dayWindow(day: "2026-09-30", timeZone: utc))
        let docNight = SleepSessionContext(start: window[0] + 3600, end: window[0] + 8 * 3600,
                                           shares: [:], unknownShare: 1)
        let doc = document(epochs: [], sleepSessions: [docNight])
        XCTAssertEqual(ActivityContextSelection.interval(metricKey: "resp_rate", document: doc, dayWindow: window,
                                                         sleepSessions: []),
                       [docNight.start, docNight.end])
        // No night anywhere: a nightly hero gets no read-out rather than the whole day's activity.
        XCTAssertNil(ActivityContextSelection.interval(metricKey: "hrv", document: document(epochs: []),
                                                       dayWindow: window, sleepSessions: []))
        // A session entirely outside the day does not count.
        let otherNight = (start: window[0] - 3 * 86_400, end: window[0] - 3 * 86_400 + 3600)
        XCTAssertNil(ActivityContextSelection.interval(metricKey: "spo2", document: document(epochs: []),
                                                       dayWindow: window, sleepSessions: [otherNight]))
    }

    func testNonNightlyMetricsUseTheWholeLocalDay() throws {
        let window = try XCTUnwrap(ActivityContextSelection.dayWindow(day: "2026-09-30", timeZone: pacific))
        XCTAssertEqual(ActivityContextSelection.interval(metricKey: "steps", document: document(epochs: []),
                                                         dayWindow: window, sleepSessions: []), window)
    }
}
