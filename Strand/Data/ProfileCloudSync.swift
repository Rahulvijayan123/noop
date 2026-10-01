import Foundation
import Combine

/// The Settings profile as the cloud `profiles` row stores it. Nil fields are not stored yet.
struct CloudProfile: Codable, Equatable, Sendable {
    var displayName: String
    /// `yyyy-MM-dd`.
    var dateOfBirth: String?
    var sex: String?
    var heightCm: Double?
    var weightKg: Double?
}

/// Keeps name, date of birth, sex, height and weight in the owner's cloud profile, so they come back after
/// a reinstall or on a second device and are the values server-side scoring uses. Cloud mode only.
///
/// Last write wins. An edit marks the local profile dirty and uploads a couple of seconds later; while it is
/// dirty the cloud never overwrites it. A clean profile adopts whatever the cloud holds each time the app
/// becomes active. A failed upload leaves the profile dirty, so it is retried instead of dropped.
@MainActor
final class ProfileCloudSync {
    private let profile: ProfileStore
    private let isAvailable: () -> Bool
    private let fetch: () async throws -> CloudProfile?
    private let save: (CloudProfile) async throws -> Void
    private var subscription: AnyCancellable?
    private var inFlight = false

    init(profile: ProfileStore,
         debounce: TimeInterval = 2,
         isAvailable: @escaping () -> Bool = { CloudPushSettings.isEnabled && CoachAPI.shared.isAvailable },
         fetch: @escaping () async throws -> CloudProfile? = { try await CoachAPI.shared.profile() },
         save: @escaping (CloudProfile) async throws -> Void = { try await CoachAPI.shared.saveProfile($0) }) {
        self.profile = profile
        self.isAvailable = isAvailable
        self.fetch = fetch
        self.save = save
        // `objectWillChange` also fires for unrelated profile fields; the dirty check makes those free.
        subscription = profile.objectWillChange
            .debounce(for: .seconds(debounce), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in await self?.pushIfDirty() } }
    }

    /// Run when the app becomes active.
    func reconcile() async {
        guard !inFlight, isAvailable() else { return }
        inFlight = true
        defer { inFlight = false }
        do {
            let remote = try await fetch()
            if profile.cloudDirty || (remote == nil && profile.hasStoredCloudFields) {
                try await upload()
            } else if let remote {
                profile.applyCloud(remote)
            }
        } catch {
            // Offline or not enrolled yet: local values stay authoritative and dirty edits stay queued.
        }
    }

    func pushIfDirty() async {
        guard profile.cloudDirty, !inFlight, isAvailable() else { return }
        inFlight = true
        defer { inFlight = false }
        try? await upload()
    }

    private func upload() async throws {
        let sent = profile.cloudSnapshot
        try await save(sent)
        if profile.cloudSnapshot == sent {
            profile.cloudDirty = false
        } else {
            // Edited while the request was in flight: that edit still needs its own upload.
            Task { @MainActor in await pushIfDirty() }
        }
    }
}
