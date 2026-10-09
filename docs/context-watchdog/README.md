# Context-aware Watchdog, signal quality, measurement context, sync and Sana memory (2026-10-09)

Branch `feat/context-watchdog-integration-20261009`, cut from `integration/seven-branches-20261008` @ 0a3cea5ab — the line
the owner's phone (Nara 11.8.0 / 431 from dbd6f1c7a) and production run. Nothing here is pushed, merged into `main` or
deployed. The audits behind it are in `_build-scratch/ctxwd/{A..F}-*/REPORT.md` on the Untitled drive (not committed:
they quote production values).

Contents: 1 what was wrong · 2 what changed · 3 how it was verified · 4 deploy order · 5 limits and owner decisions.
Contracts: [EXERCISE_SESSION.md](EXERCISE_SESSION.md) (rule `exercise-session-2`), [MEASUREMENT_CONTEXT.md](MEASUREMENT_CONTEXT.md)
(per-minute record), [WATCHDOG_EPISODES.md](WATCHDOG_EPISODES.md) (alarm lineage), [WORKOUTS.md](WORKOUTS.md) (workout
mode, catalogue `workout-types-1`), `contracts/reason-codes.json` (one reason vocabulary, `data-reason-1`).

## 1. What was wrong (audit, with the owner's own data)

**Gym alarms.** The owner trains most evenings (production HR, 09-20 → 10-09: 12 weekday sessions starting 21:13–22:12,
5 weekend sessions at ~18:45; median 80 min, HR p50 108 / p90 132 / max ~150–160). The severe pushes on 10-06 21:05,
10-07 21:07 and 10-07 22:54 came from the pre-v2 Watchdog (`watchdog-v2.5`, on-device student model) in the builds of
those days. The current v3.1 build is quiet at the gym, but for the wrong reasons:

- lifting reads as *still* to the strap (worn on the upper arm): the decoder labels 30–35 minutes of every session
  stationary / sitting / standing, 10–17 of them above 100 bpm, so those minutes were judged against seated rest;
- the strap's motion-mode optics (optical amplitude marker on ~96 % of the most active seconds) made 99 % of gym
  minutes "poor / artifact", which turned the effort into *unknown* context instead of exertion;
- every personal reference was still learning (sleep HR ≈ 10-21, awake rest ≈ 10-26), and once established any
  ≥ 0.05 g minute would have muted the HR check for 30 minutes — 92 % of still minutes;
- no session or recovery concept: post-gym tails leaked into rest references in three places (phone Layer 1: 16.9 min
  at 84.5 bpm into one day's awake rest; server physiology context: "stable rest" at 86–91 bpm 1.5 h after a bout;
  anomaly service: the 10-07 23:30 PDT window scored as rest with the highest UniTS rest score);
- posture strata never filled (a stationary interval with unknown posture reset the settle clock every 1–2 minutes).

**Signal quality.** Off-wrist is directly observable on the 5/MG (WRIST_OFF/ON, and no history records while off — the
record index steps by exactly 1). Contact quality per reading cannot be validated: there is no reference (chest strap,
deliberate loose-strap capture), the standard contact bit reads "unsupported", and the optical amplitude marker is a
motion-mode marker that predicts missing beats (P(no R-R) 0.92 vs 0.25), not wrong bpm.

