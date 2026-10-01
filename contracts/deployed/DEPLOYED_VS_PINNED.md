# Deployed vs pinned (Whoop-Nara) RPC contract diff

- Pinned upstream HEAD verified: `9abbcf22fa5ea34febc548b835cdd60454991609`
- Pinned migrations dir: `Whoop-Nara/supabase/migrations/` (147 files)
- Deployed source: live FRWHOOP Postgres (READ-ONLY), `pg_get_functiondef` per function
- Diff generated UTC: 2026-09-30T08:23:42.480175
- Verdict rule: compare deployed vs the LATEST pinned definition by migration filename (timestamp prefix) wins; multiple definitions are resolved to the latest and flagged.

## Normalization

`pg_get_functiondef` reformats the header vs the migration source. The comparison normalizes both sides with `normalize_diff.py` (reproducible; see that file). It removes:

- whitespace runs, trailing spaces, `--` and `/* */` comments (bodies)
- header canonicalization: keyword case, `OR REPLACE`, `NULL::<type>` -> `null`, type spellings (`timestamptz`/`float8`/`varchar`), comma/paren spacing, `SET search_path TO` vs `=`, quotes, and the implicit default `SECURITY INVOKER` that `pg_get_functiondef` never prints

After normalization the texts must match exactly for the verdict `IDENTICAL`. The two `_core` functions are created in the pinned migrations by `rename`, so their deployed name differs from the renamed source name by design; the pinned body is the renamed original and the comparison substitutes the deployed name.

## Verdict table

