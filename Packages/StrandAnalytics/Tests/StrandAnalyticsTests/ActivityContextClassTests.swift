import XCTest
@testable import StrandAnalytics

/// The canonical activity taxonomy: stable codes, the display-label mapping, and the class a set of heads
/// reads as (with its confidence and runner-up). Pure value tests — no decoder.
final class ActivityContextClassTests: XCTestCase {

    private typealias Posture = HeadProbabilities<PostureClass>
    private typealias Locomotion = HeadProbabilities<LocomotionClass>
    private typealias Arm = HeadProbabilities<ArmBehaviorClass>

    private func classify(posture: [PostureClass: Double] = [.unknown: 1],
                          locomotion: [LocomotionClass: Double] = [.stationary: 1],
                          arm: [ArmBehaviorClass: Double] = [.unknown: 1],
                          sleep: SleepContextState = .awake, inBed: Bool = false,
                          wear: WearContextState = .onWrist,
                          quality: Double = 0.8, learned: PostureClass? = nil) -> ActivityClassification {
        ActivityClassifier.classify(posture: Posture(posture), locomotion: Locomotion(locomotion),
                                    armBehavior: Arm(arm), sleep: sleep, inBed: inBed, wear: wear,
                                    evidenceQuality: quality, learnedPosture: learned)
    }

    // MARK: Vocabulary

    func testRawValuesAreThePersistedCodes() {
        // These strings are written to the database and the day documents. Renaming one orphans history.
        XCTAssertEqual(ActivityClass.allCases.map(\.rawValue), [
            "off_wrist", "sleeping", "lying_down", "sitting", "sitting_desk", "standing", "stationary",
            "fidgeting", "light_activity", "walking", "brisk_walking", "running", "cycling",
            "vigorous_activity", "unknown",
        ])
        // act-class-3: `confidence` is now the subclass mass with `familyConfidence` alongside (I9).
        // act-class-4: wrist-only sitting / standing confidence is capped (D9-08); codes unchanged.
        XCTAssertEqual(ActivityClassVersions.taxonomy, "act-class-4")
    }

    func testTheRequestedVocabularyIsAllRepresented() {
        let names = Set(ActivityClass.allCases.map(\.displayName))
        for wanted in ["Sleeping", "Lying down", "Sitting", "Sitting at a desk", "Standing", "Fidgeting", "Walking",
                       "Brisk walking", "Running", "Cycling", "Higher-intensity activity", "Off wrist", "Unknown"] {
            XCTAssertTrue(names.contains(wanted), "missing \(wanted)")
        }
        // The only additions are the two the sensors force on us: an honest "sitting or standing" and the
        // non-gait movement bucket.
        let extras = names.subtracting(["Sleeping", "Lying down", "Sitting", "Sitting at a desk", "Standing",
                                        "Fidgeting", "Walking", "Brisk walking", "Running", "Cycling",
                                        "Higher-intensity activity", "Off wrist", "Unknown"])
        XCTAssertEqual(extras, ["Still (sitting or standing)", "Light activity"])
    }

    func testEveryClassStatesWhatItCanAndCannotClaim() {
        let covered = ActivityClass.capabilities.map(\.activityClass)
        XCTAssertEqual(covered, ActivityClass.allCases, "one entry per class, in vocabulary order")
        for entry in ActivityClass.capabilities {
            XCTAssertFalse(entry.evidence.isEmpty)
            XCTAssertFalse(entry.limitation.isEmpty)
        }
        func basis(_ c: ActivityClass) -> ActivityClassBasis {
            ActivityClass.capabilities.first { $0.activityClass == c }!.basis
        }
        // Cycling is never inferred; sitting vs standing is never a measurement.
        XCTAssertEqual(basis(.cycling), .namedByLabel)
        XCTAssertEqual(basis(.sitting), .hedged)
        XCTAssertEqual(basis(.standing), .hedged)
        XCTAssertEqual(basis(.sleeping), .sessionContext)
    }

