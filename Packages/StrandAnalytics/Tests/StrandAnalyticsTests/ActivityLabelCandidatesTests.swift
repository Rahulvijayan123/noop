import XCTest
@testable import StrandAnalytics

/// The stretch-correction → ontology-head mapping and the pure candidate-selection rule behind the
/// "Help improve activity detection" queue. Both live on plain value types with no I/O, so the whole
/// behaviour is pinned here without a store, a clock or a device.
final class ActivityLabelCandidatesTests: XCTestCase {

    // MARK: - StretchCorrection → heads

    func testEveryCorrectionMapsToTheCanonicalPartialHeads() {
        // The full table from the ground-truth contract §6. nil = unknown: the wearer said nothing about
        // that head, and a partial label must never invent a class the person did not name.
        let table: [(StretchCorrection, String?, String?, String?)] = [
            (.sitting, "seated_likely", nil, nil),
            (.standing, "upright_stationary", nil, nil),
            (.lyingDown, "recumbent", "stationary", nil),
            (.asleep, "recumbent", "stationary", "quiet"),
            (.walking, nil, "walking", nil),
            (.briskWalking, nil, "brisk_walking", nil),
            (.running, nil, "running", nil),
            (.stairs, nil, "stairs", nil),
            (.cycling, nil, "cycling", nil),
            (.inVehicle, nil, "vehicle_motion", nil),
            (.deskWork, "seated_likely", nil, "desk_like"),
            (.typing, "seated_likely", nil, "repetitive_hand_motion"),
            (.fidgeting, "seated_likely", nil, "fidgeting"),
            (.exercise, nil, nil, "exercise_motion"),
            (.otherMovement, nil, nil, nil),
            (.notWearing, nil, nil, nil),
            (.other, nil, nil, nil),
        ]
        for (correction, posture, locomotion, arm) in table {
            let heads = StretchCorrection.partialHeads(for: correction)
            XCTAssertEqual(heads.posture, posture, "\(correction.rawValue).posture")
            XCTAssertEqual(heads.locomotion, locomotion, "\(correction.rawValue).locomotion")
            XCTAssertEqual(heads.armBehavior, arm, "\(correction.rawValue).arm_behavior")
        }
    }

    func testTheCorrectionCodesAndTitlesMatchTheContract() {
        XCTAssertEqual(Set(StretchCorrection.allCases.map(\.rawValue)),
                       ["sitting", "standing", "lying_down", "asleep", "walking", "brisk_walking", "running",
                        "stairs", "cycling", "in_vehicle", "desk_work", "typing", "fidgeting", "exercise",
                        "other_movement", "not_wearing", "other"])
        XCTAssertEqual(StretchCorrection.briskWalking.rawValue, "brisk_walking")
        XCTAssertEqual(StretchCorrection.stairs.rawValue, "stairs")
        XCTAssertEqual(StretchCorrection.deskWork.rawValue, "desk_work")
        XCTAssertEqual(StretchCorrection.typing.rawValue, "typing")
        XCTAssertEqual(StretchCorrection.fidgeting.rawValue, "fidgeting")
        XCTAssertEqual(StretchCorrection.briskWalking.title, "Brisk walking")
        XCTAssertEqual(StretchCorrection.stairs.title, "Stairs")
        XCTAssertEqual(StretchCorrection.deskWork.title, "Desk work")
        XCTAssertEqual(StretchCorrection.typing.title, "Typing")
        XCTAssertEqual(StretchCorrection.fidgeting.title, "Fidgeting")
        // The pre-existing codes must not have moved: the wire values are pinned.
        XCTAssertEqual(StretchCorrection.inVehicle.rawValue, "in_vehicle")
        XCTAssertEqual(StretchCorrection.lyingDown.rawValue, "lying_down")
        XCTAssertEqual(StretchCorrection.otherMovement.rawValue, "other_movement")
        XCTAssertEqual(StretchCorrection.notWearing.rawValue, "not_wearing")
    }

