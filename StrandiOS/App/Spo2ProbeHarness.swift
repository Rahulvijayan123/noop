#if DEBUG
import Foundation

/// DEBUG launch hook: `--probe-spo2` asks a connected 5.0/MG, read-only, whether any setting governs how often
/// it measures SpO₂, and saves what it answers to `Documents/spo2-probe.txt` so the report can be read off the
/// phone without tapping through the Test Centre.
///
/// What runs, in order, all through the probes the app already ships:
///  1. Feature-flag ENUMERATION (`START_FF_KEY_EXCHANGE` 117 / `SEND_NEXT_FF` 118): the key NAMES this
///     firmware lists.
///  2. Value READS (`GET_DEVICE_CONFIG_VALUE` 121 / `GET_FF_VALUE` 128) for the names the app already knows,
///     the guessed oxygen names, and every name step 1 listed that the plan did not already cover.
///
/// Nothing is written to the strap. `SET_FF_VALUE` (120) and `SET_DEVICE_CONFIG_VALUE` (119) are never sent from
/// these paths, and the send allowlist only admits 117/118/121/128 while a probe is in flight. The probes need
/// Test Centre → Connection on, so this turns it on for the run and puts it back afterwards.
///
/// Also starts when the process environment has `PROBE_SPO2=1` (`DEVICECTL_CHILD_PROBE_SPO2=1` from `devicectl`).
///
/// It needs the strap on and in range (it waits for a full encrypted bond) and the app in the foreground.
@MainActor
enum Spo2ProbeHarness {
    static let launchFlag = "--probe-spo2"

    static func startIfRequested(model: AppModel) {
        let requested = CommandLine.arguments.contains(launchFlag)
            || ProcessInfo.processInfo.environment["PROBE_SPO2"] == "1"
        NSLog("[Spo2ProbeHarness] requested=\(requested) args=\(CommandLine.arguments.dropFirst())")
        guard requested else { return }
        Task { @MainActor in await run(model: model) }
    }

    private static var reportURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("spo2-probe.txt")
    }

    /// Poll `condition` until it holds or `seconds` pass. True if it held.
    private static func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return condition()
    }

    private static func run(model: AppModel) async {
        var report: [String] = []
        func note(_ line: String) {
            report.append(line)
            try? report.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8)
        }
        note("SpO2 probe (read-only) started \(Date().formatted(date: .abbreviated, time: .standard))")

        let live = model.live
        let bonded = await wait(300) { live.connected && live.encryptedBond }
        note("link: connected=\(live.connected) encryptedBond=\(live.encryptedBond) firmware=\(live.strapFirmware ?? "unknown")")
        guard bonded else {
            note("STOPPED: the strap did not reach a full encrypted bond within 300 s. Wear it, keep it in range, close the official WHOOP app, and run again.")
            return
        }

        let connectionWasOn = TestCentre.active(.connection)
        if !connectionWasOn { TestCentre.activate(.connection) }
        defer { if !connectionWasOn { TestCentre.deactivate(.connection) } }

        // 1. The key NAMES this firmware lists.
        note("\n=== 1. Feature-flag enumeration (117/118, names only) ===")
        model.ble.probeFeatureFlags()
        let enumerated = await wait(180) {
            if let text = live.featureFlagProbe { return text != BLEManager.featureFlagProbeWaiting }
            return false
        }
        note(enumerated ? (live.featureFlagProbe ?? "(no text)") : "TIMED OUT waiting for the enumeration to finish")
        let names = model.ble.enumeratedFlagKeys
        note("names listed by the strap (\(names.count)): " + names.joined(separator: ", "))

        // 2. Their VALUES, plus the known and guessed names.
        note("\n=== 2. Config / flag values (121/128, read-only) ===")
        model.ble.probeDeviceConfigValues(extraFlagKeys: names)
        let valued = await wait(600) {
            if let text = live.deviceConfigProbe { return text != BLEManager.deviceConfigProbeWaiting }
            return false
        }
        note(valued ? (live.deviceConfigProbe ?? "(no text)") : "TIMED OUT waiting for the value reads to finish")

        note("\nDONE \(Date().formatted(date: .omitted, time: .standard)). Nothing was written to the strap.")
    }
}
#endif
