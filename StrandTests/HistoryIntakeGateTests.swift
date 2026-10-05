import XCTest
@testable import Strand

/// The gate that holds a strap's first offload until its saved history is known to be this account's.
///
/// Each test drives the real gate and the real policy through an in-memory world, and asserts what the offload
/// would be told (`intake()`), because that is what decides whether a stranger's days are read.
@MainActor
final class HistoryIntakeGateTests: XCTestCase {

    private final class World {
        var cloud = true
        var account: String? = "11111111-1111-4111-8111-111111111111"
        var localOwner: String?
        var localId = "my-whoop"
        var serial: String? = "MGB0214654"
        var history: Bool? = false
        var probe: HistoryProbe = .absent
        var now = 1_790_000_000
        var historyAsked: [(device: String, before: Int)] = []
        var probesAsked: [String] = []
        var beforeProbeAnswers: (() -> Void)?
    }

    private var world = World()
    private var store: HistoryOwnershipStore!
    private var decisions = 0
    private var logged: [String] = []

    override func setUp() {
        world = World()
        decisions = 0
        logged = []
        let name = "noop-history-gate-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        store = HistoryOwnershipStore(defaults: defaults)
    }

    private func makeGate() -> HistoryIntakeGate {
        let w = world
        let gate = HistoryIntakeGate(environment: .init(
            cloudEnabled: { w.cloud },
            account: { w.account },
            localOwner: { w.localOwner },
            localDeviceId: { w.localId },
            serial: { w.serial },
            hasHistory: { device, before in
                w.historyAsked.append((device, before))
                return w.history
            },
            holdsDevice: { cloudId in
                w.probesAsked.append(cloudId)
                w.beforeProbeAnswers?()
                return w.probe
            },
            now: { w.now }), store: store)
        gate.onDecided = { [unowned self] in self.decisions += 1 }
        gate.log = { [unowned self] in self.logged.append($0) }
        return gate
    }

    // MARK: - a strap nobody vouches for

    func testAStrapTheAccountHasNeverHeardOfIsHeldThenDiscardedFromThePairingInstant() async {
        let gate = makeGate()
        let pairedAt = world.now
        XCTAssertEqual(gate.intake(), .hold, "no offload may start before the question is answered")
        world.now += 4
        await gate.evaluate()
        XCTAssertEqual(gate.intake(), .discard(before: pairedAt))
        XCTAssertEqual(decisions, 1)
        XCTAssertEqual(world.probesAsked, ["whoop-MGB0214654"],
                       "the strap is looked up under its own canonical device, not this install's throwaway one")
        XCTAssertTrue(logged.contains { $0.contains("new to this account") }, "\(logged)")
    }

    func testTheNewOwnersOwnRecordsBetweenPairingAndTheAnswerSurviveTheFence() async {
        let gate = makeGate()
        let pairedAt = world.now
        _ = gate.intake()
        world.now += 3_600      // an hour of the new owner's own wear before the question can be answered
        await gate.evaluate()
        guard case .discard(let fence) = gate.intake() else { return XCTFail("expected a discard") }
        XCTAssertEqual(fence, pairedAt)
        XCTAssertLessThan(fence, world.now - 3_000, "records from the hour since pairing are the new owner's")
    }

    func testTheDecisionIsFinalAndTheQuestionIsNotAskedAgain() async {
        let gate = makeGate()
        _ = gate.intake()
        await gate.evaluate()
        world.probe = .holds           // the account now holds the strap, e.g. because uploads registered it
        world.now += 600
        await gate.evaluate()
        XCTAssertEqual(gate.intake(), .discard(before: 1_790_000_000), "a registered upload must not flip an earlier decision")
        XCTAssertEqual(world.probesAsked.count, 1)
        XCTAssertEqual(decisions, 1)
    }

    // MARK: - a strap that is already the account's

    func testAnAccountThatAlreadyHoldsTheStrapKeepsItsHistory() async {
        world.probe = .holds
        let gate = makeGate()
        _ = gate.intake()
        await gate.evaluate()
        XCTAssertEqual(gate.intake(), .keep)
        XCTAssertEqual(decisions, 1)
        XCTAssertTrue(logged.contains { $0.contains("will be kept") }, "\(logged)")
    }

    func testHistoryAlreadyOnThePhoneKeepsWithoutAskingTheServer() async {
        world.history = true
        world.localOwner = world.account
        let gate = makeGate()
        _ = gate.intake()
        await gate.evaluate()
        XCTAssertEqual(gate.intake(), .keep)
        XCTAssertTrue(world.probesAsked.isEmpty, "an owner on their own phone must not depend on the network")
        XCTAssertEqual(world.historyAsked.first?.device, "my-whoop")
        XCTAssertEqual(world.historyAsked.first?.before, world.now - HistoryIntakeGate.continuityMargin,
                       "rows from this pairing's own first minute are not evidence that the phone knew the strap")
    }

