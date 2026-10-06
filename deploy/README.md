# frwhoop-worker deployment (reproducible)

One DigitalOcean Droplet, one systemd service, outbound-only, TLS-verified.

## Live deployment reference

- Droplet `frwhoop-worker-2` (sfo3, 4 vCPU/8 GB, Ubuntu 24.04, IPv6)
- Service `frwhoop-worker.service` (user `frwhoop`, `ProtectHome=true`,
  `HOME=/var/lib/frwhoop`, restart always, SIGTERM graceful stop)
- Code `/opt/noop` (release artifacts under `Tools/CloudWorker/.build/release`)
- Secrets `/etc/frwhoop/worker.env` (0600 root) + `/etc/frwhoop/supabase-ca-chain.pem` (0644)
- DB: `sslmode=verify-full` against the pinned Supabase CA chain — the worker
  refuses plaintext (`FRWHOOP_ALLOW_INSECURE_DB=1` is local-dev only). Verified
  live: `pg_stat_ssl` shows `TLSv1.3` for the worker's backends.

## Cold provision (run once per host)

```bash
sudo deploy/provision.sh          # or copy step-by-step below
```

Steps (what provision.sh automates):
1. Packages: `build-essential clang curl unzip git pkg-config libpq-dev
   zlib1g-dev libssl-dev libzstd-dev postgresql-client`
2. Swift 6.0.3 (pinned tarball + sha256) from swift.org ubuntu2404 x86_64
3. Private snapshot-enabled SQLite (GRDB needs `sqlite3_snapshot_*`;
   distro builds omit it): pinned amalgamation 3530400 + sha256 check,
   built with `-DSQLITE_ENABLE_SNAPSHOT=1` at `/opt/sqlite`
4. `frwhoop` service user + `/etc/frwhoop` + `/var/lib/frwhoop` (HOME)
5. Unit install + `systemd-analyze verify`

## Build + release

```bash
# From a clean checkout of the pinned revision:
tar czf worker.tar.gz --exclude="Tools/CloudWorker/.build" Tools/CloudWorker contracts deploy
scp worker.tar.gz root@HOST:/opt/
ssh root@HOST 'rm -rf /opt/noop/Tools/CloudWorker /opt/noop/contracts /opt/noop/deploy &&
  tar xzf /opt/worker.tar.gz -C /opt/noop &&
  chown -R frwhoop:frwhoop /opt/noop/Tools/CloudWorker &&
  cd /opt/noop/Tools/CloudWorker &&
  LD_LIBRARY_PATH=/opt/sqlite swift build -c release -Xcc -I/opt/sqlite -Xlinker -L/opt/sqlite &&
  swift test -Xcc -I/opt/sqlite -Xlinker -L/opt/sqlite'
```

Versioned immutable releases (recommended): build to
`.build/release-<git-sha>` and atomically switch a symlink; keep the previous
artifact for rollback. `systemctl restart frwhoop-worker` only after tests pass.

## Configure

`/etc/frwhoop/worker.env` (names-only template: `deploy/worker.env.example`):
DB URL + `FRWHOOP_DB_SSLMODE=verify-full` + `FRWHOOP_DB_SSLROOTCERT=/etc/frwhoop/supabase-ca-chain.pem`,
B2 key id + application key, ingest secret, worker name, source revision, lane budgets.

### Activity context lane (optional, off by default)

The activity lane needs a Python venv and the trained artifacts on the host. This is what runs on
`frwhoop-worker-2` (Ubuntu 24.04, Python 3.12, CPU only):

