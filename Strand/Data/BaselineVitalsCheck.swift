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

        /// Same rule as the Monitor card verdict: a trusted copy and a z beyond its k band
        /// (`LongitudinalBaseline.vitalVerdict`, which the server's metric explanations mirror).
        static func make(series: LBSeries, name: String, ev: LBEvaluation) -> Vital {
            let verdict = LongitudinalBaseline.vitalVerdict(ev)
            let state: State
            switch verdict.state {
            case .inRange: state = .inRange
            case .off: state = .off
            case .learning: state = .learning
            case .noReading: state = .noReading
            }
            return Vital(series: series, name: name, state: state, value: verdict.value, bandLo: verdict.bandLo,
                         bandHi: verdict.bandHi, unit: series.planRow.unit, fromWeek: verdict.fromWeek)
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
