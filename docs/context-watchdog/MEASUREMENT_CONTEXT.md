# Measurement context per minute

One row per (user, device, UTC minute) that says what was measured, how good it was, what the person was doing,
where in their day it fell, and why anything is missing. Built on the server from stored rows only; directly
observed facts are kept apart from inferred estimates, and every inferred group carries its basis.

- Migrations: `supabase/migrations/20261009130000_reason_codes.sql` (canonical reason registry),
  `20261009130100_measurement_context_minutes.sql` (table, builder, pg_cron, backfill, read),
  `20261009130200_measurement_context_quality_minutes.sql` (the phone's optical evidence).
- Edge: `supabase/functions/_shared/measurementContext.ts`, routes in `_shared/serverScores.ts`
  (`GET scores/context-minutes`, `POST scores/quality-minutes`), reasons in `_shared/reasonCodes.ts`.
- Tests: `supabase/tests/measurement_context_minutes.sql`, `supabase/tests/measurement_context_quality_minutes.sql`
  (both run by `supabase/functions/tests/measurement_context_sql_test.ts` on the pipeline database),
  `tests/measurement_context_route_test.ts`, `tests/reason_codes_parity_test.ts`.

## The row (`public.measurement_context_minutes`)

Key: `user_id`, `device_id` (the strap the raw rows are stored under), `minute_start` (UTC, minute aligned).

| Group | Columns | Source |
| --- | --- | --- |
| Local time | `local_day`, `utc_offset_s`, `tz_basis` (`timezone_history` / `profile` / `default_utc`) | zone in effect at the minute: `scoring_timezone_history`, else `profiles.timezone`, else UTC; DST days have 23 / 25 local hours |
| OBSERVED | `hr_n`, `hr_mean`, `hr_min`, `hr_max` | `noop_hr_samples` |
| | `rr_n`, `rr_suspect_n` | `noop_rr_intervals` (`tsSuspect <> 0`) |
| | `dyn_n`, `dyn_mean`, `dyn_p90` (g) | `noop_gravity_samples.dynAccel` |
| | `steps_n`, `step_walk_n`, `step_run_n` | `noop_step_samples` and the strap's step class (1 walk, 2 run) |
| | `skin_temp_n`, `skin_temp_mean` (°C) | `noop_skin_temp_samples`; converted only for WHOOP 5/MG centidegree rows (raw 2500..4500), a WHOOP 4 raw ADC row is counted, not converted |
| | `band_sleep_state` | the strap's own modal sleep state (2 = asleep) |
| | `wrist_event` (`on` / `off` / `on_off`) | WRIST_ON / WRIST_OFF events inside the minute |
| | `contact_state` (`unsupported` / `detected` / `not_detected`) | STANDARD_HR_CONTACT, carried forward (24 h) |
| | `ble_link_down_s` | seconds inside BLE_CONNECTION_DOWN .. next link event |
| | `reset_event`, `saturation_event` | BOOT / RTC_LOST / BLE_SYSTEM_RESET; CH1/CH2/ACCEL saturation, AFE_RESET |
| | `charging` | newest of a CHARGING_ON/OFF edge (24 h) and a battery row's charging bit (60 min); NULL when nothing says |
| | `observed_s`, `max_ingested_at` | seconds with HR or motion; newest `ingested_at` of any contributing row |
| PHONE | `v18_n`, `sentinel_n`, `baseline_max`, `record_gap`, `hr_grade`, `beats_grade`, `phone_reasons`, `phone_quality_version` | only `POST scores/quality-minutes`; NULL until the phone sends them |
| DERIVED | `quality_class` (`good` / `fair` / `poor` / `off_wrist` / `unknown`), `quality_conf`, `reasons` | rule `mcq-1` (below) |
| COPIED | `activity_class`, `activity_conf`, `posture`, `exertion`, `activity_basis`, `activity_ref` | current epoch lineage (`activity_context_epochs_current`, basis `activity_epoch`), else the day document's runs (`activity_context_runs`, basis `activity_run`), else NULL (basis `none`) |
| | `sleep_state` (`asleep` / `awake` / `in_bed`), `sleep_basis` | scored night (`server_sleep_nights`, frwhoop-server-1) holding the minute: its stage segments (`server_night_stages`) or just the period (`server_night`); outside a night NULL with `outside_server_night` (day scored) or `not_scored` |
| | `wear_state` (`on_wrist` / `off_wrist` / `charging`), `wear_basis` | `charging`, then wrist events (`wrist_event`; a WRIST_OFF closes at a later WRIST_ON or after 5 sustained minutes of HR, basis `hr_present`), then the epoch, then the run, then HR presence |
| | `placement`, `placement_basis` | the declared placement in effect at the minute's start, resolved for the strap by `internal.placement_intervals_for_device_v1` (20261009150100; declarations on the strap, its aliases and the installations provably bound to it, else the owner's device-less declaration): basis `declared_strap` / `declared_alias` / `declared_installation` / `declared_account`; NULL with `undeclared` when nothing is declared (`not_resolved` on rows built before 20261009150100) |
| SESSION | `session_phase` (`none` / `session` / `recovery` / `active`), `session_start`, `session_rule`, `session_basis` | rule `exercise-session-2` (below); `session_basis = logged` inside a logged workout |
| LOGGED | `workout_type` (catalogue id, `workout-types-1`), `workout_basis` (`user_workout` / `manual_session`) | the workout the wearer logged that holds the minute's midpoint (`internal.measurement_context_logged_workouts_v1` → `internal.logged_workouts_v1`, [WORKOUTS.md](WORKOUTS.md)); its attributes are in `public.workout_types`; NULL outside one |
| COMPLETE | `missing_reasons` | why the minute has no HR, `context_unknown` when activity or the session phase is unknown, and `context_not_comparable` (`in_session` / `recovery` / `movement`) for a session / recovery / active minute |
| VERSION | `context_version`, `revision`, `computed_at` | `measurement_context_versions`; `revision` is a sequence value bumped only when the row's content changes |

