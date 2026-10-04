#!/bin/bash
# The database harness the Docker-gated Deno suites ask for: multiuser_sql_test.ts, intake_consumer_sql_test.ts
# and the other *_sql_test.ts files skip themselves unless these variables are set.
#
#   pipeline_db.sh up      create the database, GoTrue and PostgREST, apply every migration, print the variables
#   pipeline_db.sh reset   put the database back exactly as `up` left it (the suites expect an empty one)
#   pipeline_db.sh env     print the variables again
#   pipeline_db.sh down    remove the containers and stop PostgREST
#
#   PIPELINE_TEST_DATABASE_CONTAINER   nara-db-server-pipeline.<id>, labelled nara.test=server-pipeline
#   PIPELINE_TEST_REST_URL             PostgREST on loopback, JWT secret isolated-pipeline-jwt-secret-never-used-outside-tests
#   PIPELINE_TEST_AUTH_URL             GoTrue on loopback, same JWT secret, sign-up returns a session (no email step)
#   PIPELINE_TEST_OUTPUT               where the suites write their evidence files
#   PIPELINE_TEST_DATABASE_URL         the database as the postgres role, for the suites that talk to it directly
#
# The database is the same image Supabase runs (roles, extensions and default privileges included), so the
# row-level-security and grant assertions are made against what production has, not against a bare Postgres.
# GoTrue migrates the `auth` schema first, as it does on a hosted project, so auth.uid() and friends are the
# definitions production has. Migrations go in with `psql -1` as the postgres role, in the order
# ordered_migrations.sh prints: the lexicographic order does not apply to an empty database. Nothing here
# touches a hosted project or the repo's own local Supabase stack.
#
# Each suite inserts fixed fixtures and creates databases of its own, so run `reset` between suites.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
WORK="${NARA_PIPELINE_DIR:-$HOME/.cache/nara-pipeline-db}"
IMAGE="${NARA_PIPELINE_IMAGE:-public.ecr.aws/supabase/postgres:17.6.1.075}"
DB_PORT="${NARA_PIPELINE_DB_PORT:-54452}"
REST_PORT="${NARA_PIPELINE_REST_PORT:-54453}"
JWT_SECRET="isolated-pipeline-jwt-secret-never-used-outside-tests"
DB_PASSWORD="pipeline-postgres-never-used-outside-tests"
POSTGREST="${POSTGREST:-postgrest}"
PRISTINE="nara_pristine"
AUTH_PORT="${NARA_PIPELINE_AUTH_PORT:-54454}"
AUTH_IMAGE="${NARA_PIPELINE_AUTH_IMAGE:-public.ecr.aws/supabase/gotrue:v2.186.0}"

say() { printf '[pipeline-db] %s\n' "$*" >&2; }

container_name() { [ -f "$WORK/container" ] && cat "$WORK/container" || true; }
auth_name() { local c; c="$(container_name)"; [ -n "$c" ] && echo "nara-auth-server-pipeline.${c#*.}" || true; }
admin_url() { echo "postgresql://supabase_admin:$DB_PASSWORD@127.0.0.1:$DB_PORT/${1:-postgres}"; }
app_url() { echo "postgresql://postgres:$DB_PASSWORD@127.0.0.1:$DB_PORT/postgres"; }

# The capacity suites stamp their evidence with the exact source they ran against.
write_env() {
  local status
  status="$(git -C "$REPO" status --porcelain 2>/dev/null || true)"
  cat > "$WORK/pipeline.env" <<EOF
PIPELINE_TEST_DATABASE_CONTAINER=$(container_name)
PIPELINE_TEST_REST_URL=http://127.0.0.1:$REST_PORT
PIPELINE_TEST_AUTH_URL=http://127.0.0.1:$AUTH_PORT
PIPELINE_TEST_OUTPUT=$WORK/evidence
PIPELINE_TEST_DATABASE_URL=$(app_url)
PIPELINE_TEST_SOURCE_SHA=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo 0000000000000000000000000000000000000000)
PIPELINE_TEST_SOURCE_TREE=$(git -C "$REPO" rev-parse 'HEAD^{tree}' 2>/dev/null || echo 0000000000000000000000000000000000000000)
PIPELINE_TEST_SOURCE_CLEAN=$([ -z "$status" ] && echo true || echo false)
PIPELINE_TEST_SOURCE_STATUS_SHA256=$(printf '%s' "$status" | shasum -a 256 | cut -d' ' -f1)
PIPELINE_TEST_SOURCE_STATUS_LINE_COUNT=$(printf '%s' "$status" | grep -c . || true)
EOF
}

