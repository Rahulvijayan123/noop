import XCTest
import StrandAnalytics
@testable import Strand

/// D4-09 wording: a reference borrowed from the previous strap says so and says it is provisional; the context
/// stratum reads as a likely position; `.ctx_*` series have plain names.
final class PhysiologyContextBaselinesWordingTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias W = PhysiologyContextWording

    private func reference(pooled: Double, scope: String?, reasons: [PC.ReasonCode],
                           status: PC.ReferenceStatus = .provisional) -> PC.ReferenceComparison {
        var c = PC.ReferenceComparison(day: "2026-10-01", seriesKey: "hrv_rmssd.sleep_night", regimeKey: "r1",
                                       view: .rolling, referenceId: nil, status: status, supportDays: 9,
                                       fromDay: "2026-09-04", toDay: "2026-09-30", value: 58, center: 52, scale: 6,
                                       scaleFloored: false, signedDifference: 6, transformedDifference: 0.1,
                                       robustZ: 1, centerUncertainty: 2, transform: "ln",
                                       pooledContribution: pooled, reasons: reasons)
        c.predecessorScope = scope
        return c
    }

    func testABorrowedReferenceSaysItIsFromThePreviousStrapAndProvisional() {
        let partly = reference(pooled: 0.4, scope: "device:old",
                               reasons: [PC.ContextReferences.predecessorRegime, PC.ContextReferences.pooledTowardPredecessor])
        let line = W.referenceLine(partly, units: "ms")
        XCTAssertTrue(line.contains("partly from your previous strap"), line)
        XCTAssertTrue(line.contains("provisional"), line)
        XCTAssertEqual(W.predecessorNote(partly),
                       "Partly from your previous strap, provisional until this strap has its own history")
        XCTAssertTrue(W.reasonList(partly.reasons)?.contains("previous strap") ?? false)

        let only = reference(pooled: 1, scope: "device:old",
                             reasons: [PC.ContextReferences.predecessorRegime, PC.ContextReferences.predecessorRegimeOnly])
        XCTAssertTrue(W.referenceLine(only, units: "ms").contains("(from your previous strap, provisional)"))
        XCTAssertTrue(W.predecessorNote(only)?.hasPrefix("From your previous strap only") ?? false)

        let own = reference(pooled: 0, scope: nil, reasons: [], status: .ready)
        XCTAssertNil(W.predecessorNote(own))
        XCTAssertFalse(W.referenceLine(own, units: "ms").contains("previous strap"))
    }

    func testAbstainingPredecessorReasonsReadInPlainWords() {
        for code in [PC.ContextReferences.predecessorIncompatible, PC.ContextReferences.predecessorFamilyUnknown,
                     PC.ContextReferences.predecessorStale, PC.ContextReferences.predecessorInsufficient] {
            let phrase = W.reason(code)
            XCTAssertTrue(phrase.contains("previous strap"), "\(code.rawValue): \(phrase)")
        }
    }

    func testTheContextStratumReadsAsALikelyPosition() {
        var p = PC.PostureContext(version: "pc-posture-2", stratum: .uprightLikely, basis: ["forearm_gravity"],
                                  gravityS: 300, forearmFlatShare: 0.1, inBedS: 0, heartRateDependent: false,
                                  reasons: [])
        XCTAssertNil(W.positionRow(p), "an envelope from before the context stratum shows no row")
        p.context = .seated
        p.contextBasis = [PC.PostureEvidence.basisDecoderPosture, "forearm_gravity"]
        p.contextConfidence = 0.86
        p.contextReasons = [PC.PostureEvidence.sittingStandingNotSeparatedByWrist]
        let row = W.positionRow(p, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(row?.value, "Likely sitting")
        XCTAssertTrue(row?.note?.contains("arm orientation agrees") ?? false, row?.note ?? "")
        XCTAssertTrue(row?.note?.contains("learned estimate, not a measurement") ?? false, row?.note ?? "")
        XCTAssertFalse(row?.note?.contains("_") ?? true, "no raw code reaches the page")

        p.context = .unknown
        p.contextBasis = []
        p.contextConfidence = nil
        p.contextReasons = [PC.PostureEvidence.contextBelowConfidenceFloor]
        let unknown = W.positionRow(p)
        XCTAssertEqual(unknown?.value, "Unknown")
        XCTAssertEqual(unknown?.note, "The position estimate was not confident enough")
    }

    func testContextStratumSeriesHavePlainNames() {
        XCTAssertEqual(W.series("hrv_rmssd.stable_awake_5min.ctx_seated"),
                       "HRV, stable awake measurements, likely sitting")
        XCTAssertEqual(W.series("hrv_rmssd.stable_awake_5min.ctx_recumbent_awake"),
                       "HRV, stable awake measurements, likely lying down, awake")
        XCTAssertEqual(W.series("heart_rate.stable_awake_5min.ctx_upright_stationary"),
                       "Heart rate, stable awake measurements, likely standing still")
        XCTAssertFalse(W.series("coverage.optical_valid_share").contains("_"))
    }
}
