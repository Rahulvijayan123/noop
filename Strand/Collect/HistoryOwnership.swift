import Foundation
import WhoopProtocol
import WhoopStore

// MARK: - what a strap's saved history is allowed to become

/// What to do with the history a strap hands over after it is paired.
///
/// ## Why this is an acknowledgement and not an erase
///
/// A strap frees its flash only through the offload handshake: it streams `HISTORY_START`, the records and a
/// `HISTORY_END` carrying an `end_data` block, and it releases everything up to that block's trim cursor when
/// the host answers with `HISTORICAL_DATA_RESULT [0x01] + end_data`. Records that were never acknowledged are
/// offered again on the next offload, and `ABORT_HISTORICAL_TRANSMITS` leaves them where they are. That ack is
/// the one storage operation this code base has verified against real straps (`Backfiller.finishChunk`,
/// `BLEManager.ackHistoricalChunk`).
///
/// The schema also names `FORCE_TRIM` (25) and `SET_READ_POINTER` (33). Nothing in this repository documents
/// what either does to flash, nothing has observed their effect on a real strap, and `WhoopCommand` leaves
/// them out on purpose (destructive or unverified strap commands are never sent). So a new owner's "clean
/// strap" is made the supported way: the previous owner's records are read, acknowledged so the strap frees
/// them and moves its trim cursor on, and **not kept**. No flash region is addressed directly.
enum HistoryIntake: Equatable {
    /// Take everything the strap offers (same owner, or nothing to protect).
    case keep
    /// A new owner: acknowledge the strap's records so it frees them, but keep nothing dated before `fence`
    /// (unix seconds). Records at or after `fence` are the new owner's and are ingested as usual.
    case discard(before: Int)
    /// Not decided yet. Do not offload: an offload acknowledges, and an acknowledgement cannot be taken back.
    case hold
}

/// A decision taken once per (account, strap) and then kept. A decision that could change between launches
/// would let records through that an earlier launch had already discarded, or discard records an earlier
/// launch had agreed to keep.
struct HistoryOwnershipRecord: Codable, Equatable {
    enum Kind: String, Codable { case keep, discard }
    var kind: Kind
    var decidedAt: Int
    /// Unix seconds; set for `discard` only. The moment the strap was first seen paired.
    var fence: Int?
    /// Why the decision went the way it did, for the strap log.
    var reason: String
    /// Records acknowledged without being kept, summed over every offload since the decision.
    var discardedRecords: Int

    var intake: HistoryIntake {
        switch kind {
        case .keep: return .keep
        case .discard: return fence.map { .discard(before: $0) } ?? .hold
        }
    }
}

/// The account's answer to "do you already hold this strap?".
enum HistoryProbe: Equatable {
    case holds
    case absent
    /// Offline, or the server could not answer. Never a reason to discard.
    case unreachable
}

/// Everything the decision turns on, gathered by `HistoryIntakeGate`.
struct HistoryIntakeFacts: Equatable {
    /// The cloud path is configured and switched on. When it is not, nothing here applies.
    var cloudEnabled: Bool
    /// A signed-in account's cloud path is running, so the server can be asked.
    var accountRunning: Bool
    /// The strap has told us its serial (a 4.0 needs two sightings), so its cloud id can be asked about.
    var serialConfirmed: Bool
    /// This phone already holds heart-rate rows for this strap that are older than its first sighting, and
    /// the account is the one that owns the phone's history. nil: the local store could not be read.
    var localContinuity: Bool?
    var probe: HistoryProbe?
    /// When this strap was first seen by this phone. This becomes the fence.
    var firstSeenAt: Int
    var now: Int
}

enum HistoryOwnershipPolicy {

    /// With nobody signed in there is no server to ask. A signed-in account normally starts within seconds
    /// of launch, so wait that long before treating the strap as new to this phone.
    static let signedOutGrace = 120

