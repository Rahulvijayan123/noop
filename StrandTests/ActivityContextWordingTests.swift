import XCTest
import StrandAnalytics
@testable import Strand

/// The Heart rate page's ActivityContext wording and colour families stay in step with the package's
/// vocabulary: a label the decoder can say always lands in a deliberate family, and every class has a name.
final class ActivityContextWordingTests: XCTestCase {

    func testEveryLabelTheDecoderCanSayHasADeliberateFamily() {
        for label in ActivityDisplay.allLabels {
            let family = ActivityFamily.of(label)
            if label == ActivityDisplay.unclear {
                XCTAssertEqual(family, .unclear)
            } else {
                XCTAssertNotEqual(family, .unclear, "\(label) fell through to the unclear family")
            }
        }
    }

    func testFamiliesGroupTheWayAReaderWould() {
        XCTAssertEqual(ActivityFamily.of("Desk sitting"), .sitting)
        XCTAssertEqual(ActivityFamily.of("Sitting, restless"), .sitting)
        XCTAssertEqual(ActivityFamily.of("Sitting (likely)"), .sitting)
        XCTAssertEqual(ActivityFamily.of("Standing quietly"), .standing)
        XCTAssertEqual(ActivityFamily.of("Standing, hands busy"), .standing)
        XCTAssertEqual(ActivityFamily.of("Still, sitting or standing"), .stillUnsure)
        XCTAssertEqual(ActivityFamily.of("Stationary"), .stillUnsure)
        XCTAssertEqual(ActivityFamily.of("Walking"), .walking)
        XCTAssertEqual(ActivityFamily.of("Brisk walking"), .walking)
        XCTAssertEqual(ActivityFamily.of("Taking stairs"), .walking)
        XCTAssertEqual(ActivityFamily.of("Running"), .running)
        XCTAssertEqual(ActivityFamily.of("Cycling"), .otherMovement)
        XCTAssertEqual(ActivityFamily.of("Asleep"), .asleep)
        XCTAssertEqual(ActivityFamily.of("Resting in bed"), .asleep)
        XCTAssertEqual(ActivityFamily.of("Changing position"), .changing)
        XCTAssertEqual(ActivityFamily.of(ActivityDisplay.offWrist), .offWrist)
    }

    func testAnUnknownLabelIsUnclearRatherThanMiscoloured() {
        XCTAssertEqual(ActivityFamily.of("Typing"), .unclear)
        XCTAssertEqual(ActivityFamily.of(""), .unclear)
    }

    func testEveryFamilyIsInTheLegendOrderExactlyOnce() {
        XCTAssertEqual(Set(ActivityFamily.displayOrder), Set(ActivityFamily.allCases))
        XCTAssertEqual(ActivityFamily.displayOrder.count, ActivityFamily.allCases.count)
        for family in ActivityFamily.allCases {
            XCTAssertFalse(family.title.isEmpty)
            XCTAssertFalse(family.symbol.isEmpty)
        }
    }

    func testEveryClassHasAReadableName() {
        for c in PostureClass.allCases { XCTAssertFalse(c.displayName.isEmpty) }
        for c in LocomotionClass.allCases { XCTAssertFalse(c.displayName.isEmpty) }
        for c in ArmBehaviorClass.allCases { XCTAssertFalse(c.displayName.isEmpty) }
        for c in ActivityTransitionKind.allCases { XCTAssertFalse(c.displayName.isEmpty) }
        for c in SleepContextState.allCases { XCTAssertFalse(c.displayName.isEmpty) }
        for c in WearContextState.allCases { XCTAssertFalse(c.displayName.isEmpty) }
    }

    func testTheWordingNeverPromisesTyping() {
        for c in ArmBehaviorClass.allCases { XCTAssertFalse(c.displayName.lowercased().contains("typing")) }
        for label in ActivityDisplay.allLabels { XCTAssertFalse(label.lowercased().contains("typing")) }
    }
}
