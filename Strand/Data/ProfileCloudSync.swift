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
    /// The owner's reporting timezone (IANA id), read by server scoring claims via `profiles.timezone`.
    /// The DEVICE writes it (contract C2); the app never adopts a cloud value (the phone is the
    /// timezone authority), and nil means the server has not stored/returned it yet.
    var timezone: String?

    /// Whether the owner has saved any profile value. The `profiles` row exists from sign-up with every
    /// field empty except `timezone` (NOT NULL, default 'UTC'), and the route returns that row as a
    /// profile, so "the cloud has a profile" has to be read from the fields themselves.
    var hasSavedFields: Bool {
        !displayName.isEmpty || dateOfBirth != nil || sex != nil || heightCm != nil || weightKg != nil
    }
}

/// Keeps name, date of birth, sex, height, weight and the reporting timezone in the owner's cloud
/// profile, so they come back after a reinstall or on a second device and are the values server-side
/// scoring uses. The timezone is DEVICE-AUTHORITATIVE: it is refreshed from the phone's current IANA
/// zone at each sync and uploaded whenever it changes (travel), so server scoring claims use the same
/// zone as the phone. Cloud mode only.
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
         isAvailable: @escaping () -> Bool = {
             // The profile on this phone is one device-wide record. Only the account that owns the phone's
             // on-device data may exchange it with the cloud; another account signing in on the same phone
             // must neither upload it as its own nor have it replaced by its own.
             CloudPushSettings.isEnabled && CoachAPI.shared.isAvailable
                 && CloudLocalDataBinding.signedInAccountOwnsLocalData()
         },
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
            // The reporting timezone is DEVICE-AUTHORITATIVE (spec §3 / contract C2): refresh it from the
            // phone's current zone before deciding what to upload, so travel moves the synced zone on the
            // next profile sync. A stored server zone that disagrees with the phone must never win (a
            // 'UTC' default would otherwise decide the user's day ownership), so we push ours whenever
            // the remote copy names a DIFFERENT zone. A nil remote zone means "the server has not stored
            // one yet": the payload still carries the phone zone on any upload triggered by the other
            // conditions, and once the server returns the field (see the coach.ts write-path gap in
            // daybucket-repair.md) the mismatch push takes over.
            let tzChanged = profile.refreshTimezoneFromDevice()
            if profile.cloudDirty
                || (remote?.hasSavedFields != true && profile.hasStoredCloudFields)
                || tzChanged
                || (remote?.timezone != nil && remote?.timezone != profile.timezone) {
                try await upload()
            } else if let remote {
                profile.applyCloud(remote)
            }
        } catch {
            // Offline or not signed in yet: local values stay authoritative and dirty edits stay queued.
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
