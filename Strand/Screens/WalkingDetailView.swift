import SwiftUI
import StrandDesign

/// "How you walked": the server gait model's reading of one day's walking (time, pace, cadence mix, when in
/// the day, each walk), one tap down from the Steps page's context row.
struct WalkingDetailView: View {
    /// The local calendar day ("yyyy-MM-dd") to open on.
    let day: String

    var body: some View {
        ScreenScaffold(title: "How you walked", titleDisplay: .navigationBar) {
            WalkingInsightsSection(day: day)
            AboutDisclosure("About") {
                AboutParagraphs([
                    String(localized: "Read every 5 seconds from the strap's raw motion by a gait model (ElderNet). Steps, speed and stride are wrist estimates; they are steadiest on longer, unhurried walks."),
                    String(localized: "A gait reading appears once the server has processed a raw motion session from your strap."),
                ])
            }
        }
    }
}
