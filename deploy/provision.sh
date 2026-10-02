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

# =============================================================================
# ADDED SECTION: FRWHOOP physiology inference sidecar (loopback only)
# -----------------------------------------------------------------------------
# Nothing above this line is modified. This section provisions the OPTIONAL
# Python inference sidecar that the Swift worker calls over loopback. It creates a
# SEPARATE user, SEPARATE directories and a SEPARATE systemd unit, and it opens no
# public port (the sidecar binds 127.0.0.1), so no Cloud Firewall rule and no ufw
# rule are needed. The Swift worker keeps running with the sidecar absent.
#
# FAIL-CLOSED ARTIFACT POLICY (deliberate, and unlike the Swift toolchain check
# above, which records a digest it never verifies): every downloaded artifact is
# checked against a PINNED sha256. A missing digest aborts the run rather than
# trusting unverified bytes. Nothing is downloaded at inference time.
# =============================================================================

SIDECAR_ROOT="${FRWHOOP_SIDECAR_ROOT:-/opt/frwhoop-inference}"
MODELS_ROOT="${FRWHOOP_MODELS_ROOT:-/opt/frwhoop-models}"
UV_VERSION="${FRWHOOP_UV_VERSION:-0.9.5}"
UV_SHA256="${FRWHOOP_UV_SHA256:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${FRWHOOP_MODEL_MANIFEST:-$REPO_ROOT/Tools/InferenceWorker/models/manifest.json}"

echo "== sidecar: packages =="
apt-get install -y python3 ca-certificates

echo "== sidecar: service user + dirs =="
id frwhoop-inf >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin frwhoop-inf
mkdir -p "$SIDECAR_ROOT" "$MODELS_ROOT" /var/lib/frwhoop-inf /etc/frwhoop
chown frwhoop-inf:frwhoop-inf /var/lib/frwhoop-inf
chmod 0755 "$SIDECAR_ROOT" "$MODELS_ROOT"

echo "== sidecar: pinned uv ${UV_VERSION} =="
if [ ! -x "/opt/uv/${UV_VERSION}/uv" ]; then
  if [ -z "$UV_SHA256" ]; then
    echo "FATAL: FRWHOOP_UV_SHA256 is not set." >&2
    echo "       Set it to the published sha256 of uv-${UV_VERSION}-x86_64-unknown-linux-gnu.tar.gz" >&2
    echo "       (https://github.com/astral-sh/uv/releases) and re-run. Refusing to install" >&2
    echo "       an unverified interpreter toolchain." >&2
    exit 1
  fi
  mkdir -p "/opt/uv/${UV_VERSION}" /tmp/uv-dl
  # Bounded: one retry (two attempts total) on a network fetch.
  curl -fsSL --retry 1 -o /tmp/uv-dl/uv.tar.gz \
    "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz"
  echo "${UV_SHA256}  /tmp/uv-dl/uv.tar.gz" | sha256sum --check
  tar xzf /tmp/uv-dl/uv.tar.gz -C "/opt/uv/${UV_VERSION}" --strip-components=1
  rm -rf /tmp/uv-dl
fi
ln -sf "/opt/uv/${UV_VERSION}/uv" /usr/local/bin/uv
ln -sf "/opt/uv/${UV_VERSION}/uvx" /usr/local/bin/uvx 2>/dev/null || true
/usr/local/bin/uv --version

echo "== sidecar: pinned venv (deploy-prep only; never at inference time) =="
if [ -f "$REPO_ROOT/Tools/InferenceWorker/uv.lock" ]; then
  UV_PYTHON_DOWNLOADS=never /usr/local/bin/uv sync --frozen \
    --project "$REPO_ROOT/Tools/InferenceWorker" \
    --python-preference only-system
  rm -rf "$SIDECAR_ROOT/venv"
  ln -sfn "$REPO_ROOT/Tools/InferenceWorker/.venv" "$SIDECAR_ROOT/venv"
  test -x "$SIDECAR_ROOT/venv/bin/python" || { echo "FATAL: sidecar venv missing"; exit 1; }
