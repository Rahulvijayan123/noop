#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FRWHOOP physiology e2e - sidecar HTTP contract, loopback only.
#
# OWNER: impl-e2e.  Reads: Tools/InferenceWorker/**, supabase/migrations/**.
# Writes: $E2E_ROOT (outside the checkout) only.
#
# What this proves (and what it does NOT):
#   * the sidecar starts on 127.0.0.1 with an EPHEMERAL port and is reachable
#     only on loopback (lsof shows the bound address);
#   * /healthz reports readiness PER PROVIDER, with the sleep-staging checkpoint
#     gating only its own provider and the manifest reason naming the artifact;
#   * POST /v1/infer serves `hrv` 200/ok for the payload shape the Swift worker
#     actually assembles (scripts/build_hrv_request.py mirrors
#     DayScorer.hrvInput/CandidateStage.runOne);
#   * with an EMPTY artifact root, `sleep_stage` is refused with a reason that
#     names `blocked_artifact` (HTTP 503 provider_not_ready - the readiness gate),
#     and it is served 200/ok with real stages once the root is populated from the
#     installed wheel;
#   * a non-loopback bind is refused by the CLI (exit 2, never binds).
#   It does NOT prove provider accuracy, and it never touches a database.
#
# Usage:  bash Tools/InferenceWorker/scripts/e2e_sidecar_http.sh
# ---------------------------------------------------------------------------
set -euo pipefail
E2E_SUMMARY_NAME="e2e_sidecar_http"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_e2e.sh"
e2e_init sidecar-http

command -v jq >/dev/null || { printf 'FATAL: jq is required\n' >&2; exit 2; }
command -v curl >/dev/null || { printf 'FATAL: curl is required\n' >&2; exit 2; }

USER_ID="11111111-1111-4111-8111-111111111111"
DEVICE_ID="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
RESERVED_PORTS="54321 54322 54323 55432 8787"

cleanup() { e2e_sidecar_stop || true; }
trap cleanup EXIT

EMPTY_ROOT="$E2E_RUN_DIR/models-empty"
POPULATED_ROOT="$E2E_RUN_DIR/models-populated"
mkdir -p "$EMPTY_ROOT"

e2e_section "0. materialize the sleep-staging artifact root from the installed wheel"
( cd "$E2E_IW_DIR" && "$E2E_UV_BIN" run python scripts/materialize_model_root.py "$POPULATED_ROOT" )
if [ -n "$(find "$EMPTY_ROOT" -type f -print -quit)" ]; then
  e2e_fail "the empty artifact root is really empty"
else
  e2e_pass "the empty artifact root is really empty"
fi

e2e_section "1. sidecar on 127.0.0.1, ephemeral port, EMPTY artifact root"
e2e_sidecar_start empty "$EMPTY_ROOT"
e2e_note "port" "$E2E_SIDECAR_PORT"
e2e_note "url" "$E2E_SIDECAR_URL"
e2e_assert_match "ephemeral port (not 8787, not a Supabase port)" \
  '^[0-9]+$' "$E2E_SIDECAR_PORT"
for reserved in $RESERVED_PORTS; do
  if [ "$E2E_SIDECAR_PORT" = "$reserved" ]; then
    e2e_fail "sidecar did not take a reserved port $reserved"
  fi
done
e2e_pass "sidecar avoided every reserved port ($RESERVED_PORTS)"

LISTEN_ADDR="$(e2e_sidecar_listen_address)"
e2e_note "listen address" "$LISTEN_ADDR"
e2e_assert_match "the listening socket is bound to 127.0.0.1 only" \
  '^127\.0\.0\.1:' "$LISTEN_ADDR"

e2e_http_get /healthz
HEALTH="$(cat "$E2E_HTTP_BODY")"
e2e_assert_eq "GET /healthz is 200" "200" "$E2E_HTTP_STATUS"
e2e_assert_eq "process readiness is false while the checkpoint is missing" \
  "false" "$(printf '%s' "$HEALTH" | jq -r '.ready')"
