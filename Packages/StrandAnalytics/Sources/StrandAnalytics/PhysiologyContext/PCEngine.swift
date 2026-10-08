import Foundation

// PCEngine.swift — orchestrates the seven systems into one device-day document (spec §5).
//
// OWNER: lead. The flow follows the spec's conceptual order:
//   1. original observations with availability → input-contract checks and causal filtering (System A)
//   2. per-metric validity and measurement regime (System A)
//   3. heart-rate independent activity tracks, sleep/wake + wear, confirmed exposure events (Systems B, C, E)
//   4. context joined to the complete support interval of each measurement (lead join, System B eligibility)
//   5. recent history, context-matched references and bout responses (Systems C, D, F)
//   6. transient episodes and persistent-change summaries (System F)
//   7. functional features and the feature registry (System G)
//
// The engine never reads a clock: `DayInput.generatedAt` and `availabilityCutoff` are inputs, so a replay at the
// same cutoff reproduces the same document.

extension PhysiologyContext {

    public enum Engine {

        public static let version = "pc-engine-1"

        // MARK: Reason codes
        public static let historyFromFutureDropped: ReasonCode = "history_from_future_dropped"
        public static let noMeasurements: ReasonCode = "no_measurements"
        public static let noObservations: ReasonCode = "no_observations"
        public static let activityUnavailable: ReasonCode = "activity_evidence_unavailable"
        public static let sleepUnavailable: ReasonCode = "sleep_evidence_unavailable"
        public static let sharedBeatIntervals: ReasonCode = "shared_beat_intervals"
        public static let labelsReadHeartRate: ReasonCode = "labels_read_heart_rate"
        public static let motionSharedAcrossSystems: ReasonCode = "motion_shared_across_systems"
        public static let sharedOpticalSensor: ReasonCode = "shared_optical_sensor"

        public static let reasonCodes: [ReasonCode] = [
            historyFromFutureDropped, noMeasurements, noObservations, activityUnavailable,
            sleepUnavailable, sharedBeatIntervals, labelsReadHeartRate, motionSharedAcrossSystems,
            sharedOpticalSensor,
        ]

        /// Series key of the engine's own per-day motion-coverage value (feeds trailing exertion windows).
        public static let motionCoverageSeries = "coverage.motion_observed_s"
        /// Method of the heart-rate windows the engine derives from raw samples.
        public static let heartRateWindowMethod = MethodRef(id: "context.heart_rate.5min_mean",
                                                            algorithmVersion: "pc-hr-window-1",
                                                            aggregation: .mean, windowS: 300, units: "bpm")
        static let rawLookbackS = 30 * 3600
        static let rawLookaheadS = 6 * 3600

