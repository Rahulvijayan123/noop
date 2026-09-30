# frwhoop-worker deployment

One DigitalOcean Droplet (Ubuntu 24.04), one systemd service, outbound-only.

## Provision (once)

```bash
# Region near the Supabase project (us-west-2 -> sfo3), 4 vCPU / 8 GB.
doctl compute droplet create frwhoop-worker-2 \
  --region sfo3 --size s-4vcpu-8gb --image ubuntu-24-04-x64 \
  --ssh-keys <key-id> --ipv6 --monitoring --tag-names frwhoop,worker

# Base packages
apt-get update && apt-get install -y \
  build-essential clang curl unzip git pkg-config \
  libpq-dev zlib1g-dev libssl-dev zstd python3

# Swift 6 (x86_64 tarball from swift.org; pin the exact version)
curl -fsSLo /opt/swift.tar.gz \
  https://download.swift.org/swift-6.0.3-release/ubuntu2404/swift-6.0.3-RELEASE/swift-6.0.3-RELEASE-ubuntu24.04.tar.gz
tar xzf /opt/swift.tar.gz -C /opt && ln -sf /opt/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin/* /usr/local/bin/

# Private snapshot-enabled SQLite (GRDB needs sqlite3_snapshot_*; distro builds omit it)
mkdir -p /opt/sqlite && cd /opt/sqlite
curl -fsSLo sqlite.zip https://sqlite.org/2026/sqlite-amalgamation-3530400.zip
unzip -p sqlite.zip sqlite-amalgamation-3530400/sqlite3.c > sqlite3.c
unzip -p sqlite.zip sqlite-amalgamation-3530400/sqlite3.h > sqlite3.h
echo "b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189  sqlite3.c" | sha256sum --check
cc -shared -fPIC -DSQLITE_ENABLE_SNAPSHOT=1 sqlite3.c -o libsqlite3.so.0
ln -sf libsqlite3.so.0 libsqlite3.so
```

## Build

```bash
git clone -b cloud-worker https://github.com/Rahulvijayan123/noop.git /opt/noop
cd /opt/noop/Tools/CloudWorker
swift build -c release
```

## Configure

```bash
useradd -r -s /usr/sbin/nologin frwhoop
install -m 600 /dev/null /etc/frwhoop/worker.env
# Fill from your secret store (never commit):
#   FRWHOOP_DB_URL=postgres://...@db.<project>.supabase.co:5432/postgres
#   FRWHOOP_B2_KEY_ID=...
#   FRWHOOP_B2_APPLICATION_KEY=...
#   FRWHOOP_B2_BUCKET=FRWHOOP
#   FRWHOOP_WORKER_NAME=frwhoop-worker-2
#   FRWHOOP_SOURCE_REVISION=<git sha>
#   FRWHOOP_ALGORITHM_VERSION=frwhoop-server-1
cp deploy/frwhoop-worker.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now frwhoop-worker
```

## Operate

```bash
systemctl status frwhoop-worker
journalctl -u frwhoop-worker -f
# Heartbeat + queue depth in Postgres:
psql "$FRWHOOP_DB_URL" -c "select * from scoring_service_heartbeats;"
psql "$FRWHOOP_DB_URL" -c "select state, count(*) from noop_projection_debt group by 1;"
```

## Recovery

- The worker is stateless: every claim is a leased Postgres transaction; a kill
  mid-job just expires the lease and redelivers.
- Rebuild from the verified cloud inputs: the worker cache is disposable.
- Rollback: `git checkout <previous-sha> && swift build -c release && systemctl restart frwhoop-worker`.