    func testClassGroupsAgreeWithTheirMembers() {
        XCTAssertEqual(ActivityClass.allCases.filter(\.isGait), [.walking, .briskWalking, .running])
        XCTAssertEqual(Set(ActivityClass.allCases.filter(\.isMovement)),
                       [.walking, .briskWalking, .running, .cycling, .vigorousActivity, .lightActivity])
        XCTAssertEqual(Set(ActivityClass.allCases.filter(\.isRest)), [.sleeping, .lyingDown])
        XCTAssertEqual(Set(ActivityClass.allCases.filter(\.isStationaryAwake)),
                       [.sitting, .sittingDesk, .standing, .stationary, .fidgeting])
        // The groups never overlap.
        for c in ActivityClass.allCases {
            let memberships = [c.isMovement, c.isRest, c.isStationaryAwake].filter { $0 }.count
            XCTAssertLessThanOrEqual(memberships, 1, "\(c) is in more than one group")
        }
    }

    // MARK: Display label → class

    func testEveryDisplayLabelMapsToTheExpectedClass() {
        let expected: [String: ActivityClass] = [
            "Unclear": .unknown, "Off wrist": .offWrist,
            "Running": .running, "Walking": .walking, "Brisk walking": .briskWalking, "Taking stairs": .walking,
            "Cycling": .cycling, "In a vehicle": .sitting, "Exercising": .vigorousActivity, "Moving": .lightActivity,
            "Asleep": .sleeping, "Resting in bed": .lyingDown, "Lying down": .lyingDown,
            "Changing position": .lightActivity,
            "Desk sitting": .sittingDesk, "Sitting quietly": .sitting, "Sitting, restless": .fidgeting,
            "Sitting, repetitive hand activity": .sitting, "Sitting, gesturing": .sitting, "Sitting (likely)": .sitting,
            "Standing quietly": .standing, "Standing, restless": .fidgeting, "Standing, gesturing": .standing,
            "Standing, repetitive hand activity": .standing, "Standing, hands busy": .standing,
            "Standing (likely)": .standing,
            "Still, sitting or standing": .stationary, "Hands busy, sitting or standing": .stationary,
            "Stationary": .stationary,
            // Set by the decoder (not `derive`) when the wearer's verified personal sit / stand head backs the claim.
            "Likely sitting": .sitting, "Likely standing": .standing,
        ]
        XCTAssertEqual(Set(expected.keys), Set(ActivityDisplay.allLabels),
                       "a new display label needs a deliberate class")
        for label in ActivityDisplay.allLabels {
            XCTAssertEqual(ActivityClassifier.activityClass(forDisplayLabel: label), expected[label], label)
        }
    }

    func testAnUnrecognisedOrMissingLabelIsUnknownNeverAGuess() {
        XCTAssertEqual(ActivityClassifier.activityClass(forDisplayLabel: nil), .unknown)
        XCTAssertEqual(ActivityClassifier.activityClass(forDisplayLabel: "Teleporting"), .unknown)
    }

    // MARK: Heads → class

    func testOffWristIsAHardGate() {
        let k = classify(locomotion: [.walking: 1], wear: .offWrist)
        XCTAssertEqual(k.activityClass, .offWrist)
        XCTAssertEqual(k.confidence, 1)
        XCTAssertNil(k.runnerUp)
    }

    func testWalkingFamilyConfidenceAndTheBriskRunnerUp() {
        let k = classify(locomotion: [.walking: 0.55, .briskWalking: 0.35, .stationary: 0.10])
        XCTAssertEqual(k.activityClass, .walking)
        // I9: `confidence` is the chosen class's own (subclass) mass, not the walking-family mass; the
        // family belief is published separately as `familyConfidence`.
        XCTAssertEqual(k.confidence, 0.55, accuracy: 1e-9)
        XCTAssertEqual(k.familyConfidence, 0.90, accuracy: 1e-9, "walking and brisk walking are one belief")
        XCTAssertEqual(k.runnerUp, .briskWalking)
        XCTAssertEqual(k.runnerUpConfidence, 0.35, accuracy: 1e-9)
        XCTAssertEqual(k.locomotion, .walking)
    }

    func testBriskWalkingWinsWhenItLeadsTheFamily() {
        let k = classify(locomotion: [.walking: 0.30, .briskWalking: 0.62, .stationary: 0.08])
        XCTAssertEqual(k.activityClass, .briskWalking)
        XCTAssertEqual(k.confidence, 0.62, accuracy: 1e-9, "subclass mass, not the 0.92 family")
        XCTAssertEqual(k.familyConfidence, 0.92, accuracy: 1e-9)
        XCTAssertEqual(k.runnerUp, .walking)
    }