stop_rest() {
  if [ -f "$WORK/postgrest.pid" ]; then
    kill "$(cat "$WORK/postgrest.pid")" 2>/dev/null || true
    sleep 0.3
    kill -9 "$(cat "$WORK/postgrest.pid")" 2>/dev/null || true
    rm -f "$WORK/postgrest.pid"
  fi
}

stop_auth() {
  local name; name="$(auth_name)"
  [ -n "$name" ] && docker rm -f "$name" >/dev/null 2>&1 || true
}

# GoTrue, auto-confirming, so a suite can sign users up and get a session back without an email step. It owns
# the `auth` schema: its migrations run on first start and are part of the snapshot `reset` restores.
start_auth() {
  stop_auth
  say "starting GoTrue on :$AUTH_PORT"
  docker run -d --name "$(auth_name)" -p "127.0.0.1:$AUTH_PORT:9999" \
    -e GOTRUE_API_HOST=0.0.0.0 -e GOTRUE_API_PORT=9999 -e API_EXTERNAL_URL="http://127.0.0.1:$AUTH_PORT" \
    -e GOTRUE_DB_DRIVER=postgres -e GOTRUE_DB_NAMESPACE=auth \
    -e GOTRUE_DB_DATABASE_URL="postgres://supabase_auth_admin:$DB_PASSWORD@host.docker.internal:$DB_PORT/postgres" \
    -e GOTRUE_SITE_URL=http://127.0.0.1:3000 -e GOTRUE_JWT_SECRET="$JWT_SECRET" -e GOTRUE_JWT_EXP=3600 \
    -e GOTRUE_JWT_AUD=authenticated -e GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated \
    -e GOTRUE_DISABLE_SIGNUP=false -e GOTRUE_EXTERNAL_EMAIL_ENABLED=true -e GOTRUE_MAILER_AUTOCONFIRM=true \
    -e GOTRUE_RATE_LIMIT_EMAIL_SENT=1000 \
    "$AUTH_IMAGE" >/dev/null
  for _ in $(seq 120); do
    curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:$AUTH_PORT/health" && return 0
    sleep 0.5
  done
  say "GoTrue did not come up"; docker logs "$(auth_name)" 2>&1 | tail -5 >&2; exit 1
}

# Supabase loads pg-safeupdate for PostgREST's own sessions, so an UPDATE or DELETE without a WHERE clause is
# refused when it arrives through the REST API (the scoring workers use libpq and are not affected). That stays
# on, as it is in production, except for NARA_PIPELINE_SAFEUPDATE=off: the capacity suite drives the legacy
# scoring_claim_one RPC through PostgREST, which no production caller does.
apply_safeupdate() {
  if [ "${NARA_PIPELINE_SAFEUPDATE:-on}" = "off" ]; then
    psql "$(admin_url)" -qAt -c "alter role authenticator reset session_preload_libraries" >/dev/null
  else
    psql "$(admin_url)" -qAt -c "alter role authenticator set session_preload_libraries = 'safeupdate'" >/dev/null
  fi
}

start_rest() {
  stop_rest
  apply_safeupdate
  say "starting PostgREST on :$REST_PORT"
  python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' env \
    PGRST_DB_URI="postgres://authenticator:$DB_PASSWORD@127.0.0.1:$DB_PORT/postgres" \
    PGRST_DB_SCHEMAS=public PGRST_DB_ANON_ROLE=anon PGRST_JWT_SECRET="$JWT_SECRET" \
    PGRST_SERVER_HOST=127.0.0.1 PGRST_SERVER_PORT="$REST_PORT" PGRST_DB_MAX_ROWS=1000 \
    "$POSTGREST" > "$WORK/postgrest.log" 2>&1 < /dev/null &
  echo $! > "$WORK/postgrest.pid"
  for _ in $(seq 60); do
    curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:$REST_PORT/" && return 0
    sleep 0.5
  done
  say "PostgREST did not come up"; tail -5 "$WORK/postgrest.log" >&2; exit 1
}

