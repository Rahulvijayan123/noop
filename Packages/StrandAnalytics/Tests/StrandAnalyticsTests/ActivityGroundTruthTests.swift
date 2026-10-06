import XCTest
@testable import StrandAnalytics

/// The ground-truth label contract: vocabulary validation, key derivation, cue/sensor-quality
/// coding, partial multi-head labels, and the shipped calibration protocol. Everything here is
/// pure value-type behaviour with no I/O (spec §15.1).
final class ActivityGroundTruthTests: XCTestCase {

    private let t0 = 1_760_000_000

    private func label(over: @escaping (inout ActivityGroundTruthLabel) -> Void = { _ in }
    ) -> ActivityGroundTruthLabel {
        var l = ActivityGroundTruthLabel(source: .guided, sessionId: "sess-1", startTs: t0, endTs: t0 + 45,
                                          repetition: 1, protocolVersion: "calibration-v1",
                                          posture: PostureClass.seatedLikely.rawValue)
        over(&l)
        return l
    }

    // MARK: - Sources and strength

    func testSourceRawValuesAreTheWireCodes() {
        XCTAssertEqual(ActivityGroundTruthSource.guided.rawValue, "guided")
        XCTAssertEqual(ActivityGroundTruthSource.stretchFeedback.rawValue, "stretch_feedback")
        XCTAssertEqual(ActivityGroundTruthSource.imported.rawValue, "imported")
        XCTAssertEqual(Set(ActivityGroundTruthSource.allCases.map(\.rawValue)), ["guided", "stretch_feedback", "imported"])
    }

    func testStrongVersusWeakLabels() {
        XCTAssertTrue(label().isStrong, "a confident guided label is strong")
        XCTAssertFalse(label { $0.userUnsure = true }.isStrong, "an unsure guided label is weak")
        XCTAssertFalse(label { $0.source = .stretchFeedback }.isStrong, "a stretch correction is weak")
        XCTAssertFalse(label { $0.source = .imported }.isStrong, "an imported label is weak")
    }

    // MARK: - Label keys

    func testLabelKeyNamesSourceSessionStartAndRepetition() {
        XCTAssertEqual(ActivityGroundTruthLabel.labelKey(source: .guided, sessionId: "sess-1", stretchKey: nil,
                                                         startTs: t0, repetition: 2),
                       "guided:sess-1:\(t0):2")
        XCTAssertEqual(ActivityGroundTruthLabel.labelKey(source: .guided, sessionId: "sess-1", stretchKey: nil,
                                                         startTs: t0, repetition: nil),
                       "guided:sess-1:\(t0)")
        XCTAssertEqual(ActivityGroundTruthLabel.labelKey(source: .stretchFeedback, sessionId: nil,
                                                         stretchKey: "activity_context:\(t0)",
                                                         startTs: t0, repetition: nil),
                       "stretch_feedback:activity_context:\(t0):\(t0)")
        // The session wins when both are present: a guided label always names its session.
        XCTAssertEqual(ActivityGroundTruthLabel.labelKey(source: .guided, sessionId: "s", stretchKey: "k",
                                                         startTs: t0, repetition: nil), "guided:s:\(t0)")
    }

    func testConvenienceInitDerivesTheKeySoItCannotDesync() {
        let l = label()
        XCTAssertEqual(l.labelKey, "guided:sess-1:\(t0):1")
    }

    func testLabelKeyCharsetIsTheServerColumnCharset() {
        XCTAssertTrue(ActivityGroundTruthLabel.isValidLabelKey("guided:sess-1:\(t0):2"))
        XCTAssertTrue(ActivityGroundTruthLabel.isValidLabelKey("a"))
        XCTAssertTrue(ActivityGroundTruthLabel.isValidLabelKey(String(repeating: "a", count: 96)))
        XCTAssertFalse(ActivityGroundTruthLabel.isValidLabelKey(""), "empty is not a key")
        XCTAssertFalse(ActivityGroundTruthLabel.isValidLabelKey(String(repeating: "a", count: 97)), "too long")
        XCTAssertFalse(ActivityGroundTruthLabel.isValidLabelKey("guided sess"), "spaces are not in the charset")
        XCTAssertFalse(ActivityGroundTruthLabel.isValidLabelKey("guided/sess"), "slashes are not in the charset")
    }

