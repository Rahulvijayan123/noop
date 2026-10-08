import Foundation
import Combine
import StrandAnalytics

/// InactivityPrefs — settings + persisted de-dup state for the inactivity reminder (#419).
///
/// Mirrors the [BehaviorStore] idiom (UserDefaults-backed `@Published` knobs, single-user, on-device)
/// for the Automations screen, and deliberately REUSES the notification settings keys
/// (`notif.masterEnabled` / `notif.onlyWhenWorn` / `notif.quietHours*`) for the global gates rather
/// than forking them — the same keys `NotificationSettingsStore` writes.
///
/// All gating + de-dup logic lives in the shipped, unit-tested engines. The UI edits the knobs here.
/// The decision is `StandReminderEngine` (a rolling window: remind only when the last `thresholdMinutes`
/// held less than a minute of standing or movement), run by `ActivityContextCoordinator` after each sync
/// through `loadStandConfig` / `loadStandState` / `saveStandState`. The older gravity-only
/// `SedentaryDetector` path (`BLEManager.maybeBuzzInactivity`, via `loadConfig` / `loadState` /
/// `saveState`) reads the same knobs straight from UserDefaults — exactly as the Android `WhoopBleClient`
/// reads SharedPreferences — and stays as the fallback for hosts that never attach the coordinator.
///
/// The active-hours window is evaluated by the engine against the candidate bout's LOCAL end time, NOT
/// `now`: gravity only reaches the app on the strap's offload flush, so an overnight bout is processed
/// in the morning; keying off the bout's own end time is what makes "active hours excludes nighttime
/// sleep" actually hold. iOS-safe (UserDefaults only).
@MainActor
final class InactivityPrefs: ObservableObject {

    /// Feature toggle (opt-in, default OFF). Inert until the notification master is also on.
    @Published var enabled: Bool        { didSet { d.set(enabled, forKey: K.enabled) } }
    /// The rolling window, in minutes: a nudge is due only when this much time held less than a minute of
    /// standing or movement (UI 15–120, step 5; default 50). It was "minutes seated before the first nudge".
    @Published var thresholdMinutes: Int { didSet { d.set(thresholdMinutes, forKey: K.threshold) } }
    /// If still seated, re-buzz this often (UI 15–120, step 15).
    @Published var reNudgeMinutes: Int   { didSet { d.set(reNudgeMinutes, forKey: K.reNudge) } }
    /// Buzz strength in loops (UI 1–4).
    @Published var buzzLoops: Int        { didSet { d.set(buzzLoops, forKey: K.buzzLoops) } }
    /// Only nudge during the active-hours window (default ON).
    @Published var activeHoursEnabled: Bool { didSet { d.set(activeHoursEnabled, forKey: K.activeOn) } }
    /// Active-hours start, minutes since local midnight (default 09:00).
    @Published var activeStartMinutes: Int  { didSet { d.set(activeStartMinutes, forKey: K.activeStart) } }
    /// Active-hours end, minutes since local midnight (default 17:00).
    @Published var activeEndMinutes: Int    { didSet { d.set(activeEndMinutes, forKey: K.activeEnd) } }

    private let d = UserDefaults.standard
    private var syncSubscription: AnyCancellable?
    enum K {
        static let enabled     = "inactivity.enabled"
        static let threshold   = "inactivity.thresholdMinutes"
        static let reNudge     = "inactivity.reNudgeMinutes"
        static let buzzLoops   = "inactivity.buzzLoops"
        static let activeOn    = "inactivity.activeHoursEnabled"
        static let activeStart = "inactivity.activeStartMinutes"
        static let activeEnd   = "inactivity.activeEndMinutes"
        // De-dup / freshness state (persisted so a relaunch can't re-buzz a replayed window).
        static let lastProcessedTs = "inactivity.lastProcessedGravityTs"
        static let lastBuzzAt      = "inactivity.lastBuzzAt"
        static let lastBoutStart   = "inactivity.lastBuzzedBoutStart"
        static let lastBoutEnd     = "inactivity.lastBuzzedBoutEnd"
        // The rolling-window engine's own state (the legacy keys above belong to the gravity detector).
        static let standEvaluatedThrough = "inactivity.stand.evaluatedThrough"
        static let standLastRemindAt     = "inactivity.stand.lastRemindAt"
    }

