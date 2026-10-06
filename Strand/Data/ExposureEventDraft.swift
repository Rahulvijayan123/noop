import Foundation
import StrandAnalytics

/// What the timed-event editor collects, and the revision it turns into. Pure, so it is unit-tested.
///
/// A point in time is stored as `[t, t+1)`. "Approximate" around a point widens it to the hour around it
/// (`[t - 30 min, t + 30 min)`), so the record itself says how well the time is known; a range keeps its own ends.
struct ExposureEventDraft: Equatable {
    static let approximateHalfWidthS = 30 * 60

    var kind: PhysiologyContext.ExposureKind = .medication
    var label = ""
    var start: Date
    /// nil = a single moment.
    var end: Date?
    /// `.exact` or `.approximate` (day-only answers come from the journal, not the editor).
    var precision: PhysiologyContext.TimePrecision = .exact
    var doseText = ""
    var doseUnit = ""

    enum Problem: Equatable {
        case endBeforeStart
        case doseNotANumber
    }

    init(start: Date) { self.start = start }

    /// Prefill from the event being edited.
    init(event: PhysiologyContext.ExposureEvent) {
        kind = event.kind
        label = event.label
        precision = event.timePrecision == .exact ? .exact : .approximate
        let s = event.occurred.start, e = event.occurred.end
        if e - s <= 1 {
            start = Date(timeIntervalSince1970: TimeInterval(s)); end = nil; precision = .exact
        } else if event.timePrecision == .approximate && e - s == 2 * Self.approximateHalfWidthS {
            start = Date(timeIntervalSince1970: TimeInterval(s + Self.approximateHalfWidthS)); end = nil
        } else {
            start = Date(timeIntervalSince1970: TimeInterval(s)); end = Date(timeIntervalSince1970: TimeInterval(e))
        }
        if let d = event.doseAmount { doseText = Self.format(d) }
        doseUnit = event.doseUnit ?? ""
    }

    var problems: [Problem] {
        var out: [Problem] = []
        if let end, end <= start { out.append(.endBeforeStart) }
        if !doseText.trimmingCharacters(in: .whitespaces).isEmpty && dose == nil { out.append(.doseNotANumber) }
        return out
    }

    /// The dose as entered (a positive finite number), or nil.
    var dose: Double? {
        let t = doseText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let v = Double(t), v.isFinite, v > 0 else { return nil }
        return v
    }

    var occurred: PhysiologyContext.Interval {
        let s = Int(start.timeIntervalSince1970)
        if let end { return PhysiologyContext.Interval(s, max(s + 1, Int(end.timeIntervalSince1970))) }
        if precision == .approximate {
            return PhysiologyContext.Interval(s - Self.approximateHalfWidthS, s + Self.approximateHalfWidthS)
        }
        return PhysiologyContext.Interval(s, s + 1)
    }

    /// The next revision of `eventId` (revision 1 when `previous` is nil), or nil when the draft is invalid or
    /// states exactly what the latest revision already says.
    func revision(eventId: String, previous: ExposureEventStore.Revision?,
                  recordedAt: Date) -> ExposureEventStore.Revision? {
        guard problems.isEmpty else { return nil }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = doseUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        let amount = dose
        let next = ExposureEventStore.Revision(
            eventId: eventId, revision: (previous?.revision ?? 0) + 1, kind: kind,
            label: trimmedLabel.isEmpty ? kind.rawValue : trimmedLabel, occurred: occurred,
            timePrecision: end == nil && precision == .exact ? .exact : precision,
            recordedAt: Int(recordedAt.timeIntervalSince1970), source: .userEntered, confirmation: .confirmed,
            doseAmount: amount, doseUnit: amount == nil || unit.isEmpty ? nil : unit,
            doseProvenance: amount == nil ? nil : "user_entered")
        if let previous, previous.confirmation != .retracted, ExposureJournalBridge.sameStatement(previous, next) {
            return nil
        }
        return next
    }

    static func format(_ d: Double) -> String {
        d.rounded() == d ? String(Int(d)) : String(d)
    }
}

extension PhysiologyContext.ExposureKind {
    /// User-facing name of the kind.
    var title: String {
        switch self {
        case .medication: return String(localized: "Medication")
        case .supplement: return String(localized: "Supplement")
        case .caffeine: return String(localized: "Caffeine")
        case .alcohol: return String(localized: "Alcohol")
        case .meal: return String(localized: "Meal")
        case .heat: return String(localized: "Heat")
        case .travel: return String(localized: "Travel")
        case .symptom: return String(localized: "Symptom")
        case .other: return String(localized: "Other")
        }
    }
}
