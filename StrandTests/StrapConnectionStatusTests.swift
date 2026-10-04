import XCTest
@testable import Strand

/// Pins what the Pair & connect page tells the user and which of its buttons are live. The page is built
/// from `StrapConnectionStatus` alone, so these tests cover every state a strap link can be in without a
/// Bluetooth stack. Assertions lean on phases, tones and availability rather than English text, so they hold
/// under any system language.
final class StrapConnectionStatusTests: XCTestCase {

    // MARK: Connected states

    func testFullyPairedLinkHasEveryActionAndNothingToFix() {
        let s = StrapConnectionStatus(connected: true, bonded: true, encryptedBond: true)
        XCTAssertEqual(s.phase, .paired)
        XCTAssertEqual(s.tone, .positive)
        XCTAssertFalse(s.isBusy)
        XCTAssertNil(s.lead)
        XCTAssertNil(s.leadTitle)
        XCTAssertTrue(s.reconnect.isAvailable)
        XCTAssertTrue(s.disconnect.isAvailable)
        XCTAssertTrue(s.buzz.isAvailable)
        XCTAssertTrue(s.restart.isAvailable)
        XCTAssertTrue(s.pairing.isAvailable)
    }

    func testLiveHeartRateWithoutEncryptedBondIsPartlyPairedAndLeadsToRepair() {
        let s = StrapConnectionStatus(connected: true, bonded: true, encryptedBond: false)
        XCTAssertEqual(s.phase, .partlyPaired)
        XCTAssertEqual(s.tone, .warning)
        XCTAssertEqual(s.lead, .repair)
        XCTAssertTrue(s.disconnect.isAvailable)
        // Buzz and restart ride the encrypted channel; offering them here would do nothing silently.
        XCTAssertFalse(s.buzz.isAvailable)
        XCTAssertNotNil(s.buzz.reason)
        XCTAssertFalse(s.restart.isAvailable)
        XCTAssertNotNil(s.restart.reason)
    }

    func testPairingHintOutranksTheGenericPartlyPairedCopy() {
        let hint = "Close the WHOOP app, then tap Connect."
        let s = StrapConnectionStatus(connected: true, bonded: true, encryptedBond: false, pairingHint: hint)
        XCTAssertEqual(s.detail, hint)
    }

    func testPairingHintOnAnUnbondedLinkStillCountsAsPartlyPaired() {
        let s = StrapConnectionStatus(connected: true, pairingHint: "hint")
        XCTAssertEqual(s.phase, .partlyPaired)
        XCTAssertEqual(s.lead, .repair)
    }

    func testConnectedWithNothingYetIsTheHandshakeInProgress() {
        let s = StrapConnectionStatus(connected: true)
        XCTAssertEqual(s.phase, .connecting)
        XCTAssertTrue(s.isBusy)
        XCTAssertEqual(s.tone, .accent)
        XCTAssertNil(s.lead)
        XCTAssertFalse(s.buzz.isAvailable)
    }

    // MARK: Not connected

    func testKnownStrapThatIsOutOfReachLeadsToConnect() {
        let s = StrapConnectionStatus(knownStrap: true)
        XCTAssertEqual(s.phase, .disconnected)
        XCTAssertEqual(s.tone, .warning)
        XCTAssertEqual(s.lead, .connect)
        XCTAssertNotEqual(s.reconnectTitle, StrapConnectionStatus(connected: true, encryptedBond: true).reconnectTitle,
                          "with no link the control is Connect, with one it is Reconnect")
        XCTAssertTrue(s.reconnect.isAvailable)
        XCTAssertFalse(s.disconnect.isAvailable)
        XCTAssertFalse(s.buzz.isAvailable)
        XCTAssertFalse(s.restart.isAvailable)
        XCTAssertTrue(s.pairing.isAvailable)
    }

    func testTheStickyBondedFlagAloneCountsAsAStrapWeKnow() {
        XCTAssertEqual(StrapConnectionStatus(bonded: true).phase, .disconnected)
    }

