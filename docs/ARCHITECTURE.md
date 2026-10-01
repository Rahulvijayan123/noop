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
    P->>E: GET /functions/v1/scores/days, then /scores?day=…
    E->>D: read the latest snapshot
    E-->>P: server_scoring payload
    P->>P: write it into the local store; cards update
```

## 1. Strap to phone

`Strand/BLE/BLEManager.swift` talks to the strap. Live notifications (heart rate, R-R intervals,
battery, motion) arrive continuously while connected, and `Strand/Collect/Backfiller.swift` pulls
the strap's stored history whenever it reconnects. Everything lands in the local SQLite store from
`Packages/WhoopStore`, so the app keeps working offline.

## 2. Phone to Supabase

Cloud sync is off until the user enrolls the install from **Settings → Nara account**
(`Strand/Onboarding/CloudEnrollmentView.swift`, `Strand/Push/CloudEnrollment.swift`). Enrollment
stores an installation credential in the Keychain (`CloudKeychain.swift`). After that, the app treats
the server as the source of scores (`AppModel.cloudScoringIsAuthoritative`).

The upload path lives in `Strand/Push/`:

| File | Job |
| --- | --- |
| `CloudCapture.swift` | Turns each notification or history record into wire rows and stages them. It never blocks or throws into the Bluetooth pipeline. |
| `CloudJournal.swift` | A durable SQLite outbox. Rows are journaled per stream with a sequence number, then sealed into batches. |
| `CloudBatchBuilder.swift` | Encodes a sealed batch in the push wire format from `Packages/NoopPush`. |
| `CloudTransportCoordinator.swift` | Seals batches of at most 2,000 records, uploads at most two at a time (only one of them from the history backlog, so fresh data is not stuck behind it), retries failures with backoff, and makes failed batches due again at launch. |
| `CloudUploadSession.swift` | The HTTP client. Requests time out after 90 seconds, because a large batch can take the receiver more than a minute under load. |

Each batch is a gzip-compressed NDJSON `POST` to `/functions/v1/push`, authenticated with the
installation's ingest token. When the app first enrolls, `AppModel.startHistorySeedIfNeeded()`
uploads the strap history the phone already had, so the server can score past days too.

## 3. Supabase receives the batch

`supabase/functions/push/index.ts` checks the token and the batch, then commits the rows into the
typed tables for each stream (heart rate, R-R intervals, sleep state, and so on) through
`noop_commit_push_projection`. It records a receipt in `noop_upload_receipts`, which the app uses to
confirm the batch landed. Large payloads can take the object lane instead: the function hands back a
presigned URL, the app uploads the object to B2 storage, and the rows are released once the object
is verified.

Committing rows for a day marks that day's score as stale. A trigger calls
`invalidate_scoring_stream_v2`, which enqueues or updates a row in `scoring_jobs_v2`.

## 4. The VPS worker computes the day

`Tools/CloudWorker` builds `frwhoop-worker`, which runs on a DigitalOcean droplet as the systemd
service `frwhoop-worker`. It links the same `StrandAnalytics`, `WhoopProtocol` and `WhoopStore`
packages as the app, so a score computed on the server matches what the app would compute.

The worker runs independent lanes, each on its own thread and database connection:

| Lane | Queue | What it does |
| --- | --- | --- |
| scoring | `scoring_jobs_v2` | Claims a stale day (`claim_scoring_v2`), loads its inputs, computes strain, sleep, recovery, HRV, resting heart rate and respiratory rate, and publishes a row to `scoring_snapshots_v2` (`publish_scoring_snapshot_v2`). |
| archive | `scoring_archive_jobs_v2` | Copies each published snapshot to private B2 storage. |
| verify | object arrivals | Reconciles objects uploaded through the object lane that were never verified. |
| projection | `noop_projection_debt` | Replays stored objects into the typed tables. Turned off in production; see [BACKEND.md](BACKEND.md). |

The worker also writes a heartbeat to `scoring_service_heartbeats` every 15 seconds.

## 5. Results back to the phone

`supabase/functions/scores/index.ts` serves the published results:

- `GET /functions/v1/scores/days` lists the days whose results changed since the app's last cursor.
- `GET /functions/v1/scores?day=YYYY-MM-DD&deviceId=…` returns that day's latest snapshot.

`Strand/Push/ServerScoreRepository.swift` calls both, caches each result per owner, and
`HostedResultMaterializer` writes it into the same local tables (`dailyMetric` and the score
provenance tables) that the cards already read. `AppModel.syncHostedResults()` pulls yesterday, today
and any changed days when the app becomes active, then every two minutes while it stays in the
foreground.

## 6. Coach

The Coach tab is a chat that runs through the backend as well. The phone sends the question to
`supabase/functions/coach/index.ts`, which checks the same installation and fleet credentials as
`push`, takes one unit of the user's daily quota, and streams the model's answer back. The model
cannot see the database. When it needs numbers it asks the app for them through a tool call, and
`Strand/Coach/CoachTools.swift` answers from the days the phone has already read from the server in
step 5, so the coach quotes the scores the backend published instead of recomputing anything. The
app saves the conversation and the coach's memory through the same function. Charts and tables are
drawn by a second model pass on the server, which fact-checks them against the figures in the answer.

## What each score needs

- **Strain, sleep, resting heart rate, steps and calories** appear once a day's readings are in.
- **HRV and respiratory rate** come from overnight R-R intervals. Respiratory rate is derived from the
  breathing rhythm in heart rate, so it does not need a separate sensor stream.
- **Recovery** needs a baseline of four nights. Until then the card shows "Calibrating".
- **Blood oxygen** needs SpO₂ samples from the strap. The strap history this app syncs does not
  include them, so the card stays empty.
