import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// The live (main-actor) state one window build needs, copied out as values.
struct WatchdogLiveInputs {
    var hrRing: [HRSample]
    var rrRing: [RRInterval]
    var lastHeartRatePacketUnix: Int?
    /// WRIST_ON / WRIST_OFF seen live on this link (receipt-stamped).
    var wristEvents: [WatchdogQualityFeed.WristEvent]
    /// The link's charging flag; nil when unknown or disconnected.
    var charging: Bool?
}

/// Everything `WatchdogWindowLoader.load` reads, resolved on the main actor first. Value types only, so the
/// load runs detached from the main actor.
struct WatchdogWindowRequest {
    var store: WhoopStore
    /// Raw-physiology read ids, active strap first (`Repository.rawPhysiologyReadIds`).
    var readIds: [String]
    var nowUnix: Int
    var live: WatchdogLiveInputs
    /// Registry (model, brand) per id; absent = not in the registry.
    var registry: [String: (model: String?, brand: String?)]
    /// Families already proven by stored evidence (positive only; never shrinks).
    var provenFamilies: [String: DeviceFamily]
    /// Window structure for an unknown family (gap / freshness tolerances). Never used for unit conversion.
    var structuralHint: DeviceFamily
    var placement: String?
    /// Raw 100 Hz IMU records per read id (same order), read on the main actor (the file store is main-confined).
    var rawImu: [[ImuStoredRecord]]
    var contextIntervals: [ActivityContextIntervalRow]
    /// WRIST_OFF seconds already closed by a sustained-HR recovery (no need to re-read their HR).
    var recoveredOffs: Set<Int>
}

struct WatchdogWindowLoad {
    var window: Result<WatchdogWindow, WatchdogUnavailable>
    /// The quality feed (also on `window.quality` when the window built).
    var quality: WatchdogQualityFeed
    /// Families proven during this load, to cache.
    var provenFamilies: [String: DeviceFamily]
    var recoveredOffs: Set<Int>
    /// The family of the strap that owns this window's heart rate; nil = unknown.
    var family: DeviceFamily?
}

