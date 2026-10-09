import Foundation

/// "How this was read", written out. The stretch sheet used to show the model's raw probabilities (posture,
/// movement and arm percentages, the experts that ran, the other source's label seconds). This turns the same
/// facts into short paragraphs, one per question a reader would ask: what was decided and how sure, what the
/// body was doing, what the strap recorded, what the reading relied on, and whether the other source agreed.
///
/// Templates, not a model: the text is built from the numbers on the phone, offline, and says nothing the numbers
/// do not. Pure (no views, no stores), so the wording is tested without the sheet.
enum StretchNarrative {
    struct Paragraph: Equatable, Identifiable {
        let title: String
        let text: String
        var id: String { title }
    }

    /// One answer of a head and its probability (0...1).
    struct Choice: Equatable {
        let name: String
        let p: Double
    }

    struct Other: Equatable {
        /// "the strap's own labels" or "the activity model".
        let source: String
        /// Longest first.
        let labels: [(label: String, seconds: Int)]

        static func == (a: Other, b: Other) -> Bool {
            a.source == b.source && a.labels.count == b.labels.count
                && zip(a.labels, b.labels).allSatisfy { $0.label == $1.label && $0.seconds == $1.seconds }
        }
    }

    struct Input {
        /// What the stretch is called.
        var label: String
        /// The activity model's confidence (0...1); nil for a stretch worked out from the strap's own signals.
        var confidence: Double?
        var posture: [Choice] = []
        var movement: [Choice] = []
        var arm: [Choice] = []
        /// For a strap-derived stretch: why the strap called it that ("From your logged sleep", …).
        var strapBasis: String?
        var strapDetail: String?
        var avgHr: Int?
        var minHr: Int?
        var maxHr: Int?
        var meanMotionG: Double?
        var peakMotionG: Double?
        var stepTicks: Int?
        var durationSeconds: Int
        /// Names of the evidence sources that ran, in order.
        var experts: [String] = []
        /// A specific reading ("Taking stairs") when the model made one.
        var specific: String?
        var gaitProbability: Double?
        var gaitCadence: Double?
        var gaitSpeed: Double?
        var other: Other?
        /// How many separate readings the stretch was joined from.
        var runCount = 0
    }

    // MARK: Build

    static func paragraphs(_ i: Input) -> [Paragraph] {
        [decision(i), body(i), recorded(i), reliedOn(i), agreement(i)].compactMap { $0 }
    }

    // MARK: Pieces

    /// What was decided, and how sure.
    static func decision(_ i: Input) -> Paragraph? {
        let title = String(localized: "What was decided")
        let minutes = duration(i.durationSeconds)
        if let c = i.confidence {
            let percent = Int((c * 100).rounded())
            var text = String(localized: "The activity model read these \(minutes) as \(i.label), with \(confidenceWord(c)) confidence (\(percent)%).")
            if c < 0.55 {
                text += " " + String(localized: "That is not a firm call, so treat the label as a best guess and tell us if it is wrong.")
            } else if c >= 0.8 {
                text += " " + String(localized: "The evidence pointed one way for the whole stretch.")
            }
            if i.runCount > 1 {
                text += " " + String(localized: "It is joined from \(i.runCount) shorter readings that all agreed on the label.")
            }
            return Paragraph(title: title, text: text)
        }
        if let basis = i.strapBasis {
            var text = String(localized: "The strap called these \(minutes) \(i.label). \(sentence(basis))")
            if let detail = i.strapDetail, !detail.isEmpty { text += " " + sentence(detail) }
            return Paragraph(title: title, text: text)
        }
        return nil
    }

    /// What the body was doing: posture, movement and what the arm was up to, in one paragraph.
    static func body(_ i: Input) -> Paragraph? {
        let parts = [
            head(i.posture, area: String(localized: "posture"),
                 verb: { String(localized: "It saw your body as \($0)") },
                 undecided: String(localized: "No single posture stood out")),
            head(i.movement, area: String(localized: "movement"),
                 verb: { String(localized: "For how you were moving, it favoured \($0)") },
                 undecided: String(localized: "No single kind of movement stood out")),
            head(i.arm, area: String(localized: "arm"),
                 verb: { String(localized: "Your arm looked like \($0)") },
                 undecided: String(localized: "What the arm was doing was unclear")),
        ].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return Paragraph(title: String(localized: "What your body was doing"), text: parts.joined(separator: " "))
    }

    /// What the strap itself measured over the stretch.
    static func recorded(_ i: Input) -> Paragraph? {
        var sentences: [String] = []
        if let avg = i.avgHr {
            if let lo = i.minHr, let hi = i.maxHr, hi > lo {
                sentences.append(String(localized: "Your heart rate averaged \(avg) bpm, moving between \(lo) and \(hi)."))
            } else {
                sentences.append(String(localized: "Your heart rate averaged \(avg) bpm."))
            }
        }
        if let motion = i.meanMotionG {
            var line = String(localized: "Your wrist showed \(motionWord(motion)) (\(String(format: "%.2f", motion)) g on average")
            if let peak = i.peakMotionG, peak > motion * 1.5, peak >= 0.05 {
                line += String(localized: ", peaking at \(String(format: "%.2f", peak)) g")
            }
            sentences.append(line + ").")
        }
        if let ticks = i.stepTicks {
            if ticks == 0 {
                sentences.append(String(localized: "The step counter did not move, so no steps were taken."))
            } else {
                let rate = Double(ticks) / Double(max(1, i.durationSeconds))
                sentences.append(String(localized: "The step counter advanced \(ticks) times, \(stepWord(rate))."))
            }
        }
        guard !sentences.isEmpty else { return nil }
        return Paragraph(title: String(localized: "What the strap recorded"), text: sentences.joined(separator: " "))
    }

