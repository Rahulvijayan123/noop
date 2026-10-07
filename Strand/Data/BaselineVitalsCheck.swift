import Foundation
import StrandAnalytics

/// One scored night of the night vitals, each against its own Layer 1 usual. Separate from Charge.
struct BaselineVitalsCheck: Equatable {
    struct Vital: Identifiable, Equatable {
        enum State: Equatable {
            case inRange
            case off
            /// Not enough trusted nights for a usual yet.
            case learning
            /// The night has no reading for this vital.
            case noReading
        }

        let series: LBSeries
        let name: String
        let state: State
        let value: Double?
        let bandLo: Double?
        let bandHi: Double?
        let unit: String
        /// Which copy the call came from: the week usual when it is trusted, else the longer one.
        let fromWeek: Bool

        var id: String { series.rawValue }
        var counted: Bool { state == .inRange || state == .off }

        /// Same rule as the Monitor card verdict: a trusted copy and a z beyond its k band.
        static func make(series: LBSeries, name: String, ev: LBEvaluation) -> Vital {
            let unit = series.planRow.unit
            let threshold = LongitudinalBaseline.trustHideThreshold
            let week = ev.show7 && ev.usualTrustPct7 >= threshold ? ev.copy7 : nil
            let long = ev.showLong && ev.usualTrustPctLong >= threshold ? ev.copyLong : nil
            let copy = week ?? long
            guard let today = ev.todayNative else {
                return Vital(series: series, name: name, state: copy == nil ? .learning : .noReading,
                             value: nil, bandLo: copy?.bandLoDisplay, bandHi: copy?.bandHiDisplay,
                             unit: unit, fromWeek: week != nil)
            }
            guard let copy else {
                return Vital(series: series, name: name, state: .learning, value: today,
                             bandLo: nil, bandHi: nil, unit: unit, fromWeek: false)
            }
            let k = ev.kBandUsed
            let offWeek = week != nil && LongitudinalBaseline.isOffUsual(z: ev.z7, k: k)
            let offLong = long != nil && LongitudinalBaseline.isOffUsual(z: ev.zLong, k: k)
            return Vital(series: series, name: name, state: (offWeek || offLong) ? .off : .inRange,
                         value: today, bandLo: copy.bandLoDisplay, bandHi: copy.bandHiDisplay,
                         unit: unit, fromWeek: week != nil)
        }
    }

    let night: String
    let vitals: [Vital]

    var counted: [Vital] { vitals.filter(\.counted) }
    var inRangeCount: Int { vitals.filter { $0.state == .inRange }.count }
    var offCount: Int { vitals.filter { $0.state == .off }.count }

    /// "4 of 5 in range", or why there is no count yet.
    var statusLine: String {
        let n = counted.count
        if n == 0 { return vitals.contains { $0.state == .learning } ? "Learning" : "No reading" }
        return "\(inRangeCount) of \(n) in range"
    }
}
