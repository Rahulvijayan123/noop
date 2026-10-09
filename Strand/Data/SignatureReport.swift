import Foundation

/// The signature engine's report for one event type (`signature-report-1`, docs/PHENOTYPE_SIGNATURES.md),
/// as `GET /scores/event-detection/signature?typeId=` returns it. Decoding is tolerant: every field is
/// optional, a field of an unexpected type is dropped rather than failing the report, and unknown fields are
/// ignored, so a newer engine never blanks the card.
struct SignatureReport: Decodable, Equatable, Sendable {
    static let currentVersion = "signature-report-1"

    enum Status: String, Sendable {
        case insufficientEvents = "insufficient_events", individualContext = "individual_context"
        case noReliableSignature = "no_reliable_signature", emerging, established
    }

    var version: String?
    var typeId: String?
    var generatedAt: Double?
    var engine: Engine?
    var statusRaw: String?
    var evidence: Evidence?
    var signatures: [Signature] = []
    var detectability: Detectability?
    var retrospective: Retrospective?
    var dataQuality: DataQuality?
    var limitations: [String] = []
    var alertsEnabled: Bool?

    var status: Status? { statusRaw.flatMap(Status.init(rawValue:)) }
    var generated: Date? { generatedAt.map(Date.init(timeIntervalSince1970:)) }

