import SwiftUI
import Foundation
import StrandDesign

// SensorBiomarkersSection.swift — the compact details section for the descriptive sensor-biomarker
// families (spec-31 §9, CONTRACTS.md §1/§2/§6).
//
// Renders ONLY the descriptive tier: Wrist movement, Low-movement bouts, Wrist oscillation, Pulse
// waveform consistency and Pulse width. Each card shows units, the capture interval, observed
// coverage and a one-sentence plain definition. Withheld/unknown families show a precise
// human-readable reason — NEVER a measured zero. Tremor and arm-swing are research-tier and stay
// off the normal dashboard; DeepBeat/SiamAF rhythm outputs are shadow-only and never user-facing.
// No health-score framing anywhere.
//
// The pure rendering decisions live in `SensorBiomarkersViewModel` so the StrandTests can pin them
// without hosting a view; the SwiftUI shell is a thin renderer over that model.

/// Everything the section decides, as plain data. `build(_:)` turns one server document into the
/// cards to draw; tests pin the decisions here.
struct SensorBiomarkersViewModel: Equatable {

    struct Item: Equatable {
        /// Stable family key (`movement`, `oscillation`, `ppg_quality`, `pulse_shape`).
        let key: String
        let title: String
        /// One-sentence plain definition.
        let definition: String
        /// Capture interval, human readable ("Oct 6, 00:00–23:59 UTC") or nil.
        let captureInterval: String?
        /// Observed / eligible coverage ("Observed 11h 05m · eligible 10h 02m") or nil.
        let coverage: String?
        /// The measured-value lines. Empty when the family is withheld or unusable.
        let values: [String]
        /// Why there are no values ("Not enough usable data." or a precise reason). Never shown
        /// alongside values; a withheld family must never render a measured zero.
        let unavailableReason: String?
    }

    let items: [Item]

    /// The display cards: the descriptive families, in display order. The `movement` family feeds
    /// TWO cards (wrist movement and low-movement bouts), so each card is a (family, kind) pair.
    /// Research-tier families (tremor, arm_swing) and shadow families (perfusion_research,
    /// rhythm_shadow) are deliberately NOT here.
    static let displayEntries: [(family: String, kind: String)] = [
        ("movement", "wrist_movement"),
        ("movement", "low_movement"),
        ("oscillation", "oscillation"),
        ("ppg_quality", "ppg_quality"),
        ("pulse_shape", "pulse_shape"),
    ]

    // MARK: - Build

    static func build(document: SensorBiomarkerDocument) -> SensorBiomarkersViewModel {
        let interval = captureInterval(start: document.intervalStartUTC, end: document.intervalEndUTC)
        var items: [Item] = []
        // Group display entries by family so a family's split cards (wrist movement + low-movement
        // bouts) are decided together.
        for familyKey in familyOrder {
            guard let family = document.families[familyKey] else { continue }
            let entries = displayEntries.filter { $0.family == familyKey }
            guard let first = entries.first else { continue }
            if family.isUsable {
                // Publish a card per sub-kind that has display values. A usable family with NONE of
                // its display measurements still gets its primary card, with the plain fallback —
                // never a silently missing card and never a fabricated zero.
                let populated = entries.compactMap { entry -> Item? in
                    let values = values(for: family, kind: entry.kind)
                    guard !values.isEmpty else { return nil }
                    return Item(key: entry.kind, title: title(for: entry.kind),
                                definition: definition(for: entry.kind),
                                captureInterval: interval, coverage: coverage(family: family),
                                values: values, unavailableReason: nil)
                }
                if populated.isEmpty {
                    items.append(Item(key: first.kind, title: title(for: first.kind),
                                      definition: definition(for: first.kind),
                                      captureInterval: nil, coverage: nil, values: [],
                                      unavailableReason: String(localized: "Not enough usable data.")))
                } else {
                    items.append(contentsOf: populated)
                }
            } else {
                // withheld / error / unknown: ONE card per family with a precise reason or the
                // plain fallback — never a measured zero, and never one duplicate reason per split.
                items.append(Item(key: first.kind, title: title(for: first.kind),
                                  definition: definition(for: first.kind),
                                  captureInterval: nil, coverage: nil, values: [],
                                  unavailableReason: reasonText(family.reason, status: family.status)))
            }
        }
        return SensorBiomarkersViewModel(items: items)
    }

