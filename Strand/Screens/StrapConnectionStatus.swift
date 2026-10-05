import Foundation
import StrandDesign

/// What the Pair & connect page knows about the strap link, as plain values. Every decision the page makes
/// (how to describe the link, which action leads, which buttons are live and why a dead one is dead) lives
/// here so it can be pinned by unit tests without a Bluetooth stack.
struct StrapConnectionStatus: Equatable {

    enum Phase: Hashable {
        /// A restart was sent and the strap has not come back yet.
        case restarting
        /// The user asked for a connection and nothing has answered yet.
        case searching
        /// Connected with the encrypted pairing in place: every feature works.
        case paired
        /// Connected and streaming heart rate, but the encrypted pairing never finished.
        case partlyPaired
        /// Connected, secure handshake still running.
        case connecting
        /// Not connected, and the phone and strap no longer agree on the pairing.
        case needsRepair
        /// Paired before, not connected now.
        case disconnected
        /// No strap has ever been connected.
        case unpaired
    }

    /// The one action the status card puts first. Nil when the right move is to wait or there is nothing to fix.
    enum LeadAction: Equatable {
        case connect
        case findStrap
        case repair
    }

    enum Availability: Equatable {
        case available
        case unavailable(String)

        var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }

        var reason: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    var connected = false
    /// Sticky "this strap has paired" flag. The 5/MG live-HR shortcut also sets it, so it is not proof of a bond.
    var bonded = false
    /// The real encrypted bond, cleared on every disconnect. Buzz, alarms and restart need it.
    var encryptedBond = false
    var restarting = false
    var searching = false
    /// A search that has gone on long enough to start suggesting causes.
    var searchIsSlow = false
    /// A strap is registered or was connected before, even if nothing in this session has bonded yet.
    var knownStrap = false
    var pairingHint: String?
    var hasReconnectGuide = false
    /// "Bluetooth is off" style message. Nothing can connect until it is fixed, so it replaces the usual detail.
    var radioProblem: String?
    var isWhoop4 = false
    var batteryPct: Double?
    /// The person tapped Disconnect, so a missing link is their choice rather than the strap being out of reach.
    var userDisconnected = false

    // MARK: Phase

    var phase: Phase {
        if restarting { return .restarting }
        if connected {
            if encryptedBond { return .paired }
            if bonded || pairingHint != nil { return .partlyPaired }
            return .connecting
        }
        // A radio that is off cannot be searched with, so a stale "searching" flag must not keep the spinner up.
        if searching && radioProblem == nil { return .searching }
        if hasReconnectGuide { return .needsRepair }
        return (knownStrap || bonded) ? .disconnected : .unpaired
    }

    var isBusy: Bool {
        switch phase {
        case .restarting, .searching, .connecting: return true
        default: return false
        }
    }

    // MARK: Description

    var title: String {
        switch phase {
        case .restarting:   return String(localized: "Restarting")
        case .searching:    return String(localized: "Searching…")
        case .paired:       return String(localized: "Connected")
        case .partlyPaired: return String(localized: "Not fully paired")
        case .connecting:   return String(localized: "Connecting…")
        case .needsRepair:  return String(localized: "Pairing was reset")
        case .disconnected: return String(localized: "Not connected")
        case .unpaired:     return String(localized: "No strap connected")
        }
    }

    var tone: StrandTone {
        switch phase {
        case .restarting, .searching, .connecting: return .accent
        case .paired: return .positive
        case .partlyPaired, .disconnected: return .warning
        case .needsRepair, .unpaired: return .critical
        }
    }