```bash
ssh root@HOST
apt-get install -y python3.12-venv
python3 -m venv /var/lib/frwhoop/activity-venv
PY=/var/lib/frwhoop/activity-venv/bin/python
$PY -m pip install --index-url https://download.pytorch.org/whl/cpu torch==2.8.0   # CPU wheel, no CUDA stack
$PY -m pip install numpy==2.2.6 transformers==4.56.0 granite-tsfm==0.3.3 safetensors==0.8.0
chown -R frwhoop:frwhoop /var/lib/frwhoop/activity-venv
# artifacts (about 650 KB): config.json, manifest.json and model.safetensors in /var/lib/frwhoop/activity-model
# check that serve.py loads them as the service user, before touching the live worker:
printf '%s\n' '{"id":"1","op":"ping"}' '{"id":"2","op":"shutdown"}' | su -s /bin/bash frwhoop -c \
  "cd /opt/noop/Tools/ActivityContext && HOME=/var/lib/frwhoop $PY -m activity_context.serve \
   --manifest /var/lib/frwhoop/activity-model/manifest.json --checkpoint /var/lib/frwhoop/activity-model"
# the ping must answer "model_status": "hart_loaded"; then enable in /etc/frwhoop/worker.env:
#   FRWHOOP_ACTIVITY_ENABLED=1
#   FRWHOOP_ACTIVITY_PYTHON=/var/lib/frwhoop/activity-venv/bin/python
#   FRWHOOP_ACTIVITY_HOME=/opt/noop/Tools/ActivityContext
#   FRWHOOP_ACTIVITY_MODEL_DIR=/var/lib/frwhoop/activity-model
#   OMP_NUM_THREADS=2          # torch would otherwise spin all four cores next to the scoring lane
#   HF_HUB_OFFLINE=1           # the checkpoint is local; never reach for the network
#   TRANSFORMERS_OFFLINE=1
systemctl restart frwhoop-worker
```

Without a model dir the child boots the numpy baseline instead of the HART checkpoint.

Rollback is `FRWHOOP_ACTIVITY_ENABLED` off (or `activity` in `FRWHOOP_DISABLE_LANES`) and a
restart; the migration is additive and needs no revert.

The lane also stores ActivityContext v2 day documents. Apply the second migration BEFORE (or with) the
worker upgrade, the same way as every other migration (never `supabase db push`):

```bash
psql "$DB_URL" -v ON_ERROR_STOP=1 -1 -f supabase/migrations/20261003130000_activity_context_days.sql
```

