import Foundation
import StrandAnalytics

// Report.swift — human-readable (Markdown), machine-readable (JSON) and per-minute (CSV / text) output.
//
// Nothing here carries a raw sample: only per-day and per-minute derived numbers. The destination is always
// a path the operator names; the harness never picks one inside the repository.

enum Report {

    static func clock(_ seconds: Int) -> String {
        let s = ((seconds % 86_400) + 86_400) % 86_400
        return String(format: "%02d:%02d", s / 3600, (s % 3600) / 60)
    }

    private static func k(_ v: Double) -> String { String(format: "%.0f", v) }
    private static func f1(_ v: Double) -> String { String(format: "%.1f", v) }
    private static func f2(_ v: Double) -> String { String(format: "%.2f", v) }
    private static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    // MARK: Markdown

    static func markdown(runs: [DayRun], checks: [BenchCheck], options: BenchOptions, generated: Date = Date()) -> String {
        var o: [String] = []
        let stamp = ISO8601DateFormatter().string(from: generated)
        o.append("# EnergyBench report")
        o.append("")
        o.append("Generated \(stamp) · model `\(EnergyConfig.modelVersion)` · \(runs.count) days")
        if let rmr = options.measuredRmr { o.append("RMR: measured \(k(rmr)) kcal/day (what-if)") }
        o.append("")

        o.append("## Checks")
        o.append("")
        o.append("| Check | Result | Detail |")
        o.append("|---|---|---|")
        for c in checks { o.append("| `\(c.name)` | **\(c.outcome.rawValue)** | \(c.detail) |") }
        o.append("")

        o.append("## Days: previous estimator vs fusion")
        o.append("")
        o.append("Energies are kcal for the local day (the last row, if partial, up to the data's end). "
            + "Legacy = `Calories.estimateDayEnergy` (50 %-HRR gate; resting counted only over observed seconds). "
            + "30 %-gate = the earlier day model (gross Keytel above 30 % HRR) that over-counted ordinary days. "
            + "Fusion total = 24 h RMR + active. PAL = fusion total / 24 h RMR.")
        o.append("")
        o.append("| Day | HR cov | RHR | Gate bpm | Legacy total (rest + active) | 30 %-gate | RMR | Fusion total | Fusion active | PAL | Δ vs legacy | Conf |")
        o.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
        for r in runs {
            let cov = Double(r.hrMinutes) / Double(max(1, r.elapsedMinutes))
            let delta = r.fusion.totalKcal - r.legacyTotal
            let day = r.partial ? "\(r.day)*" : r.day
            o.append("| \(day) | \(pct(cov)) | \(r.restingHR.map { k($0) } ?? "—") | \(k(r.gateBpm)) | "
                + "\(k(r.legacyTotal)) (\(k(r.legacyResting)) + \(k(r.legacyActive))) | \(k(r.ungatedTotal)) | "
                + "\(k(r.fusion.rmrKcalPerDay)) | **\(k(r.fusion.totalKcal))** | \(k(r.fusion.activeKcal)) | "
                + "\(f2(r.fusionPAL)) | \(delta >= 0 ? "+" : "")\(k(delta)) | \(f2(r.fusion.confidence)) |")
        }
        if runs.contains(where: \.partial) {
            o.append("")
            o.append("`*` day still in progress: resting energy counted to the last sample; "
                + "projected full-day total in the next table.")
        }
        o.append("")

        o.append("## What fed each day")
        o.append("")
        o.append("| Day | Gravity | Steps | Sleep (local) | Sleep min | Workouts | Moving min | Sessions min | Light day | Sed / Light / Mod / High min | Active kcal below old gate | Evidence minutes | Projected | ms |")
        o.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for r in runs {
            let f = r.fusion
            let ev = f.evidenceMinutes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            let spans = r.sleepSpans.isEmpty ? "none"
                : r.sleepSpans.map { "\(clock($0.start * 60))–\(clock($0.end * 60))\($0.provided ? "" : " (detected)")" }.joined(separator: ", ")
            o.append("| \(r.day) | \(r.hasGravity ? "yes" : "no") | \(r.hasSteps ? "yes" : "no") | \(spans) | \(f.sleepMinutes) | "
                + "\(r.workoutsDetected) | \(r.movingMinutes) | \(r.sessionMinutes) | \(r.lightDay ? "yes" : "no") | "
                + "\(f.sedentaryMinutes) / \(f.lightMinutes) / \(f.moderateMinutes) / \(f.highMinutes) | "
                + "\(pct(r.activeShareBelowGate)) | \(ev) | \(f.projectedTotalKcal.map { k($0) } ?? "—") | \(f1(r.estimatorMillis)) |")
        }
        o.append("")

        let bouts = runs.flatMap { r in r.bouts.map { (r, $0) } }
        o.append("## Independently found bouts (the gate test)")
        o.append("")
        if bouts.isEmpty {
            o.append("None found with the harness's definitions (sustained locomotion, or a sustained heart-rate session with motion behind it).")
        } else {
            o.append("A bout is found from the raw streams, not from the estimator: **locomotion** = ≥ \(options.minBoutMinutes) min at "
                + "≥ \(k(options.cadenceMoving)) step-counter ticks/min (or ≥ \(f2(options.dynMoving)) g wrist motion on a day with no counter); "
                + "**session** = ≥ \(options.sessionMinutes) min at ≥ \(pct(options.sessionHRRFraction)) HRR with motion behind it. "
                + "*Sub-gate* means every minute's mean HR is below the legacy gate. kcal are above rest.")
            o.append("")
            o.append("| Day | Start | Kind | Min | HR mean (max min) | ≥ gate | Cadence / dyn g | Legacy | 30 %-gate | Fusion | kcal/min | MET (band) | Conf | Sub-gate | Verdict |")
            o.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
            for (r, b) in bouts {
                let motion = [b.meanCadence.map { k($0) }, b.meanDyn.map { f2($0) }].compactMap { $0 }.joined(separator: " / ")
                let credited = b.fusionActiveKcal > b.legacyActiveKcal + 0.5 * Double(b.minutes)
                let verdict = !b.subThreshold ? "info" : (credited && b.inBand ? "credited" : "CHECK")
                o.append("| \(r.day) | \(clock(b.startTs - r.dayStart)) | \(b.kind.rawValue) | \(b.minutes) | "
                    + "\(k(b.meanHR)) (\(k(b.maxMinuteHR))) | \(pct(b.fractionAboveGate)) | \(motion) | "
                    + "\(k(b.legacyActiveKcal)) | \(k(b.ungatedActiveKcal)) | **\(k(b.fusionActiveKcal))** | \(f2(b.fusionKcalPerMin)) | "
                    + "\(f2(b.fusionMeanMET)) (\(f1(b.band.lowerBound))–\(f1(b.band.upperBound))) | \(f2(b.fusionMeanConfidence)) | "
                    + "\(b.subThreshold ? "yes" : "no") | \(verdict) |")
            }
        }
        o.append("")

        o.append("## Reading this")
        o.append("")
        o.append("- Days recorded before raw-IMU capture have no WristMET / wrist-CNN evidence; the fusion then runs on heart rate, the strap's gravity-removed motion, the step counter and the activity priors, and says so in *Evidence minutes*.")
        o.append("- Neither estimator is calorimetry. The bout MET bands are plausibility envelopes from compendium values, not ground truth.")
        o.append("")
        return o.joined(separator: "\n")
    }

