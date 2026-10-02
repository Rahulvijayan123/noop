# Backend runbook

The Nara backend has three parts:

- **Supabase** hosts Postgres and the edge functions the app talks to (`supabase/`).
- **The VPS worker** (`frwhoop-worker`, from `Tools/CloudWorker`) computes scores. It runs as a
  systemd service on one DigitalOcean droplet.
- **Backblaze B2** stores uploaded objects and archived score snapshots.

[ARCHITECTURE.md](ARCHITECTURE.md) explains how data moves between them. This page covers deploying
and checking each part.

## Supabase

### Layout

| Path | Contents |
| --- | --- |
| `supabase/functions/` | Edge functions (Deno/TypeScript). Shared code is in `_shared/`. |
| `supabase/migrations/` | The schema, as ordered SQL migrations. This is the canonical lineage. |
| `supabase/history/` | Archived SQL from before the current lineage. Never apply it. |
| `supabase/tests/` | SQL and shell tests for enrollment and history. |
| `supabase/config.toml` | Local stack and per-function settings. |

### Edge functions

| Function | Called by | Purpose |
| --- | --- | --- |
| `push` | the app | Receives upload batches and object-lane uploads, writes rows and receipts. |
| `scores` | the app | Returns published score snapshots and the changed-days feed. Also handles enrollment-time device registration and sleep edits. |
| `coach` | the app | Relays Coach questions to the language model and stores the conversation, the coach's memory and the Settings profile (`/profile`). Authenticates like `push` (installation bearer plus the fleet token). |
| `ingest-verify` | operators | Checks the ingest pipeline end to end. |
| `reconcile` | scheduled | Reconciles the object manifest against storage. |
| `retention-sweep` | scheduled (pg_cron) | Deletes expired objects and manifests. |
| `account-deletion` | scheduled or on demand | Deletes an account: B2 objects, then rows, then the Auth user. |

Every function has `verify_jwt = false` in `config.toml` because each one does its own bearer
authentication. The app's ingest tokens are not JWTs, so gateway verification would reject them.
The scheduled functions authenticate with the `WORKER_SECRET` function secret.

Deploy a function after linking the project once:

```bash
supabase link --project-ref <project-ref>
supabase functions deploy scores
supabase secrets set WORKER_SECRET=<value>   # only when rotating it
```

### Coach

The `coach` function holds the model key, so the app never does. It needs one function secret:

```bash
supabase secrets set FIREWORKS_AI_API_KEY=<value>
```

Optional overrides are read by `coachConfig()` in `supabase/functions/_shared/coach.ts` (the upstream
URL, the model names and the daily call limit per user). Each request is counted in `coach_usage`
through the `coach_take_quota` function, and the conversation and memory live in `coach_sessions`,
`coach_messages`, `coach_memories` and `coach_memory_items`. All five are created by
`supabase/migrations/20260930235900_coach_harness.sql`, and deleting an account removes them.

#### Profile

`GET` and `PUT /functions/v1/coach/profile` read and write the owner's row in `profiles`: name
(`display_name`), date of birth, sex (`sex_model`: `male`, `female` or `nonbinary`), height and weight.
It is the same row the scoring worker reads for age, sex and body size, and a trigger re-queues scoring
only when one of those values actually changes. Values are range-checked in `profileInput()`, and a
`PUT` writes only the keys it carries. The app uploads a couple of seconds after an edit and adopts the
stored profile when it becomes active (`Strand/Data/ProfileCloudSync.swift`), in cloud mode only.
No migration is involved: the table and its deletion handling already existed.

The function tests run with Deno from `supabase/functions/`. Some of them need fixtures that are not
in this repository, such as `EDGE_TEST_ARTIFACTS` or the old `infra/vps` scripts.

### Migrations

> **Do not run `supabase db push` against production.** The production migration history
> (`supabase_migrations.schema_migrations`) only records versions up to `20260921104000`. The 39
> later migrations in `supabase/migrations/` were applied directly with SQL, so `db push` would try
> to run them all again.

To apply a new migration to production:

1. Add it to `supabase/migrations/` with a timestamp later than the newest file.
2. Run it in a transaction with `psql`, using the session pooler URL:
   `psql "$DB_URL" -v ON_ERROR_STOP=1 -1 -f supabase/migrations/<file>.sql`
3. Record it so the history stops drifting further:
   `supabase migration repair --status applied <version>`

For local development, `supabase db start` followed by `supabase db reset --yes` builds a fresh
database from the migrations.

## The VPS worker

[deploy/README.md](../deploy/README.md) covers provisioning, building and releasing the worker.
[deploy/OPERATIONS.md](../deploy/OPERATIONS.md) lists the queues each lane drains. In short:

```bash
ssh root@<worker-host>
systemctl status frwhoop-worker
journalctl -u frwhoop-worker -f
```

### Production configuration

Secrets live in `/etc/frwhoop/worker.env` on the host (template: `deploy/worker.env.example`).

The projection lane is turned off in production with a systemd drop-in:

