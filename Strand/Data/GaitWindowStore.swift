import Foundation
import StrandAnalytics

/// ElderNet's per-window gait output fetched from the server (`GET scores/gait-windows`), kept on disk so the
/// phone's activity decoder can use it beside HART's windows.
///
/// Same layout and scope as `ActivityEncoderWindowStore` (one file per UTC day under the account and strap), and
/// it reads that store's scope, so the two can never describe different straps.
///
/// Each day keeps the release the server recorded for it, with the pins, prior and input revision it was produced
/// under. What the decoder may do with a day is decided by the shared policy (`ActivityExpertSelection`) from those
/// stored fields alone (`sources(from:to:)`): the phone never builds an ElderNet config of its own, so a shadow or
/// candidate row can never shape the decode the wearer sees.
///
/// Thread-safe: the decoder input is assembled off the main actor.
final class GaitWindowStore: @unchecked Sendable {
    static let shared = GaitWindowStore()

    /// One stored UTC day. Every field after `windowsJSON` arrived with the release-authority route fields
    /// (docs/model-integration/activity-authority.md); a record stored before them decodes with them nil, and so
    /// reads as its recorded `mode` with no pins and no prior, which the policy treats as shadow.
    struct DayRecord: Codable, Equatable {
        var day: String
        var resultRevision: String
        /// The worker mode the row was written under (`shadow` / `candidate`).
        var mode: String
        var model: GaitQualityModelInfo
        /// The `gait-windows-1` object, kept as the JSON text it arrived as.
        var windowsJSON: String
        /// The row's release after the producer's own lowering (`release_mode`); nil from an older server.
        var releaseMode: String? = nil
        /// The raw-IMU input revision the windows were computed from.
        var inputRevision: Int64? = nil
        /// What the producer pinned and decoded with (the row's `authority` block); nil = not pinned / not set.
        var pinnedModelVersion: String? = nil
        var pinnedWeightsDigest: String? = nil
        var gaitPrior: Double? = nil
        /// The producer's own view of the row (`authority.use` / `authority.reason`), kept for inspection only:
        /// the policy is always re-run here and only ever lowers.
        var producerUse: String? = nil
        var producerReason: String? = nil
        /// The row's model identity as the route named it (`identity`).
        var identity: [String: String]? = nil

        /// The weakest release the stored fields record: `mode` and `release_mode` (the weaker of the route's and
        /// the authority block's), a missing or unknown one reading as shadow. Never production unless both say so.
        var recordedRelease: ActivityReleaseMode {
            var release = ActivityReleaseMode(recorded: mode)
            if let releaseMode { release = release.lowered(to: ActivityReleaseMode(recorded: releaseMode)) }
            return release
        }

        /// Equal in everything but the windows' JSON text.
        func sameStamp(as other: DayRecord) -> Bool {
            var a = self, b = other
            a.windowsJSON = ""; b.windowsJSON = ""
            return a == b
        }
    }

    private let lock = NSLock()
    private let directory: URL
    private let scopeSource: () -> ActivityEncoderWindowStore.Scope?
    private var parsed: [String: (record: DayRecord, columns: GaitWindowColumns?)?] = [:]
    private var parsedScope: ActivityEncoderWindowStore.Scope?

