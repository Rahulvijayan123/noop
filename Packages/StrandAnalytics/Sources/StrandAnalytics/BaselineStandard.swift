import Foundation
import WhoopProtocol

// BaselineStandard.swift — the ONE standard every personal baseline in the app follows (bw2 consistency pass,
// 2026-10-07, branch feat/bw2-baseline-consistency).
//
// It does NOT replace any feature's baseline. Each feature keeps its own window length, estimator family and
// thresholds; this registry holds the parts that must be identical everywhere, so a number on one screen and the
// "same" number on another are built by the same rules. Every rule below cites where it is enforced; the unit
// tests in `BaselineStandardTests` and `BaselineStandardConsistencyTests` pin each one.
//
//  #  | Rule                                                        | Enforced by
//  ---|-------------------------------------------------------------|---------------------------------------------
//  1  | HRV is compared on ln(RMSSD) (Plews et al. 2012/2013; Task   | `Metric.hrvRmssd.isLog`, `toModel`/`fromModel`,
//     | Force 1996): centre/spread in ln, shown in ms via exp. SDNN  | `Context.sdnnDays` (an SDNN night never enters
//     | (Apple / Watch rows) is a different method and never pooled. | an RMSSD reference and is never scored on one)
//  2  | Causal: day D is judged only against days strictly before D. | `causalFold` (cherry-picked
//     | No end-of-history state may score a past day.                | `Baselines.foldHistoryAsOf*`), `windowReference`
//  3  | A day with a logged confounder (felt ill, alcohol, travel,   | `isConfounded` = !`LongitudinalBaseline.
//     | extra med, atypical sleep or diet) never enters a reference; | nightIsClean`; `Context.excludedFromReference`
//     | it is still scored.                                          |
//  4  | No z below 4 valid days ("usable"); trusted at 14.           | `minUsableDays`, `minTrustedDays`, `status(n:)`
//  5  | Scale floors shared with PhysiologyContext: ln-HRV 0.05,     | `scaleFloor(_:)` reads `PhysiologyContext.
//     | RHR 1 bpm, respiration 0.3 /min, skin temp 0.1 °C. A feature | ReferenceConfig().scaleFloors`; `cfg(_:)`'s EWMA
//     | may keep a LARGER floor it already has, never a smaller one, | floors are checked against it in tests
//     | and never a ~0 floor (1e-9 / 1e-4).                          |
//  6  | A device-family change resets the reference (regime tag).    | `regimeTag`, `resolveRegimes`, `referenceEpoch`
//     | WHOOP 4.0 vs 5.0/MG vs Oura are distinct where the data tell.| (+ `Baselines.deviceEraEpoch`)
//  7  | Calendar days, not rows: "28 days" is 28 calendar days and a | `calendarDays`, `windowReference(windowDays:)`,
//     | missing day is missing (never silently skipped into a longer | `causalFold` (calendar-padded)
//     | span).                                                       |
//
// Who calls what (every entry keeps its own feature-specific estimator; the rules above are what they share):
//
//  Feature                         | Entry point                                    | Estimator / window
//  --------------------------------|------------------------------------------------|---------------------------------
//  Charge (phone)                  | `ChargeBaselines.asOf`                         | Winsorized EWMA, as-of each night,
//                                  |                                                | ln HRV, all stored history
//  Charge (server worker)          | `RecoveryScorer.recovery(…BaselineState…)`     | EWMA over day < D (120 d)
//  Illness early warning           | `IllnessBaselines.evaluate`                    | EWMA over a 28-day calendar window
//  Cycle phase                     | `CyclePhaseEngine.nights(from:context:)`       | EWMA as-of each night
//  Daily stress (Stress screen)    | `DailyStressBaseline`                          | median/MAD, 30 calendar days
//  Daytime stress (day-relative)   | `DaytimeStress.analyze(mode: .dayRelative)`    | calm quartile, SD floored
//  Readiness                       | `ReadinessEngine.evaluate`                     | EWMA (HRV ln, RHR), median/MAD
//                                  |                                                | respiration, 30 calendar days
//  HRV readiness (Plews/Altini)    | `HRVReadiness.evaluate`                        | ln mean/SD, SD floored
//  Today "HRV X% vs baseline",     | `PersonalUsual`                                | median/MAD, 28 calendar days
//  Coach readiness / context       |                                                |
//  Layer 1 / Watchdog (lead-owned) | `LongitudinalBaseline`                         | robust window copies
//  PhysiologyContext (server)      | `PhysiologyContext.References`                 | median/MAD, 28 d (source of floors)
//
// Pure and deterministic. The only global reads are the two documented, defaults-injectable helpers
// `referenceEpoch` and `loadDayLogs`.

