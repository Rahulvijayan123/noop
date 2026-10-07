import Foundation

// MetricInsight.swift — the phone's read side of the metric explanations (`POST {scores}/insights`,
// supabase/migrations/20261008000000_metric_insights.sql).
//
//   POST {scores}/insights  {"metric": "resting_hr" | "hrv_rmssd"}
//     → {status: ready|pending|unavailable, metric, insight (or null), retry_after_s (pending), reason (unavailable)}
//
// Same credential as every other scores route (the installation bearer through `CloudReceiverAuth`); the owner
// comes from it, and no device id is sent. The explanation is optional: the detail screen draws the value and the
// chart from the phone's own data, so every failure here only hides the explanation. The body is read with
// JSONSerialization, member by member: unknown members are ignored and a missing or unreadable optional member is
// simply absent, so a newer server shape never costs the rest of the answer.

// MARK: - Metric

/// The metrics the server explains (`INSIGHT_METRICS` in `_shared/serverScores.ts`).
enum MetricInsightMetric: String, CaseIterable, Sendable {
    case restingHeartRate = "resting_hr"
    case hrvRmssd = "hrv_rmssd"
}

// MARK: - Response

/// One answer of `POST {scores}/insights`.
struct MetricInsightResponse: Equatable, Sendable {

    enum Status: Equatable, Sendable {
        /// The explanation matches the metric's latest inputs.
        case ready
        /// An analysis is queued or running; `insight` is the previous one, marked stale, when there is one.
        case pending
        /// Nothing new is on its way (see `reason`); `insight` is the previous one, marked stale, when there is one.
        case unavailable
        /// A status this build does not know. Treated like `unavailable`.
        case unknown(String)

        init(raw: String) {
            switch raw {
            case "ready": self = .ready
            case "pending": self = .pending
            case "unavailable": self = .unavailable
            default: self = .unknown(raw)
            }
        }
    }

    enum Reason: Equatable, Sendable {
        /// The metric has never been measured, so there is nothing to explain.
        case noMeasuredData
        /// The analysis of these inputs failed repeatedly and is parked until the inputs change.
        case analysisFailed
        /// The day's analysis budget for this metric is used up.
        case dailyLimit
        case other(String)

        init(raw: String) {
            switch raw {
            case "no_measured_data": self = .noMeasuredData
            case "analysis_failed": self = .analysisFailed
            case "daily_limit": self = .dailyLimit
            default: self = .other(raw)
            }
        }
    }

    let status: Status
    let metric: String?
    let reason: Reason?
    /// Seconds the server suggests waiting before asking again (pending only).
    let retryAfterS: Int?
    /// The explanation as the server sent it, before the wording guard. Nil when absent, null or unreadable.
    let insight: MetricInsight?

    /// Decode a response body. Nil when it is not a JSON object with a string `status`, i.e. not this contract.
    static func decode(_ data: Data) -> MetricInsightResponse? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return decode(object)
    }

    static func decode(_ object: [String: Any]) -> MetricInsightResponse? {
        guard let status = MetricInsightJSON.string(object["status"]) else { return nil }
        return MetricInsightResponse(
            status: Status(raw: status),
            metric: MetricInsightJSON.string(object["metric"]),
            reason: MetricInsightJSON.string(object["reason"]).map(Reason.init(raw:)),
            retryAfterS: MetricInsightJSON.integer(object["retry_after_s"]),
            insight: (object["insight"] as? [String: Any]).flatMap(MetricInsight.decode))
    }
}

// MARK: - Insight

/// One published explanation of a metric, as the app renders it.
struct MetricInsight: Equatable, Sendable {

    enum Kind: Equatable, Sendable {
        /// An explanation of the measured nights.
        case explained
        /// Too little measured data to say much ("Only 2 nights measured so far"); still a valid explanation.
        case insufficientData
        case other(String)

        init(raw: String?) {
            switch raw {
            case nil, "explained": self = .explained
            case "insufficient_data": self = .insufficientData
            case let raw?: self = .other(raw)
            }
        }
    }

    /// Which way a related signal moved. Display only: none of these is good or bad.
    enum Direction: String, Equatable, Sendable {
        case up, down, flat, unknown
    }

    /// Another signal the analysis read alongside the metric.
    struct Related: Equatable, Sendable {
        let metric: String?
        let label: String
        let summary: String
        let direction: Direction
        /// True when the value is an estimate rather than a measurement. Never shown as measured.
        let estimated: Bool
    }

    /// What the analysis covered.
    struct Basis: Equatable, Sendable {
        let nights: Int?
        let from: String?
        let to: String?
        let missingNights: Int?
        let comparisonStatus: String?
    }

    struct Citation: Equatable, Sendable {
        let id: String?
        let title: String
        let year: Int?
        /// An https link only; anything else is dropped so a citation can never open another scheme.
        let url: URL?
    }

