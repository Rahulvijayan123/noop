import SwiftUI
import StrandDesign
import StrandAnalytics

// MeasurementContextDetailView.swift — the inspectable detail behind the measurement context card (spec §16).
//
// Everything the server attached to one measurement, in plain words: when it was measured (with the zone),
// whether the signal passed its checks, what the activity was during and before it (unknown and uncovered time
// shown, never hidden), sleep / wake and wear evidence with their limits, eligibility per comparison, the
// references with signed differences, recent exertion, recorded exposures ("not recorded" is not "none"), the
// inputs that do not exist, and how final the result is. Versions, fingerprints and revisions sit in a collapsed
// Diagnostics disclosure.

// MARK: - View model

struct ContextDetailRow: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let note: String?

    init(_ id: String, _ title: String, _ value: String, note: String? = nil) {
        self.id = id; self.title = title; self.value = value; self.note = note
    }
}

struct ContextDetailSection: Identifiable, Equatable {
    let id: String
    let title: String
    let rows: [ContextDetailRow]
    let footnote: String?
}

struct MeasurementContextDetailModel: Equatable {
    let title: String
    let subtitle: String?
    /// Shown above everything when the context is not current (stale pairing).
    let banner: String?
    let badges: [ContextBadge]
    let sections: [ContextDetailSection]
    let diagnostics: [ContextDetailRow]
    /// The window the exposure list should open on (the document's day window, else the support).
    let exposureWindow: PhysiologyContext.Interval?

    /// The app's own wording (titles, values, notes) — not the person's exposure labels, not diagnostics.
    var allText: [String] {
        var out = [title, subtitle, banner].compactMap { $0 } + badges.map(\.text)
        for section in sections {
            out.append(section.title)
            if let f = section.footnote { out.append(f) }
            for row in section.rows where !row.id.hasPrefix("exposure-event-") {
                out.append(row.title); out.append(row.value)
                if let n = row.note { out.append(n) }
            }
        }
        return out
    }

    static func build(day: PhysiologyContextDay, metric: PhysiologyContext.MetricKind, isStale: Bool,
                      locale: Locale = .current) -> MeasurementContextDetailModel {
        typealias W = PhysiologyContextWording
        let document = day.document
        let envelope = document.flatMap { MeasurementContextSelection.headline(in: $0.envelopes, metric: metric) }
        let banner = isStale ? String(localized: "This context was built from an earlier version of this day's results. It is shown for reference and is not paired with the value on the page.") : nil
        let window = document?.header?.identity.dayWindow ?? envelope?.support

        guard let document, let e = envelope else {
            let sections: [ContextDetailSection?] = [document.flatMap { availabilitySection($0) },
                                                     processingSection(day, document: document, locale: locale)]
            return MeasurementContextDetailModel(
                title: String(localized: "Insufficient context"),
                subtitle: String(localized: "No \(W.metric(metric)) measurement for this day has context yet."),
                banner: banner,
                badges: W.processingBadges(mode: day.effectiveMode, finality: day.effectiveFinality, unverified: false),
                sections: sections.compactMap { $0 },
                diagnostics: diagnostics(day, envelope: nil),
                exposureWindow: window)
        }
        let zone = W.zone(e.localTime.timezoneId, offsetS: e.localTime.utcOffsetS)
        let sections: [ContextDetailSection?] = [
            measurementSection(e, zone: zone, locale: locale),
            signalSection(e, locale: locale),
            activitySection(e, locale: locale),
            precedingSection(e, locale: locale),
            sleepWearSection(e),
            eligibilitySection(e),
            referenceSection(e, locale: locale),
            exertionSection(e, zone: zone, locale: locale),
            exposureSection(e, document: document, zone: zone, locale: locale),
            availabilitySection(document),
            processingSection(day, document: document, locale: locale),
        ]
        return MeasurementContextDetailModel(
            title: isStale ? String(localized: "Context updating") : W.statePhrase(e),
            subtitle: W.supportLine(e, locale: locale),
            banner: banner,
            badges: W.processingBadges(mode: day.effectiveMode, finality: e.finality,
                                       unverified: e.validity.state == .unverified),
            sections: sections.compactMap { $0 },
            diagnostics: diagnostics(day, envelope: e),
            exposureWindow: window)
    }