    func testBriskWalkingPublishesSubclassNotFamilyConfidence() {
        // WS-06-F01 / A05 mirror: walking 0.26 / brisk 0.27 chooses "Brisk walking"; classConfidence
        // must be the brisk-walking posterior mass (~0.27), not the walking-family mass (0.53).
        let k = classify(locomotion: [.walking: 0.26, .briskWalking: 0.27, .stationary: 0.47])
        XCTAssertEqual(k.activityClass, .briskWalking)
        XCTAssertEqual(k.confidence, 0.27, accuracy: 1e-9)
        XCTAssertEqual(k.familyConfidence, 0.53, accuracy: 1e-9)
    }

    func testStairsAreReportedAsWalkingWithTheHeadKeepingTheDetail() {
        let k = classify(locomotion: [.stairs: 0.7, .walking: 0.25, .unknown: 0.05])
        XCTAssertEqual(k.activityClass, .walking)
        XCTAssertEqual(k.locomotion, .stairs)
    }

    func testRunning() {
        let k = classify(locomotion: [.running: 0.9, .briskWalking: 0.05, .unknown: 0.05])
        XCTAssertEqual(k.activityClass, .running)
        XCTAssertEqual(k.confidence, 0.9, accuracy: 1e-9)
        XCTAssertEqual(k.runnerUp, .briskWalking)
    }

    func testCyclingNeedsTheHeadToSayCycling() {
        let k = classify(locomotion: [.cycling: 0.8, .other: 0.1, .unknown: 0.1])
        XCTAssertEqual(k.activityClass, .cycling)
        let none = classify(locomotion: [.other: 0.8, .unknown: 0.2], arm: [.exerciseMotion: 0.9, .other: 0.1])
        XCTAssertNotEqual(none.activityClass, .cycling)
    }

    func testNonGaitEffortIsVigorousOnlyWhenTheArmSaysExercise() {
        let vigorous = classify(locomotion: [.other: 0.8, .unknown: 0.2], arm: [.exerciseMotion: 0.7, .other: 0.3])
        XCTAssertEqual(vigorous.activityClass, .vigorousActivity)
        XCTAssertEqual(vigorous.confidence, 0.8, accuracy: 1e-9)
        let light = classify(locomotion: [.other: 0.8, .unknown: 0.2], arm: [.fidgeting: 0.6, .other: 0.4])
        XCTAssertEqual(light.activityClass, .lightActivity)
        XCTAssertEqual(light.runnerUp, nil, "the sibling only shows up when the arm head leans toward exercise")
        let leaning = classify(locomotion: [.other: 0.8, .unknown: 0.2], arm: [.exerciseMotion: 0.3, .other: 0.7])
        XCTAssertEqual(leaning.activityClass, .lightActivity)
        XCTAssertEqual(leaning.runnerUp, .vigorousActivity)
    }

    func testDeskSittingIsTheSeatedBeliefWithTheDeskWording() {
        let k = classify(posture: [.seatedLikely: 0.7, .uprightStationary: 0.2, .unknown: 0.1],
                         locomotion: [.stationary: 0.97, .unknown: 0.03],
                         arm: [.deskLike: 0.6, .quiet: 0.2, .fidgeting: 0.2])
        XCTAssertEqual(k.activityClass, .sittingDesk)
        XCTAssertEqual(k.confidence, 0.97 * 0.7, accuracy: 1e-9)
        XCTAssertEqual(k.runnerUp, .standing)
        XCTAssertEqual(k.posture, .seatedLikely)
        XCTAssertEqual(k.armBehavior, .deskLike)
    }

    func testPlainSittingAndRestlessSittingShareTheSeatedBelief() {
        let posture: [PostureClass: Double] = [.seatedLikely: 0.7, .uprightStationary: 0.2, .unknown: 0.1]
        let loco: [LocomotionClass: Double] = [.stationary: 0.97, .unknown: 0.03]
        let quiet = classify(posture: posture, locomotion: loco, arm: [.quiet: 0.8, .deskLike: 0.2])
        XCTAssertEqual(quiet.activityClass, .sitting)
        let restless = classify(posture: posture, locomotion: loco, arm: [.fidgeting: 0.7, .quiet: 0.3])
        XCTAssertEqual(restless.activityClass, .fidgeting)
        XCTAssertEqual(restless.posture, .seatedLikely, "fidgeting keeps the posture it happened in")
        // hsmm-1.9: "Sitting, restless" is a sitting claim, carried by the seated mass alone (it used to add the
        // upright mass too, 0.97 × 0.9, which is how wrist-only fidgeting reached ~0.9).
        XCTAssertEqual(restless.confidence, 0.97 * 0.7, accuracy: 1e-9)
        XCTAssertEqual(restless.confidence, quiet.confidence, accuracy: 1e-12, "one seated belief, two wordings")
    }