    var detail: String {
        if let radioProblem, !connected { return radioProblem }
        switch phase {
        case .restarting:
            return String(localized: "Your strap is restarting. It reconnects on its own in about 30 seconds and keeps your data.")
        case .searching:
            var text = searchIsSlow
                ? String(localized: "Still looking. Make sure the strap is charged and awake. Nara connects the moment it's found.")
                : String(localized: "Looking for your strap. Keep it close to \(Platform.deviceNounPhrase).")
            if searchIsSlow && !isWhoop4 {
                text += " " + String(localized: "A WHOOP 5.0 / MG pairs with one app at a time, so fully close the official WHOOP app.")
            }
            return text
        case .paired:
            return String(localized: "Your strap is paired and sending data. Open Live for a real-time heart rate.")
        case .partlyPaired:
            // The hint names the one action that fixes this particular failure, so it outranks the generic copy.
            if let pairingHint { return pairingHint }
            return String(localized: "Live heart rate is streaming, but your strap is not fully paired. The encrypted pairing is what carries motion, skin temperature, SpO₂ and respiratory rate — without it, sleep is staged from heart rate alone. Buzz, alarms and history sync need it too.")
        case .connecting:
            return String(localized: "Connected. Finishing the secure pairing handshake…")
        case .needsRepair:
            return String(localized: "Your strap's Bluetooth pairing no longer matches \(Platform.deviceNounPhrase), so reconnecting alone won't work. Re-pair it to get back in sync.")
        case .disconnected:
            if userDisconnected {
                return String(localized: "You disconnected your strap. Nara won't reconnect until you tap Connect.")
            }
            var text = String(localized: "Your strap is paired but out of reach right now. Keep it nearby and tap Connect.")
            if let pct = batteryPct, pct <= 15 {
                text += " " + String(localized: "Its battery was at \(Int(pct.rounded()))% the last time Nara saw it, so charge it first.")
            }
            return text
        case .unpaired:
            var text = String(localized: "Put your WHOOP strap nearby and tap Find my strap.")
            if !isWhoop4 {
                text += " " + String(localized: "A WHOOP 5.0 / MG pairs with one app at a time, so fully close the official WHOOP app first.")
            }
            return text
        }
    }

    // MARK: Actions

    var lead: LeadAction? {
        switch phase {
        case .restarting, .searching, .paired, .connecting: return nil
        case .partlyPaired, .needsRepair: return .repair
        case .disconnected: return .connect
        case .unpaired: return .findStrap
        }
    }

    var leadTitle: String? {
        switch lead {
        case .connect:   return String(localized: "Connect")
        case .findStrap: return String(localized: "Find my strap")
        case .repair:    return String(localized: "Re-pair strap")
        case nil:        return nil
        }
    }

    /// "Reconnect" drops a live link first; with no link it is simply "Connect".
    var reconnectTitle: String {
        connected ? String(localized: "Reconnect") : String(localized: "Connect")
    }

    var reconnect: Availability {
        restarting ? .unavailable(String(localized: "Your strap is restarting and reconnects on its own.")) : .available
    }

    /// While a search is running the same control stops it.
    var disconnectTitle: String {
        phase == .searching ? String(localized: "Stop searching") : String(localized: "Disconnect")
    }

    var disconnect: Availability {
        if restarting { return .unavailable(String(localized: "Your strap is restarting.")) }
        if connected || phase == .searching { return .available }
        return .unavailable(String(localized: "Not connected right now."))
    }

    var buzz: Availability {
        if restarting { return .unavailable(String(localized: "Wait for the restart to finish.")) }
        if !connected { return .unavailable(String(localized: "Connect your strap first.")) }
        if !encryptedBond { return .unavailable(needsEncryptedBondReason) }
        return .available
    }

    var restart: Availability {
        if isWhoop4 { return .unavailable(String(localized: "WHOOP 4.0 straps don't support restarting from an app.")) }
        if restarting { return .unavailable(String(localized: "Your strap is already restarting.")) }
        if !connected { return .unavailable(String(localized: "Connect your strap first.")) }
        if !encryptedBond { return .unavailable(needsEncryptedBondReason) }
        return .available
    }

    /// Commands go over the encrypted link. A handshake still in flight will finish by itself, so only a
    /// connection that has settled without the bond is told to re-pair.
    private var needsEncryptedBondReason: String {
        phase == .connecting
            ? String(localized: "Still finishing the secure connection. Try again in a moment.")
            : String(localized: "Needs a full pairing. Use Re-pair strap to finish it.")
    }

    /// Re-pairing and adding another strap both tear the current link down, which would fight a restart in flight.
    var pairing: Availability {
        restarting ? .unavailable(String(localized: "Wait for the restart to finish.")) : .available
    }

