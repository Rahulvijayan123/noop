#if os(iOS)
import Foundation
import AppIntents

/// Queue of actions requested by an App Intent while the app may be suspended. Intents can't reach
/// into the running `AppModel` directly (BLE only lives in the foreground app), so they enqueue here
/// and the app drains the queue when it next becomes active.
enum PendingIntents {
    enum Action: String { case markMoment, buzz, askCoach }

    private static let key = "noop.pendingIntents"
    /// K9: the question text for a pending `.askCoach` action. Stored separately because the
    /// action queue encodes as `[String]` and a question can contain colons.
    private static let coachQuestionKey = "noop.pendingCoachQuestion"
    /// K9: when the question in `coachQuestionKey` was asked (epoch seconds). The slot holds one question, so its
    /// age is its own, never that of whichever queued `.askCoach` entry happens to be drained first. A plain
    /// companion key keeps the question itself a bare string, as older builds wrote and read it.
    private static let coachQuestionDateKey = "noop.pendingCoachQuestionAt"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: WidgetSnapshot.suiteName) }

    /// Posted on the main thread once an intent running in the app process has queued something the open app should
    /// act on now. The app drains on it when its scene is already active, so a request that lands after the
    /// activation drain is not left waiting for the next one.
    static let didQueue = Notification.Name("noop.pendingIntents.didQueue")

    /// Optional `at` is the invocation time, captured now and consumed on drain. Encoded into the
    /// stored string as "rawValue:epochSeconds" so the array stays a plain [String] (no schema
    /// migration; a legacy bare "markMoment" still decodes with a nil date).
    static func append(_ action: Action, at date: Date? = nil) {
        guard let d = defaults else { return }
        var list = d.stringArray(forKey: key) ?? []
        if let date { list.append("\(action.rawValue):\(date.timeIntervalSince1970)") }
        else { list.append(action.rawValue) }
        d.set(list, forKey: key)
    }

    /// K9: queue an "Ask Coach" action with the associated question text. The question is stored
    /// in a dedicated key (one pending question at a time — the user rarely queues multiple Siri
    /// questions before the app opens), stamped with `date` so its freshness travels with it.
    static func appendAskCoach(question: String, at date: Date? = nil) {
        guard let d = defaults else { return }
        d.set(question, forKey: coachQuestionKey)
        if let date { d.set(date.timeIntervalSince1970, forKey: coachQuestionDateKey) }
        else { d.removeObject(forKey: coachQuestionDateKey) }
        append(.askCoach, at: date)
    }

    /// K9: read and clear the pending coach question and its stamp. Returns nil when no question is queued.
    /// `queuedAt` is nil for a question an older build stored without one.
    static func consumeCoachQuestion() -> (text: String, queuedAt: Date?)? {
        guard let d = defaults else { return nil }
        let q = d.string(forKey: coachQuestionKey)
        let stamp = d.object(forKey: coachQuestionDateKey) as? Double
        d.removeObject(forKey: coachQuestionKey)
        d.removeObject(forKey: coachQuestionDateKey)
        return q.map { ($0, stamp.map { Date(timeIntervalSince1970: $0) }) }
    }

    /// K9: everything one drain's `.askCoach` entries resolve to: at most one question, the pending one, and only
    /// when it is fresh. The question is consumed whatever the answer, so a stale one never comes back later.
    /// Its own stamp decides; `queueDates` (the drained entries' stamps, the newest of which belongs to the
    /// question in the slot) date only a question stored by a build that kept no stamp.
    static func takeCoachQuestion(queueDates: [Date?], now: Date = Date()) -> String? {
        guard let pending = consumeCoachQuestion() else { return nil }
        let queuedAt = pending.queuedAt ?? queueDates.compactMap { $0 }.max()
        return isFreshCoachQuestion(queuedAt: queuedAt, now: now) ? pending.text : nil
    }

    /// How long a Siri question stays worth asking. Opening the app later than this should not put an old
    /// question into a new chat.
    static let coachQuestionMaxAge: TimeInterval = 600

    /// True for a question queued within `coachQuestionMaxAge` of `now`. A question with no stamp (a corrupt
    /// entry; every queued question carries one) is not asked.
    static func isFreshCoachQuestion(queuedAt date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return false }
        let age = now.timeIntervalSince(date)
        return age >= -60 && age <= coachQuestionMaxAge
    }

    static func drain() -> [(action: Action, date: Date?)] {
        guard let d = defaults else { return [] }
        let raw = d.stringArray(forKey: key) ?? []
        d.removeObject(forKey: key)
        return raw.compactMap { entry in
            // Guard `parts.first` rather than subscripting `parts[0]`: split(omittingEmptySubsequences:
            // true by default) returns an EMPTY array for an empty or ":"-leading entry, and indexing
            // [0] there is a fatal trap. This value comes from shared App Group defaults read untrusted,
            // so a corrupt/foreign entry must be skipped, not crash the app on foreground.
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard let first = parts.first, let action = Action(rawValue: String(first)) else { return nil }
            let date = parts.count == 2 ? Double(parts[1]).map { Date(timeIntervalSince1970: $0) } : nil
            return (action, date)
        }
    }
}