/// Builds one Watchdog window off the main actor: per-stream reads across the raw-physiology ids (the first id
/// that has a second wins it; R-R comes whole from the first id that has beats, so nothing is counted twice),
/// family-aware unit conversion, R-R de-duplication against the live ring, and the sensor-quality feed.
enum WatchdogWindowLoader {
    static func load(_ req: WatchdogWindowRequest) async -> WatchdogWindowLoad {
        let now = req.nowUnix
        let from = now - WatchdogConfig.contextSeconds
        let wearFrom = now - WatchdogQualityFeedBuilder.wearLookbackSeconds
        let store = req.store
        let ids = req.readIds

        // Heart rate: per second, first id wins.
        var hrLists: [[HRSample]] = []
        var hrOwner: String?
        for id in ids {
            let rows = (try? await store.hrSamples(deviceId: id, from: from, to: now, limit: 8_000)) ?? []
            if hrOwner == nil, !rows.isEmpty { hrOwner = id }
            hrLists.append(rows)
        }
        let hrStored = firstWins(hrLists, ts: \.ts)

        // R-R: the whole window from the first id that holds beats (one strap, one transport).
        var rrStored: [RRInterval] = []
        var rrOwner: String?
        var rrChannelsById: [String: Set<Int>] = [:]
        for id in ids {
            let rows = (try? await store.rrIntervals(deviceId: id, from: from, to: now, limit: 8_000)) ?? []
            rrChannelsById[id] = Set(rows.compactMap { $0.srcChannel?.rawValue })
            if rrOwner == nil, !rows.isEmpty {
                rrOwner = id
                rrStored = rows
            }
        }

        // Families from positive evidence only.
        var proven = req.provenFamilies
        var families: [String: DeviceFamily] = [:]
        for id in ids {
            let reg = req.registry[id]
            var holdsV18 = proven[id] == .whoop5
            if !holdsV18 {
                let one = (try? await store.v18AuxSamples(deviceId: id, from: 0, to: now + 86_400, limit: 1)) ?? []
                holdsV18 = !one.isEmpty
            }
            if let family = WatchdogDeviceBinding.whoopFamily(registryModel: reg?.model, registryBrand: reg?.brand,
                                                              holdsV18: holdsV18,
                                                              rrChannels: rrChannelsById[id] ?? []) {
                families[id] = family
            }
            if holdsV18 { proven[id] = .whoop5 }
        }
        let windowFamily: DeviceFamily? = (hrOwner ?? rrOwner).flatMap { families[$0] }
            ?? ids.lazy.compactMap { families[$0] }.first
        let structural = windowFamily ?? req.structuralHint

        // Skin temperature: only ids whose raw→°C branch is known. Unknown stays missing, never the 4.0 formula
        // applied to a 5.0 centidegree register (~156 °C).
        var tempLists: [[WatchdogScalarSample]] = []
        for id in ids {
            guard let scale = WatchdogDeviceBinding.temperatureScale(whoopFamily: families[id],
                                                                     registryBrand: req.registry[id]?.brand)
            else { continue }
            let rows = (try? await store.skinTempSamples(deviceId: id, from: from, to: now, limit: 8_000)) ?? []
            tempLists.append(rows.sorted { $0.ts < $1.ts }.map {
                WatchdogScalarSample(ts: $0.ts, value: skinTempCelsius(raw: $0.raw, family: scale))
            })
        }
        let temps = firstWins(tempLists, ts: \.ts)

        var spo2Lists: [[SpO2Sample]] = []
        var respLists: [[WatchdogScalarSample]] = []
        var stepLists: [[StepSample]] = []
        var gravityLists: [[GravitySample]] = []
        var auxLists: [[V18AuxSample]] = []
        var wearEvents: [WhoopEvent] = []
        var battery: [BatterySample] = []
        var contacts: [StandardHRContactSample] = []
        var ppgLists: [[PpgHrRow]] = []
        for id in ids {
            spo2Lists.append((try? await store.spo2Samples(deviceId: id, from: from, to: now, limit: 8_000)) ?? [])
            let respRows = (try? await store.respSamples(deviceId: id, from: from, to: now, limit: 8_000)) ?? []
            respLists.append(WatchdogWindowBuilder.respPerMin(
                rawRows: respRows.map { (ts: $0.ts, raw: $0.raw) },
                ringRate: OuraRespScale.isRingRateStream(deviceId: id),
                start: from, end: now))
            stepLists.append((try? await store.stepSamples(deviceId: id, from: from, to: now, limit: 8_000)) ?? [])
            gravityLists.append((try? await store.gravitySamples(deviceId: id, from: from, to: now,
                                                                  limit: 8_000)) ?? [])
            auxLists.append((try? await store.v18AuxSamples(deviceId: id, from: from, to: now, limit: 8_000)) ?? [])
            wearEvents += (try? await store.events(deviceId: id, from: wearFrom, to: now + 60,
                                                   kindPrefixes: WatchdogQualityFeedBuilder.eventPrefixes,
                                                   limit: 2_000)) ?? []
            battery += (try? await store.batteryChargingSamples(
                deviceId: id, from: now - WatchdogQualityFeedBuilder.chargingLevelFreshSeconds, to: now + 60,
                limit: 200)) ?? []
            contacts += (try? await store.standardHRContacts(deviceId: id, from: from, to: now, limit: 2_000)) ?? []
            ppgLists.append((try? await store.ppgHrRows(deviceId: id, from: from, to: now, limit: 8_000)) ?? [])
        }

        // Live heart rate joins the stored stream on seconds it does not already hold.
        var hr = hrStored
        var hrSeconds = Set(hr.map(\.ts))
        for sample in req.live.hrRing where sample.ts >= from && sample.ts <= now && !hrSeconds.contains(sample.ts) {
            hr.append(sample)
            hrSeconds.insert(sample.ts)
        }
        hr.sort { $0.ts < $1.ts }

        // One beat train: stored transport, live ring spliced after it, fills and twins out.
        let liveBeats = req.live.rrRing.filter { $0.ts >= from && $0.ts <= now }
        let merged = WatchdogRRMerge.merge(stored: rrStored, live: liveBeats, hrBpmAt: WatchdogRRMerge.hrLookup(hr))
        let rr = merged.beats

        var respPerMin = firstWins(respLists, ts: \.ts)
        if respPerMin.isEmpty {
            let window = Repository.hrvRollingWindowSec(spanSeconds: max(1, now - from))
            let step = Repository.respRollingStepSec(windowSec: window)
            respPerMin = SleepStager.rollingRespRate(rr, windowSec: window, stepSec: step)
                .filter { $0.ts >= from && $0.ts <= now }
                .map { WatchdogScalarSample(ts: $0.ts, value: $0.breathsPerMinute) }
        }

        // Motion: SQLite gravity, filled from the raw 100 Hz capture. A logged bicep / other site drops the wrist
        // IMU model entirely (the caller passes no raw records then, and the SQLite rows are dropped here).
        let dropsWristImu = req.placement == "bicep" || req.placement == "other"
        let imu: [WatchdogIMUSample]
        if dropsWristImu {
            imu = []
        } else {
            let sqlite = firstWins(gravityLists, ts: \.ts).map {
                WatchdogIMUSample(ts: $0.ts, x: $0.x, y: $0.y, z: $0.z, dynAccel: $0.dynAccel)
            }
            let fromFiles = firstWins(req.rawImu.map { WatchdogGravityFill.fromRawIMU($0) }, ts: \.ts)
            imu = mergeImu(sqlite: sqlite, fromFiles: fromFiles)
        }
        let motion = WatchdogQualityFeedBuilder.motionOccupancy(imu, family: windowFamily)

        // Wear: an open WRIST_OFF from the last 24 h, closed only by a WRIST_ON or sustained HR recovery.
        let storedWrist = WatchdogQualityFeedBuilder.wristEvents(wearEvents)
        var recovered = req.recoveredOffs
        var openOff: Int?
        if let offTs = WatchdogWearEvidence.latestOpenOffTs(stored: storedWrist, live: req.live.wristEvents,
                                                           nowUnix: now), !recovered.contains(offTs) {
            var recoveryHR = hr
            if offTs < from {
                // HR between the OFF and the window, read once per OFF (a recovered OFF is remembered).
                var older: [[HRSample]] = []
                for id in ids {
                    older.append((try? await store.hrSamples(deviceId: id, from: offTs, to: from - 1,
                                                             limit: 90_000)) ?? [])
                }
                recoveryHR = firstWins(older, ts: \.ts) + recoveryHR
            }
            openOff = WatchdogWearEvidence.openWristOffTs(stored: storedWrist, live: req.live.wristEvents,
                                                          hr: recoveryHR, nowUnix: now)
            if openOff == nil { recovered.insert(offTs) }
        }

        var spo2Pct = firstWins(spo2Lists, ts: \.ts).compactMap { sample -> WatchdogScalarSample? in
            guard let pct = WatchdogWindowBuilder.percentFromOptical(red: sample.red, ir: sample.ir) else {
                return nil
            }
            return WatchdogScalarSample(ts: sample.ts, value: pct)
        }
        let aux = firstWins(auxLists, ts: \.ts)
        let strapSpO2 = Spo2StrapEstimate.readings(from: aux)
        if spo2Pct.isEmpty {
            spo2Pct = strapSpO2.map { WatchdogScalarSample(ts: $0.ts, value: Double($0.percent)) }
        } else {
            let have = Set(spo2Pct.map(\.ts))
            spo2Pct.append(contentsOf: strapSpO2.compactMap { reading in
                guard !have.contains(reading.ts) else { return nil }
                return WatchdogScalarSample(ts: reading.ts, value: Double(reading.percent))
            })
        }

        // Sensor-quality metadata: missing stays empty / nil.
        var quality = WatchdogQualityFeed()
        quality.v18 = WatchdogQualityFeedBuilder.v18Seconds(aux)
        quality.v18RecordIndex = WatchdogQualityFeedBuilder.v18RecordIndex(aux)
        quality.wristEvents = storedWrist
        quality.liveWristEvents = req.live.wristEvents
        quality.charging = WatchdogQualityFeedBuilder.charging(battery: battery, events: wearEvents,
                                                               liveCharging: req.live.charging, nowUnix: now)
        quality.contacts = WatchdogQualityFeedBuilder.contacts(contacts)
        quality.placement = req.placement
        quality.resetEvents = WatchdogQualityFeedBuilder.resetEventTimes(wearEvents)
        quality.saturationEvents = WatchdogQualityFeedBuilder.saturationEventTimes(wearEvents)
        quality.ppgHr = WatchdogQualityFeedBuilder.ppgHr(firstWins(ppgLists, ts: \.ts))
        quality.rrTransport = merged.transport
        quality.rrLiveSplicedAfterTs = merged.splicedAfterTs
        quality.rrPileupSeconds = merged.pileupSeconds.filter { $0 >= from && $0 < now }
        quality.rrFillRejected = merged.fillRejected
        quality.rrDuplicatesRemoved = merged.duplicatesRemoved
        quality.rrCoverageByMinute = WatchdogQualityFeedBuilder.rrCoverageByMinute(rr, startUnix: from, endUnix: now)
        quality.hrSecondsByMinute = WatchdogQualityFeedBuilder.hrSecondsByMinute(hr, startUnix: from, endUnix: now)
        quality.contextIntervals = req.contextIntervals

        let usedLive = req.live.hrRing.contains { $0.ts >= from }
        let hrSource: WatchdogHRSource = usedLive ? .live2A37 : (structural == .whoop5 ? .ppgHr : .v18)
        let steps = firstWins(stepLists, ts: \.ts)
        let feed = WatchdogFeed(family: structural, hrSource: hrSource, nowUnix: now,
                                hr: hr, rr: rr, skinTempC: temps, respPerMin: respPerMin,
                                motion: motion,
                                spo2Pct: spo2Pct, wristOff: openOff != nil,
                                holdSeeds: .empty,
                                imu: imu, steps: steps)
        let window = WatchdogWindowBuilder.build(feed).map { built -> WatchdogWindow in
            var w = built
            w.quality = quality
            return w
        }
        return WatchdogWindowLoad(window: window, quality: quality, provenFamilies: proven,
                                  recoveredOffs: recovered, family: windowFamily)
    }

