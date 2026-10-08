#if DEBUG
import SwiftUI
import StrandDesign
import WhoopStore

/// DEBUG-only `--demo-screen sleepcards`: every sleep card Today can host, on one page, built from the same
/// loads and the same `SleepModel.build` the Today host uses, so the cards can be screenshotted without
/// customising Today. Compiled out of Release.
struct SleepHostedCardsDemo: View {
    @EnvironmentObject private var repo: Repository
    @State private var model: SleepModel?

    var body: some View {
        ScreenScaffold(title: "Sleep cards", isLoading: model == nil) {
            if let model {
                StagesCard(model: model)
                NightDetailCard(model: model)
                SleepDebtLedgerCard(model: model)
                AsleepDurationCard(data: AsleepDurationData.build(days: repo.days))
                StagesVsTypicalCard(model: model)
                HoursVsNeededCard(model: model)
                ConsistencyCard(model: model)
                SleepMarkCard()
            }
        }
        .task(id: repo.refreshSeq) {
            // A demo screen skips the tab shell that triggers the first load.
            if !repo.loaded { await repo.refresh() }
            let sessions = await repo.allSleepSessions()
            let habitual = await repo.habitualMidsleepSec()
            let motion = await repo.sessionMotions(sessions: sessions)
            model = SleepModel.build(SleepModelInputs(days: repo.days, sleeps: repo.sleeps, allSessions: sessions,
                                                      importedSleep: repo.importedSleep,
                                                      habitualMidsleepSec: habitual, motionByStart: motion))
        }
    }
}
#endif
