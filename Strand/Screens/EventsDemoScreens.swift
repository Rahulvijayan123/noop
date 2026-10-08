#if DEBUG
import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - DEBUG-only screenshot hosts for the event editors
//
// `--demo-screen exposurelist | exposureeditor | markereditor` (StrandiOS/App/StrandiOSApp.swift, DemoScreens)
// render these. The editors are sheets in the app, so they are shown here as sheets over a blank canvas
// rather than pushed into the demo host's navigation stack, which would draw a second, empty bar above
// their own. Release builds do not contain this file.
enum EventsDemoScreens {
    /// The recorded-events list for the last day (the page the measurement-context sheet pushes).
    static func exposureList() -> some View {
        let now = Int(Date().timeIntervalSince1970)
        return ExposureEventListView(window: PhysiologyContext.Interval(start: now - 86_400, end: now + 3_600))
    }

    static func exposureEditor() -> some View {
        EventsDemoSheetHost { ExposureEventEditorView() }
    }

    static func markerEditor() -> some View {
        EventsDemoSheetHost { MarkerEditorView { _ in } }
    }
}

/// Presents `content` as a sheet as soon as it appears.
struct EventsDemoSheetHost<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var shown = false

    var body: some View {
        StrandPalette.surfaceBase
            .ignoresSafeArea()
            .onAppear { shown = true }
            .sheet(isPresented: $shown) {
                content()
                    #if os(iOS)
                    .noopSheetPresentation(largeFirst: true)
                    #endif
            }
    }
}
#endif
