import Foundation
import StrandAnalytics

// SleepFeatureDisplayModel.swift — the pure, precomputed view data for the "Sleep details" section
// (`SleepFeatureCards`), fed by `daily.sleep_features` (spec-25 §7.5, extended by spec-02
// docs/spec-02/CONTRACT.md §5).
//
// Rules the model enforces (spec-02 §3, CONTRACT §3):
//   • A value is shown only when the persisted document carries it. A missing value is left out (the
//     section's existing convention); an unavailable spec-02 BLOCK shows its reason in words instead of numbers.
//     Nothing is ever defaulted to 0.
//   • Values are the persisted numbers, formatted for display only (no re-derivation).
//   • Breathing is an estimate from the heart-rate rhythm, never airflow; no apnea / tachypnea / pause wording.
//   • Optical pulse intervals are pulse-rate variability (PRV), never ECG HRV; the nonlinear statistics are
//     secondary research statistics with no clinical claim.
//   • Skin-temperature rhythm is observed wrist temperature — never a core-temperature minimum or body clock.
//   • Rebound is descriptive: what followed short or broken nights, never a cause or a forecast.
//   • With `sleep_analytics_v1` present, continuity and architecture are left to that section (CONTRACT §2).

struct SleepFeatureDisplayModel: Equatable {
    typealias Chapter = SleepFeatureCards.Chapter

    /// One headline-strip number. `value` is "–" when the number is not available (never a zero).
    struct Stat: Equatable {
        let label: String
        let value: String
        let unit: String?
    }

    /// One label/value line inside an opened chapter.
    struct Row: Equatable {
        let label: String
        let value: String
        let note: String?
        init(_ label: String, _ value: String, note: String? = nil) {
            self.label = label; self.value = value; self.note = note
        }
    }

    struct ChapterSummary: Equatable {
        let chapter: Chapter
        let title: String
        let icon: String
        let line: String
    }

    let analyticsPresent: Bool
    let headline: [Stat]
    /// Visible chapters, in display order.
    let chapters: [ChapterSummary]
    private let rowTable: [Chapter: [Row]]

    func rows(for chapter: Chapter) -> [Row] { rowTable[chapter] ?? [] }
    func summary(for chapter: Chapter) -> ChapterSummary? { chapters.first { $0.chapter == chapter } }

    init(document: SleepFeatureDocument, night: SleepFeatureNight, analyticsPresent: Bool) {
        self.analyticsPresent = analyticsPresent
        var chapters: [ChapterSummary] = []
        var rows: [Chapter: [Row]] = [:]
        func add(_ chapter: Chapter, _ title: String, _ icon: String, _ line: String, _ detail: [Row] = []) {
            chapters.append(ChapterSummary(chapter: chapter, title: title, icon: icon, line: line))
            if !detail.isEmpty { rows[chapter] = detail }
        }

        // ── Existing chapters (spec 7.5), visibility unchanged ─────────────────────────────────────────
        if !analyticsPresent, let line = Self.continuityLine(night.continuity) {
            add(.continuity, "Continuity", "waveform.path", line)
        }
        if let line = Self.regularityLine(document.regularity) {
            add(.regularity, "Regularity", "metronome", line)
        }
        if !analyticsPresent, let line = Self.architectureLine(night.architecture) {
            add(.architecture, "Architecture", "square.stack.3d.up", line)
        }
        if let p = night.stagePhysiology, !p.stages.isEmpty {
            add(.physiology, "Physiology by stage", "heart.text.square",
                "Deep \(SleepFeatureFormat.value(p.deep?.hrMedianBpm, suffix: " bpm", short: true)) · REM \(SleepFeatureFormat.value(p.rem?.hrMedianBpm, suffix: " bpm", short: true))")
        }
        if let st = night.settling, Self.available(st.status), let nadir = st.hrNadirLatencyMin {
            add(.settling, "Falling asleep", "moon.zzz",
                "Lowest heart rate \(SleepFeatureFormat.minutes(nadir)) after falling asleep")
        }
        if let b = night.respiratoryVariability, Self.available(b.status), b.rateBpm != nil {
            add(.breathing, "Breathing", "lungs", Self.breathingLine(b), Self.breathingRows(b))
        }

        // ── spec-02 chapters: present block → a line; unavailable block → its reason ───────────────────
        if let rhythm = night.thermal?.observedSkinTempRhythm, !night.isNap, rhythm.status != .notApplicable {
            let (line, detail) = Self.temperatureRhythm(rhythm)
            add(.temperatureRhythm, "Skin-temperature rhythm", "thermometer.sun", line, detail)
        }
        if let rar = document.restActivityRhythm, rar.status != .notApplicable {
            let (line, detail) = Self.restActivity(rar)
            add(.restActivityRhythm, "Rest-activity rhythm", "figure.walk.circle", line, detail)
        }
        if let rebound = document.rebound, rebound.status != .notApplicable {
            let (line, detail) = Self.rebound(rebound)
            add(.rebound, "After short or broken nights", "arrow.uturn.backward.circle", line, detail)
        }
        if let prv = night.prvNonlinear, prv.status != .notApplicable {
            let (line, detail) = Self.prvResearch(prv)
            add(.prvResearch, "Pulse-interval research statistics", "waveform.path.ecg", line, detail)
        }

        self.chapters = chapters
        self.rowTable = rows
        self.headline = Self.headline(document: document, night: night, analyticsPresent: analyticsPresent)
    }

