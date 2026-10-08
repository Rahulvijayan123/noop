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
            ]),
            ("Body", [
                .push("Workouts", "figure.run") { WorkoutsView() },
                .push("Lift Log", "dumbbell") { LiftLogView() },
            ]),
            ("Learn", [
                .push("How your metrics work", "info.circle") { ScoringGuideView() },
            ]),
            ("Data", [
                .push("Apple Health", "heart") { AppleHealthView() },
                .push("Backup & Sync", "externaldrive.badge.icloud") { BackupSyncView() },
                .push("Power saving", "battery.25") { PowerSavingView() },
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

/// One row of Browse: a screen to push, or an action.
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
}
