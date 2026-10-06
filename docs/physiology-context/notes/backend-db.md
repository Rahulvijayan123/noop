# Physiology context: backend-db notes

Branch `pc/backend-db`, based on the contract commit `71dce34a`. Workstream files:

| File | What |
| --- | --- |
| `supabase/migrations/20261006050000_physiology_context.sql` | Tables, RLS, RPCs, triggers (additive, re-runnable) |
| `supabase/functions/_shared/serverScores.ts` | Four new route predicates in `handleScoresRequest`; existing routes unchanged |
| `supabase/functions/_shared/physiologyContext.ts` | Query parsers, exposure validator, `submitExposureEvents` (new file) |
| `supabase/functions/tests/physiology_context_routes_test.ts` | Routes against in-memory doubles (18 tests) |
| `supabase/functions/tests/physiology_context_sql_test.ts` | Queue, publication, reads, triggers, deletion on the production image (15 steps) |
| `supabase/functions/tests/exposure_events_sql_test.ts` | Exposure revisions, invalidation, reads, validator parity (6 steps) |
| `supabase/functions/tests/auth_isolation_sql_test.ts` | Ten names added to `SERVICE_ONLY_FUNCTIONS` (nothing else) |

`supabase/tests/e2e/ordered_migrations.sh` globs the directory, so it picks the new file up with no edit.

Days are the owner's local days in `profiles.timezone` (the zone `scoring_jobs_v2` uses); a missing or unknown zone is
UTC. Mode `causal_live` is the owner's local today, `retrospective` every earlier day. Day strings are always
`yyyy-MM-dd` (built with `to_char`, so they do not depend on `DateStyle`).

## 1. Tables

Every table has RLS. `authenticated` may only `SELECT` its own rows of the eight product/exposure tables
(`(select auth.uid()) = user_id` or `= owner`); the queue has no client grant at all; `anon` has nothing. All writes go
through the service-role RPCs. Every foreign key cascades on delete; device-scoped tables carry
`foreign key (user_id, device_id) references devices(user_id, id) on delete cascade`.

| Table | Key | Lifecycle |
| --- | --- | --- |
| `physiology_context_jobs` | PK `(user_id, device_id, day, mode)` | Queue. `input_revision`/`completed_revision`, `lease_token`/`lease_until`, `consecutive_failures`, `dead_letter`, `not_before`, `dirty_at`, `fingerprint` (sha256 hex of the dependency set, stamped at enqueue and at every claim), `reasons text[]` (distinct, sorted, ≤ 16, cleared on completion), `cutoff_override bigint` (cleared on a successful publish), counters (`claim_count`, `success_count`, `unchanged_count`, `renewal_count`, `lease_expiry_count`), `last_worker`, `last_outcome`, `last_context_revision`, `last_error`, `last_duration_ms`. Rows are never deleted except by cascade. |
| `physiology_context_days` | PK `context_revision` (identity, sequence `physiology_context_revision_seq`); unique current `(user_id, device_id, day, mode) where superseded_by is null`; unique `(user_id, device_id, day, mode, policy_fingerprint, input_fingerprint)` | One row per published revision: header columns, `versions jsonb`, `scoring_result_revision`/`scoring_input_revision`, `document jsonb` = the **summary** of `StoredDocument.split` (envelopes empty, `envelope_index` set; ≤ 16 MiB, lz4), `document_bytes`, `envelope_count` (total over its tables), `published_at`, `superseded_by`/`superseded_at`. Retention: the current row; a superseded row is deleted (tables cascade) once it has been superseded for 24 h, opportunistically by the next publish of the same key. |
| `physiology_context_envelope_tables` | PK `(context_revision, metric)`; FK `context_revision → physiology_context_days on delete cascade`; index `(user_id, device_id)` | One interned `EnvelopeTable` (`pc-wire-1`) per metric of a revision: `envelope_table jsonb` (lz4), `envelope_count`, `table_bytes`, `user_id`/`device_id` (RLS, composite device FK). Inserted in the publish transaction with its day row; never updated. |
| `physiology_context_daily_values` | PK `(user_id, device_id, mode, day, series_key, regime_key)` | Replaced for `(user, device, mode, day)` on each publish. Scalar columns (`metric`, `value`, `units`, `support_count`, `support_unit`, `support_s`, `finality`, `context_revision`) + `payload` = the DailyValue JSON exactly as published. |
| `physiology_context_bouts` | PK `(user_id, device_id, mode, bout_id)` | Replaced for `(user, device, mode, day)` on publish; a bout id stored under another day moves to the publishing day. `day`, `start_ts`, `end_ts`, `kind`, `status`, `duration_s`, `payload` = ExertionBout JSON. |
| `physiology_context_episodes` | PK `(user_id, device_id, mode, episode_id)` | The `(user, device, mode)` set is replaced only by a publish whose day ≥ the latest day with a current document for that key; `as_of_day` = the publishing day. `payload` = ChangeEpisode JSON. |
| `physiology_context_frozen_references` | PK `(user_id, device_id, reference_id)`; unique `(user_id, device_id, series_key, regime_key, version)` | Insert-only (`on conflict do nothing`); `BEFORE UPDATE` trigger raises `physiology_context_frozen_references_immutable` (55000). `payload` = FrozenReference JSON. |
| `exposure_event_revisions` | PK `(owner, event_id, revision)` | Immutable history; `BEFORE UPDATE` trigger raises `exposure_event_revisions_immutable`. `received_at` = server receipt (unix s), `upload_source_id` = the installation that sent it, `content_digest` = sha256 of the content fields. |
| `exposure_events` | PK `(owner, event_id)`, FK to its revision | Current state = the highest stored revision; `revision_count`, `first_received_at`, `updated_at`. |

