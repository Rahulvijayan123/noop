import Foundation
import Combine
import StrandAnalytics

/// A preference that follows the account rather than the phone: the name the cloud `settings` route keeps it
/// under, the defaults key this phone keeps it in, and what a valid value is.
struct SyncedSetting: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case bool
        case int(ClosedRange<Int>)
        case choice([String])
    }

    let cloudKey: String
    let defaultsKey: String
    let kind: Kind

    init(_ cloudKey: String, _ defaultsKey: String, _ kind: Kind) {
        self.cloudKey = cloudKey
        self.defaultsKey = defaultsKey
        self.kind = kind
    }

    /// `raw` as a value of this setting, or nil when it is not one (another type, out of range, unknown).
    func value(_ raw: Any?) -> SettingValue? {
        switch kind {
        case .bool:
            // JSON and defaults both hand booleans over as NSNumber; only a real boolean counts.
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return .bool(number.boolValue)
        case .int(let range):
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let whole = Int(exactly: number.doubleValue), range.contains(whole) else { return nil }
            return .int(whole)
        case .choice(let options):
            guard let string = raw as? String, options.contains(string) else { return nil }
            return .string(string)
        }
    }

    /// Everything Settings keeps in the account besides the profile and wear placement, which have routes of
    /// their own. What stays on the phone: Apple Health access, the double-tap action and Shortcut names (they
    /// name things on this device), light or dark (like the system's own), cycle awareness and Rhythm (consents
    /// given here) and sensor biomarkers.
    static let all: [SyncedSetting] = [
        SyncedSetting("sanaEnabled", "noop.coachEnabled", .bool),
        SyncedSetting("wristAlerts", AppModel.wristAlertsMasterKey, .bool),
        SyncedSetting("moveReminder", InactivityPrefs.K.enabled, .bool),
        SyncedSetting("moveReminderMinutes", InactivityPrefs.K.threshold, .int(15...120)),
        SyncedSetting("moveReminderRepeatMinutes", InactivityPrefs.K.reNudge, .int(15...120)),
        SyncedSetting("moveReminderBuzzes", InactivityPrefs.K.buzzLoops, .int(1...4)),
        SyncedSetting("moveReminderSetHours", InactivityPrefs.K.activeOn, .bool),
        SyncedSetting("moveReminderStartMinute", InactivityPrefs.K.activeStart, .int(0...1439)),
        SyncedSetting("moveReminderEndMinute", InactivityPrefs.K.activeEnd, .int(0...1439)),
        SyncedSetting("batteryAlerts", BehaviorStore.K.batteryAlerts, .bool),
        SyncedSetting("batteryEarlyWarning", BehaviorStore.K.batteryPredictiveAlerts, .bool),
        SyncedSetting("effortTarget", BehaviorStore.K.strainTargetNudge, .bool),
        SyncedSetting("illnessSigns", BehaviorStore.K.illness, .bool),
        SyncedSetting("hapticBreathing", HapticPrefs.breathing, .bool),
        SyncedSetting("hapticIntervals", HapticPrefs.intervals, .bool),
        SyncedSetting("hapticLiftRest", HapticPrefs.liftRest, .bool),
        SyncedSetting("hapticLiveSession", HapticPrefs.liveSession, .bool),
        SyncedSetting("hapticWorkout", HapticPrefs.workout, .bool),
        SyncedSetting("zoneCoaching", BehaviorStore.K.zoneCoaching, .bool),
        SyncedSetting("stressCheckIns", BehaviorStore.K.stressCheckIn, .bool),
        SyncedSetting("stressAutoStart", BehaviorStore.K.stressAutoNudge, .bool),
        SyncedSetting("stressQuietOvernight", BehaviorStore.K.stressQuietHours, .bool),
        SyncedSetting("stressResonancePace", BehaviorStore.K.stressUseResonance, .bool),
    ]
}

enum SettingValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case string(String)

    /// The value as JSON and property lists store it.
    var stored: Any {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value
        case .string(let value): return value
        }
    }
}

extension Notification.Name {
    /// Posted after preferences arrived from the account were written to defaults. Stores that keep these
    /// values in memory re-read them.
    static let syncedSettingsDidApply = Notification.Name("SettingsCloudSync.didApply")
}

/// Keeps the account-wide preferences (`SyncedSetting.all`) in the owner's cloud settings, so units, alerts,
/// haptics and the Sana switch come back after a reinstall or on a second phone. Cloud mode only.
///
/// Only values this phone has stored take part: an unset key means "the default" everywhere, so nothing here
/// restates a store's defaults. Each key merges three ways against the last exchange: a value changed on this
/// phone since then is uploaded, a value changed elsewhere is adopted, and on a phone's first exchange with an
/// account the account's saved values win (the same rule as the profile). A failed exchange changes nothing
/// it would not redo, so it is simply retried on the next edit or activation.
@MainActor
final class SettingsCloudSync {
    private let defaults: UserDefaults
    private let settings: [SyncedSetting]
    private let isAvailable: () -> Bool
    private let owner: () -> String?
    private let fetch: () async throws -> [String: Any]?
    private let save: ([String: Any]) async throws -> Void
    private let onApplied: ([String]) -> Void
    private var subscription: AnyCancellable?
    private var inFlight = false
    private var changedDuringFlight = false

