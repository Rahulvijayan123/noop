import Foundation

// SleepFeatureDocument.swift — the shared typed document for the server's sleep-features
// enrichment (`snapshot.daily.sleep_features`, spec-25 §7.3 / docs/SLEEP_FEATURES_CONTRACT.md).
//
// The Python sidecar serializes one response document per enrichment call: per-night blocks
// (continuity / architecture / stage_physiology / settling / thermal / respiratory_variability),
// a whole-document regularity block, a dependencies version stamp and a capabilities gate object.
// This file mirrors that response shape EXACTLY (wire keys are the contract's snake_case keys;
// they must not be renamed — contract section 0 "must not rename wire keys").
//
// Why a shared typed document in StrandAnalytics (contract section 6 "Reusable types out of
// UI-only modules"): the worker Swift side and the app decode the SAME schema, so a rename on
// either side is a compile-time break instead of a silent nil day. `HostedDayResult` decodes it
// non-fatally from `daily["sleep_features"]` (same pattern as `activity_context`).
//
// Tolerated decoding is the contract's rule (section 2 / spec 7.3): "missing/malformed/future
// schema must not break the entire day". Every field is Optional (the Python side publishes
// null/absent for unavailable metrics — never a fabricated zero), every leaf is decoded with
// `try?`, and an array drops malformed elements instead of the whole array. A future schema bump
// therefore decodes to whatever subset it can and nils the rest — the day and the rest of the
// document always survive.

// MARK: - Tolerant decode helpers

/// Accepts any single JSON value. Used only to skip a malformed array element so the valid
/// elements around it still decode (one bad night never hides the other nights).
private struct AnyJSONValue: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        _ = try? container.decode(Bool.self)
        _ = try? container.decode(Double.self)
        _ = try? container.decode(String.self)
        _ = try? container.decode([AnyJSONValue].self)
        _ = try? container.decode([String: AnyJSONValue].self)
    }
}

private extension KeyedDecodingContainer {
    /// Tolerant single-value decode: a missing key, a wrong-typed value, or a value whose own
    /// decode throws all become nil (or the provided default). A malformed leaf never fails the
    /// whole document (contract section 2 / spec 7.3).
    func tolerant<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }

    /// Tolerant decode with a non-optional fallback (used for counts / flags that have a sane
    /// neutral default).
    func tolerant<T: Decodable>(_ type: T.Type, forKey key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(type, forKey: key)) ?? fallback
    }

    /// Tolerant array decode: malformed elements are skipped, valid ones are kept. Without this a
    /// single corrupted night would drop the whole `nights` array.
    func tolerantArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        guard var container = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [T] = []
        while !container.isAtEnd {
            if let value = try? container.decode(T.self) {
                result.append(value)
            } else if (try? container.decode(AnyJSONValue.self)) != nil {
                // Skip the malformed element and keep scanning.
            } else {
                break
            }
        }
        return result
    }
}

// MARK: - Status vocabulary

/// Machine-readable metric availability (contract section 2). Every metric block carries one of
/// these plus machine-readable reasons; the top-level document status adds `timeout` / `error`.
/// A future status string decodes as `.unknown` — the UI treats that as "don't guess", never as a
/// fake number.
public enum SleepMetricStatus: String, Codable, Equatable, Sendable {
    case available
    case partial
    case withheld
    case notApplicable = "not_applicable"
    /// The SleepECG shadow report is "not_run" until the candidate lane actually ran
    /// (contract section 3 sleepecg_shadow).
    case notRun = "not_run"
    case timeout
    case error
    case unknown
}

// MARK: - Top-level document

/// The whole `daily.sleep_features` document (contract section 2 response shape).
public struct SleepFeatureDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let algorithmVersion: String
    public let status: SleepMetricStatus
    public let statusReasons: [String]
    public let nights: [SleepFeatureNight]
    public let regularity: SleepRegularity?
    public let dependencies: SleepFeatureDependencies?
    public let capabilities: SleepFeatureCapabilities?
    /// Sidecar wall-clock budget usage in milliseconds (filled by the route; absent in old or
    /// degraded responses).
    public let durationMs: Double?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.tolerant(Int.self, forKey: .schemaVersion) ?? 0
        algorithmVersion = c.tolerant(String.self, forKey: .algorithmVersion) ?? ""
        status = c.tolerant(SleepMetricStatus.self, forKey: .status) ?? .unknown
        statusReasons = c.tolerant([String].self, forKey: .statusReasons) ?? []
        nights = c.tolerantArray(SleepFeatureNight.self, forKey: .nights)
        regularity = c.tolerant(SleepRegularity.self, forKey: .regularity)
        dependencies = c.tolerant(SleepFeatureDependencies.self, forKey: .dependencies)
        capabilities = c.tolerant(SleepFeatureCapabilities.self, forKey: .capabilities)
        durationMs = c.tolerant(Double.self, forKey: .durationMs)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case algorithmVersion = "algorithm_version"
        case status = "status"
        case statusReasons = "status_reasons"
        case nights = "nights"
        case regularity = "regularity"
        case dependencies = "dependencies"
        case capabilities = "capabilities"
        case durationMs = "duration_ms"
    }

    /// The non-nap night whose bed window overlaps `[startTs, endTs)`. With a window given and no
    /// overlapping night, nil: the document describes a different window (an edited or locally
    /// re-detected night), and its numbers must not be shown against this one. Without a window,
    /// the longest non-nap night. nil when every night is a nap or there are no nights.
    public func night(matchingStart startTs: Int?, end endTs: Int?) -> SleepFeatureNight? {
        let mains = nights.filter { !$0.isNap }
        guard !mains.isEmpty else { return nil }
        if let start = startTs, let end = endTs {
            return mains.first(where: { night in
                guard let ns = night.startAtUnix, let ne = night.endAtUnix else { return false }
                return ns < end && ne > start
            })
        }
        return mains.max { lhs, rhs in
            (lhs.endAtUnix ?? 0) - (lhs.startAtUnix ?? 0)
                < (rhs.endAtUnix ?? 0) - (rhs.startAtUnix ?? 0)
        }
    }

    /// Honest wording for a metric the document could not compute. Every metric is Optional
    /// because null/absent is how the Python side reports "not available" (contract section 2:
    /// "missing evidence yields null + reason"); the UI must never print a fabricated zero.
    /// Returns `Not available` for a nil value, or the value formatted with `format`.
    public static func value(_ value: Double?, format: String = "%.1f") -> String {
        guard let value else { return "Not available" }
        return String(format: format, value)
    }
}

// MARK: - One night

