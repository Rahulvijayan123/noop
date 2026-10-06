import Foundation

// ActivityContextClass.swift — the canonical, versioned activity taxonomy.
//
// The ActivityContext decoder publishes *heads* (posture, locomotion, arm behaviour): probability
// distributions, never a forced class. People — and downstream systems that want one answer per moment
// ("what was the wearer doing when this HRV window was recorded?") — need a single stable label. This file
// is that label: a closed vocabulary of machine-readable codes, a deterministic mapping from the decoder's
// output, and an honest statement of which classes this strap can actually tell apart.
//
// WHAT IS AND IS NOT ADDED. A class is only in the taxonomy when the sensors we actually have can
// distinguish it with reasonable confidence (see `ActivityClass.capabilities`):
//
//   • Sitting vs standing is NOT observable from a wrist. The wrist cannot see body height, so a still
//     awake wearer stays `stationary` ("sitting or standing") until the heads lean clearly one way —
//     and every committed `sitting` / `standing` is a likelihood the decoder already hedged.
//   • Cycling is only claimed when something *names* it: the motion encoder (HART) says so, or a cycling
//     workout covers the time. Pedalling leaves almost no wrist signature and no steps, and HR alone
//     cannot tell it from a desk under stress — so it is never inferred from HR + stillness.
//   • Higher-intensity activity is the honest name for "vigorous effort without a gait" (strength
//     circuits, rowing, HIIT …): sustained high heart rate *with* vigorous arm movement and no stride.
//   • No absolute wrist-orientation cue is used for lying down: how a strap sits on a wrist differs per
//     person, per wrist and per day, and there is no labelled data to calibrate it. Lying is therefore
//     the detected night (asleep on its sleep epochs, in bed on its wake ones), or a recumbent reading the
//     decoder reaches through a lying-down movement signature.
//
// `displayContext` strings ("Desk sitting", "Brisk walking" …) stay a *view* for people; this taxonomy is
// what code may branch on. It is derived from the heads by the same rules as the display label
// (`ActivityDisplay.derive`) but WITHOUT the label's hysteresis: the label holds a wording for 10-30 s so a
// timeline does not flicker, which would make a stored class lag the evidence it is supposed to describe
// (a run that ended 10 s ago still "running" with zero belief). The class carries its own confidence
// from the same heads.

/// Version of the taxonomy and of the display-label → class mapping. Bump when a class is added, removed
/// or renamed, when the mapping changes, or when the family-confidence rules change meaning.
public enum ActivityClassVersions {
    /// 2: `sleeping` and an in-bed `lyingDown` take their mass from the staged night and stillness, not
    /// from the posture head's recumbent lean.
    /// 3: `ActivityClassification.confidence` is the chosen class's own (subclass) posterior mass, with the
    /// family mass in `familyConfidence` (I9), so stored class confidences are derived again.
    public static let taxonomy = "act-class-3"
    /// Version of how runs become persisted intervals (merge / fold / split rules and the per-interval
    /// HR, HRV, respiration and cadence statistics). Bump when any of those rules change so stored days
    /// are derived again.
    public static let interval = "ctx-int-1"
}

/// One canonical activity state per moment. Raw values are the persisted / wire codes: never rename them.
public enum ActivityClass: String, Codable, CaseIterable, Hashable, Sendable {
    /// The strap is not on the wrist (a hard gate from wear events / pulse contact, not an estimate).
    case offWrist = "off_wrist"
    /// On a sleep epoch of a detected night and still.
    case sleeping
    /// Recumbent and awake (resting in bed, a daytime lie-down).
    case lyingDown = "lying_down"
    /// Seated: the heads lean clearly seated and the hands are not obviously at a desk. A likelihood.
    case sitting
    /// Seated with desk-like hand activity (typing, mousing, writing).
    case sittingDesk = "sitting_desk"
    /// Upright and not walking: the heads lean clearly upright. A likelihood.
    case standing
    /// Awake and still, posture unresolved: sitting or standing, the wrist cannot say which.
    case stationary
    /// Restless hands / small whole-arm movements while otherwise stationary.
    case fidgeting
    /// Whole-body movement without a sustained gait: pottering, changing position, chores.
    case lightActivity = "light_activity"
    /// Ordinary walking. Stair climbing is reported as walking too (the wrist cannot see the slope, and only
    /// the encoder ever names stairs); the underlying `locomotion` head keeps the distinction.
    case walking
    /// Walking at a pace and cadence above an ordinary stroll.
    case briskWalking = "brisk_walking"
    case running
    /// Only ever claimed when an encoder or a cycling workout names it.
    case cycling
    /// Vigorous effort without a gait (strength, rowing, HIIT, court sports …).
    case vigorousActivity = "vigorous_activity"
    /// The evidence does not support a claim. Never a guess dressed up as a class.
    case unknown

