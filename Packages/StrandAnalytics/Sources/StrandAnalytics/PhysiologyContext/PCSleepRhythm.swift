import Foundation

// PCSleepRhythm.swift — System C: sleep, waking time and daily rhythm (spec §9).
//
// OWNER: sleep & history workstream. Behaviour, defaults and reason codes: docs/physiology-context/notes/sleep.md.
//
// Sleep/wake evidence is kept apart from stage inference; staging is never a mandatory condition. The server's
// sleep detector is a gravity-stillness spine CONFIRMED WITH HEART RATE (SleepStager.confirmSleepWithHR /
// detectSleep; HR-only sessions exist), and the V2 stager reads HR, HRV and RSA respiration. A sleep label is
// therefore never independent corroboration of a change in heart-derived signals (declared in `dependence`).
//
// Rules in one place:
//   * Episodes come from published sessions. In causal mode a session record is used only if it was available by
//     the cutoff (unknown availability falls back to the session END: a record that carries an end cannot exist
//     before it). A session ending within `completionMarginS` of the cutoff is incomplete: its end is not an
//     awakening and nothing after it is presumed awake. No future end is ever invented.
//   * Ownership: the local day (identity zone) containing the session end (AnalyticsEngine.analyzeDay).
//   * Main sleep vs nap: the scorer's `isNap == true` is honored; otherwise the app's own main-night rule
//     (`SleepStageTotals.mainNightGroupIndices`: bridged groups, learned-timing score) picks the main group per
//     owner day and everything else that day is a nap. A main group with several fragments is split sleep.
//   * Asleep needs a detected episode (or the band's own sleep state). Awake needs POSITIVE evidence: the detector
//     had heart-rate data over the time, could already have reported a sleep there, and reported none. Quiet motion
//     never establishes asleep, awake or worn.
//   * Rhythm descriptors are proxies; endogenous circadian phase is never claimed (inputs are HR and behaviour).

extension PhysiologyContext {

    public struct SleepConfig: Codable, Equatable, Sendable {
        public var version = "pc-sleep-1"
        /// A session whose end is within this many seconds of the cutoff is incomplete. The detector places an end
        /// only after its 15-min centered stillness window and 15-min run merge have seen post-end data
        /// (`SleepStager.stillWindowMin`, `mergeMin`), so a younger end can still move.
        public var completionMarginS = 1800
        /// A complete episode whose end is younger than this at the cutoff can still be extended by a re-onset the
        /// detector bridges (`SleepStager.nightContinuationGapMin` / `sparseBridgeGapMin`, 90 min). Flagged
        /// (`detector_may_extend`), not hidden: the awakening is the one known at the cutoff.
        public var detectorExtensionHorizonS = 5400
        /// The frwhoop-server-1 scorer publishes `is_nap: false` for every session (worker `legacyNights`), so a
        /// `false` carries no information and the main-night rule decides. `true` is always honored.
        public var honorScorerNapFalse = false
        /// Retrospective episodes are final once the cutoff is this long after their owner day ends (mirrors
        /// `JoinConfig.finalAfterDayEndS`).
        public var finalAfterDayEndS = 30 * 3600
        /// Share of the support a sleep/wake state must hold.
        public var stateMinShare = 0.9
        /// Two states each holding at least this share of the support make it `mixed`.
        public var mixedFloorShare = 0.1
        /// Heart-rate coverage of the time outside detected sleep needed before "no session here" counts as awake
        /// (the detector cannot confirm sleep without heart rate).
        public var detectorCoverageMinShare = 0.8
        /// Presence bin width in seconds (coverage, band state, wear).
        public var coverageBinS = 60
        /// Time before the end of the heart-rate data in which the absence of a session is not evidence of wake:
        /// the detector reports a run only once it exceeds 60 min (`SleepStager.minSleepMin`), plus 30 min of
        /// scoring latency.
        public var awakeEvidenceLagS = 5400
        /// Longest span the detector reports (`SleepStager.maxMainSleepSpanS`).
        public var sessionSpanCapS = 16 * 3600
        /// Share of the support with wear evidence needed for `worn` / `not_worn`.
        public var wearMinShare = 0.8
        /// Oldest awakening used as a wake reference (an older one would assume no undetected sleep since).
        public var wakeReferenceMaxAgeS = 24 * 3600
        /// Prior nights (local days) considered for sleep loss, timing change and regularity.
        public var priorNights = 14
        /// Minimum prior nights with a complete main sleep before loss / change / regularity are reported.
        public var minPriorNights = 5
        /// A midpoint and wake shift of at least this size, within tolerance of whole hours and of each other,
        /// looks like a zone change the input cannot verify.
        public var timezoneShiftMinS = 3600
        public var timezoneShiftToleranceS = 600
        /// Minimum heart-rate samples in each of sleep and wake for the day/night contrast proxy.
        public var rhythmMinSamples = 1800
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
    public struct SleepWearContext: Codable, Equatable, Sendable, Hashable {
        public var sleepState: SleepWakeState
        /// e.g. `detected_sleep_session`, `outside_detected_sleep`, `band_sleep_state`.
        public var sleepEvidence: [String]
        public var sleepDependsOnHeartSignals: Bool
        public var wearState: WearEvidenceState
        /// e.g. `wear_events`, `heart_rate_signal_present`.
        public var wearEvidence: [String]
        public var reasons: [ReasonCode]
        /// True when wear evidence came (partly) from the presence of a heart-rate signal.
        public var wearDependsOnHeartSignals: Bool
        /// Shares of the support behind the states (`asleep_share`, `awake_share`, `worn_share`, ...).
        public var diagnostics: [Diagnostic]
        public init(sleepState: SleepWakeState, sleepEvidence: [String], sleepDependsOnHeartSignals: Bool,
                    wearState: WearEvidenceState, wearEvidence: [String], reasons: [ReasonCode],
                    wearDependsOnHeartSignals: Bool = false, diagnostics: [Diagnostic] = []) {
            self.sleepState = sleepState; self.sleepEvidence = sleepEvidence
            self.sleepDependsOnHeartSignals = sleepDependsOnHeartSignals; self.wearState = wearState
            self.wearEvidence = wearEvidence; self.reasons = reasons
            self.wearDependsOnHeartSignals = wearDependsOnHeartSignals; self.diagnostics = diagnostics
        }
        public static let unknown = SleepWearContext(sleepState: .unknown, sleepEvidence: [],
                                                     sleepDependsOnHeartSignals: false, wearState: .unknown,
                                                     wearEvidence: [], reasons: [])
    }

    public enum SleepEpisodeKind: String, Codable, CaseIterable, Sendable {
        case mainSleep = "main_sleep"
        case nap
        /// Reserved: every episode the system builds is classified (provisionally when the day is open).
        case unclassified
    }

    /// Stage-derived (unverified) composition of one episode. Auxiliary only; never a mandatory condition.
    public struct SleepStageSummary: Codable, Equatable, Sendable {
        /// Seconds staged light / deep / rem inside the episode.
        public var asleepS: Int
        /// Seconds staged wake inside the episode.
        public var wakeS: Int
        /// Wake runs with sleep on both sides (wake after sleep onset).
        public var wakeSegments: Int
        /// Seconds covered by any stage span.
        public var stagedS: Int
        /// Always `stage_derived_unverified`.
        public var basis: String
        public init(asleepS: Int, wakeS: Int, wakeSegments: Int, stagedS: Int, basis: String) {
            self.asleepS = asleepS; self.wakeS = wakeS; self.wakeSegments = wakeSegments; self.stagedS = stagedS
            self.basis = basis
        }
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
        /// Shared by the fragments of one split main sleep (`split:<first fragment id>`).
        public var splitGroupId: String?
        /// `scorer_is_nap` or `main_night_group_rule`.
        public var classificationBasis: String
        /// Zone `ownerDay` was computed in.
        public var ownerTimezoneId: String?
        /// Local day whose snapshot published the session, when known.
        public var sourceDay: String?
        /// Availability of the record used (falls back to the session end when unknown).
        public var availableAt: Int?
        public var detector: String?
        public var hrOnly: Bool?
        /// The end is recent enough that a re-onset could still extend it.
        public var detectorMayExtend: Bool
        public var stages: SleepStageSummary?

        public init(id: String, interval: Interval, kind: SleepEpisodeKind, ownerDay: String, complete: Bool,
                    finality: Finality, durationS: Int, reasons: [ReasonCode] = [], splitGroupId: String? = nil,
                    classificationBasis: String = "unspecified", ownerTimezoneId: String? = nil,
                    sourceDay: String? = nil, availableAt: Int? = nil, detector: String? = nil,
                    hrOnly: Bool? = nil, detectorMayExtend: Bool = false, stages: SleepStageSummary? = nil) {
            self.id = id; self.interval = interval; self.kind = kind; self.ownerDay = ownerDay
            self.complete = complete; self.finality = finality; self.durationS = durationS; self.reasons = reasons
            self.splitGroupId = splitGroupId; self.classificationBasis = classificationBasis
            self.ownerTimezoneId = ownerTimezoneId; self.sourceDay = sourceDay; self.availableAt = availableAt
            self.detector = detector; self.hrOnly = hrOnly; self.detectorMayExtend = detectorMayExtend
            self.stages = stages
        }
    }

