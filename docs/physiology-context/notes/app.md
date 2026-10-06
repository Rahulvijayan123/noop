# Physiology context: app workstream notes

Branch `pc/app`. Contract: [contracts.md](../contracts.md) §2, §3, §8, §9, §11. Spec §15, §16, V16, V17.

## Files

| File | What it does |
| --- | --- |
| `Strand/Push/PhysiologyContextRepository.swift` | Reads `GET {scores}/context` and `GET {scores}/context/history`. Walks the device-id candidates, keeps a per-owner on-disk cache and decodes leniently into the shared `PhysiologyContext` types. |
| `Strand/Push/PhysiologyContextStore.swift` | `@MainActor` shared store. Holds one state per (day, metric) and one per history range. Reset on account end; read candidates come from the app model. |
| `Strand/Screens/MeasurementContextWording.swift` | Plain words, number and time formatting, headline selection, and the forbidden-term guard. |
| `Strand/Screens/MeasurementContextCard.swift` | The card under the hero, plus `MeasurementContextSummary` (the card's view model) and `MeasurementContextCopy`. |
| `Strand/Screens/MeasurementContextDetailView.swift` | The detail sheet and `MeasurementContextDetailModel`. |
| `Strand/Screens/PhysiologyContextHistoryView.swift` | Episodes and bouts over 30, 60 or 90 days, plus `PhysiologyContextHistoryModel`. |
| `StrandTests/PhysiologyContextAppTests.swift` | 41 tests: repository, store, wording, forbidden words, review repairs. |
| `StrandTests/PhysiologyContextWordingCoverageTests.swift` | 4 tests: the reason table against the engine's 11 `reasonCodes` registries. |

Insertions outside these files:

- `MetricExplorerView.swift`: 6 lines after `ActivityContextLine` and before `intradaySection` inside `MetricDetailView.body`. No existing section changed.
- `AppModel.swift`, 4 lines:
  - `PhysiologyContextStore.shared.reset()` in `cloudAccountEnded()`
  - `PhysiologyContextStore.shared.setReadCandidates(candidates)` in `syncHostedResults()`
  - two `// LEAD-INTEGRATION: ExposureEventCloudSync.flush()` comments, next to `StretchFeedbackCenter.shared.flush()` in `cloudBecameActive()` and `cloudAccountReady(_:)`

## Data flow

1. `MetricDetailView` puts the card on screen. That happens only for catalog keys `hrv` and `rhr` with source `my-whoop`, and only after the page has loaded, using the day of the hero's latest point. The card maps the page to `hrv_rmssd` or `resting_heart_rate`.
2. The card's `.task(id: day|metric|store.epoch)` calls `PhysiologyContextStore.load`.
3. The store checks three preconditions in order: cloud enabled and configured, a repository for the running account, and whether anyone is signed in. When one fails it sets an explicit `unavailable` state. It never returns early and leaves the card stuck on "Loading…", which is the known IntradaySeriesStore issue.
4. When nothing is shown yet, the store reads the owner's cache first and paints it, then reads the network.
5. The repository walks `readCandidates` (from `AppModel.hostedReadCandidates`: `whoop-<serial>` first, then the local id). It sends `GET …/scores/context?deviceId=&day=&metric=` with `Authorization: Bearer noop_…` only, with no fleet token and no `mode`, so the server default applies (retrospective when present, else causal_live).
   - The first `available` answer wins, then `pending`, then `none`.
   - A 405 (an edge function that predates the routes) or a 404 (a new edge function whose migration is missing, so the read RPC does not exist) from any candidate ends the walk as `.unsupportedServer` (R9).
   - A `409 device_registration_pending` counts as pending unless another candidate answers.
   - Other failures are thrown only when no candidate answered.
6. Every 200 answer is cached under SHA256(owner|device|`day|<day>|<mode>|<metric>`). Each entry stores `ownerId`, `fetchedAtMs` and the inner `context` object. Writes are atomic (temp file, then replace or move). Files older than 14 days are deleted on the next write. Another owner's file is neither returned nor deleted.
7. The parse reads the envelope with `JSONSerialization`. Every member is optional, and header fields are read flat or from a nested `header`. The `document` is decoded with `PhysiologyContext.decoder()`, twice:
   - Once as a full `DayDocument` (`document.full`, exact round trip).
   - Once member by member through `LossyArray`, so one unreadable member or element never costs the rest. Counts go in `undecodedElements` and `undecodedMembers` and are shown in Diagnostics.
8. `PhysiologyContextStore.classify` turns an answer into a state, and the card renders the state.
9. While the state is pending, stale or `job.pending`, the card re-reads on a bounded backoff, `PhysiologyContextStore.pollDelaysS` = 30, 30, 60, 60, 90, 120, 150, 180 and 180 s, about 15 minutes in total. That outlasts the server's cadence, which waits at least 10 minutes before re-queueing a job. `.task` cancels the loop when the card leaves the screen. If the context is still not current after the last read, the card says to check back later instead of promising the update (R8).
10. The job's `dead_letter`, `leased`, `input_revision`, `completed_revision` and `reasons` are decoded. A dead-lettered job means no update is coming: the day reads "Context unavailable for this day" (`unavailable(.processingFailed)`) when there is no document or the document is stale. It is not polled (R8).
11. History works the same way: `GET …/context/history?deviceId=&from=&to=`, with the range clamped to 120 days (the later end is kept), cached per owner, keyed `HistoryKey(from,to)`.

`cloudAccountEnded` calls `reset()`. That bumps the generation, so a read that started under the previous account's credential is dropped when it returns. It also clears every state, reverts the candidates to `my-whoop`, and drops the live repository.

## States and copy

| Store state | Card | Detail / history |
| --- | --- | --- |
| `unavailable(.cloudOff)` | Nothing rendered (local-only mode). The card checks `CloudPushSettings` in `body`, so nothing shows before the first load either. | n/a (not reachable) |
| `unavailable(.signedOut)` | "Sign in to see the context of this measurement." | "Sign in to see context history." |
| `unavailable(.accountNotReady)` | "Measurement context appears once your account finishes connecting." `setReadCandidates` bumps `epoch` while a card waits, so it retries. | same idea |
| `unavailable(.unsupportedServer)` (405, or 404 without the migration) | "Measurement context isn't available from the server yet." | "Context history isn't available from the server yet." |
| `unavailable(.noData)` (status `none`, or `available` without a document) | "No measurement context for this day yet." plus History | n/a |
| `unavailable(.processingFailed)` (dead-lettered job, with no document or a stale one) | "Context unavailable for this day." plus History | n/a |
| `pending(_, .computing)` | "Measurement context for this day is being prepared." After the last scheduled re-read, " Check back later." is added. | n/a |
| `pending(_, .deviceRegistration)` (409) | "Measurement context appears once this strap's data reaches your account." | "History appears once this strap's data reaches your account." |
| `stale` (`pairing.consistent == false`) | Headline "Context updating" and "This day's results changed after its context was built. Updated context is on its way." After the last scheduled re-read the second sentence becomes "The update is taking longer than usual. Check back later." Support, eligibility and reference are not shown, so the old context is never paired with the new value. Details opens the old context under a banner. | Banner: "This context was built from an earlier version of this day's results…" |
| `available` | Summary (below) | Full detail |
| `failed(cached:)` | The cached summary, still subject to the stale rule, plus "Couldn't refresh. Showing saved context." | "Couldn't refresh. Showing saved history." |
| `failed(nil)` | "Couldn't load measurement context." plus Try again | "Couldn't load history." plus Try again |
| `loading` (first read only; a re-read keeps the settled state) | Spinner and "Loading measurement context…" | Spinner |

An absent `pairing` is treated as available. A pairing the server did not report is not invented, and Diagnostics shows "not reported".

### Summary (`MeasurementContextSummary.build`)

- **Headline measurement:** the latest nightly snapshot envelope for the metric (`scoring_snapshot` source or `session` aggregation). Without one, the latest envelope with any eligible verdict. Without that, the latest envelope, which then reads "Insufficient context".
- **State phrase**, first match wins:
  - "Sleep measurement" (sleep verdict eligible)
  - "Stable awake measurement" (stable-awake verdict eligible)
  - "Recent walking", "Recent running", "Recent cycling" or "Recent movement": locomotion makes up at least 10 % of the support, or supported movement ended at most 15 min before it
  - "Measurement during or after activity" (activity-response verdict eligible)
  - otherwise "Insufficient context"
- **Support time** is shown in the envelope's own zone, using the locale's `jmm` template:
  - "Measured 23:10–06:42" for a nightly value or anything 3 h or longer
  - otherwise "5-min window 14:05–14:10" or "60-min window 13:10–14:10"
- **Eligibility** is reported for the comparison that applies: the sleep comparison for a nightly or asleep measurement, the stable awake comparison otherwise. Examples:
  - "Qualifies for the stable awake comparison"
  - "Does not qualify for the stable awake comparison: walking during the measurement"
  - "Can't tell whether it qualifies …: it is unclear whether you were awake"
- **Coverage:** "Activity known for 92% · 8% unknown · signal 95%". Unknown and uncovered time are added together, and both use the whole support interval as the denominator.
- **Reference:** the envelope's own `comparisons` first. The engine attaches a comparison only to the envelope that is its value. A 5-minute window that fed today's stable-awake median therefore has none. For such a window the card uses the day's comparison of its stable-awake series (`document.comparisons`, series `<metric>.stable_awake_<n>min`, same regime first) and labels it as the median's, never as the window's own difference (RC-16). The order is rolling, recent, frozen, conditioned, with ready comparisons preferred. Examples:
  - "+6 ms vs your 28-day reference": the span comes from `fromDay`–`toDay`, and the signed difference is in the original units, using − (U+2212) and ±0
  - "vs your historical reference" (frozen)
  - "Today's stable awake median: +6 ms vs your 28-day reference" (a window with no comparison of its own)
  - "Not enough comparable days for a reference yet"
  - "No reference comparison for this measurement yet"
- **Episode:** matched by the headline reference's series and regime, otherwise by the page's series family. Examples are "Persistent change from historical reference", "Persistent change from your recent usual range", "Transient deviation from reference" and "Within usual variation". The historical phrase needs the frozen reference: `detector == "frozen_persistence"`, or the reasons `frozen_reference_deviation`, `rolling_adapted_frozen_deviation_persists` or `frozen_and_rolling_agree`. Otherwise the shift is described against the recent usual range (RC-19). Its badges are Transient, Ongoing, and Provisional or Final.
- **Badges:** "Provisional" (finality), "Revised" (retrospective mode), "Unverified" (validity `unverified`).

### Detail sections (`MeasurementContextDetailModel`)

1. **When it was measured:** time range, zone ("PDT, UTC−7"), length, display bucket when it differs from the support, value. "Local day" is the day that owns the document (`header.identity.day`), not the date the night started. When the support crosses midnight, a note gives the start and end dates (R11).
2. **Signal:** validity state and reasons, coverage, observed time.
3. **Activity during the measurement:** shares per label, unknown activity, no activity data, source, changes and mixed. Posture classes always read as likelihoods ("Likely standing", "Likely sitting", "Likely lying down"). The second (decoder) estimate reads "Likely …" and is labelled "not a confirmed one … reads heart rate … never used to qualify" (RC-22). There is a note when the labels read heart rate.
4. **Before the measurement:** still run and what ended it, time since the last movement (for example "Time since walking"), and how far back it looked and how much of that was covered.
5. **Sleep and wear:** states with their evidence sources, time since waking, a note that sleep detection reads heart rate, and "Quiet motion alone never counts as sleep, rest or wear."
6. **Comparisons it qualifies for:** every verdict with its reasons. When there is evidence that depends on heart rate, it adds "Uses evidence that reads heart rate."
7. **References:** every view with its signed difference or status, support days, day range, center ± uncertainty marked "(approx.)" (P6), pooled share and reasons. A window with no comparison of its own lists the day's stable-awake comparisons as `day-reference-*` rows, with the note "Today's stable awake median, not this window alone". Footnote: "A historical reference is a past period of your own data, not a healthy range."
8. **Recent activity:** 24, 48 and 72 h windows (bouts, time moving, share observed), plus the last three bouts.
9. **Recorded exposures:** the document's current events (label, kind, time, precision, confirmation, dose; retracted events are left out) and the per-category status. "Recorded as none" (denied) is kept separate from "Not recorded". A denial covering only part of the window (`deniedCoverage < 1`, or not reported) reads "Recorded as none for part of this period", with "33% of this period; the rest is not recorded" (RC-14). The footnote says which period the status covers. `// LEAD-INTEGRATION` hook below.
10. **Inputs not available:** availability rows that are `unsupported`, `unverified` or `unavailable`.
11. **How final this is:** processing ("Live: only what was known at the time" or "Revised with later data"), finality, built at, data cutoff (live only), whether a newer version is being prepared (or, for a dead-lettered job, "Couldn't be updated with the latest data"), and the day's status reasons. Diagnostics shows the job's state, lease, revisions and reasons.
12. **Diagnostics** (collapsed `DisclosureGroup`, monospaced, selectable): device, read status (saved copy or network), context revision, pairing with both revisions, job, contract and schema, every policy version, policy and input fingerprints, input revisions, day and zone, undecoded counts, envelope id, method, source with its revisions, regime key, validity confidence kind, raw reason codes (validity, eligibility, activity, sleep and wear, wake, references and day status, diagnostics-only codes included).

### History (`PhysiologyContextHistoryModel`)

- **This metric's episodes** (series family prefix) are listed separately from other series. Each shows the series name, state, direction, dates with day count, badges and reasons.
- **Bouts**, newest first, show kind, local time range, duration and follow-up: "Follow-up complete", "Ongoing", or "Follow-up incomplete: another bout started". The cause is `recovery.censoring.first`; failing that, the censoring code among the reasons, then `insufficient_follow_up_samples`. It is never the alphabetically first reason (RC-06).

### Copy rules

- The required phrases are used verbatim: "stable awake measurement", "recent walking", "insufficient context", "persistent change from historical reference" (only when the frozen reference supports it), "provisional", "unverified".
- **Reason codes.** Every code in the 11 engine registries (319 unique) has exactly one of two entries. 280 have a plain phrase in `PhysiologyContextWording.reasonPhrases`. 39 are listed in `diagnosticsOnlyReasons`: developer detail such as input hygiene, estimators, detector names and provenance. Those never appear in the card, detail or history, and Diagnostics lists them raw. `PhysiologyContextWordingCoverageTests` fails when a registered code has no entry, or when an entry names a code no registry emits. `topReason` shows the first shown reason, because the engine lists the deciding reasons first (RC-05, engine side).
- `PhysiologyContextWording.forbiddenTerms` lists words (calm, stress or stressed, recovered, relaxed, anxious, tired or fatigue, illness, ill, sick, infection, fever, disease, diagnosis, medication effect, side effect, overtrained, mood, …). They are matched as whole words, so "still" does not match "ill".
- A code from a newer server that is in neither list is humanized. If the result would contain a forbidden term it becomes "another reason", so a new server code cannot introduce an inference.
- The person's own exposure labels are their words and are not scanned. The bout follow-up says "follow-up", never "recovered".

## Compatibility

- **Old server:** an unknown route answers 405 (`serverScores.ts` `method_not_allowed`), which becomes `.unsupportedServer`, which shows explicit copy and no error banner. A new edge function on a database without the migration answers 404 (the RPC's not-found passes through at `serverScores.ts:424`) and is treated the same way. A 200 without a `context` or `history` member is treated the same way.
- **Old or new document shapes:** unknown members are ignored. Absent members become nil or empty. A member that cannot be decoded is listed in Diagnostics, and so is an element that cannot be decoded (the rest of its array survives). `document.full` is nil whenever the document is not a complete `DayDocument`; the screens use only the per-member fields.
- **Revisions** may be numbers or strings and are kept as strings. A JSON bool never becomes a revision.
- **Old clients** never call these routes. Nothing existing reads the new cache folder (`<AppSupport>/OpenWhoop/cloud/physiology-context/`, a sibling of `scores/`).

## Integration hooks for the lead

1. `Strand/Screens/MeasurementContextDetailView.swift`, `exposureEditorHook(_:)`, under the "Recorded exposures" section. Comment: `// LEAD-INTEGRATION: exposure list/editor navigation`. Push `ExposureEventListView(window: model.exposureWindow ?? …)` from a `NavigationLink` with `.buttonStyle(LiquidPressStyle())`. `model.exposureWindow` is the document's `dayWindow`, or the support interval when there is no header.
2. `Strand/App/AppModel.swift`, `cloudBecameActive()` and `cloudAccountReady(_:)`: `// LEAD-INTEGRATION: ExposureEventCloudSync.flush()`, next to `StretchFeedbackCenter.shared.flush()`.
3. `Strand/Screens/PhysiologyContextHistoryView.swift`, `boutRow(_:)`: `// LEAD-INTEGRATION: heart-rate response summary per bout`. `PhysiologyContext.ExertionBout` has no response fields yet; show them when the responses workstream adds them.
4. Reason-code phrases. `PhysiologyContextWording.reasonPhrases` / `diagnosticsOnlyReasons` cover every registered code. A system that adds a code must add a phrase or a diagnostics-only entry, and the coverage test enforces this. A new registry must be added to `PhysiologyContextReasonRegistries.all` in the coverage test.
5. Metric filter value. The app sends `metric=<MetricKind.rawValue>` (`hrv_rmssd` or `resting_heart_rate`). Backend-db must filter envelopes on the same string. If the RPC expects another spelling, change it in `dayContext(day:deviceId:metric:mode:)`.

## Deviations

- **No fleet token on these routes.** The repository sets `Authorization: Bearer <installation token>` itself, instead of calling `CloudReceiverAuth.apply`, as the task asked. A legacy-enrollment installation, which needs the fleet header, therefore gets an HTTP failure, shown as "Couldn't load".
- **The live repository is built in the store** (`PhysiologyContextStore.runningAccountRepository()`, one per running `CloudDataScope`, with `CloudPushRuntime.credentialProvider(for:)`) rather than in `CloudPushRuntime`, so `CloudCapture.swift` is untouched.
- **"Selected day"** is the day of the hero's latest point (`latest(in:)`), which is the day the activity line uses.

## Tests

```bash
xcodegen generate
xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -derivedDataPath /tmp/pc-app-dd -only-testing:StrandTests/PhysiologyContextAppTests
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/pc-app-ios-dd CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -derivedDataPath /tmp/pc-app-dd -only-testing:StrandTests
```

`PhysiologyContextAppTests` (41 tests; 29 when first written) and `PhysiologyContextWordingCoverageTests` (4) cover:

- **Routes and auth:** path, query and `Authorization: Bearer noop_x` with no fleet header, for both routes; the 120-day clamp.
- **Round trip:** a `DayDocument` from `Engine.buildDay` on a small synthetic day (with placeholder systems) is encoded with `PhysiologyContext.encoder()`, wrapped in the API envelope, read back equal to the original (`document.full == doc`), and read back equal again from the cache.
- **Lenient decoding:** an unknown member, a removed member, a broken envelope and an invalid `sleep` decode what they can; a missing `status` or `pairing` is tolerated; a null `context` reads as none; a missing `context` reads as an old server.
- **States:** 405, or 404 without the migration, means unsupported (server-wide, with no further candidates asked); a dead-lettered job is "Context unavailable for this day"; 409 registration means pending, and the next candidate still answers; any other 409 is an error; the candidate walk prefers available over pending over none.
- **Cache:** owner isolation (another owner never reads the entry, the original owner keeps it, no ids appear in paths); a failed read keeps the cache; an unconfigured build makes no requests.
- **Store:** precondition copy; the full state machine, including stale pairing, pending, none, 409, 405, failed with the cached copy, and reset; cache first; a read in flight when the account ends never lands; history states.
- **Formatting:** signed differences with units; support time in the envelope's zone; zone label; durations; finality, episode and processing badges; headline selection; summary and detail rows; history split and bout follow-up.
- **Forbidden words:** more than 500 strings from every enum state, every registered reason code, card, detail (fresh and stale) and history model are checked, and each required phrase is confirmed to appear.
- **Review repairs** ([review-app-repairs.md](review-app-repairs.md)): reason coverage against the 11 registries; diagnostics-only codes kept out of the normal flow; the censoring cause; partial denials; today's stable-awake median; persistent change against the frozen versus the recent reference; the approximate ±; posture as a likelihood; polling backoff and check-back copy; the document's owner day.

## Results (2026-10-05, after merging `nara/main` at `ccd5f0dc`)

| Run | Result |
| --- | --- |
| `-only-testing:StrandTests/PhysiologyContextAppTests` (macOS) | 29 tests, 0 failures |
| `NOOPiOS` Debug, `generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED, no warnings in the new files |
| Full `-only-testing:StrandTests` (macOS) | 2894 tests, 7 skipped, 1 failure |

The one failure in the full run is `IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets`, one of the three failures docs/IOS.md already lists as pre-existing. The other two listed there (`SkinTempAbsoluteDisplayTests`, `SleepCarriedStampTests`) passed on this Mac.

After the full run I changed one thing: a failed re-read now keeps the server's last answer (none, pending or old server) instead of replacing it with "Couldn't load". `PhysiologyContextAppTests` was re-run afterwards: 29 tests, 0 failures.

No previews or screenshots were rendered.

## Results after the review repairs (2026-10-05, `pc/fix-app` from `204ea2c3`)

| Run | Result |
| --- | --- |
| `-only-testing:StrandTests/PhysiologyContextAppTests -only-testing:StrandTests/PhysiologyContextWordingCoverageTests -only-testing:StrandTests/ExposureEventTests` (macOS) | 63 tests (41 + 4 + 18), 0 failures |
| `NOOPiOS` Debug, `generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED, no warnings in the context files |
