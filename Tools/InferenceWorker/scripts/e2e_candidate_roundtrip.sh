#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FRWHOOP physiology e2e - candidate round trip on a REAL disposable PostgreSQL.
#
# OWNER: impl-e2e.  Reads: Tools/CloudWorker/**, Tools/InferenceWorker/**,
# supabase/migrations/**.  Writes: $E2E_ROOT (outside the checkout) only.
#
# THE LOOP THIS DRIVES
#   seeded stream rows (noop_hr_samples + noop_rr_intervals)
#     -> sidecar POST /v1/infer  (the exact payload DayScorer.hrvInput assembles)
#     -> the candidate write RPC, bound with the EXACT SQL text extracted at run
#        time from Tools/CloudWorker/Sources/frwhoop-worker/CandidateStage.swift
#     -> a real row in public.physiology_candidate_results
#
# HONEST SCOPE (read this before quoting the result)
#   * SWIFT LEG: the Swift worker is BUILT from this worktree (proving the SQL text
#     and the parameter encoder compile) and its candidate suites are RUN
#     (`swift test --filter`, stub sidecar + protocol fake store). The RPC is then
#     bound from SQL by this script, using the worker's own statement text and its
#     own NULL encoding (absent = '' -> nullif -> SQL NULL). That is SQL-LEVEL
#     BINDING OF THE SWIFT-BUILT CALL, NOT an in-process Swift test against
#     Postgres: the CloudWorker test target cannot be extended from this worker's
#     owned paths (Tools/InferenceWorker/**), and `Tools/CloudWorker/**` is owned by
#     another worker. The residual gap is exactly the transport hop
#     (PostgresClient -> PQexecParams), which is asserted here only as the encoded
#     string vector plus the migration's real parameter list (check A0).
#   * The cluster is a private Unix-socket-only PostgreSQL. It binds NO TCP port,
#     so it cannot touch the unrelated local Supabase stack (54321/54322/54323/55432).
#   * No production credential, no cloud, no network, no model download: the sleep
#     artifact root is materialized from the already-installed wheel.
#   * Section H drives a NINE-HOUR multi-window night (108 windows, 6,480 beats)
#     through the same sidecar and the same RPC, and asserts that the recorded
#     candidate value is the session mean over windows - not the first window's
#     RMSSD (audit S-1). Its expectation is computed in this script from the
#     fixture's own arithmetic, never from the provider's aggregation.
#
# Usage:  bash Tools/InferenceWorker/scripts/e2e_candidate_roundtrip.sh
#   E2E_SKIP_SWIFT=1   skip the Swift build/test leg (documented in the summary)
# ---------------------------------------------------------------------------
set -euo pipefail
E2E_SUMMARY_NAME="e2e_candidate_roundtrip"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_e2e.sh"
e2e_init candidate-roundtrip

command -v jq >/dev/null || { printf 'FATAL: jq is required\n' >&2; exit 2; }
command -v curl >/dev/null || { printf 'FATAL: curl is required\n' >&2; exit 2; }

USER_ID="11111111-1111-4111-8111-111111111111"
DEVICE_ID="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
UNKNOWN_DEVICE="ffffffff-ffff-4fff-8fff-ffffffffffff"
DAY="2026-09-30"
RR_BASE=1790800000            # 2026-09-30T20:26:40Z
RR_COUNT=90
PROVIDER_ID="production.runs.v1"
PROVIDER_VERSION="1.0.0"
CONFIG_VERSION="cfg-1"
ADAPTER_VERSION_EXPECTED="1.0.0"   # the SELECTED provider_version (the RPC requires the triple)
SHA_B="$(printf 'b%.0s' $(seq 1 64))"
SHA_C="$(printf 'c%.0s' $(seq 1 64))"
SHA_D="$(printf 'd%.0s' $(seq 1 64))"
SHA_E="$(printf 'e%.0s' $(seq 1 64))"
SHA_F="$(printf 'f%.0s' $(seq 1 64))"

# The 12 prerequisites the repository's own harness applies, in its dependency order,
# plus the candidate migration under test. Copied from
# supabase/functions/tests/physiology_candidate_providers_test.ts (PREREQUISITE_MIGRATIONS).
PREREQUISITES=(
  20260819190000_frwhoop_base_schema.sql
  20260824180000_production_persistence.sql
  20260907133000_noop_hr_samples.sql
  20260907133100_noop_append_stream_projections.sql
  20260907170000_noop_raw_object_lane.sql
  20260911120000_noop_remaining_append_projections.sql
  20260916160000_scoring_service_state.sql
  20260916170000_scoring_work_items_device_id.sql
  20260918010000_production_scoring_durability.sql
  20260918020000_physiology_publication.sql
  20260918050000_production_scoring_history.sql
  20260918230000_physiology_signed_promotion.sql
)
CANDIDATE_MIGRATION=20261002090000_physiology_candidate_providers.sql
SWIFT_SOURCE="$E2E_REPO_ROOT/Tools/CloudWorker/Sources/frwhoop-worker/CandidateStage.swift"

cleanup() { e2e_sidecar_stop || true; e2e_pg_stop || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
e2e_section "A. Swift leg: build the worker from THIS worktree and run its candidate suites"
# ---------------------------------------------------------------------------
SCRATCH="${E2E_SWIFT_SCRATCH:-/tmp/frwhoop-physiology/swift-build-e2e}"
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-/opt/homebrew/opt/libpq/lib/pkgconfig:/opt/homebrew/opt/zstd/lib/pkgconfig:/opt/homebrew/opt/openssl@3/lib/pkgconfig}"
if [ "${E2E_SKIP_SWIFT:-0}" = "1" ]; then
  e2e_skip "Swift build + candidate suites (E2E_SKIP_SWIFT=1)"
