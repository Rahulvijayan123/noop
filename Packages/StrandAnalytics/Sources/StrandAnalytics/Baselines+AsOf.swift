import Foundation
import WhoopStore

// Baselines+AsOf.swift - CAUSAL ("as of the start of day D") baseline folds, plus the regime-scoped,
// hierarchically-falling-back baseline the Charge re-score uses (D4-01 / D4-V02 / D4-04).
//
// Why this exists. The Charge re-score used to fold ONE baseline over the whole merged history, including
// the night it was re-scoring and every later night, then z-score every night in the window against that
// end-of-history state. A night's stored Charge therefore (a) saw its own value and the future, (b) changed
// every time new nights arrived, and (c) wore the confidence tier of the END state rather than the tier its
// baseline really had. The worker already scores causally (`day < $2::date`), so the app and server
// disagreed by construction. The fold here snapshots the state BEFORE each day is ingested, so night D is
// judged only against nights < D and its score is reproducible: appending later nights cannot change it.
//
// Regimes. A fold must not silently mix materially different measurement regimes. Two are handled here:
//   - a manual recalibration epoch (`baselineEpoch`): the fold restarts at the epoch, and nights BEFORE it
//     are judged against their own pre-epoch causal fold (they belonged to the old regime; judging them
//     against post-epoch nights would be judging them against the future);
//   - a per-day regime tag (`regimes`, e.g. the device brand bucket): the fold restarts whenever the tag
//     changes, which generalises `deviceEraEpoch` (latest era start) to every era boundary in the history.
// The END state equals `foldHistory(_:dayKeys:cfg:baselineEpoch:)` over the current regime, so a
// forward-looking display ("today", "next night") keeps exactly the state it had.
//
// Method fallback. Within one brand the nightly value can come from two METHODS (a vendor import vs NOOP's
// own computation). `resolveHierarchical` prefers the method-consistent CHILD fold and, while that child is
// still thin, shrinks it toward the all-method PARENT fold with an explicit `fallbackUsed` flag, so a method
// switch neither resets the user to "calibrating" nor silently pools the two methods as if they were one.
//
// Pure and side-effect-free (the only global read is the documented nil-epoch default, mirrored from
// `foldHistory`). Twin rules for Kotlin: same sort, same strict `<` epoch comparison, same reset rule.

/// One day's causal baseline, resolved for scoring that day.
public struct AsOfBaseline: Equatable, Sendable {
    /// The state to z-score the day against: built only from days strictly before it.
    public let state: BaselineState
    /// Newest day whose usable value reached the fold behind `state` (nil when nothing did). Provenance:
    /// "this night was scored against the baseline as of <asOfDay>".
    public let asOfDay: String?
    /// True when the method-consistent child fold was too thin and `state` was shrunk toward the parent
    /// (all methods, same regime). Never true when no parent was supplied.
    public let fallbackUsed: Bool
    /// Weight on the child in `state`'s centre/spread: 1 when no fallback, 0 when the child had no nights.
    public let childWeight: Double

    public init(state: BaselineState, asOfDay: String?, fallbackUsed: Bool, childWeight: Double) {
        self.state = state
        self.asOfDay = asOfDay
        self.fallbackUsed = fallbackUsed
        self.childWeight = childWeight
    }
}

/// The full result of a causal fold: the state before every day, plus the end-of-history state.
public struct AsOfFold: Equatable, Sendable {
    /// State BEFORE each day key was ingested (in that day's own regime segment).
    public let before: [String: BaselineState]
    /// Newest day with a usable value folded before each day key; absent when none.
    public let asOfDay: [String: String]
    /// State after the last day, in the CURRENT regime (empty/calibrating when the newest day predates the
    /// recalibration epoch). Equals the plain epoch-aware `foldHistory` for a single-regime history.
    public let end: BaselineState
    /// Newest day with a usable value behind `end`.
    public let endAsOfDay: String?
}

extension Baselines {