    static let baseKey = "settingsSync.base.v1"
    static let ownerKey = "settingsSync.owner.v1"

    init(defaults: UserDefaults = .standard,
         settings: [SyncedSetting] = SyncedSetting.all,
         throttle: TimeInterval = 2,
         isAvailable: @escaping () -> Bool = {
             // Same rule as the profile: only the account that owns this phone's data exchanges its settings.
             CloudPushSettings.isEnabled && CoachAPI.shared.isAvailable
                 && CloudLocalDataBinding.signedInAccountOwnsLocalData()
         },
         owner: @escaping () -> String? = { CloudPushIdentityStore.current()?.ownerId },
         fetch: @escaping () async throws -> [String: Any]? = { try await CoachAPI.shared.settings() },
         save: @escaping ([String: Any]) async throws -> Void = { try await CoachAPI.shared.saveSettings($0) },
         onApplied: @escaping ([String]) -> Void = { _ in }) {
        self.defaults = defaults
        self.settings = settings
        self.isAvailable = isAvailable
        self.owner = owner
        self.fetch = fetch
        self.save = save
        self.onApplied = onApplied
        // Every defaults write in the app lands here, so this throttles rather than debounces: a debounce would
        // never fire while something else keeps writing. The snapshot comparison makes unrelated writes free.
        subscription = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .throttle(for: .seconds(throttle), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in Task { @MainActor in await self?.syncIfChanged() } }
    }

    /// Run when the app becomes active and when the account is ready.
    func reconcile() async {
        guard isAvailable() else { return }
        guard !inFlight else {
            changedDuringFlight = true
            return
        }
        inFlight = true
        defer { inFlight = false }
        do {
            try await exchange()
        } catch {
            // Offline, or the server does not have the route yet: nothing was recorded as exchanged.
        }
        if changedDuringFlight {
            changedDuringFlight = false
            Task { @MainActor in await syncIfChanged() }
        }
    }

    /// Exchanges only when this phone holds a value the last exchange did not.
    func syncIfChanged() async {
        guard localSnapshot() != base() else { return }
        await reconcile()
    }

    // MARK: Exchange

    private func exchange() async throws {
        let remote = try await fetch().map(snapshot(cloud:)) ?? [:]
        let plan = Self.merge(local: localSnapshot(), remote: remote, base: base())
        if !plan.adopt.isEmpty {
            for setting in settings {
                if let value = plan.adopt[setting.cloudKey] { defaults.set(value.stored, forKey: setting.defaultsKey) }
            }
            NotificationCenter.default.post(name: .syncedSettingsDidApply, object: self)
            onApplied(plan.adopt.keys.sorted())
        }
        if !plan.upload.isEmpty {
            try await save(plan.upload.mapValues(\.stored))
        }
        defaults.set(plan.merged.mapValues(\.stored), forKey: Self.baseKey)
        defaults.set(owner(), forKey: Self.ownerKey)
    }

    struct Plan: Equatable {
        /// Values to write on this phone.
        var adopt: [String: SettingValue] = [:]
        /// Values to send to the account.
        var upload: [String: SettingValue] = [:]
        /// What both sides hold afterwards: the next exchange's base.
        var merged: [String: SettingValue] = [:]
    }

    /// The per-key three-way merge. `base` is what the last exchange left on both sides, nil when this phone
    /// has not exchanged with this account yet.
    nonisolated static func merge(local: [String: SettingValue], remote: [String: SettingValue],
                                  base: [String: SettingValue]?) -> Plan {
        var plan = Plan()
        for key in Set(local.keys).union(remote.keys) {
            let mine = local[key], theirs = remote[key]
            let keepMine: Bool
            if theirs == nil { keepMine = true }
            else if mine == nil { keepMine = false }
            else if let base { keepMine = mine != base[key] }
            else { keepMine = false }
            guard let value = keepMine ? mine : theirs else { continue }
            plan.merged[key] = value
            if value != mine { plan.adopt[key] = value }
            if value != theirs { plan.upload[key] = value }
        }
        return plan
    }

    // MARK: Snapshots

    func localSnapshot() -> [String: SettingValue] {
        var out: [String: SettingValue] = [:]
        for setting in settings {
            if let value = setting.value(defaults.object(forKey: setting.defaultsKey)) { out[setting.cloudKey] = value }
        }
        return out
    }

    private func snapshot(cloud: [String: Any]) -> [String: SettingValue] {
        var out: [String: SettingValue] = [:]
        for setting in settings {
            if let value = setting.value(cloud[setting.cloudKey]) { out[setting.cloudKey] = value }
        }
        return out
    }

    /// The last exchange's result, if it was with the account signed in now.
    private func base() -> [String: SettingValue]? {
        guard let stored = defaults.dictionary(forKey: Self.baseKey),
              defaults.string(forKey: Self.ownerKey) == owner() else { return nil }
        return snapshot(cloud: stored)
    }
}
