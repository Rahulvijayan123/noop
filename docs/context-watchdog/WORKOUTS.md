# Workout mode (catalogue `workout-types-1`)

The wearer tells Nara they are working out, and what kind of workout it is. The logged workout is an observed label,
not an inference: every pipeline that judges the strap's readings reads it, with the type's attributes, so an indoor
walk is expected to show steps and no route, a ride is expected to show no gait, and lifting with the arm still is
effort, not rest.

- Phone: `Strand/Screens/WorkoutModeSection.swift` (the strap screen: Today → Strap → Devices, section "Workout"),
  `Strand/Data/WorkoutModeStore.swift` (log, persistence, sync), `AppModel` (workout-mode actions on the live tracker),
  `Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutTypeCatalog.swift`, `WorkoutModeLog.swift`.
- Contract: `contracts/workout-types-1.json`, mirrored in Swift, `supabase/functions/_shared/workoutTypes.ts` and SQL
  `public.workout_types`, each pinned by a parity test.
- Server: `supabase/migrations/20261009170000_user_workouts.sql`, `supabase/functions/_shared/userWorkouts.ts`
  (`POST/GET scores/workouts`), the measurement-context builder (`20261009130100`), the worker
  (`Tools/CloudWorker/Sources/frwhoop-worker/LoggedWorkouts.swift`), the anomaly service (`features.py`).

## On the phone

Strap screen → Workout → **Start workout** → pick a type. While it runs the section shows the type, the elapsed time,
**Change type** and **Stop workout**; **Log a past workout** takes a type, a start and an end (at most 12 h, no overlap,
never in the future). The last three logged workouts are listed (long-press to delete).

- Starting runs the existing live tracker (`AppModel.startWorkout`) under the type's stored sport name, so heart rate,
  Effort, calories and (for an outdoor type) the route are recorded exactly as before, and Stop saves the usual
  workout row. The log adds the type. A live session started anywhere else (the Live screen) is logged too, typed
  from its sport name (`WorkoutTypeCatalog.resolve`), or `other`.