    /// A strap that never confirms its serial cannot be looked up. Holding forever would starve its history,
    /// so after a day the offload goes ahead and is kept. The cost is documented, not hidden: that one strap
    /// is not cleaned.
    static let unknownSerialPatience = 24 * 3600

    /// A sighting this old with no decision belongs to a pairing that was abandoned; a new one starts afresh.
    static let staleSighting = 24 * 3600

    /// The decision for these facts, and the record to persist (nil when nothing is settled yet).
    ///
    /// Only a definite "the server has no such strap for this account" ever discards while someone is signed
    /// in. Anything uncertain holds, because holding costs a delay and discarding costs the owner's own
    /// unsynced history for good.
    static func decide(existing: HistoryOwnershipRecord?, facts f: HistoryIntakeFacts)
        -> (intake: HistoryIntake, record: HistoryOwnershipRecord?) {
        if let existing, existing.intake != .hold { return (existing.intake, existing) }
        guard f.cloudEnabled else { return (.keep, nil) }

        func keep(_ reason: String) -> (intake: HistoryIntake, record: HistoryOwnershipRecord?) {
            (.keep, HistoryOwnershipRecord(kind: .keep, decidedAt: f.now, fence: nil,
                                           reason: reason, discardedRecords: 0))
        }
        func discard(_ reason: String) -> (intake: HistoryIntake, record: HistoryOwnershipRecord?) {
            (.discard(before: f.firstSeenAt),
             HistoryOwnershipRecord(kind: .discard, decidedAt: f.now, fence: f.firstSeenAt,
                                    reason: reason, discardedRecords: 0))
        }
        let hold: (intake: HistoryIntake, record: HistoryOwnershipRecord?) = (.hold, nil)

        switch f.localContinuity {
        case nil: return hold
        case true?: return keep("this phone already holds history for this strap")
        case false?: break
        }
        guard f.accountRunning else {
            return f.now - f.firstSeenAt >= signedOutGrace
                ? discard("new to this phone and nobody is signed in to vouch for it") : hold
        }
        guard f.serialConfirmed else {
            return f.now - f.firstSeenAt >= unknownSerialPatience
                ? keep("the strap never confirmed its serial, so it could not be looked up") : hold
        }
        switch f.probe {
        case .holds?: return keep("the account already holds this strap")
        case .absent?: return discard("the account has no such strap")
        case .unreachable?, nil: return hold
        }
    }
}

// MARK: - persistence

/// The persisted decisions, one per (account, strap), and the sightings that start each fence.
final class HistoryOwnershipStore: @unchecked Sendable {
    static let shared = HistoryOwnershipStore()

    /// Who is vouching, when nobody is signed in.
    static let unsignedOwner = "unsigned"

    private struct Sighting: Codable { var first: Int; var touched: Int }

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A strap is named by its serial once that is confirmed, and by its local slot until then.
    static func strapKey(serial: String?, localId: String) -> [String] {
        var keys: [String] = []
        if let serial = WhoopSerialIdentity.adoptedId(serial: serial) { keys.append(serial.lowercased()) }
        keys.append("slot-\(localId.lowercased())")
        return keys
    }

    private static func recordKey(owner: String, strap: String) -> String {
        "noop.cloud.historyIntake.v1.\(owner.lowercased()).\(strap)"
    }

    private static func sightingKey(strap: String) -> String {
        "noop.cloud.historyIntake.v1.seen.\(strap)"
    }

    /// The decision for this account and strap, looked up by serial first and by slot second. A decision made
    /// while only the slot was known is copied to the serial key once that is known, so it follows the strap.
    func record(owner: String, strap: [String]) -> HistoryOwnershipRecord? {
        lock.lock(); defer { lock.unlock() }
        for (index, name) in strap.enumerated() {
            guard let found = read(owner: owner, strap: name) else { continue }
            if index > 0, let primary = strap.first { write(found, owner: owner, strap: primary) }
            return found
        }
        return nil
    }

    func save(_ record: HistoryOwnershipRecord, owner: String, strap: [String]) {
        lock.lock(); defer { lock.unlock() }
        for name in strap { write(record, owner: owner, strap: name) }
    }