    /// Plain-language name for UI and prompts.
    public var displayName: String {
        switch self {
        case .offWrist: return "Off wrist"
        case .sleeping: return "Sleeping"
        case .lyingDown: return "Lying down"
        case .sitting: return "Sitting"
        case .sittingDesk: return "Sitting at a desk"
        case .standing: return "Standing"
        case .stationary: return "Still (sitting or standing)"
        case .fidgeting: return "Fidgeting"
        case .lightActivity: return "Light activity"
        case .walking: return "Walking"
        case .briskWalking: return "Brisk walking"
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .vigorousActivity: return "Higher-intensity activity"
        case .unknown: return "Unknown"
        }
    }

    /// Gait: the wearer is walking or running.
    public var isGait: Bool {
        switch self {
        case .walking, .briskWalking, .running: return true
        default: return false
        }
    }

    /// Whole-body movement of any kind (gait, cycling, vigorous or light activity).
    public var isMovement: Bool {
        switch self {
        case .walking, .briskWalking, .running, .cycling, .vigorousActivity, .lightActivity: return true
        default: return false
        }
    }

    /// Resting horizontally (asleep or awake).
    public var isRest: Bool { self == .sleeping || self == .lyingDown }

    /// Awake, on the wrist and not moving about: sitting, standing, still, fidgeting.
    public var isStationaryAwake: Bool {
        switch self {
        case .sitting, .sittingDesk, .standing, .stationary, .fidgeting: return true
        default: return false
        }
    }
}

// MARK: - What each class needs (the capability matrix)

/// How a class is established.
public enum ActivityClassBasis: String, Codable, Sendable {
    /// The strap's own streams are enough (motion, steps, heart rate, wear).
    case streams
    /// Needs a context the band knows better than the wrist does (a logged sleep session).
    case sessionContext = "session_context"
    /// Only ever claimed when something names it (the motion encoder, a logged workout).
    case namedByLabel = "named_by_label"
    /// A likelihood the wrist cannot confirm; reported hedged on purpose.
    case hedged
}

public struct ActivityClassCapability: Equatable, Sendable {
    public let activityClass: ActivityClass
    public let basis: ActivityClassBasis
    /// The evidence the class stands on.
    public let evidence: String
    /// What it cannot tell apart, stated plainly.
    public let limitation: String
}

