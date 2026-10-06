import Foundation

// PCIntervalAlgebra.swift — interval-correct joins from labelled activity records to measurement support intervals
// (spec §6.2, V01).
//
// The existing `ActivityContextJoin.context` normalizes shares by the COVERED epoch seconds, so uncovered time
// disappears from the denominator, and it sums overlapping epochs twice. That function keeps its callers; this file
// is the context layer's join and never edits it:
//
//   1. `resolve` turns overlapping / revised records into non-overlapping spans. At every second the record with
//      the highest revision wins, then the later availability, then the larger stable tie-break id. A second covered
//      by several records is counted once; how many seconds needed resolving is reported, never hidden.
//   2. `composition` measures labels over the WHOLE interval: label seconds + unknown seconds + uncovered seconds
//      equal the interval duration. A missing record is uncovered time, never stationary time.
//   3. `precedingHistory` inspects a separate lookback window that ends where the measurement starts, so activity
//      that ended before the measurement still informs it.

extension PhysiologyContext {

    /// One labelled span from an activity source, before resolution. `label == nil` means covered but unknown.
    public struct LabelRecord: Equatable, Sendable {
        public var interval: Interval
        public var label: String?
        /// Share of the span that abstained, in [0, 1] (v1 epochs carry a partial abstention fraction).
        public var unknownFraction: Double
        public var revision: Int
        public var availableAt: Int?
        /// Stable identity used as the last tie-break (deterministic regardless of input order).
        public var tieBreak: String

        public init(interval: Interval, label: String?, unknownFraction: Double = 0, revision: Int = 0,
                    availableAt: Int? = nil, tieBreak: String) {
            self.interval = interval; self.label = label
            self.unknownFraction = min(1, max(0, unknownFraction))
            self.revision = revision; self.availableAt = availableAt; self.tieBreak = tieBreak
        }
    }

    /// A non-overlapping span after resolution.
    public struct ResolvedSpan: Equatable, Sendable {
        public var interval: Interval
        public var label: String?
        public var unknownFraction: Double
        public var revision: Int
        public init(interval: Interval, label: String?, unknownFraction: Double, revision: Int) {
            self.interval = interval; self.label = label; self.unknownFraction = unknownFraction
            self.revision = revision
        }
    }

    /// Resolved spans of one source plus the overlap accounting.
    public struct ResolvedTrack: Equatable, Sendable {
        public var source: ActivitySource
        public var heartRateDependent: Bool
        public var spans: [ResolvedSpan]
        /// Merged segments covered by more than one record (each such second counted once).
        public var overlaps: [Interval]
        /// Merged segments where the overlapping records disagreed on label or abstention.
        public var conflicts: [Interval]
        /// Records dropped because they were not available at the causal cutoff.
        public var droppedUnavailable: Int

        public init(source: ActivitySource, heartRateDependent: Bool, spans: [ResolvedSpan], overlaps: [Interval],
                    conflicts: [Interval], droppedUnavailable: Int) {
            self.source = source; self.heartRateDependent = heartRateDependent; self.spans = spans
            self.overlaps = overlaps; self.conflicts = conflicts; self.droppedUnavailable = droppedUnavailable
        }

        public var overlapS: Int { overlaps.reduce(0) { $0 + $1.duration } }
        public var conflictS: Int { conflicts.reduce(0) { $0 + $1.duration } }

        public static func empty(_ source: ActivitySource = .none) -> ResolvedTrack {
            ResolvedTrack(source: source, heartRateDependent: false, spans: [], overlaps: [], conflicts: [],
                          droppedUnavailable: 0)
        }
    }

    /// Label vocabularies shared by every source. HART epochs use `MotionLabel` raw values, strap motion uses
    /// `still` / `low_movement` / `stepping` / `other_movement`, decoder intervals use `ActivityClass` codes.
    public enum MotionVocabulary {
        /// No locomotion and no gross movement: counts toward stillness.
        public static let stationary: Set<String> = [
            "stationary", "still", "low_movement",
            "sleeping", "lying_down", "sitting", "sitting_desk", "standing",
        ]
        /// Locomotion: counts as supported activity.
        public static let locomotion: Set<String> = [
            "walking", "running", "stepping", "brisk_walking", "cycling",
        ]
        /// Movement that is not locomotion; breaks stillness but is not "supported activity".
        public static let otherMovement: Set<String> = [
            "other_movement", "fidgeting", "light_activity", "vigorous_activity",
        ]