    struct Engine: Decodable, Equatable, Sendable {
        var version: String?
        var normalization: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: SignatureJSONKey.self)
            version = c.lenient("version"); normalization = c.lenient("normalization")
        }
    }

    struct Evidence: Decodable, Equatable, Sendable {
        var events: Int?
        var eventDays: Int?
        var observationHours: Double?
        var confirmedDetections: Int?
        var rejectedDetections: Int?
        var negativeIntervals: Int?
        var monitoredDays: Double?
        /// Events that entered the signature (sig-2 and later).
        var eventsUsed: Int?
        /// Events left out, counted by the engine's plain-language reason ("fewer than 3 matched controls").
        var eventsDropped: [String: Int] = [:]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: SignatureJSONKey.self)
            eventsUsed = c.int("events_used"); eventsDropped = c.lenient("events_dropped") ?? [:]
            events = c.int("events"); eventDays = c.int("event_days"); observationHours = c.lenient("observation_hours")
            confirmedDetections = c.int("confirmed_detections"); rejectedDetections = c.int("rejected_detections")
            negativeIntervals = c.int("negative_intervals"); monitoredDays = c.lenient("monitored_days")
        }
    }

    struct Finding: Decodable, Equatable, Sendable {
        var channel: String?
        var unit: String?
        /// Minutes relative to the onset, [from, to).
        var window: [Double] = []
        var direction: String?
        var change: Double?
        var changeCI: [Double] = []
        var changeZ: Double?
        var consistency: Double?
        var eventsWithData: Int?
        var text: String?
        /// What the change is measured against: `change_from_before` (the minutes before onset) or
        /// `vs_usual_for_context` (what is usual for the activity and time of day). Absent before sig-2.
        var basis: String?
        /// The person also moved more around these events, which can explain a heart-rate rise or HRV fall
        /// (sig-3 and later; heart-rate and HRV findings only).
        var movementAccompanied: Bool?
        /// For a `joint` finding (sig-4): the readings that moved together, each with its weight and its own
        /// change in SD of the person's usual variation; `change` is then the combined score in SD.
        var channels: [JointChannel] = []
        var combinedZ: Double?
        var combinedZCI: [Double] = []
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: SignatureJSONKey.self)
            basis = c.lenient("basis"); movementAccompanied = c.lenient("movement_accompanied")
            channels = c.list("channels"); combinedZ = c.lenient("combined_z"); combinedZCI = c.numbers("combined_z_ci")
            channel = c.lenient("channel"); unit = c.lenient("unit"); window = c.numbers("window")
            direction = c.lenient("direction"); change = c.lenient("change"); changeCI = c.numbers("change_ci")
            changeZ = c.lenient("change_z"); consistency = c.lenient("consistency")
            eventsWithData = c.int("events_with_data"); text = c.lenient("text")
        }
        /// Events whose change had the finding's direction ("7 of 8 events").
        var consistentEvents: Int? {
            guard let consistency, let eventsWithData, consistency.isFinite else { return nil }
            return min(eventsWithData, max(0, Int((consistency * Double(eventsWithData)).rounded())))
        }
    }

    struct JointChannel: Decodable, Equatable, Sendable {
        var channel: String?
        var weight: Double?
        var changeZ: Double?
        var change: Double?
        var unit: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: SignatureJSONKey.self)
            channel = c.lenient("channel"); weight = c.lenient("weight"); changeZ = c.lenient("change_z")
            change = c.lenient("change"); unit = c.lenient("unit")
        }
    }

    struct ProfileChannel: Decodable, Equatable, Sendable {
        var unit: String?
        /// One value per minute across the profile's lags; nil where the events had no data.
        var mean: [Double?] = []
        var ciLo: [Double?] = []
        var ciHi: [Double?] = []
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: SignatureJSONKey.self)
            unit = c.lenient("unit"); mean = c.optionalNumbers("mean")
            ciLo = c.optionalNumbers("ci_lo"); ciHi = c.optionalNumbers("ci_hi")
        }
    }

    struct Profile: Decodable, Equatable, Sendable {
        /// The first and last lag in minutes, e.g. [-30, 30].
        var lags: [Double] = []
        var channels: [String: ProfileChannel] = [:]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: SignatureJSONKey.self)
            lags = c.numbers("lags")
            if let nested = try? c.nestedContainer(keyedBy: SignatureJSONKey.self, forKey: SignatureJSONKey("channels")) {
                for key in nested.allKeys {
                    if let channel = try? nested.decode(ProfileChannel.self, forKey: key) { channels[key.stringValue] = channel }
                }
            }
        }
    }

    struct Signature: Decodable, Equatable, Sendable {
        var id: String?
        var label: String?
        var events: Int?
        var eventDays: Int?
        var eventIds: [String] = []
        var pValue: Double?
        var pMinPossible: Double?
        var replicated: Bool?
        var contextAtOnset: [String: Double] = [:]
        var findings: [Finding] = []
        var profile: Profile?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: SignatureJSONKey.self)
            id = c.lenient("id"); label = c.lenient("label"); events = c.int("events"); eventDays = c.int("event_days")
            eventIds = c.lenient("event_ids") ?? []; pValue = c.lenient("p_value"); pMinPossible = c.lenient("p_min_possible")
            replicated = c.lenient("replicated"); contextAtOnset = c.lenient("context_at_onset") ?? [:]
            findings = c.list("findings"); profile = c.lenient("profile")
        }
    }

    struct Detectability: Decodable, Equatable, Sendable {
        var d: Double?
        var dCI: [Double] = []
        /// Expected share of events caught at a false-alert budget per day, keyed by the budget ("0.5", "1", "2").
        var expectedRecall: [String: Double] = [:]
        /// 95% interval of each expected recall, same keys; an entry may be missing or partly null.
        var expectedRecallCI: [String: [Double]] = [:]
        var assessment: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: SignatureJSONKey.self)
            d = c.lenient("d"); dCI = c.numbers("d_ci"); expectedRecall = c.lenient("expected_recall") ?? [:]
            if let nested = try? c.nestedContainer(keyedBy: SignatureJSONKey.self, forKey: SignatureJSONKey("expected_recall_ci")) {
                for key in nested.allKeys {
                    let bounds = nested.numbers(key.stringValue)
                    if bounds.count == 2 { expectedRecallCI[key.stringValue] = bounds }
                }
            }
            assessment = c.lenient("assessment")
        }
        /// Expected recall at one false alert a day, whichever way the budget key was written.
        var recallAtOnePerDay: Double? {
            expectedRecall["1"] ?? expectedRecall["1.0"] ?? expectedRecall.first { Double($0.key) == 1 }?.value
        }
        var recallCIAtOnePerDay: [Double]? {
            expectedRecallCI["1"] ?? expectedRecallCI["1.0"] ?? expectedRecallCI.first { Double($0.key) == 1 }?.value
        }
        var isPromising: Bool { assessment == "promising" }
    }

    struct Retrospective: Decodable, Equatable, Sendable {
        var evaluated: Bool?
        var method: String?
        var events: Int?
        var recall: Double?
        var recallCI: [Double] = []
        var falseAlertsPerDay: Double?
        var falseAlertsCI: [Double] = []
        var latencyMedianMin: Double?
        var monitoredDays: Double?
        var promoted: Bool?
        var reason: String?
        /// End of the data the run's model was fitted on (seconds); later events are its future-held-out test.
        var trainingCutoff: Double?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: SignatureJSONKey.self)
            trainingCutoff = c.lenient("training_cutoff")
            evaluated = c.lenient("evaluated"); method = c.lenient("method"); events = c.int("events")
            recall = c.lenient("recall"); recallCI = c.numbers("recall_ci"); falseAlertsPerDay = c.lenient("false_alerts_per_day")
            falseAlertsCI = c.numbers("false_alerts_ci"); latencyMedianMin = c.lenient("latency_median_min")
            monitoredDays = c.lenient("monitored_days"); promoted = c.lenient("promoted"); reason = c.lenient("reason")
        }
    }

    struct DataQuality: Decodable, Equatable, Sendable {
        var monitoredFraction: Double?
        var channels: [String: Double] = [:]
        var notes: [String] = []
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: SignatureJSONKey.self)
            monitoredFraction = c.lenient("monitored_fraction"); channels = c.lenient("channels") ?? [:]
            notes = c.lenient("notes") ?? []
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: SignatureJSONKey.self)
        version = c.lenient("version"); typeId = c.lenient("type_id"); generatedAt = c.lenient("generated_at")
        engine = c.lenient("engine"); statusRaw = c.lenient("status"); evidence = c.lenient("evidence")
        signatures = c.list("signatures"); detectability = c.lenient("detectability")
        retrospective = c.lenient("retrospective"); dataQuality = c.lenient("data_quality")
        limitations = c.lenient("limitations") ?? []; alertsEnabled = c.lenient("alerts_enabled")
    }

    /// A report of this contract, or nil for anything else (another version, not an object, unreadable).
    static func decode(_ data: Data) -> SignatureReport? {
        guard let report = try? JSONDecoder().decode(Self.self, from: data), report.version == currentVersion else { return nil }
        return report
    }

    /// The main signature: the first one the engine reports.
    var primary: Signature? { signatures.first }
}

