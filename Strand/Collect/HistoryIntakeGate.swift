import Foundation
import WhoopStore

/// Decides what the connected strap's saved history may become on this phone, and remembers the answer.
///
/// A strap that was worn by someone else still holds their days on its flash. Offloading it would read those
/// days into this phone and, in cloud mode, upload them under the new owner's account. The offload cannot be
/// run first and sorted out afterwards, because the acknowledgement that ends each chunk makes the strap free
/// that chunk for good. So the question is asked before the first offload, and until it is answered the
/// offload does not start (`HistoryIntake.hold`). Live heart rate is unaffected: it is not history.
///
/// The question is "is this strap already yours?", answered from the cheapest evidence that cannot be wrong
/// in the harmful direction:
///  1. a decision already taken for this account and strap, which is final;
///  2. this phone already holds heart-rate rows for the strap from before it was first seen;
///  3. the signed-in account already holds the strap on the server (a reinstall, a second phone);
///  4. otherwise it is new to this account, and everything dated before it was first seen is not theirs.
/// Evidence 2 and 3 keep the strap's history. Only a definite "no" at 3, or a phone nobody has vouched for at
/// 4, discards. Whenever the answer cannot be had (offline, serial unread, store unreadable) the offload waits.
@MainActor
final class HistoryIntakeGate {

    struct Environment {
        var cloudEnabled: () -> Bool
        /// The signed-in account whose cloud path is running, if any.
        var account: () -> String?
        /// The account that owns the history already on this phone, if one has claimed it.
        var localOwner: () -> String?
        var localDeviceId: () -> String
        /// The connected strap's serial, as read (it is validated here).
        var serial: () -> String?
        /// Whether rows older than `before` exist locally for the device. nil: the store could not be read.
        var hasHistory: (_ deviceId: String, _ before: Int) async -> Bool?
        /// Whether the server holds this cloud device id for the signed-in account.
        var holdsDevice: (_ cloudId: String) async -> HistoryProbe
        var now: () -> Int
    }

    /// Re-evaluation delays while a decision is outstanding, in seconds. The last one repeats.
    static let recheckSchedule = [5, 15, 30, 60, 120, 300, 600]
    /// Calls from the offload path cannot start an evaluation more often than this.
    static let minimumEvaluationGap = 10
    /// Heart-rate rows within this many seconds of the first sighting are this pairing's own live data.
    static let continuityMargin = 60

    private struct Identity: Equatable {
        var owner: String
        var strap: [String]
    }

    private let env: Environment
    private let store: HistoryOwnershipStore
    private var evaluating = false
    private var lastEvaluationAt = Int.min / 2
    private var recheckTask: Task<Void, Never>?
    private var recheckStep = 0

    /// Strap-log sink.
    var log: ((String) -> Void)?
    /// Called once when an outstanding question has been answered, so the offload can start.
    var onDecided: (() -> Void)?

    init(environment: Environment, store: HistoryOwnershipStore = .shared) {
        self.env = environment
        self.store = store
    }

    // MARK: - the offload path

    /// What the offload that is about to start should do. Synchronous and cheap: it reads the stored
    /// decision, and when there is none it answers `.hold` and starts working one out.
    func intake() -> HistoryIntake {
        guard env.cloudEnabled() else { return .keep }
        let who = identity()
        if let record = store.record(owner: who.owner, strap: who.strap), record.intake != .hold {
            return record.intake
        }
        store.firstSeen(strap: who.strap, now: env.now())
        if env.now() - lastEvaluationAt >= Self.minimumEvaluationGap { evaluateSoon() }
        return .hold
    }

    func evaluateSoon() {
        Task { @MainActor [weak self] in await self?.evaluate() }
    }

    /// Records acknowledged without being kept by one chunk, added to the running count for the strap.
    func recordDiscarded(_ report: HistoryFenceReport) {
        let who = identity()
        store.addDiscarded(report.dropped, owner: who.owner, strap: who.strap)
    }

    /// Records this phone has acknowledged without keeping, for the connected strap. 0 when none.
    var discardedRecords: Int {
        let who = identity()
        return store.record(owner: who.owner, strap: who.strap)?.discardedRecords ?? 0
    }

    // MARK: - working the answer out

    func evaluate() async {
        guard !evaluating, env.cloudEnabled() else { return }
        evaluating = true
        defer { evaluating = false }

        let started = env.now()
        lastEvaluationAt = started
        let who = identity()
        let existing = store.record(owner: who.owner, strap: who.strap)
        if let existing, existing.intake != .hold { return }

        let firstSeen = store.firstSeen(strap: who.strap, now: started)
        let account = env.account()
        let localId = env.localDeviceId()
        let serial = env.serial()
        let serialConfirmed = WhoopSerialIdentity.adoptedId(serial: serial) != nil

        var facts = HistoryIntakeFacts(
            cloudEnabled: true, accountRunning: account != nil, serialConfirmed: serialConfirmed,
            localContinuity: false, probe: nil, firstSeenAt: firstSeen, now: started)

        if let account, let owner = env.localOwner(), owner != account.lowercased() {
            facts.localContinuity = false
        } else {
            facts.localContinuity = await env.hasHistory(localId, firstSeen - Self.continuityMargin)
        }
        if facts.localContinuity == false, account != nil, serialConfirmed {
            let cloudId = CloudDeviceIdentity.cloudId(localId: localId, serial: serial)
            facts.probe = await env.holdsDevice(cloudId)
        }

        // Anything may have moved while those awaited (a sign-out, a different strap): an answer to an old
        // question is dropped rather than filed under the new one.
        guard identity() == who else {
            scheduleRecheck(resetting: true)
            return
        }

        let outcome = HistoryOwnershipPolicy.decide(existing: existing, facts: facts)
        guard let record = outcome.record else {
            scheduleRecheck(resetting: false)
            return
        }
        store.save(record, owner: who.owner, strap: who.strap)
        recheckTask?.cancel()
        recheckStep = 0
        switch record.kind {
        case .keep:
            log?("Backfill: this strap's saved history will be kept (\(record.reason)).")
        case .discard:
            log?("Backfill: this strap is new to \(account == nil ? "this phone" : "this account") (\(record.reason)). "
                + "Its history from before pairing belongs to someone else: it will be read so the strap can free it, "
                + "and not kept. Nothing is erased directly and nothing from before pairing reaches your account.")
        }
        onDecided?()
    }

    private func scheduleRecheck(resetting: Bool) {
        recheckTask?.cancel()
        if resetting { recheckStep = 0 }
        let schedule = Self.recheckSchedule
        let delay = schedule[min(recheckStep, schedule.count - 1)]
        recheckStep += 1
        recheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.evaluate()
        }
    }

    private func identity() -> Identity {
        Identity(owner: env.account() ?? HistoryOwnershipStore.unsignedOwner,
                 strap: HistoryOwnershipStore.strapKey(serial: env.serial(), localId: env.localDeviceId()))
    }
}