    /// Wake-relative timing of an instant. Seconds are real elapsed UTC seconds (DST-safe).
    public struct WakeReference: Codable, Equatable, Sendable, Hashable {
        public var secondsSinceWake: Int?
        public var wakeAt: Int?
        public var referenceEpisodeId: String?
        public var referenceKind: SleepEpisodeKind?
        public var reasons: [ReasonCode]
        /// End of a nap that ended after the reference main sleep, when there was one.
        public var latestNapEndAt: Int?
        public init(secondsSinceWake: Int?, wakeAt: Int?, referenceEpisodeId: String?,
                    referenceKind: SleepEpisodeKind?, reasons: [ReasonCode], latestNapEndAt: Int? = nil) {
            self.secondsSinceWake = secondsSinceWake; self.wakeAt = wakeAt
            self.referenceEpisodeId = referenceEpisodeId; self.referenceKind = referenceKind; self.reasons = reasons
            self.latestNapEndAt = latestNapEndAt
        }
        public static func unknown(_ reasons: [ReasonCode]) -> WakeReference {
            WakeReference(secondsSinceWake: nil, wakeAt: nil, referenceEpisodeId: nil, referenceKind: nil,
                          reasons: reasons)
        }
    }

    /// Whether a derived sleep feature could be determined.
    public enum SleepFeatureState: String, Codable, CaseIterable, Sendable {
        case available
        case unknown
    }

    /// The day's main sleep (all fragments of the main group).
    public struct MainSleepSummary: Codable, Equatable, Sendable {
        public var episodeIds: [String]
        /// First fragment start to last fragment end (known part when incomplete).
        public var span: Interval
        /// Sum of the fragments' detected durations (gaps between fragments excluded).
        public var durationS: Int
        public var complete: Bool
        public var splitGroupId: String?
        /// Detector-derived awake time between fragments.
        public var fragmentGapS: Int
        /// Auxiliary, stage-derived (unverified) asleep seconds; nil without stages.
        public var stageAsleepS: Int?
        public var reasons: [ReasonCode]
        public init(episodeIds: [String], span: Interval, durationS: Int, complete: Bool, splitGroupId: String?,
                    fragmentGapS: Int, stageAsleepS: Int?, reasons: [ReasonCode]) {
            self.episodeIds = episodeIds; self.span = span; self.durationS = durationS; self.complete = complete
            self.splitGroupId = splitGroupId; self.fragmentGapS = fragmentGapS; self.stageAsleepS = stageAsleepS
            self.reasons = reasons
        }
    }

    public struct NapSummary: Codable, Equatable, Sendable {
        public var count: Int
        public var totalS: Int
        public var episodeIds: [String]
        public init(count: Int, totalS: Int, episodeIds: [String]) {
            self.count = count; self.totalS = totalS; self.episodeIds = episodeIds
        }
        public static let none = NapSummary(count: 0, totalS: 0, episodeIds: [])
    }

    /// Wake inside the main sleep from the (unverified) stager. Present only when stages exist.
    public struct SleepFragmentation: Codable, Equatable, Sendable {
        public var basis: String
        public var wakeSegments: Int
        public var wakeS: Int
        public var stagedS: Int
        /// Staged seconds / main-sleep duration.
        public var stagedShare: Double
        public var reasons: [ReasonCode]
        public init(basis: String, wakeSegments: Int, wakeS: Int, stagedS: Int, stagedShare: Double,
                    reasons: [ReasonCode]) {
            self.basis = basis; self.wakeSegments = wakeSegments; self.wakeS = wakeS; self.stagedS = stagedS
            self.stagedShare = stagedShare; self.reasons = reasons
        }
    }

    /// Main-sleep duration vs the median of prior nights' main-sleep durations.
    public struct SleepLossSummary: Codable, Equatable, Sendable {
        public var state: SleepFeatureState
        public var currentS: Int?
        public var priorMedianS: Int?
        /// `currentS - priorMedianS` (negative = shorter than usual).
        public var differenceS: Int?
        /// `max(0, priorMedianS - currentS)`.
        public var lossS: Int?
        /// Prior nights with a complete main sleep in the window (independent units: nights).
        public var supportNights: Int
        public var priorDays: [String]
        public var reasons: [ReasonCode]
        public init(state: SleepFeatureState, currentS: Int?, priorMedianS: Int?, differenceS: Int?, lossS: Int?,
                    supportNights: Int, priorDays: [String], reasons: [ReasonCode]) {
            self.state = state; self.currentS = currentS; self.priorMedianS = priorMedianS
            self.differenceS = differenceS; self.lossS = lossS; self.supportNights = supportNights
            self.priorDays = priorDays; self.reasons = reasons
        }
        public static func unknown(_ reasons: [ReasonCode]) -> SleepLossSummary {
            SleepLossSummary(state: .unknown, currentS: nil, priorMedianS: nil, differenceS: nil, lossS: nil,
                             supportNights: 0, priorDays: [], reasons: reasons)
        }
    }

    /// Local clock timing of the main sleep (explicit zone and offset) and its change vs prior nights.
    public struct SleepTimingSummary: Codable, Equatable, Sendable {
        public var state: SleepFeatureState
        public var onset: LocalTimeRef?
        /// Nil until the main sleep is complete (a midpoint depends on the end).
        public var midpoint: LocalTimeRef?
        public var wake: LocalTimeRef?
        /// Circular median of prior midpoints, seconds of local day (in the document's zone).
        public var priorMedianMidpointS: Int?
        /// Signed circular change of today's midpoint vs that median, seconds (positive = later).
        public var midpointChangeS: Int?
        public var priorMedianWakeS: Int?
        public var wakeChangeS: Int?
        /// Circular standard deviation of prior midpoints (simple regularity descriptor), seconds.
        public var priorMidpointSdS: Int?
        public var supportNights: Int
        /// False when the change may be a zone change the input cannot verify.
        public var changeVerifiable: Bool
        public var reasons: [ReasonCode]
        public init(state: SleepFeatureState, onset: LocalTimeRef?, midpoint: LocalTimeRef?, wake: LocalTimeRef?,
                    priorMedianMidpointS: Int?, midpointChangeS: Int?, priorMedianWakeS: Int?, wakeChangeS: Int?,
                    priorMidpointSdS: Int?, supportNights: Int, changeVerifiable: Bool, reasons: [ReasonCode]) {
            self.state = state; self.onset = onset; self.midpoint = midpoint; self.wake = wake
            self.priorMedianMidpointS = priorMedianMidpointS; self.midpointChangeS = midpointChangeS
            self.priorMedianWakeS = priorMedianWakeS; self.wakeChangeS = wakeChangeS
            self.priorMidpointSdS = priorMidpointSdS; self.supportNights = supportNights
            self.changeVerifiable = changeVerifiable; self.reasons = reasons
        }
        public static func unknown(_ reasons: [ReasonCode]) -> SleepTimingSummary {
            SleepTimingSummary(state: .unknown, onset: nil, midpoint: nil, wake: nil, priorMedianMidpointS: nil,
                               midpointChangeS: nil, priorMedianWakeS: nil, wakeChangeS: nil,
                               priorMidpointSdS: nil, supportNights: 0, changeVerifiable: false, reasons: reasons)
        }
    }

    /// A simple rhythm descriptor. Always a proxy: masked by activity, posture and sleep, never endogenous phase.
    public struct RhythmDescriptor: Codable, Equatable, Sendable {
        /// e.g. `proxy_hr_day_night_contrast`.
        public var name: String
        public var value: Double?
        public var units: String
        public var isProxy: Bool
        public var dependsOnHeartSignals: Bool
        public var sampleCount: Int
        public var reasons: [ReasonCode]
        public init(name: String, value: Double?, units: String, isProxy: Bool, dependsOnHeartSignals: Bool,
                    sampleCount: Int, reasons: [ReasonCode]) {
            self.name = name; self.value = value; self.units = units; self.isProxy = isProxy
            self.dependsOnHeartSignals = dependsOnHeartSignals; self.sampleCount = sampleCount; self.reasons = reasons
        }
    }

    /// Circadian phase. The inputs (hourly/1 Hz HR, behaviour) cannot measure endogenous phase or a core-temperature
    /// minimum, so this is always `unavailable`; it never blocks the rest of the summary.
    public struct RhythmPhaseEstimate: Codable, Equatable, Sendable {
        public var state: String
        public var quantity: String
        public var reasons: [ReasonCode]
        public init(state: String, quantity: String, reasons: [ReasonCode]) {
            self.state = state; self.quantity = quantity; self.reasons = reasons
        }
        public static let unavailable = RhythmPhaseEstimate(state: "unavailable",
                                                            quantity: "endogenous_circadian_phase",
                                                            reasons: ["endogenous_phase_unmeasured"])
    }

