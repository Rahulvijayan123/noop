import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandImport
import WhoopStore
import Foundation
#if canImport(MapKit)
import MapKit
#endif

// MARK: - Workout detail (#410)
//
// One session, read-only. The essentials once at the top (duration, effort, calories, distance and pace or
// steps), then the heart rate through the session on a clock axis with the user's zones shaded behind it (the
// readout above it follows the scrub), the time in each zone as bars, the recovery after the session, and
// the route when one was recorded or imported. Method notes, the source and the route's privacy line sit in
// the About at the bottom.
//
// Pushed from the Workouts list; the classic Today still presents it as a sheet, which keeps its Done.
// Every section below the statistics has a fixed frame from the first paint (the chart and the zone bars
// draw placeholders while `load()` runs), so nothing above the fold moves when the reads land.

struct WorkoutDetailView: View {
    let row: WorkoutRow
    /// How the page was opened: a sheet carries its own Done.
    var presentation: Presentation = .sheet

    enum Presentation { case sheet, pushed }

    @EnvironmentObject private var repo: Repository
    @StateObject private var profile = ProfileStore()
    @Environment(\.dismiss) private var dismiss

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.imperial.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .imperial,
            override: distanceSystemRaw)
    }

    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// Loaded HR curve over the session window (bucket means). Empty until loaded.
    @State private var hrPoints: [TrendPoint] = []
    /// Per-zone MINUTES for the zone bars: imported zones (duration-weighted) when present, else the
    /// window's raw HR samples binned into age-derived %HRmax zones. nil = no zone split to show.
    @State private var zoneMinutes: [Double]? = nil
    /// True when the zones came from imported WHOOP percentages (vs derived from raw strap HR).
    @State private var zonesFromImport = false
    @State private var loaded = false
    /// #516: computed from the recorded workout-end + post-workout HR window. nil when the workout was
    /// not intense enough or the strap did not record enough post-workout coverage.
    @State private var heartRateRecovery: HeartRateRecovery.Result?

    /// The GPS route captured for this session on-device (#524), if any. Decoded from `RouteStore` by the
    /// row's natural key. nil = no route was recorded (honest — the map only shows when points exist).
    @State private var route: [RouteMath.LatLng] = []

    /// Drives the GPX/FIT export chooser for the recorded route.
    @State private var showRouteExport = false

    /// The heart-rate sample under the finger.
    @State private var hrSelection: Date?

    /// Steps over the session window for an on-foot sport (#398): the count plus whether it came from the
    /// strap's own counter (MG/5.0) or the phone pedometer (fallback for WHOOP 4.0 / not-yet-synced / CSV
    /// import). nil = not an on-foot sport, or no step source had data for the window.
    private struct StepReadout { let count: Int; let fromStrap: Bool }
    @State private var steps: StepReadout?

    var body: some View {
        ScreenScaffold(title: "\(WorkoutSource.displaySport(row.sport))",
                       dateLine: "\(WorkoutFormat.day(row.startTs)) · \(WorkoutFormat.timeRange(row.startTs, row.endTs))",
                       titleDisplay: .navigationBar,
                       // PERF: chart/map-heavy column (the session HR curve, a MapKit route map). The
                       // LazyVStack path builds the off-screen ones on demand.
                       lazy: true) {
            StatGrid(essentials, columns: statColumns)
            heartRateSection
            zonesSection
            heartRateRecoverySection
            routeSection
            AboutDisclosure("About this workout", paragraphs: aboutParagraphs)
        }
        .toolbar {
            if presentation == .sheet {
                // A Done affordance for the sheet on both platforms (iOS gets the grabber too).
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    /// Three across on the phone too, so the essentials take two rows and the heart rate starts on the
    /// first screen; the values step down as a piece if a long one ("1 h 18 m") needs the room.
    private var statColumns: Int { 3 }

    // MARK: - Load

    private func load() async {
        // #524: the GPS route, if this session recorded one on-device. A cheap UserDefaults read keyed
        // by the row's natural key (startTs + sport); decoded to points only when ≥2 were captured so the
        // map only ever draws a real route.
        let routePoints: [RouteMath.LatLng] = {
            guard let r = RouteStore.load(startTs: row.startTs, sport: row.sport) else { return [] }
            let pts = RouteMath.decode(r.polyline)
            return pts.count >= 2 ? pts : []
        }()

        // HR curve over the exact session window — a finer bucket than the 24h chart so a short run
        // still reads as a curve, not a handful of points.
        let buckets = await repo.workoutHrBuckets(from: row.startTs, to: row.endTs, source: row.source)
        let points = buckets.map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }

        // Zones: prefer the imported per-workout percentages (a WHOOP-computed split), and only fall
        // back to deriving zone-minutes from the strap's own raw HR when the row has none — so we
        // never overwrite a real imported split with an on-device approximation.
        var minutes: [Double]?
        var fromImport = false
        if let pct = WorkoutZones.percents(row.zonesJSON) {
            let durMin = (row.durationS ?? Double(row.endTs - row.startTs)) / 60.0
            if durMin > 0 {
                minutes = pct.map { durMin * $0 / 100.0 }
                fromImport = true
            }
        }
        if minutes == nil {
            minutes = await repo.workoutZoneMinutes(from: row.startTs, to: row.endTs, zoneSet: profile.hrZoneSet,
                                                    source: row.source)
        }

        let hrr = await repo.workoutHeartRateRecovery(
            from: row.startTs, to: row.endTs, maxHR: Double(profile.hrMax), source: row.source)

        // Steps for an on-foot session (#398), computed at display time over the exact window so it
        // "fills in after sync": prefer the strap's own counter (MG/5.0) once it has offloaded the window,
        // else the phone pedometer (any strap, incl. WHOOP 4.0 / CSV-import). Never shown for non-foot
        // sports (cycling/rowing/… have no footfalls). Both sources return nil for "no data", so an empty
        // window stays "–" rather than a fabricated 0.
        var stepReadout: StepReadout? = nil
        if WorkoutCatalog.isOnFoot(row.sport) {
            if let ticks = await repo.strapStepTicks(from: row.startTs, to: row.endTs) {
                // Same per-user ticks-per-step calibration the daily total applies (#139), floor 0.5.
                let scaled = Int((Double(ticks) / max(profile.stepTicksPerStep, 0.5)).rounded())
                if scaled > 0 { stepReadout = StepReadout(count: scaled, fromStrap: true) }
            }
            if stepReadout == nil,
               let ped = await WorkoutPedometer.steps(fromSec: row.startTs, toSec: row.endTs), ped > 0 {
                stepReadout = StepReadout(count: ped, fromStrap: false)
            }
        }

        await MainActor.run {
            self.route = routePoints
            self.hrPoints = points
            self.zoneMinutes = minutes
            self.zonesFromImport = fromImport
            self.heartRateRecovery = hrr
            self.steps = stepReadout
            self.loaded = true
        }
    }

    // MARK: - Essentials

    private var essentials: [StatItem] {
        var items: [StatItem] = [
            StatItem(String(localized: "Duration"), value: WorkoutFormat.duration(seconds: row.durationS)),
        ]
        let effort = WorkoutFormat.effort(row.strain, scale: effortScale)
        items.append(StatItem(String(localized: "Effort"), value: effort?.value, detail: effort?.of))
        items.append(StatItem(String(localized: "Calories"),
                              value: row.energyKcal.map { WorkoutFormat.grouped($0) }, unit: "kcal"))
        if let m = row.distanceM, m > 0 {
            let d = WorkoutFormat.distance(meters: m, system: distanceUnitSystem)
            items.append(StatItem(String(localized: "Distance"), value: d.value, unit: d.unit))
            let pace = WorkoutFormat.pace(secPerKm: paceSecPerKm, system: distanceUnitSystem)
            items.append(StatItem(String(localized: "Avg pace"), value: pace?.value, unit: pace?.unit))
        }
        // Steps for an on-foot sport (#398). Shown for the on-foot set even before the value lands, so
        // the cell doesn't pop in; "—" until a source has data. The detail says which counter it came from.
        if WorkoutCatalog.isOnFoot(row.sport) {
            items.append(StatItem(String(localized: "Steps"),
                                  value: steps.map { WorkoutFormat.grouped(Double($0.count)) },
                                  detail: steps.map { $0.fromStrap ? String(localized: "strap") : String(localized: "phone") }))
        }
        return items
    }

    /// Avg pace from the row's distance + duration, in seconds per kilometre; nil when either is missing.
    private var paceSecPerKm: Double? {
        guard let m = row.distanceM, m > 0 else { return nil }
        let secs = row.durationS ?? Double(row.endTs - row.startTs)
        guard secs > 0 else { return nil }
        return secs / (m / 1000.0)
    }

    // MARK: - Heart rate

    /// The repository's bucket for this window (`workoutHrBuckets`), so a skipped bucket breaks the line.
    private var bucketSeconds: Int { max(15, min(300, (row.endTs - row.startTs) / 120)) }

    private var samples: [IntradayChart.Sample] {
        hrPoints.map { IntradayChart.Sample(time: $0.date, value: $0.value) }
    }

    private var sessionWindow: ClosedRange<Date> {
        let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
        let end = Date(timeIntervalSince1970: TimeInterval(max(row.endTs, row.startTs + 60)))
        return start...end
    }

    /// The user's five zones as shaded bands behind the line, labelled at the trailing edge.
    private var zoneBands: [IntradayChart.ValueBand] {
        profile.hrZoneSet.zones.map { z in
            IntradayChart.ValueBand(id: "z\(z.number)", range: z.lower...max(z.upper, z.lower + 1),
                                    color: StrandPalette.hrZoneColor(z.number), label: "Z\(z.number)")
        }
    }

    private var heartRateSection: some View {
        let samples = self.samples
        let avg = row.avgHr.map(Double.init)
            ?? (samples.isEmpty ? nil : samples.map(\.value).reduce(0, +) / Double(samples.count))
        let peak = row.maxHr ?? samples.map(\.value).max().map { Int($0.rounded()) }
        let content: ReadoutContent
        if let hrSelection, let sample = ChartSelection.sample(for: hrSelection, in: samples) {
            let zone = profile.hrZoneSet.zoneNumber(forBPM: sample.value)
            content = .intraday(sample, unit: "bpm", format: { "\(Int($0.rounded()))" },
                                context: zone >= 1 ? String(localized: "Zone \(zone) · \(LiveWorkoutView.zoneName(zone))")
                                                   : String(localized: "Below Zone 1"))
        } else {
            content = ReadoutContent(dateLine: WorkoutFormat.timeRange(row.startTs, row.endTs),
                                     value: avg.map { "\(Int($0.rounded()))" }, unit: "bpm",
                                     context: peak.map { String(localized: "Average · Max HR \($0) bpm") }
                                        ?? String(localized: "Average"))
        }
        let state: ChartState = !loaded ? .loading
            : (samples.count > 1 ? .ready : .empty(String(localized: "No heart rate recorded")))
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Heart rate")
            ValueReadout(content, isScrubbing: hrSelection != nil, isLoading: !loaded && row.avgHr == nil)
            NoopCard {
                // No average rule: the readout above carries the average, and a rule's label would sit on
                // the zone labels at the trailing edge.
                IntradayChart(samples: samples, bucketSeconds: bucketSeconds,
                              valueBands: zoneBands,
                              legend: [], state: state, window: sessionWindow,
                              y: ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 40)),
                              selection: $hrSelection,
                              accessibilityTitle: String(localized: "Heart rate during \(WorkoutSource.displaySport(row.sport))"))
            }
        }
    }

    /// #18: whether the displayed Avg HR was edited away from what this HR trace implies. True only when the
    /// row carries CAPTURED strain or zones (so the graph/zones/Effort are from a real recording, not the
    /// typed value) AND the row's avgHr differs from the trace mean by more than a small tolerance. The
    /// tolerance absorbs ordinary rounding/bucketing drift so an unedited session never trips the note.
    private func avgHrEditedDisclosure(traceMean: Double) -> Bool {
        guard let avg = row.avgHr, row.strain != nil || row.zonesJSON != nil else { return false }
        return abs(Double(avg) - traceMean) > 3
    }

    // MARK: - Zones

    @ViewBuilder private var zonesSection: some View {
        if !loaded || (zoneMinutes?.reduce(0, +) ?? 0) > 0 {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Time in zones",
                              trailing: !loaded ? nil
                                : (zonesFromImport ? String(localized: "Whoop import") : String(localized: "Estimate")))
                NoopCard {
                    WorkoutZoneBars(minutes: zoneMinutes ?? [], ranges: zonesFromImport ? [] : zoneRanges,
                                    isLoading: !loaded)
                }
            }
        }
    }

    /// "120–138" per zone from the user's own zone set (the one the strap-derived minutes use).
    private var zoneRanges: [String?] {
        profile.hrZoneSet.zones.sorted { $0.number < $1.number }.map { "\(Int($0.lower))–\(Int($0.upper)) bpm" }
    }

    // MARK: - Heart-rate recovery (#516)

    @ViewBuilder private var heartRateRecoverySection: some View {
        if let recovery = heartRateRecovery {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Heart rate recovery", trailing: String(localized: "Peak \(recovery.endHR) bpm"))
                StatGrid([
                    StatItem(String(localized: "1 min"), value: recovery.after1Minute.map { "\($0)" }, unit: "bpm"),
                    StatItem(String(localized: "2 min"), value: recovery.after2Minutes.map { "\($0)" }, unit: "bpm"),
                    StatItem(String(localized: "5 min"), value: recovery.after5Minutes.map { "\($0)" }, unit: "bpm"),
                ], columns: 3)
            }
        }
    }

    // MARK: - GPS route (#524)

    /// The captured-route card: a MapKit map of the polyline with start/end markers. Shown ONLY when ≥2
    /// points were captured — honest "no map" otherwise (a Mac with no GPS, denied permission, or a
    /// non-distance sport never produce a route). Distance and pace are in the statistics above.
    @ViewBuilder private var routeSection: some View {
        if route.count >= 2 {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Route", trailing: routeOriginLabel)
                NoopCard(padding: 0) {
                    WorkoutRouteMap(points: route)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
                        .accessibilityLabel(routeAccessibilityLabel)
                }
                Button {
                    showRouteExport = true
                } label: {
                    Label("Export route", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                .confirmationDialog("Export route", isPresented: $showRouteExport, titleVisibility: .visible) {
                    Button("GPX — Strava, Garmin, most apps") { exportRoute(.gpx) }
                    Button("FIT — Garmin Connect") { exportRoute(.fit) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Save this route as a standard file you can import into Strava, Garmin Connect, and other apps.")
                }
            }
        }
    }

    /// Write the route to a GPX/FIT file and hand it to the system share sheet (or a Save panel on macOS).
    /// Points are decoded lat/lon only (the stored polyline), so the exporter interpolates per-point times
    /// across the session window and carries the workout's summary (sport, distance, calories, HR).
    ///
    /// The build + disk write run OFF the main actor (a long route is a non-trivial encode, and blocking
    /// file IO must never stall the UI); only the share-sheet present hops back to the main actor.
    @MainActor private func exportRoute(_ format: RouteExporter.Format) {
        guard route.count >= 2 else { return }
        let points = route.map { RoutePoint(lat: $0.lat, lon: $0.lon) }
        // Name the file by the workout's start (not export time) so it's stable + matches the Android twin.
        let name = "noop-route-\(row.startTs).\(format.ext)"
        let startTs = row.startTs, endTs = row.endTs, sport = row.sport
        let distanceM = row.distanceM, energyKcal = row.energyKcal, avgHr = row.avgHr, maxHr = row.maxHr
        Task.detached(priority: .userInitiated) {
            let data = RouteExporter.render(
                format, route: points, startTs: startTs, endTs: endTs, sport: sport,
                distanceM: distanceM, energyKcal: energyKcal, avgHr: avgHr, maxHr: maxHr)
            let url = NoopScratch.file(name)
            do { try data.write(to: url) } catch { return }
            await MainActor.run { FileExport.exportFile(at: url, suggestedName: name) }
        }
    }

    private var routeAccessibilityLabel: String {
        let dist = row.distanceM.map { UnitFormatter.distanceFromMeters($0, system: distanceUnitSystem) } ?? "–"
        return String(localized: "Map of your \(WorkoutSource.displaySport(row.sport)) route, \(dist).")
    }

    /// #1205: the route section must be honest about where the route came from. An on-device recorded route
    /// says "Recorded on device"; an imported route (Apple Health or Health Connect) says "Imported" so the
    /// user is not told their phone recorded GPS data that actually came from another app.
    private var routeOriginLabel: String {
        switch WorkoutSource.classify(row.source) {
        // "Imported" rather than naming the app: every string here is one the catalog already carries in
        // all nine locales, so the honesty fix ships translated on day one.
        case .apple, .whoop, .lifting, .activityFile: return String(localized: "Imported")
        case .detected, .manual: return String(localized: "Recorded on device")
        }
    }

    private var routeDescription: String {
        switch WorkoutSource.classify(row.source) {
        // Same rule as the label: both of these are existing catalog keys with all nine locales. The
        // imported line carries the privacy claim without the "recorded on your device" the original
        // string opens with, which is the part that was untrue for a route another app collected.
        case .apple, .whoop, .lifting, .activityFile:
            return String(localized: "This stays on your device. It is never uploaded, never synced, never shared.")
        case .detected, .manual:
            return String(localized: "Your GPS route for this session, recorded and stored on your device. Nothing leaves your phone.")
        }
    }

    // MARK: - About

    private var aboutParagraphs: [String] {
        var out: [String] = [String(localized: "Source: \(WorkoutFormat.source(row.source))")]
        if row.strain != nil {
            out.append(String(localized: "This session's contribution to the day's Effort, as captured during the workout."))
        }
        // #18: the row's Avg HR can be EDITED on the manual sheet while the graph, zones and Effort stay
        // from the recorded session (preservingCaptured keeps the captured strain/zones). Say so plainly;
        // nothing is re-scored from the typed number.
        if !hrPoints.isEmpty,
           avgHrEditedDisclosure(traceMean: hrPoints.map(\.value).reduce(0, +) / Double(hrPoints.count)) {
            out.append(String(localized: "The average above was edited. The graph, zones and Effort stay from the recorded session."))
        }
        if zoneMinutes != nil {
            out.append(zonesFromImport
                       ? String(localized: "WHOOP's imported per-zone split for this session.")
                       : String(localized: "Time in each %HRmax zone, derived from the strap's heart rate over this window (approximate)."))
        }
        if heartRateRecovery != nil {
            out.append(String(localized: "The change from your heart rate at the end of exercise. Positive values mean your heart rate fell; a dash means the strap did not record enough data around that minute."))
        }
        if route.count >= 2 { out.append(routeDescription) }
        return out
    }
}

// MARK: - Route map (#524)
//
// A MapKit map of the captured route polyline, drawn with start + end markers — the Apple analogue of
// Android's `RouteCanvas`, but on real map tiles. Built as a platform-bridged representable around
// `MKMapView` so it runs on BOTH iOS 17 and macOS 13 (SwiftUI's newer `Map { MapPolyline }` needs iOS 17 /
// macOS 14, and the macOS deployment target is 13). The map is offline-capable: MapKit caches tiles locally
// and the route itself is on-device — NOOP never sends the route anywhere.

#if canImport(MapKit) && canImport(UIKit)
import UIKit
typealias RouteMapRepresentable = UIViewRepresentable
#elseif canImport(MapKit) && canImport(AppKit)
import AppKit
typealias RouteMapRepresentable = NSViewRepresentable
#endif

#if canImport(MapKit)
struct WorkoutRouteMap: RouteMapRepresentable {
    let points: [RouteMath.LatLng]

    private var coordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeMap(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsUserLocation = false
        configure(map)
        return map
    }

    /// Draw the polyline + start/end pins and frame the route. Replaces any existing overlays so a
    /// re-render doesn't stack them.
    private func configure(_ map: MKMapView) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        let coords = coordinates
        guard coords.count >= 2 else { return }
        let line = MKPolyline(coordinates: coords, count: coords.count)
        map.addOverlay(line)

        let start = MKPointAnnotation(); start.coordinate = coords.first!; start.title = String(localized: "Start")
        let end = MKPointAnnotation(); end.coordinate = coords.last!; end.title = String(localized: "Finish")
        map.addAnnotations([start, end])

        // Frame the whole route with a little padding so the line isn't flush to the edges.
        let rect = line.boundingMapRect
        let inset = UIEdgeInsetsLikePadding
        map.setVisibleMapRect(rect, edgePadding: inset, animated: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            // The palette's Effort colour, resolved per appearance (the renderer needs a platform colour).
            r.strokeColor = RoutePlatformColor.effort
            r.lineWidth = 4
            r.lineJoin = .round
            r.lineCap = .round
            return r
        }
    }

    #if canImport(UIKit)
    private var UIEdgeInsetsLikePadding: UIEdgeInsets { UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24) }
    func makeUIView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateUIView(_ map: MKMapView, context: Context) { configure(map) }
    #elseif canImport(AppKit)
    private var UIEdgeInsetsLikePadding: NSEdgeInsets { NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24) }
    func makeNSView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateNSView(_ map: MKMapView, context: Context) { configure(map) }
    #endif
}

