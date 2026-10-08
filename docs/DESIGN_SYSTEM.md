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
- Chart views are wrapped in `#if !os(watchOS)` (Swift Charts and pointer hover are not on the watch);
  the chart data types, `ChartRange`/`RangeControl`, `ChartLegend`, the placeholders and the `DailyPoint`
  readout bridge build there too. The non-chart components (`ScoreRing`, `ValueReadout`, `StatGrid`,
  `MetricTile`, `AboutDisclosure`, `InlineNotice`, list rows, `PeriodStepper`, surfaces) are
  cross-platform; `MetricTile`'s sparkline is dropped on watchOS.
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
- The value and unit are one line drawn at the largest of full size, 85 %, 72 % or 60 % that fits (the
  line keeps its full height), so a long value ("12,345,678 steps") shrinks as a whole instead of being cut,
  and the "Estimate" pill always shows. The context line scales to 70 % and then ends in "…": keep it short.
- Build the content from the chart's own values with the bridge in `NaraChart/ReadoutBridge.swift`:
  `ReadoutContent.daily(selection:in:bin:nightly:unit:format:context:valueColor:)`,
  `ReadoutContent.daily(_ point:unit:format:context:period:valueColor:fallbackDate:)`,
  `ReadoutContent.intraday(selection:in:unit:format:context:)` and `ReadoutContent.Period(bin:nightly:)`
  (see [The readout above a chart](#the-readout-above-a-chart)). The `DailyPoint` forms build on watchOS too.

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
1…4 and never exceed the item count; a short last row keeps the column widths. A value that does not fit
its cell steps down in size as one piece with its unit (never "252,6… steps"); labels scale to 70 % and
then end in "…", so keep them to a word or two. Use `columns: 4` on the Mac (on a phone 4 columns cut
labels). Replaces the detail pages' Average/Min/Max/Δ/Latest `StatTile`s and `ChartFooter`.

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

- `NoopListRow(icon:iconColor:title:subtitle:value:valueTone:showsChevron:)`: icon in a 28 pt column
  (`icon(.row)`), title in body, optional one-line subtitle, value in `textSecondary` (or `valueTone`'s
  colour for a state word: `NoopListRow(icon: "sensor", title: "Strap", value: "Re-pair to sync",
  valueTone: .warning)`), chevron in `textTertiary`; at least 52 pt tall, the whole row is the tap target.
- `NoopListDivider()` insets to the card padding; `NoopListDivider(leadingInset: NoopListDivider.iconRowInset)`
  lines up with the titles of icon rows; `leadingInset: 0` spans the card.
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

### InlineNotice

The one notice for a state that needs a sentence (re-pair the strap, history still syncing, Apple Health
not connected, an unencrypted backup), with at most one action. It replaces per-screen banners with
coloured strokes, tinted fills or icon tiles.

```swift
InlineNotice("Your strap needs re-pairing before it can sync.", tone: .warning,
             action: .init("Re-pair") { showRepair = true })
InlineNotice("History is still syncing from your strap.", title: "Syncing")
NoopCard { InlineNotice("Apple Health is not connected.", placement: .inCard) }
```

`tone` (`StrandTone`) picks the symbol and its colour; the fill stays neutral (a card on the page,
`NoopInsetSurface` with `placement: .inCard`); text is `textPrimary` / `textSecondary`; the action is one
accent text button with a 44 pt target. One or two lines of message: longer explanations go to About.

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
  on its sparkline (`sparkColor`), caption line reserved and spare height at the bottom, so the labels and
  values of a row line up whether or not a tile has a sparkline. Kept for existing call sites; new
  top-level tiles are `MetricTile`, new detail statistics are `StatGrid`.

## Chart kit

`Packages/StrandDesign/Sources/StrandDesign/NaraChart/`. The views are `#if !os(watchOS)`; the data types
(`DailyPoint`, `ChartDay`, `ChartDomain`, `ChartValueAxis`, `ChartReference`, `ScoreBands`, `ChartState`,
`ChartRange`, `RangeControl`, `ChartLegend`, `ChartPlaceholder`, the `ReadoutContent` bridge) build everywhere.
Screens pass values they have already computed; the kit lays them out and never scores anything. This
section is the API the screens code against; every signature here is in the source (the doc comments carry
the reasoning). `TrendChart`, `OverviewHRChart` and `Hypnogram` are untouched legacy views.

### Which chart for which data

| Data | Cadence | Kit chart |
| --- | --- | --- |
| A score per day or night (Charge, Rest, Effort, day stress, sleep score) | daily, fixed scale | `DailyBarChart.scores(_:bands:)` or `.scores(_:ramp:)`, `bin: shown.totalsBin(for: window)` |
| A daily total or duration (steps, calories, asleep time, zone minutes, sleep debt) | daily | `DailyBarChart.totals(_:color:goal:bin:aggregation:)` |
| A nightly or daily vital (HRV, resting HR, respiratory rate, average HR, absolute skin temp) | daily | `DailyLineChart(series:typicalBand:baseline:)` |
| A percentage on a fixed scale (blood oxygen, sleep efficiency) | daily | `DailyLineChart.fixedDomainPoints(_:domain:reference:color:joined:)` |
| A deviation around zero (skin-temperature deviation) | daily | `DivergingBarChart(points:positive:negative:…)`, `bin: shown.totalsBin(for: window)` |
| A span per night (bedtime to wake, time in bed as a window) | nightly | `RangeBarChart(items:color:)`, `bin: shown.totalsBin(for: window)` |
| Parts of a whole per day (sleep stages, HR zones, macros, asleep inside time in bed) | daily | `StackedBarChart(days:categories:highlighted:)`, `bin: shown.totalsBin(for: window)` |
| A level on a named scale (mood 1-5) | logged days | `DotStripChart(points:levels:levelLabels:color:)` |
| Irregular readings with a smoothed direction (weight, body fat, lean mass, BMI) | sparse | `SparsePointsChart(points:color:)` |
| An estimate held until the next one (VO2 max, fitness age, vitality, body age) | weekly / sparse | `StepLineChart(points:color:reference:)` |
| Irregular readings joined straight (lab markers) | sparse | `DailyLineChart(cadence: .sparse(maxGapDays: 365), interpolation: .linear)` |
| A signal through the day (heart rate, stress, skin temp, physiology around an event, live trace) | seconds / buckets | `IntradayChart(samples:bucketSeconds:)` |
| Sleep stages through one night | 30 s epochs | `Hypnogram` (existing, not a kit chart) |
| Correlation, dose-response, calendar heatmap, zone bars, aligned recovery curves, treatment lanes | — | Not in the kit yet: keep the screen's current view and flag it to the kit owner |

### Every chart

Every chart is a `View` with the same tail of parameters, in this order:

```swift
…, legend: [ChartLegendItem]? = nil,          // nil: the automatic legend; []: none
   state: ChartState = .ready,                // .loading / .empty("No readings yet") / .ready
   window: ClosedRange<Date>,                 // ChartAxis.window(shown, firstDataDay: …)
   xStyle: ChartAxisStyle,                    // shown.axisStyle (IntradayChart has no xStyle: always hours)
   y: ChartValueAxis,                         // not on .scores, .fixedDomainPoints, RangeBarChart, DotStripChart
   selection: Binding<Date?>,                 // the page owns it; the ValueReadout reads it
   height: CGFloat = NoopMetrics.chartHeightPrimary,
   accessibilityTitle: String,                // also the series name VoiceOver reads
   calendar: Calendar = .current
```

What every chart does for you, so screens must not redo it:

- **One frame height in every state.** `height` includes the legend. Loading draws `ChartPlaceholder` and
  empty draws `EmptyChartMessage` in the same frame; the legend row stays reserved (but empty) until the
  chart is ready. Do not put your own empty text above a chart.
- **The x window is the range ending today**, not the data's extent, so missing days at the start read as
  gaps. **Pass the whole history.** Daily marks outside `window` are not drawn, but the history is used:
  binned bars widen the window to whole weeks or months and draw the oldest bin whole (from the days
  before the range), trailing means and sparse trends use the earlier points as context, and
  `StepLineChart` draws the value held from the last reading before the window.
- **One value per day.** Every chart reads a point's day with `DailyPoint.localDay(in:)` (any instant inside
  the day works, and a point built with `DailyPoint(key:)` keeps its calendar day if the page is drawn in
  another time zone), and two values on one day become their mean (`StackedBarChart` adds same-day entries;
  `RangeBarChart` draws a second sleep on the same wake day as a second bar in the column).
- **Gaps break lines**: wherever the series skips more than its `cadence`, and wherever a point's `series`
  (method) changes. In `DailyLineChart` a series with fewer than three points in the window draws as points
  only (each series on its own); `StepLineChart` (held values) and `IntradayChart` (bucket runs) join any
  two readings of a run. Nothing is filled under a line.
- **Estimates**: `DailyPoint.isEstimate` draws a hollow point, a dashed run (a run made only of
  estimates), or a light bar with a solid cap; the legend says "Estimate" automatically. A binned bar is an
  estimate when at least half its days are.
- **References** (`ChartReference`) are rules behind the data with their labels drawn on top, on a card
  plate; a label moves to the leading edge when the newest data would sit under it at the trailing edge.
- **Long ranges bin**: bar charts take `bin:` (`.day`, `.weekOfYear`, `.month`). Pass
  `shown.totalsBin(for: window)` (daily at W and M, weekly at 3M, monthly at 6M and Y; All by the span it
  covers) so a year is twelve bars, not 365 hairlines, and a new user's All of three weeks is 21 daily bars.
- **Partial bins**: with `aggregation: .sum`, a week or month the data or the window does not fully cover
  (the running week, a history that began mid-week) is drawn light without a cap and named "Partial week"
  / "Partial month" in the legend. `DailyBarChart.partialBins(_:by:window:)` tells the readout ("So far").
- **Scrub**: a sideways drag on iPhone (a vertical swipe still scrolls the page), the pointer on the Mac,
  a tap pins the bar or point under the finger (anywhere across its day, week or month; the nearest one
  over a gap) and a second tap clears it; one selection haptic per new x; non-selected bars drop to 35 %;
  no tooltip (the `ValueReadout` is the tooltip). Selection never animates; a window change animates the
  marks for 0.25 s (off under Reduce Motion and the quiet-motion gate).
- **Accessibility**: one VoiceOver element per chart with a one-line summary, an audio graph, and swipe
  up/down stepping the selection (through every day or bar; `IntradayChart` steps through about 48
  moments across the window plus the ends of every run, not through every sample).
- **Axes**: unit above the value axis, tabular footnote labels in `textTertiary`, a hairline grid, labels
  that never repeat, edge labels pulled inside the plot, month labels starting on their month boundary,
  dense labels dropped rather than overlapped (never the newest).

### Days, windows and ranges

```swift
// A stored yyyy-MM-dd key → the LOCAL start of that day (never parse keys at UTC midnight).
let point = DailyPoint(key: "2026-10-07", value: 62)                  // nil for a malformed key
let point = DailyPoint(day: ChartDay.date(forKey: key)!, value: 62, isEstimate: false, series: "nes")
let point = DailyPoint(trendPoint, dayIsUTC: true)                    // bridge from TrendPoint / UTC midnights
ChartDay.key(for: date)                                               // back to "2026-10-07"
ChartDay.day(fromUTCMidnight: utcDate)                                // fix an existing UTC-midnight date

point.localDay(in: calendar)                                          // the local start of the point's calendar day

@State private var range: ChartRange = .month                         // W, M, 3M, 6M, Y, All (what the user picked)
let shown = RangeControl.effectiveRange(range, isAvailable: available) // what the control highlights: DRAW this
let window = ChartAxis.window(shown, firstDataDay: points.first?.day) // 7/30/90/180/365 days ending today; All from the first day (≥ 7)
shown.axisStyle                                                       // .weekday, .dayOfMonth, .month, .monthYear
shown.totalsBin(for: window)                                          // .day, .day, .weekOfYear, .month, .month; All by its span
ChartRange.totalsBin(spanning: window)                                // the span rule: ≤ 62 days daily, ≤ 200 weekly, else monthly
range.totalsBin                                                       // the fixed rule (All is always .month): prefer totalsBin(for:)
range.days, range.label, range.accessibilityName                      // 30, "M", "1 month"

RangeControl(selection: $range)                                       // all six
RangeControl(selection: $range, isAvailable: available)               // only ranges the history fills (+ All)
// let available: (ChartRange) -> Bool = { unlocked(ExploreRange($0)) }  — the same closure for both calls
RangeControl(selection: $range, options: [.week, .month, .quarter], reservesSpaceWhenHidden: true)
.onChangeCompat(of: range) { _ in selected = nil }                    // the page clears its selection
```

- `RangeControl` hides unavailable ranges (no disabled "Y" between "6M" and "All", no "Longer ranges
  unlock…" helper), hides itself when one option is left (`reservesSpaceWhenHidden` keeps its 38 pt), and
  shows a stored selection that cannot be filled as the largest range that can, without writing it back
  (tapping that highlighted segment commits it). Draw `RangeControl.effectiveRange(range, options:,
  isAvailable:)` with the same arguments as the control, never the raw `range`, so the chart's window, axis
  and bin always match the highlighted segment.
  `RangeControl.height` is 38. Screens bridge their own range enums at the view boundary. The metric
  detail page's bridge does not exist yet: add it beside `ExploreRange` in `MetricExplorerView.swift`
  (`extension ExploreRange { init(_ r: ChartRange) }` plus `var chartRange: ChartRange?`, nil for 2W/3W) and
  keep `ExploreRangeGating` as the unlock rule; `ExploreRange` itself and its cases do not change.
- Decide the options once the history span is known; do not show every range while loading.

### Value axis, references, bands

```swift
ChartValueAxis(unit: "ms", domain: .fitted(minSpan: 20))                      // fitted, at least 20 tall
ChartValueAxis(unit: "%", domain: .fixed(85...100), ticks: [85, 90, 95, 100])
ChartValueAxis(unit: "°C", domain: .symmetric(minMagnitude: 0.5), format: ChartValueAxis.decimals(1))
ChartValueAxis(unit: "steps", domain: .fitted(minSpan: 2_000, includeZero: true))
ChartValueAxis.durationMinutes()                                              // minutes in, whole hours out, unit "h"
// .fitted(minSpan:includeZero:clampTo:headroom:) · .fixed(range) widens only to show an outlier ·
// formats: ChartValueAxis.integer (default), .decimals(n), .hoursFromMinutes; tickCount, stepCandidates

ChartReference(64, label: "Baseline 64")                  // dashed (default) or style: .solid; label optional
ChartReference(10_000, label: "Goal 10,000")
ScoreBands([.init(upperBound: RecoveryScorer.bandRedMax, color: StrandPalette.statusCritical, name: "Low"),
            .init(upperBound: RecoveryScorer.bandYellowMax, color: StrandPalette.statusWarning, name: "Moderate"),
            .init(upperBound: .infinity, color: StrandPalette.chargeColor, name: "High")])
```

`ScoreBands` are built by the app from the scorer's own thresholds (`RecoveryScorer`, `StressBand`); the kit
defines none. A value belongs to the first band whose `upperBound` is greater than it.

### The charts

```swift
// Scores: fixed 0...100 (or scale: 0...21 / 0...3), bar colour from the scorer's bands, dashed 7-day
// mean on daily bars (none when binned).
DailyBarChart.scores(charge, bands: chargeBands, bin: shown.totalsBin(for: window), unit: "%",
                     state: chartState, window: window, xStyle: shown.axisStyle,
                     selection: $selected, accessibilityTitle: "Charge")
DailyBarChart.scores(effort, ramp: { StrandPalette.effortTint(fraction: $0 / 100) }, scale: 0...100,
                     bin: shown.totalsBin(for: window), window: window, xStyle: shown.axisStyle,
                     selection: $selected, accessibilityTitle: "Effort")

// Totals: one colour, an optional goal or need rule, bin + aggregation (.mean per day, or .sum per bin).
DailyBarChart.totals(steps, color: StrandPalette.metricCyan, goal: ChartReference(10_000, label: "Goal 10,000"),
                     bin: shown.totalsBin(for: window), aggregation: .mean, window: window, xStyle: shown.axisStyle,
                     y: ChartValueAxis(unit: "steps", domain: .fitted(minSpan: 2_000, includeZero: true)),
                     selection: $selected, accessibilityTitle: "Steps")
// The full init: DailyBarChart(points:fill: .single(c) / .bands(b) / .ramp(f), bin:aggregation:meanLine:reference:…)
// Pure helpers: DailyBarChart.bin(_:by:aggregation:) (what the bars show), DailyBarChart.trailingMean(_:count:unit:),
// DailyBarChart.partialBins(_:by:window:) (summed bins drawn as partial: the running week, a mid-week start).
// Band colours are chosen for the value as the axis format prints it (a weekly mean of 33.6 printed "34" is
// in 34's band); in a readout pass the same rounding: valueColor: { bands.band(for: $0.rounded()).color }.

// Vitals: line + gaps, a fixed personal band or a rolling one, a dashed baseline, a second reference.
DailyLineChart(series: [.init(id: "hrv", name: "HRV", color: StrandPalette.metricPurple, points: nights)],
               typicalBand: 52...78, baseline: ChartReference(64, label: "Baseline 64"),
               state: chartState, window: window, xStyle: shown.axisStyle,
               y: ChartValueAxis(unit: "ms", domain: .fitted(minSpan: 20)),
               selection: $selected, accessibilityTitle: "Heart rate variability")
// Also: cadence: .daily / .weekly / .sparse(maxGapDays:) / .adaptive · marks: .pointsAndLine / .pointsOnly /
// .lineOnly · interpolation: .monotone / .linear · rollingBand: [(day:range:)] · bandColor · reference ·
// several series (a legend names them). Over 60 points the line draws alone, but estimates and lone
// readings keep their points.

// Fixed-scale percentages: points only (joined: false), the rule at the trailing edge.
DailyLineChart.fixedDomainPoints(spo2, domain: 85...100, reference: ChartReference(95, label: "95 %"),
                                 color: StrandPalette.metricCyan, joined: false, window: window,
                                 xStyle: shown.axisStyle, selection: $selected, accessibilityTitle: "Blood oxygen")
DailyLineChart.fixedDomainPoints(efficiency, domain: 50...100, reference: ChartReference(85, label: "85 %"),
                                 color: StrandPalette.restColor, joined: true, window: window,
                                 xStyle: shown.axisStyle, selection: $selected, accessibilityTitle: "Sleep efficiency")

// Deviation: symmetric around zero, both directions named in the legend.
DivergingBarChart(points: deviations, positive: StrandPalette.metricAmber, negative: StrandPalette.metricCyan,
                  positiveLabel: "Warmer", negativeLabel: "Cooler",
                  references: [ChartReference(0.5), ChartReference(-0.5)], bin: shown.totalsBin(for: window),
                  window: window, xStyle: shown.axisStyle,
                  y: ChartValueAxis(unit: "°C", domain: .symmetric(minMagnitude: 0.5), format: ChartValueAxis.decimals(1)),
                  selection: $selected, accessibilityTitle: "Skin temperature")

// Bedtime to wake: a clock axis from 18:00 the evening before (evening at the top), usual windows as bands.
// The axis widens above 18:00 for an early bedtime. RangeBarChart.bin(items, by:) returns the bars as drawn
// (Span: day, start and end as clock offsets) for the readout; RangeBarChart.clockLabel(offset:) prints one.
RangeBarChart(items: nights.map { .init(day: $0.wakeDay, start: $0.bedtime, end: $0.wake, isEstimate: false) },
              typicalStart: usualBed, typicalEnd: usualWake, color: StrandPalette.restColor,
              bin: shown.totalsBin(for: window), window: window, xStyle: shown.axisStyle,
              selection: $selected, accessibilityTitle: "Sleep schedule")

// Parts of a whole: the highlighted category sits at the bottom, the rest at 30 %; normalised shows shares.
// Binned stacks are the mean day (aggregation: .mean, stages) or the totals (aggregation: .sum, HR zones);
// StackedBarChart.bin(_:by:aggregation:) is what the bars show.
StackedBarChart(days: nights.map { .init(day: $0.wakeDay, values: ["deep": $0.deep, "rem": $0.rem, "light": $0.light]) },
                categories: [.init(id: "deep", name: "Deep", color: StrandPalette.sleepDeep),
                             .init(id: "rem", name: "REM", color: StrandPalette.sleepREM),
                             .init(id: "light", name: "Light", color: StrandPalette.sleepLight)],
                highlighted: "deep", bin: shown.totalsBin(for: window), window: window, xStyle: shown.axisStyle,
                y: .durationMinutes(), selection: $selected, accessibilityTitle: "Deep sleep")

// Levels: one dot per logged day, never joined; each level a labelled row.
DotStripChart(points: moods, levels: 1...5, levelLabels: [1: "Awful", 2: "Low", 3: "Okay", 4: "Good", 5: "Great"],
              color: moodColor, window: window, xStyle: shown.axisStyle, selection: $selected,
              height: NoopMetrics.chartHeightSecondary, accessibilityTitle: "Mood")

// Sparse readings: every reading a point, a faint display-only trend (.rollingMedian(days: 14) default,
// .rollingMean(days:), .none), not drawn under three readings, broken across `cadence` gaps.
SparsePointsChart(points: weighIns, color: StrandPalette.metricPurple,
                  references: bmi ? [ChartReference(18.5), ChartReference(25), ChartReference(30)] : [],
                  window: window, xStyle: shown.axisStyle,
                  y: ChartValueAxis(unit: "kg", domain: .fitted(minSpan: 2), format: ChartValueAxis.decimals(1)),
                  selection: $selected, accessibilityTitle: "Weight")

// Held estimates: a step line with a point per reading, held to today while within the cadence
// (holdsLatest), broken where the method (DailyPoint.series) changes. The value held from the last reading
// before the window is drawn from the window's start while it was still current, so pass all of history.
StepLineChart(points: vo2, color: StrandPalette.chargeColor, reference: ChartReference(Double(age), label: "Your age"),
              window: window, xStyle: shown.axisStyle,
              y: ChartValueAxis(unit: "ml/kg/min", domain: .fitted(minSpan: 6)),
              selection: $selected, accessibilityTitle: "VO2 max")

// Through the day: a clock axis, gaps where a bucket is skipped, spans as bands behind the line (a band
// wide enough for its label carries it inside; narrow and hatched bands are named in the legend), value
// bands (stress Low/Medium/High, HR zones), labelled markers, references, an optional min/max envelope
// (Sample.low/high). compact: the small-card form (120 pt, no value labels, legend or in-plot labels).
// live: the now dot on the latest sample and no window animation. Samples ascending, one per time, and a
// stable array (the chart is rebuilt on every scrub step). A gap is a skipped bucket; samples stamped at
// their measurement time (a live trace) may jitter by up to half a bucket without breaking the line.
IntradayChart(samples: buckets.map { .init(time: $0.start, value: $0.bpm) }, bucketSeconds: 300,
              bands: [.init(id: "sleep", start: onset, end: wake, color: StrandPalette.restColor, label: "Asleep"),
                      .init(id: "off", start: offStart, end: offEnd, color: StrandPalette.textTertiary,
                            label: "Off wrist", hatched: true)],
              markers: [.init(id: "woke", time: wake, label: "Woke", color: StrandPalette.textSecondary)],
              references: [ChartReference(56, label: "Resting 56")],
              window: dayStart...dayEnd, y: ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 30)),
              selection: $selected, accessibilityTitle: "Heart rate")
IntradayChart(samples: today, bucketSeconds: 300, compact: true, window: midnight...endOfDay,
              y: ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 30)), selection: $selected,
              accessibilityTitle: "Heart rate today")
    .naraChartScrubDisabled()                    // inside a card that is a link
```

There is no zoom or pan in `IntradayChart`; the Deep Timeline keeps `OverviewHRChart` for that.

### The readout above a chart

```swift
// Daily charts: the selected point (in the chart's bin), else the latest; "—" under the selected day when
// it has no reading. For binned bars pass what the bars show and the same bin.
ValueReadout(.daily(selection: selected, in: nights, nightly: true, unit: "ms", format: fmt,
                    context: selected == nil ? "7-day avg 61 ms" : nil),
             isScrubbing: selected != nil, isLoading: !loaded)
let weekly = DailyBarChart.bin(steps, by: shown.totalsBin(for: window), aggregation: .mean)
ValueReadout(.daily(selection: selected, in: weekly, bin: shown.totalsBin(for: window), unit: "steps", format: fmt),
             isScrubbing: selected != nil)
// A score in its band colour:
ValueReadout(.daily(selection: selected, in: charge, unit: "%", format: fmt,
                    valueColor: { chargeBands.band(for: $0).color }))
// Intraday: the nearest sample, else the latest, dated "Tue 7 Oct, 14:05".
ValueReadout(.intraday(selection: selected, in: samples, unit: "bpm", format: fmt))
// Bedtime to wake: the selected night (or the week's / month's mean night, as the bar shows), else the latest.
let spans = RangeBarChart.bin(items, by: bin)
ValueReadout(.range(selection: selected, in: spans, bin: bin))                // "11:20 PM – 7:05 AM", no unit
// A summed bin still running: say so.
let partial = DailyBarChart.partialBins(points, by: bin, window: window)  // context: "So far this week"
// One point you already hold, with the date line for its period (.day, .night, .week, .month, .time):
ReadoutContent.daily(point, unit: "ms", format: fmt, period: ReadoutContent.Period(bin: .day, nightly: true))
ChartSelection.point(for: selected, in: points, unit: shown.totalsBin(for: window))    // the point under the selection
ChartSelection.sample(for: selected, in: samples)                         // the sample under an intraday selection
```

### Scrub, axes and styling for app-side Swift Charts

App views that still draw their own `Chart` (Coach viz, the Deep Timeline) use the same pieces:

```swift
Chart { … SelectionRule(selected, unit: .day) }                 // the 1 pt rule (unit: nil for raw times)
    .naraChartAxes(x: window, style: shown.axisStyle, y: ChartValueAxis(unit: "ms", domain: .fitted(minSpan: 20)),
                   yDomain: 40...100)                           // house axes from a window and an axis
    .chartScrub(xs: days, selection: $selected, unit: .day)     // drag / tap / hover, haptic, no animation
// or .chartOverlay { proxy in ChartScrubLayer(proxy: proxy, xs: days, selection: $selected, unit: .day) }
// unit: the marks' unit when xs are day / week / month starts (a finger anywhere on a bar selects it);
// leave it nil for raw times. ChartSelection.nearest(to:in:unit:calendar:) is the rule.
ChartAxis.layout(window, style: .dayOfMonth)                    // the resolved marks, labels and anchors
ChartSelection.nearest(to: date, in: xs) / .nearestIndex(to:in:) / .step(from:in:forward:) / .afterTap(current:tapped:)
someCard.naraChartCompact()                                      // compact form for every kit chart inside
someCard.naraChartScrubDisabled()                                // taps reach the enclosing link
```

`NaraChartStyle` holds the mark tokens: `line` (2 pt round), `estimateLine` (dashed), `meanLine`,
`pointSize` 24, `selectedPointSize` 64, `densePointSize` 10 (points-only series over
`densePointThreshold` 90), `barCornerRadius` 3, `barWidthRatio` 0.62, `rangeBarWidthRatio` 0.5,
`bandOpacity` 0.12, `dimmedOpacity` 0.35, `estimateFillOpacity` 0.35, `deemphasisedOpacity` 0.3,
`reference` (1 pt, 4 on 4 off), `selectionRule`, `grid`, `rangeAnimation` (0.25 s), `legendHeight` 20,
and the colours `axisColor`, `gridColor`, `referenceColor`, `selectionColor`, `meanLineColor`, plus
`axisFont` / `unitFont`. It is named `NaraChartStyle` because `ChartStyle` is the persisted Default/Classic
colour preference.

### Legends, placeholders, heights

```swift
ChartLegend([ChartLegendItem(.line(StrandPalette.metricPurple, dashed: false), "RMSSD"),
             ChartLegendItem(.line(StrandPalette.metricCyan, dashed: false), "SDNN")],
            hidden: hiddenSeries, onToggle: { id in toggle(id) })   // item id is its label
// Marks: .swatch, .line(_, dashed:), .point, .band, .estimate (hollow point), .estimateBar, .hatched
ChartPlaceholder(height: NoopMetrics.chartHeightCompact)            // a chart of your own, loading
EmptyChartMessage("No heart rate yet today", height: NoopMetrics.chartHeightCompact)
```

A legend is one row at a fixed 20 pt; when it is wider than the card it tightens, then scrolls sideways
with a faded trailing edge (it never wraps). Heights: `NoopMetrics.chartHeightPrimary` 240 (the detail
chart), `chartHeightSecondary` 160, `chartHeightCompact` 120 (Today's HR card, the sleep HR strip).

### Kit gallery and screenshot hooks (DEBUG)

`Strand/Screens/KitGalleryView.swift` renders every chart and component on synthetic data in every state,
with each case's measured height beside its title. In a DEBUG simulator build:

- `--demo-screen kitcharts` and `--demo-screen kitcomponents` open the two galleries;
- `--demo-kit-only charge,steps` limits them to some sections (ids are printed beside each section title);
- `--demo-chart-select 0.7` makes every kit chart whose selection is nil select the x 70 % of the way
  through its x positions when it appears (also on real pages), so a screenshot shows the scrubbed state.
  It is compiled out of Release.

```sh
Tools/UITour/tour.sh <udid> <bundle-id> <out-dir> kit-charts --demo-screen kitcharts --demo-chart-select 0.7
```

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

// nights: [DailyPoint] built with DailyPoint(key:value:) from the stored keys (local days, never UTC).
let available: (ChartRange) -> Bool = { unlocked(ExploreRange($0)) }
let shown = RangeControl.effectiveRange(range, isAvailable: available)   // what the control highlights
let window = ChartAxis.window(shown, firstDataDay: nights.first?.day)
let chartState: ChartState = !loaded ? .loading : (nights.isEmpty ? .empty("No HRV readings yet") : .ready)

ScreenScaffold(title: "Heart rate variability", titleDisplay: .navigationBar, isLoading: !loaded) {
    ValueReadout(.daily(selection: selected, in: nights, nightly: true, unit: "ms", format: fmt,
                        context: selected == nil ? "7-day avg \(fmt(avg7)) ms" : vsTypical(selected)),
                 isScrubbing: selected != nil, isLoading: !loaded)
    RangeControl(selection: $range, isAvailable: available)
    NoopCard {
        DailyLineChart(series: [.init(id: "hrv", name: "HRV", color: StrandPalette.metricPurple, points: nights)],
                       typicalBand: typical, baseline: ChartReference(base, label: "Baseline \(fmt(base))"),
                       state: chartState, window: window, xStyle: shown.axisStyle,
                       y: ChartValueAxis(unit: "ms", domain: .fitted(minSpan: 20)),
                       selection: $selected, accessibilityTitle: "Heart rate variability")
    }
    StatGrid(stats, isLoading: !loaded)
    ReadingsList(rows: rows, onShowAll: { showAll = true })
    AboutDisclosure("About HRV", paragraphs: about)
}
.onChangeCompat(of: range) { _ in selected = nil }
```

For a bar chart of daily totals the readout reads the bars: `let bin = shown.totalsBin(for: window)`,
`let bars = DailyBarChart.bin(points, by: bin, aggregation: .mean)`, then `.daily(selection: selected, in:
bars, bin: bin, …)`, and the chart gets the raw `points` (the whole history) with the same `bin`.

A card that contains a scrubbable chart is not itself a link; its header row is.

## Chart selection

What each kind of data is drawn as, with the kit call. "Line + gaps" is points joined by monotone segments
that break across missing days, with no area fill. "Band" is the personal typical range, drawn only once it
is trusted (14 valid nights); pass `typicalBand: nil` until then. Every bar chart takes
`bin: shown.totalsBin(for: window)` (daily bars at W and M, weekly at 3M, monthly at 6M and Y, All by its
span), where `shown` is `RangeControl.effectiveRange(range, …)`. Default range is M unless noted. "Not in
the kit" rows keep the screen's current view until the kit grows one.

| Data | Cadence | Kit chart and key parameters | Readout context / StatGrid |
| --- | --- | --- | --- |
| Charge (recovery), Rest (sleep performance) | one score per day / night | `DailyBarChart.scores(_, bands:, bin:)` on 0...100 with `ScoreBands` from `RecoveryScorer.bandRedMax` / `bandYellowMax`; 7-day mean on daily bars; secondary band mix: `StackedBarChart(normalised: true)` | "7-day avg 44 %" · Average, Low, High, Days ≥ 67 (Rest: Nights ≥ 85) |
| Effort (strain) | daily score | `DailyBarChart.scores(_, ramp: { StrandPalette.effortTint(fraction: $0 / max) }, scale: 0...max, bin:)` (max 100, or 21 with the Effort scale setting) | "7-day avg 48" · Average, Low, High, vs previous |
| Sleep score (Mi Band), Stress (Mi Band, 0-100) | nightly / daily | `DailyBarChart.scores(_, bands:, bin:)` with the source's own bands | Average, Low, High, vs previous |
| Day stress (from the WHOOP import) | daily 0-3 | `DailyBarChart.scores(_, bands: StressBand bands, scale: 0...3, bin:, format: ChartValueAxis.decimals(1))` | Average, High days, Low, High |
| HRV, resting HR, respiratory rate, average HR | nightly / daily | `DailyLineChart(series:, typicalBand:, baseline:, …, y: ChartValueAxis(unit:, domain: .fitted(minSpan:)))` with 20 ms / 10 bpm / 3 rpm. HRV's SDNN is a second `Series` toggled from a `ChartLegend(hidden:onToggle:)` | "7-day avg 82 ms · typical 74-96 ms" · Average, Low, High, Typical |
| Max heart rate | daily | `DailyLineChart(series:, …, y: ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 10)))` | Highest (with date), Average, Low, vs previous |
| Blood oxygen | nightly | `DailyLineChart.fixedDomainPoints(_, domain: 85...100, reference: ChartReference(95, label: "95 %"), joined: false)`; strap estimates `isEstimate` (hollow); "Every reading" card below | "Lowest 94 % on 2 Oct" · Average, Lowest night, Nights below 95 %, Nights |
| Skin temperature (deviation) | nightly | `DivergingBarChart(points:, positive: metricAmber, negative: metricCyan, positiveLabel: "Warmer", negativeLabel: "Cooler", references: [±0.5], bin:, …, y: ChartValueAxis(unit: "°C", domain: .symmetric(minMagnitude: 0.5), format: ChartValueAxis.decimals(1)))` | Average, Warmest, Coolest, Nights > +0.5 |
| Skin temperature (absolute) | nightly | `DailyLineChart(series:, typicalBand:)` in the displayed unit, `format: ChartValueAxis.decimals(1)` | Average, Low, High, Typical |
| Asleep time | nightly | `DailyBarChart.totals(_, color: restColor, goal: ChartReference(need, label: "Need"), bin:)`, `y: .durationMinutes()` | "6 h 42 m · 48 m below need" · Average, Shortest, Longest, Nights ≥ need |
| Time in bed | nightly | `StackedBarChart(categories: [asleep, awake in bed], bin:)`, `y: .durationMinutes()` (asleep at the bottom); time in bed alone: `DailyBarChart.totals` | Average, Shortest, Longest, vs previous |
| Hours vs needed | nightly | `DailyBarChart(points:, fill: .bands(<100 warning, else positive), bin:, reference: ChartReference(100, label: "100 %"), …, y: ChartValueAxis(unit: "%", domain: .fitted(minSpan: 40, includeZero: true)))` | Average, Nights ≥ 100 %, Low, High |
| Sleep need | nightly | `DailyLineChart(series:)`, `y: .durationMinutes(includeZero: false)` (asleep bars behind it are not in the kit) | Average, Low, High, Nights met |
| Sleep debt | nightly, never negative | `DailyBarChart.totals(_, color: metricRose, goal: nil, bin:)`, `y: .durationMinutes()` (not diverging) | Average, Max, Nights with no debt, vs previous |
| Sleep consistency | nightly score | `DailyBarChart.scores(_, bands:, bin:)`; with sleep sessions, `RangeBarChart(items:, typicalStart:, typicalEnd:, bin:)` as the secondary chart | Average, Low, High, vs previous |
| Sleep efficiency | nightly | `DailyLineChart.fixedDomainPoints(_, domain: 50...100, reference: ChartReference(85, label: "85 %"), joined: true)` | Average, Low, High, Nights ≥ 85 % |
| Deep, REM, light sleep | nightly | `StackedBarChart(categories: deep/REM/light, highlighted: <this stage>, bin:)`, `y: .durationMinutes()` | Average, Low, High, Share of sleep |
| Restorative sleep (share / time) | nightly | Share: `DailyLineChart.fixedDomainPoints(_, domain: 0...60, reference: nil, joined: true)`. Time: `StackedBarChart(categories: [deep, rem])` | Average, Low, High, vs previous |
| Steps, calories, active energy | daily total | `DailyBarChart.totals(_, goal:, bin:, aggregation: .mean)`; on-device days `isEstimate` | "avg 8,420 steps/day" · Average per day, Total, Best day, vs previous |
| Calories in, protein, carbs, fat | logged days | `DailyBarChart.totals(_, goal: nil, bin:)`; macro mix: `StackedBarChart(normalised: true)` | Average per logged day, Days logged, High, Low |
| HR zone minutes (Z1-3, Z4-5), strength time | workout days only | `DailyBarChart.totals(_, bin:, aggregation: .sum)` (an absent day is no bar, not a gap) | Total, Average per workout day, Active days, High |
| HR zones (all) | workout days | `StackedBarChart(categories: Z1…Z5 with StrandPalette.zone1…zone5, bin:, aggregation: .sum)` (the same weekly minutes as the single-zone chart and the Total stat) | Total, Average per workout day, Z4-5 share, Active days |
| Intensity minutes | daily | `let bin: Calendar.Component = shown == .week ? .day : .weekOfYear`; `DailyBarChart.totals(_, goal: bin == .weekOfYear ? ChartReference(150, label: "150 min") : nil, bin: bin, aggregation: .sum)` (the 150-minute goal is weekly, so daily bars at W get none); the running week draws as partial; default 3M | This week (so far), Weekly average, Weeks ≥ 150, Best week |
| Weight, body fat, lean mass, BMI | sparse | `SparsePointsChart(points:, color:, …, y: ChartValueAxis(unit: "kg", domain: .fitted(minSpan: 2), format: ChartValueAxis.decimals(1)))`; BMI `references: [18.5, 25, 30]`; default 3M (weight) or 6M | "−1.2 kg since Jul" · Latest, Change, Low, High |
| VO2 max (measured / estimated), Fitness age, Vitality, Body age | weekly or sparse | `StepLineChart(points:, color:, reference:)`; estimates `isEstimate`, a method change in `DailyPoint.series`; ages with `ChartReference(age, label: "Your age")`; Vitality `y: ChartValueAxis(unit: nil, domain: .fixed(0...100))`; default 6M | Latest, Change over range, High, Readings |
| Mood | daily 1-5 | `DotStripChart(points:, levels: 1...5, levelLabels:, color:)` (distribution is not in the kit) | Average, Most common, Days logged, vs previous |
| Hydration | daily total with a real goal | `DailyBarChart.totals(_, goal: ChartReference(goal, label: "Goal"), bin:)` | Average, Days at goal, Total, High |
| Lab markers | sparse, irregular | `DailyLineChart(series:, cadence: .sparse(maxGapDays: 365), interpolation: .linear)` | Latest, Change, Low, High |
| Heart rate through the day | per second / 5-min buckets | `IntradayChart(samples:, bucketSeconds:, bands: sleep/workout/off-wrist (hatched), markers:, references: [resting])`; Today's card `compact: true` + `.naraChartScrubDisabled()` | Resting, High, Low |
| Stress through the day | sliding hourly 0-3 | `IntradayChart(samples:, bucketSeconds:, bands: "Moving" hatched, valueBands: Low/Medium/High, …, y: ChartValueAxis(unit: nil, domain: .fixed(0...3), ticks: [0, 1, 2, 3]))` | — |
| Physiology around an event | intraday | `IntradayChart(bands: [the event, hatched when the time is approximate], markers:, references: [before-mean])`, window around the event | — |
| Sleep stages through the night | 30 s epochs | `Hypnogram` (existing) with `MotionTrace` beneath | — |
| Correlation, dose-response, calendar heatmap, zone bars, aligned recovery curves, treatment courses | pairs / categories / per event | Not in the kit | — |

## Rules for every chart

- The y-axis shows the unit in the displayed unit system, and uses a fixed domain where the metric has
  one (0-100 scores, 85-100 % oxygen, 50-100 % efficiency, 0-3 stress, 1-5 mood). Fitted domains have a
  minimum span so small wobbles do not fill the card.
- The x window is the selected range ending today, not the data's extent. Daily values sit at the centre
  of their day. Labels adapt to the range and never repeat; the first and last never clip.
- Daily charts plot each `yyyy-MM-dd` key at the local start of that day; never pass UTC midnights.
- Lines break across gaps longer than the metric's cadence. A series with fewer than three points is drawn
  as points only (held steps and intraday runs excepted). No area fill under a line that is not a
  cumulative quantity. No smoothing that overshoots the data or misplaces a peak (no Catmull-Rom, no
  midpoint curves); straight or monotone segments only.
- References (baseline, 95 %, goal, sleep need, "Your age") are labelled at the trailing edge, above
  their rule and in front of the data; the label moves to the leading edge when the newest data would sit
  under it.
- Long ranges aggregate rather than draw hairlines: every bar chart takes `bin: shown.totalsBin(for: window)`.
  Summed bins that are not fully covered (the running week) are drawn as partial.
  Points-only series over 90 readings in the window draw smaller dots; line series over 60 draw the line
  alone, keeping the points of estimates and of readings alone between gaps.
- A legend names only marks that are drawn; it is one row, never wraps, and its row is reserved while the
  chart is loading or empty.
- Scrubbing (a sideways drag on iPhone, the pointer on the Mac) moves a selection rule and drives the
  `ValueReadout`; a tap pins the nearest point; non-selected bars drop to 35 %. No floating tooltips on
  detail charts: the readout is the tooltip.
- Estimated or derived values are drawn hollow (points), dashed (a run of estimates) or as a light bar
  with a solid cap, and say "Estimate" in the legend. Hatching is for time without a trustworthy signal
  (off wrist, moving).
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
| `TrendChart` (detail and hosted trend cards) | `DailyLineChart` or `DailyBarChart` per [Chart selection](#chart-selection) |
| `HRVDualChart` | `DailyLineChart` with two `Series` and a toggling `ChartLegend` |
| `OverviewHRChart` on Today, `IntradaySeriesSection`, `LiveTimeChart`, `DaytimeLoadLine`, `PhysiologyChart` | `IntradayChart` (the Deep Timeline keeps `OverviewHRChart` for zoom) |
| `AsleepDurationBars` | `DailyBarChart.totals` with a need `ChartReference`, `y: .durationMinutes()` |
| Sleep consistency floating bars | `RangeBarChart` |
| Stage minutes, HR-zone stacks | `StackedBarChart` |
| Weight / body-composition lines | `SparsePointsChart` |
| VO2 max, fitness age, vitality lines | `StepLineChart` |
| Mood line | `DotStripChart` |
| App-side Swift Charts (Coach viz) | Keep the chart; adopt `.naraChartAxes(…)`, `SelectionRule`, `.chartScrub(…)` and `NaraChartStyle` |
| Parsing day keys at UTC midnight (`parseDay`) | `DailyPoint(key:value:)` / `ChartDay.date(forKey:)`, or `ChartDay.day(fromUTCMidnight:)` |
| A hand-built readout from the selected point | `ReadoutContent.daily(selection:in:…)` / `.intraday(selection:in:…)` |
| Per-screen warning / info banners | `InlineNotice` |
| Per-screen range enums, `Picker(.segmented)` for ranges | `ChartRange` + `RangeControl` |
| `ChartTooltip` floating over a detail chart | The `ValueReadout` |
| `NoopPrimary/Secondary/GhostButtonStyle` | `NoopButton` / `NoopButtonStyle(kind:)` |
| `liquidTapHaptic` and friends (app) | `StrandHaptic` / `.strandHaptic(_:trigger:)` |
