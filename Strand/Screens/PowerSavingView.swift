import SwiftUI
import StrandDesign

// MARK: - Power saving (#477)
//
// Lifted out of Settings into its own screen: on iPhone it is a first-class More row (between Test
// Centre and Settings) and on macOS its own sidebar item, so the strap-battery levers are one tap away
// instead of buried in the middle of the Settings scroll. The controls, their prefs and their wiring are
// UNCHANGED — `AppModel.applyPowerSaving()` still reads every value from `PuffinExperiment`, so moving
// the surface cannot alter behaviour.
//
// The master gates the sub-options: the threshold slider, "Pause HRV capture" and "Low refresh" only
// appear (and only apply) while Power saving is on — `applyPowerSaving` ANDs each one with the master.
struct PowerSavingView: View {
    @EnvironmentObject var model: AppModel

    @AppStorage(PuffinExperiment.powerSavingKey) private var powerSavingEnabled = false
    @AppStorage(PuffinExperiment.powerSavingBatteryPctKey) private var powerSavingPct = 20
    /// Stored INVERTED so the default (absent = false) reads as "HRV pause on". The toggle shows `!this`.
    @AppStorage(PuffinExperiment.pauseHrvDisabledKey) private var pauseHrvDisabled = false
    @AppStorage(PuffinExperiment.lowRefreshKey) private var lowRefreshEnabled = false
    /// Default ON, matching `PuffinExperiment.freshSyncEnabled` (an absent key reads as on).
    @AppStorage(PuffinExperiment.freshSyncKey) private var freshSyncEnabled = true
    @AppStorage(ActivityImuCapture.modeKey) private var activityMotionRaw = ActivityImuCapture.defaultMode.rawValue

    var body: some View {
        ScreenScaffold(title: "Power saving", titleDisplay: .navigationBar) {
            NoopListSection("When the strap is low",
                            footer: "The strap keeps recording on its own, so nothing is lost. Nara just talks to it less often.") {
                MoreToggleRow("Power saving mode",
                              footnote: String(localized: "Syncs every 45 min instead of 15 while the strap is low"),
                              isOn: $powerSavingEnabled)
                    .onChangeCompat(of: powerSavingEnabled) { _ in model.applyPowerSaving() }
                if powerSavingEnabled {
                    NoopListDivider()
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        HStack {
                            Text("Start at")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Text(verbatim: "\(powerSavingPct) %")
                                .font(StrandFont.bodyNumber)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        // 10…35 in 5s. 35 buys one more step of strap life than the old 30 ceiling: the levers
                        // engage ~5% earlier in the discharge, at the cost of a slightly longer quiet stretch.
                        Slider(
                            value: Binding(get: { Double(powerSavingPct) }, set: { powerSavingPct = Int($0) }),
                            in: 10...35, step: 5,
                            onEditingChanged: { editing in if !editing { model.applyPowerSaving() } }
                        )
                        .tint(StrandPalette.accent)
                        .accessibilityLabel("Strap battery level to start power saving")
                    }
                    .padding(.horizontal, NoopMetrics.cardPadding)
                    .padding(.vertical, NoopMetrics.space3)
                    NoopListDivider()
                    // HRV pause: a sub-option, ON by default when the master is on (stored inverted).
                    MoreToggleRow("Pause HRV capture",
                                  footnote: String(localized: "Stops the background HRV stream while the strap is low"),
                                  isOn: Binding(get: { !pauseHrvDisabled }, set: { pauseHrvDisabled = !$0 }))
                        .onChangeCompat(of: pauseHrvDisabled) { _ in model.applyPowerSaving() }
                    NoopListDivider()
                    // Low refresh: a sub-option that applies at ANY charge, not just below the threshold.
                    MoreToggleRow("Low refresh",
                                  footnote: String(localized: "Syncs hourly, whatever the strap's charge"),
                                  isOn: $lowRefreshEnabled)
                        .onChangeCompat(of: lowRefreshEnabled) { _ in model.applyPowerSaving() }
                }
            }

            NoopListSection("Sync") {
                MoreToggleRow("Sync every minute",
                              footnote: String(localized: "WHOOP 5.0 and MG with cloud scoring"),
                              isOn: $freshSyncEnabled)
                    .onChangeCompat(of: freshSyncEnabled) { _ in model.applyPowerSaving() }
            }

            NoopListSection("Motion for activity", footer: LocalizedStringKey(activityMotionSummary)) {
                SegmentedPillControl(ActivityImuCaptureMode.allCases, selection: Binding(
                    get: { ActivityImuCaptureMode(rawValue: activityMotionRaw) ?? ActivityImuCapture.defaultMode },
                    set: { mode in
                        activityMotionRaw = mode.rawValue
                        model.ble.setActivityImuCaptureMode(mode)
                    }), fillsAvailableWidth: true) { $0.title }
                    .accessibilityLabel("Raw motion")
                    .padding(NoopMetrics.cardPadding)
            }

            AboutDisclosure("About power saving", paragraphs: aboutParagraphs)
        }
    }

    /// One line for the selected motion mode; the full explanation is in About.
    private var activityMotionSummary: String {
        switch ActivityImuCaptureMode(rawValue: activityMotionRaw) ?? ActivityImuCapture.defaultMode {
        case .off: return String(localized: "Raw motion is recorded only during a Raw Data session you start.")
        case .partTime: return String(localized: "One minute in every three, sent to the server for activity labels.")
        case .continuous: return String(localized: "All the time, for the best activity labels. Uses more strap battery.")
        }
    }

    private var aboutParagraphs: [String] {
        [
            String(localized: "Power saving slows background strap sync while the strap's battery is low. The strap banks everything, so sync batches into larger, less frequent pulls and no data is lost."),
            String(localized: "Pause HRV capture stops the always-on background HRV stream, the biggest continuous drain on the strap. Live heart rate still shows, and it re-arms once the strap is charged."),
            String(localized: "Low refresh syncs in the background every hour instead of every 15 minutes at any charge. Fewer reconnections is the biggest saving on a WHOOP 4.0. Pull to sync still runs straight away."),
            String(localized: "With cloud scoring on, a WHOOP 5.0 or MG can hand over its history about once a minute, so steps, calories and respiratory rate stay current. Low refresh overrides this, and power saving slows it while the strap is low."),
            activityMotionExplanation,
        ]
    }

    private var activityMotionExplanation: String {
        switch ActivityImuCaptureMode(rawValue: activityMotionRaw) ?? ActivityImuCapture.defaultMode {
        case .off:
            return String(localized: "Raw motion: your strap's raw motion is only recorded during a Raw Data session you start yourself. What you were doing is read from heart rate, steps and the strap's once-a-second motion alone.")
        case .partTime:
            return String(localized: "Raw motion: records your strap's raw motion (100 times a second) for one minute in every three and sends it to the server, where the activity model reads it and the Heart rate page uses its verdicts. Pauses while the strap's battery is low.")
        case .continuous:
            return String(localized: "Raw motion: records your strap's raw motion all the time for the most accurate activity labels. This keeps the strap streaming, which uses more of its battery, and uploads tens of megabytes a day. Pauses while the strap's battery is low.")
        }
    }
}
