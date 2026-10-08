import XCTest
@testable import StrandAnalytics

/// The composite labels are a derived view: they must follow the heads, hedge where a wrist cannot know,
/// and never claim more than the heads do.
final class ActivityContextDisplayTests: XCTestCase {

    private func label(posture: [PostureClass: Double] = [:],
                       locomotion: [LocomotionClass: Double] = [.stationary: 0.96],
                       arm: [ArmBehaviorClass: Double] = [:],
                       sleep: SleepContextState = .awake, confidence: Double = 0.8) -> String {
        ActivityDisplay.derive(posture: HeadProbabilities(posture), locomotion: HeadProbabilities(locomotion),
                               arm: HeadProbabilities(arm), sleep: sleep, confidence: confidence)
    }

    private let seatedHead: [PostureClass: Double] = [.seatedLikely: 0.84, .uprightStationary: 0.10, .unknown: 0.06]
    private let uprightHead: [PostureClass: Double] = [.uprightStationary: 0.72, .seatedLikely: 0.20, .unknown: 0.08]

    // MARK: Stationary wording

    func testDeskSittingNeedsSeatedLeadDeskArmAndConfidence() {
        XCTAssertEqual(label(posture: seatedHead, arm: [.deskLike: 0.74, .fidgeting: 0.17]), "Desk sitting")
        XCTAssertEqual(label(posture: seatedHead, arm: [.quiet: 0.8]), "Sitting quietly")
        XCTAssertEqual(label(posture: seatedHead, arm: [.fidgeting: 0.7]), "Sitting, restless")
        XCTAssertEqual(label(posture: seatedHead, arm: [.repetitiveHandMotion: 0.6]), "Sitting, repetitive hand activity")
        XCTAssertEqual(label(posture: seatedHead, arm: [.activeGesturing: 0.6]), "Sitting, gesturing")
        XCTAssertEqual(label(posture: seatedHead, arm: [.other: 0.5]), "Sitting (likely)")
    }

    func testStandingQuietlyWording() {
        XCTAssertEqual(label(posture: uprightHead, arm: [.quiet: 0.8]), "Standing quietly")
        XCTAssertEqual(label(posture: uprightHead, arm: [.fidgeting: 0.7]), "Standing, restless")
        XCTAssertEqual(label(posture: uprightHead, arm: [.deskLike: 0.7]), "Standing, hands busy")
    }

    func testLowConfidenceKeepsTheStationaryLabelHedged() {
        let hedged = label(posture: seatedHead, arm: [.deskLike: 0.74], confidence: 0.45)
        XCTAssertEqual(hedged, "Hands busy, sitting or standing")
        XCTAssertEqual(label(posture: uprightHead, arm: [.quiet: 0.8], confidence: 0.45), "Still, sitting or standing")
        XCTAssertEqual(label(posture: seatedHead, arm: [.other: 0.5], confidence: 0.45), "Stationary")
    }

    func testAmbiguousSeatedVersusUprightIsNeverCommitted() {
        let split: [PostureClass: Double] = [.seatedLikely: 0.42, .uprightStationary: 0.38, .unknown: 0.20]
        XCTAssertEqual(label(posture: split, arm: [.quiet: 0.8], confidence: 0.9), "Still, sitting or standing")
        // hsmm-1.8 (D1-11): a clearly stationary second whose posture is unresolved still says the coarse fact,
        // "Stationary" (class `stationary`), rather than "Unclear" (class `unknown` at 0).
        let weak: [PostureClass: Double] = [.seatedLikely: 0.30, .uprightStationary: 0.15, .unknown: 0.55]
        XCTAssertEqual(label(posture: weak, arm: [.quiet: 0.8], confidence: 0.9), "Stationary")
    }

