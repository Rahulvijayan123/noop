import SwiftUI
import Foundation
import UniformTypeIdentifiers
import StrandDesign
import StrandImport
import StrandAnalytics
import WhoopStore

// MARK: - Lab Book (Health Records pillar — v5)
//
// "Your own logbook." Nara gives you a private place to KEEP the numbers you already
// get from your doctor or pharmacy — bloods, blood pressure, body measurements — and
// SEE them next to your wearable signals, entirely on this device. NOOP never tests
// you, never reads a result for you, and never tells you what a number means medically.
// (Spec: docs/superpowers/specs/2026-06-19-v5-health-records-design.md.)
//
// This screen is SELF-CONTAINED: it takes the repo via the environment (the same one
// every other screen binds to) and reads/writes markers through `repo.storeHandle()` —
// the on-device WhoopStore, where the LabMarkerStore extension lives (v17 `labMarker`
// table). Raw readings are stored under the strap device id (`repo.deviceId`); every
// write also projects a daily series under the `lab-book` source so Compare/Explore/
// Coach see markers unchanged. The "Compare with a signal" surface reuses the same
// Pearson idiom + restrained copy as CompareView's pairCard.
//
// NON-CLINICAL (load-bearing, spec §"Non-clinical / legal framing"): no word here
// asserts a clinical judgement — never "abnormal/high/low/normal" as NOOP's own
// statement; any reference range shown is EXACTLY what the user typed from their own
// report; correlation copy says "association, not a medical finding". The full
// disclaimer shows on the screen and (Wave 3) links to the consolidated About & Legal.