    // MARK: - Validation

    func testValidLabelPassesValidation() {
        XCTAssertNotNil(label().validated())
    }

    func testPartialMultiHeadLabelsAreValidUnknownIsNeverInvented() {
        // Only one head known (spec §3.3): posture = seated, everything else unknown.
        let partial = ActivityGroundTruthLabel(source: .guided, sessionId: "s", startTs: t0, endTs: t0 + 30,
                                                posture: PostureClass.seatedLikely.rawValue)
        let validated = partial.validated()
        XCTAssertNotNil(validated)
        XCTAssertNil(validated?.locomotion)
        XCTAssertNil(validated?.armBehavior)
        XCTAssertNil(validated?.semanticTag)
        // Every head nil (a pure transition label) is also valid.
        let transition = ActivityGroundTruthLabel(source: .guided, sessionId: "s", startTs: t0, endTs: t0 + 20,
                                                   transitionKind: "sit_to_stand", transitionTs: t0 + 8)
        XCTAssertNotNil(transition.validated())
    }

    func testBadVocabularyIsRejectedPerHead() {
        XCTAssertNil(label { $0.posture = "sitting_pretty" }.validated())
        XCTAssertNil(label { $0.locomotion = "sprint" }.validated())
        XCTAssertNil(label { $0.armBehavior = "keyboard" }.validated())
        XCTAssertNil(label { $0.semanticTag = "cooking" }.validated())
        // Prediction transition kinds (_like) are NOT ground-truth kinds.
        XCTAssertNil(label { $0.transitionKind = "sit_to_stand_like" }.validated())
        XCTAssertNil(label { $0.transitionKind = "hop" }.validated())
        // The vocabulary check names the offending head.
        XCTAssertThrowsError(try ActivityGroundTruthLabel.vocabularyCheck(
            posture: "nope", locomotion: nil, armBehavior: nil, transitionKind: nil, semanticTag: nil)) { error in
            guard case ActivityGroundTruthLabel.CodingError.badVocabulary(let detail) = error else {
                return XCTFail("expected badVocabulary, got \(error)")
            }
            XCTAssertTrue(detail.contains("posture"), "the error names the head: \(detail)")
        }
    }

    func testEveryCanonicalHeadCodeValidates() {
        for code in PostureClass.allCases.map(\.rawValue) {
            XCTAssertNotNil(label { $0.posture = code }.validated(), code)
        }
        for code in LocomotionClass.allCases.map(\.rawValue) {
            XCTAssertNotNil(label { $0.locomotion = code }.validated(), code)
        }
        for code in ArmBehaviorClass.allCases.map(\.rawValue) {
            XCTAssertNotNil(label { $0.armBehavior = code }.validated(), code)
        }
        for code in ["sit_to_stand", "stand_to_sit", "lying_down", "getting_up",
                     "walk_start", "walk_stop", "run_start", "run_stop"] {
            XCTAssertNotNil(label { $0.transitionKind = code }.validated(), code)
        }
        for code in ["typing", "mouse_work", "phone_use", "writing", "eating", "reading",
                     "fidgeting", "desk_work"] {
            XCTAssertNotNil(label { $0.semanticTag = code }.validated(), code)
        }
    }

    func testTimestampSanityIsEnforced() {
        XCTAssertNil(label { $0.endTs = self.t0 }.validated(), "end must be after start")
        XCTAssertNil(label { $0.endTs = self.t0 - 1 }.validated())
        XCTAssertNil(label { $0.endTs = self.t0 + 86_401 }.validated(), "at most one day long")
        XCTAssertNil(label { $0.startTs = 946_684_800; $0.endTs = 946_684_800 + 10 }.validated(),
                     "start must be after the 2000 epoch")
    }

    func testTransitionTsMustSitInsideTheInterval() {
        XCTAssertNotNil(label { $0.transitionKind = "sit_to_stand"; $0.transitionTs = self.t0 + 5 }.validated())
        XCTAssertNil(label { $0.transitionKind = "sit_to_stand"; $0.transitionTs = self.t0 - 1 }.validated())
        XCTAssertNil(label { $0.transitionKind = "sit_to_stand"; $0.transitionTs = self.t0 + 46 }.validated())
    }

