import Foundation

/// Unique-minute mean for one civil-day series. Missing is never stored as 0.
public struct LBMinuteBucket: Equatable, Sendable, Codable {
    public var sum: Double = 0
    public var n: Int = 0
    public var lastMinuteUnix: Int = 0

    public var mean: Double? { n > 0 ? sum / Double(n) : nil }

    @discardableResult
    public mutating func addUnique(value: Double, minuteUnix: Int) -> Bool {
        guard value.isFinite, minuteUnix > lastMinuteUnix else { return false }
        sum += value
        n += 1
        lastMinuteUnix = minuteUnix
        return true
    }
}

/// Civil-day Watchdog tape for stub Layer 1 series. `evaluate` never writes 7-day / 60-day snapshots.
public struct LBDayTape: Equatable, Sendable, Codable {
    public var day: String
    public var restHR = LBMinuteBucket()
    public var restHRV = LBMinuteBucket()
    public var restSpO2 = LBMinuteBucket()
    public var effortHR = LBMinuteBucket()
    public var effortHRV = LBMinuteBucket()
    public var effortSpO2 = LBMinuteBucket()
    public var allHR = LBMinuteBucket()
    public var allHRV = LBMinuteBucket()
    public var allSpO2 = LBMinuteBucket()
    public var sleepSpO2Min: Double?
    public var sleepSpO2N: Int = 0
    public var sleepSpO2LastMinute: Int = 0
    public var activeMinutes: Int = 0
    public var lastActiveMinute: Int = 0

    public init(day: String) { self.day = day }

    /// Persisted v1 stored ln(RMSSD). Means in (0, 5) are leftover ln → ms.
    public mutating func migrateHrvFromLnIfNeeded() {
        func lift(_ b: inout LBMinuteBucket) {
            guard b.n > 0, b.mean.map({ $0 > 0 && $0 < 5 }) == true else { return }
            b.sum = exp(b.sum / Double(b.n)) * Double(b.n)
        }
        lift(&restHRV)
        lift(&effortHRV)
        lift(&allHRV)
    }

    public mutating func ingest(window: WatchdogWindow, nowUnix: Int,
                                lastWorkoutEndUnix: Int = 0,
                                sleepIntervals: [WatchdogSleepInterval] = [],
                                trainUsual: Bool = true) -> Bool {
        guard trainUsual else { return false }
        let tail = WatchdogLiveTail.resolve(window)
        let recovering = tail.postWorkout(carryEndUnix: lastWorkoutEndUnix, nowUnix: nowUnix)
        let features = window.resolvedActivityFeatures()
        var changed = false

        func lastFresh(_ series: [Double?], channel: Int) -> (Double, Int, Int)? {
            guard WatchdogQuality.channelFresh(series, startUnix: window.startUnix, nowUnix: nowUnix,
                                               channel: channel, family: window.family),
                  let t = WatchdogQuality.lastFiniteMinuteUnix(series, startUnix: window.startUnix)
            else { return nil }
            let i = (t - window.startUnix) / WatchdogConfig.gridSeconds
            guard i >= 0, i < series.count, let v = series[i] else { return nil }
            return (v, t - t % 60, i)
        }

        func sleepAt(minuteUnix: Int, row: Int) -> Bool {
            if sleepIntervals.contains(where: { $0.contains(minuteUnix) }) { return true }
            guard row >= 0, row < features.count else { return false }
            return WatchdogActivityFeatures.sleepBit(features[row]) == 1
        }

        if let (v, t, i) = lastFresh(window.hr, channel: 0) {
            let sleepNow = sleepAt(minuteUnix: t, row: i)
            let row = i < features.count ? features[i] : []
            let occ = row.isEmpty ? 0 : WatchdogActivityFeatures.priorOccupancy(row)
            let loco = row.isEmpty ? 0 : WatchdogActivityFeatures.stepLocomotion(row)
            changed = allHR.addUnique(value: v, minuteUnix: t) || changed
            if sleepNow {
                // Sleep HR stays on DailyMetric nights; tape does not invent sleep RHR.
            } else if tail.period == .effort || occ >= 0.15 || loco >= 0.5 {
                changed = effortHR.addUnique(value: v, minuteUnix: t) || changed
            } else if occ < 0.15, !recovering {
                changed = restHR.addUnique(value: v, minuteUnix: t) || changed
            }
            if !sleepNow, (occ >= 0.15 || loco >= 0.5), t > lastActiveMinute {
                activeMinutes += 1
                lastActiveMinute = t
                changed = true
            }
        }
        if let (v, t, i) = lastFresh(window.hrv, channel: 2) {
            let sleepNow = sleepAt(minuteUnix: t, row: i)
            let row = i < features.count ? features[i] : []
            let occ = row.isEmpty ? 0 : WatchdogActivityFeatures.priorOccupancy(row)
            let loco = row.isEmpty ? 0 : WatchdogActivityFeatures.stepLocomotion(row)
            // Native RMSSD ms. Layer 1 `toMath` is the only ln.
            changed = allHRV.addUnique(value: v, minuteUnix: t) || changed
            if !sleepNow, tail.period == .effort || occ >= 0.15 || loco >= 0.5 {
                changed = effortHRV.addUnique(value: v, minuteUnix: t) || changed
            } else if !sleepNow, occ < 0.15, !recovering {
                changed = restHRV.addUnique(value: v, minuteUnix: t) || changed
            }
        }
        if let (v, t, i) = lastFresh(window.spo2, channel: 5) {
            let sleepNow = sleepAt(minuteUnix: t, row: i)
            let row = i < features.count ? features[i] : []
            let occ = row.isEmpty ? 0 : WatchdogActivityFeatures.priorOccupancy(row)
            let loco = row.isEmpty ? 0 : WatchdogActivityFeatures.stepLocomotion(row)
            changed = allSpO2.addUnique(value: v, minuteUnix: t) || changed
            if sleepNow, t > sleepSpO2LastMinute {
                sleepSpO2Min = sleepSpO2Min.map { min($0, v) } ?? v
                sleepSpO2N += 1
                sleepSpO2LastMinute = t
                changed = true
            } else if !sleepNow, tail.period == .effort || occ >= 0.15 || loco >= 0.5 {
                changed = effortSpO2.addUnique(value: v, minuteUnix: t) || changed
            } else if !sleepNow, occ < 0.15, !recovering {
                changed = restSpO2.addUnique(value: v, minuteUnix: t) || changed
            }
        }
        return changed
    }

