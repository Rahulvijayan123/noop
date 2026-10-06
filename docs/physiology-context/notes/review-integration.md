# Physiology context: independent integration review (backend, worker, app, end to end)

Reviewer: integration (fresh, independent; did not write this code). Target: `28f5e602` (detached worktree
`pc-review-integration`). The branch has since moved to `40781a63` (an e2e test, hash-keyed stored-form pools,
docs); those commits were not re-reviewed. No production code was changed. Nothing hosted was touched; the scratch
database was the Docker pipeline on ports 55491–55493 (`NARA_PIPELINE_DIR=~/.cache/pc-review-integration-pipeline`).

Spec items covered: §6.3, §15, §16, V09, V10, V15, V16, V17, C07–C09, C11.

## 1. Findings

Severity: High = wrong product silently published or security; Medium = a correctness gap a user can see; Low =
narrow window, self-healing, or UX.

| ID | Severity | Verdict | Finding and evidence | Suggested fix |
| --- | --- | --- | --- | --- |
| R1 | High | CONFIRMED-DEFECT | **A transient failure of any optional input read is published as a complete document and never retried.** `ContextInputs.load` wraps history daily values, history bouts, frozen references, HART epochs, decoder runs, placement and exposures in `optional(...)` (`Tools/CloudWorker/Sources/frwhoop-worker/ContextInputs.swift:341-344`), which catches *every* error (not only a missing table), records `<input>_unavailable` and carries on. The degraded document has a new input fingerprint, so publish stores it, completes the job and (for the latest day) replaces the episode set. Nothing re-enqueues it. **Executed** (`ReviewIntegrationScratchTests.testReviewTransientHistoryReadFailureIsPublishedAsComplete`): healthy revision 6 had nightly HRV `recent:ready, rolling:ready, frozen:ready` and five `usual_variation` episodes; another session held `LOCK TABLE physiology_context_daily_values` while the worker read with a 2 s statement timeout (the lock was gone before publish); `load` returned normally with `unavailable=["history_daily_values_unavailable"]`; publish → `published(revision: 7)`, job `done 4 = rev 4`, reasons empty; revision 7: `recent:insufficient, rolling:insufficient`; the current episode table became five `insufficient_evidence` rows; the following enqueue bumped 0 jobs. The same path turns a transient exposure read failure into a day without exposure references. | Treat only "object missing" (42P01, 42883, maybe 42703) as unavailable; rethrow every other error so the lane settles through `fail_physiology_context_v1` (backoff, retry). Optionally refuse to replace the episode set from a document that has any `*_unavailable` input. Add a DB test with a lock + short statement timeout. |
| R2 | Medium | CONFIRMED-DEFECT | **The cross-day cascade (D+1 .. D+28) is shorter than the episode dependency horizon.** Publish bumps only `q.day between j.day + 1 and least(v_today - 1, j.day + 28)` (`supabase/migrations/20261006050000_physiology_context.sql:1355`). References fit it (`rollingWindowDays = 28`, `conditionedWindowDays = 28`, `PCReferences.swift:56,79`), but change detection scores a 90-day window and estimates autocorrelation over 56 days (`PCChangeDetection.swift:23,40`), and the worker loads D−90..D−1 of history (`ContextInputs.swift:87`). So a corrected day D changes the episodes of documents D+29..D+90, which are never rebuilt. The current episode table is replaced only by a publish of the latest day (`:1304`); when D < today−29 the latest day is not cascaded, so for an owner with no new days the table stays stale. **Executed** (`/tmp/pcri-cascade.sql`, real `claim`/`publish` RPCs): D = today−45 with retrospective jobs D+1..D+44; a correction publish with a different daily value → `cascaded_days 28`, `history_changed` on D+1..D+28 only; D+29..D+44 (16 jobs, all inside the 90-day episode window) untouched. | Derive the horizon from the policy (max of the reference and change windows, i.e. 90), or keep 28 for documents but always also bump the latest retrospective day (today−1) and today's causal job so the episode set is rebuilt from the corrected history. Update the SQL test that pins `D + 28`. |
| R3 | Low–Medium | CONFIRMED-DEFECT | **Lock-order inversion between the enqueue and every other job toucher → deadlock.** The enqueue touches jobs newest day first (`order by … k.day desc`, `:732`; finality loop `order by d.day desc`, `:761`); `internal.physiology_context_invalidate` (exposure RPC, placement trigger, operator span) touches oldest first (`order by d.id, g.day`, `:523`) and the publish cascade ascends too (`:1352-1358`). **Executed** (`/tmp/pcri-deadlock-setup.sql` + three psql sessions; the third only aligns timing by holding one row): real `record_exposure_event_v1` vs real `enqueue_physiology_context_days_v1` on one owner's 12 retrospective jobs → `ERROR: deadlock detected … PL/pgSQL function internal.physiology_context_invalidate … record_exposure_event_v1`; the exposure revision rolled back (the edge would answer 500 `scores_unavailable`; the app keeps it pending and retries). As the victim, a publish fails and backs off; the placement trigger swallows the error into a WARNING, so that invalidation is lost (see R4). | Touch rows in one global order everywhere: sort enqueue candidates ascending by `(user_id, device_id, day, mode)` before touching (e.g. collect into an array, then loop ascending), or take a per-owner `pg_advisory_xact_lock` before touching any of that owner's jobs. |
| R4 | Low–Medium | CONFIRMED-DEFECT (mechanism, by code) / PLAUSIBLE-RISK (impact) | **A dependency-fingerprint change alone never bumps an existing job.** The enqueue bumps a completed job only when `k.touched_at > j.dirty_at`, i.e. scoring of D−1..D+1 completed after the job was last dirtied (`supabase/migrations/20261006050000_physiology_context.sql:728-731`); the fingerprint is compared only after that. HART v1 epochs are covered indirectly (`publish_activity_context_v2` calls `scoring_dirty_span`, `20261003120000_activity_context.sql:297`, so scoring re-completes). Decoder stream-day documents (`activity_context_days` / runs, which the worker reads) are not: their publish "never calls scoring_dirty_span" (`20261003140000_activity_context_stream_days.sql:10`) and nothing in this migration invalidates on them, so a stream day published after the context build reaches the context only through a later, unrelated scoring completion or the one-off `finality_due` rebuild; a decoder re-run after day end + 30 h never does. The placement trigger comment ("the next enqueue still sees the placement change through the dependency fingerprint", `:576-578`) is wrong for the same reason, which matters when the trigger's invalidation fails (R3 shows it can, and the trigger downgrades that to a WARNING). Reproduction script prepared (`/tmp/pcri-activity.sql`) but not executed: the scratch DB hit `PANIC: could not fdatasync … Input/output error` when the drive disconnected the second time. | Let the enqueue bump on a fingerprint change alone (drop the `touched_at > dirty_at` precondition for the fingerprint branch, keep the 10-minute settle), or add a trigger on `activity_context_days` that calls `internal.physiology_context_invalidate`. |
| R5 | Low–Medium | CONFIRMED-DEFECT | **A bouts-only change on D does not cascade.** Day X reads bouts of X−3..X−1 as history (`Tools/CloudWorker/Sources/frwhoop-worker/ContextInputs.swift:88`, the 24/48/72 h recent-exertion features), but the publish cascades only when the day's *daily values* changed (`v_changed`, `:1276`). D+1 can be reached through the D±1 fingerprint (only after a scoring completion, R4); D+2 and D+3 cannot. **Executed** (`/tmp/pcri-bouts.sql`, real `claim`/`publish`): D = today−10 with retrospective jobs D+1..D+5; the walk corrected from 08:00 to 18:00 with identical daily values → `daily_values_changed false`, `cascaded_days 0`, 0 later days pending, stored bout moved to 18 h. | Compare the day's bouts (id, interval, status, kind) as well as its daily values; cascade D+1..D+3 for a bouts-only change. |
| R6 | Low | PLAUSIBLE-RISK | **Prior-sleep history (D−14..D−2) is outside the fingerprint.** System C reads 14 prior nights (`ContextInputs.swift:89`, `PCEngine.swift:84,155`) from earlier snapshots, but the fingerprint covers scoring D−1..D+1 only (`:441`). A re-scored night D−5 (sleep edit) reaches D−3..D+9 only through the daily-value cascade, i.e. only when that night's daily values changed. | Put the prior-night snapshot revisions in the fingerprint, or cascade D+1..D+14 when a day's sleep sessions change. |
| R7 | Low | PLAUSIBLE-RISK | **The client never checks which result its own hero shows.** The card gets only `(metric, day)` (`Strand/Screens/MetricExplorerView.swift:1014`), and `PhysiologyContextStore.classify` (`PhysiologyContextStore.swift:248`) trusts the server's `pairing.consistent` (latest server snapshot vs the context's snapshot). If the phone shows an older hosted result than the server's latest (not yet synced) while the context was rebuilt from the latest, the card pairs a reference difference computed from the envelope value (e.g. 47.3 ms) with a different hero value. | Pass the hero's snapshot result revision (or value) into the card and treat a mismatch with `context_scoring_result_revision` as "updating". |
| R8 | Low | PLAUSIBLE-RISK | **"Context updating" can outlive the poll and can be permanent.** The card polls 10 × 30 s = 5 min (`MeasurementContextCard.swift:135-136`); an existing job is bumped only once `dirty_at ≤ now − 10 min` (`:731`) and the lane enqueues every 120 s, so a refresh often lands after polling stopped (observed: right after a re-score the enqueue bumped 0 jobs). A dead-lettered job with an inconsistent pairing shows "Updated context is on its way" forever: the app's `Job` drops `dead_letter` (`PhysiologyContextRepository.swift:44-47, 421`). | Poll for ≥ 15 min (or back off up to it); show a different line when `job.dead_letter` is true. |
| R9 | Low | PLAUSIBLE-RISK | **New edge + missing migration shows an error, not "unavailable".** A missing RPC is a PostgREST 404 → the handler answers 404 `request_rejected` (`serverScores.ts:424`); the app maps only 405 to `.unsupportedServer` (`PhysiologyContextRepository.swift:386`) → "Couldn't load measurement context". The exposure sync already treats 404 as unsupported (`ExposureEventCloudSync.swift:146,226`). Deploy order (migration first) avoids it; a rollback that drops the functions does not. | Map 404 on these two routes to `.unsupportedServer` as the exposure sync does. |
| R10 | Low | PLAUSIBLE-RISK | `cutoff_override` survives bumps: `internal.physiology_context_touch` never clears it (`:467-480`); only a successful publish does (`:1225, :1346`). A replay that dead-letters leaves its old cutoff in place, and the next live bump of that causal job then decides at the old replay cutoff. | Clear `cutoff_override` in `touch` unless the caller sets one. |
| R11 | Low | PLAUSIBLE-RISK (wording) | In the executed V17 render the detail sheet says "Local day: Oct 3" for the nightly value the document owns as Oct 4 (support starts 21:00 the evening before): `MeasurementContextDetailView.swift:113` shows the support start's local day, while sleep ownership is the day containing the end. | Show the document's day (or "night ending Oct 4") for session aggregates. |

