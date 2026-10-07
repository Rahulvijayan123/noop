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
| `supabase/tests/` | SQL and shell tests for enrollment and history. `tests/e2e/` holds the sign-up-to-scored-day stack and the production-image database harness; see its [README](../supabase/tests/e2e/README.md). |
| `supabase/config.toml` | Local stack and per-function settings, including the Auth email templates. |
| `supabase/templates/` | The signup and password-reset emails. Both show the one-time code. |

### Edge functions

| Function | Called by | Purpose |
| --- | --- | --- |
| `push` | the app | Receives upload batches and object-lane uploads, writes rows and receipts. Also provisions installation credentials from a Supabase session (`POST /installations/provision`), confirms and hands off wearables, and retires installations. |
| `scores` | the app | Returns published score snapshots, the changed-days feed and the intraday metric series (`GET /series`). Also handles device registration, sleep edits, manual strap placement and activity stretch feedback (`POST /stretch-feedback`); see Scores routes. Accepts the installation credential or the signed-in account's JWT. |
| `coach` | the app | Relays Coach questions to the language model and stores the conversation, the coach's memory and the Settings profile (`/profile`). Authenticates like `push` (the installation bearer). |
| `ingest-verify` | operators | Checks the ingest pipeline end to end. |
| `reconcile` | scheduled | Reconciles the object manifest against storage. |
| `retention-sweep` | scheduled (pg_cron) | Deletes expired objects and manifests. |
| `account-deletion` | scheduled or on demand | Deletes an account: B2 objects, then rows, then the Auth user. |

Every function has `verify_jwt = false` in `config.toml` because each one does its own bearer
authentication. The app's installation tokens are not JWTs, so gateway verification would reject them.
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

### Scores routes

Every route of the `scores` function authenticates the same way: the installation bearer token, or a
Supabase session JWT together with the `x-noop-source-id` header of a source registered to that account. The
owner always comes from the credential, never from the request. Any method and path pair not listed here
answers 405 `method_not_allowed`; an error body is always `{ "error": "<code>" }`. Request bodies are
limited to 8 KiB, except `stretch-feedback`.

| Route | Purpose |
| --- | --- |
| `GET /` | The day's published score snapshot for `?day=` and `?deviceId=`. |
| `GET /days` | The changed-days feed (`cursor`, `limit`, `scopeRevision`). |
| `GET /series` | The intraday metric series (see Intraday metric series). |
| `GET /diagnostics` | The owner-scoped pipeline diagnostics for one device and day. |
| `POST /devices` | Registers the device for the caller's source. |
| `POST /sleep-overrides` | Writes a sleep edit with an optimistic revision. |
| `GET`, `POST /compute-requests` | Submits and reads a hosted compute request. |
| `GET`, `POST /placement` | Reads and declares the owner's manual strap placement (`placement_intervals`). |
| `POST /stretch-feedback` | Stores the person's verdict on a detected activity stretch (below). |
| `GET /context` | The stored physiology context of one device-day (`?deviceId=&day=[&mode=][&metric=]`; see Physiology context). |
| `GET /context/history` | Context episodes, bouts and daily values over up to 120 days (`?deviceId=&from=&to=[&mode=]`). |
| `GET`, `POST /exposures` | Reads and records revisioned exposure events (medication, caffeine, meals, ...); `POST` takes up to 25 per request, body up to 64 KiB. |
| `POST /insights` | The explanation of one key metric (`{"metric": "resting_hr" \| "hrv_rmssd"}`; see Metric insights). |

### Activity stretch feedback

On the "Full day and activity timeline" page a person can mark each detected stretch "this is right" or
"this is wrong, it was actually X". `POST /functions/v1/scores/stretch-feedback` stores that verdict together
with what the model predicted for the stretch, so the labels can later be used to tune the model. Nothing
reads the table to score, display or classify anything.

```text
app -> POST scores/stretch-feedback {feedback: [1..25 items]}
  -> authenticate (installation bearer, or JWT + x-noop-source-id)
  -> validate every item (_shared/stretchFeedback.ts), resolve each item's optional device
  -> rpc upsert_activity_stretch_feedback(owner, validated items)   [service role only]
  -> public.activity_stretch_feedback, one row per (owner, stretch_key)
  <- 200 {saved: [{stretch_key, revision}], ignored: [{stretch_key, reason: "stale"}],
          rejected: [{stretch_key | null, reason}]}
```

- **Envelope.** The body is at most 128 KiB (413 `payload_too_large`). Not JSON is 400 `invalid_body`;
  `feedback` missing, not an array, empty or over 25 items is 400 `invalid_feedback`.
- **Items are judged one by one.** A malformed item comes back in `rejected` with `stretch_key` (null when
  that is itself malformed) and one reason code, and does not stop the others: `invalid_item`,
  `invalid_stretch_key`, `invalid_id`, `invalid_kind`, `invalid_time_range`, `invalid_predicted_label`,
  `invalid_predicted_class`, `invalid_predicted_confidence`, `invalid_verdict`, `invalid_corrected_label`,
  `invalid_note`, `invalid_model_context`, `invalid_app_version`, `invalid_app_build`, `invalid_tz_offset`,
  `invalid_client_created_at`, `invalid_client_updated_at`. The rules are in `validateStretchFeedbackItem`
  and repeated as CHECK constraints on the table. `corrected_label` is only valid with
  `verdict = "incorrect"`; a label sent with `"correct"` is rejected rather than dropped.
  `model_context` is any JSON object of at most 16 KiB (compact JSON), at most 32 levels deep, with no NUL
  characters or unpaired surrogates, because PostgreSQL cannot store those.
- **Device.** `device_id` is the app's external device id and is optional. If it resolves (through
  `findNoopDevice`, like every other route) to a device the caller owns, the internal uuid is stored in
  `device_id`; otherwise `device_id` is NULL and the item is still saved. The external id as sent is kept in
  `external_device_id` whenever it is a safe id. A device never fails an item.
- **Last writer wins.** The key is `(owner, stretch_key)`, and `stretch_key` is stable per `(kind, start)`, so
  validating the same stretch again overwrites it. An incoming `client_updated_at` OLDER than the stored one
  changes nothing and is reported in `ignored` with reason `stale` (the app treats `ignored` as done). Equal
  or newer overwrites every mutable column and bumps `revision`, which starts at 1. A repeated key inside one
  request is applied in order under the same rule, so `saved` can list a key twice.
- **Storage and access.** `public.activity_stretch_feedback` (migration
  `20261004171000_activity_stretch_feedback.sql`) has RLS on. A signed-in client can `SELECT` only its own rows
  and has no `INSERT`, `UPDATE`, `DELETE` or `EXECUTE` anywhere; `anon` has nothing. The only write path is the
  `SECURITY DEFINER` function `upsert_activity_stretch_feedback(p_owner, p_items)`, executable by
  `service_role` alone, which also re-checks that a device belongs to `p_owner`. The table keeps the
  prediction (`predicted_label`, `predicted_class`, `predicted_confidence`, `model_context`), the verdict and
  correction, the span (`start_ts`, `end_ts`, epoch seconds), and the app version, build and timezone offset.
  The database caps `model_context` at 32 KiB of jsonb text, twice the edge function's limit, because jsonb
  renders with extra spaces; it only stops a runaway row.
- **Deleting an account** removes its rows through the foreign key to `auth.users`; deleting a device keeps the
  label and clears `device_id`. The table is not in `DELETION_TABLES` (that list deletes by `user_id`).
- **Reading it for tuning.** Use the service role or `psql`; the indexes are `(owner, start_ts)` and
  `(kind, verdict, predicted_class)`:

  ```sql
  select predicted_class, verdict, corrected_label, count(*)
  from public.activity_stretch_feedback
  where kind = 'activity_context'
  group by 1, 2, 3 order by 1, 2, 4 desc;
  ```

**Deploying it.** Nothing is applied by merging. Apply the migration by hand first, then redeploy the
function (the commands are in Migrations and Edge functions above; `db push` is never used):

1. `psql "$DB_URL" -v ON_ERROR_STOP=1 -1 -f supabase/migrations/20261004171000_activity_stretch_feedback.sql`,
   then `supabase migration repair --status applied 20261004171000`.
2. `supabase functions deploy scores`.

If the function is deployed before step 1, the route answers 500 `scores_unavailable` (the RPC does not exist
yet) and nothing is stored. The migration is additive and safe to re-run. Rollback is to redeploy the previous
`scores` function; the table and function can stay, or be dropped (`drop function
public.upsert_activity_stretch_feedback(uuid, jsonb); drop table public.activity_stretch_feedback;`), which
deletes the labels.

**Tests** (from `supabase/functions/`, same sanitised environment as the intake gate in
`supabase/functions/tests/README.md`, with `EDGE_TEST_ARTIFACTS` pointing at a short directory outside the
checkout): `tests/stretch_feedback_test.ts` (validator and the route against in-memory doubles),
`tests/stretch_feedback_sql_test.ts` (schema, privileges, RLS and the upsert RPC on a throwaway local
PostgreSQL and PostgREST) and `tests/stretch_feedback_route_integration_test.ts` (the real handler against that
database). `tests/auth_isolation_sql_test.ts` lists the RPC among the service-only functions, so the
Docker-gated catalogue check fails if a client role is ever granted `EXECUTE`.

### Accounts and installation credentials

Testers sign up with Supabase Auth. There are no enrollment codes and no shared token in the app.

1. The app signs the person up with an email address and password and verifies the one-time code Auth
   emails (`verifyOTP`, type `signup`). The result is a Supabase session. The app holds only the
   project's publishable key.