public enum BaselineStandard {

    // MARK: - Metrics

    /// A nightly (or daily) physiological metric a personal baseline is built for.
    public enum Metric: String, CaseIterable, Sendable, Hashable {
        /// Nightly RMSSD (ms). Modelled on ln(ms).
        case hrvRmssd
        /// Resting / sleeping heart rate (bpm).
        case restingHR
        /// Sleeping respiration rate (breaths/min).
        case respiration
        /// Skin temperature as a signed deviation from the personal baseline (±°C).
        case skinTempDeviation
        /// Nightly absolute wrist skin temperature (°C) — the value the on-device deviation is derived from.
        case skinTempAbsolute

        /// Rule 1: right-skewed, multiplicative metrics are compared on the log scale.
        public var isLog: Bool { self == .hrvRmssd }

        /// The PhysiologyContext series prefix whose scale floor this metric shares (rule 5).
        var pcSeriesPrefix: String {
            switch self {
            case .hrvRmssd: return "hrv_rmssd."
            case .restingHR: return "resting_hr."
            case .respiration: return "resp_rate."
            case .skinTempDeviation, .skinTempAbsolute: return "skin_temp."
            }
        }
    }

    // MARK: - Rule 4: minimum support

    /// Valid days before ANY comparison (z, percentage, label) may be shown. Below it a feature shows
    /// "learning" / no comparison. Same number as `Baselines.minNightsSeed`.
    public static let minUsableDays = Baselines.minNightsSeed
    /// Valid days before a comparison is "trusted" (alerts may raise). Same as `Baselines.minNightsTrust`.
    public static let minTrustedDays = Baselines.minNightsTrust

    /// Calibration status from a valid-day count (no staleness: a calendar window already bounds age).
    public static func status(n: Int) -> BaselineStatus {
        if n < minUsableDays { return .calibrating }
        if n < minTrustedDays { return .provisional }
        return .trusted
    }

    // MARK: - Rule 5: scale floors (shared with PhysiologyContext)

    private static let pcConfig = PhysiologyContext.ReferenceConfig()

    /// The default reference window in calendar days (PhysiologyContext's rolling view, 28).
    public static let referenceWindowDays = PhysiologyContext.ReferenceConfig().rollingWindowDays

    /// The smallest σ a reference for `metric` may claim, in MODEL units (ln units for HRV). Read from
    /// `PhysiologyContext.ReferenceConfig().scaleFloors` so the server context engine and every phone feature
    /// share one table (notes/statistics.md §2.2 explains each value: the native resolution of the signal).
    public static func scaleFloor(_ metric: Metric) -> Double {
        if let f = pcConfig.scaleFloors.first(where: { $0.seriesPrefix == metric.pcSeriesPrefix }) {
            return f.floor
        }
        return metric.isLog ? pcConfig.defaultLogFloor : pcConfig.defaultAbsoluteFloor
    }