    /// The display families, in display order.
    static let familyOrder = ["movement", "oscillation", "ppg_quality", "pulse_shape"]

    // MARK: - Titles and definitions

    static func title(for kind: String) -> String {
        switch kind {
        case "wrist_movement": return String(localized: "Wrist movement")
        case "low_movement": return String(localized: "Low-movement bouts")
        case "oscillation": return String(localized: "Wrist oscillation")
        case "ppg_quality": return String(localized: "Pulse waveform consistency")
        case "pulse_shape": return String(localized: "Pulse width")
        default: return String(localized: "Sensor measurement")
        }
    }

    static func definition(for kind: String) -> String {
        switch kind {
        case "wrist_movement":
            return String(localized: "How much your wrist moved, measured from the strap's accelerometer.")
        case "low_movement":
            return String(localized: "How long your wrist stayed still and how often it moved again.")
        case "oscillation":
            return String(localized: "Small 3–7 Hz wrist motion, like a subtle shake.")
        case "ppg_quality":
            return String(localized: "How similar your pulse waveforms looked to each other.")
        case "pulse_shape":
            return String(localized: "How wide each pulse was at half its height, from the optical sensor.")
        default:
            return String(localized: "A descriptive measurement from the strap's sensors.")
        }
    }

    // MARK: - Values

    /// The measured-value lines for one display card of a usable family. An empty result means the
    /// family is usable but carries none of its display measurements — the caller skips the card.
    static func values(for family: SensorBiomarkerFamily, kind: String) -> [String] {
        switch kind {
        case "wrist_movement":
            return wristMovementValues(family)
        case "low_movement":
            return lowMovementValues(family)
        case "oscillation":
            return oscillationValues(family)
        case "ppg_quality":
            return qualityValues(family)
        case "pulse_shape":
            return pulseShapeValues(family)
        default:
            return []
        }
    }

    static func measurement(_ family: SensorBiomarkerFamily, _ key: String) -> SensorBiomarkerMeasurement? {
        family.measurements[key]
    }

    /// A finite measurement value, or nil when the server published null/absent for the key.
    static func finite(_ measurement: SensorBiomarkerMeasurement?) -> Double? {
        guard let measurement, let value = measurement.value, value.isFinite else { return nil }
        return value
    }

    private static func wristMovementValues(_ family: SensorBiomarkerFamily) -> [String] {
        let median = measurement(family, "enmo_median_mg")
        let p95 = measurement(family, "enmo_p95_mg")
        let medianValue = finite(median)
        let p95Value = finite(p95)
        guard medianValue != nil || p95Value != nil else { return [] }
        let unit = median?.unit ?? p95?.unit ?? "mg"
        var lines: [String] = []
        switch (medianValue, p95Value) {
        case (let m?, let p?):
            lines.append(String(localized: "Median \(Self.number(m)) \(unit) · 95th percentile \(Self.number(p)) \(unit)"))
        case (let m?, nil):
            lines.append(String(localized: "Median \(Self.number(m)) \(unit)"))
        case (nil, let p?):
            lines.append(String(localized: "95th percentile \(Self.number(p)) \(unit)"))
        case (nil, nil):
            break
        }
        return lines
    }