2. The app calls `POST /functions/v1/push/installations/provision` with the session's JWT as the bearer
   and `{ sourceId, platform, appVersion }` as the body. The function checks the JWT with Auth
   (`GET /auth/v1/user`), requires a confirmed, non-anonymous account, generates a 256-bit random `noop_…`
   token itself, and calls `provision_noop_installation` with only the token's SHA-256 hash. The plaintext
   never reaches Postgres.
3. The response says what happened, and a new token is returned once, in `installationToken`, unless the
   action is `reused`. `created` is the first provisioning of that source for the account (HTTP 201).
   `reused` means the phone presented its current credential in `x-noop-installation-token` and it is valid
   for more than 30 days, so nothing new is issued. `rotated` replaces a lost, expired or revoked credential
   for the account's own source, and `upgraded` adopts the account's old enrollment-code installation.
   Credentials last a year.
4. Every later request, including a background upload on a locked phone, authenticates with that token
   alone. It does not need a fresh JWT.

The user id never comes from a request body. It comes from the verified JWT when provisioning and from the
credential after that. The token row is bound to `(user_id, source_id)` by a composite foreign key to
`noop_app_installations`, and a source id belongs to one account for its whole life
(`noop_installation_immutable`). A device's id is derived from the owner's user id and its external id,
`devices.user_id` cannot change (`device_owner_immutable`), and a serial number is evidence rather than
ownership, so two accounts that confirm the same strap hold two separate devices.

Provisioning refuses with these codes:

| Code | Status | Meaning |
| --- | --- | --- |
| `email_not_confirmed` | 403 | The JWT is for an unconfirmed or anonymous account. |
| `installation_unavailable` | 409 | The source id is bound to another account. The app abandons it and picks a new one. |
| `installation_retired`, `installation_revoked` | 403 | A retired or revoked source is never silently revived. |
| `account_retired` | 403 | The account is being deleted. |
| `installation_limit` | 409 | The account already has 25 active installations. |
| `provision_rate_limited` | 429 | More than 20 credential changes in an hour. Retry after 300 seconds. |

The `NOOP_ALLOW_LEGACY_ENROLLMENT` function secret keeps the pre-Auth enrollment-code credentials working
alongside the shared fleet header. It is off unless set to `true`; leave it unset. With it off, an
enrollment-code token is refused with `legacy_enrollment_disabled`, and `/push/enroll` answers 410 with the
same code.

Row-level security is the second line behind the functions, for anything a signed-in client reads through
PostgREST. `auth_isolation_sql_test.ts` asserts that every table in `public` has RLS enabled (one shared
reference table aside), that every policy a client can hit is written in terms of `auth.uid()`, that
exactly the reviewed functions are executable by `anon` and `authenticated`, and that no view hands a
client rows its owner's rights could see.

The client roles are also narrower than Supabase's defaults.
`20261004160000_client_privilege_hardening.sql` removes every `anon` privilege on `public` relations and
sequences, removes `TRUNCATE`, `REFERENCES` and `TRIGGER` (which RLS does not govern) from `authenticated`,
applies the policies whose only job is to admit the service role to `service_role` instead of `PUBLIC`, and
stops the default privileges re-granting any of it to relations created later.
`supabase/tests/client-privileges.sql` asserts all of that, and the reviewed list of client-callable
`SECURITY DEFINER` functions, against a live database in a read-only transaction (the command is at the top
of the file), so a later migration cannot widen the surface without that script failing.
`20261004161000_reconcile_confirm_noop_wearable.sql` records the `confirm_noop_wearable` body production had
been running after an in-place change.
`20261004170000_account_deletion_detach_receipts.sql` lets an erase detach an upload receipt from an object or
token that is being deleted after the installation has already been retired. Without it `account-deletion`
stalled at `delete_supabase_rows` for any account that had uploaded, because the detach re-ran the
retired-installation guard and was rejected. A retired installation still cannot write: any other change to a
receipt, and any new receipt, is still refused. `supabase/tests/account-deletion-retired-installation.sql`
covers both halves in a rolled-back transaction (the command is at the top of the file).

#### Hosted project checklist

Do these once per project, in the dashboard or with `supabase config push`. None of it is applied by
migrations.

- **Authentication → Sign In / Providers → Email:** enabled, **Confirm email** on, minimum password length
  8. Anonymous sign-ins stay off.
- **Authentication → Emails → SMTP Settings:** custom SMTP through Resend: host `smtp.resend.com`, port
  `465`, username `resend`, password a Resend API key with sending access, and a sender on a domain verified
  in Resend. Without custom SMTP, Supabase's built-in sender only delivers to addresses on the project's
  organization team and is limited to 2 messages an hour, so testers would never receive a code. Turning
  custom SMTP on starts you at 30 messages an hour; raise **Authentication → Rate Limits → Emails** to match
  the number of testers you expect.
- **Authentication → Emails → Templates:** *Confirm sign up* and *Reset password* use the files in
  `supabase/templates/`. They show `{{ .Token }}` and no link. The code length is `otp_length` in
  `config.toml`; the app accepts 6 to 10 digits.
- **Function secrets:** leave `NOOP_ALLOW_LEGACY_ENROLLMENT` and `NOOP_ALLOW_LEGACY_FLEET_UPLOADS` unset. The
  functions read the project's keys from the platform's own variables (`SUPABASE_URL`, plus
  `SUPABASE_PUBLISHABLE_KEY(S)` or the legacy `SUPABASE_ANON_KEY`, and `SUPABASE_SECRET_KEY(S)` or the legacy
  `SUPABASE_SERVICE_ROLE_KEY`). A `sb_secret_…` key is opaque and is sent in `apikey`, never as a bearer.
- **Abuse:** sign-up is open to anyone who can receive email, and every attempt sends a message from your
  domain. Supabase recommends CAPTCHA for this; the app does not send a CAPTCHA token yet, so turning it on
  would block sign-up until it does. For a small beta, turn **Allow new users to sign up** off once your
  testers have registered, or invite them from the dashboard.
- **Build:** put the `sb_publishable_…` key in `Config/CloudPushSecrets.xcconfig` as
  `NOOP_SUPABASE_PUBLISHABLE_KEY`. Never put a secret or `service_role` key there.

#### Known limits

- There is no self-service account deletion. `account-deletion` runs on demand or on a schedule, and
  deleting a user cascades through every owned table. A Supabase *ban* is not propagated to the opaque
  installation tokens; revoking the installation or deleting the user is.
- The phone's decoded local store is one device-wide cache. The first verified account claims the
  on-device history (`CloudLocalDataBinding`); a second account on the same phone starts empty on the
  server side and never uploads the first account's history. Live capture is stamped with whoever is signed
  in when it arrives.
- Two accounts can pair the same physical strap. They get separate devices and cannot see each other's
  data, but nothing stops both from claiming it.

### Migrations

> **Do not run `supabase db push` against production.** Production is migrated by hand, as below. Its
> history table (`supabase_migrations.schema_migrations`) was brought level on 2026-10-04 and now records
> every file in `supabase/migrations/` through `20261004170000`, plus `20261001065454`, which is the same
> cron change as `20260930235500` applied from the dashboard under a generated version. Before that it had
> stopped at `20260921104000` while later migrations were applied directly with SQL.

To apply a new migration to production:

1. Add it to `supabase/migrations/` with a timestamp later than the newest file.
2. Run it in a transaction with `psql`, using the session pooler URL:
   `psql "$DB_URL" -v ON_ERROR_STOP=1 -1 -f supabase/migrations/<file>.sql`
3. Record it so the history stops drifting further:
   `supabase migration repair --status applied <version>`

The Supabase Auth change is two migrations, applied in this order:

1. `20261004120000_supabase_auth_installation_provisioning.sql` adds `provisioning_method` to
   installations and tokens, makes `enrollment_code_id` nullable (a check ties each method to its shape),
   adds `provision_noop_installation` and its audit and rate-limit ledger, and guards installations bound
   through Auth against going back to code enrollment. Existing enrollment-code rows are kept and backfilled
   as `enrollment_code`.
2. `20261004123000_revoke_client_execute_on_internal_functions.sql` takes `EXECUTE` on
   `noop_push_consume_ingest_quota` and `http_post_worker` away from `anon` and `authenticated`. Supabase's
   default privileges grant `EXECUTE` on every new function to those roles, and revoking from `public` does
   not remove a direct grant. Neither function checks its caller: the first charges an upload against *any*
   user's ingest quota, which with self-service sign-up would let one account make another's uploads fail,
   and the second posts to the worker with the worker secret as the bearer. It is guarded, so it is a no-op
   where a function does not exist.

For a fresh local database, `supabase db reset` does not work: applied in plain lexicographic order, the
migrations fail at `20260918040000_production_projection_debt.sql`, which alters a column that
`20260921060000_production_intake_durability.sql` creates. Production never hit it because its history grew
one migration at a time. Build a local database with the order `supabase/tests/e2e/ordered_migrations.sh`
prints, applied with `psql -1`; the test harnesses do exactly that.


### Candidate provider lane (20261002090000_physiology_candidate_providers.sql)

The candidate lane records versioned provider results without changing any canonical value.
It ships dormant: `physiology_provider_defaults` has one row per metric, all `mode='off'`, so
no candidate is computed, no candidate row is written and the staleness trigger does no work.
Do not change a mode in production without the rollout plan.

