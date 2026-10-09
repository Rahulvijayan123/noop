# Sentry hang audit, 2026-10-08

Source: Sentry project `nara-apple` (org `convexia`), every issue from 2026-10-07 18:37 to 2026-10-08 18:19 UTC
(122 issues, about 1,230 events). Release `com.rahulvijayan.noop@11.8.0+431` and `.staging@11.8.0+198`, both
`debug` environment: the phones run Debug builds (unoptimised Swift, debug dylib), which multiplies every
number below.

## Where the 122 issues came from

| Source | Issues | What they are |
| --- | --- | --- |
| macOS `Mac16,9`, release `.staging@198` | 67 | StrandTests / XCTest running on the main thread (`StrandTests`, `XCTestCore`, AppKit frames). Not a user. |
| iOS **simulator** `iPhone18,3` | 21 | XCUITest runs: `XCTAutomationSupport` accessibility snapshots stall the app for seconds. Not a user. |
| Physical iPhone 15 Pro (`iPhone16,1`) | 33 | The real ones: about 510 hang events (the rest of its count is the push 500s). |

## The physical-phone hangs

1. **Watchdog baseline evaluation on the main actor, every 20 s: 386 of the 455 hang events pulled with full stacks (85 %).**
   `WatchdogService` is `@MainActor` and ticks every `WatchdogConfig.tickSeconds` = 20 s. Each tick calls
   `BaselineStore.watchdogPromptEvaluations`, whose memo key included the live tape's sample count, so it
   missed on every tick and ran `LongitudinalBaseline.evaluate` for all 16 Watchdog series. `evaluate`
   replays every day of history, and each replayed day calls `nightIsClean` / `habitMatches`, which name a
   day with `isoFromEpochDay`, which was `String(format: "%04d-%02d-%02d")`. Hundreds of thousands of format
   parses per tick. Sentry shows the signature exactly: a 20.8 s period (20 s sleep + 0.5-1 s of work),
   main thread the only busy thread, leaf `String.init(format:)` → `__CFStringFindFormatSpecifiersInString`,
   and an 8-frame in-app chain (task closure → `runTick` → `watchdogPromptEvaluations` → `map` closure →
   `evaluate` → helper → `isoFromEpochDay`). The phone binary's offsets line up with
   `watchdogPromptEvaluations` in a rebuild of the nearest commit (constant shift 0x5260).
   Measured here (debug, Mac) for the 16 series: 60 days 1.63 s, 120 days 6.65 s, 200 days 15.6 s. The
   98 s, 46 s and 25 s hangs at 17:05-17:15 UTC are this job on a long history, back to back.
   Fix: `isoFromEpochDay` builds the string directly (0.55 s / 0.76 s / 0.96 s for the same three cases), and
   the memo no longer invalidates on the live tape alone for 5 minutes.
2. **Sentry's own false positives: 60 events (13 %), including every hang longer than 100 s.** The V2 hang
   tracker opens a hang when frames stop and closes it when they resume. When the screen locks while the app is
   still "active", the main thread is parked in its run loop (`mach_msg` under `__CFRunLoopServiceMachPort`),
   no frames are delivered, and the hang stays open until the app is next foregrounded: 6033 s, 2037 s, 860 s
   and so on, `in_foreground: true`, with the app uploading in the background meanwhile. The stack is
   idle at detection. `SentryHangFilter` drops hangs whose innermost frames are that run-loop wait.
3. **BLE-callback and main-actor I/O**: `NSFileHandle.read` on the main thread, 0.6 s inside a
   `CBPeripheral` callback and 2 s inside a main-actor job. `ImuSessionFileStore` (`@MainActor`) opened and read
   the 16-byte header of every segment file on each eviction sweep (every 5 minutes, on the BLE callback) and
   each upload pass. It also built a `DateFormatter` for every appended frame. Headers are now remembered per
   path and the formatter is shared.
4. **Per-call formatter construction** (`ISO8601DateFormatter`, `DateFormatter`) on paths that run per data point
   or per tick: `IntradaySeries.parseTimestamp`, `CloudReceiverClient.parseDate`, `PlacementStore.isoDate`,
   `BaselineStore.dayKey`, `BaselinePlotScale.date`. Now shared.

## Not fixed here, and why

- **CoreML `MLModel.prediction` on the main thread (0.4 s).** There is no CoreML code on `nara/main`; the phone
  build contains a branch that has it. Needs the same off-main treatment on that branch.
- **A 4.4 s Combine chain** (BLE callback → `@Published` → sink → `@Published` → SwiftUI `.onReceive`) and the
  single 0.5-0.6 s `@Published` setter hangs. The offsets could not be resolved to source (no symbols for the
  installed build). The 8 s and 17 s `XCTAutomationSupport` ones are simulator UI tests.
- **`WatchdogTermination` (2) and `Fatal App Hang` (1).** Too little in the event to attribute.
- **Debug builds on phones.** A Debug configuration is what makes a 0.8 s job out of what is tens of
  milliseconds in Release. Phone installs should be `-O` (Release, or `SWIFT_OPTIMIZATION_LEVEL = -O` in Debug).
- **The 500 errors (`HTTPClientError 500`, 454 events).** Mostly the tests (`example.invalid` URLs); on the phone they
  are the `/functions/v1/push` lock timeouts already described in the perf notes.

## Sentry configuration changes

- No Sentry in a unit-test host; no hang tracking in the simulator (`environment` = `simulator`).
- `source_revision` tag from `NOOPSourceRevision`, so the next report names its commit. The release name is the
  same for every phone build of a version, which is why the installed commit could not be identified from the
  events and symbolication was by inference.
- Dead-run-loop hang reports dropped in `beforeSend` (`SentryHangFilter`).