    /// The day's sleep / rhythm product.
    public struct SleepRhythmSummary: Codable, Equatable, Sendable {
        public var episodes: [SleepEpisode]
        public var mainSleepId: String?
        public var reasons: [ReasonCode]
        public var dependence: [DependenceNote]
        public var mainSleep: MainSleepSummary?
        public var naps: NapSummary
        /// Main sleep + naps owned by the day; nil when the day has no episode (missing is not zero).
        public var totalSleepS: Int?
        public var fragmentation: SleepFragmentation?
        public var sleepLoss: SleepLossSummary
        public var timing: SleepTimingSummary
        public var rhythm: [RhythmDescriptor]
        public var phase: RhythmPhaseEstimate
        public var finality: Finality
        public init(episodes: [SleepEpisode], mainSleepId: String?, reasons: [ReasonCode],
                    dependence: [DependenceNote], mainSleep: MainSleepSummary? = nil, naps: NapSummary = .none,
                    totalSleepS: Int? = nil, fragmentation: SleepFragmentation? = nil,
                    sleepLoss: SleepLossSummary = .unknown([]), timing: SleepTimingSummary = .unknown([]),
                    rhythm: [RhythmDescriptor] = [], phase: RhythmPhaseEstimate = .unavailable,
                    finality: Finality = .provisional) {
            self.episodes = episodes; self.mainSleepId = mainSleepId; self.reasons = reasons
            self.dependence = dependence; self.mainSleep = mainSleep; self.naps = naps
            self.totalSleepS = totalSleepS; self.fragmentation = fragmentation; self.sleepLoss = sleepLoss
            self.timing = timing; self.rhythm = rhythm; self.phase = phase; self.finality = finality
        }
        public static func unavailable(_ reasons: [ReasonCode]) -> SleepRhythmSummary {
            SleepRhythmSummary(episodes: [], mainSleepId: nil, reasons: reasons, dependence: [])
        }
    }

    public enum SleepRhythm {

        public static let version = "pc-sleep-1"

        // MARK: Evidence labels and bases
        public static let evidenceDetectedSleep = "detected_sleep_session"
        public static let evidenceOutsideDetectedSleep = "outside_detected_sleep"
        public static let evidenceBandSleepState = "band_sleep_state"
        public static let evidenceWearEvents = "wear_events"
        public static let evidenceHeartRateSignal = "heart_rate_signal_present"
        public static let basisScorerNapFlag = "scorer_is_nap"
        public static let basisMainNightGroupRule = "main_night_group_rule"
        public static let stageBasis = "stage_derived_unverified"
        public static let dayNightContrastName = "proxy_hr_day_night_contrast"

        // MARK: Reason codes — episodes
        public static let sessionRevisionResolved: ReasonCode = "session_revision_resolved"
        public static let overlappingSessionSuperseded: ReasonCode = "overlapping_session_superseded"
        public static let availabilityBasisEnd: ReasonCode = "session_availability_basis_end"
        public static let sessionEndClippedToCutoff: ReasonCode = "session_end_clipped_to_cutoff"
        public static let sessionReachesCutoff: ReasonCode = "session_reaches_cutoff"
        public static let detectorMayExtend: ReasonCode = "detector_may_extend"
        public static let ownerDayProvisional: ReasonCode = "owner_day_provisional"
        public static let sourceDayDiffers: ReasonCode = "source_day_differs_from_owner_day"
        public static let classificationProvisional: ReasonCode = "classification_provisional"
        public static let scorerNapFlag: ReasonCode = "scorer_nap_flag"
        public static let mainNightRuleApplied: ReasonCode = "main_night_rule_applied"
        public static let splitSleep: ReasonCode = "split_sleep"
        public static let hrOnlySession: ReasonCode = "hr_only_session"
        public static let stagesUnverified: ReasonCode = "stages_unverified"
        // MARK: Reason codes — sleep/wear evidence
        public static let invalidSupport: ReasonCode = "invalid_support"
        public static let noDetectorOutput: ReasonCode = "no_detector_output"
        public static let detectorInputMissing: ReasonCode = "detector_input_missing"
        public static let detectorLagWindow: ReasonCode = "detector_lag_window"
        public static let ownerDaysUnread: ReasonCode = "detector_owner_days_unread"
        public static let partiallyInDetectedSleep: ReasonCode = "partially_in_detected_sleep"
        public static let overlapsIncompleteEpisode: ReasonCode = "overlaps_incomplete_episode"
        public static let insideSplitSleepGap: ReasonCode = "inside_split_sleep_gap"
        public static let sleepSourcesDisagree: ReasonCode = "sleep_sources_disagree"
        public static let bandStateInputsUndocumented: ReasonCode = "band_state_inputs_undocumented"
        public static let sleepEvidenceInsufficient: ReasonCode = "sleep_evidence_insufficient"
        public static let noWearEvidence: ReasonCode = "no_wear_evidence"
        public static let wearEvidenceInsufficient: ReasonCode = "wear_evidence_insufficient"
        public static let wearSourcesDisagree: ReasonCode = "wear_sources_disagree"
        public static let wearFromHeartSignal: ReasonCode = "wear_from_heart_signal"
        // MARK: Reason codes — wake reference
        public static let noCompletedSleepBefore: ReasonCode = "no_completed_sleep_before"
        public static let sleepInProgress: ReasonCode = "sleep_in_progress"
        public static let insideSleepEpisode: ReasonCode = "inside_sleep_episode"
        public static let referenceBeyondLookback: ReasonCode = "reference_beyond_lookback"
        public static let napAfterMainWake: ReasonCode = "nap_after_main_wake"
        public static let noMainSleepReference: ReasonCode = "no_main_sleep_reference"
        public static let wakeMayBeRevised: ReasonCode = "wake_may_be_revised"
        public static let referenceTimeAfterCutoff: ReasonCode = "reference_time_after_cutoff"
        // MARK: Reason codes — summary
        public static let noSleepEpisodes: ReasonCode = "no_sleep_episodes"
        public static let noMainSleep: ReasonCode = "no_main_sleep"
        public static let mainSleepIncomplete: ReasonCode = "main_sleep_incomplete"
        public static let priorNightsInsufficient: ReasonCode = "prior_nights_insufficient"
        public static let stagesUnavailable: ReasonCode = "stages_unavailable"
        public static let timezoneHistoryUnknown: ReasonCode = "timezone_history_unknown"
        public static let priorZoneAssumedSame: ReasonCode = "prior_zone_assumed_same"
        public static let utcOffsetChangedInWindow: ReasonCode = "utc_offset_changed_in_window"
        public static let rhythmProxyOnly: ReasonCode = "rhythm_proxy_only"
        public static let labelsReadHeartRate: ReasonCode = "labels_read_heart_rate"
        public static let rhythmSamplesInsufficient: ReasonCode = "rhythm_samples_insufficient"
        public static let endogenousPhaseUnmeasured: ReasonCode = "endogenous_phase_unmeasured"
        // MARK: Reason codes — dependence notes
        public static let sleepLabelsReadHeartSignals: ReasonCode = "sleep_labels_read_heart_signals"
        public static let rhythmProxyReadsHeartRate: ReasonCode = "rhythm_proxy_reads_heart_rate"

        public static let reasonCodes: [ReasonCode] = [
            sessionRevisionResolved, overlappingSessionSuperseded, availabilityBasisEnd, sessionEndClippedToCutoff,
            sessionReachesCutoff, detectorMayExtend, ownerDayProvisional, sourceDayDiffers,
            classificationProvisional, scorerNapFlag, mainNightRuleApplied, splitSleep, hrOnlySession, stagesUnverified,
            invalidSupport, noDetectorOutput, detectorInputMissing, detectorLagWindow, ownerDaysUnread,
            partiallyInDetectedSleep, overlapsIncompleteEpisode, insideSplitSleepGap, sleepSourcesDisagree,
            bandStateInputsUndocumented, sleepEvidenceInsufficient, noWearEvidence, wearEvidenceInsufficient,
            wearSourcesDisagree, wearFromHeartSignal, noCompletedSleepBefore, sleepInProgress, insideSleepEpisode,
            referenceBeyondLookback, napAfterMainWake, noMainSleepReference, wakeMayBeRevised,
            referenceTimeAfterCutoff, noSleepEpisodes, noMainSleep, mainSleepIncomplete, priorNightsInsufficient,
            stagesUnavailable, timezoneHistoryUnknown, priorZoneAssumedSame, utcOffsetChangedInWindow,
            rhythmProxyOnly, labelsReadHeartRate, rhythmSamplesInsufficient, endogenousPhaseUnmeasured,
            sleepLabelsReadHeartSignals, rhythmProxyReadsHeartRate,
        ]

        /// Band sleep state values (`(sb>>4)&3`: 0 wake / 1 still / 2 asleep / 3 up, `SleepStager.bandStateAsleep`).
        /// `still` makes no sleep/wake claim.
        static let bandAsleepStates: Set<Int> = [SleepStager.bandStateAsleep]
        static let bandAwakeStates: Set<Int> = [0, 3]

