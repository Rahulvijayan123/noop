# Exposures workstream (System E + phone side of exposure events)

Branch `pc/exposures` (from contract commit `71dce34a`, `nara/main` `ccd5f0dc` merged). Spec §6, §11, §15, §16,
V09, V15; contracts §2, §3, §4 E, §8, §10, §11.

## 1. What it is (and is not)

An exposure event is a **recorded** event: medication, supplement, caffeine, alcohol, meal, heat, travel, symptom,
other. Nothing here infers a dose, a meal, hydration, infection or stress from wearable data. Medication timing is
known only as well as the record says (`time_precision`). **Pharmacological effect, absorption and clearance are out
of scope**: aligned summaries for medication, supplement, caffeine and alcohol carry `pharmacology_not_modelled`, and
every aligned summary carries `association_only`. No field or reason names an effect, a cause or a direction of
benefit (a test greps the JSON for that vocabulary).

Four states never collapse into each other:

| State | Where it comes from | Meaning |
| --- | --- | --- |
| `confirmed` | the person (editor, journal "yes", numeric > 0) or an importer (Apple Health) | it happened |
| `denied` | journal "no" (or numeric 0) | explicitly did not happen, over the occurrence range only |
| `candidate` | `inferred_candidate` source | proposed by software; never confirmed (a candidate revision claiming `confirmed` is downgraded and reported `candidate_not_confirmed`) |
| unrecorded | no entry | **unknown**, not absence |

`retracted` is a revision state (a delete): it removes the event from current state and keeps the history.

## 2. Core (`PCExposures.swift`)

| Function | Rule |
| --- | --- |
| `current(_:mode:cutoff:)` | Usable revisions (non-empty id, revision ≥ 1, valid occurrence unless retracted) available at the cutoff (`availableAt = receivedAt ?? recordedAt ≤ cutoff`) in `causal_live`; all of them in `retrospective`. Latest per event by (revision, availability, entry time, content). Latest `retracted` ⇒ not current. `revisionCount` = distinct visible revisions. Non-finite dose ⇒ dose (and its unit/provenance) dropped. Ordered by (occurred, eventId). |
| `refs(for:events:config:)` | `overlaps` (0 s) when the occurrence overlaps the support; `precedes` when `support.start − occurred.end ≤ lookbackS` (seconds from the occurrence END); later events excluded. Denied and candidate events included with their own confirmation. Nearest first, then later start, then id. |
| `categoryStatus(for:events:config:)` | Window `[support.end − lookbackS, support.end)`, one entry per `ExposureKind` (declaration order): `recorded` if any confirmed overlaps, else `denied` (+ `denied_coverage` = union of denied ranges ∩ window / window), else `candidate_only`, else `unrecorded`. A confirmed occurrence outranks a denial (positive evidence). |
| `daySummary(...)` | `events`: current events overlapping `[dayStart − lookbackS, dayEnd)`. `category_status`: over the document day itself. `revisions_not_yet_available`: retrospective only, revisions of those events with `availableAt > cutoff`; **0 in causal mode** (the engine already removed them; counting would leak). `late_revisions`: retrospective only, revisions available after the day ended (`late_entries_included`). `aligned`: see below. |
| `affectedDays(...)` | See §3. |

**Event-aligned summaries** (`EventAlignedSummary`, at most `maxAlignedEvents` = 24 per document,
`aligned_events_limited` beyond): confirmed events overlapping the document day. For each window width `w` in
`alignedWindowsH` (3 h, 24 h): before `[occurred.start − w, occurred.start)`, after `[occurred.end, occurred.end + w)`;
the occurrence range itself belongs to neither side. Searched part = window ∩ `[dayStart, causal ? min(dayEnd, cutoff)
: dayEnd)` (`window_partially_searched` when smaller). Per (metric, method id): counts and medians of envelopes whose
whole support is inside the searched side, validity `valid`/`degraded` with a finite value (others counted in
`excluded_count`); `< minMeasurementsPerSide` (3) on a side ⇒ `insufficient_measurements`; different regime keys before
vs after ⇒ `regime_change`. Behaviour (heart-rate independent, explicit confounding): bout seconds (union of System D
bouts ∩ side) and locomotion / labelled seconds from the activity compositions of non-overlapping envelopes;
`behavior_change` when bout seconds differ by ≥ `behaviorChangeS` (600 s) or the locomotion share differs by ≥ that
many seconds of the window; `behavior_unobserved` when a side has no labelled activity. Concurrent events: other
confirmed or candidate events overlapping `[before.start, after.end)` ⇒ `concurrent_events`. **Time uncertainty**:
`day_only` ⇒ no windows at all, `time_uncertain`; a range wider than `w` skips that window (`time_uncertain`).