    /// Fidgeting with no learned support stays at or below the wrist cap however the posture mass is split, and the
    /// restless wording of either posture carries no more than the plain wording of that posture.
    func testRestlessPostureClaimsAreCappedLikeSittingAndStanding() {
        let cap = ActivityClassifier.wristOnlyPostureConfidenceCap
        let loco: [LocomotionClass: Double] = [.stationary: 0.97, .unknown: 0.03]
        for (p, label) in [(PostureClass.seatedLikely, "Sitting, restless"), (.uprightStationary, "Standing, restless")] {
            let other: PostureClass = p == .seatedLikely ? .uprightStationary : .seatedLikely
            for (main, rest) in [(0.95, 0.03), (0.9, 0.05), (0.7, 0.25), (0.6, 0.35)] {
                let posture: [PostureClass: Double] = [p: main, other: rest, .unknown: 1 - main - rest]
                XCTAssertEqual(ActivityDisplay.derive(posture: Posture(posture), locomotion: Locomotion(loco),
                                                      arm: Arm([.fidgeting: 0.8, .quiet: 0.2]), sleep: .awake,
                                                      inBed: false, confidence: 0.8), label)
                let restless = classify(posture: posture, locomotion: loco, arm: [.fidgeting: 0.8, .quiet: 0.2])
                XCTAssertEqual(restless.activityClass, .fidgeting)
                XCTAssertEqual(restless.posture, p)
                XCTAssertLessThanOrEqual(restless.confidence, cap + 1e-12, "\(label) \(main)")
                XCTAssertEqual(restless.confidence, min(cap, 0.97 * main), accuracy: 1e-12, "\(label) \(main)")
                XCTAssertEqual(restless.familyConfidence, restless.confidence, accuracy: 1e-12)
            }
        }
    }

    /// Vehicle mass beside a still seated reading must not lift a "Sitting" claim past the posture cap (review r5:
    /// stationary 0.6 + vehicle 0.4 with a 0.95 seated head read "Sitting quietly" at 0.97 wrist-only). The vehicle
    /// claim itself stays the encoder's call.
    func testVehicleMassDoesNotLiftAStillSittingClaimPastTheCap() {
        let cap = ActivityClassifier.wristOnlyPostureConfidenceCap
        let sitting = classify(posture: [.seatedLikely: 0.95, .uprightStationary: 0.03, .unknown: 0.02],
                               locomotion: [.stationary: 0.6, .vehicleMotion: 0.4], arm: [.quiet: 0.9, .other: 0.1])
        XCTAssertEqual(sitting.activityClass, .sitting)
        XCTAssertNotEqual(sitting.detail, .inVehicle)
        XCTAssertLessThanOrEqual(sitting.confidence, cap + 1e-12)
        let vehicle = classify(posture: [.seatedLikely: 0.95, .uprightStationary: 0.03, .unknown: 0.02],
                               locomotion: [.stationary: 0.3, .vehicleMotion: 0.7], arm: [.quiet: 0.9, .other: 0.1])
        XCTAssertEqual(vehicle.detail, .inVehicle)
        XCTAssertEqual(vehicle.confidence, min(cap, 0.3 * 0.95) + 0.7, accuracy: 1e-9)
    }

    func testStandingNeedsAClearUprightLean() {
        let standing = classify(posture: [.uprightStationary: 0.7, .seatedLikely: 0.2, .unknown: 0.1],
                                locomotion: [.stationary: 0.97, .unknown: 0.03], arm: [.quiet: 0.9, .other: 0.1])
        XCTAssertEqual(standing.activityClass, .standing)
        XCTAssertEqual(standing.confidence, 0.97 * 0.7, accuracy: 1e-9)
    }

    // MARK: Wrist-only posture confidence (D9-08)