    // MARK: - Reason vocabulary is stable

    func testReasonStringsAreTheDocumentedStableVocabulary() {
        XCTAssertEqual(ActivityLabelCandidateSelector.reasonUncertainty, "uncertainty")
        XCTAssertEqual(ActivityLabelCandidateSelector.reasonDisagreement, "disagreement")
        XCTAssertEqual(ActivityLabelCandidateSelector.reasonCoverage, "coverage")
    }

    // MARK: - Uncertainty

    func testHighOverallUncertaintyFiresUncertainty() {
        let input = ActivityCandidateStretchInput(startTs: 100, endTs: 400,
                                                  overallUncertainty: 0.5,
                                                  decodedLocomotion: "walking", decodedPosture: "unknown")
        XCTAssertTrue(ActivityLabelCandidateSelector.firesUncertainty(input))
    }

    func testLowHeadConfidenceFiresUncertainty() {
        let input = ActivityCandidateStretchInput(startTs: 100, endTs: 400,
                                                  headConfidence: (posture: 0.9, locomotion: 0.3, armBehavior: 0.8),
                                                  decodedLocomotion: "walking", decodedPosture: "seated_likely")
        XCTAssertTrue(ActivityLabelCandidateSelector.firesUncertainty(input))
    }

    func testAbstainedDecoderHeadFiresUncertainty() {
        XCTAssertTrue(ActivityLabelCandidateSelector.firesUncertainty(
            ActivityCandidateStretchInput(startTs: 100, endTs: 400, decodedLocomotion: nil, decodedPosture: "seated_likely")))
        XCTAssertTrue(ActivityLabelCandidateSelector.firesUncertainty(
            ActivityCandidateStretchInput(startTs: 100, endTs: 400, decodedLocomotion: "unknown", decodedPosture: "seated_likely")))
    }

    func testSmallTop2MarginFiresUncertainty() {
        let input = ActivityCandidateStretchInput(startTs: 100, endTs: 400,
                                                  decodedLocomotion: "walking", decodedPosture: "seated_likely",
                                                  hartWindowTop2: (first: "walking", p1: 0.52, second: "stationary", p2: 0.40))
        XCTAssertTrue(ActivityLabelCandidateSelector.firesUncertainty(input))
    }

    func testConfidentStretchWithoutAbstentionDoesNotFireUncertainty() {
        let input = ActivityCandidateStretchInput(startTs: 100, endTs: 400,
                                                  overallUncertainty: 0.2,
                                                  headConfidence: (posture: 0.8, locomotion: 0.9, armBehavior: 0.7),
                                                  decodedLocomotion: "walking", decodedPosture: "seated_likely",
                                                  hartWindowTop2: (first: "walking", p1: 0.9, second: "stationary", p2: 0.08))
        XCTAssertFalse(ActivityLabelCandidateSelector.firesUncertainty(input))
    }

    func testAStretchWithNoReadingsAtAllIsAnAbstentionAndFiresUncertainty() {
        // Every head missing means the decoder said nothing: that is exactly when a label helps most.
        let input = ActivityCandidateStretchInput(startTs: 100, endTs: 400)
        XCTAssertTrue(ActivityLabelCandidateSelector.firesUncertainty(input))
    }

    // MARK: - Disagreement

    func testMajorityHARTClashFiresDisagreement() {
        let input = ActivityCandidateStretchInput(startTs: 100, endTs: 400,
                                                  hartWindowLabels: ["stationary", "stationary", "walking"],
                                                  decodedLocomotion: "walking", decodedPosture: "seated_likely")
        // 2 of 3 windows claim stationary against the decoder's walking: a clear clash.
        XCTAssertTrue(ActivityLabelCandidateSelector.firesDisagreement(input))
    }

    func testMinorityHARTClashDoesNotFireDisagreement() {
        let input = ActivityCandidateStretchInput(startTs: 100, endTs: 400,
                                                  hartWindowLabels: ["stationary", "walking", "walking"],
                                                  decodedLocomotion: "walking", decodedPosture: "seated_likely")
        XCTAssertFalse(ActivityLabelCandidateSelector.firesDisagreement(input))
    }

