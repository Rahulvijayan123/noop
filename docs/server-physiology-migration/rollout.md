# Rollout — operator instructions

**Nothing in this branch deploys anything or changes a live default.** Every metric ships
`mode='off'`, the Swift worker's candidate lane is off while `FRWHOOP_INFERENCE_URL` is unset, and
the sidecar service is installed but disabled. The commands below are operator instructions for a
later, deliberate rollout. They were **not executed** against any host or database.

Reference evidence: `findings/deployment-do.md` §b, `findings/impl-supabase.md` §2-§4a,
`findings/impl-swift-client.md` §6, `docs/BACKEND.md` ("Migrations"), `deploy/README.md`,
`deploy/OPERATIONS.md`, `deploy/provision.sh`, `deploy/frwhoop-inference.service`,
`deploy/inference.env.example`, `deploy/worker.env.example`.

Prerequisites that are NOT verified anywhere in this branch (see discovery report §6): the sidecar
port is free, the firewall state, free disk space for the venv + artifacts, and the real
`FRWHOOP_*` values.

---

## (a) Deploy-prep on the Droplet

Run as root on the worker Droplet. Step 1 is idempotent and additive: the sidecar section of
`provision.sh` appends after the existing Swift/SQLite steps and changes none of them
(`findings/review-swift-client.md` requirement 8: 0 removed lines, prefix byte-identical).

```bash
# 1. Provision the sidecar (pinned uv, venv, artifact cache, unit).
#    FRWHOOP_UV_SHA256 is MANDATORY: the script exits 1 without it (fail closed).
FRWHOOP_UV_SHA256=<published sha256 of uv-x86_64-unknown-linux-gnu.tar.gz> \
  sudo deploy/provision.sh
```

What that section does (`deploy/provision.sh`, sidecar section; `deploy/README.md`):

| Step | Effect |
| --- | --- |
| Packages | `python3`, `ca-certificates` |
| User + dirs | `frwhoop-inf` (system user), `/var/lib/frwhoop-inf`, `/opt/frwhoop-inference`, `/opt/frwhoop-models` |
| Pinned uv | `FRWHOOP_UV_VERSION` (default `0.9.5`) fetched once, `sha256sum --check`ed, installed to `/opt/uv/<version>/uv`; symlinked to `/usr/local/bin/uv` |
| Venv | `UV_PYTHON_DOWNLOADS=never uv sync --frozen --project <repo>/Tools/InferenceWorker`; `/opt/frwhoop-inference/venv` is a symlink to that `.venv`; refuses to continue if the venv interpreter is missing |
| Artifact cache | Reads the pinned manifest, downloads only fetchable entries, `sha256sum --check`es each, installs into `/opt/frwhoop-models/revisions/<sha256(manifest)[:12]>/`, then atomically switches `/opt/frwhoop-models/current`. Entries marked `blocked_license` / `blocked_artifact` / `blocked_input` are **never** fetched |
| Unit | `install -m 644 deploy/frwhoop-inference.service /etc/systemd/system/`, `systemd-analyze verify`, `systemctl daemon-reload` |

Overridable env names in that section: `FRWHOOP_SIDECAR_ROOT`, `FRWHOOP_MODELS_ROOT`,
`FRWHOOP_UV_VERSION`, `FRWHOOP_UV_SHA256`, `FRWHOOP_MODEL_MANIFEST`.

```bash
# 2. Install the sidecar config (names-only template).
sudo install -m 0600 -o root -g root deploy/inference.env.example /etc/frwhoop/inference.env
#    then edit it. The names the sidecar actually reads are:
#      FRWHOOP_MANIFEST=/opt/frwhoop-models/current/manifest.json
#      FRWHOOP_MODEL_ROOT=/opt/frwhoop-models/current
#      FRWHOOP_REQUEST_TIMEOUT_MS=20000

# 3. Confirm the loopback port is free BEFORE starting (127.0.0.1 only).
ss -ltnp | grep 8787        # expect no match; must never show 0.0.0.0

# 4. Start and verify readiness.
sudo systemctl enable --now frwhoop-inference
systemctl status frwhoop-inference
curl -s http://127.0.0.1:8787/healthz | head
curl -s http://127.0.0.1:8787/v1/providers | head

# 5. Resource/leak checks.
ss -ltnp | grep 8787                                    # 127.0.0.1, never 0.0.0.0
systemctl show frwhoop-inference -p MemoryCurrent -p MemoryPeak
journalctl -u frwhoop-inference -f
```