/// One canonical night entry inside `nights[]` (contract section 1 / 2).
public struct SleepFeatureNight: Codable, Equatable, Sendable {
    public let nightId: String
    /// ISO-8601 UTC bed-window start (`start_utc` on the wire — the locked contract's key; NOT
    /// `start_at`, which is the separate `sleep[]` array key in the hosted snapshot).
    public let startAt: String?
    /// ISO-8601 UTC bed-window end (`end_utc` on the wire).
    public let endAt: String?
    public let isNap: Bool
    /// True when a user edit applied to this night (contract section 1). Absent in old payloads.
    public let userEdited: Bool?
    public let stageSource: String?
    public let stageAlgorithmVersion: String?
    public let continuity: SleepContinuity?
    public let architecture: SleepArchitecture?
    public let stagePhysiology: SleepStagePhysiology?
    public let settling: SleepSettling?
    public let thermal: SleepThermal?
    public let respiratoryVariability: SleepRespiratoryVariability?
    public let metricStatus: SleepMetricStatusBlock?
    public let coverage: SleepCoverage?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nightId = c.tolerant(String.self, forKey: .nightId) ?? ""
        startAt = c.tolerant(String.self, forKey: .startAt)
        endAt = c.tolerant(String.self, forKey: .endAt)
        isNap = c.tolerant(Bool.self, forKey: .isNap) ?? false
        userEdited = c.tolerant(Bool.self, forKey: .userEdited)
        stageSource = c.tolerant(String.self, forKey: .stageSource)
        stageAlgorithmVersion = c.tolerant(String.self, forKey: .stageAlgorithmVersion)
        continuity = c.tolerant(SleepContinuity.self, forKey: .continuity)
        architecture = c.tolerant(SleepArchitecture.self, forKey: .architecture)
        stagePhysiology = c.tolerant(SleepStagePhysiology.self, forKey: .stagePhysiology)
        settling = c.tolerant(SleepSettling.self, forKey: .settling)
        thermal = c.tolerant(SleepThermal.self, forKey: .thermal)
        respiratoryVariability = c.tolerant(SleepRespiratoryVariability.self, forKey: .respiratoryVariability)
        metricStatus = c.tolerant(SleepMetricStatusBlock.self, forKey: .metricStatus)
        coverage = c.tolerant(SleepCoverage.self, forKey: .coverage)
    }

    enum CodingKeys: String, CodingKey {
        case nightId = "night_id"
        case startAt = "start_utc"
        case endAt = "end_utc"
        case isNap = "is_nap"
        case userEdited = "user_edited"
        case stageSource = "stage_source"
        case stageAlgorithmVersion = "stage_algorithm_version"
        case continuity = "continuity"
        case architecture = "architecture"
        case stagePhysiology = "stage_physiology"
        case settling = "settling"
        case thermal = "thermal"
        case respiratoryVariability = "respiratory_variability"
        case metricStatus = "metric_status"
        case coverage = "coverage"
    }

    /// Bed-window start as unix seconds (nil when `start_utc` is absent or unparsable).
    public var startAtUnix: Int? { Self.unixSeconds(startAt) }
    /// Bed-window end as unix seconds (nil when `end_utc` is absent or unparsable).
    public var endAtUnix: Int? { Self.unixSeconds(endAt) }

    private static func unixSeconds(_ iso: String?) -> Int? {
        guard let text = iso else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return Int(date.timeIntervalSince1970) }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text).map { Int($0.timeIntervalSince1970) }
    }
}

// MARK: - continuity (A1)

/// Per-night continuity / fragmentation (contract section 3 continuity, spec A1). Every metric is
/// Optional: a complete trace with zero events reports 0, missing evidence reports null + reason.
public struct SleepContinuity: Codable, Equatable, Sendable {
    public let status: SleepMetricStatus
    public let reasons: [String]
    public let tibMin: Double?
    public let tstMin: Double?
    public let solMin: Double?
    public let sol5MinRunMin: Double?
    public let sptMin: Double?
    public let wasoMin: Double?
    public let terminalWakeMin: Double?
    public let sleepEfficiencyPct: Double?
    public let sleepMaintenanceEfficiencyPct: Double?
    public let recurrentAwakenings: Int?
    public let recurrentAwakenings60sPlus: Int?
    public let recurrentAwakeningIndexPerH: Double?
    public let returnToSleepLatencyMedianMin: Double?
    public let awakeningDuration: SleepAwakeningDuration?
    public let longestSleepBoutMin: Double?
    public let meanSleepBoutMin: Double?
    public let sleepBouts: SleepBoutCount?
    public let sfiYasaPerH: Double?
    /// Raw `yasa.Hypnogram.sleep_statistics()` dict, verbatim (contract section 3 continuity).
    public let yasaStats: [String: Double]?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.tolerant(SleepMetricStatus.self, forKey: .status) ?? .unknown
        reasons = c.tolerant([String].self, forKey: .reasons) ?? []
        tibMin = c.tolerant(Double.self, forKey: .tibMin)
        tstMin = c.tolerant(Double.self, forKey: .tstMin)
        solMin = c.tolerant(Double.self, forKey: .solMin)
        sol5MinRunMin = c.tolerant(Double.self, forKey: .sol5MinRunMin)
        sptMin = c.tolerant(Double.self, forKey: .sptMin)
        wasoMin = c.tolerant(Double.self, forKey: .wasoMin)
        terminalWakeMin = c.tolerant(Double.self, forKey: .terminalWakeMin)
        sleepEfficiencyPct = c.tolerant(Double.self, forKey: .sleepEfficiencyPct)
        sleepMaintenanceEfficiencyPct = c.tolerant(Double.self, forKey: .sleepMaintenanceEfficiencyPct)
        recurrentAwakenings = c.tolerant(Int.self, forKey: .recurrentAwakenings)
        recurrentAwakenings60sPlus = c.tolerant(Int.self, forKey: .recurrentAwakenings60sPlus)
        recurrentAwakeningIndexPerH = c.tolerant(Double.self, forKey: .recurrentAwakeningIndexPerH)
        returnToSleepLatencyMedianMin = c.tolerant(Double.self, forKey: .returnToSleepLatencyMedianMin)
        awakeningDuration = c.tolerant(SleepAwakeningDuration.self, forKey: .awakeningDuration)
        longestSleepBoutMin = c.tolerant(Double.self, forKey: .longestSleepBoutMin)
        meanSleepBoutMin = c.tolerant(Double.self, forKey: .meanSleepBoutMin)
        sleepBouts = c.tolerant(SleepBoutCount.self, forKey: .sleepBouts)
        sfiYasaPerH = c.tolerant(Double.self, forKey: .sfiYasaPerH)
        yasaStats = c.tolerant([String: Double].self, forKey: .yasaStats)
    }

    enum CodingKeys: String, CodingKey {
        case status = "status", reasons = "reasons"
        case tibMin = "tib_min", tstMin = "tst_min", solMin = "sol_min"
        case sol5MinRunMin = "sol_5min_run_min", sptMin = "spt_min", wasoMin = "waso_min"
        case terminalWakeMin = "terminal_wake_min"
        case sleepEfficiencyPct = "sleep_efficiency_pct"
        case sleepMaintenanceEfficiencyPct = "sleep_maintenance_efficiency_pct"
        case recurrentAwakenings = "recurrent_awakenings"
        case recurrentAwakenings60sPlus = "recurrent_awakenings_60s_plus"
        case recurrentAwakeningIndexPerH = "recurrent_awakening_index_per_h"
        case returnToSleepLatencyMedianMin = "return_to_sleep_latency_median_min"
        case awakeningDuration = "awakening_duration"
        case longestSleepBoutMin = "longest_sleep_bout_min"
        case meanSleepBoutMin = "mean_sleep_bout_min"
        case sleepBouts = "sleep_bouts"
        case sfiYasaPerH = "sfi_yasa_per_h"
        case yasaStats = "yasa_stats"
    }
}