    /// The Winsorized-EWMA config a causal fold of `metric` uses. Each one's implied σ floor
    /// (`impliedSigmaFloor`) is at least `scaleFloor(metric)` — pinned by `BaselineStandardTests`.
    public static func cfg(_ metric: Metric) -> MetricCfg {
        switch metric {
        case .hrvRmssd: return Baselines.readinessHRVLnCfg
        case .restingHR: return Baselines.restingHRCfg
        case .respiration: return Baselines.respCfg
        case .skinTempDeviation: return VitalBands.skinTempDeviationCfg
        case .skinTempAbsolute: return Baselines.metricCfg["skin_temp"]!
        }
    }

    /// The σ floor an EWMA config implies: `Baselines.sigma` of a state whose spread sits at the floor.
    public static func impliedSigmaFloor(_ cfg: MetricCfg) -> Double { 1.253 * cfg.floorSpread }

    // MARK: - Rule 1: model space

    /// Native value → model space (ln for HRV). nil for a value that cannot be modelled: non-finite, a
    /// non-positive HRV, or (for skin deviation) a value that is not a deviation at all.
    public static func toModel(_ value: Double, _ metric: Metric) -> Double? {
        guard value.isFinite else { return nil }
        switch metric {
        case .hrvRmssd: return value > 0 ? log(value) : nil
        case .skinTempDeviation: return skinDeviation(value)
        default: return value
        }
    }

    /// Model space → native units (exp for HRV).
    public static func fromModel(_ x: Double, _ metric: Metric) -> Double { metric.isLog ? exp(x) : x }

    /// The HRV method a nightly value was measured with. RMSSD (strap, WHOOP/Oura exports) and SDNN
    /// (Apple Health / Watch) are different statistics on different scales (SDNN reads ~2–3× RMSSD).
    public enum HRVMethod: String, Sendable { case rmssd, sdnn }

    // MARK: - Skin-temperature column semantics

    /// The `DailyMetric.skinTempDevC` column is TRIMODAL: a WHOOP CSV import writes an ABSOLUTE wrist °C
    /// (~30–36), an Oura import writes Oura's own deviation and the strap pipeline writes NOOP's deviation.
    /// A real nightly deviation never reaches ±5 °C, so anything larger is not a deviation and is excluded.
    public static let maxPlausibleSkinDeviationC = 5.0

    /// The value when it is a plausible skin-temperature DEVIATION, else nil (an absolute row, or junk).
    public static func skinDeviation(_ value: Double?) -> Double? {
        guard let v = value, v.isFinite, abs(v) <= maxPlausibleSkinDeviationC else { return nil }
        return v
    }

    // MARK: - Rule 3: confounders

    /// UserDefaults key the Layer 1 store persists the morning logs under (mirrors
    /// `BaselineStore.dayLogsKey`, which is owned by the baseline workstream and cannot import this file).
    public static let dayLogsDefaultsKey = "noop.baseline.daylog.v1"

    /// The persisted morning logs, keyed by `yyyy-MM-dd`. Empty when none were ever saved. Surfaces call this
    /// from view bodies, so the decode is memoised on the stored bytes (a changed log re-decodes).
    public static func loadDayLogs(_ defaults: UserDefaults = .standard) -> [String: LBDayLog] {
        guard let data = defaults.data(forKey: dayLogsDefaultsKey) else { return [:] }
        dayLogsLock.lock()
        defer { dayLogsLock.unlock() }
        if let cached = dayLogsCache, cached.data == data { return cached.logs }
        let logs = (try? JSONDecoder().decode([String: LBDayLog].self, from: data)) ?? [:]
        dayLogsCache = (data, logs)
        return logs
    }

    private static let dayLogsLock = NSLock()
    private static var dayLogsCache: (data: Data, logs: [String: LBDayLog])?

    /// True when the day carries a logged confounder. Same semantics (and the same day key) as
    /// `LongitudinalBaseline.nightIsClean`, the rule Layer 1 trains its usuals with.
    ///
    /// `nightIsClean` re-renders the epoch day to its canonical key and looks it up; every key here is already
    /// canonical `yyyy-MM-dd`, so the direct lookup is the same rule without a string format per call (it runs
    /// per day inside cache keys). `BaselineStandardTests` pins the equivalence.
    public static func isConfounded(_ day: String, dayLogs: [String: LBDayLog]) -> Bool {
        guard !dayLogs.isEmpty, let log = dayLogs[day] else { return false }
        return log.confoundsUsual
    }

