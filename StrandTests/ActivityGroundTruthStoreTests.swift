import XCTest
import StrandAnalytics
@testable import Strand

/// Ground-truth activity labels on the phone: the pure coverage math, the local store (enrichment, LWW,
/// durability), and the upload to the `scores` function. The IMU coverage reader is injected, so these
/// tests never touch the real file store.
final class ActivityGroundTruthStoreTests: XCTestCase {

    // MARK: Fixtures

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ground-truth-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        GroundTruthStub.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A store whose coverage reader claims every second of the interval is present by default, so store
    /// round-trip tests are deterministic without touching the real IMU store.
    private func makeStore(coverageReader: @escaping ActivityGroundTruthStore.CoverageReader
        = { _, from, to in Array(from..<to).map(Int64.init) },
                           build: String = "100") -> ActivityGroundTruthStore {
        ActivityGroundTruthStore(fileURL: tempDir.appendingPathComponent("ground-truth-labels.json"),
                                 coverageReader: coverageReader, currentBuild: { build })
    }

    private func makeLabel(startTs: Int = 1_000, endTs: Int? = nil, labelKey: String? = nil,
                           source: ActivityGroundTruthSource = .guided, deviceId: String? = "w1",
                           sensorQuality: ActivityGroundTruthSensorQuality? = nil,
                           rawRefs: [ActivityGroundTruthRawRef]? = nil,
                           modelContext: [String: String]? = nil,
                           updatedAt: Date = Date(), syncedAt: Date? = nil) -> ActivityGroundTruthLabel {
        ActivityGroundTruthLabel(
            id: UUID(), labelKey: labelKey ?? "guided:sess-1:\(startTs)",
            source: source, sessionId: "sess-1", protocolVersion: "calibration-v1", repetition: 1,
            deviceId: deviceId, externalDeviceId: "whoop-123",
            startTs: startTs, endTs: endTs ?? startTs + 10,
            posture: "seated_likely", locomotion: "stationary", armBehavior: "desk_like",
            transitionKind: nil, transitionTs: nil, semanticTag: "typing",
            labelConfidence: 0.9, userUnsure: false, note: nil,
            cueContext: nil, sensorQuality: sensorQuality, rawRefs: rawRefs,
            modelContextAtLabelTime: modelContext,
            appVersion: "1.2.3", appBuild: "45",
            createdAt: updatedAt, updatedAt: updatedAt, syncedAt: syncedAt)
    }

    private func sync(_ store: ActivityGroundTruthStore, signedIn: Bool = true) -> ActivityGroundTruthCloudSync {
        ActivityGroundTruthCloudSync(
            store: store,
            session: GroundTruthStub.session(),
            endpoint: { URL(string: "https://example.invalid/functions/v1/scores")! },
            identity: {
                signedIn ? CloudPushIdentity(ownerId: "11111111-1111-4111-8111-111111111111",
                                             sourceId: "22222222-2222-4222-8222-222222222222",
                                             tokenId: "t", uploadToken: "noop_x") : nil
            })
    }

    // MARK: Coverage math (pure)

    func testFullCoverageComputesCompleteQuality() {
        let quality = ActivityGroundTruthStore.coverage(seconds: (100..<110).map(Int64.init),
                                                        from: 100, to: 110, sampleRateHz: 100)
        XCTAssertEqual(quality.expectedSeconds, 10)
        XCTAssertEqual(quality.coveredSeconds, 10)
        XCTAssertEqual(quality.coverageRatio, 1.0)
        XCTAssertEqual(quality.firstTs, 100)
        XCTAssertEqual(quality.lastTs, 109)
        XCTAssertTrue(quality.gaps.isEmpty)
        XCTAssertTrue(quality.evaluationReady)
    }

    func testPartialCoverageReportsMaximalMissingRuns() {
        // Missing seconds: 100-101, 105-106, 109 -> three maximal runs.
        let quality = ActivityGroundTruthStore.coverage(seconds: [102, 103, 104, 107, 108].map(Int64.init),
                                                        from: 100, to: 110, sampleRateHz: 100)
        XCTAssertEqual(quality.coveredSeconds, 5)
        XCTAssertEqual(quality.coverageRatio, 0.5)
        XCTAssertEqual(quality.gaps, [
            ActivityGroundTruthGap(startTs: 100, endTs: 102),
            ActivityGroundTruthGap(startTs: 105, endTs: 107),
            ActivityGroundTruthGap(startTs: 109, endTs: 110),
        ])
        XCTAssertFalse(quality.evaluationReady)
    }