Readiness rules (findings/impl-inference-hrv.md §2c, §4; findings/impl-sleep-providers.md §3.2;
`Tools/InferenceWorker/src/frwhoop_inference/server.py` readiness block): the sidecar verifies each
artifact's sha256 once at startup and reports
`ready=false` with a reason when one is missing or mismatched; it never downloads at inference
time. Per-provider readiness is what gates `POST /v1/infer` (a not-ready provider is 503'd on its
own metric); the process-level `ready` flag is the supervisor/health view. `sleepecg`'s two
artifacts are `required_for_readiness=true`, so a missing `wrn-gru-mesa.zip` makes that provider
not-ready.

```bash
# 6. Only now enable the client side, and keep the URL commented out until the sidecar is ready.
sudoedit /etc/frwhoop/worker.env
#   FRWHOOP_INFERENCE_URL=http://127.0.0.1:8787
#   FRWHOOP_INFERENCE_TIMEOUT_MS=25000     # must be ABOVE the sidecar's own budget
#   FRWHOOP_INFERENCE_BUDGET=2
sudo systemctl restart frwhoop-worker
```

The URL must be loopback: a non-loopback host is refused at startup and the lane stays off (the
refusal is reported in the heartbeat). Leaving the URL unset keeps the candidate lane completely
off and the canonical scoring path byte-identical to pre-migration behaviour
(`findings/impl-swift-client.md` §4.2).

---

## (b) Apply the migration

Per `docs/BACKEND.md` ("Migrations"). **Never run `supabase db push` against production**: the
recorded history only goes up to `20260921104000`, so `db push` would try to re-run 39 later
migrations.

```bash
# 1. Apply the new migration in ONE transaction with ON_ERROR_STOP.
psql "$DB_URL" -v ON_ERROR_STOP=1 -1 \
  -f supabase/migrations/20261002090000_physiology_candidate_providers.sql

# 2. Record it so the history stops drifting.
supabase migration repair --status applied 20261002090000
```

Notes and expectations:

* The migration is additive: 5 new tables (RLS enabled, zero policies, `service_role` only), 7 new
  functions, 4 dormant seed rows, and a third trigger family over 13 stream tables
  (findings/impl-supabase.md §2.3, §3.1, §3.2, §5.8).
* Re-applying it is a no-op for operator state (verified by the suite and independently reproduced:
  modes and provider ids unchanged, still 4 rows, still 0 policies)
  (findings/impl-supabase.md §2.1 step 16; findings/review-supabase.md R2-9).
* Apply order in a plain PostgreSQL is a known repository defect (findings/impl-supabase.md §2.2,
  §7.3): applying the whole lineage in filename order yields **130 of 151** (missing `realtime` schema, `pg_cron`/`pg_net` unavailable in
  Homebrew PG18, and `object_manifests.durability_receipt` used before the later file adds it). The
  migration's own test uses a documented 12-file prerequisite subset. Do not use the local
  filename-order result as a production prediction.
* Verify the post-state:

```bash
psql "$DB_URL" -c "select metric, provider_id, provider_version, config_version, mode
                   from public.physiology_provider_defaults order by metric;"
psql "$DB_URL" -c "select count(*) from pg_policies
                   where schemaname='public'
                     and tablename like 'physiology_%';"   -- 0 for the 5 new tables
```

---

## (c) Enabling shadow, per metric

Modes are per metric and must not all move together. The provider triple in the selection row is
the authority: the worker echoes the SELECTED triple into the record RPC, and the RPC refuses a row
whose triple differs from the current selection. Take the exact strings from the sidecar's own
capability manifest:

```bash
curl -s http://127.0.0.1:8787/v1/providers   # per provider: metric, provider_id, versions{adapter,preprocessing,dependency,config,model}
```

Fleet default for one metric (repeat per metric, one at a time):

