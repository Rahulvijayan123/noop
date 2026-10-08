import SwiftUI

/// A first-hop link from the Sleep tab.
///
/// iPhone: a `TabRoute` VALUE push, so the tab's `NavigationPath` tracks it and re-tapping the Sleep tab
/// pops back to the root (#198). The Mac's Sleep pane has no stack that registers `tabRouteDestinations()`
/// (and this file cannot add one), so there the same route resolves to its destination in place, the way
/// the Sleep tab's links always pushed there.
struct SleepRouteLink<Label: View>: View {
    let route: TabRoute
    @ViewBuilder let label: () -> Label

    var body: some View {
        #if os(iOS)
        NavigationLink(value: route) { label() }
        #else
        NavigationLink { Self.destination(route) } label: { label() }
        #endif
    }

    /// The routes the Sleep tab links to, resolved the way `tabRouteDestinations()` resolves them.
    @ViewBuilder
    static func destination(_ route: TabRoute) -> some View {
        switch route {
        case .sleepNight(let wakeDay):
            SleepNightDetailView(wakeDay: wakeDay)
        case .metricSourced(let key, let source):
            if let m = MetricCatalog.metric(key: key, source: source)
                ?? MetricCatalog.all.first(where: { $0.key == key }) {
                MetricDetailView(metric: m)
            } else {
                HealthView()
            }
        case .dataSources:
            DataSourcesView()
        default:
            EmptyView()
        }
    }
}
