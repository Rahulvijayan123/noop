#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FRWHOOP physiology migration - shared helpers for the end-to-end scripts.
#
# OWNER: impl-e2e (Tools/InferenceWorker/scripts/**, Tools/InferenceWorker/integration/**).
# Everything else in the repository is READ-ONLY from here.
#
# Invariants this library enforces, so no caller can break them:
#   * a disposable PostgreSQL cluster binds a UNIX SOCKET ONLY
#     (`listen_addresses=''` plus `-k <socket dir>`), so it can never collide
#     with the unrelated local Supabase stack that holds 54321/54322/54323/55432;
#   * the sidecar always binds 127.0.0.1 on an ephemeral port (never a fixed one);
#   * every wait loop is bounded by an explicit attempt count;
#   * all state lives under $E2E_ROOT, which must be outside the checkout;
#   * no production credential is ever read: the only environment variables used
#     are the ones this file sets.
# ---------------------------------------------------------------------------
set -euo pipefail

E2E_ROOT="${E2E_ROOT:-/tmp/frwhoop-physiology/e2e}"
E2E_PG_BIN="${E2E_PG_BIN:-/opt/homebrew/bin}"
E2E_UV_BIN="${E2E_UV_BIN:-$(command -v uv)}"
E2E_SWIFT_BIN="${E2E_SWIFT_BIN:-$(command -v swift)}"
# lib_e2e.sh lives in Tools/InferenceWorker/scripts, so the package dir is its parent.
E2E_IW_DIR="${E2E_IW_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# The checkout root, used to locate supabase/migrations and Tools/CloudWorker.
E2E_REPO_ROOT="${E2E_REPO_ROOT:-$(cd "$E2E_IW_DIR/../.." && pwd)}"

E2E_PASS_COUNT=0
E2E_FAIL_COUNT=0
E2E_SKIP_COUNT=0

# ---------------------------------------------------------------------------
# reporting
# ---------------------------------------------------------------------------

e2e_section() { printf '\n=== %s ===\n' "$*"; }

e2e_note() { printf '    note  %s: %s\n' "$1" "${2:-}"; }

e2e_pass() {
  E2E_PASS_COUNT=$((E2E_PASS_COUNT + 1))
  printf 'PASS  %s\n' "$1"
}

e2e_fail() {
  E2E_FAIL_COUNT=$((E2E_FAIL_COUNT + 1))
  printf 'FAIL  %s\n' "$1"
}

e2e_skip() {
  E2E_SKIP_COUNT=$((E2E_SKIP_COUNT + 1))
  printf 'SKIP  %s\n' "$1"
}

# e2e_assert_eq <label> <expected> <actual>
e2e_assert_eq() {
  if [ "$2" = "$3" ]; then
    e2e_pass "$1"
  else
    e2e_fail "$1"
    printf '        expected: %s\n        actual:   %s\n' "$2" "$3"
  fi
}

# e2e_assert_contains <label> <needle> <haystack>
e2e_assert_contains() {
  case "$3" in
    *"$2"*) e2e_pass "$1" ;;
    *)
      e2e_fail "$1"
      printf '        missing substring: %s\n        in: %s\n' "$2" "$3"
      ;;
  esac
}

# e2e_assert_match <label> <extended-regex> <value>
e2e_assert_match() {
  if printf '%s' "$3" | grep -Eq "$2"; then
    e2e_pass "$1"
  else
    e2e_fail "$1"
    printf '        value %s does not match /%s/\n' "$3" "$2"
  fi
}

# e2e_assert_truthy <label> <sql-returning-boolean-text>
e2e_assert_sql_true() {
  e2e_assert_eq "$1" "t" "$2"
}

e2e_summary() {
  printf '\n--- %s: %d passed, %d failed, %d skipped ---\n' \
    "${E2E_SUMMARY_NAME:-e2e}" "$E2E_PASS_COUNT" "$E2E_FAIL_COUNT" "$E2E_SKIP_COUNT"
  [ "$E2E_FAIL_COUNT" -eq 0 ]
}