    func testAStationarySecondSplitBetweenLyingAndSittingIsStationaryNotUnknown() {
        // D1-11 probe E7: stationary 0.97, recumbent 0.47, seated 0.37 used to publish "Unclear" / unknown@0.
        let split: [PostureClass: Double] = [.recumbent: 0.47, .seatedLikely: 0.37, .uprightStationary: 0.06,
                                             .unknown: 0.10]
        XCTAssertEqual(label(posture: split, locomotion: [.stationary: 0.97, .unknown: 0.03], arm: [.quiet: 0.8],
                             sleep: .unknown, confidence: 0.72), "Stationary")
        let k = ActivityClassifier.classify(posture: HeadProbabilities(split),
                                            locomotion: HeadProbabilities([.stationary: 0.97, .unknown: 0.03]),
                                            armBehavior: HeadProbabilities([.quiet: 0.8, .unknown: 0.2]),
                                            sleep: .unknown, wear: .onWrist, evidenceQuality: 0.72)
        XCTAssertEqual(k.activityClass, .stationary)
        XCTAssertGreaterThanOrEqual(k.confidence, 0.5)
        XCTAssertEqual(k.runnerUp, .lyingDown, "the posture split is carried as the runner-up")
    }

    func testLowOverallConfidenceIsUnclearWhateverTheHeadsSay() {
        XCTAssertEqual(label(posture: seatedHead, arm: [.deskLike: 0.74], confidence: 0.29), ActivityDisplay.unclear)
        XCTAssertEqual(label(locomotion: [.running: 0.9], confidence: 0.1), ActivityDisplay.unclear)
    }

    // MARK: Lying down

    func testRecumbentWordingFollowsTheSleepContext() {
        let bed: [PostureClass: Double] = [.recumbent: 0.88, .unknown: 0.12]
        XCTAssertEqual(label(posture: bed, arm: [.quiet: 0.9], sleep: .asleep), "Asleep")
        // hsmm-1.8: awake lying outside the night's in-bed window is a sofa or a daytime lie-down, not "in bed"
        // (before 1.8 awake recumbent was unreachable outside the window, so this wording never showed).
        XCTAssertEqual(label(posture: bed, arm: [.quiet: 0.9], sleep: .awake), "Lying down")
        XCTAssertEqual(label(posture: bed, arm: [.quiet: 0.9], sleep: .unknown), "Lying down")
        XCTAssertEqual(ActivityDisplay.derive(posture: HeadProbabilities(bed), locomotion: HeadProbabilities([.stationary: 0.96]),
                                              arm: HeadProbabilities([.quiet: 0.9]), sleep: .awake, inBed: true,
                                              confidence: 0.8), "Resting in bed")
    }

    // MARK: Moving

    func testLocomotionLabels() {
        XCTAssertEqual(label(locomotion: [.walking: 0.8, .briskWalking: 0.1]), "Walking")
        XCTAssertEqual(label(locomotion: [.walking: 0.2, .briskWalking: 0.7]), "Brisk walking")
        XCTAssertEqual(label(locomotion: [.walking: 0.3, .briskWalking: 0.3, .stationary: 0.4]), "Walking",
                       "the walking family adds up before it is named")
        XCTAssertEqual(label(locomotion: [.running: 0.7, .briskWalking: 0.2]), "Running")
        XCTAssertEqual(label(locomotion: [.stairs: 0.5, .walking: 0.3]), "Taking stairs")
        XCTAssertEqual(label(locomotion: [.stairs: 0.35, .walking: 0.3, .briskWalking: 0.1, .stationary: 0.25]),
                       "Taking stairs", "stairs counts toward the walking family and wins when it leads it")
        XCTAssertEqual(label(locomotion: [.walking: 0.25, .briskWalking: 0.15, .stairs: 0.15, .stationary: 0.45]),
                       "Walking", "the family total includes stairs, so this is a walk, not stillness")
        XCTAssertEqual(label(locomotion: [.briskWalking: 0.3, .walking: 0.1, .stairs: 0.15, .stationary: 0.45]),
                       "Brisk walking")
        XCTAssertEqual(label(locomotion: [.cycling: 0.6]), "Cycling")
        XCTAssertEqual(label(locomotion: [.vehicleMotion: 0.6]), "In a vehicle")
        XCTAssertEqual(label(locomotion: [.other: 0.7], arm: [.exerciseMotion: 0.6]), "Exercising")
        XCTAssertEqual(label(locomotion: [.other: 0.7], arm: [.fidgeting: 0.6]), "Moving")
    }

    func testPositionChangeIsNamedBeforePosture() {
        XCTAssertEqual(label(posture: [.posturalTransition: 0.6, .seatedLikely: 0.3], arm: [.quiet: 0.5]), "Changing position")
        XCTAssertEqual(label(posture: [.posturalTransition: 0.2, .seatedLikely: 0.6, .uprightStationary: 0.1, .unknown: 0.1],
                             arm: [.deskLike: 0.7]), "Desk sitting")
    }