    /// The empty, never-seeded state `foldHistory` returns for a history with no nights.
    static func emptyState(_ cfg: MetricCfg) -> BaselineState {
        BaselineState(baseline: (cfg.minVal + cfg.maxVal) / 2.0, spread: cfg.floorSpread, nValid: 0,
                      nightsSinceUpdate: 0, status: .calibrating)
    }

    /// UTC day-start epoch for a `yyyy-MM-dd` key, parsed exactly as the epoch-aware `foldHistory` does.
    private static func dayStartEpoch(_ key: String, _ fmt: DateFormatter) -> Double? {
        fmt.date(from: key)?.timeIntervalSince1970
    }

    /// The state each day should be scored against: the fold of every EARLIER day, never the day itself or
    /// anything after it. Keys are `yyyy-MM-dd` (sorted here, so any input order is fine). See the file
    /// header for the epoch / regime reset rules. `baselineEpoch == nil` reads `hrvBaselineEpoch()`, exactly
    /// like `foldHistory(_:dayKeys:cfg:baselineEpoch:)`.
    public static func foldHistoryAsOf(_ values: [Double?], dayKeys: [String], cfg: MetricCfg,
                                       baselineEpoch: Double? = nil, regimes: [String]? = nil,
                                       rejectHardOutliers: Bool = true) -> [String: BaselineState] {
        foldHistoryAsOfDetailed(values, dayKeys: dayKeys, cfg: cfg, baselineEpoch: baselineEpoch,
                                regimes: regimes, rejectHardOutliers: rejectHardOutliers).before
    }

    /// `foldHistoryAsOf` plus the as-of day provenance and the end-of-history state.
    public static func foldHistoryAsOfDetailed(_ values: [Double?], dayKeys: [String], cfg: MetricCfg,
                                               baselineEpoch: Double? = nil, regimes: [String]? = nil,
                                               rejectHardOutliers: Bool = true) -> AsOfFold {
        let epoch = baselineEpoch ?? hrvBaselineEpoch()
        let n = Swift.min(values.count, dayKeys.count)
        // Chronological, ties broken by input index so a duplicate key folds deterministically.
        let order = (0..<n).sorted { dayKeys[$0] != dayKeys[$1] ? dayKeys[$0] < dayKeys[$1] : $0 < $1 }
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"

        var before: [String: BaselineState] = [:]
        var asOf: [String: String] = [:]
        var state: BaselineState? = nil
        var lastUsable: String? = nil
        var segment: String? = nil
        var segmentIsPreEpoch = false
        for i in order {
            let key = dayKeys[i]
            // Same drop rule as the epoch-aware fold: strict `<` on the UTC day start; an unparseable key
            // is never treated as pre-epoch.
            let preEpoch = epoch > 0 && (dayStartEpoch(key, fmt).map { $0 < epoch } ?? false)
            let seg = (preEpoch ? "pre" : "cur") + "\u{1F}" + ((regimes.map { i < $0.count ? $0[i] : "" }) ?? "")
            if seg != segment {
                state = nil
                lastUsable = nil
                segment = seg
                segmentIsPreEpoch = preEpoch
            }
            if before[key] == nil {
                before[key] = state ?? emptyState(cfg)
                if let d = lastUsable { asOf[key] = d }
            }
            state = update(state, value: values[i], cfg: cfg, rejectHardOutliers: rejectHardOutliers)
            if let v = values[i], cfg.minVal <= v && v <= cfg.maxVal { lastUsable = key }
        }
        // The current regime is the newest day's. If that is still pre-epoch the user recalibrated after
        // the last night, so the forward-looking baseline is honestly empty (what `foldHistory` returns).
        let endState = segmentIsPreEpoch ? emptyState(cfg) : (state ?? emptyState(cfg))
        return AsOfFold(before: before, asOfDay: asOf, end: endState,
                        endAsOfDay: segmentIsPreEpoch ? nil : lastUsable)
    }