    /// Add to the running count of records acknowledged without being kept. No-op without a decision.
    func addDiscarded(_ count: Int, owner: String, strap: [String]) {
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        for name in strap {
            guard var existing = read(owner: owner, strap: name) else { continue }
            existing.discardedRecords += count
            write(existing, owner: owner, strap: name)
        }
    }

    /// When this phone first saw the strap. Set on the first call and then kept, except that a sighting left
    /// alone for `staleSighting` seconds is an abandoned pairing and starts over.
    @discardableResult
    func firstSeen(strap: [String], now: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let known = strap.compactMap { name -> Sighting? in
            defaults.data(forKey: Self.sightingKey(strap: name))
                .flatMap { try? JSONDecoder().decode(Sighting.self, from: $0) }
        }
        var first = known.map(\.first).min() ?? now
        if let touched = known.map(\.touched).max(), now - touched >= HistoryOwnershipPolicy.staleSighting {
            first = now
        }
        let sighting = Sighting(first: first, touched: now)
        if let data = try? JSONEncoder().encode(sighting) {
            for name in strap { defaults.set(data, forKey: Self.sightingKey(strap: name)) }
        }
        return first
    }

    private func read(owner: String, strap: String) -> HistoryOwnershipRecord? {
        defaults.data(forKey: Self.recordKey(owner: owner, strap: strap))
            .flatMap { try? JSONDecoder().decode(HistoryOwnershipRecord.self, from: $0) }
    }

    private func write(_ record: HistoryOwnershipRecord, owner: String, strap: String) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.recordKey(owner: owner, strap: strap))
    }
}

// MARK: - the fence

/// What a fence removed from one chunk, or from a whole offload once absorbed.
struct HistoryFenceReport: Equatable {
    var dropped = 0
    var oldest: Int?
    var newest: Int?

    mutating func absorb(_ other: HistoryFenceReport) {
        dropped += other.dropped
        if let o = other.oldest { oldest = Swift.min(oldest ?? o, o) }
        if let n = other.newest { newest = Swift.max(newest ?? n, n) }
    }
}

extension Streams {

    /// The streams with every record dated before `fence` removed, and a report of what was removed.
    ///
    /// Every stream the offload banks is filtered, not just heart rate: a previous owner's SpO₂, skin
    /// temperature, steps, events and battery readings are as much theirs as their pulse. A record dated
    /// exactly at `fence` is kept. The transient diagnostics (dropped-implausible counters, packet-type census)
    /// describe the chunk as received and are carried over unchanged.
    func discardingRecords(before fence: Int) -> (streams: Streams, report: HistoryFenceReport) {
        var kept = self
        var report = HistoryFenceReport()

        func keep<T>(_ values: [T], _ ts: KeyPath<T, Int>) -> [T] {
            var out: [T] = []
            out.reserveCapacity(values.count)
            for value in values {
                let stamp = value[keyPath: ts]
                if stamp >= fence {
                    out.append(value)
                } else {
                    report.dropped += 1
                    report.oldest = Swift.min(report.oldest ?? stamp, stamp)
                    report.newest = Swift.max(report.newest ?? stamp, stamp)
                }
            }
            return out
        }

        kept.hr = keep(hr, \.ts)
        kept.rr = keep(rr, \.ts)
        kept.spo2 = keep(spo2, \.ts)
        kept.skinTemp = keep(skinTemp, \.ts)
        kept.resp = keep(resp, \.ts)
        kept.gravity = keep(gravity, \.ts)
        kept.steps = keep(steps, \.ts)
        kept.sleepState = keep(sleepState, \.ts)
        kept.ppgHr = keep(ppgHr, \.ts)
        kept.ppgWaveform = keep(ppgWaveform, \.ts)
        kept.v18Aux = keep(v18Aux, \.ts)
        kept.events = keep(events, \.ts)
        kept.battery = keep(battery, \.ts)
        return (kept, report)
    }
}