/// Any JSON key of a signature report.
struct SignatureJSONKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private struct LenientElement<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

private struct LenientNumber: Decodable {
    let value: Double?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        value = (try? c.decode(Double.self)).flatMap { $0.isFinite ? $0 : nil }
    }
}

extension KeyedDecodingContainer where K == SignatureJSONKey {
    /// The value, or nil when it is absent, null or of another type.
    func lenient<T: Decodable>(_ key: String) -> T? { (try? decodeIfPresent(T.self, forKey: SignatureJSONKey(key))) ?? nil }
    /// An integer written as 8 or 8.0.
    func int(_ key: String) -> Int? {
        if let value: Int = lenient(key) { return value }
        guard let value: Double = lenient(key), value.isFinite, value.rounded() == value, abs(value) < 1e15 else { return nil }
        return Int(value)
    }
    /// Finite numbers; anything else in the list is dropped.
    func numbers(_ key: String) -> [Double] {
        ((try? decodeIfPresent([LenientNumber].self, forKey: SignatureJSONKey(key))) ?? nil)?.compactMap(\.value) ?? []
    }
    /// Numbers with their positions kept: null, NaN or a non-number becomes nil.
    func optionalNumbers(_ key: String) -> [Double?] {
        ((try? decodeIfPresent([LenientNumber].self, forKey: SignatureJSONKey(key))) ?? nil)?.map(\.value) ?? []
    }
    /// The readable elements of a list.
    func list<T: Decodable>(_ key: String) -> [T] {
        ((try? decodeIfPresent([LenientElement<T>].self, forKey: SignatureJSONKey(key))) ?? nil)?.compactMap(\.value) ?? []
    }
}

