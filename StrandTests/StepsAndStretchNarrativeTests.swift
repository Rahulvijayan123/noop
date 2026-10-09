import XCTest
import WhoopProtocol
import StrandAnalytics
@testable import Strand

/// Today's step total through the day, and the written "How this was read" on a stretch.
final class StepsAndStretchNarrativeTests: XCTestCase {

    // MARK: Steps through the day

    /// A walk of 20 ticks in the second slice and 30 in the fourth; nothing in between. The class is "walk" (1)
    /// on every sample, so the class gate keeps all of it.
    private func samples() -> [StepSample] {
        var out: [StepSample] = []
        var counter = 100
        // Slice 0: 0...899, idle.
        out.append(StepSample(ts: 10, counter: counter, activityClass: 0))
        out.append(StepSample(ts: 800, counter: counter, activityClass: 0))
        // Slice 1: 900...1799, two ticks a second for ten seconds.
        for s in 1000...1010 { counter += 2; out.append(StepSample(ts: s, counter: counter, activityClass: 1)) }
        // Slice 3: 2700...3599, two ticks a second for fifteen seconds.
        for s in 2800...2815 { counter += 2; out.append(StepSample(ts: s, counter: counter, activityClass: 1)) }
        return out
    }

    func testCumulativeStepsRisesOnlyWhereStepsWereTaken() {
        let points = KeyMetricReadings.cumulativeSteps(samples(), from: 0, to: 3600, sliceSeconds: 900, ticksPerStep: 1)
        XCTAssertEqual(points.map(\.ts), [900, 1800, 2700, 3600])
        XCTAssertEqual(points[0].steps, 0)
        XCTAssertGreaterThan(points[1].steps, 0)
        XCTAssertEqual(points[2].steps, points[1].steps, "a slice without steps is a flat stretch")
        XCTAssertGreaterThan(points[3].steps, points[2].steps)
        XCTAssertEqual(points.sorted { $0.steps < $1.steps }, points, "the total never goes down")
    }

    func testSlicesAddUpToTheWindowTotal() {
        let all = samples()
        let whole = StepsCounter.stepsInWindow(all) ?? 0
        let points = KeyMetricReadings.cumulativeSteps(all, from: 0, to: 3600, sliceSeconds: 900, ticksPerStep: 1)
        XCTAssertEqual(points.last?.steps ?? -1, Double(whole), accuracy: 0.001)
    }

    func testTicksPerStepScalesAndNothingCountedIsEmpty() {
        let double = KeyMetricReadings.cumulativeSteps(samples(), from: 0, to: 3600, sliceSeconds: 900, ticksPerStep: 2)
        let single = KeyMetricReadings.cumulativeSteps(samples(), from: 0, to: 3600, sliceSeconds: 900, ticksPerStep: 1)
        XCTAssertEqual((double.last?.steps ?? 0) * 2, single.last?.steps ?? -1, accuracy: 0.001)
        let idle = [StepSample(ts: 1, counter: 5, activityClass: 0), StepSample(ts: 900, counter: 5, activityClass: 0)]
        XCTAssertTrue(KeyMetricReadings.cumulativeSteps(idle, from: 0, to: 3600, sliceSeconds: 900, ticksPerStep: 1).isEmpty)
        XCTAssertTrue(KeyMetricReadings.cumulativeSteps([], from: 0, to: 3600, sliceSeconds: 900, ticksPerStep: 1).isEmpty)
    }

    // MARK: Written reading

    private func input() -> StretchNarrative.Input {
        var i = StretchNarrative.Input(label: "Sitting", confidence: 0.86, durationSeconds: 1_200)
        i.posture = [.init(name: "Sitting", p: 0.86), .init(name: "Standing", p: 0.09)]
        i.movement = [.init(name: "Still", p: 0.4), .init(name: "Walking", p: 0.35)]
        i.avgHr = 64; i.minHr = 58; i.maxHr = 71
        i.meanMotionG = 0.01; i.stepTicks = 0
        i.experts = ["Activity model", "Position-change expert"]
        i.other = .init(source: "the strap's own labels", labels: [("Resting", 1_100), ("Awake", 60)])
        return i
    }

    func testEveryQuestionGetsAParagraphOfSentences() {
        let paragraphs = StretchNarrative.paragraphs(input())
        XCTAssertEqual(paragraphs.map(\.title).count, 5)
        for p in paragraphs {
            XCTAssertTrue(p.text.hasSuffix("."), p.text)
            XCTAssertFalse(p.text.contains("%%"), p.text)
        }
        let all = paragraphs.map(\.text).joined(separator: " ")
        XCTAssertTrue(all.contains("86%"))
        XCTAssertTrue(all.contains("high confidence"))
        XCTAssertTrue(all.contains("64 bpm"))
        XCTAssertTrue(all.contains("did not move"))
    }

    func testAWeakCallSaysSoAndAnUnsureHeadNamesTheClosest() {
        var i = input()
        i.confidence = 0.4
        i.posture = [.init(name: "Sitting", p: 0.4), .init(name: "Standing", p: 0.35)]
        let paragraphs = StretchNarrative.paragraphs(i)
        XCTAssertTrue(paragraphs[0].text.contains("best guess"))
        XCTAssertTrue(paragraphs[1].text.contains("No single posture stood out"))
        XCTAssertTrue(paragraphs[1].text.contains("sitting (40%)"))
    }

    func testDisagreementIsWordedAsADifference() {
        var i = input()
        i.other = .init(source: "the strap's own labels", labels: [("Walking", 900)])
        let text = StretchNarrative.agreement(i)?.text ?? ""
        XCTAssertTrue(text.hasPrefix("Not quite."), text)
        XCTAssertNil(StretchNarrative.agreement({ var j = input(); j.other = nil; return j }()))
    }

    func testAStrapStretchCitesItsBasis() {
        var i = StretchNarrative.Input(label: "Walking", confidence: nil, durationSeconds: 300)
        i.strapBasis = "The strap labelled this walking"
        let first = StretchNarrative.paragraphs(i).first
        XCTAssertEqual(first?.title, "What was decided")
        XCTAssertTrue(first?.text.contains("The strap labelled this walking.") == true, first?.text ?? "")
    }
}