Verified OK (with the evidence that was executed):

| Check | Verdict | Evidence |
| --- | --- | --- |
| RLS on all nine new tables; no new client-callable function; service-only EXECUTE; empty `search_path` | OK | `physiology_context_sql_test.ts` catalogue step passed; `auth_isolation_sql_test.ts` "exactly the reviewed functions are executable by clients" fails only on the pre-existing `activity_context_at` (diff `+ 'activity_context_at'`, nothing new); "every user-owned table shows a signed-in user only their own rows" passed |
| Owner from the credential; device via `findNoopDevice`; cross-owner reads | OK | Scratch handler run: owner B's installation asking for owner A's `deviceId` → 409 `device_registration_pending` on `/context` and `/context/history` |
| Exposure POST cannot write another owner's events | OK | Scratch: owner B posted `{owner: A, user_id: A, events:[{…, owner: A}]}` → `saved`; the stored revision's `owner` = B |
| Revoked installation | OK | Scratch: revoked installation of owner A → 401 `installation_revoked` |
| Account / device deletion cascades every new table (envelope tables included) | OK | SQL suite step "deleting a device or the account removes every row, frozen references and exposure history included" passed |
| Claim / renew / fail / publish fencing, expired lease, stale revision, dead letter, backoff | OK | SQL suite (15 steps) and worker DB tests (`testAWorkerThatDiesMidJobIsReplacedByOneThatPublishesOnce`, `testRetryingTheSameInputsStoresNoNewRevision`) passed |
| Duplicate publish (same fingerprints) creates no row, table or episode | OK | worker DB test `unchanged`; RPC `unchanged` path updates only the pairing columns (`:1210-1229`) |
| Finality loop (fixed in 28f5e602) | OK | Executed end to end (`testReviewFinalityLoopIsGone`): a real provisional retrospective build (cutoff day end + 2 h) and a later final build with identical `input_revisions`; round 1 enqueue → `finality_due` → new revision 45 `final`; rounds 2–4 enqueue 0, no re-bump |
| Cascade convergence | OK (bounded) | Cascade is forward-only and bounded by today−1; claims run retrospective oldest first. Cost: each provisional→final flip re-runs D+1 once (daily values carry `finality`) |
| Retention | OK (one documented exception) | Superseded rows go after 24 h; the A→B→A path deletes a superseded row younger than 24 h on purpose (`:1230-1235`) |
| Failure isolation (V16) | OK | Lane off by default (exact `1`), own connection/thread; `testAFailingContextLaneDoesNotStopScoring` and `testTheLaneIdlesWhenTheTablesAreMissing` passed |
| Old clients; unknown routes | OK | Route test "existing routes answer exactly as before"; scratch: `/context/historyx` and `/context/` → 405 `method_not_allowed` |
| New app vs old server (405) | OK | App tests (405 → `.unsupportedServer`, explicit copy, no further candidates) |
| Stale pairing (spec §15) | OK end to end | Executed: worker publish → afternoon data → real scoring lane publishes snapshot 10 → real handler returns `pairing {consistent: false, snapshot 10, context 7}` → app `classify` = `.stale`, card "Context updating" with no support / eligibility / reference, detail banner shown |
| Causal vs retrospective separation; cutoffs | OK | `mode` is part of every key; causal history filtered by publication time; `testACausalReplayIsUnchangedByDataThatArrivedAfterItsCutoff` passed |

