import SwiftUI
import Charts
import StrandDesign

/// One logged event with what the strap measured and the models concluded around it: heart rate before,
/// during and after, the activity the classifier saw, canonical HRV and steps, personal baselines, and what
/// else was going on (exposures, Watchdog flags, other logged events). The numbers come from the server's
/// context document (ManualEventContext); nothing is computed or inferred on the phone.
struct ManualEventDetailView: View {
    let entry: ManualEventEntry
    @ObservedObject var center: ManualEventCenter
    @Environment(\.dismiss) private var dismiss

    private var context: ManualEventContext? { center.contexts[entry.id] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    statusNotice
                    if let context, context.status != nil {
                        heartRateCard(context)
                        activityCard(context)
                        metricsCard(context)
                        surroundingsCard(context)
                        dataCard(context)
                    }
                }
                .padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
            .background(StrandPalette.surfaceBase).foregroundStyle(StrandPalette.textPrimary)
            .navigationTitle(entry.label)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await center.syncNow() }
        }
        .frame(minWidth: 300, minHeight: 500)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.symbol).font(StrandFont.title2).foregroundStyle(StrandPalette.metricPurple)
                .frame(width: 44, height: 44)
                .background(StrandPalette.metricPurple.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.label).font(StrandFont.title2)
                if let start = entry.start {
                    Text(ManualEventFormat.range(start: start, end: entry.end))
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
                if let kind = center.effectiveKind(of: entry), kind != .other {
                    Text("Counts as \(kind.title.lowercased())").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    @ViewBuilder private var statusNotice: some View {
        if let message = ManualEventFormat.statusMessage(context, entry: entry,
                                                         pending: center.pendingIds.contains(entry.id) || center.staleContexts.contains(entry.id),
                                                         refused: center.rejected[entry.id]) {
            Label(message, systemImage: "info.circle")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading).naraCard(radius: 16)
        }
    }

    // MARK: Heart rate

    private func heartRateCard(_ c: ManualEventContext) -> some View {
        card("Heart rate") {
            if let bins = c.heartRate?.trace?.bins, bins.count > 1 {
                Chart {
                    if let start = c.event?.start {
                        RectangleMark(xStart: .value("Start", Date(timeIntervalSince1970: start)),
                                      xEnd: .value("End", Date(timeIntervalSince1970: c.event?.end ?? bins.last?[0] ?? start)))
                            .foregroundStyle(StrandPalette.metricPurple.opacity(0.12))
                    }
                    ForEach(bins.indices, id: \.self) { i in
                        if bins[i].count >= 2 {
                            LineMark(x: .value("Time", Date(timeIntervalSince1970: bins[i][0])),
                                     y: .value("Heart rate", bins[i][1]))
                                .foregroundStyle(StrandPalette.metricPurple)
                                .interpolationMethod(.monotone)
                        }
                    }
                }
                .chartYAxisLabel("bpm")
                .frame(height: 160)
                .accessibilityLabel("Heart rate before, during and after the event")
            }
            HStack(spacing: 12) {
                phase("Before", c.heartRate?.pre)
                phase(entry.end == nil ? "So far" : "During", c.heartRate?.during)
                phase("After", c.heartRate?.post)
            }
            let changes = ManualEventFormat.changes(c, label: entry.label)
            if !changes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(changes, id: \.self) { Text($0) }
                }.font(StrandFont.subhead)
            }
        }
    }

    private func phase(_ title: String, _ stats: ManualEventContext.HRStats?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textTertiary)
            if let mean = stats?.mean {
                Text("\(Int(mean.rounded())) bpm").font(StrandFont.headline).monospacedDigit()
                if let lo = stats?.min, let hi = stats?.max {
                    Text("\(Int(lo))–\(Int(hi))").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).monospacedDigit()
                }
            } else {
                Text("No data").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Activity

    @ViewBuilder private func activityCard(_ c: ManualEventContext) -> some View {
        if let classes = c.activity?.during?.classes, let covered = c.activity?.during?.coveredS, covered > 0 {
            card("What your strap detected") {
                ForEach(classes.prefix(4), id: \.class) { item in
                    let share = item.seconds / covered
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(ManualEventContext.title(forClass: item.class)).font(StrandFont.subhead)
                            Spacer()
                            Text(share.formatted(.percent.precision(.fractionLength(0)))).font(StrandFont.subhead).monospacedDigit()
                        }
                        ProgressView(value: min(1, max(0, share))).tint(StrandPalette.metricPurple)
                        if let confidence = item.confidence {
                            Text("Model confidence \(confidence.formatted(.percent.precision(.fractionLength(0))))")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if let agreement = ManualEventFormat.agreement(c.activity?.agreement) {
                    Text(agreement).font(StrandFont.subhead).fixedSize(horizontal: false, vertical: true)
                }
                if let coverage = c.activity?.during?.coverage, coverage < 0.95 {
                    Text("Detection covers \(coverage.formatted(.percent.precision(.fractionLength(0)))) of this event.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    // MARK: Metrics and baselines

    @ViewBuilder private func metricsCard(_ c: ManualEventContext) -> some View {
        let rows = ManualEventFormat.metricRows(c)
        if !rows.isEmpty {
            card("During the event") {
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Text(row.0).font(StrandFont.subhead)
                        Spacer()
                        Text(row.1).font(StrandFont.subhead).monospacedDigit().foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private func surroundingsCard(_ c: ManualEventContext) -> some View {
        let lines = ManualEventFormat.surroundings(c)
        if !lines.isEmpty {
            card("Around this event") {
                ForEach(lines, id: \.self) { Text($0).font(StrandFont.subhead).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    private func dataCard(_ c: ManualEventContext) -> some View {
        card("Data") {
            ForEach(ManualEventFormat.dataLines(c), id: \.self) {
                Text($0).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(StrandFont.headline)
            content()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).naraCard(radius: 16)
    }
}

/// Wording for logged events and their context. Plain descriptions of measurements, never diagnoses.
enum ManualEventFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func range(start: Date, end: Date?) -> String {
        guard let end else { return "Started \(start.formatted(date: .abbreviated, time: .shortened))" }
        let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
        let to = sameDay ? end.formatted(date: .omitted, time: .shortened) : end.formatted(date: .abbreviated, time: .shortened)
        return "\(start.formatted(date: .abbreviated, time: .shortened)) – \(to) · \(duration(end.timeIntervalSince(start)))"
    }

    private static func signed(_ value: Double, _ unit: String) -> String {
        let rounded = Int(value.rounded())
        return "\(rounded > 0 ? "+" : "")\(rounded) \(unit)"
    }

    /// One line for the event list, or nil when there is nothing to show yet.
    static func summary(_ context: ManualEventContext?) -> String? {
        guard let context, let status = context.status else { return nil }
        switch status {
        case .awaitingData: return "Waiting for strap data"
        case .insufficientData: return "No strap data for this time"
        case .running, .ready: break
        }
        var parts: [String] = []
        if let mean = context.heartRate?.during?.mean {
            parts.append("HR \(Int(mean.rounded())) bpm")
            if let delta = context.comparisons?.hrDuringMinusPreBpm { parts.append("\(signed(delta, "bpm")) vs before") }
        }
        if let top = context.dominantClass {
            parts.append("\(ManualEventContext.title(forClass: top.name)) \(top.share.formatted(.percent.precision(.fractionLength(0))))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @MainActor static func syncStatus(entry: ManualEventEntry, center: ManualEventCenter) -> String {
        if let reason = center.rejected[entry.id] { return "Not accepted by the cloud (\(reason)) · kept on this device" }
        return center.pendingIds.contains(entry.id) ? "Saved on device · sync pending" : "Synced"
    }

    static func statusMessage(_ context: ManualEventContext?, entry: ManualEventEntry, pending: Bool, refused: String?) -> String? {
        if refused != nil { return "The cloud did not accept this version of the event, so it has no strap context. It stays on this device." }
        if pending {
            return context == nil ? "Strap context appears once this event has synced to your account."
                : "Showing the context of an earlier version of this event. It updates once the change reaches your account."
        }
        guard let context, let status = context.status else {
            return "Strap context appears here after your strap data syncs."
        }
        switch status {
        case .running: return "This event is still running. The numbers so far update while it continues."
        case .awaitingData:
            if let through = context.quality?.dataThrough {
                let date = Date(timeIntervalSince1970: through)
                return "Waiting for strap data. It has synced through \(date.formatted(date: .abbreviated, time: .shortened))."
            }
            return "Waiting for strap data from this time."
        case .insufficientData: return "Your strap has no heart-rate or activity data from this time, so there is nothing to compare."
        case .ready: return context.final == true ? nil : "Detection results can still be refined as later data arrives."
        }
    }

    static func changes(_ c: ManualEventContext, label: String) -> [String] {
        var lines: [String] = []
        if let d = c.comparisons?.hrDuringMinusPreBpm { lines.append("\(signed(d, "bpm")) compared with the 30 minutes before") }
        if let d = c.comparisons?.hrPostMinusPreBpm { lines.append("\(signed(d, "bpm")) in the 30 minutes after, compared with before") }
        if let d = c.comparisons?.hrDuringMinusResting7dBpm, let rest = c.baselines?.restingHr7d?.value {
            lines.append("\(signed(d, "bpm")) above your resting heart rate this week (\(Int(rest.rounded())) bpm)")
        }
        if let d = c.comparisons?.hrDuringMinusTypeTypicalBpm, let n = c.history?.typicalFrom, n > 0 {
            lines.append("\(signed(d, "bpm")) compared with your usual \(label) (\(n) earlier)")
        }
        return lines
    }

    static func agreement(_ a: ManualEventContext.Agreement?) -> String? {
        guard let a, let status = a.status else { return nil }
        let kind = a.activityKind.flatMap(ManualEventEntry.ActivityKind.init(rawValue:))?.title.lowercased() ?? "this activity"
        switch status {
        case "agrees": return "Matches what you logged: most of this time was detected as \(kind)."
        case "partly": return "Partly matches what you logged: some of this time was detected as \(kind)."
        case "disagrees": return "Detection mostly saw something other than \(kind). Your label helps it learn."
        case "insufficient_coverage": return "Not enough detection data to compare with what you logged."
        default: return nil
        }
    }

    static func metricRows(_ c: ManualEventContext) -> [(String, String)] {
        var rows: [(String, String)] = []
        let during = c.series?.during
        if let hrv = during?.hrvRmssdMs?.value {
            var text = "\(Int(hrv.rounded())) ms"
            if let d = c.comparisons?.hrvDuringMinus7dMs { text += " (\(signed(d, "ms")) vs your week)" }
            rows.append(("HRV", text))
        }
        if let steps = during?.steps?.value { rows.append(("Steps", "\(Int(steps.rounded()))")) }
        if let resp = during?.respRateBpm?.value { rows.append(("Breathing rate", "\(resp.formatted(.number.precision(.fractionLength(1)))) /min")) }
        if let kcal = during?.caloriesKcal?.value { rows.append(("Energy", "\(Int(kcal.rounded())) kcal")) }
        return rows
    }

    static func surroundings(_ c: ManualEventContext) -> [String] {
        var lines: [String] = []
        for exposure in c.exposures ?? [] {
            guard let label = exposure.label, let offset = exposure.offsetS else { continue }
            let minutes = Int((abs(offset) / 60).rounded())
            let when = minutes < 2 ? "at the same time" : offset < 0 ? "\(duration(Double(minutes) * 60)) before" : "\(duration(Double(minutes) * 60)) after the start"
            lines.append("\(label) logged \(when)")
        }
        if let n = c.watchdog?.count, n > 0 {
            lines.append(n == 1 ? "Watchdog flagged an unusual stretch around this time" : "Watchdog flagged \(n) unusual stretches around this time")
        }
        for other in c.concurrentEvents ?? [] { if let label = other.label { lines.append("Also logged: \(label)") } }
        for episode in c.baselines?.episodes ?? [] {
            guard let key = episode.seriesKey, let state = episode.state else { continue }
            let metric = key.hasPrefix("hrv") ? "HRV" : key.hasPrefix("resting") ? "Resting heart rate"
                : key.hasPrefix("heart_rate") ? "Heart rate" : key.hasPrefix("respiratory") ? "Breathing rate" : "A measurement"
            let direction = (episode.direction ?? 0) < 0 ? "lower" : (episode.direction ?? 0) > 0 ? "higher" : "different"
            let span = state == "persistent_shift" ? "for a while" : "for a few days"
            lines.append("\(metric) was \(direction) than your usual \(span) around then")
        }
        if let count = c.history?.previousCount, count > 0 {
            lines.append("You logged this \(count) time\(count == 1 ? "" : "s") before")
        }
        return lines
    }

    static func dataLines(_ c: ManualEventContext) -> [String] {
        var lines: [String] = []
        if let coverage = c.heartRate?.during?.coverage {
            lines.append("Heart-rate coverage during the event: \(coverage.formatted(.percent.precision(.fractionLength(0))))")
        }
        switch c.device?.resolution {
        case "entry": lines.append("Measured by the strap that was active when you logged it")
        case "coverage": lines.append("Measured by the strap with the most data for this time")
        default: lines.append("No strap data was found for this time")
        }
        switch c.projections?.activityGroundTruth?.status {
        case "projected": lines.append("Used to check and improve activity detection")
        case "removed", "skipped":
            if let reason = c.projections?.activityGroundTruth?.reason {
                let why = ["no_activity_kind": "this type is not an activity",
                           "no_definitive_label": "this kind has no single detection class",
                           "archived": "the event is archived", "running": "the event is still running",
                           "too_short": "the event is too short", "longer_than_24h": "the event is longer than 24 hours"][reason]
                if let why { lines.append("Not used to train activity detection: \(why)") }
            }
        default: break
        }
        if let computed = c.computedAt {
            lines.append("Updated \(Date(timeIntervalSince1970: computed).formatted(date: .abbreviated, time: .shortened))")
        }
        return lines
    }
}