    /// Resolve one day's scoring baseline from a method-consistent CHILD fold and the all-method PARENT fold
    /// of the same regime (D4-04).
    ///
    /// - The child is used alone once it is trusted (`nValid >= minNightsTrust`) and not stale, or when the
    ///   parent cannot help (absent, not usable, or no more nights than the child, i.e. the two folds saw the
    ///   same data).
    /// - Otherwise the centre and spread are shrunk toward the parent with a child weight that ramps
    ///   LINEARLY from 0 (no child nights) to 1 at `minNightsTrust`, so the hand-over to the child is
    ///   continuous rather than a step on the night the child becomes trusted. The result never claims
    ///   `.trusted` (it is at most `.provisional`, so Charge reads "building"), and `fallbackUsed` is set.
    /// - A STALE child (its method has not produced a night for more than `staleDays` parent nights, e.g. a
    ///   vendor-import-only stretch) gets weight 0: its centre is old news, and `.stale` is not usable, so
    ///   using it alone would blank a Charge the parent can still honestly score.
    public static func resolveHierarchical(child: BaselineState, childAsOf: String?,
                                           parent: BaselineState?, parentAsOf: String?) -> AsOfBaseline {
        let childStale = child.status == .stale
        guard let p = parent, p.usable, child.nValid < minNightsTrust || childStale,
              p.nValid > child.nValid || childStale else {
            return AsOfBaseline(state: child, asOfDay: childAsOf, fallbackUsed: false, childWeight: 1)
        }
        let w = childStale ? 0 : Double(child.nValid) / Double(minNightsTrust)
        let centre = w == 0 ? p.baseline : w * child.baseline + (1 - w) * p.baseline
        let spread = w == 0 ? p.spread : w * child.spread + (1 - w) * p.spread
        let since = w == 0 ? p.nightsSinceUpdate : Swift.min(child.nightsSinceUpdate, p.nightsSinceUpdate)
        var status = computeStatus(nValid: p.nValid, nightsSinceUpdate: since)
        if status == .trusted { status = .provisional }
        let asOf = (w == 0 ? [parentAsOf] : [childAsOf, parentAsOf]).compactMap { $0 }.max()
        return AsOfBaseline(state: BaselineState(baseline: centre, spread: spread, nValid: p.nValid,
                                                 nightsSinceUpdate: since, status: status),
                            asOfDay: asOf, fallbackUsed: true, childWeight: w)
    }

    /// The causal, regime-scoped baseline for every day of a nightly series that can come from two METHODS
    /// (D4-01 + D4-04).
    ///
    /// - `merged`: the per-day value the history holds (a vendor import wins its day; the computed value
    ///   fills the rest). This is the PARENT (all methods).
    /// - `computed`: NOOP's own computed value per day (the method the scored nights use). This is the
    ///   CHILD. Pass the same map as `merged` (or nil) when there is only one method.
    /// - `sourceByDay`: each day's WINNING source id (the same one-per-day contract as `deviceEraEpoch`);
    ///   missing days take `defaultSource`. The fold restarts at every brand-bucket change.
    /// - `baselineEpoch`: the manual recalibration epoch (seconds; 0 = none). Passed explicitly, never read.
    ///
    /// Returns the resolved baseline BEFORE each day in `merged ∪ computed`, plus the end-of-history one.
    public static func regimeScopedAsOf(merged: [String: Double?], computed: [String: Double?]?,
                                        sourceByDay: [String: String], defaultSource: String,
                                        cfg: MetricCfg, baselineEpoch: Double,
                                        rejectHardOutliers: Bool = true)
        -> (byDay: [String: AsOfBaseline], end: AsOfBaseline) {
        var keySet = Set(merged.keys)
        if let computed { keySet.formUnion(computed.keys) }
        let keys = keySet.sorted()
        let regimes = keys.map { brandBucket(sourceByDay[$0] ?? defaultSource) }
        func fold(_ map: [String: Double?]) -> AsOfFold {
            foldHistoryAsOfDetailed(keys.map { map[$0] ?? nil }, dayKeys: keys, cfg: cfg,
                                    baselineEpoch: baselineEpoch, regimes: regimes,
                                    rejectHardOutliers: rejectHardOutliers)
        }
        let parent = fold(merged)
        guard let computed else {
            var byDay: [String: AsOfBaseline] = [:]
            for k in keys {
                byDay[k] = AsOfBaseline(state: parent.before[k] ?? emptyState(cfg), asOfDay: parent.asOfDay[k],
                                        fallbackUsed: false, childWeight: 1)
            }
            return (byDay, AsOfBaseline(state: parent.end, asOfDay: parent.endAsOfDay,
                                        fallbackUsed: false, childWeight: 1))
        }
        let child = fold(computed)
        var byDay: [String: AsOfBaseline] = [:]
        for k in keys {
            byDay[k] = resolveHierarchical(child: child.before[k] ?? emptyState(cfg), childAsOf: child.asOfDay[k],
                                           parent: parent.before[k], parentAsOf: parent.asOfDay[k])
        }
        return (byDay, resolveHierarchical(child: child.end, childAsOf: child.endAsOfDay,
                                           parent: parent.end, parentAsOf: parent.endAsOfDay))
    }
}