    /// The text lists hold at most this many sentences each (the server's publish bound).
    static let maxSentences = 6
    /// Related signals and citations hold at most this many entries each (the server's publish bound).
    static let maxEntries = 8

    let id: Int64?
    let metric: String?
    let kind: Kind
    /// `generated_at` as the server sent it (Postgres `timestamptz` text).
    let generatedAtText: String?
    /// `generated_at` as an instant; nil when it could not be read.
    let generatedAt: Date?
    let analysisVersion: String?
    /// The latest measured night (`yyyy-MM-dd`) the analysis covered.
    let dataThrough: String?
    /// True when this is an earlier analysis served while a newer one is computed (or cannot be).
    let stale: Bool
    let headline: String
    let observed: [String]
    let interpretation: [String]
    let uncertainty: [String]
    let related: [Related]
    let basis: Basis?
    let citations: [Citation]

    /// Read one `insight` object. Nil when it has no headline: an explanation without one cannot be shown.
    static func decode(_ o: [String: Any]) -> MetricInsight? {
        guard let headline = MetricInsightJSON.text(o["headline"]) else { return nil }
        let generatedAtText = MetricInsightJSON.string(o["generated_at"])
        let related: [Related] = MetricInsightJSON.objects(o["related"]).compactMap { r in
            guard let label = MetricInsightJSON.text(r["label"]),
                  let summary = MetricInsightJSON.text(r["summary"]) else { return nil }
            return Related(metric: MetricInsightJSON.string(r["metric"]), label: label, summary: summary,
                           direction: MetricInsightJSON.string(r["direction"]).flatMap(Direction.init(rawValue:))
                               ?? .unknown,
                           estimated: (r["estimated"] as? Bool) ?? false)
        }
        let citations: [Citation] = MetricInsightJSON.objects(o["citations"]).compactMap { c in
            guard let title = MetricInsightJSON.text(c["title"]) else { return nil }
            return Citation(id: MetricInsightJSON.string(c["id"]), title: title,
                            year: MetricInsightJSON.integer(c["year"]),
                            url: MetricInsightJSON.string(c["url"]).flatMap(MetricInsightJSON.httpsURL))
        }
        let basis = (o["basis"] as? [String: Any]).map { b in
            Basis(nights: MetricInsightJSON.integer(b["nights"]), from: MetricInsightJSON.string(b["from"]),
                  to: MetricInsightJSON.string(b["to"]), missingNights: MetricInsightJSON.integer(b["missing_nights"]),
                  comparisonStatus: MetricInsightJSON.string(b["comparison_status"]))
        }
        return MetricInsight(
            id: MetricInsightJSON.number(o["id"]).flatMap { $0 == $0.rounded() && abs($0) < 9.0e15 ? Int64($0) : nil },
            metric: MetricInsightJSON.string(o["metric"]),
            kind: Kind(raw: MetricInsightJSON.string(o["kind"])),
            generatedAtText: generatedAtText,
            generatedAt: generatedAtText.flatMap(MetricInsightTimestamp.parse),
            analysisVersion: MetricInsightJSON.string(o["analysis_version"]),
            dataThrough: MetricInsightJSON.string(o["data_through"]),
            stale: (o["stale"] as? Bool) ?? false,
            headline: headline,
            observed: MetricInsightJSON.sentences(o["observed"]),
            interpretation: MetricInsightJSON.sentences(o["interpretation"]),
            uncertainty: MetricInsightJSON.sentences(o["uncertainty"]),
            related: Array(related.prefix(maxEntries)),
            basis: basis,
            citations: Array(citations.prefix(maxEntries)))
    }

    // MARK: Wording guard

    /// Every string the explanation card would put on screen, for the wording guard.
    var displayedText: [String] {
        [headline] + observed + interpretation + uncertainty
            + related.flatMap { [$0.label, $0.summary] } + citations.map(\.title)
    }

    /// Why the explanation may not be shown (`MetricInsightWordingGuard`), nil when every string it displays reads
    /// clean. The server writes within the same rules; this is the phone's last guard, and an explanation that trips
    /// it is not shown at all.
    var wordingViolation: MetricInsightWordingGuard.Violation? {
        for text in displayedText {
            if let violation = MetricInsightWordingGuard.violation(in: text) { return violation }
        }
        return nil
    }
}

// MARK: - Wording guard