        /// Build one device-day document. Deterministic for equal `(input, history, policy)`.
        public static func buildDay(_ rawInput: DayInput, history rawHistory: HistoryInput,
                                    policy: Policy = .default) -> DayDocument {
            // The cutoff is enforced here, once, before any system reads an input (spec §6.3, V10). How much was
            // excluded is NOT recorded in the document: knowing that late data exists is itself information a live
            // decision did not have. Callers that want the counts (worker telemetry) call `causalView` directly.
            let (input, _) = causalView(rawInput)
            let identity = input.identity
            let mode = input.mode
            let causal = mode == .causalLive
            let cutoff = causal ? input.availabilityCutoff : Int.max
            var statusReasons: [ReasonCode] = []

            // History strictly before the day (spec §12.1: score before incorporating).
            let history = strictlyEarlier(rawHistory, than: identity.day, dayStart: identity.dayWindow.start,
                                          mode: mode)
            if history.dropped > 0 { statusReasons.append(historyFromFutureDropped) }

            // 1-2. Input contract and causal availability.
            let (observations, inputReport) = SignalValidityEngine.sanitize(input, config: policy.validity)
            let readWindow = Interval(identity.dayWindow.start - rawLookbackS, identity.dayWindow.end + rawLookaheadS)

            // 3. Heart-rate independent tracks, plus the decoder track for display only.
            let epochInputs = input.activityEpochs.filter { !causal || $0.epoch.startTs < cutoff }
            let hart = IntervalAlgebra.resolve(IntervalAlgebra.records(fromEpochs: epochInputs), source: .hartEpochs,
                                               heartRateDependent: false, availableBy: causal ? cutoff : nil)
            let strap = MotionEvidence.strapTrack(motion: observations.motion, steps: observations.steps,
                                                  window: readWindow, config: policy.eligibility.motion)
            let intervalInputs = input.activityIntervals.filter { !causal || $0.interval.start < cutoff }
            let decoder = IntervalAlgebra.resolve(IntervalAlgebra.records(fromIntervals: intervalInputs),
                                                  source: .decoderIntervals, heartRateDependent: true,
                                                  availableBy: causal ? cutoff : nil)
            if hart.spans.isEmpty && strap.spans.isEmpty { statusReasons.append(activityUnavailable) }

            let timeline = SignalValidityEngine.regimeTimeline(input, config: policy.validity)
            let episodes = SleepRhythm.episodes(sessions: input.sleepSessions, priorSleep: history.value.priorSleep,
                                                identity: identity, mode: mode,
                                                cutoff: input.availabilityCutoff, config: policy.sleep)
            if episodes.isEmpty { statusReasons.append(sleepUnavailable) }
            let events = Exposures.current(input.exposures, mode: mode, cutoff: input.availabilityCutoff)

            // Respiratory-rate estimates for the post-bout respiratory return (spec-02), filtered by the same causal
            // rule the envelopes use below: a live document never reads an estimate past its cutoff.
            let respiration = input.measurements.filter { m in
                guard m.metric == .respiratoryRate else { return false }
                guard causal else { return true }
                return m.support.end <= cutoff && (m.availableAt.map { $0 <= cutoff } ?? true)
            }
            let bouts = ExertionBouts.detect(identity: identity, hart: hart, strap: strap, workouts: input.workouts,
                                             observations: observations, mode: mode,
                                             cutoff: input.availabilityCutoff, config: policy.exertion,
                                             respiration: respiration)
            let allBouts = (history.value.bouts + bouts).sorted { $0.interval < $1.interval }
            let coverage = motionCoverage(history: history.value.dailyValues, today: strap, hart: hart,
                                          identity: identity)

            // 4-5. Envelopes over each measurement's whole support interval.
            var measurements = input.measurements
            measurements += heartRateWindows(observations.heartRate, dayWindow: identity.dayWindow)
            // A measurement not available at the cutoff is left out without a trace: recording that it exists would
            // itself be information the live decision did not have (the same rule as `causalView`).
            measurements = measurements.filter { m in
                guard causal else { return true }
                let available = m.availableAt.map { $0 <= cutoff } ?? true
                return m.support.end <= cutoff && available
            }
            measurements.sort { ($0.support, $0.method.id, $0.metric.rawValue) < ($1.support, $1.method.id, $1.metric.rawValue) }

            var registry: [String: MeasurementRegime] = [:]
            var envelopes: [MeasurementEnvelope] = []
            envelopes.reserveCapacity(measurements.count)
            for m in measurements {
                let primary = preferredTrack(hart: hart, strap: strap, over: m.support)
                let validity = SignalValidityEngine.assess(m, observations: observations, motion: primary,
                                                           config: policy.validity)
                let regime = SignalValidityEngine.regime(for: m, timeline: timeline, device: input.regime)
                registry[regime.key] = regime
                let activity = IntervalAlgebra.composition(over: m.support, track: primary, config: policy.join)
                let decoderActivity = decoder.spans.isEmpty ? nil
                    : IntervalAlgebra.composition(over: m.support, track: decoder, config: policy.join)
                let preceding = IntervalAlgebra.precedingHistory(before: m.support.start, track: primary,
                                                                 lookbackS: policy.join.precedingLookbackS)
                let sleepWear = SleepRhythm.sleepWear(for: m.support, episodes: episodes,
                                                      observations: observations, config: policy.sleep,
                                                      excludingSplitGaps: m.method.aggregation == .session)
                let wake = SleepRhythm.wakeReference(at: m.support.start, episodes: episodes, mode: mode,
                                                     cutoff: input.availabilityCutoff, config: policy.sleep)
                let recent = ExertionBouts.recentRefs(before: m.support.start, bouts: allBouts,
                                                      config: policy.exertion)
                let exertion = ExertionBouts.windows(endingAt: m.support.start, bouts: allBouts, coverage: coverage,
                                                     config: policy.exertion)
                let history = HistoryContext(
                    wake: wake, recentBouts: recent, exertion: exertion,
                    exposures: Exposures.refs(for: m.support, events: events, config: policy.exposure),
                    exposureCoverage: Exposures.categoryStatus(for: m.support, events: events,
                                                               config: policy.exposure))
                let verdicts = Eligibility.comparisons(for: m.metric, method: m.method).map { kind in
                    Eligibility.evaluate(kind, metric: m.metric, support: m.support, validity: validity,
                                         activity: activity, preceding: preceding, sleepWear: sleepWear,
                                         exertion: exertion, recentBouts: recent, config: policy.eligibility)
                }
                envelopes.append(MeasurementEnvelope(
                    id: MeasurementEnvelope.makeId(method: m.method, support: m.support), metric: m.metric,
                    method: m.method, source: m.source, value: m.value, support: m.support,
                    displayBucket: m.displayBucket,
                    localTime: localTime(at: m.support.start, timezoneId: identity.timezoneId),
                    validity: validity, regimeKey: regime.key, activity: activity,
                    decoderActivity: decoderActivity, preceding: preceding, sleepWear: sleepWear, history: history,
                    eligibility: verdicts, comparisons: [], finality: .provisional))
            }

            let finality = documentFinality(input, policy: policy)
            for i in envelopes.indices { envelopes[i].finality = finality }

            let sleep = SleepRhythm.summary(episodes: episodes, priorSleep: history.value.priorSleep, identity: identity,
                                            observations: observations, mode: mode,
                                            cutoff: input.availabilityCutoff, config: policy.sleep)
            let functional = Functional.daySummary(identity: identity, bouts: bouts, hart: hart, strap: strap,
                                                   observations: observations, sleep: sleep, mode: mode,
                                                   cutoff: input.availabilityCutoff, config: policy.functional)
            // Device-level products carry their own definition version in the regime, so values computed under
            // an older definition (e.g. pc-functional-1) never pool with the current one.
            let boutRegimeKey = deviceRegimeKey(input.regime, timeline: timeline, dayWindow: identity.dayWindow,
                                                product: policy.exertion.version)
            let functionalRegimeKey = deviceRegimeKey(input.regime, timeline: timeline, dayWindow: identity.dayWindow,
                                                      product: policy.functional.version)

            // Daily context-conditioned values: envelopes, bouts, functional, and the engine's coverage series.
            var dailyValues = ContextReferences.dailyValues(envelopes: envelopes, identity: identity, mode: mode,
                                                            finality: finality, config: policy.reference)
            dailyValues += ExertionBouts.dailyValues(bouts, identity: identity, regimeKey: boutRegimeKey,
                                                     mode: mode, config: policy.exertion)
            dailyValues += Functional.dailyValues(functional, regimeKey: functionalRegimeKey, mode: mode,
                                                  finality: finality, config: policy.functional)
            if let today = coverage.last, today.day == identity.day {
                dailyValues.append(DailyValue(day: identity.day, seriesKey: motionCoverageSeries,
                                              regimeKey: "coverage", metric: nil, value: Double(today.observedS),
                                              units: "s", supportCount: 1, supportUnit: "day",
                                              supportS: today.observedS, mode: mode, finality: finality))
            }
            dailyValues.sort { ($0.seriesKey, $0.regimeKey) < ($1.seriesKey, $1.regimeKey) }

            let fingerprint = policy.fingerprint
            let compared = ContextReferences.compare(dailyValues, history: history.value.dailyValues,
                                                     frozen: history.value.frozenReferences, day: identity.day,
                                                     policyFingerprint: fingerprint, config: policy.reference)
            attach(compared.comparisons, to: &envelopes, values: dailyValues)

            let dependence = dependenceNotes(sleep: sleep)
            let episodesOut = ChangeDetection.episodes(
                today: dailyValues, history: history.value.dailyValues,
                frozen: history.value.frozenReferences + compared.newFrozen, boundaries: timeline.boundaries,
                day: identity.day, mode: mode, finality: finality, policyFingerprint: fingerprint,
                change: policy.change, reference: policy.reference)
            let multiSignal = ChangeDetection.multiSignal(comparisons: compared.comparisons, dependence: dependence,
                                                          day: identity.day, config: policy.change)

            let exposureSummary = Exposures.daySummary(revisions: input.exposures, events: events,
                                                       envelopes: envelopes, bouts: bouts, identity: identity,
                                                       mode: mode, cutoff: input.availabilityCutoff,
                                                       config: policy.exposure)
            let availability = SignalValidityEngine.availabilityMatrix(input, observations: observations,
                                                                       config: policy.validity)
            var regimes = timeline
            regimes.registry = registry.keys.sorted().map { registry[$0]! }
            let features = FeatureRegistry.evaluate(functional: functional, regimes: regimes,
                                                    availability: availability)
            let selection = Eligibility.selection(envelopes: envelopes, observations: observations,
                                                  dayWindow: identity.dayWindow, dailyValues: dailyValues,
                                                  reference: policy.reference)

            let hasObservations = !observations.heartRate.isEmpty || !observations.beatIntervals.isEmpty
                || !observations.motion.isEmpty
            if measurements.isEmpty { statusReasons.append(noMeasurements) }
            if !hasObservations { statusReasons.append(noObservations) }
            let status: ProductStatus
            if measurements.isEmpty && !hasObservations {
                status = .noData
            } else if measurements.isEmpty || statusReasons.contains(activityUnavailable)
                        || statusReasons.contains(sleepUnavailable) {
                status = .partial
            } else {
                status = .available
            }

            let header = DocumentHeader(
                schemaVersion: PhysiologyContext.schemaVersion, contractVersion: PhysiologyContext.contractVersion,
                identity: identity,
                interpretation: Interpretation(mode: mode, finality: finality,
                                               availabilityCutoff: input.availabilityCutoff,
                                               generatedAt: input.generatedAt),
                versions: policy.versions, policyFingerprint: fingerprint,
                inputFingerprint: inputFingerprint(input, observations: observations, measurements: measurements,
                                                   history: history.value, cutoff: cutoff, finality: finality),
                inputRevisions: input.inputRevisions.sorted { ($0.input, $0.revision) < ($1.input, $1.revision) })

            var document = DayDocument(header: header, status: status, statusReasons: statusReasons.sorted(),
                                       inputReport: inputReport, availability: availability, regimes: regimes,
                                       envelopes: envelopes, sleep: sleep, bouts: bouts,
                                       exertion: ExertionBouts.windows(endingAt: min(identity.dayWindow.end, cutoff),
                                                                       bouts: allBouts, coverage: coverage,
                                                                       config: policy.exertion),
                                       exposures: exposureSummary, dailyValues: dailyValues,
                                       comparisons: compared.comparisons, newFrozenReferences: compared.newFrozen,
                                       episodes: episodesOut, multiSignal: multiSignal, functional: functional,
                                       features: features, dependence: dependence, selection: selection)
            // Sustained high / low pulse episodes over qualified inactive HR (spec-02). Heart-rate independent
            // qualification: the HART / strap tracks, never the HR-reading decoder track. Earlier days' bouts too:
            // the detector reads the evening before the day, and a bout's follow-up is never inactive.
            document.pulseEpisodes = PulseEpisodes.summarize(identity: identity, observations: observations,
                                                             hart: hart, strap: strap, episodes: episodes,
                                                             bouts: allBouts, mode: mode,
                                                             cutoff: input.availabilityCutoff, config: policy.pulse)
            return document
        }