    public func observation(series: LBSeries) -> LBDailyObservation? {
        func publish(_ bucket: LBMinuteBucket, floor: Int, native: Double?) -> LBDailyObservation? {
            guard let native, bucket.n >= floor else { return nil }
            var o = LongitudinalBaseline.observation(
                day: day, native: native, streamPresent: true, sleepHrOnly: false, series: series)
            o.coverage = Double(bucket.n)
            return LongitudinalBaseline.applyCoverageGate(o, series: series)
        }
        switch series {
        case .awakeRestHR:
            return publish(restHR, floor: 8, native: restHR.mean)
        case .awakeRestHRVLn:
            return publish(restHRV, floor: 8, native: restHRV.mean)
        case .awakeRestSpO2Mean:
            return publish(restSpO2, floor: 4, native: restSpO2.mean)
        case .awakeActiveHR:
            return publish(effortHR, floor: 8, native: effortHR.mean)
        case .awakeActiveHRVLn:
            return publish(effortHRV, floor: 8, native: effortHRV.mean)
        case .awakeActiveSpO2Mean:
            return publish(effortSpO2, floor: 4, native: effortSpO2.mean)
        case .continuousHR:
            return publish(allHR, floor: 8, native: allHR.mean)
        case .continuousHRVLn:
            return publish(allHRV, floor: 8, native: allHRV.mean)
        case .continuousSpO2Mean:
            return publish(allSpO2, floor: 4, native: allSpO2.mean)
        case .sleepSpO2Nadir:
            guard let nadir = sleepSpO2Min, sleepSpO2N >= 3 else { return nil }
            var o = LongitudinalBaseline.observation(
                day: day, native: nadir, streamPresent: true, sleepHrOnly: false, series: series)
            o.coverage = Double(sleepSpO2N)
            return LongitudinalBaseline.applyCoverageGate(o, series: series)
        case .wakingActiveMin:
            guard activeMinutes >= 1 else { return nil }
            return LongitudinalBaseline.observation(
                day: day, native: Double(activeMinutes), streamPresent: true,
                sleepHrOnly: false, series: series)
        default:
            return nil
        }
    }
}
