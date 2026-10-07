import Foundation
import StrandAnalytics

/// ElderNet's per-window gait output fetched from the server (`GET scores/gait-windows`), kept on disk so the
/// phone's activity decoder can use it beside HART's windows.
///
/// Same layout and scope as `ActivityEncoderWindowStore` (one file per UTC day under the account and strap), and
/// it reads that store's scope, so the two can never describe different straps.
///
/// Thread-safe: the decoder input is assembled off the main actor.
final class GaitWindowStore: @unchecked Sendable {
    static let shared = GaitWindowStore()

    /// The ElderNet build the decoder accepts evidence from. Windows from any other model or weights are refused by
    /// the evidence config (`GaitQualityEvidenceConfig.evidenceRefusal`), so the day decodes exactly as without them.
    enum Pins {
        static let modelVersion = "eldernet-437a38b"
        static let weightsDigest = "01b2f982a0a2664f455a529a8c483a10106a7ddcd89c326e3d15e24fa4cf4ca6"
        /// Mean served gait probability over the windows the decoder sees (the server's `FRWHOOP_ELDERNET_GAIT_PRIOR`).
        static let gaitPrior = 0.085
    }

    struct DayRecord: Codable, Equatable {
        var day: String
        var resultRevision: String
        /// The server's gait lane mode for the day (`shadow`, `candidate`, `production`). A `shadow` day is the
        /// server saying the windows must not enter a decode, so the phone never decodes with it; the phone
        /// promotes `candidate` windows itself (pinned to `Pins`), and records the mode in the ledger's config tag.
        var mode: String
        var model: GaitQualityModelInfo
        /// The `gait-windows-1` object, kept as the JSON text it arrived as.
        var windowsJSON: String
    }

    private let lock = NSLock()
    private let directory: URL
    private let scopeSource: () -> ActivityEncoderWindowStore.Scope?
    private var parsed: [String: (record: DayRecord, columns: GaitWindowColumns?)?] = [:]
    private var parsedScope: ActivityEncoderWindowStore.Scope?
    private var newestModel: DayRecord??

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
        if let existing = entry(day: record.day, scope: expected)?.record,
           existing.resultRevision == record.resultRevision, existing.model == record.model { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(record), (try? data.write(to: url, options: .atomic)) != nil else {
            return false
        }
        parsed[record.day] = nil
        newestModel = nil
        return true
    }

    static let shadowMode = "shadow"

    /// The model of the newest stored day the decoder may use (not `shadow`), which the decoder config is built
    /// around (nil until any such day is stored).
    var latestModel: GaitQualityModelInfo? {
        lock.lock(); defer { lock.unlock() }
        return newestUsableRecord()?.model
    }

    /// The server mode of that same day (`candidate` / `production`), for provenance.
    var latestMode: String? {
        lock.lock(); defer { lock.unlock() }
        return newestUsableRecord()?.mode
    }

    /// The windows ending inside `[from, to)` from `model`, across every stored UTC day overlapping it; nil when
    /// there are none.
    func trackInput(from: Int, to: Int, model: GaitQualityModelInfo) -> GaitQualityTrackInput? {
        guard to > from else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let scope = currentScope() else { return nil }
        var windows: [GaitQualityWindow] = []
        for day in ActivityEncoderWindowStore.utcDays(from: from, to: to) {
            guard let hit = entry(day: day, scope: scope), hit.record.mode != Self.shadowMode,
                  hit.record.model == model, let columns = hit.columns
            else { continue }
            windows += columns.trackWindows(from: from, to: to)
        }
        guard !windows.isEmpty else { return nil }
        windows.sort { ($0.endTs, $0.startTs) < ($1.endTs, $1.startTs) }
        return GaitQualityTrackInput(model: model, windows: windows)
    }

    /// The decoder's ElderNet evidence for `model`: production, pinned to `Pins`.
    static func evidenceConfig(model: GaitQualityModelInfo) -> GaitQualityEvidenceConfig {
        GaitQualityEvidenceConfig(mode: .production, model: model, gaitPrior: Pins.gaitPrior,
                                  expectedModelVersion: Pins.modelVersion, expectedWeightsDigest: Pins.weightsDigest)
    }

    // MARK: Private (lock held)

    private func newestUsableRecord() -> DayRecord? {
        guard let scope = currentScope() else { return nil }
        if let cached = newestModel { return cached }
        let days = (try? FileManager.default.contentsOfDirectory(atPath: scopeDirectory(scope)?.path ?? ""))?
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted() ?? []
        let record = days.reversed().lazy.compactMap { self.entry(day: $0, scope: scope)?.record }
            .first { $0.mode != Self.shadowMode }
        newestModel = .some(record)
        return record
    }

    private func currentScope() -> ActivityEncoderWindowStore.Scope? {
        let scope = scopeSource()
        if scope != parsedScope { parsed = [:]; newestModel = nil; parsedScope = scope }
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
