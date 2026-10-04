import SwiftUI
import StrandDesign

// MARK: - Model
//
// Everything the Monitor tab draws comes from a `MonitorSnapshot`. The sample below only fills the
// screen until the backend lands: build a snapshot from real data and pass it to `MonitorView(snapshot:)`.
// All strings that depend on units or locale (`valueText`, `usualText`) arrive pre-formatted, so the
// view never guesses at them. Models are `Codable` so a backend payload can decode straight into them.

enum MonitorTone: String, Codable, Hashable {
    case heart, hrv, respiratory, sleep, alert, notice

    var color: Color {
        switch self {
        case .heart, .alert: return StrandPalette.metricRose
        case .hrv, .notice: return StrandPalette.metricPurple
        case .respiratory: return Color(red: 0.42, green: 0.74, blue: 1.0)
        case .sleep: return Color(red: 0.78, green: 0.70, blue: 1.0)
        }
    }
}

struct MonitorBaseline: Identifiable, Hashable, Codable {
    /// Also the `MetricCatalog` key the card opens (`rhr`, `hrv`, `resp_rate`, `sleep_total_min`).
    let id: String
    var title: String
    var symbol: String
    var tone: MonitorTone
    var valueText: String
    var unit: String
    var usualLow: Double
    var usualHigh: Double
    var usualText: String
    /// Daily values over the baseline window, oldest first.
    var series: [Double]
}

struct WatchdogEpisode: Identifiable, Hashable, Codable {
    let id: String
    var start: Date
    var label: String
    var duration: TimeInterval
    var tone: MonitorTone
}

enum MonitoringStatus: String, Codable, Hashable {
    case good, fair, poor

    var label: String {
        switch self {
        case .good: return String(localized: "Good")
        case .fair: return String(localized: "Fair")
        case .poor: return String(localized: "Poor")
        }
    }

    var color: Color {
        switch self {
        case .good: return Color(red: 0.25, green: 0.86, blue: 0.5)
        case .fair: return StrandPalette.metricAmber
        case .poor: return StrandPalette.statusCritical
        }
    }
}

struct MonitoringQuality: Hashable, Codable {
    /// 0...1 share of the day the strap was monitoring.
    var coverage: Double
    /// 0...1 share of monitored time with valid wear.
    var validWear: Double
    var status: MonitoringStatus
}

struct MonitorSnapshot: Hashable, Codable {
    var baselines: [MonitorBaseline]
    var episodes: [WatchdogEpisode]
    var quality: MonitoringQuality
}

// MARK: - Sample data (replace with the backend snapshot)