Apply with the normal applied-by-SQL procedure (`psql "$DB_URL" -v ON_ERROR_STOP=1 -1 -f
supabase/migrations/20261002090000_physiology_candidate_providers.sql`, then `supabase
migration repair --status applied 20261002090000`). The file is idempotent-friendly: every
object is `if not exists`/`create or replace`, the seed is `on conflict do nothing`, and
re-running it preserves operator state.

Objects: `physiology_candidate_results` (interval-granular provider results with status,
withheld reason, stages, coverage and diagnostics), `physiology_provider_defaults` /
`physiology_provider_overrides` plus `physiology_selected_provider(user, metric)`,
`physiology_candidate_debt` (third, candidate-only invalidation family),
`physiology_backfill_jobs` plus `physiology_backfill_claim/advance/finish`. All five tables
have RLS enabled with **no** policy: deny by default, service role only. No client role has
any table or function privilege.

`physiology_record_candidate_result(...)` validates shape, bounds and finiteness, requires the
selected generation to still match, requires the caller's current input revision, and inserts
`on conflict do nothing`. It returns the new `candidate_id` or `null`; it never silently
accepts a stale or off-mode write. The worker should call
`physiology_candidate_debt_read(user, device, day)` and skip a write whose claim is older than
`invalidated_at`.

`mode='active'` is gated on a live signed promotion approval. `physiology_selected_provider()`
reports such a metric as `mode='shadow'` with `source` ending `_demoted_unapproved`, and an
active write is refused with `null`. Read `physiology_candidate_activation(user, metric)` to
explain the decision; its `approval.reason` is `promotion_approval_required` (or
`promotion_gate_unavailable` when the signed-promotion objects are missing). The gate is
read-only against `physiology_promotion_approvals`, its revocations and
`internal.physiology_approval_valid`; no signed-promotion object is modified. `off` and
`shadow` are never gated.

Backfill is operator-driven and bounded per call: `dry_run` writes nothing, `apply` enqueues
the existing canonical recompute through `enqueue_scoring_v2`, `rollback` does the same and
additionally fences in-flight candidate writes. No job mutates a selection table.

### Sleep-phenotype enrichment (`daily.sleep_features`, feature/sleep-phenotypes)

Descriptive sleep phenotypes (continuity, architecture dynamics, regularity/timing
variability, stage-conditioned physiology, settling curves, temperature transitions, RSA
respiratory variability) are computed by the SAME loopback sidecar on a dedicated
`POST /v1/sleep-features` endpoint (typed request/response; `docs/SLEEP_FEATURES_CONTRACT.md`)
and attached to the scoring snapshot under `daily.sleep_features`. They are an enrichment,
not a candidate: V2 stays canonical, nothing is promoted, no composite score is introduced.

- **No migration**: `publish_scoring_snapshot_v2` stores `daily` verbatim, the scores edge
  route passes `daily` through, and the phone decodes the key non-fatally
  (`HostedDayResult.sleepFeatures`, shared typed document in StrandAnalytics). The offline
  cache is the existing raw-snapshot cache.
- **Dormant default**: unset `FRWHOOP_INFERENCE_URL` = no enrichment, snapshots byte-identical.
  The worker attaches one bounded request per claimed day (3500 ms transport budget around the
  sidecar's 3000 ms compute budget; timeout → `sleep_features.status = "timeout"`, core
  results unaffected, retried on the next eligible scoring pass).
- **Inputs**: the same rows the canonical pass scored (V2-staged sessions, night-window
  HR/R-R/skin-temp, the production `SleepStager.respBreathTrack` export) plus one bounded
  31-day published-snapshot history for the regularity block. Freshness: a republished day in
  the window changes the `history_revision_digest` and invalidates the rolling SRI.
- **Honesty gates**: SRI validity is staged-spans-only in this wave (minutes outside staged
  sessions cannot be classified awake-vs-off-wrist from the published snapshot, so they are
  excluded, and an SRI window that then fails its ≥5 valid-days / ≥96 paired-hour gate is
  withheld with machine-readable reasons); oxygen analysis and waveform staging report
  `ready: false` with the verified blockers (`unverified_sparse_oxygen`,
  `continuous_ppg_not_delivered`) and are never zero-filled.

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

#### Legacy queue gating

The scoring lane serves two queues, and the legacy fleet queue (`scoring_work_items`) comes first. Its
results are not read by the app or by any edge function (the v2 publish refreshes the same
`server_daily_scores` rows), but an upload re-queues the day and revokes any legacy claim for it. While a
phone uploads every few seconds a legacy attempt therefore cannot finish: it computes the whole day (about
10 s, and the retry loop repeated that up to three times), loses the claim, and is claimed again at once. Measured over
12 minutes, 37 of the lane's 46 claims were legacy attempts and 33 were thrown away, which is why v2
snapshots for the day came 1 to 7 minutes apart.

The worker now leaves a legacy item alone while its owner has uploaded in the last
`FRWHOOP_LEGACY_QUIET_SECONDS` (default 20; 0 restores the old behaviour), and claims it regardless once it
has waited `FRWHOOP_LEGACY_MAX_DEFER_SECONDS` (default 1800), at most once per item per that long. A claim
that an upload has revoked is no longer retried. The scoring lane's heartbeat counter `legacy_deferred`
counts cycles that had only deferred legacy work, so a growing legacy backlog while the phone is active is
expected, not a fault.

#### Scoring input gate

An upload takes the owner's `scoring-inputs-v2` advisory lock exclusively and then updates the job row.
The v2 scoring pass used to do the opposite: it locked the job row when it claimed it, ran for about
7 seconds, and asked for the shared side of the advisory lock only at publication. Any upload that
reached its job-row update during those 7 seconds therefore deadlocked with the publication. Postgres
killed the publication, so the whole pass was computed a second time (the worker retries a deadlock),
or it killed the upload. Every pass ended that way once uploads arrived every couple of seconds: over
14 minutes at a 45 second cooldown, 8% of uploads failed and the 90th percentile of an upload was 9 to
10 seconds.

The lane now takes that advisory lock (shared, session level) before it claims the job, so it locks in
the same order as an upload. It first runs the claim function as a rolled-back dry run to learn which
owner is next, then polls `pg_try_advisory_lock_shared` every 100 ms for up to
`FRWHOOP_V2_INPUT_GATE_SECONDS` (default 10; 0 restores the old order). It polls instead of queueing
because a queued request would sit ahead of every upload that arrives later. If the gate stays busy for
the whole wait, the pass claims without it, so a phone that never stops uploading cannot starve scoring.
The gate is released as soon as the snapshot transaction commits or rolls back. A dead connection drops
it with the session. The scoring lane's heartbeat counters `gate_taken`, `gate_wait_ms` (summed) and
`gate_skipped` show how it is doing; `gate_skipped` should stay near zero.

With the gate in place the deadlocks stopped, uploads failed about 1% of the time, the 90th percentile of
an upload fell to about 4 seconds, and today's snapshot is published every 45 to 46 seconds, which is the
cooldown, instead of every 54 seconds. To check it, count `deadlock detected` and `statement timeout`
entries in the database's Postgres logs and the non-200 `push` responses in `function_edge_logs`.

## Intraday metric series

HRV, resting heart rate, respiratory rate, steps and calories are also stored as a dense series, one
value per bucket (one minute for respiratory rate, steps and calories, five for HRV and resting heart
rate), next to the one-value-per-day rows in `server_daily_scores`. Baselines and
event detection need the shape of the day, which a single daily number cannot give them.

```text
phone upload -> push -> noop_* rows -> scoring_jobs_v2 marked dirty -> worker re-scores the day
  -> publish_scoring_snapshot_v2 (commits)
  -> publish_metric_series_v1 (a separate statement) -> server_metric_series
  -> GET scores/series -> the "Through the day" card on each metric's detail page
```

All of the arithmetic runs on the VPS (`Tools/CloudWorker/Sources/frwhoop-worker/IntradaySeries.swift`).
Every scoring pass rebuilds the whole day's series from the raw streams, so a bucket fills in once the
upload behind it has been scored. The cadence follows data arrival, not a timer, so the limit is how soon
the strap's samples reach the database. The links in the chain, with the app open and a WHOOP 5.0/MG
connected:

| Link | Interval | Set by |
| --- | --- | --- |
| Strap to phone, heart rate and R-R | continuous (about 1 Hz) | BLE notifications |
| Strap to phone, steps, motion, skin temperature, sleep state, SpO₂ byte | one history offload a minute | `BLEManager.freshBackfillIntervalSeconds`; the Power-saving "Sync every minute" switch (`noopFreshSync`, on by default, cloud mode only) |
| Strap to phone, PPG waveform and PPG heart rate | one window of about 40 s roughly every 20 minutes, inside the same history offloads | The strap decides; the phone keeps these locally and does not upload them (see Known issues) |
| Phone to Supabase | a batch about every 2.5 s in the foreground (measured: median gap 1.8 s), 10 s off screen; the upload that meets a scoring pass waits up to about 8 s. Measured with the phone passcode-locked for 20 minutes: 20 batches a minute across all streams (28 with the screen on), longest gap 19 s | `CloudCapture.sealTargetSeconds`; the scoring input gate below |
| Day re-scored on the VPS | at most once per 45 s per day, whatever the number of uploads | `claim_scoring_v2` (migration `20261002123000`) |
| Series and snapshot read by the app | every 30 s while a screen shows them | `AppModel.hostedRefreshSeconds`, `IntradaySeriesSection.refreshSeconds` |

That puts a new step or calorie on screen roughly one to two minutes after the strap recorded it.
While iOS has the app suspended (overnight, for instance) samples arrive hours late in one batch, and the
buckets behind them fill in all at once.

