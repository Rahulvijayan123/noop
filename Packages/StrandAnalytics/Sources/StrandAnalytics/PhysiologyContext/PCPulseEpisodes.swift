import Foundation

// PCPulseEpisodes.swift — sustained high / low pulse episodes over QUALIFIED INACTIVE heart rate, and
// heart-rate accelerations that coincide with movement, on one descriptive timeline (docs/spec-02/CONTRACT.md §6).
//
// OWNER: cardiac/PRV workstream (spec-02). Contract types are lead-owned; the detector body is the owner's.
//
// Descriptive only. A sustained high or low pulse is not a tachycardia/bradycardia diagnosis, and none of this is a
// rhythm classification (AF/PAC/PVC stay with the rhythm models). An acceleration with movement carries no cause:
// it is not attributed to respiration, arousal or autonomic disease. Qualification is heart-rate independent: the
// HR-independent motion track (HART epochs or strap motion) decides "inactive", never a decoder label that reads HR.
extension PhysiologyContext {

    /// Thresholds of the pulse-episode detector. Every field enters `Policy.fingerprint`.
    public struct PulseEpisodeConfig: Codable, Equatable, Sendable {
        public var version = "pc-pulse-1"
        /// A high episode enters at or above this HR and exits below `highExitBpm` (hysteresis).
        public var highEnterBpm = 100.0
        public var highExitBpm = 95.0
        /// A low episode enters at or below this HR and exits above `lowExitBpm`.
        public var lowEnterBpm = 40.0
        public var lowExitBpm = 43.0
        /// Shortest episode reported (qualified seconds inside the episode).
        public var minDurationS = 600
        /// The exit condition must hold this long before an episode ends.
        public var exitHoldS = 60
        /// A longer gap between HR samples ends (censors) an episode; it is never bridged.
        public var maxGapS = 30
        /// Acceleration: rise of at least this much over the preceding still baseline …
        public var accelerationRiseBpm = 10.0
        /// … whose baseline is the median HR of this many qualified still seconds …
        public var accelerationBaselineS = 60
        /// … reached within this many seconds of the rise onset …
        public var accelerationRiseWithinS = 15
        /// … with an HR-independent movement onset within this many seconds of the rise onset.
        public var accelerationMovementWindowS = 15
        /// Rates per hour need at least this much qualified exposure in the context.
        public var minQualifiedExposureS = 3600
        public init() {}
    }

    /// One sustained high or low pulse episode.
    public struct PulseEpisode: Codable, Equatable, Sendable {
        /// Deterministic from (kind, start).
        public var id: String
        /// `sustained_high` | `sustained_low`.
        public var kind: String
        public var interval: Interval
        public var durationS: Int
        public var medianBpm: Double?
        /// Highest HR of a high episode, lowest of a low one.
        public var extremeBpm: Double?
        /// Qualified inactive seconds with HR inside the episode.
        public var qualifiedS: Int
        /// `asleep` | `awake` | `mixed` | `unknown` (sleep evidence is HR-dependent; see `reasons`).
        public var context: String
        /// Why the start or end is not a complete observation (`episode_censored_gap`,
        /// `episode_censored_qualification`, `cutoff_reached`).
        public var censoring: [ReasonCode]
        public var reasons: [ReasonCode]
        public init(id: String, kind: String, interval: Interval, durationS: Int, medianBpm: Double?,
                    extremeBpm: Double?, qualifiedS: Int, context: String, censoring: [ReasonCode],
                    reasons: [ReasonCode]) {
            self.id = id; self.kind = kind; self.interval = interval; self.durationS = durationS
            self.medianBpm = medianBpm; self.extremeBpm = extremeBpm; self.qualifiedS = qualifiedS
            self.context = context; self.censoring = censoring; self.reasons = reasons
        }
    }

    /// A heart-rate acceleration from a still baseline that coincides with HR-independent movement.
    public struct HeartRateAccelerationEvent: Codable, Equatable, Sendable {
        /// Rise onset (unix seconds).
        public var ts: Int
        public var baselineBpm: Double
        public var peakBpm: Double
        public var riseBpm: Double
        /// Seconds from the rise onset to the peak.
        public var riseS: Int
        /// Movement onset relative to the rise onset (signed seconds).
        public var movementOffsetS: Int
        /// `asleep` | `awake` | `unknown`.
        public var context: String
        public init(ts: Int, baselineBpm: Double, peakBpm: Double, riseBpm: Double, riseS: Int,
                    movementOffsetS: Int, context: String) {
            self.ts = ts; self.baselineBpm = baselineBpm; self.peakBpm = peakBpm; self.riseBpm = riseBpm
            self.riseS = riseS; self.movementOffsetS = movementOffsetS; self.context = context
        }
    }