e2e_assert_eq "manifest.ok is false" "false" "$(printf '%s' "$HEALTH" | jq -r '.manifest.ok')"
e2e_assert_contains "the manifest reason names the missing entry" \
  "sleepecg_wrn_gru_mesa" "$(printf '%s' "$HEALTH" | jq -r '.manifest.reason')"
for pid in production.runs.v1 neurokit2.shadow.v1 hypnospy.hr-boundary.v1; do
  e2e_assert_eq "provider $pid is ready (no model bytes needed)" \
    "true" "$(printf '%s' "$HEALTH" | jq -r --arg p "$pid" '.providers[$p].ready')"
  e2e_assert_eq "provider $pid reports no reason" \
    "null" "$(printf '%s' "$HEALTH" | jq -r --arg p "$pid" '.providers[$p].reason')"
  e2e_assert_match "provider $pid reports a version" \
    '^.+$' "$(printf '%s' "$HEALTH" | jq -r --arg p "$pid" '.providers[$p].version')"
done
e2e_assert_eq "sleepecg.wrn-gru-mesa.v1 is NOT ready" \
  "false" "$(printf '%s' "$HEALTH" | jq -r '.providers["sleepecg.wrn-gru-mesa.v1"].ready')"
e2e_assert_contains "its reason is blocked_artifact" \
  "blocked_artifact" "$(printf '%s' "$HEALTH" | jq -r '.providers["sleepecg.wrn-gru-mesa.v1"].reason')"
e2e_assert_eq "the failed check is reported as missing" \
  "missing" "$(printf '%s' "$HEALTH" | jq -r '.manifest.failed_checks[0].status')"

e2e_http_get /v1/providers
CAPS="$(cat "$E2E_HTTP_BODY")"
e2e_assert_eq "GET /v1/providers is 200" "200" "$E2E_HTTP_STATUS"
e2e_assert_eq "capability listing carries all four wired providers" "4" \
  "$(printf '%s' "$CAPS" | jq -r '[.providers[]] | length')"
e2e_assert_eq "the recorded (unwired) models are listed with their status" "8" \
  "$(printf '%s' "$CAPS" | jq -r '[.models[]] | length')"

e2e_section "2. POST /v1/infer hrv with the WORKER payload shape (empty root: HRV is unaffected)"
( cd "$E2E_IW_DIR" && "$E2E_UV_BIN" run python scripts/build_hrv_request.py \
    --synthetic-count 90 --synthetic-start 1790808000 \
    --user-id "$USER_ID" --device-id "$DEVICE_ID" --tz America/New_York \
    --profile-version profile-1 --config-version cfg-1 --corrections-version corr-0 \
    --out "$E2E_RUN_DIR/hrv-request.json" )
e2e_http_post /v1/infer "$E2E_RUN_DIR/hrv-request.json"
HRV="$(cat "$E2E_HTTP_BODY")"
e2e_assert_eq "hrv infer is 200" "200" "$E2E_HTTP_STATUS"
e2e_assert_eq "hrv status is ok" "ok" "$(printf '%s' "$HRV" | jq -r '.status')"
e2e_assert_eq "hrv provider is production.runs.v1" \
  "production.runs.v1" "$(printf '%s' "$HRV" | jq -r '.provider_id')"
e2e_assert_eq "hrv unit is ms" "ms" "$(printf '%s' "$HRV" | jq -r '.result.unit')"
e2e_assert_match "hrv value is a finite number" \
  '^-?[0-9]+(\.[0-9]+)?$' "$(printf '%s' "$HRV" | jq -r '.result.value')"
e2e_assert_match "hrv input sha256 is 64 hex chars" \
  '^[a-f0-9]{64}$' "$(printf '%s' "$HRV" | jq -r '.input.sha256')"
