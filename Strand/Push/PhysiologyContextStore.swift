import Foundation
import SwiftUI
import StrandAnalytics

// PhysiologyContextStore.swift — the screens' view of the server's physiology context (contracts.md §9).
//
// One state per (day, metric) and one per history range. Every load ends in a definite state: a read that
// cannot start (cloud off, signed out, account still connecting) says so instead of sitting on "Loading…"
// forever, and a read that fails keeps whatever was already shown. Context whose scoring revision differs
// from the one the phone shows is `stale` ("context updating"), never silently paired with the new value.
//
// The server owns every value here; nothing is computed or written back.

@MainActor
final class PhysiologyContextStore: ObservableObject {
    static let shared = PhysiologyContextStore()

    /// One card's subject: a local day and the metric whose envelopes it reads.
    struct Key: Hashable, Sendable {
        let day: String
        let metric: PhysiologyContext.MetricKind
    }

    /// One history read: inclusive local days.
    struct HistoryKey: Hashable, Sendable {
        let from: String
        let to: String
    }

    /// Why there is no context to show. Each has its own copy; none is an error.
    enum UnavailableReason: String, Sendable, Equatable {
        /// Local-only install: the card is hidden entirely.
        case cloudOff
        /// Cloud is on but nobody is signed in.
        case signedOut
        /// Signed in, but the account's cloud path has not started yet.
        case accountNotReady
        /// The server predates the context routes (405).
        case unsupportedServer
        /// The server has no context for the day.
        case noData
    }

    enum PendingReason: String, Sendable, Equatable {
        /// A context job is queued or running.
        case computing
        /// The account holds no such device yet (409).
        case deviceRegistration
    }

    enum State: Equatable {
        case loading
        /// A published context built from the scoring result the phone shows (or with no pairing reported).
        case available(PhysiologyContextDay)
        /// Context is being prepared; a previous document, when the server sent one, rides along.
        case pending(PhysiologyContextDay?, PendingReason)
        /// The context was built from an earlier scoring result than the one now published.
        case stale(PhysiologyContextDay)
        case unavailable(UnavailableReason)
        /// The last read failed; what was shown before (if anything) is kept.
        case failed(cached: PhysiologyContextDay?, message: String)

        /// The day value this state shows, if any.
        var shownDay: PhysiologyContextDay? {
            switch self {
            case .available(let d), .stale(let d): return d
            case .pending(let d, _): return d
            case .failed(let d, _): return d
            case .loading, .unavailable: return nil
            }
        }

        /// Worth re-reading on a timer while the card is on screen.
        var wantsPolling: Bool {
            switch self {
            case .pending, .stale: return true
            case .available(let d): return d.job?.pending == true
            default: return false
            }
        }
    }

    enum HistoryState: Equatable {
        case loading
        case loaded(PhysiologyContextHistory)
        case pending
        case unavailable(UnavailableReason)
        case failed(cached: PhysiologyContextHistory?, message: String)

        var shown: PhysiologyContextHistory? {
            switch self {
            case .loaded(let h): return h
            case .failed(let h, _): return h
            default: return nil
            }
        }
    }

    /// What the store reads its preconditions and repository from (injectable for tests).
    struct Environment {
        var cloudEnabled: @MainActor () -> Bool
        var signedIn: @MainActor () -> Bool
        var repository: @MainActor () -> PhysiologyContextRepository?

        static let live = Environment(
            cloudEnabled: { CloudPushSettings.isEnabled && CloudPushSettings.isConfigured },
            signedIn: { CloudPushIdentityStore.current() != nil },
            repository: { PhysiologyContextStore.runningAccountRepository() })
    }

    @Published private(set) var states: [Key: State] = [:]
    @Published private(set) var histories: [HistoryKey: HistoryState] = [:]
    /// Bumped when what a read depends on changes (read candidates, account). Cards key their load on it.
    @Published private(set) var epoch = 0

    /// Every device id the server may hold this strap's context under, best first (`AppModel.hostedReadCandidates`).
    private(set) var readCandidates = ["my-whoop"]

    private let environment: Environment
    private var inFlight: Set<Key> = []
    private var historyInFlight: Set<HistoryKey> = []
    /// Stale-response guard: bumped by `reset()`; a read writes only if it is unchanged after its await, so a
    /// response read with one account's credential never lands in the next account's screens.
    private var generation = 0

    init(environment: Environment = .live) {
        self.environment = environment
    }

    // MARK: Inputs

    /// Point every card at the ids the app model reads. `candidates` is best first; an empty list is ignored.
    func setReadCandidates(_ candidates: [String]) {
        guard !candidates.isEmpty else { return }
        let changed = candidates != readCandidates
        readCandidates = candidates
        // A card that could not read yet (account still connecting) retries when the app model is ready.
        if changed || states.values.contains(where: Self.waitsForAccount) { epoch &+= 1 }
    }

    /// Forget everything shown. Called when the signed-in account ends: what is on screen was read with the
    /// previous account's credential and must not be visible to the next one.
    func reset() {
        generation &+= 1
        epoch &+= 1
        states = [:]
        histories = [:]
        inFlight = []
        historyInFlight = []
        readCandidates = ["my-whoop"]
        Self.liveRepository = nil
    }

    // MARK: Reads

    func state(for key: Key) -> State? { states[key] }
    func historyState(for key: HistoryKey) -> HistoryState? { histories[key] }