No delete-blocking trigger exists anywhere, and no immutable table has an `ON DELETE SET NULL` key, so deleting the
auth user (or a device) removes everything (proven in the SQL suite).

## 2. RPCs (all `SECURITY DEFINER`, `search_path = ''`, EXECUTE revoked from public/anon/authenticated, granted to `service_role` only)

Helpers live in `internal` (no client USAGE; EXECUTE revoked even from `service_role`): `physiology_context_zone`,
`_today`, `_json_int`, `_parse_day`, `_is_key`, `_merge_reasons`, `_dependency_fingerprint`, `_touch`, `_invalidate`,
`_reject_update`, `_placement_changed`, `exposure_event_invalid_reason`, `exposure_revision_json`.

Errors raise with SQLSTATE `22023` (bad argument / payload) or `42501` (`cross_user_caller`, `device_owner_mismatch`,
`account_retired`, `source_owner_mismatch`). Owner-parameter RPCs also refuse a JWT caller whose `auth.uid()` differs.

### `enqueue_physiology_context_days_v1(p_limit integer default 50) → integer`

Number of jobs created or bumped (≤ `p_limit`, 1..1000). Scans `scoring_jobs_v2` (algorithm `frwhoop-server-1`,
`completed_revision > 0`) over each non-retired owner's last 120 local days:

1. **Create** a job for `(device, day, mode(day))` when that day has its own completed scoring and no job exists for
   that mode (reason `scoring_completed`). Order: causal today first, then existing-job bumps, then newest days.
2. **Bump** (reason `inputs_changed`) an existing job that is completed (or dead-lettered) when scoring of D-1..D+1
   completed after its `dirty_at`, `dirty_at ≤ now − 10 min`, and the dependency fingerprint changed. A pending job is
   never bumped here.
3. **Finalize** (reason `finality_due`): a current retrospective `provisional` document whose `availability_cutoff <
   day end + 30 h` once `now ≥ day end + 30 h` (only when its job is completed).

Dependency fingerprint (`internal.physiology_context_dependency_fingerprint`, sha256 hex): zone; completed scoring
revisions of D-1..D+1; `activity_context_days` (algorithm, day, result_revision) of D-1..D+1; `placement_intervals`
(id, revision, placement, source, start, end) of the owner, user-level or this device, overlapping [D-1, D+2); exposure
events (id, revision) whose occurrence overlaps [D-4, D+2). Never writes a scoring table.

### `invalidate_physiology_context_span_v1(p_user uuid, p_device uuid, p_from date, p_to date, p_reason text) → integer`

