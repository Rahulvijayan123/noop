import Foundation
import XCTest
@testable import StrandAnalytics

/// Prints the evaluation tables of `docs/physiology-context/notes/statistics.md`. Skipped unless `PC_EVAL_REPORT=1`
/// (it runs a few hundred thousand synthetic series-days). Exact command in the notes:
///
///     PC_EVAL_REPORT=1 swift test --filter PCEvaluationReportTests
///
/// Optional: `PC_EVAL_REPLICATES` (default 400), `PC_EVAL_SENS_REPLICATES` (default 200), `PC_EVAL_SEED`
/// (default 20261005), `PC_EVAL_OUT` (also write the markdown to this path).
final class PCEvaluationReportTests: XCTestCase {
    typealias PC = PhysiologyContext

    func testPrintEvaluationReport() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PC_EVAL_REPORT"] == "1", "set PC_EVAL_REPORT=1 to print the evaluation report")
        let reps = Int(env["PC_EVAL_REPLICATES"] ?? "") ?? 400
        let sens = Int(env["PC_EVAL_SENS_REPLICATES"] ?? "") ?? 200
        let seed = UInt64(env["PC_EVAL_SEED"] ?? "") ?? 20_261_005
        let started = Date()
        let report = PC.Evaluation.report(replicates: reps, sensitivityReplicates: sens, resamples: 500, seed: seed)
        print("PC_EVAL_REPORT_BEGIN\n\(report)\nPC_EVAL_REPORT_END")
        print("PC_EVAL_REPORT_SECONDS \(Date().timeIntervalSince(started))")
        if let path = env["PC_EVAL_OUT"] { try report.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
