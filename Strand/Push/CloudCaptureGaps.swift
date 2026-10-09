import Foundation

/// The spans of capture the cloud journal never took, so they can be replayed from the local store once the
/// upload path runs again.
///
/// The local store banks everything the strap sends whether or not the upload runtime is running; the journal
/// only takes what arrives while it is. Two things therefore never reached the cloud before this ledger:
///  - live seconds captured while the runtime was down: sync switched off, the account signed out, paused, or
///    blocked, and the moments of a relaunch before the runtime is back;
///  - a history offload banked while the runtime was down, which carries seconds from before the outage too
///    (the strap buffers what it recorded out of range and hands it over later).
///
/// The first is recorded as the span from the last moment the runtime was known to be journaling (`liveThrough`,
/// refreshed while it runs and at `stop`) to its next start. The second is recorded per offloaded chunk, by the
/// chunk's own strap seconds. `CloudHistorySeeder` and `CloudSpo2Seeder` replay each gap once, oldest first,
/// and remember the newest gap they finished, so a second is replayed once and spans the journal already
/// took while running are never sent again. Nothing older than `replayWindowSeconds` is replayed.
///
/// Process-wide and not scoped to an account: the local store is not either. Only the account that owns the
/// on-device history ever replays it (`CloudLocalDataBinding`), as with the first-run seed.
public struct CloudCaptureGaps: @unchecked Sendable {
    struct Gap: Codable, Equatable {
        /// Increasing; a seeder replays every gap with a higher seq than the last one it finished.
        var seq: Int
        /// Strap seconds, `[from, to)`.
        var from: Int
        var to: Int
        /// The LOCAL store id the missed rows were banked under, or nil for a span that applies to every strap
        /// (the runtime was down, so nothing captured from any of them was journaled).
        var deviceId: String?
    }

    struct State: Codable, Equatable {
        var liveThrough: Int?
        var nextSeq = 1
        var gaps: [Gap] = []
        /// The gap a further missed offload chunk may still extend. Cleared whenever the runtime starts, so a
        /// gap a seeder may already have replayed is never grown afterwards.
        var openSeq: Int?
    }

    /// Bounds both what is kept and what is replayed. A month covers any realistic outage (a phone left signed
    /// out over a holiday) without turning a resumed sync into an unbounded upload.
    static let replayWindowSeconds = 30 * 86_400
    static let maxGaps = 256
    /// How often a running runtime refreshes `liveThrough`. A crash loses at most this much of the edge, which
    /// is then replayed again (the receiver keeps rows by identity, and heart rate goes through the ledger).
    static let heartbeatSeconds = 30
    /// A shorter outage than this is not worth a replay pass.
    static let minimumGapSeconds = 5
    /// Missed chunks this close to the open gap extend it instead of adding another.
    static let mergeSlackSeconds = 15 * 60

    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static let shared = CloudCaptureGaps()

    private static let key = "noop.cloud.captureGaps.v1"
    private static let lock = NSLock()

    // MARK: recording

    /// The runtime is journaling right now. Called at most every `heartbeatSeconds` while it runs, and on stop.
    public func noteLive(now: Int = Int(Date().timeIntervalSince1970)) {
        mutate { state in
            state.liveThrough = max(state.liveThrough ?? now, now)
        }
    }

    /// The runtime came up: everything since it was last known live was captured without it. The very first
    /// start on an install records no gap (there is nothing earlier to have missed; the first-run seed covers
    /// the recent history instead).
    public func noteRuntimeStarted(now: Int = Int(Date().timeIntervalSince1970)) {
        mutate { state in
            if let live = state.liveThrough, now - live >= Self.minimumGapSeconds {
                Self.append(Gap(seq: state.nextSeq, from: live, to: now, deviceId: nil), to: &state)
            }
            state.openSeq = nil
            state.liveThrough = now
            Self.prune(&state, now: now)
        }
    }

    /// An offloaded chunk was banked locally while the journal was not taking records. Ignored on an install
    /// whose runtime has never run: nothing is owed to an account that was never synced from here.
    public func noteMissedHistory(deviceId: String, from: Int, to: Int,
                                  now: Int = Int(Date().timeIntervalSince1970)) {
        guard to > from else { return }
        let device = deviceId.lowercased()
        mutate { state in
            guard state.liveThrough != nil else { return }
            if let open = state.openSeq, let index = state.gaps.firstIndex(where: { $0.seq == open }),
               state.gaps[index].deviceId == device,
               from <= state.gaps[index].to + Self.mergeSlackSeconds,
               to >= state.gaps[index].from - Self.mergeSlackSeconds {
                state.gaps[index].from = min(state.gaps[index].from, from)
                state.gaps[index].to = max(state.gaps[index].to, to)
            } else {
                let seq = state.nextSeq
                Self.append(Gap(seq: seq, from: from, to: to, deviceId: device), to: &state)
                state.openSeq = seq
            }
            Self.prune(&state, now: now)
        }
    }

    // MARK: reading

    /// The newest gap's seq, or 0 when there has never been one. A seeder that starts from scratch takes this
    /// as already replayed: its first run covers the recent history by itself.
    public var latestSeq: Int { load().nextSeq - 1 }

    /// The gaps a seeder for the local store id `deviceId` has not replayed yet, oldest first, clipped to the
    /// replay window. Spans that apply to every strap are included.
    func pending(after seq: Int, deviceId: String, now: Int = Int(Date().timeIntervalSince1970)) -> [Gap] {
        let device = deviceId.lowercased()
        let floor = now - Self.replayWindowSeconds
        return load().gaps
            .filter { $0.seq > seq && ($0.deviceId == nil || $0.deviceId == device) }
            .compactMap { gap in
                var clipped = gap
                clipped.from = max(gap.from, floor)
                clipped.to = min(gap.to, now + 60)
                return clipped.to > clipped.from ? clipped : nil
            }
            .sorted { $0.seq < $1.seq }
    }

    var liveThrough: Int? { load().liveThrough }

    // MARK: storage

    private static func append(_ gap: Gap, to state: inout State) {
        state.gaps.append(gap)
        state.nextSeq = gap.seq + 1
        if state.gaps.count > maxGaps { state.gaps.removeFirst(state.gaps.count - maxGaps) }
    }

    private static func prune(_ state: inout State, now: Int) {
        let floor = now - replayWindowSeconds
        state.gaps.removeAll { $0.to <= floor }
    }

    func load() -> State {
        guard let data = defaults.data(forKey: Self.key),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    private func mutate(_ change: (inout State) -> Void) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var state = load()
        let before = state
        change(&state)
        guard state != before, let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