## 2. V17 chain that was executed

1. Docker pipeline DB (`pipeline_db.sh up`, image `supabase/postgres:17.6.1.075`, GoTrue, PostgREST, full ordered chain
   incl. `20261006050000`).
2. `ReviewIntegrationScratchTests.testReviewV17ChainLeavesAPublishedContext` (scratch, worker test target): simulated
   strap streams stored like ingest → REAL `ScoringLane` publishes snapshot 34 → `invalidate` → REAL `ContextLane`
   claims, loads, builds, splits and publishes (revision 40, provisional). Then 83 synthetic history rows (the day's own
   six retrospective daily values copied onto D−14..D−1 with ±4 % spread, **DB-level, not computed by the engine**) →
   re-publish revision 43. Installation + token inserted; the owner is left in place.
3. `supabase/functions/tests/review_v17_scratch.ts` (scratch): the REAL `handleScoresRequest` against the pipeline
   PostgREST with the installation bearer. `GET /scores/context?deviceId=whoop-PCRIV17…&day=2026-10-04&metric=hrv_rmssd`
   → 200, 273,617 bytes (no-store is asserted by the route tests), `status available`, `mode retrospective`, `context_revision 43`,
   `pairing {consistent: true, 34, 34}`, one table `hrv_rmssd` with 121 rows; same for `resting_heart_rate` (119 rows);
   `/context/history` (30 days) → 2 days, 90 daily values, 1 bout, 5 episodes.
