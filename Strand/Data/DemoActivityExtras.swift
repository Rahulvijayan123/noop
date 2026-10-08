#if DEBUG
import Foundation
import StrandAnalytics

// MARK: - DEBUG-only server readings for the Heart rate day page
//
// The Walking quality and Strap signal readings come from raw motion sessions the server has processed, so a
// simulator with no account never has them. With `--demo-activity-extras` the day loaders return a synthetic
// reading that follows the same day `DemoIntradaySeeder` writes (a walk to work, a lunch walk, a run), so the
// lanes and their pages can be rendered and screenshotted. SYNTHETIC and deterministic: nothing here is real
// data, and the whole file is `#if DEBUG`, so Release builds do not contain it.
enum DemoActivityExtras {
    static var requested: Bool { CommandLine.arguments.contains("--demo-activity-extras") }

    /// Walking spans of the demo day, in hours: (start, end, cadence steps/min, speed m/s).
    private static let walks: [(Double, Double, Double, Double)] = [
        (7.25, 7.75, 108, 1.42), (10.25, 10.4, 92, 1.15), (11.5, 11.6, 88, 1.05),
        (12.0, 12.4, 112, 1.48), (15.6, 16.0, 96, 1.25),
    ]

    private static func bounds(_ dayStart: Date) -> (from: Int, to: Int)? {
        let from = Int(dayStart.timeIntervalSince1970)
        let to = min(from + 86_400, Int(Date().timeIntervalSince1970))
        return to > from ? (from, to) : nil
    }

    static func walking(dayStart: Date) -> WalkingDayReading? {
        guard requested, let (from, to) = bounds(dayStart) else { return nil }
        var windows: [GaitWindowColumns.Window] = []
        var t = from
        while t < to {
            let hour = Double(t - from) / 3600
            if let walk = walks.first(where: { hour >= $0.0 && hour < $0.1 }) {
                let wobble = sin(Double(t) / 37) * 4
                windows.append(.init(start: t, gaitProbability: 0.92, isGait: true, speedMps: walk.3,
                                     cadenceSpm: walk.2 + wobble, strideM: walk.3 * 60 / max(1, walk.2) * 2,
                                     regularity: 0.86, steps: (walk.2 + wobble) / 6))
            } else if Int(hour * 10) % 7 == 0 {
                windows.append(.init(start: t, gaitProbability: 0.05, isGait: false, speedMps: nil, cadenceSpm: nil,
                                     strideM: nil, regularity: nil, steps: nil, prefiltered: true))
            }
            t += 10
        }
        let columns = GaitWindowColumns(windowSeconds: 10, hopSeconds: 10, windows: windows)
        return WalkingDayReading(days: [columns], from: from, to: to)
    }

    static func strapSignal(dayStart: Date) -> StrapSignalDay? {
        guard requested, let (from, to) = bounds(dayStart) else { return nil }
        var epochs: [ActivityEpoch] = []
        var t = from
        while t + 30 <= to {
            let hour = Double(t - from) / 3600
            let state: WearSignalState
            switch hour {
            case 15.3..<15.6: state = .motionArtifact
            case 13.1..<13.6: state = .onWristLoose
            case 19.0..<19.05: state = .sensorDropout
            default: state = .onWristGood
            }
            epochs.append(ActivityEpoch(startTs: t, endTs: t + 30, motion: .stationary, posture: .sitting,
                                        exercise: .unknown, sleepState: .unknown, exertion: .restingCandidate,
                                        wear: .onWrist, wearSignal: state, confidence: 0.8, observedS: 30, validS: 30))
            t += 30
        }
        return StrapSignalDay(epochs: epochs)
    }
}
#endif
