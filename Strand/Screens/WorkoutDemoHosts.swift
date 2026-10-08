#if DEBUG
import SwiftUI
import StrandDesign
import WhoopProtocol

// MARK: - DEBUG screenshot hosts for the workout screens
//
// `--demo-screen liveworkout | startworkout | manualworkout | liftlog` (StrandiOSApp's DemoScreens) render one
// of these so a simulator with no strap can be captured: nothing outside the app can start a workout or open
// a sheet. The live host fills `activeWorkout` with a synthetic session; it is compiled out of Release.

/// The in-exercise screen over a synthetic 26-minute run.
struct LiveWorkoutDemoHost: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        LiveWorkoutView(onClose: {})
            .environmentObject(model.live)
            .task {
                guard model.activeWorkout == nil else { return }
                let start = Date().addingTimeInterval(-26 * 60)
                let t0 = Int(start.timeIntervalSince1970)
                let samples = (0..<(26 * 60)).map { i -> HRSample in
                    let f = Double(i) / Double(26 * 60)
                    let base = 100 + 50 * min(1, f / 0.15) + 14 * sin(f * .pi * 7)
                    return HRSample(ts: t0 + i, bpm: Int(base.rounded()))
                }
                model.activeWorkout = AppModel.ActiveWorkout(start: start, sport: "Running", samples: samples,
                                                             liveStrain: 41.6, avgHr: 146, peakHr: 168)
                model.bpm = 154
            }
    }
}

/// The sport picker, presented the way Workouts presents it.
struct StartWorkoutDemoHost: View {
    @State private var shown = true
    var body: some View {
        Color.clear.workoutSelectionCover(isPresented: $shown) { StartWorkoutSheet { _ in } }
    }
}

/// The add-workout sheet, presented the way Workouts presents it.
struct ManualWorkoutDemoHost: View {
    @State private var shown = true
    var body: some View {
        Color.clear.sheet(isPresented: $shown) { ManualWorkoutSheet { _, _ in } }
    }
}
#endif