e2e_assert_eq "hrv coverage reports the valid pair count (89 of 90 beats)" "89" \
  "$(printf '%s' "$HRV" | jq -r '.coverage.valid_pairs')"
e2e_assert_eq "hrv production dependency version is the pinned numeric stack" \
  "numpy==2.5.3" "$(printf '%s' "$HRV" | jq -r '.versions.dependency')"
e2e_assert_match "hrv adapter version is reported" '^.+$' \
  "$(printf '%s' "$HRV" | jq -r '.versions.adapter')"
e2e_assert_match "hrv preprocessing version is reported" '^.+$' \
  "$(printf '%s' "$HRV" | jq -r '.versions.preprocessing')"
e2e_assert_eq "hrv model version is null (no model bytes for this provider)" \
  "null" "$(printf '%s' "$HRV" | jq -r '.versions.model')"
e2e_assert_match "hrv runtime_ms is an integer" \
  '^[0-9]+$' "$(printf '%s' "$HRV" | jq -r '.runtime_ms')"
e2e_http_get /healthz
e2e_assert_eq "the process-level readiness flag is still false" \
  "false" "$(jq -r '.ready' "$E2E_HTTP_BODY")"
e2e_http_get /healthz
e2e_assert_eq "the HRV request was counted" \
  "1" "$(jq -r '.counters.inference' "$E2E_HTTP_BODY")"

e2e_section "2b. the gated comparison provider (neurokit2) is reachable and never publishable"
sed 's/"production.runs.v1"/"neurokit2.shadow.v1"/' "$E2E_RUN_DIR/hrv-request.json" \
  > "$E2E_RUN_DIR/hrv-shadow-request.json"
e2e_http_post /v1/infer "$E2E_RUN_DIR/hrv-shadow-request.json"
SHADOW="$(cat "$E2E_HTTP_BODY")"
e2e_assert_eq "neurokit2 infer is 200" "200" "$E2E_HTTP_STATUS"
e2e_assert_eq "provider id is neurokit2.shadow.v1" \
  "neurokit2.shadow.v1" "$(printf '%s' "$SHADOW" | jq -r '.provider_id')"
e2e_assert_eq "the shadow provider can never publish" "false" \
  "$(printf '%s' "$SHADOW" | jq -r '.publishable')"
e2e_assert_eq "it is labelled unverified_accuracy" "unverified_accuracy" \
  "$(printf '%s' "$SHADOW" | jq -r '.accuracy_label')"
e2e_assert_eq "its dependency version is the pinned neurokit2" "neurokit2==0.2.13" \
  "$(printf '%s' "$SHADOW" | jq -r '.versions.dependency')"

e2e_section "3. sleep_stage with an EMPTY artifact root is refused with blocked_artifact"
cat > "$E2E_RUN_DIR/sleep-stage-minimal.json" <<JSON
{"metric":"sleep_stage","context":{"user_id":"$USER_ID","device_id":"$DEVICE_ID",
 "interval_start_utc":"2026-10-19T02:45:00Z","interval_end_utc":"2026-10-19T11:05:00Z",
 "iana_timezone":"America/New_York","profile_version":"profile-1","config_version":"cfg-1",
 "corrections_version":"corr-0"},"input":{},"provider":{"provider_id":"sleepecg.wrn-gru-mesa.v1"}}
JSON
e2e_http_post /v1/infer "$E2E_RUN_DIR/sleep-stage-minimal.json"
STAGE_BLOCKED="$(cat "$E2E_HTTP_BODY")"
e2e_assert_eq "sleep_stage is refused with 503 while the checkpoint is missing" \
  "503" "$E2E_HTTP_STATUS"
e2e_assert_eq "the error code is provider_not_ready" \
  "provider_not_ready" "$(printf '%s' "$STAGE_BLOCKED" | jq -r '.error.code')"
