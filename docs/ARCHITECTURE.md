# How data moves through Nara

A reading travels from the strap to the phone, up to Supabase, through the VPS worker, back into
Supabase, and down to the phone again. This page follows one reading through each step and names the
code that handles it.

```mermaid
sequenceDiagram
    participant S as WHOOP strap
    participant P as Nara app
    participant E as Supabase edge functions
    participant D as Supabase Postgres
    participant W as VPS worker
    S->>P: Bluetooth notifications and history sync
    P->>P: store locally, stage rows in the upload journal
    P->>E: POST /functions/v1/push (gzip NDJSON batch)
    E->>D: write rows, record receipt, mark day dirty
    W->>D: claim a dirty day (claim_scoring_v2)
    W->>W: compute the day with StrandAnalytics
    W->>D: publish snapshot (publish_scoring_snapshot_v2)
    W->>D: publish the day's 1- and 5-minute series (publish_metric_series_v1)
    P->>E: GET /functions/v1/scores/days, then /scores?day=…
    E->>D: read the latest snapshot
    E-->>P: server_scoring payload
    P->>P: write it into the local store; cards update
    P->>E: GET /functions/v1/scores/series (metric detail pages)
    E->>D: read server_metric_series
    E-->>P: one value per bucket (1 or 5 minutes, per metric)
```

## 1. Strap to phone

`Strand/BLE/BLEManager.swift` talks to the strap. Live notifications (heart rate, R-R intervals,
battery, motion) arrive continuously while connected, and `Strand/Collect/Backfiller.swift` pulls
the strap's stored history whenever it reconnects. Everything lands in the local SQLite store from
`Packages/WhoopStore`, so the app keeps working offline.

## 2. Phone to Supabase

Nothing leaves the phone until a person has signed in. **Settings → Nara account**
(`Strand/Auth/NaraAccountView.swift`) creates an account with Supabase Auth: an email address and a
password, then a one-time code that Supabase emails (Resend is only its mail transport) to confirm the
address. `SupabaseAuthBackend.swift` is the one file that talks to the `supabase-swift` Auth client, and
the session lives in the Keychain (`NaraKeychainAuthStorage.swift`). The app holds the project's
publishable key and nothing secret.

A verified session is all the phone needs to link itself, and the chain it builds is fixed:

```
Supabase auth.users.id  →  account-scoped source id  →  installation credential  →  canonical WHOOP device
```

- **The account** is `auth.users.id` and is the only cloud user id. No request body ever carries a user
  id; the server reads it from the verified JWT.
- **The source id** names this install *for this account*. A phone signed into two accounts has two
  source ids (`CloudPushIdentityStore`), and the server refuses to hand one account's source to another.
- **The installation credential** is a high-entropy `noop_…` token. `NaraAccountController` asks for it with
  `POST /functions/v1/push/installations/provision`, authenticated by the session's JWT. The server stores
  only its SHA-256 hash, bound to exactly `(user id, source id)`, and returns the token once; the app keeps
  it in the Keychain. Uploads and score reads authenticate with this token and not with the Auth session,
  so a locked phone finishing a background sync never depends on refreshing a JWT. There is no shared
  fleet token on this path.
- **The WHOOP** is paired as usual. It starts as a provisional device id scoped to this install, and the app
  confirms it (`POST …/push/wearables/confirm`) as soon as the strap reports its serial number. The canonical
  device id is derived from the account's user id as well as the serial, so a serial is evidence and never an
  ownership claim: two accounts that pair the same strap get two separate devices, and neither can read,
  write or move the other's.

Once the credential is stored, the app treats the server as the source of scores
(`AppModel.cloudScoringIsAuthoritative`). Signing out removes the credential and stops uploads, and what
was already queued stays under the account it was recorded for.

The upload path lives in `Strand/Push/`:

| File | Job |
| --- | --- |
| `CloudPushIdentity.swift` | The `(account, source id, credential)` triple, and `CloudDataScope`, the `(account, source)` pair that every queued record and cursor is keyed by. The Keychain holds the credential. |
| `CloudReceiverClient.swift` | The HTTP client for provisioning, wearable confirmation and installation retirement, and the one place that decides which credential headers a request carries. |
| `CloudCapture.swift` | Turns each notification or history record into wire rows and stages them. It never blocks or throws into the Bluetooth pipeline. A second of heart rate is staged once (`CloudHeartRateLedger`, first sample wins), because the receiver treats two values for one second as a conflict and keeps neither. |
| `CloudJournal.swift` | A durable SQLite outbox. Rows are journaled per stream with a sequence number, stamped with the scope they were recorded under at the moment they are submitted, then sealed into batches. Sealed batches never change scope. |
| `CloudBatchBuilder.swift` | Encodes a sealed batch in the push wire format from `Packages/NoopPush`. |
| `CloudTransportCoordinator.swift` | Serves exactly one scope at a time. Seals batches of at most 2,000 records, uploads at most two at a time (only one of them from the history backlog, so fresh data is not stuck behind it), retries failures with backoff, and makes failed batches due again at launch. |
| `CloudUploadSession.swift` | The HTTP client. Requests time out after 90 seconds, because a large batch can take the receiver more than a minute under load. |
| `CloudLocalDataBinding.swift` | Records which account owns the phone's on-device history. The first verified account claims it, and only that account's cloud path replays it, so signing out A and into B never uploads A's banked history as B's. |