        public static func isStationary(_ label: String?) -> Bool { label.map(stationary.contains) ?? false }
        public static func isLocomotion(_ label: String?) -> Bool { label.map(locomotion.contains) ?? false }
        public static func isMovement(_ label: String?) -> Bool {
            label.map { locomotion.contains($0) || otherMovement.contains($0) } ?? false
        }
    }

    public enum IntervalAlgebra {

        public static let version = "pc-join-1"

        // MARK: Reason codes
        public static let invalidInterval: ReasonCode = "invalid_interval"
        public static let noActivityRecords: ReasonCode = "no_activity_records"
        public static let uncoveredTime: ReasonCode = "uncovered_time"
        public static let mostlyUncovered: ReasonCode = "mostly_uncovered"
        public static let unknownLabelTime: ReasonCode = "unknown_label_time"
        public static let mixedStates: ReasonCode = "mixed_states"
        public static let overlappingRecordsResolved: ReasonCode = "overlapping_records_resolved"
        public static let heartRateDependentSource: ReasonCode = "heart_rate_dependent_source"
        public static let stillRunGap: ReasonCode = "gap"
        public static let stillRunMovement: ReasonCode = "movement"
        public static let stillRunUnknownLabel: ReasonCode = "unknown_label"
        public static let stillRunLookbackLimit: ReasonCode = "lookback_limit"

        public static let reasonCodes: [ReasonCode] = [
            invalidInterval, noActivityRecords, uncoveredTime, mostlyUncovered, unknownLabelTime, mixedStates,
            overlappingRecordsResolved, heartRateDependentSource, stillRunGap, stillRunMovement,
            stillRunUnknownLabel, stillRunLookbackLimit,
        ]

        /// A span whose abstention fraction is at or above this is not supported stillness.
        static let stillMaxUnknownFraction = 0.5

        // MARK: Resolution

        /// Resolve overlapping and revised records into non-overlapping spans.
        ///
        /// - Parameter availableBy: when non-nil, records whose `availableAt` is later are dropped first (a causal
        ///   decision cannot see a record published after its cutoff).
        public static func resolve(_ records: [LabelRecord], source: ActivitySource, heartRateDependent: Bool,
                                   availableBy: Int? = nil) -> ResolvedTrack {
            var dropped = 0
            let usable: [LabelRecord] = records.filter { r in
                guard r.interval.isValid else { return false }
                if let cutoff = availableBy, let at = r.availableAt, at > cutoff { dropped += 1; return false }
                return true
            }
            guard !usable.isEmpty else {
                return ResolvedTrack(source: source, heartRateDependent: heartRateDependent, spans: [],
                                     overlaps: [], conflicts: [], droppedUnavailable: dropped)
            }
            // Sweep over every boundary; the active set is small (records rarely overlap more than a few deep).
            var boundaries = Set<Int>()
            for r in usable { boundaries.insert(r.interval.start); boundaries.insert(r.interval.end) }
            let points = boundaries.sorted()
            let byStart = usable.indices.sorted { usable[$0].interval.start < usable[$1].interval.start }
            var next = 0
            var active: [Int] = []
            var spans: [ResolvedSpan] = []
            var overlaps: [Interval] = []
            var conflicts: [Interval] = []
            for k in 0..<(points.count - 1) {
                let lo = points[k], hi = points[k + 1]
                active.removeAll { usable[$0].interval.end <= lo }
                while next < byStart.count, usable[byStart[next]].interval.start <= lo {
                    let idx = byStart[next]
                    if usable[idx].interval.end > lo { active.append(idx) }
                    next += 1
                }
                guard !active.isEmpty else { continue }
                let winner = active.max { precedes(usable[$0], usable[$1]) }!
                let w = usable[winner]
                if active.count > 1 {
                    appendMerged(&overlaps, Interval(lo, hi))
                    if active.contains(where: { usable[$0].label != w.label
                                                || usable[$0].unknownFraction != w.unknownFraction }) {
                        appendMerged(&conflicts, Interval(lo, hi))
                    }
                }
                let span = ResolvedSpan(interval: Interval(lo, hi), label: w.label,
                                        unknownFraction: w.unknownFraction, revision: w.revision)
                if var last = spans.last, last.interval.end == lo, last.label == span.label,
                   last.unknownFraction == span.unknownFraction, last.revision == span.revision {
                    last.interval.end = hi
                    spans[spans.count - 1] = last
                } else {
                    spans.append(span)
                }
            }
            return ResolvedTrack(source: source, heartRateDependent: heartRateDependent, spans: spans,
                                 overlaps: overlaps, conflicts: conflicts, droppedUnavailable: dropped)
        }