Heart rate reaches the receiver at most once per second of the day. The live notification and the history
offload both carry most seconds, with a bpm that differs by a few beats, and the receiver treats a second
that arrives with two values as a conflict and keeps neither (see Known issues). `CloudHeartRateLedger`
(`Strand/Push/CloudCapture.swift`) therefore lets a second into the journal once, with whichever sample
arrives first, the same rule the phone's own store applies. The offload still fills every second the live
stream missed.

| `metric` | Value in a bucket | Notes |
| --- | --- | --- |
| `hrv_rmssd_ms` | RMSSD of the bucket's clean R-R beats | Quiet wrist only, and at least 45 clean beats, so most daytime buckets are empty. |
| `resting_hr_bpm` | Lowest near-still 5-minute mean over the trailing hour | The nightly definition applied to a moving window. |
| `resp_rate_bpm` | Respiratory rate from the breaths in the trailing 2 minutes of R-R, one point per minute | Quiet wrist only. Read per unbroken run of beats (`SleepStager.respBreathTrack`), so a dropout costs only the seconds it covers; the nightly rate still uses 300 s windows. |
| `steps` | Steps in the minute | The day's buckets sum to the daily total. |
| `calories_kcal` | Resting plus active energy in the minute | The day's buckets sum to the daily total. |

Each payload carries `bucket_seconds` (the default, 300) and `metric_bucket_seconds` (a width per metric), and
each row stores its own `bucket_seconds`; the read returns both the widest bucket overall and the widest per
metric. Apply `20261002120000_metric_series_per_metric_buckets.sql` before deploying a worker that sends
`metric_bucket_seconds`: the earlier publish function ignores the field and would label minute buckets as
five minutes wide.

Buckets are anchored at the start of the day in the timezone the phone reported for it, the same day the
daily scores use, so a day is 288 five-minute buckets (276 or 300 on a DST change) and 1,440 one-minute ones (1,380 or 1,500). Each row also carries the observations behind it (`sample_count`), the share of the
bucket they cover (`coverage`) and how much the wrist was moving (`motion`), so a consumer can weigh or
drop it. Values outside a plausible range are dropped rather than clamped.

How it is written and read:

- `publish_metric_series_v1(user, device, day, version, payload)` is callable by the service role only.
  It does nothing unless the calling device is the one the day's scores are read from
  (`selected_scoring_device_v2`), writes only buckets whose content changed, and deletes buckets in the
  day's window that the payload no longer contains. The worker calls it after the snapshot transaction has
  committed, never inside it: that transaction holds the locks uploads already deadlock against (see
  Known issues). A failure is counted and logged, and the next scoring pass of that day repairs it.
- `server_metric_series_read(user, from, to, metrics)` returns up to 72 hours as one jsonb document, which
  keeps a full day under PostgREST's 1,000-row cap.
- `GET /functions/v1/scores/series?deviceId=<id>&from=<unix>&to=<unix>[&metrics=a,b]` authenticates like
  the other `scores` routes and returns `{series, identity}`, where `series.metrics.<name>` is a list of
  `[bucket_start_unix, value, sample_count, coverage, motion]`. An unregistered device answers 409
  `device_registration_pending`.
- The app (`Strand/Push/IntradaySeriesStore.swift`) refreshes every 30 seconds while the card is on
  screen and keeps the last response on disk, so it still draws offline.
- The coach reads the same series through its `get_intraday_series` tool (`Strand/Coach/CoachIntraday.swift`),
  and its prompt states that these metrics are continuous. The daily tools (`get_daily_metrics`,
  `prepare_chart`) still return one HRV and resting HR per day, which is a summary, not what the strap records.
- On a metric page, the daily-history chart under the intraday card is labelled in days ("2 days · ALL"),
  never "readings" or "sparse", for these five metrics.

Switch the series off without stopping scoring by adding `series` to `FRWHOOP_DISABLE_LANES` (for
example `projection,series`) and restarting the worker. The table keeps what it holds.

Known limits:

- The series starts on the day the worker carrying it was deployed. Re-scoring an earlier day (marking its
  `scoring_jobs_v2` row dirty) writes that day's series from the stored raw data, for as long as the raw
  rows are kept.
- Only the v2 scoring lane writes it. The legacy fleet lane does not.
- A bucket holds a value only when the strap sent enough data for it. Gaps are expected: daytime HRV and
  respiratory rate in particular are sparse by design.

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
  -> publish_activity_encoder_windows (fenced, same transaction) -> activity_encoder_windows
  -> GET scores/activity-windows -> the phone's own activity decoder (HART evidence per 4-s window)
```

### Where the raw motion comes from, and where HART's windows go

- **Capture.** On a WHOOP 5/MG the phone records the raw motion stream on its own (`ActivityImuCapture`:
  part-time by default, one minute in every three; Off and Continuous in Power saving). It keeps one
  open-ended IMU store window per strap (`activity-<device>`) and arms or stops the stream on the
  keep-alive tick; a Raw Data session someone starts by hand still owns the stream while it runs. The
  strap's battery cost of streaming raw motion has not been measured, which is why the default is
  part-time. Recordings are kept a week on the phone (`ImuRetentionPolicy.activityCapture`).
- **Upload.** The object lane reads the IMU store under the BLE layer's local id and uploads under the
  strap's cloud id (`CloudStrapSerialStore`), the device its heart rate and gravity already go to. Before
  this the lane read under the account's fallback id, found nothing, and no `rawImuSession` object ever
  reached the server. An object goes out once its 300 s window has closed, so a live capture costs one
  object per five minutes instead of one per lane pass.
- **Cost on the worker.** A day's job re-runs whenever another object of the day turns ready. The lane
  keeps downloaded objects and the model's answer for every serve request on the host
  (`ActivityLocalCache`, `FRWHOOP_ACTIVITY_CACHE_DIR`), and request chunks are aligned to the start of
  their run, so a re-run only infers the run that grew.
- **Back to the phone.** The windows (labels, probabilities, the `imu-feat-1` features) are stored per
  UTC day in `activity_encoder_windows` as one compact `hart-windows-1` document
  (`ActivityEncoderWindowSet`, shared by the worker and the app). The phone asks for yesterday and today
  every five minutes, sending the revisions it holds so an unchanged day costs a few bytes. Its decoder
  takes them as encoder windows, and a set that arrives for seconds already decoded re-decodes the day
  (the windows are part of the day's context fingerprint). The stream days below read the same table,
  so the server's documents use the same evidence.

- The Python child is a persistent `stdin/stdout` JSON process (no per-window launches, no HTTP
  endpoint, no GPU). Model loading and inference happen outside Postgres transactions; the lane
  renews its lease around each run's inference. A missing model fails soft (`model_unavailable`),
  never blocks BLE, ingest, scoring, sleep, recovery or archive.
- Deployment needs the migrations `20261003120000_activity_context.sql` and (for the day documents
  below) `20261003130000_activity_context_days.sql` and `20261003140000_activity_context_stream_days.sql`
  applied with `psql` (never `supabase db push`; see Migrations), the `Tools/ActivityContext` tree plus a
  Python 3.10+ venv on the host (`uv venv && uv pip install -r Tools/ActivityContext/requirements` style
  pins in the package README), and the trained model artifacts copied to `FRWHOOP_ACTIVITY_MODEL_DIR`
  (fetch/build commands in the package README; nothing is committed to git). The stream days below need
  only the third migration: a host with no Python runs them with `FRWHOOP_ACTIVITY_IMU=0`.
- Rollback: set `FRWHOOP_ACTIVITY_ENABLED` off (or add `activity` to `FRWHOOP_DISABLE_LANES`) and
  restart the worker. The tables keep their rows; snapshots simply stop carrying
  `activity_context` after the next scoring pass, and old clients are unaffected either way. The
  migration is additive (new tables + functions only), so reverting it is not required for rollback.
- Promotion is evidence-gated, not config-gated: the held-out WISDM-19 watch result (macro-F1 0.66,
  coverage 0.66) does NOT meet the product targets (0.85 macro-F1, 0.90 walking/running precision),
  so automatic labels stay in shadow mode until a WHOOP-labeled pilot passes those gates. Posture
  and new activities have separate gates. The `RestingEligibility` policy is exported but rejects by
  default (wear/sleep evidence is unknown in v1), so no physiological baseline behavior changed.

### Day documents (ActivityContext v2)

The same job also stores one decoded document per UTC day in `activity_context_days`. It is the
document the app builds on the phone for its heart-rate day page: probabilistic posture, locomotion
and arm-behavior heads coalesced into runs, transition events and a day summary
(`ActivityContextDayDocument`, schema 2, ontology `v2.0`, decoder `hsmm-1.3`). The server runs the
SAME decoder (`StrandAnalytics.ActivityContextTrackBuilder`), so a phone-built and a server-built
document of one day differ only in their inputs. Every run also carries the canonical `activity_class`
(`sitting_desk`, `walking`, `off_wrist`, `unknown`, ... taxonomy `act-class-2`, see
`CURRENT_ALGORITHMS.md` section 9) and its `class_confidence`, derived by the same classifier the phone
uses. A document written before decoder `hsmm-1.2` has neither key and reads as NULL.

```text
activity job (unchanged claim / download / decode / lease renewal)
  -> Python service, per 4-s window: HART (or baseline) probabilities + imu-feat-1 IMU features
  -> Postgres, for the UTC day: HR, gravity, steps, WRIST_OFF/ON events (6 h reach-back),
     the published nights (newest scoring_snapshots_v2 of local days d-1..d+1), workouts
  -> ActivityContextTrackBuilder -> ActivityContextDayDocument (no decoder snapshot)
  -> ONE transaction: publish_activity_context_day (fenced, under a savepoint)
                      -> publish_activity_context_v2 (unchanged: epochs, job completion)
  -> scoring_dirty_span
