import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - WatchdogLiveSnapshot
//
// What the Watchdog card and its vital sheet draw for the last half-hour: each vital's call ("In range",
// "Off", "Live", "No reading"), its colour, the per-minute series and band the trace is drawn from.
// Moved out of WatchdogView.swift UNCHANGED so it can be tested on its own (WatchdogLiveSnapshotTests);
// the status rules here decide what the wearer is told, so restyling the views must not touch them.

@MainActor
struct WatchdogLiveSnapshot {
    struct MetricRow: Identifiable {
        let id: String
        let name: String
        let now: String
        let expected: String
        let status: String
        let tone: Color
        let series: [Double]
        let reconstructed: [Double]
        let usualValue: Double?
        let windowCaption: String
        let minSpan: Double
        let decimals: Int
        let rangeHalf: Double
        let rangeSeries: [Double]
        let rangeLabel: String?
        let rangeReady: Bool
        let trustPct: Int
        let pulsePeriod: Double
    }

    let isLive: Bool
    let liveLabel: String
    let updatedAgo: String?
    let certaintyCaption: String?
    let bandCaption: String
    let metrics: [MetricRow]

    init(store: BaselineStore, temperatureUnit: TemperatureUnit = .celsius) {
        let fahrenheit = temperatureUnit == .fahrenheit
        if let result = store.watchdogResult {
            isLive = result.monitoringCurrent && result.unavailable == nil
            liveLabel = isLive ? "Live baseline" : Self.waitingLabel(result)
            updatedAgo = Self.ago(result.lastTickUnix)
            certaintyCaption = Self.certaintyCaption(result)
            bandCaption = Self.bandCaption(result, contextNote: store.activityContextNote)
            let hr = result.signals.first(where: { $0.name == "HR" })
            let rhr = result.signals.first(where: { $0.name == "RHR" })
            let hrv = result.signals.first(where: { $0.name == "HRV" })
            let temp = result.signals.first(where: { $0.name == "Temp" })
            let resp = result.signals.first(where: { $0.name == "Resp" })
            let spo2 = result.signals.first(where: { $0.name == "SpO2" })
            let whoop5 = WhoopModel.persisted == .whoop5mg
            metrics = [
                Self.row(id: "hr", name: "Heart rate", signal: hr, series: result.horizonHR,
                         reconstructed: result.reconstructedHR, rangeSeries: result.rangeHR,
                         caption: "Last 30 min", minSpan: 8, whoop5: whoop5,
                         trustPct: hr?.trustPct ?? 0, liveOff: result.liveOff,
                         channelHot: result.contributing.contains("HR") || result.personalOff,
                         bandReady: result.carry.channelBandReady(0)),
                Self.row(id: "rhr", name: "Resting HR", signal: rhr, series: result.horizonRHR,
                         reconstructed: result.reconstructedRHR, rangeSeries: result.rangeRHR,
                         caption: "Still minutes only", minSpan: 8, whoop5: whoop5,
                         trustPct: rhr?.trustPct ?? 0, liveOff: result.liveOff,
                         channelHot: result.contributing.contains("RHR") || result.personalOff,
                         bandReady: result.carry.channelBandReady(1)),
                Self.row(id: "hrv", name: "HRV", signal: hrv, series: result.horizonHRV,
                         reconstructed: result.reconstructedHRV, rangeSeries: result.rangeHRV,
                         caption: "5 min RMSSD", minSpan: 18, whoop5: whoop5,
                         trustPct: hrv?.trustPct ?? 0, liveOff: result.liveOff,
                         channelHot: result.contributing.contains("HRV") || result.personalOff,
                         bandReady: result.carry.channelBandReady(2)),
                Self.row(id: "temp", name: "Temp", signal: temp, series: result.horizonTemp,
                         reconstructed: result.reconstructedTemp, rangeSeries: result.rangeTemp,
                         caption: "Wrist skin · personal usual", minSpan: 0.4, whoop5: whoop5,
                         fahrenheit: fahrenheit, trustPct: temp?.trustPct ?? 0, liveOff: result.liveOff,
                         channelHot: result.contributing.contains("Temp"),
                         bandReady: result.carry.channelBandReady(3)),
                Self.row(id: "resp", name: "Breathing", signal: resp, series: result.horizonResp,
                         reconstructed: result.reconstructedResp, rangeSeries: result.rangeResp,
                         caption: "Last 30 min", minSpan: 4, whoop5: whoop5,
                         trustPct: resp?.trustPct ?? 0, liveOff: result.liveOff,
                         channelHot: result.contributing.contains("Resp"),
                         bandReady: result.carry.channelBandReady(4)),
                Self.row(id: "spo2", name: "SpO₂", signal: spo2, series: result.horizonSpO2,
                         reconstructed: result.reconstructedSpO2, rangeSeries: result.rangeSpO2,
                         caption: "When present", minSpan: 2, whoop5: whoop5,
                         trustPct: spo2?.trustPct ?? 0, liveOff: result.liveOff,
                         channelHot: result.contributing.contains("SpO2"),
                         bandReady: result.carry.channelBandReady(5))
            ]
            return
        }

        isLive = false
        liveLabel = "Waiting"
        updatedAgo = nil
        certaintyCaption = "Waiting on this half-hour."
        bandCaption = Self.bandCaption(nil, contextNote: store.activityContextNote)
        let whoop5 = WhoopModel.persisted == .whoop5mg
        metrics = [
            Self.emptyRow(id: "hr", name: "Heart rate", caption: "Last 30 min", minSpan: 8, whoop5: whoop5),
            Self.emptyRow(id: "rhr", name: "Resting HR", caption: "Still minutes only", minSpan: 8, whoop5: whoop5),
            Self.emptyRow(id: "hrv", name: "HRV", caption: "5 min RMSSD", minSpan: 18, whoop5: whoop5),
            Self.emptyRow(id: "temp", name: "Temp", caption: "Wrist skin · personal usual", minSpan: 0.4, whoop5: whoop5,
                          fahrenheit: fahrenheit),
            Self.emptyRow(id: "resp", name: "Breathing", caption: "Last 30 min", minSpan: 4, whoop5: whoop5),
            Self.emptyRow(id: "spo2", name: "SpO₂", caption: "When present", minSpan: 2, whoop5: whoop5)
        ]
    }

