import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics

// ActivityContextViews.swift — app-side activity context UI (spec §11 / C8 UI).
//
// Server-computed activity context rides inside the hosted snapshot's `daily.activity_context`
// (C10, parsed by HostedDayResult into the SHARED StrandAnalytics `ActivityContextDocument`).
// These views turn it into three small things:
//
//   • ActivityContextLine          — the one-line read-out under a metric value on detail pages
//                                    ("Walking", "Low movement; posture unknown", "Recent activity",
//                                    "Mixed activity", "Activity unavailable"), with the day ribbon
//                                    beneath it and a tap-through to the detail sheet.
//   • ActivityTimelineView         — a compact horizontal ribbon over the day's 30-s epochs.
//   • ActivityContextDetailSheet   — the compact source / confidence / reasons / coverage sheet.
//
// Every derived decision is a PURE function (ActivityContextWording / ActivityRibbon /
// ActivityContextDetailSheetData / ActivityContextSelection) so the behaviour is unit-testable
// without rendering; the SwiftUI views are thin shells over them.
//
// Feature-off default: every view renders nothing when there is no document. Callers gate on
// `activityContext != nil` (the hosted snapshot only carries the key when the server sends it), so
// builds with no activity payload render exactly as before.

// MARK: - Wording (the one-line read-out)

/// The one-line activity read-out for a support interval, derived from the duration-weighted join.
///
/// Wording cases (spec §11 examples): "Walking", "Low movement; posture unknown", "Recent activity",
/// "Mixed activity", "Activity unavailable". The derivation is deliberately conservative: it never
/// invents a label for missing or abstained coverage, and it prefers the temporal story (recent
/// activity) over current stillness.
enum ActivityContextWording {
    /// Post-activity annotation window (spec §9 / C2 default: 10 minutes after supported activity).
    static let postActivityWindowS = 600

    static let walking = "Walking"
    static let running = "Running"
    static let lowMovementPostureUnknown = "Low movement; posture unknown"
    static let lowMovement = "Low movement"
    static let recentActivity = "Recent activity"
    static let mixedActivity = "Mixed activity"
    static let movementDetected = "Movement detected"
    static let unavailable = "Activity unavailable"

    /// Derive the line from a join summary over the metric's actual support interval.
    ///
    /// - `summary` is `ActivityContextJoin.context(for:epochs:)` over that interval, so the wording
    ///   is duration-weighted across the WHOLE interval — a slot never inherits the label that
    ///   happened to land on its final second.
    static func text(for summary: ActivityContextSummary) -> String {
        // No overlapping epochs at all -> there is nothing to say.
        if summary.qualityReasons.contains("no_data")
            || summary.qualityReasons.contains("invalid_interval") {
            return unavailable
        }
        let known = summary.shares.filter { $0.key != .unknown }
        guard !known.isEmpty else { return unavailable }
        let best = known.max { $0.value < $1.value }!

        // A clearly dominant supported activity names itself.
        if best.key == .walking && best.value > 0.5 { return walking }
        if best.key == .running && best.value > 0.5 { return running }

        // The interval's OWN composition is genuinely mixed (no label dominates its supported
        // seconds) — that describes the measurement itself and wins over the temporal story.
        if best.value <= 0.5 && known.count >= 2 { return mixedActivity }

        // The temporal story beats current stillness: the first 10 minutes after supported activity
        // is post_activity (spec §9), even when this interval is itself mostly still.
        if let recent = summary.recentActivity, recent < postActivityWindowS {
            return recentActivity
        }

        // Most of the interval abstained -> show uncertainty plainly, not a guessed label.
        if summary.unknownShare >= 0.5 { return unavailable }

        switch best.key {
        case .walking: return walking
        case .running: return running
        case .stationary:
            // v1 posture is unknown unless a user-confirmed interval supplied it (spec §11).
            return summary.postureSource == "none" ? lowMovementPostureUnknown : lowMovement
        case .otherMovement: return movementDetected
        case .unknown: return unavailable
        }
    }

    /// The dominant supported motion label (for the line's dot colour), or nil when nothing is
    /// supported. Mirrors the wording rules: shares only, never unknown.
    static func dominantLabel(in summary: ActivityContextSummary) -> MotionLabel? {
        let known = summary.shares.filter { $0.key != .unknown }
        guard !known.isEmpty else { return nil }
        return known.max { $0.value < $1.value }?.key
    }
}

// MARK: - Ribbon (day timeline)

/// The day ribbon's 30-s bucket presentation. Missing buckets are EXPLICIT gaps — the contract
/// (spec §8 / C3) never invents stationary for missing intervals.
enum ActivityRibbon {
    /// One 30-s bucket's presentation.
    enum Segment: Equatable {
        /// A bucket covered by an epoch, carrying its motion label.
        case epoch(MotionLabel)
        /// A bucket with no epoch coverage. Never rendered as stationary.
        case gap
    }