/// `continuity.awakening_duration` distribution (contract section 3 continuity).
public struct SleepAwakeningDuration: Codable, Equatable, Sendable {
    public let count: Int?
    public let medianMin: Double?
    public let p90Min: Double?
    public let maxMin: Double?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = c.tolerant(Int.self, forKey: .count)
        medianMin = c.tolerant(Double.self, forKey: .medianMin)
        p90Min = c.tolerant(Double.self, forKey: .p90Min)
        maxMin = c.tolerant(Double.self, forKey: .maxMin)
    }

    enum CodingKeys: String, CodingKey {
        case count = "count", medianMin = "median_min", p90Min = "p90_min", maxMin = "max_min"
    }
}

/// `continuity.sleep_bouts` count (contract section 3 continuity).
public struct SleepBoutCount: Codable, Equatable, Sendable {
    public let count: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = c.tolerant(Int.self, forKey: .count)
    }

    enum CodingKeys: String, CodingKey { case count = "count" }
}

// MARK: - architecture (A2)

/// Per-night stage-architecture dynamics (contract section 3 architecture, spec A2).
public struct SleepArchitecture: Codable, Equatable, Sendable {
    public let status: SleepMetricStatus
    public let reasons: [String]
    /// 4x4 adjacency counts in stage order wake/light/deep/rem; self-transitions included, UNS and
    /// gap-crossing pairs excluded (contract section 3 architecture).
    public let transitionCounts: [[Int]]
    /// 4x4 transition probabilities; an unobserved row is null (the whole row, not a fabricated 0).
    public let transitionProbabilities: [[Double?]]
    public let rowWeights: [Double?]
    public let entropyRateBitsPerTransition: Double?
    public let bouts: [String: SleepStageBoutSummary]
    public let remLatencyFromOnsetMin: Double?
    public let deepLatencyFromOnsetMin: Double?
    public let deepFrontLoadFraction: Double?
    public let remLateFraction: Double?
    public let eligiblePairs: Int?
    public let excludedPairsUns: Int?
    public let excludedPairsGap: Int?
    public let sleepPeriodThirdKnownFraction: Double?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.tolerant(SleepMetricStatus.self, forKey: .status) ?? .unknown
        reasons = c.tolerant([String].self, forKey: .reasons) ?? []
        transitionCounts = c.tolerant([[Int]].self, forKey: .transitionCounts) ?? []
        transitionProbabilities = c.tolerant([[Double?]].self, forKey: .transitionProbabilities) ?? []
        rowWeights = c.tolerant([Double?].self, forKey: .rowWeights) ?? []
        entropyRateBitsPerTransition = c.tolerant(Double.self, forKey: .entropyRateBitsPerTransition)
        bouts = c.tolerant([String: SleepStageBoutSummary].self, forKey: .bouts) ?? [:]
        remLatencyFromOnsetMin = c.tolerant(Double.self, forKey: .remLatencyFromOnsetMin)
        deepLatencyFromOnsetMin = c.tolerant(Double.self, forKey: .deepLatencyFromOnsetMin)
        deepFrontLoadFraction = c.tolerant(Double.self, forKey: .deepFrontLoadFraction)
        remLateFraction = c.tolerant(Double.self, forKey: .remLateFraction)
        eligiblePairs = c.tolerant(Int.self, forKey: .eligiblePairs)
        excludedPairsUns = c.tolerant(Int.self, forKey: .excludedPairsUns)
        excludedPairsGap = c.tolerant(Int.self, forKey: .excludedPairsGap)
        sleepPeriodThirdKnownFraction = c.tolerant(Double.self, forKey: .sleepPeriodThirdKnownFraction)
    }

    enum CodingKeys: String, CodingKey {
        case status = "status", reasons = "reasons"
        case transitionCounts = "transition_counts"
        case transitionProbabilities = "transition_probabilities"
        case rowWeights = "row_weights"
        case entropyRateBitsPerTransition = "entropy_rate_bits_per_transition"
        case bouts = "bouts"
        case remLatencyFromOnsetMin = "rem_latency_from_onset_min"
        case deepLatencyFromOnsetMin = "deep_latency_from_onset_min"
        case deepFrontLoadFraction = "deep_front_load_fraction"
        case remLateFraction = "rem_late_fraction"
        case eligiblePairs = "eligible_pairs"
        case excludedPairsUns = "excluded_pairs_uns"
        case excludedPairsGap = "excluded_pairs_gap"
        case sleepPeriodThirdKnownFraction = "sleep_period_third_known_fraction"
    }

    /// Bout summary for a stage (`bouts["wake"]`, `["light"]`, `["deep"]`, `["rem"]`).
    public func bouts(for stage: String) -> SleepStageBoutSummary? { bouts[stage] }
}

/// One stage's bout distribution (contract section 3 architecture `bouts`).
public struct SleepStageBoutSummary: Codable, Equatable, Sendable {
    public let count: Int?
    public let medianMin: Double?
    public let p90Min: Double?
    public let maxMin: Double?
    public let totalMin: Double?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = c.tolerant(Int.self, forKey: .count)
        medianMin = c.tolerant(Double.self, forKey: .medianMin)
        p90Min = c.tolerant(Double.self, forKey: .p90Min)
        maxMin = c.tolerant(Double.self, forKey: .maxMin)
        totalMin = c.tolerant(Double.self, forKey: .totalMin)
    }

    enum CodingKeys: String, CodingKey {
        case count = "count", medianMin = "median_min", p90Min = "p90_min"
        case maxMin = "max_min", totalMin = "total_min"
    }
}

// MARK: - stage_physiology (A4)

/// The `stage_physiology` block: a per-stage breakdown (contract section 3 stage_physiology,
/// spec A4). The stages dictionary is keyed by the wire stage labels (wake/light/deep/rem).
public struct SleepStagePhysiology: Codable, Equatable, Sendable {
    public let status: SleepMetricStatus
    public let reasons: [String]
    public let stageSource: String?
    public let modelDependent: Bool?
    public let notes: String?
    public let stages: [String: SleepStagePhysiologyMetrics]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.tolerant(SleepMetricStatus.self, forKey: .status) ?? .unknown
        reasons = c.tolerant([String].self, forKey: .reasons) ?? []
        stageSource = c.tolerant(String.self, forKey: .stageSource)
        modelDependent = c.tolerant(Bool.self, forKey: .modelDependent)
        notes = c.tolerant(String.self, forKey: .notes)
        stages = c.tolerant([String: SleepStagePhysiologyMetrics].self, forKey: .stages) ?? [:]
    }

    enum CodingKeys: String, CodingKey {
        case status = "status", reasons = "reasons"
        case stageSource = "stage_source", modelDependent = "model_dependent"
        case notes = "notes", stages = "stages"
    }

    public func metrics(for stage: String) -> SleepStagePhysiologyMetrics? { stages[stage] }
    public var wake: SleepStagePhysiologyMetrics? { stages["wake"] }
    public var light: SleepStagePhysiologyMetrics? { stages["light"] }
    public var deep: SleepStagePhysiologyMetrics? { stages["deep"] }
    public var rem: SleepStagePhysiologyMetrics? { stages["rem"] }
}