        // MARK: - Steps

        /// The input as a causal decision at `availabilityCutoff` could have seen it: observations and records with
        /// a sensor time at or after the cutoff, or an availability time after it, are removed. Unknown availability
        /// falls back to sensor time (reported by System A as the availability basis). Retrospective input passes
        /// through unchanged.
        public static func causalView(_ input: DayInput) -> (DayInput, [Diagnostic]) {
            guard input.mode == .causalLive else { return (input, []) }
            let c = input.availabilityCutoff
            func ok(_ ts: Int, _ at: Int?) -> Bool { ts < c && (at.map { $0 <= c } ?? true) }
            var out = input
            out.heartRate = input.heartRate.filter { ok($0.ts, $0.availableAt) }
            out.beatIntervals = input.beatIntervals.filter { ok($0.ts, $0.availableAt) }
            out.motion = input.motion.filter { ok($0.ts, $0.availableAt) }
            out.steps = input.steps.filter { ok($0.ts, $0.availableAt) }
            out.skinTemperature = input.skinTemperature.filter { ok($0.ts, $0.availableAt) }
            out.wearEvents = input.wearEvents.filter { ok($0.ts, $0.availableAt) }
            out.bandSleepStates = input.bandSleepStates.filter { ok($0.ts, $0.availableAt) }
            // A published session is known only once it was published; unknown publication means "at its end".
            out.sleepSessions = input.sleepSessions.filter {
                $0.interval.start < c && ($0.availableAt ?? $0.interval.end) <= c
            }
            out.workouts = input.workouts.filter { ok($0.interval.start, $0.availableAt) }
            out.activityEpochs = input.activityEpochs.filter { ok($0.epoch.startTs, $0.availableAt) }
            out.activityIntervals = input.activityIntervals.filter { ok($0.interval.start, $0.availableAt) }
            out.placements = input.placements.filter { ok($0.start, $0.recordedAt) }
            out.exposures = input.exposures.filter { $0.availableAt <= c }
            let removed = (input.heartRate.count - out.heartRate.count)
                + (input.beatIntervals.count - out.beatIntervals.count) + (input.motion.count - out.motion.count)
                + (input.steps.count - out.steps.count) + (input.skinTemperature.count - out.skinTemperature.count)
                + (input.wearEvents.count - out.wearEvents.count)
                + (input.bandSleepStates.count - out.bandSleepStates.count)
            let records = (input.sleepSessions.count - out.sleepSessions.count)
                + (input.workouts.count - out.workouts.count)
                + (input.activityEpochs.count - out.activityEpochs.count)
                + (input.activityIntervals.count - out.activityIntervals.count)
                + (input.placements.count - out.placements.count)
            let exposures = input.exposures.count - out.exposures.count
            return (out, [Diagnostic("causal_excluded_observations", Double(removed)),
                          Diagnostic("causal_excluded_records", Double(records)),
                          Diagnostic("causal_excluded_exposure_revisions", Double(exposures))])
        }