4. `StrandTests/ReviewV17ScratchTests` (scratch): the exact captured bytes served through a `URLProtocol` stub into
   `PhysiologyContextRepository.dayContext` / `.history`, `PhysiologyContextStore.classify`, `MeasurementContextSummary`,
   `MeasurementContextDetailModel`, `PhysiologyContextHistoryModel`. Result: `full` DayDocument decoded, 0 undecoded
   elements/members, state `.available`. Card (HRV): **"Sleep measurement" · "Measured 9:00 PM–9:59 AM" · "Qualifies for
   the sleep comparison" · "Activity known for 100% · signal 100%" · "−1 ms vs your 14-day reference" · "Within usual
   variation" [Ongoing, Provisional] · badges [Provisional, Revised]**. Resting HR: "Sleep measurement", "Measured
   9:00 PM–7:57 AM", "−1 bpm vs your 14-day reference". Detail: 11 sections incl. References (recent ±0 ms, rolling −1 ms,
   historical −1 ms with support, span, centre ± uncertainty). History: 5 episodes, bout "Workout | Oct 4 at
   8:00 AM–8:20 AM | 20 min | Follow-up complete".
5. Stale variant (steps 2–4 with `testReviewStalePairingEndToEnd` + `review_stale_scratch.ts`): see §1 "Stale pairing".