extension MonitorSnapshot {
    static var sample: MonitorSnapshot {
        func series(_ base: Double, _ amp: Double, _ seed: Double) -> [Double] {
            var values: [Double] = []
            for day in 0..<28 {
                let d = Double(day)
                let slow: Double = amp * sin(d * 0.7 + seed)
                let fast: Double = amp * 0.5 * sin(d * 1.9 + seed * 2)
                values.append(base + slow + fast)
            }
            return values
        }
        func when(daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            let cal = Calendar.current
            let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: Date())) ?? Date()
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        return MonitorSnapshot(
            baselines: [
                MonitorBaseline(id: "rhr", title: "Resting heart rate", symbol: "heart.fill", tone: .heart,
                                valueText: "58", unit: "bpm", usualLow: 50, usualHigh: 66,
                                usualText: "Usual 50–66", series: series(58, 5, 0.3)),
                MonitorBaseline(id: "hrv", title: "HRV", symbol: "waveform.path.ecg", tone: .hrv,
                                valueText: "32", unit: "ms", usualLow: 20, usualHigh: 65,
                                usualText: "Usual 20–65", series: series(38, 9, 1.1)),
                MonitorBaseline(id: "resp_rate", title: "Respiratory rate", symbol: "lungs.fill", tone: .respiratory,
                                valueText: "14", unit: "br/min", usualLow: 12, usualHigh: 18,
                                usualText: "Usual 12–18", series: series(14.5, 1.4, 2.0)),
                MonitorBaseline(id: "sleep_total_min", title: "Sleep duration", symbol: "moon.fill", tone: .sleep,
                                valueText: "8h 19m", unit: "", usualLow: 7, usualHigh: 9,
                                usualText: "Usual 7–9 h", series: series(8, 0.8, 2.8)),
            ],
            episodes: [
                WatchdogEpisode(id: "ep-1", start: when(daysAgo: 2, 13, 32), label: "Elevated resting HR",
                                duration: 12 * 60, tone: .alert),
                WatchdogEpisode(id: "ep-2", start: when(daysAgo: 4, 10, 14), label: "Low HRV",
                                duration: 18 * 60, tone: .alert),
                WatchdogEpisode(id: "ep-3", start: when(daysAgo: 6, 15, 48), label: "Higher than usual HR",
                                duration: 25 * 60, tone: .notice),
                WatchdogEpisode(id: "ep-4", start: when(daysAgo: 8, 22, 6), label: "Elevated respiratory rate",
                                duration: 9 * 60, tone: .notice),
                WatchdogEpisode(id: "ep-5", start: when(daysAgo: 11, 9, 41), label: "Low HRV",
                                duration: 32 * 60, tone: .alert),
                WatchdogEpisode(id: "ep-6", start: when(daysAgo: 14, 17, 20), label: "Elevated resting HR",
                                duration: 15 * 60, tone: .alert),
                WatchdogEpisode(id: "ep-7", start: when(daysAgo: 19, 12, 3), label: "Higher than usual HR",
                                duration: 21 * 60, tone: .notice),
                WatchdogEpisode(id: "ep-8", start: when(daysAgo: 24, 3, 55), label: "Low HRV",
                                duration: 47 * 60, tone: .alert),
            ],
            quality: MonitoringQuality(coverage: 0.96, validWear: 0.98, status: .good))
    }
}

// MARK: - Shared building blocks (also used by EventsView)

/// Card surface that follows the user's card-opacity preference, like the Today cards.
struct NaraCardModifier: ViewModifier {
    @AppStorage(CardAppearancePrefs.opacityKey) private var opacityPercent = CardAppearancePrefs.defaultPercent
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        content.background(NoopPanelSurface(cornerRadius: radius,
                                            surfaceOpacity: max(0, min(1, Double(opacityPercent) / 100))))
    }
}

extension View {
    func naraCard(radius: CGFloat = 20) -> some View { modifier(NaraCardModifier(radius: radius)) }
}