    func testExactlyHalfOfTheWindowsDisagreeingFiresDisagreement() {
        let input = ActivityCandidateStretchInput(startTs: 100, endTs: 400,
                                                  hartWindowLabels: ["stationary", "walking"],
                                                  decodedLocomotion: "walking", decodedPosture: "seated_likely")
        XCTAssertTrue(ActivityLabelCandidateSelector.firesDisagreement(input))
    }

    func testUnknownWindowsAreIgnoredNotCounted() {
        // Two unknown windows abstain; the one stationary window still disagrees 1/1.
        let input = ActivityCandidateStretchInput(startTs: 100, endTs: 400,
                                                  hartWindowLabels: ["unknown", "unknown", "stationary"],
                                                  decodedLocomotion: "walking", decodedPosture: "seated_likely")
        XCTAssertTrue(ActivityLabelCandidateSelector.firesDisagreement(input))
    }

    func testDecoderAbstentionNeverFiresDisagreement() {
        // An abstaining decoder has no claim to clash with; its abstention is an uncertainty signal instead.
        let input = ActivityCandidateStretchInput(startTs: 100, endTs: 400,
                                                  hartWindowLabels: ["stationary", "stationary"],
                                                  decodedLocomotion: nil, decodedPosture: "seated_likely")
        XCTAssertFalse(ActivityLabelCandidateSelector.firesDisagreement(input))
    }

    func testOtherMovementFoldsIntoOtherSoTheVocabulariesCompare() {
        let input = ActivityCandidateStretchInput(startTs: 100, endTs: 400,
                                                  hartWindowLabels: ["other_movement", "other_movement"],
                                                  decodedLocomotion: "other", decodedPosture: "seated_likely")
        XCTAssertFalse(ActivityLabelCandidateSelector.firesDisagreement(input))
        let clash = ActivityCandidateStretchInput(startTs: 100, endTs: 400,
                                                  hartWindowLabels: ["other_movement", "other_movement"],
                                                  decodedLocomotion: "walking", decodedPosture: "seated_likely")
        XCTAssertTrue(ActivityLabelCandidateSelector.firesDisagreement(clash))
    }

    // MARK: - Coverage

    func testTheSmallestClassShareFiresCoverage() {
        // walking 80%, stairs 20%: stairs is the smallest share and <= 0.25 → coverage.
        let walking = ActivityCandidateStretchInput(startTs: 100, endTs: 900, predictedClass: "walking",
                                                    decodedLocomotion: "walking", decodedPosture: "seated_likely")
        let stairs = ActivityCandidateStretchInput(startTs: 1000, endTs: 1200, predictedClass: "stairs",
                                                   decodedLocomotion: "stairs", decodedPosture: "seated_likely")
        let shares = ActivityLabelCandidateSelector.coverageShareByClass([walking, stairs])
        XCTAssertEqual(shares["walking"]!, 0.8, accuracy: 1e-9)
        XCTAssertEqual(shares["stairs"]!, 0.2, accuracy: 1e-9)
        XCTAssertFalse(ActivityLabelCandidateSelector.firesCoverage(walking, shares: shares))
        XCTAssertTrue(ActivityLabelCandidateSelector.firesCoverage(stairs, shares: shares))
    }

    func testAWellRepresentedSmallestClassDoesNotFireCoverage() {
        // A 49/51 split has no under-represented class: the smallest share is above the coverage cap.
        let a = ActivityCandidateStretchInput(startTs: 100, endTs: 490, predictedClass: "walking",
                                              decodedLocomotion: "walking", decodedPosture: "seated_likely")
        let b = ActivityCandidateStretchInput(startTs: 600, endTs: 1110, predictedClass: "stationary",
                                              decodedLocomotion: "stationary", decodedPosture: "seated_likely")
        let shares = ActivityLabelCandidateSelector.coverageShareByClass([a, b])
        XCTAssertFalse(ActivityLabelCandidateSelector.firesCoverage(a, shares: shares))
        XCTAssertFalse(ActivityLabelCandidateSelector.firesCoverage(b, shares: shares))
    }

