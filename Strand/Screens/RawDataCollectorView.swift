import SwiftUI
import StrandDesign
import WhoopStore

/// iOS/macOS parity twin of Android's 5/MG Raw Data Collector screen.
struct RawDataCollectorView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @StateObject private var store = RawDataSessionStore()

    @State private var exportingId: String?
    @State private var deleteCandidate: RawDataSessionStore.Session?
    @State private var confirmDeleteAll = false
    @State private var exportError: String?
    @State private var deleteError: String?
    @State private var captureError: String?
    @State private var imuCoverage: [String: String] = [:]
    @State private var historicalFrom = Date().addingTimeInterval(-3_600)
    @State private var historicalTo = Date()
    @State private var markerDraft: MarkerDraft?

    private struct MarkerDraft: Identifiable {
        let id = UUID()
        let sessionId: String
        let markerId: String?
        var at: Date
        // C8 Fix F: interval end (used only when `type` is an interval label).
        var end: Date
        var type: String
        var text: String
    }

    var body: some View {
        ScreenScaffold(
            title: "5/MG Raw Data Collector",
            subtitle: "Record a bounded 100 Hz motion session and export its complete timeline."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                coverageCard
                controls
                historicalRangeCard
                sessionsSection
            }
        }
        .task {
            // Restore a session after navigation/process lifecycle changes. The BLE layer rejects a
            // duplicate arm, so this is safe when capture never stopped.
            if let active = store.active, live.bonded { _ = model.ble.startGroundTruthRawCapture(sessionId: active.id) }
            await refreshImuCoverage()
        }
        .onChangeCompat(of: live.bonded) { bonded in
            if bonded, let active = store.active { _ = model.ble.startGroundTruthRawCapture(sessionId: active.id) }
        }
        .confirmationDialog("Delete this session?", isPresented: Binding(
            get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let session = deleteCandidate else { return }
                deleteCandidate = nil
                Task { await delete(session) }
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            if let session = deleteCandidate {
                Text("The session \(Self.range(session)) and its captured raw data will be deleted permanently.")
            }
        }
        .confirmationDialog("Delete all sessions?", isPresented: $confirmDeleteAll,
                            titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { Task { await deleteAll() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All \(store.sessions.count) recorded sessions and their captured raw data will be deleted permanently.")
        }
        .alert("Couldn't export session", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "Unknown error") }
        .alert("Couldn't delete session", isPresented: Binding(
            get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: { Text(deleteError ?? "Unknown error") }
        // C8 Fix C: a session start that can't record raw IMU (e.g. WHOOP 4.0's 1917-byte
        // REALTIME_RAW_DATA) is rolled back and surfaced here — never a silent "recording" that
        // stores nothing.
        .alert("Couldn't start raw-data session", isPresented: Binding(
            get: { captureError != nil }, set: { if !$0 { captureError = nil } }
        )) {
            Button("OK", role: .cancel) { captureError = nil }
        } message: { Text(captureError ?? "Unknown error") }
        .sheet(item: $markerDraft) { draft in markerSheet(draft) }
    }

    private var coverageCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Capture coverage").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(live.connected ? "Band: connected\(live.bonded ? " + paired" : "; pairing")"
                                    : "Band: disconnected")
                    .foregroundStyle(live.connected ? StrandPalette.statusPositive : StrandPalette.statusCritical)
                Text(live.backfilling
                     ? "History sync: running (\(live.syncChunksThisSession) chunks)"
                     : "History sync: idle")
                    .foregroundStyle(StrandPalette.textSecondary)
                if let active = store.active {
                    Text("Realtime IMU: session active since \(Self.time(active.startedAtMs))")
                        .foregroundStyle(StrandPalette.accent)
                }
            }
            .font(StrandFont.subhead)
        }
    }

    @ViewBuilder private var controls: some View {
        if store.active != nil {
            NoopButton("Stop session", systemImage: "stop.fill", kind: .destructive,
                       fullWidth: true) { Task { await stop() } }
        } else {
            NoopButton("Start raw-data session", systemImage: "record.circle", kind: .primary,
                       fullWidth: true) { start() }
                .disabled(!live.bonded)
        }
    }

    private var historicalRangeCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Historical export window").font(StrandFont.headline)
                Text("Create a session from synchronized history without starting a live capture. 100 Hz coverage is included wherever it still exists in the rolling buffer.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                DatePicker("From", selection: $historicalFrom)
                DatePicker("To", selection: $historicalTo, in: historicalFrom...)
                NoopButton("Add historical session", systemImage: "clock.arrow.circlepath",
                           kind: .secondary, fullWidth: true) {
                    _ = store.createHistorical(deviceId: model.ble.deviceId,
                                               from: historicalFrom, to: historicalTo)
                }
                .disabled(historicalTo <= historicalFrom || historicalTo.timeIntervalSince(historicalFrom) > 7 * 86_400)
            }
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Recorded sessions").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            if store.sessions.isEmpty {
                Text("No sessions recorded yet.").font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                NoopButton("Delete all sessions", systemImage: "trash", kind: .destructive,
                           fullWidth: true) { confirmDeleteAll = true }
                    .disabled(store.active != nil)
                ForEach(store.sessions) { session in sessionCard(session) }
            }
        }
    }

    private func sessionCard(_ session: RawDataSessionStore.Session) -> some View {
        let coverageText = imuCoverage[session.id, default: "no complete seconds"]
        return StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text(Self.range(session)).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                if !session.active, let endMs = session.endedAtMs {
                    DatePicker("From", selection: Binding(
                        get: { Date(timeIntervalSince1970: Double(session.startedAtMs) / 1_000) },
                        set: { store.setRange(sessionId: session.id, from: $0,
                                              to: Date(timeIntervalSince1970: Double(endMs) / 1_000)) }
                    ))
                    DatePicker("To", selection: Binding(
                        get: { Date(timeIntervalSince1970: Double(endMs) / 1_000) },
                        set: { store.setRange(sessionId: session.id,
                                              from: Date(timeIntervalSince1970: Double(session.startedAtMs) / 1_000), to: $0) }
                    ))
                }
                Text(session.active ? String(localized: "Export status: recording")
                     : String(localized: "IMU: \(coverageText)"))
                    .font(StrandFont.caption)
                    .foregroundStyle(session.active ? StrandPalette.statusWarning : StrandPalette.statusPositive)
                if let exportedAt = session.lastExportedAtMs {
                    Text(String(localized: "Last exported \(Self.time(exportedAt)) · export remains available"))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                TextField("Session comment", text: Binding(
                    get: { store.sessions.first(where: { $0.id == session.id })?.comment ?? session.comment },
                    set: { store.setComment($0, sessionId: session.id) }
                ), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
                NoopButton("Add marker", systemImage: "mappin.and.ellipse", kind: .secondary,
                           fullWidth: true) { editMarker(nil, in: session) }
                let markers = session.events.filter { $0.kind == "marker" }.sorted { $0.atMs < $1.atMs }
                ForEach(markers) { marker in
                    Button { editMarker(marker, in: session) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                                (Text(Self.markerLabel(marker.markerType))
                                    + Text(verbatim: " · \(Self.time(marker.atMs))"))
                                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                if let text = marker.text, !text.isEmpty {
                                    Text(text).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                // C8 Fix F: duration-bearing activity intervals (walking/running/sitting/standing/
                // other_movement), added beside instant markers and exported with provenance.
                NoopButton("Add activity interval", systemImage: "figure.walk", kind: .secondary,
                           fullWidth: true) { editInterval(nil, in: session) }
                let intervals = session.events.filter { $0.kind == "activityInterval" }
                    .sorted { $0.atMs < $1.atMs }
                ForEach(intervals) { interval in
                    Button { editInterval(interval, in: session) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                                (Text(Self.markerLabel(interval.markerType))
                                    + Text(verbatim: " · \(Self.time(interval.atMs))–\(Self.time(interval.endAtMs ?? interval.atMs))"))
                                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                NoopButton(exportingId == session.id ? "Building export…" : "Export session",
                           systemImage: "square.and.arrow.up", kind: .secondary, fullWidth: true) {
                    Task { await export(session) }
                }
                .disabled(session.active || exportingId != nil)
                NoopButton("Delete session", systemImage: "trash", kind: .destructive,
                           fullWidth: true) { deleteCandidate = session }
                    .disabled(session.active || exportingId != nil)
            }
        }
    }

    private func markerSheet(_ initial: MarkerDraft) -> some View {
        NavigationStack {
            if let binding = Binding($markerDraft) {
                let session = store.sessions.first(where: { $0.id == binding.wrappedValue.sessionId })
                Form {
                    if Self.isIntervalLabel(binding.wrappedValue.type) {
                        // C8 Fix F: duration-bearing interval — from/to pickers instead of the
                        // single instant-marker time control.
                        Section("Interval") {
                            DatePicker("From", selection: binding.at)
                            DatePicker("To", selection: binding.end, in: binding.wrappedValue.at...)
                        }
                    } else {
                        Section {
                            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                let current = Self.markerCurrentTime(session: session, now: timeline.date)
                                Text("Marker: \(binding.wrappedValue.at.formatted(date: .omitted, time: .standard))")
                                Text("Current time: \(current.formatted(date: .omitted, time: .standard))")
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button { binding.wrappedValue.at.addTimeInterval(-10) } label: { Text(verbatim: "−10 s") }
                                    Spacer()
                                    Button("0") {
                                        binding.wrappedValue.at = Self.markerCurrentTime(session: session, now: Date())
                                    }
                                    Spacer()
                                    Button { binding.wrappedValue.at.addTimeInterval(10) } label: { Text(verbatim: "+10 s") }
                                }
                            }
                        }
                    }
                    Section("Type") {
                        Picker("Type", selection: binding.type) {
                            ForEach(RawDataSessionStore.markerTypes, id: \.self) { type in
                                Text(Self.markerLabel(type)).tag(type)
                            }
                            ForEach(RawDataSessionStore.intervalLabels, id: \.self) { label in
                                Text(Self.markerLabel(label)).tag(label)
                            }
                        }.pickerStyle(.segmented)
                    }
                    Section("Note") {
                        TextField("Note", text: binding.text, axis: .vertical).lineLimit(2...4)
                    }
                    if let markerId = binding.wrappedValue.markerId {
                        Section {
                            Button("Delete", role: .destructive) {
                                store.deleteMarker(sessionId: binding.wrappedValue.sessionId, markerId: markerId)
                                markerDraft = nil
                            }
                        }
                    }
                }
                .navigationTitle(Self.isIntervalLabel(binding.wrappedValue.type)
                    ? (initial.markerId == nil ? "Add activity interval" : "Edit activity interval")
                    : (initial.markerId == nil ? "Add marker" : "Edit marker"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { markerDraft = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saveMarker(binding.wrappedValue) }
                    }
                }
            }
        }
    }

    private func editMarker(_ marker: RawDataSessionStore.Event?, in session: RawDataSessionStore.Session) {
        let currentMs = session.endedAtMs ?? Int64(Date().timeIntervalSince1970 * 1_000)
        let endMs = marker?.endAtMs ?? marker?.atMs ?? currentMs
        markerDraft = MarkerDraft(sessionId: session.id, markerId: marker?.markerId,
                                  at: Date(timeIntervalSince1970: Double(marker?.atMs ?? currentMs) / 1_000),
                                  end: Date(timeIntervalSince1970: Double(endMs) / 1_000),
                                  type: marker?.markerType ?? "moment", text: marker?.text ?? "")
    }

    /// C8 Fix F: open the sheet for a NEW or EXISTING duration-bearing activity interval
    /// (presets the interval label type and a sensible default from/to window).
    private func editInterval(_ interval: RawDataSessionStore.Event?, in session: RawDataSessionStore.Session) {
        let currentMs = session.endedAtMs ?? Int64(Date().timeIntervalSince1970 * 1_000)
        let defaultFrom = max(session.startedAtMs, currentMs - 300_000)
        let startMs = interval?.atMs ?? defaultFrom
        let endMs = interval?.endAtMs ?? currentMs
        markerDraft = MarkerDraft(sessionId: session.id, markerId: interval?.markerId,
                                  at: Date(timeIntervalSince1970: Double(startMs) / 1_000),
                                  end: Date(timeIntervalSince1970: Double(endMs) / 1_000),
                                  type: interval?.markerType ?? "walking", text: "")
    }

    private func saveMarker(_ draft: MarkerDraft) {
        if Self.isIntervalLabel(draft.type) {
            // C8 Fix F: duration-bearing interval — never touches a predicted label; the record is
            // a separate "user_confirmed" local overlay (RawDataSessionStore.intervalProvenance).
            if let intervalId = draft.markerId {
                store.updateIntervalLabel(sessionId: draft.sessionId, intervalId: intervalId,
                                          from: draft.at, to: draft.end, label: draft.type)
            } else {
                store.addIntervalLabel(sessionId: draft.sessionId, from: draft.at, to: draft.end,
                                       label: draft.type)
            }
        } else if let markerId = draft.markerId {
            store.updateMarker(sessionId: draft.sessionId, markerId: markerId,
                               at: draft.at, type: draft.type, text: draft.text)
        } else {
            store.addMarker(sessionId: draft.sessionId, at: draft.at, type: draft.type, text: draft.text)
        }
        markerDraft = nil
    }

    private func start() {
        guard let session = store.start(deviceId: model.ble.deviceId) else { return }
        // C8 Fix C: the BLE layer now reports WHY a session can't start (unsupported family,
        // not connected, another capture in flight) instead of a bare Bool. On anything other
        // than `.started` the session is rolled back and the reason is shown — a WHOOP 4.0
        // session never silently records nothing while the UI claims recording.
        let result = model.ble.startGroundTruthRawCapture(sessionId: session.id)
        guard result == .started else {
            captureError = Self.captureErrorMessage(result)
            // `.unsupportedDeviceFamily` latched `rawCaptureInFlight` to let the legacy writes
            // through — release it so the next start isn't blocked.
            Task { await model.ble.stopGroundTruthRawCapture() }
            store.stop()
            store.removeMetadata(session.id)
            return
        }
    }

    private func stop() async {
        await model.ble.stopGroundTruthRawCapture()
        store.stop()
        await refreshImuCoverage()
    }

    private func export(_ session: RawDataSessionStore.Session) async {
        guard let end = session.endedAtMs else { return }
        exportingId = session.id
        let bounds = Self.fullSecondBounds(fromMs: session.startedAtMs, toMs: end)
        let from = bounds?.from ?? 1, to = bounds?.to ?? 0
        let segments = bounds.map {
            ImuSessionFileStore.shared.exportSegments(session.id, from: $0.from, to: $0.to)
        } ?? []
        let history = bounds == nil ? Data("stream,unix_s,v1,v2,v3,v4\n".utf8)
            : await model.ble.groundTruthHistoryCSV(from: from, to: to)
        let sensorAvailable = !segments.isEmpty || history.split(separator: 0x0A).count > 1
        var entries = store.exportEntries(for: session, sensorAvailable: sensorAvailable)
        entries.append(.init(name: "history-sensors.csv", data: history))
        // A live capture can only produce its first complete one-second frame after startup.
        // Historical windows must still cover the exact requested start.
        let firstImuTs = segments.map(\.startTs).min().flatMap { $0 <= from + 1 ? $0 : nil }
        let coverageFrom = session.capturedStartedAtMs == nil ? from : max(from, firstImuTs ?? from)
        let imuComplete = Self.covers(segments, from: coverageFrom, to: to)
        let coverage: [String: Any] = [
            "requested_start_ts": from, "requested_end_ts": to,
            "required_start_ts": coverageFrom,
            "startup_seconds": max(0, coverageFrom - from),
            "complete": imuComplete,
            "segments": segments.map { ["file": $0.name, "start_ts": $0.startTs, "end_ts": $0.endTs,
                                         "sample_count": $0.sampleCount] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: coverage, options: [.prettyPrinted, .sortedKeys]) {
            entries.append(.init(name: "imu-coverage.json", data: data))
        }
        for segment in segments { entries.append(.init(name: "imu/\(segment.name)", data: segment.data)) }
        let result = await FileExport.exportBundle(entries: entries,
                                                    suggestedName: "noop-5mg-raw-\(session.id).zip")
        if result == nil { exportError = "The export file could not be created or shared." }
        else {
            store.markExported(session.id)
        }
        exportingId = nil
    }

    private func delete(_ session: RawDataSessionStore.Session) async {
        guard session.endedAtMs != nil else { return }
        guard store.removeMetadata(session.id) else {
            deleteError = "The captured data could not be deleted. The session was kept so you can retry."
            return
        }
        imuCoverage[session.id] = nil
    }

    private func deleteAll() async {
        for session in store.sessions where !session.active { await delete(session) }
    }

    private func refreshImuCoverage() async {
        for session in store.sessions {
            guard let end = session.endedAtMs,
                  let bounds = Self.fullSecondBounds(fromMs: session.startedAtMs, toMs: end) else { continue }
            let stats = ImuSessionFileStore.shared.stats(session.id, from: bounds.from, to: bounds.to)
            let first = stats.firstTs.flatMap { $0 <= Int64(bounds.from + 1) ? Int($0) : nil }
            let from = session.capturedStartedAtMs == nil ? bounds.from : max(bounds.from, first ?? bounds.from)
            let expected = max(0, bounds.to - from + 1)
            let bytes = ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .file)
            // C8 Fix E: readiness is judged on DURABLE seconds only — the RAM-only pending tail is
            // shown separately as "buffered" and never counts as covered/ready.
            let readiness = expected > 0 && stats.diskSeconds == expected ? "ready" : "incomplete"
            let buffered = stats.pendingSeconds > 0 ? " · +\(stats.pendingSeconds) s buffered" : ""
            imuCoverage[session.id] = "\(stats.diskSeconds)/\(expected) s\(buffered) · \(bytes) · \(readiness)"
        }
    }

    private static func time(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1_000)
            .formatted(Date.FormatStyle(date: .omitted, time: .shortened)
                .locale(AppClock.formattingLocale))   // #1821
    }

    static func fullSecondBounds(fromMs: Int64, toMs: Int64) -> (from: Int, to: Int)? {
        let from = Int((fromMs + 999) / 1_000), to = Int(toMs / 1_000) - 1
        return from <= to ? (from, to) : nil
    }

    static func markerCurrentTime(session: RawDataSessionStore.Session?, now: Date) -> Date {
        session?.endedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1_000) } ?? now
    }

    private static func range(_ session: RawDataSessionStore.Session) -> String {
        let start = Date(timeIntervalSince1970: Double(session.startedAtMs) / 1_000)
        let date = start.formatted(date: .numeric, time: .omitted)
        let end = session.endedAtMs.map(time) ?? "…"
        return "\(date) · \(time(session.startedAtMs))–\(end)"
    }

    private static func markerLabel(_ type: String?) -> LocalizedStringKey {
        switch type {
        case "start": "Start"
        case "end": "End"
        case "issue": "Issue"
        case "walking": "Walking"
        case "running": "Running"
        case "sitting": "Sitting"
        case "standing": "Standing"
        case "other_movement": "Other movement"
        default: "Moment"
        }
    }

    /// C8 Fix F: whether a picker value is a duration-bearing interval label (vs an instant marker).
    private static func isIntervalLabel(_ type: String) -> Bool {
        RawDataSessionStore.intervalLabels.contains(type)
    }

    /// C8 Fix C: user-facing reason a raw-data session could not start. Every failure path rolls
    /// the session back, so a WHOOP 4.0 (1917-byte REALTIME_RAW_DATA) can never appear to record.
    private static func captureErrorMessage(_ result: BLEManager.GroundTruthCaptureStart) -> String {
        switch result {
        case .unsupportedDeviceFamily:
            return "This WHOOP family doesn't provide the 100 Hz raw IMU stream this collector records (WHOOP 4.0's REALTIME_RAW_DATA is the 1917-byte variant, which the IMU store can't accept). No raw IMU was recorded and the session was rolled back — use a WHOOP 5/MG for raw capture."
        case .alreadyInFlight:
            return "Another raw-data capture is already running, so this session was rolled back."
        case .notConnected:
            return "The band isn't connected, so the capture could not start. The session was rolled back; it re-arms automatically on the next connection."
        case .started:
            return ""
        }
    }

    private static func covers(_ chunks: [ImuSessionFileStore.ExportSegment], from: Int, to: Int) -> Bool {
        var cursor = from
        for chunk in chunks.sorted(by: { $0.startTs < $1.startTs }) {
            let start = chunk.startTs, end = chunk.endTs
            if chunk.sampleCount < (end - start + 1) * ImuSessionFileStore.sampleRate { continue }
            if start > cursor { return false }
            if end >= cursor { cursor = end + 1 }
            if cursor > to { return true }
        }
        return cursor > to
    }
}