        /// Strict ordering used to pick the winning record for a second: revision, then availability, then id.
        static func precedes(_ a: LabelRecord, _ b: LabelRecord) -> Bool {
            if a.revision != b.revision { return a.revision < b.revision }
            let aa = a.availableAt ?? Int.min, ba = b.availableAt ?? Int.min
            if aa != ba { return aa < ba }
            return a.tieBreak < b.tieBreak
        }

        // MARK: Composition

        /// Duration-weighted composition of `track` over the whole `interval`.
        public static func composition(over interval: Interval, track: ResolvedTrack,
                                       config: JoinConfig = .init()) -> ActivityComposition {
            guard interval.isValid else {
                return ActivityComposition(interval: interval, intervalS: 0, source: track.source,
                                           heartRateDependent: track.heartRateDependent, labels: [],
                                           unknownS: 0, uncoveredS: 0, transitions: 0, mixed: false,
                                           dominantLabel: nil, resolvedOverlapS: 0, reasons: [invalidInterval])
            }
            let duration = Double(interval.duration)
            var seconds: [String: Double] = [:]
            var unknown = 0.0
            var covered = 0.0
            var transitions = 0
            var previous: ResolvedSpan?
            for span in overlapping(track.spans, interval) {
                let w = Double(span.interval.overlapSeconds(with: interval))
                covered += w
                if let label = span.label {
                    seconds[label, default: 0] += w * (1 - span.unknownFraction)
                    unknown += w * span.unknownFraction
                } else {
                    unknown += w
                }
                if let p = previous, p.interval.end == span.interval.start,
                   let a = p.label, let b = span.label, a != b {
                    transitions += 1
                }
                previous = span
            }
            let overlapInside = track.overlaps.reduce(0) { $0 + $1.overlapSeconds(with: interval) }
            let uncovered = max(0, duration - covered)
            let labels = seconds.keys.sorted().map { key -> LabelShare in
                LabelShare(label: key, seconds: seconds[key]!, share: seconds[key]! / duration)
            }
            let significant = labels.filter { $0.share >= config.mixedFloorShare }
            let dominant = labels.first { $0.share >= config.dominantFloorShare }?.label
            var reasons: [ReasonCode] = []
            if track.spans.isEmpty || covered == 0 { reasons.append(noActivityRecords) }
            if uncovered > config.reconcileToleranceS { reasons.append(uncoveredTime) }
            if uncovered / duration >= 0.5 { reasons.append(mostlyUncovered) }
            if unknown > config.reconcileToleranceS { reasons.append(unknownLabelTime) }
            if significant.count >= 2 { reasons.append(mixedStates) }
            if overlapInside > 0 { reasons.append(overlappingRecordsResolved) }
            if track.heartRateDependent { reasons.append(heartRateDependentSource) }
            return ActivityComposition(interval: interval, intervalS: interval.duration, source: track.source,
                                       heartRateDependent: track.heartRateDependent, labels: labels,
                                       unknownS: unknown, uncoveredS: uncovered, transitions: transitions,
                                       mixed: significant.count >= 2, dominantLabel: dominant,
                                       resolvedOverlapS: overlapInside, reasons: reasons)
        }

        /// True when `labels + unknown + uncovered` equals the interval within tolerance (the V01 invariant).
        public static func reconciles(_ c: ActivityComposition, tolerance: Double = 1e-6) -> Bool {
            let total = c.labels.reduce(0) { $0 + $1.seconds } + c.unknownS + c.uncoveredS
            return abs(total - Double(c.intervalS)) <= tolerance * max(1, Double(c.intervalS))
        }

        // MARK: Preceding history