struct LabBookView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState

    /// All readings, grouped + ordered for display. Loaded off the store on appear/refresh.
    @State private var markers: [LabMarkerRow] = []
    @State private var loaded = false

    /// Whether the add/edit editor sheet is open.
    @State private var showingEditor = false
    /// Whether the full Lab Book note is open.
    @State private var showingDisclaimer = false

    // Markers CSV import (LabMarkerCsvImport, Phase 2).
    @State private var showingCsvImporter = false   // macOS .fileImporter presentation
    @State private var csvImporting = false
    @State private var csvSummary: String?
    @State private var csvFailed = false

    var body: some View {
        ScreenScaffold(title: "Lab Book", dateLine: loaded && !markers.isEmpty ? countLine : nil,
                       titleDisplay: .navigationBar, isLoading: !loaded,
                       onRefresh: { await load() },
                       trailing: {
                           // The Mac pane has no navigation bar, so the actions sit in the header row.
                           #if os(macOS)
                           actionsMenu
                           #endif
                       }) {
            if let s = csvSummary {
                InlineNotice(s, tone: csvFailed ? .warning : .positive)
            }
            if loaded && markers.isEmpty {
                ComingSoon(what: "Type in a blood-pressure reading or a cholesterol value from your last appointment. It stays on \(Platform.deviceNounPhrase), and over time you'll see how it lines up with your sleep, heart rate and recovery.")
            }
            ForEach(orderedCategories, id: \.self) { category in
                categorySection(category)
            }
            AboutDisclosure("About Lab Book") {
                AboutParagraphs([
                    String(localized: "It's a notebook, not a lab. Nara lines up the numbers you enter. It doesn't test, read, or judge them. Not medical advice."),
                    String(localized: "Bring in a markers CSV (date, marker, value, unit). Names that match the catalog fold onto your existing markers; anything else comes in as a custom marker. Rows that can't be read are skipped and counted, never guessed. Everything you import stays on \(Platform.deviceNounPhrase)."),
                ])
                NoopButton("Read the full note", kind: .tertiary) { showingDisclaimer = true }
                    .accessibilityLabel("Read the full Lab Book note")
            }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { actionsMenu }
        }
        #endif
        .task(id: repo.refreshSeq) { await load() }
        .sheet(isPresented: $showingEditor) {
            MarkerEditorView { drafts in
                await save(drafts)
            }
        }
        .sheet(isPresented: $showingDisclaimer) {
            NavigationStack { LabBookDisclaimerView() }
        }
        // macOS picker for the markers CSV; iOS goes through DocumentPicker (see
        // presentCsvImporter) for the iCloud download-on-pick behaviour (#179).
        .fileImporter(isPresented: $showingCsvImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { importMarkersCsv(url: url) }
            case .failure(let error):
                NSLog("Import: markers CSV picker failed - \(error.localizedDescription)")
            }
        }
    }

    /// Add a reading, import a CSV: the page's two actions, in one accent menu.
    private var actionsMenu: some View {
        Menu {
            Button { showingEditor = true } label: { Label("Add a reading", systemImage: "plus") }
                .accessibilityLabel("Add a marker reading")
            Button { presentCsvImporter() } label: {
                Label(csvImporting ? "Importing…" : "Choose CSV…", systemImage: "tray.and.arrow.down")
            }
            .disabled(csvImporting)
            .accessibilityLabel("Choose a markers CSV file to import")
        } label: {
            Image(systemName: "plus")
                .font(StrandFont.icon(.inline))
                .foregroundStyle(StrandPalette.accent)
                .frame(minWidth: NoopMetrics.minimumHitTarget, minHeight: NoopMetrics.minimumHitTarget)
        }
        .accessibilityLabel("Add a reading")
    }

    /// Whole-phrase variants per count so translators see complete phrases (never stitched plurals).
    private var countLine: String {
        let keys = Set(markers.map(\.markerKey)).count
        switch (keys == 1, markers.count == 1) {
        case (true, true):   return String(localized: "1 marker tracked · 1 reading")
        case (true, false):  return String(localized: "1 marker tracked · \(markers.count) readings")
        case (false, true):  return String(localized: "\(keys) markers tracked · 1 reading")
        case (false, false): return String(localized: "\(keys) markers tracked · \(markers.count) readings")
        }
    }

    // MARK: - Import (the Phase-2 markers CSV importer, LabMarkerCsvImport)
    //
    // The cross-platform floor is manual entry. The bulk markers CSV import is the Phase-2 engine
    // (LabMarkerCsvImport, spec §"Phasing"): (date, marker, value, unit) rows with tolerant headers,
    // catalog + custom marker mapping, and skip-and-count on anything unreadable. The picker follows the
    // Data Sources idiom (DocumentPicker on iOS, .fileImporter on macOS).

    private func presentCsvImporter() {
        #if os(iOS)
        // iOS: UIDocumentPickerViewController with asCopy:true (DocumentPicker) so an
        // undownloaded iCloud file is fetched and handed over readable (#179).
        Task {
            guard let url = await DocumentPicker.importFile([.commaSeparatedText, .plainText]) else { return } // cancelled
            importMarkersCsv(url: url)
        }
        #else
        showingCsvImporter = true
        #endif
    }

    /// Parse a markers CSV (LabMarkerCsvImport) and upsert the readings into the Lab Book
    /// under this device id with the `lab-csv` provenance tag; the daily `lab-book`
    /// projection rides the store's upsert, then a refresh lets Compare/Explore/Coach see
    /// the new markers.
    private func importMarkersCsv(url: URL) {
        csvImporting = true
        csvSummary = nil
        csvFailed = false
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                // A WHOOP biomarker export (its own header signature) routes to the vendor parser —
                // packed units, US 2-digit dates, a Status column carried into note; any other file
                // takes the generic (date,marker,value,unit) path.
                let isWhoop = WhoopBiomarkerExportParser.matches(data: data)
                let result = isWhoop ? WhoopBiomarkerExportParser.parse(data: data)
                                     : LabMarkerCsvImport.parse(data: data)
                let sourceId = isWhoop ? WhoopBiomarkerExportParser.sourceId : LabMarkerCsvImport.sourceId
                guard !result.fileTooLarge else {
                    csvSummary = String(localized: "That file is too large for a markers CSV import.")
                    csvFailed = true
                    csvImporting = false
                    return
                }
                guard result.importedReadings > 0 else {
                    csvSummary = String(localized: "No usable rows found. Check the file has date, marker and value columns.")
                    csvFailed = true
                    logImport("Lab Book CSV: no usable rows (\(result.skippedRows) skipped)")
                    csvImporting = false
                    return
                }
                guard let store = await repo.storeHandle() else {
                    csvSummary = String(localized: "Couldn't open the local store.")
                    csvFailed = true
                    csvImporting = false
                    return
                }
                let rows = result.rows.map { r -> LabMarkerRow in
                    // Local noon of the row's literal day: deterministic, so re-importing
                    // the same file updates in place (natural key
                    // deviceId+markerKey+takenAt+source) instead of duplicating.
                    let epoch = LabBookFormat.noonEpoch(r.day)
                    return LabMarkerRow(
                        id: "\(r.markerKey)-\(epoch)-\(UUID().uuidString.prefix(8))",
                        deviceId: repo.deviceId,
                        markerKey: r.markerKey,
                        category: r.category.rawValue,
                        day: r.day,
                        takenAt: epoch,
                        value: r.value,
                        valueText: nil,
                        unit: r.unit,
                        source: sourceId,
                        note: r.note,
                        referenceText: nil
                    )
                }
                try await store.upsertLabMarkers(rows)
                await repo.refresh()   // re-resolves the lab-book projection into Compare/Explore/Coach
                await load()
                var msg = String(localized: "Imported \(result.importedReadings) readings (\(result.distinctMarkers) markers)")
                if let a = result.earliestDay, let b = result.latestDay, a != b { msg += " · \(a)-\(b)" }
                if result.skippedRows > 0 {
                    // Whole-phrase variants per count; the separator stays outside the localized key.
                    msg += " · " + (result.skippedRows == 1
                                    ? String(localized: "1 row skipped")
                                    : String(localized: "\(result.skippedRows) rows skipped"))
                }
                // A vendor export's not-measured markers ("--" / "No Data Available") are absent by
                // design, not malformed — reported apart so a clean import doesn't look broken.
                if result.notMeasured > 0 {
                    msg += " · " + (result.notMeasured == 1
                                    ? String(localized: "1 not measured")
                                    : String(localized: "\(result.notMeasured) not measured"))
                }
                csvSummary = msg
                csvFailed = false
                logImport("Lab Book CSV: \(result.importedReadings) readings, \(result.distinctMarkers) markers, \(result.skippedRows) rejected")
            } catch {
                csvSummary = String(localized: "Import failed: \(error.localizedDescription)")
                csvFailed = true
                logImport("Lab Book CSV failed: \(error.localizedDescription)")
            }
            csvImporting = false
        }
    }

    /// One privacy-safe line into the SAME exported strap log the other importers use
    /// (issue #421 parity): COUNTS only, never a file name, a path, or any health value.
    /// Same shape as DataSourcesView.logImport.
    private func logImport(_ line: String) {
        live.append(log: "[\(AppModel.logTimeFormatter.string(from: Date()))] Import \(line)")
    }

    // MARK: - Category sections

    /// Categories present in the data, in the spec's display order.
    private var orderedCategories: [LabMarkerCategory] {
        let present = Set(markers.compactMap { LabMarkerCategory(rawValue: $0.category) })
        return LabBookView.categoryOrder.filter { present.contains($0) }
    }

    private static let categoryOrder: [LabMarkerCategory] = [
        .bloodPanel, .bloodPressure, .bodyMeasurement, .imaging, .appointmentNote, .other,
    ]

    @ViewBuilder
    private func categorySection(_ category: LabMarkerCategory) -> some View {
        let keys = markerKeys(in: category)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(LocalizedStringKey(category.displayName))
            NoopListSection {
                ForEach(Array(keys.enumerated()), id: \.element) { index, key in
                    if index > 0 { NoopListDivider() }
                    markerRow(key)
                }
            }
        }
    }

    /// Distinct marker keys in a category, alphabetised by display name.
    private func markerKeys(in category: LabMarkerCategory) -> [String] {
        let keys = Set(markers.filter { $0.category == category.rawValue }.map(\.markerKey))
        return keys.sorted { displayName(for: $0) < displayName(for: $1) }
    }

    /// One marker as a row: name, when it was last taken, the latest reading + unit. Opens its detail
    /// (history chart, compare with a signal, every reading) one tap down.
    private func markerRow(_ key: String) -> some View {
        let series = readings(for: key)
        let latest = series.last
        return InsightsDetailLink {
            MarkerDetailView(markerKey: key,
                             readings: readings(for: key),
                             onDelete: { id in await delete(id) })
        } label: {
            NoopListRow(icon: nil, title: LocalizedStringKey(displayName(for: key)),
                        subtitle: lastTakenCaption(latest),
                        value: latestLabel(latest, key: key))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName(for: key)), latest \(latestLabel(latest, key: key)), \(series.count) readings")
    }

    // MARK: - Data helpers

    /// Marker definition lookup → display name (catalog, else the key humanised).
    private func displayName(for key: String) -> String {
        if let def = MarkerCatalog.definition(for: key) { return def.displayName }
        return LabBookView.humanise(key)
    }

    static func humanise(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Readings for one marker, oldest-first (the store already returns them sorted by takenAt).
    private func readings(for key: String) -> [LabMarkerRow] {
        markers.filter { $0.markerKey == key }
    }

    private func latestLabel(_ row: LabMarkerRow?, key: String) -> String {
        guard let row else { return "—" }
        if let v = row.value { return "\(LabBookFormat.value(v, key: key)) \(row.unit)" }
        return row.valueText ?? "—"
    }

    private func lastTakenCaption(_ row: LabMarkerRow?) -> String {
        guard let row else { return String(localized: "no readings yet") }
        return String(localized: "last taken \(LabBookFormat.day(row.takenAt))")
    }

    // MARK: - Load / save / delete (through the shared on-device store)

    private func load() async {
        guard let store = await repo.storeHandle() else { return }
        // Read by category so we cover them all; markers are stored under the strap device id.
        var all: [LabMarkerRow] = []
        for category in LabMarkerCategory.allCases {
            let rows = (try? await store.labMarkers(deviceId: repo.deviceId, category: category.rawValue)) ?? []
            all.append(contentsOf: rows)
        }
        markers = all.sorted { $0.takenAt < $1.takenAt }
        loaded = true
    }

    private func save(_ drafts: [LabMarkerRow]) async {
        guard !drafts.isEmpty, let store = await repo.storeHandle() else { return }
        try? await store.upsertLabMarkers(drafts)
        await repo.refresh()   // re-resolves the lab-book projection into Compare/Explore/Coach
        await load()
    }

    private func delete(_ id: String) async {
        guard let store = await repo.storeHandle() else { return }
        _ = try? await store.deleteLabMarker(id: id)
        await repo.refresh()
        await load()
    }
}