extension ActivityClass {
    /// The honest capability statement for every class, in a stable order. A test pins that every class has
    /// exactly one entry, so adding a class forces writing down what it can and cannot claim.
    public static let capabilities: [ActivityClassCapability] = [
        ActivityClassCapability(activityClass: .offWrist, basis: .streams,
            evidence: "wear events (wrist-off), loss of pulse contact",
            limitation: "a quiet strap on a table is never treated as on-wrist evidence"),
        ActivityClassCapability(activityClass: .sleeping, basis: .sessionContext,
            evidence: "a sleep epoch of a detected night (the sleep stager's call) + stillness",
            limitation: "naps outside a detected session read as lying down; lying awake in bed is lying down, not sleeping"),
        ActivityClassCapability(activityClass: .lyingDown, basis: .sessionContext,
            evidence: "awake inside a detected night's in-bed window, or a recumbent mode reached through a lying-down movement signature",
            limitation: "no absolute wrist-orientation cue is used, so a daytime lie-down without a movement signature is not seen"),
        ActivityClassCapability(activityClass: .sitting, basis: .hedged,
            evidence: "stationary wrist whose posture head leans seated (reached after sitting-down movement, long quiet spells)",
            limitation: "a wrist cannot see body height: sitting vs standing is a likelihood, never a measurement"),
        ActivityClassCapability(activityClass: .sittingDesk, basis: .hedged,
            evidence: "seated lean + desk-like arm behaviour (low, steady, orientation-stable movement)",
            limitation: "typing at a standing desk looks the same; the posture lean is still only a likelihood"),
        ActivityClassCapability(activityClass: .standing, basis: .hedged,
            evidence: "stationary wrist whose posture head leans upright (typically right after walking or standing up)",
            limitation: "needs a committed upright lean; otherwise the state stays `stationary`"),
        ActivityClassCapability(activityClass: .stationary, basis: .hedged,
            evidence: "awake, on the wrist, no movement",
            limitation: "deliberately unresolved between sitting and standing"),
        ActivityClassCapability(activityClass: .fidgeting, basis: .streams,
            evidence: "bursty low-amplitude movement without gait, high burst-to-mean ratio",
            limitation: "hand tremor, restless legs and gesturing overlap; reported as a behaviour, not a cause"),
        ActivityClassCapability(activityClass: .lightActivity, basis: .streams,
            evidence: "whole-body movement without a sustained gait, or a posture-change signature",
            limitation: "chores, pacing and rearranging are not told apart"),
        ActivityClassCapability(activityClass: .walking, basis: .streams,
            evidence: "step-counter cadence 70-125/min + steady movement intensity",
            limitation: "needs the step counter (WHOOP 5/MG) or raw IMU rhythm for confident gait; WHOOP 4.0 relies on movement shape"),
        ActivityClassCapability(activityClass: .briskWalking, basis: .streams,
            evidence: "step-counter cadence 105-150/min + higher movement intensity + raised heart rate",
            limitation: "overlaps ordinary walking near 105-125/min; the runner-up reports the ambiguity"),
        ActivityClassCapability(activityClass: .running, basis: .streams,
            evidence: "step-counter cadence 135-210/min + high movement intensity, strap run label",
            limitation: "treadmill vs outdoor and speed are not distinguished"),
        ActivityClassCapability(activityClass: .cycling, basis: .namedByLabel,
            evidence: "the motion encoder names cycling, or a cycling workout covers the time (plus compatible movement and heart rate)",
            limitation: "never inferred from heart rate and stillness: pedalling leaves almost no wrist or step signature"),
        ActivityClassCapability(activityClass: .vigorousActivity, basis: .streams,
            evidence: "sustained heart rate >= ~45% of reserve + vigorous arm movement + no gait (rising or steady, not recovering), or a logged workout",
            limitation: "the activity itself (rowing, lifting, HIIT, a ball sport) is not named"),
        ActivityClassCapability(activityClass: .unknown, basis: .streams,
            evidence: "conflicting or missing evidence",
            limitation: "carries no claim; the best guess is reported as the runner-up"),
    ]
}

// MARK: - Classification result

/// One canonical answer with its uncertainty.
public struct ActivityClassification: Equatable, Sendable {
    public var activityClass: ActivityClass
    /// Belief in the *specific* published class — the subclass posterior mass, not the family's
    /// (I9 / WS-06-F01 / A05). For `brisk_walking` this is the `brisk_walking` head mass; for `walking`
    /// it is `walking` plus the folded `stairs` mass (stairs are reported as walking). The walking-family
    /// mass (walking + brisk walking + stairs) is published separately in `familyConfidence`.
    /// 0 for `unknown` (no claim). Range 0…1.
    public var confidence: Double
    /// Belief in the class's *family* (the body state behind the wording): the walking family for
    /// `walking` and `brisk_walking` alike, the seated family for `sitting`/`sitting_desk`, and equal to
    /// `confidence` for classes whose family is the class itself. Range 0…1.
    public var familyConfidence: Double
    /// The best alternative reading and its mass; nil when the evidence offers nothing else.
    public var runnerUp: ActivityClass?
    public var runnerUpConfidence: Double
    /// How good the evidence behind the whole reading was (the decoder's overall confidence: sensor
    /// coverage, agreement between channels, warm-up). A confident class over thin evidence has a low value.
    public var evidenceQuality: Double
    /// The top (non-unknown) class of each head, for consumers that want the underlying structure — e.g. a
    /// `fidgeting` reading is upright or seated depending on `posture`.
    public var posture: PostureClass?
    public var locomotion: LocomotionClass?
    public var armBehavior: ArmBehaviorClass?