/// One stage's physiological summary (contract section 3 stage_physiology).
public struct SleepStagePhysiologyMetrics: Codable, Equatable, Sendable {
    public let status: SleepMetricStatus
    public let reasons: [String]
    public let hrMedianBpm: Double?
    public let hrP10Bpm: Double?
    public let hrP90Bpm: Double?
    public let rmssdMs: SleepHrvAggregate?
    public let sdnnMs: SleepHrvAggregate?
    public let respMedianBpm: Double?
    public let respVariabilityCv: Double?
    public let skinTempMedianC: Double?
    public let skinTempMadC: Double?
    public let movementEventsPerH: Double?
    public let validMin: Int?
    public let windows: Int?
    public let excludedMixedStageMin: Double?
    public let thinData: Bool?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.tolerant(SleepMetricStatus.self, forKey: .status) ?? .unknown
        reasons = c.tolerant([String].self, forKey: .reasons) ?? []
        hrMedianBpm = c.tolerant(Double.self, forKey: .hrMedianBpm)
        hrP10Bpm = c.tolerant(Double.self, forKey: .hrP10Bpm)
        hrP90Bpm = c.tolerant(Double.self, forKey: .hrP90Bpm)
        rmssdMs = c.tolerant(SleepHrvAggregate.self, forKey: .rmssdMs)
        sdnnMs = c.tolerant(SleepHrvAggregate.self, forKey: .sdnnMs)
        respMedianBpm = c.tolerant(Double.self, forKey: .respMedianBpm)
        respVariabilityCv = c.tolerant(Double.self, forKey: .respVariabilityCv)
        skinTempMedianC = c.tolerant(Double.self, forKey: .skinTempMedianC)
        skinTempMadC = c.tolerant(Double.self, forKey: .skinTempMadC)
        movementEventsPerH = c.tolerant(Double.self, forKey: .movementEventsPerH)
        validMin = c.tolerant(Int.self, forKey: .validMin)
        windows = c.tolerant(Int.self, forKey: .windows)
        excludedMixedStageMin = c.tolerant(Double.self, forKey: .excludedMixedStageMin)
        thinData = c.tolerant(Bool.self, forKey: .thinData)
    }

    enum CodingKeys: String, CodingKey {
        case status = "status", reasons = "reasons"
        case hrMedianBpm = "hr_median_bpm", hrP10Bpm = "hr_p10_bpm", hrP90Bpm = "hr_p90_bpm"
        case rmssdMs = "rmssd_ms", sdnnMs = "sdnn_ms"
        case respMedianBpm = "resp_median_bpm", respVariabilityCv = "resp_variability_cv"
        case skinTempMedianC = "skin_temp_median_c", skinTempMadC = "skin_temp_mad_c"
        case movementEventsPerH = "movement_events_per_h"
        case validMin = "valid_min", windows = "windows"
        case excludedMixedStageMin = "excluded_mixed_stage_min"
        case thinData = "thin_data"
    }
}

/// HRV aggregate over usable stage windows (contract section 3: median + IQR over windows).
public struct SleepHrvAggregate: Codable, Equatable, Sendable {
    public let median: Double?
    public let iqr: Double?
    public let windows: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        median = c.tolerant(Double.self, forKey: .median)
        iqr = c.tolerant(Double.self, forKey: .iqr)
        windows = c.tolerant(Int.self, forKey: .windows)
    }

    enum CodingKeys: String, CodingKey {
        case median = "median", iqr = "iqr", windows = "windows"
    }
}

// MARK: - settling (A5)

/// Per-night autonomic settling (contract section 3 settling, spec A5). t=0 is the canonical
/// ACTUAL sleep onset (first sleep epoch), not the session start.
public struct SleepSettling: Codable, Equatable, Sendable {
    public let status: SleepMetricStatus
    public let reasons: [String]
    public let hrPreOnsetSlopeBpmMin: Double?
    public let hrEarlySleepSlopeBpmMin: Double?
    public let hrDropBpm: Double?
    public let hrNadirLatencyMin: Double?
    public let hrSettlingLatencyMin: Double?
    public let hrvEarlySleepLogSlopePerMin: Double?
    public let hrCurve: [SleepHrCurvePoint]
    public let tempCurve: [SleepTempCurvePoint]
    public let hrvEarlySleepCurve: [SleepHrvCurvePoint]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.tolerant(SleepMetricStatus.self, forKey: .status) ?? .unknown
        reasons = c.tolerant([String].self, forKey: .reasons) ?? []
        hrPreOnsetSlopeBpmMin = c.tolerant(Double.self, forKey: .hrPreOnsetSlopeBpmMin)
        hrEarlySleepSlopeBpmMin = c.tolerant(Double.self, forKey: .hrEarlySleepSlopeBpmMin)
        hrDropBpm = c.tolerant(Double.self, forKey: .hrDropBpm)
        hrNadirLatencyMin = c.tolerant(Double.self, forKey: .hrNadirLatencyMin)
        hrSettlingLatencyMin = c.tolerant(Double.self, forKey: .hrSettlingLatencyMin)
        hrvEarlySleepLogSlopePerMin = c.tolerant(Double.self, forKey: .hrvEarlySleepLogSlopePerMin)
        hrCurve = c.tolerantArray(SleepHrCurvePoint.self, forKey: .hrCurve)
        tempCurve = c.tolerantArray(SleepTempCurvePoint.self, forKey: .tempCurve)
        hrvEarlySleepCurve = c.tolerantArray(SleepHrvCurvePoint.self, forKey: .hrvEarlySleepCurve)
    }

    enum CodingKeys: String, CodingKey {
        case status = "status", reasons = "reasons"
        case hrPreOnsetSlopeBpmMin = "hr_pre_onset_slope_bpm_min"
        case hrEarlySleepSlopeBpmMin = "hr_early_sleep_slope_bpm_min"
        case hrDropBpm = "hr_drop_bpm"
        case hrNadirLatencyMin = "hr_nadir_latency_min"
        case hrSettlingLatencyMin = "hr_settling_latency_min"
        case hrvEarlySleepLogSlopePerMin = "hrv_early_sleep_log_slope_per_min"
        case hrCurve = "hr_curve", tempCurve = "temp_curve"
        case hrvEarlySleepCurve = "hrv_early_sleep_curve"
    }
}

/// One minute-median heart-rate sample on the settling curves (contract section 3 settling).
public struct SleepHrCurvePoint: Codable, Equatable, Sendable {
    public let ts: Int?
    public let bpm: Double?
    /// False when the minute lacked enough time support; the UI must not connect across invalid
    /// minutes or treat them as a measured value.
    public let valid: Bool?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = c.tolerant(Int.self, forKey: .ts)
        bpm = c.tolerant(Double.self, forKey: .bpm)
        valid = c.tolerant(Bool.self, forKey: .valid)
    }

    enum CodingKeys: String, CodingKey {
        case ts = "ts", bpm = "bpm", valid = "valid"
    }
}