    func testNoRecordsReportsTheWholeIntervalAsOneGap() {
        let quality = ActivityGroundTruthStore.coverage(seconds: [], from: 100, to: 110, sampleRateHz: 100)
        XCTAssertEqual(quality.coveredSeconds, 0)
        XCTAssertEqual(quality.coverageRatio, 0)
        XCTAssertNil(quality.firstTs)
        XCTAssertNil(quality.lastTs)
        XCTAssertEqual(quality.gaps, [ActivityGroundTruthGap(startTs: 100, endTs: 110)])
        XCTAssertFalse(quality.evaluationReady)
    }

    func testAMissingRunIsOneGapEvenAcrossABucketBoundary() {
        // The IMU store's segment files split at 30-minute buckets (e.g. at second 120), but the reader
        // merges every record into ONE flat list, so a missing run must never come back split in two.
        let covered = (100..<118).map(Int64.init) + (123..<130).map(Int64.init)
        let quality = ActivityGroundTruthStore.coverage(seconds: covered, from: 100, to: 130, sampleRateHz: 100)
        XCTAssertEqual(quality.gaps, [ActivityGroundTruthGap(startTs: 118, endTs: 123)],
                       "the run 118..<123 crosses the 120 boundary and must stay one gap")
    }

    func testHalfOpenSemanticsCountOnlyInsideTheInterval() {
        // 100 is inside [100,110), 110 is not; a record at exactly `to` must not count, and a gap never
        // extends past `to` (its endTs is exclusive).
        let quality = ActivityGroundTruthStore.coverage(seconds: [99, 100, 101, 110, 111].map(Int64.init),
                                                        from: 100, to: 110, sampleRateHz: 100)
        XCTAssertEqual(quality.coveredSeconds, 2, "only 100 and 101 lie inside [100,110)")
        XCTAssertEqual(quality.gaps, [ActivityGroundTruthGap(startTs: 102, endTs: 110)])
        XCTAssertEqual(quality.lastTs, 101)
    }

    func testDuplicateSecondsAreCountedOnce() {
        let quality = ActivityGroundTruthStore.coverage(seconds: [102, 102, 103, 102].map(Int64.init),
                                                        from: 100, to: 110, sampleRateHz: 100)
        XCTAssertEqual(quality.coveredSeconds, 2)
    }

    func testAZeroLengthIntervalIsExplicitlyNotEvaluationReady() {
        let quality = ActivityGroundTruthStore.coverage(seconds: [], from: 500, to: 500, sampleRateHz: 100)
        XCTAssertEqual(quality.expectedSeconds, 0)
        XCTAssertEqual(quality.coverageRatio, 0)
        XCTAssertTrue(quality.gaps.isEmpty)
        XCTAssertFalse(quality.evaluationReady, "evaluationReady requires expectedSeconds > 0")
    }

    // MARK: Store round-trip