/// Record a timestamped "moment" — the iOS analogue of the strap double-tap "mark a moment" action.
struct MarkMomentIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark a Moment"
    static var description = IntentDescription("Record a timestamped moment in NOOP.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingIntents.append(.markMoment, at: Date())
        return .result(dialog: "Moment marked.")
    }
}

/// Send a confirming haptic buzz to the strap. Opens the app so the live BLE link can deliver it.
struct BuzzStrapIntent: AppIntent {
    static var title: LocalizedStringResource = "Buzz Strap"
    static var description = IntentDescription("Send a haptic buzz to your WHOOP strap.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingIntents.append(.buzz)
        return .result()
    }
}

/// Pull the strap's stored history now: the Shortcuts twin of the "Sync now" button, run WITHOUT opening NOOP.
/// iOS runs an in-app intent inside NOOP's own process (launching or resuming it in the background), where the
/// strap link lives under the bluetooth-central background mode, so the offload carries on after this returns.
/// The spoken/shown reply reports only what this path observed about the sync starting.
///
/// `LiveActivityIntent`, not plain `AppIntent`: that is what lets it START the strap-sync Live Activity
/// (the Dynamic Island "Connecting… / Syncing… N chunks" readout) from the background. A plain intent
/// running in a background-launched app is refused by ActivityKit.
struct SyncStrapIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Sync Strap"
    static var description = IntentDescription("Pull your WHOOP strap's stored history into NOOP now.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await AppModel.startStrapSyncFromShortcut() {
        case .started:               return .result(dialog: "Syncing your strap.")
        case .alreadyRunning:        return .result(dialog: "Your strap is already syncing.")
        case .willSyncWhenConnected: return .result(dialog: "NOOP is connecting to your strap and will sync as soon as it's ready.")
        case .strapNotReady:         return .result(dialog: "Your strap isn't connected to NOOP yet, so the sync didn't start.")
        case .notStarted:            return .result(dialog: "NOOP couldn't start the sync. Open NOOP to see the strap log.")
        }
    }
}

/// K9: Ask the Coach a question via Siri. Queues the question and opens the app, which asks it in a new
/// Sana chat on the Sana tab (`AppModel.drainPendingIntents`). The question is spoken or typed in Siri.
/// Nothing is queued while Coach is switched off.
struct AskCoachIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Coach"
    static var description = IntentDescription("Ask your NOOP Coach a question about your recovery, sleep, or training.")
    static var openAppWhenRun = true

    /// The question to ask, populated by Siri from the user's spoken phrase.
    @Parameter(title: "Question")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard CoachBriefScheduler.coachMasterEnabled else {
            return .result(dialog: "Sana is switched off. Turn it on in Settings to ask questions.")
        }
        PendingIntents.appendAskCoach(question: question, at: Date())
        // This runs in the app process. When the scene went active before the append (a warm resume), the
        // activation drain has already run and found nothing; this asks the open app to drain again now.
        NotificationCenter.default.post(name: PendingIntents.didQueue, object: nil)
        return .result(dialog: "Opening Sana with your question: \(question)")
    }
}

/// Surfaces NOOP's intents to Siri, Spotlight, and the Shortcuts gallery without any user setup.
struct NOOPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SyncStrapIntent(),
                    phrases: [
                        "Sync my \(.applicationName) strap",
                        "Sync \(.applicationName)",
                    ],
                    shortTitle: "Sync Strap",
                    systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: MarkMomentIntent(),
                    phrases: ["Mark a moment in \(.applicationName)"],
                    shortTitle: "Mark a Moment",
                    systemImageName: "mappin.and.ellipse")
        AppShortcut(intent: BuzzStrapIntent(),
                    phrases: ["Buzz my \(.applicationName) strap"],
                    shortTitle: "Buzz Strap",
                    systemImageName: "waveform.path")
        // K9: "Ask Coach" via Siri — opens Coach with the question and sends it. The question
        // parameter is provided via the Shortcuts app or Siri prompts for it when the phrase fires.
        AppShortcut(intent: AskCoachIntent(),
                    phrases: [
                        "Ask \(.applicationName) about my recovery",
                        "Ask \(.applicationName) how I'm doing",
                        "Ask \(.applicationName) Coach",
                    ],
                    shortTitle: "Ask Coach",
                    systemImageName: "sparkles")
    }
}
#endif