/// One minute-median skin-temperature sample on the settling curves.
public struct SleepTempCurvePoint: Codable, Equatable, Sendable {
    public let ts: Int?
    public let celsius: Double?
    public let valid: Bool?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = c.tolerant(Int.self, forKey: .ts)
        celsius = c.tolerant(Double.self, forKey: .celsius)
        valid = c.tolerant(Bool.self, forKey: .valid)
    }

    enum CodingKeys: String, CodingKey {
        case ts = "ts", celsius = "celsius", valid = "valid"
    }
}

/// One pooled-RMSSD window on the early-sleep HRV curve (contract section 3 settling).
public struct SleepHrvCurvePoint: Codable, Equatable, Sendable {
    public let ts: Int?
    public let rmssdMs: Double?
    public let pairs: Int?
    public let coverage: Double?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = c.tolerant(Int.self, forKey: .ts)
        rmssdMs = c.tolerant(Double.self, forKey: .rmssdMs)
        pairs = c.tolerant(Int.self, forKey: .pairs)
        coverage = c.tolerant(Double.self, forKey: .coverage)
    }

    enum CodingKeys: String, CodingKey {
        case ts = "ts", rmssdMs = "rmssd_ms", pairs = "pairs", coverage = "coverage"
    }
}

// MARK: - thermal (A6)

/// Per-night temperature transition and (withheld in wave 1) observed rhythm (contract section 3
/// thermal, spec A6).
public struct SleepThermal: Codable, Equatable, Sendable {
    public let status: SleepMetricStatus
    public let reasons: [String]
    public let baselineC: Double?
    public let earlySleepDeltaC: Double?
    public let riseSlopeCMin: Double?
    public let peakLatencyMin: Double?
    public let preWakeSlopeCMin: Double?
    public let thermalTransition: SleepThermalTransition?
    public let thermalToSleepLatencyMin: Double?
    public let observedSkinTempRhythm: SleepObservedRhythm?
    public let notes: [String]?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.tolerant(SleepMetricStatus.self, forKey: .status) ?? .unknown
        reasons = c.tolerant([String].self, forKey: .reasons) ?? []
        baselineC = c.tolerant(Double.self, forKey: .baselineC)
        earlySleepDeltaC = c.tolerant(Double.self, forKey: .earlySleepDeltaC)
        riseSlopeCMin = c.tolerant(Double.self, forKey: .riseSlopeCMin)
        peakLatencyMin = c.tolerant(Double.self, forKey: .peakLatencyMin)
        preWakeSlopeCMin = c.tolerant(Double.self, forKey: .preWakeSlopeCMin)
        thermalTransition = c.tolerant(SleepThermalTransition.self, forKey: .thermalTransition)
        thermalToSleepLatencyMin = c.tolerant(Double.self, forKey: .thermalToSleepLatencyMin)
        observedSkinTempRhythm = c.tolerant(SleepObservedRhythm.self, forKey: .observedSkinTempRhythm)
        notes = c.tolerant([String].self, forKey: .notes)
    }

    enum CodingKeys: String, CodingKey {
        case status = "status", reasons = "reasons"
        case baselineC = "baseline_c", earlySleepDeltaC = "early_sleep_delta_c"
        case riseSlopeCMin = "rise_slope_c_min", peakLatencyMin = "peak_latency_min"
        case preWakeSlopeCMin = "pre_wake_slope_c_min"
        case thermalTransition = "thermal_transition"
        case thermalToSleepLatencyMin = "thermal_to_sleep_latency_min"
        case observedSkinTempRhythm = "observed_skin_temp_rhythm"
        case notes = "notes"
    }
}

/// Bounded two-line breakpoint search result (contract section 3 thermal). `supported` gates
/// every interpretation; the UI must not present the transition as an onset detector.
public struct SleepThermalTransition: Codable, Equatable, Sendable {
    public let onsetMin: Double?
    public let rssSingle: Double?
    public let rssSplit: Double?
    public let improvementPct: Double?
    public let postSlopeCMin: Double?
    public let sustainedC: Double?
    public let supported: Bool?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onsetMin = c.tolerant(Double.self, forKey: .onsetMin)
        rssSingle = c.tolerant(Double.self, forKey: .rssSingle)
        rssSplit = c.tolerant(Double.self, forKey: .rssSplit)
        improvementPct = c.tolerant(Double.self, forKey: .improvementPct)
        postSlopeCMin = c.tolerant(Double.self, forKey: .postSlopeCMin)
        sustainedC = c.tolerant(Double.self, forKey: .sustainedC)
        supported = c.tolerant(Bool.self, forKey: .supported)
    }

    enum CodingKeys: String, CodingKey {
        case onsetMin = "onset_min", rssSingle = "rss_single", rssSplit = "rss_split"
        case improvementPct = "improvement_pct", postSlopeCMin = "post_slope_c_min"
        case sustainedC = "sustained_c", supported = "supported"
    }
}

/// Multi-day observed skin-temperature rhythm (withheld in wave 1:
/// `multi_day_history_not_requested` — contract section 3 thermal).
public struct SleepObservedRhythm: Codable, Equatable, Sendable {
    public let status: SleepMetricStatus
    public let reasons: [String]
    public let mesorC: Double?
    public let amplitudeC: Double?
    public let acrophaseH: Double?
    public let fitQuality: Double?
    public let isValue: Double?
    public let iv: Double?
    public let dailyAmplitudeC: Double?
    public let phaseStabilityH: Double?
    public let notes: [String]?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.tolerant(SleepMetricStatus.self, forKey: .status) ?? .unknown
        reasons = c.tolerant([String].self, forKey: .reasons) ?? []
        mesorC = c.tolerant(Double.self, forKey: .mesorC)
        amplitudeC = c.tolerant(Double.self, forKey: .amplitudeC)
        acrophaseH = c.tolerant(Double.self, forKey: .acrophaseH)
        fitQuality = c.tolerant(Double.self, forKey: .fitQuality)
        isValue = c.tolerant(Double.self, forKey: .isValue)
        iv = c.tolerant(Double.self, forKey: .iv)
        dailyAmplitudeC = c.tolerant(Double.self, forKey: .dailyAmplitudeC)
        phaseStabilityH = c.tolerant(Double.self, forKey: .phaseStabilityH)
        notes = c.tolerant([String].self, forKey: .notes)
    }

    enum CodingKeys: String, CodingKey {
        case status = "status", reasons = "reasons"
        case mesorC = "mesor_c", amplitudeC = "amplitude_c", acrophaseH = "acrophase_h"
        case fitQuality = "fit_quality", isValue = "is", iv = "iv"
        case dailyAmplitudeC = "daily_amplitude_c", phaseStabilityH = "phase_stability_h"
        case notes = "notes"
    }
}

// MARK: - respiratory_variability (A7)