    // MARK: - Rule 6: device regimes

    /// The regime tag of one day's source. The brand bucket (`Baselines.brandBucket`: WHOOP-origin ids are
    /// one brand, each wearable export its own) refined to the WHOOP hardware family only on POSITIVE registry
    /// evidence (`DeviceFamily.confirmedRegistryFamily`, the one interpreter of registry model labels; the
    /// legacy "WHOOP" label names no generation). An unknown WHOOP family stays "whoop" and is resolved by
    /// `resolveRegimes`, so a missing or legacy model never opens a false era.
    public static func regimeTag(sourceId: String, deviceModel: String? = nil, deviceBrand: String? = nil) -> String {
        let brand = Baselines.brandBucket(sourceId)
        guard brand == "whoop", deviceModel != nil else { return brand }
        switch DeviceFamily.confirmedRegistryFamily(model: deviceModel, brand: deviceBrand) {
        case .whoop4?: return "whoop4"
        case .whoop5?: return "whoop5"
        case nil: return brand
        }
    }

    /// Resolve per-day regime tags so only a POSITIVELY identified change opens an era. A nil tag (no source
    /// known) and an unknown WHOOP family ("whoop") inherit the nearest known tag of the same run: the previous
    /// one, else the next one. Two known families (or two brands) side by side remain distinct.
    public static func resolveRegimes(_ tags: [String?]) -> [String] {
        func known(_ t: String?) -> Bool { t != nil && t != "whoop" && t != "" }
        func compatible(_ unknown: String?, _ candidate: String) -> Bool {
            // A nil tag fits anything; an unknown WHOOP family only fits a WHOOP family.
            guard let u = unknown else { return true }
            return u == "whoop" ? candidate.hasPrefix("whoop") : u == candidate
        }
        var out = [String](repeating: "", count: tags.count)
        var last: String? = nil
        for i in tags.indices {
            if known(tags[i]) { out[i] = tags[i]!; last = tags[i] }
            else if let l = last, compatible(tags[i], l) { out[i] = l }
            else { out[i] = tags[i] ?? "" }
        }
        // Leading unknowns (nothing known before them) take the NEXT compatible known tag.
        var next: String? = nil
        for i in tags.indices.reversed() {
            if known(tags[i]) { next = tags[i]; continue }
            if out[i] == (tags[i] ?? ""), let n = next, compatible(tags[i], n) { out[i] = n }
        }
        return out
    }

    /// The reference epoch (seconds, UTC day start; 0 = none) for `metric`: the later of the manual
    /// recalibration epoch and the latest device-era start. HRV honours `noop.hrvBaselineEpoch`; every other
    /// metric honours the Charge-wide `noop.recoveryBaselineEpoch`. The "Recalibrate" action writes both, so a
    /// recalibration reaches every feature that builds its context through this function (rule 6 + J).
    public static func referenceEpoch(metric: Metric,
                                      sourceDays: [(day: String, sourceId: String)] = [],
                                      defaults: UserDefaults = .standard) -> Double {
        let manual = metric == .hrvRmssd ? Baselines.hrvBaselineEpoch(defaults)
                                         : Baselines.recoveryBaselineEpoch(defaults)
        return max(manual, Baselines.deviceEraEpoch(sourceDays))
    }

    /// `referenceEpoch` for every metric, for a surface that only needs the epochs.
    public static func referenceEpochs(sourceDays: [(day: String, sourceId: String)] = [],
                                       defaults: UserDefaults = .standard) -> [Metric: Double] {
        var epochs: [Metric: Double] = [:]
        for m in Metric.allCases { epochs[m] = referenceEpoch(metric: m, sourceDays: sourceDays, defaults: defaults) }
        return epochs
    }