    func testNoStrapAtAllLeadsToFindMyStrap() {
        let s = StrapConnectionStatus()
        XCTAssertEqual(s.phase, .unpaired)
        XCTAssertEqual(s.tone, .critical)
        XCTAssertEqual(s.lead, .findStrap)
        XCTAssertNotNil(s.leadTitle)
    }

    func testAResetPairingLeadsToRepairNotToAnotherReconnect() {
        let s = StrapConnectionStatus(knownStrap: true, hasReconnectGuide: true)
        XCTAssertEqual(s.phase, .needsRepair)
        XCTAssertEqual(s.tone, .critical)
        XCTAssertEqual(s.lead, .repair)
    }

    // MARK: Searching

    func testSearchingBeatsTheNotConnectedStatesAndOffersToStop() {
        for base in [StrapConnectionStatus(knownStrap: true),
                     StrapConnectionStatus(),
                     StrapConnectionStatus(knownStrap: true, hasReconnectGuide: true)] {
            var s = base
            s.searching = true
            XCTAssertEqual(s.phase, .searching)
            XCTAssertTrue(s.isBusy)
            XCTAssertNil(s.lead, "while searching the right move is to wait")
            XCTAssertTrue(s.disconnect.isAvailable, "stopping a search must be possible")
            XCTAssertNotEqual(s.disconnectTitle, StrapConnectionStatus(connected: true, encryptedBond: true).disconnectTitle)
        }
    }

    func testASearchAgainstARadioThatIsOffDoesNotSpinForever() {
        let message = "Bluetooth is off. Turn it on to connect to your strap."
        let s = StrapConnectionStatus(searching: true, knownStrap: true, radioProblem: message)
        XCTAssertNotEqual(s.phase, .searching)
        XCTAssertEqual(s.detail, message)
    }

    func testARadioProblemDoesNotOverrideAWorkingLink() {
        let working = StrapConnectionStatus(connected: true, bonded: true, encryptedBond: true)
        var withStaleMessage = working
        withStaleMessage.radioProblem = "Bluetooth is off. Turn it on to connect to your strap."
        XCTAssertEqual(withStaleMessage.detail, working.detail)
    }

    func testALongSearchStartsSuggestingCauses() {
        let quick = StrapConnectionStatus(searching: true, knownStrap: true)
        let slow = StrapConnectionStatus(searching: true, searchIsSlow: true, knownStrap: true)
        XCTAssertNotEqual(quick.detail, slow.detail)
    }

    func testOnlyTheFiveOrMgMentionsTheOtherAppWhenTheSearchIsSlow() {
        let five = StrapConnectionStatus(searching: true, searchIsSlow: true, knownStrap: true, isWhoop4: false)
        let four = StrapConnectionStatus(searching: true, searchIsSlow: true, knownStrap: true, isWhoop4: true)
        XCTAssertNotEqual(five.detail, four.detail)
        XCTAssertTrue(five.detail.hasPrefix(four.detail))
    }

    // MARK: Restarting

    func testARestartInFlightLocksEveryOtherActionEvenWhileTheLinkIsStillUp() {
        let s = StrapConnectionStatus(connected: true, bonded: true, encryptedBond: true, restarting: true)
        XCTAssertEqual(s.phase, .restarting)
        XCTAssertTrue(s.isBusy)
        XCTAssertNil(s.lead)
        XCTAssertFalse(s.reconnect.isAvailable)
        XCTAssertFalse(s.disconnect.isAvailable)
        XCTAssertFalse(s.buzz.isAvailable)
        XCTAssertFalse(s.restart.isAvailable)
        XCTAssertFalse(s.pairing.isAvailable)
    }

    func testRestartingStillReadsAsRestartingOnceTheLinkHasDropped() {
        let s = StrapConnectionStatus(bonded: true, restarting: true, knownStrap: true)
        XCTAssertEqual(s.phase, .restarting)
    }

    // MARK: Model differences