    /// Walk the 30-s grid from `dayStart` to `dayEnd`, emitting one segment per bucket.
    ///
    /// A bucket that an epoch covers maps to that epoch's motion; a bucket with no epoch is a gap.
    /// Partial epochs at run edges are matched by overlap, so their edge bucket still paints. The
    /// result is strictly one segment per grid bucket: a day with one hour of data and 23 hours of
    /// nothing produces 2880 segments, 2760 of them gaps.
    static func segments(epochs: [ActivityEpoch],
                         dayStart: Int,
                         dayEnd: Int,
                         epochSeconds: Int = 30) -> [Segment] {
        guard dayEnd > dayStart, epochSeconds > 0 else { return [] }
        let sorted = epochs.sorted { $0.startTs < $1.startTs }
        var result: [Segment] = []
        var cursor = 0
        var t = dayStart
        while t < dayEnd {
            let bucketEnd = t + epochSeconds
            while cursor < sorted.count && sorted[cursor].endTs <= t { cursor += 1 }
            // A bucket paints its epoch's motion when the epoch OVERLAPS the bucket — a partial
            // epoch that starts or ends mid-bucket still covers that bucket.
            if cursor < sorted.count, sorted[cursor].startTs < bucketEnd, sorted[cursor].endTs > t {
                result.append(.epoch(sorted[cursor].motion))
            } else {
                result.append(.gap)
            }
            t += epochSeconds
        }
        return result
    }

    /// The ribbon colour for a motion label: walking = the app accent, running = rose, other
    /// movement = amber, stationary = calm cyan, unknown = neutral inset.
    static func color(for motion: MotionLabel) -> Color {
        switch motion {
        case .walking: return StrandPalette.accent
        case .running: return StrandPalette.metricRose
        case .otherMovement: return StrandPalette.metricAmber
        case .stationary: return StrandPalette.metricCyan
        case .unknown: return StrandPalette.surfaceInset
        }
    }
}

// MARK: - Selection (support interval + day window)

/// Maps a hosted day + metric key onto the support interval and day window the read-out joins on.
enum ActivityContextSelection {
    /// The UTC day window `[start, end)` for a "YYYY-MM-DD" day key, or nil when unparseable.
    /// The hosted day string is UTC (the worker's local-midnight/DST helpers render epochs in UTC),
    /// so UTC midnight is the correct window even for non-UTC wearers.
    static func dayWindow(day: String) -> [Int]? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day) else { return nil }
        let start = Int(date.timeIntervalSince1970)
        return [start, start + 86_400]
    }

    /// The interval whose epochs describe the metric's measurement:
    ///   • `hrv`        — the last published 15-min HRV slot `[slot_s, slot_s + 900)`. The worker's
    ///                    slot is the actual measurement bucket (physiology-policy §5.2), so the
    ///                    read-out is duration-weighted across the whole slot, never its last second.
    ///   • `resp_rate` / `spo2` — the primary sleep session overlapping the day (both are nightly
    ///                    estimates over the in-bed span).
    ///   • otherwise    — the whole day.
    static func interval(metricKey: String,
                         document: ActivityContextDocument,
                         dayWindow: [Int],
                         sleepSessions: [(start: Int, end: Int)]) -> [Int] {
        switch metricKey {
        case "hrv":
            if let slot = document.contexts.hrvSlots.last {
                return [slot.slotS, slot.slotS + 900]
            }
        case "resp_rate", "spo2":
            if let night = sleepSessions.first(where: { $0.start < dayWindow[1] && $0.end > dayWindow[0] }) {
                return [night.start, night.end]
            }
        default:
            break
        }
        return dayWindow
    }
}

// MARK: - Detail sheet data (pure)

/// Pure data behind the detail sheet (spec §11: source, confidence, reasons, coverage, dataThrough).
struct ActivityContextDetailData: Equatable {
    /// The same one-line wording the line shows.
    let wording: String
    /// Snapshot availability (`available` / `partial` / `no_data` / `pending`).
    let status: ActivityStatus
    /// Source evidence: the server's model version (the only source the C10 document carries in v1).
    let source: String
    /// Mean epoch confidence over the overlapping epochs (nil when none), in [0, 1].
    let confidence: Double?
    /// Sum of observed seconds across the overlapping epochs.
    let observedS: Int
    /// Sum of valid (accepted, non-unknown) seconds across the overlapping epochs.
    let validS: Int
    /// The dedicated activity `data_through` (ISO-8601) from the C10 document.
    let dataThrough: String?
    /// Snapshot reasons + join-derived quality reasons, deduplicated, in order.
    let reasons: [String]
    /// "user_confirmed" when a user-confirmed posture interval overlaps; "none" otherwise (v1).
    let postureSource: String
}