    func testOnlyTheSmallestShareFiresCoverageAmongSeveralSmallClasses() {
        // shares 0.7 / 0.2 / 0.1: only the 0.1 class is the smallest, even though 0.2 is also small.
        let big = ActivityCandidateStretchInput(startTs: 0, endTs: 700, predictedClass: "walking")
        let mid = ActivityCandidateStretchInput(startTs: 0, endTs: 200, predictedClass: "stationary")
        let rare = ActivityCandidateStretchInput(startTs: 0, endTs: 100, predictedClass: "cycling")
        let shares = ActivityLabelCandidateSelector.coverageShareByClass([big, mid, rare])
        XCTAssertFalse(ActivityLabelCandidateSelector.firesCoverage(big, shares: shares))
        XCTAssertFalse(ActivityLabelCandidateSelector.firesCoverage(mid, shares: shares))
        XCTAssertTrue(ActivityLabelCandidateSelector.firesCoverage(rare, shares: shares))
    }

    func testInputsWithoutAClassNeverFireCoverage() {
        let labelled = ActivityCandidateStretchInput(startTs: 0, endTs: 700, predictedClass: "walking")
        let unclassified = ActivityCandidateStretchInput(startTs: 0, endTs: 300, predictedClass: nil)
        let shares = ActivityLabelCandidateSelector.coverageShareByClass([labelled, unclassified])
        XCTAssertEqual(shares.count, 1)
        XCTAssertFalse(ActivityLabelCandidateSelector.firesCoverage(unclassified, shares: shares))
    }

    // MARK: - Selection

    private func stretch(_ start: Int, _ end: Int, uncertainty: Double? = 0.1,
                         locomotion: String? = "walking", posture: String? = "seated_likely",
                         cls: String? = "walking") -> ActivityCandidateStretchInput {
        ActivityCandidateStretchInput(startTs: start, endTs: end, predictedClass: cls,
                                      overallUncertainty: uncertainty,
                                      headConfidence: (posture: 0.8, locomotion: 0.9, armBehavior: 0.7),
                                      hartWindowLabels: [locomotion ?? "walking"],
                                      decodedLocomotion: locomotion, decodedPosture: posture)
    }

    func testSelectionRanksByPriorityThenRecencyAndIsDeterministic() {
        // Candidate A: uncertain (0.6) but confident heads → uncertainty only → 0.6.
        let a = ActivityCandidateStretchInput(startTs: 1_000, endTs: 1_400, predictedClass: "walking",
                                              overallUncertainty: 0.6,
                                              headConfidence: (posture: 0.8, locomotion: 0.9, armBehavior: 0.7),
                                              hartWindowLabels: ["walking"],
                                              decodedLocomotion: "walking", decodedPosture: "seated_likely")
        // Candidate B: decoder says walking, all HART windows stationary → disagreement only → 0.4.
        let b = ActivityCandidateStretchInput(startTs: 2_000, endTs: 2_300, predictedClass: "walking",
                                              overallUncertainty: 0.1,
                                              headConfidence: (posture: 0.8, locomotion: 0.9, armBehavior: 0.7),
                                              hartWindowLabels: ["stationary", "stationary"],
                                              decodedLocomotion: "walking", decodedPosture: "seated_likely")
        // Candidate C: rare class cycling, smallest share → coverage only → 0.3.
        let c = ActivityCandidateStretchInput(startTs: 3_000, endTs: 3_100, predictedClass: "cycling",
                                              overallUncertainty: 0.1,
                                              headConfidence: (posture: 0.8, locomotion: 0.9, armBehavior: 0.7),
                                              hartWindowLabels: ["cycling"],
                                              decodedLocomotion: "cycling", decodedPosture: "seated_likely")

        let first = ActivityLabelCandidateSelector.select(from: [a, b, c])
        XCTAssertEqual(first.map(\.id), ["activity_context:1000", "activity_context:2000", "activity_context:3000"])
        XCTAssertEqual(first.map(\.reasons), [["uncertainty"], ["disagreement"], ["coverage"]])
        XCTAssertEqual(first.map(\.priority), [0.6, 0.4, 0.3])
        XCTAssertEqual(first[0].predictedLabel, nil)

        // Determinism: the same inputs always give the same queue, in the same order.
        let shuffled = [c, a, b]
        let second = ActivityLabelCandidateSelector.select(from: shuffled)
        XCTAssertEqual(second, first)
    }