# Copy the finished database aside so `reset` is a database copy rather than 150 migrations.
snapshot() {
  stop_rest
  psql "$(admin_url template1)" -v ON_ERROR_STOP=1 -qAt >/dev/null <<SQL
select pg_terminate_backend(pid) from pg_stat_activity where datname = 'postgres' and pid <> pg_backend_pid();
drop database if exists $PRISTINE;
create database $PRISTINE template postgres owner postgres;
SQL
}

reset() {
  [ -n "$(container_name)" ] || { say "no database; run up first"; exit 1; }
  stop_rest
  stop_auth
  psql "$(admin_url template1)" -v ON_ERROR_STOP=1 -qAt >/dev/null <<SQL
select pg_terminate_backend(pid) from pg_stat_activity where datname not in ('template1', '$PRISTINE') and pid <> pg_backend_pid() and datname is not null;
drop database if exists multiuser_restore;
drop database if exists postgres;
create database postgres template $PRISTINE owner postgres;
SQL
  rm -rf "$WORK/evidence"; mkdir -p "$WORK/evidence"
  start_auth
  start_rest
  say "reset"
}

up() {
  command -v docker >/dev/null || { say "docker not found"; exit 1; }
  docker info >/dev/null 2>&1 || { say "docker is not running"; exit 1; }
  command -v "$POSTGREST" >/dev/null || { say "postgrest not found (brew install postgrest)"; exit 1; }
  mkdir -p "$WORK/evidence"

  local name; name="$(container_name)"
  if [ -z "$name" ] || ! docker inspect "$name" >/dev/null 2>&1; then
    name="nara-db-server-pipeline.$(openssl rand -hex 4)"
    say "creating $name from $IMAGE"
    # PGPASSWORD is for the suites that `docker exec` pg_dump / pg_restore as supabase_admin over the socket.
    docker run -d --name "$name" --label nara.test=server-pipeline \
      -e POSTGRES_PASSWORD="$DB_PASSWORD" -e PGPASSWORD="$DB_PASSWORD" \
      -p "127.0.0.1:$DB_PORT:5432" "$IMAGE" >/dev/null
    echo "$name" > "$WORK/container"
  fi

  local admin url; admin="$(admin_url)"; url="$(app_url)"
  for _ in $(seq 120); do
    psql "$admin" -Atqc "select 1" >/dev/null 2>&1 && break
    sleep 0.5
  done
  psql "$admin" -Atqc "select 1" >/dev/null 2>&1 || { say "database did not come up"; exit 1; }
  # The image's init scripts finish after the first connections succeed; wait for the roles they create.
  for _ in $(seq 120); do
    [ "$(psql "$admin" -Atqc "select count(*) from pg_roles where rolname in ('anon','authenticated','service_role','authenticator')" 2>/dev/null)" = "4" ] && break
    sleep 0.5
  done

  if ! psql "$url" -Atqc "select to_regclass('public.noop_app_installations') is not null" 2>/dev/null | grep -q t; then
    # A hosted project's `auth` schema is whatever GoTrue's migrations leave, and they run before any
    # application migration. Do the same: the image ships an older schema whose auth.uid() and auth.role()
    # read per-claim settings that PostgREST no longer sets.
    psql "$admin" -qAt -c "alter role supabase_auth_admin with password '$DB_PASSWORD'" >/dev/null
    start_auth
    say "applying migrations in order"
    while IFS= read -r f; do
      psql "$url" -v ON_ERROR_STOP=1 -q -1 -f "$f" >/dev/null 2> "$WORK/migrate.err" || {
        say "migration failed: $f"; cat "$WORK/migrate.err" >&2; exit 1; }
    done < <("$HERE/ordered_migrations.sh" "$REPO/supabase/migrations")
    psql "$admin" -qAtc "alter role authenticator with password '$DB_PASSWORD'" >/dev/null
    stop_auth
    snapshot
  fi
  start_auth
  start_rest

  write_env
  say "ready"
  cat "$WORK/pipeline.env"
}

down() {
  stop_rest
  stop_auth
  local name; name="$(container_name)"
  [ -n "$name" ] && docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  say "removed"
}

case "${1:-}" in
  up) up ;;
  reset) reset ;;
  env) write_env; cat "$WORK/pipeline.env" ;;
  down) down ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