    public init(activityClass: ActivityClass, confidence: Double, familyConfidence: Double = 0,
                runnerUp: ActivityClass? = nil,
                runnerUpConfidence: Double = 0, evidenceQuality: Double = 0,
                posture: PostureClass? = nil, locomotion: LocomotionClass? = nil,
                armBehavior: ArmBehaviorClass? = nil) {
        self.activityClass = activityClass; self.confidence = confidence
        self.familyConfidence = familyConfidence
        self.runnerUp = runnerUp; self.runnerUpConfidence = runnerUpConfidence
        self.evidenceQuality = evidenceQuality
        self.posture = posture; self.locomotion = locomotion; self.armBehavior = armBehavior
    }
}

// MARK: - Classifier

public enum ActivityClassifier {

    /// The display label → class mapping. Total over `ActivityDisplay.allLabels` (a test pins it), and
    /// anything unrecognised — a future label an older reader does not know — is `unknown`, never a guess.
    public static func activityClass(forDisplayLabel label: String?) -> ActivityClass {
        guard let label else { return .unknown }
        switch label {
        case ActivityDisplay.offWrist: return .offWrist
        case ActivityDisplay.unclear: return .unknown
        case "Running": return .running
        case "Brisk walking": return .briskWalking
        case "Walking", "Taking stairs": return .walking
        case "Cycling": return .cycling
        // Riding in a vehicle is seated; the wrist reads vibration, not posture.
        case "In a vehicle": return .sitting
        case "Exercising": return .vigorousActivity
        case "Moving", "Changing position": return .lightActivity
        case "Asleep": return .sleeping
        case "Resting in bed", "Lying down": return .lyingDown
        case "Desk sitting": return .sittingDesk
        case "Sitting quietly", "Sitting, repetitive hand activity", "Sitting, gesturing", "Sitting (likely)":
            return .sitting
        case "Standing quietly", "Standing, gesturing", "Standing, repetitive hand activity",
             "Standing, hands busy", "Standing (likely)":
            return .standing
        case "Sitting, restless", "Standing, restless": return .fidgeting
        case "Still, sitting or standing", "Hands busy, sitting or standing", "Stationary":
            return .stationary
        default: return .unknown
        }
    }