```sql
-- HRV shadow (both HRV providers share the metric; production.runs.v1 is the authoritative one).
update public.physiology_provider_defaults
   set provider_id      = 'production.runs.v1',
       provider_version = '<provider_version from /v1/providers>',
       config_version   = '<config from /v1/providers>',
       mode             = 'shadow',
       updated_at       = now()
 where metric = 'hrv';

-- Sleep boundaries (HypnosPy HR boundary algorithm).
update public.physiology_provider_defaults
   set provider_id      = 'hypnospy.hr-boundary.v1',
       provider_version = 'hypnospy.hr-boundary.v1/1.0.0',
       config_version   = 'hypnospy-hr-defaults/1.0.0',
       mode             = 'shadow',
       updated_at       = now()
 where metric = 'sleep_boundary';

-- Beat-based staging (SleepECG wrn-gru-mesa). Requires the sleepecg artifact to be present and
-- verified: its two artifacts are required_for_readiness=true, so a missing zip makes the provider
-- not-ready and POST /v1/infer returns 503 for this metric.
update public.physiology_provider_defaults
   set provider_id      = 'sleepecg.wrn-gru-mesa.v1',
       provider_version = 'sleepecg.wrn-gru-mesa.v1/1.0.0',
       config_version   = 'sleepecg-wrn-gru-mesa-defaults/1.0.0',
       mode             = 'shadow',
       updated_at       = now()
 where metric = 'sleep_stage';
```

The three strings for each metric must match the sidecar's registered provider id and the versions
it reports in `/v1/providers`; the worker echoes the SELECTED triple into the record RPC, and the
RPC drops a row whose triple differs from the current selection.

Per-user override (beats the fleet default for that owner only):

```sql
insert into public.physiology_provider_overrides
  (user_id, metric, provider_id, provider_version, config_version, mode, updated_at)
values
  ('<user uuid>', 'hrv', 'production.runs.v1', '<provider_version>', '<config_version>', 'shadow', now())
on conflict (user_id, metric) do update
  set provider_id = excluded.provider_id,
      provider_version = excluded.provider_version,
      config_version = excluded.config_version,
      mode = excluded.mode,
      updated_at = now();
```

Verify what the worker will actually see (the EFFECTIVE mode after the promotion gate):

```sql
-- Effective selection for one owner and metric.
select public.physiology_selected_provider('<user uuid>', 'hrv');
--  -> {"provider_id","provider_version","config_version","mode","source"}
--     source in user_override | default | unset | user_override_demoted_unapproved | default_demoted_unapproved

-- The gate decision, for explaining a refused write.
select public.physiology_candidate_activation('<user uuid>', 'hrv');
--  -> {"provider_id","provider_version","config_version","requested_mode","mode","source",
--      "demoted", "feature", "approval":{approved,reason,approval_id,preprocessing_version,quality_policy_version}}

-- Metric -> signed-promotion feature map.
select metric, public.physiology_candidate_feature(metric)
  from unnest(array['hrv','sleep_boundary','sleep_stage','respiration']) as metric;
--  hrv->hrv, sleep_boundary->sleep, sleep_stage->sleep, respiration->respiration
```

Turn it back off the same way (`set mode='off'`); `off` is never gated.

---

## (d) Watching shadow results

```sql
-- Recent candidate rows for one owner.
select metric, period_day, provider_id, provider_version, status, withheld_reason,
       value, unit, label_space, runtime_ms, created_at
  from public.physiology_candidate_results
 where user_id = '<user uuid>'
 order by created_at desc
 limit 50;

-- Withheld-reason mix per metric (a provider that withholds everything is visible immediately).
select metric, provider_id, status, coalesce(withheld_reason,'-') as reason, count(*)
  from public.physiology_candidate_results
 where created_at > now() - interval '24 hours'
 group by 1,2,3,4
 order by 5 desc;

-- Paired comparison helper: candidate value vs the canonical daily HRV for the same day.
select c.period_day, c.provider_id, c.status, c.value as candidate_rmssd
  from public.physiology_candidate_results c
 where c.user_id = '<user uuid>' and c.metric = 'hrv'
 order by c.period_day desc
 limit 30;
-- (The canonical value comes from the existing scoring read path — scoring_snapshots_v2 /
--  server_metric_series — not from this table.)

-- Staleness debt (newer input arrived than the claim a candidate was written from).
select public.physiology_candidate_debt_read('<user uuid>', '<device id>', current_date - 1);
--  -> {"debt":bool,"invalidated_at":timestamptz|null}
select user_id, device_id, day, invalidated_at
  from public.physiology_candidate_debt
 order by invalidated_at desc limit 20;

-- Duplicate/replay behaviour is visible as "no new row": the unique key is
-- (user_id, device_id, metric, period_day, interval_start_at, input_sha256, provider_id,
--  provider_version, config_version) and the write is ON CONFLICT DO NOTHING.
```

Worker-side counters and readiness arrive in the EXISTING heartbeat row:

```bash
psql "$DB_URL" -c "select meta->'inference' from scoring_service_heartbeats where id = 1;"
psql "$DB_URL" -c "select meta->'lanes' from scoring_service_heartbeats where id = 1;"
journalctl -u frwhoop-worker -f
```

Failure mapping to watch for (`deploy/OPERATIONS.md`): refused/unreachable → `provider_error`
(retried once, max 2 attempts); deadline → `timeout` (retried once); HTTP 503 → `not_ready`
(retried once); any other non-200 or an undecodable body → `provider_error` (not retried). Skips
are counted as `skipped_stale_debt`, `skipped_deleted_user`, `skipped_no_input`, `skipped_budget`
and `skipped_off`.

Do not expect any change in canonical values or app reads while a metric is in `shadow`: candidate
rows are isolated, and no read route exposes them (findings/impl-supabase.md §8).

---

## (e) Bounded backfill

The backfill only enqueues the EXISTING canonical recompute (`enqueue_scoring_v2`) and, in
`rollback`, fences in-flight candidate writes. It never rewrites raw objects and never changes a
selection row.

Create a job (dry-run first, always):

```sql
-- DRY RUN: writes nothing. processed_days stays 0; the scanned day set lands in progress.scannedDays.
insert into public.physiology_backfill_jobs
  (mode, metric, from_provider_id, from_provider_version,
   to_provider_id, to_provider_version,
   scope_user, scope_device, scope_from_day, scope_through_day, max_users)
values
  ('dry_run', 'hrv', 'none', 'none',
   'production.runs.v1', '<provider_version>',
   '<user uuid>'::uuid,            -- or NULL for all owners in range
   '<device id>',                  -- or NULL for every device of the owner
   date '2026-09-01', date '2026-09-30',
   1)                              -- max_users: distinct users one advance call may process (1..1000)
returning job_id;
```

Run it in bounded steps (each call is bounded by `p_max_days` AND by `max_users`):

```sql
-- Claim with a bounded lease (1..3600 s; the claim stores the length it granted).
select * from public.physiology_backfill_claim(300, 'operator-1');
--  -> at most one job row; sets state='running', lease_token, lease_owner, lease_until, attempts+1

-- Advance at most 3 (user, day) pairs, one day at a time, resuming from (cursor_user, cursor_day).
select public.physiology_backfill_advance('<job uuid>'::uuid, '<lease token>'::uuid, 3);
--  -> {jobId,mode,state,scanned,enqueued,cursorUser,cursorDay,done}
--     state='complete' and the lease cleared when the cursor is exhausted (and not capped)

-- Finish (only these states are accepted): complete | failed | cancelled | paused.
select public.physiology_backfill_finish('<job uuid>'::uuid, '<lease token>'::uuid, 'complete');
--  -> true when the live lease matched; false otherwise
```

Lease semantics and bounds (findings/impl-supabase.md §3.2, §4; verified by the Deno suite and
independently reproduced by findings/review-supabase.md R2-4, R2-7, R2-8):

* `physiology_backfill_claim(p_lease_seconds, p_lease_owner)` returns at most one runnable job
  (`state in ('pending','running')`, lease free, `max_users` enforceable) with `for update skip
  locked`. A lease outside 1..3600 s raises `invalid_lease` (SQLSTATE 22023).
* `advance` requires the live lease: a wrong token or an expired lease raises
  `backfill_lease_lost` (55006); a non-running job raises `backfill_not_running` (55000);
  `p_max_days` outside 1..400 raises `invalid_backfill_bound` (22023).
* `advance` renews with the length the claim granted (not a hardcoded 900 s), and stops with
  `done=false` when the `max_users` cap is hit.
* `dry_run` never enqueues, never bumps the canonical revision and writes no debt — its
  `processed_days` stays 0, which is the proof that nothing was written.
* `apply` enqueues the canonical recompute per device/day and bumps the revision.
* `rollback` enqueues the recompute AND upserts `physiology_candidate_debt` for the restored days,
  which fences in-flight candidate writes. It does not mutate any selection table.

Operator checklist before `apply`: a completed `dry_run` over the same range with the expected
`scannedDays`; a lease short enough to bound one call; and per-user/per-day limits set explicitly
rather than relying on defaults (findings/impl-supabase.md §5.11; findings/review-supabase.md
R2-7).

---

## (f) Promotion (`active`)