    func testLabelConfidenceBoundsAndNoteCleaning() {
        XCTAssertNotNil(label { $0.labelConfidence = 0 }.validated())
        XCTAssertNotNil(label { $0.labelConfidence = 1 }.validated())
        XCTAssertNil(label { $0.labelConfidence = 1.2 }.validated())
        XCTAssertNil(label { $0.labelConfidence = -0.1 }.validated())
        // Note cleaning runs in the inits (mirroring StretchFeedback.cleaned), so the notes go in there.
        func made(_ note: String?) -> ActivityGroundTruthLabel {
            ActivityGroundTruthLabel(source: .guided, sessionId: "s", startTs: t0, endTs: t0 + 30, note: note)
        }
        XCTAssertEqual(made("   ").note, nil, "blank notes are dropped")
        XCTAssertEqual(made("  a walk  ").note, "a walk", "notes are trimmed")
        XCTAssertEqual(made(String(repeating: "x", count: 400)).note?.count,
                      ActivityGroundTruthLabel.maxNoteLength, "notes are capped")
        // A non-finite confidence is dropped by the didSet on mutation (JSON cannot hold it), so the
        // label stays valid with no confidence rather than being rejected.
        var finite = made(nil)
        finite.labelConfidence = .infinity
        XCTAssertNil(finite.labelConfidence)
        XCTAssertNotNil(finite.validated())
    }

    // MARK: - Sync bookkeeping

    func testNeedsSyncFollowsTheLastWriterWinsClock() {
        let fresh = label()
        XCTAssertTrue(fresh.needsSync, "never-sent labels need sync")
        var sent = fresh
        sent.syncedAt = sent.updatedAt
        XCTAssertFalse(sent.needsSync)
        var edited = sent
        edited.note = "edited"
        edited.updatedAt = sent.updatedAt.addingTimeInterval(1)
        XCTAssertTrue(edited.needsSync, "an edit after the send re-queues the label")
    }

    // MARK: - Coding