    /// No store handle: the live ring alone. Wear comes from live WRIST events (and recovery in the live HR);
    /// the family is whatever was proven for the active strap, else only a structural hint.
    static func liveOnly(snapshot: WatchdogLiveInputs, nowUnix: Int, family: DeviceFamily?,
                         structuralHint: DeviceFamily) -> WatchdogWindowLoad {
        let from = nowUnix - WatchdogConfig.contextSeconds
        let structural = family ?? structuralHint
        let hr = snapshot.hrRing.filter { $0.ts >= from && $0.ts <= nowUnix }
        let merged = WatchdogRRMerge.merge(stored: [], live: snapshot.rrRing.filter { $0.ts >= from && $0.ts <= nowUnix },
                                           hrBpmAt: WatchdogRRMerge.hrLookup(hr))
        var quality = WatchdogQualityFeed()
        quality.liveWristEvents = snapshot.wristEvents
        quality.charging = snapshot.charging
        quality.rrLiveSplicedAfterTs = merged.splicedAfterTs
        quality.rrPileupSeconds = merged.pileupSeconds
        quality.rrFillRejected = merged.fillRejected
        quality.rrDuplicatesRemoved = merged.duplicatesRemoved
        quality.rrCoverageByMinute = WatchdogQualityFeedBuilder.rrCoverageByMinute(merged.beats, startUnix: from,
                                                                                  endUnix: nowUnix)
        quality.hrSecondsByMinute = WatchdogQualityFeedBuilder.hrSecondsByMinute(hr, startUnix: from, endUnix: nowUnix)
        let liveBeating = WatchdogLiveTape.isFresh(packetUnix: snapshot.lastHeartRatePacketUnix, now: nowUnix,
                                                   freshnessSeconds: WatchdogQuality.freshnessLimit(structural))
        let empty = WatchdogWindowLoad(window: .failure(.empty), quality: quality, provenFamilies: [:],
                                       recoveredOffs: [], family: family)
        if hr.isEmpty && !liveBeating { return empty }
        let openOff = WatchdogWearEvidence.openWristOffTs(stored: [], live: snapshot.wristEvents, hr: hr,
                                                          nowUnix: nowUnix)
        let feed = WatchdogFeed(family: structural, hrSource: .live2A37, nowUnix: nowUnix,
                                hr: hr, rr: merged.beats,
                                wristOff: openOff != nil,
                                holdSeeds: .empty)
        var load = empty
        load.window = WatchdogWindowBuilder.build(feed).map { built -> WatchdogWindow in
            var w = built
            w.quality = quality
            return w
        }
        return load
    }

