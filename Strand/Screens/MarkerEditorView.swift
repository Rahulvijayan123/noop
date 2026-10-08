import SwiftUI
import Foundation
import StrandDesign
import StrandImport
import StrandAnalytics
import WhoopStore

// MARK: - Marker editor (manual entry — MVP)
//
// The "+ add a reading" sheet for the Lab Book (Health Records pillar, spec §"Add / edit
// a marker"). Pick a marker from MarkerCatalog (searchable) OR add a custom marker (free
// name + unit), then: value (numeric, the marker's canonical unit prefilled, a unit
// switcher where sensible e.g. mmol/L↔mg/dL with the conversion shown transparently),
// date/time taken, an optional note, and an OPTIONAL "reference range from my report"
// free-text — NEVER a NOOP-shipped range. Blood pressure is a PAIRED marker (systolic +
// diastolic entered together, stored as two keys) so it reads naturally.
//
// On save it hands the caller `[LabMarkerRow]` drafts (one row, or two for BP) under the
// strap device id with a `lab-book`-projecting write path; the caller persists + refreshes.
// SELF-CONTAINED: no AppModel/Settings edits; the sheet owns all its state.
//
// NON-CLINICAL: this only captures what the user types. The reference field is theirs,
// shown back verbatim — NOOP defines no ranges and asserts no normality.

struct MarkerEditorView: View {
    /// Persist the validated draft row(s). Async so the caller can write + refresh.
    let onSave: (_ drafts: [LabMarkerRow]) async -> Void

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    // Marker selection.
    @State private var selection: MarkerDefinition?
    @State private var customName = ""
    @State private var customUnit = ""
    @State private var addingCustom = false
    @State private var search = ""

    // Reading inputs.
    @State private var valueText = ""
    @State private var diastolicText = ""   // only used for the paired BP marker
    @State private var unit = ""
    @State private var unitChoice = 0       // index into the active unit options (the switcher)
    @State private var takenAt = Date()
    @State private var note = ""
    @State private var referenceText = ""

    @State private var saving = false

    private enum Field: Hashable { case value, diastolic, note, reference, customName, customUnit }
    @FocusState private var focused: Field?

    var body: some View {
        NavigationStack {
            Form {
                markerSection
                if selection != nil || addingCustom {
                    readingSection
                    detailsSection
                }
            }
            .eventEditorForm()
            .keyboardDoneToolbar($focused)
            .navigationTitle("Add a reading")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(drafts.isEmpty || saving)
                        .accessibilityLabel("Save reading")
                }
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        // A FIXED frame (not minWidth/minHeight): a macOS sheet hosting a scrolling form needs a definite
        // height, otherwise its height stays ambiguous and every row collapses to the top, rendering the
        // title/fields/catalog on top of each other. Matches the other editor sheets.
        .frame(width: 520, height: 720)
        #endif
    }

    // MARK: - Marker picker

    @ViewBuilder
    private var markerSection: some View {
        Section {
            if addingCustom {
                customMarkerFields
            } else if let selection {
                chosenMarkerRow(selection)
            } else {
                searchField
                catalogRows
                Button {
                    addingCustom = true
                    focused = .customName
                } label: {
                    Label("Add a custom marker", systemImage: "plus")
                        .foregroundStyle(StrandPalette.accent)
                }
            }
        } header: {
            Text("Marker")
        }
        .eventEditorRow()
    }

