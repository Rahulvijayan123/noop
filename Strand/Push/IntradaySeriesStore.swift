import Foundation
import SwiftUI

/// The screens' view of the server's dense intraday series: the last window read per (metric, range), kept
/// in memory so reopening a metric page paints at once, and backed by the repository's on-disk cache so a
/// cold launch (or no network) still shows the last readings the server published.
///
/// The server owns every number here. Nothing is computed on the phone and nothing is written back.
@MainActor
final class IntradaySeriesStore: ObservableObject {
    static let shared = IntradaySeriesStore()

    @Published private(set) var windows: [String: IntradaySeriesWindow] = [:]
    /// Why the last read of a range failed, kept so the card can say its numbers are saved ones.
    @Published private(set) var failures: [String: String] = [:]

    /// The registered device the series route resolves the owner through. The app keeps this equal to
    /// the strap it reads scores for (`AppModel.hostedReadDeviceId`); `my-whoop` is the provisional
    /// device every install registers.
    var readDeviceId = "my-whoop"

    private let repositoryProvider: @MainActor () -> ServerScoreRepository?
    private var inFlight: Set<String> = []
    /// G1 stale-response guard (findings/g1-day-ui.md T04 / Q3): a generation token bumped whenever the
    /// local calendar "Today" key changes (`Repository.dayKeyDidChange`, or `noteDayRolledOver` called
    /// directly). `refresh` captures the generation before its await and only writes the window if the
    /// generation is unchanged afterwards, so a response that STARTED before local midnight can never
    /// land after midnight and overwrite the new day's live window under the shared `"<metric>|live"` key.
    /// Cancellation is honoured the same way (no write after the owning task was cancelled).
    private var dayGeneration = 0
    private var dayChangeObserver: NSObjectProtocol?

    init(repositoryProvider: @escaping @MainActor () -> ServerScoreRepository? = {
        CloudPushRuntime.shared.scoreRepository()
    }) {
        self.repositoryProvider = repositoryProvider
        // Bump the stale-response generation on every day re-key, so an in-flight pre-midnight read is
        // dropped the moment the day rolls. The notification is posted by `Repository.noteDayRolledOver`
        // (driven by `DayRolloverCoordinator`); safe to observe from init — the observer is removed in
        // deinit and the callback is async onto the main actor (this type is @MainActor).
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: Repository.dayKeyDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.noteDayRolledOver() }
        }
    }

    deinit {
        if let dayChangeObserver {
            NotificationCenter.default.removeObserver(dayChangeObserver)
        }
    }

    /// G1: bump the stale-response generation — called on every day re-key. Exposed directly so tests
    /// (and any non-NotificationCenter driver) can advance the epoch deterministically.
    /// audit-g1-day F6a: also releases every in-flight slot, so a pre-midnight refresh still awaiting
    /// its response cannot block the NEW day's refresh for the same shared `|live` key (its write is
    /// still dropped by the generation guard; it just stops holding the slot).
    func noteDayRolledOver() {
        dayGeneration &+= 1
        inFlight.removeAll()
    }

    /// Show the last stored readings for a range, once, without touching the network.
    /// audit-g1-day F6b: for the constant `|live` key, never seed the view with a PRIOR-DAY cached
    /// window — on a cold launch after midnight the on-disk cache holds yesterday's rolling window,
    /// which must not paint as today's (a window that does not reach the current local midnight is
    /// stale). The generation is also captured before the await and re-checked after, so a day rollover
    /// that lands mid-read cannot apply an old cached window either.
    func loadCached(_ bounds: IntradayRange.Bounds) async {
        guard windows[bounds.key] == nil, let repository = repositoryProvider() else { return }
        let generation = dayGeneration
        let cached = await repository.cachedIntradaySeries(cacheKey: bounds.key, deviceId: readDeviceId)
        guard generation == dayGeneration, let cached, windows[bounds.key] == nil else { return }
        let localMidnight = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        if !bounds.isLive || cached.to >= localMidnight { windows[bounds.key] = cached }
    }

    /// Read a range from the server. A failure leaves whatever was already showing in place.
    /// G1 (T04): the generation + cancellation guard after the await means a response that started
    /// before a day rollover (or whose task was cancelled mid-flight) is dropped instead of overwriting
    /// the new day's window under the shared `|live` key — the rollover can never be blocked or reversed
    /// by a stale read.
    func refresh(_ metric: IntradayMetric, bounds: IntradayRange.Bounds) async {
        guard !inFlight.contains(bounds.key), let repository = repositoryProvider() else { return }
        inFlight.insert(bounds.key)
        defer { inFlight.remove(bounds.key) }
        let generation = dayGeneration
        do {
            let window = try await repository.intradaySeries(
                from: bounds.from, to: bounds.to, deviceId: readDeviceId,
                metrics: [metric], cacheKey: bounds.key)
            guard !Task.isCancelled, generation == dayGeneration else { return }
            windows[bounds.key] = window
            failures[bounds.key] = nil
        } catch {
            guard !Task.isCancelled, generation == dayGeneration else { return }
            failures[bounds.key] = String(describing: error)
        }
    }
}