Reason codes (`Exposures.reasonCodes`): `association_only`, `concurrent_events`, `time_uncertain`,
`insufficient_measurements`, `behavior_change`, `behavior_unobserved`, `window_partially_searched`, `regime_change`,
`pharmacology_not_modelled`, `late_entries_included`, `aligned_events_limited`, `no_exposure_records` (nothing touches
the day: unrecorded, not absence), `candidate_not_confirmed`, `invalid_revisions_ignored`, `invalid_dose_dropped`.

Added fields (all defaulted, older JSON still decodes): `ExposureConfig.alignedWindowsH / minMeasurementsPerSide /
behaviorChangeS / maxAlignedEvents / maxAffectedDays` (custom decoding with defaults);
`ExposureCategoryStatus.deniedCoverage`; `ExposureDaySummary.aligned / lateRevisions`. New types:
`EventAlignedSummary`, `AlignedWindow`, `AlignedMetricSummary`, `AlignedBehavior`, `ConcurrentExposure`.

## 3. `affectedDays` rule (for the SQL mirror in `record_exposure_event_v1`)

```
ranges   = occurred of the new revision and, when present, of the previous current revision
           (an empty range [s, e≤s) counts as [s, s+1))
from_ts  = min(range.start) − maxAlignedWindowS        -- 24 h with the default alignedWindowsH = [3, 24]
to_ts    = max(range.end)   + lookbackS                -- 72 h with the default lookbackH = 72
days     = every local day (owner's zone) from local_day(from_ts) through local_day(to_ts), inclusive,
           capped at 120 days (earliest kept)
```

SQL sketch (zone = the device/owner zone used for day keys):
`generate_series((to_timestamp(from_ts) at time zone tz)::date, (to_timestamp(to_ts) at time zone tz)::date,
interval '1 day')`, then `invalidate_physiology_context_span_v1(owner, null, first, last, 'exposure_changed')`.

Why: forward reach = lookback (a measurement starting exactly `lookbackS` after the occurrence end still references it;
a day-only answer for D therefore reaches D+4, the day containing `D+1 00:00 + 72 h`). Backward reach = the widest
aligned window: an earlier day's aligned summary lists this event as concurrent when it falls inside that day's
after-window. This is one day more than the contract's "plus the 72 h lookahead" wording; **backend-db should mirror
the backward 24 h as well** (or the lead removes it here). The worker's exposure read window D-4..D+1 already covers
both directions.

## 4. Journal question → kind (`JournalExposureMapping`)

Whole-word phrase match on the normalized question, rules in this order, first match wins; anything else is `other`
with the question as label.

| Order | Kind | Phrases |
| --- | --- | --- |
| 1 | other | cold shower, cold plunge, ice bath, cold water, cold room, cold weather, fasting, fasted |
| 2 | medication | medication(s), medicine, meds, pill(s), painkiller(s), ibuprofen, paracetamol, acetaminophen, aspirin, antihistamine(s), prescription, sleeping pill, sleep aid, inhaler, antibiotic(s) |
| 3 | supplement | magnesium, supplement(s), melatonin, vitamin(s), zinc, creatine, ashwagandha, fish oil, omega, electrolytes, probiotic(s) |
| 4 | alcohol | alcohol, alcoholic, beer(s), wine, liquor, spirits, cocktail(s), drunk |
| 5 | caffeine | caffeine, coffee, espresso, energy drink(s), pre workout |
| 6 | heat | sauna, steam room, hot tub, hot bath, heat |
| 7 | travel | travel(led/ed/ling/ing), flight, flew, fly, jet lag, jetlag, time zone, timezone |
| 8 | meal | eat, ate, eating, meal(s), food, dinner, lunch, breakfast, snack(s) |
| 9 | symptom | sick, ill, illness, symptom(s), fever, headache, migraine, cold, flu, sore, nausea, nauseous, cough, congestion, congested, pain, injured, injury |

Starter questions: alcohol → alcohol; "caffeine late in the day" → caffeine; screen in bed, stressed, share your
bed, read before bed → other (recorded as stated, never reinterpreted — stress is not inferred or relabelled);
"eat close to bedtime" → meal; sauna → heat; "sick or ill" → symptom; magnesium → supplement.