    /// Show the cached context at once (when nothing is shown yet), then read the server. Always ends in a
    /// definite state.
    func load(_ key: Key) async {
        guard environment.cloudEnabled() else { states[key] = .unavailable(.cloudOff); return }
        guard let repository = environment.repository() else {
            states[key] = .unavailable(environment.signedIn() ? .accountNotReady : .signedOut)
            return
        }
        guard !inFlight.contains(key) else { return }
        let started = generation
        inFlight.insert(key)
        defer { if started == generation { inFlight.remove(key) } }
        let candidates = readCandidates

        if states[key]?.shownDay == nil {
            // A re-read of a settled state keeps it on screen; only a first (or retried) read shows loading.
            if Self.showsLoading(before: states[key]) { states[key] = .loading }
            let cached = await repository.cachedDayContext(day: key.day, deviceIds: candidates, metric: key.metric)
            guard started == generation else { return }
            if let cached { states[key] = Self.classify(cached) }
        }
        do {
            let read = try await repository.dayContext(day: key.day, deviceIds: candidates, metric: key.metric)
            guard started == generation else { return }
            switch read {
            case .loaded(let day): states[key] = Self.classify(day)
            case .unsupportedServer: states[key] = .unavailable(.unsupportedServer)
            case .deviceRegistrationPending: states[key] = .pending(states[key]?.shownDay, .deviceRegistration)
            }
        } catch {
            guard started == generation else { return }
            if Self.isCancellation(error) {
                // The screen went away mid-read: leave nothing half-loaded behind.
                if case .loading = states[key] { states[key] = nil }
                return
            }
            // A settled server answer without a document (none, pending, old server) stays as it was.
            if let current = states[key], current.shownDay == nil, Self.isSettledAnswer(current) { return }
            states[key] = .failed(cached: states[key]?.shownDay, message: Self.describe(error))
        }
    }

    /// Read the history for `key`, cache first. Always ends in a definite state.
    func loadHistory(_ key: HistoryKey) async {
        guard environment.cloudEnabled() else { histories[key] = .unavailable(.cloudOff); return }
        guard let repository = environment.repository() else {
            histories[key] = .unavailable(environment.signedIn() ? .accountNotReady : .signedOut)
            return
        }
        guard !historyInFlight.contains(key) else { return }
        let started = generation
        historyInFlight.insert(key)
        defer { if started == generation { historyInFlight.remove(key) } }
        let candidates = readCandidates

        if histories[key]?.shown == nil {
            switch histories[key] {
            case nil, .failed?, .unavailable(.accountNotReady)?, .unavailable(.signedOut)?: histories[key] = .loading
            default: break
            }
            let cached = await repository.cachedHistory(from: key.from, to: key.to, deviceIds: candidates)
            guard started == generation else { return }
            if let cached { histories[key] = .loaded(cached) }
        }
        do {
            let read = try await repository.history(from: key.from, to: key.to, deviceIds: candidates)
            guard started == generation else { return }
            switch read {
            case .loaded(let h): histories[key] = .loaded(h)
            case .unsupportedServer: histories[key] = .unavailable(.unsupportedServer)
            case .deviceRegistrationPending: histories[key] = .pending
            }
        } catch {
            guard started == generation else { return }
            if Self.isCancellation(error) {
                if case .loading = histories[key] { histories[key] = nil }
                return
            }
            switch histories[key] {
            case .pending?, .unavailable(.unsupportedServer)?: return   // the server's last answer stays
            default: break
            }
            histories[key] = .failed(cached: histories[key]?.shown, message: Self.describe(error))
        }
    }

    // MARK: Pure rules

    /// The state one server answer puts a card in.
    nonisolated static func classify(_ day: PhysiologyContextDay) -> State {
        switch day.status {
        case .none:
            return .unavailable(.noData)
        case .pending:
            return .pending(day.document == nil ? nil : day, .computing)
        case .available:
            guard day.document != nil else { return .unavailable(.noData) }
            // Built from an earlier scoring result: never pair it silently with the value now on screen.
            if day.pairing?.consistent == false { return .stale(day) }
            return .available(day)
        }
    }

    /// A state the server itself answered with (as opposed to loading or a failure).
    nonisolated static func isSettledAnswer(_ state: State) -> Bool {
        switch state {
        case .pending: return true
        case .unavailable(let reason): return reason == .noData || reason == .unsupportedServer
        default: return false
        }
    }

    nonisolated static func showsLoading(before state: State?) -> Bool {
        guard let state else { return true }
        if case .failed = state { return true }
        return waitsForAccount(state)
    }

    nonisolated static func waitsForAccount(_ state: State) -> Bool {
        if case .unavailable(let reason) = state { return reason == .accountNotReady || reason == .signedOut }
        return false
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return false
    }

    /// A short, log-safe reason (never a URL, id or body).
    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case let e as PhysiologyContextRepository.ReadError:
            switch e {
            case .notConfigured: return "not-configured"
            case .missingIdentity: return "no-credential"
            case .http(let code, _): return "http-\(code)"
            case .malformed: return "malformed"
            }
        case let e as URLError: return "network-\(e.code.rawValue)"
        default: return "error"
        }
    }

    // MARK: Live repository

    /// One repository per running account, reading with that account's own credential only.
    private static var liveRepository: (scope: CloudDataScope, repository: PhysiologyContextRepository)?

    static func runningAccountRepository() -> PhysiologyContextRepository? {
        guard let scope = CloudPushRuntime.shared.runningScope else { return nil }
        if let live = liveRepository, live.scope == scope { return live.repository }
        let created = PhysiologyContextRepository(identity: CloudPushRuntime.credentialProvider(for: scope))
        liveRepository = (scope, created)
        return created
    }
}
