import Foundation
import WhoopProtocol

/// Whether to send the WHOOP 5/MG CLIENT_HELLO at all on this connect.
///
/// The #1635 field captures show the hello is what ends the link. Across two sessions and sixteen writes it
/// was never once acknowledged, and the drop is locked to the HELLO rather than to the connect: 3.158s,
/// 3.159s, 3.155s after the write, cycle after cycle, while live HR streams happily over the standard
/// profile the whole time.
///
/// An HCI capture later established the cause: the phone transmits an SMP Pairing Request and the strap
/// answers `Pairing Not Supported` (0x05). The refusal is categorical — the encrypted bond this hello waits
/// behind can never arrive on a 5/MG — so the write is a handshake that has never once succeeded knocking a
/// strap that CAN deliver live HR off every few seconds.
///
/// Suppressing it after the give-up latches trades an unreachable capability (puffin commands, history
/// offload) for one that demonstrably works (continuous live HR) — the "Live HR, not fully paired" state
/// the app already models (#69), reached deliberately instead of never at all.
///
/// [userInitiated] always re-attempts: suppression is a fallback for automatic reconnects, never a
/// permanent verdict. Someone who puts the strap in pairing mode and presses Connect must get a fresh try.
/// That try is ONE connect's worth and nothing more — the latch itself survives the tap, so if the strap
/// still will not answer, the automatic reconnects behind it stay suppressed instead of re-earning the
/// give-up over five more refusals. The latch is dropped by a genuine bond (it demonstrably works now) or
/// by forgetting the strap, which are the two events that are actually evidence about this device.
///
/// Kotlin twin: `com.noop.ble.shouldSendClientHello`.
func shouldSendClientHello(suppressedForDevice: Bool, userInitiated: Bool) -> Bool {
    !suppressedForDevice || userInitiated
}

/// How many consecutive refusals this cause needs before the give-up latches.
///
/// The flat 5 was argued for the AUTH-REFUSAL branch and only makes sense there: the pairing hint shows at
/// 2, the hint asks the user to do something (close the official app, free a stale phone pairing), and the
/// extra cycles are the time to do it before NOOP stops hammering.
///
/// An unanswered handshake gives the user nothing to act on. The write vanishes, the strap is not refusing
/// anything it could be talked out of, and the outcome — suppress the hello and keep streaming live HR —
/// needs no permission and costs no capability that was reachable anyway. Every cycle spent waiting is a
/// ~4.8s link drop bought for nothing, so this branch stops at 3.
///
/// Not 2, which is exactly where the pairing hint fires: a strap whose hello is unanswered twice by some
/// transient would latch a PERSISTED verdict with no margin at all. 3 keeps one cycle of margin and still
/// takes roughly 40% off the churn.
///
/// Kotlin twin: `com.noop.ble.UNANSWERED_GIVE_UP_THRESHOLD`.
let unansweredGiveUpThreshold = 3

/// The give-up threshold for the refusal in hand. Keyed on the same `authRefusal` that decides whether the
/// give-up suppresses or pauses (`giveUpSuppressesHello`), so the two can never disagree about which branch
/// a refusal belongs to.
///
/// Kotlin twin: `com.noop.ble.giveUpThresholdFor`.
func giveUpThresholdFor(authRefusal: Bool, pauseThreshold: Int) -> Int {
    authRefusal ? pauseThreshold : unansweredGiveUpThreshold
}

/// Should the give-up latch suppress the hello, rather than pause auto-reconnect?
///
/// The two give-up causes want opposite treatment, which is why they are split here rather than sharing
/// one branch:
///
///  - An AUTH REFUSAL means the strap actively declined the encrypted bond — typically because it is still
///    held by the official WHOOP app. Reconnecting cannot help until the user acts, so pausing is right.
///  - An UNANSWERED HANDSHAKE means the write vanished. The link itself is healthy and streaming, so
///    pausing throws away working live HR to punish a handshake nobody is waiting on. Suppress the hello
///    and stay connected instead.
///
/// Splitting them is the whole point: before this, both ended in the same pause, so the strap that could
/// still deliver HR was treated exactly like the one that could not.
///
/// Kotlin twin: `com.noop.ble.giveUpSuppressesHello`.
func giveUpSuppressesHello(authRefusal: Bool) -> Bool { !authRefusal }

