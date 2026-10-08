import Foundation

/// One night's two HRV numbers (the detail page draws them as two `DailyLineChart` series, SDNN behind a
/// legend toggle). Either may be missing: a night scored before the SDNN index existed
/// still plots its RMSSD, and an Apple-only night can carry SDNN alone.
struct HRVDualPoint: Identifiable, Equatable {
    let day: String
    let date: Date
    let rmssd: Double?
    let sdnn: Double?
    var id: String { day }
}

enum HRVDualSeries {
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ day: String) -> Date? { dayParser.date(from: day) }

    /// Joins the two series on day. RMSSD and SDNN stay in separate fields; they are different
    /// statistics and are never blended into one number.
    static func merge(
        rmssd: [(day: String, value: Double)],
        sdnn: [(day: String, value: Double)]
    ) -> [HRVDualPoint] {
        var byDay: [String: (rmssd: Double?, sdnn: Double?)] = [:]
        for r in rmssd where r.value.isFinite && r.value > 0 { byDay[r.day, default: (nil, nil)].rmssd = r.value }
        for s in sdnn where s.value.isFinite && s.value > 0 { byDay[s.day, default: (nil, nil)].sdnn = s.value }
        return byDay.keys.sorted().compactMap { day in
            guard let date = date(day), let pair = byDay[day] else { return nil }
            return HRVDualPoint(day: day, date: date, rmssd: pair.rmssd, sdnn: pair.sdnn)
        }
    }

    /// SDNN readings that fall inside the RMSSD window the screen is showing.
    static func window(
        _ series: [(day: String, value: Double)],
        firstDay: String?
    ) -> [(day: String, value: Double)] {
        guard let firstDay else { return series }
        return series.filter { $0.day >= firstDay }
    }

    /// Run ids that advance wherever more than `maxGapDays` separate two readings, so the line is not
    /// drawn across nights that were never measured.
    static func segmentIDs(dates: [Date], maxGapDays: Int = 3) -> [Int] {
        var ids: [Int] = []
        var current = 0
        var previous: Date?
        for d in dates {
            if let previous, d.timeIntervalSince(previous) > Double(maxGapDays) * 86_400 { current += 1 }
            ids.append(current)
            previous = d
        }
        return ids
    }

    /// Mean SDNN ÷ mean RMSSD over nights that have both numbers.
    static func ratio(_ points: [HRVDualPoint]) -> Double? {
        let both = points.compactMap { p -> (Double, Double)? in
            guard let r = p.rmssd, let s = p.sdnn else { return nil }
            return (r, s)
        }
        guard !both.isEmpty else { return nil }
        let meanR = both.map(\.0).reduce(0, +) / Double(both.count)
        let meanS = both.map(\.1).reduce(0, +) / Double(both.count)
        return meanR > 0 ? meanS / meanR : nil
    }
}