        // MARK: - Episodes

        /// Sleep episodes known by the cutoff (causal) or in full (retrospective), classified main / nap.
        public static func episodes(sessions: [SleepSessionInput], identity: DayIdentity, mode: ProcessingMode,
                                    cutoff: Int, config: SleepConfig) -> [SleepEpisode] {
            episodes(sessions: sessions, priorSleep: [], identity: identity, mode: mode, cutoff: cutoff,
                     config: config)
        }

        /// As `episodes(sessions:identity:mode:cutoff:config:)`, with earlier nights as classification context:
        /// they feed the learned habitual midsleep (`SleepStageTotals.habitualMidsleepSec`, ≥ 14 days) and the
        /// other sessions of a partly-read owner day. Only episodes of `sessions` are returned.
        public static func episodes(sessions: [SleepSessionInput], priorSleep: [SleepSessionInput],
                                    identity: DayIdentity, mode: ProcessingMode, cutoff: Int,
                                    config: SleepConfig) -> [SleepEpisode] {
            let prior = priorSleep.filter { $0.interval.end <= identity.dayWindow.start }
            let items = sessions.map { ($0, true) } + prior.map { ($0, false) }
            return build(items, identity: identity, mode: mode, cutoff: cutoff, config: config)
                .filter { $0.current }
                .map { $0.episode }
        }

        /// A session record chosen for the episode list.
        struct Resolved {
            var session: SleepSessionInput
            var availability: Int
            var reasons: [ReasonCode]
            var current: Bool
        }

        /// Availability filter, revision resolution by id (latest availability wins), then overlap resolution.
        static func resolve(_ items: [(SleepSessionInput, Bool)], mode: ProcessingMode, cutoff: Int) -> [Resolved] {
            let causal = mode == .causalLive
            var byId: [String: [Resolved]] = [:]
            for (s, current) in items where s.interval.isValid {
                var reasons: [ReasonCode] = []
                let availability: Int
                if let a = s.availableAt {
                    availability = a
                } else {
                    // A record that carries an end cannot have been published before that end.
                    availability = s.interval.end
                    reasons.append(availabilityBasisEnd)
                }
                if causal && (s.interval.start >= cutoff || availability > cutoff) { continue }
                byId[s.id, default: []].append(Resolved(session: s, availability: availability, reasons: reasons,
                                                        current: current))
            }
            var chosen: [Resolved] = []
            for id in byId.keys.sorted() {
                let revisions = byId[id]!
                var best = revisions[0]
                for r in revisions.dropFirst() where ranks(r, above: best) { best = r }
                if revisions.count > 1 { best.reasons.append(sessionRevisionResolved) }
                best.current = revisions.contains { $0.current }
                chosen.append(best)
            }
            // The detector never reports overlapping sleep: overlapping records with different ids are versions of
            // one night (e.g. a refined onset changes the id). The preferred record wins.
            var accepted: [Resolved] = []
            for c in chosen.sorted(by: { ranks($0, above: $1) }) {
                let hit = accepted.firstIndex { $0.session.interval.overlapSeconds(with: c.session.interval) > 0 }
                if let i = hit {
                    if !accepted[i].reasons.contains(overlappingSessionSuperseded) {
                        accepted[i].reasons.append(overlappingSessionSuperseded)
                    }
                    accepted[i].current = accepted[i].current || c.current
                    continue
                }
                accepted.append(c)
            }
            return accepted.sorted { ($0.session.interval, $0.session.id) < ($1.session.interval, $1.session.id) }
        }

        /// Strict, input-order independent preference between two records.
        static func ranks(_ a: Resolved, above b: Resolved) -> Bool {
            if a.availability != b.availability { return a.availability > b.availability }
            if a.session.interval.end != b.session.interval.end {
                return a.session.interval.end > b.session.interval.end
            }
            if a.session.interval.start != b.session.interval.start {
                return a.session.interval.start < b.session.interval.start
            }
            if a.session.id != b.session.id { return a.session.id < b.session.id }
            if a.current != b.current { return a.current }
            return recordFingerprint(a.session) > recordFingerprint(b.session)
        }

        static func recordFingerprint(_ s: SleepSessionInput) -> String {
            PhysiologyContext.fnv1a((try? PhysiologyContext.encoder().encode(s)) ?? Data())
        }

        /// Resolve, build and classify. Returns every accepted episode with whether it came from the day's input.
        static func build(_ items: [(SleepSessionInput, Bool)], identity: DayIdentity, mode: ProcessingMode,
                          cutoff: Int, config: SleepConfig) -> [(episode: SleepEpisode, current: Bool)] {
            let causal = mode == .causalLive
            let tz = identity.timezoneId
            let resolved = resolve(items, mode: mode, cutoff: cutoff)
            var eps: [SleepEpisode] = []
            eps.reserveCapacity(resolved.count)
            for r in resolved {
                let s = r.session
                var iv = s.interval
                var reasons = r.reasons
                var clipped = false
                if causal && iv.end > cutoff {
                    // Available by the cutoff but claiming a later end: only the part before the cutoff is known.
                    iv.end = cutoff
                    clipped = true
                    reasons.append(sessionEndClippedToCutoff)
                }
                let complete = !clipped && iv.end <= cutoff - config.completionMarginS
                if !complete { reasons.append(sessionReachesCutoff); reasons.append(ownerDayProvisional) }
                let mayExtend = complete && cutoff - iv.end < config.detectorExtensionHorizonS
                if mayExtend { reasons.append(detectorMayExtend) }
                let zoneDay = localTime(at: iv.end, timezoneId: tz).localDay
                // Today's sessions are owned in the document's zone (contract); history keeps its own day key.
                let ownerDay = r.current ? zoneDay : (s.sourceDay ?? zoneDay)
                if let sd = s.sourceDay, sd != zoneDay { reasons.append(sourceDayDiffers) }
                if s.hrOnly == true { reasons.append(hrOnlySession) }
                let stages = stageSummary(s.stages, within: iv)
                if stages != nil { reasons.append(stagesUnverified) }
                let ownerWindow = Engine.dayInterval(ownerDay, timezoneId: tz)
                let final = !causal && complete && cutoff >= ownerWindow.end + config.finalAfterDayEndS
                eps.append(SleepEpisode(id: s.id, interval: iv, kind: .unclassified, ownerDay: ownerDay,
                                        complete: complete, finality: final ? .final : .provisional,
                                        durationS: iv.duration, reasons: reasons, ownerTimezoneId: tz,
                                        sourceDay: s.sourceDay, availableAt: r.availability, detector: s.detector,
                                        hrOnly: s.hrOnly, detectorMayExtend: mayExtend, stages: stages))
            }
            let habitual = habitualMidsleep(eps, before: identity.day, timezoneId: tz,
                                            dayWindow: identity.dayWindow)
            classify(&eps, napFlags: resolved.map { $0.session.isNap }, timezoneId: tz, cutoff: cutoff,
                     habitual: habitual, config: config)
            for i in eps.indices { eps[i].reasons = unique(eps[i].reasons) }
            return zip(eps, resolved).map { ($0, $1.current) }
        }

        /// Learned habitual midsleep from complete episodes of earlier owner days (selection independent).
        static func habitualMidsleep(_ eps: [SleepEpisode], before day: String, timezoneId: String,
                                     dayWindow: Interval) -> Int? {
            let blocks = eps.filter { $0.ownerDay < day && $0.complete }.map {
                SleepStageTotals.HistoryBlock(start: $0.interval.start, end: $0.interval.end, dayKey: $0.ownerDay)
            }
            guard !blocks.isEmpty else { return nil }
            let offsetSec = offset(at: dayWindow.start + dayWindow.duration / 2, timezoneId: timezoneId)
            return SleepStageTotals.habitualMidsleepSec(blocks, offsetSec: offsetSec)
        }

