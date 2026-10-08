#if DEBUG
import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - DEBUG-only treatment demo seed
//
// With `--demo-treatment`, an empty treatment log gets one open course (started three weeks ago) and two
// weekly doses, written through the store's own `logStart` / `logDose`, so the Treatment page's open
// course, watch list and log can be screenshotted in a simulator. SYNTHETIC; a no-op once anything is
// logged. Called from the Treatment page's DEBUG appear hook, once the day tape it needs has loaded. The
// whole file is `#if DEBUG`, so Release builds do not contain it.
@MainActor
enum DemoTreatmentSeeder {
    static var requested: Bool { CommandLine.arguments.contains("--demo-treatment") }

    static func seedIfRequested(into store: BaselineStore, days: [DailyMetric]) {
        guard requested, store.events.isEmpty else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func day(_ ago: Int) -> String {
            TreatmentStamp.iso(from: cal.date(byAdding: .day, value: -ago, to: today) ?? today)
        }
        store.logStart(name: "Methotrexate", dose: "15 mg", civilDay: day(21), clockTime: "08:00",
                       enteredBy: .caregiver, kind: .medication, days: days,
                       onsetDays: 14, washoutDays: 21, schedule: .course)
        store.logDose(civilDay: day(14), clockTime: "08:15", dose: "15 mg", days: days)
        store.logDose(civilDay: day(7), clockTime: "08:05", dose: "15 mg", days: days)
    }
}
#endif