enum ActivityContextDetailSheetData {
    static func build(document: ActivityContextDocument, interval: [Int]) -> ActivityContextDetailData {
        let summary = ActivityContextJoin.context(for: interval, epochs: document.epochs)
        let overlapping = document.epochs.filter { $0.startTs < interval[1] && $0.endTs > interval[0] }
        let confidence: Double? = {
            guard !overlapping.isEmpty else { return nil }
            let values = overlapping.map(\.confidence).filter { $0 > 0 }
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }()
        var reasons = document.reasons
        for reason in summary.qualityReasons where !reasons.contains(reason) {
            reasons.append(reason)
        }
        return ActivityContextDetailData(
            wording: ActivityContextWording.text(for: summary),
            status: document.status,
            source: sourceLabel(for: document),
            confidence: confidence,
            observedS: overlapping.reduce(0) { $0 + $1.observedS },
            validS: overlapping.reduce(0) { $0 + $1.validS },
            dataThrough: document.dataThrough,
            reasons: reasons,
            postureSource: summary.postureSource)
    }

    /// v1 source evidence: the C10 document has no per-document baseline flag (baseline is a
    /// per-window flag in the serve protocol), so the only source it carries is the model version.
    static func sourceLabel(for document: ActivityContextDocument) -> String {
        document.modelVersion.isEmpty ? "Server model" : "Server model · \(document.modelVersion)"
    }

    /// Plain-language reason text. Technical identifiers stay internal — the sheet shows the human
    /// meaning, never raw reason codes.
    static func reasonLabel(_ reason: String) -> String {
        switch reason {
        case "no_epochs": return "No activity data for this day"
        case "low_coverage": return "Little of the interval was covered"
        case "unknown_motion": return "Most of the interval was unclassified"
        case "off_wrist": return "The strap may have been off"
        case "post_activity": return "Shortly after activity"
        case "recent_activity": return "Soon after supported activity"
        case "invalid_interval": return "The measurement interval is invalid"
        default: return reason
        }
    }
}

// MARK: - Timeline ribbon view

/// A compact horizontal ribbon over a day's 30-s epochs (spec §11 "small activity ribbon").
///
/// Each grid bucket is one slim coloured tick: walking green, running rose, other movement amber,
/// stationary cyan, unknown neutral. Missing buckets stay CLEAR — the ribbon never invents
/// stationary. When the snapshot status is not `available`/`partial` (`no_data`/`pending`), the
/// ribbon shows the honest "Activity unavailable" placeholder instead of any segments.
struct ActivityTimelineView: View {
    let document: ActivityContextDocument
    /// UTC day window `[start, end)` the ribbon spans.
    let dayStart: Int
    let dayEnd: Int