    static func row(id: String, name: String, signal: WatchdogSignalEvidence?,
                    series: [Double], reconstructed: [Double], rangeSeries: [Double],
                    caption: String, minSpan: Double, whoop5: Bool, fahrenheit: Bool = false,
                    trustPct: Int, liveOff: Bool = false, channelHot: Bool = false,
                    bandReady: Bool = false) -> MetricRow {
        var now = signal?.observed
        var usual = signal?.reconstructed ?? signal?.usual
        var series = series
        var reconstructed = reconstructed
        var rangeSeries = rangeSeries
        var minSpan = minSpan
        var range = (signal?.rangeHalf ?? 0) > 0 ? (signal?.rangeHalf ?? rangeHalf(for: id)) : rangeHalf(for: id)
        var unit = signal?.unit ?? ""
        if id == "temp", fahrenheit {
            now = now.map(UnitFormatter.celsiusToFahrenheit)
            usual = usual.map(UnitFormatter.celsiusToFahrenheit)
            series = series.map(UnitFormatter.celsiusToFahrenheit)
            reconstructed = reconstructed.map(UnitFormatter.celsiusToFahrenheit)
            minSpan *= 9.0 / 5.0
            range *= 9.0 / 5.0
            rangeSeries = rangeSeries.map { $0 * 9.0 / 5.0 }
            unit = "°F"
        }
        let hasLive = series.contains(where: \.isFinite)
        let callReady = bandReady && trustPct >= LongitudinalBaseline.trustHideThreshold
        let bandGain = Self.learningBandGain(trustPct)
        reconstructed = Self.maskToRecorded(reconstructed, recorded: series)
        rangeSeries = Self.maskToRecorded(rangeSeries, recorded: series).map { $0.isFinite ? $0 * bandGain : $0 }
        if id == "rhr" || id == "spo2" {
            let packed = Self.packRecorded(series: series, reconstructed: reconstructed, rangeSeries: rangeSeries)
            series = packed.series
            reconstructed = packed.reconstructed
            rangeSeries = packed.rangeSeries
        }
        range *= bandGain
        guard hasLive else {
            return MetricRow(id: id, name: name, now: "–", expected: "–", status: "No reading",
                             tone: StrandPalette.textTertiary, series: series, reconstructed: [],
                             usualValue: nil, windowCaption: caption, minSpan: minSpan,
                             decimals: decimals(for: id), rangeHalf: range, rangeSeries: [],
                             rangeLabel: nil, rangeReady: callReady, trustPct: trustPct,
                             pulsePeriod: whoopReadSeconds(id: id, whoop5: whoop5))
        }
        let aligned = lastAligned(series: series, reconstructed: reconstructed, usual: usual)
        let lastObs = aligned?.obs
        let lastHat = aligned?.hat
        let lastWidth: Double = {
            if let i = aligned?.index, i >= 0, i < rangeSeries.count, rangeSeries[i] > 0 {
                return rangeSeries[i]
            }
            return range
        }()
        let outsideBand: Bool = {
            guard let lastObs, let lastHat, lastWidth > 0 else { return false }
            return abs(lastObs - lastHat) > lastWidth
        }()
        let status: String
        let tone: Color
        if lastObs == nil {
            status = "No reading"
            tone = StrandPalette.textTertiary
        } else if !callReady {
            status = hasLive ? "Live" : "Learning"
            tone = StrandPalette.textSecondary
        } else if outsideBand {
            let mag: Double
            if lastWidth > 0, let lastObs, let lastHat {
                mag = min(1, abs(lastObs - lastHat) / max(lastWidth, 0.001) / WatchdogConfig.tauSevere)
            } else {
                mag = 0.5
            }
            status = "Off"
            tone = baselineOffColor(mag)
        } else {
            status = "In range"
            tone = StrandPalette.statusPositive
        }
        let rangeCenter = lastHat ?? usual
        let rangeLabel: String? = {
            guard let rangeCenter, lastWidth > 0 else { return nil }
            let dec = decimals(for: id)
            let lo = format(rangeCenter - lastWidth, decimals: dec, unit: "")
            let hi = format(rangeCenter + lastWidth, decimals: dec, unit: unit)
            return "Range \(lo)–\(hi)"
        }()
        return MetricRow(id: id, name: name,
                         now: format(lastObs ?? now, decimals: decimals(for: id), unit: unit),
                         expected: format(lastHat ?? usual, decimals: decimals(for: id), unit: unit),
                         status: status, tone: tone, series: series, reconstructed: reconstructed,
                         usualValue: lastHat ?? usual, windowCaption: caption, minSpan: minSpan,
                         decimals: decimals(for: id),
                         rangeHalf: lastWidth,
                         rangeSeries: rangeSeries,
                         rangeLabel: rangeLabel, rangeReady: callReady, trustPct: trustPct,
                         pulsePeriod: whoopReadSeconds(id: id, whoop5: whoop5))
    }