/// Section title with an optional caption and a "See all" link.
struct NaraSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var seeAll: TabRoute? = nil
    var seeAllLabel: LocalizedStringKey = "See all"

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(StrandFont.rounded(19))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer(minLength: 8)
            if let seeAll {
                NavigationLink(value: seeAll) {
                    HStack(spacing: 3) {
                        Text(seeAllLabel).font(StrandFont.caption)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(StrandPalette.metricPurple)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Round gear in the screen header; the iOS shell presents Settings.
struct HeaderSettingsButton: View {
    @EnvironmentObject private var router: NavRouter

    var body: some View {
        Button { router.openSettings() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(StrandPalette.surfaceInset))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }
}

/// Smooth curve through `points` (quadratic segments between midpoints).
func naraSmoothPath(_ points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first, let last = points.last, points.count >= 2 else { return path }
    path.move(to: first)
    for i in 1..<(points.count - 1) {
        let c = points[i], n = points[i + 1]
        path.addQuadCurve(to: CGPoint(x: (c.x + n.x) / 2, y: (c.y + n.y) / 2), control: c)
    }
    path.addLine(to: last)
    return path
}

/// "12 min" under an hour, "2h 48m" above.
func naraDurationText(_ seconds: TimeInterval) -> String {
    let minutes = Int((seconds / 60).rounded())
    return minutes < 60 ? "\(minutes) min" : "\(minutes / 60)h \(minutes % 60)m"
}

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

/// The Monitor tab is Nara's single owner-scoped diagnostic surface (spec G7): it shows
/// what the server actually measured for this installation — day bounds/zone, stream
/// status, coverage, largest gap, v2 queue age, projection revision, durable acceptance
/// vs verified archival, and explicit blockers. No fabricated numbers.
struct MonitorView: View {
    @State private var diagnostics: PipelineDiagnostics?
    @State private var failure: String?
    @State private var loading = false

    var body: some View {
        ScreenScaffold(title: "Monitor", subtitle: "Nara pipeline diagnostics", trailing: { HeaderSettingsButton() }) {
            VStack(alignment: .leading, spacing: 24) {
                toolbar
                if let diagnostics {
                    surface(diagnostics)
                } else if let failure {
                    emptyState(failure)
                } else {
                    loadingState
                }
            }
        }
        .task { await load() }
    }

    private var toolbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(localDayKey())
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let zone = diagnostics?.dayBounds?.zone {
                    Text(zone)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer()
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.metricPurple)
            }
            .buttonStyle(.plain)
            .disabled(loading)
        }
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

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Loading Nara diagnostics…")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .naraCard()
    }

    private func emptyState(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nara diagnostics unavailable")
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(reason)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .naraCard()
    }

    // MARK: Surface

    private func surface(_ d: PipelineDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            NaraSectionHeader(title: String(localized: "Day bounds"))
            diagnosticsCard {
                row("Zone", d.dayBounds?.zone ?? "not_measured")
                row("Policy", d.dayBounds?.zonePolicy ?? "local_calendar_midnight")
                if let first = d.dayBounds?.segments.first, let zoneId = first.timezoneId {
                    row("Start", dayTime(first.startTs) + " " + zoneId)
                }
                if d.countsTruncated == true {
                    row("Counts", "truncated")
                }
            }

            NaraSectionHeader(title: String(localized: "Streams"))
            diagnosticsCard {
                row("Status", d.streams?.status ?? "not_measured")
                let windows = d.streams?.signalWindows ?? [:]
                if windows.isEmpty {
                    row("Signal windows", "not_measured")
                } else {
                    ForEach(windows.sorted(by: { $0.key < $1.key }), id: \.key) { stream, window in
                        row(stream, "\(window.windows ?? 0) windows · \(window.receivedRecords ?? 0) received · \(coverageText(window.meanCoverage)) covered")
                    }
                }
                if let gap = d.streams?.largestGap, gap.status == "measured", let seconds = gap.seconds {
                    row("Largest gap", "\(seconds) s" + (gap.stream.map { " (\($0))" } ?? ""))
                } else {
                    row("Largest gap", "not_measured")
                }
            }

            NaraSectionHeader(title: String(localized: "Pipeline"))
            diagnosticsCard {
                let q = d.queue?.scoringV2
                row("Queue", q?.status ?? "none")
                if let q {
                    if let pending = q.pending, pending > 0 {
                        row("Pending jobs", "\(pending)")
                    }
                    if let age = q.oldestEligibleAgeSeconds {
                        row("Oldest eligible", durationText(age))
                    }
                    row("Revisions", "\(q.inputRevision ?? 0) in → \(q.completedRevision ?? 0) done")
                }
                let p = d.projection
                row("Projection", p?.status ?? "not_observed")
                if let p, let published = p.publishedRevision {
                    row("Revision", "published \(published)" + (p.requiredRevision.map { " · required \($0)" } ?? ""))
                }
                if let archive = d.archive {
                    row("Durable accepted", "\(archive.durablePublished ?? 0)")
                    row("Verified archived", "\(archive.verified ?? 0)")
                    if let failed = archive.statuses["failed"], failed > 0 {
                        row("Archive failed", "\(failed)")
                    }
                }
            }

            NaraSectionHeader(title: String(localized: "Blockers"))
            diagnosticsCard {
                if d.blockers.isEmpty {
                    row("None", "")
                } else {
                    ForEach(Array(d.blockers.enumerated()), id: \.offset) { _, blocker in
                        row(blocker.code ?? "blocker", blocker.detail?.text ?? "")
                    }
                }
            }

            if let stage = d.stages["accepted"] {
                NaraSectionHeader(title: String(localized: "Acceptance"))
                diagnosticsCard {
                    row("Accepted", stage.status ?? "not_measured")
                    if let receipts = stage.receipts {
                        row("Receipts", "\(receipts)")
                    }
                }
            }
        }
    }

    private func diagnosticsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .naraCard()
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(value == "not_measured" || value == "not_observed" || value == "none"
                    ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Divider().overlay(StrandPalette.hairline) }
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
        guard let fraction else { return "?" }
        return "\(Int((fraction * 100).rounded()))%"
    }
}