    // MARK: Action rows

    func availability(of action: StrapAction) -> Availability {
        switch action {
        case .reconnect: return reconnect
        case .disconnect: return disconnect
        case .buzz: return buzz
        case .restart: return restart
        case .repair, .pairDifferent: return pairing
        }
    }

    func title(of action: StrapAction) -> String {
        switch action {
        case .reconnect: return reconnectTitle
        case .disconnect: return disconnectTitle
        case .buzz: return String(localized: "Buzz strap")
        case .restart: return String(localized: "Restart strap")
        case .repair: return String(localized: "Re-pair strap")
        case .pairDifferent: return String(localized: "Pair a different strap")
        }
    }

    /// The line under an action's title: why it can't be used right now, otherwise what it does.
    func detail(of action: StrapAction, notes: StrapActionNotes = StrapActionNotes()) -> String {
        if let reason = availability(of: action).reason { return reason }
        switch action {
        case .reconnect:
            if phase == .searching { return String(localized: "Looking for your strap…") }
            return connected
                ? String(localized: "Drops the Bluetooth link and connects again. Try this first when data stops flowing.")
                : String(localized: "Looks for your strap and connects to it.")
        case .disconnect:
            return phase == .searching
                ? String(localized: "Cancels the search.")
                : String(localized: "Ends the Bluetooth link. Nara stays quiet until you tap Connect.")
        case .buzz:
            return notes.buzzSent
                ? String(localized: "Buzz sent. You should feel it on your wrist.")
                : String(localized: "Vibrates the strap once so you know it's the right one.")
        case .restart:
            return notes.restartIgnored
                ? String(localized: "The strap didn't restart. Try again, or use Re-pair strap if it keeps happening.")
                : String(localized: "Reboots the strap. It reconnects by itself in about 30 seconds and keeps your data.")
        case .repair:
            return String(localized: "Guided fix for a strap that won't connect, drops right away or isn't fully paired.")
        case .pairDifferent:
            return String(localized: "Add another WHOOP or a heart-rate strap.")
        }
    }
}

/// The six rows under the status card, in the order the page lays them out.
enum StrapAction: CaseIterable, Hashable {
    case reconnect, disconnect, buzz, restart, repair, pairDifferent

    /// Every line this row can show, found by walking the states the link can be in. A row sets aside room for
    /// the longest of them, so it keeps its height when the link changes and its wording follows.
    ///
    /// Only the flags that can change a row's wording are walked (the unit tests walk every flag and fail if one
    /// of them turns out to matter), which keeps this to a couple of thousand cheap lookups, once.
    var possibleDetails: [String] { Self.catalogue[self] ?? [] }

    private static let catalogue: [StrapAction: [String]] = {
        var lines: [StrapAction: [String]] = [:]
        func note(_ action: StrapAction, _ text: String) {
            if lines[action, default: []].contains(text) == false { lines[action, default: []].append(text) }
        }
        for bits in 0..<(1 << 8) {
            var status = StrapConnectionStatus()
            status.connected = bits & 1 != 0
            status.bonded = bits & 2 != 0
            status.encryptedBond = bits & 4 != 0
            status.restarting = bits & 8 != 0
            status.searching = bits & 16 != 0
            status.isWhoop4 = bits & 32 != 0
            status.pairingHint = bits & 64 != 0 ? "hint" : nil
            status.radioProblem = bits & 128 != 0 ? "radio" : nil
            for action in StrapAction.allCases {
                switch action {
                case .buzz:
                    note(action, status.detail(of: action, notes: StrapActionNotes(buzzSent: false)))
                    note(action, status.detail(of: action, notes: StrapActionNotes(buzzSent: true)))
                case .restart:
                    note(action, status.detail(of: action, notes: StrapActionNotes(restartIgnored: false)))
                    note(action, status.detail(of: action, notes: StrapActionNotes(restartIgnored: true)))
                default:
                    note(action, status.detail(of: action))
                }
            }
        }
        return lines
    }()
}

/// What the person has just done on the page. Each flag swaps one row's line for a few seconds.
struct StrapActionNotes: Equatable {
    var buzzSent = false
    var restartIgnored = false
}
