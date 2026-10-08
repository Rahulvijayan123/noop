import SwiftUI
import StrandDesign

// MARK: - Browse
//
// Every screen that has no tab of its own, in one grouped list: since the iPhone More tab went, these were
// reachable only from the Mac sidebar or a deep link. Reached from Today's "Browse" footer action
// (`TabRoute.browse`, the first hop, so a re-tap of the Today tab pops back). The rows are second hops, so
// they push with closure links. Each destination is the existing screen, presented the way it was when the
// More list pushed it; nothing here reads or computes data.

struct BrowseView: View {
    /// The Live session runs full screen (the guardian owns the display), as it did from Today before.
    @State private var showsLiveSession = false
    #if DEBUG
    /// `--demo-browse-open N`: the Nth row (counting down the whole list from 0) opened at launch, so a
    /// simulator screenshot can check that every destination opens.
    @State private var demoEntry: BrowseEntry?
    #endif

    private var groups: [(title: LocalizedStringKey, entries: [BrowseEntry])] {
        [
            ("Metrics", [
                .push("Health", "heart.text.square") { HealthView() },
                .push("Trends", "chart.xyaxis.line") { TrendsView() },
                .push("Explore", "square.grid.2x2") { MetricExplorerView() },
                .push("Compare", "chart.line.uptrend.xyaxis") { CompareView() },
                .push("Week in review", "calendar") { WeeklyDigestView() },
                .push("Hydration", "drop") { HydrationView() },
            ]),
            ("Body", [
                .push("Workouts", "figure.run") { WorkoutsView() },
                .push("Lift Log", "dumbbell") { LiftLogView() },
                .push("Live", "waveform.path.ecg") { LiveView() },
                .action("Live session", "shield.lefthalf.filled") { showsLiveSession = true },
                .push("Stress", "gauge.with.dots.needle.50percent") { StressView() },
                .push("Breathe", "wind") { BreathingView() },
                .push("Intervals", "timer") { IntervalTimerView() },
                .push("Rhythm", "waveform.path") { RhythmHost() },
            ]),
            ("Insights", [
                .push("Insights", "lightbulb") { InsightsView() },
                .push("What Moves You", "wand.and.sparkles") { InsightsHubView() },
                .push("Intelligence", "brain.head.profile") { IntelligenceView() },
                .push("Lab Book", "books.vertical") { LabBookView() },
                .push("Coupled view", "rectangle.split.3x1") { CoupledView() },
                .push("How your scores work", "info.circle") { ScoringGuideView() },
            ]),
            ("Data", [
                .push("Data sources", "square.and.arrow.down") { DataSourcesView() },
                .push("Your Data, Fused", "square.stack.3d.up") { FusedRecordHost() },
                .push("Apple Health", "heart") { AppleHealthView() },
                .push("Mi Band", "figure.walk.motion") { XiaomiBandView() },
                .push("Backup & Sync", "externaldrive.badge.icloud") { BackupSyncView() },
                .push("Power saving", "battery.25") { PowerSavingView() },
                .push("Nara Limitations", "list.bullet.rectangle") { NoopLimitationsView() },
                .push("Updates", "bell") { UpdatesInboxView() },
            ]),
        ]
    }

    var body: some View {
        ScreenScaffold(title: "Browse", titleDisplay: .navigationBar) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                NoopListSection(group.title) {
                    BrowseRows(entries: group.entries)
                }
            }
        }
        .browseLiveSessionPresentation(isPresented: $showsLiveSession)
        #if DEBUG
        .navigationDestination(isPresented: Binding(get: { demoEntry != nil },
                                                    set: { if !$0 { demoEntry = nil } })) {
            if case .push(let destination)? = demoEntry?.kind {
                destination().browsePushChrome()
            }
        }
        .task {
            guard let index = DemoLaunch.intArg("--demo-browse-open") else { return }
            let all = groups.flatMap(\.entries)
            guard all.indices.contains(index) else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            switch all[index].kind {
            case .push: demoEntry = all[index]
            case .action(let perform): perform()
            }
        }
        #endif
    }
}

/// One row of Browse: a screen to push, or (the Live session) an action.
private struct BrowseEntry: Identifiable {
    enum Kind {
        case push(() -> AnyView)
        case action(() -> Void)
    }

    let title: LocalizedStringKey
    let icon: String
    let kind: Kind
    /// The icon names are unique across the list, so they double as the row identity.
    var id: String { icon }

    static func push<V: View>(_ title: LocalizedStringKey, _ icon: String,
                              @ViewBuilder _ destination: @escaping () -> V) -> BrowseEntry {
        BrowseEntry(title: title, icon: icon, kind: .push { AnyView(destination()) })
    }

    static func action(_ title: LocalizedStringKey, _ icon: String,
                       _ perform: @escaping () -> Void) -> BrowseEntry {
        BrowseEntry(title: title, icon: icon, kind: .action(perform))
    }
}

/// The rows of one Browse group, separated by hairlines that line up with the titles.
private struct BrowseRows: View {
    let entries: [BrowseEntry]

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
            switch entry.kind {
            case .push(let destination):
                NavigationLink {
                    destination().browsePushChrome()
                } label: {
                    NoopListRow(icon: entry.icon, title: entry.title)
                }
                .buttonStyle(.plain)
            case .action(let perform):
                Button(action: perform) {
                    NoopListRow(icon: entry.icon, title: entry.title)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private extension View {
    /// The chrome the More list gave every pushed screen: the flat canvas behind it, an inline title bar,
    /// and no bar background (#1027), so a screen's own header is not clipped by an opaque band on scroll.
    @ViewBuilder func browsePushChrome() -> some View {
        #if os(iOS)
        self.background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        #else
        self.background(StrandPalette.surfaceBase)
        #endif
    }

    /// The Live session: a full-screen cover on iPhone (the guardian owns the display mid-workout), a sheet
    /// on the Mac, where `fullScreenCover` does not exist. The session view ends itself through `onClose`.
    @ViewBuilder func browseLiveSessionPresentation(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #else
        self.sheet(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #endif
    }
}