    private var searchField: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            TextField("Search markers (e.g. LDL, ferritin)", text: $search)
                .accessibilityLabel("Search markers")
        }
    }

    private var filteredCatalog: [MarkerDefinition] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return MarkerCatalog.builtIn }
        return MarkerCatalog.builtIn.filter {
            $0.displayName.lowercased().contains(q) || $0.key.contains(q)
        }
    }

    /// Every catalog marker as a form row; the form itself scrolls, so there is no nested scroll view.
    @ViewBuilder
    private var catalogRows: some View {
        ForEach(filteredCatalog, id: \.key) { def in
            Button {
                choose(def)
            } label: {
                HStack(spacing: NoopMetrics.space3) {
                    VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                        Text(def.displayName)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(def.category.displayName)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    Text(def.canonicalUnit)
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(def.displayName), \(def.canonicalUnit)")
        }
        if filteredCatalog.isEmpty {
            Text("No match")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func chosenMarkerRow(_ def: MarkerDefinition) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(def.displayName).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(def.category.displayName).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            Button("Change") { reset() }
                .buttonStyle(.plain)
                .font(StrandFont.subhead.weight(.medium))
                .foregroundStyle(StrandPalette.accent)
                .accessibilityLabel("Change marker")
        }
    }

    @ViewBuilder
    private var customMarkerFields: some View {
        LabeledContent("Name") {
            TextField("e.g. Magnesium", text: $customName)
                .multilineTextAlignment(.trailing)
                .focused($focused, equals: .customName)
                .accessibilityLabel("Custom marker name")
        }
        LabeledContent("Unit") {
            TextField("e.g. mmol/L", text: $customUnit)
                .multilineTextAlignment(.trailing)
                .focused($focused, equals: .customUnit)
                .accessibilityLabel("Custom marker unit")
        }
        Button("Back to the marker list") { addingCustom = false }
            .foregroundStyle(StrandPalette.accent)
    }

    // MARK: - Reading inputs

    @ViewBuilder
    private var readingSection: some View {
        Section {
            if isBloodPressure {
                LabeledContent("Systolic") {
                    numberBox(placeholder: String(localized: "e.g. 120"), text: $valueText, unit: "mmHg", field: .value)
                        .accessibilityLabel("Systolic blood pressure in mmHg")
                }
                LabeledContent("Diastolic") {
                    numberBox(placeholder: String(localized: "e.g. 80"), text: $diastolicText, unit: "mmHg", field: .diastolic)
                        .accessibilityLabel("Diastolic blood pressure in mmHg")
                }
            } else {
                LabeledContent("Value") {
                    numberBox(placeholder: String(localized: "e.g. 3.1"), text: $valueText, unit: activeUnit, field: .value)
                }
                if unitOptions.count > 1 {
                    // The transparent unit switcher (e.g. mmol/L ↔ mg/dL).
                    Picker("Unit", selection: $unitChoice) {
                        ForEach(Array(unitOptions.indices), id: \.self) { index in
                            Text(unitOptions[index]).tag(index)
                        }
                    }
                }
            }
            DatePicker("Date taken", selection: $takenAt, in: ...Date(),
                       displayedComponents: [.date, .hourAndMinute])
                .accessibilityLabel("Date and time taken")
        } header: {
            Text("Reading")
        } footer: {
            if let conversionLine {
                Text(verbatim: conversionLine)
            }
        }
        .eventEditorRow()
    }

    private var detailsSection: some View {
        Section {
            LabeledContent("Note") {
                TextField("Optional", text: $note)
                    .multilineTextAlignment(.trailing)
                    .focused($focused, equals: .note)
                    .accessibilityLabel("Optional note")
            }
            LabeledContent("Reference range") {
                TextField("From your report", text: $referenceText)
                    .multilineTextAlignment(.trailing)
                    .focused($focused, equals: .reference)
                    .accessibilityLabel("Reference range from your own report, optional")
            }
        }
        .eventEditorRow()
    }

    private func numberBox(placeholder: String, text: Binding<String>, unit: String, field: Field) -> some View {
        HStack(spacing: NoopMetrics.space1) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .numericKeyboard()
                .focused($focused, equals: field)
            Text(unit).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    /// What will be stored when the typed unit is converted: "Saved as 3.1 mmol/L". Nil when nothing converts.
    private var conversionLine: String? {
        guard unitOptions.count > 1 else { return nil }
        let canonical = MarkerUnits.canonicalUnit(for: markerKey, fallback: unit)
        guard activeUnit != canonical,
              MarkerUnits.factorToCanonical(markerKey: markerKey, from: activeUnit) != nil else { return nil }
        guard let raw = parsed(valueText) else { return String(localized: "Saved in \(canonical)") }
        let stored = MarkerUnits.toCanonical(markerKey: markerKey, value: raw, from: activeUnit)
        return String(localized: "Saved as \(stored.formatted(.number.precision(.fractionLength(0...2)))) \(canonical)")
    }

    // MARK: - Selection + units

    private func choose(_ def: MarkerDefinition) {
        selection = def
        unit = def.canonicalUnit
        unitChoice = 0
        focused = .value
    }

    private func reset() {
        selection = nil
        valueText = ""
        diastolicText = ""
        unitChoice = 0
        search = ""
    }

    /// The active marker key (catalog key, or a slug of the custom name).
    private var markerKey: String {
        if let selection { return selection.key }
        return MarkerUnits.slug(customName)
    }

    private var category: LabMarkerCategory {
        if let selection { return selection.category }
        return .other
    }

    private var isBloodPressure: Bool { markerKey == LabBookProjection.bpSystolicKey }

    /// The unit options for the active marker — a switcher list only for markers that have a
    /// well-known dual unit (lipids/glucose: mmol/L↔mg/dL). Everything else has one canonical unit.
    private var unitOptions: [String] {
        if addingCustom { return [customUnit.isEmpty ? "" : customUnit] }
        return MarkerUnits.options(for: markerKey, canonical: unit)
    }

    private var activeUnit: String {
        guard unitOptions.indices.contains(unitChoice) else { return unit }
        return unitOptions[unitChoice]
    }

    // MARK: - Build the draft rows

    /// The validated draft row(s): two for BP, one otherwise. Empty when inputs aren't usable yet.
    private var drafts: [LabMarkerRow] {
        // Custom marker needs a name + unit.
        if addingCustom {
            guard !customName.trimmingCharacters(in: .whitespaces).isEmpty,
                  !customUnit.trimmingCharacters(in: .whitespaces).isEmpty,
                  let v = parsed(valueText) else { return [] }
            return [row(key: markerKey, category: .other, value: v, unit: customUnit)]
        }
        guard selection != nil else { return [] }
        if isBloodPressure {
            guard let sys = parsed(valueText), let dia = parsed(diastolicText) else { return [] }
            return [
                row(key: LabBookProjection.bpSystolicKey, category: .bloodPressure, value: sys, unit: "mmHg"),
                row(key: LabBookProjection.bpDiastolicKey, category: .bloodPressure, value: dia, unit: "mmHg"),
            ]
        }
        guard let raw = parsed(valueText) else { return [] }
        // Convert the entered value to the canonical stored unit if a switcher is in use.
        let canonical = MarkerUnits.canonicalUnit(for: markerKey, fallback: unit)
        let stored = MarkerUnits.toCanonical(markerKey: markerKey, value: raw, from: activeUnit)
        return [row(key: markerKey, category: category, value: stored, unit: canonical)]
    }

    private func row(key: String, category: LabMarkerCategory, value: Double, unit: String) -> LabMarkerRow {
        let trimmedNote = note.trimmingCharacters(in: .whitespaces)
        let trimmedRef = referenceText.trimmingCharacters(in: .whitespaces)
        let epoch = Int(takenAt.timeIntervalSince1970)
        return LabMarkerRow(
            id: "\(key)-\(epoch)-\(UUID().uuidString.prefix(8))",
            deviceId: repo.deviceId,
            markerKey: key,
            category: category.rawValue,
            day: LabBookFormat.dayKey(takenAt),
            takenAt: epoch,
            value: value,
            valueText: nil,
            unit: unit,
            source: "manual",
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            referenceText: trimmedRef.isEmpty ? nil : trimmedRef
        )
    }

    private func parsed(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces))
    }

    private func save() {
        let rows = drafts
        guard !rows.isEmpty else { return }
        saving = true
        Task {
            await onSave(rows)
            dismiss()
        }
    }

}

