# Manual event logging

The top of the Events tab logs real labels, and the rest of the tab is built from them
(`ManualEventPresentation`): the latest-reaction card, the timeline with its All / Reported / Detected
filter, All events and each event's page. A logged event's page draws heart rate, HRV and movement
(milli-g) before, during and after it from the event's server context, with Before / During / After
means and the recovery comparison against earlier events of the same type, and opens the full strap
context (what the classifier saw, baselines, what else was going on). An event without a synced context
is listed without curves. The DEBUG-only sample events still appear only under `--demo-events` /
`--demo-seed`, and the manual log does not upload them.

The logger supports saved custom types, favorites, live start/stop, timed and past events, notes,
editing, JSON export, named duration presets, and a retained archive. A preset's window ends now,
because logging is mostly retrospective and a window that ends in the future has no measurements behind
it yet. The slider moves the whole window into the past without changing its duration. Start now and
End now move both endpoints, and the date pickers can edit either endpoint.

The default catalog has three types: Rest, Walking and Exercise. Older factory types are archived
once per account and type, preserving their history and earlier event labels. Types the wearer
renamed, favorited or customized stay available. Restoring an archived type keeps it restored.
Custom types have a choice of icons; the type selector shows each type's icon when logging an event.

## Activity kinds

A type can say what it counts as for activity detection ("Counts as"): rest, walking, running,
cycling, stairs, exercise, or not an activity. Rest, Walking and Exercise count as themselves through
their fixed UUIDs; their seed revisions stay byte-identical, so they carry no field. An event copies its
type's kind when it is logged, like its label, so editing a type later never relabels past events.

## Storage and sync

Sign in before logging. `ManualEventStore` saves each full revision in
`OpenWhoop/ManualEvents/events.sqlite`, with an account key. SQLite rejects content updates and deletes.
Renaming a type does not rename past event labels. Archive and restore append revisions; no empty-trash
action exists. JSON exports include every revision, including archives, for the current account only.
Saving an entry that is already current adds no revision, and an empty note is stored as no note.

`ManualEventCenter` retries on foreground entry, account readiness, edits and every 30 seconds while
the Events tab is visible. Pending entries remain on the device after network errors or an older
server's 404/405. Only a reply that identifies the same account and source and names each revision UUID,
as saved or as rejected, settles it. A rejected revision (the server's reason is kept, for example
`revision_conflict`) stays in the history, is marked on the event, and no longer holds back later
writes. A server that refuses a whole request (400, 409 or 413) is asked again one revision at a time,
so one bad revision is set aside and the rest sync. A stale editor cannot save to an account that
replaced its owner.

The account-level endpoint is `GET/POST /functions/v1/scores/manual-events`. It uses the same verified
installation credential or registered account session as scores. No user ID is accepted in the body.
GET returns account-filtered history in pages of 100, including archived entries. POST accepts at most
25 revisions and judges each on its own: unknown fields, an unknown activity kind, oversized notes and
labels, events before 2000 and invalid time ranges come back in `rejected` with a reason, beside `saved`.
The database uses RLS for owner reads. Anonymous and authenticated clients cannot write, update, delete,
truncate or call the writer RPC; the service role can only select and insert. Source ownership is
checked again in SQL. Deleting the account removes every row through the auth.users foreign keys.

## Context

Every logged event gets a timestamp-aligned context document (`manual-event-context-1`), built on the
server from what is already there, never from a model of its own:

| Part | Source |
| --- | --- |
| Heart rate before (30 min), during and after (30 min): n, coverage, mean, range, p10/p50/p90, a binned trace | `noop_hr_samples` (per second) |
| Traces for the event page: canonical HRV buckets and binned wrist movement, each with its support seconds | `server_metric_series`, `noop_gravity_samples` |
| Wrist motion | `noop_gravity_samples.dynAccel` |
| HRV, resting HR, breathing rate, steps, energy | `server_metric_series` (published by the scoring lane) |
| Classes the activity classifier saw, with seconds and mean confidence; sleep and off-wrist seconds; agreement with the event's kind | `activity_context_runs` (published by the activity lane) |
| Wear events, placement, overlapping sleep | `noop_events`, `placement_intervals`, `server_sleep_nights` |
| Baselines: 7-day resting HR and HRV, causal frozen references, active baseline episodes | `server_metric_series`, `physiology_context_frozen_references`, `physiology_context_episodes` |
| Watchdog candidates, confirmed exposures from 6 h before, other logged events, earlier events of the same type | `anomaly_candidates`, `exposure_events`, `manual_event_revisions` / `manual_event_contexts` |

