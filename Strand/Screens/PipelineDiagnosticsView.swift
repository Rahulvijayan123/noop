import SwiftUI
import StrandDesign

// MARK: - G7 pipeline diagnostics (owner-scoped)

/// One honest row of the /scores/diagnostics contract. Every value is what the server
/// measured (or an explicit `not_measured` / `not_observed`); nothing is fabricated.
/// The client decodes with `convertFromSnakeCase`; the models below only carry the
/// fields the surface shows, unknown server fields are ignored.
struct PipelineDayBounds: Decodable, Hashable {
    struct Segment: Decodable, Hashable {
        let startTs: Int
        let endTs: Int
        let timezoneId: String?
    }
    let segments: [Segment]
    let zone: String?
    let zoneSource: String?
    let boundsHalfOpen: Bool?
    let zonePolicy: String?
}

struct PipelineSignalWindow: Decodable, Hashable {
    let windows: Int?
    let receivedRecords: Int?
    let expectedRecords: Int?
    let meanCoverage: Double?
    let lastValidTs: Int?
}

struct PipelineStreamCount: Decodable, Hashable {
    let received: Int?
}

struct PipelineLargestGap: Decodable, Hashable {
    let status: String?
    let stream: String?
    let seconds: Int?
    let reason: String?
}

struct PipelineStreams: Decodable, Hashable {
    let status: String?
    let signalWindows: [String: PipelineSignalWindow]
    let coverage: [String: [String: PipelineStreamCount]]
    let largestGap: PipelineLargestGap?
}

struct PipelineQueueV2: Decodable, Hashable {
    let status: String?
    let pending: Int?
    let deadLettered: Int?
    let invalidationSuppressed: Int?
    let eligible: Int?
    let inputRevision: Int?
    let completedRevision: Int?
    let oldestDirtyAgeSeconds: Int?
    let oldestEligibleAgeSeconds: Int?
    let nextAttemptAt: String?
}

struct PipelineQueue: Decodable, Hashable {
    let scoringV2: PipelineQueueV2?
}

struct PipelineProjection: Decodable, Hashable {
    let status: String?
    let publishedRevision: Int?
    let requiredRevision: Int?
    let behind: Bool?
}

struct PipelineArchive: Decodable, Hashable {
    let durablePublished: Int?
    let verified: Int?
    let oldestVerifiedAgeSeconds: Int?
    let statuses: [String: Int]
}

enum PipelineDetail: Decodable, Hashable {
    case string(String)
    case number(Int)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s) }
        else if let n = try? c.decode(Int.self) { self = .number(n) }
        else { self = .string("") }
    }

    var text: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return "\(n)"
        }
    }
}

struct PipelineBlocker: Decodable, Hashable {
    let code: String?
    let detail: PipelineDetail?
}

struct PipelineStage: Decodable, Hashable {
    let status: String?
    let reason: String?
    let receipts: Int?
}

/// The full /scores/diagnostics response (schema_version 2). `fetchedAt` is client-side.
struct PipelineDiagnostics: Decodable, Hashable {
    let schemaVersion: Int?
    let day: String?
    let scope: String?
    let countsTruncated: Bool?
    let dayBounds: PipelineDayBounds?
    let streams: PipelineStreams?
    let stages: [String: PipelineStage]
    let queue: PipelineQueue?
    let projection: PipelineProjection?
    let archive: PipelineArchive?
    let blockers: [PipelineBlocker]
    var fetchedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, day, scope, countsTruncated, dayBounds, streams,
             stages, queue, projection, archive, blockers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
        day = try c.decodeIfPresent(String.self, forKey: .day)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        countsTruncated = try c.decodeIfPresent(Bool.self, forKey: .countsTruncated)
        dayBounds = try c.decodeIfPresent(PipelineDayBounds.self, forKey: .dayBounds)
        streams = try c.decodeIfPresent(PipelineStreams.self, forKey: .streams)
        stages = try c.decodeIfPresent([String: PipelineStage].self, forKey: .stages) ?? [:]
        queue = try c.decodeIfPresent(PipelineQueue.self, forKey: .queue)
        projection = try c.decodeIfPresent(PipelineProjection.self, forKey: .projection)
        archive = try c.decodeIfPresent(PipelineArchive.self, forKey: .archive)
        blockers = try c.decodeIfPresent([PipelineBlocker].self, forKey: .blockers) ?? []
        fetchedAt = nil
    }
}

