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

## Sidecar provision (run once per host)

```bash
FRWHOOP_UV_SHA256=<published uv digest> sudo deploy/provision.sh
```

The sidecar section of `provision.sh` is additive: it does not touch the Swift or
SQLite steps. See `deploy/OPERATIONS.md` for start/verify/rollback commands.
