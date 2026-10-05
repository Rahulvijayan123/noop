import XCTest
@testable import StrandAnalytics

/// Systems D and G through `Engine.buildDay`: bouts detected from HART epochs reach the document, its daily values,
/// the envelopes' recent-bout history and the feature evaluations, deterministically.
final class PCExertionEngineIntegrationTests: XCTestCase {
    typealias PC = PhysiologyContext

    static let day = "2026-10-01"
    static let identity = PC.DayIdentity(deviceScope: "dev-1", day: day, timezoneId: "UTC",
                                         dayWindow: PC.Engine.dayInterval(day, timezoneId: "UTC"))
    static var t0: Int { identity.dayWindow.start + 10 * 3600 }

    static func epoch(_ start: Int, _ motion: MotionLabel) -> PC.ActivityEpochInput {
        PC.ActivityEpochInput(epoch: ActivityEpoch(startTs: start, endTs: start + 30, motion: motion,
                                                   posture: .unknown, exercise: .unknown, sleepState: .unknown,
                                                   exertion: .unknown, wear: .unknown, confidence: 0.9,
                                                   observedS: 30, validS: 30),
                              revision: 1)
    }

    /// HART: stationary 30 min, walking [t0, t0+600), stationary 1 h. HR 70 / 110 / 80.
    static func input(mode: PC.ProcessingMode = .retrospective, cutoff: Int? = nil) -> PC.DayInput {
        let t0 = Self.t0
        let epochs = stride(from: t0 - 1800, to: t0 + 4200, by: 30).map { s in
            epoch(s, (t0..<(t0 + 600)).contains(s) ? .walking : .stationary)
        }
        var hr: [PC.HeartRateObservation] = []
        for ts in (t0 - 1800)..<(t0 + 4200) {
            hr.append(.init(ts: ts, bpm: ts < t0 ? 70 : (ts < t0 + 600 ? 110 : 80)))
        }
        return PC.DayInput(identity: identity, mode: mode,
                           availabilityCutoff: cutoff ?? identity.dayWindow.end + 40 * 3600,
                           generatedAt: identity.dayWindow.end + 40 * 3600, heartRate: hr, activityEpochs: epochs,
                           regime: .init(scoringAlgorithmVersion: "frwhoop-server-1"))
    }

    func testBoutFlowsThroughTheDocument() throws {
        let doc = PC.Engine.buildDay(Self.input(), history: .empty)
        XCTAssertEqual(doc.bouts.count, 1)
        let b = doc.bouts[0]
        XCTAssertEqual(b.interval, .init(Self.t0, Self.t0 + 600))
        XCTAssertEqual(b.kind, "walking")
        XCTAssertEqual(b.sourceEvidence, ["hart_epochs"])
        XCTAssertEqual(b.status, .complete)
        XCTAssertEqual(b.response?.hrRiseBpm, 40)
        XCTAssertEqual(b.recovery?.observation(at: 60)?.declineBpm, 30)

        let keys = Set(doc.dailyValues.map(\.seriesKey))
        XCTAssertTrue(keys.contains("hr_response.walking.cadence_unavailable.d600_1800s.rested"))
        XCTAssertTrue(keys.contains("hr_recovery_60s.walking"))
        XCTAssertEqual(doc.dailyValues.first { $0.seriesKey == "hr_recovery_60s.walking" }?.sourceIds, [b.id])

        // A heart-rate window after the bout carries a reference to it.
        let after = try XCTUnwrap(doc.envelopes.first { $0.metric == .heartRate && $0.support.start >= Self.t0 + 600 })
        XCTAssertEqual(after.history.recentBouts.first?.boutId, b.id)
        XCTAssertEqual(after.history.exertion.map(\.windowH), [24, 48, 72])

        XCTAssertEqual(doc.functional.boutCount, 1)
        XCTAssertTrue(doc.features.contains { $0.featureId == "specialized.gait_speed" && $0.state == "unavailable" })

        let a = try PC.encoder().encode(doc)
        XCTAssertEqual(a, try PC.encoder().encode(PC.Engine.buildDay(Self.input(), history: .empty)))
        XCTAssertEqual(try PC.decoder().decode(PC.DayDocument.self, from: a), doc)
    }

    func testCausalDocumentHasAnOngoingProvisionalBout() throws {
        let cutoff = Self.t0 + 300
        let doc = PC.Engine.buildDay(Self.input(mode: .causalLive, cutoff: cutoff), history: .empty)
        XCTAssertEqual(doc.bouts.count, 1)
        XCTAssertEqual(doc.bouts[0].status, .ongoing)
        XCTAssertEqual(doc.bouts[0].finality, .provisional)
        XCTAssertLessThanOrEqual(doc.bouts[0].interval.end, cutoff)
        XCTAssertFalse(doc.dailyValues.contains { $0.seriesKey.hasPrefix("hr_response.") })
    }
}