    // Defaults match SedentaryDetector / the PR #419 numbers. `followsSyncedSettings` is off only for the
    // throwaway read `reload()` makes.
    init(followsSyncedSettings: Bool = true) {
        enabled            = d.object(forKey: K.enabled) as? Bool ?? false
        thresholdMinutes   = d.object(forKey: K.threshold) as? Int ?? StandReminderEngine.defaultWindowMinutes  // 50
        reNudgeMinutes     = d.object(forKey: K.reNudge) as? Int ?? SedentaryDetector.defaultReNudgeMinutes      // 30
        buzzLoops          = d.object(forKey: K.buzzLoops) as? Int ?? SedentaryDetector.defaultBuzzLoops         // 2
        activeHoursEnabled = d.object(forKey: K.activeOn) as? Bool ?? true
        activeStartMinutes = d.object(forKey: K.activeStart) as? Int ?? SedentaryDetector.defaultActiveStartMin  // 09:00
        activeEndMinutes   = d.object(forKey: K.activeEnd) as? Int ?? SedentaryDetector.defaultActiveEndMin      // 17:00
        if followsSyncedSettings {
            syncSubscription = NotificationCenter.default.publisher(for: .syncedSettingsDidApply)
                .sink { [weak self] _ in Task { @MainActor in self?.reload() } }
        }
    }

    /// Re-reads the knobs after settings arrived from the account, so an open Alerts page shows them.
    func reload() {
        let stored = InactivityPrefs(followsSyncedSettings: false)
        if enabled != stored.enabled { enabled = stored.enabled }
        if thresholdMinutes != stored.thresholdMinutes { thresholdMinutes = stored.thresholdMinutes }
        if reNudgeMinutes != stored.reNudgeMinutes { reNudgeMinutes = stored.reNudgeMinutes }
        if buzzLoops != stored.buzzLoops { buzzLoops = stored.buzzLoops }
        if activeHoursEnabled != stored.activeHoursEnabled { activeHoursEnabled = stored.activeHoursEnabled }
        if activeStartMinutes != stored.activeStartMinutes { activeStartMinutes = stored.activeStartMinutes }
        if activeEndMinutes != stored.activeEndMinutes { activeEndMinutes = stored.activeEndMinutes }
    }

    // MARK: - Engine seams (UserDefaults-direct; safe to call off the UI store)
    //
    // These read/write the SAME keys as the @Published store above. The BLE hook uses them so it never
    // has to reach a MainActor ObservableObject through the connection layer — it just reads defaults,
    // exactly like the Android WhoopBleClient reads SharedPreferences.

    /// The notification settings keys reused for the global gates (written by NotificationSettingsStore).
    private enum NotifK {
        static let master     = "notif.masterEnabled"
        static let worn       = "notif.onlyWhenWorn"
        static let quiet      = "notif.quietHoursEnabled"
        static let quietStart = "notif.quietStartMinutes"
        static let quietEnd   = "notif.quietEndMinutes"
    }