    func testAnsweredKeysAreExcluded() {
        let input = stretch(1_000, 1_400, uncertainty: 0.6)
        let selected = ActivityLabelCandidateSelector.select(from: [input],
                                                            answeredKeys: ["activity_context:1000"])
        XCTAssertTrue(selected.isEmpty)
    }

    func testLimitCapsTheQueue() {
        let inputs = (0..<10).map { stretch($0 * 1_000, $0 * 1_000 + 400, uncertainty: 0.6) }
        XCTAssertEqual(ActivityLabelCandidateSelector.select(from: inputs, limit: 3).count, 3)
        XCTAssertEqual(ActivityLabelCandidateSelector.select(from: inputs, limit: 0).count, 0)
        // Default is the documented queue cap (the spec's prompt budget is <= 5 per day).
        XCTAssertEqual(ActivityLabelCandidateSelector.select(from: inputs).count, 5)
    }

    func testStretchesWithNoReasonAreNotCandidates() {
        let confident = stretch(1_000, 1_400, uncertainty: 0.1)
        XCTAssertTrue(ActivityLabelCandidateSelector.select(from: [confident]).isEmpty)
    }

    func testCombinedReasonsAddTheirWeights() {
        let input = ActivityCandidateStretchInput(
            startTs: 100, endTs: 400, predictedClass: "stairs",
            overallUncertainty: 0.6,
            headConfidence: (posture: 0.8, locomotion: 0.3, armBehavior: 0.7),
            hartWindowLabels: ["stationary", "stationary", "stairs"],
            decodedLocomotion: "stairs", decodedPosture: "seated_likely")
        // A dominant walking stretch beside it, so stairs holds a small share of the classified time.
        let dominant = ActivityCandidateStretchInput(
            startTs: 1_000, endTs: 5_000, predictedClass: "walking",
            overallUncertainty: 0.1,
            headConfidence: (posture: 0.8, locomotion: 0.9, armBehavior: 0.7),
            hartWindowLabels: ["walking"],
            decodedLocomotion: "walking", decodedPosture: "upright_stationary")
        // Uncertainty (0.6 overall) + disagreement (2/3 stationary vs stairs) + coverage (smallest, rare).
        let selected = ActivityLabelCandidateSelector.select(from: [input, dominant])
        XCTAssertEqual(selected.first?.reasons, ["uncertainty", "disagreement", "coverage"])
        XCTAssertEqual(selected.first?.priority ?? 0, 1.1, accuracy: 1e-9)
    }

    func testCandidateIdsMatchTheStretchKeysAnswersAreStoredUnder() {
        XCTAssertEqual(ActivityLabelCandidateSelector.stretchKey(start: 123_456),
                       StretchFeedback.key(kind: .activityContext, start: 123_456))
        XCTAssertEqual(ActivityLabelCandidateSelector.stretchKey(start: 123_456), "activity_context:123456")
    }

    // MARK: - Episode assembly