Each batch is a gzip-compressed NDJSON `POST` to `/functions/v1/push`, authenticated with the
installation's token. When a phone first links to an account, `AppModel.startHistorySeedIfNeeded()`
uploads the strap history the phone already had, so the server can score past days too.

## 3. Supabase receives the batch

`supabase/functions/push/index.ts` checks the token and the batch, then commits the rows into the
typed tables for each stream (heart rate, R-R intervals, sleep state, and so on) through
`noop_commit_push_projection`. It records a receipt in `noop_upload_receipts`, which the app uses to
confirm the batch landed. Large payloads can take the object lane instead: the function hands back a
presigned URL, the app uploads the object to B2 storage, and the rows are released once the object
is verified.

Ownership comes from the credential and never from the request. The token resolves server-side to exactly
one `(user_id, source_id)`, and the function takes both from there rather than from the batch. The device a
row lands on is derived from that user, so a row cannot be written into another account's device. Every
table in `public` has row-level security on, except one shared reference table with no user data; the
policies on user-owned tables are written in terms of `auth.uid()`; and the service credentials the
functions and the worker use never leave the server.
`supabase/functions/tests/auth_isolation_sql_test.ts` checks all of this against the production Postgres image.

Committing rows for a day marks that day's score as stale. A trigger calls
`invalidate_scoring_stream_v2`, which enqueues or updates a row in `scoring_jobs_v2`.

## 4. The VPS worker computes the day

`Tools/CloudWorker` builds `frwhoop-worker`, which runs on a DigitalOcean droplet as the systemd
service `frwhoop-worker`. It links the same `StrandAnalytics`, `WhoopProtocol` and `WhoopStore`
packages as the app, so a score computed on the server matches what the app would compute.

The worker runs independent lanes, each on its own thread and database connection:

| Lane | Queue | What it does |
| --- | --- | --- |
| scoring | `scoring_jobs_v2` | Claims a stale day (`claim_scoring_v2`), loads its inputs, computes strain, sleep, recovery, HRV, resting heart rate and respiratory rate, and publishes a row to `scoring_snapshots_v2` (`publish_scoring_snapshot_v2`). Once that commits it also writes the day's dense series (1-minute for respiratory rate, steps and calories, 5-minute for HRV and resting heart rate) of HRV, resting heart rate, respiratory rate, steps and calories to `server_metric_series` (`publish_metric_series_v1`); see [BACKEND.md](BACKEND.md#intraday-metric-series). |
| archive | `scoring_archive_jobs_v2` | Copies each published snapshot to private B2 storage. |
| verify | object arrivals | Reconciles objects uploaded through the object lane that were never verified. |
| projection | `noop_projection_debt` | Replays stored objects into the typed tables. Turned off in production; see [BACKEND.md](BACKEND.md). |
| activity | `activity_context_jobs` | (Off by default; `FRWHOOP_ACTIVITY_ENABLED=1`.) Downloads verified `rawImuSession` objects, decodes the NPB1 IMU payloads, splits contiguous runs, classifies each 4-second window through a persistent local Python process (HART, `Tools/ActivityContext`), folds the day through the same `ActivityContextPolicy` the app links, and publishes 30-second activity epochs under a fenced lease. Publishing re-dirties the day's score, so the next scoring pass attaches `daily.activity_context` to the snapshot. In the same transaction it also stores a decoded ActivityContext v2 day document in `activity_context_days` (the window probabilities and IMU features plus the day's stored heart rate, gravity, steps, wear events, sleep and workouts, through the app's own `StrandAnalytics` decoder); a failure there is counted and never blocks the epoch publish. See [BACKEND.md](BACKEND.md#day-documents-activitycontext-v2). |


The worker also writes a heartbeat to `scoring_service_heartbeats` every 15 seconds.

## 5. Results back to the phone

`supabase/functions/scores/index.ts` serves the published results:

- `GET /functions/v1/scores/days` lists the days whose results changed since the app's last cursor.
- `GET /functions/v1/scores?day=YYYY-MM-DD&deviceId=…` returns that day's latest snapshot.
- `GET /functions/v1/scores/series?deviceId=…&from=<unix>&to=<unix>` returns the intraday metric series for a
  range of up to three days.

`Strand/Push/ServerScoreRepository.swift` calls all three, caches each result per owner, and
`HostedResultMaterializer` writes it into the same local tables (`dailyMetric` and the score
provenance tables) that the cards already read. `AppModel.syncHostedResults()` pulls yesterday, today
and any changed days when the app becomes active, then every 30 seconds while it stays in the
foreground.