    /// The first `yyyy-MM-dd` on or after `epoch` (seconds) that a reference may use, nil when no epoch.
    /// Same strict rule as the folds: a day whose UTC start is before the epoch is dropped.
    public static func firstDayOnOrAfter(epoch: Double) -> String? {
        guard epoch > 0 else { return nil }
        let d = Int((epoch / 86_400).rounded(.up))
        return dayKey(d)
    }

    // MARK: - Context

    /// Everything outside the series itself that decides which days a reference may use.
    public struct Context: Sendable {
        /// Morning logs (rule 3). Empty = no confounders known.
        public var dayLogs: [String: LBDayLog]
        /// Days whose HRV value is SDNN (rule 1): never in an RMSSD reference, never scored against one.
        public var sdnnDays: Set<String>
        /// Regime tag per day (rule 6), e.g. from `regimeTag`. Missing days inherit (see `resolveRegimes`).
        public var regimeByDay: [String: String] { didSet { resolved = Context.resolve(regimeByDay) } }
        /// Reference epoch per metric (seconds; 0/absent = none). Days starting before it are dropped.
        public var epochs: [Metric: Double]
        /// `regimeByDay` resolved once over its whole calendar span (`resolveRegimes`).
        private var resolved: (byDay: [String: String], first: String, last: String)?

        public init(dayLogs: [String: LBDayLog] = [:], sdnnDays: Set<String> = [],
                    regimeByDay: [String: String] = [:], epochs: [Metric: Double] = [:]) {
            self.dayLogs = dayLogs
            self.sdnnDays = sdnnDays
            self.regimeByDay = regimeByDay
            self.epochs = epochs
            self.resolved = Context.resolve(regimeByDay)
        }

        private static func resolve(_ tags: [String: String])
            -> (byDay: [String: String], first: String, last: String)? {
            guard let first = tags.keys.min(), let last = tags.keys.max() else { return nil }
            let days = BaselineStandard.calendarDays(from: first, through: last)
            let res = BaselineStandard.resolveRegimes(days.map { tags[$0] })
            return (Dictionary(uniqueKeysWithValues: zip(days, res)), first, last)
        }

        /// The resolved regime of `day` (rule 6); nil when no regime facts are known. A day past either end of
        /// the tagged span takes the nearest end's regime.
        public func regime(of day: String) -> String? {
            guard let r = resolved else { return nil }
            if let t = r.byDay[day] { return t.isEmpty ? nil : t }
            let t = day > r.last ? r.byDay[r.last] : (day < r.first ? r.byDay[r.first] : nil)
            return (t?.isEmpty ?? true) ? nil : t
        }

        /// The app's context: persisted morning logs, the manual recalibration + device-era epoch for every
        /// metric (`referenceEpoch`), plus whatever method/regime facts the caller knows.
        public static func app(dayLogs: [String: LBDayLog]? = nil, sdnnDays: Set<String> = [],
                               regimeByDay: [String: String] = [:],
                               sourceDays: [(day: String, sourceId: String)] = [],
                               defaults: UserDefaults = .standard) -> Context {
            Context(dayLogs: dayLogs ?? loadDayLogs(defaults), sdnnDays: sdnnDays, regimeByDay: regimeByDay,
                    epochs: referenceEpochs(sourceDays: sourceDays, defaults: defaults))
        }

        public func epoch(_ metric: Metric) -> Double { epochs[metric] ?? 0 }

        /// Rule 1 + 3: the day's value may not enter a reference for `metric`.
        public func excludedFromReference(_ day: String, metric: Metric) -> Bool {
            if metric == .hrvRmssd && sdnnDays.contains(day) { return true }
            return BaselineStandard.isConfounded(day, dayLogs: dayLogs)
        }

        /// Rule 1: the day's value may not be SCORED against a reference for `metric` (an SDNN night is not
        /// comparable with an RMSSD baseline). Confounded days ARE scored (rule 3).
        public func comparable(_ day: String, metric: Metric) -> Bool {
            !(metric == .hrvRmssd && sdnnDays.contains(day))
        }

