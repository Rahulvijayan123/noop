import Foundation

// PCStoredDocument.swift — the storage / wire encoding of a day document (lead-owned).
//
// A fully observed day carries ~2,300 envelopes (5-minute HRV / HR / resting-HR windows, 1-minute respiratory
// estimates, nightly values). Encoded naively that is ~10 MB, almost all of it sub-objects that repeat between
// neighbouring measurements (the same sleep/wear evidence, the same exposure status, the same recent bout, exertion
// windows that differ only by where they end). The stored form is therefore:
//
//   • a SUMMARY document — the `DayDocument` with `envelopes` empty and `envelopeIndex` listing what was split off;
//   • one self-contained ENVELOPE TABLE per metric, in which every sub-object is interned into a pool and each row
//     holds indices. Times inside pooled objects are stored relative to the row's support start, and the two
//     history numbers that are pure functions of it (seconds since wake, seconds since a bout ended) are derived on
//     decode — with an explicit per-row override whenever the derivation would not reproduce the stored value.
//
// The encoding is lossless: `join(split(doc)) == doc` (tested on synthetic full days and real nights). A metric page
// fetches the summary plus only its own table.

extension PhysiologyContext {

    /// What the summary document split off into envelope tables.
    public struct EnvelopeTableIndex: Codable, Equatable, Sendable {
        public var metric: MetricKind
        public var envelopeCount: Int
        public init(metric: MetricKind, envelopeCount: Int) { self.metric = metric; self.envelopeCount = envelopeCount }
    }

    /// One metric's envelopes, interned.
    public struct EnvelopeTable: Codable, Equatable, Sendable {
        public static let wireVersion = "pc-wire-1"

        public struct Row: Codable, Equatable, Sendable {
            /// Present only when the id is not `MeasurementEnvelope.makeId(method:support:)`.
            public var id: String?
            public var method: Int
            public var source: SourceRef
            public var value: Double?
            public var support: Interval
            public var displayBucket: Interval?
            public var localTime: LocalTimeRef
            public var validity: Int
            public var regimeKey: String
            public var activity: Int
            public var decoderActivity: Int?
            public var preceding: Int
            public var sleepWear: Int
            public var wake: Int
            /// Override when `secondsSinceWake != support.start - wakeAt`.
            public var wakeSecondsOverride: Int?
            /// True when the envelope had a `wakeAt` but no `secondsSinceWake` (an explicit flag, not a sentinel).
            public var wakeSecondsCleared: Bool?
            public var recentBouts: Int
            /// Override when any `secondsBeforeMeasurement != support.start - endedAt`.
            public var boutSecondsOverride: [Int]?
            public var exertion: Int
            public var exposures: Int
            public var exposureCoverage: Int
            public var eligibility: [Int]
            public var comparisons: Int
            public var finality: Finality
            /// Indices into `posture` / `wearSignal` (absent on rows written before they existed, and when the
            /// envelope has none).
            public var posture: Int? = nil
            public var wearSignal: Int? = nil
        }

        public var wireVersion: String
        public var metric: MetricKind
        public var methods: [MethodRef]
        public var validity: [SignalValidity]
        /// Compositions with `interval` relative to the row's support start.
        public var activity: [ActivityComposition]
        /// Preceding histories with `lookback` relative to the row's support start.
        public var preceding: [PrecedingHistory]
        public var sleepWear: [SleepWearContext]
        /// Wake references with `secondsSinceWake` removed (derived from `wakeAt`).
        public var wake: [WakeReference]
        /// Bout references with `secondsBeforeMeasurement` zeroed (derived from `endedAt`).
        public var recentBouts: [[BoutRef]]
        /// Exertion windows with `interval` relative to the row's support start.
        public var exertion: [[ExertionWindowSummary]]
        /// Distinct exposure references; a `precedes` reference holds its occurrence's absolute end instant in
        /// `secondsSinceOccurrence` (derived back on decode).
        public var exposureRefs: [ExposureRef]
        /// Each row's exposure list as indices into `exposureRefs` (a sliding 72 h window changes lists often, so
        /// references are pooled individually).
        public var exposures: [[Int]]
        public var exposureCoverage: [[ExposureCategoryStatus]]
        public var eligibility: [EligibilityVerdict]
        public var comparisons: [[ReferenceComparison]]
        public var rows: [Row]
        /// Posture contexts (no times inside) and wear-signal summaries (`interval` relative to the row's support
        /// start). Additive: tables written before them decode with nil.
        public var posture: [PostureContext]? = nil
        public var wearSignal: [WearSignalSummary]? = nil
    }

