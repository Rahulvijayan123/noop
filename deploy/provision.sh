#!/bin/bash
# Cold-host provision for frwhoop-worker (Ubuntu 24.04 x86_64). Pinned, idempotent-ish.
set -euo pipefail

SWIFT_VER=swift-6.0.3-RELEASE
SWIFT_SHA256_REQUIRED=1   # verify the tarball sha256 before trusting it (fill from swift.org)
SQLITE_AMALGamation=3530400
SQLITE_SHA256=b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189

echo "== packages =="
apt-get update -y
apt-get install -y build-essential clang curl unzip git pkg-config \
  libpq-dev zlib1g-dev libssl-dev libzstd-dev postgresql-client

echo "== swift =="
if ! command -v swift >/dev/null || ! swift --version 2>/dev/null | grep -q 6.0.3; then
  cd /opt
  curl -fsSLo swift.tar.gz "https://download.swift.org/swift-6.0.3-release/ubuntu2404/swift-6.0.3-RELEASE/${SWIFT_VER}-ubuntu24.04.tar.gz"
  # sha256sum -c against the published digest here (SWIFT_SHA256) once recorded
  tar xzf swift.tar.gz && rm swift.tar.gz
  ln -sf /opt/${SWIFT_VER}-ubuntu24.04/usr/bin/* /usr/local/bin/ || true
fi
swift --version

echo "== private snapshot sqlite =="
mkdir -p /opt/sqlite && cd /opt/sqlite
curl -fsSLo sqlite.zip "https://sqlite.org/2026/sqlite-amalgamation-${SQLITE_AMALGamation}.zip"
unzip -o -q sqlite.zip
unzip -p sqlite.zip "sqlite-amalgamation-${SQLITE_AMALGamation}/sqlite3.c" > sqlite3.c
unzip -p sqlite.zip "sqlite-amalgamation-${SQLITE_AMALGamation}/sqlite3.h" > sqlite3.h
echo "${SQLITE_SHA256}  sqlite3.c" | sha256sum --check
cc -shared -fPIC -DSQLITE_ENABLE_SNAPSHOT=1 sqlite3.c -o libsqlite3.so.0
ln -sf libsqlite3.so.0 libsqlite3.so
# Verify the snapshot API is actually present in the built library:
nm -D libsqlite3.so | grep -q sqlite3_snapshot_get || { echo "snapshot API missing"; exit 1; }

echo "== service user + dirs =="
id frwhoop >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin frwhoop
mkdir -p /etc/frwhoop /var/lib/frwhoop
chown frwhoop:frwhoop /var/lib/frwhoop

echo "== systemd unit =="
install -m 644 "$(dirname "$0")/frwhoop-worker.service" /etc/systemd/system/frwhoop-worker.service
systemd-analyze verify /etc/systemd/system/frwhoop-worker.service || true
systemctl daemon-reload

echo "== next steps =="
cat <<'EOF'
1. Install /etc/frwhoop/worker.env (0600) from deploy/worker.env.example
   (DB URL, verify-full TLS, B2 creds, ingest secret, lane budgets).
2. Install /etc/frwhoop/supabase-ca-chain.pem (0644) from deploy/supabase-ca-chain.pem.
3. Build + release per deploy/README.md, then:
   systemctl enable --now frwhoop-worker
EOF
