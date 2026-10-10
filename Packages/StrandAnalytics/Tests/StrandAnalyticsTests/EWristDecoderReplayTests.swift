import Foundation
import XCTest
@testable import StrandAnalytics

// E-wrist-decoder (throwaway, untracked; copy kept in _build-scratch/bicep-posture/E-wrist-decoder/swift): decode
// Capture-24 strap-like 1 Hz streams (01_build_inputs.py) as a WRIST strap and dump each published state's class.
//
//   E_IN=<obs dir> E_OUT=<out dir> E_PIDS=P001,P002 E_ARMS=dp_streams,nd_streams,dp_imu,nd_imu \
//     swift test --filter EWristDecoderReplayTests
//
// Arm = <config>_<evidence>. config: dp (default config; on hsmm-2.0 the still-duration prior is on), nd
// (stillDurationPrior = false; hsmm-2.0 only). evidence: streams (gravity + dyn), imu (+ the accel-only imu windows).
// Output <E_OUT>/<arm>/<pid>.csv: ts,class,posture,seatedMass,uprightMass,confidence
final class EWristDecoderReplayTests: XCTestCase {

    private func lines(_ path: String) -> [Substring] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
    }

    func testEWristReplay() throws {
        let env = ProcessInfo.processInfo.environment
        guard let inDir = env["E_IN"], let outDir = env["E_OUT"], let pidList = env["E_PIDS"] else {
            throw XCTSkip("set E_IN, E_OUT, E_PIDS")
        }
        let arms = (env["E_ARMS"] ?? "dp_streams").split(separator: ",").map(String.init)
        let fm = FileManager.default
        for pid in pidList.split(separator: ",").map(String.init) {
            var obs: [ActivityObservation] = []
            for l in lines("\(inDir)/\(pid).csv") {
                let p = l.split(separator: ",", omittingEmptySubsequences: false)
                guard p.count >= 6, let ts = Int(p[0]), let dyn = Double(p[1]), let x = Double(p[2]),
                      let y = Double(p[3]), let z = Double(p[4]) else { continue }
                let asleep = p[5] == "1"
                obs.append(ActivityObservation(ts: ts, dynAccelG: dyn, gravity: [x, y, z], wear: .onWrist,
                                               sleep: asleep ? .asleep : .awake, inBed: asleep))
            }
            var imuAt: [Int: ImuWindowFeatures] = [:]
            for l in lines("\(inDir)/\(pid).imu.csv") {
                let p = l.split(separator: ",", omittingEmptySubsequences: false)
                guard p.count >= 8, let s = Int(p[0]), let e = Int(p[1]), let a = Double(p[2]), let g = Double(p[3]),
                      let j = Double(p[4]), let cs = Double(p[6]) else { continue }
                imuAt[e] = ImuWindowFeatures(startTs: s, endTs: e, accelRmsG: a, gyroRmsDps: g, jerkRms: j,
                                             cadenceHz: Double(p[5]), cadenceStrength: cs,
                                             orientationChangeDeg: Double(p[7]))
            }
            for arm in arms {
                let parts = arm.split(separator: "_").map(String.init)
                var config = ActivityDecoderConfig()
                if parts[0] == "nd" { setNoDurationPrior(&config) }
                var o = obs
                if parts.count > 1, parts[1] == "imu" {
                    for i in o.indices { if let w = imuAt[o[i].ts] { o[i].imu = w } }
                }
                let track = ActivityContextTrackBuilder.decode(o, config: config)
                var out = "ts,class,posture,seated,upright,conf\n"
                out.reserveCapacity(track.states.count * 48)
                for s in track.states {
                    let k = ActivityClassifier.classify(state: s)
                    out += "\(s.ts),\(k.activityClass.rawValue),\(k.posture?.rawValue ?? ""),"
                    out += String(format: "%.3f,%.3f,%.3f\n", s.posture[.seatedLikely], s.posture[.uprightStationary], k.confidence)
                }
                try fm.createDirectory(atPath: "\(outDir)/\(arm)", withIntermediateDirectories: true)
                try out.write(toFile: "\(outDir)/\(arm)/\(pid).csv", atomically: true, encoding: .utf8)
                if env["E_TRACE"] == "1" {
                    // Per second: the decoder's own still stretch length and the prior lean it applied.
                    var dec = ActivityContextDecoder(config: config)
                    var tr = "ts,stillFor,lean\n"
                    for ob in o {
                        _ = dec.ingest(ob)
                        let st = dec.stillPriorState
                        if st.since != nil || st.lean != nil {
                            tr += "\(ob.ts),\(st.since.map { ob.ts - $0 } ?? -1),\(String(format: "%.3f", st.lean ?? 0))\n"
                        }
                    }
                    try tr.write(toFile: "\(outDir)/\(arm)/\(pid).trace.csv", atomically: true, encoding: .utf8)
                }
                print("EWRIST \(pid) \(arm) states \(track.states.count) obs \(o.count) decoder \(ActivityContextVersions.decoder)")
            }
        }
    }
}

private func setNoDurationPrior(_ c: inout ActivityDecoderConfig) { c.stillDurationPrior = false }
