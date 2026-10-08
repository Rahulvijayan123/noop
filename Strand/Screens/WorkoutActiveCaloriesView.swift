import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Active calories, last 13 weeks
//
// Opened from the Workouts page. A calendar of daily active calories (columns are weeks, Monday first; rows are
// weekdays; a cell's shade is that day's burn against the window's busiest day), with the day under a tap in
// the readout. The bucketing is the pure cross-platform `ActivityHeatmap` (parity with the Kotlin twin); this
// is only the renderer. The daily totals are the ones the Workouts page read; nothing is re-read here.

struct WorkoutActiveCaloriesView: View {
    /// Day "yyyy-MM-dd" → active kcal.
    let dailyKcal: [String: Double]

    @State private var selectedDay: String?

    private static let gap: CGFloat = 3
    private static let leftInset: CGFloat = 20   // weekday gutter
    private static let topInset: CGFloat = 14    // month row

    var body: some View {
        let today = WorkoutsView.todayDayString()
        let grid = ActivityHeatmap.build(values: dailyKcal, today: today)
        ScreenScaffold(title: "Active calories", titleDisplay: .navigationBar) {
            ValueReadout(readout(grid), isScrubbing: selectedDay != nil)
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    GeometryReader { geo in
                        Canvas { ctx, size in draw(ctx, size: size, grid: grid, today: today) }
                            .contentShape(Rectangle())
                            .onTapGesture { location in select(at: location, size: geo.size, grid: grid) }
                    }
                    .aspectRatio(13.0 / 7.6, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Active-calorie heatmap, last 13 weeks"))
                    HStack(spacing: NoopMetrics.space1) {
                        Text("Less").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        ForEach(0..<5, id: \.self) { lvl in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Self.heatColor(lvl))
                                .frame(width: 10, height: 10)
                        }
                        Text("More").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        Spacer(minLength: 0)
                        Text("kcal").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                    .accessibilityHidden(true)
                }
            }
            StatGrid(stats(grid), columns: 2)
        }
    }

    private func readout(_ grid: ActivityHeatmap.Grid) -> ReadoutContent {
        if let selectedDay, let date = ChartDay.date(forKey: selectedDay) {
            return ReadoutContent(dateLine: ReadoutContent.dateLine(date, period: .day),
                                  value: dailyKcal[selectedDay].map { WorkoutFormat.grouped($0) }, unit: "kcal")
        }
        return ReadoutContent(dateLine: String(localized: "Last 13 weeks"), value: WorkoutFormat.grouped(grid.total),
                              unit: "kcal",
                              context: grid.streak > 0
                                ? "\(grid.streak) \(grid.streak == 1 ? String(localized: "day in a row") : String(localized: "days in a row"))"
                                : nil)
    }

    private func stats(_ grid: ActivityHeatmap.Grid) -> [StatItem] {
        let cells = grid.columns.flatMap { $0 }.filter { $0.day != nil && $0.value != nil }
        let values = cells.compactMap(\.value)
        let best = cells.max { ($0.value ?? 0) < ($1.value ?? 0) }
        return [
            StatItem(String(localized: "Daily average"),
                     value: values.isEmpty ? nil : WorkoutFormat.grouped(values.reduce(0, +) / Double(values.count)), unit: "kcal"),
            StatItem(String(localized: "Best day"), value: best?.value.map { WorkoutFormat.grouped($0) },
                     unit: "kcal",
                     detail: best?.day.flatMap { ChartDay.date(forKey: $0) }.map { ReadoutContent.dateLine($0, period: .day) }),
        ]
    }

    // MARK: Drawing

    private func cellSize(_ size: CGSize, cols: Int) -> CGFloat {
        min((size.width - Self.leftInset - Self.gap * CGFloat(cols - 1)) / CGFloat(cols),
            (size.height - Self.topInset - Self.gap * 6) / 7)
    }

    private func select(at location: CGPoint, size: CGSize, grid: ActivityHeatmap.Grid) {
        let cols = grid.columns.count
        guard cols > 0 else { return }
        let cell = cellSize(size, cols: cols)
        guard cell > 0 else { return }
        let c = Int((location.x - Self.leftInset) / (cell + Self.gap))
        let r = Int((location.y - Self.topInset) / (cell + Self.gap))
        guard (0..<cols).contains(c), (0..<7).contains(r), let day = grid.columns[c][r].day else { return }
        selectedDay = selectedDay == day ? nil : day
        StrandHaptic.selection.play()
    }

    /// The weekday gutter (Mon/Wed/Fri/Sun), the month row (drawn where the month changes), then the cells.
    /// Labels use the LOCALIZED calendar symbols so they translate for free and carry no hardcoded literals.
    private func draw(_ ctx: GraphicsContext, size: CGSize, grid: ActivityHeatmap.Grid, today: String) {
        let cols = grid.columns.count
        guard cols > 0 else { return }
        let cell = cellSize(size, cols: cols)
        guard cell > 0 else { return }
        // Resolve + colour via the Canvas shading (macOS 13 compatible — `Text.foregroundStyle`
        // returning Text is macOS 14+, but a resolved text's `shading` is available here).
        func label(_ s: String) -> GraphicsContext.ResolvedText {
            var t = ctx.resolve(Text(s).font(StrandFont.footnote))
            t.shading = .color(StrandPalette.textTertiary)
            return t
        }
        let wd = Calendar.current.veryShortWeekdaySymbols
        if wd.count == 7 {
            for r in stride(from: 0, to: 7, by: 2) {
                let y = Self.topInset + CGFloat(r) * (cell + Self.gap) + cell / 2
                ctx.draw(label(wd[(r + 1) % 7]), at: CGPoint(x: 0, y: y), anchor: .leading)
            }
        }
        let months = Calendar.current.shortMonthSymbols
        var lastMonth = -1
        for c in 0..<cols {
            guard let day = grid.columns[c].first(where: { $0.day != nil })?.day,
                  let m = Int(day.dropFirst(5).prefix(2)), m >= 1, m <= 12 else { continue }
            if m != lastMonth {
                lastMonth = m
                let x = Self.leftInset + CGFloat(c) * (cell + Self.gap)
                ctx.draw(label(months[m - 1]), at: CGPoint(x: x, y: 0), anchor: .topLeading)
            }
        }
        // Cells; today's cell and the tapped one get an outline so "where am I" reads at a glance (#222).
        for c in 0..<cols {
            let col = grid.columns[c]
            for r in 0..<7 {
                let rect = CGRect(x: Self.leftInset + CGFloat(c) * (cell + Self.gap),
                                  y: Self.topInset + CGFloat(r) * (cell + Self.gap),
                                  width: cell, height: cell)
                let path = Path(roundedRect: rect, cornerRadius: cell * 0.24)
                ctx.fill(path, with: .color(Self.heatColor(col[r].level)))
                if let day = col[r].day, day == selectedDay {
                    ctx.stroke(path, with: .color(StrandPalette.accent), lineWidth: 2)
                } else if col[r].day == today {
                    ctx.stroke(path, with: .color(StrandPalette.textPrimary), lineWidth: 1.5)
                }
            }
        }
    }

    /// Level (0 = no data, 1...4 by intensity) → the amber calorie ramp.
    static func heatColor(_ level: Int) -> Color {
        switch level {
        case 0: return StrandPalette.surfaceInset
        case 1: return StrandPalette.metricAmber.opacity(0.28)
        case 2: return StrandPalette.metricAmber.opacity(0.52)
        case 3: return StrandPalette.metricAmber.opacity(0.78)
        default: return StrandPalette.metricAmber
        }
    }
}