else
  e2e_require_tool swift "$E2E_SWIFT_BIN" E2E_SWIFT_BIN
  ( cd "$E2E_REPO_ROOT/Tools/CloudWorker" \
      && "$E2E_SWIFT_BIN" build --scratch-path "$SCRATCH" > "$E2E_RUN_DIR/swift-build.log" 2>&1 )
  e2e_pass "swift build of the worker from the worktree (log: swift-build.log)"
  ( cd "$E2E_REPO_ROOT/Tools/CloudWorker" \
      && "$E2E_SWIFT_BIN" test --scratch-path "$SCRATCH" \
           --filter 'CandidateStageTests|InferenceClientTests|DayScoringCandidateInputTests' \
           > "$E2E_RUN_DIR/swift-test.log" 2>&1 ) || true
  SWIFT_TESTS="$(grep -Eo "Executed [0-9]+ tests, with [0-9]+ failures" "$E2E_RUN_DIR/swift-test.log" | tail -1)"
  e2e_note "swift test (candidate suites)" "${SWIFT_TESTS:-no summary line}"
  e2e_assert_match "the candidate suites ran and reported 0 failures" \
    'with 0 failures' "${SWIFT_TESTS:-none}"
fi

e2e_section "A0. the Swift statement text and the migration's parameter list agree"
# swift_record_call.py extracts the statement verbatim and REFUSES to continue unless the
# placeholder count and the NULL-encoding pattern match the documented contract, so a non-zero
# exit here aborts this script (set -e): the check is enforced, not merely printed.
python3 "$E2E_IW_DIR/scripts/swift_record_call.py" --swift-source "$SWIFT_SOURCE" --dump \
  > "$E2E_RUN_DIR/swift-sql-dump.txt"
e2e_pass "the extracted Swift statement satisfies its own contract checks"
e2e_assert_eq "the statement has 23 distinct placeholders" "23" \
  "$(sed -n '/--- SQL extracted/,/--- contract checks/p' "$E2E_RUN_DIR/swift-sql-dump.txt" \
      | grep -o '\$[0-9]*' | sort -u | wc -l | tr -d ' ')"
e2e_assert_contains "nullif covers \$16..\$23 but never the jsonb object \$15" \
  '"nullif_params": [' "$(cat "$E2E_RUN_DIR/swift-sql-dump.txt")"
e2e_note "extracted SQL head" "$(sed -n '2p' "$E2E_RUN_DIR/swift-sql-dump.txt" | tr -s ' ')"

# ---------------------------------------------------------------------------
e2e_section "B. disposable PostgreSQL: unix socket only, never a TCP port"
# ---------------------------------------------------------------------------
e2e_pg_start pg
e2e_assert_eq "listen_addresses is empty, so no TCP port is bound" "" \
  "$(e2e_pg_sql "show listen_addresses")"
e2e_assert_eq "the cluster socket exists in the run directory" "yes" \
  "$([ -S "$E2E_PG_SOCK/.s.PGSQL.5432" ] && echo yes || echo no)"
e2e_assert_eq "the socket path is inside the run dir (outside the checkout)" "yes" \
  "$(case "$E2E_PG_SOCK" in "$E2E_RUN_DIR"/*) echo yes ;; *) echo no ;; esac)"
e2e_note "reserved ports untouched" "54321/54322/54323/55432 (not bound by this script)"

e2e_section "C. apply the curated prerequisite subset + the candidate migration"
e2e_pg_bootstrap
for migration in "${PREREQUISITES[@]}"; do
  e2e_pg_apply "$migration" >/dev/null
done
e2e_pg_apply "$CANDIDATE_MIGRATION" >/dev/null
e2e_pass "12 prerequisite migrations + $CANDIDATE_MIGRATION applied"

e2e_pg_apply "$CANDIDATE_MIGRATION" >/dev/null
e2e_pass "the candidate migration re-applies cleanly (idempotent)"

e2e_assert_eq "all four metrics are seeded off" "off|off|off|off" \
  "$(e2e_pg_sql "select string_agg(mode,'|' order by metric) from public.physiology_provider_defaults")"
e2e_assert_eq "every candidate table has RLS enabled" "5" \
  "$(e2e_pg_sql "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relrowsecurity
        and c.relname in ('physiology_candidate_results','physiology_provider_defaults',
                          'physiology_provider_overrides','physiology_candidate_debt',
                          'physiology_backfill_jobs')")"
e2e_assert_eq "no policy exists on the candidate tables (service-role only)" "0" \
  "$(e2e_pg_sql "select count(*) from pg_policies where schemaname='public'
      and tablename in ('physiology_candidate_results','physiology_provider_defaults',
                        'physiology_provider_overrides','physiology_candidate_debt',
                        'physiology_backfill_jobs')")"
e2e_assert_eq "authenticated cannot execute the record RPC" "f" \
  "$(e2e_pg_sql "select has_function_privilege('authenticated',
      'public.physiology_record_candidate_result(uuid,text,text,date,timestamptz,timestamptz,text,bigint,text,text,text,text,text,text,jsonb,text,numeric,text,jsonb,text,jsonb,jsonb,integer)',
      'execute')")"

# A0 (continued): the migration's real parameter list, in order, against the Swift list.
ACTUAL_SIGNATURE="$(e2e_pg_sql "select string_agg(split_part(a, ' ', 1), ',' order by ord)
  from unnest(string_to_array(pg_get_function_arguments(
    'public.physiology_record_candidate_result(uuid,text,text,date,timestamptz,timestamptz,text,bigint,text,text,text,text,text,text,jsonb,text,numeric,text,jsonb,text,jsonb,jsonb,integer)'::regprocedure),
    ', ')) with ordinality as t(a, ord)")"
# PhysiologyCandidateSQL.recordCandidateParameters (CandidateStage.swift), in order.
SWIFT_SIGNATURE="p_user,p_device,p_metric,p_period_day,p_interval_start_at,p_interval_end_at,p_input_sha256,p_input_revision,p_provider_id,p_provider_version,p_adapter_version,p_preprocessing_version,p_config_version,p_status,p_dependency_versions,p_withheld_reason,p_value,p_unit,p_stages,p_label_space,p_coverage,p_diagnostics,p_runtime_ms"
e2e_assert_eq "the migration's 23 parameters are named and ordered as the Swift list" \
  "$SWIFT_SIGNATURE" "$ACTUAL_SIGNATURE"