- One workout at a time. A running workout survives a relaunch (the log is JSON in `UserDefaults`, like the live
  tracker's own snapshot). A stop under a minute deletes it (an accidental start). A workout still running after
  4 hours is closed at the 4-hour mark and flagged `auto_ended`, checked on relaunch, on the strap screen and on
  every Watchdog tick.
- Change type keeps the live session's route setting from the first type.
- A past workout is context only: no heart-rate scoring and no row in the Workouts list.
- Offline first: every edit (start, change type, stop, delete, auto-end) bumps the entry's clock and stays pending
  until `POST scores/workouts` accepts it; a user action sends at once, the Watchdog tick retries every minute.
  Synced entries leave the phone 30 days after they end.

## Catalogue

| id | name | stored sport | decoder kind | environment | locomotion | effort | gait expected | arm | steps |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| strength | Strength training | Strength | other | either | none | resistance | no | varied | no |
| hiit | HIIT / circuit | HIIT | other | either | mixed | vigorous | no | varied | yes |
| indoor_walk | Indoor walk (treadmill) | Treadmill walk | walking | indoor | walking | moderate | yes | varied | yes |
| outdoor_walk | Outdoor walk | Walking | walking | outdoor | walking | moderate | yes | swing | yes |
| indoor_run | Indoor run (treadmill) | Treadmill run | running | indoor | running | vigorous | yes | varied | yes |
| outdoor_run | Outdoor run | Running | running | outdoor | running | vigorous | yes | swing | yes |
| indoor_cycling | Indoor cycling | Indoor cycle | cycling | indoor | cycling | moderate | no | fixed | no |
| outdoor_cycling | Outdoor cycling | Cycling | cycling | outdoor | cycling | moderate | no | fixed | no |
| rowing | Rowing / erg | Row machine | other | either | none | vigorous | no | varied | no |
| elliptical | Elliptical | Elliptical | other | indoor | none | moderate | no | varied | no |
| stair_climber | Stair climber | Stair climber | other | indoor | walking | vigorous | yes | varied | yes |
| swimming | Swimming | Pool swim | other | either | none | vigorous | no | varied | no |
| yoga | Yoga | Yoga | other | either | none | light | no | varied | no |
| pilates | Pilates | Pilates | other | either | none | moderate | no | varied | no |
| stretching | Stretching / mobility | Stretching | other | either | none | light | no | varied | no |
| sports | Sports (team / racket) | Sports | other | either | mixed | vigorous | yes | varied | yes |
| hiking | Hiking | Hiking | walking | outdoor | walking | moderate | yes | swing | yes |
| dance | Dance | Dancing | other | either | mixed | moderate | no | varied | yes |
| martial_arts | Martial arts / boxing | Martial arts | other | either | mixed | vigorous | no | varied | no |
| other | Other | Other | other | either | mixed | moderate | no | varied | no |

`arm`: swing = free arm swing; fixed = hands on bars or handles; varied = changes through the workout, or handrails
may be held (treadmill). The stored sport is a WorkoutCatalog name (cross-platform data), and the decoder already
reads a workout's kind from it (`WorkoutKind(sport:)`): the catalogue maps onto that reading instead of adding a
parallel one, and `WorkoutTypeCatalogTests` pins `WorkoutKind(sport: sport_name) == decoder_kind` for every type.
Each type also lists the other WorkoutCatalog names it stands for (`sport_aliases`, e.g. Tennis → sports), so a manual
or imported row resolves to a type the same way on the phone and the server (`internal.workout_type_for_sport`).
Ids are never renamed or removed; a change is `workout-types-2`.

## Storage

`public.user_workouts`, one row per (owner, `client_id`):

| Column | |
| --- | --- |
| `user_id`, `client_id` | key; `client_id` is the phone's UUID (idempotency) |
| `device_id` | the canonical strap device the scores route resolves (findNoopDevice), FK with the owner to `devices` |
| `local_device_id`, `source_id` | the phone's own id for the strap; the installation that sent this version |
| `workout_type`, `catalogue_version` | FK to `public.workout_types` (its attributes); `workout-types-1` |
| `started_at`, `ended_at` | `ended_at` NULL while running; at most 24 h |
| `source` | `manual` (the wearer stopped it or logged it afterwards) or `auto_ended` (the 4-hour cap, or closed by a later workout) |
| `notes` | optional, ≤ 500 characters |
| `deleted_at` | soft delete |
| `client_updated_at`, `created_at`, `updated_at` | last writer wins on the phone's clock |

RLS: the owner selects their own rows; only `service_role` writes (through the route). `public.workout_types` is
readable by every signed-in account.

`POST scores/workouts` (installation credential; owner and installation from it):

```json
{"device_id": "whoop-<serial>", "local_device_id": "my-whoop", "catalogue_version": "workout-types-1",
 "workouts": [{"client_id": "<uuid>", "type": "indoor_walk", "started_at": 1790305200, "ended_at": null,
               "source": "manual", "deleted": false, "notes": null, "client_updated_at": 1790305200}]}
```

1..50 workouts, each ≤ 4 KiB; a batch with a problem is refused whole (`invalid_workout_type`, `invalid_workout_times`,
`duplicate_client_id`, …; 413 `workout_too_large`; 409 `device_registration_pending`). Response
`{"accepted", "skipped_stale", "closed"}`. `user_workouts_upsert_v1` checks everything again, keeps the newest
`client_updated_at` per workout (a replay changes nothing), closes an open workout when a later one starts, and re-queues
the local days it touched for the measurement-context builder.

`GET scores/workouts?from=<unix>&to=<unix>[&deviceId=<id>][&includeDeleted=1]` (≤ 90 days, ≤ 500 workouts) returns
each workout with its type's `attributes`.

`internal.logged_workouts_v1(user, strap, from, to)` is every server pipeline's one read: workout-mode rows (a running
one up to now, never past 4 hours; deleted ones never) plus the manual workout sessions (`public.sessions` kind
`manual_workout`, the live tracker's and the manual sheet's rows from the structured push) that no workout-mode row
already holds (same start within 2 minutes), typed from their sport name.

## How each pipeline uses a logged workout