What V17 does not show: real (non-synthetic) strap data, multi-week engine-computed history (history was copied at the
DB level), any hosted environment, the iOS build, rendered SwiftUI (view models only, no screenshots).

## 3. Executed

| Command | Result |
| --- | --- |
| `pipeline_db.sh up` (ports 55491–55493) | ready; full chain applied. Rebuilt once after the Docker VM crashed with the drive (~17:02); that DB was lost again at ~18:27 (second disconnect) |
| `FRWHOOP_TEST_DB_URL=… swift test --filter ContextLaneDatabaseTests` | 9 tests, 8 passed, 1 skipped (opt-in profile), 0 failures, 348 s |
| `swift test --filter 'ContextLaneTests\|ContextLaneFixtureTests'` | 31 tests, 0 failures (486 s under host load ≈ 70) |
| `deno test … tests/physiology_context_sql_test.ts` (after `reset`) | 1 passed (15 steps) |
| `deno test … tests/exposure_events_sql_test.ts` (after `reset`) | 1 passed (6 steps) |
| `deno test … tests/auth_isolation_sql_test.ts` (after `reset`) | 1 passed (11 steps), 1 failed step: `activity_context_at` client-executable (pre-existing; no new name) |
| `deno test … tests/physiology_context_routes_test.ts` | 18 passed |
| `xcodegen generate`; `xcodebuild build-for-testing … -derivedDataPath /tmp/pc-review-int-dd` | TEST BUILD SUCCEEDED |
| `xcodebuild test-without-building … -only-testing:StrandTests/PhysiologyContextAppTests -only-testing:StrandTests/ExposureEventTests` | 48 tests (30 + 18), 0 failures |
| Scratch `testReviewV17ChainLeavesAPublishedContext` | passed (§2) |
| Scratch `review_v17_scratch.ts` | §2 step 3; cross-owner 409/409, exposure owner = credential, revoked 401, unknown route 405, trailing slash 405 |
| Scratch `StrandTests/ReviewV17ScratchTests` (2 tests) | 2 passed (§2 step 4, stale variant) |
| Scratch `testReviewFinalityLoopIsGone` | passed: finality loop gone |
| Scratch `testReviewStalePairingEndToEnd` + `review_stale_scratch.ts` | passed: `consistent false` → `.stale` |
| Scratch `testReviewTransientHistoryReadFailureIsPublishedAsComplete` | passed as a reproduction of R1 |
| `/tmp/pcri-cascade.sql` | R2 reproduced (`cascaded_days 28`; D+29..D+44 untouched) |
| `/tmp/pcri-deadlock-setup.sql` + 3 sessions | R3 reproduced (`deadlock detected` in `record_exposure_event_v1`) |
| `/tmp/pcri-bouts.sql` (rebuilt DB) | R5 reproduced (`cascaded_days 0`, bout moved, no later day pending) |
| `/tmp/pcri-activity.sql` | NOT RUN: the DB panicked (`could not fdatasync … Input/output error`) when the external drive disconnected a second time |

Not run: the full `StrandTests` suite and the iOS build (not requested), `ContextLaneProfileTests` (opt-in), the whole
worker suite, any hosted deploy, `/tmp/pcri-activity.sql` (environment failure above). Everything in §1–§2 except R5
ran on the first scratch DB; R5 ran on the DB rebuilt after the first Docker VM crash; the second drive disconnect
ended the session's DB work.

Scratch files (untracked, not committed): `Tools/CloudWorker/Tests/frwhoop-workerTests/ReviewIntegrationScratchTests.swift`,
`StrandTests/ReviewV17ScratchTests.swift`, `supabase/functions/tests/review_v17_scratch.ts`,
`supabase/functions/tests/review_stale_scratch.ts`, `/tmp/pcri-*.sql`, `/tmp/pcri-psql.sh`; `Config/*Secrets.xcconfig`
copied from the examples (gitignored).
