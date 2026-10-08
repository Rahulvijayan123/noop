import Foundation
import StrandAnalytics

/// The gait days fetched this session, keyed by account + strap + UTC day, so revisiting a day asks the server
/// only whether its revision moved.
actor GaitWindowsCache {
    static let shared = GaitWindowsCache()

    private var days: [String: (revision: String, columns: GaitWindowColumns?)] = [:]

    /// `utcDays` for `deviceId`, from the server when it has something newer than what is held.
    func columns(utcDays: [String], deviceId: String, ownerId: String,
                 repository: ServerScoreRepository) async throws -> [GaitWindowColumns] {
        func key(_ day: String) -> String { "\(ownerId)|\(deviceId)|\(day)" }
        var known: [String: String] = [:]
        for day in utcDays { if let hit = days[key(day)] { known[day] = hit.revision } }
        let fetched = try await repository.gaitWindows(days: utcDays, deviceId: deviceId, known: known)
        for day in fetched where !day.unchanged {
            days[key(day.day)] = (day.resultRevision, day.windows)
        }
        return utcDays.compactMap { days[key($0)]?.columns }
    }

    func reset() { days = [:] }
}
