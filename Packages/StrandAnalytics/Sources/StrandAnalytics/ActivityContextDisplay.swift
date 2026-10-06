import Foundation

// ActivityContextDisplay.swift — composite labels as a DERIVED VIEW of the heads.
//
// "Desk sitting", "Standing quietly", "Brisk walking", "Resting in bed" are conveniences for people
// reading a timeline. They are not canonical state: the canonical state is the set of head
// distributions, and nothing downstream should branch on these strings. The wording stays hedged where
// the sensor cannot know: a wrist IMU cannot see body height, so a stationary period is "Sitting"
// only when the heads lean clearly that way, and "Still, sitting or standing" otherwise.

public enum ActivityDisplay {
    public static let unclear = "Unclear"
    public static let offWrist = "Off wrist"

    /// Every label `derive` (and the decoder's off-wrist gate) can produce. UI code that styles labels
    /// should cover exactly these; a test fails if `derive` ever says something that is not listed.
    public static let allLabels: [String] = [
        unclear, offWrist,
        "Running", "Walking", "Brisk walking", "Taking stairs", "Cycling", "In a vehicle", "Exercising", "Moving",
        "Asleep", "Resting in bed", "Lying down", "Changing position",
        "Desk sitting", "Sitting quietly", "Sitting, restless", "Sitting, repetitive hand activity",
        "Sitting, gesturing", "Sitting (likely)",
        "Standing quietly", "Standing, restless", "Standing, gesturing", "Standing, repetitive hand activity",
        "Standing, hands busy", "Standing (likely)",
        "Still, sitting or standing", "Hands busy, sitting or standing", "Stationary",
    ]

    /// Seconds a new label must lead before replacing the current one (0 = switch immediately).
    static func holdSeconds(to label: String, default d: Int) -> Int {
        switch label {
        case offWrist: return 0
        case unclear, "Asleep": return max(d, 15)
        default: return d
        }
    }

    /// Coarse kind of a label, used so display hysteresis treats wording changes inside a kind as one.
    static func group(_ label: String) -> String {
        switch label {
        case offWrist: return "off_wrist"
        case unclear: return "unclear"
        case "Walking", "Brisk walking", "Running", "Taking stairs", "Cycling", "In a vehicle", "Exercising", "Moving":
            return "moving"
        case "Asleep", "Resting in bed", "Lying down": return "lying"
        case "Changing position": return "transition"
        default: return "stationary"
        }
    }

    /// Derives the label from the heads. `confidence` is the decoder's overall confidence.
    public static func derive(posture: HeadProbabilities<PostureClass>,
                              locomotion: HeadProbabilities<LocomotionClass>,
                              arm: HeadProbabilities<ArmBehaviorClass>,
                              sleep: SleepContextState,
                              inBed: Bool = false,
                              confidence: Double) -> String {
        if confidence < 0.30 { return unclear }

        // Moving states first: they are the strongest and least ambiguous claims.
        let running = locomotion[.running]
        // The label is chosen on the walking FAMILY mass (walking + brisk walking + stairs, the same family
        // `ActivityClassifier` sums). The class confidence a consumer reads for the chosen label is the
        // SUBclass mass: "Brisk walking" at 0.27 means brisk walking at 0.27, not the family (I9 / A05).
        // The subclass is picked on the masses the classifier reports (brisk vs walking + stairs), so the
        // published subclass never carries less mass than its walking sibling.
        let walking = locomotion[.walking], brisk = locomotion[.briskWalking], stairs = locomotion[.stairs]
        let walkFamily = walking + brisk + stairs
        if running >= 0.5 { return "Running" }
        if walkFamily >= 0.5 {
            if stairs > max(walking, brisk) { return "Taking stairs" }
            return brisk > walking + stairs ? "Brisk walking" : "Walking"
        }
        if stairs >= 0.4 { return "Taking stairs" }
        if locomotion[.cycling] >= 0.5 { return "Cycling" }
        if locomotion[.vehicleMotion] >= 0.5 { return "In a vehicle" }
        if locomotion[.other] >= 0.5 {
            return arm[.exerciseMotion] >= 0.4 ? "Exercising" : "Moving"
        }
        guard locomotion[.stationary] >= 0.5 else { return unclear }

        // Asleep is the staged night's call, not the posture head's. `sleep` is `.asleep` only on the
        // night's sleep epochs (lying awake in bed is staged wake), and a still sleeper's wrist reads as
        // seated as often as not: no orientation cue tells lying from sitting. Letting a seated lean
        // override the night is what labelled a sleeper "Sitting quietly". Movement still wins above.
        if sleep == .asleep { return "Asleep" }
        // Awake inside the night's in-bed window, for the same reason: in bed, whatever the wrist leans.
        if inBed {
            return posture[.posturalTransition] >= 0.45 ? "Changing position" : "Resting in bed"
        }

        // Stationary: posture, then arm behaviour.
        if posture[.posturalTransition] >= 0.45 { return "Changing position" }
        if posture[.recumbent] >= 0.5 {
            switch sleep {
            case .asleep: return "Asleep"
            case .awake: return "Resting in bed"
            case .unknown: return "Lying down"
            }
        }
        let seated = posture[.seatedLikely], upright = posture[.uprightStationary]
        let armTop = arm.top(excluding: .unknown)?.0
        // Below this confidence (conflicting or thin evidence) the label stays hedged even when the
        // heads lean one way.
        let committed = confidence >= 0.55
        if committed, seated >= 0.45, seated - upright >= 0.20 {
            switch armTop {
            case .deskLike: return "Desk sitting"
            case .quiet: return "Sitting quietly"
            case .fidgeting: return "Sitting, restless"
            case .repetitiveHandMotion: return "Sitting, repetitive hand activity"
            case .activeGesturing: return "Sitting, gesturing"
            default: return "Sitting (likely)"
            }
        }
        if committed, upright >= 0.40, upright - seated >= 0.20 {
            switch armTop {
            case .quiet: return "Standing quietly"
            case .fidgeting: return "Standing, restless"
            case .activeGesturing: return "Standing, gesturing"
            case .repetitiveHandMotion: return "Standing, repetitive hand activity"
            case .deskLike: return "Standing, hands busy"
            default: return "Standing (likely)"
            }
        }
        if seated + upright >= 0.5 {
            switch armTop {
            case .quiet: return "Still, sitting or standing"
            case .deskLike: return "Hands busy, sitting or standing"
            default: return "Stationary"
            }
        }
        return unclear
    }
}