    var body: some View {
        if document.status == .available || document.status == .partial {
            let segs = ActivityRibbon.segments(epochs: document.epochs,
                                               dayStart: dayStart, dayEnd: dayEnd)
            if segs.isEmpty {
                Text(ActivityContextWording.unavailable)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                // Drawn on a Canvas so the ribbon always fits the width it is given. A day is 2,880
                // buckets; one view per bucket plus spacing has a fixed minimum width far wider than any
                // screen and stretches the whole page.
                Canvas { context, size in
                    guard !segs.isEmpty, size.width > 0 else { return }
                    let step = size.width / CGFloat(segs.count)
                    var index = 0
                    while index < segs.count {
                        var end = index + 1
                        while end < segs.count, segs[end] == segs[index] { end += 1 }
                        if case .epoch(let motion) = segs[index] {
                            let rect = CGRect(x: CGFloat(index) * step, y: 0,
                                              width: CGFloat(end - index) * step, height: size.height)
                            context.fill(Path(rect), with: .color(ActivityRibbon.color(for: motion)))
                        }
                        index = end
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 8)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ribbonAccessibilityLabel(segs))
            }
        } else {
            // no_data / pending: the server has no timeline for this day yet.
            Text(ActivityContextWording.unavailable)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func ribbonAccessibilityLabel(_ segs: [ActivityRibbon.Segment]) -> String {
        let counts = segs.reduce(into: [MotionLabel: Int]()) { acc, seg in
            if case .epoch(let motion) = seg { acc[motion, default: 0] += 1 }
        }
        let parts = counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { label, count in
            "\(count) x \(label.rawValue.replacingOccurrences(of: "_", with: " "))"
        }
        let gaps = segs.filter { $0 == .gap }.count
        var text = parts.joined(separator: ", ")
        if gaps > 0 { text += text.isEmpty ? "\(gaps) uncovered" : ", \(gaps) uncovered" }
        return text.isEmpty ? "No activity data" : "Activity timeline: " + text
    }
}

// MARK: - One-line read-out (with day ribbon + detail sheet)

/// One row of the detail page's context card (spec §11): the activity read-out derived from the epochs
/// overlapping the selected interval, with the day ribbon beneath it, and a tap-through to the compact
/// detail sheet.
///
/// Callers render this ONLY when a hosted snapshot carries an activity context (feature-off default
/// renders nothing otherwise). All data flows through the pure join + wording helpers above.
struct ActivityContextLine: View {
    let document: ActivityContextDocument
    /// The support interval joined for the read-out (see `ActivityContextSelection`).
    let interval: [Int]
    /// UTC day window for the ribbon.
    let dayStart: Int
    let dayEnd: Int
    @State private var showingDetail = false

    var body: some View {
        // Computed ONCE per body eval: the join is O(epochs) and both the wording and the dot need it.
        let summary = ActivityContextJoin.context(for: interval, epochs: document.epochs)
        Button {
            #if os(iOS)
            StrandHaptic.selection.play()
            #endif
            showingDetail = true
        } label: {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack(spacing: NoopMetrics.space3) {
                    Circle()
                        .fill(dotColor(for: summary))
                        .frame(width: 10, height: 10)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    Text(ActivityContextWording.text(for: summary))
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: NoopMetrics.space2)
                    Image(systemName: "chevron.right")
                        .font(StrandFont.icon(.inline))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                ActivityTimelineView(document: document, dayStart: dayStart, dayEnd: dayEnd)
                    .padding(.leading, 28 + NoopMetrics.space3)
            }
            .padding(.horizontal, NoopMetrics.cardPadding)
            .padding(.vertical, NoopMetrics.space3)
            .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows activity detail")
        .sheet(isPresented: $showingDetail) {
            ActivityContextDetailSheet(document: document, interval: interval)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func dotColor(for summary: ActivityContextSummary) -> Color {
        ActivityContextWording.dominantLabel(in: summary)
            .map { ActivityRibbon.color(for: $0) }
            ?? StrandPalette.surfaceInset
    }
}

// MARK: - Detail sheet

/// Compact detail sheet for the activity line (spec §11): source, confidence, reasons, observed vs
/// valid seconds, data_through, and the v1 user-correction note. This is the one place source
/// details are named; the normal flow stays jargon-free.
struct ActivityContextDetailSheet: View {
    let document: ActivityContextDocument
    let interval: [Int]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    header
                    statusRow
                    sourceRow
                    confidenceRow
                    coverageRow
                    if !data.reasons.isEmpty { reasonsCard }
                    dataThroughRow
                    userCorrectionNote
                }
                .padding(NoopMetrics.screenPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("Activity")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: NoopMetrics.detailSheetMinWidth, minHeight: NoopMetrics.detailSheetMinHeight)
        #endif
    }

    @Environment(\.dismiss) private var dismiss
    private var data: ActivityContextDetailData {
        ActivityContextDetailSheetData.build(document: document, interval: interval)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(data.wording)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private var statusRow: some View {
        detailRow(label: "Status") {
            Text(statusText)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private var statusText: String {
        switch data.status {
        case .available: return "Available"
        case .partial: return "Partial"
        case .noData: return "No data"
        case .pending: return "Pending"
        }
    }

    private var sourceRow: some View {
        detailRow(label: "Source") {
            Text(data.source)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private var confidenceRow: some View {
        detailRow(label: "Confidence") {
            Text(data.confidence.map { String(format: "%.0f%%", $0 * 100) } ?? "Not reported")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private var coverageRow: some View {
        detailRow(label: "Coverage") {
            Text("\(data.validS) of \(data.observedS) seconds recognised")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private var dataThroughRow: some View {
        detailRow(label: "Data through") {
            Text(data.dataThrough.map(ActivityContextDetailSheet.relativeThrough) ?? "—")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func detailRow<Value: View>(label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: NoopMetrics.space4)
            value()
        }
    }

    private var reasonsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Notes")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                ForEach(data.reasons, id: \.self) { reason in
                    Text("· " + ActivityContextDetailSheetData.reasonLabel(reason))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var userCorrectionNote: some View {
        Text("Labels you confirm stay local to this device. The server\u{2019}s posture stays unknown in this version.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "… ago" style for the dedicated activity data_through, mirroring ServerScoreRepository's
    /// freshness language without claiming the value is "computed" (data_through is coverage, not a
    /// computation timestamp). Future timestamps are never rendered as a freshness claim.
    static func relativeThrough(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions.remove(.withFractionalSeconds)
            date = formatter.date(from: iso)
        }
        guard let date else { return iso }
        let seconds = Int(Date().timeIntervalSince1970) - Int(date.timeIntervalSince1970)
        guard seconds >= 0 else { return iso }
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86_400) d ago"
    }
}