    /// Bout count, median/max bout length, transitions per observed hour and the low-movement
    /// fraction WITH its classified-observed denominator (CONTRACTS §2). All descriptive.
    private static func lowMovementValues(_ family: SensorBiomarkerFamily) -> [String] {
        var lines: [String] = []
        if let count = finite(measurement(family, "low_movement_bout_count")) {
            let whole = Int(count.rounded())
            lines.append(whole == 1 ? String(localized: "1 bout") : String(localized: "\(whole) bouts"))
        }
        let medianBout = finite(measurement(family, "low_movement_bout_median_seconds"))
        let maxBout = finite(measurement(family, "low_movement_bout_max_seconds"))
        switch (medianBout, maxBout) {
        case (let m?, let x?):
            lines.append(String(localized: "Median \(Self.duration(m)) · longest \(Self.duration(x))"))
        case (let m?, nil):
            lines.append(String(localized: "Median bout \(Self.duration(m))"))
        case (nil, let x?):
            lines.append(String(localized: "Longest bout \(Self.duration(x))"))
        case (nil, nil):
            break
        }
        if let perHour = finite(measurement(family, "low_to_moving_transitions_per_observed_hour")) {
            lines.append(String(localized: "\(Self.number(perHour)) transitions per observed hour"))
        }
        if let fraction = finite(measurement(family, "low_movement_fraction")),
           fraction >= 0, fraction <= 1 {
            let denominator = measurement(family, "low_movement_fraction")?.denominator
            if let denominator, !denominator.isEmpty {
                lines.append(String(localized: "Low movement \(Self.percent(fraction)) of \(denominator)"))
            } else {
                lines.append(String(localized: "Low movement \(Self.percent(fraction)) of classified time"))
            }
        }
        return lines
    }

    private static func oscillationValues(_ family: SensorBiomarkerFamily) -> [String] {
        let median = measurement(family, "wrist_oscillation_power_3_7hz_median")
        let p95 = measurement(family, "wrist_oscillation_power_3_7hz_p95")
        let medianValue = finite(median)
        let p95Value = finite(p95)
        guard medianValue != nil || p95Value != nil else { return [] }
        let unit = median?.unit ?? p95?.unit ?? "(deg/s)²"
        var lines: [String] = []
        switch (medianValue, p95Value) {
        case (let m?, let p?):
            lines.append(String(localized: "Median \(Self.number(m, maxDecimals: 2)) \(unit) · 95th percentile \(Self.number(p, maxDecimals: 2)) \(unit)"))
        case (let m?, nil):
            lines.append(String(localized: "Median \(Self.number(m, maxDecimals: 2)) \(unit)"))
        case (nil, let p?):
            lines.append(String(localized: "95th percentile \(Self.number(p, maxDecimals: 2)) \(unit)"))
        case (nil, nil):
            break
        }
        return lines
    }

    private static func qualityValues(_ family: SensorBiomarkerFamily) -> [String] {
        let median = measurement(family, "template_similarity_median")
        let p25 = measurement(family, "template_similarity_p25")
        let medianValue = finite(median)
        let p25Value = finite(p25)
        guard medianValue != nil || p25Value != nil else { return [] }
        var lines: [String] = []
        switch (medianValue, p25Value) {
        case (let m?, let p?):
            lines.append(String(localized: "Median similarity \(Self.number(m, maxDecimals: 2)) · 25th percentile \(Self.number(p, maxDecimals: 2))"))
        case (let m?, nil):
            lines.append(String(localized: "Median similarity \(Self.number(m, maxDecimals: 2))"))
        case (nil, let p?):
            lines.append(String(localized: "25th percentile similarity \(Self.number(p, maxDecimals: 2))"))
        case (nil, nil):
            break
        }
        if let fraction = finite(measurement(family, "valid_waveform_fraction")),
           fraction >= 0, fraction <= 1 {
            lines.append(String(localized: "Valid waveform \(Self.percent(fraction)) of observed time"))
        }
        return lines
    }