# ---------------------------------------------------------------------------
e2e_section "D. seed a synthetic day (HR rows + RR rows) and open the hrv lane"
# ---------------------------------------------------------------------------
e2e_pg_sql "insert into auth.users(id) values ('$USER_ID') on conflict (id) do nothing" >/dev/null
e2e_pg_sql "insert into public.devices(id,user_id,source_kind) values ('$DEVICE_ID','$USER_ID','strap')
            on conflict (id) do nothing" >/dev/null
e2e_pg_sql "insert into public.noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id)
            select '$USER_ID'::uuid,'$DEVICE_ID'::uuid,'$DEVICE_ID'::uuid, $RR_BASE + 5*g, 58 + (g % 5),
                   '$DEVICE_ID'::uuid
              from generate_series(0, 59) as g" >/dev/null
e2e_pg_sql "insert into public.noop_rr_intervals(user_id,device_id,source_id,ts,\"rrMs\",seq,ord,\"srcChannel\",batch_id)
            select '$USER_ID'::uuid,'$DEVICE_ID'::uuid,'$DEVICE_ID'::uuid, $RR_BASE + g,
                   800 + (g % 7) * 3, g, g, 1, '$DEVICE_ID'::uuid
              from generate_series(0, $((RR_COUNT - 1))) as g" >/dev/null
e2e_assert_eq "60 HR rows seeded" "60" \
  "$(e2e_pg_sql "select count(*) from public.noop_hr_samples where user_id='$USER_ID'::uuid")"
e2e_assert_eq "$RR_COUNT RR rows seeded" "$RR_COUNT" \
  "$(e2e_pg_sql "select count(*) from public.noop_rr_intervals where user_id='$USER_ID'::uuid")"

# Dormancy gate: the stream triggers exist, but with every mode 'off' they record no debt.
e2e_assert_eq "no candidate debt while every metric is off (dormancy gate)" "0" \
  "$(e2e_pg_sql "select count(*) from public.physiology_candidate_debt")"
e2e_assert_eq "the unconfigured metric resolves to mode=off" "off|default" \
  "$(e2e_pg_sql "select (public.physiology_selected_provider('$USER_ID'::uuid,'hrv')->>'mode')
      ||'|'||(public.physiology_selected_provider('$USER_ID'::uuid,'hrv')->>'source')")"

e2e_pg_sql "update public.physiology_provider_defaults
              set provider_id='$PROVIDER_ID', provider_version='$PROVIDER_VERSION',
                  config_version='$CONFIG_VERSION', mode='shadow', updated_at=clock_timestamp()
            where metric='hrv'" >/dev/null
e2e_assert_eq "hrv now selects the shadow provider" "shadow|default|$PROVIDER_ID|$PROVIDER_VERSION|$CONFIG_VERSION" \
  "$(e2e_pg_sql "select (public.physiology_selected_provider('$USER_ID'::uuid,'hrv')->>'mode')
      ||'|'||(public.physiology_selected_provider('$USER_ID'::uuid,'hrv')->>'source')
      ||'|'||(public.physiology_selected_provider('$USER_ID'::uuid,'hrv')->>'provider_id')
      ||'|'||(public.physiology_selected_provider('$USER_ID'::uuid,'hrv')->>'provider_version')
      ||'|'||(public.physiology_selected_provider('$USER_ID'::uuid,'hrv')->>'config_version')")"
e2e_assert_eq "a new stream insert now records candidate debt (trigger family fires)" "1" \
  "$(e2e_pg_sql "insert into public.noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id)
                   values ('$USER_ID'::uuid,'$DEVICE_ID'::uuid,'$DEVICE_ID'::uuid, $RR_BASE + 400, 61,
                           '$DEVICE_ID'::uuid);
                 select count(*) from public.physiology_candidate_debt
                  where user_id='$USER_ID'::uuid and day='$DAY'")"
e2e_assert_eq "the debt read RPC reports it" "true" \
  "$(e2e_pg_sql "select public.physiology_candidate_debt_read('$USER_ID'::uuid,'$DEVICE_ID','$DAY')->>'debt'")"

REVISION="$(e2e_pg_sql "select public.enqueue_scoring_v2('$USER_ID'::uuid,'$DEVICE_ID'::uuid,'$DAY'::date,'frwhoop-server-1','test')")"
e2e_assert_match "the day has a current input revision" '^[0-9]+$' "$REVISION"
e2e_note "input revision (current)" "$REVISION"

# ---------------------------------------------------------------------------
e2e_section "E. the sidecar serves the seeded night (real inference on DB rows)"
# ---------------------------------------------------------------------------
POPULATED_ROOT="$E2E_RUN_DIR/models-populated"
( cd "$E2E_IW_DIR" && "$E2E_UV_BIN" run python scripts/materialize_model_root.py "$POPULATED_ROOT" ) \
  > "$E2E_RUN_DIR/materialize.log"
e2e_sidecar_start hrv "$POPULATED_ROOT"
e2e_http_get /healthz
HEALTH="$(cat "$E2E_HTTP_BODY")"
e2e_assert_eq "the sidecar is fully ready (every provider, artifacts verified)" "true" \
  "$(printf '%s' "$HEALTH" | jq -r '.ready')"

e2e_pg_sql "select coalesce(json_agg(json_build_object(
              'ts', ts, 'rrMs', \"rrMs\", 'seq', seq, 'ord', ord, 'srcChannel', \"srcChannel\")
              order by ts, seq), '[]'::json)
            from public.noop_rr_intervals where user_id='$USER_ID'::uuid" \
  > "$E2E_RUN_DIR/rr-rows.json"
e2e_assert_eq "the request is built from the DB's own RR rows" "$RR_COUNT" \
  "$(jq 'length' "$E2E_RUN_DIR/rr-rows.json")"
( cd "$E2E_IW_DIR" && "$E2E_UV_BIN" run python scripts/build_hrv_request.py \
    --rows "$E2E_RUN_DIR/rr-rows.json" --out "$E2E_RUN_DIR/hrv-request.json" \
    --user-id "$USER_ID" --device-id "$DEVICE_ID" --tz America/New_York \
    --profile-version profile-1 --config-version "$CONFIG_VERSION" --corrections-version corr-0 ) \
  | tee "$E2E_RUN_DIR/build-request.log"