`p_device` NULL = every device of the owner (a device not the owner's raises `device_owner_mismatch`). `p_reason`
matches `^[a-z][a-z0-9_]{0,47}$`; `p_to < p_from` raises `invalid_span`. The span is clamped to `[max(p_from,
to' − 119), to' = min(p_to, owner today)]`. Each `(device, day)` that has a `scoring_jobs_v2` row or a context job is
created or bumped: today → `causal_live`, earlier → `retrospective`. A bump = `input_revision + 1`, `dirty_at =
not_before = now`, failures and dead letter reset, reason merged. Retired owner → 0. Returns the jobs touched.

### `claim_physiology_context_v1(p_worker text, p_lease_seconds integer default 300) → table`

```text
user_id uuid, device_id uuid, day date, mode text, input_revision bigint, lease_token uuid,
lease_until timestamptz, timezone_id text, day_start bigint, day_end bigint, cutoff_override bigint,
reasons text[], claim_count bigint
```

Zero or one row. `FOR UPDATE SKIP LOCKED`; due = `completed_revision < input_revision`, not dead-lettered, `not_before
≤ now`, lease free or expired, owner not retired. Order: least recently served owner; within an owner `causal_live`
(newest first) before `retrospective` (**oldest first**); then `dirty_at`, `device_id`. `day_start`/`day_end` = unix
seconds of local midnight and the next local midnight in `timezone_id` (82800/90000 on DST days). Re-stamps the
dependency fingerprint. `p_worker` matches `^[A-Za-z0-9._:@/-]{1,128}$`; lease 1..3600 s.

### `renew_physiology_context_v1(p_token uuid, p_lease_seconds integer default 300) → boolean`

True when the lease was live and is extended.

### `fail_physiology_context_v1(p_token uuid, p_revision bigint, p_error text) → jsonb`

```json
{"status": "failed|released|lease_lost|lease_expired", "consecutive_failures": 3, "dead_letter": false,
 "not_before": "2026-10-05T22:00:20+00:00"}
```

Same revision: `consecutive_failures + 1`, `not_before = now + min(3600, 5·2^(previous failures))` s (5, 10, 20, … 640),
dead letter at the 8th, `last_error = left(p_error, 2000)`, lease cleared. Different revision: clean release (failures
0, due now). Lost/expired lease: nothing changes (only `status` is returned).

### `publish_physiology_context_v1(p_token uuid, p_revision bigint, p_payload jsonb) → jsonb`

Payload (snake_case, items exactly as `PhysiologyContext.encoder()` writes them; `document` and `envelope_tables` are
the two halves of `StoredDocument.split(doc)`):

```json
{
  "header": {"mode": "retrospective", "day": "2026-10-04", "finality": "provisional|final",
             "status": "available|partial|no_data|unavailable", "availability_cutoff": 1791230000,
             "generated_at": 1791230000, "contract_version": "pc-contract-1", "schema_version": 1,
             "policy_fingerprint": "…", "input_fingerprint": "…", "versions": {"…": "…"}},
  "document": { /* summary DayDocument: "envelopes": [], "envelope_index": [{"metric", "envelope_count"}] */ },
  "envelope_tables": [{"metric": "hrv_rmssd", "envelope_count": 288, "table": { /* EnvelopeTable */ }}],
  "scoring_result_revision": 123, "scoring_input_revision": 4,   // or null
  "duration_ms": 850,                                            // optional
  "daily_values": [ /* DailyValue, day = header.day, mode = header.mode */ ],
  "bouts": [ /* ExertionBout, day = header.day */ ],
  "episodes": [ /* ChangeEpisode */ ],
  "new_frozen_references": [ /* FrozenReference */ ]
}
```

Validation (raises `22023 invalid_physiology_context_*`, everything rolled back, the lease stays with the worker, which
then calls `fail_…`): `header.mode/day` = the job's (`…_identity`); `document.header.identity.day`,
`.interpretation.mode`, `.policy_fingerprint`, `.input_fingerprint`, when present, agree with it; finality/status
enums; cutoff/generated integral; contract `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`; schema 1..1000; fingerprints
`^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$`; document an object ≤ 16 MiB; ≤ 4000 daily values (unique series+regime), ≤ 1000
bouts (unique id, `interval.end > start`), ≤ 4000 episodes (state enum, direction −1/0/1, valid days, unique id), ≤ 1000
frozen references (version ≥ 1, valid days, numeric center/scale, unique id and series+regime+version); ≤ 16 envelope
tables, one per metric (`^[a-z][a-z0-9_]{0,47}$`), each with `table.metric` = `metric`, a `table.wire_version`
string, `table.rows` of exactly `envelope_count` rows, ≤ 16 MiB (`…_envelope_table`, `…_envelope_table_duplicate`);
when the summary has an `envelope_index` it must list exactly the tables' `(metric, envelope_count)` pairs, and
tables without an index are refused (`…_envelope_index`). A plain document with no index and no tables is accepted.
Keys (series, regime, ids) are 1–160 characters without whitespace or control characters.

Response:

```json
{"applied": true, "context_revision": 812, "reason": "published", "cascaded_days": 3,
 "superseded_revision": 790, "document_bytes": 54211, "envelope_tables": ["heart_rate", "hrv_rmssd"],
 "table_bytes": 731000, "daily_values_changed": true, "episodes_replaced": true, "frozen_references_inserted": 1}
```

| `reason` | `applied` | Effect |
| --- | --- | --- |
| `published` | true | New row and its envelope tables (same transaction); previous current row marked superseded; superseded rows of the key older than 24 h deleted with their tables; values/bouts of the day replaced; episode rule; frozen references inserted; job completed; cascade (below). |
| `unchanged` | false | The current row already has these `(policy_fingerprint, input_fingerprint)`: no new row, no envelope table, nothing replaced, job completed (`unchanged_count + 1`); `context_revision` = the existing one. If `scoring_result_revision` is newer than the stored one, the pairing columns are raised to it (the only update a document row ever receives besides `superseded_by`). |
| `stale_revision` | false | Lease live but `input_revision ≠ p_revision`: nothing written, lease released (job due at once). |
| `lease_expired` / `lease_lost` | false | Nothing written. |
| `owner_retired` | false | Account deletion under way: nothing written, lease released. |

If an identical-fingerprint row exists but is a retained *superseded* row (A → B → A), it is deleted (tables cascade) and a
new row with a higher revision is inserted, so `context_revision` only ever increases. Publications are serialized per `(user, device,
mode)` with an advisory lock taken before any row lock (episode rule under concurrency, no deadlock).

**Cascade (cross-day horizon):** only for `retrospective`, and only when the day's daily values changed (old set vs new
set, full JSON equality, ordered by series/regime): every **existing** retrospective job of the same device for D+1 ..
`min(owner today − 1, D + 28)` is bumped with `history_changed`. `cascaded_days` counts them.