// MARK: - Charge (recovery) baselines, as of each night

/// The four Charge baselines a night is scored against, all CAUSAL (built only from nights before it).
public struct ChargeBaselineSnapshot: Sendable {
    /// Ready to hand to `RecoveryScorer` / `ScoreConfidence.charge`. `resp` and `skinTemp` are nil unless
    /// usable (the scorer includes those terms whenever a baseline object is present, so a calibrating one
    /// must not reach it); `hrv` and `restingHR` are always present (the scorer applies their gates).
    public let profile: AnalyticsEngine.ProfileBaselines
    /// Newest night folded behind the HRV baseline (the headline driver), or nil when none preceded it.
    public let hrvAsOfDay: String?
    /// True when ANY of the HRV / resting-HR / respiration baselines used the method fallback (the
    /// NOOP-computed child was thin or stale, so it was shrunk toward the vendor-import parent).
    public let fallbackUsed: Bool

    public init(profile: AnalyticsEngine.ProfileBaselines, hrvAsOfDay: String?, fallbackUsed: Bool) {
        self.profile = profile
        self.hrvAsOfDay = hrvAsOfDay
        self.fallbackUsed = fallbackUsed
    }
}

extension Baselines {

    /// The causal Charge baselines for every night in a history, plus the end-of-history snapshot for
    /// forward-looking displays (D4-01, D4-V02, D4-04).
    ///
    /// - `imported*`: vendor-import nightly values (they win the day in the all-method PARENT).
    /// - `computed*`: NOOP's own nightly values (the method the scored nights use: the CHILD). Skin is
    ///   on-device only, so it is a single-method fold.
    /// - `sourceByDay`: each day's WINNING source id (see `deviceEraEpoch`). HRV, resting HR and
    ///   respiration restart at every brand-era boundary; skin keeps its pre-existing epoch-only scope.
    /// - `hrvEpoch` scopes HRV; `recoveryEpoch` scopes resting HR, respiration and skin (the manual
    ///   Recalibrate epochs, passed explicitly so the caller reads each preference once).
    ///
    /// The merged parent follows `IntelligenceEngine.mergeNightlyIntoHistory`: an imported NON-nil value
    /// wins; a nil or absent import slot takes the computed value.
    public static func chargeBaselinesAsOf(
        importedHrv: [String: Double?], importedRhr: [String: Double?], importedResp: [String: Double?],
        computedHrv: [String: Double?], computedRhr: [String: Double?], computedResp: [String: Double?],
        computedSkin: [String: Double?],
        sourceByDay: [String: String], defaultSource: String,
        hrvEpoch: Double, recoveryEpoch: Double
    ) -> (byDay: [String: ChargeBaselineSnapshot], end: ChargeBaselineSnapshot) {
        func merged(_ imp: [String: Double?], _ comp: [String: Double?]) -> [String: Double?] {
            var m = imp
            for (day, v) in comp {
                if let existing = m[day], existing != nil { continue }
                m[day] = v
            }
            return m
        }
        let hrv = regimeScopedAsOf(merged: merged(importedHrv, computedHrv), computed: computedHrv,
                                   sourceByDay: sourceByDay, defaultSource: defaultSource,
                                   cfg: hrvCfg, baselineEpoch: hrvEpoch)
        let rhr = regimeScopedAsOf(merged: merged(importedRhr, computedRhr), computed: computedRhr,
                                   sourceByDay: sourceByDay, defaultSource: defaultSource,
                                   cfg: restingHRCfg, baselineEpoch: recoveryEpoch)
        let resp = regimeScopedAsOf(merged: merged(importedResp, computedResp), computed: computedResp,
                                    sourceByDay: sourceByDay, defaultSource: defaultSource,
                                    cfg: respCfg, baselineEpoch: recoveryEpoch)
        let skinCfg = metricCfg["skin_temp"]!
        let skinKeys = computedSkin.keys.sorted()
        let skin = foldHistoryAsOfDetailed(skinKeys.map { computedSkin[$0] ?? nil }, dayKeys: skinKeys,
                                           cfg: skinCfg, baselineEpoch: recoveryEpoch)

        func snapshot(_ h: AsOfBaseline?, _ r: AsOfBaseline?, _ rs: AsOfBaseline?,
                      _ sk: BaselineState?) -> ChargeBaselineSnapshot {
            let profile = AnalyticsEngine.ProfileBaselines(
                hrv: h?.state ?? emptyState(hrvCfg),
                restingHR: r?.state ?? emptyState(restingHRCfg),
                resp: (rs?.state).flatMap { $0.usable ? $0 : nil },
                skinTemp: sk.flatMap { $0.usable ? $0 : nil })
            let fb = (h?.fallbackUsed ?? false) || (r?.fallbackUsed ?? false) || (rs?.fallbackUsed ?? false)
            return ChargeBaselineSnapshot(profile: profile, hrvAsOfDay: h?.asOfDay, fallbackUsed: fb)
        }
        var days = Set(hrv.byDay.keys)
        days.formUnion(rhr.byDay.keys); days.formUnion(resp.byDay.keys); days.formUnion(skin.before.keys)
        var byDay: [String: ChargeBaselineSnapshot] = [:]
        for d in days {
            byDay[d] = snapshot(hrv.byDay[d], rhr.byDay[d], resp.byDay[d], skin.before[d] ?? emptyState(skinCfg))
        }
        return (byDay, snapshot(hrv.end, rhr.end, resp.end, skin.end))
    }
}

