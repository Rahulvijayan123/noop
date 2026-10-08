import XCTest
@testable import Strand

/// WP7 app wiring that the package tests cannot see: each Charge night is scored against its own as-of
/// baseline (D4-01), the daytime-stress lens folds past days with their sleep / activity context and
/// holds strapless days (D4-05, run1 D4-14), and the stress-onset call site supplies stored context
/// (D6-04). The math is pinned in StrandAnalytics; this pins that the app actually calls it.
final class CausalBaselineWiringTests: XCTestCase {
    private func source(_ path: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testChargePassScoresEachNightAgainstItsOwnAsOfBaseline() throws {
        let engine = try source("Strand/Data/IntelligenceEngine.swift")
        XCTAssertTrue(engine.contains("Baselines.chargeBaselinesAsOf("))
        XCTAssertTrue(engine.contains("chargeAsOf.byDay[night.daily.day] ?? noBaselines"))
        XCTAssertTrue(engine.contains("baselineAsOfDay: asOf.hrvAsOfDay, baselineFallbackUsed: asOf.fallbackUsed"))
        // The single end-of-history fold that every night used to be scored against is gone.
        XCTAssertFalse(engine.contains("hrv: Baselines.foldHistory(hrvSeq, dayKeys: hrvDayKeys"))
    }

    func testDaytimeLensFoldsWithContextAndHoldsEmptyDays() throws {
        let mode = try source("Strand/Data/DaytimeStressMode.swift")
        XCTAssertTrue(mode.contains("aggregates.append((hr: nil, rmssd: nil))"))
        XCTAssertTrue(mode.contains("DaytimeStress.dayDaytimeAggregate(hr: dayHR, rr: dayRR, tzOffsetSeconds: dayTz,\n"
                                    + "                                                      context: context)"))
    }

    func testStressOnsetCallSiteSuppliesStoredContext() throws {
        let app = try source("Strand/App/AppModel.swift")
        XCTAssertTrue(app.contains("context: StressOnsetDetector.liveContext(intervals: stressContextIntervals, nowSec: nowSec)"))
        XCTAssertTrue(app.contains("decision.stillnessVerified"))
    }
}