        /// Main sleep vs nap per owner day, split groups, provisional classification.
        static func classify(_ eps: inout [SleepEpisode], napFlags: [Bool?], timezoneId tz: String, cutoff: Int,
                             habitual: Int?, config: SleepConfig) {
            let byDay = Dictionary(grouping: eps.indices, by: { eps[$0].ownerDay })
            for day in byDay.keys.sorted() {
                let members = byDay[day]!.sorted { (eps[$0].interval, eps[$0].id) < (eps[$1].interval, eps[$1].id) }
                let window = Engine.dayInterval(day, timezoneId: tz)
                let offsetSec = offset(at: window.start + window.duration / 2, timezoneId: tz)
                var ruled: [Int] = []
                for i in members {
                    switch napFlags[i] {
                    case .some(true):
                        eps[i].kind = .nap
                        eps[i].classificationBasis = basisScorerNapFlag
                        eps[i].reasons.append(scorerNapFlag)
                    case .some(false) where config.honorScorerNapFalse:
                        eps[i].kind = .mainSleep
                        eps[i].classificationBasis = basisScorerNapFlag
                        eps[i].reasons.append(scorerNapFlag)
                    default:
                        ruled.append(i)
                    }
                }
                if !ruled.isEmpty {
                    let blocks = ruled.map { SleepStageTotals.NightBlock(start: eps[$0].interval.start,
                                                                          end: eps[$0].interval.end) }
                    let winners = Set(SleepStageTotals.mainNightGroupIndices(blocks, offsetSec: offsetSec,
                                                                             habitualMidsleepSec: habitual) ?? [])
                    for (k, i) in ruled.enumerated() {
                        eps[i].kind = winners.contains(k) ? .mainSleep : .nap
                        eps[i].classificationBasis = basisMainNightGroupRule
                        eps[i].reasons.append(mainNightRuleApplied)
                    }
                }
                // Split sleep: main fragments the app's two-tier bridge folds into one night.
                let mains = members.filter { eps[$0].kind == .mainSleep }
                let groups = SleepStageTotals.bridgedNightGroups(
                    mains.map { SleepStageTotals.NightBlock(start: eps[$0].interval.start, end: eps[$0].interval.end) },
                    offsetSec: offsetSec)
                for g in groups where g.indices.count >= 2 {
                    let ids = g.indices.map { mains[$0] }
                    let groupId = "split:\(eps[ids[0]].id)"
                    for i in ids {
                        eps[i].splitGroupId = groupId
                        eps[i].reasons.append(splitSleep)
                    }
                }
                // More sessions may still end on an open day; an incomplete member can still change length.
                if cutoff < window.end || members.contains(where: { !eps[$0].complete }) {
                    for i in members { eps[i].reasons.append(classificationProvisional) }
                }
            }
        }

        /// Stage composition inside `iv` (spans clipped to it). Nil when no stage overlaps.
        static func stageSummary(_ stages: [StageSpan], within iv: Interval) -> SleepStageSummary? {
            let clipped = stages.compactMap { s -> (Interval, String)? in
                guard let x = s.interval.intersection(iv) else { return nil }
                return (x, s.stage.lowercased())
            }.sorted { $0.0 < $1.0 }
            guard !clipped.isEmpty else { return nil }
            var asleep = 0, wake = 0, staged = 0, segments = 0
            var seenSleep = false, pendingWake = false
            for (x, stage) in clipped {
                staged += x.duration
                if stage == "wake" || stage == "awake" {
                    wake += x.duration
                    if seenSleep { pendingWake = true }
                } else if stage == "light" || stage == "deep" || stage == "rem" {
                    asleep += x.duration
                    if pendingWake { segments += 1 }
                    pendingWake = false
                    seenSleep = true
                }
            }
            return SleepStageSummary(asleepS: asleep, wakeS: wake, wakeSegments: segments, stagedS: staged,
                                     basis: stageBasis)
        }

        // MARK: - Sleep / wear evidence

        /// Sleep/wake and wear evidence over `support`.
        ///
        /// `observations` must be sorted by `ts` (the sanitized streams are). Asleep comes from detected episodes
        /// (or the band's own sleep state); awake only from positive evidence; wear from wear events and the
        /// presence of a heart-rate signal. Quiet motion is never evidence of either.
        public static func sleepWear(for support: Interval, episodes: [SleepEpisode],
                                     observations: SanitizedObservations, config: SleepConfig) -> SleepWearContext {
            guard support.isValid else {
                return SleepWearContext(sleepState: .unknown, sleepEvidence: [], sleepDependsOnHeartSignals: false,
                                        wearState: .unknown, wearEvidence: [], reasons: [invalidSupport])
            }
            let binS = max(1, config.coverageBinS)
            let nBins = (support.duration + binS - 1) / binS
            func bin(_ k: Int) -> Interval {
                Interval(support.start + k * binS, min(support.end, support.start + (k + 1) * binS))
            }
            func binIndex(_ ts: Int) -> Int { min(nBins - 1, max(0, (ts - support.start) / binS)) }

            // Presence per bin.
            var hrBin = [Bool](repeating: false, count: nBins)
            for s in samples(observations.heartRate, in: support, ts: { $0.ts }) { hrBin[binIndex(s.ts)] = true }
            var dataBin = hrBin
            for s in samples(observations.motion, in: support, ts: { $0.ts }) { dataBin[binIndex(s.ts)] = true }
            var bandAsleep = [Bool](repeating: false, count: nBins)
            var bandAwake = [Bool](repeating: false, count: nBins)
            let band = samples(observations.bandSleepStates, in: support, ts: { $0.ts })
            for s in band {
                if bandAsleepStates.contains(s.state) { bandAsleep[binIndex(s.ts)] = true }
                if bandAwakeStates.contains(s.state) { bandAwake[binIndex(s.ts)] = true }
            }

            // Detected sleep inside the support.
            let overlapping = episodes.filter { $0.interval.overlapSeconds(with: support) > 0 }
            let sleepUnion = merged(overlapping.compactMap { $0.interval.intersection(support) })
            // Time after an incomplete episode's known end is not presumed awake: that end is not an awakening.
            var blockedSpans: [Interval] = []
            for e in episodes where !e.complete && e.interval.end < support.end {
                let lo = max(e.interval.end, support.start)
                if support.end > lo { blockedSpans.append(Interval(lo, support.end)) }
            }
            let blocked = merged(blockedSpans)
            var inside = [Int](repeating: 0, count: nBins)
            var hrOutsideS = 0
            for k in 0..<nBins {
                let b = bin(k)
                inside[k] = sleepUnion.reduce(0) { $0 + $1.overlapSeconds(with: b) }
                if hrBin[k] { hrOutsideS += b.duration - inside[k] }
            }
            let asleepDetS = inside.reduce(0, +)
            let outsideS = support.duration - asleepDetS
            let dur = Double(support.duration)

            var reasons: [ReasonCode] = []
            var detectorReasons: [ReasonCode] = []
            var detectorAwake = false
            if episodes.isEmpty {
                detectorReasons.append(noDetectorOutput)
            } else if outsideS > 0 {
                let coverageOK = Double(hrOutsideS) / Double(outsideS) >= config.detectorCoverageMinShare
                let dataThrough = latestTs(observations.heartRate, ts: { $0.ts }).map { $0 + 1 }
                let latestStart = episodes.map { $0.interval.start }.max() ?? Int.min
                // The detector reports a run only once it exceeds its minimum length; a later known episode shows
                // it already evaluated past this support.
                let lagOK = support.end <= latestStart
                    || (dataThrough.map { support.end <= $0 - config.awakeEvidenceLagS } ?? false)
                let ownerOK = ownerDaysRead(support, episodes: episodes, dataThrough: dataThrough, config: config)
                if !coverageOK { detectorReasons.append(detectorInputMissing) }
                if !lagOK { detectorReasons.append(detectorLagWindow) }
                if !ownerOK { detectorReasons.append(ownerDaysUnread) }
                detectorAwake = coverageOK && lagOK && ownerOK
            }

            var awakeDetS = 0, awakeBandS = 0, asleepBandS = 0, conflictS = 0
            for k in 0..<nBins {
                let b = bin(k)
                let outside = b.duration - inside[k]
                guard outside > 0 else { continue }
                if blocked.contains(where: { $0.overlapSeconds(with: b) > 0 }) { continue }
                let bAsleep = bandAsleep[k] && !bandAwake[k]
                let bAwake = bandAwake[k] && !bandAsleep[k]
                if detectorAwake {
                    if bAsleep { conflictS += outside } else { awakeDetS += outside }
                } else if bAwake {
                    awakeBandS += outside
                } else if bAsleep {
                    asleepBandS += outside
                }
            }
            let asleepShare = Double(asleepDetS + asleepBandS) / dur
            let awakeShare = Double(awakeDetS + awakeBandS) / dur
            let state: SleepWakeState
            if asleepShare >= config.stateMinShare {
                state = .asleep
            } else if awakeShare >= config.stateMinShare {
                state = .awake
            } else if asleepShare >= config.mixedFloorShare && awakeShare >= config.mixedFloorShare {
                state = .mixed
            } else {
                state = .unknown
            }
            var evidence: [String] = []
            if asleepDetS > 0 { evidence.append(evidenceDetectedSleep) }
            if awakeDetS > 0 { evidence.append(evidenceOutsideDetectedSleep) }
            let bandUsed = asleepBandS + awakeBandS + conflictS > 0
            if bandUsed { evidence.append(evidenceBandSleepState); reasons.append(bandStateInputsUndocumented) }
            if conflictS > 0 { reasons.append(sleepSourcesDisagree) }
            if asleepDetS > 0 && Double(asleepDetS) / dur < config.stateMinShare {
                reasons.append(partiallyInDetectedSleep)
            }
            if overlapping.contains(where: { !$0.complete }) || !blocked.isEmpty {
                reasons.append(overlapsIncompleteEpisode)
            }
            if asleepDetS == 0 && inSplitGap(support, episodes: episodes) { reasons.append(insideSplitSleepGap) }
            if state != .asleep { reasons += detectorReasons }
            if state == .unknown && reasons.isEmpty { reasons.append(sleepEvidenceInsufficient) }
            // The detector confirms sleep with heart rate and its "no sleep here" needs heart-rate coverage; the
            // band state's inputs are undocumented, so it is not treated as heart-independent either.
            let sleepDependsOnHeart = asleepDetS > 0 || awakeDetS > 0 || bandUsed

            // Wear.
            let spans = wearSpans(observations.wearEvents, breaks: observations.breaks)
            var wornHrS = 0, wornEventS = 0, notWornS = 0, wearConflictS = 0
            for k in 0..<nBins {
                let b = bin(k)
                let mid = b.start + b.duration / 2
                let eventState = spans.first(where: { $0.interval.contains(mid) })?.state
                if hrBin[k] {
                    wornHrS += b.duration
                    if eventState == .offWrist { wearConflictS += b.duration }
                } else if eventState == .onWrist && dataBin[k] {
                    wornEventS += b.duration
                } else if eventState == .offWrist {
                    notWornS += b.duration
                }
            }
            let wornShare = Double(wornHrS + wornEventS) / dur
            let notWornShare = Double(notWornS) / dur
            let wearState: WearEvidenceState
            if wornShare >= config.wearMinShare {
                wearState = .worn
            } else if notWornShare >= config.wearMinShare {
                wearState = .notWorn
            } else if wornShare >= config.mixedFloorShare && notWornShare >= config.mixedFloorShare {
                wearState = .mixed
            } else {
                wearState = .unknown
            }
            var wearEvidence: [String] = []
            if wornEventS + notWornS > 0 || (wearConflictS > 0) { wearEvidence.append(evidenceWearEvents) }
            if wornHrS > 0 { wearEvidence.append(evidenceHeartRateSignal); reasons.append(wearFromHeartSignal) }
            if wearConflictS > 0 { reasons.append(wearSourcesDisagree) }
            if wearState == .unknown {
                reasons.append(wornHrS + wornEventS + notWornS == 0 ? noWearEvidence : wearEvidenceInsufficient)
            }

            let diagnostics = [
                Diagnostic("asleep_share", asleepShare), Diagnostic("awake_share", awakeShare),
                Diagnostic("detected_sleep_share", Double(asleepDetS) / dur),
                Diagnostic("heart_rate_bin_share", Double(hrBin.filter { $0 }.count) / Double(nBins)),
                Diagnostic("worn_share", wornShare), Diagnostic("not_worn_share", notWornShare),
            ]
            return SleepWearContext(sleepState: state, sleepEvidence: evidence,
                                    sleepDependsOnHeartSignals: sleepDependsOnHeart, wearState: wearState,
                                    wearEvidence: wearEvidence, reasons: unique(reasons).sorted(),
                                    wearDependsOnHeartSignals: wornHrS > 0, diagnostics: diagnostics)
        }