/// The explanation card's wording guard: stricter than `PhysiologyContextWording.containsForbiddenTerm` (which the
/// context screens keep using unchanged) because this text is model-written.
///
/// A string is first normalised with NFKC and lowercased, so compatibility forms (fullwidth letters, a no-break
/// space) and capitals cannot hide a term. Then it is rejected outright when it holds an invisible format character
/// (general category Cf: zero-width space, joiners, soft hyphen, bidi marks) or a word that mixes Latin letters with
/// Cyrillic or Greek ones ("strеss" with a Cyrillic е). Finally the app's forbidden terms are matched as whole words
/// with their simple inflections: the term followed by s, es, ed, ing, ness or nesses ("illnesses", "stresses",
/// "side effects"), plus the irregular forms in `extraForms`. The base list is
/// `PhysiologyContextWording.forbiddenTerms` itself, read here and never copied, so it stays identical to the
/// server's list.
enum MetricInsightWordingGuard {

    enum Violation: Equatable, Sendable {
        /// A forbidden term (the base term, or the irregular form) appeared, possibly inflected.
        case forbiddenTerm(String)
        /// An invisible format character (its scalar value).
        case invisibleCharacter(UInt32)
        /// A word mixing Latin letters with Cyrillic or Greek ones (as normalised).
        case mixedScriptWord(String)
    }

    /// Forms of the base terms the suffix rule cannot reach.
    static let extraForms = ["diagnose", "diagnoses", "diagnosing", "infections"]

    /// The suffixes a term may carry and still be the term.
    static let inflections = ["s", "es", "ed", "ing", "ness", "nesses"]

    /// The text as it is matched: NFKC, then lowercase.
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
    }

    /// The first reason `text` may not be shown, nil when it reads clean.
    static func violation(in text: String) -> Violation? {
        if let scalar = firstFormCharacter(text) { return .invisibleCharacter(scalar.value) }
        let normal = normalized(text)
        if let scalar = firstFormCharacter(normal) { return .invisibleCharacter(scalar.value) }
        if let word = firstMixedScriptWord(normal) { return .mixedScriptWord(word) }
        let range = NSRange(normal.startIndex..., in: normal)
        for (term, pattern) in patterns where pattern.firstMatch(in: normal, range: range) != nil {
            return .forbiddenTerm(term)
        }
        return nil
    }

    /// One whole-word pattern per term: the words of a multi-word term may be split by any whitespace or a hyphen.
    private static let patterns: [(term: String, regex: NSRegularExpression)] = {
        let suffixes = "(?:" + inflections.joined(separator: "|") + ")?"
        return (PhysiologyContextWording.forbiddenTerms + extraForms).compactMap { term in
            let words = term.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = #"\b"# + words.joined(separator: #"[\s\-\x{2010}]+"#) + suffixes + #"\b"#
            return (try? NSRegularExpression(pattern: pattern)).map { (term, $0) }
        }
    }()

    private static func firstFormCharacter(_ text: String) -> Unicode.Scalar? {
        text.unicodeScalars.first { $0.properties.generalCategory == .format }
    }

    private enum Script { case latin, cyrillic, greek, other }

    /// The script of a letter, by Unicode block; nil for anything that is not a letter.
    private static func script(_ scalar: Unicode.Scalar) -> Script? {
        guard scalar.properties.isAlphabetic else { return nil }
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x2AF, 0x1E00...0x1EFF, 0x2C60...0x2C7F,
             0xA720...0xA7FF, 0xAB30...0xAB6F, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return .latin
        case 0x400...0x52F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
            return .cyrillic
        case 0x370...0x3FF, 0x1F00...0x1FFF:
            return .greek
        default:
            return .other
        }
    }

    /// The first word (a run of letters, marks and digits) holding Latin letters together with Cyrillic or Greek ones.
    private static func firstMixedScriptWord(_ text: String) -> String? {
        var word = String.UnicodeScalarView()
        var scripts = Set<Script>()
        func mixed() -> Bool { scripts.contains(.latin) && (scripts.contains(.cyrillic) || scripts.contains(.greek)) }
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory
            let inWord = scalar.properties.isAlphabetic || scalar.properties.numericType != nil
                || category == .nonspacingMark || category == .spacingMark || category == .enclosingMark
            if inWord {
                word.append(scalar)
                if let script = script(scalar) { scripts.insert(script) }
            } else {
                if mixed() { return String(word) }
                word = String.UnicodeScalarView()
                scripts = []
            }
        }
        return mixed() ? String(word) : nil
    }
}

// MARK: - Timestamps