### `physiology_context_read_v1(p_user uuid, p_device uuid, p_day date, p_mode text default null, p_metric text default null) → jsonb`

```json
{
  "status": "available|pending|none",
  "mode": "retrospective", "day": "2026-10-04", "available_modes": ["causal_live", "retrospective"],
  "context_revision": 812,
  "header": {"mode": "…", "day": "…", "finality": "…", "status": "…", "availability_cutoff": 0, "generated_at": 0,
             "contract_version": "…", "schema_version": 1, "policy_fingerprint": "…", "input_fingerprint": "…",
             "versions": {}, "published_at": "…"},
  "document": { /* the stored summary DayDocument */ },
  "envelope_tables": [ /* EnvelopeTable JSON: only p_metric's when given, every table otherwise (by metric) */ ],
  "metric": "hrv_rmssd",
  "document_bytes": 54211, "stored_table_bytes": 2600000, "returned_table_bytes": 430000,
  "envelope_count": 2300, "returned_envelope_count": 288,
  "pairing": {"snapshot_result_revision": 123, "context_scoring_result_revision": 123, "consistent": true},
  "job": {"pending": false, "dirty_at": "…", "input_revision": 4, "completed_revision": 4, "dead_letter": false,
          "leased": false, "reasons": []}
}
```

Rebuild with `StoredDocument.join(summary: document, tables: envelope_tables)`. `header`, `document`,
`envelope_tables`, sizes and `context_revision` are null without a document (`envelope_tables` is `[]` when the
document has no table for the metric); `job` is null without a job. Mode NULL →
`retrospective` if a retrospective document exists, else `causal_live` if one exists, else `retrospective` if a
retrospective job exists, else `causal_live`. `status`: `pending` when that mode's job is queued (`completed <
input`, not dead-lettered) — the current (older) document is still returned; else `available` when a document exists;
else `none`. `pairing.snapshot_result_revision` = newest `scoring_snapshots_v2.result_revision` for (user, device, day,
`frwhoop-server-1`); `consistent` = a document exists and the two are equal (both NULL counts as equal). `p_metric`
(MetricKind raw value, e.g. `hrv_rmssd`, `resting_heart_rate`; `^[a-z][a-z0-9_]{0,47}$`) selects the table (and, for a
plain document with inline envelopes, filters those). Raises `device_owner_mismatch`,
`account_retired`, `invalid_mode`, `invalid_metric`.

### `physiology_context_history_read_v1(p_user uuid, p_device uuid, p_from date, p_to date, p_mode text default null) → jsonb`

Mode default `retrospective`; `p_to − p_from ≤ 119` (≤ 120 days inclusive) else `invalid_range`.

```json
{"mode": "retrospective", "from": "2026-09-01", "to": "2026-10-04",
 "days": [{"day": "…", "context_revision": 1, "finality": "…", "status": "…", "availability_cutoff": 0,
           "generated_at": 0, "published_at": "…", "document_bytes": 0, "scoring_result_revision": null}],
 "daily_values": [ /* DailyValue, day in range */ ],
 "bouts": [ /* ExertionBout, day in range, by start */ ],
 "episodes": [ /* ChangeEpisode overlapping the range */ ],
 "episodes_as_of": {"day": "2026-10-04", "context_revision": 812},
 "frozen_references": [ /* every FrozenReference of the device */ ],
 "pending_days": 0}
