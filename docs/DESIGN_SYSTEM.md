# Nara design system

How the iPhone app looks and behaves, and the shared pieces every screen is built from. The shared
pieces live in `Packages/StrandDesign` (the app's screens also compile into the macOS target, so they
must keep building there). If a screen needs something this file does not cover, add it here and to
the package rather than inventing a one-off.

## Principles

1. **The top level is a glance.** A tab root shows the day's state as values and short state words.
   It does not explain itself: no taglines, subtitles, helper sentences, disclaimers, overlines,
   "Live"/"Just now" labels, decorative wordmarks or progress bars that imply a goal that does not exist.
2. **Depth lives one tap down.** Every number on a top-level screen opens a detail page with its
   history, an interactive chart chosen for that kind of data, the statistics behind it and, at the
   bottom, the explanation and caveats.
3. **Charts match the data.** The chart type follows what was measured and how often (see
   [Chart selection](#chart-selection)). Missing days are gaps, never smoothed over. Every chart has a
   unit, labelled axes, a visible time range and a readout you can scrub with a finger.
4. **One canvas, one card, one header, one range control, one chart kit.** Different screens use
   different charts, but they are drawn from the same kit with the same type, colours, spacing and
   interaction.
5. **Nothing moves unless something changed.** No animated skies, scenic photos, glints, count-up
   numbers or staggered entrances. Motion marks navigation and data changes only.
6. **Loading never moves the layout.** Before data arrives, a screen shows placeholders at the final
   size. "No data" is only shown once loading has finished and there really is none.

## Canvas and surfaces

- **Canvas.** Every screen sits on the flat `StrandPalette.surfaceBase`. There is no sky, day-cycle
  scene, photo backdrop or in-card scenic hero anywhere. The old preference keys (`SceneBackgroundPrefs`,
  `SkyBehindCardsPrefs`, `BackgroundImagePrefs`, `CardAppearancePrefs`) stay readable for
  compatibility but no longer draw anything.
- **Card.** `NoopCard` is the one card: `NoopPanelSurface` at `NoopMetrics.cardRadius` (20) with
  `NoopMetrics.cardPadding` (16) inside and no tint. Domain colour belongs to data marks and icons, not
  card fills. `StrandCard`, `.naraCard`, `.frostedCardSurface` and direct `NoopPanelSurface` calls render
  the same surface.
- **Nested surfaces** inside a card (a stat cell, a chip row, an inset list) use
  `NoopMetrics.insetRadius` (12) on `StrandPalette.surfaceInset`, without a shadow.
- **Lists of settings-like rows** use `NoopListRow` inside one `NoopCard`, separated by hairlines.

## Layout

| Token | Value | Use |
| --- | --- | --- |
| `NoopMetrics.screenHPadding` | 20 | Left and right page margin on iPhone |
| `NoopMetrics.sectionGap` | 24 | Between sections of a page (ScreenScaffold column spacing) |
| `NoopMetrics.gap` | 12 | Between cards in a grid, and between a section header and its content |
| `NoopMetrics.cardPadding` | 16 | Inside a card |
| `NoopMetrics.cardInnerSpacing` | 12 | Between blocks inside a card |
| `NoopMetrics.cardRadius` | 20 | Cards |
| `NoopMetrics.insetRadius` | 12 | Surfaces nested inside a card |

Every page uses `ScreenScaffold` (tab roots and pushed pages alike). Pushed pages and sheets use the
system navigation bar with an inline title; sheets add a trailing **Done**. A page's title appears once.

## Type

SF Pro only, sentence case, three weights. Roles from `StrandFont`:

| Role | Font | Use |
| --- | --- | --- |
| Page title | `title1` (28 semibold) | ScreenScaffold header on tab roots |
| Section title | `title2` (20 semibold) | `SectionHeader`, one line, optional trailing action |
| Card title | `headline` (16 semibold) | Title inside a card |
| Label | `subhead` (14) in `textSecondary` | Metric name on a tile, stat labels |
| Body | `body` (16) | Sentences, only on detail pages |
| Metadata | `caption` (12) in `textTertiary` | Dates, units under values, legends |
| Chart axis | `captionNumber` (11-12) in `textTertiary` | Axis tick labels |
| Hero value | `display(40)` | The readout above a detail chart, ring centres |
| Tile value | `number(28)` | Today key-metric tiles |

Overlines (spaced capitals) are not used on content screens. `SectionHeader(_:overline:)` ignores its
overline. Units are always shown next to values (`62 ms`, `14.2 rpm`, `7 h 32 m`); a missing value is
`—` with no unit.

## Colour

The palette in `StrandPalette` is unchanged. Use `textPrimary/Secondary/Tertiary` for text, `accent`
for interactive elements (links, selected segments, toggles), the domain colours for data
(`chargeColor`, `effortColor`, `restColor`, `stressColor`, `metricCyan/Purple/Amber/Rose`), the score
ramps (`recoveryColor(_:)`, `effortTint(fraction:)`) for score-coloured marks, the sleep-stage colours
for stages, and `statusPositive/Warning/Critical` for state. Never use a data colour as a link colour
and never hard-code white text over an image.

## Components

All in `Packages/StrandDesign` unless noted. See the source for exact parameters.

- `ScreenScaffold` (app): page shell. `subtitle` is only for data (a date or span), never a tagline.
- `SectionHeader`: one-line section title with an optional trailing action.
- `NoopCard`: the card.
- `MetricTile`: a top-level tile: icon + label, value + unit, optional one-line state. Fixed height.
- `ScoreRing`: flat score ring (hairline track, solid arc in the score's colour, value in the centre).
- `ValueReadout`: the pinned header above a chart: date line, hero value + unit, one context line.
  Fixed height, so scrubbing never moves the page.
- `ChartRange` + `RangeControl`: the one time-range control (W, M, 3M, 6M, Y, All).
- `NaraChart` kit (see below): `DailyChart`, `IntradayChart`, shared axes, scrub and legends.
- `StatGrid`: two to four labelled values for the visible range (Average, Low, High, Typical ...).
- `NoopListRow`: icon, title, optional value, chevron.
- `AboutDisclosure`: collapsed "About" section at the bottom of a detail page for method, caveats
  and disclaimers.
- `Placeholder` helpers: `.loadingPlaceholder(_:)` redacts real layout while loading;
  `ChartPlaceholder(height:)` reserves a chart's space; `EmptyChartMessage` fills an empty chart frame at
  the same height.
- Buttons: `NoopButton` / `NoopButtonStyle` only. Press feedback: `LiquidPressStyle` (app).

## Detail pages

Every metric or section drill-down has the same anatomy, top to bottom:

1. Navigation bar with the inline title (the metric name, once).
2. `ValueReadout`: the latest value, or the value under the finger while scrubbing, with its date and
   one context line (for example "7-day avg 61 ms" or "+4 bpm vs typical").
3. `RangeControl`, when there is history to page through.
4. The primary chart card, chosen per metric (below).
5. Secondary visuals where they say something the primary chart cannot (stage composition, weekday
   pattern, distribution, the night's hypnogram, "What shaped it").
6. `StatGrid` for the visible range.
7. Existing context modules (measurement context, banked readings, correlations), restyled.
8. Readings list, showing the most recent seven with "Show all".
9. `AboutDisclosure`: what the metric is, how it is measured, and any disclaimer.

## Chart selection

| Data | Cadence | Chart |
| --- | --- | --- |
| Charge (recovery), Rest (sleep performance), Effort (strain) | one score per day or night | Bars on a fixed 0-100 (or chosen Effort scale) axis, each bar coloured by its score band, 7-day mean line |
| HRV, resting HR, respiratory rate, average HR | one value per night or day | Points joined by a line that breaks across missing days, shaded personal typical band, dashed baseline |
| Blood oxygen | nightly | Points on a fixed 85-100 % axis with a 95 % reference rule |
| Skin temperature (deviation) | nightly | Diverging bars around zero (warm above, cool below) |
| Skin temperature (absolute) | nightly | Points + line with the personal band, in the displayed unit |
| Asleep time, time in bed | nightly | Bars in h:mm against the sleep-need line |
| Sleep stages (deep, REM, light, restorative) | nightly | Stacked stage bars, the selected stage highlighted |
| Sleep consistency | nightly | Floating bars from bedtime to wake per night |
| Sleep debt | nightly | Diverging per-night balance bars |
| Sleep efficiency | nightly | Points + line on a fixed 50-100 % axis with an 85 % rule |
| Steps, calories, active energy, strength minutes, intensity minutes | daily total | Bars, against a goal line where one exists; weekly or monthly average bars on long ranges |
| HR zone minutes | daily | Stacked zone bars |
| Weight, body fat, lean mass, BMI | sparse | Points for each reading plus a smoothed trend line, no area |
| VO2 max, Fitness age, Vitality, Body age | weekly or sparse | Points + step line, default range 6M |
| Day stress | daily 0-3 | Bars on a fixed 0-3 axis coloured by band |
| Mood | daily 1-5 | Dot strip, no interpolation |
| Heart rate through the day | per second / 5-min buckets | `IntradayChart` (time axis, sleep band, scrub) |
| Sleep stages through the night | 30 s epochs | `Hypnogram` with stage labels and hourly ticks, `MotionTrace` beneath |

Rules for every chart:

- The y-axis shows the unit (in the displayed unit system) and uses a fixed domain where the metric
  has one (0-100 scores, 85-100 % oxygen, 0-3 stress).
- The x-axis labels adapt to the range (weekday for W, day for M, month for 3M and longer, hours for
  intraday) and never repeat the same label.
- A scrub (a sideways drag on iPhone, the pointer on the Mac) moves a selection rule and drives the
  `ValueReadout`; a tap selects the nearest point.
- Lines break across gaps longer than the metric's cadence. Fewer than three points are drawn as
  points only.
- No smoothing that overshoots the data (no Catmull-Rom); use straight or monotone segments.
- Estimated or derived values are drawn hollow or hatched and say "estimate" in the legend.

## Motion

- Navigation uses the system push, sheet and tab transitions.
- Changing a chart's range animates the marks for 0.25 s; values swap without counting up.
- Selection changes give a light selection haptic per new point.
- Nothing loops on screen except a genuinely live signal (the live heart rate).
- Respect Reduce Motion and the quiet-motion gate (`NoopMotionState`).

## Loading, empty and sparse states

- Before the first load, render the real layout with `.loadingPlaceholder(true)`, so the page does
  not jump when values arrive. Never show "No data" before loading has finished.
- An empty chart keeps its frame and shows one short `EmptyChartMessage` inside it.
- With only a few readings, show them as points and say how many there are in the readout's context
  line.

## Copy

- Say Nara, never NOOP, in anything the user reads.
- No helper sentences on top-level screens. Explanations go to the detail page's About section.
- Short state words over sentences ("Within range", "Low", "On track").