```

- **Storage.** One row per `(user_id, device_id, day, algorithm_version)`; a republish replaces it, so
  readers never merge versions. The `document` jsonb is the source of truth; scalar columns repeat
  the version stamps (`schema_version`, `ontology_version`, `decoder_version`, `feature_schema`,
  `encoder_id`, `encoder_version`) and `observed_s`, `data_through`, `run_count`, `event_count` for
  filtering. RLS lets an owner select their own rows; only `service_role` writes.
- **Fence.** `publish_activity_context_day(token, revision, payload)` uses the v1 fence (live lease and
  current `input_revision`, otherwise NULL and nothing is written). It validates the document before
  writing (day and version stamps, 16 MiB, at most 20 000 runs and 10 000 events, every run inside the
  day) and raises a stable `invalid_activity_day_*` error otherwise. It does NOT complete the job,
  clear the lease or dirty scoring: the v1 publish stays the only thing that does.
- **v2 can never block v1.** A failure at any v2 step (stream read, decode, a rejected document, the
  migration not applied yet) is counted and skipped, and the v1 epochs, the job completion and the
  scoring invalidation happen exactly as before. The v2 row and the v1 epochs share one transaction,
  so a v1 publish that rolls back takes the day document with it. A fenced publish (lease lost) is
  ignored for both. Heartbeat counters: `context_days_published` (stored) and `context_day_failures`
  (skipped). A skip is logged to stderr as
  `activity context v2 day skipped (v1 publish unaffected): <reason>` whenever its reason differs from
  the previous one, so a failure that repeats on every job does not flood the journal. Reasons never
  contain the document.
- **Knob.** `FRWHOOP_ACTIVITY_CONTEXT_V2=0` turns only the day documents off (default on while the
  lane is on). Inference is unchanged: the same windows (4 s, 2-s hop) feed both the v1 epochs and the
  day document, and the only new work per job is reading the day's streams and the decode (cost under
  "Known limits"). Windows from a service that does not report `feature_schema` `imu-feat-1` (an older
  `serve.py`) are decoded without IMU features, never with shifted ones.
- **What a document covers.** The UTC day `[00:00, 24:00)`. For the day in progress it covers up to
  the time the job ran (`data_through`), and a WRIST_OFF that has no WRIST_ON yet is open only up to
  then. Runs are clamped to the day; the neighbouring day's document starts where this one stops.
  Time outside logged sleep sessions stays "unknown" (the server does not infer sleep from stillness).
- **Where sleep comes from.** The nights the scoring lane published: every `payload.sleep` entry of the
  newest `scoring_snapshots_v2` row for each local day from d-1 to d+1 that overlaps the UTC day. A
  night's in-bed window is its `start_at`/`end_at`; it is asleep only on its staged non-wake `stages`,
  so lying awake in bed is `sleep_state` `awake` with `in_bed: true` on the run, never `asleep`.
  `public.sessions` was the source until 2026-10; the current scoring lane does not write nights there,
  and every stream day decoded since then had no sleep at all.
- **Deploy order.** Apply the migration BEFORE (or together with) the worker upgrade. A worker that
  runs first still publishes v1 as before; its v2 write fails with a missing-function error under the
  savepoint, which is counted on every job and logged once.
- **Check.**

  ```sql
  select day, schema_version, ontology_version, decoder_version, feature_schema, encoder_id,
         publish_interval_s, observed_s, run_count, event_count, computed_at
  from public.activity_context_days order by computed_at desc limit 10;

  -- Completed days that have no v2 document yet (published before the upgrade):
  select j.day, j.last_completed_at
  from public.activity_context_jobs j
  left join public.activity_context_days d
    on (d.user_id, d.device_id, d.day, d.algorithm_version) = (j.user_id, j.device_id, j.day, j.algorithm_version)
  where j.completed_revision = j.input_revision and d.day is null
  order by j.day desc limit 20;
  ```

- **Backfill (operator step, optional).** Completed jobs are not re-run on their own. To give
  recent days a v2 document, mark them due again; the lane recomputes the whole UTC day from the
  stored objects and publishes both v1 and v2:

  ```sql
  update public.activity_context_jobs
     set input_revision = input_revision + 1, dirty_at = clock_timestamp(),
         not_before = clock_timestamp(), reason = 'v2-backfill'
   where algorithm_version = 'hart-activity-1' and completed_revision = input_revision
     and not dead_letter and day >= current_date - 14;
  ```

- **Rollback.** Set `FRWHOOP_ACTIVITY_CONTEXT_V2=0` and restart the worker. The table keeps its rows and
  nothing reads it, so the migration needs no revert. Account deletion removes the rows through the
  foreign keys to `auth.users` and `devices`, so the table is not listed in the edge function's
  explicit deletion tables.
- **Not built yet.** No edge route serves these documents and the app does not fetch them: the phone
  still draws its own locally decoded document. A route (`GET scores/activity-context`), stitching of
  the UTC-day documents into the phone's local day, and a choice between local and server results are
  the follow-up.
- **Known limits.** The document is rebuilt from the stored streams every time the day's job runs
  (a job runs when raw IMU for that day arrives), so HR, gravity or sleep that reaches the server
  later than the last IMU upload shows up at the next job, not immediately. Days are UTC days, not the
  wearer's local days. Decoding is cheap next to inference: a full busy day (a transition every few
  minutes: 1,075 runs, 523 events, 450 KB of JSON) is built in about 0.8 s in a release build. The same
  code takes about 19 s in a debug build, so time it with the release binary the worker runs.

### Inertia-1 motion heads (shadow / candidate, off by default)

A second, optional expert beside HART (contract: `Tools/ActivityContext/INERTIA1.md` §8). With
`FRWHOOP_INERTIA_ENABLED` on (`1`/`true`/`yes`/`on`; any other value keeps it off and is logged) and
`FRWHOOP_INERTIA_BUNDLE_DIR` set, the activity lane starts a SECOND Python child (`python -m
activity_context.inertia.serve --bundle <dir> [--checkpoint <path>] --timeout <s> [--expect-bundle-sha256 <hex>]
[--allow-standin-shadow]`, its own timeout, restart cap and response cap) and, after each HART chunk, renews the
job lease and asks it for `motion-heads-1` windows (posture, locomotion, arm, transition heads, movement
intensity, OOD) for the same chunk.

```text
activity job: HART chunk infer (unchanged) -> Inertia infer for the same chunk (isolated)
  -> strict Swift validation (MotionHeadsResponse: schema, class keys, sums, NaN)
  -> shadow payload (provenance + compact windows + OOD counts)
     [candidate mode: + the day decoded a second time with Inertia evidence, or why it was withheld]
  -> ONE transaction: publish_activity_context_day (savepoint)
                      -> publish_activity_motion_heads_day (savepoint, fenced) -> activity_motion_heads_days
                      -> publish_activity_context_v2 (unchanged)