```

### `record_exposure_event_v1(p_owner uuid, p_source uuid, p_event jsonb) → jsonb`

`p_event` = ExposureEventRevision JSON: `event_id` (`^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$`), `revision` (1..2^31−1),
`kind`, `label` (1..200 code points, no control characters), `occurred {start, end}` (unix s, `2000-01-01 ≤ start <
end ≤ 2100-01-01`, ≤ 31 days), `time_precision`, `recorded_at`, `source`, `confirmation`, optional `dose_amount` (0..1e9),
`dose_unit` (1..32), `dose_provenance`. `inferred_candidate` + `confirmed` is refused. A client `received_at` is ignored;
the server sets it. Unknown keys are ignored.

```json
{"status": "saved|ignored|rejected", "event_id": "…", "revision": 2, "reason": null, "received_at": 1791237163,
 "invalidated_days": 6}
```

| Case | Result |
| --- | --- |
| revision > current (or new event) | `saved`; revision inserted, current replaced, affected days invalidated |
| revision = current, same content | `ignored` / `duplicate` (original `received_at`) |
| revision = current, different content | `rejected` / `revision_conflict` |
| revision < current, identical to the stored one | `ignored` / `duplicate` |
| revision < current, otherwise | `rejected` / `stale_revision` |
| invalid | `rejected` / `invalid_event`, `invalid_event_id`, `invalid_revision`, `invalid_kind`, `invalid_label`, `invalid_occurred`, `invalid_time_precision`, `invalid_recorded_at`, `invalid_source`, `invalid_confirmation`, `invalid_dose_amount`, `invalid_dose_unit`, `invalid_dose_provenance` |

Concurrent writers of one event are serialized (advisory lock per owner + event). Raises `invalid_owner`,
`account_retired`, `source_owner_mismatch` (a `p_source` that belongs to another owner's installation or account
source).

**Affected days** (mirrors Swift `Exposures.affectedDays`): the local days (owner zone) covering the **closed** instant
range `[min(start) − 24 h, max(end) + 72 h]` over the old and new revision, with `end = max(end, start + 1)` for a point
event. The end instant is included because `Exposures.refs` keeps an event whose end is exactly 72 h before a
measurement (`support.start − occurred.end <= lookback`), so an event ending at local midnight reaches the day that
starts at `end + 72 h`. A correction invalidates the whole hull. Then the invalidation rules above (every device of the
owner, days ≤ today, the most recent 120 days, only `(device, day)` with scoring or a job). Reason `exposure_changed`.

### `exposure_events_read_v1(p_owner uuid, p_from bigint, p_to bigint, p_include_history boolean default false) → jsonb`

Current events with `occurred_start < p_to and occurred_end > p_from` (`p_to − p_from ≤ 366 days`), earliest first, at
most 2000:

```json
{"events": [{"event_id": "…", "revision": 2, "kind": "caffeine", "label": "Coffee",
             "occurred": {"start": 1791000000, "end": 1791000001}, "time_precision": "exact",
             "recorded_at": 1791000060, "received_at": 1791000100, "source": "user_entered",
             "confirmation": "confirmed", "dose_amount": 95, "dose_unit": "mg", "dose_provenance": "user_entered",
             "revision_count": 2}],
 "revisions": [ /* ExposureEventRevision JSON (same keys minus revision_count) of those events, by id, revision; null without history */ ],
 "truncated": false}