e2e_http_post /v1/infer "$E2E_RUN_DIR/hrv-request.json"
cp "$E2E_HTTP_BODY" "$E2E_RUN_DIR/infer-response.json"
INFER="$(cat "$E2E_RUN_DIR/infer-response.json")"
e2e_assert_eq "the sidecar answers 200" "200" "$E2E_HTTP_STATUS"
e2e_assert_eq "status is ok" "ok" "$(printf '%s' "$INFER" | jq -r '.status')"
e2e_assert_eq "provider is production.runs.v1" "production.runs.v1" \
  "$(printf '%s' "$INFER" | jq -r '.provider_id')"
e2e_assert_match "the RMSSD value is finite" '^-?[0-9]+(\.[0-9]+)?$' \
  "$(printf '%s' "$INFER" | jq -r '.result.value')"
e2e_note "rmssd_ms" "$(printf '%s' "$INFER" | jq -r '.result.value')"
e2e_note "valid_pairs / coverage" "$(printf '%s' "$INFER" | jq -r '.coverage.valid_pairs')"
e2e_assert_match "the response carries the input sha256 the worker records" '^[a-f0-9]{64}$' \
  "$(printf '%s' "$INFER" | jq -r '.input.sha256')"

# ---------------------------------------------------------------------------
e2e_section "F. bind the RPC with the EXACT SQL text from CandidateStage.swift"
# ---------------------------------------------------------------------------
INFER_START="$(printf '%s' "$INFER" | jq -r '.interval.start_utc')"
INFER_END="$(printf '%s' "$INFER" | jq -r '.interval.end_utc')"
python3 "$E2E_IW_DIR/scripts/swift_record_call.py" --swift-source "$SWIFT_SOURCE" \
  --from-response "$E2E_RUN_DIR/infer-response.json" \
  --user-id "$USER_ID" --device-id "$DEVICE_ID" --period-day "$DAY" \
  --interval-start "$INFER_START" --interval-end "$INFER_END" \
  --input-revision "$REVISION" --provider-id "$PROVIDER_ID" \
  --provider-version "$PROVIDER_VERSION" --config-version "$CONFIG_VERSION" \
  --input-rows "$RR_COUNT" --deduped-rows "$RR_COUNT" \
  --out "$E2E_RUN_DIR/call-ok.sql" | tee "$E2E_RUN_DIR/bind-ok.log"
# The ok record has exactly three absent optionals: $16 withheld_reason, $19 stages and
# $20 label_space. The other nullif'd parameters carry a real value (or a cast suffix), so the
# literal "nullif(''::text,'')" appears exactly three times. A fourth occurrence would mean a
# parameter that SHOULD have carried a value was encoded as absent.
e2e_assert_eq "the bound statement nullif's exactly the three absent optionals ('' -> NULL)" "3" \
  "$(grep -o "nullif(''::text,'')" "$E2E_RUN_DIR/call-ok.sql" | wc -l | tr -d ' ')"
e2e_assert_contains "p_dependency_versions is passed as a jsonb object, never ''" \
  "::jsonb" "$(grep -o "'{.*}'::jsonb" "$E2E_RUN_DIR/call-ok.sql" | head -1)"

CANDIDATE_ID="$(e2e_pg_file "$E2E_RUN_DIR/call-ok.sql" | tail -1)"
e2e_assert_match "the RPC returned a candidate_id (a real row was written)" \
  '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' "$CANDIDATE_ID"
e2e_note "candidate_id" "$CANDIDATE_ID"
e2e_assert_eq "exactly one candidate row exists" "1" \
  "$(e2e_pg_sql "select count(*) from public.physiology_candidate_results")"

ENVELOPE="$(e2e_pg_sql "select status||'|'||coalesce(value::text,'null')||'|'||coalesce(unit,'null')
    ||'|'||metric||'|'||period_day::text||'|'||provider_id||'|'||provider_version
    ||'|'||config_version||'|'||adapter_version||'|'||preprocessing_version
    ||'|'||input_sha256||'|'||coalesce(runtime_ms::text,'null')||'|'||device_id
  from public.physiology_candidate_results where candidate_id='$CANDIDATE_ID'")"
EXPECTED_VALUE="$(printf '%s' "$INFER" | jq -r '.result.value')"
EXPECTED_SHA="$(printf '%s' "$INFER" | jq -r '.input.sha256')"
EXPECTED_RUNTIME="$(printf '%s' "$INFER" | jq -r '.runtime_ms')"
EXPECTED_ADAPTER="$(printf '%s' "$INFER" | jq -r '.versions.adapter')"
EXPECTED_PREP="$(printf '%s' "$INFER" | jq -r '.versions.preprocessing')"
e2e_assert_eq "the stored envelope is exactly the sidecar's answer + the selected triple" \
  "ok|$EXPECTED_VALUE|ms|hrv|$DAY|$PROVIDER_ID|$PROVIDER_VERSION|$CONFIG_VERSION|$EXPECTED_ADAPTER|$EXPECTED_PREP|$EXPECTED_SHA|$EXPECTED_RUNTIME|$DEVICE_ID" \
  "$ENVELOPE"