/// Per-night RSA-derived respiratory variability (contract section 3 respiratory_variability,
/// spec A7). Always an ESTIMATE from the heart-rate rhythm — never presented as airflow.
public struct SleepRespiratoryVariability: Codable, Equatable, Sendable {
    public let status: SleepMetricStatus
    public let reasons: [String]
    public let estimateSource: String?
    public let unobservedBreathIsNotApnea: Bool?
    public let algorithmSource: String?
    public let notes: String?
    public let intervalsValid: Int?
    public let rateBpm: Double?
    public let sdIntervalS: Double?
    public let cvInterval: Double?
    public let rmssdIntervalS: Double?
    public let validRunMin: Double?
    public let quality: SleepRespQuality?
    public let stageConditioned: [String: SleepStageRespiratory]
    public let outlierFractionVsPersonal: SleepOutlierFraction?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.tolerant(SleepMetricStatus.self, forKey: .status) ?? .unknown
        reasons = c.tolerant([String].self, forKey: .reasons) ?? []
        estimateSource = c.tolerant(String.self, forKey: .estimateSource)
        unobservedBreathIsNotApnea = c.tolerant(Bool.self, forKey: .unobservedBreathIsNotApnea)
        algorithmSource = c.tolerant(String.self, forKey: .algorithmSource)
        notes = c.tolerant(String.self, forKey: .notes)
        intervalsValid = c.tolerant(Int.self, forKey: .intervalsValid)
        rateBpm = c.tolerant(Double.self, forKey: .rateBpm)
        sdIntervalS = c.tolerant(Double.self, forKey: .sdIntervalS)
        cvInterval = c.tolerant(Double.self, forKey: .cvInterval)
        rmssdIntervalS = c.tolerant(Double.self, forKey: .rmssdIntervalS)
        validRunMin = c.tolerant(Double.self, forKey: .validRunMin)
        quality = c.tolerant(SleepRespQuality.self, forKey: .quality)
        stageConditioned = c.tolerant([String: SleepStageRespiratory].self, forKey: .stageConditioned) ?? [:]
        outlierFractionVsPersonal = c.tolerant(SleepOutlierFraction.self, forKey: .outlierFractionVsPersonal)
    }

    enum CodingKeys: String, CodingKey {
        case status = "status", reasons = "reasons"
        case estimateSource = "estimate_source"
        case unobservedBreathIsNotApnea = "unobserved_breath_is_not_apnea"
        case algorithmSource = "algorithm_source", notes = "notes"
        case intervalsValid = "intervals_valid", rateBpm = "rate_bpm"
        case sdIntervalS = "sd_interval_s", cvInterval = "cv_interval"
        case rmssdIntervalS = "rmssd_interval_s", validRunMin = "valid_run_min"
        case quality = "quality", stageConditioned = "stage_conditioned"
        case outlierFractionVsPersonal = "outlier_fraction_vs_personal"
    }

    public func conditioned(for stage: String) -> SleepStageRespiratory? { stageConditioned[stage] }
    public var wake: SleepStageRespiratory? { stageConditioned["wake"] }
    public var light: SleepStageRespiratory? { stageConditioned["light"] }
    public var deep: SleepStageRespiratory? { stageConditioned["deep"] }
    public var rem: SleepStageRespiratory? { stageConditioned["rem"] }
}

/// Whole-night respiratory quality summary (contract section 3 respiratory_variability).
public struct SleepRespQuality: Codable, Equatable, Sendable {
    public let usableWindows: Int?
    public let totalWindows: Int?
    public let nightRunCoverage: Double?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        usableWindows = c.tolerant(Int.self, forKey: .usableWindows)
        totalWindows = c.tolerant(Int.self, forKey: .totalWindows)
        nightRunCoverage = c.tolerant(Double.self, forKey: .nightRunCoverage)
    }

    enum CodingKeys: String, CodingKey {
        case usableWindows = "usable_windows", totalWindows = "total_windows"
        case nightRunCoverage = "night_run_coverage"
    }
}

/// One stage's RSA pooling (`stage_conditioned`; contract section 3 respiratory_variability).
public struct SleepStageRespiratory: Codable, Equatable, Sendable {
    public let rateBpm: Double?
    public let cvInterval: Double?
    public let windows: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rateBpm = c.tolerant(Double.self, forKey: .rateBpm)
        cvInterval = c.tolerant(Double.self, forKey: .cvInterval)
        windows = c.tolerant(Int.self, forKey: .windows)
    }

    enum CodingKeys: String, CodingKey {
        case rateBpm = "rate_bpm", cvInterval = "cv_interval", windows = "windows"
    }
}

/// `outlier_fraction_vs_personal` — withheld until a personal baseline exists
/// (contract section 3 respiratory_variability).
public struct SleepOutlierFraction: Codable, Equatable, Sendable {
    public let status: SleepMetricStatus
    public let reasons: [String]
    public let fraction: Double?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.tolerant(SleepMetricStatus.self, forKey: .status) ?? .unknown
        reasons = c.tolerant([String].self, forKey: .reasons) ?? []
        fraction = c.tolerant(Double.self, forKey: .fraction)
    }

    enum CodingKeys: String, CodingKey {
        case status = "status", reasons = "reasons", fraction = "fraction"
    }
}

// MARK: - metric_status + coverage (per night)

/// The per-night `metric_status` block: the whole-night coverage gate verdict plus any module
/// that failed and published a withheld block instead of numbers (contract section 2 / 4).
public struct SleepMetricStatusBlock: Codable, Equatable, Sendable {
    public let nightGate: SleepMetricGate?
    public let moduleErrors: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nightGate = c.tolerant(SleepMetricGate.self, forKey: .nightGate)
        moduleErrors = c.tolerant([String].self, forKey: .moduleErrors) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case nightGate = "night_gate", moduleErrors = "module_errors"
    }
}

/// One machine-readable status + reasons pair (used by the night gate and every metric block).
public struct SleepMetricGate: Codable, Equatable, Sendable {
    public let status: SleepMetricStatus
    public let reasons: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.tolerant(SleepMetricStatus.self, forKey: .status) ?? .unknown
        reasons = c.tolerant([String].self, forKey: .reasons) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case status = "status", reasons = "reasons"
    }
}