Lists are bounded (20 Watchdog candidates, exposures and other logged events; 50 wear events), and one
event whose context cannot be built never fails the others in a request or in the refresh.

The strap is the one the event was logged with (the app's device id, resolved like `findNoopDevice`, or
the server's device UUID when the app stored that),
else the one with the most heart-rate samples in the window. The status is `running`, `awaiting_data`
(uploads have not reached the end of the post window yet), `insufficient_data` or `ready`. A context
is rebuilt while it can change and frozen (`final`) 72 hours after the post window. Comparisons are
only between like quantities: during against before, against the week's resting HR and HRV, and against
the same type's typical heart rate.

`GET /functions/v1/scores/manual-events/context?ids=<uuid>,...` (at most 25) returns the caller's
contexts, rebuilding one that is older than five minutes and not final. pg_cron runs
`refresh_manual_event_contexts_v1(100)` every 10 minutes for events that ended in the last 14 days,
so contexts exist for other consumers without the app being open. The app asks for synced events
without a final context at most every five minutes, keeps the last reply on the device, and shows it
in the event row and in the event's detail sheet.

## Activity labels

A synced event whose kind is rest, walking, running, cycling or stairs, with a closed window of at
most 24 hours, becomes a row in `activity_ground_truth_labels` with `source = 'manual_event'` and
`label_key = 'manual_event:<event id>'` (locomotion stationary, walking, running, cycling, stairs), on
the strap it was logged with. Exercise and "not an activity" have no single classifier label and are
recorded as skipped. Archiving the event, or changing its kind away from one of these, removes the row;
the log keeps every revision. Clients still cannot submit that source. `manual_event_projections`
records what happened to each event. These are weak labels (self-logged, not cued) without sample-level
raw-IMU coverage, so the activity evaluation harness (`Tools/ActivityContext`, source `manual_event`) leaves
them out by default and uses them as weak labels only when non-ready labels are included. A type change
re-projects only when the kind it lends changes, and only the events that inherit it; an unchanged
event never rewrites its label. Exposures (caffeine, meals, medication) stay in their own log;
logged events show the confirmed ones around them but are not copied into it.

## Deploying

Apply, in order, with the SQL procedure in [BACKEND.md](BACKEND.md#migrations) (never `supabase db push`):

1. `supabase/migrations/20261008090000_manual_events.sql`
2. `supabase/migrations/20261008100000_manual_event_context.sql` (also schedules `nara-manual-event-context`)

Then deploy the `scores` edge function. No worker change is needed: the context reads what the activity,
scoring, context and anomaly lanes already publish. Until both steps are deployed, the UI reports
device-only storage and pending sync.

## Validation

```sh
xcodegen generate
xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -only-testing:StrandTests/ManualEventTests -only-testing:StrandTests/ManualEventSyncTests
(cd supabase/functions && deno test --allow-env --no-lock tests/manual_events_test.ts)
# On the production image (supabase/tests/e2e/pipeline_db.sh up):
psql "$PIPELINE_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f supabase/functions/tests/manual_events_retention.sql
psql "$PIPELINE_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f supabase/functions/tests/manual_event_context.sql
(cd supabase/functions && deno test -A --no-lock tests/manual_events_sql_test.ts)
```

The SQL checks exercise RLS, owner/source isolation, idempotent retries, per-item conflict refusal,
archive retention, denied update/delete access, the ground-truth projection and its removal, the
context of a walk built from real sensor rows, classifier runs, baselines, Watchdog candidates and
exposures, the cache, and account deletion. `manual_events_sql_test.ts` drives the real `scores`
handler through PostgREST. The Swift checks cover durable history, account switches, stale editors,
exact and per-item acknowledgements, isolation of refused revisions, offline retry, context fetch and
cache, activity kinds, the Events-tab presentation and the movable time window.
`EventLogUITests` (scheme `NOOPiOSUITests`) checks the tab in the simulator: the logged walk leads the
latest-reaction card and the timeline and opens with its three curves. `--demo-screen eventslog`,
`eventpage` and `eventdetail` show the tab, the event page and the context sheet with a sample context.