```ini
# /etc/systemd/system/frwhoop-worker.service.d/no-projection-replay.conf
[Service]
Environment=FRWHOOP_DISABLE_LANES=projection
```

Rows from the app are committed by the `push` function as they arrive, so the projection lane only
replays old stored objects. Its queue holds about 16,000 stale rows from other test devices that
fail on every attempt, and each attempt holds the owner lock that live uploads need. Scoring,
archive and verify stay on.

After changing a drop-in, run `systemctl daemon-reload && systemctl restart frwhoop-worker`.

## Activity context (shadow, off by default)

Raw IMU classification (spec: activity context) runs as a separate worker lane. It is OFF by
default: the lane starts only with `FRWHOOP_ACTIVITY_ENABLED=1` in `/etc/frwhoop/worker.env` and
`activity` not in `FRWHOOP_DISABLE_LANES`.

Objects and queues:

```text
phone raw capture (ImuSessionFileStore) -> rawImuSession NPB1 objects (object lane, verified)
  -> object_manifests status 'ready' -> trigger enqueues activity_context_jobs (per UTC day)
  -> activity lane: claim (lease) -> download + digest-verify + decode -> contiguous runs
  -> persistent Python process (Tools/ActivityContext, HART) -> 4-s window predictions
  -> shared ActivityContextPolicy (same code as the app) -> 30-s epochs
  -> publish_activity_context_v2 (fenced) -> activity_context_epochs
  -> scoring_dirty_span -> next scoring pass attaches daily.activity_context -> snapshot -> app
```

- The Python child is a persistent `stdin/stdout` JSON process (no per-window launches, no HTTP
  endpoint, no GPU). Model loading and inference happen outside Postgres transactions; the lane
  renews its lease around each run's inference. A missing model fails soft (`model_unavailable`),
  never blocks BLE, ingest, scoring, sleep, recovery or archive.
- Deployment needs the migration `20261003120000_activity_context.sql` applied with `psql`
  (never `supabase db push`; see Migrations), the `Tools/ActivityContext` tree plus a Python 3.10
  venv on the host (`uv venv && uv pip install -r Tools/ActivityContext/requirements` style pins in
  the package README), and the trained model artifacts copied to `FRWHOOP_ACTIVITY_MODEL_DIR`
  (fetch/build commands in the package README; nothing is committed to git).
- Rollback: set `FRWHOOP_ACTIVITY_ENABLED` off (or add `activity` to `FRWHOOP_DISABLE_LANES`) and
  restart the worker. The tables keep their rows; snapshots simply stop carrying
  `activity_context` after the next scoring pass, and old clients are unaffected either way. The
  migration is additive (new tables + functions only), so reverting it is not required for rollback.
- Promotion is evidence-gated, not config-gated: the held-out WISDM-19 watch result (macro-F1 0.66,
  coverage 0.66) does NOT meet the product targets (0.85 macro-F1, 0.90 walking/running precision),
  so automatic labels stay in shadow mode until a WHOOP-labeled pilot passes those gates. Posture
  and new activities have separate gates. The `RestingEligibility` policy is exported but rejects by
  default (wear/sleep evidence is unknown in v1), so no physiological baseline behavior changed.

## Health checks

Run these with `psql` against the database. All four are read-only.

```sql
-- Is the worker alive? since_poll should be under about 15 seconds.
select id, version, now() - last_poll_at as since_poll, now() - last_score_at as since_score, last_error
from scoring_service_heartbeats order by last_poll_at desc limit 3;

-- Are uploads arriving?
select count(*) as receipts_last_hour, max(accepted_at) as latest
from noop_upload_receipts where accepted_at > now() - interval '1 hour';

-- How many days are waiting to be scored?
select count(*) filter (where completed_revision is distinct from input_revision and not dead_letter) as pending,
       count(*) filter (where dead_letter) as dead_lettered
from scoring_jobs_v2;

-- What was published most recently?
select day, device_id, computed_at from scoring_snapshots_v2 order by computed_at desc limit 5;
```

For upload errors, check the `push` function's logs in the Supabase dashboard, or query
`function_edge_logs` for responses with status 500.

## Known issues

- **Lock-order conflict between uploads and scoring.** The worker's scoring transaction locks the
  job row first and then takes a shared advisory lock on the user's inputs. An upload takes the
  exclusive advisory lock first and then updates the job row. When both happen at once for the same
  user, Postgres reports a deadlock and one side retries. Migration `20260930231500` stops the worker
  from re-claiming a day within two minutes of its last claim, which cut upload failures from about
  15% to about 2%. The full fix is to make the worker take the advisory lock before claiming the row.
- **Old projection debt.** About 16,000 `noop_projection_debt` rows from 12–20 September, from other
  test devices, fail replay and are left unprocessed while the projection lane is off. Clearing or
  dead-lettering them would let the lane run again.
- **Verify lane mismatches.** The verify lane logs digest mismatches for some older objects.
- **One other device fails a check constraint** on upload. It is not this app's install.
- **Recovery** stays at "Calibrating" until a device has four nights of data.
- **Blood oxygen** stays empty because the synced strap history contains no SpO₂ samples.