/// Does this disconnect count as the strap refusing to bond?
///
/// Two observations mean the same thing for the purpose of giving up: the strap answered the bond write
/// with INSUFFICIENT_AUTHENTICATION / INSUFFICIENT_ENCRYPTION, or it never answered the CLIENT_HELLO at
/// all. The second was invisible to the give-up on this platform, because the gate tested only the write
/// error — and an unanswered handshake produces no write error at all, just a link that drops a few
/// seconds later. The consequence is the loop #1635 describes, with nothing able to end it.
///
/// Deliberately does NOT widen what counts as an AUTH refusal — [helloUnacked] is a separate signal carried
/// separately, so the user-facing guidance can stay honest about which was observed. An auth refusal
/// supports naming a cause; an unanswered handshake does not.
///
/// Pure so the rule is unit-tested without a radio. Kotlin twin: `com.noop.ble.countsAsBondRefusal`.
func countsAsBondRefusal(
    isAuthRefusalStatus: Bool,
    helloUnacked: Bool,
    alreadyBonded: Bool,
    family: DeviceFamily
) -> Bool {
    if alreadyBonded { return false }        // bonded already — not a pairing problem
    if family != .whoop5 { return false }    // the 4.0 bonds cleanly; this is the 5/MG handshake
    return isAuthRefusalStatus || helloUnacked
}

/// How long a CLIENT_HELLO must have been outstanding at the drop before the drop can be blamed on it.
///
/// The #1635 signature is a drop locked to the write at 3.155-3.159 s, cycle after cycle. A link that dies
/// sooner than this was not ended by the strap timing out the handshake. Kotlin twin:
/// `MIN_HELLO_OUTSTANDING_MS_FOR_REFUSAL`.
let minHelloOutstandingMsForRefusal = 2_500

/// How many inbound frames the link must have carried before an unanswered hello on it counts.
///
/// #1635's strap streamed live HR over the standard profile the whole time, so its links always carried
/// traffic. A link at the edge of range comes up, delivers nothing and drops on the supervision timeout,
/// whether or not a hello went out: a 2026-10-07 log has seven such links in four minutes with no hello at
/// all, between the three that had one. Counting those three latched the suppression on a strap that had
/// acknowledged the hello three times that day. Kotlin twin: `MIN_INBOUND_FRAMES_FOR_REFUSAL`.
let minInboundFramesForRefusal = 2

/// Is an unanswered CLIENT_HELLO at disconnect evidence that the strap refuses the handshake?
///
/// Only when the link was otherwise healthy (it carried traffic) and the hello had been waiting long enough
/// for the strap to have timed it out. Otherwise the drop is the radio's, and it says nothing about the
/// handshake: blaming it there turns an out-of-range walk into a persisted "this strap cannot pair" verdict
/// that switches history sync off.
///
/// `helloOutstandingMs` is nil when no hello was outstanding. Pure so the rule is pinned without a radio.
/// Kotlin twin: `helloUnansweredIsEvidence`.
func helloUnansweredIsEvidence(helloOutstandingMs: Int?, inboundFramesOnLink: Int) -> Bool {
    guard let ms = helloOutstandingMs else { return false }
    return ms >= minHelloOutstandingMsForRefusal && inboundFramesOnLink >= minInboundFramesForRefusal
}

/// When a SUPPRESSED strap gets an automatic handshake retry (#1635 follow-up).
///
/// The latch used to be cleared only by a genuine bond, forgetting the strap, or a Connect tap, so a strap
/// latched by mistake stayed on "not fully paired" with history sync off until someone found the button.
/// The retry costs at most one link drop when the strap really does refuse, so it waits for a link that has
/// held for `stableLinkSeconds` and then backs off: 30 min, doubling, capped at 6 h. A genuine ack clears
/// the latch through the normal bond path. Pure apart from the store below.
enum SuppressedHelloRetry {
    static let stableLinkSeconds: TimeInterval = 5 * 60
    static let firstBackoffSeconds: TimeInterval = 30 * 60
    static let maxBackoffSeconds: TimeInterval = 6 * 60 * 60

    /// Backoff after the `attempts`-th automatic retry (1-based).
    static func backoff(afterAttempts attempts: Int) -> TimeInterval {
        let doublings = max(0, min(attempts - 1, 16))
        return min(firstBackoffSeconds * pow(2, Double(doublings)), maxBackoffSeconds)
    }

    /// Is a retry due on this link right now?
    static func isDue(now: Date, linkUpSeconds: TimeInterval, nextRetryAt: Date?) -> Bool {
        guard linkUpSeconds >= stableLinkSeconds else { return false }
        guard let nextRetryAt else { return true }
        return now >= nextRetryAt
    }

    private static func key(_ peripheralId: String?, _ field: String) -> String? {
        helloSuppressionPrefKey(peripheralId).map { "\($0).retry.\(field)" }
    }

    static func attempts(_ peripheralId: String?) -> Int {
        key(peripheralId, "attempts").map { UserDefaults.standard.integer(forKey: $0) } ?? 0
    }

