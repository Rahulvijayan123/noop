import Foundation
import StrandAnalytics

/// The wearer's last personal-profile fit (`ActivityPersonalProfileFitter`): the adopted profile the activity
/// decoder scores with, or why the defaults were kept, plus a fingerprint of what it was fit on so a launch
/// only refits when the labels or their evidence changed.
///
/// Scoped like `GaitWindowStore` (account, then strap, reading `ActivityEncoderWindowStore`'s scope): a profile
/// fit on one wearer's strap is never applied to another's. Thread-safe: the decoder config is read off the
/// main actor.
final class ActivityPersonalProfileStore: @unchecked Sendable {
    static let shared = ActivityPersonalProfileStore()

    struct Record: Codable, Equatable {
        /// What the fit saw (`Repository.activityPersonalFingerprint`); equal means a refit would repeat it.
        var fingerprint: String
        var result: ActivityPersonalFitResult
        /// The heart-rate-by-posture fit from the same labels (`ActivityPostureHeartRateFitter`, hsmm-2.0); nil in
        /// records written before it existed, and then refit on the next pass.
        var postureHeartRate: ActivityPostureHeartRateFitResult? = nil
        /// Per-placement fits (hsmm-2.0), keyed by `ActivityWearPlacement.calibrationKey`: runs and labels made on the
        /// wrist fit the wrist's profile, those made on the bicep the bicep's. `result` / `postureHeartRate` above
        /// mirror the placement worn at fit time (what the summary card shows). nil in records written before
        /// placement-scoped calibration; such a record applies to no placement until the next fit.
        var placements: [String: PlacementFit]? = nil
        /// The calibration key worn when this record was fitted.
        var currentPlacement: String? = nil
    }

    /// One placement's calibration: the activity profile fit and the heart-rate-by-posture fit from its labels.
    struct PlacementFit: Codable, Equatable {
        var result: ActivityPersonalFitResult
        var postureHeartRate: ActivityPostureHeartRateFitResult?
        /// Guided runs and posture-labelled stretches recorded at this placement.
        var runs: Int
        var labels: Int
    }

    private let lock = NSLock()
    private let directory: URL
    private let scopeSource: () -> ActivityEncoderWindowStore.Scope?
    private var cached: (scope: ActivityEncoderWindowStore.Scope, record: Record?)?

    init(directory: URL? = nil,
         scope: @escaping () -> ActivityEncoderWindowStore.Scope? = { ActivityEncoderWindowStore.shared.currentScope }) {
        let fm = FileManager.default
        let base = directory ?? ((try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)) ?? fm.temporaryDirectory)
            .appendingPathComponent("OpenWhoop/ActivityPersonalProfile", isDirectory: true)
        self.directory = base
        self.scopeSource = scope
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    var currentScope: ActivityEncoderWindowStore.Scope? { scopeSource() }

    /// The stored fit for the current account and strap; nil when there is none or no scope.
    func record() -> Record? {
        lock.lock(); defer { lock.unlock() }
        guard let scope = scopeSource() else { return nil }
        return recordLocked(scope)
    }

    /// The profiles the decoder scores with, per placement: each placement's own fit, only when it was adopted. A
    /// record from before placement-scoped calibration contributes nothing (it does not say where its runs were worn).
    var adoptedProfiles: [String: ActivityPersonalProfile] {
        guard let placements = record()?.placements else { return [:] }
        return placements.compactMapValues { $0.result.status == .adopted ? $0.result.profile : nil }
    }

    /// The heart-rate-by-posture models the decoder may read, per placement: only adopted fits (no model stands in
    /// before then).
    var adoptedPostureHeartRates: [String: ActivityPostureHeartRateModel] {
        guard let placements = record()?.placements else { return [:] }
        return placements.compactMapValues { fit in
            guard let hr = fit.postureHeartRate, hr.status == .adopted, let model = hr.model, model.isUsable else { return nil }
            return model
        }
    }

    /// A stable summary of what is adopted where (for change detection and logs), e.g. "bicep:pp-a1b2,wrist:none".
    var adoptedSummary: String {
        let p = adoptedProfiles, h = adoptedPostureHeartRates
        return Set(p.keys).union(h.keys).sorted().map { key in
            "\(key):\(p[key].map { "pp-" + $0.tag } ?? "none")/\(h[key].map { "ph-" + $0.tag } ?? "none")"
        }.joined(separator: ",")
    }

    /// Store a fit made under `expected`. Refused when the scope changed meanwhile (the fit read another
    /// wearer's labels or strap). Returns true when it was written.
    @discardableResult
    func save(_ record: Record, scope expected: ActivityEncoderWindowStore.Scope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard scopeSource() == expected, let url = file(scope: expected) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record), (try? data.write(to: url, options: .atomic)) != nil else {
            return false
        }
        cached = (expected, record)
        return true
    }

    // MARK: Private (lock held)

    private func recordLocked(_ scope: ActivityEncoderWindowStore.Scope) -> Record? {
        if let cached, cached.scope == scope { return cached.record }
        let record = file(scope: scope)
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        cached = (scope, record)
        return record
    }

    private func file(scope: ActivityEncoderWindowStore.Scope) -> URL? {
        func safe(_ s: String) -> String? {
            let ok = !s.isEmpty && s.count <= 128 && s.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
            return ok && s != "." && s != ".." ? s : nil
        }
        guard let owner = safe(scope.ownerId.lowercased()), let device = safe(scope.deviceId) else { return nil }
        return directory.appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(device, isDirectory: true)
            .appendingPathComponent("personal-profile.json")
    }
}