    func testNoLocomotionClaimBelowHalfFallsBackToUnclear() {
        XCTAssertEqual(label(locomotion: [.stationary: 0.4, .walking: 0.35, .unknown: 0.25]), ActivityDisplay.unclear)
    }

    // MARK: What the sensor cannot say

    func testNoLabelEverClaimsTypingOrAnExactBodyPose() {
        for arm in ArmBehaviorClass.allCases {
            for (posture, loco) in [(seatedHead, [LocomotionClass.stationary: 0.96]), (uprightHead, [.stationary: 0.96])] {
                let l = label(posture: posture, locomotion: loco, arm: [arm: 0.9]).lowercased()
                XCTAssertFalse(l.contains("typing"), l)
                XCTAssertFalse(l.contains("writing"), l)
            }
        }
        // A seated head is capped below certainty; wording never states sitting without the hedge words
        // when confidence is thin.
        XCTAssertFalse(label(posture: seatedHead, arm: [.deskLike: 0.74], confidence: 0.4).hasPrefix("Desk sitting"))
    }

    // MARK: Hysteresis grouping

    func testHoldSecondsAndGroups() {
        XCTAssertEqual(ActivityDisplay.holdSeconds(to: ActivityDisplay.offWrist, default: 10), 0)
        XCTAssertEqual(ActivityDisplay.holdSeconds(to: ActivityDisplay.unclear, default: 10), 15)
        XCTAssertEqual(ActivityDisplay.holdSeconds(to: "Asleep", default: 10), 15)
        XCTAssertEqual(ActivityDisplay.holdSeconds(to: "Walking", default: 10), 10)

        XCTAssertEqual(ActivityDisplay.group("Walking"), ActivityDisplay.group("Brisk walking"))
        XCTAssertEqual(ActivityDisplay.group("Asleep"), ActivityDisplay.group("Resting in bed"))
        XCTAssertEqual(ActivityDisplay.group("Desk sitting"), ActivityDisplay.group("Sitting quietly"))
        XCTAssertEqual(ActivityDisplay.group("Standing quietly"), ActivityDisplay.group("Standing, hands busy"))
        // Getting up is a change of kind (hsmm-1.6), so it does not wait out the refinement hold.
        XCTAssertNotEqual(ActivityDisplay.group("Desk sitting"), ActivityDisplay.group("Standing quietly"))
        XCTAssertNotEqual(ActivityDisplay.group("Standing quietly"), ActivityDisplay.group("Still, sitting or standing"))
        XCTAssertNotEqual(ActivityDisplay.group("Walking"), ActivityDisplay.group("Desk sitting"))
        XCTAssertNotEqual(ActivityDisplay.group(ActivityDisplay.offWrist), ActivityDisplay.group(ActivityDisplay.unclear))
        XCTAssertEqual(ActivityDisplay.group("Changing position"), "transition")
    }

    // MARK: Logged sleep

    func testBriefRestlessnessInsideLoggedSleepIsStillAsleep() {
        let stationary = HeadProbabilities<LocomotionClass>([.stationary: 0.9, .unknown: 0.1])
        let quiet = HeadProbabilities<ArmBehaviorClass>([.quiet: 0.7, .unknown: 0.3])
        // A turn in bed reads partly upright for a moment; the night is still the night.
        let restless = HeadProbabilities<PostureClass>([.recumbent: 0.35, .uprightStationary: 0.25, .seatedLikely: 0.2, .unknown: 0.2])
        XCTAssertEqual(ActivityDisplay.derive(posture: restless, locomotion: stationary, arm: quiet,
                                              sleep: .asleep, confidence: 0.7), "Asleep")
        // Outside a logged session the same posture does not become sleep.
        XCTAssertNotEqual(ActivityDisplay.derive(posture: restless, locomotion: stationary, arm: quiet,
                                                 sleep: .awake, confidence: 0.7), "Asleep")
    }