Reasons (`reasons`, `missing_reasons`) are JSON arrays of `{code, certainty}` (plus `subcode` where the code has
one), codes from `contracts/reason-codes.json` (`data-reason-1`, SQL `public.reason_codes`). Unknown stays unknown:
nothing is fabricated to fill a gap (no activity is guessed, no sleep state outside a scored night, no placement that was not declared).

### Quality rule `mcq-1` (`internal.measurement_context_quality_v1`)

First match, from the row's own columns. Without the phone's evidence the server cannot see optics, so a still
minute is `good` only when beat timing is present.

| Condition | Class, conf | Reason |
| --- | --- | --- |
| charging | off_wrist 1.0 | charging (confirmed) |
| wear off_wrist from a wrist event | off_wrist 1.0 | off_wrist (confirmed) |
| phone `record_gap = paused` | off_wrist 0.8 | strap_not_recording (confirmed) |
| no HR, wear off_wrist from a classifier | off_wrist 0.6 | off_wrist (inferred) |
| < 30 s of HR | unknown | strap_reset (confirmed, with a reset event), insufficient_coverage (measured), records_missing (measured, phone `record_gap = lost`) |
| saturation event | poor 0.9 | optical_saturation (confirmed) |
| phone `hr_grade = poor` | poor 0.8 | |
| moving (dyn ≥ 0.05 g, or walk/run on ≥ half the step samples) | fair 0.6 | hr_in_motion_unverified (inferred): never good in motion |
| phone `hr_grade = degraded` / `good` | fair 0.7 / good 0.9 | |
| R-R count ≥ 0.5 × mean bpm | good 0.6 | |
| otherwise | fair 0.5 | insufficient_coverage (measured) |

The phone's `reasons` (legacy `watchdog_quality` codes) follow, mapped through `public.reason_code_legacy`
(e.g. `motion_mode_optics` → motion_artifact inferred), one entry per code. A code the table does not know is kept
in `phone_reasons` as sent and left out of `reasons`.

### Missing reasons

For a minute without heart rate, the first that applies: charging (confirmed), off_wrist (confirmed from an
event, else inferred), strap_not_recording (phone: paused), strap_link_down (confirmed by BLE events), records_missing (measured: the
phone saw the strap's record index skip — lost in transfer, may never arrive), awaiting_upload (inferred: no HR has been
uploaded at or after this minute; never in a backfill),
sensor_dropout (inferred: believed worn), insufficient_coverage (measured). Plus context_unknown (unknown) when no
activity lineage covers the minute or its session phase is unknown, then, for a minute inside a session, its recovery
or an active period, context_not_comparable (inferred) with subcode `in_session`, `recovery` or `movement`: the
reading is not comparable with a rest reference.

### Rule `exercise-session-2`