e2e_assert_eq "the interval is the sidecar's interval" "$INFER_START|$INFER_END" \
  "$(e2e_pg_sql "select to_char(interval_start_at at time zone 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')
      ||'|'||to_char(interval_end_at at time zone 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')
      from public.physiology_candidate_results where candidate_id='$CANDIDATE_ID'")"
e2e_assert_eq "dependency_versions keeps the provider's dependency/model versions" \
  "$(printf '%s' "$INFER" | jq -r '.versions.dependency')|null" \
  "$(e2e_pg_sql "select dependency_versions->>'dependency'||'|'||coalesce(dependency_versions->>'model','null')
      from public.physiology_candidate_results where candidate_id='$CANDIDATE_ID'")"
e2e_assert_eq "coverage is stored as the sidecar's coverage object" \
  "$(printf '%s' "$INFER" | jq -r '.coverage.valid_pairs')" \
  "$(e2e_pg_sql "select coverage->>'valid_pairs' from public.physiology_candidate_results
      where candidate_id='$CANDIDATE_ID'")"
e2e_assert_eq "diagnostics record the mode, transport and row counts" "shadow|ok|$RR_COUNT|$RR_COUNT" \
  "$(e2e_pg_sql "select (diagnostics->>'mode')||'|'||(diagnostics->>'transport')||'|'
      ||(diagnostics->>'input_rows')||'|'||(diagnostics->>'deduped_rows')
      from public.physiology_candidate_results where candidate_id='$CANDIDATE_ID'")"
e2e_assert_eq "the canonical lane is untouched: the candidate write changed no canonical row" "0" \
  "$(e2e_pg_sql "select count(*) from public.physiology_candidate_results
      where candidate_id='$CANDIDATE_ID' and (status<>'ok' or value is null)")"

# ---------------------------------------------------------------------------
e2e_section "G1. replay is idempotent (ON CONFLICT DO NOTHING)"
# ---------------------------------------------------------------------------
REPLAY="$(e2e_pg_file "$E2E_RUN_DIR/call-ok.sql" | tail -1)"
e2e_assert_eq "the identical call returns NULL (nothing new written)" "null" "$REPLAY"
e2e_assert_eq "and the row count is unchanged" "1" \
  "$(e2e_pg_sql "select count(*) from public.physiology_candidate_results")"

# ---------------------------------------------------------------------------
e2e_section "G2. a stale input revision is refused by the guard"
# ---------------------------------------------------------------------------
REVISION_2="$(e2e_pg_sql "select public.enqueue_scoring_v2('$USER_ID'::uuid,'$DEVICE_ID'::uuid,'$DAY'::date,'frwhoop-server-1','test')")"
e2e_note "input revision (after a newer ingest generation)" "$REVISION_2"
e2e_assert_eq "the newer generation really is newer" "yes" \
  "$([ "$REVISION_2" -gt "$REVISION" ] && echo yes || echo no)"

python3 "$E2E_IW_DIR/scripts/swift_record_call.py" --swift-source "$SWIFT_SOURCE" \
  --from-response "$E2E_RUN_DIR/infer-response.json" \
  --user-id "$USER_ID" --device-id "$DEVICE_ID" --period-day "$DAY" \
  --interval-start "$INFER_START" --interval-end "$INFER_END" \
  --input-revision "$REVISION" --provider-id "$PROVIDER_ID" \
  --provider-version "$PROVIDER_VERSION" --config-version "$CONFIG_VERSION" \
  --input-rows "$RR_COUNT" --deduped-rows "$RR_COUNT" \
  --override "inputSHA256=$SHA_B" --out "$E2E_RUN_DIR/call-stale.sql" >/dev/null
e2e_assert_eq "a claim from the superseded generation is refused (NULL)" "null" \
  "$(e2e_pg_file "$E2E_RUN_DIR/call-stale.sql" | tail -1)"
e2e_assert_eq "and nothing was written" "1" \
  "$(e2e_pg_sql "select count(*) from public.physiology_candidate_results")"

python3 "$E2E_IW_DIR/scripts/swift_record_call.py" --swift-source "$SWIFT_SOURCE" \
  --from-response "$E2E_RUN_DIR/infer-response.json" \
  --user-id "$USER_ID" --device-id "$DEVICE_ID" --period-day "$DAY" \
  --interval-start "$INFER_START" --interval-end "$INFER_END" \
  --input-revision "$REVISION_2" --provider-id "$PROVIDER_ID" \
  --provider-version "$PROVIDER_VERSION" --config-version "$CONFIG_VERSION" \
  --input-rows "$RR_COUNT" --deduped-rows "$RR_COUNT" \
  --override "inputSHA256=$SHA_B" --out "$E2E_RUN_DIR/call-current.sql" >/dev/null
CANDIDATE_ID_2="$(e2e_pg_file "$E2E_RUN_DIR/call-current.sql" | tail -1)"
e2e_assert_match "the same claim at the CURRENT revision is accepted" \
  '^[0-9a-f]{8}-' "$CANDIDATE_ID_2"
e2e_assert_eq "so the stale refusal above was the guard, not the uniqueness key" "2" \
  "$(e2e_pg_sql "select count(*) from public.physiology_candidate_results")"

# ---------------------------------------------------------------------------
e2e_section "G3. a provider generation that is no longer selected is refused"
# ---------------------------------------------------------------------------
python3 "$E2E_IW_DIR/scripts/swift_record_call.py" --swift-source "$SWIFT_SOURCE" \
  --from-response "$E2E_RUN_DIR/infer-response.json" \
  --user-id "$USER_ID" --device-id "$DEVICE_ID" --period-day "$DAY" \
  --interval-start "$INFER_START" --interval-end "$INFER_END" \
  --input-revision "$REVISION_2" --provider-id "$PROVIDER_ID" \
  --provider-version "runs.v2" --config-version "$CONFIG_VERSION" \
  --input-rows "$RR_COUNT" --deduped-rows "$RR_COUNT" \
  --override "inputSHA256=$SHA_C" --out "$E2E_RUN_DIR/call-triple.sql" >/dev/null
e2e_assert_eq "a moved provider_version is refused (NULL)" "null" \
  "$(e2e_pg_file "$E2E_RUN_DIR/call-triple.sql" | tail -1)"
e2e_assert_eq "and nothing was written" "2" \
  "$(e2e_pg_sql "select count(*) from public.physiology_candidate_results")"

# ---------------------------------------------------------------------------
e2e_section "G4. mode=off is a total no-op for the lane"
# ---------------------------------------------------------------------------
e2e_pg_sql "update public.physiology_provider_defaults set mode='off', updated_at=clock_timestamp()
            where metric='hrv'" >/dev/null
e2e_assert_eq "the metric now resolves to off" "off" \
  "$(e2e_pg_sql "select public.physiology_selected_provider('$USER_ID'::uuid,'hrv')->>'mode'")"
python3 "$E2E_IW_DIR/scripts/swift_record_call.py" --swift-source "$SWIFT_SOURCE" \
  --from-response "$E2E_RUN_DIR/infer-response.json" \
  --user-id "$USER_ID" --device-id "$DEVICE_ID" --period-day "$DAY" \
  --interval-start "$INFER_START" --interval-end "$INFER_END" \
  --input-revision "$REVISION_2" --provider-id "$PROVIDER_ID" \
  --provider-version "$PROVIDER_VERSION" --config-version "$CONFIG_VERSION" \
  --input-rows "$RR_COUNT" --deduped-rows "$RR_COUNT" \
  --override "inputSHA256=$SHA_D" --out "$E2E_RUN_DIR/call-off.sql" >/dev/null
e2e_assert_eq "an off-mode write is refused (NULL)" "null" \
  "$(e2e_pg_file "$E2E_RUN_DIR/call-off.sql" | tail -1)"
e2e_assert_eq "and nothing was written" "2" \
  "$(e2e_pg_sql "select count(*) from public.physiology_candidate_results")"
e2e_pg_sql "update public.physiology_provider_defaults
              set provider_id='$PROVIDER_ID', provider_version='$PROVIDER_VERSION',
                  config_version='$CONFIG_VERSION', mode='shadow', updated_at=clock_timestamp()
            where metric='hrv'" >/dev/null
e2e_assert_eq "the lane is back on shadow" "shadow" \
  "$(e2e_pg_sql "select public.physiology_selected_provider('$USER_ID'::uuid,'hrv')->>'mode'")"

# ---------------------------------------------------------------------------
e2e_section "G5. a withheld result persists with its contract fields"
# ---------------------------------------------------------------------------
python3 "$E2E_IW_DIR/scripts/swift_record_call.py" --swift-source "$SWIFT_SOURCE" \
  --from-response "$E2E_RUN_DIR/infer-response.json" \
  --user-id "$USER_ID" --device-id "$DEVICE_ID" --period-day "$DAY" \
  --interval-start "$INFER_START" --interval-end "$INFER_END" \
  --input-revision "$REVISION_2" --provider-id "$PROVIDER_ID" \
  --provider-version "$PROVIDER_VERSION" --config-version "$CONFIG_VERSION" \
  --input-rows "$RR_COUNT" --deduped-rows "$RR_COUNT" \
  --override "inputSHA256=$SHA_E" --override status=withheld \
  --override withheldReason=insufficient_coverage --override value=null --override unit=null \
  --out "$E2E_RUN_DIR/call-withheld.sql" >/dev/null
CANDIDATE_ID_3="$(e2e_pg_file "$E2E_RUN_DIR/call-withheld.sql" | tail -1)"
e2e_assert_match "the withheld candidate is recorded" '^[0-9a-f]{8}-' "$CANDIDATE_ID_3"
e2e_assert_eq "it stores null value + the machine-readable reason" "withheld|null|insufficient_coverage" \
  "$(e2e_pg_sql "select status||'|'||coalesce(value::text,'null')||'|'||withheld_reason
      from public.physiology_candidate_results where candidate_id='$CANDIDATE_ID_3'")"
e2e_assert_eq "row count is now 3" "3" \
  "$(e2e_pg_sql "select count(*) from public.physiology_candidate_results")"

# ---------------------------------------------------------------------------
e2e_section "G6. malformed shapes raise 22023 and write nothing"
# ---------------------------------------------------------------------------
python3 "$E2E_IW_DIR/scripts/swift_record_call.py" --swift-source "$SWIFT_SOURCE" \
  --from-response "$E2E_RUN_DIR/infer-response.json" \
  --user-id "$USER_ID" --device-id "$DEVICE_ID" --period-day "$DAY" \
  --interval-start "$INFER_START" --interval-end "$INFER_END" \
  --input-revision "$REVISION_2" --provider-id "$PROVIDER_ID" \
  --provider-version "$PROVIDER_VERSION" --config-version "$CONFIG_VERSION" \
  --input-rows "$RR_COUNT" --deduped-rows "$RR_COUNT" \
  --override "inputSHA256=$SHA_F" --override status=ok --override value=null \
  --override stages=null --override withheldReason=null \
  --out "$E2E_RUN_DIR/call-malformed.sql" >/dev/null
MALFORMED="$(e2e_pg_sql_err "$(cat "$E2E_RUN_DIR/call-malformed.sql")")"
e2e_assert_contains "an ok result with neither value nor stages is rejected" \
  "invalid_candidate_result" "$MALFORMED"
e2e_assert_eq "and nothing was written" "3" \
  "$(e2e_pg_sql "select count(*) from public.physiology_candidate_results")"

python3 "$E2E_IW_DIR/scripts/swift_record_call.py" --swift-source "$SWIFT_SOURCE" \
  --from-response "$E2E_RUN_DIR/infer-response.json" \
  --user-id "$USER_ID" --device-id "$DEVICE_ID" --period-day "$DAY" \
  --interval-start "$INFER_START" --interval-end "$INFER_END" \
  --input-revision "$REVISION_2" --provider-id "$PROVIDER_ID" \
  --provider-version "$PROVIDER_VERSION" --config-version "$CONFIG_VERSION" \
  --input-rows "$RR_COUNT" --deduped-rows "$RR_COUNT" \
  --override "inputSHA256=$SHA_F" --override value=5000 \
  --out "$E2E_RUN_DIR/call-outofbounds.sql" >/dev/null
OUT_OF_BOUNDS="$(e2e_pg_sql_err "$(cat "$E2E_RUN_DIR/call-outofbounds.sql")")"
e2e_assert_contains "an hrv value of 5000 ms is rejected by the metric bounds" \
  "candidate_value_out_of_bounds" "$OUT_OF_BOUNDS"
e2e_assert_eq "and nothing was written" "3" \
  "$(e2e_pg_sql "select count(*) from public.physiology_candidate_results")"

# ---------------------------------------------------------------------------
e2e_section "G7. ownership: another device cannot be written to"
# ---------------------------------------------------------------------------
python3 "$E2E_IW_DIR/scripts/swift_record_call.py" --swift-source "$SWIFT_SOURCE" \
  --from-response "$E2E_RUN_DIR/infer-response.json" \
  --user-id "$USER_ID" --device-id "$UNKNOWN_DEVICE" --period-day "$DAY" \
  --interval-start "$INFER_START" --interval-end "$INFER_END" \
  --input-revision "$REVISION_2" --provider-id "$PROVIDER_ID" \
  --provider-version "$PROVIDER_VERSION" --config-version "$CONFIG_VERSION" \
  --input-rows "$RR_COUNT" --deduped-rows "$RR_COUNT" \
  --override "inputSHA256=$SHA_D" --out "$E2E_RUN_DIR/call-unowned.sql" >/dev/null
e2e_assert_eq "a device the user does not own is refused (NULL)" "null" \
  "$(e2e_pg_file "$E2E_RUN_DIR/call-unowned.sql" | tail -1)"
e2e_assert_eq "row count is still 3" "3" \
  "$(e2e_pg_sql "select count(*) from public.physiology_candidate_results")"

# ---------------------------------------------------------------------------
e2e_section "H. multi-window night (audit S-1): the candidate value is the session mean"
# ---------------------------------------------------------------------------
# The audit's S-1 repro, end to end through the REAL sidecar and the REAL RPC: a nine-hour
# night spanning 108 tumbling 5-minute windows - the audit's 39,513-beat night at the same
# WINDOW count, with 60 clean intervals in each window (one beat per second for the first
# 60 s of it) instead of 300, so the script does not spend minutes inserting one dense
# night. Every window is clean and its RMSSD is analytically 2a: inside a window the RR
# alternates +a/-a, so every successive difference is +/-2a and RMSSD = 2a exactly. With
# a = 10 + (window % 5) * 10 the window RMSSDs cycle 20, 40, 60, 80, 100 ms, so the
# session mean (59.44 ms) is a number the FIRST window (20 ms) cannot produce. The
# expectation is computed HERE from that arithmetic; this script never imports the
# provider's aggregation, and the request is built by scripts/build_hrv_request.py, i.e.
# the worker's real shape (intent only in input.config).
NIGHT_BASE=1790733600                  # 2026-09-30T02:00:00Z (same period_day as above)
NIGHT_WINDOWS=108                      # 9 h / 300 s
NIGHT_BEATS_PER_WINDOW=60              # one beat per second for the first 60 s of each window
NIGHT_BEATS=$((NIGHT_WINDOWS * NIGHT_BEATS_PER_WINDOW))
NIGHT_LAST=$((NIGHT_BASE + (NIGHT_WINDOWS - 1) * 300 + NIGHT_BEATS_PER_WINDOW - 1))

e2e_pg_sql "insert into public.noop_rr_intervals(user_id,device_id,source_id,ts,\"rrMs\",seq,ord,\"srcChannel\",batch_id)
            select '$USER_ID'::uuid,'$DEVICE_ID'::uuid,'$DEVICE_ID'::uuid,
                   $NIGHT_BASE + (g / $NIGHT_BEATS_PER_WINDOW) * 300 + (g % $NIGHT_BEATS_PER_WINDOW),
                   1000 + (case when (g % $NIGHT_BEATS_PER_WINDOW) % 2 = 0 then 1 else -1 end)
                          * (10 + ((g / $NIGHT_BEATS_PER_WINDOW) % 5) * 10),
                   g, g, 1, '$DEVICE_ID'::uuid
              from generate_series(0, $((NIGHT_BEATS - 1))) as g" >/dev/null
e2e_assert_eq "$NIGHT_BEATS night beats seeded" "$NIGHT_BEATS" \
  "$(e2e_pg_sql "select count(*) from public.noop_rr_intervals
      where user_id='$USER_ID'::uuid and ts between $NIGHT_BASE and $NIGHT_LAST")"

REVISION_3="$(e2e_pg_sql "select public.enqueue_scoring_v2('$USER_ID'::uuid,'$DEVICE_ID'::uuid,'$DAY'::date,'frwhoop-server-1','test')")"
e2e_assert_match "the night has a current input revision" '^[0-9]+$' "$REVISION_3"
e2e_note "input revision (multi-window night)" "$REVISION_3"

e2e_pg_sql "select coalesce(json_agg(json_build_object(
              'ts', ts, 'rrMs', \"rrMs\", 'seq', seq, 'ord', ord, 'srcChannel', \"srcChannel\")
              order by ts, seq), '[]'::json)
            from public.noop_rr_intervals
           where user_id='$USER_ID'::uuid and ts between $NIGHT_BASE and $NIGHT_LAST" \
  > "$E2E_RUN_DIR/night-rows.json"