    func testAWristOnlySittingOrStandingClaimNeverExceedsTheCap() {
        let cap = ActivityClassifier.wristOnlyPostureConfidenceCap
        XCTAssertEqual(cap, 0.75)
        let loco: [LocomotionClass: Double] = [.stationary: 0.97, .unknown: 0.03]
        let sitting = classify(posture: [.seatedLikely: 0.9, .uprightStationary: 0.05, .unknown: 0.05], locomotion: loco,
                               arm: [.quiet: 0.9, .other: 0.1])
        XCTAssertEqual(sitting.activityClass, .sitting, "the class itself is unchanged")
        XCTAssertEqual(sitting.confidence, cap, accuracy: 1e-12)
        XCTAssertEqual(sitting.familyConfidence, cap, accuracy: 1e-12)
        let desk = classify(posture: [.seatedLikely: 0.9, .uprightStationary: 0.05, .unknown: 0.05], locomotion: loco,
                            arm: [.deskLike: 0.8, .quiet: 0.2])
        XCTAssertEqual(desk.activityClass, .sittingDesk)
        XCTAssertEqual(desk.confidence, cap, accuracy: 1e-12)
        let standing = classify(posture: [.uprightStationary: 0.9, .seatedLikely: 0.05, .unknown: 0.05], locomotion: loco,
                                arm: [.quiet: 0.9, .other: 0.1])
        XCTAssertEqual(standing.activityClass, .standing)
        XCTAssertEqual(standing.confidence, cap, accuracy: 1e-12)
        // The runner-up mass is capped the same way.
        let still = classify(posture: [.seatedLikely: 0.48, .uprightStationary: 0.42, .unknown: 0.1], locomotion: loco,
                             arm: [.quiet: 0.9, .other: 0.1])
        XCTAssertEqual(still.activityClass, .stationary)
        XCTAssertLessThanOrEqual(still.runnerUpConfidence, cap)
        // Below the cap nothing changes.
        let low = classify(posture: [.seatedLikely: 0.7, .uprightStationary: 0.2, .unknown: 0.1], locomotion: loco,
                           arm: [.quiet: 0.9, .other: 0.1])
        XCTAssertEqual(low.confidence, 0.97 * 0.7, accuracy: 1e-12)
    }

    func testOnlyAnAgreeingLearnedSourceOrAVehicleRaisesTheCap() {
        let loco: [LocomotionClass: Double] = [.stationary: 0.97, .unknown: 0.03]
        let wrist = ActivityClassifier.wristOnlyPostureConfidenceCap, learnedCap = ActivityClassifier.learnedPostureConfidenceCap
        XCTAssertEqual(learnedCap, 0.85)
        let seated: [PostureClass: Double] = [.seatedLikely: 0.9, .uprightStationary: 0.05, .unknown: 0.05]
        let upright: [PostureClass: Double] = [.uprightStationary: 0.9, .seatedLikely: 0.05, .unknown: 0.05]
        // Agreement raises the ceiling to the softer learned cap; it never removes it.
        XCTAssertEqual(classify(posture: seated, locomotion: loco, arm: [.quiet: 0.9, .other: 0.1],
                                learned: .seatedLikely).confidence, learnedCap, accuracy: 1e-12)
        XCTAssertEqual(classify(posture: upright, locomotion: loco, arm: [.quiet: 0.9, .other: 0.1],
                                learned: .uprightStationary).confidence, learnedCap, accuracy: 1e-12)
        // A learned source that leans the OTHER way does not raise the confidence of the wrist's claim.
        let disagree = classify(posture: seated, locomotion: loco, arm: [.quiet: 0.9, .other: 0.1],
                                learned: .uprightStationary)
        XCTAssertEqual(disagree.activityClass, .sitting)
        XCTAssertEqual(disagree.confidence, wrist, accuracy: 1e-12)
        let disagreeStand = classify(posture: upright, locomotion: loco, arm: [.quiet: 0.9, .other: 0.1],
                                     learned: .seatedLikely)
        XCTAssertEqual(disagreeStand.confidence, wrist, accuracy: 1e-12)
        // ...and neither does one that names a posture the claim is not about.
        XCTAssertEqual(classify(posture: seated, locomotion: loco, arm: [.quiet: 0.9, .other: 0.1],
                                learned: .recumbent).confidence, wrist, accuracy: 1e-12)
        // Restless wordings follow the same rule.
        XCTAssertEqual(classify(posture: seated, locomotion: loco, arm: [.fidgeting: 0.8, .quiet: 0.2],
                                learned: .uprightStationary).confidence, wrist, accuracy: 1e-12)
        XCTAssertEqual(classify(posture: seated, locomotion: loco, arm: [.fidgeting: 0.8, .quiet: 0.2],
                                learned: .seatedLikely).confidence, learnedCap, accuracy: 1e-12)
        // Between the two caps an agreeing claim keeps its mass.
        let between = classify(posture: [.seatedLikely: 0.82, .uprightStationary: 0.08, .unknown: 0.1], locomotion: loco,
                               arm: [.quiet: 0.9, .other: 0.1], learned: .seatedLikely)
        XCTAssertEqual(between.confidence, 0.97 * 0.82, accuracy: 1e-12)
        // Presence is provenance only.
        XCTAssertTrue(ActivityClassifier.learnedPostureEvidence(experts: ["hart_fine"]))
        XCTAssertTrue(ActivityClassifier.learnedPostureEvidence(experts: ["encoder", "transition"]))
        XCTAssertFalse(ActivityClassifier.learnedPostureEvidence(experts: ["encoder", "eldernet"]),
                       "folded encoder classes and the gait expert say nothing about posture")
        // A vehicle is the encoder's call (it names vehicle motion): not a wrist posture claim.
        let car = classify(posture: [.seatedLikely: 0.6, .unknown: 0.4],
                           locomotion: [.vehicleMotion: 0.85, .stationary: 0.1, .unknown: 0.05], arm: [.quiet: 1])
        XCTAssertEqual(car.activityClass, .sitting)
        XCTAssertEqual(car.detail, .inVehicle)
        XCTAssertGreaterThan(car.confidence, 0.85)
    }