    func testUpsertReplacesByLabelKeyAndKeepsOthers() {
        let store = makeStore()
        let first = makeLabel(startTs: 1_000)
        store.upsert(first)
        store.upsert(makeLabel(startTs: 2_000))

        let replacement = makeLabel(startTs: 1_000, updatedAt: Date().addingTimeInterval(5))
        store.upsert(replacement)

        let rows = store.all()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.startTs == 1_000 })?.id, replacement.id)
        XCTAssertEqual(rows.first(where: { $0.startTs == 2_000 })?.id != replacement.id, true)
    }

    func testLabelsSurviveRelaunchWithTheirDates() {
        let first = makeStore()
        let saved = makeLabel(startTs: 1_000)
        first.upsert(saved)

        let reopened = makeStore().all()
        XCTAssertEqual(reopened.count, 1)
        XCTAssertEqual(reopened.first?.id, saved.id)
        XCTAssertEqual(reopened.first?.labelKey, saved.labelKey)
        XCTAssertEqual(reopened.first?.source, .guided)
        // Persisted as ISO 8601 with milliseconds, so the round trip is exact only to the millisecond.
        XCTAssertEqual(reopened.first?.updatedAt.timeIntervalSince1970 ?? 0,
                       saved.updatedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(reopened.first?.needsSync ?? false)
    }

    func testPendingIsOldestFirstAndClearedByMarkSynced() {
        let store = makeStore()
        let now = Date()
        let a = makeLabel(startTs: 1_000, updatedAt: now)
        let b = makeLabel(startTs: 2_000, updatedAt: now.addingTimeInterval(10))
        store.upsert(b); store.upsert(a)

        XCTAssertEqual(store.pending().map(\.startTs), [1_000, 2_000])

        store.markSynced([(id: a.id, updatedAt: a.updatedAt)])
        XCTAssertEqual(store.pending().map(\.startTs), [2_000])
        XCTAssertEqual(store.all().count, 2, "a synced label stays until pruning, just not pending")
    }

    func testLastWriterWinsOnUpdatedAt() {
        let store = makeStore()
        let sent = makeLabel(startTs: 1_000)
        store.upsert(sent)
        let edited = makeLabel(startTs: 1_000, updatedAt: sent.updatedAt.addingTimeInterval(30))
        store.upsert(edited)

        store.markSynced([(id: sent.id, updatedAt: sent.updatedAt)])

        XCTAssertEqual(store.pending().map(\.startTs), [1_000], "the edit after the send stays pending")
        XCTAssertEqual(store.pending().first?.updatedAt, edited.updatedAt)

        store.markSynced([(id: edited.id, updatedAt: edited.updatedAt)])
        XCTAssertTrue(store.pending().isEmpty)
    }

    func testOldSyncedLabelsAreDroppedButUnsentOnesNever() {
        let store = makeStore()
        let longAgo = Date().addingTimeInterval(-Double(ActivityGroundTruthStore.keepSyncedDays + 5) * 86_400)
        let oldSent = makeLabel(startTs: 1_000, updatedAt: longAgo)
        let oldUnsent = makeLabel(startTs: 2_000, updatedAt: longAgo)
        store.upsert(oldSent); store.upsert(oldUnsent)

        store.markSynced([(id: oldSent.id, updatedAt: oldSent.updatedAt)])

        XCTAssertEqual(store.all().map(\.startTs), [2_000])
    }

    func testAnUnreadableFileIsSetAsideNotDestroyed() throws {
        let url = tempDir.appendingPathComponent("ground-truth-labels.json")
        try Data("not json".utf8).write(to: url)
        let store = ActivityGroundTruthStore(fileURL: url)

        store.upsert(makeLabel(startTs: 1_000))

        let kept = try setAsideFiles()
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try String(contentsOf: kept[0], encoding: .utf8), "not json")
        XCTAssertEqual(ActivityGroundTruthStore(fileURL: url).all().count, 1, "the new label is saved as usual")
    }

    func testOnlyTheNewestSetAsideCopiesAreKept() throws {
        let url = tempDir.appendingPathComponent("ground-truth-labels.json")
        for n in 0..<(ActivityGroundTruthStore.keepUnreadableCopies + 3) {
            let stale = tempDir.appendingPathComponent(
                "\(ActivityGroundTruthStore.unreadablePrefix)\(1_000 + n).json")
            try Data("old \(n)".utf8).write(to: stale)
        }
        try Data("not json".utf8).write(to: url)

        _ = ActivityGroundTruthStore(fileURL: url).all()

        let names = try setAsideFiles().map(\.lastPathComponent).sorted()
        XCTAssertEqual(names.count, ActivityGroundTruthStore.keepUnreadableCopies)
        XCTAssertFalse(names.contains("\(ActivityGroundTruthStore.unreadablePrefix)1000.json"),
                       "the oldest copy goes first")
    }

    func testRemoveAllEmptiesTheStore() {
        let store = makeStore()
        store.upsert(makeLabel(startTs: 1_000))
        store.removeAll()
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertTrue(store.pending().isEmpty)
    }

    private func setAsideFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(ActivityGroundTruthStore.unreadablePrefix) }
    }

    // MARK: Enrichment (injected reader)

    func testUpsertFillsSensorQualityAndRawRefsFromTheReader() {
        let store = makeStore()
        let label = makeLabel(startTs: 1_000, endTs: 1_010)
        let saved = store.upsert(label)

        XCTAssertNotNil(saved.sensorQuality)
        XCTAssertEqual(saved.sensorQuality?.expectedSeconds, 10)
        XCTAssertEqual(saved.sensorQuality?.coveredSeconds, 10)
        XCTAssertEqual(saved.sensorQuality?.sampleRateHz, 100)
        XCTAssertEqual(saved.sensorQuality?.coverageRatio, 1.0)
        XCTAssertTrue(saved.sensorQuality?.evaluationReady ?? false)
        XCTAssertEqual(saved.rawRefs?.count, 1)
        let fact = saved.rawRefs?.first
        XCTAssertEqual(fact?.storeSessionId, "activity-w1", "the fact names the open activity window")
        XCTAssertEqual(fact?.startTs, 1_000)
        XCTAssertEqual(fact?.endTs, 1_010)
        XCTAssertEqual(fact?.sampleRateHz, 100)
        XCTAssertEqual(fact?.coveredSeconds, 10)
        XCTAssertEqual(store.all().first?.sensorQuality?.coveredSeconds, 10, "the enriched label is persisted")
    }

    func testUpsertWithoutADeviceFillsExplicitMissingCoverage() {
        let store = makeStore(coverageReader: { _, _, _ in XCTFail("no device: the reader must not be asked"); return nil })
        let label = makeLabel(startTs: 1_000, endTs: 1_010, deviceId: nil)
        let saved = store.upsert(label)

        XCTAssertNotNil(saved.sensorQuality, "missing coverage is explicit, never nil")
        XCTAssertEqual(saved.sensorQuality?.coveredSeconds, 0)
        XCTAssertEqual(saved.sensorQuality?.gaps, [ActivityGroundTruthGap(startTs: 1_000, endTs: 1_010)])
        XCTAssertFalse(saved.sensorQuality?.evaluationReady ?? true)
        XCTAssertEqual(saved.rawRefs?.count, 0)
    }

    func testUpsertWithNoRecordsFillsMissingCoverageAndAZeroFact() {
        let store = makeStore(coverageReader: { _, _, _ in [] })
        let saved = store.upsert(makeLabel(startTs: 1_000, endTs: 1_010))

        XCTAssertEqual(saved.sensorQuality?.coveredSeconds, 0)
        XCTAssertEqual(saved.sensorQuality?.gaps, [ActivityGroundTruthGap(startTs: 1_000, endTs: 1_010)])
        XCTAssertFalse(saved.sensorQuality?.evaluationReady ?? true)
        XCTAssertEqual(saved.rawRefs?.first?.storeSessionId, "activity-w1")
        XCTAssertEqual(saved.rawRefs?.first?.coveredSeconds, 0, "the fact still names what the server can re-join")
    }

    func testExistingSensorQualityIsKeptWithoutAskingTheReader() {
        let store = makeStore(coverageReader: { _, _, _ in [] })  // would report missing if consulted
        let preFilled = ActivityGroundTruthSensorQuality(expectedSeconds: 10, coveredSeconds: 10, sampleRateHz: 100,
                                                         firstTs: 1_000, lastTs: 1_009, gaps: [])
        let saved = store.upsert(makeLabel(sensorQuality: preFilled))

        XCTAssertEqual(saved.sensorQuality?.coveredSeconds, 10, "the pre-filled quality is untouched")
        XCTAssertNil(saved.rawRefs, "rawRefs are left alone too")
    }

    // MARK: Wire form

    func testWireUsesTheExactSnakeCaseFieldSet() throws {
        let quality = ActivityGroundTruthSensorQuality(expectedSeconds: 10, coveredSeconds: 8, sampleRateHz: 100,
                                                       firstTs: 1_000, lastTs: 1_009,
                                                       gaps: [ActivityGroundTruthGap(startTs: 1_004, endTs: 1_006)])
        let raw = ActivityGroundTruthRawRef(storeSessionId: "activity-w1", startTs: 1_000, endTs: 1_010,
                                            sampleRateHz: 100, coveredSeconds: 8)
        let label = makeLabel(sensorQuality: quality, rawRefs: [raw], modelContext: ["decoder": "hsmm-1.3"])

        let data = try JSONEncoder().encode(GroundTruthLabelWire(label))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let expectedKeys = Set([
            "id", "label_key", "source", "session_id", "protocol_version", "repetition",
            "device_id", "external_device_id", "start_ts", "end_ts", "posture", "locomotion",
            "arm_behavior", "transition_kind", "transition_ts", "semantic_tag",
            "label_confidence", "user_unsure", "note", "cue_context", "sensor_quality",
            "raw_refs", "model_context_at_label_time", "app_version", "app_build",
            "tz_offset_s", "client_created_at", "client_updated_at",
        ])
        // Nil optionals are omitted (the route validator treats an absent key as null); every key that is
        // sent must be one the validator knows.
        XCTAssertTrue(Set(json.keys).isSubset(of: expectedKeys), "unknown wire keys: \(Set(json.keys).subtracting(expectedKeys))")
        XCTAssertEqual(expectedKeys.subtracting(json.keys),
                       ["transition_kind", "transition_ts", "note", "cue_context"],
                       "only this label's nil fields are absent")

        XCTAssertEqual(json["id"] as? String, label.id.uuidString.lowercased())
        XCTAssertEqual(json["label_key"] as? String, label.labelKey)
        XCTAssertEqual(json["source"] as? String, "guided")
        XCTAssertEqual(json["session_id"] as? String, "sess-1")
        XCTAssertEqual(json["protocol_version"] as? String, "calibration-v1")
        XCTAssertEqual(json["repetition"] as? Int, 1)
        XCTAssertEqual(json["device_id"] as? String, "w1")
        XCTAssertEqual(json["external_device_id"] as? String, "whoop-123")
        XCTAssertEqual(json["start_ts"] as? Int, 1_000)
        XCTAssertEqual(json["end_ts"] as? Int, 1_010)
        XCTAssertEqual(json["posture"] as? String, "seated_likely")
        XCTAssertEqual(json["locomotion"] as? String, "stationary")
        XCTAssertEqual(json["arm_behavior"] as? String, "desk_like")
        XCTAssertEqual(json["semantic_tag"] as? String, "typing")
        XCTAssertEqual(json["label_confidence"] as? Double, 0.9)
        XCTAssertEqual(json["user_unsure"] as? Bool, false)
        XCTAssertEqual(json["model_context_at_label_time"] as? [String: String], ["decoder": "hsmm-1.3"])
        XCTAssertEqual(json["app_version"] as? String, "1.2.3")
        XCTAssertEqual(json["app_build"] as? String, "45")
        XCTAssertNotNil(json["tz_offset_s"] as? Int)
        XCTAssertNotNil(json["client_created_at"] as? String)
        XCTAssertNotNil(json["client_updated_at"] as? String)

        let sq = try XCTUnwrap(json["sensor_quality"] as? [String: Any])
        XCTAssertEqual(Set(sq.keys), Set(["expected_seconds", "covered_seconds", "sample_rate_hz",
                                          "first_ts", "last_ts", "gaps", "coverage_ratio", "evaluation_ready"]),
                       "sensor quality encodes through the StrandAnalytics type's own snake_case keys")
        XCTAssertEqual(sq["expected_seconds"] as? Int, 10)
        XCTAssertEqual(sq["covered_seconds"] as? Int, 8)
        XCTAssertEqual(sq["sample_rate_hz"] as? Int, 100)
        XCTAssertEqual(sq["coverage_ratio"] as? Double, 0.8)
        let gaps = try XCTUnwrap(sq["gaps"] as? [[String: Any]])
        let gap = try XCTUnwrap(gaps.first)
        XCTAssertEqual(gap["start_ts"] as? Int, 1_004)
        XCTAssertEqual(gap["end_ts"] as? Int, 1_006)

        let refs = try XCTUnwrap(json["raw_refs"] as? [[String: Any]])
        let ref = try XCTUnwrap(refs.first)
        XCTAssertEqual(Set(ref.keys), Set(["store_session_id", "start_ts", "end_ts",
                                           "sample_rate_hz", "covered_seconds"]))
        XCTAssertEqual(ref["store_session_id"] as? String, "activity-w1")
        XCTAssertEqual(ref["covered_seconds"] as? Int, 8)
    }

    // MARK: Reading the server's reply

    func testSavedAndIgnoredCountAsDeliveredRejectedDoesNot() {
        let a = makeLabel(startTs: 1_000), b = makeLabel(startTs: 2_000), c = makeLabel(startTs: 3_000)
        let d = makeLabel(startTs: 4_000)
        let reply = """
        {"saved":[{"label_key":"\(a.labelKey)","revision":1}],
         "ignored":[{"label_key":"\(b.labelKey)","reason":"older"}],
         "rejected":[{"label_key":"\(c.labelKey)","reason":"bad_vocabulary"}]}
        """
        let result = ActivityGroundTruthCloudSync.accepted(in: Data(reply.utf8), batch: [a, b, c, d])

        XCTAssertEqual(Set(result.accepted.map(\.id)), [a.id, b.id])
        XCTAssertEqual(result.rejected, 1)
    }

    func testAnUnreadableReplyTakesNothing() {
        let a = makeLabel()
        XCTAssertTrue(ActivityGroundTruthCloudSync.accepted(in: Data("oops".utf8), batch: [a]).accepted.isEmpty)
        XCTAssertTrue(ActivityGroundTruthCloudSync.accepted(in: Data("{}".utf8), batch: [a]).accepted.isEmpty)
    }

    // MARK: Upload

    func testPushSendsTheWireContractAndClearsTheQueue() async throws {
        let store = makeStore()
        let a = makeLabel(startTs: 1_000)
        store.upsert(a)
        GroundTruthStub.reply = .saved

        let outcome = try await sync(store).pushPending()

        XCTAssertEqual(outcome, .init(uploaded: 1, rejected: 0))
        XCTAssertTrue(store.pending().isEmpty)
        let request = try XCTUnwrap(GroundTruthStub.requests.first)
        XCTAssertEqual(request.url?.path, "/functions/v1/scores/ground-truth-labels")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer noop_x")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: GroundTruthStub.bodies[0]) as? [String: Any])
        let items = try XCTUnwrap(body["labels"] as? [[String: Any]])
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item["label_key"] as? String, a.labelKey)
        XCTAssertEqual(item["source"] as? String, "guided")
        XCTAssertEqual(item["start_ts"] as? Int, 1_000)
        XCTAssertEqual(item["id"] as? String, a.id.uuidString.lowercased())
        XCTAssertNotNil(item["sensor_quality"] as? [String: Any], "the enriched quality travels with the label")
        XCTAssertNotNil(item["raw_refs"] as? [[String: Any]])
        XCTAssertNotNil(item["client_updated_at"] as? String)
    }

    func testPushSplitsLargeQueuesIntoBatches() async throws {
        let store = makeStore()
        let total = ActivityGroundTruthCloudSync.batchSize * 2 + 3
        for i in 0..<total {
            store.upsert(makeLabel(startTs: 1_000 + i * 700, updatedAt: Date().addingTimeInterval(Double(i))))
        }
        GroundTruthStub.reply = .echo

        let outcome = try await sync(store).pushPending()

        XCTAssertEqual(outcome.uploaded, total)
        XCTAssertEqual(GroundTruthStub.requests.count, 3)
        XCTAssertTrue(store.pending().isEmpty)
    }

    func testRejectedLabelsStayQueued() async throws {
        let store = makeStore()
        store.upsert(makeLabel(startTs: 1_000))
        GroundTruthStub.reply = .rejected

        let outcome = try await sync(store).pushPending()

        XCTAssertEqual(outcome.uploaded, 0)
        XCTAssertEqual(outcome.rejected, 1)
        XCTAssertNil(outcome.blocked)
        XCTAssertEqual(store.pending().count, 1)
    }

    func testStructurallyInvalidLabelsAreQuarantinedNotDeleted() async throws {
        let store = makeStore()
        let a = makeLabel(startTs: 1_000)
        store.upsert(a)
        GroundTruthStub.reply = .invalid

        let outcome = try await sync(store).pushPending()

        XCTAssertEqual(outcome.quarantined, 1)
        XCTAssertEqual(outcome.refusals[a.labelKey], "invalid_posture")
        XCTAssertTrue(store.pending().isEmpty, "a malformed label is not re-sent on every activation")
        XCTAssertEqual(store.quarantined().map(\.label.labelKey), [a.labelKey])
        XCTAssertEqual(store.quarantined().first?.reason, "invalid_posture")

        _ = try await sync(store).pushPending()
        XCTAssertEqual(GroundTruthStub.requests.count, 1, "the same build does not retry it")
    }

    func testALabelEditedAfterTheRefusedCopyWasSentStaysQueued() {
        let store = makeStore()
        let sentAt = Date(timeIntervalSince1970: 1_000_000)
        let a = makeLabel(startTs: 1_000, updatedAt: sentAt.addingTimeInterval(60))
        store.upsert(a)

        let moved = store.quarantine([(labelKey: a.labelKey, updatedAt: sentAt, reason: "invalid_posture")])

        XCTAssertEqual(moved, 0)
        XCTAssertEqual(store.pending().map(\.labelKey), [a.labelKey])
        XCTAssertTrue(store.quarantined().isEmpty)
    }

    func testQuarantinedLabelsGoBackInTheQueueOnANewBuild() async throws {
        let a = makeLabel(startTs: 1_000)
        let old = makeStore(build: "100")
        old.upsert(a)
        GroundTruthStub.reply = .invalid
        _ = try await sync(old).pushPending()
        XCTAssertTrue(old.pending().isEmpty)

        let upgraded = makeStore(build: "101")
        GroundTruthStub.reply = .saved
        let outcome = try await sync(upgraded).pushPending()

        XCTAssertEqual(outcome.uploaded, 1)
        XCTAssertTrue(upgraded.pending().isEmpty)
        XCTAssertTrue(upgraded.quarantined().isEmpty)
    }

    func testACredentialTheServerRefusesIsReportedAsSignedOut() async throws {
        let store = makeStore()
        store.upsert(makeLabel(startTs: 1_000))
        GroundTruthStub.status = 401

        let outcome = try await sync(store).pushPending()

        XCTAssertEqual(outcome.blocked, .signedOut)
        XCTAssertEqual(store.pending().count, 1)
    }

    func testAReplyThatIsNotTheRoutesJSONIsTriedAgainNotTrusted() async {
        let store = makeStore()
        store.upsert(makeLabel(startTs: 1_000))
        GroundTruthStub.reply = .garbage

        do {
            _ = try await sync(store).pushPending()
            XCTFail("expected a thrown error")
        } catch {
            XCTAssertTrue(error is ActivityGroundTruthSyncError)
        }
        XCTAssertEqual(store.pending().count, 1)
    }

    func testServerErrorKeepsEverythingQueued() async {
        let store = makeStore()
        store.upsert(makeLabel(startTs: 1_000))
        GroundTruthStub.status = 500

        do {
            _ = try await sync(store).pushPending()
            XCTFail("expected a thrown error")
        } catch {
            XCTAssertTrue(error is ActivityGroundTruthSyncError)
        }
        XCTAssertEqual(store.pending().count, 1)
    }

    func testNoCloudAddressIsReportedAsSuch() async throws {
        let store = makeStore()
        store.upsert(makeLabel(startTs: 1_000))
        let noAddress = ActivityGroundTruthCloudSync(
            store: store, session: GroundTruthStub.session(), endpoint: { nil },
            identity: {
                CloudPushIdentity(ownerId: "11111111-1111-4111-8111-111111111111",
                                  sourceId: "22222222-2222-4222-8222-222222222222",
                                  tokenId: "t", uploadToken: "noop_x")
            })

        let outcome = try await noAddress.pushPending()

        XCTAssertEqual(outcome.blocked, .noServer)
        XCTAssertTrue(GroundTruthStub.requests.isEmpty)
    }
}