    func testAnUnclaimedPhoneStillCountsItsOwnHistory() async {
        world.history = true
        world.localOwner = nil
        let gate = makeGate()
        _ = gate.intake()
        await gate.evaluate()
        XCTAssertEqual(gate.intake(), .keep)
    }

    func testAnotherAccountsHistoryOnThePhoneIsNotThisAccountsStrap() async {
        world.history = true
        world.localOwner = "99999999-9999-4999-8999-999999999999"
        let gate = makeGate()
        _ = gate.intake()
        await gate.evaluate()
        XCTAssertEqual(gate.intake(), .discard(before: world.now))
        XCTAssertTrue(world.historyAsked.isEmpty, "history that belongs to someone else is not asked about at all")
        XCTAssertEqual(world.probesAsked, ["whoop-MGB0214654"])
    }

    // MARK: - waiting

    func testAnUnreachableServerHoldsAndNeverDiscards() async {
        world.probe = .unreachable
        let gate = makeGate()
        _ = gate.intake()
        await gate.evaluate()
        XCTAssertEqual(gate.intake(), .hold)
        XCTAssertEqual(decisions, 0)
        world.probe = .absent
        world.now += 30
        await gate.evaluate()
        XCTAssertEqual(gate.intake(), .discard(before: 1_790_000_000))
        XCTAssertEqual(decisions, 1)
    }

    func testAnUnreadableLocalStoreHolds() async {
        world.history = nil
        let gate = makeGate()
        _ = gate.intake()
        await gate.evaluate()
        XCTAssertEqual(gate.intake(), .hold, "a store that cannot be read is not proof the strap is new")
        XCTAssertTrue(world.probesAsked.isEmpty)
    }

    func testAnUnreadSerialHoldsWithoutAskingAnyoneAndTheAnswerComesWithIt() async {
        world.serial = nil
        let gate = makeGate()
        _ = gate.intake()
        await gate.evaluate()
        XCTAssertEqual(gate.intake(), .hold)
        XCTAssertTrue(world.probesAsked.isEmpty, "there is no canonical id to ask about yet")
        world.serial = "MGB0214654"
        world.now += 90
        await gate.evaluate()
        XCTAssertEqual(gate.intake(), .discard(before: 1_790_000_000),
                       "the fence is the first sighting, not the moment the serial arrived")
    }

    func testANobodySignedInPhoneWaitsForAnAccountThenTreatsTheStrapAsNew() async {
        world.account = nil
        let gate = makeGate()
        _ = gate.intake()
        world.now += HistoryOwnershipPolicy.signedOutGrace - 1
        await gate.evaluate()
        XCTAssertEqual(gate.intake(), .hold)
        world.now += 1
        await gate.evaluate()
        XCTAssertEqual(gate.intake(), .discard(before: 1_790_000_000))
        XCTAssertTrue(world.probesAsked.isEmpty)
        XCTAssertTrue(logged.contains { $0.contains("new to this phone") }, "\(logged)")
    }

    // MARK: - scope

    func testALocalOnlyBuildIsNeverGated() async {
        world.cloud = false
        let gate = makeGate()
        XCTAssertEqual(gate.intake(), .keep)
        await gate.evaluate()
        XCTAssertEqual(decisions, 0)
        XCTAssertTrue(world.probesAsked.isEmpty)
        XCTAssertTrue(world.historyAsked.isEmpty)
    }

    func testAnotherAccountOnTheSamePhoneDecidesForItself() async {
        let gate = makeGate()
        _ = gate.intake()
        await gate.evaluate()
        XCTAssertEqual(gate.intake(), .discard(before: 1_790_000_000))
        world.account = "22222222-2222-4222-8222-222222222222"
        world.probe = .holds
        XCTAssertEqual(gate.intake(), .hold, "the first account's decision is not the second account's")
        await gate.evaluate()
        XCTAssertEqual(gate.intake(), .keep)
    }

    func testAnAnswerToAQuestionThatNoLongerAppliesIsDropped() async {
        let gate = makeGate()
        _ = gate.intake()
        world.beforeProbeAnswers = { [world] in world.serial = "ZZZ0000001" }   // a different strap meanwhile
        await gate.evaluate()
        world.beforeProbeAnswers = nil
        XCTAssertEqual(decisions, 0)
        XCTAssertNil(store.record(owner: world.account!, strap: HistoryOwnershipStore.strapKey(serial: "MGB0214654", localId: "my-whoop")),
                     "an answer about one strap must not be filed under another")
        XCTAssertEqual(gate.intake(), .hold)
    }

    // MARK: - counting what was refused

    func testDiscardedRecordsAreCountedAgainstTheDecision() async {
        let gate = makeGate()
        _ = gate.intake()
        await gate.evaluate()
        XCTAssertEqual(gate.discardedRecords, 0)
        gate.recordDiscarded(HistoryFenceReport(dropped: 1_200, oldest: 1, newest: 2))
        gate.recordDiscarded(HistoryFenceReport(dropped: 34, oldest: 1, newest: 2))
        XCTAssertEqual(gate.discardedRecords, 1_234)
    }
}
