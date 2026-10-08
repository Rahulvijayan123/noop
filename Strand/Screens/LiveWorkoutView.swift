import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import WhoopProtocol

/// Live workout mode (#238) — the in-exercise screen: elapsed time, the live heart rate with its zone, the
/// session's heart rate so far with the zones behind it, the time spent in each zone, and the live effort,
/// all from the SAME live feed and scorers the rest of the app uses (no invented numbers). Presented while a
/// manual workout is active, entered from the Start-workout control on Live or Workouts.
///
/// Live HR is the smoothed `AppModel.bpm`; the zone is derived from the user's HR-max via the shared
/// `HRZones` model; elapsed time ticks from the workout's start (a TimelineView, no manual Timer);
/// effort is the running `ActiveWorkout.liveStrain` (StrainScorer over the captured window).
struct LiveWorkoutView: View {
    @EnvironmentObject private var model: AppModel
    // PERF (scroll/recompose): this screen deliberately does NOT observe `LiveState` directly. A connected
    // strap publishes `LiveState` ~1 Hz (HR + each R-R packet, plus sensor frames), and an
    // `@EnvironmentObject live` here would invalidate the WHOLE body on every tick even though it reads from
    // `model` (smoothed bpm + scorers), not `live`. The only region that genuinely needs `live` is the
    // additive sensor readout (speed / cadence / power), so it's extracted into the small
    // `SensorRowIfPresent` leaf below that owns its OWN `@EnvironmentObject live`. The session chart and the
    // time-in-zone bars are another leaf (`LiveWorkoutCharts`) that takes a snapshot of the samples every
    // two seconds, so neither re-aggregates on every published tick.
    let onClose: () -> Void

    /// Effort display scale (#268) — routes the live Effort read-out through the shared helper so it
    /// matches every other surface. Display-only; the captured value stays stored 0–100.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// Keep the screen awake while recording (#703). Opt-in, default off; the toggle lives in Settings.
    /// Read here so we can hold the idle timer off only while this in-exercise screen is up and release it
    /// the moment it leaves, which is exactly the bounded usage Apple asks for. iOS-only (no-op on Mac).
    @AppStorage("workoutKeepScreenOn") private var keepScreenOn = false

    /// Guards the destructive End action behind a confirm (#517) — a stray tap must not end the workout
    /// instantly with no way back.
    @State private var showEndConfirm = false
    @State private var showDeleteConfirm = false