/// The route stroke colour as a platform colour (MapKit's renderer can't take a SwiftUI `Color`): the
/// palette's Effort colour, so the line matches the rest of the app in both appearances.
private enum RoutePlatformColor {
    #if canImport(UIKit)
    static var effort: UIColor { UIColor(StrandPalette.effortColor) }
    #elseif canImport(AppKit)
    static var effort: NSColor { NSColor(StrandPalette.effortColor) }
    #endif
}
#else
/// Platforms without MapKit (none we ship, but keeps the type resolvable): no route map.
struct WorkoutRouteMap: View {
    let points: [RouteMath.LatLng]
    var body: some View { Color.clear }
}
#endif

#if DEBUG
#Preview("Workout Detail") {
    NavigationStack {
        WorkoutDetailView(row: WorkoutRow(
            startTs: Int(Date().timeIntervalSince1970) - 3600,
            endTs: Int(Date().timeIntervalSince1970),
            sport: "Running", source: "whoop", durationS: 3600, energyKcal: 712,
            avgHr: 152, maxHr: 178, strain: 14.2, distanceM: 10_400,
            zonesJSON: #"{"z1":12.5,"z2":28.0,"z3":33.5,"z4":18.0,"z5":6.0}"#, notes: nil, steps: nil),
            presentation: .pushed)
            .environmentObject(Repository(deviceId: "preview"))
    }
}
#endif
