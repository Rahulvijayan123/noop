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
