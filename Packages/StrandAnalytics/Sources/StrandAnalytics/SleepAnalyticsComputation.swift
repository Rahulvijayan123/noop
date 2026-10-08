import Foundation

// SleepAnalyticsComputation.swift — the extractor entry point (docs/sleep-analytics/spec.md
// section 4 "Suggested API" + section 8 worker step 3): the ONE pure function the worker
// adapter and the app's local compute path both call, so a hosted document and a local
// document are the same arithmetic on the same lineage.
//
// Group computers (each in its own file, each owning its spec section):
//   * SleepAnalyticsContinuity + SleepAnalyticsStageDynamics (spec section 5)
//   * SleepAnalyticsMovement / SleepAnalyticsThermal / SleepAnalyticsPrv (spec sections 6-7)
//   * SleepAnalyticsMorning (spec-02: curves around the estimated wake boundary)
// All of them consume the ONE normalized timeline (SleepAnalyticsNormalization.swift) built
// from the adapter-assembled input; the document records the fingerprint, lineage and
// freshness the app's staleness guard checks.

extension SleepAnalyticsV1 {

    /// Compute the `daily.sleep_analytics_v1` document for one resolved main-night group.
    ///
    /// Pure and deterministic: same input + config -> the same document. A failure inside
    /// any group is that group's `unavailable`/`computationFailed` reason, never a thrown
    /// error and never a fabricated value (spec worker step 5: a failure withholds its own
    /// document, never the canonical score).
    public static func compute(input: SleepAnalyticsInput,
                               config: SleepAnalyticsConfig = .v2) -> SleepAnalyticsDocument {
        let timeline = normalize(input: input, config: config)
        // Thermal minute bins are built ONCE over the peri-sleep span and shared by the thermal
        // group and the morning-response temperature curve (spec-02 §3: no double aggregation).
        let thermalBins = thermalMinuteBins(timeline: timeline, input: input, config: config)
        let fingerprint = documentFingerprint(input: input, timeline: timeline, config: config)

        func fragmentInfo(for span: SleepAnalyticsTimeline.FragmentSpan) -> SleepAnalyticsFragmentInfo? {
            guard let fragment = input.fragments.first(where: { $0.id == span.id }) else { return nil }
            return SleepAnalyticsFragmentInfo(
                id: fragment.id, sourceKind: fragment.sourceKind,
                startAt: isoUTC(fragment.start), endAt: isoUTC(fragment.end),
                edited: fragment.edited, editRevision: fragment.editRevision,
                start: fragment.start, end: fragment.end)
        }

        return SleepAnalyticsDocument(
            schemaVersion: schemaVersion,
            algorithmVersion: algorithmVersion,
            configVersion: config.version,
            scope: scope,
            timezone: input.timezoneId,
            startAt: isoUTC(timeline.windowStart),
            endAt: isoUTC(timeline.windowEnd),
            start: timeline.windowStart,
            end: timeline.windowEnd,
            fragments: timeline.fragments.compactMap(fragmentInfo(for:)),
            fingerprint: fingerprint,
            stageSourceVersion: input.stageSourceVersion,
            nativeEpochResolutionSeconds: timeline.fragments
                .first(where: { $0.sourceKind == .nativeWhoop })?.sourceEpochSeconds,
            inputRevision: input.inputRevision,
            continuity: SleepAnalyticsV1.continuityGroup(timeline: timeline, input: input, config: config),
            stageDynamics: SleepAnalyticsV1.stageDynamicsGroup(timeline: timeline, input: input, config: config),
            movement: SleepAnalyticsV1.movementGroup(timeline: timeline, input: input, config: config),
            thermal: SleepAnalyticsV1.thermalGroup(timeline: timeline, input: input, config: config,
                                                   bins: thermalBins),
            prvDiagnostics: SleepAnalyticsV1.prvGroup(timeline: timeline, input: input, config: config),
            morningResponse: SleepAnalyticsV1.morningResponseGroup(timeline: timeline, input: input,
                                                                   config: config, thermalBins: thermalBins))
    }
}