/// Fetches the owner-scoped diagnostics route with the SAME installation credential as
/// every other score read (`CloudReceiverAuth`, deviceId=my-whoop),
/// matching `ServerScoreRepository`'s single-source-of-truth endpoint derivation.
enum PipelineDiagnosticsClient {
    struct Unavailable: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    static func load(day: String) async throws -> PipelineDiagnostics {
        guard let identity = CloudPushIdentityStore.current() else {
            throw Unavailable(reason: "no enrolled Nara account")
        }
        guard let base = ServerScoreRepository.derivedEndpoint(),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw Unavailable(reason: "cloud endpoint not configured")
        }
        components.path += "/diagnostics"
        components.queryItems = [
            URLQueryItem(name: "day", value: day),
            URLQueryItem(name: "deviceId", value: "my-whoop"),
        ]
        guard let url = components.url else { throw Unavailable(reason: "cloud endpoint not configured") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        CloudReceiverAuth.apply(identity, to: &request)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Unavailable(reason: "no response") }
        guard http.statusCode == 200 else {
            throw Unavailable(reason: "HTTP \(http.statusCode)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var diagnostics = try decoder.decode(PipelineDiagnostics.self, from: data)
        diagnostics.fetchedAt = Date()
        return diagnostics
    }
}

// MARK: - Screen

/// Nara's owner-scoped diagnostic surface (spec G7), one tap down from the Monitor header menu for an
/// enrolled account: what the server actually measured for this installation today — day bounds and zone,
/// stream status and coverage, the largest gap, the v2 queue, the projection revision, durable acceptance
/// against verified archival, and explicit blockers. No fabricated numbers; a value the server did not
/// measure is "—".
struct PipelineDiagnosticsView: View {
    @State private var diagnostics: PipelineDiagnostics?
    @State private var failure: String?
    @State private var loading = false

    /// The real sections, empty, drawn redacted until the first response lands.
    private static let placeholder: PipelineDiagnostics? =
        try? JSONDecoder().decode(PipelineDiagnostics.self, from: Data("{}".utf8))

    var body: some View {
        ScreenScaffold(title: "Pipeline diagnostics", titleDisplay: .navigationBar,
                       onRefresh: { await load() }) {
            Text(verbatim: metaLine)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .monospacedDigit()
            if let failure, diagnostics == nil {
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text("Diagnostics unavailable")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(failure)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            } else if let shown = diagnostics ?? Self.placeholder {
                surface(shown)
                    .loadingRedaction(diagnostics == nil)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .tint(StrandPalette.accent)
                .disabled(loading)
                .accessibilityLabel("Refresh")
            }
        }
        .task { await load() }
    }

