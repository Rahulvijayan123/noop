import Foundation

// PCExertionBouts.swift — System D: exertion bouts, response and recovery (spec §10).
//
// OWNER: responses & function workstream. SKELETON — signatures are the shared contract.
//
// Bouts are detected from heart-rate independent evidence (HART epochs, strap motion, step counter, logged
// workouts), so a bout is never selected because heart rate rose. Response measurements are kept independently of
// any recovery classification; missing follow-up is censored, never invented.

extension PhysiologyContext {

    public struct ExertionConfig: Codable, Equatable, Sendable {
        public var version = "pc-exertion-1"
        /// Trailing exertion-summary windows in hours (candidate 24/48/72 h summaries).
        public var windowsH: [Int] = [24, 48, 72]
        public init() {}
    }

    public enum BoutStatus: String, Codable, CaseIterable, Sendable {
        /// Ended and its recovery follow-up was observed to the last supported offset.
        case complete
        /// Still in progress at the cutoff.
        case ongoing
        /// Ended but recovery follow-up is incomplete (reasons say why).
        case censored
    }

    /// One supported exertion bout with its measured response.
    public struct ExertionBout: Codable, Equatable, Sendable {
        /// Deterministic: `bout:<deviceScope>:<start>` hashed (stable across retries and re-runs).
        public var id: String
        public var interval: Interval
        /// Local day that owns the bout (day containing its start).
        public var day: String
        /// `walking` | `running` | `stepping` | `workout` | `mixed_locomotion`.
        public var kind: String
        public var status: BoutStatus
        public var durationS: Int
        public var reasons: [ReasonCode]
        public init(id: String, interval: Interval, day: String, kind: String, status: BoutStatus, durationS: Int,
                    reasons: [ReasonCode] = []) {
            self.id = id; self.interval = interval; self.day = day; self.kind = kind; self.status = status
            self.durationS = durationS; self.reasons = reasons
        }
    }

    /// A reference from a measurement to a bout that preceded it.
    public struct BoutRef: Codable, Equatable, Sendable {
        public var boutId: String
        public var kind: String
        public var endedAt: Int
        public var secondsBeforeMeasurement: Int
        public var durationS: Int
        public init(boutId: String, kind: String, endedAt: Int, secondsBeforeMeasurement: Int, durationS: Int) {
            self.boutId = boutId; self.kind = kind; self.endedAt = endedAt
            self.secondsBeforeMeasurement = secondsBeforeMeasurement; self.durationS = durationS
        }
    }

    /// Observed-coverage accounting for one earlier day (so trailing windows report their missingness).
    public struct DayCoverage: Codable, Equatable, Sendable {
        public var day: String
        public var interval: Interval
        public var observedS: Int
        public init(day: String, interval: Interval, observedS: Int) {
            self.day = day; self.interval = interval; self.observedS = observedS
        }
    }

    /// Descriptive exertion over a trailing window ending at an instant.
    public struct ExertionWindowSummary: Codable, Equatable, Sendable {
        public var windowH: Int
        public var interval: Interval
        public var boutCount: Int
        public var locomotionS: Int
        /// Seconds of the window with motion evidence; nil when unknown.
        public var observedS: Int?
        public var reasons: [ReasonCode]
        public init(windowH: Int, interval: Interval, boutCount: Int, locomotionS: Int, observedS: Int?,
                    reasons: [ReasonCode]) {
            self.windowH = windowH; self.interval = interval; self.boutCount = boutCount
            self.locomotionS = locomotionS; self.observedS = observedS; self.reasons = reasons
        }
    }

    public enum ExertionBouts {

        public static let reasonCodes: [ReasonCode] = []

        /// Detect bouts over the day window from heart-rate independent evidence, with response and recovery
        /// measured from the observations available at `cutoff`.
        public static func detect(identity: DayIdentity, hart: ResolvedTrack, strap: ResolvedTrack,
                                  workouts: [WorkoutInput], observations: SanitizedObservations,
                                  mode: ProcessingMode, cutoff: Int, config: ExertionConfig) -> [ExertionBout] {
            []
        }

        /// Bouts (today's and earlier days') that ended before `ts`, newest first, within the longest window.
        public static func recentRefs(before ts: Int, bouts: [ExertionBout], config: ExertionConfig) -> [BoutRef] {
            []
        }

        /// Trailing exertion summaries ending at `ts` for each configured window.
        public static func windows(endingAt ts: Int, bouts: [ExertionBout], coverage: [DayCoverage],
                                   config: ExertionConfig) -> [ExertionWindowSummary] {
            []
        }

        /// Daily context-conditioned values contributed by bouts (e.g. matched-bout HR response).
        public static func dailyValues(_ bouts: [ExertionBout], identity: DayIdentity, regimeKey: String,
                                       mode: ProcessingMode, config: ExertionConfig) -> [DailyValue] {
            []
        }
    }
}
