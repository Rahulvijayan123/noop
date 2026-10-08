import Foundation

// ActivityContextComparison.swift — what an added expert changes in the FINAL activity output, not in its own
// classifier accuracy: the canonical class, confidence and display label a decode publishes, second by second,
// against a reference decode of the same input (HART alone). The candidate comparison stores it per arm
// (`activity_candidate_days.arms`) and the offline replay harness reports it per arm, so a joint candidate that
// regresses can be located in time and attributed to the expert whose ablation regresses the same way.

/// One stretch of a decode's published output.
public struct ActivityOutputSegment: Equatable, Sendable {
    public var start: Int
    public var end: Int
    public var activityClass: ActivityClass
    public var confidence: Double
    public var display: String?

    public init(start: Int, end: Int, activityClass: ActivityClass, confidence: Double, display: String?) {
        self.start = start; self.end = end; self.activityClass = activityClass
        self.confidence = confidence; self.display = display
    }

    /// A day document's runs, one segment each.
    public static func of(_ document: ActivityContextDayDocument) -> [ActivityOutputSegment] {
        document.runs.map { run in
            let k = run.classification
            return ActivityOutputSegment(start: run.start, end: run.end, activityClass: k.activityClass,
                                         confidence: k.confidence, display: run.displayContext)
        }
    }

    /// Published states, each describing the `intervalS` seconds up to its `ts` (the decoder's publish cadence).
    public static func of(states: [ActivityContextState], intervalS: Int) -> [ActivityOutputSegment] {
        let step = max(1, intervalS)
        return states.map { s in
            let k = ActivityClassifier.classify(state: s)
            return ActivityOutputSegment(start: s.ts - step, end: s.ts, activityClass: k.activityClass,
                                         confidence: k.confidence, display: s.displayContext)
        }
    }
}

/// How one decode reads its span.
public struct ActivityOutputSummary: Codable, Equatable, Sendable {
    /// Seconds the decode describes, and those it does not call off-wrist.
    public var seconds: Int
    public var onWristSeconds: Int
    /// Seconds per canonical class (`ActivityClass` raw values).
    public var classSeconds: [String: Int]
    /// Share of on-wrist seconds with a class other than `unknown`.
    public var coverage: Double
    /// Share of on-wrist seconds with a display label (not "Unclear").
    public var displayCoverage: Double
    /// Mean class confidence over on-wrist seconds.
    public var meanConfidence: Double

    enum CodingKeys: String, CodingKey {
        case seconds, onWristSeconds = "on_wrist_s", classSeconds = "class_s", coverage
        case displayCoverage = "display_coverage", meanConfidence = "mean_confidence"
    }

    public init(_ segments: [ActivityOutputSegment]) {
        var seconds = 0, onWrist = 0, known = 0, labelled = 0
        var confidence = 0.0
        var classes: [String: Int] = [:]
        for s in segments where s.end > s.start {
            let n = s.end - s.start
            seconds += n
            classes[s.activityClass.rawValue, default: 0] += n
            guard s.activityClass != .offWrist else { continue }
            onWrist += n
            if s.activityClass != .unknown { known += n }
            if Self.labelled(s.display) { labelled += n }
            confidence += s.confidence * Double(n)
        }
        self.seconds = seconds
        self.onWristSeconds = onWrist
        self.classSeconds = classes
        self.coverage = Self.share(known, onWrist)
        self.displayCoverage = Self.share(labelled, onWrist)
        self.meanConfidence = onWrist > 0 ? Self.rounded(confidence / Double(onWrist)) : 0
    }

    static func labelled(_ display: String?) -> Bool {
        guard let display, !display.isEmpty else { return false }
        return display != ActivityDisplay.unclear
    }

    static func share(_ part: Int, _ whole: Int) -> Double { whole > 0 ? rounded(Double(part) / Double(whole)) : 0 }
    static func rounded(_ x: Double) -> Double { (x * 10_000).rounded() / 10_000 }
}