    // MARK: - Shared helpers

    /// The section's existing availability rule: anything but withheld / not applicable / not run / timeout /
    /// error counts (a future status string is not guessed at, but its numbers are still the persisted ones).
    static func available(_ s: SleepMetricStatus?) -> Bool {
        guard let s else { return false }
        return s != .withheld && s != .notApplicable && s != .notRun && s != .timeout && s != .error
    }

    /// "Not available: needs several days of full-day temperature".
    static func unavailableLine(_ reasons: [String]) -> String {
        guard let first = reasons.first else { return SleepFeatureWording.notAvailable }
        return "\(SleepFeatureWording.notAvailable): \(SleepFeatureWording.reason(first))"
    }

    /// One row per reason, so a withheld block explains itself.
    static func reasonRows(_ reasons: [String]) -> [Row] {
        guard !reasons.isEmpty else { return [Row("Status", SleepFeatureWording.notAvailable)] }
        return [Row("Why not available", SleepFeatureWording.reasonList(reasons))]
    }

    static func definitionRow(_ parts: [String?]) -> Row? {
        let present = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : Row("Definition", present.joined(separator: " · "))
    }

    // MARK: - Headline

    static func headline(document: SleepFeatureDocument, night: SleepFeatureNight,
                         analyticsPresent: Bool) -> [Stat] {
        let sri = document.regularity?.sri7d
        let sriValue: String = {
            guard let sri, sri.status == .available, let v = sri.value else { return "–" }
            return String(format: "%.0f", v)
        }()
        let regularity = Stat(label: "Regularity", value: sriValue, unit: sriValue == "–" ? nil : "/100")
        if analyticsPresent {
            // Continuity numbers belong to the analytics section; the strip shows what only this one has.
            let b = night.respiratoryVariability
            let rate = available(b?.status) ? b?.rateBpm : nil
            let rateText = rate.map { String(format: "%.1f", $0) } ?? "–"
            let settle = night.settling
            let nadir = available(settle?.status) ? settle?.hrNadirLatencyMin : nil
            return [
                regularity,
                Stat(label: "Breathing (est.)", value: rateText, unit: rate == nil ? nil : "br/min"),
                Stat(label: "Lowest HR after", value: SleepFeatureFormat.compactMinutes(nadir), unit: nil),
            ]
        }
        let c = night.continuity
        let continuityOK = c.map { $0.status != .withheld && $0.status != .notApplicable } ?? false
        return [
            Stat(label: "Awake in bed",
                 value: continuityOK ? SleepFeatureFormat.compactMinutes(c?.wasoMin) : "–", unit: nil),
            Stat(label: "Longest stretch",
                 value: continuityOK ? SleepFeatureFormat.compactMinutes(c?.longestSleepBoutMin) : "–", unit: nil),
            regularity,
        ]
    }

    // MARK: - Existing chapter lines (unchanged wording)

    static func continuityLine(_ c: SleepContinuity?) -> String? {
        let ok = available(c?.status)
        guard ok || !(c?.reasons.isEmpty ?? true) else { return nil }
        return ok
            ? "\(SleepFeatureFormat.value(c?.recurrentAwakeningIndexPerH, suffix: " wakes/hr")) · \(SleepFeatureFormat.percent(c?.sleepMaintenanceEfficiencyPct)) maintained"
            : "Not published for this night"
    }

    static func regularityLine(_ r: SleepRegularity?) -> String? {
        let sri = r?.sri7d
        guard sri != nil || r?.clockProfile != nil else { return nil }
        if let sri, sri.status == .available, let v = sri.value {
            return "SRI \(String(format: "%.0f", v)) of 100 · \(sri.validDays ?? 0) days"
        } else if r?.clockProfile != nil {
            return "SRI still building · timing variability available"
        }
        return "Not enough history yet"
    }

