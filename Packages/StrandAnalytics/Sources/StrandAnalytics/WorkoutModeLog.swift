import Foundation

// WorkoutModeLog.swift — the wearer's own record of when they worked out and what kind of workout it was
// (docs/context-watchdog/WORKOUTS.md). Started and stopped from the strap screen; one workout runs at a time; a
// forgotten one closes itself at `maxOpenSeconds` and says so (`autoEnded`). The log is pure value state: the app
// persists it, syncs it to `scores/workouts`, and hands its spans to the decoder and the Watchdog as logged workouts,
// an observed label rather than an inference.

/// One logged workout. `endUnix` is nil while it runs. Edits (stop, change type, delete) bump `updatedUnix`, which is
/// the server's last-writer-wins clock (`client_updated_at`); `syncedUnix` is the `updatedUnix` the server last
/// accepted, so an entry needs syncing while the two differ.
public struct WorkoutModeEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Source: String, Codable, Equatable, Sendable {
        /// Started and stopped (or logged afterwards) by the wearer.
        case manual
        /// Still running at the cap: closed at `startUnix + maxOpenSeconds`.
        case autoEnded = "auto_ended"
    }

    /// Lowercase UUID chosen on the phone; the server's idempotency key (`client_id`).
    public var id: String
    public var typeId: String
    public var startUnix: Int
    public var endUnix: Int?
    public var source: Source
    public var notes: String?
    /// Soft delete: kept (and synced) so the server drops it too, then pruned.
    public var deleted: Bool
    public var updatedUnix: Int
    public var syncedUnix: Int?

    public init(id: String, typeId: String, startUnix: Int, endUnix: Int? = nil, source: Source = .manual,
                notes: String? = nil, deleted: Bool = false, updatedUnix: Int, syncedUnix: Int? = nil) {
        self.id = id; self.typeId = typeId; self.startUnix = startUnix; self.endUnix = endUnix; self.source = source
        self.notes = notes; self.deleted = deleted; self.updatedUnix = updatedUnix; self.syncedUnix = syncedUnix
    }

    public var isOpen: Bool { endUnix == nil && !deleted }
    public var needsSync: Bool { syncedUnix != updatedUnix }
    public var type: WorkoutTypeCatalog.Entry? { WorkoutTypeCatalog.entry(id: typeId) }

    /// The end the pipelines use: the stored end, or for a running workout `now`, never past the cap.
    public func effectiveEnd(now: Int) -> Int {
        endUnix ?? min(max(now, startUnix), startUnix + WorkoutModeLog.maxOpenSeconds)
    }
}

/// A logged workout as the pipelines see it: an interval with its catalogue type.
public struct LoggedWorkoutSpan: Equatable, Sendable, Codable {
    public var startUnix: Int
    /// Effective end (exclusive): the stored end, or now for a running workout.
    public var endUnix: Int
    public var typeId: String
    public var open: Bool
    public init(startUnix: Int, endUnix: Int, typeId: String, open: Bool = false) {
        self.startUnix = startUnix; self.endUnix = endUnix; self.typeId = typeId; self.open = open
    }
    public var type: WorkoutTypeCatalog.Entry? { WorkoutTypeCatalog.entry(id: typeId) }
    public func covers(_ unix: Int) -> Bool { unix >= startUnix && unix < endUnix }
    /// The span covering `unix`, the newest first.
    public static func span(at unix: Int, in spans: [LoggedWorkoutSpan]) -> LoggedWorkoutSpan? {
        spans.last { $0.covers(unix) }
    }
}

public enum WorkoutModeError: Error, Equatable {
    case alreadyRunning
    case notRunning
    case unknownType
    case invalidInterval
    case overlapsAnother
    case notFound
}

public struct WorkoutModeLog: Codable, Equatable, Sendable {
    public var entries: [WorkoutModeEntry]

    /// A running workout is closed here (an evening gym session runs 1–2 h; four hours is a forgotten Stop).
    public static let maxOpenSeconds = 4 * 3600
    /// A stop sooner than this was an accidental start: the entry is deleted (as the live tracker discards it).
    public static let minimumSeconds = 60
    /// A workout logged afterwards is at most this long.
    public static let maxPastSeconds = 12 * 3600
    /// Synced entries older than this leave the phone (the server keeps them).
    public static let retentionSeconds = 30 * 86_400

    public static let empty = WorkoutModeLog(entries: [])

    public init(entries: [WorkoutModeEntry]) { self.entries = entries }

    public var active: WorkoutModeEntry? { entries.last { $0.isOpen } }

    // MARK: Lifecycle

    /// Start a workout of `typeId` at `now` (or at `startUnix`, when a session already running elsewhere is adopted).
    /// A forgotten one past the cap is closed first.
    @discardableResult
    public mutating func start(typeId: String, now: Int, startUnix: Int? = nil,
                               id: String = UUID().uuidString.lowercased()) throws -> WorkoutModeEntry {
        guard WorkoutTypeCatalog.entry(id: typeId) != nil else { throw WorkoutModeError.unknownType }
        autoEndIfOverdue(now: now)
        guard active == nil else { throw WorkoutModeError.alreadyRunning }
        let entry = WorkoutModeEntry(id: id, typeId: typeId, startUnix: min(startUnix ?? now, now), updatedUnix: now)
        entries.append(entry)
        return entry
    }

    /// The running workout is a different kind than first picked.
    public mutating func changeType(_ typeId: String, now: Int) throws {
        guard WorkoutTypeCatalog.entry(id: typeId) != nil else { throw WorkoutModeError.unknownType }
        guard let i = entries.lastIndex(where: { $0.isOpen }) else { throw WorkoutModeError.notRunning }
        guard entries[i].typeId != typeId else { return }
        entries[i].typeId = typeId
        entries[i].updatedUnix = bumped(entries[i], now)
    }

