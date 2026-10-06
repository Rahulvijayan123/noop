# Physiology context — rollout

How to bring the physiology context layer up in development, what a separate production activation requires, how it
stays compatible, and how to roll it back (spec §4, §15, §20.5). **Nothing in this document has been run against
production.** No production migration was applied, nothing was deployed, no provider or lane was activated, and the
branch is not merged to `main`.

## 1. What ships

| Piece | Where | Default state |
| --- | --- | --- |
| Core engine (Systems A–G) | `Packages/StrandAnalytics/Sources/StrandAnalytics/PhysiologyContext/` | Linked by the app and the worker; runs only when called |
| Migration | `supabase/migrations/20261006050000_physiology_context.sql` (additive, re-runnable) | Not applied anywhere but local scratch databases |
| Edge routes | `supabase/functions/_shared/serverScores.ts` + `_shared/physiologyContext.ts` (`GET /scores/context`, `GET /scores/context/history`, `POST`/`GET /scores/exposures`) | Not deployed |
| Worker lane | `Tools/CloudWorker/Sources/frwhoop-worker/Context*.swift`, wiring in `main.swift` | **Off** unless `FRWHOOP_CONTEXT_ENABLED=1` |
| App | context card on the HRV and resting-HR pages, detail sheet, history, recorded-events list and editor, exposure sync | Card shows only when the server returns context; otherwise hidden (local mode) or an explicit "unavailable" state |

Existing scoring, series, candidate-provider selection (`physiology_provider_defaults` all `off`) and score
publication are unchanged. The context lane writes only through its own fenced RPCs; it never writes `noop_*`,
`sessions`, scoring tables or series, and never calls `scoring_dirty_span` or `enqueue_scoring_v2` (unit-tested over
every statement the lane sends).

## 2. Environments

There is no staging project (`docs/core-plumbing/acceptance.md`: "STAGING: none exists"). The dev procedure is a
local, disposable database built from the full ordered migration chain:

```bash
export NARA_PIPELINE_DB_PORT=55481 NARA_PIPELINE_REST_PORT=55482 NARA_PIPELINE_AUTH_PORT=55483 \
  NARA_PIPELINE_DIR="$HOME/.cache/pc-pipeline"
supabase/tests/e2e/pipeline_db.sh up            # supabase/postgres 17.6.1.075 + GoTrue + PostgREST, ordered chain
set -a; source "$NARA_PIPELINE_DIR/pipeline.env"; set +a
cd supabase/functions
EDGE_TEST_ARTIFACTS=/tmp/pc-edgeart deno test -A --no-lock tests/physiology_context_sql_test.ts
../tests/e2e/pipeline_db.sh reset
EDGE_TEST_ARTIFACTS=/tmp/pc-edgeart deno test -A --no-lock tests/exposure_events_sql_test.ts
deno test --allow-env --allow-read --no-lock tests/physiology_context_routes_test.ts
cd ../../Tools/CloudWorker
export PKG_CONFIG_PATH=/opt/homebrew/opt/libpq/lib/pkgconfig:/opt/homebrew/opt/openssl@3/lib/pkgconfig:/opt/homebrew/opt/zstd/lib/pkgconfig \
  CPATH=/opt/homebrew/opt/libpq/include
FRWHOOP_TEST_DB_URL="$PIPELINE_TEST_DATABASE_URL" swift test        # includes ContextLaneDatabaseTests (V15–V17)
supabase/tests/e2e/pipeline_db.sh down
```

`supabase db reset` fails on this chain (BACKEND.md); use `pipeline_db.sh` or `supabase/tests/e2e/ordered_migrations.sh`
with `psql -1`.

## 3. Activation order (requires explicit authorization; not done)

1. **Migration.** By hand, never `supabase db push` (AGENTS.md, BACKEND.md):
   ```bash
   psql "$DB_URL" -v ON_ERROR_STOP=1 -1 -f supabase/migrations/20261006050000_physiology_context.sql
   supabase migration repair --status applied 20261006050000
   ```
   Then run `supabase/tests/client-privileges.sql` read-only against the target and confirm the only failure is the
   pre-existing `compute_family_policy` item, and that every new function is service-role only (the ten new RPCs are in
   `SERVICE_ONLY_FUNCTIONS` of `auth_isolation_sql_test.ts`).
2. **Edge function.** Deploy `scores`. Before step 1 the new routes would fail (RPC missing); existing routes are
   unaffected either way.
3. **Worker build.** Deploy the worker per `deploy/README.md` with the lane still off (`FRWHOOP_CONTEXT_ENABLED`
   unset). Confirm the heartbeat lists `context` with `enabled: false` and the queue-age query unchanged.
4. **Lane on, small.** Set `FRWHOOP_CONTEXT_ENABLED=1`, `FRWHOOP_CONTEXT_BUDGET=1`. Watch the heartbeat `context` lane
   counters: `published`, `unchanged`, `failed`, `documents_too_large`, `build_ms_max`, `doc_bytes_max`,
   `context_tables_missing`, and `scoring` lane latency (it must not move). The enqueue creates jobs only for days with
   their own completed scoring in the last 120 days (causal today first, then retrospective days oldest first).
5. **Backfill.** Happens through the enqueue as scoring days complete; to force a span:
   `select public.invalidate_physiology_context_span_v1(<user>, null, <from>, <to>, 'backfill');` (≤ 120 days,
   service role).
6. **App.** Ship the build; the card appears once a context exists for the selected day.

## 4. Configuration