e2e_assert_eq "the night request is built from every seeded night beat" "$NIGHT_BEATS" \
  "$(jq 'length' "$E2E_RUN_DIR/night-rows.json")"

( cd "$E2E_IW_DIR" && "$E2E_UV_BIN" run python scripts/build_hrv_request.py \
    --rows "$E2E_RUN_DIR/night-rows.json" --pad-seconds 0 \
    --out "$E2E_RUN_DIR/night-request.json" \
    --user-id "$USER_ID" --device-id "$DEVICE_ID" --tz America/New_York \
    --profile-version profile-1 --config-version "$CONFIG_VERSION" --corrections-version corr-0 ) \
  | tee "$E2E_RUN_DIR/build-night-request.log"
e2e_assert_eq "the worker payload states its intent in input.config" "mean_over_windows" \
  "$(jq -r '.input.config.aggregation' "$E2E_RUN_DIR/night-request.json")"
e2e_assert_eq "and sends the top-level input.aggregation (the current worker shape)" "mean_over_windows" \
  "$(jq -r '.input.aggregation // "null"' "$E2E_RUN_DIR/night-request.json")"

e2e_http_post /v1/infer "$E2E_RUN_DIR/night-request.json"
cp "$E2E_HTTP_BODY" "$E2E_RUN_DIR/night-response.json"
NIGHT="$(cat "$E2E_RUN_DIR/night-response.json")"
e2e_assert_eq "the sidecar answers 200" "200" "$E2E_HTTP_STATUS"
e2e_assert_eq "status is ok" "ok" "$(printf '%s' "$NIGHT" | jq -r '.status')"
e2e_assert_eq "the parser mirrored input.config and took the session aggregation" \
  "mean_over_windows" "$(printf '%s' "$NIGHT" | jq -r '.diagnostics.aggregation')"
