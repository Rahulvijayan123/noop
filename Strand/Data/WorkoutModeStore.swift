import Foundation
import StrandAnalytics

/// Workout mode's log on this phone (docs/context-watchdog/WORKOUTS.md): the workouts the wearer started from the
/// strap screen (or the live tracker), with their catalogue type, kept in `UserDefaults` so a running one survives a
/// relaunch, and copied to the account through `POST scores/workouts`. The decoder and the Watchdog read its spans as
/// logged workouts.
///
/// Offline first: every edit bumps the entry's clock and leaves it pending; `sync` sends the pending entries and marks
/// only what the server accepted, so an upload that fails is simply sent again on the next call.
@MainActor
final class WorkoutModeStore: ObservableObject {
    static let shared = WorkoutModeStore()

    @Published private(set) var log: WorkoutModeLog
    private let defaults: UserDefaults
    private var syncInFlight = false
    private var lastSyncAttempt = 0

    static let defaultsKey = "noop.workoutMode.log.v1"
    /// Background retries (a Watchdog tick) at most this often; a user action syncs at once.
    static let syncEverySeconds = 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.log = Self.load(defaults: defaults)
    }

    static func load(defaults: UserDefaults) -> WorkoutModeLog {
        guard let data = defaults.data(forKey: defaultsKey),
              let log = try? JSONDecoder().decode(WorkoutModeLog.self, from: data) else { return .empty }
        // A corrupt or foreign entry (unknown type, inverted times) is dropped rather than shown.
        return WorkoutModeLog(entries: log.entries.filter {
            WorkoutTypeCatalog.entry(id: $0.typeId) != nil && $0.startUnix > 0 && ($0.endUnix ?? $0.startUnix) >= $0.startUnix
        })
    }

    /// Apply an edit and persist it. A throwing edit changes nothing.
    @discardableResult
    func mutate<T>(_ body: (inout WorkoutModeLog) throws -> T) rethrows -> T {
        var next = log
        let out = try body(&next)
        if next != log {
            log = next
            if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.defaultsKey) }
        }
        return out
    }

    var active: WorkoutModeEntry? { log.active }

    /// The logged workouts overlapping `[from, to)` for the decoder and the Watchdog (running ones up to `now`).
    func spans(from: Int, to: Int, now: Int) -> [LoggedWorkoutSpan] {
        log.spans(from: from, to: to, now: now)
    }

    /// Recently logged workouts for the strap screen, newest first.
    func recent(limit: Int = 3) -> [WorkoutModeEntry] {
        Array(log.entries.filter { !$0.deleted && $0.endUnix != nil }.sorted { $0.startUnix > $1.startUnix }
            .prefix(limit))
    }

    // MARK: Sync

    /// Send the pending entries (at most `WorkoutModeLog.syncBatch` per call) through `send`, which returns whether
    /// the server accepted the body. Only accepted versions are marked; an entry edited meanwhile stays pending.
    /// `force` skips the background throttle (a user action).
    func sync(serverDeviceId: String?, localDeviceId: String?, now: Int, force: Bool = false,
              send: ([String: Any]) async -> Bool) async {
        guard let serverDeviceId, !syncInFlight, force || now - lastSyncAttempt >= Self.syncEverySeconds else { return }
        lastSyncAttempt = now
        syncInFlight = true
        defer { syncInFlight = false }
        var pending = log.pendingSync
        while !pending.isEmpty {
            // Closed (and deleted) entries first, so the server never sees two open workouts at once.
            let ordered = pending.sorted {
                ($0.endUnix == nil ? 1 : 0, $0.startUnix) < ($1.endUnix == nil ? 1 : 0, $1.startUnix)
            }
            let chunk = Array(ordered.prefix(WorkoutModeLog.syncBatch))
            let body = WorkoutModeLog.serverBody(chunk, deviceId: serverDeviceId, localDeviceId: localDeviceId)
            guard await send(body) else { return }
            mutate { $0.markSynced(Dictionary(chunk.map { ($0.id, $0.updatedUnix) }, uniquingKeysWith: { _, b in b })) }
            let sent = Set(chunk.map(\.id))
            pending = log.pendingSync.filter { !sent.contains($0.id) }
        }
        mutate { $0.prune(now: now) }
    }

    /// The production transport: `POST scores/workouts` as the account's installation, like the Watchdog's uploads.
    static func post(_ body: [String: Any], session: URLSession = .shared) async -> Bool {
        guard let base = PlacementCloudSync.derivedEndpoint(), let identity = CloudPushIdentityStore.current(),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        var req = URLRequest(url: base.appendingPathComponent("workouts"), timeoutInterval: 30)
        req.httpMethod = "POST"
        CloudReceiverAuth.apply(identity, to: &req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        guard let (_, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}

/// What the strap screen's workout section shows, from the log and the clock (pure, so the copy and the states are
/// testable without a view).
struct WorkoutModeSectionModel: Equatable {
    struct Recent: Equatable, Identifiable {
        let id: String
        let typeName: String
        let symbol: String
        let detail: String
        let autoEnded: Bool
    }

    let running: Bool
    let typeId: String?
    let title: String
    let elapsedText: String?
    let symbolSport: String
    let recent: [Recent]

    init(log: WorkoutModeLog, now: Int, calendar: Calendar = .current) {
        if let a = log.active, let t = a.type {
            running = true
            typeId = a.typeId
            title = t.name
            elapsedText = Self.duration(a.effectiveEnd(now: now) - a.startUnix)
            symbolSport = t.sportName
        } else {
            running = false
            typeId = nil
            title = String(localized: "Start workout")
            elapsedText = nil
            symbolSport = WorkoutTypeCatalog.entry(id: WorkoutTypeCatalog.otherId)?.sportName ?? "Other"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        recent = log.entries.filter { !$0.deleted && $0.endUnix != nil }
            .sorted { $0.startUnix > $1.startUnix }.prefix(3)
            .compactMap { e in
                guard let t = e.type, let end = e.endUnix else { return nil }
                let when = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(e.startUnix)))
                return Recent(id: e.id, typeName: t.name, symbol: t.sportName,
                              detail: "\(when) · \(Self.duration(end - e.startUnix))", autoEnded: e.source == .autoEnded)
            }
    }

    /// "42 min", "1 h 05 min", "0:45" under a minute.
    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return String(format: "0:%02d", s) }
        let m = s / 60
        if m < 60 { return String(localized: "\(m) min") }
        return String(localized: "\(m / 60) h \(String(format: "%02d", m % 60)) min")
    }
}