// MARK: - Category display names + ordering

extension LabMarkerCategory {
    /// Human label for the Lab Book grouping header. Organisational only — never a clinical panel name.
    var displayName: String {
        switch self {
        case .bloodPanel:      return String(localized: "Blood panel")
        case .bloodPressure:   return String(localized: "Blood pressure")
        case .bodyMeasurement: return String(localized: "Body")
        case .imaging:         return String(localized: "Imaging")
        case .appointmentNote: return String(localized: "Notes")
        case .other:           return String(localized: "Custom")
        }
    }
}

// MARK: - Shared formatting (decimals from the catalog; UTC day labels)

enum LabBookFormat {
    /// Format a numeric value with the marker's catalog decimals. A custom (non-catalog) marker has no
    /// declared precision, so it is shown at its own precision via `plain` rather than a fixed 1 decimal,
    /// which rounded plateletcrit 0.27 to "0.3" and urine specific gravity 1.020 to "1.0".
    static func value(_ v: Double, key: String) -> String {
        guard v.isFinite else { return "—" }
        guard let decimals = MarkerCatalog.definition(for: key)?.decimals else { return plain(v) }
        return decimals == 0 ? String(Int(v.rounded())) : String(format: "%.\(decimals)f", v)
    }

    /// Up to 3 decimals with trailing zeros dropped ("0.27", "1.02", "140"), always with a "." separator
    /// whatever the device locale (`String(format:)` without a locale is POSIX). A value that rounds to
    /// zero prints "0", never "-0"; a non-finite value prints "—". Twin: `LabValueFormat.plain` (Android);
    /// both are pinned by the same expected strings in `LabBookFormatTests` / `LabValueFormatTest`.
    static func plain(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    /// "12 Jun 2026" for a takenAt epoch-seconds value.
    static func day(_ epoch: Int) -> String {
        dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    /// "12 Jun 2026" rendered from a stored `yyyy-MM-dd` day string, LOCATION-INDEPENDENTLY: the day key
    /// is parsed in UTC and reformatted in UTC, so the history date never shifts with the device zone the
    /// way `day(takenAt)` (a local render of a stored instant) can near midnight. Falls back to the raw
    /// string if it doesn't parse.
    static func dayFromKey(_ day: String) -> String {
        guard let date = utcKeyFormatter.date(from: day) else { return day }
        return utcDayFormatter.string(from: date)
    }

    /// "d MMM yyyy" pinned to UTC, paired with `utcKeyFormatter` so `dayFromKey` round-trips a UTC day.
    private static let utcDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    /// The `yyyy-MM-dd` day key the projection uses (LOCAL day of the reading).
    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func dayKey(_ date: Date) -> String { keyFormatter.string(from: date) }

    /// A `yyyy-MM-dd` parser PINNED to UTC, so a day string always maps to the same instant regardless
    /// of the device zone. The local-zone `keyFormatter` above returns nil for a day whose LOCAL midnight
    /// is skipped by a DST transition (e.g. Chile/Cuba, 06 Sep) - which used to collapse `noonEpoch` to
    /// epoch 0 and collide different days on the natural key. UTC never skips midnight.
    private static let utcKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Epoch seconds of UTC noon on a `yyyy-MM-dd` day — the deterministic, LOCATION-INDEPENDENT `takenAt`
    /// for CSV-imported readings, so re-importing the same file (even after travel to another zone) upserts
    /// in place instead of minting a duplicate (natural key deviceId+markerKey+takenAt+source). Pinned to
    /// UTC so a DST-skipped local midnight can never collapse the key to epoch 0. 0 only for a genuinely
    /// unparseable day string. History dates render from the stored `day` string, not this takenAt.
    static func noonEpoch(_ day: String) -> Int {
        guard let midnight = utcKeyFormatter.date(from: day) else { return 0 }
        return Int(midnight.timeIntervalSince1970) + 12 * 3600
    }
}

// MARK: - Marker detail (history + trend + "compare with a signal")

private struct MarkerDetailView: View {
    let markerKey: String
    let readings: [LabMarkerRow]
    let onDelete: (_ id: String) async -> Void

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    /// The wearable metric chosen to correlate against (nil until the user picks one).
    @State private var signal: MetricDescriptor?
    /// The trailing-window width for the windowed-aggregate pairing.
    @State private var window: LabWindow = .fortnight
    /// The computed correlation result, recomputed when signal/window change.
    @State private var pairs: [WindowedPair] = []
    @State private var correlation: Correlation?
    @State private var computing = false

    private var displayName: String {
        MarkerCatalog.definition(for: markerKey)?.displayName ?? LabBookView.humanise(markerKey)
    }
    private var unit: String { readings.last?.unit ?? MarkerCatalog.definition(for: markerKey)?.canonicalUnit ?? "" }
    private var numericReadings: [LabMarkerRow] { readings.filter { $0.value != nil } }

    /// One point per day for the chart (the latest reading of a day wins), on its local day.
    private var points: [DailyPoint] {
        var byDay: [String: Double] = [:]
        for row in numericReadings { if let v = row.value { byDay[row.day] = v } }
        return byDay.compactMap { DailyPoint(key: $0.key, value: $0.value) }.sorted { $0.day < $1.day }
    }

    @State private var selected: Date?

    var body: some View {
        let points = self.points
        let window = ChartAxis.window(.all, firstDataDay: points.first?.day)
        let span = InsightsRanges.span(firstDay: points.first?.day)
        ScreenScaffold(title: LocalizedStringKey(displayName),
                       // Whole-phrase variants per count (never a stitched plural).
                       dateLine: readings.count == 1 ? String(localized: "1 reading")
                                                     : String(localized: "\(readings.count) readings"),
                       titleDisplay: .navigationBar) {
            ValueReadout(.daily(selection: selected, in: points, unit: unit,
                                format: { LabBookFormat.value($0, key: markerKey) },
                                context: selected == nil ? latestReferenceText.map { String(localized: "Your report: \($0)") } : nil))
            if !points.isEmpty || readings.isEmpty {
                NoopCard {
                    // Sparse, irregular readings: every reading a point on a true date axis, joined
                    // straight (never smoothed past a reading), the unit on the value axis.
                    DailyLineChart(series: [.init(id: "marker", name: displayName,
                                                  color: StrandPalette.metricCyan, points: points)],
                                   cadence: .sparse(maxGapDays: 365), interpolation: .linear,
                                   state: points.isEmpty ? .empty(String(localized: "No numeric readings yet.")) : .ready,
                                   window: window,
                                   xStyle: span > 365 ? .monthYear : (span > 60 ? .month : .dayOfMonth),
                                   y: ChartValueAxis(unit: unit.isEmpty ? nil : unit,
                                                     domain: .fitted(minSpan: valueSpan(points)),
                                                     format: { LabBookFormat.value($0, key: markerKey) }),
                                   selection: $selected, height: NoopMetrics.chartHeightSecondary,
                                   accessibilityTitle: displayName)
                }
            }
            Text(trendSentence)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !numericReadings.isEmpty { compareSection }
            historySection
            AboutDisclosure(paragraphs: [
                String(localized: "These are your own numbers shown back to you. Nara doesn't decide whether any value is normal, high or low."),
            ])
        }
        .background(StrandPalette.surfaceBase)
    }

    /// The smallest value-axis span: a tenth of the marker's typical size, so a steady marker does not
    /// fill the plot with noise.
    private func valueSpan(_ points: [DailyPoint]) -> Double {
        let values = points.map(\.value)
        guard let mean = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) else { return 1 }
        return max(0.01, abs(mean) * 0.1)
    }

    // MARK: - Trend sentence (descriptive arithmetic, never interpretation)

    /// "Your last 3 LDL readings: 3.4 → 3.1 → 2.9 mmol/L, trending down." — descriptive only.
    /// Whole-phrase variants per direction so translators never see a stitched trend fragment.
    private var trendSentence: String {
        let nums = numericReadings
        guard let last = nums.last?.value else {
            return readings.last?.valueText.map { String(localized: "Latest entry: \($0).") } ?? String(localized: "No numeric readings yet.")
        }
        guard nums.count >= 2 else {
            return String(localized: "One reading so far: \(LabBookFormat.value(last, key: markerKey)) \(unit). Log a few more to see a trend.")
        }
        let shown = nums.suffix(3).compactMap { $0.value }
        let arrowed = shown.map { LabBookFormat.value($0, key: markerKey) }.joined(separator: " → ")
        let first = shown.first ?? last
        if last > first {
            return String(localized: "Your last \(shown.count) readings: \(arrowed) \(unit), trending up.")
        }
        if last < first {
            return String(localized: "Your last \(shown.count) readings: \(arrowed) \(unit), trending down.")
        }
        return String(localized: "Your last \(shown.count) readings: \(arrowed) \(unit), holding steady.")
    }

    private var latestReferenceText: String? {
        readings.last(where: { ($0.referenceText?.isEmpty == false) })?.referenceText
    }

    // MARK: - Compare with a signal (reuses the Pearson idiom + restrained copy)

    private var compareSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Compare with a signal")
            NoopCard {
                VStack(alignment: .leading, spacing: 12) {
                    // Signal picker + window control.
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            signalMenu
                            Spacer()
                            SegmentedPillControl(LabWindow.allCases, selection: $window) { $0.label }
                                .accessibilityLabel("Trailing window")
                        }
                        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                            signalMenu
                            SegmentedPillControl(LabWindow.allCases, selection: $window) { $0.label }
                                .accessibilityLabel("Trailing window")
                        }
                    }