        /// Rule 6: the day starts before the metric's reference epoch.
        func preEpoch(_ day: String, metric: Metric) -> Bool {
            let e = epoch(metric)
            guard e > 0, let d = BaselineStandard.epochDay(day) else { return false }
            return Double(d) * 86_400 < e
        }
    }

    // MARK: - Rule 7: calendar days

    /// Days since the civil epoch for a `yyyy-MM-dd` key (TZ-free; same algorithm as `Baselines`).
    public static func epochDay(_ key: String) -> Int? { Baselines.isoEpochDay(key) }

    /// `yyyy-MM-dd` for a civil epoch day.
    public static func dayKey(_ epochDay: Int) -> String { LongitudinalBaseline.isoFromEpochDay(epochDay) }

    /// `key` shifted by `days` calendar days; nil when unparseable.
    public static func shift(_ key: String, by days: Int) -> String? {
        epochDay(key).map { dayKey($0 + days) }
    }

    /// Every calendar day from `first` through `last` inclusive (empty when unparseable or reversed).
    public static func calendarDays(from first: String, through last: String) -> [String] {
        guard let a = epochDay(first), let b = epochDay(last), a <= b else { return [] }
        return (a...b).map(dayKey)
    }

    // MARK: - Robust calendar-window reference (median / MAD)

    /// A reference built from the valid days of a calendar window strictly before the day it judges.
    public struct Reference: Equatable, Sendable {
        public let metric: Metric
        /// Median, in model space (ln for HRV).
        public let center: Double
        /// σ estimate in model space: 1.4826·MAD with the small-sample factor, floored (rule 5).
        public let scale: Double
        /// Valid days behind the reference.
        public let n: Int
        public let scaleFloored: Bool
        public let fromDay: String?
        public let toDay: String?

        public var status: BaselineStatus { BaselineStandard.status(n: n) }
        public var usable: Bool { n >= BaselineStandard.minUsableDays }
        public var trusted: Bool { n >= BaselineStandard.minTrustedDays }
        /// The centre back in native units (ms for HRV, via exp).
        public var centerNative: Double { BaselineStandard.fromModel(center, metric) }

        /// Robust z of a native value against this reference; nil below `minUsableDays` (rule 4) or when the
        /// value cannot be modelled.
        public func z(_ value: Double) -> Double? {
            guard usable, let x = BaselineStandard.toModel(value, metric) else { return nil }
            return (x - center) / scale
        }

        /// `value / centre − 1` in native units (the "X% over baseline" read); nil below `minUsableDays`.
        public func ratio(_ value: Double) -> Double? {
            guard usable, centerNative > 0, value.isFinite else { return nil }
            return value / centerNative - 1
        }
    }

    /// The robust reference for `metric` as of `day`: the valid values of the `windowDays` calendar days
    /// strictly before `day`, with every standard filter applied — confounded and SDNN days out (rules 1, 3),
    /// days before the reference epoch out, and the walk back stops at the first regime change (rule 6).
    /// Centre = median, scale = `1.4826·MAD·b_n` (PhysiologyContext's small-sample factor), floored at
    /// `max(scaleFloor(metric), minScale)` — a caller may pass a LARGER floor it already had (rule 5).
    public static func windowReference(_ series: [String: Double], metric: Metric, asOf day: String,
                                       windowDays: Int = referenceWindowDays,
                                       context: Context = Context(),
                                       minScale: Double = 0) -> Reference {
        let floor = max(scaleFloor(metric), minScale)
        let empty = Reference(metric: metric, center: 0, scale: floor, n: 0, scaleFloored: true,
                              fromDay: nil, toDay: nil)
        guard let d = epochDay(day), windowDays > 0 else { return empty }
        let regime = context.regime(of: day)
        var xs: [Double] = []
        var from: String? = nil, to: String? = nil
        // Newest → oldest so the regime walk can stop at the first boundary.
        for back in 1...windowDays {
            let key = dayKey(d - back)
            if let r = regime, let rk = context.regime(of: key), rk != r { break }
            guard let raw = series[key], !context.preEpoch(key, metric: metric),
                  !context.excludedFromReference(key, metric: metric),
                  let x = toModel(raw, metric), plausible(raw, metric) else { continue }
            xs.append(x)
            if to == nil { to = key }
            from = key
        }
        typealias RS = PhysiologyContext.RobustStats
        guard let med = RS.median(xs) else { return empty }
        let raw = RS.madScale(xs, center: med, smallSampleCorrection: true) ?? 0
        let floored = !(raw >= floor)
        return Reference(metric: metric, center: med, scale: floored ? floor : raw, n: xs.count,
                         scaleFloored: floored, fromDay: from, toDay: to)
    }