```

- **Never gates, never fails a job.** Inertia is not part of the readiness gate. A missing model (ping
  `model_available: false`), timeout, crash, malformed or invalid output is counted (`inertia_failures`,
  `inertia_unavailable`), logged once per distinct kind, and the HART path continues. Anything that would repeat
  on every chunk (a timeout, crash, `model_missing`, a bundle mismatch, an unknown schema, a malformed response,
  invalid probabilities, `output_too_large`) stops Inertia for the rest of that job, so a broken child costs at most
  one timeout; only a NaN line or a service `internal` error costs a single chunk. A per-job time budget
  (`FRWHOOP_INERTIA_JOB_BUDGET_SECONDS`, default 600 s) caps the wall time of Inertia's calls in one job; once used,
  Inertia is stopped for that job (`inertia_budget_exhausted`). The one exception is the lease: it is renewed
  before Inertia's job-start readiness check (child start + ping) and before every Inertia call, exactly as before
  every HART call, and a lost lease ends the job the same way.
- **Timeouts.** `FRWHOOP_INERTIA_TIMEOUT_SECONDS` (default 60) is clamped to a third of
  `FRWHOOP_ACTIVITY_LEASE_SECONDS` (logged at start-up when it is); the child's own `--timeout` is set strictly
  below it (worker − 5 s, at least 5 s while that is still below), so the child's structured `timeout` answer
  arrives before the worker kills the line.
- **Bundle pin.** `FRWHOOP_INERTIA_BUNDLE_SHA256` (64 hex) names the one head bundle the worker accepts. It is
  required in candidate mode and enforced in shadow mode when set: passed to the child as
  `--expect-bundle-sha256`, and checked by the worker against the ping and every response. A different served
  bundle turns Inertia off for that job (`inertia_bundle_refused`, logged); the decoder refuses it too
  (`bundle_sha256_mismatch`).
- **Stand-in shadow (opt-in).** `FRWHOOP_INERTIA_ALLOW_STANDIN_SHADOW=1` (default off, shadow mode only; a
  configuration error in candidate mode) passes `--allow-standin-shadow`, so the shadow lane can be exercised
  on real WHOOP data before an Inertia-1 checkpoint exists. Those rows are stored with
  `encoder_kind = standin` and can never feed the decoder: the decoder refuses stand-ins and the table refuses a
  stand-in candidate document. Without the flag a stand-in bundle answers `model_available: false` and nothing
  is stored.
- **The published documents are untouched.** v1 epochs and the `activity_context_days` document are
  byte-identical with Inertia on or off; the candidate comparison is stored only in
  `activity_motion_heads_days.candidate_document` (the read surface would otherwise rank it first).
- **Evidence gate.** Candidate decodes run only for `encoder_kind = inertia1` (a pinned Inertia-1
  checkpoint) with `evidence_tier_max >= candidate` and the pinned bundle; anything else (every stand-in today)
  stores `withheld_reason` (`encoder_kind_standin`, `evidence_tier_shadow`, `bundle_sha256_mismatch`, ...).
  `FRWHOOP_INERTIA_MODE` accepts only `shadow` (default) and `candidate`; production evidence needs a code and
  config change.
- **Storage.** `activity_motion_heads_days`, one row per `(user_id, device_id, day, bundle_id, mode)`,
  migration `20261005170000_activity_motion_heads.sql`. Service role writes through the fenced
  `publish_activity_motion_heads_day(token, revision, payload)` (live lease and current revision, else
  NULL, counted as `inertia_shadow_fenced`; stable `invalid_motion_heads_*` errors; 16 MiB payload); owners may
  select their own rows. Per-window predictions are columnar small integers (`mh-col-1`: per head the top-class
  index and its probability in percent, an OOD flag, start deltas; about 0.5 MB per full day per bundle, omitted
  above 512 KiB, refused above 1 MiB). `summary.track_report` says how the windows met the day's observed
  seconds (attached / dropped, and in candidate mode the decode's posture omissions on the sleep route). A
  `candidate_document` is only ever stored for `encoder_kind = 'inertia1'`, `mode = 'candidate'`, tier
  candidate or production (table CHECK and RPC). Contract:
  `supabase/functions/tests/activity_motion_heads_contract.sql`.
- **Retention.** `prune_activity_motion_heads_days(keep_days default 30, max_rows default 10000)` (service role
  only) deletes rows computed more than 30 days ago and returns the count. The lane calls it every 6 h while
  Inertia is on (`inertia_rows_pruned`, `inertia_prune_failures`); with Inertia off nothing new is written, and
  the remaining rows can be pruned from cron: `select public.prune_activity_motion_heads_days(30, 10000);`.
- **Deploy order.** Migration first. A worker with Inertia on and no migration still publishes v1 and v2;
  the shadow write fails under its savepoint and is counted (`inertia_shadow_failures`).
- **Rollback.** Unset `FRWHOOP_INERTIA_ENABLED` and restart. Nothing reads the table.
- **Check.**

  ```sql
  select day, mode, bundle_id, encoder_kind, evidence_tier_max, n_windows, n_ood, withheld_reason,
         summary->'track_report'->>'attached' as attached, summary->>'windows_omitted' as windows_omitted,
         candidate_document is not null as has_candidate, computed_at
  from public.activity_motion_heads_days order by computed_at desc limit 10;
  ```

### ElderNet gait quality (shadow / candidate, off by default)

A third, optional expert beside HART and Inertia (contract: `Tools/ActivityContext/ELDERNET.md` §6). With
`FRWHOOP_ELDERNET_ENABLED` on (`1`/`true`/`yes`/`on`; any other value keeps it off and is logged) and
`FRWHOOP_ELDERNET_WEIGHTS_DIR` and `FRWHOOP_ELDERNET_UPSTREAM_DIR` set, the activity lane starts a THIRD Python
child (`python -m activity_context.eldernet.serve --weights-dir <dir> --upstream-dir <dir> --timeout <s>`, its own
timeout, restart cap and response cap) and, after each HART chunk (and after Inertia, when that is on), renews the job lease and asks it for
`gait-quality-1` windows (10-s windows: gait probability, gait flag, pre-filter flag and, on gait windows,
speed, cadence, stride length, regularity and steps) for the same chunk.

```text
activity job: HART chunk infer (unchanged) [-> Inertia (isolated)] -> ElderNet infer for the same chunk (isolated)
  -> strict Swift validation (GaitQualityResponse: schema, known keys, ranges, metrics only on gait, NaN)
  -> shadow payload (provenance + compact windows + counts + ElderNet's own gait metrics)
     [candidate mode: + the day decoded a second time with the gait channel, or why it was withheld]
  -> ONE transaction: publish_activity_context_day (savepoint)
                      -> publish_activity_motion_heads_day (savepoint, when Inertia is on)
                      -> publish_activity_gait_windows_day (savepoint, fenced) -> activity_gait_windows_days
                      -> publish_activity_context_v2 (unchanged)
```

- **Never gates, never fails a job.** ElderNet is not part of the readiness gate. A missing model or bad weights
  (ping `model_available: false`), a pin mismatch, timeout, crash, malformed or invalid output is counted
  (`eldernet_failures`, `eldernet_unavailable`, `eldernet_pin_refused`), logged once per distinct kind, and the
  HART path continues. Anything that would repeat on every chunk (a timeout, crash, `model_missing`,
  `weights_mismatch`, a pin refusal, an unknown schema, a malformed response, invalid values, `output_too_large`)
  stops ElderNet for the rest of that job; only a NaN line or a service `internal` error costs a single chunk. A
  per-job time budget (`FRWHOOP_ELDERNET_JOB_BUDGET_SECONDS`, default 600 s) caps the wall time of ElderNet's calls
  in one job (readiness check included); once used, ElderNet is stopped for that job (`eldernet_budget_exhausted`)
  and the chunks it answered are still stored. The lease is renewed before ElderNet's job-start readiness check
  (child start + ping, which can take up to a request timeout) and before every ElderNet infer call, and a lost
  lease ends the job exactly as before a HART call. Only HART answers are cached on the host: a chunk whose HART answer comes from the cache is
  still sent to ElderNet.
- **Timeouts.** `FRWHOOP_ELDERNET_TIMEOUT_SECONDS` (default 60) is clamped to a third of
  `FRWHOOP_ACTIVITY_LEASE_SECONDS`; the child's `--timeout` is set strictly below it, as for Inertia.
- **Upstream source.** The serve process imports upstream ElderNet's own modules from a sha-verified upstream source
  checkout, fetched by an operator with `python -m activity_context.eldernet.upstream fetch --dest DIR` and named by
  `FRWHOOP_ELDERNET_UPSTREAM_DIR` (passed as `--upstream-dir`). It is required when ElderNet is on (a configuration
  error otherwise, ElderNet stays off); a child without it reports `model_missing`. The ping's extra
  `weights_digest` and `upstream_source` keys are tolerated.
- **Pins.** `FRWHOOP_ELDERNET_MODEL_VERSION` (the served `model_version`) and `FRWHOOP_ELDERNET_WEIGHTS_SHA256`
  (the weights digest: sha256 of `eldernet-weights-1\n` followed by `name=sha256\n` for every served head in name
  order, the same value the decoder and the table compute) are required in candidate mode and enforced in shadow
  mode when set: checked against the ping (its `model_version` and `weights`) and every response. A different
  model turns ElderNet off for that job (`eldernet_pin_refused`); the decoder refuses it too
  (`model_version_mismatch`, `weights_digest_mismatch`). `FRWHOOP_ELDERNET_GAIT_PRIOR` (π in [0.01, 0.99]: the mean
  served `gait_prob` over the VAL windows the decoder sees, which makes the channel neutral on average; 0.085 for
  the served defaults, ELDERNET.md §5) is required in candidate mode.
- **The published documents are untouched.** v1 epochs and the `activity_context_days` document are byte-identical
  with ElderNet on or off; the candidate comparison is stored only in `activity_gait_windows_days.candidate_document`.
  `FRWHOOP_ELDERNET_MODE` accepts only `shadow` (default) and `candidate`; production evidence needs a code and
  config change.
- **Storage.** `activity_gait_windows_days`, one row per `(user_id, device_id, day, model_version, mode)`, migration
  `20261006090000_activity_gait_windows.sql` (its own table: `activity_encoder_windows` is read by the phone and the
  stream days as HART evidence). Service role writes through the fenced `publish_activity_gait_windows_day(token,
  revision, payload)` (live lease and current revision, else NULL, counted as `eldernet_shadow_fenced`; stable
  `invalid_gait_windows_*` errors; 16 MiB payload; the weights digest is recomputed from the stored weights and a
  mismatch is refused); owners may select their own rows. Per-window outputs are columnar small integers
  (`gait-windows-1`: gait probability per mille, gait / pre-filter flags, speed cm/s, cadence steps/min, stride cm,
  regularity %, steps × 10, -1 where absent; about 0.45 MB per full day at a 5-s hop, omitted above 512 KiB,
  refused above 1 MiB). `summary` carries the counts, ElderNet's own gait metrics over its gait windows and
  `track_report` (how the windows met the day's observed seconds). A `candidate_document` must carry its
  `versions.gait_quality` stamp (table CHECK and RPC), and stored `windows` must say `format: gait-windows-1` (the
  CHECK uses `is not distinct from`, so a missing key is refused too). Contract:
  `supabase/functions/tests/activity_gait_windows_contract.sql`.
- **Retention.** `prune_activity_gait_windows_days(keep_days default 30, max_rows default 10000)` (service role
  only); the lane calls it every 6 h while ElderNet is on (`eldernet_rows_pruned`, `eldernet_prune_failures`).
- **Deploy order.** Migration first. A worker with ElderNet on and no migration still publishes v1 and v2; the
  shadow write fails under its savepoint and is counted (`eldernet_shadow_failures`).
- **Rollback.** Unset `FRWHOOP_ELDERNET_ENABLED` and restart. Nothing reads the table.
- **Check.**

  ```sql
  select day, mode, model_version, left(weights_digest, 12) as weights12, hop_s, n_windows, n_gait, n_prefiltered,
         withheld_reason, summary->'gait'->>'cadence_spm' as cadence, summary->>'windows_omitted' as windows_omitted,
         candidate_document is not null as has_candidate, computed_at
  from public.activity_gait_windows_days order by computed_at desc limit 10;
  ```

### Stream days (a document for every day with measurements)

Raw IMU is uploaded for only a handful of sessions, but heart rate, gravity, steps and wear events are
stored for every day the strap was worn. Stream days give each of those UTC days the same day document,
decoded from the stored measurements and, when the raw-IMU lane has stored any for the day, HART's windows
from `activity_encoder_windows` (otherwise `encoder_id` is null and the HART/IMU evidence is absent). The lineage is `algorithm_version = 'streams-activity-1'`; a day that also has a raw
IMU document (`hart-activity-1`) keeps both rows and the read surface lists the IMU one first.

```text
scoring_jobs_v2 completed work (any revision)
  -> enqueue_activity_stream_days(lookback, backfill limit, min rebuild interval)   [every 2 min]
       one activity_context_jobs row per (owner, device, UTC day), algorithm 'streams-activity-1';
       the job for day d depends on the scoring of d-1, d and d+1 (a UTC day's measurements reach the
       scorer's local day boundaries), so any of them completing again marks it for a rebuild
  -> claim_activity_stream_day (lease, fairness across owners)
  -> worker: HR, gravity, steps, WRIST_OFF/ON (6 h reach-back), the published nights and workouts
  -> ActivityContextTrackBuilder (same decoder as the phone) -> ActivityContextDayDocument
  -> complete_activity_stream_day (fenced): publish_activity_context_day + complete the job
```

- **Needs neither Python nor B2.** It runs while the model is down, and a host with no Python venv can run
  it alone with `FRWHOOP_ACTIVITY_IMU=0`.
- **Never touches scoring or the v1 tables.** It writes no epochs and calls no `scoring_dirty_span`.
  `claim_activity_context_v2` skips stream jobs, so an older worker never receives one.
- **When a day is built.** Only days that have completed scoring work get a job (the same days the app can
  show), at most one rebuild per job per 10 minutes, and days from 2020-01-01 to today only. An empty day
  (scoring ran, no stored measurements) completes without a document and is not retried until its scoring
  changes. The first run walks backwards from the newest completed day, 25 days per call, so a database
  with a long history fills in over a few hours without starving the live day. A day still in progress is
  rebuilt about every 10 minutes while new scoring completes.
- **Knobs.** `FRWHOOP_ACTIVITY_STREAMS=0` stops the stream stage, `FRWHOOP_ACTIVITY_STREAM_BUDGET`
  (default 4) is jobs per wake, `FRWHOOP_ACTIVITY_IMU=0` stops the raw-IMU stage. Heartbeat counters:
  `stream_days_enqueued`, `stream_days_claimed`, `stream_days_published`, `stream_days_empty`,
  `stream_days_superseded`, `stream_day_failures`. A failing claim (the migration is not applied, a grant is
  missing) is logged once, shows as `last_error_kind = stream_days`, and the stage backs off for a minute;
  the raw-IMU stage is unaffected.
- **Deploy order.** Apply `20261003140000_activity_context_stream_days.sql` BEFORE the worker upgrade.
  Rollback: `FRWHOOP_ACTIVITY_STREAMS=0` and a restart; the migration is additive, and
  `delete from public.activity_context_jobs where algorithm_version = 'streams-activity-1'` removes the queue
  rows (the documents stay readable).
- **Canonical class (additive).** `20261004150000_activity_context_canonical_class.sql` appends
  `activity_class` and `class_confidence` to `activity_context_runs` and `activity_context_at`, and makes
  the publish-time run check strict about them WHEN PRESENT (a snake_case code of at most 32 characters, a
  confidence from 0 to 1; a document without them stays valid). It can be applied before or after the
  worker upgrade. Documents already stored keep NULL until their day is rebuilt, which the worker does when
  that day's scoring next changes; to rebuild a range on purpose, bump the job and let the budget spread the
  work out: `update public.activity_context_jobs set input_revision = input_revision + 1, dirty_at = now(),
  not_before = now() where algorithm_version = 'streams-activity-1' and day >= :from;`. Rollback: re-create
  the view and the function from `20261003140000_activity_context_stream_days.sql` (drop them first;
  columns cannot be removed in place); stored documents are untouched. The worker shares
  `StrandAnalytics` with the app, so the classes only appear in documents after the worker is rebuilt and
  redeployed from this tree.
- **Coverage and honesty.** Time is described in 5-second states, coalesced into runs whenever the state does
  not change; the per-tick probabilities are not kept, the per-run confidence and uncertainty are. A stream
  day has no raw-motion evidence, so posture and arm behavior lean on heart rate, gravity and the step
  counter and are less certain than on a raw-IMU day; the stored `overall_confidence` and
  `overall_uncertainty` say so per run. Days are UTC days, not the wearer's local days. Nothing is stored
  for seconds the strap sent nothing (wrist off is an explicit state, a gap is simply uncovered).

#### Reading it downstream

Everything below is read-only and security-invoker, so an owner sees only their own rows (RLS on
`activity_context_days`); `service_role` sees all.

| Object | One row per | Columns of interest |
| --- | --- | --- |
| `public.activity_context_runs` | state run | `start_ts`, `end_ts` (exact UTC epoch seconds, half-open), `start_at`, `end_at`, `duration_s`, `display_context`, `confidence`, `uncertainty`, `intensity`, `sleep_state`, `wear_state`, `states`, `posture`, `locomotion`, `arm_behavior` (head probabilities), version columns, `source_rank` (1 = raw-IMU document, 2 = stream document), `activity_class`, `class_confidence` (the canonical class and how sure the classifier was; NULL on a document written before decoder `hsmm-1.2`) |
| `public.activity_context_transitions` | transition event | `ts`, `at`, `kind`, `probability`, version columns, `source_rank` |
| `public.activity_context_at(user, device, ts)` | the run containing `ts` | the run columns above (including `activity_class`, `class_confidence`), best source first |

```sql
-- What was the user doing at one exact second?
select * from public.activity_context_at(:user, :device, :ts);

-- Label a range of stored heart-rate samples with the state at their exact second (best source first;
-- the day predicate lets Postgres open only that day's document):
select distinct on (h.ts) h.ts, h.bpm, r.display_context, r.confidence, r.uncertainty, r.algorithm_version
from public.noop_hr_samples h
join public.activity_context_runs r
  on r.user_id = h.user_id and r.device_id = h.device_id
 and r.day = (to_timestamp(h.ts) at time zone 'UTC')::date
 and h.ts >= r.start_ts and h.ts < r.end_ts
where h.user_id = :user and h.device_id = :device and h.ts between :from and :to
order by h.ts, r.source_rank;

-- The same, with the canonical class instead of the display wording:
select h.ts, h.bpm, r.activity_class, r.class_confidence
from public.noop_hr_samples h
join public.activity_context_runs r
  on r.user_id = h.user_id and r.device_id = h.device_id
 and r.day = (to_timestamp(h.ts) at time zone 'UTC')::date
 and h.ts >= r.start_ts and h.ts < r.end_ts and r.source_rank = 2
where h.user_id = :user and h.device_id = :device and h.ts between :from and :to;

-- Seconds per canonical class on one day (NULL = a run from before the class existed):
select activity_class, sum(duration_s) as seconds
from public.activity_context_runs
where user_id = :user and device_id = :device and day = :day and source_rank = 2
group by activity_class order by seconds desc;

-- Every change of state with its time and confidence, for one day:
select start_at, display_context, confidence, duration_s
from public.activity_context_runs
where user_id = :user and device_id = :device and day = :day and source_rank = 2
order by start_ts;

-- Which days have a stream document, and how complete is each?
select day, observed_s, run_count, event_count, computed_at
from public.activity_context_days
where algorithm_version = 'streams-activity-1' and user_id = :user
order by day desc;
```

#### Where the data lives

| Data | Store | Notes |
| --- | --- | --- |
| Raw strap batches, per-sample heart rate, gravity, steps, events, RR, skin temperature, sleep sessions, workouts, scoring snapshots | Backblaze B2 (objects) and Supabase Postgres (typed tables, indexed by timestamp) | Ingest writes both; the object manifest ties them together |
| Raw IMU sessions | Backblaze B2 only | NPB1 objects, verified by digest; only sessions the phone chose to upload |
| ActivityContext v2 day documents (runs, events, confidence, uncertainty, provenance) | Supabase Postgres only (`activity_context_days`) | There is no B2 copy; the table is the store of record |
| v1 30-second epochs (raw-IMU days) | Supabase Postgres (`activity_context_epochs`) | |
| HART per-window output (raw-IMU days) | Supabase Postgres (`activity_encoder_windows`) | One `hart-windows-1` document per UTC day; regenerable from the raw IMU objects |
| Phone-built documents | The phone only | They are never uploaded; the server rebuilds the same document from the stored streams |

## Physiology context (off by default)

The context lane attaches measurement conditions, recent history, exposures and responses to the published
measurements (series points and nightly snapshot values) and stores one context document per device-day and mode
(`causal_live` for the owner's today, `retrospective` for closed days). It is off unless `FRWHOOP_CONTEXT_ENABLED=1`;
`context` in `FRWHOOP_DISABLE_LANES` also turns it off. It reads published products and raw streams and writes only
its own tables through fenced RPCs, so it never re-dirties scoring and a context failure never blocks scoring,
series, BLE or uploads.

- Migration `20261006050000_physiology_context.sql`: `physiology_context_jobs` (queue, enqueued from scoring
  completions by fingerprint), `physiology_context_days` (one immutable row per published revision; the summary
  document), `physiology_context_envelope_tables` (one interned envelope table per metric), current
  `physiology_context_daily_values` / `_bouts` / `_episodes`, insert-only `physiology_context_frozen_references`, and
  `exposure_event_revisions` / `exposure_events`. All service-role RPCs; owners can read only their own rows.
- Invalidation: scoring completions (D−1..D+1), placement changes, exposure revisions (`[start − 24 h, end + 72 h]`)
  and a `history_changed` cascade over the next 28 retrospective days. A policy change does not reprocess history by
  itself; see `docs/physiology-context/rollout.md`.
- Routes: `GET /scores/context`, `GET /scores/context/history`, `GET`/`POST /scores/exposures` (table above).

Design, methods, validation and rollout: [`docs/physiology-context/`](physiology-context/).

## Metric insights (off until the worker is deployed)

The explanation card on a key metric's detail screen (resting heart rate; HRV is supported server-side but its
screen is not switched on). The app draws the value and the chart from its own data; the card is optional, so a
missing or failed explanation never affects the rest of the screen.

- Migration `20261008000000_metric_insights.sql`: `metric_insight_jobs` (queue, one row per owner and metric) and
  `metric_insights` (one immutable row per published analysis; owners can read only their own). An analysis is keyed
  by an inputs fingerprint (the metric's 90 measured days, its own context comparisons and episodes, exposures around
  the latest night, coach memory). `POST /scores/insights` calls `metric_insight_request_v1`: unchanged inputs are
  served from the cache with no work queued; changed inputs queue the worker and the previous explanation is served
  marked stale. Bounded to 8 analyses per owner, metric and UTC day; 3 failures dead-letter the inputs until they change.
- Worker: `Tools/MetricInsight` (`deploy/frwhoop-metric-insight.service`). Prime Agent reasons over owner-scoped
  tools in a per-job sandbox; every number it states must come from the tools, and a validator gates what is
  published. Architecture, isolation and memory: [`Tools/MetricInsight/README.md`](../Tools/MetricInsight/README.md).
- Nothing is queued until the worker is running: requests then return `pending`, and the app shows "Explanation
  unavailable right now" after its bounded wait.

## Health checks

Run these with `psql` against the database. All of them are read-only.

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

-- Which device feeds each day of one owner's baselines, and which metrics did it contribute?
select day, source_device_id, hrv_rmssd_ms is not null as hrv, resting_hr_bpm is not null as rhr,
       resp_rate_bpm is not null as resp, skin_temp_c is not null as skin
from server_daily_scores
where user_id = '<owner uuid>' and algorithm_version = 'frwhoop-server-1' order by day desc limit 14;

-- Is the intraday series fresh? Filter on user_id first: the table holds a row per bucket.
select metric, count(*) as buckets, max(bucket_start) as latest_bucket, max(computed_at) as latest_write
from server_metric_series
where user_id = '<owner uuid>' and bucket_start > now() - interval '24 hours'
group by metric order by metric;

-- Are heart-rate seconds being refused? New rows per hour should stay at 0 while phones run the ledger
-- build (the first query), and a worn, connected strap should reach close to 3,600 seconds an hour.
select date_trunc('hour', detected_at) as hour, count(*) as refused_seconds
from noop_projection_conflicts
where user_id = '<owner uuid>' and stream = 'hrSample' and detected_at > now() - interval '24 hours'
group by 1 order by 1;
select date_trunc('hour', to_timestamp(ts)) as hour, count(*) as seconds
from noop_hr_samples
where user_id = '<owner uuid>' and ts > extract(epoch from now() - interval '12 hours')
group by 1 order by 1;

-- Series counters since the worker started. series_failed should stay at 0; series_skipped counts days
-- whose canonical device was another one.
select l->'counters'->>'series_published' as published, l->'counters'->>'series_rows_written' as rows_written,
       l->'counters'->>'series_skipped' as skipped, l->'counters'->>'series_failed' as failed
from (select meta from scoring_service_heartbeats order by last_poll_at desc limit 1) h,
     jsonb_array_elements(h.meta->'lanes') l
where l->>'name' = 'scoring';
```

For upload errors, check the `push` function's logs in the Supabase dashboard, or query
`function_edge_logs` for responses with status 500.

## Known issues

- **Uploads wait for a scoring pass.** The scoring pass holds the owner's scoring-input gate for its whole
  computation (about 7 seconds) so that no upload can change the inputs under it; an upload that arrives
  meanwhile waits, and one that arrives in the first second or so exceeds the API's 8 second statement
  timeout and is retried by the app (about 1% of uploads). Letting `publish_scoring_snapshot_v2` accept a
  revision that moved on, and leave the job dirty for the next pass, would remove the wait, but changes the
  fenced publication contract and has not been done. Migration `20260930231500` still stops the worker from
  re-claiming a day within two minutes of its last claim, and `20261002123000` shortens that to 45 seconds;
  the cooldown only starts when a pass commits.
- **Heart-rate seconds the receiver removed before 2 October 2026.** `noop_project_append_batch` keeps one
  bpm per (device, second). When a second arrives again with a different bpm it writes the key to
  `noop_projection_conflicts`, deletes the row it holds and refuses that second from then on. Earlier
  builds offered the same second twice with different values: the live 0x2A37 notification and the
  history offload (the offload carries every second the live stream already did, and its bpm matched in
  about a quarter of them), and now and then two live notifications in one second. On the account checked,
  51,838 seconds (about 14 hours, 30 September to 2 October) were removed that way, so the server held 37%
  to 64% of each day's seconds while the phone held all of them. Only heart rate was affected: R-R, motion,
  skin temperature, steps, sleep state and battery rows were complete. `CloudHeartRateLedger` stops new
  conflicts. The removed seconds are still in `noop_projection_observations`; restoring them means
  re-inserting each key's first observation into `noop_hr_samples` and deleting its marker, which marks the
  affected days for scoring again. That repair has not been run. Changing the receiver to keep the first
  value instead of deleting both would also stop the problem, but it relaxes a deliberate rule (a
  contradiction is recorded, never silently resolved) and has not been done.
- **Old projection debt.** About 16,000 `noop_projection_debt` rows from 12–20 September, from other
  test devices, fail replay and are left unprocessed while the projection lane is off. Clearing or
  dead-lettering them would let the lane run again.
- **Verify lane mismatches.** The verify lane logs digest mismatches for some older objects.
- **One other device fails a check constraint** on upload. It is not this app's install.
- **Baselines come from one `server_daily_scores` row per owner and day.** The v2 projection fills it
  from the device whose latest snapshot holds the most for that day (`selected_scoring_device_v2`: status,
  then scored metrics, then serial-scoped over installation-scoped, then heart-rate coverage), so a strap
  that was re-paired under a new install keeps its earlier nights in the baseline. A row in
  `scoring_source_preferences_v2` overrides this for every day, including days that device never scored,
  so do not use it to consolidate history. The legacy lane still upserts the same row for whichever device
  it claimed, so a late upload from a stale install can replace a better row until the v2 lane next
  refreshes that day. `reproject_scoring_legacy_v2(user, version)` rebuilds the rows from the stored
  snapshots (derived rows only, safe to repeat); `20261001190000_baseline_device_selection.sql` runs it
  once.
- **Recovery** stays at "Calibrating" until a device has four nights of data.
- **Blood oxygen** is a strap estimate, not a measurement, and exists only for the night. The WHOOP 5.0/MG
  history carries one SpO₂ byte per record (`@82` of the v18 record), but the strap fills it only while the
  wearer is asleep and still: about 400 to 500 in-band readings (70 to 100) a night and none by day. Whether
  those bytes are calibrated percentages is not established (the validity evidence disagrees), so they are
  never published as `spo2Pct` and never feed a score. The phone sends each reading as a `SPO2_STRAP_EST`
  event (`{"pct":97}`), the worker averages them per night into `spo2_candidate_pct` and
  `spo2_candidate_samples` in the day's snapshot (`coverage.spo2StrapEstimate` records how many arrived), and
  the app shows the number as "strap estimate (unverified)" (`PuffinExperiment.spo2CandidateDisplayEnabled`,
  on by default).
- **PPG is not continuous and is not uploaded.** The strap sends one 24 Hz waveform window of about 40 s
  roughly every 20 minutes (about 70 windows, or 2,800 one-second records, a day on the phone checked on
  2 October 2026). The phone keeps them in its own database; `CloudCapture` has no stream for the waveform
  or for the PPG-derived heart rate, the server has never held a `noop_ppg_hr_samples` row, and the hosted
  compute policy lists `ppg_hr` as `unqualified` (`optical_clock_channel_unqualified`). The only continuous
  signals are heart rate and R-R, at about 1 Hz over BLE. The Test Centre "Legacy R22 feature-flag
  experiment" has not been shown to make the strap send PPG continuously, the app does not store the
  larger optical records it might produce (only the opt-in `PuffinDeepBufferLog` keeps raw frames), and its
  sixteen writes include `disable_pip_r26_packets`, so it could reduce the windows above instead. It is
  left off.