// MARK: - Watchdog page

struct WatchdogEpisodeRow: View {
    let episode: WatchdogEpisode
    var showsChevron = false

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(episode.tone.color)
                .frame(width: 3, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(episode.start.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(episode.label)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 8)
            Text(naraDurationText(episode.duration))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// Every watchdog episode, newest first, with the totals across them.
struct WatchdogView: View {
    var snapshot: MonitorSnapshot = .sample

    private var episodes: [WatchdogEpisode] { snapshot.episodes.sorted { $0.start > $1.start } }

    var body: some View {
        ScreenScaffold(title: "Watchdog", subtitle: "Episodes in the last 30 days") {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 10) {
                    stat("Episodes", "\(episodes.count)")
                    stat("Total time", naraDurationText(episodes.reduce(0) { $0 + $1.duration }))
                    stat("Longest", naraDurationText(episodes.map(\.duration).max() ?? 0))
                }
                VStack(spacing: 0) {
                    ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                        if index > 0 { Divider().overlay(StrandPalette.hairline) }
                        WatchdogEpisodeRow(episode: episode)
                    }
                    if episodes.isEmpty {
                        Text("No episodes")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                    }
                }
                .naraCard()
            }
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value)
                .font(StrandFont.rounded(22))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .naraCard(radius: 16)
    }
}

// MARK: - Pieces

/// 28-day trend with the "usual" range as a shaded band between dashed edges.
private struct BaselineSparkline: View {
    let series: [Double]
    let low: Double
    let high: Double
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard series.count >= 2, let sMin = series.min(), let sMax = series.max() else { return }
            let lo = min(sMin, low), hi = max(sMax, high)
            let pad = max((hi - lo) * 0.12, 0.001)
            let yMin = lo - pad, yMax = hi + pad
            func y(_ v: Double) -> CGFloat { size.height * (1 - CGFloat((v - yMin) / (yMax - yMin))) }

            let top = y(high), bottom = y(low)
            context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: bottom - top)),
                         with: .color(tint.opacity(0.14)))
            var edges = Path()
            for edge in [top, bottom] {
                edges.move(to: CGPoint(x: 0, y: edge))
                edges.addLine(to: CGPoint(x: size.width, y: edge))
            }
            context.stroke(edges, with: .color(tint.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))

            let points = series.enumerated().map {
                CGPoint(x: size.width * CGFloat($0.offset) / CGFloat(series.count - 1), y: y($0.element))
            }
            context.stroke(naraSmoothPath(points), with: .color(tint),
                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct CoverageRing: View {
    let fraction: Double
    private let tint = Color(red: 0.25, green: 0.85, blue: 0.78)

    var body: some View {
        ZStack {
            Circle().stroke(StrandPalette.hairline, lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded()))%")
                .font(StrandFont.rounded(16))
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Coverage \(Int((fraction * 100).rounded())) percent"))
    }
}