    // MARK: Sections

    private static func measurementSection(_ e: PhysiologyContext.MeasurementEnvelope, zone: TimeZone,
                                           locale: Locale) -> ContextDetailSection {
        typealias W = PhysiologyContextWording
        var rows = [
            ContextDetailRow("metric", String(localized: "Measurement"), W.metric(e.metric)),
            ContextDetailRow("time", String(localized: "Measured"), W.timeRange(e.support, zone: zone, locale: locale),
                             note: W.zoneLabel(zone, at: e.support.start, utcOffsetS: e.localTime.utcOffsetS)),
            ContextDetailRow("day", String(localized: "Local day"), W.day(e.localTime.localDay, locale: locale)),
            ContextDetailRow("length", String(localized: "Length"), W.duration(e.support.duration)),
        ]
        if let bucket = e.displayBucket, bucket != e.support {
            rows.append(ContextDetailRow("bucket", String(localized: "Drawn at"),
                                         W.timeRange(bucket, zone: zone, locale: locale),
                                         note: String(localized: "The chart draws this value here; it was measured over the time above.")))
        }
        if let v = e.value {
            rows.append(ContextDetailRow("value", String(localized: "Value"), W.value(v, units: e.method.units, locale: locale)))
        }
        return ContextDetailSection(id: "measurement", title: String(localized: "When it was measured"), rows: rows,
                                    footnote: nil)
    }

    private static func signalSection(_ e: PhysiologyContext.MeasurementEnvelope,
                                      locale: Locale) -> ContextDetailSection {
        typealias W = PhysiologyContextWording
        var rows = [ContextDetailRow("validity", String(localized: "Signal"), W.validity(e.validity.state),
                                     note: W.reasonList(e.validity.reasons))]
        if let coverage = e.validity.coverage {
            rows.append(ContextDetailRow("coverage", String(localized: "Signal coverage"), W.percent(coverage, locale: locale)))
        }
        if let observed = e.validity.observedS {
            rows.append(ContextDetailRow("observed", String(localized: "Observed"), W.duration(observed)))
        }
        return ContextDetailSection(id: "signal", title: String(localized: "Signal"), rows: rows,
                                    footnote: e.validity.state == .unverified
                                        ? String(localized: "This value's accuracy has not been established.") : nil)
    }