// MARK: - Assembling the Charge history (engine inputs -> the maps above)

/// The nightly maps `chargeBaselinesAsOf` folds, assembled once so the scorer and its #1614 trace read the
/// SAME inputs (see `assembleChargeHistory`).
public struct ChargeHistoryMaps: Equatable, Sendable {
    public var importedHrv: [String: Double?]
    public var importedRhr: [String: Double?]
    public var importedResp: [String: Double?]
    public var computedHrv: [String: Double?]
    public var computedRhr: [String: Double?]
    public var computedResp: [String: Double?]
    public var computedSkin: [String: Double?]
    /// Each day's winning source id (brand-era regime input); days absent here take the fold's default.
    public var sourceByDay: [String: String]

    public init(importedHrv: [String: Double?] = [:], importedRhr: [String: Double?] = [:],
                importedResp: [String: Double?] = [:], computedHrv: [String: Double?] = [:],
                computedRhr: [String: Double?] = [:], computedResp: [String: Double?] = [:],
                computedSkin: [String: Double?] = [:], sourceByDay: [String: String] = [:]) {
        self.importedHrv = importedHrv
        self.importedRhr = importedRhr
        self.importedResp = importedResp
        self.computedHrv = computedHrv
        self.computedRhr = computedRhr
        self.computedResp = computedResp
        self.computedSkin = computedSkin
        self.sourceByDay = sourceByDay
    }
}

extension Baselines {