    private static func pulseShapeValues(_ family: SensorBiomarkerFamily) -> [String] {
        var lines: [String] = []
        let width = measurement(family, "pulse_width50_median_ms")
        let iqr = measurement(family, "pulse_width50_iqr_ms")
        if let widthValue = finite(width) {
            let unit = width?.unit ?? "ms"
            if let iqrValue = finite(iqr) {
                lines.append(String(localized: "Median \(Self.number(widthValue, maxDecimals: 0)) \(unit) · IQR \(Self.number(iqrValue, maxDecimals: 0)) \(unit)"))
            } else {
                lines.append(String(localized: "Median \(Self.number(widthValue, maxDecimals: 0)) \(unit)"))
            }
        } else if let iqrValue = finite(iqr) {
            lines.append(String(localized: "IQR \(Self.number(iqrValue, maxDecimals: 0)) ms"))
        }
        // Native timing resolution: the sensor's own rate, never upgraded by interpolation.
        if let native = familyNativeRateHz(family) {
            lines.append(String(localized: "Native timing \(Self.number(native, maxDecimals: 0)) Hz (\(Self.samplePeriod(native)))"))
        } else if let resolution = familyNativeTimingResolution(family) {
            lines.append(String(localized: "Native timing \(resolution)"))
        }
        // Stable-configuration scope: device-unit pulse amplitudes are not comparable across
        // configurations, so the UI names the one these pulses came from.
        if let configuration = familyConfiguration(family) {
            lines.append(String(localized: "Stable configuration \(configuration)"))
        }
        let accepted = finite(measurement(family, "pulse_accepted_count"))
        let rejected = finite(measurement(family, "pulse_rejected_count"))
        switch (accepted, rejected) {
        case (let a?, let r?):
            lines.append(String(localized: "\(Self.integer(a)) pulses accepted · \(Self.integer(r)) rejected"))
        case (let a?, nil):
            lines.append(String(localized: "\(Self.integer(a)) pulses accepted"))
        case (nil, let r?):
            lines.append(String(localized: "\(Self.integer(r)) pulses rejected"))
        case (nil, nil):
            break
        }
        return lines
    }

    /// The family's native sample rate, from the family or its pulse measurements.
    static func familyNativeRateHz(_ family: SensorBiomarkerFamily) -> Double? {
        for measurement in family.measurements.values where measurement.nativeRateHz != nil {
            return measurement.nativeRateHz
        }
        return nil
    }

    /// A server-provided human string for the native timing resolution, when there is no numeric rate.
    static func familyNativeTimingResolution(_ family: SensorBiomarkerFamily) -> String? {
        for measurement in family.measurements.values where measurement.nativeTimingResolution != nil {
            return measurement.nativeTimingResolution
        }
        return nil
    }

    /// The opaque configuration identity the family's pulses belong to.
    static func familyConfiguration(_ family: SensorBiomarkerFamily) -> String? {
        for measurement in family.measurements.values where measurement.configuration != nil {
            return measurement.configuration
        }
        return nil
    }

    // MARK: - Coverage and interval

    /// Observed / eligible coverage as one line, or nil when the server reported neither.
    /// An eligible of 0 is NOT shown as "eligible 0s": it means nothing was eligible
    /// (an uncalibrated movement family, an unresolved gate), and the honest line
    /// is the observed time alone.
    static func coverage(family: SensorBiomarkerFamily) -> String? {
        switch (family.observedSeconds, family.eligibleSeconds) {
        case (let observed?, let eligible?) where eligible > 0:
            if abs(observed - eligible) < 1 {
                return String(localized: "Observed \(duration(observed))")
            }
            return String(localized: "Observed \(duration(observed)) · eligible \(duration(eligible))")
        case (let observed?, _):
            // eligible missing or zero: the honest line is the observed time alone.
            return String(localized: "Observed \(duration(observed))")
        case (nil, let eligible?) where eligible > 0:
            return String(localized: "Eligible \(duration(eligible))")
        case (nil, _):
            return nil
        }
    }