    public enum StoredDocument {

        /// Split a document into its summary and one envelope table per metric (metrics in `MetricKind` order).
        public static func split(_ doc: DayDocument) -> (summary: DayDocument, tables: [EnvelopeTable]) {
            var summary = doc
            summary.envelopes = []
            var tables: [EnvelopeTable] = []
            for metric in MetricKind.allCases {
                let envelopes = doc.envelopes.filter { $0.metric == metric }
                guard !envelopes.isEmpty else { continue }
                tables.append(table(metric: metric, envelopes))
            }
            summary.envelopeIndex = tables.map { EnvelopeTableIndex(metric: $0.metric, envelopeCount: $0.rows.count) }
            return (summary, tables)
        }

        /// Rebuild a document from its summary and any subset of its tables. With every table the result equals the
        /// original; with a subset, `envelopes` holds only those metrics and `envelopeIndex` still lists all of them.
        public static func join(summary: DayDocument, tables: [EnvelopeTable]) -> DayDocument {
            var doc = summary
            var envelopes: [MeasurementEnvelope] = []
            var dropped = 0
            for t in tables {
                let decoded = decode(t)
                dropped += t.rows.count - decoded.count
                envelopes += decoded
            }
            envelopes.sort(by: documentOrder)
            doc.envelopes = envelopes
            // The index is cleared only when every table came back AND every row decoded; a short rebuild keeps it,
            // so a reader never mistakes a partial document for a complete one.
            let complete = Set(tables.map(\.metric)) == Set((summary.envelopeIndex ?? []).map(\.metric))
            if complete && dropped == 0 { doc.envelopeIndex = nil }
            return doc
        }

        /// The envelopes held by `tables`, in document order (for readers that decode the summary leniently).
        public static func envelopes(_ tables: [EnvelopeTable]) -> [MeasurementEnvelope] {
            tables.flatMap(decode).sorted(by: documentOrder)
        }

        /// The engine's envelope order: support, method id, then metric.
        static func documentOrder(_ a: MeasurementEnvelope, _ b: MeasurementEnvelope) -> Bool {
            (a.support, a.method.id, a.metric.rawValue) < (b.support, b.method.id, b.metric.rawValue)
        }

        // MARK: Encode