    // MARK: JSON

    static func json(runs: [DayRun], checks: [BenchCheck], options: BenchOptions) throws -> Data {
        let days: [[String: Any]] = runs.map { r in
            let f = r.fusion
            return [
                "day": r.day, "partial": r.partial, "elapsed_minutes": r.elapsedMinutes, "hr_minutes": r.hrMinutes,
                "has_gravity": r.hasGravity, "has_steps": r.hasSteps,
                "resting_hr": r.restingHR as Any? ?? NSNull(), "hrmax": r.hrmax, "gate_bpm": r.gateBpm,
                "legacy": ["resting": r.legacyResting, "active": r.legacyActive, "total": r.legacyTotal],
                "ungated_30pct_total": r.ungatedTotal,
                "fusion": [
                    "model_version": f.modelVersion, "rmr_kcal_per_day": f.rmrKcalPerDay, "rmr_source": f.rmrSource.rawValue,
                    "resting": f.restingKcal, "resting_gap": f.restingGapKcal, "active": f.activeKcal,
                    "workout": f.workoutKcal, "total": f.totalKcal, "projected_total": f.projectedTotalKcal as Any? ?? NSNull(),
                    "average_met": f.averageMET as Any? ?? NSNull(), "peak_met": f.peakMET as Any? ?? NSNull(),
                    "confidence": f.confidence, "coverage_minutes": f.coverageMinutes, "gap_minutes": f.gapMinutes,
                    "sleep_minutes": f.sleepMinutes,
                    "intensity_minutes": ["sedentary": f.sedentaryMinutes, "light": f.lightMinutes,
                                          "moderate": f.moderateMinutes, "high": f.highMinutes],
                    "evidence_minutes": f.evidenceMinutes,
                ] as [String: Any],
                "pal": r.fusionPAL, "light_day": r.lightDay, "active_share_below_gate": r.activeShareBelowGate,
                "moving_minutes": r.movingMinutes, "workouts_detected": r.workoutsDetected,
                "estimator_ms": r.estimatorMillis,
                "bouts": r.bouts.map { b -> [String: Any] in
                    ["kind": b.kind.rawValue, "start_offset_min": (b.startTs - r.dayStart) / 60, "minutes": b.minutes,
                     "mean_hr": b.meanHR, "max_minute_hr": b.maxMinuteHR, "fraction_above_gate": b.fractionAboveGate,
                     "legacy_active": b.legacyActiveKcal, "ungated_active": b.ungatedActiveKcal,
                     "fusion_active": b.fusionActiveKcal, "fusion_mean_met": b.fusionMeanMET,
                     "fusion_mean_confidence": b.fusionMeanConfidence, "sub_threshold": b.subThreshold]
                },
            ]
        }
        let doc: [String: Any] = [
            "format": "energy-bench-report-v1",
            "model_version": EnergyConfig.modelVersion,
            "days": days,
            "checks": checks.map { ["name": $0.name, "outcome": $0.outcome.rawValue, "detail": $0.detail] },
        ]
        return try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Per-minute timeline

    /// Minutes `[fromMinute, toMinute)` since local midnight, one line each.
    static func timeline(run r: DayRun, fromMinute: Int, toMinute: Int) -> String {
        var o = ["time   hr   dyn_g cad  activity        MET   ±σ   conf  kcal  evidence / flags"]
        let byStart = Dictionary(uniqueKeysWithValues: r.fusion.minutes.map { ($0.startTs, $0) })
        for m in max(0, fromMinute)..<min(r.signals.count, toMinute) {
            let s = r.signals[m]
            guard let em = byStart[r.dayStart + m * 60] else { continue }
            let hr = s.hrMean.map { String(format: "%4.0f", $0) } ?? "   ·"
            let dyn = s.dynMean.map { String(format: "%5.3f", $0) } ?? "    ·"
            let cad = s.cadence.map { String(format: "%3.0f", $0) } ?? "  ·"
            let tags = (em.evidence.names + em.flags.names.map { "!" + $0 }).joined(separator: ",")
            o.append(String(format: "%@ %@ %@ %@  %-14@ %5.2f %4.2f %5.2f %5.2f  %@",
                            clock(m * 60), hr, dyn, cad, em.activity.name as NSString, em.met, em.metSigma,
                            em.confidence, em.activeKcal, tags))
        }
        return o.joined(separator: "\n")
    }

    static func timelineCSV(run r: DayRun) -> String {
        var o = ["minute_of_day,hr_mean,dyn_g,cadence_ticks,activity,met,met_sigma,confidence,active_kcal,resting_kcal,sleep,covered,evidence,flags"]
        let byStart = Dictionary(uniqueKeysWithValues: r.fusion.minutes.map { ($0.startTs, $0) })
        for m in 0..<r.signals.count {
            guard let em = byStart[r.dayStart + m * 60] else { continue }
            let s = r.signals[m]
            func v(_ x: Double?) -> String { x.map { String(format: "%.4f", $0) } ?? "" }
            o.append("\(m),\(v(s.hrMean)),\(v(s.dynMean)),\(v(s.cadence)),\(em.activity.name),\(v(em.met)),\(v(em.metSigma)),"
                + "\(v(em.confidence)),\(v(em.activeKcal)),\(v(em.restingKcal)),\(em.isSleep ? 1 : 0),\(em.covered ? 1 : 0),"
                + "\(em.evidence.names.joined(separator: "|")),\(em.flags.names.joined(separator: "|"))")
        }
        return o.joined(separator: "\n") + "\n"
    }
}
