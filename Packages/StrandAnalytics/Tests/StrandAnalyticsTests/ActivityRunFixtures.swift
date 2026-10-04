import XCTest
@testable import StrandAnalytics

/// Hand-built decoder runs whose heads read as a chosen situation, for tests that work on runs rather than
/// on a decoded stream. Every fixture asserts the class it is meant to read as, so a change to the display
/// rules fails here, with the fixture's name, instead of surfacing as a puzzling failure in the test using it.
enum RunKind: String {
    case desk, sitting, standing, fidgeting, lying, unclear
    case light, walking, brisk, running, cycling, vigorous
    case asleep, off

    var expectedClass: ActivityClass {
        switch self {
        case .desk: return .sittingDesk
        case .sitting: return .sitting
        case .standing: return .standing
        case .fidgeting: return .fidgeting
        case .lying: return .lyingDown
        case .unclear: return .unknown
        case .light: return .lightActivity
        case .walking: return .walking
        case .brisk: return .briskWalking
        case .running: return .running
        case .cycling: return .cycling
        case .vigorous: return .vigorousActivity
        case .asleep: return .sleeping
        case .off: return .offWrist
        }
    }
}

func fixtureRun(_ kind: RunKind, _ from: Int, _ to: Int, quality: Double = 0.8,
                intensity: Double? = 0.3, file: StaticString = #filePath, line: UInt = #line) -> ActivityContextRun {
    typealias Posture = HeadProbabilities<PostureClass>
    typealias Locomotion = HeadProbabilities<LocomotionClass>
    typealias Arm = HeadProbabilities<ArmBehaviorClass>
    let posture: Posture, locomotion: Locomotion, arm: Arm
    var sleep = SleepContextState.awake, wear = WearContextState.onWrist
    var label: String?
    var quality = quality
    let still = Locomotion([.stationary: 0.97, .unknown: 0.03])
    switch kind {
    case .desk:
        posture = Posture([.seatedLikely: 0.75, .unknown: 0.25]); locomotion = still
        arm = Arm([.deskLike: 0.6, .quiet: 0.4]); label = "Desk sitting"
    case .sitting:
        posture = Posture([.seatedLikely: 0.8, .unknown: 0.2]); locomotion = still
        arm = Arm([.quiet: 0.9, .unknown: 0.1]); label = "Sitting quietly"
    case .standing:
        posture = Posture([.uprightStationary: 0.8, .unknown: 0.2]); locomotion = still
        arm = Arm([.quiet: 0.9, .unknown: 0.1]); label = "Standing quietly"
    case .fidgeting:
        posture = Posture([.seatedLikely: 0.8, .unknown: 0.2]); locomotion = still
        arm = Arm([.fidgeting: 0.7, .quiet: 0.3]); label = "Sitting, restless"
    case .lying:
        posture = Posture([.recumbent: 0.8, .unknown: 0.2]); locomotion = still
        arm = Arm([.quiet: 1]); label = "Lying down"
    case .unclear:
        posture = Posture([.unknown: 1]); locomotion = Locomotion([.unknown: 1]); arm = Arm([.unknown: 1])
        quality = min(quality, 0.2)
    case .light:
        posture = Posture([.unknown: 1]); locomotion = Locomotion([.other: 0.8, .unknown: 0.2])
        arm = Arm([.other: 0.8, .unknown: 0.2]); label = "Moving"
    case .walking:
        posture = Posture([.unknown: 1]); locomotion = Locomotion([.walking: 0.92, .unknown: 0.08])
        arm = Arm([.other: 1]); label = "Walking"
    case .brisk:
        posture = Posture([.unknown: 1]); locomotion = Locomotion([.briskWalking: 0.9, .unknown: 0.1])
        arm = Arm([.other: 1]); label = "Brisk walking"
    case .running:
        posture = Posture([.unknown: 1]); locomotion = Locomotion([.running: 0.92, .unknown: 0.08])
        arm = Arm([.other: 1]); label = "Running"
    case .cycling:
        posture = Posture([.unknown: 1]); locomotion = Locomotion([.cycling: 0.9, .unknown: 0.1])
        arm = Arm([.other: 1]); label = "Cycling"
    case .vigorous:
        posture = Posture([.unknown: 1]); locomotion = Locomotion([.other: 0.8, .unknown: 0.2])
        arm = Arm([.exerciseMotion: 0.7, .other: 0.3]); label = "Exercising"
    case .asleep:
        posture = Posture([.recumbent: 0.8, .unknown: 0.2]); locomotion = still
        arm = Arm([.quiet: 1]); sleep = .asleep; label = "Asleep"
    case .off:
        posture = Posture([.unknown: 1]); locomotion = Locomotion([.unknown: 1]); arm = Arm([.unknown: 1])
        wear = .offWrist; sleep = .unknown; label = "Off wrist"
    }
    let run = ActivityContextRun(start: from, end: to, posture: posture, locomotion: locomotion, armBehavior: arm,
                                 intensity: kind == .off ? nil : intensity, overallConfidence: quality,
                                 overallUncertainty: 1 - quality, displayContext: label, sleep: sleep,
                                 wear: wear, count: max(1, (to - from) / 5))
    XCTAssertEqual(ActivityClassifier.classify(run: run).activityClass, kind.expectedClass,
                   "fixture \(kind.rawValue) no longer reads as its class", file: file, line: line)
    return run
}

/// Consecutive runs laid end to end from `start`: `[(.desk, 600), (.walking, 30)]`.
func fixtureTimeline(from start: Int, _ segments: [(RunKind, Int)]) -> [ActivityContextRun] {
    var t = start
    var out: [ActivityContextRun] = []
    for (kind, seconds) in segments {
        out.append(fixtureRun(kind, t, t + seconds))
        t += seconds
    }
    return out
}