        /// True when every owner day whose snapshot could hold a session covering the support was read.
        ///
        /// A covering session ends after the support starts and, to be published, by the end of the data; it is at
        /// most `sessionSpanCapS` long. When the support ends before the latest known episode ends, a session from a
        /// later owner day would overlap that episode, which the detector never produces, so later days are not
        /// needed. Read days are the owner and source days of the episodes.
        static func ownerDaysRead(_ support: Interval, episodes: [SleepEpisode], dataThrough: Int?,
                                  config: SleepConfig) -> Bool {
            guard let zone = episodes.first?.ownerTimezoneId else { return false }
            var read = Set(episodes.map { $0.ownerDay })
            for e in episodes { if let d = e.sourceDay { read.insert(d) } }
            var upper = support.end - 1 + config.sessionSpanCapS
            if let d = dataThrough { upper = min(upper, d) }
            if let latestEnd = episodes.map({ $0.interval.end }).max(), support.end <= latestEnd {
                upper = min(upper, latestEnd)
            }
            upper = max(upper, support.start + 1)
            var day = localTime(at: support.start + 1, timezoneId: zone).localDay
            let last = localTime(at: upper, timezoneId: zone).localDay
            var steps = 0
            while day <= last && steps < 8 {
                if !read.contains(day) { return false }
                day = shiftDay(day, by: 1, timezoneId: zone)
                steps += 1
            }
            return true
        }

        /// True when the support lies in the gap between two fragments of one split main sleep.
        static func inSplitGap(_ support: Interval, episodes: [SleepEpisode]) -> Bool {
            for e in episodes where e.splitGroupId != nil && e.interval.end <= support.start {
                if episodes.contains(where: { $0.splitGroupId == e.splitGroupId && $0.interval.start >= support.end }) {
                    return true
                }
            }
            return false
        }

        struct WearSpan { var interval: Interval; var state: WearEventState }

        /// Wear state spans: each event holds until the next event, and never across a break.
        static func wearSpans(_ events: [WearEventObservation], breaks: [Interval]) -> [WearSpan] {
            let sorted = events.sorted { ($0.ts, $0.state.rawValue, $0.kind) < ($1.ts, $1.state.rawValue, $1.kind) }
            var out: [WearSpan] = []
            for (i, e) in sorted.enumerated() {
                var end = i + 1 < sorted.count ? sorted[i + 1].ts : Int.max
                for b in breaks where b.start >= e.ts && b.start < end { end = b.start }
                if end > e.ts { out.append(WearSpan(interval: Interval(e.ts, end), state: e.state)) }
            }
            return out
        }

        // MARK: - Wake reference

        /// Time since the supported awakening that precedes `ts` (never a future awakening in causal mode).
        ///
        /// The reference is the end of the most recent COMPLETE main sleep that ended at or before `ts` within
        /// `wakeReferenceMaxAgeS` (a nap when no main sleep qualifies; a later nap is reported alongside). Unknown
        /// while the latest episode is in progress or when `ts` itself lies in sleep. Seconds are real UTC seconds.
        public static func wakeReference(at ts: Int, episodes: [SleepEpisode], mode: ProcessingMode, cutoff: Int,
                                         config: SleepConfig) -> WakeReference {
            let causal = mode == .causalLive
            var reasons: [ReasonCode] = []
            if causal && ts > cutoff { reasons.append(referenceTimeAfterCutoff) }
            let started = episodes.filter { $0.interval.start <= ts && (!causal || $0.interval.start < cutoff) }
            guard let latest = started.max(by: { ($0.interval, $0.id) < ($1.interval, $1.id) }) else {
                return .unknown(reasons + [noCompletedSleepBefore])
            }
            if !latest.complete || (causal && latest.interval.end > cutoff) {
                return .unknown(reasons + [sleepInProgress])
            }
            if latest.interval.contains(ts) { return .unknown(reasons + [insideSleepEpisode]) }
            let ended = started.filter {
                $0.complete && $0.interval.end <= ts && (!causal || $0.interval.end <= cutoff)
            }
            guard let last = ended.max(by: { ($0.interval.end, $0.id) < ($1.interval.end, $1.id) }) else {
                return .unknown(reasons + [noCompletedSleepBefore])
            }
            guard ts - last.interval.end <= config.wakeReferenceMaxAgeS else {
                return .unknown(reasons + [noCompletedSleepBefore, referenceBeyondLookback])
            }
            let mains = ended.filter { $0.kind == .mainSleep && ts - $0.interval.end <= config.wakeReferenceMaxAgeS }
            let reference: SleepEpisode
            var latestNapEnd: Int? = nil
            if let main = mains.max(by: { ($0.interval.end, $0.id) < ($1.interval.end, $1.id) }) {
                reference = main
                if last.kind != .mainSleep && last.interval.end > main.interval.end {
                    reasons.append(napAfterMainWake)
                    latestNapEnd = last.interval.end
                }
            } else {
                reference = last
                reasons.append(noMainSleepReference)
            }
            if reference.detectorMayExtend { reasons.append(wakeMayBeRevised) }
            if let g = reference.splitGroupId,
               episodes.contains(where: { $0.splitGroupId == g && $0.interval.start > ts }) {
                reasons.append(insideSplitSleepGap)
            }
            return WakeReference(secondsSinceWake: ts - reference.interval.end, wakeAt: reference.interval.end,
                                 referenceEpisodeId: reference.id, referenceKind: reference.kind,
                                 reasons: unique(reasons), latestNapEndAt: latestNapEnd)
        }

        // MARK: - Summary

