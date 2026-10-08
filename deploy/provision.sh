#!/bin/bash
# Cold-host provision for frwhoop-worker (Ubuntu 24.04 x86_64). Pinned, idempotent-ish.
#
#   sudo deploy/provision.sh                  everything below, once per host
#   sudo deploy/provision.sh --sidecar-only   only the inference sidecar: venv, model revision, unit
#                                             (run from the release the sidecar should serve)
#   deploy/provision.sh --models-only --models-root DIR [--python PY] [--offline] [--mirror DIR]...
#                       [--service-env FILE] [--probe-user USER]
#                                             only the model revision, against DIR; needs no root,
#                                             no apt and no systemd (operators and tests)
#
# The model section is the same function in every mode: it runs the sidecar's materializer
# (Tools/InferenceWorker/scripts/materialize_model_root.py) with the sidecar venv, which stages a
# revision, verifies it with the sidecar's own verifier, probes provider readiness and only then
# switches `current` (docs/model-integration/provisioning.md).
set -euo pipefail

# Resolve this script and the repository before anything changes directory, so the documented
# relative invocation (`sudo deploy/provision.sh`) works from any cwd. Nothing below uses a
# relative path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

usage() {
  sed -n '3,11p' "$SCRIPT_DIR/provision.sh" | sed 's/^# \{0,1\}//'
}

MODE=full
MODELS_ROOT_ARG=""
PYTHON_ARG=""
OFFLINE=0
SERVICE_ENV_ARG=""
PROBE_USER_ARG=""
MIRRORS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --models-only) MODE=models ;;
    --sidecar-only) MODE=sidecar ;;
    --models-root) MODELS_ROOT_ARG="${2:?--models-root needs a directory}"; shift ;;
    --python) PYTHON_ARG="${2:?--python needs an interpreter}"; shift ;;
    --offline) OFFLINE=1 ;;
    --mirror) MIRRORS+=("${2:?--mirror needs a directory}"); shift ;;
    --service-env) SERVICE_ENV_ARG="${2:?--service-env needs a file}"; shift ;;
    --probe-user) PROBE_USER_ARG="${2:?--probe-user needs a user}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "provision.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

SWIFT_VER=swift-6.0.3-RELEASE
SWIFT_SHA256_REQUIRED=1   # verify the tarball sha256 before trusting it (fill from swift.org)
SQLITE_AMALGamation=3530400
SQLITE_SHA256=b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189

SIDECAR_ROOT="${FRWHOOP_SIDECAR_ROOT:-/opt/frwhoop-inference}"
MODELS_ROOT="${FRWHOOP_MODELS_ROOT:-/opt/frwhoop-models}"
UV_VERSION="${FRWHOOP_UV_VERSION:-0.9.5}"
UV_SHA256="${FRWHOOP_UV_SHA256:-}"
MANIFEST="${FRWHOOP_MODEL_MANIFEST:-$REPO_ROOT/Tools/InferenceWorker/models/manifest.json}"
MATERIALIZER="$REPO_ROOT/Tools/InferenceWorker/scripts/materialize_model_root.py"

# Replace a symlink atomically: a new link under a temporary name, then rename(2) over the old
# one. `ln -sfn` unlinks first and leaves a moment with no link at all.
switch_link() {
  local target="$1" link="$2"
  local temporary
  temporary="$(dirname "$link")/.$(basename "$link").tmp.$$"
  ln -s "$target" "$temporary"
  mv -Tf "$temporary" "$link"
}

# The model section: stage, verify, probe, then switch `current` (or leave it and fail).
# $1 = sidecar python, $2 = models root, the rest is passed to the materializer.
provision_models() {
  local python="$1" models_root="$2"
  shift 2
  if [ ! -f "$MANIFEST" ]; then
    echo "FATAL: no model manifest at $MANIFEST" >&2
    return 1
  fi
  if [ ! -x "$python" ]; then
    echo "FATAL: sidecar python $python is missing; run uv sync --frozen in" >&2
    echo "       $REPO_ROOT/Tools/InferenceWorker first (or pass --python)" >&2
    return 1
  fi
  local args=(stage --models-root "$models_root" --manifest "$MANIFEST"
              --service-unit "$SCRIPT_DIR/frwhoop-inference.service")
  "$python" "$MATERIALIZER" "${args[@]}" "$@"
}