/// `generated_at` is Postgres `timestamptz` JSON text: `2026-10-07T02:43:31.835123+00:00`, i.e. microseconds and a
/// colon offset, which `ISO8601DateFormatter` does not read reliably. This reads that and the nearby ISO 8601 forms:
/// any number of fractional digits or none, `Z` or a `±HH`, `±HHMM` or `±HH:MM` offset (none is read as UTC), and a
/// space instead of `T`.
enum MetricInsightTimestamp {
    private static let pattern = try? NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:[.,](\d+))?\s*(Z|z|[+-]\d{2}(?::?\d{2})?)?$"#)

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = pattern?.firstMatch(in: trimmed, range: range) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(match.range(at: i), in: trimmed) else { return nil }
            return String(trimmed[r])
        }
        guard let year = group(1).flatMap(Int.init), let month = group(2).flatMap(Int.init),
              let day = group(3).flatMap(Int.init), let hour = group(4).flatMap(Int.init),
              let minute = group(5).flatMap(Int.init), let second = group(6).flatMap(Int.init),
              (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour),
              (0...59).contains(minute), (0...60).contains(second) else { return nil }
        let components = DateComponents(calendar: utc, timeZone: utc.timeZone, year: year, month: month, day: day,
                                        hour: hour, minute: minute, second: second)
        guard components.isValidDate(in: utc), let base = utc.date(from: components) else { return nil }
        let fraction = group(7).flatMap { Double("0." + $0) } ?? 0
        return base.addingTimeInterval(fraction - Double(offsetSeconds(group(8)) ?? 0))
    }

    /// Seconds east of UTC for `Z`, `±HH`, `±HHMM` or `±HH:MM`; 0 when absent.
    private static func offsetSeconds(_ text: String?) -> Int? {
        guard let text, text != "Z", text != "z" else { return 0 }
        let sign = text.hasPrefix("-") ? -1 : 1
        let digits = text.dropFirst().replacingOccurrences(of: ":", with: "")
        guard let hours = Int(digits.prefix(2)) else { return nil }
        let minutes = digits.count > 2 ? Int(digits.dropFirst(2)) ?? 0 : 0
        return sign * (hours * 3600 + minutes * 60)
    }
}

// MARK: - Lenient member reads

enum MetricInsightJSON {
    static func string(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    /// A string worth showing: trimmed, non-empty.
    static func text(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return s
    }

    /// A finite JSON number (a JSON bool also bridges to NSNumber and is rejected).
    static func number(_ value: Any?) -> Double? { PhysiologyContextRepository.number(value) }

    /// A whole number, from a JSON number or a numeric string.
    static func integer(_ value: Any?) -> Int? {
        if let d = number(value), d == d.rounded(), abs(d) < 1e9 { return Int(d) }
        if let s = value as? String, let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
        return nil
    }

    static func objects(_ value: Any?) -> [[String: Any]] {
        ((value as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
    }

    /// A list of short sentences: strings only, trimmed, empty ones dropped, at most `MetricInsight.maxSentences`.
    static func sentences(_ value: Any?) -> [String] {
        Array(((value as? [Any]) ?? []).compactMap(text).prefix(MetricInsight.maxSentences))
    }

    static func httpsURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

// MARK: - Transport

/// What one request came back with. Every case but `response` hides the explanation.
enum MetricInsightFetchResult: Equatable, Sendable {
    case response(MetricInsightResponse)
    /// The server has no insights route yet (405), or its database lacks the RPC (404). Not an error.
    case unsupportedServer
    case failed(MetricInsightClient.Failure)
    /// The request was cancelled because the screen went away. Nothing changes.
    case cancelled
}

/// `POST {scores}/insights` for one metric, with the account's own installation credential.
struct MetricInsightClient: Sendable {

    enum Failure: Equatable, Sendable {
        case notConfigured
        case missingIdentity
        case http(Int)
        case transport
        case malformed
    }

    static let timeout: TimeInterval = 20

    private let session: URLSession
    private let endpoint: URL?
    private let identity: @Sendable () -> CloudPushIdentity?

    /// `identity` supplies the credential to read with. The app passes one bound to the running account's scope
    /// (`CloudPushRuntime.credentialProvider`), so a client made for account A never reads with B's.
    init(session: URLSession = .shared,
         endpoint: URL? = PhysiologyContextRepository.derivedEndpoint(),
         identity: @escaping @Sendable () -> CloudPushIdentity?) {
        self.session = session
        self.endpoint = endpoint
        self.identity = identity
    }

    func request(_ metric: MetricInsightMetric) async -> MetricInsightFetchResult {
        guard let endpoint else { return .failed(.notConfigured) }
        guard let identity = identity() else { return .failed(.missingIdentity) }
        var request = URLRequest(url: endpoint.appendingPathComponent("insights"), timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        CloudReceiverAuth.apply(identity, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let body = try? JSONSerialization.data(withJSONObject: ["metric": metric.rawValue]) else {
            return .failed(.malformed)
        }
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
            return .failed(.transport)
        }
        guard let http = response as? HTTPURLResponse else { return .failed(.malformed) }
        switch http.statusCode {
        case 200:
            guard let decoded = MetricInsightResponse.decode(data) else { return .failed(.malformed) }
            return .response(decoded)
        case 404, 405:
            return .unsupportedServer
        default:
            return .failed(.http(http.statusCode))
        }
    }
}