`active` is the only mode that can reach canonical publication, so it requires a **live signed
promotion approval**. The gate reads the repository's existing signed-promotion surface read-only
(`physiology_promotion_approvals`, `physiology_promotion_revocations`, `physiology_feature_manifests`,
`internal.physiology_approval_keys`, `internal.physiology_approval_valid`); none of it was changed.

How the gate behaves (findings/impl-supabase.md §4a; verified by the suite and independently
reproduced with a forged signature):

1. A signed approval is registered by the release process, service_role only:

```sql
select public.register_physiology_promotion('<signed payload text>', '<hmac-sha256 hex>');
-- raises 'signed reference approval required' (22023) when internal.physiology_approval_valid() is false
```

The payload must satisfy every condition in `internal.physiology_approval_valid`
(`supabase/migrations/20260918230000_physiology_signed_promotion.sql`, the
`internal.physiology_approval_valid` definition; findings/impl-supabase.md §4a), including
`schema_version='1'`, `purpose='physiology_feature_promotion'`, the matching `approval_id`/`key_id`/
`reviewer`, `decision='approved'`, `algorithm_version` (= the provider version), `feature`, the
manifest/checkpoint/preprocessing/quality-policy hashes, 64-hex `evaluation_sha256` /
`policy_sha256` / `reference_artifact_sha256`, a `reference_kind` appropriate to the feature
(`hrv`→`synchronized_ecg_nn`, `sleep`→`psg_30s_and_sleep_opportunities`,
`respiration`→`synchronized_respiratory_reference`), `evaluation_partition in ('test','external')`,
`participant_disjoint`, `functional_gates_passed`, `promotion_policy_passed`, the frozen-policy
ordering (`policy_frozen_at < evaluation_started_at <= evaluation_finished_at <= approved_at <=
now()`), and no revocation row.

2. Then, and only then, flip the mode:

```sql
update public.physiology_provider_defaults
   set mode = 'active', updated_at = now()
 where metric = 'hrv';

-- Confirm it is NOT demoted:
select public.physiology_candidate_activation('<user uuid>', 'hrv');
--  expect mode='active', demoted=false, approval.approved=true, approval.reason=null
```

3. **Flipping `mode='active'` without a live approval does not enable anything.** The gate demotes
   and refuses writes:
   * `physiology_selected_provider()` returns `mode='shadow'` with
     `source='default_demoted_unapproved'` (or `user_override_demoted_unapproved`), so a worker that
     only reads the selection can never treat an unapproved provider as active.
   * `physiology_record_candidate_result()` uses the **requested** mode, so a caller that still
     claims `active` is refused outright (returns NULL, no row) rather than being silently
     downgraded into a shadow row. `physiology_candidate_activation()` explains it with
     `promotion_approval_required`.
   * If the signed-promotion objects are absent (partial lineage), the gate fails closed with
     `promotion_gate_unavailable` instead of erroring.
   * Revocation, a future `approved_at`, or a revoked signing key each demote again — all three
     paths are exercised against the real machinery, each with a positive control.

Two limits to record: the existing approval table is fleet-wide and has no `provider_id` /
`config_version` column, so those are surfaced in the activation payload for the worker to compare
rather than enforced; and there is no expiry column, so "expired" is covered by the future-dated
case plus revocation.

---

## (g) Rollback

Rollback is layered. Do the cheapest layer that fixes the problem.

```bash
# Layer 1 — turn the candidate lane off at the worker, without touching the sidecar or the DB.
sudoedit /etc/frwhoop/worker.env      # comment out FRWHOOP_INFERENCE_URL
sudo systemctl restart frwhoop-worker
# Scoring returns to the legacy path exactly: no sidecar call, no candidate SQL, no extra transaction.

# Layer 2 — stop the sidecar.
sudo systemctl disable --now frwhoop-inference
# The worker keeps running; candidates settle as withheld 'provider_error'.

# Layer 3 — roll the model cache back by repointing the atomic symlink.
ls -l /opt/frwhoop-models/            # list revisions/<manifest-sha256-12>
sudo ln -sfn /opt/frwhoop-models/revisions/<previous> /opt/frwhoop-models/current
sudo systemctl restart frwhoop-inference
```

```sql
-- Layer 4 — set the affected metric back to off (per metric, never all at once).
update public.physiology_provider_defaults
   set mode = 'off', updated_at = now()
 where metric = 'hrv';
-- and/or drop the per-user override:
delete from public.physiology_provider_overrides where user_id = '<user uuid>' and metric = 'hrv';
```