        static func table(metric: MetricKind, _ envelopes: [MeasurementEnvelope]) -> EnvelopeTable {
            var methods = Pool<MethodRef>(), validity = Pool<SignalValidity>(), activity = Pool<ActivityComposition>()
            var preceding = Pool<PrecedingHistory>(), sleepWear = Pool<SleepWearContext>()
            var wake = Pool<WakeReference>(), bouts = Pool<[BoutRef]>(), exertion = Pool<[ExertionWindowSummary]>()
            var exposureRefs = Pool<ExposureRef>(), exposures = Pool<[Int]>()
            var coverage = Pool<[ExposureCategoryStatus]>()
            var verdicts = Pool<EligibilityVerdict>(), comparisons = Pool<[ReferenceComparison]>()
            var postures = Pool<PostureContext>(), wearSignals = Pool<WearSignalSummary>()
            var rows: [EnvelopeTable.Row] = []
            rows.reserveCapacity(envelopes.count)
            for e in envelopes {
                let anchor = e.support.start
                var w = e.history.wake
                var wakeOverride: Int? = nil
                var wakeCleared: Bool? = nil
                if let at = w.wakeAt, let since = w.secondsSinceWake, since == derived(anchor, at) {
                    w.secondsSinceWake = nil
                } else if w.wakeAt != nil && w.secondsSinceWake == nil {
                    wakeCleared = true
                } else if let since = w.secondsSinceWake {
                    wakeOverride = since
                    w.secondsSinceWake = nil
                }
                var refs = e.history.recentBouts
                var boutOverride: [Int]? = nil
                if refs.contains(where: { $0.secondsBeforeMeasurement != derived(anchor, $0.endedAt) }) {
                    boutOverride = refs.map(\.secondsBeforeMeasurement)
                }
                for i in refs.indices { refs[i].secondsBeforeMeasurement = 0 }
                rows.append(EnvelopeTable.Row(
                    id: e.id == MeasurementEnvelope.makeId(method: e.method, support: e.support) ? nil : e.id,
                    method: methods.index(e.method), source: e.source, value: e.value, support: e.support,
                    displayBucket: e.displayBucket, localTime: e.localTime, validity: validity.index(e.validity),
                    regimeKey: e.regimeKey, activity: activity.index(shifted(e.activity, by: -anchor)),
                    decoderActivity: e.decoderActivity.map { activity.index(shifted($0, by: -anchor)) },
                    preceding: preceding.index(shifted(e.preceding, by: -anchor)),
                    sleepWear: sleepWear.index(e.sleepWear), wake: wake.index(w), wakeSecondsOverride: wakeOverride,
                    wakeSecondsCleared: wakeCleared,
                    recentBouts: bouts.index(refs), boutSecondsOverride: boutOverride,
                    exertion: exertion.index(e.history.exertion.map { shifted($0, by: -anchor) }),
                    exposures: exposures.index(e.history.exposures.map {
                        exposureRefs.index(absoluteExposure($0, anchor: anchor))
                    }),
                    exposureCoverage: coverage.index(e.history.exposureCoverage),
                    eligibility: e.eligibility.map { verdicts.index($0) },
                    comparisons: comparisons.index(e.comparisons), finality: e.finality,
                    posture: e.posture.map { postures.index($0) },
                    wearSignal: e.wearSignal.map { wearSignals.index(shifted($0, by: -anchor)) }))
            }
            return EnvelopeTable(wireVersion: EnvelopeTable.wireVersion, metric: metric, methods: methods.values,
                                 validity: validity.values, activity: activity.values, preceding: preceding.values,
                                 sleepWear: sleepWear.values, wake: wake.values, recentBouts: bouts.values,
                                 exertion: exertion.values, exposureRefs: exposureRefs.values,
                                 exposures: exposures.values,
                                 exposureCoverage: coverage.values, eligibility: verdicts.values,
                                 comparisons: comparisons.values, rows: rows,
                                 posture: postures.values.isEmpty ? nil : postures.values,
                                 wearSignal: wearSignals.values.isEmpty ? nil : wearSignals.values)
        }

        // MARK: Decode

        static func decode(_ t: EnvelopeTable) -> [MeasurementEnvelope] {
            t.rows.compactMap { r in
                guard t.methods.indices.contains(r.method), t.validity.indices.contains(r.validity),
                      t.activity.indices.contains(r.activity), t.preceding.indices.contains(r.preceding),
                      t.sleepWear.indices.contains(r.sleepWear), t.wake.indices.contains(r.wake),
                      t.recentBouts.indices.contains(r.recentBouts), t.exertion.indices.contains(r.exertion),
                      t.exposures.indices.contains(r.exposures),
                      t.exposures[r.exposures].allSatisfy(t.exposureRefs.indices.contains),
                      t.exposureCoverage.indices.contains(r.exposureCoverage),
                      t.comparisons.indices.contains(r.comparisons),
                      r.eligibility.allSatisfy(t.eligibility.indices.contains),
                      r.decoderActivity.map(t.activity.indices.contains) ?? true,
                      r.posture.map { (t.posture ?? []).indices.contains($0) } ?? true,
                      r.wearSignal.map { (t.wearSignal ?? []).indices.contains($0) } ?? true else { return nil }
                let anchor = r.support.start
                let method = t.methods[r.method]
                var wake = t.wake[r.wake]
                if let o = r.wakeSecondsOverride {
                    wake.secondsSinceWake = o
                } else if r.wakeSecondsCleared == true {
                    wake.secondsSinceWake = nil
                } else if let at = wake.wakeAt {
                    wake.secondsSinceWake = derived(anchor, at)
                }
                var refs = t.recentBouts[r.recentBouts]
                for i in refs.indices {
                    refs[i].secondsBeforeMeasurement = r.boutSecondsOverride.flatMap { i < $0.count ? $0[i] : nil }
                        ?? derived(anchor, refs[i].endedAt)
                }
                let history = HistoryContext(
                    wake: wake, recentBouts: refs,
                    exertion: t.exertion[r.exertion].map { shifted($0, by: anchor) },
                    exposures: t.exposures[r.exposures].map { relativeExposure(t.exposureRefs[$0], anchor: anchor) },
                    exposureCoverage: t.exposureCoverage[r.exposureCoverage])
                return MeasurementEnvelope(
                    id: r.id ?? MeasurementEnvelope.makeId(method: method, support: r.support), metric: t.metric,
                    method: method, source: r.source, value: r.value, support: r.support,
                    displayBucket: r.displayBucket, localTime: r.localTime, validity: t.validity[r.validity],
                    regimeKey: r.regimeKey, activity: shifted(t.activity[r.activity], by: anchor),
                    decoderActivity: r.decoderActivity.map { shifted(t.activity[$0], by: anchor) },
                    preceding: shifted(t.preceding[r.preceding], by: anchor), sleepWear: t.sleepWear[r.sleepWear],
                    history: history, eligibility: r.eligibility.map { t.eligibility[$0] },
                    comparisons: t.comparisons[r.comparisons], finality: r.finality,
                    posture: r.posture.map { t.posture![$0] },
                    wearSignal: r.wearSignal.map { shifted(t.wearSignal![$0], by: anchor) })
            }
        }