    /// Stop the running workout at `now`. Shorter than `minimumSeconds` it was an accident and is deleted. Returns the
    /// entry as stored (deleted or not).
    @discardableResult
    public mutating func stop(now: Int) throws -> WorkoutModeEntry {
        guard let i = entries.lastIndex(where: { $0.isOpen }) else { throw WorkoutModeError.notRunning }
        let cap = entries[i].startUnix + Self.maxOpenSeconds
        let end = min(max(now, entries[i].startUnix), cap)
        entries[i].endUnix = end
        if now > cap { entries[i].source = .autoEnded }
        if end - entries[i].startUnix < Self.minimumSeconds { entries[i].deleted = true }
        entries[i].updatedUnix = bumped(entries[i], now)
        return entries[i]
    }

    /// Close a workout still running at the cap: it ends at `startUnix + maxOpenSeconds`, flagged `autoEnded`.
    @discardableResult
    public mutating func autoEndIfOverdue(now: Int) -> WorkoutModeEntry? {
        guard let i = entries.lastIndex(where: { $0.isOpen }),
              now >= entries[i].startUnix + Self.maxOpenSeconds else { return nil }
        entries[i].endUnix = entries[i].startUnix + Self.maxOpenSeconds
        entries[i].source = .autoEnded
        entries[i].updatedUnix = bumped(entries[i], now)
        return entries[i]
    }

    /// Log a workout that already happened. It may not overlap another logged workout, end in the future, or be
    /// longer than `maxPastSeconds`.
    @discardableResult
    public mutating func logPast(typeId: String, startUnix: Int, endUnix: Int, now: Int,
                                 id: String = UUID().uuidString.lowercased()) throws -> WorkoutModeEntry {
        guard WorkoutTypeCatalog.entry(id: typeId) != nil else { throw WorkoutModeError.unknownType }
        guard endUnix - startUnix >= Self.minimumSeconds, endUnix - startUnix <= Self.maxPastSeconds,
              endUnix <= now else { throw WorkoutModeError.invalidInterval }
        let overlaps = entries.contains { e in
            !e.deleted && e.startUnix < endUnix && e.effectiveEnd(now: now) > startUnix
        }
        guard !overlaps else { throw WorkoutModeError.overlapsAnother }
        let entry = WorkoutModeEntry(id: id, typeId: typeId, startUnix: startUnix, endUnix: endUnix, updatedUnix: now)
        entries.append(entry)
        entries.sort { $0.startUnix < $1.startUnix }
        return entry
    }

    /// Delete a logged workout (a running one is stopped by it).
    public mutating func delete(id: String, now: Int) throws {
        guard let i = entries.firstIndex(where: { $0.id == id && !$0.deleted }) else { throw WorkoutModeError.notFound }
        if entries[i].endUnix == nil {
            entries[i].endUnix = max(entries[i].startUnix, min(now, entries[i].startUnix + Self.maxOpenSeconds))
        }
        entries[i].deleted = true
        entries[i].updatedUnix = bumped(entries[i], now)
    }

    /// `client_updated_at` must move forward on every edit, even two in the same second.
    private func bumped(_ e: WorkoutModeEntry, _ now: Int) -> Int { max(now, e.updatedUnix + 1) }

    // MARK: Sync bookkeeping

    public var pendingSync: [WorkoutModeEntry] { entries.filter(\.needsSync) }

    /// The server accepted these versions (`id` → the `updatedUnix` sent). A newer local edit stays pending.
    public mutating func markSynced(_ sent: [String: Int]) {
        for i in entries.indices {
            if let v = sent[entries[i].id], v == entries[i].updatedUnix { entries[i].syncedUnix = v }
        }
    }

    /// Drop synced entries that ended more than `retentionSeconds` ago, and synced deletions.
    public mutating func prune(now: Int) {
        entries.removeAll { e in
            guard !e.needsSync, let end = e.endUnix else { return false }
            return e.deleted || now - end > Self.retentionSeconds
        }
    }

    /// At most this many workouts per `POST scores/workouts`.
    public static let syncBatch = 50

    /// The `POST scores/workouts` body for `entries` (docs/context-watchdog/WORKOUTS.md): times in unix seconds, the
    /// strap's server device id, the type checked against the catalogue on the server.
    public static func serverBody(_ entries: [WorkoutModeEntry], deviceId: String,
                                  localDeviceId: String?) -> [String: Any] {
        var body: [String: Any] = [
            "device_id": deviceId, "catalogue_version": WorkoutTypeCatalog.version,
            "workouts": entries.map { e -> [String: Any] in
                var w: [String: Any] = ["client_id": e.id, "type": e.typeId, "started_at": e.startUnix,
                                        "ended_at": e.endUnix.map { $0 as Any } ?? NSNull(),
                                        "source": e.source.rawValue, "deleted": e.deleted,
                                        "client_updated_at": e.updatedUnix]
                if let notes = e.notes, !notes.isEmpty { w["notes"] = notes }
                return w
            },
        ]
        if let localDeviceId { body["local_device_id"] = localDeviceId }
        return body
    }

    // MARK: Pipelines

    /// The logged workouts overlapping `[from, to)` as the pipelines see them (deleted ones never), oldest first.
    public func spans(from: Int, to: Int, now: Int) -> [LoggedWorkoutSpan] {
        entries.filter { !$0.deleted }
            .map { LoggedWorkoutSpan(startUnix: $0.startUnix, endUnix: $0.effectiveEnd(now: now), typeId: $0.typeId,
                                     open: $0.endUnix == nil) }
            .filter { $0.endUnix > $0.startUnix && $0.startUnix < to && $0.endUnix > from }
            .sorted { $0.startUnix < $1.startUnix }
    }
}