e2e_assert_eq "all $NIGHT_WINDOWS windows were scored" "$NIGHT_WINDOWS" \
  "$(printf '%s' "$NIGHT" | jq -r '.coverage.usable_windows')"
e2e_assert_eq "and the interval really is a $NIGHT_WINDOWS-window night" "$NIGHT_WINDOWS" \
  "$(printf '%s' "$NIGHT" | jq -r '.coverage.total_windows')"
e2e_assert_eq "the first window's OWN RMSSD is the 20 ms the pre-repair code returned" "yes" \
  "$(python3 -c "
import sys
print('yes' if abs(float(sys.argv[1]) - 20.0) <= 1e-9 else 'no')
" "$(printf '%s' "$NIGHT" | jq -r '.diagnostics.windows[0].rmssd_ms')")"

# Independent expectation: the plain mean over the 108 window RMSSDs, each of which is 2a
# by construction. Nothing from the provider is imported to compute it.
NIGHT_EXPECTED="$(python3 -c "
n = $NIGHT_WINDOWS
values = [2.0 * (10 + (k % 5) * 10) for k in range(n)]
print(repr(sum(values) / float(len(values))))
")"
e2e_note "independently computed session mean over windows" "$NIGHT_EXPECTED"
NIGHT_VALUE="$(printf '%s' "$NIGHT" | jq -r '.result.value')"
e2e_note "sidecar value" "$NIGHT_VALUE"
e2e_assert_eq "the sidecar value equals the independent session mean over windows" "yes" \
  "$(python3 -c "
