import Foundation
import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Sleep display formatting
//
// One place for how the Sleep surfaces (the tab root, the night page and the cards Today hosts) print a
// duration, a clock window and a signed balance, so the same number never reads two ways on two screens.
// Display only: every input is a value the model already computed.

enum SleepFormat {
    /// Minutes as "6 h 42 m", "42 m" or "8 h" (units beside the numbers, docs/DESIGN_SYSTEM.md Copy).
    /// Negative input prints as zero: a duration is never negative.
    static func duration(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m) m") }
        if m % 60 == 0 { return String(localized: "\(m / 60) h") }
        return String(localized: "\(m / 60) h \(m % 60) m")
    }

    /// A signed balance against a need: "+1 h 20 m", "−2 h 10 m", "0 m".
    static func signedDuration(_ minutes: Double) -> String {
        if abs(minutes) < 1 { return duration(0) }
        return (minutes >= 0 ? "+" : "−") + duration(abs(minutes))
    }

    /// "11:21 PM – 6:37 AM" (the device's 12/24-hour setting, via the shared night formatter).
    static func window(_ startTs: Int, _ endTs: Int) -> String {
        "\(Night.clockString(startTs)) – \(Night.clockString(endTs))"
    }

    /// "92" for a 0–100 score; nil stays nil.
    static func score(_ value: Double?) -> String? {
        value.map { "\(Int($0.rounded()))" }
    }

    /// A short state word for a Rest score, the same banding the Rest hero has always used.
    static func restWord(_ score: Double) -> String {
        switch score {
        case ..<50:  return String(localized: "Poor")
        case ..<70:  return String(localized: "Fair")
        case ..<85:  return String(localized: "Good")
        default:     return String(localized: "Optimal")
        }
    }

    /// The local wake-day key a night is filed under ("2026-10-07"), the key the night page is routed by.
    static func wakeDayKey(_ endTs: Int) -> String {
        Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(endTs)))
    }

    /// The night's date line ("Mon 6 – Tue 7 Oct"), named from its wake day like every other night label.
    static func nightDateLine(_ endTs: Int) -> String {
        ReadoutContent.dateLine(Date(timeIntervalSince1970: TimeInterval(endTs)), period: .night)
    }

    /// "Last night" / "1 night ago" / "N nights ago" for a calendar-night count (`SleepNightLabel.nightsAgo`).
    static func relativeNight(_ nightsAgo: Int) -> String {
        switch nightsAgo {
        case 0: return String(localized: "Last night")
        case 1: return String(localized: "1 night ago")
        default: return String(localized: "\(nightsAgo) nights ago")
        }
    }
}
