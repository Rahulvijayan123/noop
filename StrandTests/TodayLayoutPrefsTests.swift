import XCTest
@testable import Strand

/// Twin of the Android `TodayLayoutPrefsTest` (#today-layout): default order, encode/decode round-trip,
/// reorder, and the never-hide "insert missing section at its default position" invariant — pinned on both
/// platforms so the byte-identical "today.sectionOrder" wire format can't drift.
///
/// Key metrics, Recovery vitals and Your cards were retired from the Apple Today screens. Orders and hidden
/// sets saved while they existed must still decode cleanly, so several cases below feed the retired tokens
/// in on purpose.
final class TodayLayoutPrefsTests: XCTestCase {

    func testEmptyOrUnsetYieldsDefaultOrder() {
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder(""), TodaySection.defaultOrder)
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder("   "), TodaySection.defaultOrder)
    }

    func testEncodeDecodeRoundTripsAReorderedList() {
        let reordered: [TodaySection] = [
            .heartRate, .hero, .liveSession, .synthesis, .workouts, .journal, .menstrualCycle, .addedCards,
        ]
        let encoded = TodayLayoutPrefs.encode(reordered)
        XCTAssertEqual(encoded, "heartRate,hero,liveSession,synthesis,workouts,journal,menstrualCycle,addedCards")
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder(encoded), reordered)
    }

    /// The v1 upgrade path: an order saved by the FIRST cut (six sections — no hero/liveSession, which were
    /// pinned then, and three that have since been retired) must surface the two pinned sections at the TOP
    /// (their default position), not teleport them to the bottom of the user's saved order, and must drop
    /// the retired tokens without disturbing what remains.
    func testSavedOrderFromFirstCutInsertsHeroAndSessionAtTheirDefaultPosition() {
        let firstCut = "synthesis,keyMetrics,workouts,heartRate,recoveryVitals,yourCards"
        XCTAssertEqual(
            TodayLayoutPrefs.decodeOrder(firstCut),
            [.hero, .liveSession, .synthesis, .workouts, .heartRate, .menstrualCycle, .journal, .addedCards]
        )
    }

    func testInsertsAnyMissingSectionAtItsDefaultPositionRelativeToSaved() {
        let partial = "heartRate,synthesis,keyMetrics,recoveryVitals"
        XCTAssertEqual(
            TodayLayoutPrefs.decodeOrder(partial),
            [.hero, .liveSession, .workouts, .heartRate, .synthesis, .menstrualCycle, .journal, .addedCards]
        )
    }

    func testDropsUnknownTokensAndCollapsesDuplicates() {
        let messy = "heartRate,BOGUS,heartRate,workouts, ,workouts"
        XCTAssertEqual(
            TodayLayoutPrefs.decodeOrder(messy),
            [.hero, .liveSession, .synthesis, .heartRate, .workouts, .menstrualCycle, .journal, .addedCards]
        )
    }

    /// An order that names ONLY retired sections is as good as junk: the user sees the default Today, not an
    /// empty one.
    func testAnOrderNamingOnlyRetiredSectionsYieldsDefaultOrder() {
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder("keyMetrics,recoveryVitals,yourCards"), TodaySection.defaultOrder)
    }

    func testRetiredSectionsCanNeverComeBack() {
        let retired = ["keyMetrics", "recoveryVitals", "yourCards"]
        for token in retired {
            XCTAssertNil(TodaySection(rawValue: token), "\(token) was retired from Today")
        }
        XCTAssertFalse(TodayLayoutPrefs.decodeOrder(retired.joined(separator: ",")).isEmpty)
    }

    func testAllJunkYieldsDefaultOrder() {
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder("nope,,zzz"), TodaySection.defaultOrder)
    }

    func testHiddenSectionsAreExplicitReversibleAndDeduplicated() {
        let hidden = TodayLayoutPrefs.decodeHidden("workouts,BOGUS,workouts,journal")
        XCTAssertEqual(hidden, [.workouts, .journal])
        XCTAssertEqual(TodayLayoutPrefs.encodeHidden(hidden), "workouts,journal")
    }

    /// A section hidden before it was retired is simply gone from the set; nothing else is hidden by accident.
    func testHiddenSetDropsRetiredSections() {
        XCTAssertEqual(TodayLayoutPrefs.decodeHidden("keyMetrics,recoveryVitals,yourCards,workouts"), [.workouts])
        XCTAssertEqual(TodayLayoutPrefs.decodeHidden("keyMetrics,yourCards"), [])
    }

    func testVisibleOrderFiltersHiddenWithoutChangingSavedOrder() {
        let order = "heartRate,hero,liveSession,synthesis,workouts,journal"
        XCTAssertEqual(
            TodayLayoutPrefs.visibleOrder(orderRaw: order, hiddenRaw: "hero,workouts"),
            [.heartRate, .liveSession, .synthesis, .menstrualCycle, .journal, .addedCards]
        )
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder(order), [
            .heartRate, .hero, .liveSession, .synthesis, .workouts, .menstrualCycle, .journal, .addedCards,
        ])
    }

    func testNewOrPreviouslyMissingSectionsDefaultToVisible() {
        XCTAssertTrue(
            TodayLayoutPrefs.visibleOrder(
                orderRaw: "synthesis,keyMetrics,workouts,heartRate,recoveryVitals,yourCards",
                hiddenRaw: "workouts"
            ).contains(.journal)
        )
    }

    /// defaultOrder must cover EVERY case: the never-hide merge iterates it, so a case missing from the
    /// default order could otherwise be dropped from render (Android) or mis-sorted (iOS).
    func testDefaultOrderCoversEveryCase() {
        XCTAssertEqual(Set(TodaySection.defaultOrder), Set(TodaySection.allCases))
        XCTAssertEqual(TodaySection.defaultOrder.count, TodaySection.allCases.count)
    }

    func testSectionRawKeysAreStableAndUnique() {
        let raws = TodaySection.allCases.map(\.rawValue)
        XCTAssertEqual(raws.count, Set(raws).count, "raw keys must be unique (they're the persisted identity)")
        // Pin the exact wire strings — each must match the Android TodaySection spelling byte-for-byte
        // (Android still defines the three retired keys; they are simply absent here).
        XCTAssertEqual(
            raws,
            ["hero", "liveSession", "synthesis", "workouts", "heartRate", "menstrualCycle", "journal", "addedCards"]
        )
    }

    func testEditableLayoutHidesAndRestoresWithoutDeleting() {
        var draft = EditableLayoutDraft(
            visible: TodaySection.defaultOrder,
            allItems: TodaySection.defaultOrder
        )

        draft.hide(.workouts)
        XCTAssertFalse(draft.visible.contains(.workouts))
        XCTAssertEqual(draft.hidden, [.workouts])

        draft.show(.workouts)
        XCTAssertEqual(draft.visible.last, .workouts)
        XCTAssertTrue(draft.hidden.isEmpty)
        XCTAssertEqual(Set(draft.visible), Set(TodaySection.defaultOrder))
    }

    func testEditableLayoutKeepsAtLeastOneItemVisible() {
        var draft = EditableLayoutDraft(visible: [KeyMetric.hrv], hidden: KeyMetric.defaultOrder.filter { $0 != .hrv })
        draft.hide(.hrv)
        XCTAssertEqual(draft.visible, [.hrv])
    }
}
