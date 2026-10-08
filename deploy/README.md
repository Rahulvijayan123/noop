# frwhoop-worker deployment (reproducible)

One DigitalOcean Droplet, one systemd service, outbound-only, TLS-verified.

## Live deployment reference

- Droplet `frwhoop-worker-2` (sfo3, 4 vCPU/8 GB, Ubuntu 24.04, IPv6)
- Service `frwhoop-worker.service` (user `frwhoop`, `ProtectHome=true`,
  `HOME=/var/lib/frwhoop`, restart always, SIGTERM graceful stop)
- Code: one immutable directory per release, `/opt/noop/releases/<id>`, selected by the
  `/opt/noop/current` symlink; the unit runs
  `/opt/noop/current/Tools/CloudWorker/.build/release/frwhoop-worker`. A host provisioned before
  releases existed has the code directly under `/opt/noop` (`Tools`, `contracts`, `deploy`); see
  "Moving an existing host to releases" below.
- Secrets `/etc/frwhoop/worker.env` (0600 root) + `/etc/frwhoop/supabase-ca-chain.pem` (0644)
- DB: `sslmode=verify-full` against the pinned Supabase CA chain — the worker
  refuses plaintext (`FRWHOOP_ALLOW_INSECURE_DB=1` is local-dev only). Verified
  live: `pg_stat_ssl` shows `TLSv1.3` for the worker's backends.

## Cold provision (run once per host)

```bash
sudo deploy/provision.sh          # or copy step-by-step below
```

The script resolves its own directory and the repository root before it changes directory, so the
relative form works from any cwd. Steps (what provision.sh automates):
1. Packages: `build-essential clang curl unzip git pkg-config libpq-dev
   zlib1g-dev libssl-dev libzstd-dev postgresql-client`
2. Swift 6.0.3 (pinned tarball + sha256) from swift.org ubuntu2404 x86_64
3. Private snapshot-enabled SQLite (GRDB needs `sqlite3_snapshot_*`;
   distro builds omit it): pinned amalgamation 3530400 + sha256 check,
   built with `-DSQLITE_ENABLE_SNAPSHOT=1` at `/opt/sqlite`
4. `frwhoop` service user + `/etc/frwhoop` + `/var/lib/frwhoop` (HOME) + `/opt/noop/releases`
5. Unit install + `systemd-analyze verify`
6. The inference sidecar (see "Physiology inference sidecar" below)

`--sidecar-only` runs only step 6, and `--models-only --models-root DIR` runs only the sidecar's
model revision step, unprivileged (see [docs/model-integration/provisioning.md](../docs/model-integration/provisioning.md)).

## Build + release

A release is ONE git revision of everything the worker build and its tests read:
`Tools/CloudWorker`, the local packages its `Package.swift` reaches (today `Packages/StrandAnalytics`,
`WhoopProtocol`, `WhoopStore` and, through WhoopStore, `OuraProtocol`; derived from the
`Package.swift` files, never listed by hand), the repository files those packages' tests read by
path (the `android/app/src/test/resources` oracles, `Tools/MetricInsight/tests/data`, an
`Tools/EnergyModels` fixture), `contracts`, `deploy`, `Tools/ActivityContext`,
`Tools/InferenceWorker` and the licence files. Extracting only some directories over an old tree
used to leave a host building against whatever `Packages/` it still had; a release is therefore
always extracted into a fresh directory, built there, and selected with a symlink.

1. **Package** (developer machine, clean checkout of the revision to ship):

   ```bash
   deploy/package-release.sh --out ~/nara-releases          # HEAD; --rev <commit> for another
   ```

   It refuses uncommitted changes in the release paths; `--allow-dirty` packages them and stamps the
   release `dirty: true` (id `<commit>-dirty-<tree>`). Output: `nara-release-<id>.tar.gz` (a
   `git archive`), its `.sha256`, `nara-release-<id>.release.json` (the stamp, readable before
   extracting) and `release-host.sh` from the same revision. Inside, `RELEASE.files` lists every
   file's sha256 (`sha256sum -c RELEASE.files` works) and `RELEASE.json` records the commit, tree,
   dirty flag, `Package.resolved` / `uv.lock` / manifest digests, included paths and the digest of
   `RELEASE.files`.

