import XCTest
@testable import StrandAnalytics

final class StretchTargetTests: XCTestCase {

    private let t0 = 1_760_000_000

    private func episode(label: String = "Walking", start: Int? = nil, seconds: Int = 600) -> ActivityEpisode {
        let s = start ?? t0
        return ActivityEpisode(
            start: s, end: s + seconds, label: label,
            posture: HeadProbabilities([.unknown: 0.9, .uprightStationary: 0.1]),
            locomotion: HeadProbabilities([.walking: 0.8, .briskWalking: 0.15, .stationary: 0.01, .running: 0.04]),
            armBehavior: HeadProbabilities([.quiet: 1.0]),
            intensity: 0.4, confidence: 0.77, uncertainty: 0.2, sleep: .awake, wear: .onWrist)
    }

    private func segment(_ state: DayState = .still, start: Int? = nil, seconds: Int = 900) -> DayStateSegment {
        let s = start ?? t0
        return DayStateSegment(state: state, basis: .motion, start: s, end: s + seconds, avgHr: 64, minHr: 58,
                               maxHr: 80, motionG: 0.03, locomotionShare: nil, stepTicks: 2, workoutSport: nil)
    }

    func testAnActivityStretchDescribesItself() {
        let target = StretchTarget.activity(episode())
        XCTAssertEqual(target.kind, .activityContext)
        XCTAssertEqual(target.id, "activity_context:\(t0)")
        XCTAssertEqual(target.durationSeconds, 600)
        XCTAssertEqual(target.predictedLabel, "Walking")
        XCTAssertEqual(target.predictedConfidence, 0.77)
        XCTAssertEqual(target.predictedClass, ActivityClass.walking.rawValue)
    }

    func testAStrapStretchDescribesItself() {
        let target = StretchTarget.strap(segment(.sleeping))
        XCTAssertEqual(target.kind, .strapState)
        XCTAssertEqual(target.id, "strap_state:\(t0)")
        XCTAssertEqual(target.predictedLabel, "Sleeping")
        XCTAssertEqual(target.predictedClass, "sleeping")
        XCTAssertNil(target.predictedConfidence)
    }

    func testTheContextCarriesTheModelsReadingWithoutNoise() throws {
        let context = StretchTarget.activity(episode()).modelContext(
            overlapping: [.init(source: "strap_state", label: "Moving", seconds: 540)], runCount: 4)
        XCTAssertEqual(context.displayLabel, "Walking")
        XCTAssertEqual(context.confidence, 0.77)
        XCTAssertEqual(context.sleepState, "awake")
        XCTAssertEqual(context.wearState, "on_wrist")
        XCTAssertEqual(context.runCount, 4)
        XCTAssertEqual(context.locomotion?["walking"], 0.8)
        XCTAssertNil(context.locomotion?["stationary"], "classes under 2% are dropped")
        XCTAssertEqual(context.overlapping?.first?.label, "Moving")
        XCTAssertEqual(context.modelVersions?["decoder"], ActivityContextVersions.decoder)

        let data = try JSONEncoder().encode(context)
        XCTAssertLessThan(data.count, 16 * 1024)
    }

    func testAStrapContextCarriesItsBasisAndNumbers() {
        let context = StretchTarget.strap(segment(.still)).modelContext()
        XCTAssertEqual(context.basis, "motion")
        XCTAssertEqual(context.avgHr, 64)
        XCTAssertEqual(context.stepTicks, 2)
        XCTAssertNil(context.posture)
        XCTAssertNil(context.overlapping)
    }

    func testOverlapAddsUpEachLabelAndDropsSlivers() {
        func run(_ a: Int, _ b: Int, _ label: String?) -> ActivityContextRun {
            ActivityContextRun(start: t0 + a, end: t0 + b, posture: HeadProbabilities([.unknown: 1]),
                               locomotion: HeadProbabilities([.stationary: 1]),
                               armBehavior: HeadProbabilities([.quiet: 1]), intensity: nil,
                               overallConfidence: 0.5, overallUncertainty: 0.5, displayContext: label,
                               sleep: .awake, wear: .onWrist, count: 1)
        }
        let runs = [run(0, 300, "Sitting"), run(300, 330, "Walking"), run(330, 600, "Sitting"), run(600, 700, nil)]
        let overlap = StretchOverlap.activityLabels(over: t0 + 100, t0 + 650, runs: runs)
        XCTAssertEqual(overlap.map(\.label), ["Sitting", "Unclear", "Walking"])
        XCTAssertEqual(overlap.map(\.seconds), [200 + 270, 50, 30])
        XCTAssertEqual(overlap.first?.source, "activity_context")

        let sliver = StretchOverlap.activityLabels(over: t0 + 300, t0 + 310, runs: runs)
        XCTAssertTrue(sliver.isEmpty, "ten seconds is below the 20 s floor")

        let segments = [segment(.still, start: t0, seconds: 400), segment(.walking, start: t0 + 400, seconds: 200)]
        let strap = StretchOverlap.strapStates(over: t0 + 300, t0 + 500, segments: segments)
        XCTAssertEqual(strap.map(\.label), ["Still", "Walking"])
        XCTAssertEqual(strap.map(\.seconds), [100, 100])
    }
}
