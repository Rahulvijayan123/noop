import XCTest
@testable import StrandAnalytics

/// hsmm-1.9: a sitting / standing / restless claim carries more than the wrist-only ceiling only when a learned
/// posture source AGREES with it (`ActivityEvidenceSummary.learnedPosture`), and then no more than the softer
/// learned ceiling. Presence of a learned source is not agreement. Event detection is the decoder's and is never
/// touched by the confidence caps.
final class ActivityContextPostureAgreementTests: XCTestCase {

    private let wristCap = ActivityClassifier.wristOnlyPostureConfidenceCap
    private let learnedCap = ActivityClassifier.learnedPostureConfidenceCap
    private let postureClaims: Set<ActivityClass> = [.sitting, .sittingDesk, .standing, .fidgeting]

    /// HART's fine distribution every 2 s, leaning to `activity` ("sitting", "standing", …).
    private func hart(_ activity: String) -> (Int) -> MotionEncoderOutput? {
        { ts in
            guard ts % 2 == 0 else { return nil }
            var fine: [String: Double] = ["sitting": 0.04, "standing": 0.04, "typing": 0.04, "walking": 0.02]
            fine[activity] = 0.86
            return MotionEncoderOutput(encoderId: "hart", encoderVersion: "t", startTs: ts - 4, endTs: ts,
                                       classProbs: ["stationary": 0.9, "other_movement": 0.08, "walking": 0.02],
                                       calibrated: true, abstained: false, fineProbs: fine)
        }
    }

    /// A walk, a sit-down whose direction the forearm shows, then restless hands for 15 minutes: the strongest
    /// wrist-only case for "Sitting, restless" the simulator has.
    private func sitDownThenFidget(encoder: ((Int) -> MotionEncoderOutput?)? = nil) -> [ActivityObservation] {
        var sim = ActivitySim(seed: 51)
        var opt = ActivitySim.Options()
        opt.encoder = encoder
        sim.forearm(0.9)
        sim.walk(90, opt: opt)
        sim.still(8, opt: opt)
        sim.postureShift(netDegrees: 45, toForearm: 0.2, opt: opt)
        sim.fidget(900, opt: opt)
        sim.desk(300, opt: opt)
        return sim.observations
    }

    private func decode(_ obs: [ActivityObservation]) -> ActivityContextTrack {
        ActivityContextTrackBuilder.decode(obs, config: ActivityDecoderConfig())
    }

