# Watchdog episodes and annotations: the server copy

The phone's Watchdog keeps a journal of every episode it opened (`WatchdogEpisodeLedgerRow`) and the wearer's optional
note after a page (`WatchdogEpisodeAnnotation`). Both lived only in the phone's UserDefaults (21 days, one phone). The
phone now uploads them; the server keeps one row per (owner, strap device, episode), last writer wins on the phone's
own `client_updated_at`.

- Migration: `supabase/migrations/20261009150000_watchdog_episodes.sql` (`public.watchdog_episodes`,
  `public.watchdog_episodes_upsert_v1`, `public.watchdog_episodes_read_v1`).
- Edge: `supabase/functions/_shared/watchdogEpisodes.ts`; routes in `_shared/serverScores.ts`.
- Tests: `supabase/functions/tests/watchdog_episodes_route_test.ts` (validation and wiring),
  `supabase/tests/watchdog_episodes.sql` + `tests/watchdog_episodes_sql_test.ts` (pipeline database: upsert, caps,
  read, RLS, the route through PostgREST).
- Source shapes (StrandAnalytics): `WatchdogEpisodeLedgerRow` (`WatchdogEpisodeLedger.swift`),
  `WatchdogEpisodeAnnotation` (`WatchdogEpisodeAnnotation.swift`), `WatchdogExerciseSnapshot` and
  `WatchdogSignalEvidence` (`Watchdog.swift`).

## Auth and device

Same credential as every other `scores` route (installation token, or the signed-in account's session with
`x-noop-source-id`). The owner is the credential's; the uploading installation (`source_id`) is recorded. `device_id`
names the strap the way the phone names it for every other read: `AppModel.hostedReadCandidates.first`, i.e. the
strap's own `whoop-<SERIAL>` once its serial is known, else the local id. The server resolves it with
`findNoopDevice` (installation-scoped for a local id, alias-aware), so episodes land on the canonical strap device
that holds the strap's data. An id that resolves to no device of the owner is `409 device_registration_pending`.

## `POST scores/watchdog-episodes`

```json
{
  "device_id": "whoop-MGB0000001",
  "local_device_id": "my-whoop",
  "episodes": [ { ...episode... } ]
}
```

1 to 50 episodes per call; each episode at most 16 KiB serialized (UTF-8 JSON). Body cap 823,296 bytes.

### Episode

Top-level keys are snake_case and map 1:1 onto `WatchdogEpisodeLedgerRow`; the nested objects are the app's own
`Codable` JSON (camelCase), stored as sent.

| Key | Type | From (`WatchdogEpisodeLedgerRow` unless noted) | Rule |
| --- | --- | --- | --- |
| `episode_id` | string | `episodeId` | `^[A-Za-z0-9._:-]{1,128}$`, unique within the call |
| `opened_at` | int (unix s) | `openedUnix` | 2020-01-01 .. 2100-01-01 |
| `last_at` | int | `lastUnix` | `>= opened_at` |
| `closed_at` | int or null | `closedUnix` | `>= opened_at` |
| `max_severity` | string | `maxSeverity` | `candidate` / `active` / `severe` |
| `peak_severity` | string or null | `peakSeverity` | a `WatchdogSeverity`: `withinLimits` / `note` / `candidate` / `active` / `severe` / `dataUnavailable` |
| `safety` | bool | `safety` | a VERIFIED safety-extreme alert happened (not merely "reached severe") |
| `personal_off` | bool | `personalOff` | default false |
| `notify_delivery` | string | `notifyDelivery` | `""` (never notified) / `queued` / `sent` / `denied` / `failed` / `skipped`; default `""` |
| `live_alerts` | bool | `liveAlerts` | default true |
| `off_minute_count` | int | `offMinutes.count` | 0 .. 1,000,000 (the minute list itself is not sent) |
| `unavailable_minutes` | int | `unavailableMinutes` | 0 .. 1,000,000 |
| `headline` | string or null | `headline` | <= 500 chars |
| `event_label` | string or null | `eventLabel` | `^[A-Za-z0-9._:-]{1,64}$` |
| `activity_label` | string or null | `activityLabel` | same pattern |
| `contributing` | string[] or null | `contributing` | <= 16 items, each <= 32 chars |
| `signals` | object[] or null | `signals` (`WatchdogSignalEvidence`: `name`, `unit`, `observed`, `usual`, `reconstructed`, `energy`, `trustPct`, `rangeHalf`) | <= 16; `name` required (<= 32), numbers finite or null |
| `exercise` | object or null | `exercise` (`WatchdogExerciseSnapshot`: `rule`, `phase`, `sessionStartUnix`, `sessionLastMovementUnix`, `restReference`, `restBasis`, `ceilingBpm`, `ceilingBasis`, `sessionReference`, `recoveryReference`, `routine`, `confirmed`) | `rule` required; `phase` `session` / `recovery` / `active` / `none`; `confirmed` boolean or absent/null; references `established` / `learning` |
| `annotation` | object or null | the `WatchdogEpisodeAnnotation` with this `episodeId` (`episodeId`, `deviceId`, `eventUnix`, `enteredUnix`, `reporter`, `status`, `symptoms`, `exertion`, `stress`, `illness`, `sensor`, `note`) | `annotation.episodeId == episode_id`; `status` `pending` / `entered` / `skipped` / `expired`; `exertion` `rest` / `light` / `hard`; `stress` `low` / `high`; `illness` `felt_off` / `not`; `sensor` `loose` / `charging` / `just_on` / `other`; `symptoms` <= 1000, `note` <= 2000 |
| `quality_reasons` | object[] or null | optional: the canonical data reasons in effect (`DataReason`: `{code, certainty, subcode?}`) | `code` registered in `contracts/reason-codes.json` (`data-reason-1`), `certainty` `confirmed` / `inferred` / `unknown` / `measured`, `subcode` one the code lists; <= 32 |
| `versions` | object | e.g. `{"watchdog": "...", "baseline": "...", "exercise_rule": "exercise-session-2", "reason_codes": "data-reason-1"}` | <= 16 string values (<= 128 chars), keys `^[A-Za-z0-9._:-]{1,64}$` |
| `client_updated_at` | int (unix s) | the phone's clock when it last changed this episode or its annotation | required |