    static func learningBandGain(_ trust: Int) -> Double {
        if trust >= LongitudinalBaseline.trustHideThreshold { return 1 }
        let t = max(0, min(LongitudinalBaseline.trustHideThreshold, trust))
        return 1 + Double(LongitudinalBaseline.trustHideThreshold - t) / 35.0 * 2.5
    }

    static func maskToRecorded(_ values: [Double], recorded: [Double]) -> [Double] {
        values.enumerated().map { i, value in
            guard i < recorded.count, recorded[i].isFinite, value.isFinite else { return .nan }
            return value
        }
    }

    /// Drop empty minutes so still / sparse channels fill the plot instead of a sliver at t=29.
    static func packRecorded(series: [Double], reconstructed: [Double],
                             rangeSeries: [Double]) -> (series: [Double], reconstructed: [Double], rangeSeries: [Double]) {
        var outS: [Double] = []
        var outR: [Double] = []
        var outG: [Double] = []
        for i in series.indices {
            guard series[i].isFinite else { continue }
            outS.append(series[i])
            outR.append(i < reconstructed.count ? reconstructed[i] : .nan)
            outG.append(i < rangeSeries.count ? rangeSeries[i] : .nan)
        }
        return (outS, outR, outG)
    }

    static func lastAligned(series: [Double], reconstructed: [Double], usual: Double?) -> (obs: Double, hat: Double, index: Int)? {
        let n = max(series.count, reconstructed.count)
        guard n > 0 else {
            if let usual, let obs = series.last(where: { $0.isFinite }) { return (obs, usual, series.count - 1) }
            return nil
        }
        var i = n - 1
        while i >= 0 {
            let obs = i < series.count && series[i].isFinite ? series[i] : nil
            let hat = i < reconstructed.count && reconstructed[i].isFinite ? reconstructed[i] : nil
            if let obs, let hat { return (obs, hat, i) }
            if let obs, let usual { return (obs, usual, i) }
            i -= 1
        }
        return nil
    }

