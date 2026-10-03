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

    init(repositoryProvider: @escaping @MainActor () -> ServerScoreRepository? = {
        CloudPushRuntime.shared.scoreRepository()
    }) {
        self.repositoryProvider = repositoryProvider
    }

    /// Show the last stored readings for a range, once, without touching the network.
    func loadCached(_ bounds: IntradayRange.Bounds) async {
        guard windows[bounds.key] == nil, let repository = repositoryProvider() else { return }
        let cached = await repository.cachedIntradaySeries(cacheKey: bounds.key, deviceId: readDeviceId)
        // A network read that landed while this one was suspended is newer than the file.
        if let cached, windows[bounds.key] == nil { windows[bounds.key] = cached }
    }

    /// Read a range from the server. A failure leaves whatever was already showing in place.
    func refresh(_ metric: IntradayMetric, bounds: IntradayRange.Bounds) async {
        guard !inFlight.contains(bounds.key), let repository = repositoryProvider() else { return }
        inFlight.insert(bounds.key)
        defer { inFlight.remove(bounds.key) }
        do {
            let window = try await repository.intradaySeries(
                from: bounds.from, to: bounds.to, deviceId: readDeviceId,
                metrics: [metric], cacheKey: bounds.key)
            windows[bounds.key] = window
            failures[bounds.key] = nil
        } catch {
            failures[bounds.key] = String(describing: error)
        }
    }
}