| RPC | deployed identity args | pinned migration file:line | verdict | note |
|---|---|---|---|---|
| `noop_commit_push_projection` | `p_object_id uuid, p_body_sha256 text, p_header jsonb, p_rows jsonb, p_keep_keys jsonb, p_token uuid` | `20260922120000_intake_service_contract.sql:241` | IDENTICAL | 2 pinned defs; latest by filename wins |
| `noop_commit_push_projection_intake_core` | `p_object_id uuid, p_body_sha256 text, p_header jsonb, p_rows jsonb, p_keep_keys jsonb, p_token uuid` | `20260918040000_production_projection_debt.sql:153` | IDENTICAL | renamed from noop_commit_push_projection (only pre-rename def) at 20260922120000_intake_service_contract.sql:237 (rename-created; deployed name differs by design) |
| `noop_apply_projection_rows` | `p_stream text, p_rows jsonb` | `20260922120000_intake_service_contract.sql:213` | IDENTICAL | 3 pinned defs; latest by filename wins |
| `noop_project_append_batch` | `p_user uuid, p_device uuid, p_source uuid, p_batch uuid, p_stream text, p_rows jsonb` | `20260928011000_append_projection_qualified_row.sql:6` | IDENTICAL | 8 pinned defs; latest by filename wins |
| `noop_project_append_batch_core` | `p_user uuid, p_device uuid, p_source uuid, p_batch uuid, p_stream text, p_rows jsonb` | `20260921070000_production_append_stream_compatibility.sql:130` | IDENTICAL | renamed from noop_project_append_batch (latest pre-rename def) at 20260921111000_wearable_lifecycle.sql:89 (rename-created; deployed name differs by design) |
| `noop_projection_target` | `p_stream text` | `20260921111000_wearable_lifecycle.sql:70` | IDENTICAL | single pinned definition |
| `noop_projection_coordinate` | `p_stream text, p_row jsonb` | `20260918040000_production_projection_debt.sql:43` | IDENTICAL | single pinned definition |
| `noop_claim_projection_debt` | `` | `20260922120000_intake_service_contract.sql:412` | IDENTICAL | 2 pinned defs; latest by filename wins |
| `noop_fail_projection_debt` | `p_object_id uuid, p_token uuid` | `20260918040000_production_projection_debt.sql:106` | IDENTICAL | single pinned definition |
| `noop_commit_object_receipt` | `p_user_id uuid, p_object_id uuid, p_verified_key text, p_wire_sha256 text, p_content_sha256 text, p_compressed_bytes bigint, p_uncompressed_bytes bigint` | `20260922120000_intake_service_contract.sql:8` | IDENTICAL | 2 pinned defs; latest by filename wins |
| `noop_claim_object_verification` | `p_max_bytes bigint, p_max_decoded_bytes bigint` | `20260922120000_intake_service_contract.sql:356` | IDENTICAL | 2 pinned defs; latest by filename wins |
| `noop_finish_object_verification` | `p_object_id uuid, p_lease_token uuid, p_failure_code text, p_failure_status integer, p_retryable boolean, p_verification_ms integer` | `20260922020000_async_object_verification.sql:174` | IDENTICAL | single pinned definition |
| `noop_reserve_object_manifest` | `p_manifest jsonb` | `20260923180000_object_representation_identity.sql:39` | IDENTICAL | 3 pinned defs; latest by filename wins |
| `noop_reserve_push_batch` | `p_user_id uuid, p_batch_id uuid, p_device_id uuid, p_body_sha256 text, p_entry jsonb` | `20260921060000_production_intake_durability.sql:78` | IDENTICAL | single pinned definition |
| `noop_push_save_ack` | `p_user_id uuid, p_batch_id uuid, p_body_sha256 text, p_ack jsonb` | `20260921060000_production_intake_durability.sql:251` | IDENTICAL | 2 pinned defs; latest by filename wins |
| `noop_register_push_device` | `p_user_id uuid, p_device_id uuid, p_external_device_id text` | `20260921060000_production_intake_durability.sql:49` | IDENTICAL | single pinned definition |
| `scoring_claim_one` | `p_lease_seconds integer, p_max_failures integer, p_user uuid, p_device uuid, p_day date` | `20260921112000_fleet_scheduler.sql:79` | IDENTICAL | 3 pinned defs; latest by filename wins |
| `scoring_finish_work` | `p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid, p_outcome text, p_duration_ms integer, p_error text` | `20260921112000_fleet_scheduler.sql:120` | IDENTICAL | 5 pinned defs; latest by filename wins |
| `engine_publish_legacy_fenced` | `p_secret text, p_payload jsonb` | `20260921103000_server_publication_conflict_transport.sql:14` | IDENTICAL | 3 pinned defs; latest by filename wins |
| `claim_scoring_v2` | `p_version text, p_lease_seconds integer` | `20260918050000_production_scoring_history.sql:764` | IDENTICAL | 2 pinned defs; latest by filename wins |
| `publish_scoring_snapshot_v2` | `p_token uuid, p_revision bigint, p_payload jsonb, p_duration_ms bigint` | `20260918010000_production_scoring_durability.sql:228` | IDENTICAL | single pinned definition |
| `claim_scoring_archive_v2` | `p_seconds integer` | `20260918010000_production_scoring_durability.sql:310` | IDENTICAL | single pinned definition |
| `complete_scoring_archive_v2` | `p_token uuid, p_sha text, p_bytes bigint, p_bucket text, p_retention_days integer` | `20260918010000_production_scoring_durability.sql:348` | IDENTICAL | single pinned definition |
| `renew_scoring_archive_v2` | `p_token uuid, p_seconds integer` | `20260918010000_production_scoring_durability.sql:328` | IDENTICAL | single pinned definition |
| `fail_scoring_archive_v2` | `p_token uuid, p_error text` | `20260918010000_production_scoring_durability.sql:337` | IDENTICAL | single pinned definition |
| `engine_ingest_scored` | `p_secret text, p_payload jsonb` | `20260927020000_restore_fenced_baseline_serializer.sql:163` | IDENTICAL | 4 pinned defs; latest by filename wins |
| `server_scoring_for_day` | `p_user uuid, p_day date` | `20260921121000_final_hosted_compute_contract.sql:260` | IDENTICAL | 9 pinned defs; latest by filename wins |
| `scoring_legacy_claim_one` | `p_lease_seconds integer, p_max_failures integer, p_user uuid, p_device uuid, p_day date` | `20260923140000_legacy_snapshot_progress.sql:96` | IDENTICAL | 2 pinned defs; latest by filename wins |
| `scoring_legacy_seal_snapshot` | `p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid` | `20260923140000_legacy_snapshot_progress.sql:133` | IDENTICAL | single pinned definition |
| `scoring_legacy_finish_work` | `p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid, p_outcome text, p_duration_ms integer, p_error text` | `20260923140000_legacy_snapshot_progress.sql:174` | IDENTICAL | 2 pinned defs; latest by filename wins |

## Behavioural divergences

None found. All 30 RPCs are behaviourally identical to the latest pinned definition after normalization. The only textual differences between deployed `pg_get_functiondef` output and the migration source are the header canonicalizations listed above (formatting only) and, for the two rename-created `_core` functions, the function name.

## Multiple pinned definitions (latest by filename wins)