    private func summary(_ track: ActivityContextTrack) -> String {
        let ks = track.states.map(ActivityClassifier.classify(state:))
        var byClass: [String: (n: Int, max: Double)] = [:]
        for k in ks {
            let e = byClass[k.activityClass.rawValue] ?? (0, 0)
            byClass[k.activityClass.rawValue] = (e.n + 1, max(e.max, k.confidence))
        }
        let learned = Dictionary(grouping: track.states, by: { $0.evidence.learnedPosture?.rawValue ?? "nil" }).mapValues(\.count)
        return "classes \(byClass.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.n)@\(String(format: "%.3f", $0.value.max))" }) learned \(learned)"
    }

    func testWristOnlyFidgetingStaysAtOrBelowTheWristCap() {
        let track = decode(sitDownThenFidget())
        print("AGREEMENT wrist-only", summary(track))
        XCTAssertTrue(track.states.allSatisfy { $0.evidence.learnedPosture == nil },
                      "no learned source spoke, so nothing can agree")
        let claims = track.states.map(ActivityClassifier.classify(state:)).filter { postureClaims.contains($0.activityClass) }
        XCTAssertFalse(claims.isEmpty, "the scenario does commit a posture")
        for k in claims { XCTAssertLessThanOrEqual(k.confidence, wristCap + 1e-12, "\(k.activityClass)") }
        for r in ActivityContextRuns.coalesce(track.states) {
            let k = ActivityClassifier.classify(run: r)
            if postureClaims.contains(k.activityClass) { XCTAssertLessThanOrEqual(k.confidence, wristCap + 1e-12) }
        }
        for iv in ActivityContextIntervalBuilder.build(runs: ActivityContextRuns.coalesce(track.states))
        where postureClaims.contains(iv.activityClass) {
            XCTAssertLessThanOrEqual(iv.confidence, wristCap + 1e-9)
        }
    }

    func testAnAgreeingLearnedSourceRaisesOnlyToTheSofterCap() {
        let track = decode(sitDownThenFidget(encoder: hart("sitting")))
        print("AGREEMENT hart sitting", summary(track))
        XCTAssertTrue(track.states.contains { $0.evidence.learnedPosture == .seatedLikely },
                      "HART naming sitting second after second is learned agreement with seated")
        XCTAssertFalse(track.states.contains { $0.evidence.learnedPosture == .uprightStationary })
        for s in track.states {
            let k = ActivityClassifier.classify(state: s)
            guard postureClaims.contains(k.activityClass) else { continue }
            XCTAssertLessThanOrEqual(k.confidence, learnedCap + 1e-12)
            if s.evidence.learnedPosture != k.posture {
                XCTAssertLessThanOrEqual(k.confidence, wristCap + 1e-12, "without agreement, the wrist cap")
            }
        }
    }

    func testADisagreeingLearnedSourceDoesNotRaiseConfidence() {
        // HART says standing throughout while the wrist shows a sit-down and seated hands.
        let track = decode(sitDownThenFidget(encoder: hart("standing")))
        print("AGREEMENT hart standing", summary(track))
        for s in track.states {
            let k = ActivityClassifier.classify(state: s)
            guard postureClaims.contains(k.activityClass) else { continue }
            if k.posture == .seatedLikely {
                XCTAssertNotEqual(s.evidence.learnedPosture, .seatedLikely)
                XCTAssertLessThanOrEqual(k.confidence, wristCap + 1e-12, "a disagreeing source never lifts the cap")
            }
        }
        // HART spoke (the hsmm-1.8 rule would have lifted the cap on its presence alone).
        XCTAssertTrue(track.states.contains { ActivityClassifier.learnedPostureEvidence(experts: $0.evidence.experts) })
    }

    /// A stand of 5, 10 or 15 s between two desk stretches, direction visible on the forearm both ways: the caps
    /// are on class confidence only, so both changes of position are still flagged, and with a learned source
    /// that names standing during the stand the heads may lean upright and the confidence may rise to the softer
    /// cap (never above it).
    func testShortStandsKeepTheirEventsAndAStandingReadingWhereEvidenceSupportsIt() {
        for standS in [5, 10, 15] {
            for withHart in [false, true] {
                var sim = ActivitySim(seed: 60 + UInt64(standS))
                var seat = ActivitySim.Options(), stand = ActivitySim.Options()
                if withHart { seat.encoder = hart("typing"); stand.encoder = hart("standing") }
                sim.forearm(0.2)
                sim.desk(300, opt: seat)
                let up = sim.ts
                sim.postureShift(netDegrees: -75, seconds: 3, toForearm: 0.9, opt: stand)
                sim.still(standS, opt: stand)
                sim.postureShift(netDegrees: 75, seconds: 3, toForearm: 0.2, opt: seat)
                sim.desk(120, opt: seat)
                let track = decode(sim.observations)
                let events = track.events.filter { $0.ts >= up - 2 && $0.ts <= up + standS + 20 }
                let kinds = Set(events.map(\.kind))
                let during = track.states.filter { $0.ts > up + 3 && $0.ts <= up + 3 + standS + 4 }
                let ks = during.map(ActivityClassifier.classify(state:))
                print("SHORTSTAND \(standS)s hart=\(withHart) events=\(events.map { "\($0.kind)@\($0.ts - up)" }) "
                      + "labels=\(during.map { $0.displayContext ?? "-" }) "
                      + "classes=\(ks.map { "\($0.activityClass.rawValue):\(String(format: "%.2f", $0.confidence))" }) "
                      + "learned=\(during.map { $0.evidence.learnedPosture?.rawValue ?? "-" })")
                // The stand-up is flagged at every length; the sit-back once the stand is long enough for its own
                // shift to be told from the stand-up's (at 5 s the two bursts merge into one change of position).
                XCTAssertTrue(kinds.contains(.sitToStandLike), "\(standS) s stand, hart \(withHart): stand-up flagged \(kinds)")
                if standS >= 10 {
                    XCTAssertTrue(kinds.contains(.standToSitLike), "\(standS) s stand, hart \(withHart): sit-back flagged \(kinds)")
                    // Once the display hold has passed (the first state after the stand-up still shows the desk), the
                    // stand is not shown as sitting.
                    let held = track.states.filter { $0.ts >= up + 9 && $0.ts <= up + standS + 4 }
                    XCTAssertFalse(held.isEmpty)
                    XCTAssertFalse(held.contains { ActivityDisplay.group($0.displayContext ?? "") == "seated" },
                                   "\(standS) s stand, hart \(withHart): the stand is not shown as sitting")
                }
                if standS >= 15 && withHart {
                    // A learned source naming standing through the stand agrees with the upright lean: the stand is
                    // read as standing, at no more than the softer cap.
                    XCTAssertTrue(during.contains { $0.evidence.learnedPosture == .uprightStationary })
                    XCTAssertTrue(ks.contains { $0.activityClass == .standing },
                                  "a supported 15 s stand reads as standing: \(ks.map(\.activityClass))")
                }
                for k in ks where postureClaims.contains(k.activityClass) {
                    XCTAssertLessThanOrEqual(k.confidence, learnedCap + 1e-12)
                }
            }
        }
    }
}