**What does and does not need historical restoration.** While every metric was never `active`, no
canonical value was ever produced by a candidate: candidate rows live only in
`physiology_candidate_results`, which no read route exposes, and the canonical publisher never read
them. So there is nothing to restore on the canonical side, no baseline to reproject, and no cache
to invalidate — layers 1-4 are sufficient. The historical-restoration path matters only for a
metric that actually reached `active`; in that case the operator must, in addition:

```sql
-- 1. Flip the metric back to off (above).
-- 2. Restore the days the provider promoted, with the rollback backfill (dry_run first):
insert into public.physiology_backfill_jobs
  (mode, metric, from_provider_id, from_provider_version,
   to_provider_id, to_provider_version, scope_from_day, scope_through_day, max_users)
values ('dry_run', 'hrv', '<active provider id>', '<active provider version>',
        'production.runs.v1', '<legacy provider version>', date '...', date '...', 1)
returning job_id;
-- then claim/advance/finish as in section (e).
```

**The tested rollback fence.** `mode='rollback'` in a backfill job both enqueues the canonical
recompute and upserts `physiology_candidate_debt` for the restored days, so an in-flight candidate
write for those days is refused (the worker skips a write whose claim is older than
`invalidated_at`, and the RPC's `p_input_revision` guard is the authoritative fence). This is
covered by the Deno suite (step 12: "backfill `rollback` enqueues the recompute **and** upserts
candidate debt, so in-flight candidate writes are fenced") and reproduced independently.

Rollback is not complete by changing a flag alone **for a metric that was active**: the promoted
days and their dependent baselines must be recomputed with the legacy method in the same pass
(spec §7). For this branch, where nothing ever became active, the flag change is complete.

---

## (h) What is deliberately absent from this branch

* No production deploy, no `mode` other than `off`, no `active` provider, no live default change
  (findings/impl-supabase.md §3.1 seed block; parent decision D5).
* No model weights in the repo; artifacts are pinned by manifest and staged at deploy-prep only.
* No new public port: the sidecar binds `127.0.0.1` only, so no Cloud Firewall rule and no `ufw`
  rule are required (findings/deployment-do.md §0.2, §b5). Confirming the host firewall state is
  still an operator task, and it cannot be done from this repository
  (findings/deployment-do.md §e.1).


## Audit addendum (2026-10-02, tied to HEAD f813a687 and the repair round after it)

Known, accepted properties recorded by the final audit:

- **Candidate lane is at-most-once per revision.** The candidate write happens after the
  canonical snapshot commits; a crash between the two loses that candidate for that
  revision, and only new input re-enqueues it (the pre-existing invalidation family, not
  the candidate-debt trigger). This is accepted for shadow evaluation; it is not a
  durability guarantee.
- **The candidate-debt trigger is advisory.** The authoritative staleness fence is the
  `p_input_revision` guard inside `physiology_record_candidate_result`; the debt rows are
  an operator hint (`physiology_candidate_debt_read`).
- **Day-cursor scope revision.** The iOS day cursor's `scope_revision` does not include the
  new selection tables (`result_day_pagination.sql:63-71`). Bounded: republishes bump the
  per-day `change_revision`, so promoted days re-walk anyway. Wire the selection state into
  the scope revision when the active republish path is enabled.
- **Shadow HRV config is the shipped engine's config.** 20 clean intervals per 5-minute
  window, plain mean over windows — the spec's stricter 30/20%/3-window/median numbers do
  not match the shipped code (20 beats, plain mean; see the discovery report's
  discrepancies section). The candidate is faithful to the shipped engine; the stricter
  gates are a promotion-time decision, predeclared before any benchmarking.
- **Worker-side metric coverage.** The candidate lane sends `hrv` requests; the repair round
  extends the worker to assemble and send `sleep_boundary` and `sleep_stage` inputs when
  their modes are not `off`. Until then, flipping a sleep metric to `shadow` produces no
  candidate rows without a backfill or worker update.

- **Deploy the sidecar package before or with the worker.** The worker's candidate payloads
  carry the top-level `aggregation` field and mapped `gender` values that the repaired
  sidecar parser accepts; an older sidecar build rejects them with `invalid_input`. Ship
  `Tools/InferenceWorker` (sidecar) first, then the worker; both live in this branch, so a
  normal branch rollout applies them together. A worker-only update against an old sidecar
  makes every HRV candidate request fail closed (withheld `provider_error`), never a
  canonical change.