**Metadata.** Raw rows carried value, time, device and batch only; context lived in four incompatible shapes; daily
values linked to sources only implicitly; anomaly outputs had no model version or input fingerprint; per-minute quality
was stored nowhere and the phone's v18 quality bytes were never uploaded. Defects: every-second "contact unsupported"
upload (~95 % of the owner's event rows), fill-beat flag lost on upload, the owner's *bicep* placement stored on
installation ids instead of the strap, so every server lane read placement as unknown.

**Reasons.** Certainty inverted in copy (an inferred gap read "the strap disconnected"; an event-confirmed strap-off read
"may not have been worn"); one code meant two causes (`artifact_unavailable`); stale Layer 1 data read "Weak signal".

**Sync / memory.** Sync was an opt-in switch (and a reinstall with a kept Keychain session came back signed in with sync
off); the server had no notion of required sync and could not see silent accounts (2 of 7 never provisioned, 1 silent
for 2 days); the journal was never pruned; capture while sync was off was never replayed. Sana memories could not be
edited; retired memories reached metric insights; forgetting the automatic "Ask Sana" note did not stick.

## 2. What changed

**Exercise context (phone Watchdog, Layer 1, server).** Rule `exercise-session-2`: a session is opened by movement
(steps, dynamic acceleration, decoder walking/vigorous/exercise-arm intervals — never heart rate, never time of day),
qualified by load (≥ 8 min at rest + 25 bpm), keeps its still minutes (sets, leg work), and is followed by a recovery
that ends when HR returns or at a load-scaled cap. Weak movement counts only within 20 min of strong movement. A
session is confirmed at 15 strong minutes, or when it starts ≤ 30 min after a confirmed one; one that ends
unconfirmed is stored as `active` (movement: no recovery, no exercise-reference training, never rest). Live opening
does not wait for confirmation. HART `other_movement` is not evidence (as common outside the gym as in it). The
pretrained activity models are annotation only: they see the cardio part of a gym session, not the lifting, and
arrive too late to open a session (EXERCISE_SESSION.md, "Activity models").
One rule, four implementations pinned to one fixture (`contracts/reference/`): Swift (`ExerciseSession.swift`),
the anomaly service (Python), the measurement-context builder (SQL), and the reference (Python).

- Watchdog: session and recovery minutes are compared with the person's own `exercise_session_hr` /
  `exercise_recovery_hr` references (Layer 1, established after 8 session days; "learning" until then — no stand-in).
  Plain walking keeps the walking reference. The 30-minute post-movement mute is gone (2-minute settle after an
  isolated movement minute, 10 after a bout or walking). Safety bounds stay: the resting > 120 bpm rule tolerates
  up to two fidget minutes and applies to recovery from 15 minutes after the last movement; a new in-session ceiling
  (profile HR max + 5 for the age formula, own session peaks + 10 once 7 sessions exist, 200 bpm when unknown).
  A recurring routine (weekday/weekend × start time) is recorded for interpretation and display only.
- Quality: bpm and beat timing are graded separately; record-index continuity names "strap not recording" (off-body)
  apart from "records lost in transfer"; skin temperature settles 20 min after WRIST_ON.
- Layer 1: sessions and recovery never reach rest strata; posture bouts fixed; unconfirmed (`active`) periods never train exercise references and get the 10-minute settle (`lb-context-3`); the day tape files
  off-body / poor-signal minutes as unknown.
- Ledger: `safety` means a verified safety alert; delivery is recorded only for the episode notified; unavailable
  time counted per minute; the exercise snapshot is kept with each episode.
- Server: the anomaly service uses the user's time zone for candidate days, reads only the current activity lineage,
  never lets an epoch turn a moving minute into rest, and withholds session (`activity`) and recovery (`recovery`)
  windows; a helper lists (and on request purges) reference windows the new rules exclude. Physiology-context
  eligibility merges bouts into sessions for the post-exertion exclusion (`pc-eligibility-5`).

**Reasons.** `contracts/reason-codes.json` (31 codes; family, certainty, effect; legacy maps) mirrored in Swift
(`DataReason`), the edge (`reasonCodes.ts`), SQL (`public.reason_codes`, `internal.canonical_reason`) and Python, each
with a parity test. Copy states only what is known; `artifact_unavailable` split into `no_verified_input` /
`model_unavailable`; `unresolved_adjacency` kept as itself; not-yet-uploaded HR is `awaiting_upload`, never "sensor
dropout"; records lost in transfer are `records_missing`.

**Measurement context (server).** `measurement_context_minutes` (one row per user, strap and minute; ~0.7–0.9 MB per
user-day): observed counts kept apart from inferred context, each inferred field with its basis (`*_basis`), quality
class + canonical reasons with certainty, local time (DST-correct), session phase, completeness and missing reasons,
version and revision. Built by an idempotent SQL builder (pg_cron every 5 min, bounded), backfilled from stored data
only. Phone-only optical evidence arrives via `POST scores/quality-minutes`; the phone's alarm lineage via
`POST scores/watchdog-episodes`. Placement is resolved for the strap from declarations on the strap, its aliases and
provably bound installations; a declared upper arm is `placement_unsupported` (confirmed) for wrist-trained families.
`GET scores/anomaly-candidates` can return windows with canonical reasons and the context mix.

**Sync and durability.** Signed in means syncing (no switch while the server policy requires it; reinstall covered);
the server returns `syncPolicy` in provisioning, push capabilities and coach status, and `account_sync_health_v1` /
`my_sync_health_v1` find silent accounts ("Not syncing since …" in the app). Journal pruning, stuck/blocked batch
recovery, replay of capture missed while the runtime was down, source-rotation re-stamping, IMU never evicted before
upload (4 GiB hard ceiling), change-only contact upload, fill-beat flag uploaded.

**Sana memory.** `PATCH memories/<id>` (version-guarded, actor user) through the single writer; edits update every read
path (list, ranked, manifest, prompt) and every cached manifest on the phone; the curator never rewrites or resurrects a
user-edited memory; automatic notes respect forget/edit tombstones; retired memories no longer reach metric insights;
saved memories win over older chat history in the prompt. Edit and Add in the memory sheet.

## 3. Verification

Final run on the merged branch (2026-10-09, `_build-scratch/ctxwd/final/{app,server2}-summary.txt`):

| Suite | Result |
| --- | --- |
| iOS build (NOOPiOS, generic iOS) | succeeded |
| StrandAnalytics (`swift test --skip LongitudinalBaselineTests`; that class's fixtures were never committed) | 4041 tests, 0 failures, 12 skipped (base: 4022, 0) |
| WhoopStore | 687, 0 failures |
| StrandTests, macOS (internal-disk copy; `ActivityCalibrationSessionTests` skipped: it blocks on a Bluetooth permission prompt and fails on main anyway) | 3614, 1 failure = the known `IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets` |
| CloudWorker incl. database tests | 794, 0 failures, 4 skipped |
| Edge, database-gated suites on a fresh pipeline DB (production Postgres image, every migration) | all pass: reason-code parity, measurement context (SQL + route), watchdog episodes (SQL + route), placement resolution (SQL + routes), anomaly windows (SQL + route), account sync health, coach threads/memory (SQL, e2e, pipeline), metric insights, physiology context, exposure events, auth isolation |
| Edge, whole `tests/` directory | 507 passed, 10 failed, 31 ignored; the 10 failing files fail identically on the base commit (missing Swift fixture exports, coach_timezone, intake_deadline, production_append_compatibility, raw_auth_history_review) |
| Anomaly service | 36 passed, 5 skipped (database tests; 41/41 with `ANOMALY_TEST_DB` during integration) |

Behaviour, on synthetic and real data:

- Scenario table (`WatchdogV2ScenarioTests`, 18 scenarios): 0 false notifications; every expected alert detected —
  including HR 206 inside a session (5 min), failure to recover after the gym (23 min after the last movement), resting
  tachycardia with fidgets (10 min); gym sets with 12 minutes of still-arm leg work and a long cardio tail stay silent.
- Owner's real gym evenings 10-06…10-08 (`WatchdogGymReplayTests`, minute ticks, NARA_REPLAY_DIR): with the session
  context 0 notifications, 0 severe and 0 held minutes, both with today's references and with references established
  from his own data; the phone's current code (a checkout of 0a3cea5ab) holds 30 minutes of personal deviation on
  10-07 once references establish. Whole days 10-06 12:00 → 10-09 01:00 with established references: base 6 held
  ticks and 79 ticks of unknown context; new 0 held, 9 unknown. Sessions found: 10-06 to 23:22, 10-07 21:30 (history
  start) – 00:26, 10-08 21:30–21:59 and 22:11–00:59.
- Exercise-session parity: Swift, Python (anomaly service) and SQL reproduce all 8 fixture cases exactly.
- Anomaly service on the owner's minutes: the 10-07 23:30 PDT window production scored as rest is now `recovery`.

## 4. Deploy order (none executed; production is unchanged)

Production state checked read-only on 2026-10-09 ~04:20 PDT: newest migration 20261009030000; worker
`frwhoop-server-1` release e517e2c16 polling; anomaly service heartbeat fresh (calibrating, 0 candidates); cron jobs
succeed, retention-sweep's HTTP call still 500s (pre-existing).

1. Index outside a transaction: `create index concurrently if not exists noop_upload_receipts_source_device_idx on
   public.noop_upload_receipts (user_id, source_id, device_id, accepted_at);`
2. Migrations, each `psql -v ON_ERROR_STOP=1 -1 -f …` as `postgres`, recorded in `supabase_migrations.schema_migrations`:
   `20261009110000_account_sync_health` · `20261009120000_coach_memory_user_edits` ·
   `20261009120100_metric_insight_inputs_active_memories` · `20261009130000_reason_codes` ·
   `20261009130100_measurement_context_minutes` (schedules `frwhoop-measurement-context`, every 5 min) ·
   `20261009130200_measurement_context_quality_minutes` · `20261009140000_candidate_withheld_unresolved_adjacency`
   (before the new worker) · `20261009140100_anomaly_window_reason_codes` · `20261009150000_watchdog_episodes` ·
   `20261009150100_placement_device_resolution` · `20261009150200_anomaly_windows_read` ·
   `20261009160000_activity_exercise_windows` (RecGym shadow head; needs 20261008100600, already in production) ·
   `20261009170000_user_workouts` (workout mode: catalogue, `user_workouts`, `internal.logged_workouts_v1`; after
   130100, whose builder it feeds; WORKOUTS.md).
   Re-applying 20261007160000 or 20261008000000 later would restore the old coach/insight functions: re-apply the
   120000/120100 pair after them.
3. Edge functions: `scores` (now also `POST/GET scores/workouts`), `coach`, `push`
   (`supabase functions deploy <fn> --project-ref sgoyxzcagqyxexmsidtk`).
   No new secrets (`NOOP_SYNC_REQUIRED` defaults on, `NOOP_SYNC_STALE_AFTER_HOURS` 24).
4. Worker + sidecar release on frwhoop-worker-2 (`deploy/OPERATIONS.md`: package, install, build, switch, restart);
   the second instance 7d49ceba (revision 7f38ceef5, not in this repository) needs the same release if it runs these
   lanes. `deploy/provision.sh --sidecar-only` stages the RecGym checkpoint
   (`recgym/e085ac0e/wrist_-_imu_only_best.pt`, sha256 `7f0c4adf…51f5d9`). The RecGym head stays off unless
   `/etc/frwhoop/worker.env` sets `FRWHOOP_EXERCISE_ENABLED=1` with `FRWHOOP_EXERCISE_WEIGHTS_PATH`,
   `FRWHOOP_EXERCISE_WEIGHTS_SHA256` and `FRWHOOP_EXERCISE_MODEL_VERSION=recgym-cnn-transformer-e085ac0`
   (`Tools/ActivityContext/RECGYM.md`); it writes shadow rows only. MetricInsight worker (`sources.py`) on the VPS.
   The release reads workout mode's log (`LoggedWorkouts.swift`, `internal.logged_workouts_v1`): deploy it after
   20261009170000 (before it, the lane reads the session records alone, as today). No new worker settings.
5. Anomaly service on the VPS (`docs/BASELINE_WATCHDOG_V2.md` §5 "Context hygiene"): stop, back up state, install, list
   the reference windows the new rules exclude with `tools/reference_audit.py`, review, purge with `--apply`, start.
   This install also reads logged workouts (`features.logged_workouts`; none before 20261009170000), so a logged
   workout's windows are withheld as exercise. No new settings.
6. Phone build from this branch (set `NOOP_SOURCE_REVISION` to the real HEAD first). Old builds keep working against the
   new server (all additions are optional fields / new routes).
7. Optional owner repairs: `deploy/placement-rescope-strap.sql` (dry run, then `-v apply=1`; `-v copy=1` optional);
   `internal.backfill_measurement_context_minutes(owner, strap, '2026-09-29', today)`;
   `invalidate_physiology_context_span_v1` for 10-06…10-09 to re-derive with `pc-eligibility-5`.

## 5. Limits and owner decisions

- Contact quality is not validated: there is no reference recording. "Loose" is never shown; HR during movement is
  "unverified", not "poor". A chest-strap session and a deliberate loose-strap session would let it be validated.
- Personal exercise references need 8 session days; until then only safety bounds judge exercise minutes ("learning").
  The in-session ceiling uses the profile's HR max (owner: age 19 → 195 + 5) until 7 sessions exist.
- The session rule cannot tell a workout from other vigorous movement with high HR (e.g. stairs, a late-night walk);
  10-07 00:16–00:30 (HR up to 132, arm nearly still, within movement evidence) is treated as part of the session.
  Rule -2's confirmation (15 strong minutes) cuts stored non-gym sessions from 6 to 1 on the owner's data, with a thin
  margin (weakest gym session 19 strong minutes). A "Were you exercising?" confirmation would make sessions observed
  instead of inferred.
- No activity model detects lifting on the owner's upper arm: HART, ActiNet and ElderNet see the cardio part only
  (EXERCISE_SESSION.md, "Activity models"), and the RecGym CNN-Transformer, the one model trained on gym exercises,
  scores gym against daytime at AUC 0.53 (chance; movement alone does as well; RECGYM.md). All stay annotation or
  shadow only.
- Rhythm (DeepBeat/SiamAF) stays withheld until its sample clock is verified; no phone heuristic replaces it.
- The anomaly service still needs ~2 weeks of calibration (96 windows per model per bucket); activity windows are
  withheld with an explicit reason rather than scored against rest.
- Upper-arm wear: wrist-trained models (HART, ActiNet, ElderNet, ParaDigMa tremor) still run on bicep IMU; whether to
  withhold them is an owner decision. Arm swing is reported `placement_unsupported`.
- Owner decisions assumed: signed in ⇒ always syncing (sign-in stays optional; cellular allowed); unknown sync policy
  counts as required; user-edited memories are locked against curator rewording; automatic notes respect tombstones;
  windows touching any session/recovery minute are withheld by the anomaly service; placement binding from upload
  receipts with conservative time bounds.
