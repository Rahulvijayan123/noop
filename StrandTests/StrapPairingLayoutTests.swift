import XCTest
import SwiftUI
import AppKit
import StrandDesign
@testable import Strand

/// The Pair & connect page used to grow and shrink as the strap's state changed: a longer sentence pushed
/// everything under it down, a shorter one pulled it back. These tests lay the real views out, at a phone's
/// width, across every state the link can be in and every sentence the page can say, and require the sizes to
/// be identical. They measure layout, not pixels, so they hold under any system language.
@MainActor
final class StrapPairingLayoutTests: XCTestCase {

    /// The width of a card on a 402 pt phone: the screen less its side padding and the card's own.
    private let width: CGFloat = 330

    private func height<V: View>(_ view: V, width: CGFloat? = nil) -> CGFloat {
        let w = width ?? self.width
        return NSHostingController(rootView: view.frame(width: w))
            .sizeThatFits(in: CGSize(width: w, height: 10_000)).height
    }

    /// Heights are compared to the nearest half point, which is finer than the eye and coarser than float noise.
    private func assertAllEqual(_ heights: [String: CGFloat], _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let distinct = Set(heights.values.map { ($0 * 2).rounded() / 2 })
        XCTAssertEqual(distinct.count, 1, "\(what) changes height with its content: \(heights.sorted { $0.key < $1.key })",
                       file: file, line: line)
    }

    private static let longHint = String(repeating: "Close the WHOOP app, put the strap in pairing mode and try again. ", count: 40)

    // MARK: Status card

    /// Link states paired with the strap values the card reads from them.
    private func cardStates() -> [(name: String, status: StrapConnectionStatus, link: StrapLinkInputs)] {
        func state(_ name: String, _ link: StrapLinkInputs, searching: Bool = false, slow: Bool = false,
                   userDisconnected: Bool = false) -> (String, StrapConnectionStatus, StrapLinkInputs) {
            (name, StrapConnectionStatus(link: link, searching: searching, searchIsSlow: slow,
                                         userDisconnected: userDisconnected), link)
        }
        let paired = StrapLinkInputs(connected: true, bonded: true, encryptedBond: true, batteryPct: 82,
                                     firmware: "50.40.1.0", knownStrap: true)
        var charging = paired
        charging.charging = true
        charging.batteryPct = 9
        return [
            state("unpaired", StrapLinkInputs()),
            state("unpaired 4.0", StrapLinkInputs(isWhoop4: true)),
            state("disconnected", StrapLinkInputs(batteryPct: 12, knownStrap: true)),
            state("disconnected by user", StrapLinkInputs(batteryPct: 82, knownStrap: true), userDisconnected: true),
            state("searching", StrapLinkInputs(knownStrap: true), searching: true),
            state("searching slow", StrapLinkInputs(knownStrap: true), searching: true, slow: true),
            state("connecting", StrapLinkInputs(connected: true)),
            state("partly paired", StrapLinkInputs(connected: true, bonded: true, batteryPct: 60)),
            state("partly paired with a long hint",
                  StrapLinkInputs(connected: true, bonded: true, pairingHint: Self.longHint, batteryPct: 60)),
            state("paired", paired),
            state("paired charging", charging),
            state("restarting", StrapLinkInputs(connected: true, bonded: true, encryptedBond: true, restarting: true)),
            state("needs repair", StrapLinkInputs(hasReconnectGuide: true, knownStrap: true)),
            state("radio off", StrapLinkInputs(radioProblem: "Bluetooth is off. Turn it on to connect to your strap.",
                                               knownStrap: true)),
            state("radio message far too long", StrapLinkInputs(radioProblem: "Bluetooth " + Self.longHint,
                                                                knownStrap: true)),
        ]
    }

    private func card(_ status: StrapConnectionStatus, _ link: StrapLinkInputs) -> some View {
        StrapStatusCard(status: status, link: link, selectedModel: .whoop5mg, onPickModel: { _ in }, onLead: { })
    }

    func testStatusCardKeepsTheSameHeightInEveryState() {
        var heights: [String: CGFloat] = [:]
        for state in cardStates() {
            heights[state.name] = height(card(state.status, state.link))
        }
        assertAllEqual(heights, "the status card")
    }

    /// The control for every test above: if measuring could not tell a growing layout from a steady one, they
    /// would all pass whatever the views did.
    func testTheMeasurementCanTellAGrowingLayoutFromASteadyOne() {
        func unreserved(_ text: String) -> some View {
            Text(verbatim: text).font(StrandFont.subhead).fixedSize(horizontal: false, vertical: true)
        }
        let short = height(unreserved("Short."))
        let long = height(unreserved(Self.longHint))
        XCTAssertGreaterThan(short, 10)
        XCTAssertGreaterThan(long, short * 5, "ordinary text should grow with its content")

        let steady = [height(FixedMessageArea(text: "Short.")), height(FixedMessageArea(text: Self.longHint))]
        XCTAssertEqual(steady[0], steady[1], accuracy: 0.5)
        XCTAssertLessThan(steady[0], long, "the box has to be smaller than the long text it holds back")
    }