    static func nextRetryAt(_ peripheralId: String?) -> Date? {
        guard let k = key(peripheralId, "nextAt") else { return nil }
        let t = UserDefaults.standard.double(forKey: k)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Record an automatic retry going out, and schedule the next one.
    static func noteAttempt(_ peripheralId: String?, now: Date = Date()) {
        guard let a = key(peripheralId, "attempts"), let n = key(peripheralId, "nextAt") else { return }
        let attempts = UserDefaults.standard.integer(forKey: a) + 1
        UserDefaults.standard.set(attempts, forKey: a)
        UserDefaults.standard.set(now.addingTimeInterval(backoff(afterAttempts: attempts)).timeIntervalSince1970,
                                  forKey: n)
    }

    /// Forget the retry schedule: the handshake succeeded or the strap was removed.
    static func clear(_ peripheralId: String?) {
        for field in ["attempts", "nextAt"] {
            if let k = key(peripheralId, field) { UserDefaults.standard.removeObject(forKey: k) }
        }
    }
}

/// UserDefaults key holding the hello-suppression latch for one strap.
///
/// Per device, and lowercased for the same reason the firmware key is: the same strap can present its
/// identifier in different cases across sessions, and a case-sensitive key would silently latch a second
/// time under a second key instead of reading the first.
///
/// DIVERGENCE FROM ANDROID (deliberate, PII): the identifier here is the CoreBluetooth-local peripheral
/// UUID, which is per-install rather than the hardware address. The key SHAPE is shared with the Kotlin
/// twin so the two are recognisably the same latch; the value that goes into it is not the same kind of
/// identifier, and deliberately so.
///
/// Kotlin twin: `com.noop.ble.helloSuppressionPrefKey`.
func helloSuppressionPrefKey(_ peripheralId: String?) -> String? {
    guard let raw = peripheralId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return nil
    }
    return "noop.helloUnanswered.\(raw.lowercased())"
}

/// Read/write the per-strap hello-suppression latch. Kept beside the key helper so no caller hand-rolls
/// the key, which is how the Android side ended up with a case-sensitivity bug worth a comment.
enum HelloSuppressionStore {
    static func suppressed(_ peripheralId: String?) -> Bool {
        guard let key = helloSuppressionPrefKey(peripheralId) else { return false }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setSuppressed(_ peripheralId: String?, _ suppressed: Bool) {
        guard let key = helloSuppressionPrefKey(peripheralId) else { return }
        if suppressed {
            UserDefaults.standard.set(true, forKey: key)
        } else {
            // Remove rather than store false: an absent key and a false one mean the same thing, and this
            // keeps a strap that never latched from leaving a permanent entry behind.
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// #2332: is a link RSSI reading worth recording?
///
/// -127...20 dBm is the LE spec's valid range for a read RSSI, and 127 is its reserved "RSSI is not
/// available". Stashing that sentinel would put an impossibly strong reading on a link that died, which
/// argues the radio was fine and sends the next reader of the log anywhere but at range. So the band is
/// the spec's own range, which rejects 127 and any other out-of-spec value a stack invents, and keeps
/// every reading the spec says is real.
///
/// What it does NOT catch, deliberately: a stack that reports "unavailable" as an IN-BAND value. 0 dBm is
/// not reachable on a real link, but the spec permits it, so it is indistinguishable here from a genuine
/// reading and is kept. Widening the rejection to cover it would start discarding spec-valid readings on
/// a guess, which is the worse trade for a diagnostic. The age printed beside the value in the epitaph is
/// what a reader uses to judge a suspicious one.
///
/// Twin of the Kotlin `WhoopBleClient.rssiReadingIsUsable`.
func rssiReadingIsUsable(_ rssi: Int) -> Bool { (-127...20).contains(rssi) }


/// May the keep-alive timer do its work on this link?
///
/// #1635: the timer used to gate on the genuine encrypted bond alone. A SUPPRESSED 5/MG never reaches
/// one, so that gate switched the whole timer off for exactly the link the suppression keeps up for
/// hours — taking the liveness watchdog with it and leaving a stalled stream with nothing to bounce it.
/// The stable-live-HR promise would have quietly depended on a stream nothing was watching.
///
/// So a 5/MG that is STREAMING (`bonded` is the live-HR shortcut of #8/#69, set when HR actually arrives
/// over the standard profile) is admitted too. Deliberately narrower than the Android twin, which admits
/// any `bonded` link: here it is 5/MG only, and only as far as the watchdog — the caller re-guards on the
/// real bond before anything puffin-framed, which an unbonded link cannot land anyway.
///
/// Pure so the rule is pinned without a radio.
func keepAliveMayRun(connected: Bool, didBond: Bool, bonded: Bool, family: DeviceFamily) -> Bool {
    guard connected else { return false }
    if didBond { return true }
    return bonded && family == .whoop5
}