    private var zoneSet: HRZoneSet { model.profile.hrZoneSet }
    private var zone: Int { model.bpm.map { zoneSet.zoneNumber(forBPM: Double($0)) } ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                header
                clock
                heartRate
                // A leaf that snapshots the samples itself (see the PERF note above).
                LiveWorkoutCharts(model: model).equatable()
                statsGrid
                // Live GPS distance + pace (#1195) — a self-gating leaf owning its own recorder observation,
                // so a GPS fix re-renders only this card. Renders nothing until the first accepted fix, so
                // non-GPS / denied sessions leave the stack unchanged. It sits below everything that is
                // always there, so its arrival never pushes the clock or the heart rate.
                DistancePaceRowIfPresent(recorder: model.gpsRecorder)
                // Live-observing leaf: renders the sensor row only when a standard fitness sensor is feeding
                // metrics, refreshing on its own packets without re-rendering the readouts above.
                SensorRowIfPresent()
            }
            .screenPadding()
            .padding(.vertical, NoopMetrics.space6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        // #697/#horizontal-swipe parity, see ScreenScaffold. This is the full-screen in-exercise
        // tracker, up for the whole workout, so worth the same defensive fix.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        // The controls sit in the bottom safe area so the scroll content never owns them.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controlBar
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        // If the workout ended elsewhere (process restart cleared it), close the screen.
        .onChangeCompat(of: model.activeWorkout == nil) { gone in if gone { onClose() } }
        // Arm the realtime HR stream while the in-exercise screen is up (#681). On a WHOOP 5/MG live HR
        // only flows while the puffin realtime stream is armed; previously only the Live tab armed it, so
        // starting a manual workout straight from Workouts (Live never opened) left `model.bpm == nil` —
        // captureWorkoutSample bailed on every sample and endWorkout silently discarded the empty
        // session. Ref-counted in AppModel, so when this sheet sits over an already-armed Live tab the
        // two balance and neither disarms the other (mirrors Android LiveWorkoutScreen's DisposableEffect
        // requestRealtimeHr/releaseRealtimeHr). Balanced: one start on appear, one stop on disappear.
        .onAppear {
            model.startRealtimeHR()
            // Hold the display awake for the session only if the user opted in (#703).
            if keepScreenOn { ScreenIdle.keepAwake(true) }
        }
        .onDisappear {
            model.stopRealtimeHR()
            // Always release on the way out so the system idle timer resumes. Even if the toggle was
            // flipped off mid-workout, this clears any hold we placed.
            ScreenIdle.keepAwake(false)
        }
        // Confirm before ending (#517): ending still requires an explicit confirm so a stray tap cannot
        // discard the in-progress recording with no way back.
        .alert("End this workout?",
               isPresented: $showEndConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("End", role: .destructive) {
                model.endWorkout()
                onClose()
            }
        } message: {
            Text("This stops recording and saves what's captured so far. It can't be resumed.")
        }
        .confirmationDialog("Delete", isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.discardWorkout()
                onClose()
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Readouts

    private var header: some View {
        let paused = model.activeWorkout?.isPaused == true
        return HStack(alignment: .center, spacing: NoopMetrics.space3) {
            Text(WorkoutSource.displaySport(model.activeWorkout?.sport ?? WorkoutCatalog.defaultSportName))
                .font(StrandFont.title1)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            // Recording is a genuinely live state, so its dot may pulse; paused is still.
            StatePill(paused ? "Paused" : "Recording workout", tone: paused ? .neutral : .critical,
                      pulsing: !paused)
        }
    }

    /// The one clock on the screen (the bottom bar carries only controls).
    private var clock: some View {
        Group {
            if let workout = model.activeWorkout {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    ValueReadout(ReadoutContent(dateLine: String(localized: "Time"),
                                                value: Self.elapsed(seconds: workout.elapsed()), unit: nil))
                }
            }
        }
    }

    /// The live heart rate with its zone, named and bounded, on the context line.
    private var heartRate: some View {
        let band = zoneSet.zones.first(where: { $0.number == zone })
        let zoneLine: String = {
            guard zone >= 1, let band else { return String(localized: "Below Zone 1") }
            return "\(String(localized: "Zone \(zone) · \(Self.zoneName(zone))")) · \(Int(band.lower))–\(Int(band.upper)) bpm"
        }()
        return ValueReadout(ReadoutContent(dateLine: String(localized: "Heart rate"),
                                           value: model.bpm.map { "\($0)" }, unit: "bpm",
                                           context: model.bpm == nil ? nil : zoneLine))
    }

    /// Average, peak and effort so far. Effort carries its state word ("Moderate") below the value.
    private var statsGrid: some View {
        let w = model.activeWorkout
        let strain = w?.liveStrain ?? 0
        let displayEffort = UnitFormatter.effortValue(strain, scale: effortScale)
        let maxValue = effortScale == .whoop ? 21.0 : 100.0
        let fraction = min(max(displayEffort / maxValue, 0), 1)
        return StatGrid([
            StatItem(String(localized: "Avg HR"), value: (w?.avgHr ?? 0) > 0 ? "\(w!.avgHr)" : nil, unit: "bpm"),
            StatItem(String(localized: "Peak"), value: (w?.peakHr ?? 0) > 0 ? "\(w!.peakHr)" : nil, unit: "bpm"),
            StatItem(String(localized: "Effort"), value: UnitFormatter.effortDisplay(strain, scale: effortScale),
                     detail: StrainGauge.stateLabel(forFraction: fraction)),
        ], columns: 3)
    }

    // MARK: - Bottom controls

    /// More (delete) · Pause/Resume · End. Delete sits behind the menu so the destructive action is never
    /// the neighbour of the routine one (#1533's two circles on the left made exactly that adjacency).
    private var controlBar: some View {
        let paused = model.activeWorkout?.isPaused == true
        return HStack(spacing: NoopMetrics.space2) {
            Menu {
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(StrandFont.icon(.row))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: NoopMetrics.controlHeight, height: NoopMetrics.controlHeight)
                    .background(NoopInsetSurface(cornerRadius: NoopMetrics.pillRadius))
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("More"))
            NoopButton(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill",
                       kind: .secondary, fullWidth: true) {
                model.toggleWorkoutPause()
            }
            .accessibilityLabel(Text(paused ? "Resume" : "Pause"))
            NoopButton("End", systemImage: "stop.fill", kind: .primary, fullWidth: true) {
                showEndConfirm = true
            }
            .accessibilityLabel(Text("End workout"))
            .accessibilityHint(Text("Stops recording and saves what's captured so far"))
        }
        .padding(NoopMetrics.space2)
        .background(NoopPanelSurface(cornerRadius: NoopMetrics.cardRadius, elevated: true))
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.top, NoopMetrics.space2)
        .padding(.bottom, NoopMetrics.space3)
    }

    // MARK: - Helpers

    /// Delegates to the shared clock. This carried its own `%d:%02d` with NO hour roll-over, so a
    /// 90-minute session read "90:00" here while Android's live workout screen read "1:30:00" — and,
    /// after the card fix, while the iOS card that opens THIS screen read "1:30:00" too. The math was
    /// already pause-aware (`workout.elapsed()`); only the formatting was the odd one out.
    private static func elapsed(seconds: TimeInterval) -> String {
        ActiveWorkoutClock.clock(Int(seconds))
    }

    static func zoneName(_ zone: Int) -> String {
        switch zone {
        case 1: return String(localized: "Recovery")
        case 2: return String(localized: "Fat burn")
        case 3: return String(localized: "Aerobic")
        case 4: return String(localized: "Threshold")
        case 5: return String(localized: "Maximum")
        default: return ""
        }
    }
}