    /// A still sleeper's wrist leans seated as often as not: the reported night's 2:23 a.m. stretch read
    /// seated 0.80 / upright 0.14 while the strap and the session both said asleep, and the old override
    /// labelled it "Sitting quietly". On a sleep epoch the posture lean no longer overrides the night.
    func testASeatedLeanDoesNotOverrideASleepEpoch() {
        let stationary = HeadProbabilities<LocomotionClass>([.stationary: 0.97, .unknown: 0.03])
        let deskLike = HeadProbabilities<ArmBehaviorClass>([.deskLike: 0.77, .fidgeting: 0.23])
        let seated = HeadProbabilities<PostureClass>([.seatedLikely: 0.80, .uprightStationary: 0.14, .unknown: 0.06])
        XCTAssertEqual(ActivityDisplay.derive(posture: seated, locomotion: stationary, arm: deskLike,
                                              sleep: .asleep, inBed: true, confidence: 0.61), "Asleep")
        // Movement still breaks it: walking inside the night is walking.
        let walking = HeadProbabilities<LocomotionClass>([.walking: 0.8, .stationary: 0.2])
        XCTAssertEqual(ActivityDisplay.derive(posture: seated, locomotion: walking, arm: deskLike,
                                              sleep: .asleep, inBed: true, confidence: 0.7), "Walking")
    }

    /// Lying awake in bed (staged wake inside the night) is in bed, however seated the wrist leans: the
    /// reported night's 2:30–2:50 a.m. stretches read "Desk sitting" at seated 0.75–0.83, and the wearer
    /// corrected every one of them to lying down.
    func testAwakeInsideTheNightIsRestingInBed() {
        let stationary = HeadProbabilities<LocomotionClass>([.stationary: 0.97, .unknown: 0.03])
        let deskLike = HeadProbabilities<ArmBehaviorClass>([.deskLike: 0.8, .quiet: 0.2])
        let seated = HeadProbabilities<PostureClass>([.seatedLikely: 0.82, .uprightStationary: 0.11, .unknown: 0.07])
        XCTAssertEqual(ActivityDisplay.derive(posture: seated, locomotion: stationary, arm: deskLike,
                                              sleep: .awake, inBed: true, confidence: 0.79), "Resting in bed")
        // Outside a night the same reading is desk sitting, as before.
        XCTAssertEqual(ActivityDisplay.derive(posture: seated, locomotion: stationary, arm: deskLike,
                                              sleep: .awake, confidence: 0.79), "Desk sitting")
    }

    // MARK: Vocabulary

    func testDeriveOnlyEverSaysAListedLabel() {
        var rng = SystemRandomNumberGeneratorSeeded(seed: 7)
        let listed = Set(ActivityDisplay.allLabels)

        func dist<C: RawRepresentable & Hashable & CaseIterable & Sendable>(_ type: C.Type, _ rng: inout SystemRandomNumberGeneratorSeeded)
            -> HeadProbabilities<C> where C.RawValue == String {
            var raw: [C: Double] = [:]
            for c in C.allCases where rng.nextUnit() < 0.6 { raw[c] = rng.nextUnit() }
            return HeadProbabilities(raw).normalized()
        }

        var seen = Set<String>()
        for _ in 0..<4000 {
            let label = ActivityDisplay.derive(
                posture: dist(PostureClass.self, &rng), locomotion: dist(LocomotionClass.self, &rng),
                arm: dist(ArmBehaviorClass.self, &rng),
                sleep: [SleepContextState.asleep, .awake, .unknown][Int(rng.nextUnit() * 3) % 3],
                confidence: rng.nextUnit())
            XCTAssertTrue(listed.contains(label), "\(label) is not in ActivityDisplay.allLabels")
            seen.insert(label)
        }
        XCTAssertGreaterThan(seen.count, 8, "the sweep should reach a good spread of labels")
        XCTAssertEqual(listed.count, ActivityDisplay.allLabels.count, "labels must be unique")
    }

    func testEveryListedLabelHasAHoldAndAGroup() {
        for label in ActivityDisplay.allLabels {
            XCTAssertGreaterThanOrEqual(ActivityDisplay.holdSeconds(to: label, default: 10), 0)
            XCTAssertFalse(ActivityDisplay.group(label).isEmpty)
        }
    }
}

/// A tiny deterministic generator so the sweep above is the same on every run.
struct SystemRandomNumberGeneratorSeeded {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func nextUnit() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state >> 11) / Double(1 << 53)
    }
}
