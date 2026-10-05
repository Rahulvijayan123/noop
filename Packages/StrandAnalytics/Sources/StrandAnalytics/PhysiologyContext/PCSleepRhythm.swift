import Foundation

// PCSleepRhythm.swift — System C: sleep, waking time and daily rhythm (spec §9).
//
// OWNER: sleep & history workstream. SKELETON — signatures are the shared contract.
//
// Sleep/wake evidence is kept apart from stage inference; staging is never a mandatory condition. The server's
// sleep detector confirms sleep with heart rate, so a sleep label is never independent corroboration of a change in
// heart-derived signals (declared in `dependence`).

extension PhysiologyContext {

    public struct SleepConfig: Codable, Equatable, Sendable {
        public var version = "pc-sleep-1"
        public init() {}
    }

    public enum SleepWakeState: String, Codable, CaseIterable, Sendable {
        case asleep, awake, mixed, unknown
    }

    public enum WearEvidenceState: String, Codable, CaseIterable, Sendable {
        case worn
        case notWorn = "not_worn"
        case mixed
        case unknown
    }

    /// Sleep/wake and wear evidence over a support interval, with the sources that produced it.
    public struct SleepWearContext: Codable, Equatable, Sendable {
        public var sleepState: SleepWakeState
        /// e.g. `detected_sleep_session`, `outside_detected_sleep`, `band_sleep_state`.
        public var sleepEvidence: [String]
        public var sleepDependsOnHeartSignals: Bool
        public var wearState: WearEvidenceState
        /// e.g. `wear_events`, `heart_rate_signal_present`.
        public var wearEvidence: [String]
        public var reasons: [ReasonCode]
        public init(sleepState: SleepWakeState, sleepEvidence: [String], sleepDependsOnHeartSignals: Bool,
                    wearState: WearEvidenceState, wearEvidence: [String], reasons: [ReasonCode]) {
            self.sleepState = sleepState; self.sleepEvidence = sleepEvidence
            self.sleepDependsOnHeartSignals = sleepDependsOnHeartSignals; self.wearState = wearState
            self.wearEvidence = wearEvidence; self.reasons = reasons
        }
        public static let unknown = SleepWearContext(sleepState: .unknown, sleepEvidence: [],
                                                     sleepDependsOnHeartSignals: false, wearState: .unknown,
                                                     wearEvidence: [], reasons: [])
    }

    public enum SleepEpisodeKind: String, Codable, CaseIterable, Sendable {
        case mainSleep = "main_sleep"
        case nap
        case unclassified
    }

    /// One sleep episode as known at the document's cutoff.
    public struct SleepEpisode: Codable, Equatable, Sendable {
        public var id: String
        public var interval: Interval
        public var kind: SleepEpisodeKind
        /// Local day that owns the episode (existing rule: the day containing its end).
        public var ownerDay: String
        /// True when the episode had ended (with this end) by the cutoff; a live document never assumes a later end.
        public var complete: Bool
        public var finality: Finality
        public var durationS: Int
        public var reasons: [ReasonCode]
        public init(id: String, interval: Interval, kind: SleepEpisodeKind, ownerDay: String, complete: Bool,
                    finality: Finality, durationS: Int, reasons: [ReasonCode] = []) {
            self.id = id; self.interval = interval; self.kind = kind; self.ownerDay = ownerDay
            self.complete = complete; self.finality = finality; self.durationS = durationS; self.reasons = reasons
        }
    }

    /// Wake-relative timing of an instant.
    public struct WakeReference: Codable, Equatable, Sendable {
        public var secondsSinceWake: Int?
        public var wakeAt: Int?
        public var referenceEpisodeId: String?
        public var referenceKind: SleepEpisodeKind?
        public var reasons: [ReasonCode]
        public init(secondsSinceWake: Int?, wakeAt: Int?, referenceEpisodeId: String?,
                    referenceKind: SleepEpisodeKind?, reasons: [ReasonCode]) {
            self.secondsSinceWake = secondsSinceWake; self.wakeAt = wakeAt
            self.referenceEpisodeId = referenceEpisodeId; self.referenceKind = referenceKind; self.reasons = reasons
        }
        public static func unknown(_ reasons: [ReasonCode]) -> WakeReference {
            WakeReference(secondsSinceWake: nil, wakeAt: nil, referenceEpisodeId: nil, referenceKind: nil,
                          reasons: reasons)
        }
    }

    /// The day's sleep / rhythm product.
    public struct SleepRhythmSummary: Codable, Equatable, Sendable {
        public var episodes: [SleepEpisode]
        public var mainSleepId: String?
        public var reasons: [ReasonCode]
        public var dependence: [DependenceNote]
        public init(episodes: [SleepEpisode], mainSleepId: String?, reasons: [ReasonCode],
                    dependence: [DependenceNote]) {
            self.episodes = episodes; self.mainSleepId = mainSleepId; self.reasons = reasons
            self.dependence = dependence
        }
        public static func unavailable(_ reasons: [ReasonCode]) -> SleepRhythmSummary {
            SleepRhythmSummary(episodes: [], mainSleepId: nil, reasons: reasons, dependence: [])
        }
    }

    public enum SleepRhythm {

        public static let reasonCodes: [ReasonCode] = []

        /// Sleep episodes known by the cutoff (causal) or in full (retrospective), classified main / nap.
        public static func episodes(sessions: [SleepSessionInput], identity: DayIdentity, mode: ProcessingMode,
                                    cutoff: Int, config: SleepConfig) -> [SleepEpisode] {
            []
        }

        /// Sleep/wake and wear evidence over `support`.
        public static func sleepWear(for support: Interval, episodes: [SleepEpisode],
                                     observations: SanitizedObservations, config: SleepConfig) -> SleepWearContext {
            .unknown
        }

        /// Time since the supported awakening that precedes `ts` (never a future awakening in causal mode).
        public static func wakeReference(at ts: Int, episodes: [SleepEpisode], mode: ProcessingMode, cutoff: Int,
                                         config: SleepConfig) -> WakeReference {
            .unknown(["not_implemented"])
        }

        /// The day summary: durations, naps, fragmentation where supported, recent sleep loss, timing change,
        /// rhythm descriptors and dependence notes.
        public static func summary(episodes: [SleepEpisode], priorSleep: [SleepSessionInput], identity: DayIdentity,
                                   observations: SanitizedObservations, mode: ProcessingMode, cutoff: Int,
                                   config: SleepConfig) -> SleepRhythmSummary {
            .unavailable(["not_implemented"])
        }
    }
}