    static func architectureLine(_ a: SleepArchitecture?) -> String? {
        guard available(a?.status) else { return nil }
        var parts: [String] = []
        if let rem = a?.remLatencyFromOnsetMin { parts.append("REM first at \(SleepFeatureFormat.minutes(rem))") }
        if let deep = a?.deepLatencyFromOnsetMin { parts.append("deep first at \(SleepFeatureFormat.minutes(deep))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Breathing (respiratory_variability, CONTRACT §5.2)

    static func breathingLine(_ b: SleepRespiratoryVariability) -> String {
        var parts = ["\(SleepFeatureFormat.value(b.rateBpm, suffix: " br/min", short: true)) estimated"]
        if let stable = b.stableModulation, available(stable.status), let frac = stable.stableFractionOfEvaluated {
            parts.append("\(SleepFeatureFormat.fractionPercent(frac)) of evaluated time with steady breathing rhythm")
        }
        return parts.joined(separator: " · ")
    }

    static func breathingRows(_ b: SleepRespiratoryVariability) -> [Row] {
        var rows: [Row] = []
        if let rate = b.rateBpm { rows.append(Row("Rate (estimated)", SleepFeatureFormat.value(rate, suffix: " br/min"))) }
        if let cv = b.cvInterval { rows.append(Row("Breath-interval variation (CV)", SleepFeatureFormat.percent(cv * 100))) }
        if let sd = b.sdIntervalS { rows.append(Row("Breath-interval SD", SleepFeatureFormat.seconds(sd))) }
        if let rmssd = b.rmssdIntervalS {
            rows.append(Row("Breath-interval RMSSD", SleepFeatureFormat.seconds(rmssd),
                            note: "Successive differences between consecutive breath intervals"))
        }
        // Interval distribution: real consecutive intervals inside usable runs (gaps never make a long breath).
        if let d = b.intervalDistribution {
            if available(d.status), let median = d.medianS {
                var value = SleepFeatureFormat.seconds(median)
                if let iqr = d.iqrS { value += " (IQR \(SleepFeatureFormat.seconds(iqr)))" }
                let n = d.nIntervals.map { "From \(SleepFeatureFormat.count($0)) consecutive breath intervals inside usable stretches" }
                rows.append(Row("Typical breath interval", value, note: n))
                if let p10 = d.p10S, let p90 = d.p90S {
                    rows.append(Row("10th–90th percentile",
                                    "\(SleepFeatureFormat.seconds(p10)) – \(SleepFeatureFormat.seconds(p90))"))
                }
                if let p05 = d.p05S, let p95 = d.p95S {
                    rows.append(Row("5th–95th percentile",
                                    "\(SleepFeatureFormat.seconds(p05)) – \(SleepFeatureFormat.seconds(p95))"))
                }
            } else {
                rows.append(Row("Typical breath interval", unavailableLine(d.reasons)))
            }
        }
        // Stable modulation: the components, never a breathing score. Unknown time is never stable.
        if let m = b.stableModulation {
            if available(m.status), let stable = m.stableMinutes, let evaluated = m.evaluatedMinutes {
                var value = "\(SleepFeatureFormat.minutes(stable)) of \(SleepFeatureFormat.minutes(evaluated)) evaluated"
                if let frac = m.stableFractionOfEvaluated { value += " (\(SleepFeatureFormat.fractionPercent(frac)))" }
                rows.append(Row("Steady breathing rhythm", value,
                                note: "Minutes whose estimated breathing rhythm met a fixed steadiness definition. Not a breathing score."))
                if let unknown = m.unknownMinutes {
                    rows.append(Row("Not evaluated", SleepFeatureFormat.minutes(unknown),
                                    note: "Time without a usable estimate never counts as steady"))
                }
                if let night = m.stableFractionOfNight {
                    rows.append(Row("Share of the whole night", SleepFeatureFormat.fractionPercent(night)))
                }
                if let def = definitionRow([m.definitionVersion]) { rows.append(def) }
            } else {
                rows.append(Row("Steady breathing rhythm", unavailableLine(m.reasons)))
            }
        }
        // Per-stage rate / variability (stage_conditioned): estimated stages, model-dependent.
        for (key, title) in [("light", "Light (est.)"), ("deep", "Deep (est.)"), ("rem", "REM (est.)"), ("wake", "Awake (est.)")] {
            guard let s = b.conditioned(for: key) else { continue }
            var parts: [String] = []
            if let rate = s.rateBpm { parts.append(SleepFeatureFormat.value(rate, suffix: " br/min")) }
            if let sd = s.sdIntervalS { parts.append("SD \(SleepFeatureFormat.seconds(sd))") }
            if let rmssd = s.rmssdIntervalS { parts.append("RMSSD \(SleepFeatureFormat.seconds(rmssd))") }
            if let median = s.medianIntervalS {
                var m = "median \(SleepFeatureFormat.seconds(median))"
                if let iqr = s.iqrIntervalS { m += " (IQR \(SleepFeatureFormat.seconds(iqr)))" }
                parts.append(m)
            }
            if parts.isEmpty, let cv = s.cvInterval { parts.append("CV \(SleepFeatureFormat.percent(cv * 100))") }
            guard !parts.isEmpty else { continue }
            rows.append(Row(title, parts.joined(separator: " · "),
                            note: s.windows.map { $0 == 1 ? "1 window" : "\($0) windows" }))
        }
        if let coverage = b.quality?.nightRunCoverage {
            rows.append(Row("Coverage", SleepFeatureFormat.percent(coverage * 100),
                            note: b.validRunMin.map { "\(SleepFeatureFormat.minutes($0)) of usable breathing estimate" }))
        }
        if let range = b.supportedRange {
            var parts: [String] = []
            if range.detectorBandBpm.count == 2 {
                parts.append("detected \(SleepFeatureFormat.range(range.detectorBandBpm)) br/min")
            }
            if range.displayRateRangeBpm.count == 2 {
                parts.append("shown \(SleepFeatureFormat.range(range.displayRateRangeBpm)) br/min")
            }
            if !parts.isEmpty {
                rows.append(Row("Supported range", parts.joined(separator: " · "),
                                note: "Rates outside this range are not measured, so very fast or slow breathing and pauses are not reported"))
            }
        }
        rows.append(Row("Source", "Estimated from the heart-rate rhythm, not measured airflow"))
        if let def = definitionRow([b.methodVersion]) { rows.append(def) }
        return rows
    }

    // MARK: - Skin-temperature rhythm (CONTRACT §5.4)

    static func temperatureRhythm(_ r: SleepObservedRhythm) -> (String, [Row]) {
        var rows: [Row] = []
        let disclaimer = Row("About this", "Observed wrist skin temperature over several days. Not core body temperature or a body-clock measurement.")
        guard available(r.status) else {
            rows += reasonRows(r.reasons)
            if let days = r.qualifyingDays {
                rows.append(Row("Qualifying days so far", "\(days)" + (r.daysEvaluated.map { " of \($0) checked" } ?? "")))
            }
            rows.append(disclaimer)
            if let def = definitionRow([r.methodVersion]) { rows.append(def) }
            return (unavailableLine(r.reasons), rows)
        }
        let phaseOK = r.phaseStatus.map { $0.status == .available } ?? true
        if let mesor = r.mesorC { rows.append(Row("Rhythm-adjusted mean (mesor)", SleepFeatureFormat.celsius(mesor))) }
        if let amp = r.amplitudeC {
            var value = SleepFeatureFormat.celsius(amp)
            if let se = r.uncertainty?.amplitudeSeC { value += " ± \(SleepFeatureFormat.celsius(se))" }
            rows.append(Row("Amplitude", value))
        }
        if phaseOK, let acro = r.acrophaseH {
            var value = SleepFeatureFormat.clockHours(acro)
            if let se = r.uncertainty?.acrophaseSeH { value += " ± \(SleepFeatureFormat.hours(se))" }
            rows.append(Row("Peak time (acrophase)", value,
                            note: r.uncertainty?.method.map { "Uncertainty: \($0)" }))
        } else if let gate = r.phaseStatus, !phaseOK {
            rows.append(Row("Peak time (acrophase)", unavailableLine(gate.reasons)))
        }
        if let fit = r.fitQuality { rows.append(Row("Fit quality", String(format: "%.2f", fit))) }
        if let days = r.qualifyingDays {
            rows.append(Row("Days used", "\(days)" + (r.daysEvaluated.map { " of \($0) checked" } ?? "")))
        }
        if let cov = r.coverage {
            var parts: [String] = []
            if let d = cov.dayHoursSupported { parts.append("\(d) h daytime") }
            if let n = cov.nightHoursSupported { parts.append("\(n) h night") }
            if !cov.quadrantsObserved.isEmpty {
                parts.append("\(cov.quadrantsObserved.filter { $0 }.count) of \(cov.quadrantsObserved.count) quarters of the day")
            }
            if !parts.isEmpty { rows.append(Row("Coverage", parts.joined(separator: " · "))) }
        }
        if r.isValue != nil || r.iv != nil {
            var parts: [String] = []
            if let isv = r.isValue { parts.append("IS \(String(format: "%.2f", isv))") }
            if let iv = r.iv { parts.append("IV \(String(format: "%.2f", iv))") }
            rows.append(Row("Day-to-day stability / hour-to-hour variability", parts.joined(separator: " · "),
                            note: r.ivDefinition == "consecutive_valid_hour_pairs_across_midnight"
                                ? "Hour-to-hour pairs include the hours across midnight" : nil))
        }
        if let relations = r.phaseRelations {
            if let hr = relations.hrMinusTemp {
                rows.append(phaseRelationRow("Heart-rate peak minus temperature peak", hr))
            }
            if let sleep = relations.sleepMidpointMinusTemp {
                rows.append(phaseRelationRow("Sleep midpoint minus temperature peak", sleep))
            }
        }
        if let drift = r.phaseDrift { rows += driftRows(drift) }
        rows.append(disclaimer)
        if let def = definitionRow([r.methodVersion]) { rows.append(def) }
        var line: [String] = []
        if phaseOK, let acro = r.acrophaseH { line.append("Peak around \(SleepFeatureFormat.clockHours(acro))") }
        if let amp = r.amplitudeC { line.append("amplitude \(SleepFeatureFormat.celsius(amp))") }
        if let days = r.qualifyingDays { line.append("\(days) days") }
        return (line.isEmpty ? "Observed over several days" : line.joined(separator: " · "), rows)
    }

    static func phaseRelationRow(_ title: String, _ p: SleepPhaseRelation) -> Row {
        guard available(p.status), let diff = p.differenceH else { return Row(title, unavailableLine(p.reasons)) }
        var note: [String] = []
        if let a = p.aH { note.append("\(SleepFeatureWording.phaseLabel(p.aLabel)) \(SleepFeatureFormat.clockHours(a))") }
        if let b = p.bH { note.append("\(SleepFeatureWording.phaseLabel(p.bLabel)) \(SleepFeatureFormat.clockHours(b))") }
        if let days = p.supportDays { note.append(days == 1 ? "1 day" : "\(days) days") }
        return Row(title, SleepFeatureFormat.signedHours(diff), note: note.isEmpty ? nil : note.joined(separator: " · "))
    }

    static func driftRows(_ d: SleepPhaseDrift) -> [Row] {
        var rows: [Row] = []
        if available(d.status), let drift = d.utcDriftHPerDay {
            rows.append(Row("Peak-time drift", "\(SleepFeatureFormat.signedHours(drift)) per day",
                            note: "Measured on elapsed time, so clock changes are not counted as drift"
                                + (d.daysUsed.map { " · \($0) days" } ?? "")))
        } else if !d.reasons.isEmpty {
            rows.append(Row("Peak-time drift", unavailableLine(d.reasons)))
        }
        if !d.clockChanges.isEmpty {
            let changes = d.clockChanges.map { c -> String in
                let kind = c.kind == "dst" ? "daylight-saving change" : "time-zone change"
                let shift = (c.fromOffsetH != nil && c.toOffsetH != nil)
                    ? " (\(SleepFeatureFormat.signedHours((c.toOffsetH ?? 0) - (c.fromOffsetH ?? 0))))" : ""
                return "\(c.day ?? "") \(kind)\(shift)".trimmingCharacters(in: .whitespaces)
            }
            rows.append(Row("Clock changes", changes.joined(separator: "; "),
                            note: "A clock change relabels time; it is not a change in your rhythm"))
        }
        if let r = d.observedRealignment {
            if available(r.status), let frac = r.fractionRealigned {
                var value = "\(SleepFeatureFormat.fractionPercent(frac)) of the clock shift"
                if let days = r.daysSinceChange { value += " after \(days == 1 ? "1 day" : "\(days) days")" }
                rows.append(Row("Observed realignment", value, note: "Looking back only, never a prediction"))
            } else if !r.reasons.isEmpty {
                rows.append(Row("Observed realignment", unavailableLine(r.reasons)))
            }
        }
        return rows
    }

    // MARK: - Rest-activity rhythm (CONTRACT §5.4)

    static func restActivity(_ r: SleepRestActivityRhythm) -> (String, [Row]) {
        guard available(r.status) else {
            var rows = reasonRows(r.reasons)
            if let def = definitionRow([r.methodVersion]) { rows.append(def) }
            return (unavailableLine(r.reasons), rows)
        }
        var rows: [Row] = []
        if let isv = r.isValue { rows.append(Row("Interdaily stability (IS)", String(format: "%.2f", isv))) }
        if let iv = r.iv { rows.append(Row("Intradaily variability (IV)", String(format: "%.2f", iv))) }
        if let l5 = r.l5 {
            rows.append(Row("Least active 5 h (L5)", SleepFeatureFormat.movement(l5),
                            note: r.l5StartH.map { "Starting around \(SleepFeatureFormat.clockHours($0))" }))
        }
        if let m10 = r.m10 {
            rows.append(Row("Most active 10 h (M10)", SleepFeatureFormat.movement(m10),
                            note: r.m10StartH.map { "Starting around \(SleepFeatureFormat.clockHours($0))" }))
        }
        if let ra = r.ra { rows.append(Row("Relative amplitude (RA)", String(format: "%.2f", ra))) }
        if let days = r.daysUsed { rows.append(Row("Days used", "\(days)")) }
        var signal: [String] = []
        if r.signal == "gravity_movement_seconds_per_minute" { signal.append("wrist movement seconds per minute") }
        else if let s = r.signal { signal.append(s.replacingOccurrences(of: "_", with: " ")) }
        if let epoch = r.epochSeconds { signal.append(epoch == 3600 ? "hourly" : "\(epoch) s epochs") }
        if !signal.isEmpty { rows.append(Row("Signal", signal.joined(separator: ", "))) }
        if let def = definitionRow([r.methodVersion]) { rows.append(def) }
        var line: [String] = []
        if let isv = r.isValue { line.append("IS \(String(format: "%.2f", isv))") }
        if let iv = r.iv { line.append("IV \(String(format: "%.2f", iv))") }
        if let days = r.daysUsed { line.append("\(days) days") }
        return (line.isEmpty ? "Observed over several days" : line.joined(separator: " · "), rows)
    }

    // MARK: - Rebound (CONTRACT §5.5)

    static func rebound(_ r: SleepRebound) -> (String, [Row]) {
        let about = Row("About this", "Describes what the following nights looked like. Not a cause and not a prediction.")
        guard available(r.status) else {
            var rows = reasonRows(r.reasons)
            rows.append(about)
            if let def = definitionRow([r.definitionVersion]) { rows.append(def) }
            return (unavailableLine(r.reasons), rows)
        }
        var rows: [Row] = []
        if let ref = r.personalReference {
            var parts: [String] = []
            if let asleep = ref.medianAsleepMin { parts.append("\(SleepFeatureFormat.minutes(asleep)) asleep") }
            if let awake = ref.medianAwakeMin { parts.append("\(SleepFeatureFormat.minutes(awake)) awake") }
            if !parts.isEmpty {
                rows.append(Row("Your usual night", parts.joined(separator: " · "),
                                note: ref.nights.map { "Median of \($0) nights" }))
            }
        }
        var line: [String] = []
        for (set, title, short) in [(r.afterShort, "Night after a short night", "after short"),
                                    (r.afterFragmented, "Night after a broken night", "after broken")] {
            guard let set else { continue }
            guard let pairs = set.pairs, pairs > 0 else {
                rows.append(Row(title, "No such nights in this period"))
                continue
            }
            var parts: [String] = []
            if let asleep = set.nextNightAsleepDiffMin?.median {
                var p = "\(SleepFeatureFormat.signedMinutes(asleep)) asleep"
                if let iqr = set.nextNightAsleepDiffMin?.iqr { p += " (IQR \(SleepFeatureFormat.minutes(iqr)))" }
                parts.append(p)
                line.append("\(SleepFeatureFormat.signedMinutes(asleep)) asleep \(short)")
            }
            if let awake = set.nextNightAwakeDiffMin?.median {
                var p = "\(SleepFeatureFormat.signedMinutes(awake)) awake"
                if let iqr = set.nextNightAwakeDiffMin?.iqr { p += " (IQR \(SleepFeatureFormat.minutes(iqr)))" }
                parts.append(p)
            }
            rows.append(Row(title, parts.isEmpty ? "No difference measured" : parts.joined(separator: " · "),
                            note: pairs == 1 ? "1 pair of nights, compared with your usual night"
                                : "\(pairs) pairs of nights, compared with your usual night"))
        }
        rows.append(about)
        if let def = definitionRow([r.definitionVersion]) { rows.append(def) }
        return (line.isEmpty ? "What followed short or broken nights" : line.joined(separator: " · "), rows)
    }

    // MARK: - Secondary PRV statistics (prv_nonlinear, CONTRACT §5.3)

    static func prvResearch(_ p: SleepPrvNonlinear) -> (String, [Row]) {
        let about = Row("About this", "Secondary research statistics from optical pulse intervals (pulse-rate variability, not ECG). Not a health, fitness or training-zone measure.")
        let definition = definitionRow([p.methodVersion, p.neurokit2.map { "NeuroKit2 \($0)" }])
        guard available(p.status) else {
            var rows = reasonRows(p.reasons)
            if let used = p.segmentsUsed {
                rows.append(Row("Gap-free segments", "\(used) used" + (p.segmentsRejected.map { " · \($0) rejected" } ?? "")))
            }
            rows.append(about)
            if let definition { rows.append(definition) }
            return (unavailableLine(p.reasons), rows)
        }
        var rows: [Row] = []
        var line = ["Secondary"]
        if let se = p.sampleEntropy, let median = se.median {
            rows.append(Row("Sample entropy", SleepFeatureFormat.medianIqr(median, se.iqr),
                            note: se.segments.map { "Median over \($0) segments" }))
            line.append("sample entropy \(String(format: "%.2f", median))")
        }
        if let dfa = p.dfaAlpha1, let median = dfa.median {
            rows.append(Row("DFA α1", SleepFeatureFormat.medianIqr(median, dfa.iqr),
                            note: dfa.segments.map { "Median over \($0) segments" }))
            line.append("DFA α1 \(String(format: "%.2f", median))")
        }
        if let used = p.segmentsUsed {
            var value = "\(used) used"
            if let rejected = p.segmentsRejected { value += " · \(rejected) rejected" }
            rows.append(Row("Gap-free segments", value,
                            note: p.config?.segmentBeats.map { "Each \($0) consecutive beats; nothing joined across gaps" }))
        }
        if let c = p.config {
            var parts: [String] = []
            if let m = c.sampenDimension { parts.append("m = \(m)") }
            if let r = c.sampenToleranceSd { parts.append("r = \(String(format: "%.2g", r)) SD") }
            if c.dfaScales.count == 2 { parts.append("DFA scales \(c.dfaScales[0])–\(c.dfaScales[1]) beats") }
            if !parts.isEmpty { rows.append(Row("Parameters", parts.joined(separator: " · "))) }
        }
        rows.append(about)
        if let definition { rows.append(definition) }
        return (line.joined(separator: " · "), rows)
    }
}

// MARK: - Reason wording (sleep_features)

/// Plain words for the machine reasons `daily.sleep_features` blocks carry (Python `features/*.py`, CONTRACT §5).
/// Written to follow "Not available: " (lower case, no full stop). A code this table does not know reads as
/// humanized words, never as a raw code. Producers may add codes: add a line to `phrases` (and its
/// Localizable.xcstrings entry) — `SleepFeatureReadbackTests` checks every listed code reads cleanly.
enum SleepFeatureWording {
    static var notAvailable: String { String(localized: "Not available") }

    static let phrases: [String: String] = [
        // History and gates
        "insufficient_history": String(localized: "not enough earlier nights yet"),
        "insufficient_nights": String(localized: "not enough nights yet"),
        "insufficient_nights_for_sd": String(localized: "not enough nights to measure variation yet"),
        "insufficient_valid_days": String(localized: "not enough days with full data yet"),
        "insufficient_days": String(localized: "not enough qualifying days yet"),
        "insufficient_paired_minutes": String(localized: "not enough matching minutes across days yet"),
        "insufficient_pair_fraction": String(localized: "too few matching minutes across days"),
        "no_history": String(localized: "no earlier nights available"),
        "irregular_history_spacing": String(localized: "the earlier nights are not evenly spaced"),
        "invalid_timezone": String(localized: "the time zone could not be read"),
        "workday_labels_unavailable": String(localized: "workdays and free days are not known"),
        "no_personal_baseline": String(localized: "no personal reference yet"),
        "not_applicable": String(localized: "does not apply to this night"),
        "module_error": String(localized: "could not be computed"),
        "regularity_module_error": String(localized: "could not be computed"),
        "module_unavailable": String(localized: "not available from the server yet"),
        "candidate_lane_result_not_provided": String(localized: "the comparison estimate was not provided"),
        // Night coverage and edges
        "low_timeline_coverage": String(localized: "too much of the night has no stage data"),
        "timeline_coverage_below_gate": String(localized: "too much of the night has no stage data"),
        "low_coverage": String(localized: "too little of the night was covered"),
        "unresolved_internal_gap": String(localized: "a gap in the night's data"),
        "onset_edge_unobserved": String(localized: "the start of the night was not recorded"),
        "unobserved_onset_edge": String(localized: "the start of the night was not recorded"),
        "offset_edge_unobserved": String(localized: "the end of the night was not recorded"),
        "unobserved_offset_edge": String(localized: "the end of the night was not recorded"),
        "thin_data": String(localized: "based on little data"),
        "no_sleep": String(localized: "no sleep found"),
        "no_sleep_onset": String(localized: "no sleep onset found"),
        "no_persistent_sleep_run": String(localized: "no settled stretch of sleep found"),
        "no_final_wake": String(localized: "the final waking was not found"),
        "no_rem": String(localized: "no REM sleep estimated"),
        "no_deep": String(localized: "no deep sleep estimated"),
        "no_nights": String(localized: "no nights in this period"),
        "no_windows": String(localized: "no usable stretches of data"),
        "no_usable_windows": String(localized: "no usable stretches of data"),
        "no_valid_hr_minutes": String(localized: "no usable heart-rate minutes"),
        "no_valid_temp_minutes": String(localized: "no usable temperature minutes"),
        "no_detectable_transition": String(localized: "no clear temperature change found"),
        "no_detected_plateau": String(localized: "no settled level found"),
        "no_valid_daytime_decision": String(localized: "daytime could not be told apart from night"),
        "no_common_valid_epochs": String(localized: "no stretches where both estimates exist"),
        "movement_stream_not_in_request": String(localized: "no movement data was sent"),
        // Breathing (respiratory_variability)
        "no_breath_intervals": String(localized: "no breathing estimates this night"),
        "no_adjacent_pairs_within_runs": String(localized: "no consecutive breaths to compare"),
        "no_respiratory_evidence_in_windows": String(localized: "no breathing signal in the usable stretches"),
        "median_interval_nonpositive": String(localized: "breath timing could not be read"),
        "insufficient_intervals": String(localized: "too few consecutive breaths"),
        "insufficient_evaluated_minutes": String(localized: "too few minutes could be evaluated"),
        // Pulse intervals (prv_nonlinear)
        "insufficient_clean_beats": String(localized: "too few clean beats"),
        "high_rejected_fraction": String(localized: "too many beats were rejected"),
        "insufficient_pairs": String(localized: "too few pairs to compare"),
        "insufficient_segments": String(localized: "too few long gap-free stretches of beats"),
        // Rhythm (observed_skin_temp_rhythm, rest_activity_rhythm)
        "multi_day_history_not_requested": String(localized: "needs several days of full-day temperature"),
        "insufficient_daytime_temperature": String(localized: "needs daytime temperature too, not only nights"),
        "zero_amplitude": String(localized: "the temperature rhythm was too flat to time"),
        "unstable_phase": String(localized: "the peak time changed too much between days"),
        "mixed_devices": String(localized: "different straps or settings were mixed"),
        "movement_history_unavailable": String(localized: "needs several days of movement data"),
        // Rebound
        "no_short_nights": String(localized: "no short nights in this period"),
        "no_fragmented_nights": String(localized: "no broken nights in this period"),
    ]

    /// Clinical or causal words no sleep-feature wording may use.
    static let forbiddenTerms = ["apnea", "apnoea", "tachypnea", "bradypnea", "tachycardia", "bradycardia",
                                 "arrhythmia", "fibrillation", "disease", "disorder", "diagnos", "insomnia",
                                 "circadian disorder", "jet lag", "forecast", "caused", "because of"]

    /// A reason in plain words; an unknown code reads as humanized words.
    static func reason(_ code: String) -> String {
        if let phrase = phrases[code] { return phrase }
        let words = code.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces).lowercased()
        return words.isEmpty ? String(localized: "another reason") : words
    }

    /// Every reason in plain words, de-duplicated, first letter capitalized.
    static func reasonList(_ codes: [String]) -> String {
        var seen = Set<String>()
        let phrases = codes.map(reason).filter { seen.insert($0).inserted }
        let joined = phrases.joined(separator: "; ")
        guard let first = joined.first else { return notAvailable }
        return first.uppercased() + joined.dropFirst()
    }

    /// The name of one side of a phase relation (`a_label` / `b_label`).
    static func phaseLabel(_ label: String?) -> String {
        switch label {
        case "hr_acrophase", "hr": return "Heart-rate peak"
        case "temp_acrophase", "skin_temp_acrophase", "temp": return "Temperature peak"
        case "sleep_midpoint", "midsleep": return "Sleep midpoint"
        case let other?: return other.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: return "Phase"
        }
    }
}