        /// History of `track` in `[start - lookback, start)`; time since supported activity scans every span before
        /// `start` so it can exceed the lookback.
        public static func precedingHistory(before start: Int, track: ResolvedTrack,
                                            lookbackS: Int) -> PrecedingHistory {
            let lookback = Interval(start - max(0, lookbackS), start)
            let prior = track.spans.filter { $0.interval.start < start }
            // Still run: walk backward through contiguous stationary spans ending at `start`.
            var still = 0.0
            var endedBy: ReasonCode? = nil
            var expectedEnd = start
            var i = prior.count - 1
            while i >= 0 {
                let s = prior[i]
                let spanEnd = min(s.interval.end, start)
                if spanEnd < expectedEnd { endedBy = stillRunGap; break }
                if MotionVocabulary.isMovement(s.label) { endedBy = stillRunMovement; break }
                guard MotionVocabulary.isStationary(s.label), s.unknownFraction < stillMaxUnknownFraction else {
                    endedBy = stillRunUnknownLabel; break
                }
                let lo = max(s.interval.start, lookback.start)
                still += Double(spanEnd - lo) * (1 - s.unknownFraction)
                if s.interval.start <= lookback.start { endedBy = stillRunLookbackLimit; break }
                expectedEnd = s.interval.start
                i -= 1
            }
            if i < 0 && endedBy == nil {
                endedBy = expectedEnd > lookback.start ? stillRunGap : stillRunLookbackLimit
            }
            var sinceActivity: Int? = nil
            var lastLabel: String? = nil
            for s in prior.reversed() where MotionVocabulary.isLocomotion(s.label) && s.unknownFraction < 1 {
                sinceActivity = max(0, start - min(s.interval.end, start))
                lastLabel = s.label
                break
            }
            var covered = 0
            var transitions = 0
            var previous: ResolvedSpan?
            for s in overlapping(track.spans, lookback) {
                covered += s.interval.overlapSeconds(with: lookback)
                if let p = previous, p.interval.end == s.interval.start, let a = p.label, let b = s.label, a != b {
                    transitions += 1
                }
                previous = s
            }
            return PrecedingHistory(lookback: lookback, source: track.source, stillRunS: Int(still.rounded(.down)),
                                    stillRunEndedBy: endedBy, secondsSinceSupportedActivity: sinceActivity,
                                    lastSupportedActivityLabel: lastLabel, coveredS: covered,
                                    transitions: transitions)
        }

        // MARK: Record builders

        /// v1 HART epochs: label = motion raw value, `unknown` motion is covered-unknown.
        public static func records(fromEpochs epochs: [ActivityEpochInput]) -> [LabelRecord] {
            epochs.map { e in
                let unknown = e.epoch.motion == .unknown
                return LabelRecord(interval: Interval(e.epoch.startTs, e.epoch.endTs),
                                   label: unknown ? nil : e.epoch.motion.rawValue,
                                   unknownFraction: unknown ? 1 : e.epoch.unknownFraction,
                                   revision: e.revision, availableAt: e.availableAt,
                                   tieBreak: "epoch:\(e.revision):\(e.epoch.startTs):\(e.epoch.endTs):"
                                       + "\(e.epoch.motion.rawValue):\(e.epoch.observedS):\(e.epoch.validS)")
            }
        }

        /// v2 decoder intervals: label = class code; `unknown` and `off_wrist` are covered-unknown for activity.
        public static func records(fromIntervals intervals: [ActivityIntervalInput]) -> [LabelRecord] {
            intervals.map { r in
                let unknown = r.activityClass == "unknown" || r.activityClass == "off_wrist"
                return LabelRecord(interval: r.interval, label: unknown ? nil : r.activityClass,
                                   unknownFraction: unknown ? 1 : 0, revision: r.revision,
                                   availableAt: r.availableAt,
                                   tieBreak: "interval:\(r.revision):\(r.interval.start):\(r.interval.end):"
                                       + "\(r.activityClass):\(r.confidence)")
            }
        }

        // MARK: Helpers

        /// Spans of a sorted, non-overlapping list that overlap `interval` (binary search on the start).
        static func overlapping(_ spans: [ResolvedSpan], _ interval: Interval) -> ArraySlice<ResolvedSpan> {
            guard !spans.isEmpty, interval.isValid else { return [] }
            var lo = 0, hi = spans.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if spans[mid].interval.end <= interval.start { lo = mid + 1 } else { hi = mid }
            }
            var end = lo
            while end < spans.count, spans[end].interval.start < interval.end { end += 1 }
            return spans[lo..<end]
        }

        static func appendMerged(_ list: inout [Interval], _ segment: Interval) {
            if var last = list.last, last.end == segment.start {
                last.end = segment.end
                list[list.count - 1] = last
            } else {
                list.append(segment)
            }
        }
    }

    // MARK: - Local time

    /// Local-time interpretation of `ts` in `timezoneId` (falls back to UTC for an unknown zone, flagged by the id).
    public static func localTime(at ts: Int, timezoneId: String) -> LocalTimeRef {
        let zone = TimeZone(identifier: timezoneId) ?? TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
        let seconds = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
        return LocalTimeRef(timezoneId: zone.identifier, utcOffsetS: zone.secondsFromGMT(for: date),
                            localDay: day, secondsOfDay: seconds)
    }
}