/// The per-night evidence/coverage block (contract section 4). Every number is a count or a
/// fraction — the UI uses it to say HOW supported a shown metric is, never as a health value.
public struct SleepCoverage: Codable, Equatable, Sendable {
    public let knownFraction: Double?
    public let knownEpochFraction: Double?
    public let validHrMin: Int?
    public let observedHrMin: Int?
    public let validTempMin: Int?
    public let observedTempMin: Int?
    public let hrGapMaxS: Double?
    public let tempGapMaxS: Double?
    public let rrRows: Int?
    public let rrRejectedFraction: Double?
    public let breathIntervals: Int?
    public let breathRunMin: Double?
    public let overlapSeconds: Double?
    public let observedOnsetEdge: Bool?
    public let observedOffsetEdge: Bool?
    public let maxUnresolvedGapS: Double?
    public let sources: SleepCoverageSources?
    public let nightSpanS: Double?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        knownFraction = c.tolerant(Double.self, forKey: .knownFraction)
        knownEpochFraction = c.tolerant(Double.self, forKey: .knownEpochFraction)
        validHrMin = c.tolerant(Int.self, forKey: .validHrMin)
        observedHrMin = c.tolerant(Int.self, forKey: .observedHrMin)
        validTempMin = c.tolerant(Int.self, forKey: .validTempMin)
        observedTempMin = c.tolerant(Int.self, forKey: .observedTempMin)
        hrGapMaxS = c.tolerant(Double.self, forKey: .hrGapMaxS)
        tempGapMaxS = c.tolerant(Double.self, forKey: .tempGapMaxS)
        rrRows = c.tolerant(Int.self, forKey: .rrRows)
        rrRejectedFraction = c.tolerant(Double.self, forKey: .rrRejectedFraction)
        breathIntervals = c.tolerant(Int.self, forKey: .breathIntervals)
        breathRunMin = c.tolerant(Double.self, forKey: .breathRunMin)
        overlapSeconds = c.tolerant(Double.self, forKey: .overlapSeconds)
        observedOnsetEdge = c.tolerant(Bool.self, forKey: .observedOnsetEdge)
        observedOffsetEdge = c.tolerant(Bool.self, forKey: .observedOffsetEdge)
        maxUnresolvedGapS = c.tolerant(Double.self, forKey: .maxUnresolvedGapS)
        sources = c.tolerant(SleepCoverageSources.self, forKey: .sources)
        nightSpanS = c.tolerant(Double.self, forKey: .nightSpanS)
    }

    enum CodingKeys: String, CodingKey {
        case knownFraction = "known_fraction", knownEpochFraction = "known_epoch_fraction"
        case validHrMin = "valid_hr_min", observedHrMin = "observed_hr_min"
        case validTempMin = "valid_temp_min", observedTempMin = "observed_temp_min"
        case hrGapMaxS = "hr_gap_max_s", tempGapMaxS = "temp_gap_max_s"
        case rrRows = "rr_rows", rrRejectedFraction = "rr_rejected_fraction"
        case breathIntervals = "breath_intervals", breathRunMin = "breath_run_min"
        case overlapSeconds = "overlap_seconds"
        case observedOnsetEdge = "observed_onset_edge", observedOffsetEdge = "observed_offset_edge"
        case maxUnresolvedGapS = "max_unresolved_gap_s"
        case sources = "sources", nightSpanS = "night_span_s"
    }
}

/// Row counts per input channel inside the night (contract section 4 `sources`).
public struct SleepCoverageSources: Codable, Equatable, Sendable {
    public let hr: Int?
    public let temp: Int?
    public let rr: Int?
    public let resp: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hr = c.tolerant(Int.self, forKey: .hr)
        temp = c.tolerant(Int.self, forKey: .temp)
        rr = c.tolerant(Int.self, forKey: .rr)
        resp = c.tolerant(Int.self, forKey: .resp)
    }

    enum CodingKeys: String, CodingKey {
        case hr = "hr", temp = "temp", rr = "rr", resp = "resp"
    }
}

// MARK: - regularity (A3)

/// The whole-document `regularity` block (contract section 3 regularity, spec A3): rolling SRI
/// windows, the pair-coverage-by-hour profile and the circular clock profile.
public struct SleepRegularity: Codable, Equatable, Sendable {
    public let pairPolicy: String?
    public let sri7d: SleepSriWindow?
    public let sri14d: SleepSriWindow?
    public let sri30d: SleepSriWindow?
    public let pairCoverageByHour: [Int]
    public let clockProfile: SleepClockProfile?
    public let status: SleepMetricStatus
    public let reasons: [String]
    public let historyRevisionDigest: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pairPolicy = c.tolerant(String.self, forKey: .pairPolicy)
        sri7d = c.tolerant(SleepSriWindow.self, forKey: .sri7d)
        sri14d = c.tolerant(SleepSriWindow.self, forKey: .sri14d)
        sri30d = c.tolerant(SleepSriWindow.self, forKey: .sri30d)
        pairCoverageByHour = c.tolerant([Int].self, forKey: .pairCoverageByHour) ?? []
        clockProfile = c.tolerant(SleepClockProfile.self, forKey: .clockProfile)
        status = c.tolerant(SleepMetricStatus.self, forKey: .status) ?? .unknown
        reasons = c.tolerant([String].self, forKey: .reasons) ?? []
        historyRevisionDigest = c.tolerant(String.self, forKey: .historyRevisionDigest)
    }

    enum CodingKeys: String, CodingKey {
        case pairPolicy = "pair_policy"
        case sri7d = "sri_7d", sri14d = "sri_14d", sri30d = "sri_30d"
        case pairCoverageByHour = "pair_coverage_by_hour"
        case clockProfile = "clock_profile"
        case status = "status", reasons = "reasons"
        case historyRevisionDigest = "history_revision_digest"
    }
}

/// One rolling SRI window (contract section 3 regularity). A withheld window keeps its honest
/// gate numbers (`pairedMinutes` / `validDays`) and machine-readable reasons — the UI shows the
/// value only when `status == .available`.
public struct SleepSriWindow: Codable, Equatable, Sendable {
    public let value: Double?
    public let pairedMinutes: Int?
    public let eligibleMinutes: Int?
    public let validDays: Int?
    public let status: SleepMetricStatus
    public let reasons: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = c.tolerant(Double.self, forKey: .value)
        pairedMinutes = c.tolerant(Int.self, forKey: .pairedMinutes)
        eligibleMinutes = c.tolerant(Int.self, forKey: .eligibleMinutes)
        validDays = c.tolerant(Int.self, forKey: .validDays)
        status = c.tolerant(SleepMetricStatus.self, forKey: .status) ?? .unknown
        reasons = c.tolerant([String].self, forKey: .reasons) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case value = "value", pairedMinutes = "paired_minutes"
        case eligibleMinutes = "eligible_minutes", validDays = "valid_days"
        case status = "status", reasons = "reasons"
    }
}

/// The clock (timing-variability) profile (contract section 3 regularity). Delivered even when
/// SRI is withheld: timing variability is independent of the SRI gates.
public struct SleepClockProfile: Codable, Equatable, Sendable {
    public let bedTime: SleepCircadianMetric?
    public let sleepOnset: SleepCircadianMetric?
    public let finalWake: SleepCircadianMetric?
    public let midsleep: SleepCircadianMetric?
    public let adjacentNightPhaseShiftMin: SleepPhaseShift?
    public let socialJetlagMin: SleepSocialJetlag?
    public let dstTransitionDays: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bedTime = c.tolerant(SleepCircadianMetric.self, forKey: .bedTime)
        sleepOnset = c.tolerant(SleepCircadianMetric.self, forKey: .sleepOnset)
        finalWake = c.tolerant(SleepCircadianMetric.self, forKey: .finalWake)
        midsleep = c.tolerant(SleepCircadianMetric.self, forKey: .midsleep)
        adjacentNightPhaseShiftMin = c.tolerant(SleepPhaseShift.self, forKey: .adjacentNightPhaseShiftMin)
        socialJetlagMin = c.tolerant(SleepSocialJetlag.self, forKey: .socialJetlagMin)
        dstTransitionDays = c.tolerant(Int.self, forKey: .dstTransitionDays)
    }

    enum CodingKeys: String, CodingKey {
        case bedTime = "bed_time", sleepOnset = "sleep_onset"
        case finalWake = "final_wake", midsleep = "midsleep"
        case adjacentNightPhaseShiftMin = "adjacent_night_phase_shift_min"
        case socialJetlagMin = "social_jetlag_min"
        case dstTransitionDays = "dst_transition_days"
    }
}