    func testFromEpisodesCarriesTheDecodedReadingIntoTheInputs() {
        let posture = HeadProbabilities<PostureClass>([.seatedLikely: 0.8, .unknown: 0.2])
        let locomotion = HeadProbabilities<LocomotionClass>([.walking: 0.85, .unknown: 0.15])
        let arm = HeadProbabilities<ArmBehaviorClass>([.quiet: 0.9, .unknown: 0.1])
        let episode = ActivityEpisode(start: 100, end: 500, label: "Walking", posture: posture,
                                      locomotion: locomotion, armBehavior: arm, intensity: 0.3,
                                      confidence: 0.85, uncertainty: 0.15, sleep: .awake, wear: .onWrist)
        let inputs = ActivityLabelCandidateInputs.fromEpisodes([episode], deviceId: "my-whoop")
        XCTAssertEqual(inputs.count, 1)
        let input = inputs[0]
        XCTAssertEqual(input.startTs, 100)
        XCTAssertEqual(input.endTs, 500)
        XCTAssertEqual(input.deviceId, "my-whoop")
        XCTAssertEqual(input.predictedLabel, "Walking")
        XCTAssertEqual(input.overallUncertainty, 0.15)
        XCTAssertEqual(input.decodedLocomotion, "walking")
        XCTAssertEqual(input.decodedPosture, "seated_likely")
        XCTAssertNil(input.headConfidence?.posture,
                     "a moving episode carries no posture belief by design, so it is not scored as low confidence")
        XCTAssertEqual(input.headConfidence?.locomotion, 0.85)
        XCTAssertEqual(input.headConfidence?.armBehavior, 0.9)
        XCTAssertTrue(input.hartWindowLabels.isEmpty, "episodes carry no HART windows")
    }

    func testFromEpisodesMarksAnAbstainingHeadAsZeroConfidenceLikeTheDecoderDoes() {
        let posture = HeadProbabilities<PostureClass>([.unknown: 1])
        let locomotion = HeadProbabilities<LocomotionClass>([.walking: 0.9, .unknown: 0.1])
        let arm = HeadProbabilities<ArmBehaviorClass>([.quiet: 0.8, .unknown: 0.2])
        let episode = ActivityEpisode(start: 100, end: 500, label: "Unclear", posture: posture,
                                      locomotion: locomotion, armBehavior: arm, intensity: nil,
                                      confidence: 0.3, uncertainty: 0.7, sleep: .unknown, wear: .onWrist)
        let input = ActivityLabelCandidateInputs.fromEpisodes([episode])[0]
        XCTAssertNil(input.headConfidence?.posture, "walking: posture is not scored")
        XCTAssertNil(input.decodedPosture, "an all-unknown head has no reading to report")
        XCTAssertEqual(input.decodedLocomotion, "walking")

        let still = ActivityEpisode(start: 100, end: 500, label: "Unclear", posture: posture,
                                    locomotion: HeadProbabilities<LocomotionClass>([.stationary: 0.9, .unknown: 0.1]),
                                    armBehavior: arm, intensity: nil,
                                    confidence: 0.3, uncertainty: 0.7, sleep: .unknown, wear: .onWrist)
        let stillInput = ActivityLabelCandidateInputs.fromEpisodes([still])[0]
        XCTAssertEqual(stillInput.headConfidence?.posture, 0, "a still episode with an abstaining posture head scores 0")
        XCTAssertTrue(ActivityLabelCandidateSelector.firesUncertainty(stillInput))
    }

    func testAConfidentWalkIsNotFlaggedUncertainJustForHavingNoPosture() {
        let episode = ActivityEpisode(start: 100, end: 500, label: "Walking",
                                      posture: HeadProbabilities<PostureClass>([.unknown: 1]),
                                      locomotion: HeadProbabilities<LocomotionClass>([.walking: 0.9, .unknown: 0.1]),
                                      armBehavior: HeadProbabilities<ArmBehaviorClass>([.quiet: 0.85, .unknown: 0.15]),
                                      intensity: 0.4, confidence: 0.9, uncertainty: 0.1, sleep: .awake, wear: .onWrist)
        let input = ActivityLabelCandidateInputs.fromEpisodes([episode])[0]
        XCTAssertFalse(ActivityLabelCandidateSelector.firesUncertainty(input))
    }
}