## 5. Phone side

**Store** (`Strand/Data/ExposureEventStore.swift`): table `exposureEventRevision` in the shared WhoopStore database
(`store.registryWriter`, `CREATE TABLE IF NOT EXISTS`, like `PlacementStore`), PK `(owner, eventId, revision)`, every
revision field plus `sourceKey` (local provenance), `synced`, `serverStatus`, `serverReason`. Triggers reject any
update of identity/content columns and a second write of `receivedAt`. `record` is idempotent for identical content
and throws `revisionConflict` otherwise. Owner ids are lowercased; revisions recorded before any account claimed the
phone are stored under `unclaimed`, never uploaded, and adopted by the local-data owner (`adoptUnclaimed`: journal
events re-keyed to the owner's deterministic id, renumbered in entry order after the owner's synced history).
`current(owner:from:to:)` runs the core `current` (retrospective) over every revision of events touching the window.
`replaceFromServer` merges: server revisions inserted as synced or confirm the identical local row (filling
`receivedAt`); a pending local revision whose number the server already used (another phone of the same account) is
renumbered after the server's history, keeping its content; nothing pending is ever deleted.

**Deterministic journal id**: first 16 bytes of SHA-256 over UTF-8
`journal|<owner lowercased>|<yyyy-MM-dd>|<JournalCatalogStore.norm(question)>`, byte 6 = `(b & 0x0F) | 0x80`
(RFC 9562 version 8), byte 8 = `(b & 0x3F) | 0x80`, lowercase UUID string. Caffeine: intake UUID (the HealthKit sample
UUID for imports). Editor: random UUID.

**Bridge** (`ExposureJournalBridge.swift`), fire-and-forget on one serial queue (edit order preserved, failures
logged, never thrown into the journal/caffeine flow, no revision when nothing changed):

| Source | Revision |
| --- | --- |
| journal yes / no | `confirmed` / `denied`, `occurred` = local day `[midnight, next midnight)` (phone zone), `day_only`, `journal_day_answer`, label = question (whitespace-collapsed) |
| journal numeric v | v > 0 ⇒ `confirmed`, v = 0 ⇒ `denied`; `dose_amount = v`, `dose_unit` = catalog unit, `dose_provenance = catalog_default` (no unit ⇒ `user_entered`) |
| journal cleared | `retracted` copy of the latest revision (nothing when never recorded) |
| caffeine log | `[t, t+1)`, `exact`, `caffeine`, mg dose, `user_entered` |
| Apple Health caffeine | same, `imported` (dose provenance `imported`); a sample missing from a later import is retracted only when it is newer than `now − 47 h` (an hour inside the 48 h import window), so aging out is not a deletion |
| caffeine remove / clear all | `retracted` |
| caffeine 48 h pruning | **nothing**: the exposure store is the durable record |

Hooks: `Repository.saveJournalAnswer / saveJournalNumeric / clearJournalAnswer` (after a successful write);
`CaffeineLogStore.log / remove / clearAll / replaceImported` through `exposureSink`, which only
`CaffeineLogStore.shared` sets (test instances stay inert).

**Sync** (`ExposureEventCloudSync.swift`): `ExposureEventCloudSync.flush()` (`@MainActor`, single-flight, never
throws) → `ExposureEventSyncClient.sync()`: requires a signed-in identity AND `CloudLocalDataBinding.isOwner`; adopts
unclaimed rows; `GET {scores}/exposures?from=now−30d&to=now+1d&history=1` and reconcile; then `POST {scores}/exposures`
`{"events": [...]}` in batches of 25 of the owner's own pending rows (entry order). Results: `saved`/`ignored` ⇒ synced;
`rejected` ⇒ kept, reason stored, not retried; unnamed ⇒ pending. 405/404 ⇒ `unsupported`, everything stays pending;
401/403 ⇒ `unauthorized`, stop; 409 ⇒ reconcile then stop (retried next flush); other ⇒ stop. A reply whose `identity`
names another account marks nothing (`identity_mismatch`). GET reply parsing accepts `events`, `revisions` and nested
`revisions`, each decoded on its own.

**UI**: `ExposureEventListView(window:)` ("Recorded events": kind, label, time with precision, dose/unit, "Answered
no" / "Not confirmed", "Journal" / "Imported", "Edited" when `revisionCount > 1`, add, tap or context menu to edit,
Remove = retract; journal and imported rows are read-only here). `ExposureEventEditorView(event:defaultTime:onDone:)`
(kind, name, moment or range, exact/approximate — approximate moment = `[t − 30 min, t + 30 min)` — optional amount and
unit; Save writes the next revision, Remove a retraction; removing a card-logged caffeine also removes it from the
card).

