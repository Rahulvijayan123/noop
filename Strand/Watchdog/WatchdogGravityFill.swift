import Foundation
import WhoopProtocol
import StrandAnalytics

/// Downsample a WHOOP 5 / MG 100 Hz IMU second into the 1 Hz sample Watchdog already eats.
/// Does not write the capture files. Accel scale is the strap's 1/4096 g per LSB.
enum WatchdogGravityFill {
    static func fromRawIMU(_ records: [ImuStoredRecord]) -> [WatchdogIMUSample] {
        let n = Whoop5RawImu.sampleCount
        let scale = Whoop5RawImu.accelScale
        var out: [WatchdogIMUSample] = []
        out.reserveCapacity(records.count)
        for record in records.sorted(by: { $0.ts < $1.ts }) {
            let cols = record.columns
            guard cols.count >= n * 3 else { continue }
            var sx = 0.0, sy = 0.0, sz = 0.0
            var mags = [Double]()
            mags.reserveCapacity(n)
            for i in 0..<n {
                let x = Double(cols[i]) * scale
                let y = Double(cols[n + i]) * scale
                let z = Double(cols[2 * n + i]) * scale
                sx += x
                sy += y
                sz += z
                mags.append((x * x + y * y + z * z).squareRoot())
            }
            let inv = 1.0 / Double(n)
            let mx = sx * inv, my = sy * inv, mz = sz * inv
            let g = (mx * mx + my * my + mz * mz).squareRoot()
            let ux: Double
            let uy: Double
            let uz: Double
            if g > 1e-6 {
                ux = mx / g
                uy = my / g
                uz = mz / g
            } else {
                ux = 0
                uy = 0
                uz = 1
            }
            let meanMag = mags.reduce(0, +) * inv
            var energy = 0.0
            for m in mags {
                let d = m - meanMag
                energy += d * d
            }
            let dyn = (energy * inv).squareRoot()
            out.append(WatchdogIMUSample(ts: Int(record.ts), x: ux, y: uy, z: uz, dynAccel: dyn))
        }
        return out
    }
}