2. **Copy** to the host:

   ```bash
   scp ~/nara-releases/nara-release-<id>.tar.gz{,.sha256} ~/nara-releases/release-host.sh \
     root@HOST:/opt/noop/incoming/
   ```

3. **Install** into a fresh `/opt/noop/releases/<id>` (refused when that directory exists; the tarball
   checksum and every stamped file are verified before it is moved into place):

   ```bash
   bash /opt/noop/incoming/release-host.sh install /opt/noop/incoming/nara-release-<id>.tar.gz
   ```

4. **Build and test there**, against the private SQLite:

   ```bash
   /opt/noop/releases/<id>/deploy/release-host.sh build <id>
   ```

   This runs `swift build -c release` and `swift test` in `releases/<id>/Tools/CloudWorker`
   (`-Xcc -I/opt/sqlite -Xlinker -L/opt/sqlite`, `LD_LIBRARY_PATH=/opt/sqlite`), writes
   `releases/<id>/BUILD.json` (the binary's sha256, Swift version, test summary), runs the new binary
   with `--print-identity` and refuses the release unless it reports `matches_release: true`, deletes
   the test build products, and makes the release read-only. A failed test leaves no `BUILD.json`,
   so the release cannot be selected. The log is in `/opt/noop/releases/.logs/<id>/`.

5. **Sidecar from the same release** (hosts that run it):

   ```bash
   FRWHOOP_UV_SHA256=<published uv digest> /opt/noop/releases/<id>/deploy/provision.sh --sidecar-only
   ```

   It creates `/opt/frwhoop-inference/venvs/<id>` from that release's `uv.lock`, switches
   `/opt/frwhoop-inference/venv` to it, and stages the model revision (below).

6. **Switch, then restart**:

   ```bash
   /opt/noop/releases/<id>/deploy/release-host.sh switch <id>
   systemctl restart frwhoop-worker            # and frwhoop-inference after step 5
   ```

   `current` is replaced atomically (a new symlink renamed over the old one); the release it pointed
   to becomes `previous`. `switch` refuses a release without `BUILD.json`, or whose binary no longer
   has the recorded digest. If this release's unit file differs from the installed one it prints the
   install command; install it before restarting.

7. **Verify** with the runtime checklist in [OPERATIONS.md](OPERATIONS.md#runtime-identity-checklist):
   the heartbeat's `meta.identity.matches_release` must be `true` and its `release.git_commit` the
   commit you shipped.

`release-host.sh status` lists the releases, `current`, `previous` and the current binary's identity.

How each component of a release is used:

| Component | Installed as | Runs from |
| --- | --- | --- |
| `Tools/CloudWorker` + `Packages/*` | built in place by `release-host.sh build` | `/opt/noop/current/Tools/CloudWorker/.build/release/frwhoop-worker` |
| `Tools/ActivityContext` | used in place; its third-party packages stay in `/var/lib/frwhoop/activity-venv` | `FRWHOOP_ACTIVITY_HOME=/opt/noop/current/Tools/ActivityContext` |
| `Tools/InferenceWorker` | `provision.sh --sidecar-only` from the release: `/opt/frwhoop-inference/venvs/<id>` (editable install of the release's source) | `/opt/frwhoop-inference/venv -> venvs/<id>` |
| `deploy` | unit files and these scripts, from the release that is selected | |
| `contracts`, test fixtures | read by `swift test` during `build` | |

### Rollback

```bash
/opt/noop/current/deploy/release-host.sh rollback && systemctl restart frwhoop-worker
# the sidecar, when it was moved too: re-run the previous release's sidecar step
/opt/noop/releases/<previous>/deploy/provision.sh --sidecar-only && systemctl restart frwhoop-inference
```

The previous release is never deleted by these scripts. Delete old releases by hand once they are
neither `current` nor `previous` (a built release is about 1 GB with the test build pruned):
`chmod -R u+w /opt/noop/releases/<old> && rm -rf /opt/noop/releases/<old>`.

### Moving an existing host to releases (once)

The old layout (`/opt/noop/{Tools,contracts,deploy}` extracted in place, unit pointing at
`/opt/noop/Tools/CloudWorker/.build/release`) stays untouched; it is the rollback target for the
first move.

1. Steps 1-5 above (`mkdir -p /opt/noop/incoming /opt/noop/releases` first).
2. In `/etc/frwhoop/worker.env`, point `FRWHOOP_ACTIVITY_HOME` at
   `/opt/noop/current/Tools/ActivityContext` (an old path would keep running the OLD activity code).
3. `release-host.sh switch <id>`, then install the release's unit and restart:
   `install -m 644 /opt/noop/current/deploy/frwhoop-worker.service /etc/systemd/system/ &&
   systemctl daemon-reload && systemctl restart frwhoop-worker`. The drop-in
   `frwhoop-worker.service.d/no-projection-replay.conf` is kept.
4. Rolling back to the old layout: `install -m 644 /opt/noop/deploy/frwhoop-worker.service
   /etc/systemd/system/ && systemctl daemon-reload && systemctl restart frwhoop-worker` (and the old
   `FRWHOOP_ACTIVITY_HOME`).

## Configure

`/etc/frwhoop/worker.env` (names-only template: `deploy/worker.env.example`):
DB URL + `FRWHOOP_DB_SSLMODE=verify-full` + `FRWHOOP_DB_SSLROOTCERT=/etc/frwhoop/supabase-ca-chain.pem`,
B2 key id + application key, ingest secret, worker name, source revision, lane budgets.
`FRWHOOP_SOURCE_REVISION` is only a claim: the heartbeat's `meta.identity` reports the digest of the
binary that actually runs and whether its release's build record names it.

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
  "cd /opt/noop/current/Tools/ActivityContext && HOME=/var/lib/frwhoop $PY -m activity_context.serve \
   --manifest /var/lib/frwhoop/activity-model/manifest.json --checkpoint /var/lib/frwhoop/activity-model"
# the ping must answer "model_status": "hart_loaded"; then enable in /etc/frwhoop/worker.env:
#   FRWHOOP_ACTIVITY_ENABLED=1
#   FRWHOOP_ACTIVITY_PYTHON=/var/lib/frwhoop/activity-venv/bin/python
#   FRWHOOP_ACTIVITY_HOME=/opt/noop/current/Tools/ActivityContext   (the selected release's code)
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

3. **The Python side on the worker host**: the venv and model above. The code itself is part of every
   release (`/opt/noop/current/Tools/ActivityContext`, the same revision as the worker), so nothing is
   copied separately:

   ```bash
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
# What actually runs (see OPERATIONS.md, "Runtime identity checklist"):
/opt/noop/current/deploy/release-host.sh status
psql "$FRWHOOP_DB_URL" -Atc "select meta->'identity' from scoring_service_heartbeats where id = 1;"
```

## Recovery

- Stateless worker: every claim is a leased transaction; restarts are safe.
- DB outage: the worker reconnects with capped backoff (or exits for systemd
  restart) — see PostgresClient reconnection.
- Rollback: `release-host.sh rollback` and a restart (see "Rollback" above); the
  previous release is kept on disk, already built.
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
  it **fails closed** when the digest is not supplied) and creates one venv per
  release, `/opt/frwhoop-inference/venvs/<release id>`, at deploy-prep from that
  release's committed `Tools/InferenceWorker/uv.lock`; `/opt/frwhoop-inference/venv`
  points at it. A normal service start resolves no packages, downloads nothing and
  compiles nothing.
- Artifact cache: `/opt/frwhoop-models/revisions/<id>/` (read-only, with the
  manifest it was staged from and a `revision.json`) and an atomic `current`
  symlink. `Tools/InferenceWorker/scripts/materialize_model_root.py` stages a
  complete revision from the manifest's artifact sources (the SleepECG checkpoint
  comes from the installed `sleepecg` wheel; the optional ParaDigMa, DeepBeat and
  SiamAF files are downloaded and checked against their pinned sha256 and size),
  verifies it with the sidecar's own verifier, builds the sidecar's provider
  registry against it as the service user to prove readiness, and only then
  switches `current`. A missing or mismatched required artifact, or a required
  provider that is not ready, leaves `current` where it was; a missing optional
  artifact withholds only its own provider. Entries marked `blocked_license` /
  `blocked_input` / `unverified`, or not wired, are recorded and never fetched. The
  sidecar re-verifies at startup and reports `ready=false` when an artifact is
  missing or mismatched. Details: [docs/model-integration/provisioning.md](../docs/model-integration/provisioning.md).
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
- Deploy step: the sidecar step of a release (`provision.sh --sidecar-only` from
  `/opt/noop/releases/<id>`, step 5 of "Build + release"), then
  `systemctl restart frwhoop-inference`. Verify with
  `curl -s http://127.0.0.1:8787/healthz` and one loopback smoke POST.
- Phone: no migration, no new route — the Sleep page reads the typed document
  from the cached hosted snapshot (`HostedDayResult.sleepFeatures`), decoded
  non-fatally.

## Sidecar provision and model revisions

```bash
FRWHOOP_UV_SHA256=<published uv digest> sudo deploy/provision.sh                 # cold host
FRWHOOP_UV_SHA256=<published uv digest> /opt/noop/releases/<id>/deploy/provision.sh --sidecar-only
```

The sidecar section of `provision.sh` does not touch the Swift or SQLite steps, and
`--sidecar-only` runs nothing else. Its model step is the sidecar's own materializer and verifier
(`Tools/InferenceWorker/scripts/materialize_model_root.py` with `frwhoop_inference.artifacts`),
run with the release's venv; the shell never parses the manifest. In order:

1. **Plan** from `models/manifest.json`: every entry and nested artifact gets an action
   (`stage`, `check_installed`, `record`, `skip`) and a reason. Only wired `eligible` /
   `shadow_eligible` entries are staged; blocked, unverified and unwired entries are recorded,
   never fetched. Print it without touching anything:
   `/opt/frwhoop-inference/venv/bin/python /opt/noop/current/Tools/InferenceWorker/scripts/materialize_model_root.py plan`.
2. **Stage** a complete revision in `/opt/frwhoop-models/revisions/.staging-*`: the SleepECG
   checkpoint is copied from the installed `sleepecg` wheel and its inner `classifier.keras`
   extracted from that zip; optional `url` artifacts are fetched over HTTPS (or taken from a
   `--mirror DIR`), size-capped, and installed only after their pinned sha256 and size match.
   `--offline` fetches nothing and records the optional ones as missing.
3. **Verify** every staged artifact with `verify_manifest` (the check the sidecar runs at
   startup), then **probe**: a child process builds the sidecar's `Application` against the staged
   root with the service's environment (from the unit and `/etc/frwhoop/inference.env`), as
   `frwhoop-inf`.
4. **Reject or select.** A missing or mismatched required artifact, or a required provider that
   is not ready, rejects the revision: staging is removed, `current` is untouched, the script
   exits non-zero. Otherwise `revision.json` is written, the tree is made read-only, renamed to
   `revisions/<id>` (a content id over the manifest digest and the verified artifact digests, so
   a re-run with the same bytes selects the same revision) and `current` is replaced atomically
   (a temporary symlink renamed over it). A missing optional artifact is recorded in
   `revision.json` `withheld` and withholds only its own provider.
5. **Restart** `frwhoop-inference`: it resolves `current` once at startup and keeps that revision
   for its lifetime, so a later switch never changes a running process underneath it.

Model rollback: `materialize_model_root.py list --models-root /opt/frwhoop-models`, then
`select --models-root /opt/frwhoop-models <revision-id>` and restart the sidecar (see
[OPERATIONS.md](OPERATIONS.md#rollback)). The model step alone, unprivileged, against any
directory (operators and tests use the same code path):
`deploy/provision.sh --models-only --models-root DIR [--offline] [--mirror DIR]`.

## Identity checks after a deploy

Run the read-only [runtime identity checklist](OPERATIONS.md#runtime-identity-checklist). In short:

- the heartbeat's `meta.identity.executable.sha256` equals `sha256sum /proc/<worker pid>/exe` and
  `BUILD.json`'s recorded digest, `matches_release` is `true`, and `release.git_commit` is the
  commit you shipped;
- the sidecar's `GET /healthz` `identity` names the same commit in `code_revision`, with
  `source_matches_release`, `uv_lock_matches_release` and `manifest.matches_release` all `true`,
  the selected `model_revision.revision_id` equal to `readlink /opt/frwhoop-models/current`, and
  every required artifact `verified`;
- `FRWHOOP_SOURCE_REVISION` is only `claimed_source_revision` in both; it proves nothing.

A release built on another architecture (for example the arm64 Linux build used to check a
release before shipping) has a different binary digest from the x86_64 droplet's build of the same
commit; only the droplet's own `BUILD.json` and process digest identify what it runs.

## Rolling out the Spec 01 model-integration changes

Every new behaviour is off or unchanged by default. When an operator chooses to roll it out (not done
by the Spec 01 branch), the order matters; details are in `docs/model-integration/`.

1. **Migrations**, in timestamp order: `20261008100000_activity_release_authority.sql` (expert rows
   carry `release_mode`/`authority`; joint candidate table), `20261008110000_physiology_candidate_pending.sql`
   (persisted candidate queue), `20261008120000_ppg_transport_anchor.sql` (protocol 1.5 objects). They are
   additive and re-runnable. Follow [docs/BACKEND.md](../docs/BACKEND.md); never `supabase db push` from
   a workstation.
2. **The `scores` edge function** after migration 20261008100000: its gait/activity routes select the new
   columns.
3. **Sidecar and worker** from one release (`release-host.sh`), then the identity checks above. The worker
   and the candidate migration can go in either order (without the migration the worker keeps the
   in-memory candidate pass). The worker must be the new one before step 4: an older worker refuses NPB1
   format 3 objects (`unsupportedVersion`).
4. **Receiver advertisement** of protocol 1.5: `NOOP_PUSH_ADVERTISE_PPG_ANCHOR=1` in the push function's
   environment. Accepting 1.5 does not depend on it.
5. **Phone flag** `noop.cloud.ppgAnchorUpload` (off by default) only after step 4. It adds roughly 80 bytes
   of upload per optical second. Turning it on is an owner decision.

Resource notes. The sidecar's limits in `frwhoop-inference.service` fit one warm infer worker
(measured about 373 MB for the parent plus both workers); raise `MemoryHigh` before setting
`FRWHOOP_INFERENCE_MAX_ACTIVE=2`. The activity children run in the worker's unit. With every activity stage
on, they add about 1.1 GiB (HART about 454 MB, ElderNet 302 MB, Inertia about 235 MB, an ActiNet encoder
about 361 MB). Their math threads are capped at one each by default (`FRWHOOP_ACTIVITY_THREADS`,
`FRWHOOP_ELDERNET_THREADS`, `FRWHOOP_INERTIA_THREADS`). `frwhoop-worker.service` sets no memory or task
limit. Measure the worker's own RSS on the droplet before adding one (suggested: `MemoryHigh` at worker
RSS plus 1.2 GiB, and a `TasksMax`), so a guessed ceiling never kills the scoring lane.