import sys
value, expected = float(sys.argv[1]), float(sys.argv[2])
print('yes' if abs(value - expected) <= 1e-9 else 'no')
" "$NIGHT_VALUE" "$NIGHT_EXPECTED")"
e2e_assert_eq "and it is NOT the first window's value (S-1 regression guard)" "yes" \
  "$(python3 -c "
import sys
value, first = float(sys.argv[1]), float(sys.argv[2])
print('yes' if abs(value - first) > 1e-6 else 'no')
" "$NIGHT_VALUE" "20")"

NIGHT_START="$(printf '%s' "$NIGHT" | jq -r '.interval.start_utc')"
NIGHT_END="$(printf '%s' "$NIGHT" | jq -r '.interval.end_utc')"
python3 "$E2E_IW_DIR/scripts/swift_record_call.py" --swift-source "$SWIFT_SOURCE" \
  --from-response "$E2E_RUN_DIR/night-response.json" \
  --user-id "$USER_ID" --device-id "$DEVICE_ID" --period-day "$DAY" \
  --interval-start "$NIGHT_START" --interval-end "$NIGHT_END" \
  --input-revision "$REVISION_3" --provider-id "$PROVIDER_ID" \
  --provider-version "$PROVIDER_VERSION" --config-version "$CONFIG_VERSION" \
  --input-rows "$NIGHT_BEATS" --deduped-rows "$NIGHT_BEATS" \
  --out "$E2E_RUN_DIR/call-night.sql" >/dev/null
NIGHT_CANDIDATE_ID="$(e2e_pg_file "$E2E_RUN_DIR/call-night.sql" | tail -1)"
e2e_assert_match "the multi-window candidate is recorded" \
  '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' "$NIGHT_CANDIDATE_ID"
e2e_note "night candidate_id" "$NIGHT_CANDIDATE_ID"
NIGHT_STORED="$(e2e_pg_sql "select value::text from public.physiology_candidate_results
    where candidate_id='$NIGHT_CANDIDATE_ID'")"
e2e_note "stored candidate value" "$NIGHT_STORED"
e2e_assert_eq "the RECORDED candidate value equals the session mean over windows" "yes" \
  "$(python3 -c "
import sys
stored, expected = float(sys.argv[1]), float(sys.argv[2])
print('yes' if abs(stored - expected) <= 1e-9 else 'no')
" "$NIGHT_STORED" "$NIGHT_EXPECTED")"
e2e_assert_eq "and the recorded value is not the first window's 20 ms" "yes" \
  "$(python3 -c "
import sys
print('yes' if abs(float(sys.argv[1]) - 20.0) > 1e-6 else 'no')
" "$NIGHT_STORED")"
e2e_assert_eq "the recorded interval is the night the beats describe" "$NIGHT_START|$NIGHT_END" \
  "$(e2e_pg_sql "select to_char(interval_start_at at time zone 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')
      ||'|'||to_char(interval_end_at at time zone 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')
      from public.physiology_candidate_results where candidate_id='$NIGHT_CANDIDATE_ID'")"
e2e_assert_eq "the stored coverage reports all $NIGHT_WINDOWS windows usable" "$NIGHT_WINDOWS" \
  "$(e2e_pg_sql "select coverage->>'usable_windows' from public.physiology_candidate_results
      where candidate_id='$NIGHT_CANDIDATE_ID'")"
e2e_assert_eq "the night row is stored ok with a value" "ok|yes" \
  "$(e2e_pg_sql "select status||'|'||(case when value is null then 'no' else 'yes' end)
      from public.physiology_candidate_results where candidate_id='$NIGHT_CANDIDATE_ID'")"

# ---------------------------------------------------------------------------
e2e_section "I. scope statement (what this run does and does not prove)"
# ---------------------------------------------------------------------------
e2e_note "Swift leg" "built from this worktree + candidate suites green; the RPC was bound
    from the worker's OWN extracted SQL text, not from an in-process Swift test"
e2e_note "not proven" "the PostgresClient -> PQexecParams transport hop; deployed Supabase
    version behaviour; provider accuracy; any production default (all four metrics stay off)"

e2e_summary