        /// Drop any history element from the day itself or later (it could not be prior history).
        ///
        /// Frozen references are the exception in retrospective mode: every registered reference is passed on, so a
        /// back-filled earlier day never registers a second "version 1" for a (series, regime) that already has one
        /// (the registered reference is the authority and is never replaced). References use a frozen reference only
        /// for days after its selection window. Causal mode keeps only references whose window ended and that were
        /// created before the day (the worker also passes only references registered by the cutoff).
        static func strictlyEarlier(_ h: HistoryInput, than day: String, dayStart: Int,
                                    mode: ProcessingMode) -> (value: HistoryInput, dropped: Int) {
            let values = h.dailyValues.filter { $0.day < day }
            let bouts = h.bouts.filter { $0.day < day && $0.interval.end <= dayStart }
            let frozen = mode == .retrospective
                ? h.frozenReferences
                : h.frozenReferences.filter { $0.toDay < day && $0.createdForDay < day }
            let sleep = h.priorSleep.filter { $0.interval.end <= dayStart || ($0.sourceDay.map { $0 < day } ?? false) }
            let dropped = (h.dailyValues.count - values.count) + (h.bouts.count - bouts.count)
                + (h.frozenReferences.count - frozen.count) + (h.priorSleep.count - sleep.count)
            return (HistoryInput(dailyValues: values, bouts: bouts, frozenReferences: frozen, priorSleep: sleep),
                    dropped)
        }