/// A candidate decode against a reference decode of the same input, over the seconds both describe.
public struct ActivityOutputComparison: Codable, Equatable, Sendable {
    /// A stretch where the two decodes publish different classes.
    public struct Difference: Codable, Equatable, Sendable {
        public var start: Int
        public var end: Int
        public var reference: String
        public var candidate: String

        enum CodingKeys: String, CodingKey { case start = "s", end = "e", reference, candidate }
    }

    public var reference: ActivityOutputSummary
    public var candidate: ActivityOutputSummary
    /// Seconds both decodes describe.
    public var commonSeconds: Int
    public var classAgreementSeconds: Int
    /// Share of the common seconds on which the class is the same.
    public var classAgreement: Double
    public var displayAgreementSeconds: Int
    /// The largest class changes, "<reference>><candidate>" → seconds (at most `maxChanges`).
    public var changes: [String: Int]
    /// Merged stretches where the class differs, in time order (the first `maxDifferences`).
    public var differences: [Difference]
    public var differencesTruncated: Bool

    public static let maxChanges = 12
    public static let maxDifferences = 200

    enum CodingKeys: String, CodingKey {
        case reference, candidate, commonSeconds = "common_s", classAgreementSeconds = "class_agreement_s"
        case classAgreement = "class_agreement", displayAgreementSeconds = "display_agreement_s", changes
        case differences, differencesTruncated = "differences_truncated"
    }

    /// Compare two decodes. Each list is non-overlapping (a decode's runs or its states); seconds only one of them
    /// describes count in its own summary but not in the agreement.
    public static func compare(reference: [ActivityOutputSegment],
                               candidate: [ActivityOutputSegment]) -> ActivityOutputComparison {
        let ref = reference.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        let cand = candidate.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var points = Set<Int>()
        for s in ref { points.insert(s.start); points.insert(s.end) }
        for s in cand { points.insert(s.start); points.insert(s.end) }
        let cuts = points.sorted()
        var i = 0, j = 0
        var common = 0, sameClass = 0, sameDisplay = 0
        var changes: [String: Int] = [:]
        var differences: [Difference] = []
        var truncated = false
        for k in 0..<max(0, cuts.count - 1) {
            let a = cuts[k], b = cuts[k + 1]
            while i < ref.count, ref[i].end <= a { i += 1 }
            while j < cand.count, cand[j].end <= a { j += 1 }
            guard i < ref.count, ref[i].start <= a, j < cand.count, cand[j].start <= a else { continue }
            let r = ref[i], c = cand[j], n = b - a
            common += n
            if r.activityClass == c.activityClass {
                sameClass += n
            } else {
                changes["\(r.activityClass.rawValue)>\(c.activityClass.rawValue)", default: 0] += n
                if let last = differences.last, last.end == a, last.reference == r.activityClass.rawValue,
                   last.candidate == c.activityClass.rawValue {
                    differences[differences.count - 1].end = b
                } else if differences.count < maxDifferences {
                    differences.append(Difference(start: a, end: b, reference: r.activityClass.rawValue,
                                                  candidate: c.activityClass.rawValue))
                } else {
                    truncated = true
                }
            }
            if ActivityOutputSummary.labelled(r.display) == ActivityOutputSummary.labelled(c.display),
               !ActivityOutputSummary.labelled(r.display) || r.display == c.display {
                sameDisplay += n
            }
        }
        let top = changes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(maxChanges)
        return ActivityOutputComparison(
            reference: ActivityOutputSummary(ref), candidate: ActivityOutputSummary(cand),
            commonSeconds: common, classAgreementSeconds: sameClass,
            classAgreement: ActivityOutputSummary.share(sameClass, common),
            displayAgreementSeconds: sameDisplay,
            changes: Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) }),
            differences: differences, differencesTruncated: truncated)
    }

    /// Two day documents (their runs).
    public static func compare(reference: ActivityContextDayDocument,
                               candidate: ActivityContextDayDocument) -> ActivityOutputComparison {
        compare(reference: ActivityOutputSegment.of(reference), candidate: ActivityOutputSegment.of(candidate))
    }
}