    private var metaLine: String {
        var parts = [localDayKey()]
        if let zone = diagnostics?.dayBounds?.zone { parts.append(zone) }
        if let fetched = diagnostics?.fetchedAt {
            parts.append("fetched \(fetched.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            diagnostics = try await PipelineDiagnosticsClient.load(day: localDayKey())
            failure = nil
        } catch {
            failure = (error as? PipelineDiagnosticsClient.Unavailable)?.reason
                ?? "Nara diagnostics unavailable"
        }
    }

    // MARK: Surface

    @ViewBuilder private func surface(_ d: PipelineDiagnostics) -> some View {
        section("Day bounds") {
            row("Zone", d.dayBounds?.zone ?? "not_measured")
            divider
            row("Policy", d.dayBounds?.zonePolicy ?? "local_calendar_midnight")
            if let first = d.dayBounds?.segments.first, let zoneId = first.timezoneId {
                divider
                row("Start", dayTime(first.startTs) + " " + zoneId)
            }
            if d.countsTruncated == true {
                divider
                row("Counts", "truncated")
            }
        }

        section("Streams") {
            row("Status", d.streams?.status ?? "not_measured")
            let windows = d.streams?.signalWindows ?? [:]
            if windows.isEmpty {
                divider
                row("Signal windows", "not_measured")
            } else {
                ForEach(windows.sorted(by: { $0.key < $1.key }), id: \.key) { stream, window in
                    divider
                    streamRow(stream, window)
                }
            }
            divider
            if let gap = d.streams?.largestGap, gap.status == "measured", let seconds = gap.seconds {
                row("Largest gap", "\(seconds) s" + (gap.stream.map { " (\($0))" } ?? ""))
            } else {
                row("Largest gap", "not_measured")
            }
        }

        section("Pipeline") {
            let q = d.queue?.scoringV2
            row("Queue", q?.status ?? "none")
            if let q {
                if let pending = q.pending, pending > 0 {
                    divider
                    row("Pending jobs", "\(pending)")
                }
                if let age = q.oldestEligibleAgeSeconds {
                    divider
                    row("Oldest eligible", durationText(age))
                }
                divider
                row("Revisions", "\(q.inputRevision ?? 0) in → \(q.completedRevision ?? 0) done")
            }
            let p = d.projection
            divider
            row("Projection", p?.status ?? "not_observed")
            if let p, let published = p.publishedRevision {
                divider
                row("Revision", "published \(published)" + (p.requiredRevision.map { " · required \($0)" } ?? ""))
            }
            if let archive = d.archive {
                divider
                row("Durable accepted", "\(archive.durablePublished ?? 0)")
                divider
                row("Verified archived", "\(archive.verified ?? 0)")
                if let failed = archive.statuses["failed"], failed > 0 {
                    divider
                    row("Archive failed", "\(failed)")
                }
            }
        }

        section("Blockers") {
            if d.blockers.isEmpty {
                row("Blockers", "none")
            } else {
                ForEach(Array(d.blockers.enumerated()), id: \.offset) { index, blocker in
                    if index > 0 { divider }
                    row(blocker.code ?? "blocker", blocker.detail?.text ?? "")
                }
            }
        }

        if let stage = d.stages["accepted"] {
            section("Acceptance") {
                row("Accepted", stage.status ?? "not_measured")
                if let receipts = stage.receipts {
                    divider
                    row("Receipts", "\(receipts)")
                }
            }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        let rows = content()
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(title)
            NoopCard(padding: 0) {
                VStack(spacing: 0) { rows }
            }
        }
    }

    private var divider: some View { NoopListDivider() }

    /// Server tokens that mean "nothing measured" read as a dash; the token stays for VoiceOver.
    private static func isUnmeasured(_ value: String) -> Bool {
        value == "not_measured" || value == "not_observed" || value == "none"
    }

    private func row(_ title: String, _ value: String) -> some View {
        let unmeasured = Self.isUnmeasured(value)
        return HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Text(verbatim: title)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: NoopMetrics.space2)
            Text(verbatim: unmeasured ? "—" : value)
                .font(StrandFont.subhead.monospacedDigit())
                .foregroundStyle(unmeasured ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(Text(verbatim: value))
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// One stream: its name and coverage, a 0–100 % coverage bar, and its windows and records.
    private func streamRow(_ stream: String, _ window: PipelineSignalWindow) -> some View {
        let coverage = window.meanCoverage.map { min(1, max(0, $0)) }
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: stream)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: NoopMetrics.space2)
                Text(verbatim: coverageText(window.meanCoverage))
                    .font(StrandFont.subhead.monospacedDigit())
                    .foregroundStyle(coverage == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceInset)
                    Capsule().fill(StrandPalette.textSecondary)
                        .frame(width: geo.size.width * CGFloat(coverage ?? 0))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
            Text(verbatim: recordsText(window))
                .font(StrandFont.footnote.monospacedDigit())
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space3)
        .accessibilityElement(children: .combine)
    }

    private func recordsText(_ window: PipelineSignalWindow) -> String {
        var parts = ["\(window.windows ?? 0) windows"]
        if let received = window.receivedRecords {
            parts.append(window.expectedRecords.map { "\(received) of \($0) records" } ?? "\(received) records")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Formatting

    private func localDayKey() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func dayTime(_ seconds: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    private func durationText(_ seconds: Int) -> String {
        if seconds < 90 { return "\(seconds) s" }
        let minutes = seconds / 60
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private func coverageText(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return "\(Int((fraction * 100).rounded())) %"
    }
}