// MARK: - Unit handling (transparent mmol/L ↔ mg/dL switcher for lipids/glucose)
//
// Only the markers with a well-known dual unit get a switcher; everything else keeps its
// single canonical unit. Conversions are exact and reversible. The stored value is always
// the canonical unit, so the daily projection + correlation stay consistent regardless of
// what the user typed in.

enum MarkerUnits {
    /// Markers whose mg/dL → mmol/L factor we know (molar-mass derived, standard clinical factors).
    /// Lipids share 38.67; glucose uses 18.0.
    private static let mgdlToMmol: [String: Double] = [
        "total_cholesterol": 1.0 / 38.67,
        "ldl":               1.0 / 38.67,
        "hdl":               1.0 / 38.67,
        "triglycerides":     1.0 / 88.57,   // triglyceride molar conversion
        "fasting_glucose":   1.0 / 18.0,
    ]

    /// The canonical (stored) unit for a marker — the catalog's, or a fallback.
    static func canonicalUnit(for key: String, fallback: String) -> String {
        MarkerCatalog.definition(for: key)?.canonicalUnit ?? fallback
    }

    /// The unit options shown in the switcher. Two entries (canonical + mg/dL) for the dual-unit
    /// markers; otherwise just the single canonical unit.
    static func options(for key: String, canonical: String) -> [String] {
        if mgdlToMmol[key] != nil { return [canonicalUnit(for: key, fallback: canonical), "mg/dL"] }
        return [canonical]
    }

    /// Multiplicative factor turning a value in `from` into the canonical unit, or nil if no conversion.
    static func factorToCanonical(markerKey: String, from unit: String) -> Double? {
        guard unit == "mg/dL", let f = mgdlToMmol[markerKey] else { return nil }
        return f
    }

    /// Convert a typed value (in `from`) to the canonical stored unit. Identity when no conversion applies.
    static func toCanonical(markerKey: String, value: Double, from unit: String) -> Double {
        guard let f = factorToCanonical(markerKey: markerKey, from: unit) else { return value }
        return value * f
    }

    /// A short label for the conversion factor (4 sig figs), e.g. "0.02586".
    static func factorLabel(_ f: Double) -> String { String(format: "%.5g", f) }

    /// A lower-cased, underscored slug for a custom marker name → its stable key. Delegates to the CSV
    /// importer's `customKey` so a hand-added custom marker and an imported one always share one key.
    static func slug(_ name: String) -> String {
        let key = LabMarkerCsvImport.customKey(name)
        return key.isEmpty ? "custom_" : key
    }
}

#if DEBUG
@MainActor
private func markerEditorPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Marker Editor") {
    MarkerEditorView { _ in }
        .environmentObject(markerEditorPreviewRepo())
        .frame(width: 520, height: 720)
        .preferredColorScheme(.dark)
}
#endif
