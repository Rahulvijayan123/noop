import XCTest
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Integration of the consumer gaps: the coach reads each day's ledger standing (provisional / from an older
/// model) instead of the 300 s tail heuristic, the wearer's stretch corrections reach every reader of the saved
/// context (D9-07), and the metric explorer's activity line covers every nightly hero.
final class CoachLedgerStatusAndCorrectionsTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-01 00:00 UTC.
    private let day0 = 1_790_812_800

    private func interval(_ start: Int, _ end: Int, _ cls: ActivityClass, conf: Double = 0.8,
                          provenance: String? = nil) -> ActivityContextInterval {
        ActivityContextInterval(start: start, end: end, activityClass: cls, confidence: conf,
                                sleep: .awake, wear: .onWrist, provenance: provenance)
    }

    private func day(_ start: Int, status: ActivityContextPersistence.ServingStatus, provisional: Bool,
                     key: String) -> Repository.StoredActivityContextDay {
        Repository.StoredActivityContextDay(day: key, dayStart: start, dayEnd: start + 86_400, deviceId: "d",
                                            status: status, isProvisional: provisional, decoderVersion: "v",
                                            configTag: nil, dataThrough: start + 86_000, computedAt: start + 86_400)
    }

    private func stretchLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter { $0.hasPrefix("  ") }
    }

    // MARK: Coach: ledger standing

    func testProvisionalAndOlderModelComeFromTheLedgerNotTheTail() {
        // Day 0 is final but being re-derived (refreshing); day 1 is current but provisional.
        let day1 = day0 + 86_400
        let items = [interval(day0 + 3_600, day0 + 4_800, .sitting),
                     interval(day1 + 3_600, day1 + 4_200, .walking),
                     interval(day1 + 4_200, day1 + 5_400, .sitting)]
        let days = [day(day0, status: .refreshing, provisional: false, key: "2026-10-01"),
                    day(day1, status: .current, provisional: true, key: "2026-10-02")]
        // "now" is long after the horizon: the old heuristic would mark nothing (not within 300 s of it) except
        // by date; the ledger says the whole of day 1 is not final.
        let now = Date(timeIntervalSince1970: TimeInterval(day1 + 9_000))
        let text = CoachActivityContext.describe(intervals: items, from: day0, to: day1 + 9_000,
                                                 storedThrough: day1 + 5_400, days: days, timeZone: utc, now: now)
        let lines = stretchLines(text)
        XCTAssertEqual(lines.count, 3, text)
        XCTAssertTrue(lines[0].hasSuffix(", from an older model"), lines[0])
        XCTAssertFalse(lines[0].contains("provisional"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix(", provisional"), "every stretch of a day that is not final: \(lines[1])")
        XCTAssertTrue(lines[2].hasSuffix(", provisional"), lines[2])
        XCTAssertFalse(text.contains("older classifier with different labels"), "no stale day in the window")
    }

    func testAFinalCurrentDayIsNeverProvisionalEvenAtTodaysTail() {
        // The heuristic would tag today's newest stretch; a final ledger says it will not change.
        let items = [interval(day0 + 600, day0 + 1_200, .sitting)]
        let now = Date(timeIntervalSince1970: TimeInterval(day0 + 1_260))
        let text = CoachActivityContext.describe(intervals: items, from: day0, to: day0 + 1_260,
                                                 storedThrough: day0 + 1_200,
                                                 days: [day(day0, status: .current, provisional: false, key: "2026-10-01")],
                                                 timeZone: utc, now: now)
        XCTAssertFalse(stretchLines(text).joined().contains("provisional"), text)
        // Without a ledger read the heuristic still applies.
        let fallback = CoachActivityContext.describe(intervals: items, from: day0, to: day0 + 1_260,
                                                     storedThrough: day0 + 1_200, timeZone: utc, now: now)
        XCTAssertTrue(stretchLines(fallback).joined().contains("provisional"), fallback)
    }

    func testStaleDaysAreNamedAsUnknownNotOffWrist() {
        let day1 = day0 + 86_400
        let text = CoachActivityContext.describe(
            intervals: [interval(day1 + 600, day1 + 1_200, .sitting)], from: day0, to: day1 + 1_200,
            days: [day(day0, status: .stale, provisional: false, key: "2026-10-01"),
                   day(day1, status: .current, provisional: false, key: "2026-10-02")],
            timeZone: utc, now: Date(timeIntervalSince1970: TimeInterval(day1 + 3 * 86_400)))
        XCTAssertTrue(text.contains("Saved context for 2026-10-01 came from an older classifier"), text)
    }

    func testCorrectedStretchesAreTaggedAndCounted() {
        let items = [interval(day0, day0 + 600, .sitting),
                     interval(day0 + 600, day0 + 900, .offWrist, conf: 1, provenance: ActivityContextProvenance.userCorrection)]
        let text = CoachActivityContext.describe(intervals: items, from: day0, to: day0 + 900, timeZone: utc,
                                                 now: Date(timeIntervalSince1970: TimeInterval(day0 + 5 * 86_400)))
        let lines = stretchLines(text)
        XCTAssertFalse(lines[0].contains("corrected"), lines[0])
        XCTAssertTrue(lines[1].contains("corrected by the user"), lines[1])
        XCTAssertTrue(text.contains("5 min of this window is labelled from the user's own corrections"), text)
    }

    // MARK: Repository: corrections overlay at read time

    @MainActor
    func testStoredContextAppliesTheWearersCorrectionsWithoutRewritingTheStore() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "acx-intd-\(UUID().uuidString)"
        let repo = Repository(deviceId: deviceId)
        repo.setStoreForTesting(store)
        let d = ActivityContextMaterialization.localDays(endingAt: Int(Date().timeIntervalSince1970), count: 3,
                                                         timeZone: .current)[2]
        let ledger = ActivityContextDayRow(day: d.key, dayStart: d.start, dayEnd: d.end,
                                           taxonomyVersion: ActivityClassVersions.taxonomy,
                                           decoderVersion: ActivityContextVersions.decoder,
                                           ontologyVersion: ActivityContextVersions.ontology,
                                           intervalVersion: ActivityClassVersions.interval, dataThrough: d.start + 1_200,
                                           computedAt: d.end, featureSchema: ActivityContextVersions.featureSchema,
                                           configTag: repo.activityContextLedgerConfigTag(dayStart: d.start),
                                           finality: "final")
        try await store.replaceActivityContext(
            deviceId: deviceId, day: ledger,
            intervals: [ActivityContextIntervalRow(startTs: d.start + 600, endTs: d.start + 1_200,
                                                   activityClass: "sitting", confidence: 0.7)])
        let notWearing = StretchFeedback(kind: .activityContext, startTs: d.start + 700, endTs: d.start + 1_000,
                                         deviceId: deviceId, predictedLabel: "Sitting", predictedClass: "sitting",
                                         predictedConfidence: 0.7, verdict: .incorrect, correctedLabel: .notWearing)

        let corrected = await repo.storedActivityContextWithStatus(from: d.start, to: d.end, feedback: [notWearing])
        XCTAssertEqual(corrected.intervals.map(\.activityClass), [.sitting, .offWrist, .sitting])
        XCTAssertEqual(corrected.intervals[1].wear, .offWrist)
        XCTAssertEqual(corrected.intervals[1].provenance, "user_correction")
        XCTAssertEqual(corrected.userCorrectedSeconds, 300)
        let plain = await repo.storedActivityContext(from: d.start, to: d.end, feedback: [notWearing])
        XCTAssertEqual(plain.intervals, corrected.intervals, "both read paths carry the overlay")

        // The decoder's row is untouched in the store, and reads back as-is without corrections.
        let rows = try await store.activityContextIntervals(deviceId: deviceId, from: d.start, to: d.end)
        XCTAssertEqual(rows.map(\.activityClass), ["sitting"])
        let raw = await repo.storedActivityContextWithStatus(from: d.start, to: d.end, feedback: [])
        XCTAssertEqual(raw.intervals.map(\.activityClass), [.sitting])
        XCTAssertNil(raw.intervals[0].provenance)
    }

    func testStretchFeedbackStoreServesOnlyOverlappingCorrections() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sf-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = StretchFeedbackStore(fileURL: url)
        func f(_ s: Int, _ verdict: StretchVerdict, _ label: StretchCorrection?) -> StretchFeedback {
            StretchFeedback(kind: .activityContext, startTs: s, endTs: s + 600, deviceId: nil, predictedLabel: "Sitting",
                            predictedClass: "sitting", predictedConfidence: nil, verdict: verdict, correctedLabel: label)
        }
        store.upsert(f(day0, .incorrect, .lyingDown))
        store.upsert(f(day0 + 1_000, .correct, nil))
        store.upsert(f(day0 + 5_000, .incorrect, .standing))
        XCTAssertEqual(store.corrections(overlapping: day0, to: day0 + 2_000).map(\.correctedLabel), [.lyingDown])
    }

    // MARK: Metric explorer

    func testTheActivityLineCoversEveryNightlyHero() {
        XCTAssertEqual(MetricDetailView.activityMetrics, ActivityContextSelection.nightlyMetrics)
        XCTAssertTrue(MetricDetailView.activityMetrics.isSuperset(of: ["rhr", "skin_temp"]))
    }
}
