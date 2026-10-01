# Deployed public function enumeration

Captured from the live FRWHOOP Postgres database (READ-ONLY). See `db_url.txt` in `research/`.

- Date (UTC): 2026-09-30T08:13:58.928056
- Row count: 276

## Exact SQL executed

```sql
SELECT p.oid::regprocedure, p.proname, pg_get_function_identity_arguments(p.oid)
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' ORDER BY 1;
```

## Full output

```text
rls_auto_enable()|rls_auto_enable|
set_updated_at()|set_updated_at|
handle_new_user()|handle_new_user|
get_frwhoop_day(date)|get_frwhoop_day|for_day date
engine_load_user_days(text,uuid,date,date)|engine_load_user_days|p_secret text, p_user_id uuid, p_from date, p_to date
engine_ingest_upsert(text,jsonb)|engine_ingest_upsert|p_secret text, p_payload jsonb
engine_ingest_extras(text,jsonb)|engine_ingest_extras|p_secret text, p_payload jsonb
app_upsert_daily_metrics(text,jsonb)|app_upsert_daily_metrics|p_secret text, p_rows jsonb
app_upsert_device(text,uuid,text,text,text,jsonb)|app_upsert_device|p_secret text, p_user_id uuid, p_external_device_id text, p_nickname text, p_firmware text, p_sync_state jsonb
sync_daily_metric_aliases()|sync_daily_metric_aliases|
bump_user_revision()|bump_user_revision|
get_day_snapshot(date)|get_day_snapshot|p_day date
get_range(date,date)|get_range|p_from date, p_to date
get_sync_revision()|get_sync_revision|
get_frwhoop_range(date,date)|get_frwhoop_range|from_day date, to_day date
touch_versioned_row()|touch_versioned_row|
engine_put_integration_secret(uuid,text,jsonb)|engine_put_integration_secret|p_user_id uuid, p_provider text, p_tokens jsonb
engine_get_integration_secret(uuid,text)|engine_get_integration_secret|p_user_id uuid, p_provider text
engine_delete_integration_secret(uuid,text)|engine_delete_integration_secret|p_user_id uuid, p_provider text
day_bounds(date,text)|day_bounds|p_day date, p_tz text
local_calendar_date(timestamp with time zone,text)|local_calendar_date|p_at timestamp with time zone, p_tz text
profile_timezone(uuid)|profile_timezone|p_user_id uuid
get_days(date,date)|get_days|p_from date, p_to date
energy_rollup_day(uuid,date)|energy_rollup_day|p_user_id uuid, p_day date
energy_rollup_workout(uuid)|energy_rollup_workout|p_session_id uuid
get_energy_day(date)|get_energy_day|p_day date
get_energy_range(date,date)|get_energy_range|p_from date, p_to date
get_energy_workout(uuid)|get_energy_workout|p_session_id uuid
engine_ingest_energy(text,jsonb)|engine_ingest_energy|p_secret text, p_payload jsonb
engine_replace_sleep_day(text,jsonb)|engine_replace_sleep_day|p_secret text, p_payload jsonb
engine_patch_daily_extras(text,uuid,date,jsonb)|engine_patch_daily_extras|p_secret text, p_user_id uuid, p_day date, p_patch jsonb
engine_resolve_ingest_gaps(text,uuid,jsonb)|engine_resolve_ingest_gaps|p_secret text, p_user_id uuid, p_rows jsonb
sleep_projection_day(text,timestamp with time zone,text)|sleep_projection_day|p_external_id text, p_end timestamp with time zone, p_tz text
daily_metrics_steps_recompute()|daily_metrics_steps_recompute|
healthkit_upsert_external(uuid,jsonb,jsonb,jsonb,jsonb)|healthkit_upsert_external|p_user_id uuid, p_measurements jsonb, p_links jsonb, p_sessions jsonb, p_step_buckets jsonb
merge_apple_watch_step_bucket()|merge_apple_watch_step_bucket|
step_validation_events_are_valid(timestamp with time zone[],integer,timestamp with time zone,timestamp with time zone)|step_validation_events_are_valid|p_events timestamp with time zone[], p_true_count integer, p_start timestamp with time zone, p_end timestamp with time zone
sleep_day_availability(uuid,timestamp with time zone,timestamp with time zone)|sleep_day_availability|p_user uuid, p_start timestamp with time zone, p_end timestamp with time zone
engine_read_day_snapshot(text,uuid,date)|engine_read_day_snapshot|p_secret text, p_user_id uuid, p_day date
hr_series_occupied_buckets(jsonb)|hr_series_occupied_buckets|p_series jsonb
noop_push_save_ack(uuid,uuid,text,jsonb)|noop_push_save_ack|p_user_id uuid, p_batch_id uuid, p_body_sha256 text, p_ack jsonb
noop_push_consume_ingest_quota(uuid,bigint,integer,bigint,integer)|noop_push_consume_ingest_quota|p_user_id uuid, p_bytes bigint, p_max_batches integer, p_max_bytes bigint, p_window_seconds integer
http_post_worker(text)|http_post_worker|fn_path text
engine_ingest_scored_legacy_internal(text,jsonb)|engine_ingest_scored_legacy_internal|p_secret text, p_payload jsonb
server_scoring_for_day(uuid,date)|server_scoring_for_day|p_user uuid, p_day date
scoring_record_timezone()|scoring_record_timezone|
scoring_timezone_at(uuid,timestamp with time zone)|scoring_timezone_at|p_user uuid, p_at timestamp with time zone
scoring_affected_days(uuid,bigint,bigint)|scoring_affected_days|p_user uuid, p_start bigint, p_end bigint
scoring_enqueue_day(uuid,uuid,date,text,integer)|scoring_enqueue_day|p_user uuid, p_device uuid, p_day date, p_timezone text, p_debounce_seconds integer
scoring_dirty_span(uuid,uuid,bigint,bigint)|scoring_dirty_span|p_user uuid, p_device uuid, p_start bigint, p_end bigint
scoring_dirty_projection()|scoring_dirty_projection|
scoring_dirty_sleep_details()|scoring_dirty_sleep_details|
scoring_dirty_context()|scoring_dirty_context|
scoring_dirty_raw_object()|scoring_dirty_raw_object|
scoring_claim_one_core(integer,integer,uuid,uuid,date)|scoring_claim_one_core|p_lease_seconds integer, p_max_failures integer, p_user uuid, p_device uuid, p_day date
scoring_begin_publication(uuid,uuid,date,bigint,uuid,uuid)|scoring_begin_publication|p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid
scoring_renew_lease_core(uuid,uuid,date,bigint,uuid,uuid,integer)|scoring_renew_lease_core|p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid, p_lease_seconds integer
scoring_finish_work_core(uuid,uuid,date,bigint,uuid,uuid,text,integer,text)|scoring_finish_work_core|p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid, p_outcome text, p_duration_ms integer, p_error text
physiology_dirty_override()|physiology_dirty_override|
physiology_write_sleep_override(uuid,uuid,timestamp with time zone,timestamp with time zone,timestamp with time zone,timestamp with time zone,boolean,bigint)|physiology_write_sleep_override|p_id uuid, p_device uuid, p_original_start timestamp with time zone, p_original_end timestamp with time zone, p_start timestamp with time zone, p_end timestamp with time zone, p_tombstone boolean, p_expected_revision bigint
select_physiology_source(text,uuid,text)|select_physiology_source|p_feature text, p_device uuid, p_version text
physiology_processing_metadata(uuid,uuid,date,text,bigint)|physiology_processing_metadata|p_user uuid, p_device uuid, p_day date, p_version text, p_revision bigint
physiology_required_revision(uuid,uuid,date)|physiology_required_revision|p_user uuid, p_device uuid, p_day date
scoring_hrv_contribution(jsonb)|scoring_hrv_contribution|p_payload jsonb
scoring_lock_device(uuid,uuid)|scoring_lock_device|p_user uuid, p_device uuid
scoring_enqueue_dependency(uuid,uuid,date)|scoring_enqueue_dependency|p_user uuid, p_device uuid, p_day date
scoring_dirty_hrv_dependents(uuid,uuid,date,jsonb)|scoring_dirty_hrv_dependents|p_user uuid, p_device uuid, p_source_day date, p_measurements jsonb
scoring_hrv_input_invalidated()|scoring_hrv_input_invalidated|
scoring_capture_measurement_revision()|scoring_capture_measurement_revision|
scoring_hrv_result_changed()|scoring_hrv_result_changed|
scoring_day_segments(uuid,date)|scoring_day_segments|p_user uuid, p_day date
physiology_owned_sleep_overrides(uuid,uuid,date)|physiology_owned_sleep_overrides|p_user uuid, p_device uuid, p_day date
scoring_dirty_wear_state()|scoring_dirty_wear_state|
physiology_legacy_sleep_boundaries(uuid,uuid)|physiology_legacy_sleep_boundaries|p_user uuid, p_device uuid
set_physiology_sleep_override(uuid,uuid,timestamp with time zone,timestamp with time zone,timestamp with time zone,timestamp with time zone,boolean,bigint)|set_physiology_sleep_override|p_id uuid, p_device uuid, p_original_start timestamp with time zone, p_original_end timestamp with time zone, p_start timestamp with time zone, p_end timestamp with time zone, p_tombstone boolean, p_expected_revision bigint
continue_legacy_physiology_sleep_override(uuid,uuid,timestamp with time zone,timestamp with time zone,timestamp with time zone,timestamp with time zone,boolean,bigint,text)|continue_legacy_physiology_sleep_override|p_id uuid, p_device uuid, p_original_start timestamp with time zone, p_original_end timestamp with time zone, p_start timestamp with time zone, p_end timestamp with time zone, p_tombstone boolean, p_expected_revision bigint, p_legacy_revision text
scoring_legacy_snapshot(uuid,uuid,date)|scoring_legacy_snapshot|p_user uuid, p_device uuid, p_day date
scoring_legacy_queue_transition()|scoring_legacy_queue_transition|
scoring_enqueue_legacy(uuid,uuid,date,text)|scoring_enqueue_legacy|p_user uuid, p_device uuid, p_day date, p_timezone text
physiology_enqueue_day(uuid,uuid,date,text,integer)|physiology_enqueue_day|p_user uuid, p_device uuid, p_day date, p_timezone text, p_debounce_seconds integer
preserve_device_owner()|preserve_device_owner|
register_noop_device(uuid,uuid,text,timestamp with time zone)|register_noop_device|p_device uuid, p_user uuid, p_external_device_id text, p_last_seen_at timestamp with time zone
scoring_legacy_write_guard()|scoring_legacy_write_guard|
scoring_enqueue_legacy_fenced(uuid,uuid,date,text,integer)|scoring_enqueue_legacy_fenced|p_user uuid, p_device uuid, p_day date, p_timezone text, p_debounce_seconds integer
scoring_legacy_begin_publication(uuid,uuid,date,bigint,uuid,uuid)|scoring_legacy_begin_publication|p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid
scoring_legacy_claim_one(integer,integer,uuid,uuid,date)|scoring_legacy_claim_one|p_lease_seconds integer, p_max_failures integer, p_user uuid, p_device uuid, p_day date
scoring_legacy_renew_lease(uuid,uuid,date,bigint,uuid,uuid,integer)|scoring_legacy_renew_lease|p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid, p_lease_seconds integer
scoring_legacy_finish_work(uuid,uuid,date,bigint,uuid,uuid,text,integer,text)|scoring_legacy_finish_work|p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid, p_outcome text, p_duration_ms integer, p_error text
get_owner_day_snapshot(uuid,date)|get_owner_day_snapshot|p_user uuid, p_day date
preserve_standard_hr_receipt()|preserve_standard_hr_receipt|
validate_heart_rate_window_ownership()|validate_heart_rate_window_ownership|
scoring_acquire_input_gate(uuid,uuid)|scoring_acquire_input_gate|p_user uuid, p_device uuid
redeem_noop_enrollment(text,uuid,text,text,text,integer)|redeem_noop_enrollment|p_code_hash text, p_source_id uuid, p_platform text, p_app_version text, p_token_hash text, p_retry_window_seconds integer
server_scoring_for_device_day(uuid,date,uuid)|server_scoring_for_device_day|p_user uuid, p_day date, p_device uuid
enrolled_physiology_sleep_override(uuid,uuid,uuid,timestamp with time zone,timestamp with time zone,timestamp with time zone,timestamp with time zone,boolean,bigint,text)|enrolled_physiology_sleep_override|p_user uuid, p_device uuid, p_id uuid, p_original_start timestamp with time zone, p_original_end timestamp with time zone, p_start timestamp with time zone, p_end timestamp with time zone, p_tombstone boolean, p_expected_revision bigint, p_legacy_revision text
noop_project_append_batch_core(uuid,uuid,uuid,uuid,text,jsonb)|noop_project_append_batch_core|p_user uuid, p_device uuid, p_source uuid, p_batch uuid, p_stream text, p_rows jsonb
scoring_composite_contribution(jsonb)|scoring_composite_contribution|p_payload jsonb
scoring_dirty_composite_dependents(uuid,uuid,date)|scoring_dirty_composite_dependents|p_user uuid, p_device uuid, p_source_day date
scoring_composite_input_invalidated()|scoring_composite_input_invalidated|
scoring_composite_result_changed()|scoring_composite_result_changed|
scoring_composite_qualification_changed()|scoring_composite_qualification_changed|
noop_keep_device_owner()|noop_keep_device_owner|
noop_register_push_device(uuid,uuid,text)|noop_register_push_device|p_user_id uuid, p_device_id uuid, p_external_device_id text
noop_reserve_push_batch(uuid,uuid,uuid,text,jsonb)|noop_reserve_push_batch|p_user_id uuid, p_batch_id uuid, p_device_id uuid, p_body_sha256 text, p_entry jsonb
noop_reserve_object_manifest_lifecycle_core(jsonb)|noop_reserve_object_manifest_lifecycle_core|p_manifest jsonb
noop_commit_object_receipt(uuid,uuid,text,text,text,bigint,bigint)|noop_commit_object_receipt|p_user_id uuid, p_object_id uuid, p_verified_key text, p_wire_sha256 text, p_content_sha256 text, p_compressed_bytes bigint, p_uncompressed_bytes bigint
noop_intake_reconcile_page(integer)|noop_intake_reconcile_page|p_limit integer
enqueue_scoring_v2(uuid,uuid,date,text,text)|enqueue_scoring_v2|p_user uuid, p_device uuid, p_day date, p_version text, p_reason text
renew_scoring_v2(uuid,integer)|renew_scoring_v2|p_token uuid, p_seconds integer
fail_scoring_v2(uuid,bigint,text)|fail_scoring_v2|p_token uuid, p_revision bigint, p_error text
selected_scoring_device_v2(uuid,date,text)|selected_scoring_device_v2|p_user uuid, p_day date, p_version text
refresh_scoring_legacy_v2(uuid,date,text)|refresh_scoring_legacy_v2|p_user uuid, p_day date, p_version text
publish_scoring_snapshot_v2(uuid,bigint,jsonb,bigint)|publish_scoring_snapshot_v2|p_token uuid, p_revision bigint, p_payload jsonb, p_duration_ms bigint
reject_snapshot_update_v2()|reject_snapshot_update_v2|
claim_scoring_archive_v2(integer)|claim_scoring_archive_v2|p_seconds integer
renew_scoring_archive_v2(uuid,integer)|renew_scoring_archive_v2|p_token uuid, p_seconds integer
fail_scoring_archive_v2(uuid,text)|fail_scoring_archive_v2|p_token uuid, p_error text
complete_scoring_archive_v2(uuid,text,bigint,text,integer)|complete_scoring_archive_v2|p_token uuid, p_sha text, p_bytes bigint, p_bucket text, p_retention_days integer
retry_scoring_archive_v2(bigint)|retry_scoring_archive_v2|p_revision bigint
register_scoring_algorithm_v2(text)|register_scoring_algorithm_v2|p_version text
expand_scoring_invalidations_v2(integer)|expand_scoring_invalidations_v2|p_limit integer
repair_legacy_scoring_v2(integer)|repair_legacy_scoring_v2|p_limit integer
scoring_local_day_v2(text,text)|scoring_local_day_v2|p_time text, p_zone text
reconcile_scoring_days_v2(uuid,uuid,date,date,integer)|reconcile_scoring_days_v2|p_user uuid, p_device uuid, p_from date, p_through date, p_limit integer
invalidate_scoring_stream_v2()|invalidate_scoring_stream_v2|
invalidate_scoring_profile_v2()|invalidate_scoring_profile_v2|
invalidate_scoring_history_v2(uuid,uuid,date,date,text)|invalidate_scoring_history_v2|p_user uuid, p_device uuid, p_from date, p_through date, p_reason text
set_scoring_source_v2(uuid,uuid)|set_scoring_source_v2|p_user uuid, p_device uuid
invalidate_scoring_device_v2()|invalidate_scoring_device_v2|
engine_ingest_scored(text,jsonb)|engine_ingest_scored|p_secret text, p_payload jsonb
reconcile_scoring_versions_v2(integer)|reconcile_scoring_versions_v2|p_limit integer
noop_projection_coordinate(text,jsonb)|noop_projection_coordinate|p_stream text, p_row jsonb
noop_projection_archive_debt()|noop_projection_archive_debt|
noop_seed_projection_debt(integer)|noop_seed_projection_debt|p_limit integer
noop_claim_projection_debt()|noop_claim_projection_debt|
noop_fail_projection_debt(uuid,uuid)|noop_fail_projection_debt|p_object_id uuid, p_token uuid
noop_apply_projection_rows_intake_legacy(text,jsonb)|noop_apply_projection_rows_intake_legacy|p_stream text, p_rows jsonb
noop_commit_push_projection_intake_core(uuid,text,jsonb,jsonb,jsonb,uuid)|noop_commit_push_projection_intake_core|p_object_id uuid, p_body_sha256 text, p_header jsonb, p_rows jsonb, p_keep_keys jsonb, p_token uuid
noop_step_activity_compat()|noop_step_activity_compat|
scoring_timestamp_v3(text)|scoring_timestamp_v3|p_time text
invalidate_scoring_history_stream_v3()|invalidate_scoring_history_stream_v3|
mark_scoring_history_dirty_v3()|mark_scoring_history_dirty_v3|
register_scoring_history_v3(text)|register_scoring_history_v3|p_version text
expand_scoring_history_v3(integer)|expand_scoring_history_v3|p_limit integer
claim_scoring_history_v3(text,integer)|claim_scoring_history_v3|p_version text, p_lease_seconds integer
publish_scoring_history_v3(uuid,bigint,bigint,bigint,jsonb,jsonb,bigint,bigint,bigint)|publish_scoring_history_v3|p_token uuid, p_revision bigint, p_generation bigint, p_predecessor bigint, p_payload jsonb, p_state jsonb, p_profile_revision bigint, p_configuration_revision bigint, p_duration_ms bigint
check_scoring_history_publication_v3()|check_scoring_history_publication_v3|
validate_scoring_history_input_v3(text,jsonb,boolean)|validate_scoring_history_input_v3|p_kind text, p_payload jsonb, p_deleted boolean
put_scoring_history_input_v3(uuid,text,text,date,jsonb,bigint,boolean,uuid,uuid,bigint)|put_scoring_history_input_v3|p_device uuid, p_kind text, p_entity text, p_effective_day date, p_payload jsonb, p_expected_revision bigint, p_deleted boolean, p_client_id uuid, p_client_mutation_id uuid, p_client_revision bigint
get_scoring_history_input_head_v3(uuid,text,text)|get_scoring_history_input_head_v3|p_device uuid, p_kind text, p_entity text
get_scoring_history_input_v3(uuid,text,text,date)|get_scoring_history_input_v3|p_device uuid, p_kind text, p_entity text, p_as_of_day date
get_server_score_snapshot_v2(date,text)|get_server_score_snapshot_v2|p_day date, p_algorithm_version text
claim_scoring_v2(text,integer)|claim_scoring_v2|p_version text, p_lease_seconds integer
noop_scalar_measurement_immutable()|noop_scalar_measurement_immutable|
noop_valid_scalar_provenance(jsonb)|noop_valid_scalar_provenance|p jsonb
noop_aux_receipt_requires_validation()|noop_aux_receipt_requires_validation|
noop_aux_window_coverage_unknown()|noop_aux_window_coverage_unknown|
noop_commit_aux_object_receipt(uuid,uuid,text,text,text,bigint,bigint,jsonb)|noop_commit_aux_object_receipt|p_user_id uuid, p_object_id uuid, p_verified_key text, p_wire_sha256 text, p_content_sha256 text, p_compressed_bytes bigint, p_uncompressed_bytes bigint, p_validation jsonb
physiology_feature_is_canonical(text,text)|physiology_feature_is_canonical|p_version text, p_feature text
register_physiology_promotion(text,text)|register_physiology_promotion|p_payload text, p_signature text
physiology_activate_model(text,text)|physiology_activate_model|p_payload text, p_checkpoint text
physiology_claim_model_core(text,text,integer)|physiology_claim_model_core|p_model text, p_activation_hash text, p_lease_seconds integer
physiology_renew_model(uuid,uuid,integer)|physiology_renew_model|p_job uuid, p_token uuid, p_seconds integer
physiology_finish_model(uuid,uuid,jsonb,text)|physiology_finish_model|p_job uuid, p_token uuid, p_output jsonb, p_failure text
physiology_cancel_model(text,bigint)|physiology_cancel_model|p_model text, p_activation bigint
physiology_shadow_model_for_day(text,date,uuid)|physiology_shadow_model_for_day|p_model text, p_day date, p_device uuid
server_scoring_read_contract_before_signals(uuid,date,uuid)|server_scoring_read_contract_before_signals|p_user uuid, p_day date, p_device uuid
server_pipeline_diagnostics(uuid,uuid,uuid,date)|server_pipeline_diagnostics|p_user uuid, p_source uuid, p_device uuid, p_day date
engine_publish_legacy_fenced(text,jsonb)|engine_publish_legacy_fenced|p_secret text, p_payload jsonb
engine_publish_physiology(text,jsonb)|engine_publish_physiology|p_secret text, p_payload jsonb
noop_installation_immutable()|noop_installation_immutable|
retire_noop_installation(text)|retire_noop_installation|p_token_hash text
noop_require_active_source()|noop_require_active_source|
noop_reserve_object_manifest_representation_core(jsonb)|noop_reserve_object_manifest_representation_core|p_manifest jsonb
authorize_noop_object_put(uuid,uuid,uuid)|authorize_noop_object_put|p_user uuid, p_source uuid, p_object uuid
noop_projection_target(text)|noop_projection_target|p_stream text
noop_same_rr_payload(text,text,text)|noop_same_rr_payload|p_left text, p_right text, p_packet text
noop_project_append_batch(uuid,uuid,uuid,uuid,text,jsonb)|noop_project_append_batch|p_user uuid, p_device uuid, p_source uuid, p_batch uuid, p_stream text, p_rows jsonb
confirm_noop_wearable(uuid,uuid,uuid,uuid,jsonb)|confirm_noop_wearable|p_user uuid, p_source uuid, p_provisional uuid, p_canonical uuid, p_evidence jsonb
noop_alias_raw_dependency()|noop_alias_raw_dependency|
handoff_noop_collection(uuid,uuid,uuid,uuid,integer)|handoff_noop_collection|p_user uuid, p_device uuid, p_source uuid, p_expected uuid, p_seconds integer
scoring_work_class(date,text)|scoring_work_class|p_day date, p_timezone text
scoring_claim_one(integer,integer,uuid,uuid,date)|scoring_claim_one|p_lease_seconds integer, p_max_failures integer, p_user uuid, p_device uuid, p_day date
scoring_renew_lease(uuid,uuid,date,bigint,uuid,uuid,integer)|scoring_renew_lease|p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid, p_lease_seconds integer
scoring_finish_work(uuid,uuid,date,bigint,uuid,uuid,text,integer,text)|scoring_finish_work|p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid, p_outcome text, p_duration_ms integer, p_error text
begin_noop_account_deletion(uuid)|begin_noop_account_deletion|p_user uuid
noop_account_retirement_admission()|noop_account_retirement_admission|
delete_noop_integration_credentials(uuid)|delete_noop_integration_credentials|p_user uuid
admit_noop_request(uuid,uuid)|admit_noop_request|p_user uuid, p_source uuid
prune_multiuser_operational_records()|prune_multiuser_operational_records|
physiology_claim_model(text,text,integer)|physiology_claim_model|p_model text, p_activation_hash text, p_lease_seconds integer
server_scoring_read_contract_v1(uuid,date,uuid)|server_scoring_read_contract_v1|p_user uuid, p_day date, p_device uuid
sensor_enqueue_closed_windows(timestamp with time zone,integer)|sensor_enqueue_closed_windows|p_now timestamp with time zone, p_limit integer
publish_compute_dispositions(uuid,uuid,date,bigint)|publish_compute_dispositions|p_user uuid, p_device uuid, p_day date, p_revision bigint
process_compute_disposition()|process_compute_disposition|
server_scoring_read_contract_before_families(uuid,date,uuid)|server_scoring_read_contract_before_families|p_user uuid, p_day date, p_device uuid
server_scoring_pending_contract(uuid,date)|server_scoring_pending_contract|p_user uuid, p_day date
register_account_compute_source(uuid,uuid)|register_account_compute_source|p_user uuid, p_source uuid
submit_compute_session_request(uuid,uuid,uuid,jsonb)|submit_compute_session_request|p_user uuid, p_device uuid, p_source uuid, p_request jsonb
read_compute_session_result_before_numerical(uuid,uuid,uuid,uuid)|read_compute_session_result_before_numerical|p_user uuid, p_device uuid, p_source uuid, p_request uuid
process_compute_session_request()|process_compute_session_request|
noop_copy_parent_detached()|noop_copy_parent_detached|
noop_reserve_copy_intent_unfenced(uuid,uuid)|noop_reserve_copy_intent_unfenced|p_user_id uuid, p_object_id uuid
noop_commit_copy_receipt(uuid,uuid,text,text,bigint,bigint,integer,jsonb)|noop_commit_copy_receipt|p_intent_id uuid, p_lease_token uuid, p_wire_sha256 text, p_content_sha256 text, p_compressed_bytes bigint, p_uncompressed_bytes bigint, p_verification_ms integer, p_validation jsonb
noop_abandon_copy_intent(uuid,uuid,text)|noop_abandon_copy_intent|p_intent_id uuid, p_lease_token uuid, p_failure_code text
noop_claim_copy_orphans(integer,bigint)|noop_claim_copy_orphans|p_limit integer, p_max_bytes bigint
noop_finish_copy_sweep(uuid,uuid,boolean)|noop_finish_copy_sweep|p_intent_id uuid, p_sweep_token uuid, p_succeeded boolean
noop_reserve_copy_intent(uuid,uuid,uuid)|noop_reserve_copy_intent|p_user_id uuid, p_object_id uuid, p_verification_token uuid
noop_object_receipt_matches_manifest(object_manifests)|noop_object_receipt_matches_manifest|m object_manifests
noop_current_object_receipt(uuid,uuid)|noop_current_object_receipt|p_user_id uuid, p_object_id uuid
noop_enqueue_object_verification(uuid,uuid)|noop_enqueue_object_verification|p_user_id uuid, p_object_id uuid
noop_claim_object_verification(bigint,bigint)|noop_claim_object_verification|p_max_bytes bigint, p_max_decoded_bytes bigint
noop_finish_object_verification(uuid,uuid,text,integer,boolean,integer)|noop_finish_object_verification|p_object_id uuid, p_lease_token uuid, p_failure_code text, p_failure_status integer, p_retryable boolean, p_verification_ms integer
noop_defer_object_verification(uuid,uuid)|noop_defer_object_verification|p_object_id uuid, p_lease_token uuid
noop_retry_object_verification(uuid,uuid)|noop_retry_object_verification|p_user_id uuid, p_object_id uuid
noop_apply_projection_rows(text,jsonb)|noop_apply_projection_rows|p_stream text, p_rows jsonb
noop_commit_push_projection(uuid,text,jsonb,jsonb,jsonb,uuid)|noop_commit_push_projection|p_object_id uuid, p_body_sha256 text, p_header jsonb, p_rows jsonb, p_keep_keys jsonb, p_token uuid
noop_intake_consumer_poll(uuid,uuid,text,text,integer,integer,integer)|noop_intake_consumer_poll|p_process uuid, p_instance uuid, p_source_revision text, p_lane text, p_claimed integer, p_completed integer, p_failures integer
noop_intake_consumer_contract()|noop_intake_consumer_contract|
noop_async_verification_ready()|noop_async_verification_ready|
noop_verification_owner_enqueued()|noop_verification_owner_enqueued|
noop_projection_owner_enqueued()|noop_projection_owner_enqueued|
noop_intake_status()|noop_intake_status|
noop_intake_canary_validate(uuid,uuid)|noop_intake_canary_validate|p_user uuid, p_device uuid
noop_intake_reconcile_page_scoped(uuid,uuid,integer)|noop_intake_reconcile_page_scoped|p_user_id uuid, p_device_id uuid, p_limit integer
noop_seed_projection_debt_scoped(uuid,uuid,integer)|noop_seed_projection_debt_scoped|p_user_id uuid, p_device_id uuid, p_limit integer
noop_claim_object_verification_scoped(uuid,uuid,bigint,bigint)|noop_claim_object_verification_scoped|p_user_id uuid, p_device_id uuid, p_max_bytes bigint, p_max_decoded_bytes bigint
noop_claim_projection_debt_scoped(uuid,uuid)|noop_claim_projection_debt_scoped|p_user_id uuid, p_device_id uuid
scoring_canary_claim_one(integer,integer,uuid,uuid,date)|scoring_canary_claim_one|p_lease_seconds integer, p_max_failures integer, p_user uuid, p_device uuid, p_day date
scoring_canary_enqueue_legacy(uuid,uuid,date,text,integer)|scoring_canary_enqueue_legacy|p_user uuid, p_device uuid, p_day date, p_timezone text, p_debounce_seconds integer
noop_intake_canary_commit_receipt(uuid,uuid,uuid,uuid,uuid,text,text,text,bigint,bigint,integer,jsonb)|noop_intake_canary_commit_receipt|p_user uuid, p_device uuid, p_object uuid, p_intent uuid, p_lease uuid, p_verified_key text, p_wire_sha256 text, p_content_sha256 text, p_compressed_bytes bigint, p_uncompressed_bytes bigint, p_verification_ms integer, p_validation jsonb
noop_intake_canary_commit_projection(uuid,uuid,uuid,text,jsonb,jsonb,jsonb,uuid)|noop_intake_canary_commit_projection|p_user uuid, p_device uuid, p_object_id uuid, p_body_sha256 text, p_header jsonb, p_rows jsonb, p_keep_keys jsonb, p_token uuid
engine_publish_canary_legacy_fenced(text,jsonb,uuid,uuid)|engine_publish_canary_legacy_fenced|p_secret text, p_payload jsonb, p_user uuid, p_device uuid
noop_intake_consumer_poll_v2(uuid,uuid,text,text,integer,integer,integer,text,uuid,uuid)|noop_intake_consumer_poll_v2|p_process uuid, p_instance uuid, p_source_revision text, p_lane text, p_claimed integer, p_completed integer, p_failures integer, p_admission_mode text, p_user_id uuid, p_device_id uuid
noop_intake_canary_status(uuid,uuid,text,uuid)|noop_intake_canary_status|p_user uuid, p_device uuid, p_source_revision text, p_instance uuid
server_legacy_read_eligibility(jsonb)|server_legacy_read_eligibility|p_payload jsonb
scoring_legacy_seal_snapshot(uuid,uuid,date,bigint,uuid,uuid)|scoring_legacy_seal_snapshot|p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid
scoring_legacy_minimum_readable_revision(uuid,uuid,date)|scoring_legacy_minimum_readable_revision|p_user uuid, p_device uuid, p_day date
touch_server_result_day()|touch_server_result_day|
server_result_days_page(uuid,uuid,uuid,bigint,integer,text)|server_result_days_page|p_user uuid, p_device uuid, p_source uuid, p_after bigint, p_limit integer, p_scope_revision text
noop_history_inventory_page(uuid,uuid,uuid,integer,timestamp with time zone)|noop_history_inventory_page|p_user uuid, p_device uuid, p_after uuid, p_limit integer, p_before timestamp with time zone
noop_history_requeue_object(uuid,uuid,uuid,uuid)|noop_history_requeue_object|p_user uuid, p_device uuid, p_object uuid, p_receipt uuid
server_scoring_read_contract(uuid,date,uuid)|server_scoring_read_contract|p_user uuid, p_day date, p_device uuid
compute_session_journal_consent(uuid,uuid)|compute_session_journal_consent|p_user uuid, p_device uuid
compute_session_source_fingerprint(uuid)|compute_session_source_fingerprint|p_request uuid
publish_compute_session_candidate(uuid,date,bigint,text,jsonb)|publish_compute_session_candidate|p_request uuid, p_day date, p_revision bigint, p_fingerprint text, p_candidate jsonb
read_compute_session_result(uuid,uuid,uuid,uuid)|read_compute_session_result|p_user uuid, p_device uuid, p_source uuid, p_request uuid
noop_object_logical_identity(object_manifests)|noop_object_logical_identity|p object_manifests
noop_reserve_object_manifest(jsonb)|noop_reserve_object_manifest|p_manifest jsonb
noop_require_object_batch_identity()|noop_require_object_batch_identity|
compute_historical_configuration(uuid,uuid)|compute_historical_configuration|p_user uuid, p_device uuid
noop_recovery_validate(uuid,boolean)|noop_recovery_validate|p_run uuid, p_require_observer boolean
recovery_target_identity(uuid,uuid,uuid)|recovery_target_identity|p_run uuid, p_user uuid, p_device uuid
noop_recovery_supervise(uuid,uuid,text,jsonb,timestamp with time zone)|noop_recovery_supervise|p_run uuid, p_supervisor uuid, p_policy_hash text, p_observation jsonb, p_renew_until timestamp with time zone
noop_recovery_confirm_stopped(uuid,uuid,uuid,text)|noop_recovery_confirm_stopped|p_run uuid, p_supervisor uuid, p_instance uuid, p_container text
noop_recovery_assert_attempt(uuid,uuid,uuid)|noop_recovery_assert_attempt|p_run uuid, p_process uuid, p_token uuid
noop_recovery_has_turn(uuid,text)|noop_recovery_has_turn|p_run uuid, p_lane text
noop_recovery_claim(uuid,uuid,uuid,text,text,text)|noop_recovery_claim|p_run uuid, p_process uuid, p_instance uuid, p_source_revision text, p_image_digest text, p_lane text
noop_recovery_inventory_page(uuid,integer)|noop_recovery_inventory_page|p_run uuid, p_limit integer
noop_recovery_release(uuid,uuid,uuid,boolean,text,boolean)|noop_recovery_release|p_run uuid, p_process uuid, p_token uuid, p_success boolean, p_reason text, p_retryable boolean
noop_recovery_intake_call(uuid,uuid,uuid,text,jsonb)|noop_recovery_intake_call|p_run uuid, p_process uuid, p_token uuid, p_operation text, p_args jsonb
noop_recovery_poll(uuid,text,integer,integer)|noop_recovery_poll|p_run uuid, p_lane text, p_completed integer, p_failures integer
noop_recovery_status(uuid)|noop_recovery_status|p_run uuid
scoring_recovery_claim_one(uuid,uuid,uuid,text,text,integer,integer,uuid,uuid,date)|scoring_recovery_claim_one|p_recovery_run uuid, p_process uuid, p_instance uuid, p_source_revision text, p_image_digest text, p_lease_seconds integer, p_max_failures integer, p_user uuid, p_device uuid, p_day date
engine_publish_recovery_legacy_fenced(text,jsonb,uuid,uuid,uuid,uuid)|engine_publish_recovery_legacy_fenced|p_secret text, p_payload jsonb, p_user uuid, p_device uuid, p_recovery_run uuid, p_process uuid
scoring_recovery_finish_work(uuid,uuid,date,bigint,uuid,uuid,text,integer,text,uuid,uuid)|scoring_recovery_finish_work|p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid, p_outcome text, p_duration_ms integer, p_error text, p_recovery_run uuid, p_process uuid
scoring_recovery_renew_lease(uuid,uuid,date,bigint,uuid,uuid,integer,uuid,uuid)|scoring_recovery_renew_lease|p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid, p_lease_seconds integer, p_recovery_run uuid, p_process uuid
get_server_score_snapshot_v2(date,uuid,text)|get_server_score_snapshot_v2|p_day date, p_source uuid, p_external_device_id text
noop_recovery_archive_bind(uuid,uuid,uuid,uuid,text,text,text)|noop_recovery_archive_bind|p_run uuid, p_supervisor uuid, p_instance uuid, p_process uuid, p_source_revision text, p_image_digest text, p_container text
noop_recovery_archive_supervise(uuid,uuid,uuid,uuid,text,text,text,jsonb)|noop_recovery_archive_supervise|p_run uuid, p_supervisor uuid, p_instance uuid, p_process uuid, p_source_revision text, p_image_digest text, p_container text, p_observation jsonb
noop_recovery_archive_validate(uuid,uuid)|noop_recovery_archive_validate|p_run uuid, p_process uuid
noop_recovery_archive_claim(uuid,uuid,uuid,text,text)|noop_recovery_archive_claim|p_run uuid, p_process uuid, p_instance uuid, p_source_revision text, p_image_digest text
noop_recovery_archive_assert(uuid,uuid,uuid)|noop_recovery_archive_assert|p_run uuid, p_process uuid, p_token uuid
noop_recovery_archive_finish(uuid,uuid,uuid,text)|noop_recovery_archive_finish|p_run uuid, p_process uuid, p_token uuid, p_compressed_sha256 text
noop_recovery_archive_confirm_stopped(uuid,uuid,uuid,text)|noop_recovery_archive_confirm_stopped|p_run uuid, p_supervisor uuid, p_instance uuid, p_container text
noop_recovery_archive_status(uuid)|noop_recovery_archive_status|p_run uuid

```