        /// The heart-rate independent track with more covered seconds over `interval`; HART wins ties.
        static func preferredTrack(hart: ResolvedTrack, strap: ResolvedTrack, over interval: Interval) -> ResolvedTrack {
            let h = covered(hart, interval), s = covered(strap, interval)
            if h == 0 && s == 0 { return hart.spans.isEmpty ? strap : hart }
            return h >= s ? hart : strap
        }

        static func covered(_ track: ResolvedTrack, _ interval: Interval) -> Int {
            IntervalAlgebra.overlapping(track.spans, interval).reduce(0) { $0 + $1.interval.overlapSeconds(with: interval) }
        }

        /// 5-minute heart-rate means on the local-midnight grid (the series grid), from every sample the input
        /// contract accepted (System A rejects contract failures; an extreme but contract-valid value is kept and
        /// judged by the validity assessment, never dropped here). Windows with no sample produce no measurement.
        static func heartRateWindows(_ hr: [HeartRateObservation], dayWindow: Interval) -> [MeasurementInput] {
            let width = heartRateWindowMethod.windowS
            var sums: [Int: (sum: Int, n: Int)] = [:]
            for s in hr where dayWindow.contains(s.ts) {
                let b = dayWindow.start + ((s.ts - dayWindow.start) / width) * width
                let cur = sums[b] ?? (0, 0)
                sums[b] = (cur.sum + s.bpm, cur.n + 1)
            }
            return sums.keys.sorted().compactMap { b in
                let v = sums[b]!
                let end = min(b + width, dayWindow.end)
                guard end > b else { return nil }
                return MeasurementInput(metric: .heartRate, method: heartRateWindowMethod,
                                        source: SourceRef(product: .contextDerived, key: "heart_rate_5min@\(b)"),
                                        value: Double(v.sum) / Double(v.n), support: Interval(b, end),
                                        sampleCount: v.n, coverage: Double(v.n) / Double(end - b))
            }
        }