    func testWhoop4NeverOffersRestartButStillBuzzes() {
        let s = StrapConnectionStatus(connected: true, bonded: true, encryptedBond: true, isWhoop4: true)
        XCTAssertFalse(s.restart.isAvailable)
        XCTAssertNotNil(s.restart.reason)
        XCTAssertTrue(s.buzz.isAvailable)
    }

    func testTheWhoop4ReasonIsGivenEvenWhenNotConnected() {
        let four = StrapConnectionStatus(knownStrap: true, isWhoop4: true)
        let five = StrapConnectionStatus(knownStrap: true, isWhoop4: false)
        XCTAssertNotEqual(four.restart.reason, five.restart.reason,
                          "a 4.0 owner should be told it is unsupported, not to connect first")
    }

    // MARK: Battery

    func testLowBatteryIsMentionedOnlyWhenTheStrapIsOutOfReach() {
        let plain = StrapConnectionStatus(knownStrap: true)
        let low = StrapConnectionStatus(knownStrap: true, batteryPct: 8)
        let fine = StrapConnectionStatus(knownStrap: true, batteryPct: 16)
        XCTAssertNotEqual(low.detail, plain.detail)
        XCTAssertTrue(low.detail.hasPrefix(plain.detail))
        XCTAssertEqual(fine.detail, plain.detail)

        let connectedLow = StrapConnectionStatus(connected: true, bonded: true, encryptedBond: true, batteryPct: 8)
        let connectedPlain = StrapConnectionStatus(connected: true, bonded: true, encryptedBond: true)
        XCTAssertEqual(connectedLow.detail, connectedPlain.detail)
    }

    // MARK: Wording that depends on how we got here

    func testADeliberateDisconnectIsDescribedAsSuch() {
        let outOfReach = StrapConnectionStatus(knownStrap: true)
        let chosen = StrapConnectionStatus(knownStrap: true, userDisconnected: true)
        XCTAssertEqual(chosen.phase, .disconnected)
        XCTAssertNotEqual(chosen.detail, outOfReach.detail)

        let radioOff = "Bluetooth is off. Turn it on to connect to your strap."
        let both = StrapConnectionStatus(knownStrap: true, radioProblem: radioOff, userDisconnected: true)
        XCTAssertEqual(both.detail, radioOff, "a dead radio explains more than a deliberate disconnect does")
    }

    func testAHandshakeStillRunningIsNotTreatedAsAMissingPairing() {
        let handshake = StrapConnectionStatus(connected: true)
        let settled = StrapConnectionStatus(connected: true, bonded: true)
        XCTAssertEqual(handshake.phase, .connecting)
        XCTAssertEqual(settled.phase, .partlyPaired)
        XCTAssertNotNil(handshake.buzz.reason)
        XCTAssertNotEqual(handshake.buzz.reason, settled.buzz.reason)
        XCTAssertNotEqual(handshake.restart.reason, settled.restart.reason)
    }

    func testAnUnpairedFiveOrMgIsToldTheOtherAppMustBeClosed() {
        let five = StrapConnectionStatus(isWhoop4: false)
        let four = StrapConnectionStatus(isWhoop4: true)
        XCTAssertNotEqual(five.detail, four.detail)
        XCTAssertTrue(five.detail.hasPrefix(four.detail))
    }

    // MARK: Reasons

    func testEveryUnavailableActionExplainsItself() {
        let states = [
            StrapConnectionStatus(),
            StrapConnectionStatus(knownStrap: true),
            StrapConnectionStatus(connected: true),
            StrapConnectionStatus(connected: true, bonded: true),
            StrapConnectionStatus(connected: true, bonded: true, encryptedBond: true, restarting: true),
            StrapConnectionStatus(connected: true, bonded: true, encryptedBond: true, isWhoop4: true),
        ]
        for s in states {
            for availability in [s.reconnect, s.disconnect, s.buzz, s.restart, s.pairing] {
                if !availability.isAvailable {
                    XCTAssertFalse(availability.reason?.isEmpty ?? true, "a dead button needs a reason: \(s)")
                } else {
                    XCTAssertNil(availability.reason)
                }
            }
        }
    }
}