    func testCodingRoundTripsEveryFieldWithTheWireKeys() throws {
        var l = label()
        l.sessionId = "session-uuid"
        l.deviceId = "local-whoop"
        l.externalDeviceId = "whoop-A1B2"
        l.locomotion = LocomotionClass.walking.rawValue
        l.armBehavior = ArmBehaviorClass.repetitiveHandMotion.rawValue
        l.semanticTag = "typing"
        l.transitionKind = nil
        l.labelConfidence = 0.9
        l.userUnsure = false
        l.note = "afternoon block"
        l.cueContext = ActivityGroundTruthCueContext(instructionTs: t0 - 10, countdownStartTs: t0 - 3,
                                                     cueStartTs: t0, cueStopTs: t0 + 45,
                                                     intervalStartTs: t0 + 2, intervalEndTs: t0 + 43)
        l.sensorQuality = ActivityGroundTruthSensorQuality(expectedSeconds: 41, coveredSeconds: 39,
                                                            sampleRateHz: 100, firstTs: t0 + 2,
                                                            lastTs: t0 + 42,
                                                            gaps: [ActivityGroundTruthGap(startTs: t0 + 10, endTs: t0 + 12)])
        l.rawRefs = [ActivityGroundTruthRawRef(storeSessionId: "activity-local-whoop", startTs: t0,
                                               endTs: t0 + 45, sampleRateHz: 100, coveredSeconds: 39)]
        l.modelContextAtLabelTime = ["decoder": "hsmm-1.3", "display": "Desk sitting"]
        l.appVersion = "11.9.0"
        l.appBuild = "432"
        // Whole-second dates: the wire form carries milliseconds, so a sub-millisecond Date would
        // not survive the round trip for reasons that have nothing to do with the coding keys.
        l.createdAt = Date(timeIntervalSince1970: 1_791_200_000)
        l.updatedAt = Date(timeIntervalSince1970: 1_791_200_001)

        let data = try JSONEncoder().encode(l)
        let back = try JSONDecoder().decode(ActivityGroundTruthLabel.self, from: data)
        XCTAssertEqual(back, l)

        // The wire keys are the snake_case column names (spot-check a sample of them).
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["label_key"] as? String, l.labelKey)
        XCTAssertEqual(object["start_ts"] as? Int, l.startTs)
        XCTAssertEqual(object["end_ts"] as? Int, l.endTs)
        XCTAssertEqual(object["arm_behavior"] as? String, l.armBehavior)
        XCTAssertEqual(object["semantic_tag"] as? String, l.semanticTag)
        XCTAssertEqual(object["user_unsure"] as? Bool, false)
        XCTAssertEqual(object["protocol_version"] as? String, "calibration-v1")
        let cue = try XCTUnwrap(object["cue_context"] as? [String: Any])
        XCTAssertEqual(cue["cue_start_ts"] as? Int, t0)
        XCTAssertEqual(cue["interval_end_ts"] as? Int, t0 + 43)
        let quality = try XCTUnwrap(object["sensor_quality"] as? [String: Any])
        XCTAssertEqual(quality["covered_seconds"] as? Int, 39)
        XCTAssertEqual(quality["evaluation_ready"] as? Bool, false, "a gapped label is not evaluation-ready")
        let refs = try XCTUnwrap(object["raw_refs"] as? [[String: Any]])
        XCTAssertEqual(refs.first?["store_session_id"] as? String, "activity-local-whoop")
        let modelContext = try XCTUnwrap(object["model_context_at_label_time"] as? [String: String])
        XCTAssertEqual(modelContext["decoder"], "hsmm-1.3")
    }

    func testDecodingOlderDocumentsWithoutDerivedQualityFields() throws {
        // A sensor_quality without coverage_ratio/evaluation_ready (older persisted form) recomputes them.
        let quality = """
        {"expected_seconds": 10, "covered_seconds": 10, "sample_rate_hz": 100,
         "first_ts": \(t0), "last_ts": \(t0 + 10), "gaps": []}
        """
        let json = """
        {"id": "5f0d3f0e-8f5a-4c8e-9d52-7d7a7f0c2a11",
         "label_key": "guided:sess-1:\(t0):1", "source": "guided",
         "start_ts": \(t0), "end_ts": \(t0 + 45), "posture": "seated_likely",
         "created_at": "2026-10-06T16:00:00.000Z", "updated_at": "2026-10-06T16:00:00.000Z",
         "sensor_quality": \(quality)}
        """
        let back = try JSONDecoder().decode(ActivityGroundTruthLabel.self, from: Data(json.utf8))
        XCTAssertEqual(back.sensorQuality?.coverageRatio ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(back.sensorQuality?.evaluationReady, true)
    }

    // MARK: - Sensor quality semantics

    func testSensorQualityDerivesCoverageAndReadiness() {
        let full = ActivityGroundTruthSensorQuality(expectedSeconds: 45, coveredSeconds: 45, sampleRateHz: 100)
        XCTAssertEqual(full.coverageRatio, 1, accuracy: 1e-9)
        XCTAssertTrue(full.evaluationReady)
        let partial = ActivityGroundTruthSensorQuality(expectedSeconds: 45, coveredSeconds: 30, sampleRateHz: 100,
                                                       gaps: [ActivityGroundTruthGap(startTs: t0, endTs: t0 + 15)])
        XCTAssertEqual(partial.coverageRatio, 30.0 / 45.0, accuracy: 1e-9)
        XCTAssertFalse(partial.evaluationReady)
        let empty = ActivityGroundTruthSensorQuality(expectedSeconds: 0, coveredSeconds: 0, sampleRateHz: 100)
        XCTAssertEqual(empty.coverageRatio, 0)
        XCTAssertFalse(empty.evaluationReady, "no expected evidence is never ready")
    }

    // MARK: - The shipped protocol

    func testV1ProtocolIsWellFormedAndVersioned() {
        let p = ActivityCalibrationProtocols.v1
        XCTAssertEqual(p.version, "calibration-v1")
        XCTAssertGreaterThanOrEqual(p.tasks.count, 15)
        var taskIds = Set<String>()
        for task in p.tasks {
            XCTAssertTrue(taskIds.insert(task.id).inserted, "task ids are unique: \(task.id)")
            XCTAssertGreaterThan(task.durationSeconds, 0)
            XCTAssertGreaterThanOrEqual(task.repetitions, 1)
            XCTAssertGreaterThanOrEqual(task.restSeconds, 0)
            XCTAssertGreaterThanOrEqual(task.guardSeconds, 0)
            // Every task claims at least one head or a transition kind.
            let claimsSomething = task.posture != nil || task.locomotion != nil || task.armBehavior != nil
                || task.semanticTag != nil || task.transitionKind != nil
            XCTAssertTrue(claimsSomething, "\(task.id) labels something")
            // A transition label never claims a persistent head over the whole interval.
            if task.transitionKind != nil {
                XCTAssertNil(task.posture, "\(task.id): heads stay nil across a transition interval")
                XCTAssertNil(task.locomotion)
                XCTAssertNil(task.armBehavior)
            }
            // Head codes are canonical.
            XCTAssertNoThrow(try ActivityGroundTruthLabel.vocabularyCheck(
                posture: task.posture, locomotion: task.locomotion, armBehavior: task.armBehavior,
                transitionKind: task.transitionKind, semanticTag: task.semanticTag))
        }
    }

    func testV1ProtocolMatchesTheSpecSevens() {
        let p = ActivityCalibrationProtocols.v1
        var found: [String: ActivityCalibrationTask] = [:]
        for t in p.tasks { found[t.id] = t }
        func task(_ id: String) -> ActivityCalibrationTask {
            guard let t = found[id] else {
                XCTFail("missing task \(id)")
                return found.values.first ?? p.tasks[0]
            }
            return t
        }
        // Static / posture: 45 s × 3 each.
        XCTAssertEqual(task("posture.sitting-quietly").durationSeconds, 45)
        XCTAssertEqual(task("posture.sitting-quietly").repetitions, 3)
        XCTAssertEqual(task("posture.standing-quietly").repetitions, 3)
        XCTAssertEqual(task("posture.lying-down").repetitions, 3)
        // Desk group durations from spec §7.4.
        XCTAssertEqual(task("desk.desk-work").durationSeconds, 60)
        XCTAssertEqual(task("desk.typing").durationSeconds, 45)
        XCTAssertEqual(task("desk.writing-mouse").durationSeconds, 45)
        XCTAssertEqual(task("desk.fidgeting-seated").durationSeconds, 30)
        XCTAssertEqual(task("desk.phone-use").durationSeconds, 45)
        XCTAssertEqual(task("desk.phone-use").repetitions, 2)
        // Locomotion.
        XCTAssertEqual(task("locomotion.walking").durationSeconds, 90)
        XCTAssertEqual(task("locomotion.walking").repetitions, 2)
        XCTAssertEqual(task("locomotion.brisk-walking").repetitions, 2)
        XCTAssertEqual(task("locomotion.cycling").repetitions, 1)
        // Transitions: 10 reps each with stable pre/post state.
        for id in ["transition.sit-to-stand", "transition.stand-to-sit", "transition.lying-down",
                   "transition.getting-up", "transition.walk-start", "transition.walk-stop"] {
            XCTAssertEqual(task(id).repetitions, 10, id)
            XCTAssertEqual(task(id).preStateSeconds, 8, id)
            XCTAssertEqual(task(id).postStateSeconds, 8, id)
        }
    }

    func testV1ProtocolGroupsInOrderAndInstructionsTeachVariation() {
        let p = ActivityCalibrationProtocols.v1
        let categories = p.tasks.map(\.category)
        XCTAssertEqual(Array(categories.prefix(3)), ["posture", "posture", "posture"])
        XCTAssertTrue(categories.contains("desk"))
        XCTAssertTrue(categories.contains("locomotion"))
        XCTAssertEqual(Array(categories.suffix(6)), Array(repeating: "transition", count: 6))
        for task in p.tasks {
            let variation = task.instructions.lowercased()
            let mentions = ["vary", "alternate", "natural", "switch", "relax"].contains { variation.contains($0) }
            XCTAssertTrue(mentions, "\(task.id) teaches natural variation, not a scripted pose")
        }
    }

    func testProtocolCodingRoundTrips() throws {
        let data = try JSONEncoder().encode(ActivityCalibrationProtocols.v1)
        let back = try JSONDecoder().decode(ActivityCalibrationProtocolModel.self, from: data)
        XCTAssertEqual(back.version, ActivityCalibrationProtocols.v1.version)
        XCTAssertEqual(back.tasks, ActivityCalibrationProtocols.v1.tasks)
    }
}