        /// Observed motion seconds per earlier day (from history) and today (from the tracks).
        static func motionCoverage(history: [DailyValue], today strap: ResolvedTrack, hart: ResolvedTrack,
                                   identity: DayIdentity) -> [DayCoverage] {
            var out: [DayCoverage] = history.filter { $0.seriesKey == motionCoverageSeries }
                .sorted { $0.day < $1.day }
                .map { DayCoverage(day: $0.day, interval: dayInterval($0.day, timezoneId: identity.timezoneId),
                                   observedS: Int($0.value)) }
            // Today's observed seconds are the union of both heart-rate independent tracks' covered spans, kept as
            // intervals so a trailing window can clip the day exactly instead of prorating it.
            let spans = (strap.spans + hart.spans).compactMap { $0.interval.intersection(identity.dayWindow) }.sorted()
            var union: [Interval] = []
            for s in spans {
                if var last = union.last, s.start <= last.end {
                    last.end = max(last.end, s.end)
                    union[union.count - 1] = last
                } else {
                    union.append(s)
                }
            }
            let observed = union.reduce(0) { $0 + $1.duration }
            out.append(DayCoverage(day: identity.day, interval: identity.dayWindow, observedS: observed,
                                   observedIntervals: union))
            return out
        }

        /// `[local midnight, next local midnight)` of a day key in a zone.
        public static func dayInterval(_ day: String, timezoneId: String) -> Interval {
            let zone = TimeZone(identifier: timezoneId) ?? TimeZone(identifier: "UTC")!
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let start = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                  let next = cal.date(byAdding: .day, value: 1, to: start) else { return Interval(0, 0) }
            return Interval(Int(start.timeIntervalSince1970), Int(next.timeIntervalSince1970))
        }