    /// Classify from the decoder's heads.
    ///
    /// The class is the display rules' reading of the heads *at this instant* (no label hysteresis) and its
    /// confidence is the belief mass of the body state it names. That keeps "Sitting, restless" and
    /// "Sitting quietly" as one seated belief rather than splitting it by hand-pattern wording the run
    /// average cannot hold steady.
    public static func classify(posture: HeadProbabilities<PostureClass>,
                                locomotion: HeadProbabilities<LocomotionClass>,
                                armBehavior: HeadProbabilities<ArmBehaviorClass>,
                                sleep: SleepContextState,
                                inBed: Bool = false,
                                wear: WearContextState,
                                evidenceQuality: Double) -> ActivityClassification {
        let quality = min(1, max(0, evidenceQuality))
        if wear == .offWrist {
            return ActivityClassification(activityClass: .offWrist, confidence: 1, familyConfidence: 1,
                                         evidenceQuality: quality)
        }

        let label = ActivityDisplay.derive(posture: posture, locomotion: locomotion, arm: armBehavior,
                                           sleep: sleep, inBed: inBed, confidence: quality)
        let cls = activityClass(forDisplayLabel: label)
        let stationary = locomotion[.stationary]
        let recumbent = posture[.recumbent], seated = posture[.seatedLikely]
        let upright = posture[.uprightStationary], transition = posture[.posturalTransition]
        let unresolved = posture[.unknown]
        let other = locomotion[.other]
        // `Exercising` needs the arm head's exercise motion at 0.4 (the display rule); the same ramp splits
        // the non-gait mass into vigorous and light so the runner-up can name the sibling.
        let exerciseShare = min(1, max(0, armBehavior[.exerciseMotion] / 0.4))
        let walkFamily = locomotion[.walking] + locomotion[.briskWalking] + locomotion[.stairs]
        // Asleep and in bed are the staged night's claims, so their mass is the stillness that confirms
        // them, not the posture head's lean (which reads a still sleeper as seated; see `ActivityDisplay`).
        let lying = (sleep == .asleep || inBed) ? stationary : stationary * recumbent

        var candidates: [ActivityClass: Double] = [
            .running: locomotion[.running],
            .briskWalking: locomotion[.briskWalking],
            .walking: locomotion[.walking] + locomotion[.stairs],
            .cycling: locomotion[.cycling],
            .vigorousActivity: other * exerciseShare,
            .lightActivity: other * (1 - exerciseShare) + stationary * transition,
            .sitting: stationary * seated + locomotion[.vehicleMotion],
            .standing: stationary * upright,
            .stationary: stationary * unresolved,
        ]
        if sleep == .asleep { candidates[.sleeping] = lying }
        else { candidates[.lyingDown] = lying }

        // `confidence` is the published class's own (subclass) mass; `family` is the family mass the
        // label is chosen on (I9 / WS-06-F01 / A05). They differ only for the walking speed subclasses.
        let confidence: Double
        let family: Double
        var sameFamily: Set<ActivityClass> = [cls]
        switch cls {
        case .offWrist: confidence = 1; family = 1
        case .unknown: confidence = 0; family = 0
        case .running: confidence = locomotion[.running]; family = confidence
        case .walking, .briskWalking:
            confidence = cls == .briskWalking ? locomotion[.briskWalking] : locomotion[.walking] + locomotion[.stairs]
            family = walkFamily
        case .cycling: confidence = locomotion[.cycling]; family = confidence
        case .vigorousActivity: confidence = other; family = confidence
        case .lightActivity: confidence = other + stationary * transition; family = confidence
        case .sleeping: confidence = lying; family = confidence; sameFamily = [.sleeping, .lyingDown]
        case .lyingDown: confidence = lying; family = confidence; sameFamily = [.sleeping, .lyingDown]
        case .sitting, .sittingDesk:
            confidence = stationary * seated + locomotion[.vehicleMotion]
            family = confidence
            sameFamily = [.sitting, .sittingDesk]
        case .standing: confidence = stationary * upright; family = confidence
        case .fidgeting: confidence = stationary * (seated + upright); family = confidence
        case .stationary: confidence = stationary * (1 - recumbent); family = confidence
        }

        var runnerUp: ActivityClass?
        var runnerUpMass = 0.0
        for c in ActivityClass.allCases {
            guard !sameFamily.contains(c), let mass = candidates[c], mass > runnerUpMass else { continue }
            runnerUp = c; runnerUpMass = mass
        }
        if runnerUpMass < 0.02 { runnerUp = nil; runnerUpMass = 0 }

        return ActivityClassification(
            activityClass: cls, confidence: min(1, max(0, confidence)),
            familyConfidence: min(1, max(0, family)),
            runnerUp: runnerUp, runnerUpConfidence: min(1, runnerUpMass), evidenceQuality: quality,
            posture: posture.top(excluding: .unknown)?.0,
            locomotion: locomotion.top(excluding: .unknown)?.0,
            armBehavior: armBehavior.top(excluding: .unknown)?.0)
    }

    public static func classify(run: ActivityContextRun) -> ActivityClassification {
        classify(posture: run.posture, locomotion: run.locomotion, armBehavior: run.armBehavior,
                 sleep: run.sleep, inBed: run.inBed, wear: run.wear, evidenceQuality: run.overallConfidence)
    }

    public static func classify(state: ActivityContextState) -> ActivityClassification {
        classify(posture: state.posture, locomotion: state.locomotion, armBehavior: state.armBehavior,
                 sleep: state.sleep.state, inBed: state.sleep.inBed, wear: state.wear.state,
                 evidenceQuality: state.overallConfidence)
    }
}
