import Foundation

// KeyMetricHandoff.swift — what the key-metric screen hands Sana when the person taps "Ask Sana": a first question in
// their voice, the screen as the model should see it, and a memory that this metric matters to them. Pure, so the
// wording checks and tests can read it.

enum KeyMetricHandoff {
    /// The screen context's longest length (`CoachHandoff.screenContext`).
    static let contextCap = CoachHandoff.contextCap

    /// Everything the screen was showing, already in the reader's units and words.
    struct Screen: Equatable {
        /// "Heart rate variability (RMSSD)".
        var metricName: String
        /// "30 nights", "24 hours".
        var periodLabel: String
        /// "Sleep" in the 24-hour view.
        var contextFilter: String?
        /// "52 ms" and what it is ("Median of 26 measured nights").
        var headline: String?
        var headlineMeaning: String?
        /// "Your usual range: 45–62 ms".
        var rangeLine: String?
        /// The reading the person had selected, and what it meant: "48 ms · Tue, Oct 6", "Below your usual range".
        var selection: String?
        var selectionMeaning: String?
        /// "Estimated" when the metric is an estimate.
        var measurement: String?
        /// The most recent readings, newest last: ("Oct 6", "48 ms").
        var recent: [(label: String, value: String)] = []
        var countLine: String?
        /// The server's explanation as the screen shows it.
        var explanationHeadline: String?
        var explanationSentences: [String] = []
        var explanationBasis: String?

        static func == (a: Screen, b: Screen) -> Bool {
            a.metricName == b.metricName && a.periodLabel == b.periodLabel && a.contextFilter == b.contextFilter
                && a.headline == b.headline && a.headlineMeaning == b.headlineMeaning && a.rangeLine == b.rangeLine
                && a.selection == b.selection && a.selectionMeaning == b.selectionMeaning
                && a.measurement == b.measurement && a.recent.map(\.label) == b.recent.map(\.label)
                && a.recent.map(\.value) == b.recent.map(\.value) && a.countLine == b.countLine
                && a.explanationHeadline == b.explanationHeadline
                && a.explanationSentences == b.explanationSentences && a.explanationBasis == b.explanationBasis
        }
    }

    /// The first message: a plain question about the metric.
    static func prompt(metricName: String) -> String {
        String(localized: "Help me understand my \(lowercasedFirst(metricName)).")
    }

    /// The memory saved when the question is sent: the interest itself, never a reading.
    static func memory(metricName: String) -> String {
        String(localized: "Wants to understand their \(lowercasedFirst(metricName)); asked Sana about it from that metric's page.")
    }

    /// The model's view of the screen, one fact per line, at most `contextCap` characters. The explanation's
    /// sentences go last so a long one is what gets cut.
    static func context(_ s: Screen) -> String {
        var lines = ["Screen: the \(s.metricName) page, showing \(s.periodLabel)"
                        + (s.contextFilter.map { " (\($0) readings)" } ?? "") + "."]
        if let measurement = s.measurement { lines.append("This metric is \(measurement.lowercased()).") }
        if let headline = s.headline {
            lines.append("Shown value: \(headline)" + (s.headlineMeaning.map { " (\($0))" } ?? "") + ".")
        }
        if let rangeLine = s.rangeLine { lines.append("\(rangeLine).") }
        if let selection = s.selection {
            lines.append("Selected reading: \(selection)" + (s.selectionMeaning.map { " — \($0)" } ?? "") + ".")
        }
        if !s.recent.isEmpty {
            lines.append("Recent readings: " + s.recent.map { "\($0.label) \($0.value)" }.joined(separator: "; ") + ".")
        }
        if let countLine = s.countLine { lines.append("\(countLine).") }
        if let headline = s.explanationHeadline {
            lines.append("The page's written explanation: \(headline)")
            if let basis = s.explanationBasis { lines.append("(\(basis).)") }
            lines.append(contentsOf: s.explanationSentences)
        }
        lines.append("Shaded ranges on this page are the person's own usual or recent range, not a safety range.")
        let text = lines.joined(separator: "\n")
        return text.count > contextCap ? String(text.prefix(contextCap - 1)) + "…" : text
    }

    private static func lowercasedFirst(_ name: String) -> String {
        // Keep acronyms ("HRV", "RMSSD") as written; lower only an ordinary leading capital.
        guard let first = name.first, first.isUppercase else { return name }
        let second = name.dropFirst().first
        if let second, second.isUppercase { return name }
        return first.lowercased() + name.dropFirst()
    }
}