        static func documentFinality(_ input: DayInput, policy: Policy) -> Finality {
            guard input.mode == .retrospective else { return .provisional }
            return input.availabilityCutoff >= input.identity.dayWindow.end + policy.join.finalAfterDayEndS
                ? .final : .provisional
        }

        /// Copy each comparison onto the envelope whose value it compares. Only a daily value made of exactly one
        /// envelope (a nightly product) is that envelope's own value; an aggregate (the median of many 5-minute
        /// windows) is never shown as one window's difference — it stays a document-level comparison.
        static func attach(_ comparisons: [ReferenceComparison], to envelopes: inout [MeasurementEnvelope],
                           values: [DailyValue]) {
            guard !comparisons.isEmpty else { return }
            var index: [String: Int] = [:]
            for (i, e) in envelopes.enumerated() { index[e.id] = i }
            for v in values where v.sourceIds.count == 1 {
                let cs = comparisons.filter { $0.seriesKey == v.seriesKey && $0.regimeKey == v.regimeKey }
                guard !cs.isEmpty, let i = index[v.sourceIds[0]] else { continue }
                envelopes[i].comparisons += cs
            }
        }

        /// Regime of products that belong to the device rather than to one measurement method (bout responses,
        /// functional features): vendor, family, source kind, firmware and the placement that covered most of the
        /// day. Stable for a device whatever measurement families happen to exist that day.
        static func deviceRegimeKey(_ device: DeviceRegimeInput, timeline: RegimeTimeline,
                                    dayWindow: Interval, product: String) -> String {
            var byPlacement: [String: Int] = [:]
            for seg in timeline.placements {
                byPlacement[seg.placement, default: 0] += seg.interval.overlapSeconds(with: dayWindow)
            }
            let placement = byPlacement.filter { $0.value > 0 }
                .max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? "unknown"
            let text = ["device", device.vendor, device.deviceFamily ?? "", device.sourceKind ?? "",
                        device.firmware ?? "", placement, product].joined(separator: "|")
            return "dev-" + PhysiologyContext.fnv1a(text)
        }

        /// Dependence between derived signals and labels (spec §9 last bullet, §12.3, V13).
        static func dependenceNotes(sleep: SleepRhythmSummary) -> [DependenceNote] {
            var notes: [DependenceNote] = [
                DependenceNote(group: "beat_intervals",
                               members: [MetricKind.hrvRmssd.rawValue, MetricKind.hrvSdnn.rawValue,
                                         MetricKind.respiratoryRate.rawValue],
                               note: sharedBeatIntervals),
                DependenceNote(group: "heart_rate",
                               members: [MetricKind.heartRate.rawValue, MetricKind.restingHeartRate.rawValue,
                                         "sleep_detector", "decoder_intervals"],
                               note: labelsReadHeartRate),
                DependenceNote(group: "optical_pulse",
                               members: [MetricKind.heartRate.rawValue, MetricKind.restingHeartRate.rawValue,
                                         MetricKind.hrvRmssd.rawValue, MetricKind.hrvSdnn.rawValue,
                                         MetricKind.respiratoryRate.rawValue],
                               note: sharedOpticalSensor),
                DependenceNote(group: "strap_motion",
                               members: ["eligibility_stillness", "exertion_bouts", "functional_features"],
                               note: motionSharedAcrossSystems),
            ]
            notes += sleep.dependence
            return notes.sorted { ($0.group, $0.note) < ($1.group, $1.note) }
        }