if [ "$MODE" = models ]; then
  if [ -z "$MODELS_ROOT_ARG" ]; then
    echo "provision.sh: --models-only needs --models-root DIR" >&2
    exit 2
  fi
  PY="${PYTHON_ARG:-$REPO_ROOT/Tools/InferenceWorker/.venv/bin/python}"
  extra=()
  [ "$OFFLINE" = 1 ] && extra+=(--offline)
  [ -n "$SERVICE_ENV_ARG" ] && extra+=(--service-env "$SERVICE_ENV_ARG")
  [ -n "$PROBE_USER_ARG" ] && extra+=(--probe-user "$PROBE_USER_ARG")
  for mirror in ${MIRRORS[@]+"${MIRRORS[@]}"}; do extra+=(--mirror "$mirror"); done
  echo "== models: $MODELS_ROOT_ARG (manifest $MANIFEST) ==" >&2
  # The JSON report goes to stdout, the progress lines to stderr.
  provision_models "$PY" "$MODELS_ROOT_ARG" ${extra[@]+"${extra[@]}"}
  exit 0
fi

if [ "$(id -u)" != 0 ]; then
  echo "provision.sh: run as root (or use --models-only for an unprivileged model section)" >&2
  exit 1
fi

if [ "$MODE" = full ]; then
echo "== packages =="
apt-get update -y
apt-get install -y build-essential clang curl unzip git pkg-config \
  libpq-dev zlib1g-dev libssl-dev libzstd-dev postgresql-client