    /// Convenience: a `[day: value]` series from rows (last row wins a duplicated day).
    public static func series<T>(_ rows: [T], day: (T) -> String, value: (T) -> Double?) -> [String: Double] {
        var out: [String: Double] = [:]
        for r in rows { if let v = value(r) { out[day(r)] = v } }
        return out
    }

    /// The plausibility bounds of the metric's EWMA config, applied in NATIVE units (so a 3 ms HRV or a
    /// 200 bpm "resting" HR never reaches a reference).
    static func plausible(_ value: Double, _ metric: Metric) -> Bool {
        switch metric {
        case .hrvRmssd:
            let c = cfg(.hrvRmssd)
            return value > 0 && log(value) >= c.minVal && log(value) <= c.maxVal
        default:
            let c = cfg(metric)
            return value >= c.minVal && value <= c.maxVal
        }
    }

    // MARK: - Causal Winsorized-EWMA fold (as of each day)

    /// The Winsorized-EWMA fold of `series` AS OF every calendar day: `before[D]` is built only from days < D
    /// (rule 2, via the cherry-picked `Baselines.foldHistoryAsOfDetailed`). The input is calendar-padded from
    /// `from` (or its first day) through `through` (or its newest day) so a missing day is a missing day
    /// (rule 7), values go to model space (rule 1), excluded days (SDNN, confounded) become missing (rules 1, 3)
    /// but stay keys, and the fold restarts at every regime change and at the metric's reference epoch (rule 6).
    public static func causalFold(_ series: [String: Double], metric: Metric, from: String? = nil,
                                  through: String? = nil, context: Context = Context(),
                                  cfg overrideCfg: MetricCfg? = nil,
                                  rejectHardOutliers: Bool = true) -> AsOfFold {
        let foldCfg = overrideCfg ?? cfg(metric)
        let bounds = Array(series.keys) + [from, through].compactMap { $0 }
        guard let first = bounds.min(), let last = bounds.max() else {
            let empty = Baselines.emptyState(foldCfg)
            return AsOfFold(before: [:], asOfDay: [:], end: empty, endAsOfDay: nil)
        }
        let days = calendarDays(from: first, through: last)
        let values: [Double?] = days.map { k in
            guard let v = series[k], !context.excludedFromReference(k, metric: metric) else { return nil }
            return toModel(v, metric)
        }
        let regimes: [String]? = context.regimeByDay.isEmpty
            ? nil : days.map { context.regime(of: $0) ?? "" }
        return Baselines.foldHistoryAsOfDetailed(values, dayKeys: days, cfg: foldCfg,
                                                 baselineEpoch: context.epoch(metric), regimes: regimes,
                                                 rejectHardOutliers: rejectHardOutliers)
    }

    /// z of a native value against an EWMA state (`Baselines.deviation` in model space). nil when the state
    /// is not usable (rule 4) or the value cannot be modelled.
    public static func z(_ value: Double, metric: Metric, state: BaselineState) -> Double? {
        guard state.usable, let x = toModel(value, metric) else { return nil }
        return Baselines.deviation(x, state: state).z
    }
}