/// Plain-language wording for a signature report. It describes patterns in the person's own readings around
/// the events they logged, never a diagnosis, and always says alerts are off in this phase.
enum SignaturePresentation {
    static let minimumEvents = 3
    static let minimumDays = 3
    static let testableDays = 6
    static let learningDetail = "Showing each event's context; a signature needs at least 3 events on 3 different days."
    static let alertsOff = "Alerts are off. Nara is learning this event's signature and does not send alerts for it in this phase."

    struct StatusLine: Equatable {
        var title: String
        var detail: String
        var symbol: String
    }

    /// The event-aligned average is shown only for a testable pattern (emerging or established).
    static func showsProfile(_ report: SignatureReport?) -> Bool {
        guard let status = report?.status else { return false }
        return status == .emerging || status == .established
    }

    /// The status line for a type: from its report, or from the events logged so far when there is none yet.
    static func status(_ report: SignatureReport?, loggedEvents: Int) -> StatusLine {
        guard let report, let status = report.status else {
            if loggedEvents < minimumEvents {
                return StatusLine(title: "Learning", detail: learningDetail, symbol: "hourglass")
            }
            return StatusLine(title: "Learning",
                detail: "\(loggedEvents) events logged. The first analysis appears after the next cloud update.",
                symbol: "hourglass")
        }
        let events = report.evidence?.events ?? report.primary?.events ?? loggedEvents
        let days = report.evidence?.eventDays ?? report.primary?.eventDays
        switch status {
        case .insufficientEvents:
            return StatusLine(title: "Learning", detail: learningDetail, symbol: "hourglass")
        case .individualContext:
            let need = (days ?? 0) >= minimumDays
                ? "a reliable signature needs events on at least \(testableDays) different days."
                : "a signature needs events on at least \(minimumDays) different days."
            return StatusLine(title: "Individual context",
                detail: "\(count(events, "event")) on \(count(days ?? 0, "day")) so far. Each event's context is shown; \(need)",
                symbol: "list.bullet.rectangle")
        case .emerging:
            return StatusLine(title: "Emerging signature",
                detail: "A pattern is appearing\(evidenceClause(report)), but it is not yet confirmed on later events and may change as more events are logged.",
                symbol: "chart.line.uptrend.xyaxis")
        case .established:
            return StatusLine(title: "Established signature",
                detail: "The pattern held on events logged later\(evidenceClause(report)).",
                symbol: "checkmark.seal")
        case .noReliableSignature:
            return StatusLine(title: "No reliable signature yet", detail: noSignatureReason(report), symbol: "questionmark.circle")
        }
    }

    enum NoSignatureReason: Equatable { case tooFewDays, notConsistent, notReplicated }

    static func noSignatureReasonKind(_ report: SignatureReport) -> NoSignatureReason {
        let signature = report.primary
        let days = report.evidence?.eventDays ?? signature?.eventDays ?? 0
        if let p = signature?.pValue, p < 0.05, signature?.replicated == false { return .notReplicated }
        if days < testableDays || (signature?.pMinPossible ?? 0) >= 0.05 { return .tooFewDays }
        return .notConsistent
    }