```

Retracted events are included (their `confirmation` is `retracted`); the consumer decides.

## 3. Invalidation sources

| Source | Days | Devices | Reason |
| --- | --- | --- | --- |
| Scoring completion (enqueue) | the day itself (create) / D-1..D+1 via fingerprint (bump) | that device | `scoring_completed`, `inputs_changed` |
| Finality | retrospective provisional docs once day end + 30 h | that device | `finality_due` |
| Exposure record | local days of the closed range `[min start − 24 h, max end + 72 h]` | every device | `exposure_changed` |
| Placement trigger (`after insert or update of placement, source, effective_start, effective_end`) | local day of the earliest changed instant (insert: start; placement/source change: earlier start; end/start change: earlier changed bound) through today | the declared device, or every device for a user-level row | `placement_changed` |
| Publish cascade | D+1 .. min(today − 1, D + 28), existing retrospective jobs | same device | `history_changed` |

All are capped at 120 days and never touch a retired owner. The placement trigger never fails a declaration: a
future-dated one is skipped, and the invalidation runs in its own subtransaction (a failure is a `WARNING`; the
enqueue still sees the placement through the fingerprint). The device FK's `ON DELETE SET NULL` does not fire it.

## 4. Routes (`scores` function)

Same auth as `/series`: installation bearer, or Supabase JWT + `x-noop-source-id` of a source registered to the account
(revoked → 401 `source_revoked`, another owner's → 403 `forbidden`). Owner from the credential only.
`cache-control: no-store`. Errors are `{"error": "<code>"}`. Any other method/path (including trailing slashes) stays
405 `method_not_allowed`, which is what an old server answers and what a new client treats as "context unavailable".

| Route | Parameters | Response | Errors |
| --- | --- | --- | --- |
| `GET /scores/context` | `deviceId` (required), `day=yyyy-MM-dd` (required, real date), `mode` (`causal_live`/`retrospective`, optional), `metric` (`^[a-z][a-z0-9_]{0,47}$`, optional) | `{context: <physiology_context_read_v1>, identity}` | 400 `invalid_device_id`, `invalid_day`, `invalid_mode`, `invalid_metric`; 409 `device_registration_pending` (unknown or another owner's device) |
| `GET /scores/context/history` | `deviceId`, `from`, `to` (`yyyy-MM-dd`, inclusive, ≤ 120 days), `mode` | `{history: <physiology_context_history_read_v1>, identity}` | 400 `invalid_range`, `invalid_mode`, `invalid_device_id`; 409 |
| `POST /scores/exposures` | body `{events: [1..25 ExposureEventRevision]}`, ≤ 64 KiB (this route only) | `{results: [{event_id, revision, status, reason, received_at?}], identity}` in request order; invalid events are `rejected` without a database call | 400 `invalid_body`, `invalid_events`; 413 `payload_too_large` |
| `GET /scores/exposures` | `from`, `to` (unix s, half-open, ≤ 366 days), `history` (`1`/`true`/`0`/`false`) | `{events: [...], identity, truncated}`; with `history=1` also `revisions: [...]` (always an array) | 400 `invalid_range`, `invalid_history` |

`identity` = `{userId, sourceId, deviceId, externalDeviceId, project}` (device null for exposures). A database 403
keeps its code (e.g. `device_owner_mismatch`, `account_retired`); anything unexpected is 500 `scores_unavailable`.
Each exposure is its own transaction: a retried batch gets `ignored`/`duplicate` for events that already landed.

## 5. Deviations from contracts.md (refinements; the lead may fold them into the contract)

1. **Cascade upper bound** is `min(today − 1, D + 28)`, not `min(today, D + 28)`: today has no retrospective job
   (today is `causal_live`, and causal documents read causal history), so including it would only add a
   retrospective job for today. The cascade bumps **existing** retrospective jobs only (a day never computed has
   nothing stale).
2. **Invalidation** creates/bumps only `(device, day)` pairs that have scoring work or a context job, so an owner's old,
   idle devices do not fill the queue with `no_data` days. **Enqueue** creates jobs only for days with their own
   completed scoring; neighbours are bumped through the D-1..D+1 fingerprint when they already have a job.
3. **Claim order**: retrospective jobs run **oldest first** (causal newest first), so references are built from
   already-computed earlier days and a backfill does not cascade into days computed out of order.
4. **Claim returns more columns** than listed: `lease_until`, `day_start`, `day_end`, `reasons`, `claim_count`.
5. **Publish with a stale revision releases the lease** (the job is due at once); calling `fail_…` afterwards is
   harmless (`lease_lost`). Publish also returns `superseded_revision`, `document_bytes`, `daily_values_changed`,
   `episodes_replaced`, `frozen_references_inserted`.
6. **`unchanged` may raise the pairing columns** of the current row to the newer scoring snapshot (an identical document
   is the context for that snapshot too); otherwise the read would report `consistent: false` forever.
7. **`fail_…` returns jsonb** (`status`, `consecutive_failures`, `dead_letter`, `not_before`); the contract did not
   specify a return.
8. **Exposures**: a lower revision is `ignored` when identical to the stored one, else `rejected/stale_revision`;
   `inferred_candidate` cannot be `confirmed`; `received_at` is server-assigned and returned per result (the phone can
   store it as the revision's availability time).
9. **Read**: `pending` still returns the current document; `consistent` is a boolean (false without a document);
   extra keys `day`, `available_modes`, `metric`, `document_bytes`, `stored_table_bytes`, `returned_table_bytes`,
   `envelope_count`, `returned_envelope_count`, `job.leased`, `job.reasons`. History adds `days`, `episodes_as_of`,
   `pending_days`. Publish also returns `envelope_tables` (metrics stored) and `table_bytes`.
10. `context_revision` is an identity column with a fixed sequence name (`physiology_context_revision_seq`) so the
    publish can allocate the next revision before superseding the old row.
11. Route validation lives in a new `_shared/physiologyContext.ts`; `serverScores.ts` only gains the route predicates
    and dispatch.

## 6. Tests and results

Environment: Docker pipeline `supabase/tests/e2e/pipeline_db.sh` (image `supabase/postgres:17.6.1.075`, GoTrue
`v2.186.0`, PostgREST, full ordered chain) on my own ports; Deno 2.9.7; Homebrew PostgreSQL 18.3 + PostgREST for the
`local_postgres.ts` suites. Nothing touched a hosted project; the other running containers were left alone.

```sh
export NARA_PIPELINE_DB_PORT=55461 NARA_PIPELINE_REST_PORT=55462 NARA_PIPELINE_AUTH_PORT=55463 \
  NARA_PIPELINE_DIR="$HOME/.cache/pc-backend-db-pipeline"