/// Circular mean/SD of a local-clock timing metric, in minutes (contract section 3 regularity).
public struct SleepCircadianMetric: Codable, Equatable, Sendable {
    public let circadianMeanMin: Double?
    public let circadianSdMin: Double?
    public let n: Int?
    public let status: SleepMetricStatus
    public let reasons: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        circadianMeanMin = c.tolerant(Double.self, forKey: .circadianMeanMin)
        circadianSdMin = c.tolerant(Double.self, forKey: .circadianSdMin)
        n = c.tolerant(Int.self, forKey: .n)
        status = c.tolerant(SleepMetricStatus.self, forKey: .status) ?? .unknown
        reasons = c.tolerant([String].self, forKey: .reasons) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case circadianMeanMin = "circadian_mean_min", circadianSdMin = "circadian_sd_min"
        case n = "n", status = "status", reasons = "reasons"
    }
}

/// Median signed shortest circular difference between adjacent nights' midsleep, in minutes
/// (contract section 3 regularity).
public struct SleepPhaseShift: Codable, Equatable, Sendable {
    public let value: Double?
    public let n: Int?
    public let status: SleepMetricStatus
    public let reasons: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = c.tolerant(Double.self, forKey: .value)
        n = c.tolerant(Int.self, forKey: .n)
        status = c.tolerant(SleepMetricStatus.self, forKey: .status) ?? .unknown
        reasons = c.tolerant([String].self, forKey: .reasons) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case value = "value", n = "n", status = "status", reasons = "reasons"
    }
}

/// Social jetlag — withheld in wave 1 (`workday_labels_unavailable`).
public struct SleepSocialJetlag: Codable, Equatable, Sendable {
    public let value: Double?
    public let status: SleepMetricStatus
    public let reasons: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = c.tolerant(Double.self, forKey: .value)
        status = c.tolerant(SleepMetricStatus.self, forKey: .status) ?? .unknown
        reasons = c.tolerant([String].self, forKey: .reasons) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case value = "value", status = "status", reasons = "reasons"
    }
}

// MARK: - dependencies + capabilities

/// Version stamps of the sidecar's compute stack (contract section 2 / 9). Every value is
/// recorded from the installed package at runtime — nothing here is a fabricated version.
public struct SleepFeatureDependencies: Codable, Equatable, Sendable {
    public let yasa: String?
    public let numpy: String?
    public let scipy: String?
    public let neurokit2: String?
    public let sleepecg: String?
    public let configVersion: String?
    /// Every threshold the sidecar used, versioned as `sleep-features-defaults-1`
    /// (contract section 9). Numeric leaves only.
    public let config: [String: Double]?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        yasa = c.tolerant(String.self, forKey: .yasa)
        numpy = c.tolerant(String.self, forKey: .numpy)
        scipy = c.tolerant(String.self, forKey: .scipy)
        neurokit2 = c.tolerant(String.self, forKey: .neurokit2)
        sleepecg = c.tolerant(String.self, forKey: .sleepecg)
        configVersion = c.tolerant(String.self, forKey: .configVersion)
        config = c.tolerant([String: Double].self, forKey: .config)
    }

    enum CodingKeys: String, CodingKey {
        case yasa = "yasa", numpy = "numpy", scipy = "scipy"
        case neurokit2 = "neurokit2", sleepecg = "sleepecg"
        case configVersion = "config_version", config = "config"
    }
}

/// Group B capability gates (contract section 7): each blocked feature states its blocker
/// machine-readably. The UI reads `oxygenEvents.ready` to decide whether ANY oxygen metric may
/// be shown — a false gate means "no oxygen number at all", never a fake zero burden.
public struct SleepFeatureCapabilities: Codable, Equatable, Sendable {
    public let oxygenEvents: SleepCapabilityGate?
    public let waveformStaging: SleepCapabilityGate?
    public let cvhrScreening: SleepCapabilityGate?
    public let ppgAutonomicEvents: SleepCapabilityGate?
    public let cpcCycles: SleepCapabilityGate?
    public let sleepecgShadow: SleepEcgShadowReport?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        oxygenEvents = c.tolerant(SleepCapabilityGate.self, forKey: .oxygenEvents)
        waveformStaging = c.tolerant(SleepCapabilityGate.self, forKey: .waveformStaging)
        cvhrScreening = c.tolerant(SleepCapabilityGate.self, forKey: .cvhrScreening)
        ppgAutonomicEvents = c.tolerant(SleepCapabilityGate.self, forKey: .ppgAutonomicEvents)
        cpcCycles = c.tolerant(SleepCapabilityGate.self, forKey: .cpcCycles)
        sleepecgShadow = c.tolerant(SleepEcgShadowReport.self, forKey: .sleepecgShadow)
    }

    enum CodingKeys: String, CodingKey {
        case oxygenEvents = "oxygen_events", waveformStaging = "waveform_staging"
        case cvhrScreening = "cvhr_screening", ppgAutonomicEvents = "ppg_autonomic_events"
        case cpcCycles = "cpc_cycles", sleepecgShadow = "sleepecg_shadow"
    }
}

/// One capability gate: `ready` + a machine-readable `reason` for the blocker.
public struct SleepCapabilityGate: Codable, Equatable, Sendable {
    public let ready: Bool?
    public let reason: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ready = c.tolerant(Bool.self, forKey: .ready)
        reason = c.tolerant(String.self, forKey: .reason)
    }

    enum CodingKeys: String, CodingKey {
        case ready = "ready", reason = "reason"
    }
}

/// The SleepECG shadow report (A8) — agreement of the existing candidate lane vs V2 in the
/// common label space; report-only, never a staging replacement (contract section 3 sleepecg_shadow).
public struct SleepEcgShadowReport: Codable, Equatable, Sendable {
    public let status: SleepMetricStatus
    public let reason: String?
    public let epochsCompared: Int?
    public let agreementPct: Double?
    public let agreementByLabel: [String: Double]?
    public let v2Distribution: [String: Double]?
    public let sleepecgDistribution: [String: Double]?
    public let disagreementNearOnsetOffsetPct: Double?
    public let weightsRevision: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.tolerant(SleepMetricStatus.self, forKey: .status) ?? .unknown
        reason = c.tolerant(String.self, forKey: .reason)
        epochsCompared = c.tolerant(Int.self, forKey: .epochsCompared)
        agreementPct = c.tolerant(Double.self, forKey: .agreementPct)
        agreementByLabel = c.tolerant([String: Double].self, forKey: .agreementByLabel)
        v2Distribution = c.tolerant([String: Double].self, forKey: .v2Distribution)
        sleepecgDistribution = c.tolerant([String: Double].self, forKey: .sleepecgDistribution)
        disagreementNearOnsetOffsetPct = c.tolerant(Double.self, forKey: .disagreementNearOnsetOffsetPct)
        weightsRevision = c.tolerant(String.self, forKey: .weightsRevision)
    }

    enum CodingKeys: String, CodingKey {
        case status = "status", reason = "reason"
        case epochsCompared = "epochs_compared", agreementPct = "agreement_pct"
        case agreementByLabel = "agreement_by_label"
        case v2Distribution = "v2_distribution", sleepecgDistribution = "sleepecg_distribution"
        case disagreementNearOnsetOffsetPct = "disagreement_near_onset_offset_pct"
        case weightsRevision = "weights_revision"
    }
}
