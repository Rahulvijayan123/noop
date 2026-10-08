#!/bin/bash
# A disposable, real Supabase Auth + Postgres + PostgREST stack plus the repo's own Edge functions and the
# real VPS worker, for the signup -> emailed code -> installation -> pairing -> upload -> scoring -> readback
# path. Nothing here touches a hosted project, and it never uses the repo's own local stack or its ports.
#
#   stack.sh up        build the stack (idempotent) and print the environment the tests need
#   stack.sh env       print that environment again
#   stack.sh down      stop everything and remove the containers and volumes
#
# What runs where
#   Postgres 17 + GoTrue + PostgREST + Kong   `supabase start` in $WORK, project id nara-auth-e2e
#   confirmation / recovery email             GoTrue -> smtp_sink.py (every message is a JSON file)
#   push + scores Edge functions              the unmodified supabase/functions/{push,scores}/index.ts under Deno
#   raw object store                          an in-memory S3 stub (gateway.ts) standing in for Backblaze B2
#   gateway                                   one origin for /functions/v1, /auth/v1, /rest/v1 and /__e2e/mail
#   frwhoop-worker                            the real scoring worker (Tools/CloudWorker), scoring lane only
#
# Migrations are applied with `psql -1` as the postgres role, in the order printed by ordered_migrations.sh,
# which is how production applies them (never `supabase db push`).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
# Under $HOME because Docker on macOS (Colima, Docker Desktop) shares the home directory with its VM but not
# /tmp, and the Auth service reads its email templates through a bind mount of this directory.
WORK="${NARA_E2E_DIR:-$HOME/.cache/nara-auth-e2e}"
PROJECT="nara-auth-e2e"
API_PORT="${NARA_E2E_API_PORT:-54421}"
DB_PORT="${NARA_E2E_DB_PORT:-54422}"
SHADOW_PORT="${NARA_E2E_SHADOW_PORT:-54420}"
SMTP_PORT="${NARA_E2E_SMTP_PORT:-54425}"
GATEWAY_PORT="${NARA_E2E_GATEWAY_PORT:-54431}"
S3_PORT="${NARA_E2E_S3_PORT:-54432}"
PUSH_PORT="${NARA_E2E_PUSH_PORT:-54441}"
SCORES_PORT="${NARA_E2E_SCORES_PORT:-54442}"
COACH_PORT="${NARA_E2E_COACH_PORT:-54443}"
WORKER_BIN="${NARA_E2E_WORKER_BIN:-$REPO/Tools/CloudWorker/.build/debug/frwhoop-worker}"
RUN="$WORK/run"
DENO="${DENO:-deno}"

say() { printf '[e2e] %s\n' "$*" >&2; }

write_config() {
  mkdir -p "$WORK/supabase/templates" "$RUN" "$WORK/mail"
  cp "$REPO/supabase/templates/"*.html "$WORK/supabase/templates/"
  cat > "$WORK/supabase/config.toml" <<EOF
project_id = "$PROJECT"

[api]
enabled = true
port = $API_PORT
schemas = ["public", "graphql_public"]
extra_search_path = ["public", "extensions"]
max_rows = 1000

[db]
port = $DB_PORT
shadow_port = $SHADOW_PORT
major_version = 17

[db.pooler]
enabled = false

[realtime]
enabled = false

[studio]
enabled = false

[inbucket]
enabled = false

[storage]
enabled = false

[edge_runtime]
enabled = false

[analytics]
enabled = false

[auth]
enabled = true
site_url = "http://127.0.0.1:3000"
enable_signup = true
enable_anonymous_sign_ins = false
minimum_password_length = 8
jwt_expiry = 3600
enable_refresh_token_rotation = true
refresh_token_reuse_interval = 10

[auth.rate_limit]
email_sent = 1000
sign_in_sign_ups = 1000
token_verifications = 1000
token_refresh = 1000

[auth.email]
enable_signup = true
enable_confirmations = true
double_confirm_changes = true
max_frequency = "1s"
otp_length = 8
otp_expiry = 3600

[auth.email.smtp]
enabled = true
host = "host.docker.internal"
port = $SMTP_PORT
user = "e2e"
pass = "e2e"
admin_email = "no-reply@nara.test"
sender_name = "Nara"

[auth.email.template.confirmation]
subject = "Your Nara verification code"
content_path = "./supabase/templates/confirmation.html"

[auth.email.template.recovery]
subject = "Reset your Nara password"
content_path = "./supabase/templates/recovery.html"
EOF
}