// MARK: - Session chart and time in zones (throttled leaf)

/// The session's heart rate so far, with the zones shaded behind it, and the minutes spent in each zone.
///
/// Takes a snapshot of `activeWorkout.samples` every two seconds instead of observing the model, so the
/// 1 Hz publish that re-renders the readouts never re-aggregates an hour of samples. `Equatable` on the model
/// reference keeps SwiftUI from rebuilding it when the parent re-renders.
private struct LiveWorkoutCharts: View, Equatable {
    let model: AppModel

    @State private var samples: [HRSample] = []
    @State private var start: Date = Date()
    @State private var now: Date = Date()
    @State private var selection: Date?

    static func == (lhs: LiveWorkoutCharts, rhs: LiveWorkoutCharts) -> Bool { lhs.model === rhs.model }

    var body: some View {
        let zoneSet = model.profile.hrZoneSet
        let points = samples.map { IntradayChart.Sample(time: Date(timeIntervalSince1970: TimeInterval($0.ts)),
                                                        value: Double($0.bpm)) }
        let minutes = Self.zoneMinutes(samples, zoneSet: zoneSet)
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            NoopCard {
                IntradayChart(samples: points, bucketSeconds: 5,
                              valueBands: Self.zoneBands(zoneSet),
                              live: true, legend: [],
                              state: points.isEmpty ? .empty(String(localized: "Waiting for heart rate")) : .ready,
                              window: start...max(now, start.addingTimeInterval(60)),
                              y: ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 40)),
                              selection: $selection, height: NoopMetrics.chartHeightSecondary,
                              accessibilityTitle: String(localized: "Heart rate this workout"))
            }
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Time in zones")
                NoopCard { WorkoutZoneBars(minutes: minutes) }
            }
        }
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func refresh() {
        guard let w = model.activeWorkout else { return }
        samples = w.samples
        start = w.start
        now = Date()
    }

    static func zoneBands(_ zoneSet: HRZoneSet) -> [IntradayChart.ValueBand] {
        zoneSet.zones.map { z in
            IntradayChart.ValueBand(id: "z\(z.number)", range: z.lower...max(z.upper, z.lower + 1),
                                    color: StrandPalette.hrZoneColor(z.number), label: "Z\(z.number)")
        }
    }

    /// Minutes in each zone from the live samples: each sample counts for the gap to the next one, capped at
    /// five seconds so a dropout is not credited to whatever zone came before it. Display only.
    static func zoneMinutes(_ samples: [HRSample], zoneSet: HRZoneSet) -> [Double] {
        var seconds = [Double](repeating: 0, count: 5)
        for (i, s) in samples.enumerated() {
            let z = zoneSet.zoneNumber(forBPM: Double(s.bpm))
            guard (1...5).contains(z) else { continue }
            let next = i + 1 < samples.count ? samples[i + 1].ts : s.ts + 1
            seconds[z - 1] += Double(min(max(next - s.ts, 1), 5))
        }
        return seconds.map { $0 / 60 }
    }
}