    /// "Oct 6, 00:00–23:59 UTC" for a same-day interval (including an end exactly at the next
    /// day's midnight, the CONTRACTS §3 day boundary), else "Oct 6, 00:00 – Oct 7, 06:00 UTC".
    /// Nil when either bound is missing or unparseable.
    static func captureInterval(start: String?, end: String?) -> String? {
        guard let start, let end,
              let startDate = isoDate(start), let endDate = isoDate(end) else { return nil }
        let startFormatter = DateFormatter()
        startFormatter.locale = Locale(identifier: "en_US_POSIX")
        startFormatter.timeZone = TimeZone(identifier: "UTC")
        startFormatter.dateFormat = "MMM d"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = TimeZone(identifier: "UTC")
        timeFormatter.dateFormat = "HH:mm"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let startDay = calendar.startOfDay(for: startDate)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: startDay)
        let sameDay = calendar.isDate(startDate, inSameDayAs: endDate)
            || (nextDay != nil && endDate == nextDay)
        if sameDay {
            // A UTC-day document ends exactly at the next midnight; render it as the day's last minute.
            let endTime = timeFormatter.string(from: endDate)
            let shownEnd = endTime == "00:00" ? "23:59" : endTime
            return "\(startFormatter.string(from: startDate)), \(timeFormatter.string(from: startDate))–\(shownEnd) UTC"
        }
        return "\(startFormatter.string(from: startDate)), \(timeFormatter.string(from: startDate)) – \(startFormatter.string(from: endDate)), \(timeFormatter.string(from: endDate)) UTC"
    }

    static func isoDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions.remove(.withFractionalSeconds)
        return formatter.date(from: string)
    }

    // MARK: - Reasons

    /// A precise human-readable reason for a withheld/error family, or the plain fallback.
    static func reasonText(_ reason: String?, status: String) -> String {
        if status == "error" {
            return String(localized: "This couldn't be computed today.")
        }
        switch reason {
        case "unknown_wrist_placement":
            return String(localized: "The strap's wrist placement wasn't verified.")
        case "unknown_orientation":
            return String(localized: "The strap's orientation wasn't verified.")
        case "insufficient_eligible_time":
            return String(localized: "Not enough eligible time was recorded.")
        case "unsupported_native_rate":
            return String(localized: "The sensor's native sample rate isn't supported for this measurement.")
        case "missing_ppg_anchor":
            return String(localized: "The pulse waveform was missing its reference anchor.")
        case "saturated_delta":
            return String(localized: "Part of the pulse waveform was saturated.")
        case "unverified_sample_clock":
            return String(localized: "The sensor's sample timing couldn't be verified.")
        case "preprocessing_unverified":
            return String(localized: "The signal preprocessing couldn't be verified.")
        case "no_verified_input":
            return String(localized: "No verified sensor data reached this measurement.")
        case "model_unavailable":
            return String(localized: "The model for this measurement isn't available.")
        case "artifact_unavailable":
            // Days published before 2026-10-09 used this one reason for both causes above, so it
            // claims neither.
            return String(localized: "This measurement couldn't be computed for this day.")
        case "unverified_optical_dc":
            return String(localized: "The optical baseline couldn't be verified.")
        case "not_enough_valid_data":
            return String(localized: "Not enough usable data.")
        default:
            return String(localized: "Not enough usable data.")
        }
    }

    // MARK: - Formatting

    /// "8h 05m", "45m", "3m 05s", "42s" — a human duration for coverage.
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(String(format: "%02dm", minutes))" : "\(hours)h"
        }
        if minutes > 0 {
            return seconds > 0 ? "\(minutes)m \(String(format: "%02ds", seconds))" : "\(minutes)m"
        }
        return "\(seconds)s"
    }

    /// One sample period from a native rate, e.g. 25 Hz → "40 ms per sample", 24 Hz → "42 ms per sample".
    /// Rounded to a whole millisecond: numerical interpolation does not add physical resolution.
    static func samplePeriod(_ nativeRateHz: Double) -> String {
        guard nativeRateHz > 0 else { return "unknown period" }
        return "\(Int((1000.0 / nativeRateHz).rounded())) ms per sample"
    }

    /// 0.42 → "42%". Clamped to 0–100.
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    /// A plain integer string ("1234") for counts.
    static func integer(_ value: Double) -> String {
        Self.number(value, maxDecimals: 0)
    }

    /// Fixed-locale number formatting so values never depend on the device locale. A whole value
    /// always renders without a decimal part; otherwise up to `maxDecimals` are shown with trailing
    /// zeros stripped ("0.31", "0.9", never "0.90").
    static func number(_ value: Double, maxDecimals: Int = 1) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 1e-9 {
            return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        let decimals = min(max(maxDecimals, 0), 6)
        var formatted = String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), value)
        if formatted.contains(".") {
            while formatted.hasSuffix("0") { formatted.removeLast() }
            if formatted.hasSuffix(".") { formatted.removeLast() }
        }
        return formatted
    }
}