        /// The day summary: durations, naps, fragmentation where supported, recent sleep loss, timing change,
        /// rhythm descriptors and dependence notes.
        public static func summary(episodes: [SleepEpisode], priorSleep: [SleepSessionInput], identity: DayIdentity,
                                   observations: SanitizedObservations, mode: ProcessingMode, cutoff: Int,
                                   config: SleepConfig) -> SleepRhythmSummary {
            let tz = identity.timezoneId
            let causal = mode == .causalLive
            let all = episodes.sorted { ($0.interval, $0.id) < ($1.interval, $1.id) }
            var reasons: [ReasonCode] = []
            if all.isEmpty { reasons.append(noSleepEpisodes) }

            let today = all.filter { $0.ownerDay == identity.day }
            let mains = today.filter { $0.kind == .mainSleep }
            // Durations use complete episodes only: an in-progress nap has no final length yet.
            let naps = today.filter { $0.kind == .nap && $0.complete }
            let main = mainSummary(mains)
            if main == nil { reasons.append(noMainSleep) }
            if let m = main, !m.complete { reasons.append(mainSleepIncomplete) }
            let inProgress = today.contains { !$0.complete }
            if inProgress { reasons.append(sleepInProgress) }
            let mainSleepId = mains.max {
                ($0.durationS, -$0.interval.start) < ($1.durationS, -$1.interval.start)
            }?.id
            let napSummary = NapSummary(count: naps.count, totalS: naps.reduce(0) { $0 + $1.durationS },
                                        episodeIds: naps.map { $0.id })
            let totalSleep: Int? = today.isEmpty || inProgress ? nil : (main?.durationS ?? 0) + napSummary.totalS

            var fragmentation: SleepFragmentation? = nil
            let staged = mains.compactMap { $0.stages }
            if !mains.isEmpty {
                if staged.isEmpty {
                    reasons.append(stagesUnavailable)
                } else {
                    let stagedS = staged.reduce(0) { $0 + $1.stagedS }
                    let durationS = max(1, mains.reduce(0) { $0 + $1.durationS })
                    fragmentation = SleepFragmentation(
                        basis: stageBasis, wakeSegments: staged.reduce(0) { $0 + $1.wakeSegments },
                        wakeS: staged.reduce(0) { $0 + $1.wakeS }, stagedS: stagedS,
                        stagedShare: min(1, Double(stagedS) / Double(durationS)), reasons: [stagesUnverified])
                }
            }

            let prior = priorNights(all, priorSleep: priorSleep, identity: identity, mode: mode, cutoff: cutoff,
                                    config: config)
            let loss = sleepLoss(main, prior: prior.nights, config: config)
            let timing = timingSummary(main, prior: prior, timezoneId: tz, config: config)
            let rhythm = dayNightContrast(mains: mains, all: all, identity: identity, observations: observations,
                                          causal: causal, cutoff: cutoff, config: config)

            var dependence: [DependenceNote] = [
                DependenceNote(group: "sleep_detector",
                               members: ["sleep_wake", "sleep_stages", MetricKind.heartRate.rawValue,
                                         MetricKind.hrvRmssd.rawValue, MetricKind.respiratoryRate.rawValue],
                               note: sleepLabelsReadHeartSignals),
                DependenceNote(group: "wear_heart_signal", members: ["wear_state", MetricKind.heartRate.rawValue],
                               note: wearFromHeartSignal),
            ]
            if !observations.bandSleepStates.isEmpty {
                dependence.append(DependenceNote(group: "band_sleep_state", members: ["sleep_wake", "band_sleep_state"],
                                                 note: bandStateInputsUndocumented))
            }
            if rhythm.value != nil {
                dependence.append(DependenceNote(group: "rhythm_proxy",
                                                 members: [dayNightContrastName, MetricKind.heartRate.rawValue,
                                                           "sleep_wake"],
                                                 note: rhythmProxyReadsHeartRate))
            }

            if timing.reasons.contains(timezoneHistoryUnknown) { reasons.append(timezoneHistoryUnknown) }
            let final = !causal && cutoff >= identity.dayWindow.end + config.finalAfterDayEndS
                && today.allSatisfy { $0.finality == .final }
            return SleepRhythmSummary(
                episodes: all, mainSleepId: mainSleepId, reasons: unique(reasons).sorted(),
                dependence: dependence.sorted { ($0.group, $0.note) < ($1.group, $1.note) }, mainSleep: main,
                naps: napSummary, totalSleepS: totalSleep, fragmentation: fragmentation, sleepLoss: loss,
                timing: timing, rhythm: [rhythm], phase: .unavailable, finality: final ? .final : .provisional)
        }

        static func mainSummary(_ mains: [SleepEpisode]) -> MainSleepSummary? {
            guard let first = mains.first else { return nil }
            let sorted = mains.sorted { ($0.interval, $0.id) < ($1.interval, $1.id) }
            let end = sorted.map { $0.interval.end }.max() ?? first.interval.end
            var gap = 0
            var reach = sorted[0].interval.end
            for e in sorted.dropFirst() {
                if e.interval.start > reach { gap += e.interval.start - reach }
                reach = max(reach, e.interval.end)
            }
            let stages = sorted.compactMap { $0.stages }
            var reasons: [ReasonCode] = []
            if sorted.count > 1 { reasons.append(splitSleep) }
            if !stages.isEmpty { reasons.append(stagesUnverified) }
            return MainSleepSummary(episodeIds: sorted.map { $0.id }, span: Interval(sorted[0].interval.start, end),
                                    durationS: sorted.reduce(0) { $0 + $1.durationS },
                                    complete: sorted.allSatisfy { $0.complete },
                                    splitGroupId: sorted.compactMap { $0.splitGroupId }.first, fragmentGapS: gap,
                                    stageAsleepS: stages.isEmpty ? nil : stages.reduce(0) { $0 + $1.asleepS },
                                    reasons: reasons)
        }

        struct PriorNight { var day: String; var durationS: Int; var span: Interval }
        struct PriorNights { var nights: [PriorNight]; var zoneMismatch: Bool }

        /// Complete main sleeps of the `priorNights` owner days before the document's day, from history and from
        /// the input's own earlier-day episodes. Causal: only records available by the cutoff.
        static func priorNights(_ all: [SleepEpisode], priorSleep: [SleepSessionInput], identity: DayIdentity,
                                mode: ProcessingMode, cutoff: Int, config: SleepConfig) -> PriorNights {
            let firstDay = shiftDay(identity.day, by: -max(1, config.priorNights), timezoneId: identity.timezoneId)
            var items: [(SleepSessionInput, Bool)] = priorSleep
                .filter { $0.interval.end <= identity.dayWindow.start }
                .map { ($0, false) }
            // The input's own earlier-day episodes re-enter as records keyed by their already-computed owner day.
            for e in all where e.ownerDay < identity.day && e.interval.end <= identity.dayWindow.start {
                let isNap: Bool? = e.classificationBasis == basisScorerNapFlag ? (e.kind == .nap) : nil
                items.append((SleepSessionInput(id: e.id, interval: e.interval, isNap: isNap, hrOnly: e.hrOnly,
                                                availableAt: e.availableAt, sourceDay: e.ownerDay,
                                                detector: e.detector ?? "episode"), false))
            }
            let built = build(items, identity: identity, mode: mode, cutoff: cutoff, config: config).map { $0.episode }
            let inWindow = built.filter { $0.ownerDay >= firstDay && $0.ownerDay < identity.day }
            let inputMismatch = all.contains { $0.ownerDay < identity.day && $0.reasons.contains(sourceDayDiffers) }
            var nights: [PriorNight] = []
            for (day, eps) in Dictionary(grouping: inWindow, by: { $0.ownerDay }) {
                let mains = eps.filter { $0.kind == .mainSleep }
                guard !mains.isEmpty, mains.allSatisfy({ $0.complete }) else { continue }
                let start = mains.map { $0.interval.start }.min()!, end = mains.map { $0.interval.end }.max()!
                nights.append(PriorNight(day: day, durationS: mains.reduce(0) { $0 + $1.durationS },
                                         span: Interval(start, end)))
            }
            let mismatch = inputMismatch || inWindow.contains { $0.reasons.contains(sourceDayDiffers) }
            return PriorNights(nights: nights.sorted { $0.day < $1.day }, zoneMismatch: mismatch)
        }

        static func sleepLoss(_ main: MainSleepSummary?, prior: [PriorNight], config: SleepConfig) -> SleepLossSummary {
            let days = prior.map { $0.day }
            func unknown(_ r: [ReasonCode]) -> SleepLossSummary {
                SleepLossSummary(state: .unknown, currentS: main?.durationS, priorMedianS: nil, differenceS: nil,
                                 lossS: nil, supportNights: prior.count, priorDays: days, reasons: r)
            }
            guard let main else { return unknown([noMainSleep]) }
            guard main.complete else { return unknown([mainSleepIncomplete]) }
            guard prior.count >= max(1, config.minPriorNights) else { return unknown([priorNightsInsufficient]) }
            let median = medianInt(prior.map { $0.durationS })
            let diff = main.durationS - median
            return SleepLossSummary(state: .available, currentS: main.durationS, priorMedianS: median,
                                    differenceS: diff, lossS: max(0, -diff), supportNights: prior.count,
                                    priorDays: days, reasons: [])
        }

