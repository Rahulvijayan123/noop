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

    /// The profile the decoder should score with: the stored fit's, only when it was adopted.
    var adoptedProfile: ActivityPersonalProfile? {
        guard let record = record(), record.result.status == .adopted else { return nil }
        return record.result.profile
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