// MARK: - Live-observing leaf (scroll-stutter isolation)

/// Additive readout for a connected standard fitness sensor (a footpod / bike speed-cadence sensor /
/// power meter) feeding RSC/CSC/CPS ALONGSIDE heart rate. Only the fields the sensor actually sent
/// render — each metric is dropped when its value is absent, and the WHOLE block is hidden when nothing is
/// present (`live.hasSensorMetrics`), so a plain HR-only workout looks exactly as before. Speed follows the
/// exercise-distance preference; cadence stays per-minute and power in watts. Nothing here touches HR /
/// zone / effort.
///
/// This is a standalone leaf that owns its OWN `@EnvironmentObject live` (the parent `LiveWorkoutView`
/// no longer observes `LiveState`), so an incoming sensor / R-R packet re-renders only this row.
private struct SensorRowIfPresent: View {
    @EnvironmentObject private var live: LiveState
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
            override: distanceSystemRaw)
    }

    var body: some View {
        if live.hasSensorMetrics {
            let items = sensorItems
            if !items.isEmpty { StatGrid(items, columns: items.count) }
        }
    }

    private var sensorItems: [StatItem] {
        let speed = UnitFormatter.speedFromKilometersPerHour(live.sensorSpeedKmh, system: distanceUnitSystem)
        let cadence = LiveState.formatCadence(live.sensorCadence)
        let power = LiveState.formatPowerWatts(live.sensorPowerWatts)
        var items: [StatItem] = []
        if let speed {
            let parts = speed.split(separator: " ", maxSplits: 1).map(String.init)
            items.append(StatItem(String(localized: "Speed"), value: parts.first, unit: parts.count > 1 ? parts[1] : nil))
        }
        if let cadence { items.append(StatItem(String(localized: "Cadence"), value: "\(cadence)", unit: "/min")) }
        if let power { items.append(StatItem(String(localized: "Power"), value: "\(power)", unit: "W")) }
        return items
    }
}

/// Live GPS distance + average pace on the active-workout screen, for distance sports (#1195). The main
/// gap this closes: the recorder already computes and publishes `distanceM` / `paceSecPerKm` on every
/// accepted fix, but they were only ever shown in the post-workout detail view — never live.
///
/// A standalone leaf that owns its OWN `@ObservedObject` on the recorder (the parent `LiveWorkoutView`
/// does not observe it), so a GPS fix re-renders only this card — the same scroll-stutter isolation as
/// `SensorRowIfPresent`. Self-gates to nothing until the first accepted fix, so a denied-permission or
/// GPS-less (Mac) session shows no empty card. Mirrors Android's gated distance/pace row.
private struct DistancePaceRowIfPresent: View {
    @ObservedObject var recorder: GpsWorkoutRecorder
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
            override: distanceSystemRaw)
    }

    var body: some View {
        // `isRecording` is essential, not just `pointCount > 0`: the recorder is a single long-lived
        // object and `stop()` leaves `pointCount`/`distanceM` intact (only `start()` resets them, and it
        // runs solely for distance sports). Without the `isRecording` guard a non-GPS workout started
        // after a GPS one would show the previous session's stale distance. Together they mean "a GPS
        // recording is live AND has at least one accepted fix" — the Android `gpsEnabled && track` twin.
        if recorder.isRecording, recorder.pointCount > 0 {
            let d = WorkoutFormat.distance(meters: recorder.distanceM, system: distanceUnitSystem)
            let pace = WorkoutFormat.pace(secPerKm: recorder.paceSecPerKm, system: distanceUnitSystem)
            StatGrid([
                StatItem(String(localized: "Distance"), value: d.value, unit: d.unit),
                StatItem(String(localized: "Pace"), value: pace?.value, unit: pace?.unit),
            ], columns: 2)
        }
    }
}