| RPC | definitions (file:line) | latest chosen |
|---|---|---|
| `noop_commit_push_projection` | 20260918040000_production_projection_debt.sql:153, 20260922120000_intake_service_contract.sql:241 | 20260922120000_intake_service_contract.sql:241 |
| `noop_apply_projection_rows` | 20260918040000_production_projection_debt.sql:117, 20260918060000_production_scalar_projections.sql:3, 20260922120000_intake_service_contract.sql:213 | 20260922120000_intake_service_contract.sql:213 |
| `noop_project_append_batch` | 20260920220000_atomic_append_projection.sql:5, 20260920233000_set_based_append_projection.sql:5, 20260921070000_production_append_stream_compatibility.sql:130, 20260921111000_wearable_lifecycle.sql:111, 20260922120000_intake_service_contract.sql:119, 20260925030000_indexed_append_identity_lookup.sql:4, 20260928010000_set_based_append_projection.sql:9, 20260928011000_append_projection_qualified_row.sql:6 | 20260928011000_append_projection_qualified_row.sql:6 |
| `noop_claim_projection_debt` | 20260918040000_production_projection_debt.sql:90, 20260922120000_intake_service_contract.sql:412 | 20260922120000_intake_service_contract.sql:412 |
| `noop_commit_object_receipt` | 20260921060000_production_intake_durability.sql:168, 20260922120000_intake_service_contract.sql:8 | 20260922120000_intake_service_contract.sql:8 |
| `noop_claim_object_verification` | 20260922020000_async_object_verification.sql:149, 20260922120000_intake_service_contract.sql:356 | 20260922120000_intake_service_contract.sql:356 |
| `noop_reserve_object_manifest` | 20260921060000_production_intake_durability.sql:107, 20260921110000_installation_retirement.sql:78, 20260923180000_object_representation_identity.sql:39 | 20260923180000_object_representation_identity.sql:39 |
| `noop_push_save_ack` | 20260907150000_noop_push_wal.sql:59, 20260921060000_production_intake_durability.sql:251 | 20260921060000_production_intake_durability.sql:251 |
| `scoring_claim_one` | 20260918010000_physiology_revisions.sql:322, 20260918100000_physiology_independent_work.sql:319, 20260921112000_fleet_scheduler.sql:79 | 20260921112000_fleet_scheduler.sql:79 |
| `scoring_finish_work` | 20260918010000_physiology_revisions.sql:368, 20260918100000_physiology_independent_work.sql:194, 20260918150000_coalesce_inflight_scoring.sql:140, 20260918200000_restore_input_revision_fencing.sql:36, 20260921112000_fleet_scheduler.sql:120 | 20260921112000_fleet_scheduler.sql:120 |
| `engine_publish_legacy_fenced` | 20260918120000_fenced_baseline_transport.sql:178, 20260921102000_server_baseline_publication.sql:5, 20260921103000_server_publication_conflict_transport.sql:14 | 20260921103000_server_publication_conflict_transport.sql:14 |
| `claim_scoring_v2` | 20260918010000_production_scoring_durability.sql:121, 20260918050000_production_scoring_history.sql:764 | 20260918050000_production_scoring_history.sql:764 |
| `engine_ingest_scored` | 20260916160000_scoring_service_state.sql:198, 20260918030000_production_scoring_review_repairs.sql:6, 20260918120000_fenced_baseline_transport.sql:170, 20260927020000_restore_fenced_baseline_serializer.sql:163 | 20260927020000_restore_fenced_baseline_serializer.sql:163 |
| `server_scoring_for_day` | 20260917180000_server_score_user_reads.sql:22, 20260918020000_physiology_publication.sql:326, 20260918100000_physiology_independent_work.sql:407, 20260918130000_owner_score_reads.sql:57, 20260918140000_score_device_with_samples.sql:7, 20260918190000_frequent_heart_rate_readback.sql:33, 20260918230000_physiology_signed_promotion.sql:234, 20260921100000_server_score_read_contract.sql:151, 20260921121000_final_hosted_compute_contract.sql:260 | 20260921121000_final_hosted_compute_contract.sql:260 |
| `scoring_legacy_claim_one` | 20260918120000_fenced_baseline_transport.sql:84, 20260923140000_legacy_snapshot_progress.sql:96 | 20260923140000_legacy_snapshot_progress.sql:96 |
| `scoring_legacy_finish_work` | 20260918120000_fenced_baseline_transport.sql:121, 20260923140000_legacy_snapshot_progress.sql:174 | 20260923140000_legacy_snapshot_progress.sql:174 |

## Notes

- The parent task named `scoring_legacy_claim_one`, `scoring_legacy_seal_snapshot`, `scoring_legacy_finish_work`. All three exist in the deployed DB as separate functions and were dumped; they are NOT aliases of `scoring_claim_one`/`scoring_finish_work`.
- `noop_commit_push_projection_intake_core` and `noop_project_append_batch_core` exist in the deployed DB but have no literal `create function` in any migration; they are created by `alter function ... rename to`. Their pinned bodies are the renamed originals. See RENAME_CORES list in `normalize_diff.py`.
- Per-function diff files (normalized, empty for IDENTICAL) are in `diffs/<name>.diff`.
- Raw deployed definitions: `public__<name>.sql`; signatures/ACL: `SIGNATURES.md`; enumeration: `ENUMERATION.md`.