    static func noSignatureReason(_ report: SignatureReport) -> String {
        let days = report.evidence?.eventDays ?? report.primary?.eventDays ?? 0
        switch noSignatureReasonKind(report) {
        case .tooFewDays:
            return "Too few days: events on \(count(days, "different day")) so far. Testing a pattern reliably needs events on at least \(testableDays) different days."
        case .notConsistent:
            return "Not consistent: across \(count(days, "day")), these events did not change your readings in the same way each time."
        case .notReplicated:
            return "Not replicated: a pattern in the earlier events did not hold on the events logged later."
        }
    }

    /// " (p = 0.03 across 6 days)".
    private static func evidenceClause(_ report: SignatureReport) -> String {
        var parts: [String] = []
        if let p = report.primary?.pValue { parts.append("p = \(pValue(p))") }
        if let days = report.evidence?.eventDays ?? report.primary?.eventDays { parts.append("across \(count(days, "day"))") }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: " ")))"
    }

    static func pValue(_ p: Double) -> String { p < 0.001 ? "< 0.001" : String(format: p < 0.01 ? "%.3f" : "%.2f", p) }

    static func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }

    static func channelTitle(_ channel: String?) -> String {
        switch channel {
        case "hr": "Heart rate"
        case "hr_max": "Peak heart rate"
        case "hr_min": "Lowest heart rate"
        case "ln_rmssd", "hrv": "HRV"
        case "temp", "temp_detr": "Skin temperature"
        case "resp": "Breathing rate"
        case "motion", "motion_p90": "Movement"
        case "steps": "Steps"
        case let other?: other.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: "Reading"
        }
    }

    /// "0–5 min after onset", "15–5 min before onset".
    static func window(_ window: [Double]) -> String? {
        guard window.count == 2 else { return nil }
        let a = Int(window[0].rounded()), b = Int(window[1].rounded())
        if a >= 0 { return "\(a)–\(b) min after onset" }
        if b <= 0 { return "\(-a)–\(-b) min before onset" }
        return "\(-a) min before to \(b) min after onset"
    }

    private static func number(_ value: Double) -> String {
        abs(value) >= 10 || value.rounded() == value ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }

    /// "+18 bpm (12 to 24)": the change with its 95% interval.
    static func change(_ finding: SignatureReport.Finding) -> String? {
        guard let change = finding.change else { return nil }
        let unit = finding.unit.map { " \($0)" } ?? ""
        var text = "\(change > 0 ? "+" : change < 0 ? "−" : "")\(number(abs(change)))\(unit)"
        if finding.changeCI.count == 2 {
            text += " (\(signed(finding.changeCI[0])) to \(signed(finding.changeCI[1])))"
        }
        return text
    }

    private static func signed(_ value: Double) -> String { (value < 0 ? "−" : "") + number(abs(value)) }

    private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    /// What a finding is compared with, for its chip; nil for reports that do not say.
    static func basis(_ finding: SignatureReport.Finding) -> String? {
        switch finding.basis {
        case "change_from_before": "vs the minutes before"
        case "vs_usual_for_context": "vs usual for the activity"
        case "joint": "readings combined"
        default: nil
        }
    }

    /// "Heart rate +2.3 SD" per reading of a joint finding, largest weight first; empty for other findings.
    static func jointParts(_ finding: SignatureReport.Finding) -> [String] {
        finding.channels
            .filter { $0.changeZ != nil }
            .sorted { abs($0.weight ?? 0) > abs($1.weight ?? 0) }
            .map { part in
                let z = part.changeZ ?? 0
                return "\(channelTitle(part.channel)) \(z > 0 ? "+" : z < 0 ? "−" : "")\(String(format: "%.1f", abs(z))) SD"
            }
    }

    /// "with more movement" / "with less movement" when movement changed the way that would explain the finding
    /// (heart rate up or HRV down with more movement, the reverse with less).
    static func movement(_ finding: SignatureReport.Finding) -> String? {
        guard finding.movementAccompanied == true else { return nil }
        let up = finding.direction.map { $0 == "up" } ?? (finding.change.map { $0 > 0 } ?? true)
        let hrv = ["hrv", "ln_rmssd", "rmssd"].contains(finding.channel ?? "")
        return up != hrv ? "with more movement" : "with less movement"
    }

    /// "2 of 8 events were left out: fewer than 3 matched controls (2)." or nil when none were.
    static func droppedNote(_ report: SignatureReport) -> String? {
        guard let evidence = report.evidence else { return nil }
        let dropped = evidence.eventsDropped.filter { $0.value > 0 }
        let total = dropped.values.reduce(0, +)
        guard total > 0 else { return nil }
        let reasons = dropped.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
        let of = evidence.events.map { " of \($0)" } ?? ""
        return "\(total)\(of) \(total == 1 ? "event was" : "events were") left out: \(reasons)."
    }

    static func consistency(_ finding: SignatureReport.Finding) -> String? {
        guard let n = finding.consistentEvents, let total = finding.eventsWithData else { return nil }
        return "\(n) of \(total) events"
    }

    static func directionSymbol(_ finding: SignatureReport.Finding) -> String {
        switch finding.direction ?? (finding.change.map { $0 >= 0 ? "up" : "down" } ?? "") {
        case "up": "arrow.up.right"
        case "down": "arrow.down.right"
        default: "arrow.left.and.right"
        }
    }

    struct Detectability: Equatable {
        var title: String
        var detail: String
        var promising: Bool
    }

    static func detectability(_ report: SignatureReport) -> Detectability {
        let d = report.detectability
        let recall = d?.recallAtOnePerDay.map { value -> String in
            let range = d?.recallCIAtOnePerDay.map { " (\(percent($0[0]))–\(percent($0[1])))" } ?? ""
            return "About \(percent(value))\(range) of events would be caught at 1 false alert per day."
        }
        if d?.isPromising == true {
            return Detectability(title: "Promising", detail: [recall, "This is an estimate from past events, not a working alert."]
                .compactMap { $0 }.joined(separator: " "), promising: true)
        }
        let why = d?.assessment == "insufficient_data" ? "There is not enough data yet to estimate it." : nil
        return Detectability(title: "Not reliable enough for alerts yet",
                             detail: [why, recall].compactMap { $0 }.joined(separator: " "), promising: false)
    }

    /// The channel the profile chart shows: the top finding's, else heart rate, else the first one.
    static func profileChannel(_ signature: SignatureReport.Signature) -> (key: String, channel: SignatureReport.ProfileChannel)? {
        guard let profile = signature.profile, !profile.channels.isEmpty else { return nil }
        for key in signature.findings.compactMap(\.channel) + ["hr"] {
            if let channel = profile.channels[key], channel.mean.contains(where: { $0 != nil }) { return (key, channel) }
        }
        return profile.channels.sorted { $0.key < $1.key }
            .first { $0.value.mean.contains(where: { $0 != nil }) }.map { ($0.key, $0.value) }
    }

    struct ProfilePoint: Equatable, Identifiable {
        var minute: Double
        var mean: Double
        var low: Double?
        var high: Double?
        /// Consecutive points share a run; a missing minute starts a new one, so the line breaks there.
        var run: Int
        var id: Double { minute }
    }

    static func profilePoints(_ channel: SignatureReport.ProfileChannel, lags: [Double]) -> [ProfilePoint] {
        let n = channel.mean.count
        guard n > 1 else { return [] }
        let lo = lags.first ?? -30, hi = lags.count > 1 ? lags[1] : 30
        let step = (hi - lo) / Double(n - 1)
        var run = 0, previous = -1
        var points: [ProfilePoint] = []
        for i in 0..<n {
            guard let mean = channel.mean[i] else { continue }
            if previous >= 0 && i != previous + 1 { run += 1 }
            previous = i
            func at(_ list: [Double?]) -> Double? { i < list.count ? list[i] : nil }
            points.append(ProfilePoint(minute: lo + Double(i) * step, mean: mean, low: at(channel.ciLo), high: at(channel.ciHi), run: run))
        }
        return points
    }
}