stack_env() {
  # shellcheck disable=SC1090
  source "$RUN/stack.env"
  cat "$RUN/stack.env"
}

wait_http() { # url, seconds
  local url="$1" tries=$(( $2 * 2 ))
  for _ in $(seq "$tries"); do
    if curl -sf -o /dev/null --max-time 2 "$url"; then return 0; fi
    sleep 0.5
  done
  say "timed out waiting for $url"; return 1
}

stop_pidfile() {
  local f="$1"
  [ -f "$f" ] || return 0
  local pid; pid="$(cat "$f")"
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; sleep 0.3; kill -9 "$pid" 2>/dev/null || true; fi
  rm -f "$f"
}

# Each service gets its own session, so it outlives the shell that started it and is stopped only by `down`.
spawn() { # name, logfile, command...
  local name="$1" log="$2"; shift 2
  stop_pidfile "$RUN/$name.pid"
  python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" > "$log" 2>&1 < /dev/null &
  echo $! > "$RUN/$name.pid"
}

up() {
  command -v supabase >/dev/null || { say "supabase CLI not found"; exit 1; }
  command -v "$DENO" >/dev/null || { say "deno not found"; exit 1; }
  docker info >/dev/null 2>&1 || { say "docker is not running"; exit 1; }
  write_config

  if ! supabase status --workdir "$WORK" >/dev/null 2>&1; then
    say "starting Postgres, Auth, PostgREST and Kong ($PROJECT)"
    supabase start --workdir "$WORK" \
      -x realtime,storage-api,imgproxy,mailpit,studio,edge-runtime,logflare,vector,supavisor,postgres-meta >&2
  fi
  supabase status --workdir "$WORK" -o env > "$RUN/status.env" 2>/dev/null
  # shellcheck disable=SC1090
  set -a; source "$RUN/status.env"; set +a

  local DBURL="postgresql://postgres:postgres@127.0.0.1:$DB_PORT/postgres"
  if ! psql "$DBURL" -Atqc "select to_regclass('public.noop_app_installations') is not null" 2>/dev/null | grep -q t; then
    say "applying migrations in order"
    while IFS= read -r f; do
      psql "$DBURL" -v ON_ERROR_STOP=1 -q -1 -f "$f" >/dev/null 2> "$RUN/migrate.err" || {
        say "migration failed: $f"; cat "$RUN/migrate.err" >&2; exit 1; }
    done < <("$HERE/ordered_migrations.sh" "$REPO/supabase/migrations")
    psql "$DBURL" -qAtc "notify pgrst, 'reload schema'" >/dev/null
  fi

  local PUB="${PUBLISHABLE_KEY:-${ANON_KEY:-}}"
  local SECRET="${SECRET_KEY:-${SERVICE_ROLE_KEY:-}}"
  local WORKER_SECRET INGEST_SECRET PEPPER
  WORKER_SECRET="$(openssl rand -hex 24)"; INGEST_SECRET="$(openssl rand -hex 24)"; PEPPER="$(openssl rand -hex 32)"

  say "starting the SMTP sink on :$SMTP_PORT"
  spawn smtp "$RUN/smtp.log" python3 "$HERE/smtp_sink.py" "$SMTP_PORT" "$WORK/mail"

  local fn_env=(
    SUPABASE_URL="http://127.0.0.1:$API_PORT"
    SUPABASE_PUBLISHABLE_KEY="$PUB"
    SUPABASE_SERVICE_ROLE_KEY="$SECRET"
    B2_KEY_ID=e2e B2_APPLICATION_KEY=e2e B2_BUCKET=e2e-raw
    B2_S3_ENDPOINT="http://127.0.0.1:$S3_PORT" RAW_STORE=b2
    NOOP_ENROLLMENT_PEPPER="$PEPPER"
    WORKER_SECRET="$WORKER_SECRET"
  )
  say "starting the push, scores and coach functions"
  spawn push "$RUN/push.log" env "${fn_env[@]}" DENO_SERVE_ADDRESS="tcp:127.0.0.1:$PUSH_PORT" \
    "$DENO" run -A --no-lock "$REPO/supabase/functions/push/index.ts"
  spawn scores "$RUN/scores.log" env "${fn_env[@]}" DENO_SERVE_ADDRESS="tcp:127.0.0.1:$SCORES_PORT" \
    "$DENO" run -A --no-lock "$REPO/supabase/functions/scores/index.ts"
  # Coach serves the Settings profile route (/coach/profile). No model key is configured, so chat calls fail
  # closed; the profile and memory routes only need the database.
  spawn coach "$RUN/coach.log" env "${fn_env[@]}" DENO_SERVE_ADDRESS="tcp:127.0.0.1:$COACH_PORT" \
    "$DENO" run -A --no-lock "$REPO/supabase/functions/coach/index.ts"

  say "starting the gateway on :$GATEWAY_PORT"
  spawn gateway "$RUN/gateway.log" env \
    E2E_GATEWAY_PORT="$GATEWAY_PORT" E2E_S3_PORT="$S3_PORT" E2E_KONG_URL="http://127.0.0.1:$API_PORT" \
    E2E_PUSH_URL="http://127.0.0.1:$PUSH_PORT" E2E_SCORES_URL="http://127.0.0.1:$SCORES_PORT" \
    E2E_COACH_URL="http://127.0.0.1:$COACH_PORT" \
    E2E_MAIL_DIR="$WORK/mail" "$DENO" run -A --no-lock "$HERE/gateway.ts"
  wait_http "http://127.0.0.1:$GATEWAY_PORT/__e2e/health" 40

  if [ -x "$WORKER_BIN" ]; then
    # The physiology context lane runs too (NARA_E2E_CONTEXT=0 turns it off): it reads only published products and
    # raw streams and writes only its own tables, so the scoring scenarios are unaffected.
    local context_enabled="${NARA_E2E_CONTEXT:-1}"
    say "starting frwhoop-worker (scoring lane; context lane enabled=$context_enabled)"
    spawn worker "$RUN/worker.log" env \
      FRWHOOP_DB_URL="$DBURL" FRWHOOP_ALLOW_INSECURE_DB=1 FRWHOOP_DB_SSLMODE=disable \
      FRWHOOP_B2_KEY_ID=e2e FRWHOOP_B2_APPLICATION_KEY=e2e FRWHOOP_B2_BUCKET=e2e-raw \
      FRWHOOP_INGEST_SECRET="$INGEST_SECRET" FRWHOOP_WORKER_NAME=e2e-worker \
      FRWHOOP_DISABLE_LANES=projection,archive,verify FRWHOOP_POLL_INTERVAL_MS=300 \
      FRWHOOP_V2_INPUT_GATE_SECONDS=0 FRWHOOP_SOURCE_REVISION=e2e \
      FRWHOOP_CONTEXT_ENABLED="$context_enabled" FRWHOOP_CONTEXT_ENQUEUE_INTERVAL_SECONDS=2 \
      "$WORKER_BIN"
  else
    say "worker binary not found at $WORKER_BIN (build Tools/CloudWorker first); scoring will not run"
  fi

  cat > "$RUN/stack.env" <<EOF
NARA_E2E_GATEWAY=http://127.0.0.1:$GATEWAY_PORT
NARA_E2E_SUPABASE_URL=http://127.0.0.1:$GATEWAY_PORT
NARA_E2E_PUBLISHABLE_KEY=$PUB
NARA_E2E_SECRET_KEY=$SECRET
NARA_E2E_DATABASE_URL=$DBURL
NARA_E2E_KONG_URL=http://127.0.0.1:$API_PORT
NARA_E2E_MAIL_DIR=$WORK/mail
NARA_E2E_WORKER_RUNNING=$([ -f "$RUN/worker.pid" ] && echo 1 || echo 0)
EOF
  say "ready"
  cat "$RUN/stack.env"
}

down() {
  for n in worker gateway coach scores push smtp; do stop_pidfile "$RUN/$n.pid"; done
  if [ -d "$WORK/supabase" ]; then
    supabase stop --workdir "$WORK" --no-backup >&2 || true
  fi
  rm -rf "$WORK"
  say "stack removed"
}

case "${1:-}" in
  up) up ;;
  env) stack_env ;;
  down) down ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