`docs/context-watchdog/EXERCISE_SESSION.md`; the SQL port `internal.exercise_session_spans_v2` reproduces every case
of `contracts/reference/exercise-session-2.json` (start, end, recovery end, pre-session reference, `confirmed`,
`confirmed_at`). Evidence per minute (never heart rate; never asleep or off the wrist): strong = walk/run step
classes on at least half of the minute's step samples, dyn_mean ≥ 0.10 g, or a confident (≥ 0.6) epoch that is
walking / running, exertion `active` or inside a logged exercise; weak = dyn_mean ≥ 0.05 g. A HART `other_movement`
epoch is not evidence (it covers 27 % of gym minutes and 29 % of other awake minutes; rule -1 counted it as weak,
which stretched a non-gym period from 37 to 71 minutes); it only keeps the minute out of the still minutes of the
rest fallback. Weak counts only within 20 minutes of strong. The rest reference is the median nightly resting HR of
the 14 nights before the local day (60-day window, `server_daily_scores`) + 10 (`session_basis = sleep_resting_hr`),
else the median HR of still minutes in the 2 h before the period (`awake_still_median`), else 70 (`default_70`).

A minute inside a workout the wearer logged (workout mode) is strong evidence and never a still minute; while worn and
awake it is `session` with `session_basis = logged` and `session_start` the workout's start, whatever the rule found
(an observed label beats the inference), and a recovery the rule found after it stays. Logging, stopping or deleting a
workout re-queues the local days it touches (`user_workouts_upsert_v1`).

A period that meets the four session conditions is *confirmed* once it holds 15 strong minutes, or when it starts at
most 30 minutes after the last evidence minute of the previous confirmed session (inheritance only runs forward).
A confirmed session's minutes are `session`, followed by `recovery`. A period that meets the conditions but is not
confirmed is `active`: no recovery after it (the next minutes are judged as they are), its minutes are skipped by a
later session's pre-session reference, and it still ends the recovery of a confirmed session before it.

The server runs the rule in batch mode over 6 h before and 4 h after the minutes it writes, on the data stored so far,
and rebuilds as data arrives: each queued local day (an upload, new scores, a newer activity document) is rebuilt
whole, `[00:00 − 3 h, 24:00)`, and only rows whose content changed are rewritten (with a new `revision`). So a
period still growing appears once it has lasted 12 minutes, as `active` while it holds fewer than 15 strong minutes
(and inherits nothing), and its rows become `session` (with the recovery after it) on the first rebuild after the
15th strong minute is stored; once the period has ended the rows match the batch answer over the whole period.
`session_phase` is NULL when the minute had no motion evidence at all (no IMU, no steps, no epoch) and is not inside
a session, a recovery or an active period.

## Versions (`public.measurement_context_versions`)

`(id, builder_version, rule_ids, reason_codes_version, backfill, notes, created_at)`. Two rows today:
`mcm-1 / {exercise-session-2, mcq-1} / data-reason-1` live and the same with `backfill = true`. A row keeps the
version that last changed its content. Any threshold change is a new builder version or rule id.

## Write paths (all service-only; no trigger on any `noop_*` table; the scoring lock is never taken)

- `internal.build_measurement_context_minutes(user, device, from, to)`: rebuilds the completed minutes of
  `[from, to)` (at most 3 days) from stored rows, writes only rows whose content changed. One builder per
  (user, device) at a time (advisory transaction lock `measurement-context:<user>:<device>`). A heavy synthetic day
  (1 Hz HR, motion and R-R, a contact row every 2 s) builds in ~0.35 s on the pipeline database; a rebuild that
  changes nothing takes about as long and writes nothing.
- pg_cron `frwhoop-measurement-context`, every 5 minutes: `internal.measurement_context_tick_v1()` queues on
  `internal.measurement_context_work` the local days whose scoring inputs (an upload) or scoring results (nights,
  daily scores) changed, or whose activity documents were published, in the last 2 days (`scoring_jobs_v2`,
  `activity_context_days`, read without locks), then builds at most 12 queued days, oldest first,
  `FOR UPDATE SKIP LOCKED`, within 40 s. Each day rebuilds local `[00:00 − 3 h, 24:00)`. A failing day backs off
  (1 h doubling to 1 day) with its error kept in `last_error`.
- `internal.backfill_measurement_context_minutes(user, device, from_day, to_day)`: up to 31 local days per call,
  oldest first, from stored rows only; rows tagged with the backfill version; awaiting_upload is never asserted;
  phone columns stay NULL unless already stored. Run by an operator as `postgres`.
- `POST scores/quality-minutes` (below): the only writer of the PHONE columns.

## Read path: `GET scores/context-minutes?from=<unix>&to=<unix>[&deviceId=<id>]`

Same credential as every score route; the owner is the credential's, the device the caller's own (or every device of
the owner when `deviceId` is absent). `[from, to)` at most 1440 minutes. Response:

```json
{"rows": [{"minute_start": 1789999980, "device_id": "…", "local_day": "2026-09-14", "utc_offset_s": -25200,
           "hr_n": 60, "quality_class": "fair", "quality_conf": 0.6,
           "reasons": [{"code": "hr_in_motion_unverified", "certainty": "inferred", "effect": "degraded", "family": "motion"}],
           "session_phase": "session", "session_start": 1789999980, "…": "…"}],
 "versions": {"1": {"builder_version": "mcm-1", "rule_ids": ["exercise-session-2", "mcq-1"],
                    "reason_codes_version": "data-reason-1", "backfill": false}},
 "truncated": false, "identity": {"…": "…"}}
```

Rows are oldest first, at most 1440 (`truncated` says more matched); every column of the row except `user_id`;
reasons carry their `effect` and `family` from `public.reason_codes`. 400 `invalid_range` / `invalid_device_id`,
409 `device_registration_pending`.

## Phone payload: `POST scores/quality-minutes`

```json
{"device_id": "<the strap's device id, resolved like every other route (aliases ok)>",
 "version": "phone-quality-1",
 "minutes": [{"minute_start": 1791345900, "v18_n": 60, "sentinel_n": 12, "baseline_max": 31,
              "record_gap": null, "hr_grade": "good", "beats_grade": "degraded",
              "reasons": ["motion_mode_optics"]}]}
```

| Field | Rule |
| --- | --- |
| `device_id` | required; the caller's own device |
| `version` | required; `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`; stored as `phone_quality_version` |
| `minutes` | 1..1440 objects; distinct `minute_start`; span (max − min) under 3 days |
| `minute_start` | required; unix seconds, multiple of 60, from 2020-01-01, at most 2 minutes ahead of the server clock |
| `v18_n`, `sentinel_n` | null or integer 0..120, `sentinel_n ≤ v18_n` |
| `baseline_max` | null or integer 0..65535 |
| `record_gap` | null, `paused` (record index stepped by one: the strap stopped recording) or `lost` (index stepped with time: lost in transport) |
| `hr_grade`, `beats_grade` | null, `good`, `degraded`, `poor`, `unknown` |
| `reasons` | null or up to 32 legacy `watchdog_quality` codes (`^[a-z][a-z0-9_]{0,63}$`) |

Every field but `minute_start` may be null or absent; unknown fields are ignored. Response 200
`{"accepted": n, "changed": k}`: `accepted` counts the minutes stored (a minute that has not ended yet is not), `changed`
the minutes whose evidence differed from what was stored. Idempotent: the same payload again is
`{"accepted": n, "changed": 0}` and bumps no revision. 400 `{"error": code}` with `invalid_body`, `invalid_version`,
`invalid_minutes`, `invalid_minute`, `duplicate_minute`, `invalid_range` or `invalid_device_id`; 409
`device_registration_pending`; 413 `payload_too_large` above 512 KiB. A minute with no row yet is built first; after
the phone's columns change, the builder re-derives `quality_class`, `reasons` and `missing_reasons` for those minutes.

## Size

Measured on the pipeline database (Postgres 17.6, heavy synthetic day, every minute with a reason and a missing
reason): 408 bytes per row on average, 704 KiB heap + 224 KiB primary key and revision index for 1,620 rows, i.e.
**≈ 0.86 MB per user-device-day** (≈ 0.31 GB per user-device-year). The two reason arrays are about a third of a row
(73 + 64 bytes); a minute whose activity is known and HR present carries an empty `missing_reasons`, so real days
should land nearer 0.7 MB. If that is too much: monthly range partitions on `minute_start` (detach / archive old
months) and coded enums for the `*_basis` columns are the next steps; neither changes the contract above.

## Deploy (not executed)

1. Apply, in order, as `postgres` with `psql -1`: `20261009130000_reason_codes.sql`,
   `20261009130100_measurement_context_minutes.sql`, `20261009130200_measurement_context_quality_minutes.sql`
   (each is re-runnable). The second schedules `frwhoop-measurement-context` (`*/5 * * * *`).
2. Deploy the `scores` function.
3. Optional backfill per device, a month at a time:
   `select internal.backfill_measurement_context_minutes('<user>', '<device>', '<from_day>', '<to_day>');`
4. Watch `internal.measurement_context_work` (`last_error`, `attempts`) and `cron.job_run_details` for the job.

Rollback: `select cron.unschedule('frwhoop-measurement-context')`, drop the functions and tables named in the
migration headers; nothing else depends on them.
