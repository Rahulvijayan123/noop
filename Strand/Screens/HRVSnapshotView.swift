import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Manual HRV snapshot — "Take an HRV reading" (#127).
///
/// A short, deliberate seated capture: the user sits still and breathes normally while the strap's
/// live R-R intervals (the reliable 0x2A37 stream) accumulate for ~60 s. We then run the full
/// HRVAnalyzer cleaning pipeline (range filter → Malik ectopic rejection → ≥minBeats) and surface the
/// headline RMSSD plus SDNN, mean HR and the beats used. Saving banks the RMSSD as a single point in
/// the generic metric series ("hrv_snapshot", source "manual-hrv") so it sits beside every other
/// source for the explorer/trends.
///
/// The live ingest uses the shared `onRRPackets` observer; the capture buffer is uncapped (unlike
/// Breathe's rolling 30) because the analysis wants every clean beat. The window is a monotonic
/// 60-second deadline — countdown display and ingest cutoff both derive from it.
struct HRVSnapshotView: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    /// Optional dismissal hook when presented as a sheet (Live → "Take an HRV reading").
    var onClose: (() -> Void)? = nil

    /// Where the live R-R is coming from, so the methodology caveat is honest (#537): a WHOOP 5/MG
    /// derives R-R from the optical pulse signal (noisier) while a WHOOP 4 / chest strap is electrical
    /// R-R. Defaults to `.unknown` for callers that do not pass a strap model, matching the Android twin.
    var source: SpotHrvReading.Source = .unknown

    // MARK: - Capture phase

    private enum Phase: Equatable {
        case idle           // not yet started (or finished and reset)
        case capturing      // accumulating R-R, counting down
        case done           // analysis complete — showing the result
    }

    /// Length of a capture in seconds. Long enough to collect ≥minBeats clean intervals at a resting
    /// rate (≈60 beats at 60 bpm) with headroom for ectopic/range rejection.
    static let captureSeconds = 60

    // MARK: - State

    @State private var phase: Phase = .idle

    /// Every R-R interval (ms) collected during the active capture window — uncapped on purpose; the
    /// analyzer wants the whole window.
    @State private var captureBuffer: [Int] = []
    @State private var secondsRemaining = HRVSnapshotView.captureSeconds

    /// Monotonic start of the active capture — the single time base for the countdown display, the
    /// ingest cutoff, and the finish deadline. Nil outside a capture.
    @State private var captureStart: ContinuousClock.Instant? = nil

    /// Wall-clock bounds of the capture, for the timestamped spot record: when it started, and (once finished)
    /// when it ended. The monotonic clock above times the capture; these only place it on the timeline.
    @State private var captureStartedAt: Date? = nil
    @State private var capturedSpan: (start: Int, end: Int)? = nil

    /// Live RMSSD over the beats gathered so far (a running indicator while capturing; the final
    /// figure comes from the cleaned `HRVAnalyzer.analyze`).
    @State private var runningRMSSD: Double? = nil

    /// The completed analysis (nil until `.done`).
    @State private var result: HRVAnalyzer.HRVResult? = nil

    /// Whether the just-finished snapshot has been saved (drives the Save button → "Saved").
    @State private var saved = false

    private let secondTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var bonded: Bool { live.bonded }

    var body: some View {
        ScreenScaffold(title: "HRV Reading",
                       subtitle: "A still, seated snapshot of your heart-rate variability") {
            statusRow
            captureCard
            controlRow
            if phase == .done, let result { resultCard(result) }
            methodologyCard
            if !bonded { notBondedHint }
        }
        // rrSeq-keyed: equal consecutive packets both count (see RRPacketObserver.swift).
        .onRRPackets(live) { rr in
            ingest(rr)
        }
        // Capture countdown — only ticks while capturing.
        .onReceive(secondTimer) { _ in
            guard phase == .capturing else { return }
            tick()
        }
        .onDisappear {
            ScreenIdle.keepAwake(false)
        }
    }

    // MARK: - Status row

    private var statusRow: some View {
        HStack(spacing: 10) {
            switch phase {
            case .idle:
                StatePill("Ready", tone: .neutral)
            case .capturing:
                StatePill("Capturing", tone: .accent, pulsing: true)
            case .done:
                StatePill("Reading complete", tone: .positive, showsDot: true)
            }

            if bonded {
                StatePill("Strap live", tone: .positive, showsDot: true)
            } else {
                StatePill("Not connected", tone: .warning, showsDot: true)
            }

            Spacer()

            if let close = onClose {
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(StrandFont.icon(.row))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close HRV reading")
            }
        }
    }

    // MARK: - Capture card

    private var captureCard: some View {
        StrandCard(padding: 24) {
            VStack(spacing: 18) {
                captureDial
                    .padding(.vertical, 6)
                .frame(height: 260)
                .frame(maxWidth: .infinity)

                Text(instruction)
                    .font(StrandFont.subhead)
                    .foregroundStyle(phase == .capturing ? StrandPalette.restBright : StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The centre dial: a progress ring around the live RMSSD / countdown. While capturing it shows the
    /// running RMSSD; idle/done it shows the headline figure or a prompt.
    private var captureDial: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .strokeBorder(StrandPalette.restColor.opacity(0.20), lineWidth: 10)
                    .frame(width: d, height: d)

                Circle()
                    .trim(from: 0, to: captureFraction)
                    .stroke(
                        AngularGradient(colors: [StrandPalette.restDeep, StrandPalette.restBright],
                                        center: .center),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: d, height: d)
                    .animation(.easeInOut(duration: 0.4), value: captureFraction)

                VStack(spacing: 2) {
                    Text(dialValue)
                        .font(StrandFont.number(48))
                        .foregroundStyle(StrandPalette.metricPurple)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: dialValue)
                    Text(dialUnit)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    if phase == .capturing {
                        Text("\(secondsRemaining)s left · \(captureBuffer.count) beats")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(.top, 4)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(dialAccessibilityLabel)
        }
    }

    /// 0…1 capture progress, driving the ring trim.
    private var captureFraction: CGFloat {
        switch phase {
        case .idle:      return 0
        case .capturing: return CGFloat(Self.captureSeconds - secondsRemaining) / CGFloat(Self.captureSeconds)
        case .done:      return 1
        }
    }

    private var dialValue: String {
        switch phase {
        case .idle:
            return "—"
        case .capturing:
            return runningRMSSD.map { String(format: "%.0f", $0) } ?? "…"
        case .done:
            return result?.rmssd.map { String(format: "%.0f", $0) } ?? "—"
        }
    }

    private var dialUnit: String {
        phase == .idle ? "RMSSD" : "MS RMSSD"
    }

    private var instruction: String {
        switch phase {
        case .idle:
            return bonded
                ? String(localized: "Sit still and breathe normally. Tap below to take a 60-second reading.")
                : String(localized: "Connect your strap on the Live screen to take a reading.")
        case .capturing:
            return String(localized: "Sit still, breathe normally. Keep your wrist relaxed and steady.")
        case .done:
            if let r = result, r.rmssd == nil {
                return String(localized: "Not enough clean beats. Sit still and try again.")
            }
            return String(localized: "Done. Save this reading to keep it in your trends.")
        }
    }

    private var dialAccessibilityLabel: String {
        switch phase {
        case .idle:      return String(localized: "HRV reading not started")
        case .capturing: return String(localized: "Capturing. \(secondsRemaining) seconds remaining, \(captureBuffer.count) beats collected.")
        case .done:
            return result?.rmssd.map { String(localized: "RMSSD \(Int($0.rounded())) milliseconds") } ?? String(localized: "Reading incomplete")
        }
    }

    // MARK: - Controls

    private var controlRow: some View {
        HStack(spacing: 12) {
            Button {
                phase == .capturing ? cancel() : start()
            } label: {
                Label(primaryLabel, systemImage: primaryIcon)
                    .font(StrandFont.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(phase == .capturing ? StrandPalette.statusCritical : StrandPalette.accent)
            .disabled(!bonded && phase != .capturing)
            .help(bonded
                  ? "Take a 60-second seated HRV reading from the live R-R stream."
                  : "Connect your strap first. The reading needs the live R-R stream.")

            if phase == .done, let r = result, r.rmssd != nil {
                Button {
                    save(r)
                } label: {
                    Label(saved ? "Saved" : "Save", systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                        .font(StrandFont.body)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.bordered)
                .tint(StrandPalette.accent)
                .disabled(saved)
            }
        }
    }

    private var primaryLabel: String {
        switch phase {
        case .idle:      return String(localized: "Take an HRV reading")
        case .capturing: return String(localized: "Cancel")
        case .done:      return String(localized: "Take another reading")
        }
    }

    private var primaryIcon: String {
        phase == .capturing ? "stop.fill" : "waveform.path.ecg"
    }

    // MARK: - Result

    private func resultCard(_ result: HRVAnalyzer.HRVResult) -> some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Your reading")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)

                if result.rmssd == nil {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(StrandPalette.statusWarning)
                            .accessibilityHidden(true)
                        Text("Not enough clean beats. Sit still and try again. \(result.nClean) of \(result.nInput) beats survived filtering (need \(HRVAnalyzer.minBeats)).")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    HStack(spacing: NoopMetrics.gap) {
                        metricTile("RMSSD", Self.format(result.rmssd, "%.0f"), "ms", StrandPalette.metricPurple)
                        metricTile("SDNN", Self.format(result.sdnn, "%.0f"), "ms", StrandPalette.restBright)
                        metricTile(String(localized: "Mean HR"), Self.format(Self.meanHR(meanNN: result.meanNN), "%.0f"), "bpm", StrandPalette.metricRose)
                        metricTile(String(localized: "Beats"), "\(result.nClean)", String(localized: "used"), StrandPalette.metricCyan)
                    }
                }
            }
        }
    }

    private func metricTile(_ label: String, _ value: String, _ unit: String, _ accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).strandLabel()
            Spacer(minLength: 6)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(StrandFont.number(24))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(NoopInsetSurface())
    }

    // MARK: - Methodology

    /// Source-aware methodology (#537): the first line states the spot RMSSD uses the SAME cleaned
    /// Task-Force math as the nightly HRV (so the number is comparable to your overnight figure), then
    /// `SpotHrvReading.caveatFor` adds the honest limits — including the noisier optical-PPG note on a
    /// WHOOP 5/MG. Single-sourced with Android via the shared helper, no em-dashes.
    private var methodologyCard: some View {
        AboutDisclosure("How this is measured") {
            VStack(alignment: .leading, spacing: 8) {
                Text("A 60-second snapshot of your beat-to-beat (R-R) intervals from the strap, cleaned (range and ectopic-beat filtering) before computing RMSSD the same way your overnight HRV is computed.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SpotHrvReading.caveatFor(source))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Not-bonded hint

    private var notBondedHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            Text("An HRV reading needs the live R-R stream. Open the Live screen and connect your strap, then come back.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(StrandPalette.statusWarning.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                .strokeBorder(StrandPalette.statusWarning.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Capture control

    private func start() {
        guard bonded else { return }
        captureStart = ContinuousClock().now
        captureStartedAt = Date()
        capturedSpan = nil
        phase = .capturing
        captureBuffer.removeAll()
        secondsRemaining = Self.captureSeconds
        runningRMSSD = nil
        result = nil
        saved = false
        ScreenIdle.keepAwake(true)      // hold the screen awake through the hands-still capture (no-op on macOS)
    }

    private func cancel() {
        phase = .idle
        captureStart = nil
        secondsRemaining = Self.captureSeconds
        runningRMSSD = nil
        ScreenIdle.keepAwake(false)
    }

    /// Milliseconds of monotonic time since the capture started (nil outside a capture).
    private func captureElapsedMs() -> Int? {
        guard let start = captureStart else { return nil }
        let c = (ContinuousClock().now - start).components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }

    /// Derive the countdown from the monotonic clock — a late timer fire jumps to the correct
    /// remaining value instead of stretching the window (the old per-callback decrement did).
    private func tick() {
        guard let ms = captureElapsedMs() else { return }
        secondsRemaining = Self.remainingSeconds(elapsedMs: ms)
        if secondsRemaining == 0 {
            finish()
        }
    }

    /// End the capture and run the full cleaning analysis over everything collected.
    private func finish() {
        ScreenIdle.keepAwake(false)
        let captureMs = captureElapsedMs() ?? Self.captureSeconds * 1000
        captureStart = nil
        if let began = captureStartedAt {
            let start = Int(began.timeIntervalSince1970)
            capturedSpan = (start, start + max(1, (captureMs + 999) / 1000))
        }
        captureStartedAt = nil
        let raw = captureBuffer.map(Double.init)
        // A capture whose collected beat time exceeds the wall clock it ran for held duplicated
        // beats (e.g. overlapping live sources) — refuse the number rather than publish it.
        if HRVAnalyzer.spotCaptureOverCounted(beatTimeMs: raw.reduce(0, +),
                                              captureMs: Double(captureMs)) {
            result = HRVAnalyzer.HRVResult(rmssd: nil, sdnn: nil, meanNN: nil, pnn50: nil,
                                           nInput: raw.count, nClean: 0)
            phase = .done
            return
        }
        // HRV & Autonomic test mode (Group G): when the mode is on, emit the cleaning trace (nInput /
        // nClean / rejected fraction, the range + Malik ectopic counts, the minBeats + spot gates,
        // RMSSD/SDNN/meanNN) tagged `.hrv`. analyzeTrace returns the SAME HRVResult `analyze` would
        // (it reuses analyze verbatim), so the headline RMSSD is byte-identical with the trace on or off.
        // Zero cost when off: the gate is one UserDefaults bool read and analyzeTrace is never called, so
        // the plain `analyze` path below runs untouched.
        if TestCentre.active(.hrv) {
            let (traced, lines) = HRVAnalyzer.analyzeTrace(
                rawRR: raw, maxRejectedFraction: HRVAnalyzer.defaultSpotMaxRejectedFraction, path: "spot")
            for line in lines { live.append(log: line, domain: .hrv) }
            result = traced
        } else {
            result = HRVAnalyzer.analyze(rawRR: raw,
                                         maxRejectedFraction: HRVAnalyzer.defaultSpotMaxRejectedFraction)
        }
        phase = .done
    }

    // MARK: - Live R-R ingest (mirrors BreathingView)

    /// Append newly-arrived R-R intervals to the capture buffer (only while capturing) and refresh the
    /// running RMSSD indicator. The published `rr` is the latest set of intervals.
    private func ingest(_ rr: [Int]) {
        guard phase == .capturing, !rr.isEmpty,
              let ms = captureElapsedMs(), Self.captureWindowOpen(elapsedMs: ms) else { return }
        captureBuffer.append(contentsOf: rr)
        runningRMSSD = HRVAnalyzer.rmssdRaw(captureBuffer.map(Double.init))
    }

    // MARK: - Save

    /// Persist the snapshot twice over:
    ///  - as the day's metric point (key "hrv_snapshot", source "manual-hrv"), which the per-source explorer and
    ///    the Android twin read. That one stays a day value: a second reading the same day overwrites it, as
    ///    every other importer's upsert does. Written first, and on its own: the spot record below can never
    ///    keep it from being saved;
    ///  - as a timestamped spot record (`spotHrvReading`: the capture's own start and end, its clean-beat
    ///    support and the method), keyed by the capture's start, so a second reading the same day is a second
    ///    record. It holds no copy of the activity context: that joins by time (`spotHrvReadingCtx`), so the
    ///    live day's provisional label never sticks to it.
    private func save(_ result: HRVAnalyzer.HRVResult) {
        guard let rmssd = result.rmssd else { return }
        let day = Repository.dayString(Date())
        let point = MetricPoint(day: day, key: HRVSnapshot.metricKey, value: rmssd)
        let span = capturedSpan
        saved = true                    // optimistic — the write is local + idempotent
        Task {
            guard let store = await model.repo.storeHandle() else {
                saved = false
                return
            }
            do {
                try await store.upsertMetricSeries([point], deviceId: HRVSnapshot.sourceId)
            } catch {
                saved = false
                return
            }
            if let span, let reading = HRVSnapshot.reading(result: result, start: span.start, end: span.end,
                                                           createdAt: Int(Date().timeIntervalSince1970)) {
                do {
                    try await store.saveSpotHrvReading(reading, deviceId: model.repo.deviceId)
                } catch {
                    NSLog("HRV snapshot: could not save the spot record: \(error)")
                }
            }
            await model.repo.refresh()
        }
    }

    // MARK: - Pure formatting helpers (shared with the tests)

    static func format(_ value: Double?, _ fmt: String) -> String {
        guard let value else { return "—" }
        return String(format: fmt, value)
    }

    /// Mean heart rate (bpm) from the mean NN interval (ms): 60000 / meanNN. nil when meanNN is missing
    /// or non-positive.
    static func meanHR(meanNN: Double?) -> Double? {
        guard let meanNN, meanNN > 0 else { return nil }
        return 60_000.0 / meanNN
    }

    /// Whole seconds left for a monotonic elapsed time, never negative. Mirrors Android
    /// `remainingCaptureSeconds`.
    static func remainingSeconds(elapsedMs: Int) -> Int {
        max(0, captureSeconds - elapsedMs / 1000)
    }

    /// The ingest gate: intervals on or after the 60-second deadline stay out, however late the
    /// countdown timer fires. Mirrors Android `captureWindowOpen`.
    static func captureWindowOpen(elapsedMs: Int) -> Bool {
        elapsedMs < captureSeconds * 1000
    }
}

/// Snapshot-write constants — the metric-series key + source id the manual HRV reading banks under.
/// Kept as a tiny namespace so the source id ("manual-hrv") and key ("hrv_snapshot") are single-sourced
/// and match the Android side value-for-value.
enum HRVSnapshot {
    /// Generic metric-series key for a manual HRV reading.
    static let metricKey = "hrv_snapshot"
    /// Source id this manual reading is stored under — its own source so it sits beside WHOOP / Apple
    /// for the per-source explorer, exactly like the other manual/imported sources.
    static let sourceId = "manual-hrv"
    /// The analysis behind a spot record's RMSSD: `HRVAnalyzer.analyze` over the raw 60 s capture with the spot
    /// rejected-fraction gate. Bump when that changes, so readings from different methods are never one regime.
    static let methodVersion = "spot-rmssd-1"

    /// The spot record for a finished capture over `[start, end)`; nil when it produced no RMSSD. Its activity
    /// context is not copied in: it joins by time (`spotHrvReadingCtx`).
    static func reading(result: HRVAnalyzer.HRVResult, start: Int, end: Int, createdAt: Int) -> SpotHrvReadingRow? {
        guard let rmssd = result.rmssd, end > start else { return nil }
        return SpotHrvReadingRow(
            startTs: start, endTs: end, rmssd: rmssd, sdnn: result.sdnn, meanNN: result.meanNN,
            cleanBeats: result.nClean, inputBeats: result.nInput, source: sourceId, methodVersion: methodVersion,
            createdAt: createdAt)
    }
}
