#if DEBUG
import Foundation
import WhoopStore
import StrandImport

// MARK: - DEBUG-only Lab Book demo seed
//
// `AppleDemoSeeder` fills the daily tables but leaves the Lab Book empty, so its marker list and marker
// detail (the readings chart, compare with a signal) could not be screenshotted in a simulator. With
// `--demo-labbook` this writes a few SYNTHETIC, deterministic readings (two blood markers over a year and
// a run of blood-pressure readings over three months) once, into an empty Lab Book. Nothing here is real
// biometric data. The whole file is `#if DEBUG`, so Release builds do not contain it.
enum DemoLabBookSeeder {
    static var requested: Bool { CommandLine.arguments.contains("--demo-labbook") }

    static func seedIfRequested(into store: WhoopStore, deviceId: String) async {
        guard requested else { return }
        let existing = (try? await store.labMarkers(deviceId: deviceId, category: LabMarkerCategory.bloodPanel.rawValue)) ?? []
        guard existing.isEmpty else { return }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let keyFormatter = DateFormatter()
        keyFormatter.locale = Locale(identifier: "en_US_POSIX")
        keyFormatter.dateFormat = "yyyy-MM-dd"

        func row(_ key: String, _ category: LabMarkerCategory, daysAgo: Int, value: Double, unit: String,
                 reference: String? = nil) -> LabMarkerRow? {
            guard let date = cal.date(byAdding: .day, value: -daysAgo, to: today) else { return nil }
            let day = keyFormatter.string(from: date)
            let epoch = Int(date.timeIntervalSince1970) + 9 * 3600
            return LabMarkerRow(id: "demo-\(key)-\(daysAgo)", deviceId: deviceId, markerKey: key,
                                category: category.rawValue, day: day, takenAt: epoch, value: value,
                                valueText: nil, unit: unit, source: "manual", note: nil, referenceText: reference)
        }

        var rows: [LabMarkerRow?] = []
        for (daysAgo, value) in [(360, 3.4), (270, 3.2), (180, 3.3), (90, 2.9), (20, 2.7)] {
            rows.append(row("ldl", .bloodPanel, daysAgo: daysAgo, value: value, unit: "mmol/L", reference: "< 3.0"))
        }
        for (daysAgo, value) in [(300, 38.0), (150, 36.0), (20, 35.0)] {
            rows.append(row("hba1c", .bloodPanel, daysAgo: daysAgo, value: value, unit: "mmol/mol"))
        }
        for (index, daysAgo) in [84, 70, 56, 42, 35, 28, 21, 14, 7, 2].enumerated() {
            rows.append(row("bp_systolic", .bloodPressure, daysAgo: daysAgo, value: Double(128 - index), unit: "mmHg"))
            rows.append(row("bp_diastolic", .bloodPressure, daysAgo: daysAgo, value: Double(82 - index / 2), unit: "mmHg"))
        }
        _ = try? await store.upsertLabMarkers(rows.compactMap { $0 })
    }
}
#endif