e2e_require_tool() {
  if [ -z "$2" ] || [ ! -x "$2" ]; then
    printf 'FATAL: required tool %s not found (set %s)\n' "$1" "$3" >&2
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# run directory
# ---------------------------------------------------------------------------

# e2e_init <run-name>: creates $E2E_ROOT/<run-name>-<pid> and tees the transcript.
e2e_init() {
  local name="$1"
  E2E_RUN_DIR="${E2E_RUN_DIR:-$E2E_ROOT/$name-$$}"
  mkdir -p "$E2E_RUN_DIR"
  E2E_LOG="${E2E_LOG:-$E2E_RUN_DIR/transcript.log}"
  exec > >(tee "$E2E_LOG") 2>&1
  printf 'run dir: %s\n' "$E2E_RUN_DIR"
  printf 'repo:    %s\n' "$E2E_REPO_ROOT"
  # The disposable cluster must never live inside the checkout.
  case "$E2E_RUN_DIR" in
    "$E2E_REPO_ROOT"/*) printf 'FATAL: E2E_RUN_DIR is inside the checkout\n' >&2; exit 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# disposable PostgreSQL (unix socket only)
# ---------------------------------------------------------------------------

# e2e_pg_start <subdir-name>
e2e_pg_start() {
  local sub="$1"
  e2e_require_tool initdb "$E2E_PG_BIN/initdb" E2E_PG_BIN
  e2e_require_tool pg_ctl "$E2E_PG_BIN/pg_ctl" E2E_PG_BIN
  e2e_require_tool psql "$E2E_PG_BIN/psql" E2E_PG_BIN
  E2E_PG_SOCK="$E2E_RUN_DIR/$sub"
  E2E_PG_DATA="$E2E_PG_SOCK/data"
  E2E_PG_USER=edge_test
  mkdir -p "$E2E_PG_SOCK"
  local socket_path="$E2E_PG_SOCK/.s.PGSQL.5432"
  if [ "${#socket_path}" -gt 103 ]; then
    printf 'FATAL: socket path is %d bytes (macOS limit 103): %s\n' "${#socket_path}" "$socket_path" >&2
    exit 2
  fi
  env -i PATH="$E2E_PG_BIN:/usr/bin:/bin" TMPDIR="$E2E_PG_SOCK" LC_ALL=C \
    "$E2E_PG_BIN/initdb" -D "$E2E_PG_DATA" -U "$E2E_PG_USER" \
    --auth-local=trust --auth-host=reject --no-locale --encoding=UTF8 >"$E2E_PG_SOCK/initdb.log" 2>&1
  # listen_addresses='' keeps the cluster off every TCP port. The socket is the only way in.
  env -i PATH="$E2E_PG_BIN:/usr/bin:/bin" TMPDIR="$E2E_PG_SOCK" LC_ALL=C \
    "$E2E_PG_BIN/pg_ctl" -D "$E2E_PG_DATA" -l "$E2E_PG_SOCK/postgres.log" -o \
    "-k '$E2E_PG_SOCK' -c listen_addresses='' -c unix_socket_permissions=0700 -c max_connections=30" \
    -w start >"$E2E_PG_SOCK/pgctl-start.log" 2>&1
  E2E_PG_STARTED=1
  printf 'postgres up: data=%s socket=%s (listen_addresses='')\n' "$E2E_PG_DATA" "$E2E_PG_SOCK"
}

e2e_pg_stop() {
  [ "${E2E_PG_STARTED:-0}" = "1" ] || return 0
  env -i PATH="$E2E_PG_BIN:/usr/bin:/bin" TMPDIR="$E2E_PG_SOCK" LC_ALL=C \
    "$E2E_PG_BIN/pg_ctl" -D "$E2E_PG_DATA" -m fast -w stop >>"$E2E_PG_SOCK/pgctl-stop.log" 2>&1 || true
  E2E_PG_STARTED=0
}

# e2e_pg_sql <sql>            -> unaligned tuples-only output, ON_ERROR_STOP
e2e_pg_sql() {
  "$E2E_PG_BIN/psql" -X -qAt -v ON_ERROR_STOP=1 -h "$E2E_PG_SOCK" -U "$E2E_PG_USER" \
    -d postgres -c "$1"
}

# e2e_pg_sql_err <sql>        -> the first ERROR line, or "OK"
e2e_pg_sql_err() {
  local out status
  out="$("$E2E_PG_BIN/psql" -X -qAt -v ON_ERROR_STOP=1 -h "$E2E_PG_SOCK" -U "$E2E_PG_USER" \
    -d postgres -c "$1" 2>&1)" && status=0 || status=$?
  if [ "$status" -eq 0 ]; then
    printf 'OK'
    return 0
  fi
  printf '%s' "$out" | grep -m1 '^ERROR:' || printf 'UNKNOWN_ERROR'
}

# e2e_pg_file <file>           -> run a SQL file (used for the bound Swift statement)
e2e_pg_file() {
  "$E2E_PG_BIN/psql" -X -qAt -v ON_ERROR_STOP=1 -h "$E2E_PG_SOCK" -U "$E2E_PG_USER" -d postgres -f "$1"
}

# e2e_pg_apply <migration-filename>
e2e_pg_apply() {
  "$E2E_PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 -h "$E2E_PG_SOCK" -U "$E2E_PG_USER" -d postgres \
    -1 -f "$E2E_REPO_ROOT/supabase/migrations/$1"
}

# The Supabase-shaped bootstrap: the roles, schemas and helpers the migrations expect.
e2e_pg_bootstrap() {
  e2e_pg_sql "
    create role postgres nologin; create role anon nologin; create role authenticated nologin;
    create role service_role nologin bypassrls; create role authenticator login noinherit;
    grant anon,authenticated,service_role to authenticator;
    create schema auth; create schema extensions;
    create publication supabase_realtime;
    create table auth.users (id uuid primary key, raw_user_meta_data jsonb default '{}'::jsonb, email text);
    create function auth.uid() returns uuid language sql stable as \$\$
      select coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),
        nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid \$\$;
    create function auth.role() returns text language sql stable as \$\$
      select coalesce(nullif(current_setting('request.jwt.claim.role',true),''),
        nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role',current_user::text) \$\$;
    grant usage on schema public,auth,extensions to anon,authenticated,service_role;
    alter default privileges in schema public grant all on tables to service_role;
    alter default privileges in schema public grant all on sequences to service_role;
  " >/dev/null
}

# ---------------------------------------------------------------------------
# sidecar (loopback, ephemeral port)
# ---------------------------------------------------------------------------

# e2e_sidecar_start <label> <model-root>
e2e_sidecar_start() {
  local label="$1" model_root="$2"
  e2e_require_tool uv "$E2E_UV_BIN" E2E_UV_BIN
  local log="$E2E_RUN_DIR/sidecar-$label.log"
  (
    cd "$E2E_IW_DIR"
    exec env -u FRWHOOP_HOST -u FRWHOOP_PORT -u FRWHOOP_INFERENCE_URL \
      FRWHOOP_MODEL_ROOT="$model_root" \
      "$E2E_UV_BIN" run python -m frwhoop_inference.server \
        --host 127.0.0.1 --port 0 --model-root "$model_root"
  ) >"$log" 2>&1 &
  E2E_SIDECAR_PID=$!
  E2E_SIDECAR_LOG="$log"
  local attempt port=""
  for attempt in $(seq 1 100); do
    port="$(sed -n 's/.*listening on http:\/\/127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$log" | tail -1)"
    [ -n "$port" ] && break
    if ! kill -0 "$E2E_SIDECAR_PID" 2>/dev/null; then
      printf 'FATAL: sidecar exited during startup; log follows\n' >&2
      tail -30 "$log" >&2
      return 1
    fi
    sleep 0.1
  done
  if [ -z "$port" ]; then
    printf 'FATAL: sidecar did not report a port within 10s\n' >&2
    tail -30 "$log" >&2
    return 1
  fi
  E2E_SIDECAR_PORT="$port"
  E2E_SIDECAR_URL="http://127.0.0.1:$port"
  printf 'sidecar[%s] up: %s (model_root=%s, log=%s)\n' "$label" "$E2E_SIDECAR_URL" "$model_root" "$log"
}

# e2e_sidecar_stop: kill the launcher AND whatever still listens on the ephemeral port.
e2e_sidecar_stop() {
  [ -n "${E2E_SIDECAR_PID:-}" ] || return 0
  kill "$E2E_SIDECAR_PID" 2>/dev/null || true
  local attempt listeners
  for attempt in $(seq 1 20); do
    listeners="$(lsof -nP -iTCP:"$E2E_SIDECAR_PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
    [ -z "$listeners" ] && break
    printf '%s\n' "$listeners" | while read -r pid; do kill "$pid" 2>/dev/null || true; done
    sleep 0.1
  done
  listeners="$(lsof -nP -iTCP:"$E2E_SIDECAR_PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
  if [ -n "$listeners" ]; then
    printf 'WARN: sidecar port %s still has listeners: %s\n' "$E2E_SIDECAR_PORT" "$listeners"
  fi
  E2E_SIDECAR_PID=""
}

# e2e_sidecar_listen_address: the local address the sidecar is bound to (loopback proof).
e2e_sidecar_listen_address() {
  lsof -nP -iTCP:"$E2E_SIDECAR_PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $9}'
}

# HTTP helpers. They are called WITHOUT command substitution, because a
# $(...) call runs in a subshell and any global it sets would be lost:
#
#     e2e_http_get /healthz
#     HEALTH="$(cat "$E2E_HTTP_BODY")"
#
# After each call: E2E_HTTP_STATUS holds the status code and E2E_HTTP_BODY the
# path to the response body.

# e2e_http_get <path>
e2e_http_get() {
  local body="$E2E_RUN_DIR/http-get.json" status
  status="$(curl -sS -m 20 -o "$body" -w '%{http_code}' "$E2E_SIDECAR_URL$1")" || true
  E2E_HTTP_STATUS="$status"
  E2E_HTTP_BODY="$body"
  printf '        GET  %s -> %s\n' "$1" "$status"
}

# e2e_http_post <path> <file>
e2e_http_post() {
  local body="$E2E_RUN_DIR/http-post.json" status
  status="$(curl -sS -m 120 -o "$body" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' --data-binary "@$2" "$E2E_SIDECAR_URL$1")" || true
  E2E_HTTP_STATUS="$status"
  E2E_HTTP_BODY="$body"
  printf '        POST %s -> %s (%s)\n' "$1" "$status" "$(basename "$2")"
}
