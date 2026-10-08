import SwiftUI
import StrandDesign

/// Every reading in the detail page's visible range, newest first: the "Show all" page behind the
/// detail's newest-seven list.
struct MetricReadingsListView: View {
    let title: String
    let rows: [ReadingsList.Row]

    var body: some View {
        ScreenScaffold(title: "\(title)", titleDisplay: .navigationBar, lazy: true) {
            ReadingsList(rows: rows, visibleCount: max(1, rows.count), onShowAll: nil)
        }
    }
}