A worker that runs before it still publishes the v1 epochs; only its day document fails (counted in the
heartbeat as `context_day_failures`). `FRWHOOP_ACTIVITY_CONTEXT_V2=0` turns the day documents off alone.
Backfill of days that were published before the upgrade is an operator step, see
[docs/BACKEND.md](../docs/BACKEND.md#day-documents-activitycontext-v2).

The third migration adds the stream days (a day document for every UTC day with stored measurements, not
only the few with raw IMU) and the read views. Apply it BEFORE the worker that carries the stream stage:

```bash
psql "$DB_URL" -v ON_ERROR_STOP=1 -1 -f supabase/migrations/20261003140000_activity_context_stream_days.sql
```

A worker that runs before it notes `stream_days` once, backs the stage off for a minute and carries on with
everything else. The stage needs neither Python nor B2, so a host with no venv enables the lane with
`FRWHOOP_ACTIVITY_ENABLED=1 FRWHOOP_ACTIVITY_IMU=0`. `FRWHOOP_ACTIVITY_STREAMS=0` turns the stage off.
Python on Ubuntu 24.04 needs `apt-get install python3.12-venv` before `python3 -m venv` works.

### HART over the phone's raw motion (rawImuSession objects)

Phones from `feat/hart-imu-wiring-20261005` on record the WHOOP 5/MG raw motion stream for HART on their own
(part-time by default, see `ActivityImuCapture`) and upload it as `rawImuSession` objects. Before that build
reaches anyone, the server needs four things, in this order:

1. **Migration** (additive): the `activity_encoder_windows` table and its fenced publish.

   ```bash
   psql "$DB_URL" -v ON_ERROR_STOP=1 -1 -f supabase/migrations/20261005150000_activity_encoder_windows.sql
   ```

2. **Edge functions**: `scores` (the new `GET /scores/activity-windows` route the phone reads HART's windows
   from) and `push` (its object lane must advertise `rawImuSession`; check `GET /push/capabilities` shows an
   `objectLane`). A phone that meets an older `scores` simply decodes without HART.

3. **The Python side on the worker host**: the venv and model above, plus the code itself. The release tarball
   does not carry it, so copy it alongside:

   ```bash
   tar czf activity.tar.gz Tools/ActivityContext
   scp activity.tar.gz root@HOST:/opt/ && ssh root@HOST 'rm -rf /opt/noop/Tools/ActivityContext &&
     tar xzf /opt/activity.tar.gz -C /opt/noop && chown -R frwhoop:frwhoop /opt/noop/Tools/ActivityContext'
   # the trained artifacts (hart-wisdm-v0, sha256 39dc12e0… for model.safetensors) are not in git:
   scp config.json manifest.json model.safetensors root@HOST:/var/lib/frwhoop/activity-model/
   ssh root@HOST 'chown -R frwhoop:frwhoop /var/lib/frwhoop/activity-model && chmod 0644 /var/lib/frwhoop/activity-model/*'
   ```

   Then run the ping check above; it must answer `"model_status": "hart_loaded"`. A worker from this branch
   treats `hart_unavailable` as no model and claims nothing until it loads; older workers claimed and failed
   every job.

4. **The worker** from this branch, with `FRWHOOP_ACTIVITY_ENABLED=1` and the four `FRWHOOP_ACTIVITY_*` paths
   above. It keeps downloaded objects and model answers in `FRWHOOP_ACTIVITY_CACHE_DIR` (default
   `/var/lib/frwhoop/activity-cache`, already writable under the unit; `""` turns it off), so a day's job only
   re-runs HART over the stretch that grew. The cache is disposable: delete it after replacing the model
   without changing its version string.

Verify after the first phone uploads: `object_manifests` gains `rawImuSession` rows, `activity_context_jobs`
gains `hart-activity-1` jobs with non-empty `input_object_ids`, and the activity lane's heartbeat counters
`windows_inferred`, `windows_reused` and `window_sets_published` climb. `window_set_failures` counts window
sets that were not stored (a migration not applied shows up there; the v1 epochs are unaffected).

## Operate / verify

```bash
systemctl status frwhoop-worker
journalctl -u frwhoop-worker -f
# TLS: expect TLSv1.3 rows for the worker:
psql "$FRWHOOP_DB_URL" -c "select pid,ssl,version from pg_stat_ssl join pg_stat_activity using (pid) where application_name like '%frwhoop%';"
# Queues:
psql "$FRWHOOP_DB_URL" -c "select state,count(*) from noop_projection_debt group by 1;"
```

## Recovery

- Stateless worker: every claim is a leased transaction; restarts are safe.
- DB outage: the worker reconnects with capped backoff (or exits for systemd
  restart) — see PostgresClient reconnection.
- Rollback: `git checkout <previous-sha>` + rebuild, or restore the retained
  previous release artifact.
- Supabase DB backups and B2 object retention are SEPARATE concerns; a Droplet
  snapshot is not a raw-data backup.

## Physiology inference sidecar (optional, loopback only)

The candidate (shadow/active) physiology lane calls a Python inference sidecar over
**loopback HTTP**. The sidecar is a second systemd service on the same Droplet and
binds `127.0.0.1` only, so it opens **no public port** and needs no Cloud Firewall
rule and no ufw rule. The Swift worker keeps running normally when the sidecar is
absent or not ready.

- Unit: `deploy/frwhoop-inference.service` (user `frwhoop-inf`, `HOME=/var/lib/frwhoop-inf`,
  `ProtectHome=true`, `ProtectSystem=strict`, `ReadOnlyPaths=/opt/frwhoop-models`,
  `Restart=always`, `TimeoutStopSec=60`). It is deliberately ranked below the worker
  (`CPUWeight=50`, `IOWeight=50`) and capped (`CPUQuota=150%`, `MemoryMax=3G`,
  `MemorySwapMax=0`, `TasksMax=64`) so a model burst cannot starve scoring,
  archiving or the heartbeat on a 4 vCPU / 8 GB host.
- Config: `/etc/frwhoop/inference.env` (0600, root) — names-only template in
  `deploy/inference.env.example`.
- Pinned runtime: `deploy/provision.sh` installs a pinned `uv` (sha256 checked, and
  it **fails closed** when the digest is not supplied) and creates the venv once at
  deploy-prep from the committed `Tools/InferenceWorker/uv.lock`. A normal service
  start resolves no packages, downloads nothing and compiles nothing.
- Artifact cache: `/opt/frwhoop-models/revisions/<manifest-sha256-12>/` with an
  atomic `current` symlink. Every artifact is sha256-verified against the pinned
  manifest at deploy-prep; the sidecar re-verifies at startup and reports
  `ready=false` when one is missing or mismatched. Artifacts marked
  `blocked_license` / `blocked_artifact` / `blocked_input` are never fetched.
- Client side (the worker): `FRWHOOP_INFERENCE_URL` (loopback only),
  `FRWHOOP_INFERENCE_TIMEOUT_MS` (default 25000, kept strictly above the sidecar's
  own 20000 ms budget so the sidecar's withheld/timeout verdict reaches the worker),
  `FRWHOOP_INFERENCE_BUDGET`
  (candidate runs per drain, default 2). **Unset URL = the candidate lane is fully
  off and scoring is byte-identical to the pre-migration behaviour.**

Inference never runs inside a scoring transaction: the candidate stage executes
after the canonical snapshot transaction has committed, calls the sidecar with no
transaction open, and writes its result in a fresh committed transaction.

### Sleep-phenotype enrichment lane (feature/sleep-phenotypes)

The SAME sidecar process serves a second, dedicated endpoint for the descriptive
sleep-phenotype enrichment: `POST /v1/sleep-features` (loopback-only, its own
typed request/response; see `docs/SLEEP_FEATURES_CONTRACT.md`). It is NOT an
inference request and NOT a candidate provider — a bundle of descriptive
features is neither a scalar result nor stage segments, so it never touches the
candidate lane's promotion semantics.

- Trigger: the Swift worker's scoring pass attaches it to the snapshot payload
  under `daily.sleep_features` BEFORE `publish_scoring_snapshot_v2` (a plain
  loopback JSON call, no waveform download / model inference; the repeatable-read
  transaction is bounded by the 3500 ms transport budget around the sidecar's
  own 3000 ms compute budget, and a timeout publishes the core snapshot with
  `sleep_features.status = "timeout"` — core scores never depend on it).
- Rollback / off switch: unset `FRWHOOP_INFERENCE_URL` (or stop the sidecar).
  Snapshots then publish without `daily.sleep_features`, byte-identical in every
  core field; old clients and the scores route are unaffected either way. NO
  database migration is involved (`publish_scoring_snapshot_v2` stores `daily`
  verbatim as jsonb, and the scores edge route passes `daily` through).
- One new pinned dependency: `yasa==0.8.0` in `Tools/InferenceWorker/pyproject.toml`
  (hypnogram analysis only — YASA's PSG classifiers are never applied to WHOOP
  signals). `uv.lock` is committed; deploy-prep resolves it from the lock like
  every other sidecar dependency.
- Deploy step (additive, after the normal sidecar provision): sync
  `Tools/InferenceWorker` to `/opt/frwhoop-inference`, `uv sync --frozen` in its
  venv, then `systemctl restart frwhoop-inference`. Verify with
  `curl -s http://127.0.0.1:8787/healthz` and one loopback smoke POST.
- Phone: no migration, no new route — the Sleep page reads the typed document
  from the cached hosted snapshot (`HostedDayResult.sleepFeatures`), decoded
  non-fatally.

## Sidecar provision (run once per host)

```bash
FRWHOOP_UV_SHA256=<published uv digest> sudo deploy/provision.sh
```

The sidecar section of `provision.sh` is additive: it does not touch the Swift or
SQLite steps. See `deploy/OPERATIONS.md` for start/verify/rollback commands.