    init(directory: URL? = nil,
         scope: @escaping () -> ActivityEncoderWindowStore.Scope? = { ActivityEncoderWindowStore.shared.currentScope }) {
        let fm = FileManager.default
        let base = directory ?? ((try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)) ?? fm.temporaryDirectory)
            .appendingPathComponent("OpenWhoop/GaitWindows", isDirectory: true)
        self.directory = base
        self.scopeSource = scope
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    /// The stored result revision of each of `days`, for the route's `known` parameter.
    func revisions(days: [String]) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        guard let scope = currentScope() else { return [:] }
        var out: [String: String] = [:]
        for day in days { if let hit = entry(day: day, scope: scope) { out[day] = hit.record.resultRevision } }
        return out
    }

    /// Store a day the route returned with its windows and model. Returns true when it differs from what is stored.
    @discardableResult
    func save(_ record: DayRecord, scope expected: ActivityEncoderWindowStore.Scope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard currentScope() == expected, let url = file(day: record.day, scope: expected) else { return false }
        // The result revision names the windows (their JSON text can differ in key order); everything else the
        // record holds is compared, so a demoted or newly pinned row is stored even at the same revision.
        if let existing = entry(day: record.day, scope: expected)?.record,
           existing.sameStamp(as: record) { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(record), (try? data.write(to: url, options: .atomic)) != nil else {
            return false
        }
        parsed[record.day] = nil
        return true
    }

    /// A day the route answered `unchanged` with a lower release than the one stored (a row can be demoted
    /// without new windows): lower the stored record to it. Never raises. Returns true when the record changed.
    @discardableResult
    func lowerRelease(day: String, to release: ActivityReleaseMode,
                      scope expected: ActivityEncoderWindowStore.Scope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard currentScope() == expected, let url = file(day: day, scope: expected),
              var record = entry(day: day, scope: expected)?.record, release < record.recordedRelease else { return false }
        record.releaseMode = release.rawValue
        guard let data = try? JSONEncoder().encode(record), (try? data.write(to: url, options: .atomic)) != nil else {
            return false
        }
        parsed[day] = nil
        return true
    }

    /// The stored days overlapping `[from, to)` as the shared policy's sources: each day's windows ending inside the
    /// span, with the release, pins, prior and input revision the row recorded. Days without windows in the span
    /// are left out. `ActivityExpertSelection.select` decides what, if anything, they may shape.
    func sources(from: Int, to: Int) -> [GaitQualitySource] {
        guard to > from else { return [] }
        lock.lock(); defer { lock.unlock() }
        guard let scope = currentScope() else { return [] }
        var out: [GaitQualitySource] = []
        for day in ActivityEncoderWindowStore.utcDays(from: from, to: to) {
            guard let hit = entry(day: day, scope: scope), let columns = hit.columns else { continue }
            let windows = columns.trackWindows(from: from, to: to)
                .sorted { ($0.endTs, $0.startTs) < ($1.endTs, $1.startTs) }
            guard !windows.isEmpty else { continue }
            let r = hit.record
            out.append(GaitQualitySource(track: GaitQualityTrackInput(model: r.model, windows: windows),
                                         releaseMode: r.recordedRelease, route: .standalone,
                                         expectedModelVersion: r.pinnedModelVersion,
                                         expectedWeightsDigest: r.pinnedWeightsDigest,
                                         gaitPrior: r.gaitPrior, inputRevision: r.inputRevision, day: day))
        }
        return out
    }

    /// The windows ending inside `[from, to)` from `model`, across every stored UTC day overlapping it; nil when
    /// there are none. They carry no release (`releaseMode` nil), so only a candidate config accepts them; the
    /// canonical decode reads `sources(from:to:)` through the policy instead.
    func trackInput(from: Int, to: Int, model: GaitQualityModelInfo) -> GaitQualityTrackInput? {
        guard to > from else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let scope = currentScope() else { return nil }
        var windows: [GaitQualityWindow] = []
        for day in ActivityEncoderWindowStore.utcDays(from: from, to: to) {
            guard let hit = entry(day: day, scope: scope), hit.record.model == model, let columns = hit.columns
            else { continue }
            windows += columns.trackWindows(from: from, to: to)
        }
        guard !windows.isEmpty else { return nil }
        windows.sort { ($0.endTs, $0.startTs) < ($1.endTs, $1.startTs) }
        return GaitQualityTrackInput(model: model, windows: windows)
    }

    // MARK: Private (lock held)

    private func currentScope() -> ActivityEncoderWindowStore.Scope? {
        let scope = scopeSource()
        if scope != parsedScope { parsed = [:]; parsedScope = scope }
        return scope
    }

    private func entry(day: String, scope: ActivityEncoderWindowStore.Scope)
        -> (record: DayRecord, columns: GaitWindowColumns?)? {
        if let hit = parsed[day] { return hit }
        guard let url = file(day: day, scope: scope), let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(DayRecord.self, from: data) else {
            parsed[day] = .some(nil)
            return nil
        }
        let object = record.windowsJSON.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let hit = (record: record, columns: GaitWindowColumns(object))
        parsed[day] = .some(hit)
        return hit
    }

    private func scopeDirectory(_ scope: ActivityEncoderWindowStore.Scope) -> URL? {
        func safe(_ s: String) -> String? {
            let ok = !s.isEmpty && s.count <= 128 && s.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
            return ok && s != "." && s != ".." ? s : nil
        }
        guard let owner = safe(scope.ownerId.lowercased()), let device = safe(scope.deviceId) else { return nil }
        return directory.appendingPathComponent(owner, isDirectory: true).appendingPathComponent(device, isDirectory: true)
    }

    private func file(day: String, scope: ActivityEncoderWindowStore.Scope) -> URL? {
        guard day.count == 10, day.allSatisfy({ $0.isNumber || $0 == "-" }) else { return nil }
        return scopeDirectory(scope)?.appendingPathComponent("\(day).json")
    }
}

extension GaitWindowStore.DayRecord {
    /// A full day the route sent; nil without a trusted model or windows (`unchanged` days carry neither).
    init?(_ day: ServerScoreRepository.GaitWindowsDay) {
        guard !day.unchanged, let model = day.model, let json = day.windowsJSON else { return nil }
        self.init(day: day.day, resultRevision: day.resultRevision, mode: day.mode, model: model,
                  windowsJSON: json, releaseMode: day.releaseMode, inputRevision: day.inputRevision,
                  pinnedModelVersion: day.pinnedModelVersion, pinnedWeightsDigest: day.pinnedWeightsDigest,
                  gaitPrior: day.gaitPrior, producerUse: day.producerUse, producerReason: day.producerReason,
                  identity: day.identity)
    }
}