                    if signal == nil {
                        Text("Pick a wearable signal (resting HR, HRV, sleep, Charge, weight…) to line it up against this marker. Nara averages the signal over the \(window.phrase) before each reading.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        resultBlock
                    }
                }
            }
        }
        .task(id: "\(signal?.id ?? "")|\(window.rawValue)|\(repo.refreshSeq)") {
            await recompute()
        }
    }

    private var signalMenu: some View {
        Menu {
            ForEach(LabBookSignals.options) { metric in
                Button {
                    signal = metric
                } label: {
                    Label(metric.title, systemImage: signal?.id == metric.id ? "checkmark" : metric.icon)
                }
            }
            if signal != nil {
                Divider()
                Button(role: .destructive) { signal = nil } label: { Label("Clear", systemImage: "xmark") }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                Text(signal?.title ?? "Choose a signal")
                    .font(StrandFont.subhead)
            }
            .foregroundStyle(StrandPalette.accent)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Choose a wearable signal to compare")
    }

    @ViewBuilder
    private var resultBlock: some View {
        let n = pairs.count
        if computing {
            Text("Lining them up…").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
        } else if n < LabBookSignals.floor {
            // Below the floor: show the points exist, withhold the conclusion sentence.
            // Whole-phrase variants per count (never a stitched plural).
            Text(n == 0
                 ? "No overlap yet between this marker and \(signal?.title.lowercased() ?? String(localized: "that signal")). Log a few more readings (and keep wearing your strap)."
                 : (n == 1
                    ? "1 reading lines up so far, not enough to read a trend yet (Nara waits for \(LabBookSignals.floor))."
                    : "\(n) readings line up so far, not enough to read a trend yet (Nara waits for \(LabBookSignals.floor))."))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let c = correlation {
            pairResult(c, n: n)
        } else {
            Text("\(n) readings line up, but there isn't enough variation to compute a relationship.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One correlation read-out, in the shipped restrained idiom + the mandatory markers clause: r with a
    /// bar for its direction and size, and the scatter of each reading against the signal's mean before it.
    private func pairResult(_ c: Correlation, n: Int) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(displayName) ↔ \(signal?.title ?? "")")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: NoopMetrics.space2)
                Text("r = \(LabBookSignals.signedR(c.r))")
                    .font(StrandFont.number(17))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            InsightsDivergingBar(value: c.r, magnitude: 1,
                                 positiveColor: StrandPalette.metricCyan, negativeColor: StrandPalette.metricRose)
            Text(LabBookSignals.insightSentence(markerName: displayName,
                                                 signalName: signal?.title ?? "the signal",
                                                 r: c.r))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            InsightsScatterChart(pairs: LabBookProjection.correlationInput(pairs),
                                 xTitle: unit.isEmpty ? displayName : "\(displayName) (\(unit))",
                                 yTitle: signal.map { $0.unit.isEmpty ? $0.title : "\($0.title) (\($0.unit))" } ?? "",
                                 color: StrandPalette.metricCyan)
            // The mandatory clause for markers (spec §"On-device algorithm").
            Text("\(n) readings used · \(LabBookSignals.strengthWord(c.r)) \(LabBookSignals.directionWord(c.r)) association. This is your own data sitting side by side. It's not a medical finding, and it shows association, not cause.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, NoopMetrics.spaceHalf)
    }

    // MARK: - History table

    private var historySection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("History")
            NoopCard {
                VStack(spacing: 0) {
                    ForEach(Array(readings.reversed().enumerated()), id: \.element.id) { idx, row in
                        historyRow(row)
                        if idx < readings.count - 1 {
                            Divider().overlay(StrandPalette.hairline)
                        }
                    }
                }
            }
        }
    }

    private func historyRow(_ row: LabMarkerRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(valueLabel(row))
                    .font(StrandFont.number(16))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(LabBookFormat.dayFromKey(row.day))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                if let note = row.note, !note.isEmpty {
                    Text(note)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                Task { await onDelete(row.id) }
            } label: {
                Image(systemName: "trash")
                    .font(StrandFont.icon(.inline))
                    .foregroundStyle(StrandPalette.statusCritical)
                    .frame(width: NoopMetrics.minimumHitTarget, height: NoopMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete this reading")
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func valueLabel(_ row: LabMarkerRow) -> String {
        if let v = row.value { return "\(LabBookFormat.value(v, key: markerKey)) \(row.unit)" }
        return row.valueText ?? "—"
    }

    // MARK: - Correlation compute (windowed-aggregate pairing → Pearson)

    private func recompute() async {
        guard let signal else { pairs = []; correlation = nil; return }
        computing = true
        defer { computing = false }
        // The marker series, read from the projected `lab-book` daily series (numeric only).
        let markerSeries = await repo.series(key: markerKey, source: WhoopStore.labBookSourceId)
        // The wearable series, freshest-wins through the Explore read path.
        let wearable = await repo.exploreSeries(key: signal.key, source: signal.source)
        let built = LabBookProjection.pairMarkerToWearable(marker: markerSeries,
                                                           wearable: wearable,
                                                           windowDays: window.days)
        pairs = built
        correlation = built.count >= LabBookSignals.floor
            ? CorrelationEngine.pearson(LabBookProjection.correlationInput(built))
            : nil
    }
}

// MARK: - Trailing window control (7 / 14 / 30 days)

enum LabWindow: String, CaseIterable, Identifiable {
    case week, fortnight, month
    var id: String { rawValue }
    var label: String {
        switch self {
        case .week:      return String(localized: "7d")
        case .fortnight: return String(localized: "14d")
        case .month:     return String(localized: "30d")
        }
    }
    var days: Int {
        switch self {
        case .week:      return 7
        case .fortnight: return 14
        case .month:     return 30
        }
    }
    var phrase: String {
        switch self {
        case .week:      return String(localized: "7 days")
        case .fortnight: return String(localized: "14 days")
        case .month:     return String(localized: "30 days")
        }
    }
}

// MARK: - Wearable signals offered for correlation + the shared insight language
//
// The pickable wearable metrics + the restrained correlation copy, kept here so the
// Lab Book detail's "Compare with a signal" reads in the exact CompareView idiom
// (strength words, tends-to, association-not-cause) plus the mandatory markers clause.

enum LabBookSignals {
    /// The reading-count floor below which NO conclusion sentence renders (spec default 4).
    static let floor = 4

    /// The wearable metrics offered to pair a marker against. Strap-source keys read through the
    /// Explore freshest-wins path; weight resolves from Apple/Health-Connect/strap as available.
    static let options: [MetricDescriptor] = [
        descriptor("rhr"),
        descriptor("hrv"),
        descriptor("recovery"),
        descriptor("sleep_performance"),
        descriptor("sleep_total_min"),
        descriptor("strain"),
        descriptor("skin_temp"),
        descriptor("steps"),
        descriptor("weight"),
    ].compactMap { $0 }

    private static func descriptor(_ key: String) -> MetricDescriptor? {
        MetricCatalog.all.first { $0.key == key }
    }

    static func signedR(_ r: Double) -> String {
        (r >= 0 ? "+" : "−") + String(format: "%.2f", abs(r))
    }

    static func strengthWord(_ r: Double) -> String {
        switch abs(r) {
        case ..<0.1:  return String(localized: "negligible")
        case ..<0.3:  return String(localized: "weak")
        case ..<0.5:  return String(localized: "moderate")
        case ..<0.7:  return String(localized: "strong")
        default:      return String(localized: "very strong")
        }
    }

    static func directionWord(_ r: Double) -> String {
        if abs(r) < 0.1 { return "" }
        return r >= 0 ? String(localized: "positive") : String(localized: "negative")
    }

    /// "When LDL is higher, HRV tends to be lower." — descriptive, no causal language.
    /// Whole-phrase variants per direction so translators never see a stitched verb fragment.
    static func insightSentence(markerName: String, signalName: String, r: Double) -> String {
        guard abs(r) >= 0.3 else {
            return String(localized: "Over your readings, \(markerName) and \(signalName.lowercased()) move largely independently. No clear relationship.")
        }
        return r < 0
            ? String(localized: "When \(markerName) is higher, \(signalName.lowercased()) tends to be lower.")
            : String(localized: "When \(markerName) is higher, \(signalName.lowercased()) tends to be higher.")
    }

    static func correlationColor(_ r: Double) -> Color {
        let base = r >= 0 ? StrandPalette.statusPositive : StrandPalette.statusCritical
        return base.opacity(0.55 + 0.45 * min(abs(r), 1.0))
    }
}

// MARK: - First-use / linked disclaimer

private struct LabBookDisclaimerView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScreenScaffold(title: "About Lab Book", titleDisplay: .navigationBar) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                bullet(String(localized: "Nara stores and lines up the numbers you enter yourself. It does not test you, read your results, give medical advice, or diagnose anything."))
                bullet(String(localized: "Anything you see here (including any side-by-side trend) is your own information shown back to you. It's an association, never a cause, and never a medical finding."))
                bullet(String(localized: "Nara never decides whether a value is \"normal,\" \"high,\" or \"low.\" Any reference range shown is exactly what you typed from your own report."))
                bullet(String(localized: "Your records never leave \(Platform.deviceNounPhrase). There's no account, no cloud, no Nara server. Because Nara is an independent app you run yourself (not a healthcare provider), it isn't \"HIPAA-covered,\" and that protection doesn't apply here; the safety comes from the data being local-only and yours."))
                bullet(String(localized: "Always rely on your doctor, pharmacist, or a qualified professional to interpret results and make decisions. If a number worries you, talk to them, not to an app."))
                Button("Got it") { dismiss() }
                    .buttonStyle(.noopPrimary)
                    .padding(.top, 4)
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 480, height: 560)
        #endif
        .background(StrandPalette.surfaceBase)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(StrandPalette.metricCyan)
                .frame(width: 6, height: 6)
                .padding(.top, 7)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
/// `--demo-screen labmarker`: the first stored marker's detail page (pair with `--demo-labbook`), so the
/// readings chart and compare section can be screenshotted without a tap.
struct LabMarkerDemoScreen: View {
    @EnvironmentObject var repo: Repository
    @State private var rows: [LabMarkerRow] = []

    var body: some View {
        Group {
            if let key = rows.first?.markerKey {
                MarkerDetailView(markerKey: key, readings: rows.filter { $0.markerKey == key },
                                 onDelete: { _ in })
            } else {
                ComingSoon(what: "No readings yet")
            }
        }
        .task(id: repo.refreshSeq) {
            guard let store = await repo.storeHandle() else { return }
            let all = (try? await store.labMarkers(deviceId: repo.deviceId, category: LabMarkerCategory.bloodPanel.rawValue)) ?? []
            rows = all.sorted { $0.takenAt < $1.takenAt }
        }
    }
}

@MainActor
private func labBookPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Lab Book") {
    LabBookView()
        .environmentObject(labBookPreviewRepo())
        .environmentObject(LiveState())
        .frame(width: 920, height: 860)
        .preferredColorScheme(.dark)
}
#endif