Unknown top-level keys are ignored (not stored); unknown keys inside `exercise`, `annotation` and `signals` are kept
as sent (the 16 KiB cap bounds them). The `annotation.deviceId` is the phone's local id; the server does not resolve
it.

### Response

`200 {"accepted": n, "skipped_stale": m}`: `accepted` = episodes the server now holds exactly as sent (written now
or already identical), `skipped_stale` = episodes for which the server already holds a newer `client_updated_at`
(the row is left alone). `accepted + skipped_stale` = the number sent.

Last-writer-wins per (owner, device, `episode_id`): a newer `client_updated_at` replaces the row; an equal one
replaces it only when the content differs (the later arrival wins); the same content again writes nothing.

Errors, `{"error": code}`; the whole batch is refused and nothing is written:

| Status | `error` |
| --- | --- |
| 400 | `invalid_body`, `invalid_device_id` (missing or unsafe `device_id`), `invalid_local_device_id`, `invalid_episodes` (not 1..50), `invalid_episode`, `invalid_episode_id`, `duplicate_episode_id`, `invalid_episode_times`, `invalid_client_updated_at`, `invalid_severity`, `invalid_notify_delivery`, `invalid_signals`, `invalid_exercise`, `invalid_annotation`, `invalid_quality_reasons`, `invalid_versions`; `request_rejected` if the database backstop refuses what the edge let through |
| 409 | `device_registration_pending` |
| 413 | `payload_too_large` (body), `episode_too_large` (one episode over 16 KiB) |

## `GET scores/watchdog-episodes?from=<unix>&to=<unix>[&deviceId=<id>]`

Episodes overlapping `[from, to)`: opened before `to` and last seen (`max(last_at, closed_at)`) at or after `from`.
Range at most 90 days. With `deviceId`, that strap's episodes (resolved as for POST); without it, every device of the
owner. Oldest first, at most 500.

```json
{
  "device_id": "whoop-MGB0000001",
  "episodes": [ { ...episode as POSTed..., "device_id": "whoop-MGB0000001", "local_device_id": "my-whoop",
                  "updated_at": 1791441600 } ],
  "truncated": false
}
```

Each episode has every key of the POST shape (absent values as `null`; `versions` `{}`), plus `device_id` (the
server device's external id), `local_device_id` (as last sent) and `updated_at` (server time of the last write, unix
s). The top-level `device_id` echoes the query's `deviceId` and is absent without it. `truncated` is true when more
than 500 matched. Errors: `400 invalid_range`, `400 invalid_device_id`, `409 device_registration_pending`.

## Storage (`public.watchdog_episodes`)

Primary key `(user_id, device_id, episode_id)`; FK `(user_id, device_id)` to `devices` (cascade). Columns:
`local_device_id`, `source_id`, `opened_at`, `last_at`, `closed_at` (timestamptz), `max_severity`, `peak_severity`,
`safety`, `personal_off`, `live_alerts`, `notify_delivery`, `off_minute_count`, `unavailable_minutes`;
`verdict` jsonb (`headline`, `event_label`, `contributing`, `signals`), `context` jsonb (`activity_label`,
`exercise`, `quality_reasons`), `annotation` jsonb (one per episode, the phone's `annotation`), `versions` jsonb,
`client_updated_at`, `created_at`, `updated_at`. CHECKs hold the enums and the 16 KiB bound.

RLS: an owner may `select` their own rows; `anon` nothing; no client may insert, update or delete. Writes only through
`watchdog_episodes_upsert_v1` (service role, called by the route with the credential's owner). Rows are not pruned
(a few per day per person); account deletion cascades.