        /// FNV-1a over every input the engine read (after sanitizing and the causal cutoff), so appending data that
        /// was not available at the cutoff does not change the fingerprint and any change to a used input does. The
        /// high-volume raw streams are hashed field by field; every record list and the history go through the
        /// canonical encoder, so a new field on any input type is covered without editing this function.
        static func inputFingerprint(_ input: DayInput, observations o: SanitizedObservations,
                                     measurements: [MeasurementInput], history: HistoryInput,
                                     cutoff: Int, finality: Finality) -> String {
            var h = FNV()
            h.add(input.mode.rawValue); h.add(input.mode == .causalLive ? input.availabilityCutoff : 0)
            // A retrospective document's cutoff matters only through its finality (provisional → final once the
            // day is 30 h closed); without it the finality rebuild would publish "unchanged" forever.
            h.add(finality.rawValue)
            for s in o.heartRate { h.add(s.ts); h.add(s.bpm) }
            h.add("|rr")
            for b in o.beatIntervals { h.add(b.ts); h.add(b.rrMs); h.add(b.seq); h.add(b.ord ?? -1); h.add(b.channel ?? -1) }
            h.add("|mo")
            for m in o.motion { h.add(m.ts); h.add(m.dynAccelG ?? -1); h.add(m.x ?? -9); h.add(m.y ?? -9); h.add(m.z ?? -9) }
            h.add("|st")
            for s in o.steps { h.add(s.ts); h.add(s.counter); h.add(s.activityClass ?? -1) }
            h.add("|sk")
            for s in o.skinTemperature { h.add(s.ts); h.add(s.celsius ?? -999) }
            h.add("|we")
            for w in o.wearEvents { h.add(w.ts); h.add(w.state.rawValue); h.add(w.kind) }
            h.add("|bs")
            for b in o.bandSleepStates { h.add(b.ts); h.add(b.state) }
            h.add("|br")
            for b in o.breaks { h.add(b.start); h.add(b.end) }
            struct Records: Encodable {
                let identity: DayIdentity
                let measurements: [MeasurementInput]
                let sleepSessions: [SleepSessionInput]
                let workouts: [WorkoutInput]
                let activityEpochs: [ActivityEpochInput]
                let activityIntervals: [ActivityIntervalInput]
                let placements: [PlacementInput]
                let regime: DeviceRegimeInput
                let exposures: [ExposureEventRevision]
                let inputRevisions: [InputRevision]
                let history: HistoryInput
            }
            let records = Records(identity: input.identity, measurements: measurements,
                                  sleepSessions: input.sleepSessions, workouts: input.workouts,
                                  activityEpochs: input.activityEpochs, activityIntervals: input.activityIntervals,
                                  placements: input.placements, regime: input.regime, exposures: input.exposures,
                                  inputRevisions: input.inputRevisions.sorted { ($0.input, $0.revision) < ($1.input, $1.revision) },
                                  history: history)
            h.add("|rec")
            if let data = try? PhysiologyContext.encoder().encode(records) {
                for byte in data { h.addByte(byte) }
            } else {
                h.add("unencodable")
            }
            return h.hex
        }
    }

    /// Incremental FNV-1a 64 over typed fields (cheap enough for a day of 1 Hz streams).
    struct FNV {
        private(set) var state: UInt64 = 0xcbf29ce484222325
        mutating func add(_ s: String) {
            for b in s.utf8 { state = (state ^ UInt64(b)) &* 0x100000001b3 }
            state = (state ^ 0x1f) &* 0x100000001b3
        }
        mutating func add(_ i: Int) {
            var v = UInt64(bitPattern: Int64(i))
            for _ in 0..<8 { state = (state ^ (v & 0xff)) &* 0x100000001b3; v >>= 8 }
        }
        mutating func add(_ d: Double) { add(Int(truncatingIfNeeded: Int64(bitPattern: d.bitPattern))) }
        mutating func addByte(_ b: UInt8) { state = (state ^ UInt64(b)) &* 0x100000001b3 }
        var hex: String {
            let s = String(state, radix: 16)
            return String(repeating: "0", count: max(0, 16 - s.count)) + s
        }
    }
}