        static func timingSummary(_ main: MainSleepSummary?, prior: PriorNights, timezoneId tz: String,
                                  config: SleepConfig) -> SleepTimingSummary {
            guard let main else { return .unknown([noMainSleep]) }
            var reasons: [ReasonCode] = []
            let onset = localTime(at: main.span.start, timezoneId: tz)
            guard main.complete else {
                var t = SleepTimingSummary.unknown([mainSleepIncomplete])
                t.onset = onset
                return t
            }
            let midTs = main.span.start + main.span.duration / 2
            let midpoint = localTime(at: midTs, timezoneId: tz)
            let wake = localTime(at: main.span.end, timezoneId: tz)
            let priorMid = prior.nights.map { localTime(at: $0.span.start + $0.span.duration / 2, timezoneId: tz) }
            let priorWake = prior.nights.map { localTime(at: $0.span.end, timezoneId: tz) }
            var timing = SleepTimingSummary(state: .unknown, onset: onset, midpoint: midpoint, wake: wake,
                                            priorMedianMidpointS: nil, midpointChangeS: nil, priorMedianWakeS: nil,
                                            wakeChangeS: nil, priorMidpointSdS: nil,
                                            supportNights: prior.nights.count, changeVerifiable: false, reasons: [])
            guard prior.nights.count >= max(1, config.minPriorNights) else {
                timing.reasons = prior.zoneMismatch ? [priorNightsInsufficient, timezoneHistoryUnknown]
                    : [priorNightsInsufficient]
                return timing
            }
            let medMid = circularMedianSec(priorMid.map { $0.secondsOfDay })
            let medWake = circularMedianSec(priorWake.map { $0.secondsOfDay })
            let midChange = signedCircularDiff(midpoint.secondsOfDay, medMid)
            let wakeChange = signedCircularDiff(wake.secondsOfDay, medWake)
            timing.priorMedianMidpointS = medMid
            timing.priorMedianWakeS = medWake
            timing.midpointChangeS = midChange
            timing.wakeChangeS = wakeChange
            timing.priorMidpointSdS = circularSdSec(priorMid.map { $0.secondsOfDay })
            timing.state = .available
            // The input carries only the document's zone: prior nights are read on today's clock.
            reasons.append(priorZoneAssumedSame)
            if Set(priorMid.map { $0.utcOffsetS } + [midpoint.utcOffsetS]).count > 1 {
                reasons.append(utcOffsetChangedInWindow)
            }
            let tol = config.timezoneShiftToleranceS
            func wholeHours(_ s: Int) -> Bool {
                let a = abs(s)
                guard a >= config.timezoneShiftMinS - tol else { return false }
                let r = a % 3600
                return r <= tol || 3600 - r <= tol
            }
            let zoneLike = wholeHours(midChange) && wholeHours(wakeChange) && abs(midChange - wakeChange) <= tol
            if zoneLike || prior.zoneMismatch {
                reasons.append(timezoneHistoryUnknown)
                timing.changeVerifiable = false
            } else {
                timing.changeVerifiable = true
            }
            timing.reasons = unique(reasons).sorted()
            return timing
        }

        /// Median awake HR minus median main-sleep HR on the document's day: a masked proxy whose "sleep" side was
        /// itself selected with heart rate (circular by construction). Never endogenous phase.
        static func dayNightContrast(mains: [SleepEpisode], all: [SleepEpisode], identity: DayIdentity,
                                     observations: SanitizedObservations, causal: Bool, cutoff: Int,
                                     config: SleepConfig) -> RhythmDescriptor {
            var reasons: [ReasonCode] = [rhythmProxyOnly, labelsReadHeartRate]
            let plausible = 30...220
            var sleepBpm: [Double] = []
            if mains.contains(where: { !$0.complete }) {
                reasons.append(mainSleepIncomplete)
                return RhythmDescriptor(name: dayNightContrastName, value: nil, units: "bpm", isProxy: true,
                                        dependsOnHeartSignals: true, sampleCount: 0, reasons: reasons.sorted())
            }
            for e in mains {
                for s in samples(observations.heartRate, in: e.interval, ts: { $0.ts })
                where plausible.contains(s.bpm) {
                    sleepBpm.append(Double(s.bpm))
                }
            }
            let dayEnd = causal ? min(identity.dayWindow.end, cutoff) : identity.dayWindow.end
            var awakeBpm: [Double] = []
            if dayEnd > identity.dayWindow.start {
                let sleepTime = merged(all.map { $0.interval })
                for s in samples(observations.heartRate, in: Interval(identity.dayWindow.start, dayEnd), ts: { $0.ts })
                where plausible.contains(s.bpm) && !sleepTime.contains(where: { $0.contains(s.ts) }) {
                    awakeBpm.append(Double(s.bpm))
                }
            }
            var value: Double? = nil
            if sleepBpm.count >= config.rhythmMinSamples && awakeBpm.count >= config.rhythmMinSamples,
               let a = RobustStats.median(awakeBpm), let b = RobustStats.median(sleepBpm) {
                value = a - b
            } else {
                reasons.append(rhythmSamplesInsufficient)
            }
            return RhythmDescriptor(name: dayNightContrastName, value: value, units: "bpm", isProxy: true,
                                    dependsOnHeartSignals: true, sampleCount: sleepBpm.count + awakeBpm.count,
                                    reasons: reasons.sorted())
        }

        // MARK: - Helpers

        /// Elements of a `ts`-sorted array inside `interval` (binary search). Falls back to a full scan when the
        /// slice boundaries show the array is not sorted.
        static func samples<T>(_ items: [T], in interval: Interval, ts: (T) -> Int) -> [T] {
            guard !items.isEmpty, interval.isValid else { return [] }
            var lo = 0, hi = items.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if ts(items[mid]) < interval.start { lo = mid + 1 } else { hi = mid }
            }
            var end = lo
            var prev = Int.min
            var ordered = lo == 0 || ts(items[lo - 1]) < interval.start
            while ordered, end < items.count {
                let t = ts(items[end])
                if t >= interval.end { break }
                if t < prev || t < interval.start { ordered = false; break }
                prev = t
                end += 1
            }
            if ordered && ts(items[0]) <= ts(items[items.count - 1]) { return Array(items[lo..<end]) }
            return items.filter { interval.contains(ts($0)) }
        }

        static func latestTs<T>(_ items: [T], ts: (T) -> Int) -> Int? {
            guard let first = items.first, let last = items.last else { return nil }
            if ts(first) <= ts(last) && ts(items[items.count / 2]) <= ts(last) { return ts(last) }
            return items.map(ts).max()
        }

        /// Sorted union of intervals.
        static func merged(_ intervals: [Interval]) -> [Interval] {
            var out: [Interval] = []
            for iv in intervals.filter({ $0.isValid }).sorted() {
                if var last = out.last, iv.start <= last.end {
                    last.end = max(last.end, iv.end)
                    out[out.count - 1] = last
                } else {
                    out.append(iv)
                }
            }
            return out
        }

        static func offset(at ts: Int, timezoneId: String) -> Int {
            let zone = TimeZone(identifier: timezoneId) ?? TimeZone(identifier: "UTC")!
            return zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(ts)))
        }

        /// The local day `n` days after `day` in the zone (DST-safe: steps from local noon).
        static func shiftDay(_ day: String, by n: Int, timezoneId: String) -> String {
            let window = Engine.dayInterval(day, timezoneId: timezoneId)
            guard window.isValid else { return day }
            return localTime(at: window.start + 12 * 3600 + n * 86_400, timezoneId: timezoneId).localDay
        }

        static func medianInt(_ values: [Int]) -> Int {
            let v = values.sorted()
            guard !v.isEmpty else { return 0 }
            let mid = v.count / 2
            return v.count % 2 == 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2
        }

        /// Signed circular difference `a - b` of two seconds-of-day, in [-43200, 43200).
        static func signedCircularDiff(_ a: Int, _ b: Int) -> Int {
            let d = ((a - b) % 86_400 + 86_400) % 86_400
            return d >= 43_200 ? d - 86_400 : d
        }

        /// Median of seconds-of-day unwrapped around their circular mean (so 23:50 and 00:10 are 20 min apart).
        static func circularMedianSec(_ values: [Int]) -> Int {
            guard let ref = SleepStageTotals.circularMeanSec(values) ?? values.first else { return 0 }
            let unwrapped = values.map { ref + signedCircularDiff($0, ref) }
            let m = medianInt(unwrapped)
            return ((m % 86_400) + 86_400) % 86_400
        }

        /// Circular standard deviation of seconds-of-day, `sqrt(-2 ln R)` scaled to seconds; nil when degenerate.
        static func circularSdSec(_ values: [Int]) -> Int? {
            guard !values.isEmpty else { return nil }
            let k = 2.0 * Double.pi / 86_400.0
            var s = 0.0, c = 0.0
            for v in values { s += sin(Double(v) * k); c += cos(Double(v) * k) }
            let r = (s * s + c * c).squareRoot() / Double(values.count)
            guard r > 1e-9 else { return nil }
            let sd = (-2.0 * log(min(1.0, r))).squareRoot() / k
            return sd.isFinite ? Int(sd.rounded()) : nil
        }

        static func unique(_ codes: [ReasonCode]) -> [ReasonCode] {
            var seen = Set<ReasonCode>()
            return codes.filter { seen.insert($0).inserted }
        }
    }
}