## 6. Wiring for the lead

- `AppModel`: `Task { await ExposureEventCloudSync.flush() }` next to each `StretchFeedbackCenter.shared.flush()`
  (`cloudBecameActive`, `cloudAccountReady`).
- Context detail view: `ExposureEventListView(window: PhysiologyContext.Interval(...))`; the editor alone is
  `ExposureEventEditorView(event: nil, defaultTime: Date(), onDone: {})`.

## 7. Limitations / open issues

- Journal answers are day-granular; their aligned summaries are always `time_uncertain` (no hour-level alignment).
- Journal history written before this change is not back-filled into exposure revisions (only new writes are).
- Editing a card-logged caffeine intake in the editor does not update the caffeine card's 48 h decay list (removal
  does).
- Two phones editing the same event offline: the pending one is renumbered after the other's on reconcile, so the
  later *upload* wins, not the later entry.
- New UI strings are not yet in `Localizable.xcstrings` (i18n audit will list them).
- The SQL invalidation must add the 24 h backward reach (§3) to match `affectedDays`.

## 8. Tests ↔ V-cases

| Case | Test |
| --- | --- |
| V09 late entry (occurrence vs availability) | `PCExposureTests.testLateEntryIsInvisibleToAnEarlierCausalViewButUsedRetrospectively`, `testEngineLiveDocumentIgnoresLateEntriesAndRetrospectiveCountsThem` (live document byte-identical with late revisions appended) |
| V09 correction, V15 invalidation | `testCorrectionReplacesCurrentStateKeepsHistoryAndInvalidatesOldAndNewDays`, `testAffectedDaysFollowLocalDaysAcrossTheDSTChange` |
| V09 retraction | `testRetractionLeavesCurrentStateButKeepsHistory`; app `testRevisionsAreImmutableAndRecordingIsIdempotent` |
| V09 absent ≠ denied ≠ confirmed | `testUnrecordedDeniedAndConfirmedAreDifferentStates` |
| candidate never confirmed | `testACandidateIsNeverPromotedToConfirmed` |
| day-only ⇒ no hour alignment | `testDayOnlyPrecisionGetsNoHourLevelAlignment` |
| concurrent events, behaviour change, regime | `testAlignedWindowsDescribeMeasurementsWithConcurrentEventsAndBehaviourChange`, `testRegimeChangeAcrossTheEventIsFlagged`, `testCausalAlignmentStopsAtTheCutoffAndThinDataIsInsufficient` |
| V10 / determinism | `testOrderIsDeterministicAndOlderSummariesDecode` |
| V15 idempotent revisions, V16 owner scope | app `testRowsAreScopedToTheirOwner`, `testNothingIsSentForAnotherAccountOrWhileSignedOut`, `testUnclaimedRevisionsUploadOnlyOnceTheLocalOwnerAdoptsThem`, `testReconcileRenumbersAPendingRevisionAnotherPhoneAlreadyUsed` |
| V16 old server | app `testAnOldServerKeepsEverythingPending` |
| bridge mapping | app `testJournalAnswersBecomeDayOnlyRevisionsOfOneEvent`, `testJournalQuestionsMapToKindsByTheDocumentedTable`, `testJournalIdsAreDeterministicUUIDs`, `testCaffeineIntakesBecomeExactRevisionsAndRemovalRetracts`, `testCaffeineStoreReportsChangesButNotPruning`, `testJournalHookRecordsWithoutBlockingTheJournalWrite` |

## 9. Commands and results

| Command | Result |
| --- | --- |
| `swift build` (Packages/StrandAnalytics) | Build complete |
| `swift test --filter PCExposure` | 13 tests, 0 failures |
| `swift test --parallel` | 2591 tests, exit 0 (after merging `nara/main` `ccd5f0dc`) |
| `xcodegen generate` | project generated (pbxproj not committed) |
| `xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -derivedDataPath /tmp/pc-exposures-dd -only-testing:StrandTests/ExposureEventTests` | 18 tests, 0 failures |
| `xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/pc-exposures-ios-dd CODE_SIGNING_ALLOWED=NO build` | BUILD SUCCEEDED (no warnings in the new/changed files) |

No secrets files were needed (all `#include?` are optional). Not run: device install, backend/worker, production
anything.