// MARK: - SwiftUI shell

/// The compact details section. Hidden entirely (no route, no render) while
/// `SensorBiomarkerFeature` is off; the hosting page gates on the same flag.
struct SensorBiomarkersSection: View {
    let day: String

    @ObservedObject private var store: SensorBiomarkerStore

    /// Seconds between re-reads while the section is on screen, mirroring `IntradaySeriesSection`.
    private static let refreshSeconds: UInt64 = 30
    /// Re-reads only while the app is on screen, as `IntradaySeriesSection` does.
    @Environment(\.scenePhase) private var scenePhase

    init(day: String, store: SensorBiomarkerStore = .shared) {
        self.day = day
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        // Defense in depth: even if a future caller mounts this without checking the flag, nothing
        // renders and no route is called while the feature is off.
        if SensorBiomarkerFeature.isEnabled {
            content
                .task(id: "\(day)|\(store.epoch)|\(scenePhase == .active)") {
                    guard scenePhase == .active else { return }
                    await store.load(day: day)
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: Self.refreshSeconds * 1_000_000_000)
                        guard !Task.isCancelled else { return }
                        await store.load(day: day)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state(for: day) {
        case nil, .idle?, .loading?:
            loadingCard
        case .available(let document)?:
            availableContent(document, footerNote: nil)
        case .noData?:
            unavailableCard(String(localized: "No sensor biomarker data for this day yet."))
        case .unavailable(let reason)?:
            unavailableCard(reason)
        case .failed(let cached, _)?:
            if let cached {
                availableContent(cached, footerNote: String(localized: "Showing saved readings. The server can't be reached right now."))
            } else {
                unavailableCard(String(localized: "Can't reach the server right now."))
            }
        }
    }

    private func availableContent(_ document: SensorBiomarkerDocument, footerNote: String?) -> some View {
        let model = SensorBiomarkersViewModel.build(document: document)
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            header
            if model.items.isEmpty {
                unavailableCard(String(localized: "No sensor biomarker data for this day yet."))
            } else {
                ForEach(model.items, id: \.key) { item in
                    itemCard(item)
                }
                if let footerNote {
                    Text(footerNote)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var header: some View {
        SectionHeader("Sensor biomarkers")
    }

    private var loadingCard: some View {
        NoopCard {
            HStack(spacing: NoopMetrics.space2) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Loading sensor biomarkers…"))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private func unavailableCard(_ text: String) -> some View {
        NoopCard {
            HStack(alignment: .top, spacing: NoopMetrics.space2) {
                Image(systemName: "info.circle")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                Text(text)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func itemCard(_ item: SensorBiomarkersViewModel.Item) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text(item.title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(item.definition)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = item.unavailableReason {
                    HStack(alignment: .top, spacing: NoopMetrics.space1) {
                        Image(systemName: "exclamationmark.circle")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                        Text(reason)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ForEach(item.values, id: \.self) { line in
                        Text(line)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let interval = item.captureInterval {
                    Text(interval)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let coverage = item.coverage {
                    Text(coverage)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
