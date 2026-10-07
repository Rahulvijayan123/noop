import SwiftUI
import Foundation
import StrandDesign

// SensorBiomarkersView.swift — the Settings page for the sensor biomarkers: the on/off switch
// (`SensorBiomarkerFeature`, default OFF) and one UTC day of the server's descriptive documents,
// stepped back up to `maxDaysBack` days. The server computes per UTC day, so the page names UTC days.

struct SensorBiomarkersView: View {
    @State private var enabled = SensorBiomarkerFeature.isEnabled
    @State private var daysBack = 0

    static let maxDaysBack = 30

    private static let utc = TimeZone(identifier: "UTC")!

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }()

    /// The `YYYY-MM-DD` UTC day `daysBack` days before `now`, the key the route and cache use.
    static func day(daysBack: Int, now: Date = Date()) -> String {
        let date = utcCalendar.date(byAdding: .day, value: -daysBack, to: now) ?? now
        let parts = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    static func dayLabel(daysBack: Int, now: Date = Date()) -> String {
        switch daysBack {
        case 0: return String(localized: "Today (UTC)")
        case 1: return String(localized: "Yesterday (UTC)")
        default:
            let date = utcCalendar.date(byAdding: .day, value: -daysBack, to: now) ?? now
            var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
            style.timeZone = utc
            return date.formatted(style)
        }
    }

    var body: some View {
        ScreenScaffold(title: "Sensor biomarkers") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                SettingsGroup(footer: "Computed on Nara's server from your strap's raw motion recordings. Descriptive measurements only, not a health score or a diagnosis.") {
                    HStack(alignment: .center, spacing: NoopMetrics.space4) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show sensor biomarkers")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Wrist movement, still periods and small wrist oscillation, per day.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: NoopMetrics.space3)
                        Toggle("", isOn: $enabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(StrandPalette.accent)
                            .accessibilityLabel("Show sensor biomarkers")
                    }
                    .padding(.horizontal, NoopMetrics.space4)
                    .frame(minHeight: 64)
                }
                if enabled {
                    dayStepper
                    SensorBiomarkersSection(day: Self.day(daysBack: daysBack))
                        .id(Self.day(daysBack: daysBack))
                }
            }
        }
        .onChange(of: enabled) { value in
            SensorBiomarkerFeature.setEnabled(value)
        }
    }

    private var dayStepper: some View {
        HStack(spacing: NoopMetrics.space3) {
            Button {
                daysBack = min(Self.maxDaysBack, daysBack + 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(NoopButtonStyle(.tertiary))
            .disabled(daysBack >= Self.maxDaysBack)
            .accessibilityLabel("Previous day")
            Spacer()
            Text(Self.dayLabel(daysBack: daysBack))
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            Button {
                daysBack = max(0, daysBack - 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(NoopButtonStyle(.tertiary))
            .disabled(daysBack == 0)
            .accessibilityLabel("Next day")
        }
    }
}
