import XCTest
import Combine
@testable import Strand

/// The Pair & connect page reads the strap link through `StrapLinkObserver` so that it only redraws when
/// something it shows has changed, and gives every row room for every line it can say. These cover both.
@MainActor
final class StrapLinkTests: XCTestCase {

    // MARK: Observer

    private final class Source {
        var inputs = StrapLinkInputs()
    }

    private func settle() {
        let hop = expectation(description: "main queue turn")
        DispatchQueue.main.async { hop.fulfill() }
        wait(for: [hop], timeout: 2)
    }

    func testRefreshPublishesOnlyWhenTheInputsDiffer() {
        let source = Source()
        let observer = StrapLinkObserver(read: { source.inputs }, triggers: [])
        var announced = 0
        let watch = observer.objectWillChange.sink { announced += 1 }
        defer { watch.cancel() }

        observer.refresh()
        XCTAssertEqual(announced, 0, "looking again at an unchanged link must not redraw the page")

        source.inputs.connected = true
        observer.refresh()
        XCTAssertEqual(announced, 1)
        XCTAssertTrue(observer.inputs.connected)

        observer.refresh()
        XCTAssertEqual(announced, 1)
    }

    func testABurstOfChangesIsOneRedraw() {
        // Connecting flips several flags in one go; each of them fires its own trigger.
        let source = Source()
        let trigger = PassthroughSubject<Void, Never>()
        let observer = StrapLinkObserver(read: { source.inputs }, triggers: [trigger.eraseToAnyPublisher()])
        var announced = 0
        let watch = observer.objectWillChange.sink { announced += 1 }
        defer { watch.cancel() }

        source.inputs.connected = true; trigger.send()
        source.inputs.bonded = true; trigger.send()
        source.inputs.encryptedBond = true; trigger.send()
        settle()

        XCTAssertEqual(announced, 1)
        XCTAssertEqual(observer.inputs, StrapLinkInputs(connected: true, bonded: true, encryptedBond: true))
    }

    func testATriggerThatChangesNothingTheyShowIsNoRedraw() {
        let source = Source()
        let trigger = PassthroughSubject<Void, Never>()
        let observer = StrapLinkObserver(read: { source.inputs }, triggers: [trigger.eraseToAnyPublisher()])
        var announced = 0
        let watch = observer.objectWillChange.sink { announced += 1 }
        defer { watch.cancel() }

        for _ in 0..<50 { trigger.send() }
        settle()

        XCTAssertEqual(announced, 0)
    }

    func testTheObserverSeesTheValueTheTriggerAnnouncedNotTheOneBeforeIt() {
        // A @Published property announces in willSet, before the new value is stored. The observer reads on the
        // next turn, so it must see the stored value.
        final class Holder: ObservableObject { @Published var connected = false }
        let holder = Holder()
        let observer = StrapLinkObserver(
            read: { StrapLinkInputs(connected: holder.connected) },
            triggers: [holder.$connected.dropFirst().map { _ in () }.eraseToAnyPublisher()])

        holder.connected = true
        settle()

        XCTAssertTrue(observer.inputs.connected)
    }

    func testStatusBuiltFromLinkInputsMatchesTheSameStatusBuiltByHand() {
        let link = StrapLinkInputs(connected: true, bonded: true, encryptedBond: false, restarting: false,
                                   pairingHint: "hint", hasReconnectGuide: false, radioProblem: nil,
                                   batteryPct: 40, charging: nil, firmware: "1", knownStrap: true, isWhoop4: true)
        let viaLink = StrapConnectionStatus(link: link, searching: false, searchIsSlow: true, userDisconnected: true)
        let byHand = StrapConnectionStatus(connected: true, bonded: true, encryptedBond: false, restarting: false,
                                           searching: false, searchIsSlow: true, knownStrap: true,
                                           pairingHint: "hint", hasReconnectGuide: false, radioProblem: nil,
                                           isWhoop4: true, batteryPct: 40, userDisconnected: true)
        XCTAssertEqual(viaLink, byHand)
    }

    // MARK: Row lines

    /// Every status the type can express, walking all of its flags (not just the ones the row catalogue walks).
    private func everyStatus() -> [StrapConnectionStatus] {
        var all: [StrapConnectionStatus] = []
        for bits in 0..<(1 << 13) {
            var s = StrapConnectionStatus()
            s.connected = bits & (1 << 0) != 0
            s.bonded = bits & (1 << 1) != 0
            s.encryptedBond = bits & (1 << 2) != 0
            s.restarting = bits & (1 << 3) != 0
            s.searching = bits & (1 << 4) != 0
            s.searchIsSlow = bits & (1 << 5) != 0
            s.knownStrap = bits & (1 << 6) != 0
            s.hasReconnectGuide = bits & (1 << 7) != 0
            s.isWhoop4 = bits & (1 << 8) != 0
            s.userDisconnected = bits & (1 << 9) != 0
            s.pairingHint = bits & (1 << 10) != 0 ? "hint" : nil
            s.radioProblem = bits & (1 << 11) != 0 ? "Bluetooth is off." : nil
            s.batteryPct = bits & (1 << 12) != 0 ? 5 : 80
            all.append(s)
        }
        return all
    }

    func testEveryLineARowCanShowIsOneItReservedRoomFor() {
        let notes = [StrapActionNotes(), StrapActionNotes(buzzSent: true),
                     StrapActionNotes(restartIgnored: true), StrapActionNotes(buzzSent: true, restartIgnored: true)]
        let reserved = Dictionary(uniqueKeysWithValues: StrapAction.allCases.map { ($0, Set($0.possibleDetails)) })
        var missing: [String] = []
        for status in everyStatus() {
            for action in StrapAction.allCases {
                for note in notes {
                    let line = status.detail(of: action, notes: note)
                    if reserved[action]?.contains(line) != true, !missing.contains("\(action): \(line)") {
                        missing.append("\(action): \(line)")
                    }
                }
            }
        }
        XCTAssertTrue(missing.isEmpty,
                      "these lines can appear but the row did not set aside room for them: \(missing)")
    }

    func testRowsReserveRoomForSomethingAndNeverForNothing() {
        for action in StrapAction.allCases {
            let lines = action.possibleDetails
            XCTAssertFalse(lines.isEmpty, "\(action)")
            XCTAssertEqual(lines.count, Set(lines).count, "\(action) repeats a line")
            XCTAssertFalse(lines.contains(""), "\(action) has an empty line")
        }
    }

    func testRowTitlesAreSingleLinesOfText() {
        for status in everyStatus().prefix(512) {
            for action in StrapAction.allCases {
                let title = status.title(of: action)
                XCTAssertFalse(title.isEmpty)
                XCTAssertFalse(title.contains("\n"))
            }
        }
    }

    func testAnUnavailableRowSaysWhyAndAnAvailableOneSaysWhatItDoes() {
        // The same rule the old page applied by hand: a reason, when there is one, outranks the description.
        for status in everyStatus().prefix(2_048) {
            for action in StrapAction.allCases {
                if let reason = status.availability(of: action).reason {
                    XCTAssertEqual(status.detail(of: action), reason)
                } else {
                    XCTAssertTrue(status.availability(of: action).isAvailable)
                }
            }
        }
    }
}