supabase/tests/e2e/pipeline_db.sh up          # applies the full chain incl. 20261006050000
set -a; source "$NARA_PIPELINE_DIR/pipeline.env"; set +a
cd supabase/functions
EDGE_TEST_ARTIFACTS=/tmp/pcbd-edgeart deno test -A --no-lock tests/physiology_context_sql_test.ts
../tests/e2e/pipeline_db.sh reset   # (from the repo root) before each suite
EDGE_TEST_ARTIFACTS=/tmp/pcbd-edgeart deno test -A --no-lock tests/exposure_events_sql_test.ts
EDGE_TEST_ARTIFACTS=/tmp/pcbd-edgeart deno test -A --no-lock tests/auth_isolation_sql_test.ts
psql "$PIPELINE_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f ../tests/client-privileges.sql
deno test --allow-env --allow-read --no-lock tests/physiology_context_routes_test.ts
```

| Check | Baseline (chain without the new migration) | After |
| --- | --- | --- |
| Full ordered chain applies on an empty production-image DB | ok | ok (also re-applied twice on top: idempotent) |
| `physiology_context_sql_test.ts` | n/a | **1 passed (15 steps)**, DST window asserted (Australia/Sydney 2026-10-04 = 23 h); lz4 asserted on `document` and `envelope_table` (the image supports it) |
| `exposure_events_sql_test.ts` | n/a | **1 passed (6 steps)**, including an event ending exactly at local midnight (the day starting at end + 72 h is invalidated) and the −24 h start (00:30 reaches the previous day, no further) |
| `physiology_context_routes_test.ts` | n/a | **18 passed** |
| `auth_isolation_sql_test.ts` | 1 passed (11 steps), **1 failed step**: `activity_context_at` is client-executable but missing from `CLIENT_CALLABLE_FUNCTIONS` (pre-existing, discovery §5 item 8) | identical: same single failure, no new name in the diff |
| same, temp copy with `activity_context_at` listed (not committed) | — | **2 passed (12 steps)**: all ten new RPCs pass the service-only privilege loop |
| `supabase/tests/client-privileges.sql` | fails: `row level security is off on 1 public table(s): compute_family_policy` (pre-existing; the auth test lists it in `TABLES_WITHOUT_RLS`) | identical; with only that item excluded (temp copy): `client-privileges: ok` |
| `stretch_feedback_test`, `scores_auth_test`, `server_scores_auth_test`, `enrolled_scores_test`, `result_days_test`, `auth_credentials_test`, `stretch_feedback_route_integration_test` | pass | pass (20, 5, 4, 17, 4, 7, 1) |
| `placement_route_test.ts` (local_postgres subset) | **fails**: first POST answers 400 `request_rejected` | identical (pre-existing; unrelated, does not apply this migration) |

Mutation check (temporary broken copies of the migration applied to my container, then the real one restored), each
caught by the intended step: the `D + 28` cascade bound, the episode rule, an EXECUTE grant to `authenticated`, the
stale-revision fence, the exposure range without the −24 h start, the exposure range with an open end (`+ 72 h − 1 s`),
immediate retention instead of 24 h, the read without the table metric filter, and a publish without the
envelope-index check.

Not run, and why:

- The worker (`ContextLane`) end to end: owned by the worker workstream; the SQL suite drives the same RPCs the worker
  calls (claim → publish → read) and the real `scores` handler against the database.
- `multiuser_sql_test.ts`, `server_pipeline_sql_test.ts`, `capacity_evidence_test.ts`: unrelated to these files, long
  (capacity ≈ 7 min, needs `safeupdate` off) and partly fixture-dependent per `supabase/tests/e2e/README.md`.
- Anything hosted (deploy, `db push`, `functions deploy`): not allowed in this workstream.

## 7. Deploy order and rollback

1. Apply the migration by hand (`psql "$DB_URL" -v ON_ERROR_STOP=1 -1 -f
   supabase/migrations/20261006050000_physiology_context.sql`, then `supabase migration repair --status applied
   20261006050000`). It is additive and safe to re-run.
2. Deploy the `scores` function. Before step 1 the new routes answer 404/500 (RPC missing); old routes are unaffected.
3. Enable the worker lane (`FRWHOOP_CONTEXT_ENABLED=1`) after both.

Rollback: redeploy the previous `scores` function and turn the lane off; the tables can stay. Full removal: `drop
trigger physiology_context_placement_changed on public.placement_intervals;` then drop the ten public functions, the
`internal.physiology_context_*`/`internal.exposure_*` helpers and the eight tables (this deletes the context products and
exposure history).

Operational notes: the enqueue scans `scoring_jobs_v2` for the last ~122 days each call (fine at the current fleet
size; an index on `(algorithm_version, day)` would be the first step if it grows). The full-payload comparison for the
cascade means a provisional → final flip of a day's values re-runs up to 28 later days once (their own values usually
do not change, so it does not chain). Superseded documents of a key that is never republished stay until the next
publish of that key (retention is opportunistic); each is at most one row plus its tables.
