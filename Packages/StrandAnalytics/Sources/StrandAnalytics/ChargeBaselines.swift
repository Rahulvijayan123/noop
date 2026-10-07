import Foundation

// ChargeBaselines.swift — the CAUSAL personal baselines the phone's Charge re-score scores each night against
// (BaselineStandard fix A, audit 2026-10-07 "Charge on the phone").
//
// What was wrong. `IntelligenceEngine.analyzeRecent` folded ONE baseline per metric over the whole merged history
// (including the night being scored and every later night) and z-scored every night of the scan window against
// that end-of-history state: look-ahead plus self-inclusion, so a stored Charge changed whenever later nights
// arrived. HRV was folded on raw milliseconds; the skin-temperature baseline saw only the nights of the current
// scan window (21 days on a normal pass, the whole history on a 4000-day rescore), and a strap-only user's HRV,
// resting-HR and respiration baselines likewise saw only the scan window. No logged confounder was excluded.
//
// What this does. Every metric is folded with `BaselineStandard.causalFold` (the cherry-picked as-of fold), so a
// night is judged ONLY against nights strictly before it (rule 2), over every stored night, calendar-padded
// (rule 7), with confounded nights out of the fold but still scored (rule 3), restarting at each device-regime
// change and at the manual recalibration epoch (rule 6). HRV is folded on ln(RMSSD) with
// `Baselines.readinessHRVLnCfg` and scored through `RecoveryScorer.HRVScale.ln` (rule 1); SDNN nights never enter.
// The method-consistent CHILD fold (NOOP's own computed values) is preferred and, while thin, shrunk toward the
// all-method PARENT fold (`Baselines.resolveHierarchical`), so an import→strap hand-over neither resets the user
// to "calibrating" nor silently pools two methods.
//
// RecoveryScorer's weights, terms and logistic mapping are unchanged. The shift this causes in Charge values is
// measured by `ChargeBaselinesShiftTests` on a realistic synthetic 90-night tape (see that file's header).

public enum ChargeBaselines {

    /// The nightly series the Charge baselines are built from. Keys are `yyyy-MM-dd` wake days.
    public struct Inputs: Sendable {
        /// HRV (ms) per day with every method pooled: an import wins its day, NOOP's computed value fills
        /// the rest. The PARENT of the hierarchical fold.
        public var hrvMerged: [String: Double]
        /// NOOP's own computed HRV (ms) per day: the method the scored nights use. The CHILD. nil = one method.
        public var hrvComputed: [String: Double]?
        public var rhrMerged: [String: Double]
        public var rhrComputed: [String: Double]?
        public var respMerged: [String: Double]
        public var respComputed: [String: Double]?
        /// Nightly ABSOLUTE wrist skin temperature (°C) over the WHOLE stored history plus this pass.
        public var skinAbsolute: [String: Double]
        /// Confounders, SDNN days, regimes and per-metric reference epochs.
        public var context: BaselineStandard.Context
        /// Newest day to resolve; defaults to the newest key of any series.
        public var through: String?

        public init(hrvMerged: [String: Double], hrvComputed: [String: Double]? = nil,
                    rhrMerged: [String: Double], rhrComputed: [String: Double]? = nil,
                    respMerged: [String: Double], respComputed: [String: Double]? = nil,
                    skinAbsolute: [String: Double] = [:],
                    context: BaselineStandard.Context = BaselineStandard.Context(),
                    through: String? = nil) {
            self.hrvMerged = hrvMerged; self.hrvComputed = hrvComputed
            self.rhrMerged = rhrMerged; self.rhrComputed = rhrComputed
            self.respMerged = respMerged; self.respComputed = respComputed
            self.skinAbsolute = skinAbsolute
            self.context = context
            self.through = through
        }
    }

    /// Per-day causal baselines plus the forward-looking end state.
    public struct Resolved: Sendable {
        /// The baselines each day is scored against: built only from days strictly before it.
        public let byDay: [String: AnalyticsEngine.ProfileBaselines]
        /// After the newest day, in the current regime (for "tonight" / display).
        public let end: AnalyticsEngine.ProfileBaselines
        /// Days whose HRV baseline was the child shrunk toward the parent (`AsOfBaseline.fallbackUsed`).
        public let hrvFallbackDays: Set<String>

