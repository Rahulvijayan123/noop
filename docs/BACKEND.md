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