    func testStatusCardKeepsItsHeightWhateverTheStrapIsCalledAndWhicheverModelIsPicked() {
        var heights: [String: CGFloat] = [:]
        for model in WhoopModel.allCases {
            for firmware in [nil, "", "50.40.1.0", "50.40.1.0.2.3.4.5.6.7.8"] {
                let link = StrapLinkInputs(connected: true, bonded: true, encryptedBond: true, firmware: firmware)
                let status = StrapConnectionStatus(link: link)
                heights["\(model) \(firmware ?? "nil")"] = height(
                    StrapStatusCard(status: status, link: link, selectedModel: model, onPickModel: { _ in }, onLead: { }))
            }
        }
        assertAllEqual(heights, "the status card")
    }

    func testALongMessageDoesNotGrowTheCard() {
        let shortLink = StrapLinkInputs(radioProblem: "Bluetooth is off.", knownStrap: true)
        let longLink = StrapLinkInputs(radioProblem: "Bluetooth " + Self.longHint, knownStrap: true)
        let short = height(card(StrapConnectionStatus(link: shortLink), shortLink))
        let long = height(card(StrapConnectionStatus(link: longLink), longLink))
        XCTAssertEqual(short, long, accuracy: 0.5)
    }

    func testStatusCardWorksAtTheLargestTextSizes() {
        var heights: [String: CGFloat] = [:]
        for state in cardStates() {
            heights[state.name] = height(card(state.status, state.link).environment(\.dynamicTypeSize, .accessibility3))
        }
        assertAllEqual(heights, "the status card at accessibility text sizes")
    }

    // MARK: Message area

    func testMessageAreaIsAlwaysTheSameHeight() {
        var heights: [String: CGFloat] = [:]
        for length in [0, 1, 20, 90, 200, 400, 3_000] {
            let text = String(repeating: "word ", count: length / 5)
            heights["\(length) characters"] = height(FixedMessageArea(text: text, lines: 4))
        }
        assertAllEqual(heights, "the message area")
    }

    func testMessageAreaHoldsExactlyTheLinesItIsAskedFor() {
        let one = height(FixedMessageArea(text: "x", lines: 1))
        let four = height(FixedMessageArea(text: "x", lines: 4))
        XCTAssertEqual(four, one * 4, accuracy: 4, "four lines should be about four times one line")
    }

    // MARK: Reserved text

    func testReservedTextTakesTheRoomOfItsTallestAlternativeWhicheverIsShowing() {
        let lines = ["Short.",
                     "A medium sentence that wraps onto a second line on a phone-width screen.",
                     String(repeating: "A much longer sentence that keeps going and going. ", count: 6)]
        var heights: [String: CGFloat] = [:]
        for (i, shown) in lines.enumerated() {
            heights["showing \(i)"] = height(ReservedText(text: shown, alternatives: lines))
        }
        assertAllEqual(heights, "reserved text")

        let tallest = height(ReservedText(text: lines[2]))
        XCTAssertEqual(heights["showing 0"] ?? 0, tallest, accuracy: 0.5,
                       "the slot should be exactly as tall as the tallest line")
    }

    func testReservedTextWithNoAlternativesIsJustTheText() {
        let plain = height(Text(verbatim: "Hello there").font(StrandFont.subhead).fixedSize(horizontal: false, vertical: true))
        let reserved = height(ReservedText(text: "Hello there"))
        XCTAssertEqual(plain, reserved, accuracy: 0.5)
    }

    // MARK: Action rows

    func testEveryActionRowKeepsItsHeightWhateverItIsSaying() {
        for action in StrapAction.allCases {
            var heights: [String: CGFloat] = [:]
            for (i, line) in action.possibleDetails.enumerated() {
                for busy in [nil, false, true] as [Bool?] {
                    for enabled in [true, false] {
                        heights["line \(i) busy \(String(describing: busy)) enabled \(enabled)"] = height(
                            StrapActionRow(symbol: "link", title: "Title", detail: line,
                                           possibleDetails: action.possibleDetails,
                                           isEnabled: enabled, busy: busy, action: { }))
                    }
                }
            }
            XCTAssertFalse(heights.isEmpty, "\(action) has no lines")
            assertAllEqual(heights, "the \(action) row")
        }
    }

    func testRowsKeepTheirHeightWhenTheTitleChanges() {
        var heights: [String: CGFloat] = [:]
        for status in [StrapConnectionStatus(), StrapConnectionStatus(connected: true),
                       StrapConnectionStatus(searching: true, knownStrap: true)] {
            for action in [StrapAction.reconnect, .disconnect] {
                heights["\(action) \(status.phase)"] = height(
                    StrapActionRow(symbol: "link", title: status.title(of: action),
                                   detail: status.detail(of: action), possibleDetails: action.possibleDetails,
                                   isEnabled: status.availability(of: action).isAvailable,
                                   busy: action == .reconnect ? status.phase == .searching : nil, action: { }))
            }
        }
        // Reconnect and Disconnect each have their own tallest line, so compare within an action.
        for action in [StrapAction.reconnect, .disconnect] {
            assertAllEqual(heights.filter { $0.key.hasPrefix("\(action)") }, "the \(action) row")
        }
    }
}