    /// Materialise the user knobs + the reused notification gates into the engine's `SedentaryConfig`.
    /// The detector tunables (move threshold / smoothing) keep the engine defaults.
    static func loadConfig(_ d: UserDefaults = .standard) -> SedentaryConfig {
        SedentaryConfig(
            enabled: d.object(forKey: K.enabled) as? Bool ?? false,
            notificationsMasterOn: d.object(forKey: NotifK.master) as? Bool ?? false,
            thresholdMinutes: d.object(forKey: K.threshold) as? Int ?? SedentaryDetector.defaultThresholdMinutes,
            reNudgeMinutes: d.object(forKey: K.reNudge) as? Int ?? SedentaryDetector.defaultReNudgeMinutes,
            buzzLoops: d.object(forKey: K.buzzLoops) as? Int ?? SedentaryDetector.defaultBuzzLoops,
            activeHoursEnabled: d.object(forKey: K.activeOn) as? Bool ?? true,
            activeStartMinutes: d.object(forKey: K.activeStart) as? Int ?? SedentaryDetector.defaultActiveStartMin,
            activeEndMinutes: d.object(forKey: K.activeEnd) as? Int ?? SedentaryDetector.defaultActiveEndMin,
            quietHoursEnabled: d.object(forKey: NotifK.quiet) as? Bool ?? false,
            quietStartMinutes: d.object(forKey: NotifK.quietStart) as? Int ?? SedentaryDetector.defaultQuietStartMin,
            quietEndMinutes: d.object(forKey: NotifK.quietEnd) as? Int ?? SedentaryDetector.defaultQuietEndMin,
            onlyWhenWorn: d.object(forKey: NotifK.worn) as? Bool ?? true
        )
    }

    /// The rolling-window rule's configuration: the same stored knobs and notification gates as above, with
    /// "Sitting for" as the window length. Guarded against an out-of-range stored value.
    static func loadStandConfig(_ d: UserDefaults = .standard) -> StandReminderEngine.Config {
        var config = StandReminderEngine.Config(loadConfig(d))
        config.windowMinutes = min(max(d.object(forKey: K.threshold) as? Int ?? StandReminderEngine.defaultWindowMinutes, 5), 240)
        return config
    }

    /// Rehydrate the rolling-window engine's de-dup state.
    static func loadStandState(_ d: UserDefaults = .standard) -> StandReminderEngine.State {
        StandReminderEngine.State(
            lastEvaluatedThrough: d.object(forKey: K.standEvaluatedThrough) as? Int ?? 0,
            lastRemindAt: d.object(forKey: K.standLastRemindAt) as? Int ?? 0)
    }

    /// Persist the rolling-window engine's `nextState`, so a relaunch cannot judge the same window twice.
    static func saveStandState(_ s: StandReminderEngine.State, to d: UserDefaults = .standard) {
        d.set(s.lastEvaluatedThrough, forKey: K.standEvaluatedThrough)
        d.set(s.lastRemindAt, forKey: K.standLastRemindAt)
    }

    /// Whether the feature toggle is on (cheap pre-check so the hook can bail before any DB read).
    static func isEnabled(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: K.enabled) as? Bool ?? false
    }

    /// Rehydrate the persisted de-dup state (the LAST_* keys) the engine feeds back into `evaluate`.
    static func loadState(_ d: UserDefaults = .standard) -> SedentaryState {
        SedentaryState(
            lastProcessedGravityTs: d.object(forKey: K.lastProcessedTs) as? Int ?? 0,
            lastBuzzAt: d.object(forKey: K.lastBuzzAt) as? Int ?? 0,
            lastBuzzedBoutStart: d.object(forKey: K.lastBoutStart) as? Int ?? 0,
            lastBuzzedBoutEnd: d.object(forKey: K.lastBoutEnd) as? Int ?? 0
        )
    }

    /// Persist the engine's `nextState` so a relaunch can't re-buzz a replayed window.
    static func saveState(_ s: SedentaryState, to d: UserDefaults = .standard) {
        d.set(s.lastProcessedGravityTs, forKey: K.lastProcessedTs)
        d.set(s.lastBuzzAt, forKey: K.lastBuzzAt)
        d.set(s.lastBuzzedBoutStart, forKey: K.lastBoutStart)
        d.set(s.lastBuzzedBoutEnd, forKey: K.lastBoutEnd)
    }

    /// Local tz offset (seconds east of UTC) at `epochSec` — the engine evaluates active/quiet hours
    /// against the bout's local end time, so it needs the offset for that instant (DST-correct).
    static func tzOffsetSec(_ epochSec: Int) -> Int {
        TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(epochSec)))
    }
}