| Key | Default | Meaning |
| --- | --- | --- |
| `FRWHOOP_CONTEXT_ENABLED` | off | Exactly `1` turns the lane on |
| `FRWHOOP_DISABLE_LANES` | — | `context` in the list turns it off even when enabled |
| `FRWHOOP_CONTEXT_BUDGET` | 2 | Jobs per wake |
| `FRWHOOP_CONTEXT_LEASE_SECONDS` | 300 | Lease length (RPC allows 1–3600) |
| `FRWHOOP_CONTEXT_ENQUEUE_INTERVAL_SECONDS` | 120 | Seconds between enqueue scans |

`deploy/worker.env.example` lists them commented out. Policy tunables are compiled into `PhysiologyContext.Policy`;
they are not environment-configurable.

## 5. Reprocessing

- **Data changes** reprocess automatically: scoring completions (fingerprint over D−1..D+1), decoder day documents
  (trigger on `activity_context_days`, the local days the UTC day overlaps), placement changes (trigger on
  `placement_intervals`, from the effective start through today), exposure revisions
  (`[min start − 24 h, max end + 72 h]`), and the `history_changed` cascade when a published retrospective day
  changes what later days read: daily values → D+1..min(today − 1, D+28) plus the newest retrospective day (whose
  90-day episode window may still reach D); sleep episodes only → D+1..D+14 (prior-night sleep); bouts only →
  D+1..D+3. Every job-touching path takes row locks in (user, device, day, mode) order.
- **Policy changes** do not: the dependency fingerprint does not include the worker's policy fingerprint. After
  deploying a worker whose `Policy.fingerprint` changed (any tunable, any system version), re-dirty history
  explicitly, newest window first and in budget-sized batches:
  ```sql
  select public.invalidate_physiology_context_span_v1(u.user_id, null, current_date - 120, current_date, 'policy_changed')
    from (select distinct user_id from public.physiology_context_jobs) u;
  ```
  Documents record `policy_fingerprint` and `versions`, so a mixed-policy history is detectable
  (`select policy_fingerprint, count(*) from physiology_context_days where superseded_by is null group by 1`).
  Frozen references are never rewritten by a policy change; a new regime or version registers a new one.
- **Regime keys of earlier builds.** Development builds before the worker review repairs stamped the device row's
  current family and firmware on every day; they are now unknown on every day (no effective-dated history exists).
  Every series' regime key therefore changed once, and the change detector reads a key change as a regime boundary.
  Production has no stored context, so nothing is needed there; any test database that ran an earlier build should
  be cleared or re-dirtied over its whole 120-day range (the query above) before its documents are compared.
- **Finality.** A retrospective document becomes `final` once its cutoff is ≥ day end + 30 h; the enqueue schedules
  that rebuild (`finality_due`), and the input fingerprint includes finality so the rebuild stores a new revision.

## 6. Compatibility

| Case | Behaviour |
| --- | --- |
| Old app, new server | Never calls the new routes; existing routes unchanged (route tests) |
| New app, old server | `/scores/context` answers 405 → the card shows "context unavailable", never a spinner or error banner (app tests) |
| Context missing for a day / pending job | Card shows "insufficient context" / "context updating"; the metric itself is shown as before |
| New metric revision, older context | Read pairs the context with the latest snapshot (`pairing.consistent`); the app shows "context updating" instead of pairing them silently |
| Context lane failing | Failures are counted and retried with backoff; scoring keeps publishing (DB test `testAFailingContextLaneDoesNotStopScoring`) |
| Context tables absent | Lane idles and reports `context_tables_missing` |
| Exposure uploads to an old server | 405 keeps revisions pending on the phone |
| Signed out / another account | Context reads and exposure uploads are owner-scoped; rows recorded before sign-in stay unclaimed until the local-data owner adopts them |

## 7. Rollback

1. Turn the lane off (`FRWHOOP_CONTEXT_ENABLED` unset or `context` in `FRWHOOP_DISABLE_LANES`) and restart the worker.
   No other lane is affected.
2. Redeploy the previous `scores` function: the new routes answer 405 and the app shows "context unavailable".
   Exposure revisions stay pending on phones and upload when the routes return.
3. The tables can stay (they are read by nothing else). Full removal, only with authorization because it deletes
   context products and exposure history: drop trigger `physiology_context_placement_changed` on
   `placement_intervals`, the ten public `*_physiology_context_*` / `*exposure_event*` functions, the
   `internal.physiology_context_*` and `internal.exposure_*` helpers, and the nine tables
   (`physiology_context_jobs`, `_days`, `_envelope_tables`, `_daily_values`, `_bouts`, `_episodes`,
   `_frozen_references`, `exposure_event_revisions`, `exposure_events`).

## 8. Separate production activation requirements

Merging this branch does not authorize any of these; each needs its own explicit go-ahead:

1. Apply the migration to production (step 3.1) and deploy the `scores` function.
2. Enable the worker lane and choose a budget after observing the worker's real load (development profile: a fully
   observed day builds in ~1 s release and stores 2.7–3.9 MB before TOAST compression; see validation.md §6).
3. Storage budget review: current-only retention plus one superseded row for 24 h; at ~1–4 MB per device-day
   before compression the yearly footprint per device is material.
4. Privacy review of exposure data (medication names, doses, symptoms are sensitive health data) and of retention.
5. Product/clinical review of every user-facing string; the copy states measurement conditions only.
6. Real-data calibration of the change detector and eligibility selection (methods.md §14 open hypotheses) before any
   episode is surfaced as more than an inspectable summary. No alerting or notification is part of this work.
7. Any disease-specific interpretation requires validation in its intended population (FDA DHT guidance, research
   note 15); nothing here is accuracy- or clinically-validated (validation.md readiness table).