The intraday series does not go through the local store. `Strand/Push/IntradaySeriesStore.swift` keeps
the last window it read for each metric in memory and in an on-disk cache, and the "Through the day" card
(`Strand/Screens/IntradaySeriesSection.swift`) on the HRV, resting heart rate, respiratory rate, steps and
calories detail pages re-reads it every 30 seconds while it is on screen. Nothing on the phone computes
those values.

## 6. Coach

The Sana tab (the health assistant chat) runs through the backend as well. The phone sends the question to
`supabase/functions/coach/index.ts`, which checks the same installation credential as
`push`, takes one unit of the user's daily quota, and streams the model's answer back. The model
cannot see the database. When it needs numbers it asks the app for them through a tool call, and
`Strand/Coach/CoachTools.swift` answers from the days the phone has already read from the server in
step 5, so the coach quotes the scores the backend published instead of recomputing anything. The
app saves the conversation and the coach's memory through the same function. Charts and tables are
drawn by a second model pass on the server, which fact-checks them against the figures in the answer.

The same function stores the Settings profile (name, date of birth, sex, height, weight) in the owner's
`profiles` row, the row server-side scoring reads. The phone uploads an edit shortly after it is made and
loads the stored profile when the app opens, so the values survive a reinstall and a second device.

## 7. Activity context

Raw IMU (the strap's 100 Hz six-axis stream) rides the same path with one extra hop: a bounded raw
capture session records the strap's one-second frames durably on the phone (`ImuSessionFileStore`),
the phone packs them into `rawImuSession` objects through the NoopPush object lane (verified objects
only), and the worker's activity lane (off by default) classifies each 4-second window and publishes
30-second activity epochs (`activity_context_epochs`). Scoring then attaches an `activity_context`
object to the day's snapshot `daily`, and the app shows an activity ribbon and a context line
("Walking", "Low movement; posture unknown", "Recent activity") on the metric pages. Unknown is a
first-class label: the classifier abstains below its confidence thresholds, posture stays unknown
until a validated head exists, and quiet wrists never prove the strap is worn. The first automatic
labels are shadow-only: they have not met the promotion gates on held-out data, so the lane runs
disabled by default and no physiological value depends on it.

The phone also decodes a richer, granular version of the day on its own (posture, locomotion and arm
heads, transitions) for the heart-rate day page. The worker produces the same document from the same
decoder and stores it per UTC day, but nothing serves it to the phone yet; the app still draws its
local result.

An optional second motion expert, Inertia-1 (`Tools/ActivityContext/INERTIA1.md`), can run beside HART on
the worker. It is off by default and shadow-first: its head outputs are stored in their own table and,
in candidate mode, compared against a second decode of the day, but the published documents never change.
In the decoder its heads are separate, tempered channels (never an average with HART) that stay off unless
`ActivityDecoderConfig.motionHeads` accepts a real Inertia-1 bundle; with them off the decoder's output is
byte-identical to before.

That decoding also leaves a durable record. Each run carries a canonical activity class (a closed
vocabulary, with a confidence) beside the display wording. On the phone, each local day's runs are saved
as timestamp-aligned intervals in the on-device store (`activityContextInterval`), and the per-sample
tables (heart rate, R-R, SpO₂, skin temperature, respiration, gravity, steps) join to them by time
through the `*Ctx` views instead of carrying a copied label, so a score, the coach or a query can ask
what the wearer was doing when any measurement was taken (docs/IOS.md). The worker's per-day documents
carry the same class as `activity_class` (docs/BACKEND.md). The stand reminder reads the same decoding:
it stays quiet when the rolling window (50 minutes by default) held a minute of standing or moving
(docs/CURRENT_ALGORITHMS.md, section 10).

## What each score needs

- **Strain, sleep, resting heart rate, steps and calories** appear once a day's readings are in.
- **HRV and respiratory rate** come from overnight R-R intervals. Respiratory rate is derived from the
  breathing rhythm in heart rate, so it does not need a separate sensor stream.
- **Recovery** needs a baseline of four nights. Until then the card shows "Calibrating".
- **Blood oxygen** is shown only as a labelled strap estimate, and only for the night. The WHOOP 5.0/MG
  history carries an SpO₂ byte, but the strap fills it only while the wearer is asleep and still (roughly
  400 to 500 readings a night, none by day), and it is not established that the byte is a calibrated
  percentage. The worker averages the night's readings into `spo2_candidate_pct`; the card says "strap
  estimate (unverified)" and no score uses it. See the Blood oxygen entry in the backend runbook. The Key
  Metrics tile's caption counts the readings the phone banked for that night (`KeyMetricReadings`, which
  counts with the function that builds the uploaded `SPO2_STRAP_EST` rows, so the two cannot differ), and
  says "Measured during sleep" when there are none.
- **Skin temperature** is a per-second sample in the strap's history, banked on the phone and uploaded as
  `skinTempSample` rows. The Key Metrics tile shows the newest banked sample with its age while a 5.0/MG is
  on the wrist (a worn-range reading, under 30 minutes old, and only when Settings asks for the absolute
  scale); otherwise it shows the nightly value, as before. The 4.0's register is a provisional map, so it
  never gets a live absolute reading.
