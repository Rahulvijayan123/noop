#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import StrandDesign
@testable import Strand

/// Renders the "Every reading" card with realistic data so it can be looked at and so a layout that cannot
/// render at all fails a test. Set `BANKED_READINGS_RENDER_DIR` to also write PNGs there; without it the
/// test only checks that each card produces a non-empty image.
@MainActor
final class BankedReadingsRenderTests: XCTestCase {

    private let hour = 3_600

    /// A local-midnight-aligned "yesterday 12:00 to today 12:00" window, like the live card's last 24 hours.
    private var window: (from: Int, to: Int) {
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        let to = Int(noon.timeIntervalSince1970)
        return (to - 24 * hour, to)
    }

    /// Skin temperature at 1 Hz: a night-time plateau, a daytime dip, and two stretches with nothing banked
    /// (strap off the wrist), the shape of the real capture.
    private func skinTempSeries() -> KeyMetricReadings.BankedSeries {
        let w = window
        var readings: [(ts: Int, value: Double)] = []
        for ts in w.from..<w.to {
            let h = Double(ts - w.from) / Double(hour)
            if (3.0..<4.17).contains(h) || (21.5..<21.9).contains(h) { continue }   // off the wrist
            let diurnal = 34.2 - 0.9 * sin((h - 6) / 24 * 2 * .pi)
            let wobble = 0.08 * sin(Double(ts) / 37)
            readings.append((ts, diurnal + wobble))
        }
        return KeyMetricReadings.bankedSeries(readings, bucketSeconds: 300)
    }

    /// SpO₂ in 30-second windows while asleep (about 02:00 to 11:00), none awake; 178 valid readings, 542 codes.
    private func spo2Series() -> KeyMetricReadings.BankedSeries {
        let w = window
        var readings: [(ts: Int, value: Double)] = []
        var i = 0
        var start = w.from + 14 * hour
        while readings.count < 178, start < w.to - hour {
            for s in 0..<30 where i % 4 != 0 || s % 2 == 0 {        // thin the windows to land on 178
                guard readings.count < 178 else { break }
                readings.append((start + s, Double(94 + (i + s) % 6)))
            }
            start += 1_250
            i += 1
        }
        return KeyMetricReadings.bankedSeries(readings, bucketSeconds: 1, statusBytes: 542)
    }

    private func render(_ signal: BankedReadingsSection.Signal, accent: Color,
                        series: KeyMetricReadings.BankedSeries, name: String) throws {
        let w = window
        let repo = Repository(deviceId: "my-whoop")
        let view = ZStack(alignment: .top) {
            StrandPalette.surfaceBase
            BankedReadingsSection(signal: signal, accent: accent, preloaded: (w.from, w.to, series))
                .padding(16)
        }
        .frame(width: 390)
        .environmentObject(repo)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "\(name) produced no image")
        XCTAssertGreaterThan(image.width, 300)
        XCTAssertGreaterThan(image.height, 400, "the card is a header, plot, stats and an hourly chart tall")

        if let dir = ProcessInfo.processInfo.environment["BANKED_READINGS_RENDER_DIR"] {
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            try XCTUnwrap(png).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func testSkinTempCardRenders() throws {
        let series = skinTempSeries()
        XCTAssertGreaterThan(series.count, 70_000)
        try render(.skinTemp, accent: StrandPalette.metricAmber, series: series, name: "skin-temp")
    }

    func testSpo2CardRenders() throws {
        let series = spo2Series()
        XCTAssertEqual(series.count, 178)
        try render(.bloodOxygen, accent: StrandPalette.metricCyan, series: series, name: "spo2")
    }
}
#endif