    /// The day's pulse-episode timeline with its exposure. Counts are only meaningful with exposure:
    /// `nil` counts mean "not evaluated", `0` means "evaluated, none found".
    public struct PulseEpisodeSummary: Codable, Equatable, Sendable {
        public var version: String
        public var state: AvailabilityState
        /// The thresholds the run used (`high_enter_bpm`, `min_duration_s`, …).
        public var thresholds: [Diagnostic]
        /// Qualified inactive seconds with HR (the exposure every count divides by), split by context.
        public var qualifiedInactiveS: Int
        public var qualifiedAsleepS: Int
        public var qualifiedAwakeS: Int
        public var episodes: [PulseEpisode]
        public var highEpisodeCount: Int?
        public var lowEpisodeCount: Int?
        public var highEpisodeS: Int?
        public var lowEpisodeS: Int?
        public var accelerationEvents: [HeartRateAccelerationEvent]
        public var accelerationEventsPerAsleepHour: Double?
        public var accelerationEventsPerAwakeHour: Double?
        /// Always carries `not_rhythm_classification` and `cause_not_attributed`.
        public var reasons: [ReasonCode]
        public init(version: String, state: AvailabilityState, thresholds: [Diagnostic], qualifiedInactiveS: Int,
                    qualifiedAsleepS: Int, qualifiedAwakeS: Int, episodes: [PulseEpisode],
                    highEpisodeCount: Int?, lowEpisodeCount: Int?, highEpisodeS: Int?, lowEpisodeS: Int?,
                    accelerationEvents: [HeartRateAccelerationEvent], accelerationEventsPerAsleepHour: Double?,
                    accelerationEventsPerAwakeHour: Double?, reasons: [ReasonCode]) {
            self.version = version; self.state = state; self.thresholds = thresholds
            self.qualifiedInactiveS = qualifiedInactiveS; self.qualifiedAsleepS = qualifiedAsleepS
            self.qualifiedAwakeS = qualifiedAwakeS; self.episodes = episodes
            self.highEpisodeCount = highEpisodeCount; self.lowEpisodeCount = lowEpisodeCount
            self.highEpisodeS = highEpisodeS; self.lowEpisodeS = lowEpisodeS
            self.accelerationEvents = accelerationEvents
            self.accelerationEventsPerAsleepHour = accelerationEventsPerAsleepHour
            self.accelerationEventsPerAwakeHour = accelerationEventsPerAwakeHour
            self.reasons = reasons
        }
    }

    public enum PulseEpisodes {
        public static let version = "pc-pulse-1"

        // Reserved reason codes (docs/spec-02/CONTRACT.md §6). The owner adds any further codes here and to
        // `reasonCodes`; the app maps every one (PhysiologyContextWordingCoverageTests).
        public static let pulseEpisodeHigh: ReasonCode = "pulse_episode_high"
        public static let pulseEpisodeLow: ReasonCode = "pulse_episode_low"
        public static let hrAccelerationWithMovement: ReasonCode = "hr_acceleration_with_movement"
        public static let episodeCensoredGap: ReasonCode = "episode_censored_gap"
        public static let episodeCensoredQualification: ReasonCode = "episode_censored_qualification"
        public static let qualifiedInactiveHrInsufficient: ReasonCode = "qualified_inactive_hr_insufficient"
        public static let causeNotAttributed: ReasonCode = "cause_not_attributed"
        public static let notRhythmClassification: ReasonCode = "not_rhythm_classification"

        public static let reasonCodes: [ReasonCode] = [
            pulseEpisodeHigh, pulseEpisodeLow, hrAccelerationWithMovement, episodeCensoredGap,
            episodeCensoredQualification, qualifiedInactiveHrInsufficient, causeNotAttributed,
            notRhythmClassification,
        ]

        /// The day's pulse-episode summary over qualified inactive HR. Contract skeleton: not evaluated yet (nil),
        /// so documents omit the key. The owner replaces this body.
        static func summarize(identity: DayIdentity, observations: SanitizedObservations, hart: ResolvedTrack,
                              strap: ResolvedTrack, episodes: [SleepEpisode], bouts: [ExertionBout],
                              mode: ProcessingMode, cutoff: Int, config: PulseEpisodeConfig) -> PulseEpisodeSummary? {
            nil
        }
    }
}
