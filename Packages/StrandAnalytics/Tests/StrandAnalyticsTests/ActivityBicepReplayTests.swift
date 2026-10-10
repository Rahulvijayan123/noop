import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Opt-in replay of a recorded afternoon (`NARA_BICEP_REPLAY_DIR`: gravity.csv ts,x,y,z,dyn; hr.csv ts,bpm;
/// steps.csv ts,counter,class; windows.txt "<encoder>|<version>|<hart-windows-1 json>"; range.txt "<from> <to>";
/// optional truth.txt lines "<from> <to> <label>"). Decodes it as a wrist (pre-hsmm-2.0 reading) and as a bicep and
/// prints minutes per class inside each truth span. Skipped when the variable is unset.
final class ActivityBicepReplayTests: XCTestCase {

    private func rows(_ url: URL) -> [[String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }

    func testReplayRecordedAfternoon() throws {
        guard let dir = ProcessInfo.processInfo.environment["NARA_BICEP_REPLAY_DIR"] else {
            throw XCTSkip("NARA_BICEP_REPLAY_DIR not set")
        }
        let base = URL(fileURLWithPath: dir)
        let range = try String(contentsOf: base.appendingPathComponent("range.txt"), encoding: .utf8)
            .split(whereSeparator: { $0 == " " || $0.isNewline }).compactMap { Int($0) }
        let gravity = rows(base.appendingPathComponent("gravity.csv")).compactMap { r -> GravitySample? in
            guard r.count >= 4, let ts = Int(r[0]), let x = Double(r[1]), let y = Double(r[2]), let z = Double(r[3]) else { return nil }
            return GravitySample(ts: ts, x: x, y: y, z: z, dynAccel: r.count > 4 ? Double(r[4]) : nil)
        }
        let hr = rows(base.appendingPathComponent("hr.csv")).compactMap { r -> HRSample? in
            guard r.count >= 2, let ts = Int(r[0]), let b = Double(r[1]) else { return nil }
            return HRSample(ts: ts, bpm: Int(b.rounded()))
        }
        let steps = rows(base.appendingPathComponent("steps.csv")).compactMap { r -> StepSample? in
            guard r.count >= 2, let ts = Int(r[0]), let c = Int(r[1]) else { return nil }
            return StepSample(ts: ts, counter: c, activityClass: r.count > 2 ? Int(r[2]) : nil)
        }
        var input = ActivityContextTrackInput(dayStart: range[0], dayEnd: range[1], hr: hr, gravity: gravity,
                                              steps: steps, sleepKnownOutsideSessions: true)
        if let text = try? String(contentsOf: base.appendingPathComponent("windows.txt"), encoding: .utf8) {
            let parts = text.split(separator: "|", maxSplits: 2).map(String.init)
            if parts.count == 3, let obj = try? JSONSerialization.jsonObject(with: Data(parts[2].utf8)),
               let set = ActivityEncoderWindowSet.decode(obj, encoderId: parts[0], encoderVersion: parts[1]) {
                input.encoderWindows = set.windows.filter { $0.endTs >= range[0] && $0.endTs < range[1] }
                input.imuWindows = set.features.filter { $0.endTs >= range[0] && $0.endTs < range[1] }
                input.encoderId = set.encoderId
                input.encoderVersion = set.encoderVersion
                input.transitionWindows = set.transitions.filter { $0.endTs >= range[0] && $0.endTs < range[1] }
            }
        }
        var truth: [(Int, Int, String)] = []
        if let text = try? String(contentsOf: base.appendingPathComponent("truth.txt"), encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let p = line.split(separator: " ")
                if p.count >= 3, let a = Int(p[0]), let b = Int(p[1]) { truth.append((a, b, String(p[2]))) }
            }
        }
        if truth.isEmpty { truth = [(range[0], range[1], "all")] }
        print("REPLAY gravity \(gravity.count) hr \(hr.count) steps \(steps.count) hart \(input.encoderWindows.count)")

        var bicep = ActivityDecoderConfig.personalized(restingHeartRate: 60, maxHeartRate: 190)
        bicep.placements = [ActivityPlacementSpan(start: 0, end: nil, placement: .bicep)]
        let wrist = ActivityDecoderConfig.personalized(restingHeartRate: 60, maxHeartRate: 190)
        for (name, config) in [("wrist", wrist), ("bicep", bicep)] {
            let track = ActivityContextTrackBuilder.build(input, config: config)
            for (a, b, label) in truth {
                var minutes: [String: Double] = [:]
                for s in track.states where s.ts >= a && s.ts < b {
                    let k = ActivityClassifier.classify(state: s)
                    minutes[k.activityClass.rawValue, default: 0] += Double(config.publishIntervalS) / 60
                }
                let line = minutes.sorted { $0.value > $1.value }.map { "\($0.key) \(Int($0.value.rounded()))m" }
                    .joined(separator: ", ")
                print("REPLAY \(name) [\(label)] \(line)")
                if name == "bicep" && label == "sitting" {
                    XCTAssertEqual(minutes["standing"] ?? 0, 0, accuracy: 1, "a seated afternoon on the bicep is never standing")
                }
            }
        }
    }
}
