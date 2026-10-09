import XCTest
import StrandAnalytics
@testable import Strand

/// Every reason-code registry the physiology context engine publishes (each system's public `reasonCodes`).
/// A new system's registry is added here when it starts emitting codes the app can show.
enum PhysiologyContextReasonRegistries {
    typealias PC = PhysiologyContext

    static let all: [(system: String, codes: [PC.ReasonCode])] = [
        ("IntervalAlgebra", PC.IntervalAlgebra.reasonCodes),
        ("Engine", PC.Engine.reasonCodes),
        ("SignalValidityEngine", PC.SignalValidityEngine.reasonCodes),
        ("MotionEvidence", PC.MotionEvidence.reasonCodes),
        ("Eligibility", PC.Eligibility.reasonCodes),
        ("SleepRhythm", PC.SleepRhythm.reasonCodes),
        ("ExertionBouts", PC.ExertionBouts.reasonCodes),
        ("Exposures", PC.Exposures.reasonCodes),
        ("ContextReferences", PC.ContextReferences.reasonCodes),
        ("ChangeDetection", PC.ChangeDetection.reasonCodes),
        ("Functional", PC.Functional.reasonCodes),
        ("PulseEpisodes", PC.PulseEpisodes.reasonCodes),
    ]

    /// Every registered code, once.
    static var codes: Set<String> { Set(all.flatMap { $0.codes.map(\.rawValue) }) }
}

/// RC-15 (review-contract): the app's reason wording matches the engine's registries exactly. Each registered
/// code has a plain phrase or is explicitly diagnostics-only, and the table carries no code the engine never
/// emits.
final class PhysiologyContextWordingCoverageTests: XCTestCase {

    typealias PC = PhysiologyContext
    typealias W = PhysiologyContextWording

    func testEveryRegisteredReasonCodeHasAPhraseOrIsDiagnosticsOnly() {
        var missing: [String] = []
        var both: [String] = []
        for (system, codes) in PhysiologyContextReasonRegistries.all {
            XCTAssertFalse(codes.isEmpty, "\(system) registers no codes")
            for code in codes {
                let phrased = W.phrase(code) != nil
                let diagnostics = W.isDiagnosticsOnly(code)
                if !phrased && !diagnostics { missing.append("\(system).\(code.rawValue)") }
                if phrased && diagnostics { both.append("\(system).\(code.rawValue)") }
            }
        }
        XCTAssertTrue(missing.isEmpty, "registered codes with no phrase and no diagnostics-only entry: \(missing)")
        XCTAssertTrue(both.isEmpty, "codes both phrased and diagnostics-only: \(both)")
        XCTAssertGreaterThanOrEqual(PhysiologyContextReasonRegistries.codes.count, 300)
    }

    func testTheTableCarriesNoCodeTheEngineNeverEmits() {
        let registered = PhysiologyContextReasonRegistries.codes
        let phrased = Set(W.reasonPhrases.keys)
        XCTAssertEqual(phrased.subtracting(registered).sorted(), [], "phrases for codes no registry emits")
        XCTAssertEqual(W.diagnosticsOnlyReasons.subtracting(registered).sorted(), [],
                       "diagnostics-only entries for codes no registry emits")
        XCTAssertEqual(phrased.union(W.diagnosticsOnlyReasons), registered)
        // The guessed names the first table carried are gone (they never matched an engine code).
        for retired in ["insufficient_stationary_share", "recent_exertion", "no_bout", "signal_missing",
                        "walking_during_support", "awake_unknown", "wear_unknown", "not_in_sleep", "not_implemented",
                        "regime_differs"] {
            XCTAssertNil(W.phrase(PC.ReasonCode(retired)), retired)
        }
    }

    func testPhrasesArePlainAndShortAndInferNothing() {
        for (code, phrase) in W.reasonPhrases.sorted(by: { $0.key < $1.key }) {
            XCTAssertFalse(phrase.isEmpty, code)
            XCTAssertFalse(phrase.hasSuffix("."), "\(code): a phrase follows \"…: \" and has no full stop")
            XCTAssertLessThanOrEqual(phrase.count, 100, "\(code): \"\(phrase)\" is not short")
            XCTAssertFalse(phrase.contains("_"), "\(code): \"\(phrase)\" reads like a code")
            if let term = W.containsForbiddenTerm(phrase) {
                XCTFail("\(code): \"\(phrase)\" uses the forbidden term \"\(term)\"")
            }
            for claim in ["recovery", "recover", "diagnos", "medicat", "symptom"] {
                XCTAssertFalse(phrase.lowercased().contains(claim), "\(code): \"\(phrase)\" makes a \(claim) claim")
            }
        }
    }

    func testEveryRegisteredCodeReadsInPlainWordsOrNotAtAll() {
        for code in PhysiologyContextReasonRegistries.codes.sorted().map({ PC.ReasonCode($0) }) {
            if W.isDiagnosticsOnly(code) {
                XCTAssertNil(W.reasonList([code]), "\(code.rawValue) is diagnostics-only")
                XCTAssertNil(W.topReason([code]), "\(code.rawValue) is diagnostics-only")
            } else {
                XCTAssertEqual(W.reason(code), W.reasonPhrases[code.rawValue], code.rawValue)
                XCTAssertEqual(W.reasonList([code]), W.capitalizedFirst(W.reason(code)), code.rawValue)
            }
        }
        // A code from a newer server still reads as words, and never smuggles in an inference.
        XCTAssertEqual(W.reason("brand_new_code"), "brand new code")
        XCTAssertEqual(W.reason("stress_index_high"), "another reason")
    }
}
