import SwiftUI
import StrandDesign

// MARK: - Monitor links
//
// The Monitor root's first-hop links push `TabRoute` VALUES on iPhone, so a re-tap of the Monitor tab
// pops them (the tab's NavigationPath only tracks value pushes). The Mac shows the Monitor in an engine
// sheet whose NavigationStack registers no `tabRouteDestinations()`, so there the same links build their
// destination in place. Both resolve to the same screens.

/// A link to one of the Monitor area's pages.
struct MonitorLink<Label: View>: View {
    let route: TabRoute
    @ViewBuilder var label: () -> Label

    var body: some View {
        #if os(macOS)
        NavigationLink { MonitorRouteDestination(route: route) } label: { label() }
        #else
        NavigationLink(value: route) { label() }
        #endif
    }
}

/// The Monitor area's pages by route, for the Mac's in-place links. Mirrors `tabRouteDestinations()`.
struct MonitorRouteDestination: View {
    let route: TabRoute

    var body: some View {
        switch route {
        case .watchdog: WatchdogPage()
        case .baselineCharts: BaselineVitalPage()
        case .baselineVital(let raw): BaselineVitalPage(seriesRaw: raw)
        case .pipelineDiagnostics: PipelineDiagnosticsView()
        default: EmptyView()
        }
    }
}

extension SectionHeaderAction {
    /// A section header's "See all" to one of the Monitor area's pages (see `MonitorLink`).
    static func monitorLink(label: LocalizedStringKey, route: TabRoute) -> SectionHeaderAction {
        #if os(macOS)
        .link(label: label) { MonitorRouteDestination(route: route) }
        #else
        .link(label: label, value: route)
        #endif
    }
}
