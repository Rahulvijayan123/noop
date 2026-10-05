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
        ScreenScaffold(title: "Power saving",
                       subtitle: "Ease the load on your strap when its battery is running low.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                NoopCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Power saving").strandOverline()
                        Text("The strap keeps banking data on its own, so nothing is lost — NOOP just talks to it less often to help it last until you can charge it.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        rowDivider
                        Toggle(isOn: $powerSavingEnabled) {
                            Text("Power saving mode")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                        }
                        .toggleStyle(.switch)
                        .tint(StrandPalette.accent)
                        .onChangeCompat(of: powerSavingEnabled) { _ in model.applyPowerSaving() }
                        Text("Slows background strap-sync (every 45 min instead of 15) while your strap's battery is low. No data loss — the strap banks everything, so sync just batches into larger, less frequent pulls.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        if powerSavingEnabled {
                            rowDivider
                            HStack {
                                Text("Kick in at (strap battery)")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                Text(verbatim: "\(powerSavingPct)%")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.accent)
                            }
                            // 10…35 in 5s. 35 buys one more step of strap life than the old 30 ceiling:
                            // the levers engage ~5% earlier in the discharge, at the cost of a slightly
                            // longer stretch of quieter syncing.
                            Slider(
                                value: Binding(get: { Double(powerSavingPct) }, set: { powerSavingPct = Int($0) }),
                                in: 10...35, step: 5,
                                onEditingChanged: { editing in if !editing { model.applyPowerSaving() } }
                            )
                            .tint(StrandPalette.accent)

                            rowDivider
                            // HRV pause: a sub-option, ON by default when the master is on (stored inverted).
                            Toggle(isOn: Binding(get: { !pauseHrvDisabled }, set: { pauseHrvDisabled = !$0 })) {
                                Text("Pause HRV capture")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                            }
                            .toggleStyle(.switch)
                            .tint(StrandPalette.accent)
                            .onChangeCompat(of: pauseHrvDisabled) { _ in model.applyPowerSaving() }
                            Text("While your strap's battery is low, stop the always-on background HRV stream — the biggest continuous drain on the strap. A Live screen still shows heart rate, and it re-arms automatically once the strap is charged.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            rowDivider
                            // Low refresh: a sub-option that applies at ANY charge, not just below the threshold.
                            Toggle(isOn: $lowRefreshEnabled) {
                                Text("Low refresh")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                            }
                            .toggleStyle(.switch)
                            .tint(StrandPalette.accent)
                            .onChangeCompat(of: lowRefreshEnabled) { _ in model.applyPowerSaving() }
                            Text("Sync in the background every hour instead of every 15 minutes, whatever the strap's charge — fewer reconnections is the biggest saving on a WHOOP 4.0. Nothing is lost: the strap banks everything and hands it over in larger batches. Pull to sync still runs straight away, and live heart rate is untouched.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                activityMotionCard

                NoopCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Fresh data").strandOverline()
                        Toggle(isOn: $freshSyncEnabled) {
                            Text("Sync every minute")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                        }
                        .toggleStyle(.switch)
                        .tint(StrandPalette.accent)
                        .onChangeCompat(of: freshSyncEnabled) { _ in model.applyPowerSaving() }
                        Text("With cloud scoring on, a WHOOP 5.0 or MG hands NOOP its history about once a minute, so steps, calories and respiratory rate stay current instead of arriving in batches every few minutes. Live heart rate is unaffected either way. Low refresh overrides this, and Power saving slows it while the strap's battery is low. Nothing is lost if you turn it off: the strap banks everything and hands it over later.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var activityMotionCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Motion for activity").strandOverline()
                Picker("Raw motion", selection: Binding(
                    get: { ActivityImuCaptureMode(rawValue: activityMotionRaw) ?? ActivityImuCapture.defaultMode },
                    set: { mode in
                        activityMotionRaw = mode.rawValue
                        model.ble.setActivityImuCaptureMode(mode)
                    })) {
                    ForEach(ActivityImuCaptureMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                Text(activityMotionExplanation)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var activityMotionExplanation: String {
        switch ActivityImuCaptureMode(rawValue: activityMotionRaw) ?? ActivityImuCapture.defaultMode {
        case .off:
            return "Your strap's raw motion is only recorded during a Raw Data session you start yourself. What you were doing is read from heart rate, steps and the strap's once-a-second motion alone."
        case .partTime:
            return "Records your strap's raw motion (100 times a second) for one minute in every three and sends it to the server, where the activity model reads it and the Heart rate page uses its verdicts. Pauses while the strap's battery is low."
        case .continuous:
            return "Records your strap's raw motion all the time for the most accurate activity labels. This keeps the strap streaming, which uses more of its battery, and uploads tens of megabytes a day. Pauses while the strap's battery is low."
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
            .padding(.vertical, 4)
    }
}