/// Answers the ground-truth-labels route from memory so the real request path runs with no network.
private final class GroundTruthStub: URLProtocol {
    enum Reply { case saved, rejected, invalid, echo, silent, garbage }

    static var status = 200
    static var reply = Reply.saved
    static var requests: [URLRequest] = []
    static var bodies: [Data] = []

    static func reset() {
        status = 200; reply = .saved; requests = []; bodies = []
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GroundTruthStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(of: request)
        Self.requests.append(request)
        Self.bodies.append(body)

        let keys = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
            .flatMap { $0["labels"] as? [[String: Any]] }?
            .compactMap { $0["label_key"] as? String } ?? []
        let rows = keys.map { ["label_key": $0] }
        let payload: [String: Any]
        switch Self.reply {
        case .saved, .echo: payload = ["saved": rows, "ignored": [], "rejected": []]
        case .rejected: payload = ["saved": [], "ignored": [], "rejected": rows]
        case .invalid:
            payload = ["saved": [], "ignored": [], "rejected": keys.map { ["label_key": $0, "reason": "invalid_posture"] }]
        case .silent: payload = ["saved": [], "ignored": [], "rejected": []]
        case .garbage: payload = [:]
        }
        let data = Self.reply == .garbage
            ? Data("<html>sign in to the wifi</html>".utf8)
            : (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let http = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                   headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var out = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read <= 0 { break }
            out.append(buffer, count: read)
        }
        return out
    }
}