echo "== swift =="
if ! command -v swift >/dev/null || ! swift --version 2>/dev/null | grep -q 6.0.3; then
  (
    cd /opt
    curl -fsSLo swift.tar.gz "https://download.swift.org/swift-6.0.3-release/ubuntu2404/swift-6.0.3-RELEASE/${SWIFT_VER}-ubuntu24.04.tar.gz"
    # sha256sum -c against the published digest here (SWIFT_SHA256) once recorded
    tar xzf swift.tar.gz && rm swift.tar.gz
  )
  ln -sf /opt/${SWIFT_VER}-ubuntu24.04/usr/bin/* /usr/local/bin/ || true
fi
swift --version

echo "== private snapshot sqlite =="
mkdir -p /opt/sqlite
(
  cd /opt/sqlite
  curl -fsSLo sqlite.zip "https://sqlite.org/2026/sqlite-amalgamation-${SQLITE_AMALGamation}.zip"
  unzip -o -q sqlite.zip
  unzip -p sqlite.zip "sqlite-amalgamation-${SQLITE_AMALGamation}/sqlite3.c" > sqlite3.c
  unzip -p sqlite.zip "sqlite-amalgamation-${SQLITE_AMALGamation}/sqlite3.h" > sqlite3.h
  echo "${SQLITE_SHA256}  sqlite3.c" | sha256sum --check
  cc -shared -fPIC -DSQLITE_ENABLE_SNAPSHOT=1 sqlite3.c -o libsqlite3.so.0
  ln -sf libsqlite3.so.0 libsqlite3.so
  # Verify the snapshot API is actually present in the built library:
  nm -D libsqlite3.so | grep -q sqlite3_snapshot_get || { echo "snapshot API missing"; exit 1; }
)

echo "== service user + dirs =="
id frwhoop >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin frwhoop
mkdir -p /etc/frwhoop /var/lib/frwhoop /opt/noop/releases
chown frwhoop:frwhoop /var/lib/frwhoop

echo "== systemd unit =="
install -m 644 "$SCRIPT_DIR/frwhoop-worker.service" /etc/systemd/system/frwhoop-worker.service
systemd-analyze verify /etc/systemd/system/frwhoop-worker.service || true
systemctl daemon-reload

echo "== next steps =="
cat <<'EOF'
1. Install /etc/frwhoop/worker.env (0600) from deploy/worker.env.example
   (DB URL, verify-full TLS, B2 creds, ingest secret, lane budgets).
2. Install /etc/frwhoop/supabase-ca-chain.pem (0644) from deploy/supabase-ca-chain.pem.
3. Install, build and switch a release per deploy/README.md (deploy/release-host.sh), then:
   systemctl enable --now frwhoop-worker
EOF
fi

# =============================================================================
# FRWHOOP physiology inference sidecar (loopback only)
# -----------------------------------------------------------------------------
# This section provisions the OPTIONAL Python inference sidecar that the Swift worker calls
# over loopback. It creates a SEPARATE user, SEPARATE directories and a SEPARATE systemd unit,
# and it opens no public port (the sidecar binds 127.0.0.1), so no Cloud Firewall rule and no
# ufw rule are needed. The Swift worker keeps running with the sidecar absent.
#
# FAIL-CLOSED ARTIFACT POLICY (deliberate, and unlike the Swift toolchain check above, which
# records a digest it never verifies): every artifact is checked against a PINNED sha256 before
# a revision is selected, and a revision missing a required artifact is never selected. Nothing
# is downloaded at inference time.
# =============================================================================

echo "== sidecar: packages =="
apt-get install -y python3 ca-certificates

echo "== sidecar: service user + dirs =="
id frwhoop-inf >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin frwhoop-inf
mkdir -p "$SIDECAR_ROOT/venvs" "$MODELS_ROOT" /var/lib/frwhoop-inf /etc/frwhoop
chown frwhoop-inf:frwhoop-inf /var/lib/frwhoop-inf
chmod 0755 "$SIDECAR_ROOT" "$SIDECAR_ROOT/venvs" "$MODELS_ROOT"

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
if [ ! -f "$REPO_ROOT/Tools/InferenceWorker/uv.lock" ]; then
  echo "FATAL: $REPO_ROOT/Tools/InferenceWorker/uv.lock is missing (sidecar package not in this tree)" >&2
  exit 1
fi
# One venv per release, outside the (read-only) release tree, so a release is never written to
# after it was built and the previous release's venv stays for rollback.
VENV_ID="$(python3 - "$REPO_ROOT" <<'PY'
import json, os, subprocess, sys
root = sys.argv[1]
try:
    print(json.load(open(os.path.join(root, "RELEASE.json")))["release_id"])
except Exception:
    try:
        sha = subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], capture_output=True,
                             text=True, check=True).stdout.strip()
        dirty = subprocess.run(["git", "-C", root, "status", "--porcelain"], capture_output=True,
                               text=True, check=True).stdout.strip()
        print("checkout-" + sha[:12] + ("-dirty" if dirty else ""))
    except Exception:
        print("checkout")
PY
)"
VENV_DIR="$SIDECAR_ROOT/venvs/$VENV_ID"
UV_PROJECT_ENVIRONMENT="$VENV_DIR" UV_PYTHON_DOWNLOADS=never /usr/local/bin/uv sync --frozen \
  --project "$REPO_ROOT/Tools/InferenceWorker" \
  --python-preference only-system
test -x "$VENV_DIR/bin/python" || { echo "FATAL: sidecar venv missing at $VENV_DIR"; exit 1; }
if [ -e "$SIDECAR_ROOT/venv" ] && [ ! -L "$SIDECAR_ROOT/venv" ]; then
  mv "$SIDECAR_ROOT/venv" "$SIDECAR_ROOT/venv.replaced-$(date -u +%Y%m%dT%H%M%SZ)"
fi
switch_link "$VENV_DIR" "$SIDECAR_ROOT/venv"
echo "  sidecar venv: $SIDECAR_ROOT/venv -> $VENV_DIR"

echo "== sidecar: model revision (stage, verify, probe, switch) =="
model_args=(--probe-user frwhoop-inf)
[ -f /etc/frwhoop/inference.env ] && model_args+=(--service-env /etc/frwhoop/inference.env)
[ -n "$SERVICE_ENV_ARG" ] && model_args+=(--service-env "$SERVICE_ENV_ARG")
[ "$OFFLINE" = 1 ] && model_args+=(--offline)
for mirror in ${MIRRORS[@]+"${MIRRORS[@]}"}; do model_args+=(--mirror "$mirror"); done
# The service user reads the cache and cannot write it (ReadOnlyPaths=); a rejected revision
# leaves `current` where it was and stops this script here.
provision_models "$VENV_DIR/bin/python" "$MODELS_ROOT" "${model_args[@]}" \
  --report "$SIDECAR_ROOT/last-model-provision.json" > /dev/null
echo "  models: $MODELS_ROOT/current -> $(readlink "$MODELS_ROOT/current")"

echo "== sidecar: systemd unit =="
install -m 644 "$SCRIPT_DIR/frwhoop-inference.service" /etc/systemd/system/frwhoop-inference.service
systemd-analyze verify /etc/systemd/system/frwhoop-inference.service || true
systemctl daemon-reload

echo "== sidecar: next steps =="
cat <<'EOF'
1. Install /etc/frwhoop/inference.env (0600, root-owned) from deploy/inference.env.example.
2. Confirm the sidecar port is free on the host:  ss -ltnp | grep 8787
   (the bind is 127.0.0.1 only; no Cloud Firewall or ufw rule is required)
3. systemctl enable --now frwhoop-inference   (or: systemctl restart frwhoop-inference)
4. Check readiness and identity:  curl -s http://127.0.0.1:8787/healthz | python3 -m json.tool
   A missing or mismatched artifact must report ready=false, never a silent fallback.
5. Only then enable the client side: set FRWHOOP_INFERENCE_URL=http://127.0.0.1:8787
   in /etc/frwhoop/worker.env and restart frwhoop-worker. Leaving it unset keeps the
   candidate lane completely off.
EOF