    /// Assemble the Charge re-score's history maps (D4-01 / D4-04) from the engine's three inputs:
    ///
    /// - `imported`: the vendor-import daily rows (all history). They feed only the all-method PARENT.
    /// - `window*`: NOOP's freshly computed nightly values for THIS pass's scan window, and
    ///   `windowSourceByDay`, the per-day winning source already resolved by the engine (it also carries
    ///   the import-day defaults). Window values always win their day.
    /// - `storedComputed`: NOOP's own previously STORED nightly rows. They fill ONLY days the window does
    ///   not cover (a day is "covered" when the window has an HRV key for it, the same one-key rule for all
    ///   four series), so the earliest nights of a re-score still have a causal history behind them. A
    ///   stored day with no resolved source is tagged `storedSource` (the storage id is the best available
    ///   guess there, exactly as the engine already tags import days outside the window).
    ///
    /// CAVEAT (documented, not gated): stored rows carry the HRV / RHR values of the analytics version that
    /// wrote them. No per-row version stamp exists to gate on, so a version change inside the stored span is
    /// not separated; the 21-night re-score window refreshes the newest nights on every pass.
    public static func assembleChargeHistory(
        imported: [DailyMetric],
        windowHrv: [String: Double?], windowRhr: [String: Double?],
        windowResp: [String: Double?], windowSkin: [String: Double?],
        windowSourceByDay: [String: String],
        storedComputed: [DailyMetric], storedSource: String
    ) -> ChargeHistoryMaps {
        var maps = ChargeHistoryMaps(computedHrv: windowHrv, computedRhr: windowRhr,
                                     computedResp: windowResp, computedSkin: windowSkin,
                                     sourceByDay: windowSourceByDay)
        for d in imported {
            maps.importedHrv[d.day] = d.avgHrv
            maps.importedRhr[d.day] = d.restingHr.map(Double.init)
            maps.importedResp[d.day] = d.respRateBpm
        }
        for r in storedComputed where windowHrv[r.day] == nil {
            maps.computedHrv[r.day] = r.avgHrv
            maps.computedRhr[r.day] = r.restingHr.map(Double.init)
            maps.computedResp[r.day] = r.respRateBpm
            maps.computedSkin[r.day] = r.skinTempC
            if maps.sourceByDay[r.day] == nil { maps.sourceByDay[r.day] = storedSource }
        }
        return maps
    }

    /// `chargeBaselinesAsOf` over assembled maps.
    public static func chargeBaselinesAsOf(_ maps: ChargeHistoryMaps, defaultSource: String,
                                           hrvEpoch: Double, recoveryEpoch: Double)
        -> (byDay: [String: ChargeBaselineSnapshot], end: ChargeBaselineSnapshot) {
        chargeBaselinesAsOf(
            importedHrv: maps.importedHrv, importedRhr: maps.importedRhr, importedResp: maps.importedResp,
            computedHrv: maps.computedHrv, computedRhr: maps.computedRhr, computedResp: maps.computedResp,
            computedSkin: maps.computedSkin, sourceByDay: maps.sourceByDay, defaultSource: defaultSource,
            hrvEpoch: hrvEpoch, recoveryEpoch: recoveryEpoch)
    }

    /// The #1614 HRV trace input for the SAME fold the scorer uses: the NOOP-method CHILD series (the method
    /// every scored night uses) over the union day axis the as-of fold walks (an import-only day is a held
    /// night for the child, exactly as in `regimeScopedAsOf`), with the epoch raised to the start of the
    /// current brand era (`deviceEraEpoch` over the same per-day sources). Its final state is therefore the
    /// child's end-of-history state; a night whose child was still thin is scored against that child shrunk
    /// toward the all-method parent, which the per-night `charge` trace and `fallbackUsed` report.
    public static func chargeHrvTraceInput(_ maps: ChargeHistoryMaps, defaultSource: String, hrvEpoch: Double)
        -> (values: [Double?], dayKeys: [String], epoch: Double) {
        let keys = Set(maps.importedHrv.keys).union(maps.computedHrv.keys).sorted()
        let era = deviceEraEpoch(keys.map { (day: $0, sourceId: maps.sourceByDay[$0] ?? defaultSource) })
        return (keys.map { maps.computedHrv[$0] ?? nil }, keys, Swift.max(hrvEpoch, era))
    }
}