    /// Which evidence the reading relied on.
    static func reliedOn(_ i: Input) -> Paragraph? {
        var sentences: [String] = []
        if !i.experts.isEmpty {
            sentences.append(String(localized: "To get there it combined \(list(i.experts))."))
        } else if i.confidence != nil {
            sentences.append(String(localized: "To get there it used the strap's motion, step counter and heart rate."))
        }
        if let specific = i.specific {
            sentences.append(String(localized: "It also made a more specific reading: \(specific.lowercased())."))
        }
        if let g = i.gaitProbability {
            var line = String(localized: "The gait check put the chance you were walking at \(Int((g * 100).rounded()))%")
            var extras: [String] = []
            if let c = i.gaitCadence { extras.append(String(localized: "a cadence of about \(Int(c.rounded())) steps a minute")) }
            if let s = i.gaitSpeed { extras.append(String(localized: "a speed of about \(String(format: "%.1f", s)) metres a second")) }
            if !extras.isEmpty { line += String(localized: ", with \(list(extras))") }
            sentences.append(line + ".")
        } else if i.confidence != nil {
            sentences.append(String(localized: "The gait check had no reading for this time."))
        }
        guard !sentences.isEmpty else { return nil }
        return Paragraph(title: String(localized: "What it relied on"), text: sentences.joined(separator: " "))
    }

    /// Whether the other source (the strap's own states, or the activity model) said the same thing.
    static func agreement(_ i: Input) -> Paragraph? {
        guard let other = i.other, let first = other.labels.first else { return nil }
        let title = String(localized: "Does the other reading agree?")
        let mine = i.label.lowercased()
        let top = first.label.lowercased()
        let total = max(1, other.labels.reduce(0) { $0 + $1.seconds })
        let share = Double(first.seconds) / Double(total)
        let agrees = top == mine || top.contains(mine) || mine.contains(top)
        var text: String
        if other.labels.count == 1 {
            text = agrees
                ? String(localized: "Yes. \(capitalized(other.source)) said \(first.label) for \(duration(first.seconds)) of it, the same call.")
                : String(localized: "Not quite. \(capitalized(other.source)) said \(first.label) for \(duration(first.seconds)) of it, where this reading says \(i.label).")
        } else {
            let rest = other.labels.dropFirst().prefix(2).map { "\($0.label) (\(duration($0.seconds)))" }
            text = agrees
                ? String(localized: "Mostly. \(capitalized(other.source)) said \(first.label) for \(duration(first.seconds)) of it (\(Int((share * 100).rounded()))%), and also \(list(rest)).")
                : String(localized: "They differ. \(capitalized(other.source)) said \(first.label) for \(duration(first.seconds)) of it, then \(list(rest)); this reading says \(i.label).")
        }
        text += " " + String(localized: "The two read the same strap signals in different ways, so a disagreement is a reason to check the label, not proof either one is wrong.")
        return Paragraph(title: title, text: text)
    }

    // MARK: Words

    static func confidenceWord(_ c: Double) -> String {
        c >= 0.8 ? String(localized: "high") : c >= 0.55 ? String(localized: "moderate") : String(localized: "low")
    }

    static func motionWord(_ g: Double) -> String {
        g < 0.02 ? String(localized: "almost no movement")
            : g < 0.08 ? String(localized: "light movement") : String(localized: "plenty of movement")
    }

    static func stepWord(_ perSecond: Double) -> String {
        perSecond >= 1.5 ? String(localized: "a steady walking pace")
            : perSecond >= 0.5 ? String(localized: "a few steps at a time")
            : String(localized: "only now and then")
    }

    /// "Sitting (86%), with leaning back (9%) as the runner-up." or the undecided line when the top answer is weak.
    private static func head(_ choices: [Choice], area: String, verb: (String) -> String, undecided: String) -> String? {
        guard let top = choices.max(by: { $0.p < $1.p }) else { return nil }
        let percent = Int((top.p * 100).rounded())
        guard top.p >= 0.5 else {
            let two = choices.sorted { $0.p > $1.p }.prefix(2).map { "\($0.name.lowercased()) (\(Int(($0.p * 100).rounded()))%)" }
            return "\(undecided): " + String(localized: "the closest were \(list(two)).")
        }
        var text = verb("\(top.name.lowercased()) (\(percent)%)")
        if let next = choices.filter({ $0.name != top.name }).max(by: { $0.p < $1.p }), next.p >= 0.15 {
            text += String(localized: ", with \(next.name.lowercased()) (\(Int((next.p * 100).rounded()))%) as the runner-up")
        }
        return text + "."
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return String(localized: "\(items[0]) and \(items[1])")
        default: return items.dropLast().joined(separator: ", ") + String(localized: ", and \(items[items.count - 1])")
        }
    }

    static func capitalized(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// A phrase as a sentence: first letter up, a full stop at the end.
    static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return t }
        let cased = first.uppercased() + t.dropFirst()
        return cased.hasSuffix(".") ? cased : cased + "."
    }

    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return String(localized: "\(s) seconds") }
        let m = Int((Double(s) / 60).rounded())
        if m < 60 { return m == 1 ? String(localized: "1 minute") : String(localized: "\(m) minutes") }
        let h = m / 60, r = m % 60
        return r == 0 ? String(localized: "\(h) h") : String(localized: "\(h) h \(r) min")
    }
}