    private static func activitySection(_ e: PhysiologyContext.MeasurementEnvelope,
                                        locale: Locale) -> ContextDetailSection {
        typealias W = PhysiologyContextWording
        let a = e.activity
        let total = Double(max(1, a.intervalS))
        var rows: [ContextDetailRow] = a.labels.sorted { ($0.seconds, $0.label) > ($1.seconds, $1.label) }.map {
            ContextDetailRow("label-\($0.label)", W.activityLabel($0.label), W.percent($0.share, locale: locale))
        }
        if a.unknownS > 0 {
            rows.append(ContextDetailRow("unknown", String(localized: "Unknown activity"),
                                         W.percent(a.unknownS / total, locale: locale)))
        }
        if a.uncoveredS > 0 {
            rows.append(ContextDetailRow("uncovered", String(localized: "No activity data"),
                                         W.percent(a.uncoveredS / total, locale: locale)))
        }
        rows.append(ContextDetailRow("source", String(localized: "Based on"), W.activitySource(a.source)))
        if a.transitions > 0 || a.mixed {
            rows.append(ContextDetailRow("transitions", String(localized: "Changes of activity"), "\(a.transitions)",
                                         note: a.mixed ? String(localized: "Activity was mixed during the measurement.") : nil))
        }
        if let decoder = e.decoderActivity {
            rows.append(ContextDetailRow("decoder", String(localized: "Second estimate"),
                                         decoder.dominantLabel.map(W.activityLabel) ?? String(localized: "Mixed or unknown"),
                                         note: String(localized: "This estimate reads heart rate, so it is shown for reference only and never used to qualify the measurement.")))
        }
        var notes: [String] = []
        if let reasons = W.reasonList(a.reasons) { notes.append(reasons) }
        if a.heartRateDependent {
            notes.append(String(localized: "These labels read heart rate, so they are not independent of heart-based values."))
        }
        return ContextDetailSection(id: "activity", title: String(localized: "Activity during the measurement"),
                                    rows: rows, footnote: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    private static func precedingSection(_ e: PhysiologyContext.MeasurementEnvelope,
                                         locale: Locale) -> ContextDetailSection {
        typealias W = PhysiologyContextWording
        let p = e.preceding
        var rows = [ContextDetailRow("still", String(localized: "Still beforehand"), W.duration(p.stillRunS),
                                     note: p.stillRunEndedBy.map { String(localized: "Ended by \(W.reason($0))") })]
        if let since = p.secondsSinceSupportedActivity {
            let label = p.lastSupportedActivityLabel.map { W.activityLabel($0).lowercased() } ?? String(localized: "movement")
            rows.append(ContextDetailRow("since", String(localized: "Time since \(label)"), W.duration(since)))
        } else {
            rows.append(ContextDetailRow("since", String(localized: "Time since movement"),
                                         String(localized: "None seen in the last \(W.duration(p.lookback.duration))")))
        }
        let lookback = p.lookback.duration
        rows.append(ContextDetailRow("lookback", String(localized: "Looked back"), W.duration(lookback),
                                     note: lookback > 0
                                        ? String(localized: "\(W.percent(Double(p.coveredS) / Double(lookback), locale: locale)) of it has activity data")
                                        : nil))
        return ContextDetailSection(id: "preceding", title: String(localized: "Before the measurement"), rows: rows,
                                    footnote: String(localized: "Activity that ended before the measurement started can still affect it."))
    }

    private static func sleepWearSection(_ e: PhysiologyContext.MeasurementEnvelope) -> ContextDetailSection {
        typealias W = PhysiologyContextWording
        let s = e.sleepWear
        func evidence(_ sources: [String]) -> String? {
            sources.isEmpty ? nil : String(localized: "From \(sources.map(W.evidence).joined(separator: ", "))")
        }
        var rows = [
            ContextDetailRow("sleep", String(localized: "Sleep"), W.sleepState(s.sleepState), note: evidence(s.sleepEvidence)),
            ContextDetailRow("wear", String(localized: "Strap worn"), W.wearState(s.wearState), note: evidence(s.wearEvidence)),
        ]
        let wake = e.history.wake
        rows.append(ContextDetailRow("wake", String(localized: "Since waking"),
                                     wake.secondsSinceWake.map(W.duration) ?? String(localized: "Unknown"),
                                     note: wake.secondsSinceWake == nil ? W.reasonList(wake.reasons) : nil))
        var notes: [String] = []
        if s.sleepDependsOnHeartSignals {
            notes.append(String(localized: "Sleep detection reads heart rate, so it is not independent of heart-based values."))
        }
        if let reasons = W.reasonList(s.reasons) { notes.append(reasons) }
        notes.append(String(localized: "Quiet motion alone never counts as sleep, rest or wear."))
        return ContextDetailSection(id: "sleep", title: String(localized: "Sleep and wear"), rows: rows,
                                    footnote: notes.joined(separator: " "))
    }

    private static func eligibilitySection(_ e: PhysiologyContext.MeasurementEnvelope) -> ContextDetailSection {
        typealias W = PhysiologyContextWording
        let rows: [ContextDetailRow] = e.eligibility.isEmpty
            ? [ContextDetailRow("none", String(localized: "Comparisons"), String(localized: "Not evaluated"))]
            : e.eligibility.map { v in
                var notes: [String] = []
                if let r = W.reasonList(v.reasons) { notes.append(r) }
                if !v.dependsOn.isEmpty { notes.append(String(localized: "Uses evidence that reads heart rate.")) }
                return ContextDetailRow("eligibility-\(v.comparison.rawValue)", W.comparisonTitle(v.comparison),
                                        W.eligibilityState(v.state),
                                        note: notes.isEmpty ? nil : notes.joined(separator: " "))
            }
        return ContextDetailSection(id: "eligibility", title: String(localized: "Comparisons it qualifies for"),
                                    rows: rows, footnote: nil)
    }

    private static func referenceSection(_ e: PhysiologyContext.MeasurementEnvelope,
                                         locale: Locale) -> ContextDetailSection {
        typealias W = PhysiologyContextWording
        let units = e.method.units
        let rows: [ContextDetailRow] = e.comparisons.isEmpty
            ? [ContextDetailRow("none", String(localized: "References"), String(localized: "None for this measurement yet"))]
            : e.comparisons.enumerated().map { index, c in
                var notes: [String] = []
                if c.signedDifference != nil, c.status != .ready { notes.append(W.referenceStatus(c.status)) }
                notes.append(c.supportDays == 1 ? String(localized: "Based on 1 day")
                                                : String(localized: "Based on \(c.supportDays) days"))
                if let from = c.fromDay, let to = c.toDay {
                    notes.append("\(W.day(from, locale: locale))\u{2013}\(W.day(to, locale: locale))")
                }
                if let center = c.center {
                    var text = String(localized: "Reference \(W.value(center, units: units, locale: locale))")
                    if let u = c.centerUncertainty { text += " \u{00B1} " + W.value(u, units: units, locale: locale) }
                    notes.append(text)
                }
                if c.pooledContribution > 0 {
                    notes.append(String(localized: "\(W.percent(c.pooledContribution, locale: locale)) from related contexts"))
                }
                if let r = W.reasonList(c.reasons) { notes.append(r) }
                let value = c.signedDifference.map { W.signedDifference($0, units: units, locale: locale) }
                    ?? W.referenceStatus(c.status)
                return ContextDetailRow("reference-\(index)", W.referenceTitle(c.view), value,
                                        note: notes.joined(separator: " \u{00B7} "))
            }
        return ContextDetailSection(id: "references", title: String(localized: "References"), rows: rows,
                                    footnote: String(localized: "A historical reference is a past period of your own data, not a healthy range."))
    }

    private static func exertionSection(_ e: PhysiologyContext.MeasurementEnvelope, zone: TimeZone,
                                        locale: Locale) -> ContextDetailSection {
        typealias W = PhysiologyContextWording
        var rows: [ContextDetailRow] = e.history.exertion.sorted { $0.windowH < $1.windowH }.map { w in
            let bouts = w.boutCount == 1 ? String(localized: "1 bout") : String(localized: "\(w.boutCount) bouts")
            var notes = [String(localized: "\(W.duration(w.locomotionS)) moving")]
            if let observed = w.observedS, w.interval.duration > 0 {
                notes.append(String(localized: "\(W.percent(Double(observed) / Double(w.interval.duration), locale: locale)) observed"))
            } else {
                notes.append(String(localized: "observed time unknown"))
            }
            return ContextDetailRow("window-\(w.windowH)", String(localized: "Past \(w.windowH) h"), bouts,
                                    note: notes.joined(separator: " \u{00B7} "))
        }
        for bout in e.history.recentBouts.prefix(3) {
            rows.append(ContextDetailRow("bout-\(bout.boutId)",
                                         "\(W.boutKind(bout.kind)), \(W.duration(bout.durationS))",
                                         String(localized: "\(W.duration(bout.secondsBeforeMeasurement)) before")))
        }
        if rows.isEmpty {
            rows.append(ContextDetailRow("none", String(localized: "Recent activity"), String(localized: "None found")))
        }
        return ContextDetailSection(id: "exertion", title: String(localized: "Recent activity"), rows: rows,
                                    footnote: nil)
    }

    private static func exposureSection(_ e: PhysiologyContext.MeasurementEnvelope,
                                        document: PhysiologyContextDocument, zone: TimeZone,
                                        locale: Locale) -> ContextDetailSection {
        typealias W = PhysiologyContextWording
        var rows: [ContextDetailRow] = []
        let events = (document.exposures?.events ?? []).filter { $0.confirmation != .retracted }
            .sorted { ($0.occurred.start, $0.eventId) < ($1.occurred.start, $1.eventId) }
        for event in events {
            var notes: [String] = []
            notes.append(event.timePrecision == .dayOnly
                         ? W.date(event.occurred.start, zone: zone, locale: locale)
                         : W.dayAndTime(event.occurred.start, zone: zone, locale: locale))
            if let precision = W.timePrecision(event.timePrecision) { notes.append(precision) }
            notes.append(W.exposureConfirmation(event.confirmation))
            if let amount = event.doseAmount {
                notes.append(event.doseUnit.map { "\(amount.formatted(.number.locale(locale))) \($0)" }
                             ?? amount.formatted(.number.locale(locale)))
            }
            let label = event.label.trimmingCharacters(in: .whitespaces)
            rows.append(ContextDetailRow("exposure-event-\(event.eventId)",
                                         label.isEmpty ? W.exposureKind(event.kind) : label,
                                         W.exposureKind(event.kind), note: notes.joined(separator: " \u{00B7} ")))
        }
        let statuses = e.history.exposureCoverage.isEmpty ? (document.exposures?.categoryStatus ?? [])
                                                           : e.history.exposureCoverage
        for status in statuses {
            rows.append(ContextDetailRow("exposure-status-\(status.kind.rawValue)", W.exposureKind(status.kind),
                                         W.exposureCategoryStatus(status.status)))
        }
        if rows.isEmpty {
            rows.append(ContextDetailRow("none", String(localized: "Recorded"), String(localized: "Nothing recorded")))
        }
        return ContextDetailSection(id: "exposures", title: String(localized: "Recorded exposures"), rows: rows,
                                    footnote: String(localized: "\u{201C}Not recorded\u{201D} is not the same as none. Times are when they happened, not when they were entered."))
    }

    private static func availabilitySection(_ document: PhysiologyContextDocument) -> ContextDetailSection? {
        typealias W = PhysiologyContextWording
        let absent: [PhysiologyContext.AvailabilityState] = [.unsupported, .unverified, .unavailable]
        let missing = document.availability.filter { absent.contains($0.state) }
        guard !missing.isEmpty else { return nil }
        let rows = missing.enumerated().map { index, entry in
            ContextDetailRow("availability-\(index)",
                             entry.metric.map { "\(W.metric($0)): \(W.assessment(entry.assessment))" }
                                ?? W.assessment(entry.assessment),
                             W.availabilityState(entry.state), note: W.reasonList(entry.reasons))
        }
        return ContextDetailSection(id: "availability", title: String(localized: "Inputs not available"), rows: rows,
                                    footnote: nil)
    }

    private static func processingSection(_ day: PhysiologyContextDay, document: PhysiologyContextDocument?,
                                           locale: Locale) -> ContextDetailSection {
        typealias W = PhysiologyContextWording
        var rows: [ContextDetailRow] = []
        if let mode = day.effectiveMode { rows.append(ContextDetailRow("mode", String(localized: "Processing"), W.mode(mode))) }
        if let finality = day.effectiveFinality {
            rows.append(ContextDetailRow("finality", String(localized: "Finality"), W.finality(finality)))
        }
        if let interpretation = document?.header?.interpretation {
            let zone = W.zone(document?.timezoneId)
            rows.append(ContextDetailRow("generated", String(localized: "Built"),
                                         W.dayAndTime(interpretation.generatedAt, zone: zone, locale: locale)))
            if interpretation.mode == .causalLive {
                rows.append(ContextDetailRow("cutoff", String(localized: "Uses data up to"),
                                             W.dayAndTime(interpretation.availabilityCutoff, zone: zone, locale: locale)))
            }
        }
        if day.job?.pending == true {
            rows.append(ContextDetailRow("job", String(localized: "Update"), String(localized: "A newer version is being prepared")))
        }
        if rows.isEmpty { rows.append(ContextDetailRow("mode", String(localized: "Processing"), String(localized: "Not reported"))) }
        return ContextDetailSection(id: "processing", title: String(localized: "How final this is"), rows: rows,
                                    footnote: document.flatMap { W.reasonList($0.statusReasons) })
    }

    // MARK: Diagnostics

    private static func diagnostics(_ day: PhysiologyContextDay,
                                    envelope e: PhysiologyContext.MeasurementEnvelope?) -> [ContextDetailRow] {
        var rows: [ContextDetailRow] = [
            ContextDetailRow("d-device", "Device", day.deviceId),
            ContextDetailRow("d-status", "Read status", day.status.rawValue
                             + (day.fetchedAtMs > 0 ? " (saved copy)" : "")),
        ]
        if let r = day.contextRevision { rows.append(ContextDetailRow("d-revision", "Context revision", String(r))) }
        if let p = day.pairing {
            rows.append(ContextDetailRow("d-pairing", "Pairing",
                                         p.consistent.map { $0 ? "consistent" : "inconsistent" } ?? "not reported",
                                         note: "snapshot \(p.snapshotResultRevision ?? "-") / context built from \(p.contextScoringResultRevision ?? "-")"))
        } else {
            rows.append(ContextDetailRow("d-pairing", "Pairing", "not reported"))
        }
        if let job = day.job {
            rows.append(ContextDetailRow("d-job", "Job", job.pending ? "pending" : "idle", note: job.dirtyAt))
        }
        if let h = day.document?.header {
            rows.append(ContextDetailRow("d-contract", "Contract", "\(h.contractVersion) (schema \(h.schemaVersion))"))
            let v = h.versions
            rows.append(ContextDetailRow("d-versions", "Versions",
                                         [v.join, v.validity, v.eligibility, v.sleep, v.exertion, v.exposure,
                                          v.reference, v.change, v.functional, v.featureRegistry].joined(separator: " ")))
            rows.append(ContextDetailRow("d-policy", "Policy fingerprint", h.policyFingerprint))
            rows.append(ContextDetailRow("d-input", "Input fingerprint", h.inputFingerprint))
            if !h.inputRevisions.isEmpty {
                rows.append(ContextDetailRow("d-inputs", "Input revisions",
                                             h.inputRevisions.map { "\($0.input)=\($0.revision)" }.joined(separator: " ")))
            }
            rows.append(ContextDetailRow("d-zone", "Day", "\(h.identity.day) \(h.identity.timezoneId)"))
        }
        if let doc = day.document, doc.full == nil || doc.undecodedElements > 0 {
            rows.append(ContextDetailRow("d-undecoded", "Not decoded",
                                         "\(doc.undecodedElements) elements" + (doc.undecodedMembers.isEmpty ? ""
                                            : "; " + doc.undecodedMembers.joined(separator: ", "))))
        }
        if let e {
            rows.append(ContextDetailRow("d-envelope", "Envelope", e.id))
            rows.append(ContextDetailRow("d-method", "Method",
                                         "\(e.method.id) \(e.method.algorithmVersion) \(e.method.aggregation.rawValue) \(e.method.windowS)s \(e.method.units)"))
            rows.append(ContextDetailRow("d-source", "Source",
                                         "\(e.source.product.rawValue) \(e.source.key)",
                                         note: "input \(e.source.inputRevision.map(String.init) ?? "-") result \(e.source.resultRevision.map(String.init) ?? "-")"))
            rows.append(ContextDetailRow("d-regime", "Regime", e.regimeKey))
            rows.append(ContextDetailRow("d-confidence", "Validity confidence",
                                         e.validity.confidence.kind.rawValue
                                            + (e.validity.confidence.value.map { " \($0)" } ?? "")))
            let codes = (e.validity.reasons + e.eligibility.flatMap(\.reasons) + e.activity.reasons).map(\.rawValue)
            if !codes.isEmpty {
                rows.append(ContextDetailRow("d-codes", "Reason codes", Array(Set(codes)).sorted().joined(separator: " ")))
            }
        }
        return rows
    }
}

// MARK: - View

struct MeasurementContextDetailView: View {
    let day: PhysiologyContextDay
    let metric: PhysiologyContext.MetricKind
    var isStale = false

    @Environment(\.dismiss) private var dismiss
    @State private var showDiagnostics = false

    private var model: MeasurementContextDetailModel {
        MeasurementContextDetailModel.build(day: day, metric: metric, isStale: isStale)
    }

    var body: some View {
        let model = self.model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    header(model)
                    ForEach(model.sections) { section in
                        sectionCard(section)
                        if section.id == "exposures" { exposureEditorHook(model) }
                    }
                    historyLink
                    diagnostics(model)
                }
                .padding(NoopMetrics.screenPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle(MeasurementContextCopy.title)
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

    private func header(_ model: MeasurementContextDetailModel) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(model.title)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            if let subtitle = model.subtitle {
                Text(subtitle)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            if !model.badges.isEmpty {
                HStack(spacing: NoopMetrics.space1) {
                    ForEach(model.badges, id: \.self) { ContextBadgeView(badge: $0) }
                }
            }
            if let banner = model.banner {
                Text(banner)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionCard(_ section: ContextDetailSection) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text(section.title).strandOverline()
                ForEach(section.rows) { row in rowView(row) }
                if let footnote = section.footnote {
                    Text(footnote)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func rowView(_ row: ContextDetailRow) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                Text(row.title)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: NoopMetrics.space2)
                Text(row.value)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.trailing)
            }
            if let note = row.note {
                Text(note)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Where the exposure list / editor opens from (contracts.md §10: the timed-event editor is reachable from
    /// the context detail view). Corrections go through the same revisioned events the journal and caffeine log
    /// feed, so an edit here invalidates the affected context on the server.
    @ViewBuilder
    private func exposureEditorHook(_ model: MeasurementContextDetailModel) -> some View {
        if let window = model.exposureWindow {
            NavigationLink {
                ExposureEventListView(window: window)
            } label: {
                NoopCard {
                    HStack(spacing: NoopMetrics.space2) {
                        Image(systemName: "list.bullet.clipboard")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text("Recorded events")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: NoopMetrics.space2)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    private var historyLink: some View {
        NavigationLink {
            PhysiologyContextHistoryView(metric: metric, endingAt: day.day, timezoneId: day.document?.timezoneId)
        } label: {
            NoopCard {
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Changes and activity history")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: NoopMetrics.space2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(LiquidPressStyle())
    }

    private func diagnostics(_ model: MeasurementContextDetailModel) -> some View {
        NoopCard {
            DisclosureGroup(isExpanded: $showDiagnostics) {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    ForEach(model.diagnostics) { row in
                        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                            Text(row.title)
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Text(row.value)
                                .font(StrandFont.mono(11))
                                .foregroundStyle(StrandPalette.textSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if let note = row.note {
                                Text(note)
                                    .font(StrandFont.mono(11))
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.top, NoopMetrics.space2)
            } label: {
                Text("Diagnostics")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}