    static func emptyRow(id: String, name: String, caption: String, minSpan: Double, whoop5: Bool,
                         fahrenheit: Bool = false) -> MetricRow {
        let span = (id == "temp" && fahrenheit) ? minSpan * 9.0 / 5.0 : minSpan
        let half = rangeHalf(for: id) * ((id == "temp" && fahrenheit) ? 9.0 / 5.0 : 1)
        return MetricRow(id: id, name: name, now: "–", expected: "–", status: "No reading",
                  tone: StrandPalette.textTertiary, series: [], reconstructed: [],
                  usualValue: nil, windowCaption: caption, minSpan: span,
                  decimals: decimals(for: id), rangeHalf: half, rangeSeries: [],
                  rangeLabel: nil, rangeReady: false, trustPct: 0,
                  pulsePeriod: whoopReadSeconds(id: id, whoop5: whoop5))
    }

    static func rangeHalf(for id: String) -> Double {
        let scale: Double
        switch id {
        case "hr", "rhr": scale = WatchdogConfig.hrScale
        case "hrv": scale = WatchdogConfig.hrvScale
        case "temp": scale = WatchdogConfig.tempScale
        case "resp": scale = WatchdogConfig.respScale
        case "spo2": scale = WatchdogConfig.spo2Scale
        default: scale = 1
        }
        return scale * WatchdogConfig.tau
    }

    /// Live HR/RR cadence from the strap. WHOOP 4 ~1 Hz (2A37); 5/MG ~30 s. Other vitals are held or sparse.
    static func whoopReadSeconds(id: String, whoop5: Bool) -> Double {
        switch id {
        case "hr", "rhr", "hrv":
            return whoop5 ? 30 : 1
        default:
            return 0
        }
    }

    static func decimals(for id: String) -> Int { id == "temp" ? 1 : 0 }

    static func bandCaption(_ result: WatchdogResult?, contextNote: String? = nil) -> String {
        let base: String
        if let result, result.unavailable == nil {
            let n = result.carry.presentMinutes(channel: 0)
            let need = max(0, WatchdogBand.firstMinutes - n)
            if need == 0 {
                base = "Heart-rate green band is on. Sparse vitals (temp, breathing, SpO₂) each need their own 14 good minutes."
            } else {
                base = "Model range is on (gray). Green personal width after 14 good still minutes of that vital, about \(need) more for heart rate if the strap is labeling still."
            }
        } else {
            base = "Live line and gray model range can fill as soon as this half-hour has readings. Green personal width waits for 14 good still minutes of that vital."
        }
        return contextNote.map { base + " " + $0 } ?? base
    }

    static func certaintyCaption(_ result: WatchdogResult) -> String? {
        switch result.carry.notifyDelivery {
        case "denied":
            return "Alert not delivered. Notifications are off. Turn them on to retry."
        case "failed":
            return "Alert not delivered. Will retry."
        default:
            break
        }
        if result.unavailable == .wristOff {
            return "Strap off. Not recovered."
        }
        if result.unavailable != nil {
            return "Not enough minutes."
        }
        return nil
    }

    static func trustColor(_ pct: Int) -> Color {
        if pct >= 70 { return StrandPalette.statusPositive }
        if pct >= 40 { return StrandPalette.textSecondary }
        return StrandPalette.statusWarning
    }

    static func waitingLabel(_ result: WatchdogResult) -> String {
        result.unavailable == .wristOff ? "Off wrist" : "Waiting"
    }

    static func format(_ value: Double?, decimals: Int, unit: String) -> String {
        guard let value else { return "–" }
        let number = decimals == 0 ? String(format: "%.0f", value) : String(format: "%.\(decimals)f", value)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    static func ago(_ unix: Int) -> String {
        let seconds = Int(Date().timeIntervalSince1970) - unix
        if seconds < 45 { return "Just now" }
        if seconds < 120 { return "1 min ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3600) h ago"
    }
}