    /// SQLite x/y/z win on a shared second; a nil SQLite `dynAccel` is filled from the same second in the raw
    /// capture; raw seconds SQLite does not have yet are appended (a live walk moves HR before the gravity row
    /// is stored).
    static func mergeImu(sqlite: [WatchdogIMUSample], fromFiles: [WatchdogIMUSample]) -> [WatchdogIMUSample] {
        if fromFiles.isEmpty { return sqlite }
        if sqlite.isEmpty { return fromFiles }
        var dynByTs: [Int: Double?] = [:]
        for sample in fromFiles { dynByTs[sample.ts] = sample.dynAccel }
        let covered = Set(sqlite.map(\.ts))
        let filled = sqlite.map { sample -> WatchdogIMUSample in
            guard sample.dynAccel == nil, let dyn = dynByTs[sample.ts] ?? nil else { return sample }
            return WatchdogIMUSample(ts: sample.ts, x: sample.x, y: sample.y, z: sample.z, dynAccel: dyn)
        }
        return filled + fromFiles.filter { !covered.contains($0.ts) }
    }

    /// Per-second union of per-id lists, earlier lists (the active strap) winning a shared second. A single
    /// list is returned unchanged (sorted), so a one-strap install reads exactly what it did before.
    static func firstWins<T>(_ lists: [[T]], ts: KeyPath<T, Int>) -> [T] {
        let nonEmpty = lists.filter { !$0.isEmpty }
        if nonEmpty.count <= 1 {
            let only = nonEmpty.first ?? []
            return zip(only, only.dropFirst()).allSatisfy({ $0[keyPath: ts] <= $1[keyPath: ts] })
                ? only : only.sorted { $0[keyPath: ts] < $1[keyPath: ts] }
        }
        var seen = Set<Int>()
        var out: [T] = []
        for list in nonEmpty {
            for item in list where seen.insert(item[keyPath: ts]).inserted { out.append(item) }
        }
        return out.sorted { $0[keyPath: ts] < $1[keyPath: ts] }
    }
}