    func testStatesReadAgreementAndRunsStayAtTheWristCap() {
        func state(hartFine: Bool, learned: PostureClass?) -> ActivityContextState {
            ActivityContextState(
                ts: 1_760_000_000, posture: Posture([.seatedLikely: 0.9, .uprightStationary: 0.05, .unknown: 0.05]),
                locomotion: Locomotion([.stationary: 0.97, .unknown: 0.03]), armBehavior: Arm([.quiet: 1]),
                intensity: 0.05, transition: nil, sleep: SleepContext(state: .awake),
                wear: WearContext(state: .onWrist, validity: 1), overallConfidence: 0.8, overallUncertainty: 0.2,
                headConfidence: ActivityHeadConfidence(posture: 0.9, locomotion: 0.97, armBehavior: 1),
                displayContext: "Sitting quietly",
                history: ActivityHistorySummary(sinceLocomotionS: nil, stationaryForS: 300, recentEvents: []),
                evidence: ActivityEvidenceSummary(imu: false, encoder: hartFine, dynAccel: true, gravity: true,
                                                  steps: true, heartRate: true, sleep: true, coverage: 0.8,
                                                  hartFine: hartFine ? true : nil, transitionExpert: true,
                                                  learnedPosture: learned),
                versions: ActivityStateVersions())
        }
        XCTAssertEqual(ActivityClassifier.classify(state: state(hartFine: false, learned: nil)).confidence, 0.75,
                       accuracy: 1e-12)
        // HART and the transition expert spoke, but neither leaned toward sitting: still the wrist cap.
        XCTAssertEqual(ActivityClassifier.classify(state: state(hartFine: true, learned: nil)).confidence, 0.75,
                       accuracy: 1e-12)
        XCTAssertEqual(ActivityClassifier.classify(state: state(hartFine: true, learned: .uprightStationary)).confidence,
                       0.75, accuracy: 1e-12)
        XCTAssertEqual(ActivityClassifier.classify(state: state(hartFine: true, learned: .seatedLikely)).confidence,
                       0.85, accuracy: 1e-12)
        // The agreement survives the state's JSON round trip, and is absent from it when nil.
        let agreeing = state(hartFine: true, learned: .seatedLikely)
        let data = try! JSONEncoder().encode(agreeing.evidence)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"learned_posture\":\"seated_likely\""))
        XCTAssertEqual(try! JSONDecoder().decode(ActivityEvidenceSummary.self, from: data), agreeing.evidence)
        let none = try! JSONEncoder().encode(state(hartFine: true, learned: nil).evidence)
        XCTAssertFalse(String(decoding: none, as: UTF8.self).contains("learned_posture"))
        // A run keeps which experts spoke, not whether they agreed second by second: the wrist cap.
        var run = ActivityContextRun(start: 0, end: 60, posture: agreeing.posture,
                                     locomotion: agreeing.locomotion, armBehavior: Arm([.quiet: 1]),
                                     intensity: 0.05, overallConfidence: 0.8, overallUncertainty: 0.2,
                                     displayContext: "Sitting quietly", sleep: .awake, wear: .onWrist, count: 12)
        XCTAssertEqual(run.classification.confidence, 0.75, accuracy: 1e-12)
        run.experts = ["hart_fine", "transition"]
        XCTAssertEqual(run.classification.confidence, 0.75, accuracy: 1e-12, "presence does not lift the cap")
    }

    func testStillWristWithNoLeanStaysStationaryNotSittingOrStanding() {
        let k = classify(posture: [.seatedLikely: 0.4, .uprightStationary: 0.35, .unknown: 0.25],
                         locomotion: [.stationary: 0.97, .unknown: 0.03], arm: [.quiet: 0.9, .other: 0.1])
        XCTAssertEqual(k.activityClass, .stationary)
        XCTAssertEqual(k.confidence, 0.97, accuracy: 1e-9, "sure it is a still, awake, non-recumbent wrist")
        XCTAssertEqual(k.runnerUp, .sitting, "...and the lean it cannot commit to")
    }

    func testSleepingNeedsTheSessionAndLyingDownDoesNot() {
        let night = classify(posture: [.recumbent: 0.9, .unknown: 0.1], locomotion: [.stationary: 0.97, .unknown: 0.03],
                             sleep: .asleep)
        XCTAssertEqual(night.activityClass, .sleeping)
        // On a sleep epoch the confirming evidence is stillness.
        XCTAssertEqual(night.confidence, 0.97, accuracy: 1e-9)

        let nap = classify(posture: [.recumbent: 0.9, .unknown: 0.1], locomotion: [.stationary: 0.97, .unknown: 0.03],
                           sleep: .unknown)
        XCTAssertEqual(nap.activityClass, .lyingDown)
        XCTAssertEqual(nap.confidence, 0.97 * 0.9, accuracy: 1e-9)
        let inBed = classify(posture: [.recumbent: 0.9, .unknown: 0.1], locomotion: [.stationary: 0.97, .unknown: 0.03],
                             sleep: .awake)
        XCTAssertEqual(inBed.activityClass, .lyingDown)
    }

    /// The staged night decides asleep and in bed; a seated lean (how a still wrist often reads at night)
    /// neither overrides it nor drains its confidence.
    func testTheNightNotThePostureLeanDecidesSleepingAndInBed() {
        let seated: [PostureClass: Double] = [.seatedLikely: 0.80, .uprightStationary: 0.14, .unknown: 0.06]
        let still: [LocomotionClass: Double] = [.stationary: 0.97, .unknown: 0.03]
        let asleep = classify(posture: seated, locomotion: still, arm: [.deskLike: 0.77, .fidgeting: 0.23],
                              sleep: .asleep, inBed: true)
        XCTAssertEqual(asleep.activityClass, .sleeping)
        XCTAssertEqual(asleep.confidence, 0.97, accuracy: 1e-9)

        let awakeInBed = classify(posture: seated, locomotion: still, arm: [.deskLike: 0.8, .quiet: 0.2],
                                  sleep: .awake, inBed: true)
        XCTAssertEqual(awakeInBed.activityClass, .lyingDown)
        XCTAssertEqual(awakeInBed.confidence, 0.97, accuracy: 1e-9)

        let atDesk = classify(posture: seated, locomotion: still, arm: [.deskLike: 0.8, .quiet: 0.2], sleep: .awake)
        XCTAssertEqual(atDesk.activityClass, .sittingDesk, "outside a night the lean is read as before")
    }

    func testThinEvidenceIsUnknownWithTheBestGuessAsRunnerUp() {
        let k = classify(posture: [.seatedLikely: 0.5, .uprightStationary: 0.3, .unknown: 0.2],
                         locomotion: [.stationary: 0.6, .walking: 0.2, .unknown: 0.2], quality: 0.2)
        XCTAssertEqual(k.activityClass, .unknown)
        XCTAssertEqual(k.confidence, 0)
        XCTAssertEqual(k.runnerUp, .sitting, "what it would be if forced, offered as a guess and nothing more")
        XCTAssertEqual(k.evidenceQuality, 0.2, accuracy: 1e-9)
    }

    func testConfidenceAndEvidenceQualityAreBoundedAndIndependent() {
        let k = classify(locomotion: [.running: 1], quality: 7)
        XCTAssertEqual(k.evidenceQuality, 1)
        XCTAssertEqual(k.confidence, 1)
        let low = classify(locomotion: [.running: 1], quality: 0.31)
        XCTAssertEqual(low.activityClass, .running)
        XCTAssertEqual(low.evidenceQuality, 0.31, accuracy: 1e-9, "a sure class over thin evidence says so")
    }

    func testClassificationOfAStateAndItsRunAgree() {
        let state = ActivityContextState(
            ts: 1_760_000_000, posture: Posture([.seatedLikely: 0.7, .uprightStationary: 0.2, .unknown: 0.1]),
            locomotion: Locomotion([.stationary: 0.97, .unknown: 0.03]), armBehavior: Arm([.deskLike: 0.6, .quiet: 0.4]),
            intensity: 0.2, transition: nil, sleep: SleepContext(state: .awake), wear: WearContext(state: .onWrist, validity: 1),
            overallConfidence: 0.8, overallUncertainty: 0.2,
            headConfidence: ActivityHeadConfidence(posture: 0.7, locomotion: 0.97, armBehavior: 0.6),
            displayContext: "Desk sitting",
            history: ActivityHistorySummary(sinceLocomotionS: nil, stationaryForS: 300, recentEvents: []),
            evidence: ActivityEvidenceSummary(imu: false, encoder: false, dynAccel: true, gravity: true, steps: true,
                                              heartRate: true, sleep: true, coverage: 0.8),
            versions: ActivityStateVersions())
        let run = ActivityContextRun(start: state.ts, end: state.ts + 5, posture: state.posture,
                                     locomotion: state.locomotion, armBehavior: state.armBehavior, intensity: 0.2,
                                     overallConfidence: 0.8, overallUncertainty: 0.2, displayContext: "Desk sitting",
                                     sleep: .awake, wear: .onWrist, count: 1)
        XCTAssertEqual(ActivityClassifier.classify(state: state), ActivityClassifier.classify(run: run))
        XCTAssertEqual(run.classification.activityClass, .sittingDesk)
    }

    // MARK: Persisted shape

    func testRunsCarryTheCanonicalClassInTheirJSONAndIgnoreItOnRead() throws {
        let run = ActivityContextRun(start: 100, end: 160, posture: Posture([.unknown: 1]),
                                     locomotion: Locomotion([.walking: 0.9, .briskWalking: 0.05, .unknown: 0.05]),
                                     armBehavior: Arm([.other: 1]), intensity: 0.5, overallConfidence: 0.8,
                                     overallUncertainty: 0.2, displayContext: "Walking", sleep: .awake,
                                     wear: .onWrist, count: 12)
        let data = try JSONEncoder().encode(run)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["activity_class"] as? String, "walking")
        // I9: class_confidence is the chosen class's own mass (walking + stairs), not the family mass
        // (walking + brisk + stairs = 0.95) that the run previously reported.
        XCTAssertEqual(try XCTUnwrap(json["class_confidence"] as? Double), 0.90, accuracy: 0.011)
        XCTAssertEqual(try JSONDecoder().decode(ActivityContextRun.self, from: data), run)

        // A run written before the taxonomy existed still reads.
        var legacy = json
        legacy["activity_class"] = nil; legacy["class_confidence"] = nil
        let old = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertEqual(try JSONDecoder().decode(ActivityContextRun.self, from: old), run)
    }

    func testDaySummaryAddsSecondsPerClassAndOldSummariesStillDecode() throws {
        let walk = ActivityContextRun(start: 0, end: 60, posture: Posture([.unknown: 1]),
                                      locomotion: Locomotion([.walking: 1]), armBehavior: Arm([.other: 1]),
                                      intensity: 0.5, overallConfidence: 0.8, overallUncertainty: 0.2,
                                      displayContext: "Walking", sleep: .awake, wear: .onWrist, count: 12)
        let off = ActivityContextRun(start: 60, end: 100, posture: Posture([.unknown: 1]),
                                     locomotion: Locomotion([.unknown: 1]), armBehavior: Arm([.unknown: 1]),
                                     intensity: nil, overallConfidence: 0, overallUncertainty: 1,
                                     displayContext: "Off wrist", sleep: .unknown, wear: .offWrist, count: 8)
        let summary = ActivityContextDaySummary(runs: [walk, off])
        XCTAssertEqual(summary.classSeconds, ["walking": 60, "off_wrist": 40])

        let legacy = #"{"label_s":{"Walking":60},"unclear_s":0,"mean_confidence":0.8}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ActivityContextDaySummary.self, from: legacy)
        XCTAssertNil(decoded.classSeconds)
        let key = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        XCTAssertNotNil(key["class_s"])
    }
}