| Pipeline | What a logged workout does |
| --- | --- |
| Phone decoder (`ActivityContextTrack`) | Through the existing logged-workout path: `Repository.withLoggedWorkouts` adds a running workout (up to now) and a logged one with no saved row to the day's `DayStateWorkout`s under the type's stored sport name, so `loggedWorkout` is set and `workoutKind` is the type's kind (indoor walk → walking, indoor cycling → cycling, strength → other). The decoder's gates are unchanged (`hsmm` version unchanged). The day's input fingerprint names the logged workouts, so a start, change or stop re-decodes the day. |
| Session rule `exercise-session-2` | Unchanged (no new rule id; fixture and four ports untouched). Logged minutes are strong evidence, which the rule's server port already allowed ("inside a workout the person logged"); every logged minute being strong, a logged workout of 15 minutes or more confirms itself at its 15th minute, so its recovery and the exercise references follow from the rule. The load check still decides whether the rule finds a session. |
| Watchdog (`WatchdogExerciseContext`) | A logged workout's window minutes are `session` from the first minute (no waiting for movement or load), so lifting with a still arm is compared with the exercise-session reference, never awake rest; a plain walk keeps the walking reference. Safety bounds are untouched: the in-session ceiling (`WatchdogV2ScenarioTests`-style test: 212 bpm inside a logged strength workout is a verified alert), bradycardia and SpO2 extremes. The episode snapshot records `basis` (`logged` / `inferred`) and `workoutType` (lineage, synced with the episode). |
| Measurement context (`20261009130100`) | `workout_type` and `workout_basis` (`user_workout` / `manual_session`) per minute; logged minutes are strong evidence and never still minutes for the rest fallback; while worn and awake they are `session` with `session_basis = logged` and `session_start` the workout's start, whatever the rule found. A recovery the rule found after it stays. |
| Activity epochs (worker) | `ActivityLane.daySpans` merges workout-mode rows into the session records (`LoggedWorkouts.merge`), so the epochs' `exercise_session` is `true` inside a logged workout and the v2 decoder reads the type's kind. A workout logged for a past day reaches that day's epochs at its next activity job (any upload of that day); the builder and the anomaly service read the log directly. |
| ElderNet gait row (worker) | `summary.workouts` on `activity_gait_windows_days`: each logged workout in the day with its type's attributes, the gait windows inside it, how many ElderNet called gait, and `gait_label` (`expected_gait` for walks, runs, hiking, stairs and sports; `unexpected_gait` for stationary or cycling types; `unlabelled` for mixed). Model outputs are unchanged. |
| HART | Through the epochs and the decoder above (the HART windows themselves are unchanged). |
| Anomaly service | `features.load` reads `internal.logged_workouts_v1` into a `logged` channel (re-read over the whole cached frame every job, so edits after the fact apply); logged minutes are strong evidence and are `exercise` whatever the rule found (off-wrist minutes stay `off`), so their windows are withheld as `activity`, never scored as rest and never added to a rest reference. |

Only plumbed, not used yet (follow-ups):

- The type's attributes reach the decoder only as its kind (running / walking / cycling / other). Using `effort =
  resistance`, `environment` or `arm_motion` inside the decoder is a decoder change (`hsmm` version, Python port).
- Physiology context (`ContextInputs` / `PCExertionBouts`) still reads only the session records (a finished live
  workout is one); workout-mode rows need their availability time for causal replays first.
- RecGym exercise windows (shadow) do not record the overlapping workout yet; `internal.logged_workouts_v1` is the
  join for evaluating it against the wearer's own labels.
- Layer 1's history strata (`ContextMaterializer`) read decoder intervals only; a logged workout reaches them through
  the decoder's labels, not as a session.
- The phone Watchdog reads workout mode's log (every live session is in it); a workout added afterwards through the
  manual sheet is logged on the server (manual session) but not in the phone's 4-hour Watchdog history.

## Tests

`WorkoutTypeCatalogTests`, `WorkoutModeLogTests`, `LoggedWorkoutContextTests` (StrandAnalytics: contract parity,
decoder kinds, state machine, the 4-hour cap, persistence, sync bookkeeping, a still logged strength workout judged as
exercise and silent, the ceiling breach still alerting); `WorkoutModeStoreTests` (StrandTests: relaunch, offline queue,
section states, decoder input); `tests/workout_types_parity_test.ts`, `tests/user_workouts_route_test.ts`,
`tests/user_workouts_sql_test.ts` + `supabase/tests/user_workouts.sql` (RLS, idempotent upsert, type check, open/close,
queue, read, logged list, the builder); `LoggedWorkoutsTests` and `ActivityStreamDaysDatabaseTests` (worker);
`test_context_hygiene.py` and `test_db_features.py` (anomaly service).
