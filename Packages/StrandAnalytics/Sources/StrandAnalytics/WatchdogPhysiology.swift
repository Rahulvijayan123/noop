import Foundation

/// One vital's own Watchdog label. Not a shared usual and not an alert.
public struct WatchdogVitalMark: Equatable, Sendable {
    public var name: String
    public var present: Bool
    public var outside: Bool
    public var energy: Double
}

/// Separate from per-vital graphs. Reads each channel's in/out label and decides
/// whether overall physiology should **page**. Does not rewrite hats, σ, or row ranges.
public enum WatchdogPhysiologyAlert: Sendable {
    /// Cluster size to even consider a model page (matches three-vital severe add-up).
    public static let minVitals = 3
    /// At least this many of the cluster must be at tActive, not just tNote.
    public static let minExtreme = 2

    public static func marks(absR: [Double], mask: [Bool],
                             tau: Double = WatchdogCalibration.tNote) -> [WatchdogVitalMark] {
        let names = WatchdogDirection.names
        let n = min(absR.count, mask.count, names.count, WatchdogDirection.channelCount)
        return (0..<n).map { k in
            let present = mask[k] && k != WatchdogScores.rhrSeverityIndex
            let energy = present && absR[k].isFinite ? max(0, absR[k]) : 0
            let outside = present && energy >= tau
            return WatchdogVitalMark(name: names[k], present: present, outside: outside, energy: energy)
        }
    }

    /// Page only for safety extrema or an extreme multi-vital cluster.
    /// Personal-off and one/two vitals slightly outside do not page.
    public static func shouldAlert(marks: [WatchdogVitalMark],
                                   safety: Bool,
                                   personalOff: Bool = false) -> Bool {
        _ = personalOff
        if safety { return true }
        let cluster = marks.filter(\.outside)
        guard cluster.count >= minVitals else { return false }
        let extreme = cluster.filter { $0.energy >= WatchdogCalibration.tActive }.count
        return extreme >= minExtreme
    }
}