        // MARK: Helpers

        /// A `precedes` reference stores, in the pool, the absolute instant its occurrence ended
        /// (`anchor - secondsSinceOccurrence`), so the same event shares one pooled entry across rows. `overlaps`
        /// references (0 s) are stored as they are.
        static func absoluteExposure(_ r: ExposureRef, anchor: Int) -> ExposureRef {
            var r = r
            if r.relation == Exposures.relationPrecedes { r.secondsSinceOccurrence = anchor &- r.secondsSinceOccurrence }
            return r
        }
        static func relativeExposure(_ r: ExposureRef, anchor: Int) -> ExposureRef {
            var r = r
            if r.relation == Exposures.relationPrecedes { r.secondsSinceOccurrence = anchor &- r.secondsSinceOccurrence }
            return r
        }

        // Shifts wrap (two's complement), so storing times relative to the row and adding the anchor back is exactly
        // invertible for any value, including adversarial extremes.
        static func shifted(_ c: ActivityComposition, by d: Int) -> ActivityComposition {
            var c = c; c.interval = Interval(c.interval.start &+ d, c.interval.end &+ d)
            c.transitionEvents = c.transitionEvents.map { shifted($0, by: d) }
            return c
        }
        static func shifted(_ p: PrecedingHistory, by d: Int) -> PrecedingHistory {
            var p = p; p.lookback = Interval(p.lookback.start &+ d, p.lookback.end &+ d)
            p.transitionEvents = p.transitionEvents.map { shifted($0, by: d) }
            return p
        }
        static func shifted(_ t: TransitionEventSummary, by d: Int) -> TransitionEventSummary {
            var t = t; t.interval = Interval(t.interval.start &+ d, t.interval.end &+ d); return t
        }
        static func shifted(_ w: WearSignalSummary, by d: Int) -> WearSignalSummary {
            var w = w; w.interval = Interval(w.interval.start &+ d, w.interval.end &+ d); return w
        }
        static func shifted(_ w: ExertionWindowSummary, by d: Int) -> ExertionWindowSummary {
            var w = w; w.interval = Interval(w.interval.start &+ d, w.interval.end &+ d); return w
        }
        /// `anchor - at`, wrapping; equal to the plain difference whenever that does not overflow, and the encoder
        /// only derives when it reproduces the stored value exactly.
        static func derived(_ anchor: Int, _ at: Int) -> Int { anchor &- at }

        /// Interning pool keyed by value equality (deterministic first-occurrence order). Lossless by construction:
        /// a row's index points at a value equal to its own.
        struct Pool<T: Codable & Hashable> {
            var values: [T] = []
            var byKey: [T: Int] = [:]
            mutating func index(_ v: T) -> Int {
                if let i = byKey[v] { return i }
                values.append(v)
                byKey[v] = values.count - 1
                return values.count - 1
            }
        }
    }
}
