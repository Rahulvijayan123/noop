# Nara design system

How the iPhone app looks and behaves, and the shared pieces every screen is built from. This is the
spec: when a screen and this file disagree, the screen is wrong. If a screen needs something this file
does not cover, add it here and to the kit rather than inventing a one-off.

The kit lives in `Packages/StrandDesign` (`Sources/StrandDesign`, charts in `Sources/StrandDesign/NaraChart`).
The page shell, `ScreenScaffold`, lives in the app (`Strand/Screens/ScreenScaffold.swift`). The kit only
draws values that screens pass in: nothing in it reads, computes, scores or stores health data, and
nothing on a screen should change BLE, sync, scoring or metric-computation code to suit a visual.

Contents: [Principles](#principles) · [Platforms](#platforms) · [Canvas and surfaces](#canvas-and-surfaces) ·
[Layout](#layout) · [Type](#type) · [Colour](#colour) · [Components](#components) ·
[Chart kit](#chart-kit) · [Detail pages](#detail-pages) · [Chart selection](#chart-selection) ·
[Rules for every chart](#rules-for-every-chart) · [Motion](#motion) ·
[Loading, empty and sparse states](#loading-empty-and-sparse-states) · [Copy](#copy) · [Migrating](#migrating)

## Principles

1. **The top level is a glance.** A tab root shows the day's state as values and short state words.
   It does not explain itself: no taglines, helper sentences, disclaimers, overlines, "Live"/"Just now"
   labels, decorative wordmarks, or progress bars that imply a goal that does not exist.
2. **Depth lives one tap down.** Every number on a top-level screen opens a detail page with its
   history, an interactive chart chosen for that kind of data, the statistics behind it and, at the
   bottom, the explanation and caveats.
3. **Charts match the data.** The chart type follows what was measured and how often
   ([Chart selection](#chart-selection)), not one generic graph. Missing days are gaps, never smoothed
   over. Every chart has a unit, labelled axes, a visible time range and a readout you can scrub.
4. **One of each.** One canvas, one card, one page header, one section header, one range control, one
   ring, one readout, one chart kit. Screens differ in what they show, not in how the pieces look.
5. **Nothing moves unless something changed.** No animated skies, scenic photos, glints, count-up
   numbers or staggered entrances. Motion marks navigation and data changes only.
6. **Loading never moves the layout.** Before data arrives a screen shows its real layout, redacted, at
   the final size. "No data" is only shown once loading has finished and there really is none.

## Platforms

- `StrandDesign` compiles for **iOS 16, macOS 13 and watchOS 10** (`Packages/StrandDesign/Package.swift`).
  The app's screens compile into the macOS app as well as the iPhone app, so shared screens must build
  for macOS 13 too.
- Chart files are wrapped in `#if !os(watchOS)` (Swift Charts and pointer hover are not on the watch).
  The non-chart components (`ScoreRing`, `ValueReadout`, `StatGrid`, `MetricTile`, `AboutDisclosure`,
  list rows, `PeriodStepper`, surfaces, placeholders) are cross-platform; `MetricTile`'s sparkline is
  dropped on watchOS.
- iOS 17 / macOS 14 APIs need an availability check or a shim: `chartXSelection`, `chartScrollableAxes`,
  `chartXVisibleDomain`, `chartScrollPosition`, `SectorMark`, `ContentUnavailableView`, `sensoryFeedback`,
  the two-parameter `onChange`. Use the existing shims: `onChangeCompat(of:perform:)`,
  `ChartProxy.plotRectCompat(in:)`, `strandHaptic(_:trigger:)`, `StrandHaptic.play()`.
- `HorizontalScrubSurface` is iOS-only (`#if canImport(UIKit) && os(iOS)`); the Mac scrubs with the pointer.
- No `@available(*, deprecated)` markers on kit API: they would flood every build with warnings. Older
  API keeps compiling and is listed in [Migrating](#migrating) instead.

## Canvas and surfaces

- **Canvas.** Every screen sits on the flat `StrandPalette.surfaceBase`. There is no sky, day-cycle
  scene, photo backdrop or in-card scenic hero anywhere. The old preference keys (`SceneBackgroundPrefs`,
  `SkyBehindCardsPrefs`, `BackgroundImagePrefs`, `CardAppearancePrefs`) stay readable for backups and
  Android parity but no longer draw anything.
- **Card.** `NoopCard` is the one card: `NoopPanelSurface` at `NoopMetrics.cardRadius` (20) with
  `NoopMetrics.cardPadding` (16) inside. The surface is a flat `surfaceRaised` fill with a 1 pt
  `hairline` border: no gradient, no gradient border, no tint, no transparency. Light mode keeps one
  shared soft shadow (radius 8, y 2, 5 % Deep Indigo) so a white card separates from the lavender canvas;
  dark mode has no shadow. `NoopPanelSurface(elevated: true)` is only for things that float over other
  content (tooltips, popovers) and lifts a little more in both schemes. `StrandCard`, `.frostedCardSurface()`,
  the app's `.naraCard()` and direct `NoopPanelSurface` calls all render the same surface; their `tint`
  and `surfaceOpacity` arguments are ignored.
- **Nested surfaces** inside a card (a stat cell, a chip row, an inset list) use `NoopInsetSurface`:
  `surfaceInset` at `NoopMetrics.insetRadius` (12), no border, no shadow. Never put a card inside a card.
- **Chrome** (sheet and split-view headers) uses `NoopChromeSurface`: the flat card fill with a hairline
  along the bottom edge.
- **Lists of settings-like rows** use `NoopListRow`s inside one card (`NoopListSection`), separated by
  `NoopListDivider` hairlines, never a stack of one-row cards.
- Domain colour belongs to data marks and icons, never to card fills or backgrounds.

## Layout

| Token (`NoopMetrics.`) | Value | Use |
| --- | --- | --- |
| `screenHPadding` | 20 | Left and right page margin on iPhone (`.screenPadding()`) |
| `desktopScreenPadding` | 28 | Page margin on the Mac (`ScreenScaffold`) |
| `readableColumnWidth` | 700 | Widest page column on iPad |
| `space6` | 24 | Top inset of the page column |
| `sectionGap` | 24 | Between sections of a page (the `ScreenScaffold` column spacing) |
| `gap` | 12 | Between cards in a grid; between a section header and its content |
| `cardPadding` | 16 | Inside a card |
| `cardInnerSpacing` | 12 | Between blocks inside a card |
| `space1` … `space10` | 4, 8, 12, 16, 20, 24, 32, 40 | The 4-pt ramp for everything else (`spaceHalf` 2 for paired labels) |
| `cardRadius` | 20 | Cards |
| `insetRadius` | 12 | Nested surfaces; the segmented-control track |
| `segmentRadius` | 9 | Selected segment (track radius minus `segmentedTrackPadding` 3, concentric) |
| `pillRadius` | 999 | Pills, chips, capsule buttons |
| `hairlineWidth` | 1 | Card and control borders, dividers |
| `segmentedHeight` | 32 | Segmented control / `RangeControl` segments |
| `readoutHeight` | 88 | `ValueReadout` (floor at the default text size) |
| `metricTileHeight` | 116 | `MetricTile` (floor); `metricTileTrendSlot` 28 more with a sparkline |
| `listRowMinHeight` | 52 | `NoopListRow` |
| `minimumHitTarget` | 44 | Smallest tap target (chevrons, header actions) |
| `controlHeight` | 48 | Buttons and fields |
| `tabBarClearance` | 76 | Bottom scroll room under the floating tab bar (`ScreenScaffold`) |
| `chartHeightPrimary` / `Secondary` / `Compact` | 240 / 160 / 120 | Chart plot heights (chart kit) |

Older names that say the same thing: `screenPadding` = `screenHPadding`, `sectionSpacing` = `sectionGap`,
`cardInnerPadding` = `cardPadding`, `NoopVisualStyle.pagePadding` = `screenHPadding`. `tileHeight` (96)
and `keyMetricTileHeight` (122) size the older tiles and stay as they are. `rowSpacing` (10) and
`NoopVisualStyle.compactRadius` (14, buttons) are off the ramp; do not use them in new code.

**Fixed heights.** Components that must not change height (`ValueReadout`, `MetricTile`, `StatGrid` rows,
`PeriodStepper`) reserve every line, keep each line to one line (`lineLimit(1)` + `minimumScaleFactor`),
and use the token as a floor. Their height therefore never depends on the values shown (scrubbing,
loading, empty, a missing state word), and at larger Dynamic Type sizes every instance grows by the same
amount, so a row of them still lines up.

Every page uses `ScreenScaffold`. A page's title appears once.

## Type

SF Pro only, sentence case, three weights (Regular, Medium, Semibold). Every role follows Dynamic Type.
Roles from `StrandFont`:

| Role | Font | Colour | Use |
| --- | --- | --- | --- |
| Page title | `title1` (28 semibold) | `textPrimary` | `ScreenScaffold` header on tab roots |
| Section title | `title2` (20 semibold) | `textPrimary` | `SectionHeader`, one line |
| Card title | `headline` (16 semibold) | `textPrimary` | Title inside a card |
| Label | `subhead` (14) | `textSecondary` | Metric name on a tile, stat labels: `Text.strandLabel()` |
| Body | `body` (16) | `textPrimary` / `textSecondary` | Sentences, only on detail pages and in About |
| Metadata | `footnote` (12) | `textTertiary` | Dates, legends, captions (`caption` is the same size) |
| Chart axis | `axis` (12, tabular) | `textTertiary` | Axis tick labels |
| Hero value | `display(40)` | `textPrimary` | `ValueReadout`, large ring centres |
| Tile value | `number(28)` | `textPrimary` | `MetricTile` |
| Stat value | `number(20)` | `textPrimary` | `StatGrid` cells |
| Small value | `captionNumber` (12 medium, tabular) | as context | Chips, compact readouts |
| Symbol | `icon(.inline / .tile / .row / .hero)` | as context | SF Symbols, sized by the text beside them |

- Numerals use only the four value roles above; anything over 42 pt is capped by `StrandFont.heroMaxSize`.
  `rounded(_:)` is an older alias of `number(_:)`.
- Symbols use `StrandFont.icon(_:)`, never `.font(.system(size:))`, so they scale with the text beside them.
- Overlines (spaced capitals, or a small label stacked above a title) are not used on content screens.
  `SectionHeader(_:overline:)` ignores its overline; `strandOverline()` is the older 13 Medium label, use
  `strandLabel()` instead.
- Units always sit next to values with a space (`62 ms`, `14.2 rpm`, `7 h 32 m`, `97 %`); the unit is
  drawn in `textSecondary`, never inside the value string's font. A missing value is `—` with no unit.

## Colour

The palette values in `StrandPalette` stay; the rules decide which role a colour plays.

- **Text** uses `textPrimary`, `textSecondary`, `textTertiary` only. Never hard-code white text, and
  never put text over an image. A score in a ring or readout is `textPrimary`; only a `ReadoutContent`
  `valueColor` (a score drawn in its band colour) may tint a value.
- **Links and actions use `accent` only**: "See all", "Show all", "Edit", chevrons, selected toggles.
  Never a data colour as a link (the pink "Full day" link, the purple "See all", the teal source name are
  all wrong).
- **Data** uses the domain colours (`chargeColor`, `effortColor`, `restColor`, `stressColor`,
  `metricCyan/Purple/Amber/Rose`), the sleep-stage colours for stages, and the score ramps for
  score-coloured marks. Several roles share one value (for example `chargeColor` = `statusPositive` =
  `metricCyan`), so colour alone can never tell state from domain on one screen.
- **Status is never conveyed by colour alone.** `statusPositive/Warning/Critical` reinforce a word: a
  `StatePill` always carries its word, a `MetricTile` state is a word, a chart legend names its marks.
- **Score bars use the scorer's own bands.** Bar and ring colours come from the thresholds the scorer
  uses (`RecoveryScorer.bandRedMax` / `bandYellowMax`, `StressBand`), passed to the chart kit as
  `ScoreBands`. The kit never defines its own bands, and a screen never invents a new set.
- Estimates are drawn hollow or hatched and named "Estimate" in a legend or state line, not shown in a
  different hue.

## Components

All in `Packages/StrandDesign` unless marked (app). Parameters below are the public API; see the source
doc comments for the reasoning.

### ScreenScaffold (app)

The page shell: flat canvas, scroll view, page margins, the header, the content column (spacing
`sectionGap`), pull-to-refresh, scroll-to-top on a tab re-tap and the iPad readable-width cap.

```swift
// Tab root: title1 header in the column.
ScreenScaffold(title: "Sleep", onRefresh: { await repo.refresh() }) { … }

// Pushed page: inline navigation-bar title, no in-content title; real layout redacted while loading.
ScreenScaffold(title: "Heart rate variability", titleDisplay: .navigationBar, isLoading: !loaded) { … }

// A page whose subtitle is data.
ScreenScaffold(title: "Run", dateLine: start.formatted(date: .abbreviated, time: .shortened)) { … }
```

- `titleDisplay: .header` (default; tab roots) or `.navigationBar` (pushed pages: `.navigationTitle` +
  inline display mode on iOS, no in-content title; trailing controls keep their header row). The Mac keeps
  the in-content header in both modes.
- `dateLine:` is the data-only line under the title (a date, a span, a count), drawn verbatim. `subtitle:`
  still works and must only carry data too; taglines go (the explanation belongs in the page's About).
- `isLoading:` renders the content column redacted, without taps, with one "Loading" VoiceOver element;
  the header stays readable. The content keeps its identity, so state and `.task`s survive the load.
- `trailing:` pins one header control (for example the settings button). `topBackground:` is kept for
  the remaining callers; new pages leave it nil.
- `ComingSoon`, `DataPendingNote`, `SyncingHistoryNote` and `relativeAgo` live beside it, unchanged.

### SectionHeader

One `title2` line, an optional trailing note, an optional action in `accent` (tap area grown to 44 pt
without making the row taller).

```swift
SectionHeader("Readings", trailing: "Last 7")
SectionHeader("Events", action: .link(label: "See all", value: TabRoute.events))
SectionHeader("Events", action: .link(label: "See all") { EventsListView() })   // no value destination
SectionHeader("Key metrics", action: .button(label: "Edit") { editing = true })
```

### NoopCard, NoopInsetSurface

```swift
NoopCard { Text("Resting heart rate").font(StrandFont.headline) }
Text("62 ms").padding(NoopMetrics.space3).background(NoopInsetSurface())
```

`NoopCard(padding:)` takes `0` for list cards. Its `tint:` is ignored.

### MetricTile

The top-level tile: icon + label, value + unit, one optional state word, an optional trend sparkline.
No progress bar, no helper caption.

```swift
MetricTile(icon: "waveform.path.ecg", iconColor: StrandPalette.metricPurple, label: "HRV",
           value: hrv.map(fmt), unit: "ms", state: "Within range", stateTone: .neutral,
           trend: last14, reservesTrendSlot: showsTrends, isEstimate: false, isLoading: !loaded)
```

- `value: nil` shows `—` with no unit. `state` is a word or short phrase coloured by `stateTone`
  (`.neutral` is `textSecondary`); `isEstimate` appends "Estimate" to the state line.
- Every tile in a grid has the same height: the state line is always reserved and every line is one
  line, with `metricTileHeight` as the floor. Pass the same `reservesTrendSlot` to every tile in a grid
  so tiles with and without a trend line up.
- Wrap it in `NavigationLink(value:)` with `.buttonStyle(.plain)`; it is one VoiceOver element.

### ScoreRing

The one ring for 0-100 scores: a flat `surfaceInset` track edged by hairlines, one solid arc in the
score's colour, the value centred in `textPrimary`, an optional caption.

```swift
ScoreRing(fraction: charge.map { $0 / 100 }, value: charge.map { "\(Int($0))" } ?? "—",
          caption: "Charge", color: chargeBands.band(for: charge ?? 0).color, diameter: 88)
```

- `fraction` is clamped to 0…1; `nil` (or NaN) draws the track alone with `—`.
- The centre numeral sizes itself to the well (about 28 pt in an 88 pt ring, up to `display(40)`).
- The arc eases 0.25 s when the score changes from one value to another; it does not sweep in on first
  load and does not move under Reduce Motion or the quiet-motion gate. No gradient, shadow, glow,
  end-cap dot or count-up.
- `isLoading` draws the track with a redacted centre. Replaces `RecoveryRing`, `BevelGauge`,
  `StrainGauge`, `LiquidVessel`, `LiquidScoreGauge` and `StressHeroGauge`; `GlowRing` stays for the watch
  and widgets.

### ValueReadout

The pinned header above a detail chart and its tooltip: date line (footnote, `textSecondary`), hero
value (`display(40)`) + unit (`title2`, `textSecondary`), one context line (subhead).

```swift
ValueReadout(ReadoutContent(dateLine: ReadoutContent.dateLine(day, period: .night),
                            value: fmt(hrv), unit: "ms",
                            context: selected == nil ? "7-day avg 61 ms" : "+4 ms vs typical"),
             isScrubbing: selected != nil, isLoading: !loaded)
```

- `ReadoutContent(dateLine:value:unit:context:valueColor:isEstimate:)`. `value: nil` is `—` with no unit;
  `valueColor` is for a score's band colour only; `isEstimate` adds an "Estimate" pill.
- `ReadoutContent.dateLine(_:period:)` formats the date line in the user's locale: `.day` "Tue 7 Oct",
  `.night` "Mon 6 – Tue 7 Oct" (from the wake day), `.week` "Week of 29 Sep", `.month` "Sep 2026",
  `.time` "Tue 7 Oct, 14:05"; the year is added outside the current year.
- Fixed height (`readoutHeight` floor, context line reserved); values swap with no animation even inside
  someone else's transaction; one VoiceOver element, marked as updating frequently while scrubbing.
- A convenience that builds the content from a chart's `DailyPoint` (latest or selected) belongs beside
  `DailyPoint` in `NaraChart/`, as an extension on `ReadoutContent`; the readout itself does not depend on
  the chart types, so it stays available on watchOS.

### StatGrid

Two to four statistics for the visible range in **one** card, each cell on `NoopInsetSurface`: label
(subhead, `textSecondary`), value `number(20)` + unit, optional detail line (footnote, `textTertiary`).

```swift
StatGrid([StatItem("Average", value: "61", unit: "ms"),
          StatItem("Typical", value: "54–68", unit: "ms"),
          StatItem("Low", value: "42", unit: "ms", detail: "30 Sep"),
          StatItem("High", value: "88", unit: "ms", detail: "3 Oct")],
         columns: 2, isLoading: !loaded)
```

Rows have one height (when any item has a detail every cell reserves the line); columns are clamped to
1…4 and never exceed the item count; a short last row keeps the column widths. Use `columns: 4` on the
Mac. Replaces the detail pages' Average/Min/Max/Δ/Latest `StatTile`s and `ChartFooter`.

### Lists: NoopListRow, NoopListSection, NoopListDivider, ReadingsList

```swift
NoopListSection("Data", footer: "Everything stays on this iPhone.") {
    NavigationLink(value: TabRoute.devices) {
        NoopListRow(icon: "sensor", title: "Devices", value: "WHOOP 4.0")
    }
    NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
    NavigationLink(value: TabRoute.storage) {
        NoopListRow(icon: "internaldrive", title: "Storage", subtitle: "Last cleaned 3 days ago")
    }
}
.buttonStyle(.plain)

ReadingsList(rows: readings, visibleCount: 7, onShowAll: { showAll = true })
```

- `NoopListRow(icon:iconColor:title:subtitle:value:showsChevron:)`: icon in a 28 pt column (`icon(.row)`),
  title in body, optional one-line subtitle, value in `textSecondary`, chevron in `textTertiary`; at least
  52 pt tall, the whole row is the tap target.
- `ReadingsList` shows the newest `visibleCount` readings (date and source on the left, value on the
  right; the source in `textTertiary`), then "Show all" with the count when there are more.

### PeriodStepper

"‹ Last night · Mon 6 – Tue 7 Oct ›": one look for stepping nights, days and weeks.

```swift
PeriodStepper(title: "Last night", subtitle: ReadoutContent.dateLine(wake, period: .night),
              canGoBack: hasOlder, canGoForward: offset > 0,
              onBack: { offset += 1 }, onForward: { offset -= 1 }, onTitleTap: { picking = true })
```

44 pt chevrons in `accent`, an end that cannot move is `textTertiary` and disabled, the centre is a
button only when `onTitleTap` is set (open a date picker), one 44 pt line, a selection haptic per step.
Replaces `DayNavBar`, the Trends week chevrons, the Full-day "Today" chevrons and the Sleep night chip.

### AboutDisclosure

The collapsed card at the bottom of a detail page for method, caveats and disclaimers.

```swift
AboutDisclosure("About HRV", paragraphs: ["Heart rate variability is …", "Nara compares …"])
AboutDisclosure { Text("Scored on this iPhone."); NoopButton("How it is scored", kind: .tertiary) { … } }
```

Title row with a chevron (52 pt), body paragraphs in `textSecondary` below a hairline when open; it only
grows downward.

### Loading placeholder

```swift
someCard.loadingPlaceholder(!loaded)
```

Redacts the real layout (`.redacted(reason: .placeholder)`), turns off taps, and adds one "Loading"
VoiceOver element (the redacted content itself is hidden from VoiceOver on iOS 18 / macOS 15 and later).
Static (no shimmer). Value modifiers only, so the view keeps its identity, state and `.task`s when
loading ends. Apply it to one view. For a column of several views use `.loadingRedaction(_:)` plus one
`LoadingAccessibilityElement` for the group; `ScreenScaffold(isLoading:)` does exactly that for a page.
`ValueReadout`, `StatGrid`, `MetricTile` and `ScoreRing` take `isLoading:` directly and draw
representative-width placeholders instead of `—`. Charts use `ChartPlaceholder` (chart kit).

### Controls and small pieces

- `SegmentedPillControl(items, selection:, fillsAvailableWidth:, isEnabled:, label:)`: the one segmented
  control. `surfaceInset` track at `insetRadius`, selected segment `surfaceRaised` + hairline at
  `segmentRadius`, segments `segmentedHeight` tall, selection haptic built in, neutral (never tinted).
  `RangeControl` (chart kit) wraps it for time ranges.
- `StatePill(_:tone:showsDot:)`: the one status pill, always with its word. `SourceBadge`: provenance.
  `TrendChip(text:color:)`: a delta (`+4 bpm`), laid out at its full width so it never truncates
  mid-number; pass a number and unit, not a sentence.
- Buttons: `NoopButton` / `NoopButtonStyle(kind:)` only. Press feedback on tappable cards:
  `StrandPressableButtonStyle` (kit) or `LiquidPressStyle` (app) until they merge.
- Haptics: `StrandHaptic` / `.strandHaptic(_:trigger:)` only.
- `StatTile` (older value tile): label in the Label role, value in `textPrimary`, the metric colour only
  on its sparkline (`sparkColor`), caption line reserved so tiles in a row line up. Kept for existing
  call sites; new top-level tiles are `MetricTile`, new detail statistics are `StatGrid`.

## Chart kit

`Packages/StrandDesign/Sources/StrandDesign/NaraChart/`, all `#if !os(watchOS)`. Screens pass already
computed values; the kit draws them. This section is the API contract the chart files are built to; where
a detail differs in the source, the source's doc comment is authoritative and this section is updated in
the next pass.

### Range: `ChartRange` + `RangeControl`

```swift
public enum ChartRange: String, CaseIterable { case week = "W", month = "M", quarter = "3M", half = "6M", year = "Y", all = "All" }
// .label, .accessibilityName ("1 week" …), .days (7, 30, 90, 180, 365, nil), .axisStyle,
// .totalsBin (.day, .day, .weekOfYear, .month, .month, .month)
RangeControl(selection: $range, options: ChartRange.allCases, isAvailable: { unlocked($0) })
```

- Labels are `W M 3M 6M Y All` everywhere. The control shows only the ranges the history can fill (plus
  All) and hides itself when one option remains: no disabled "Y" between "6M" and "All", and no "Longer
  ranges unlock…" helper. 2W and 3W are no longer offered (data windows may still use them).
- The app bridges to its data window with `ExploreRange(_ r: ChartRange)` and `ExploreRange.chartRange`,
  keeping `ExploreRangeGating` as the rule. The other range enums (`TrendsView.Range`, `IntelRange`,
  `CompareRange`, `XiaomiBandView.RangeWindow`, `AppleHealthView.RangeWindow`, `WorkoutsView.Range`,
  `ReportRange`) are replaced by `ChartRange` or a subset passed as `options:`.
- Changing the range clears the selection and animates the marks for 0.25 s.

### Shared types

- `DailyPoint(day:value:isEstimate:series:)`: one value per local day (a night belongs to its wake day),
  plotted with `unit: .day` so it sits in the middle of its day. `DailyPoint(_ point: TrendPoint)` bridges.
- `ChartCadence`: `.daily`, `.weekly`, `.sparse(maxGapDays:)`, `.buckets(seconds:)`, `.adaptive`; decides
  where lines break (`ChartGaps.runs`, built on `TrendChart.gapSegments` and `hrGapSegments`).
- `ChartDomain`: `.fixed(range)` whenever the metric has a natural scale (0-100, 85-100, 0-3, 1-5),
  `.fitted(minSpan:includeZero:clampTo:headroom:)`, `.symmetric(minMagnitude:)` for diverging data.
- `ChartValueAxis(unit:domain:tickCount:ticks:format:)`: the unit is drawn above the y-axis.
- `ChartReference(value, label:, style:)`: a labelled horizontal rule (baseline, 95 %, goal, sleep need),
  label at the trailing edge.
- `ScoreBands`: bands built by the app from the scorer's thresholds, for bar colours.
- `ChartLegendItem` + `ChartLegend`: swatch, line, band or estimate marks with names; a legend item can
  toggle a series (HRV's SDNN).
- `ChartState`: `.loading`, `.empty(message)`, `.ready`. A chart frame never changes height between states.

### Axes, scrub, placeholders

- `ChartAxis.window(range, firstDataDay:)`: the x window is the selected range ending today, so missing
  days at the start read as gaps. `ChartAxis.marks` / `.format`: weekday for W, day of month for M (month
  name on the first mark of a month), month for 3M-Y, month + year for All, clock hours intraday
  (`chartTimeTicks`); never the same label twice; first and last labels inset so they never clip.
  Built on `ChartAxisDays` and `chartTimeTicks`.
- `.naraChartAxes(x:style:y:yDomain:)`: leading y with the unit on top, `axis` font in `textTertiary`,
  a `hairline` grid at 40 %.
- `.chartScrub(xs:selection:pinsOnTap:)`: iPhone sideways drag on `HorizontalScrubSurface` (a vertical
  swipe still scrolls the page), tap pins the nearest point; Mac pointer hover, click pins. Snaps to the
  nearest point, one selection haptic per new point, no animation, a VoiceOver adjustable action that
  steps the selection. `SelectionRule` draws the 1 pt `textSecondary` rule.
- `ChartPlaceholder(height:)` reserves a chart's frame (axis gutters, faint grid, static) while loading;
  `EmptyChartMessage(_:height:)` is one short footnote line centred in an empty frame of the same height.
- Heights: `NoopMetrics.chartHeightPrimary` (240, the detail chart), `chartHeightSecondary` (160),
  `chartHeightCompact` (120, Today's HR card, the sleep HR strip).

### Chart types

Every chart takes `window`, `xStyle`, `y: ChartValueAxis`, `selection: Binding<Date?>`, `height`,
`state: ChartState` and `accessibilityTitle`, attaches an audio graph (`accessibilityChartDescriptor`)
and a one-line summary ("Heart rate variability, 30 nights, 56 to 104 ms").

| Chart | For | Key parameters |
| --- | --- | --- |
| `DailyBarChart` | Scores, daily totals, durations | `fill: .single(color) / .bands(ScoreBands)`, `bin`, `meanLine: 7`, `reference` (goal, need); `.scores(…)`, `.totals(…)` |
| `DailyLineChart` | Nightly / daily vitals | `series` (multi), `cadence`, `marks: .pointsAndLine / .pointsOnly / .lineOnly`, `typicalBand`, `rollingBand`, `baseline`, `reference`; `.fixedDomainPoints(domain:reference:)` |
| `DivergingBarChart` | Skin-temperature deviation | `positive`, `negative`, `positiveLabel`, `negativeLabel`; y `.symmetric` |
| `RangeBarChart` | Bedtime → wake per night | `items` (start, end, estimate), `anchorHour: 18`, `typicalStart/End` |
| `StackedBarChart` | Sleep stages, HR zones, macros | `categories`, `highlighted`, `normalised` |
| `DotStripChart` | Mood 1-5 | `levels`, `levelLabels`, colour per level |
| `SparsePointsChart` | Weight, body fat, BMI | `trend: .rollingMedian(days: 14)` (display only), `cadence: .sparse(maxGapDays: 21)` |
| `StepLineChart` | VO2 max, Fitness age, Vitality, Body age | `.stepEnd` line + points at readings, `reference` |
| `IntradayChart` | Heart rate through the day, stress through the day, event physiology | `samples`, `bucketSeconds` (gap rule), `bands` (sleep, workout, event), `markers`, optional `zoom`, `compact`, `live` |

Marks shared by all: lines 2 pt with round caps and `.monotone` interpolation (never Catmull-Rom, never
midpoint smoothing); points `symbolSize(24)`, hollow for estimates; bars `cornerRadius(3)` binned with
`unit: .day / .weekOfYear / .month`; bands at 12 % of the series colour; references 1 pt dashed `[4, 4]`
`textSecondary` with a trailing footnote label; plots clipped; lines above 120 points downsampled with
`ChartDownsample.minMaxBucketed` (bars bin instead). `TrendChart` and `OverviewHRChart` stay as legacy
until their screens move to these.

## Detail pages

Every metric or section drill-down has the same anatomy, top to bottom:

1. The navigation bar with the inline title, once (`ScreenScaffold(titleDisplay: .navigationBar)`). No
   in-content title, category overline or tagline.
2. `ValueReadout`: the latest value, or the value under the finger while scrubbing, with its date and
   one context line ("7-day avg 61 ms", "+4 bpm vs typical", "3 readings").
3. `RangeControl`, when there is history to page through.
4. The primary chart card, chosen per metric ([Chart selection](#chart-selection)), with its legend.
5. Secondary visuals only where they say something the primary chart cannot (stage composition, band
   mix, weekday pattern, distribution, the night's hypnogram, "Today" intraday, "What shaped it").
6. `StatGrid` for the visible range (four cells; the cells are listed per metric below).
7. Existing context modules (measurement context, banked readings, correlations), restyled with kit pieces.
8. `ReadingsList`: the newest seven with "Show all".
9. `AboutDisclosure`: what the metric is, how it is measured, caveats and any disclaimer.

```swift
@State private var range: ChartRange = .month
@State private var selected: Date?

ScreenScaffold(title: "Heart rate variability", titleDisplay: .navigationBar, isLoading: !loaded) {
    ValueReadout(readout(for: selected ?? latest), isScrubbing: selected != nil, isLoading: !loaded)
    RangeControl(selection: $range, isAvailable: { unlocked(ExploreRange($0)) })
    NoopCard {
        DailyLineChart(series: [.init(id: "hrv", name: "HRV", color: StrandPalette.metricPurple, points: windowed)],
                       typicalBand: typical, baseline: ChartReference(base, label: "Baseline \(fmt(base))"),
                       state: chartState, window: ChartAxis.window(range, firstDataDay: first),
                       xStyle: range.axisStyle, y: ChartValueAxis(unit: "ms", domain: .fitted(minSpan: 20)),
                       selection: $selected, accessibilityTitle: "Heart rate variability")
    }
    StatGrid(stats, isLoading: !loaded)
    ReadingsList(rows: rows, onShowAll: { showAll = true })
    AboutDisclosure("About HRV", paragraphs: about)
}
.onChangeCompat(of: range) { _ in selected = nil }
```

A card that contains a scrubbable chart is not itself a link; its header row is.

## Chart selection

What each kind of data is drawn as. "Line + gaps" is points joined by monotone segments that break
across missing days, with no area fill. "Band" is the personal typical range (drawn only once it is
trusted, 14 valid nights). Daily totals bin by range (`ChartRange.totalsBin`): daily bars at W and M,
weekly average bars at 3M, monthly average bars at 6M and longer. Default range is M unless noted.

| Data | Cadence | Primary chart | Readout context / StatGrid |
| --- | --- | --- | --- |
| Charge (recovery), Rest (sleep performance) | one score per day / night | `DailyBarChart.scores` on a fixed 0-100 axis, each bar in its scorer band, dashed 7-day mean | "7-day avg 44 %" · Average, Low, High, Days ≥ 67 (Rest: Nights ≥ 85) |
| Effort (strain) | daily score | Score bars on fixed 0-100 (or 0-21 with the Effort scale setting), `effortTint`, 7-day mean; weekday pattern at 3M+ | Average, Low, High, vs previous |
| Sleep score (Mi Band), Stress (Mi Band, 0-100) | nightly / daily | Score bars on fixed 0-100, coloured by the source's own bands | Average, Low, High, vs previous |
| Day stress (from the WHOOP import) | daily 0-3 | Bars on a fixed 0-3 axis coloured by `StressBand` | Average, High days, Low, High |
| HRV, resting HR, respiratory rate, average HR | nightly / daily | `DailyLineChart`: line + gaps, band, dashed baseline; y fitted with a minimum span (HRV 20 ms, HR 10 bpm, resp 3 rpm). HRV's SDNN is an off-by-default second series | "7-day avg 82 ms · typical 74-96 ms" · Average, Low, High, Typical |
| Max heart rate | daily | Points + thin line + gaps | Highest (with date), Average, Low, vs previous |
| Blood oxygen | nightly | Points only on a fixed 85-100 % axis with a 95 % reference rule; strap estimates hollow ("Strap estimate"); "Every reading" card below | "lowest 94 % on 2 Oct" · Average, Lowest night, Nights below 95 %, Nights |
| Skin temperature (deviation) | nightly | `DivergingBarChart` around zero, warm above (`metricAmber`), cool below (`metricCyan`), ±0.5 dashed rules | Average, Warmest, Coolest, Nights > +0.5 |
| Skin temperature (absolute) | nightly | Line + gaps with the band, in the displayed unit | Average, Low, High, Typical |
| Asleep time | nightly | Bars in h:mm against the sleep-need line, 7-day mean | "6 h 42 m · 48 m below need" · Average, Shortest, Longest, Nights ≥ need |
| Time in bed | nightly | Bars in h:mm; asleep drawn as the inner solid bar when it exists | Average, Shortest, Longest, vs previous |
| Hours vs needed | nightly | Bars with a 100 % rule | Average, Nights ≥ 100 %, Low, High |
| Sleep need | nightly | Line + gaps in h:mm with asleep bars behind it | Average, Low, High, Nights met |
| Sleep debt | nightly, never negative | Bars from zero in `metricRose` (not diverging) | Average, Max, Nights with no debt, vs previous |
| Sleep consistency | nightly score | Score bars on fixed 0-100; when sleep sessions are available, floating bedtime → wake bars (`RangeBarChart`) as the secondary chart | Average, Low, High, vs previous |
| Sleep efficiency | nightly | Line + gaps on a fixed 50-100 % axis with an 85 % rule | Average, Low, High, Nights ≥ 85 % |
| Deep, REM, light sleep | nightly | `StackedBarChart` of the night's stages, the page's stage highlighted, others at 30 % | Average, Low, High, Share of sleep |
| Restorative sleep (share / time) | nightly | Share: line + gaps on 0-60 %. Time: stacked deep + REM bars | Average, Low, High, vs previous |
| Steps, calories, active energy | daily total | `DailyBarChart.totals`, goal line where one exists, binned by range; on-device estimates hatched ("Estimate") | "avg 8,420 steps/day" · Average per day, Total, Best day, vs previous |
| Calories in, protein, carbs, fat | logged days | Bars on logged days; macro mix stacked as a secondary | Average per logged day, Days logged, High, Low |
| HR zone minutes (Z1-3, Z4-5), strength time | workout days only | Bars on the full calendar (an absent day is 0, not a gap), weekly totals at 3M+ | Total, Average per workout day, Active days, High |
| HR zones (all) | workout days | Stacked zone bars Z1-Z5 | Total, Average per workout day, Z4-5 share, Active days |
| Intensity minutes | daily | Weekly total bars with a 150 min/week rule (daily bars at W); default 3M | This week, Weekly average, Weeks ≥ 150, Best week |
| Weight, body fat, lean mass, BMI | sparse | `SparsePointsChart`: each reading a point, a smoothed trend line (display only), no area; BMI with faint 18.5 / 25 / 30 rules; default 3M (weight) or 6M | "−1.2 kg since Jul" · Latest, Change, Low, High |
| VO2 max, VO2 max (estimated), Fitness age, Vitality, Body age | weekly or sparse | `StepLineChart` (points + step line), default 6M; estimates hollow, a change of method breaks the line; Fitness/Body age with a dashed "Your age" rule; Vitality on fixed 0-100 | Latest, Change over range, High, Readings |
| Mood | daily 1-5 | `DotStripChart` on a fixed 1-5 axis, no interpolation; distribution as a secondary | Average, Most common, Days logged, vs previous |
| Hydration | daily total with a real goal | Bars + goal rule | Average, Days at goal, Total, High |
| Lab markers | sparse, irregular | Points on a date axis joined by straight lines, unit axis, no area | Latest, Change, Low, High |
| Heart rate through the day | per second / 5-min buckets | `IntradayChart`: time axis, sleep and workout bands, breaks where a bucket is missing, scrub | Resting, High, Low |
| Stress through the day | sliding hourly 0-3 | `IntradayChart` on a fixed 0-3 axis with band shading, hatched "Moving" gaps | — |
| Sleep stages through the night | 30 s epochs | `Hypnogram` with stage labels and hourly ticks, `MotionTrace` beneath | — |
| Correlation, dose-response | pairs / categories | Scatter with axis titles and units; categorical points + line, hollow when "typical" | — |

## Rules for every chart

- The y-axis shows the unit in the displayed unit system, and uses a fixed domain where the metric has
  one (0-100 scores, 85-100 % oxygen, 50-100 % efficiency, 0-3 stress, 1-5 mood). Fitted domains have a
  minimum span so small wobbles do not fill the card.
- The x window is the selected range ending today, not the data's extent. Daily values sit at the centre
  of their day. Labels adapt to the range and never repeat; the first and last never clip.
- Daily charts plot each `yyyy-MM-dd` key at the local start of that day; never pass UTC midnights.
- Lines break across gaps longer than the metric's cadence. Fewer than three points are drawn as points
  only. No area fill under a line that is not a cumulative quantity. No smoothing that overshoots the
  data or misplaces a peak (no Catmull-Rom, no midpoint curves); straight or monotone segments only.
- References (baseline, 95 %, goal, sleep need, "Your age") are labelled at the trailing edge.
- Scrubbing (a sideways drag on iPhone, the pointer on the Mac) moves a selection rule and drives the
  `ValueReadout`; a tap pins the nearest point; non-selected bars drop to 35 %. No floating tooltips on
  detail charts: the readout is the tooltip.
- Estimated or derived values are drawn hollow or hatched and say "Estimate" in the legend.
- Deltas: percentages change in points, deviations in the signed unit; never a percent change of a
  percentage or of a deviation.
- Progress bars and goal rings appear only where a real target exists (hydration goal, steps goal,
  sleep need).

## Motion

- Navigation uses the system push, sheet and tab transitions.
- Changing a chart's range animates the marks for 0.25 s; a selection never animates; values swap
  without counting up (no `contentTransition(.numericText())` on metric values).
- `ScoreRing`'s arc eases 0.25 s between two scores, never on first load. `AboutDisclosure` opens with a
  0.2 s ease.
- A selection change gives one light selection haptic per new point; a `PeriodStepper` step and a
  segment change give one too.
- Nothing loops on screen except a genuinely live signal (the live heart rate). Every never-settling
  animation consults the quiet-motion gate (`NoopMotionState.poseStill`), and the census in
  `QuietMotionCoverageTests` is updated in the same commit whenever a decorative loop is removed.
- Respect Reduce Motion and the quiet-motion gate everywhere motion exists.

## Loading, empty and sparse states

- Before the first load, render the real layout redacted: `ScreenScaffold(isLoading:)` for the page,
  `.loadingPlaceholder(_:)` for a single card, `isLoading:` on `ValueReadout`, `StatGrid`, `MetricTile`
  and `ScoreRing`, `ChartState.loading` (`ChartPlaceholder`) for charts. Never show "No data", an
  import prompt or an empty-state sentence before loading has finished, and never show a caption only
  while loading.
- A range control's options are decided once the history span is known; do not show every range while
  loading and then remove some.
- An empty chart keeps its frame and shows one short `EmptyChartMessage` inside it, never a message
  above the frame and another inside it.
- An empty section is one quiet line (`ComingSoon` / `DataPendingNote`), not an icon tile with a
  headline.
- With only a few readings, show them as points and say how many in the readout's context line
  ("3 readings").

## Copy

- Say Nara, never NOOP, in anything the user reads.
- No helper sentences, taglines or disclaimers on top-level screens or in page subtitles. Explanations
  go to the detail page's `AboutDisclosure` (or Settings help).
- Short state words over sentences ("Within range", "Low", "On track").
- Units next to values with a space (`62 ms`, `97 %`, `7 h 32 m`); `—` (em dash) for a missing value,
  with no unit.
- Sentence case everywhere, including section titles and buttons. No ALL CAPS.
- A title appears once per page; a value appears once per page (the readout), not again in a chart
  card's header or a "Latest" tile.

## Migrating

The older pieces keep compiling (no deprecation markers). When a screen is touched, move it as follows.

| Older | Use instead |
| --- | --- |
| `NoopPanelSurface(tint:…, surfaceOpacity:…)`, `NoopCard(tint:)`, `StrandCard(tint:)` | Drop the arguments (ignored) |
| `SectionHeader(_:overline:)`, `Text(…).strandOverline()` above a title | Drop the overline |
| `.strandOverline()` as a value label | `.strandLabel()` |
| `NaraSectionHeader(seeAll:)` (app) | `SectionHeader(_:action: .link(…))` |
| `.naraCard()` (app) | `NoopCard` |
| `StatTile` on a top-level grid; LiquidToday `ktile`; `LiquidVitalTile` | `MetricTile` |
| Detail-page Average/Min/Max/Latest `StatTile`s, `ChartFooter` | `StatGrid` |
| `ChartCard(subtitle:trailing:)`, `TrendChart.largeSelection`, hero numbers, `CountUpText` / `CountUpNumber` | `ValueReadout` above the chart in a `NoopCard` |
| `RecoveryRing`, `BevelGauge`, `StrainGauge`, `LiquidVessel`, `LiquidScoreGauge`, `StressHeroGauge` | `ScoreRing` |
| `LiquidTube` / progress bars on tiles without a target | Nothing |
| `PipBar`, `InsightCard`, `ScoreStatePill` | Plain text, `NoopCard` + text, `StatePill` |
| `DayNavBar`, ad-hoc chevrons and date chips | `PeriodStepper` |
| Settings-like card stacks, `SettingsGroup`-style wrappers | `NoopListSection` + `NoopListRow` + `NoopListDivider` |
| Unbounded readings tables | `ReadingsList` |
| Caveat sentences under heroes and charts | `AboutDisclosure` |
| `ScreenScaffold(subtitle: "tagline")` | Remove it; dates and spans go in `dateLine:` |
| `ScreenScaffold(topBackground: liquidScaffoldSky())`, `ScenicHeroBackground` | Remove (flat canvas) |
| `.navigationTitle(x)` + an in-content title on a pushed page | `ScreenScaffold(title: x, titleDisplay: .navigationBar)` |
| `ComingSoon` / "No data" shown while loading | `isLoading:` / `.loadingPlaceholder(_:)` |
| `.font(.system(size: n))` on a symbol | `.font(StrandFont.icon(_:))` |
| `.staggeredAppear(index:)` | Delete the call |
| `TrendChart`, `OverviewHRChart`, app-side charts | The chart kit type from [Chart selection](#chart-selection) |
| Per-screen range enums, `Picker(.segmented)` for ranges | `ChartRange` + `RangeControl` |
| `ChartTooltip` floating over a detail chart | The `ValueReadout` |
| `NoopPrimary/Secondary/GhostButtonStyle` | `NoopButton` / `NoopButtonStyle(kind:)` |
| `liquidTapHaptic` and friends (app) | `StrandHaptic` / `.strandHaptic(_:trigger:)` |