e2e_assert_contains "the refusal names blocked_artifact" \
  "blocked_artifact" "$(printf '%s' "$STAGE_BLOCKED" | jq -r '.error.message')"
e2e_note "refusal message" "$(printf '%s' "$STAGE_BLOCKED" | jq -r '.error.message')"
e2e_sidecar_stop

e2e_section "4. sidecar with the POPULATED artifact root: sleep_stage is served"
e2e_sidecar_start populated "$POPULATED_ROOT"
e2e_http_get /healthz
HEALTH2="$(cat "$E2E_HTTP_BODY")"
e2e_assert_eq "healthz is 200" "200" "$E2E_HTTP_STATUS"
e2e_assert_eq "manifest.ok is true" "true" "$(printf '%s' "$HEALTH2" | jq -r '.manifest.ok')"
e2e_assert_eq "process readiness is true" "true" "$(printf '%s' "$HEALTH2" | jq -r '.ready')"
e2e_assert_eq "every provider is ready" "true" \
  "$(printf '%s' "$HEALTH2" | jq -r '[.providers[].ready] | all')"
e2e_assert_eq "the staging provider reports no reason" "null" \
  "$(printf '%s' "$HEALTH2" | jq -r '.providers["sleepecg.wrn-gru-mesa.v1"].reason')"

( cd "$E2E_IW_DIR" && "$E2E_UV_BIN" run python scripts/build_sleep_stage_request.py \
    --out "$E2E_RUN_DIR/sleep-stage-request.json" \
    --user-id "$USER_ID" --device-id "$DEVICE_ID" --fixture normal_night )
e2e_http_post /v1/infer "$E2E_RUN_DIR/sleep-stage-request.json"
STAGE_OK="$(cat "$E2E_HTTP_BODY")"
e2e_assert_eq "sleep_stage infer is 200" "200" "$E2E_HTTP_STATUS"
e2e_assert_eq "sleep_stage status is ok" "ok" "$(printf '%s' "$STAGE_OK" | jq -r '.status')"
e2e_assert_eq "sleep_stage provider id" \
  "sleepecg.wrn-gru-mesa.v1" "$(printf '%s' "$STAGE_OK" | jq -r '.provider_id')"
e2e_assert_eq "label space is the three-class space" \
  "wake/rem/nrem" "$(printf '%s' "$STAGE_OK" | jq -r '.result.label_space')"
e2e_assert_match "the stage array is non-empty" '^[1-9][0-9]*$' \
  "$(printf '%s' "$STAGE_OK" | jq -r '.result.stages | length')"
e2e_assert_eq "every stage label is inside the declared label space" "true" \
  "$(printf '%s' "$STAGE_OK" | jq -r '[.result.stages[].stage] | unique | map(. == "wake" or . == "rem" or . == "nrem") | all')"
e2e_assert_eq "the uncalibrated scores are not labelled calibrated" "false" \
  "$(printf '%s' "$STAGE_OK" | jq -r '.raw_scores.calibrated')"
e2e_assert_eq "the stage provider is not publishable" "false" \
  "$(printf '%s' "$STAGE_OK" | jq -r '.publishable')"
e2e_assert_eq "its accuracy label is unverified_accuracy" \
  "unverified_accuracy" "$(printf '%s' "$STAGE_OK" | jq -r '.accuracy_label')"

e2e_section "5. non-loopback bind is refused"
set +e
REFUSAL="$( cd "$E2E_IW_DIR" && "$E2E_UV_BIN" run python -m frwhoop_inference.server \
  --host 0.0.0.0 --port 0 2>&1 )"
REFUSAL_STATUS=$?
set -e
e2e_assert_eq "the CLI exits 2 for a non-loopback host" "2" "$REFUSAL_STATUS"
e2e_assert_contains "and says loopback only" "loopback only" "$REFUSAL"
e2e_note "refusal" "$(printf '%s' "$REFUSAL" | tail -1)"

e2e_summary
