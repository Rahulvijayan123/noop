import Foundation

// PCChangeDetection.swift — System F (part 2): transient, recurring and persistent change (spec §12.3).
//
// OWNER: statistics workstream. SKELETON — signatures are the shared contract.
//
// Episodes are descriptive. A known regime boundary is reported separately from an unexplained change; neither is
// called disease progression. Derived signals that share inputs are not counted as independent corroboration.

extension PhysiologyContext {

    public struct ChangeConfig: Codable, Equatable, Sendable {
        public var version = "pc-change-1"
        public init() {}
    }

    public enum EpisodeState: String, Codable, CaseIterable, Sendable {
        case usualVariation = "usual_variation"
        case transientDeviation = "transient_deviation"
        case recurringEpisode = "recurring_episode"
        case persistentShift = "persistent_shift"
        case insufficientEvidence = "insufficient_evidence"
    }

    /// One descriptive change episode of one series.
    public struct ChangeEpisode: Codable, Equatable, Sendable {
        /// Deterministic from (series, regime, start day, direction, policy) so retries never duplicate it.
        public var id: String
        public var seriesKey: String
        public var regimeKey: String
        public var state: EpisodeState
        /// +1 above the reference, -1 below, 0 when not applicable.
        public var direction: Int
        public var startDay: String
        public var lastDay: String
        public var ongoing: Bool
        public var durationDays: Int
        public var finality: Finality
        public var reasons: [ReasonCode]
        public init(id: String, seriesKey: String, regimeKey: String, state: EpisodeState, direction: Int,
                    startDay: String, lastDay: String, ongoing: Bool, durationDays: Int, finality: Finality,
                    reasons: [ReasonCode]) {
            self.id = id; self.seriesKey = seriesKey; self.regimeKey = regimeKey; self.state = state
            self.direction = direction; self.startDay = startDay; self.lastDay = lastDay; self.ongoing = ongoing
            self.durationDays = durationDays; self.finality = finality; self.reasons = reasons
        }
    }

    /// Multi-signal summary for one day that counts dependence groups, not metrics.
    public struct MultiSignalSummary: Codable, Equatable, Sendable {
        public var day: String
        public var deviatingSeries: [String]
        public var dependenceGroups: [String]
        public var independentGroupCount: Int
        public var reasons: [ReasonCode]
        public init(day: String, deviatingSeries: [String], dependenceGroups: [String], independentGroupCount: Int,
                    reasons: [ReasonCode]) {
            self.day = day; self.deviatingSeries = deviatingSeries; self.dependenceGroups = dependenceGroups
            self.independentGroupCount = independentGroupCount; self.reasons = reasons
        }
    }

    public enum ChangeDetection {

        public static let reasonCodes: [ReasonCode] = []

        /// Episodes over the trailing history plus today, each day scored against references built from strictly
        /// earlier days; regime boundaries split series.
        public static func episodes(today: [DailyValue], history: [DailyValue], frozen: [FrozenReference],
                                    boundaries: [RegimeBoundary], day: String, mode: ProcessingMode,
                                    finality: Finality, policyFingerprint: String, change: ChangeConfig,
                                    reference: ReferenceConfig) -> [ChangeEpisode] {
            []
        }

        /// Multi-signal summary that accounts for shared inputs (`dependence`).
        public static func multiSignal(comparisons: [ReferenceComparison], dependence: [DependenceNote],
                                       day: String, config: ChangeConfig) -> [MultiSignalSummary] {
            []
        }
    }
}