else
  echo "SKIP: $REPO_ROOT/Tools/InferenceWorker/uv.lock not present (sidecar package not checked out)"
fi

echo "== sidecar: model artifact cache + manifest verification =="
if [ -f "$MANIFEST" ]; then
  STAGING="$(mktemp -d /tmp/frwhoop-models.XXXXXX)"
  # The manifest schema is owned by Tools/InferenceWorker. This reader accepts a
  # top-level array or {"artifacts": [...]}, and the common field aliases, so a
  # schema tweak does not silently skip verification. Only entries that are
  # actually fetchable are downloaded: a blocked_license / blocked_artifact /
  # blocked_input entry is RECORDED, never fetched.
  python3 - "$MANIFEST" > "$STAGING/fetch.tsv" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
entries = doc if isinstance(doc, list) else doc.get("artifacts", doc.get("models", []))
if isinstance(entries, dict):
    entries = [dict(v, **{"name": k}) for k, v in entries.items()]
skip = {"blocked_license", "blocked_artifact", "blocked_input"}
for e in entries:
    if not isinstance(e, dict):
        continue
    status = str(e.get("status", "") or "").lower()
    url = e.get("url") or e.get("artifact_url") or ""
    sha = e.get("sha256") or e.get("artifact_sha256") or ""
    rel = e.get("path") or e.get("relative_path") or e.get("file") or e.get("name") or ""
    if status in skip or not url or not sha or not rel:
        print("SKIP\t%s\t%s\t%s" % (e.get("name", rel or "?"), status or "no-artifact", sha[:12]))
        continue
    print("FETCH\t%s\t%s\t%s" % (sha, url, rel))
PY
  # The manifest digest names the immutable revision directory, so a re-run with
  # the same manifest is idempotent and a changed manifest lands somewhere new.
  REVISION="$(sha256sum "$MANIFEST" | cut -c1-12)"
  REV_DIR="$MODELS_ROOT/revisions/$REVISION"
  mkdir -p "$REV_DIR"
  while IFS=$'\t' read -r kind a b c; do
    case "$kind" in
      SKIP)
        echo "  skip artifact: $a ($b)" ;;
      FETCH)
        target="$STAGING/$(basename "$c")"
        echo "  fetch artifact: $c"
        curl -fsSL --retry 1 -o "$target" "$b"
        echo "$a  $target" | sha256sum --check
        install -D -m 0644 "$target" "$REV_DIR/$c"
        ;;
    esac
  done < "$STAGING/fetch.tsv"
  install -m 0644 "$MANIFEST" "$REV_DIR/manifest.json"
  rm -rf "$STAGING"
  # Atomically switch `current` only after every fetchable artifact verified.
  # The service user can READ the cache and cannot write it (ReadOnlyPaths=).
  chmod -R a+rX "$REV_DIR"
  ln -sfn "$REV_DIR" "$MODELS_ROOT/current"
  echo "  artifact cache ready: $MODELS_ROOT/current -> $REV_DIR"
else
  echo "SKIP: no model manifest at $MANIFEST (sidecar package not checked out)"
fi

echo "== sidecar: systemd unit =="
install -m 644 "$(dirname "$0")/frwhoop-inference.service" /etc/systemd/system/frwhoop-inference.service
systemd-analyze verify /etc/systemd/system/frwhoop-inference.service || true
systemctl daemon-reload

echo "== sidecar: next steps =="
cat <<'EOF'
1. Install /etc/frwhoop/inference.env (0600, root-owned) from deploy/inference.env.example.
2. Confirm the sidecar port is free on the host:  ss -ltnp | grep 8787
   (the bind is 127.0.0.1 only; no Cloud Firewall or ufw rule is required)
3. systemctl enable --now frwhoop-inference
4. Check readiness:  curl -s http://127.0.0.1:8787/healthz | head
   A missing or mismatched artifact must report ready=false, never a silent fallback.
5. Only then enable the client side: set FRWHOOP_INFERENCE_URL=http://127.0.0.1:8787
   in /etc/frwhoop/worker.env and restart frwhoop-worker. Leaving it unset keeps the
   candidate lane completely off.
EOF