        /// The baselines `day` is scored against. A day outside the folded span (newer than every input)
        /// is judged against the end state, which only holds days before it.
        public func baselines(for day: String) -> AnalyticsEngine.ProfileBaselines {
            byDay[day] ?? end
        }
    }

    /// Resolve the causal Charge baselines for every calendar day of the inputs.
    public static func asOf(_ inputs: Inputs) -> Resolved {
        let ctx = inputs.context
        let allKeys = [inputs.hrvMerged.keys, inputs.rhrMerged.keys, inputs.respMerged.keys,
                       inputs.skinAbsolute.keys].flatMap { $0 }
            + (inputs.hrvComputed?.keys.map { $0 } ?? [])
            + (inputs.rhrComputed?.keys.map { $0 } ?? [])
            + (inputs.respComputed?.keys.map { $0 } ?? [])
        let through = ([inputs.through] + [allKeys.max()]).compactMap { $0 }.max()

        func hierarchical(_ merged: [String: Double], _ computed: [String: Double]?,
                          _ metric: BaselineStandard.Metric) -> (byDay: [String: AsOfBaseline], end: AsOfBaseline) {
            let cfg = BaselineStandard.cfg(metric)
            let parent = BaselineStandard.causalFold(merged, metric: metric, through: through, context: ctx)
            guard let computed else {
                var byDay: [String: AsOfBaseline] = [:]
                for (k, s) in parent.before {
                    byDay[k] = AsOfBaseline(state: s, asOfDay: parent.asOfDay[k], fallbackUsed: false, childWeight: 1)
                }
                return (byDay, AsOfBaseline(state: parent.end, asOfDay: parent.endAsOfDay,
                                            fallbackUsed: false, childWeight: 1))
            }
            let child = BaselineStandard.causalFold(computed, metric: metric, through: through, context: ctx)
            var byDay: [String: AsOfBaseline] = [:]
            for k in Set(parent.before.keys).union(child.before.keys) {
                byDay[k] = Baselines.resolveHierarchical(child: child.before[k] ?? Baselines.emptyState(cfg),
                                                         childAsOf: child.asOfDay[k],
                                                         parent: parent.before[k], parentAsOf: parent.asOfDay[k])
            }
            let end = Baselines.resolveHierarchical(child: child.end, childAsOf: child.endAsOfDay,
                                                    parent: parent.end, parentAsOf: parent.endAsOfDay)
            return (byDay, end)
        }

        let hrv = hierarchical(inputs.hrvMerged, inputs.hrvComputed, .hrvRmssd)
        let rhr = hierarchical(inputs.rhrMerged, inputs.rhrComputed, .restingHR)
        let resp = hierarchical(inputs.respMerged, inputs.respComputed, .respiration)
        let skin = BaselineStandard.causalFold(inputs.skinAbsolute, metric: .skinTempAbsolute,
                                               through: through, context: ctx)

        func profile(hrv h: AsOfBaseline?, rhr r: AsOfBaseline?, resp p: AsOfBaseline?,
                     skin s: BaselineState?) -> AnalyticsEngine.ProfileBaselines {
            // Respiration and skin are passed only when usable (rule 4). RecoveryScorer re-gates resting HR
            // and respiration itself; the skin deviation's only use-site re-checks `.usable` as well.
            AnalyticsEngine.ProfileBaselines(
                hrv: h?.state,
                restingHR: r?.state,
                resp: p.flatMap { $0.state.usable ? $0.state : nil },
                skinTemp: s.flatMap { $0.usable ? $0 : nil },
                hrvScale: .ln)
        }

        var byDay: [String: AnalyticsEngine.ProfileBaselines] = [:]
        var fallback = Set<String>()
        let days = Set(hrv.byDay.keys).union(rhr.byDay.keys).union(resp.byDay.keys).union(skin.before.keys)
        for k in days {
            let h = hrv.byDay[k]
            if h?.fallbackUsed == true { fallback.insert(k) }
            byDay[k] = profile(hrv: h, rhr: rhr.byDay[k], resp: resp.byDay[k], skin: skin.before[k])
        }
        let end = profile(hrv: hrv.end, rhr: rhr.end, resp: resp.end, skin: skin.end)
        return Resolved(byDay: byDay, end: end, hrvFallbackDays: fallback)
    }
}
