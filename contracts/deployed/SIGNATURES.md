# Deployed RPC signatures

Captured from the live FRWHOOP Postgres database (READ-ONLY). Owner is the function's `proowner`; proacl shows grants. The FRWHOOP cloud worker calls these with `service_role`.

- Captured UTC: 2026-09-30T08:17:26.487342
- Source: `pg_proc` joined to `pg_namespace` (nspname='public')

## Metadata query

```sql
SELECT p.proname,
       pg_get_function_identity_arguments(p.oid) AS identity_args,
       pg_get_userbyid(p.proowner) AS owner,
       COALESCE(array_to_string(p.proacl, E'\n'), '(default)') AS proacl
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname = '%s'
ORDER BY p.oid::regprocedure::text;
```

| RPC | identity arguments | overloads | owner | proacl |
|---|---|---|---|---|
| noop_commit_push_projection | `p_object_id uuid, p_body_sha256 text, p_header jsonb, p_rows jsonb, p_keep_keys jsonb, p_token uuid` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| noop_commit_push_projection_intake_core | `p_object_id uuid, p_body_sha256 text, p_header jsonb, p_rows jsonb, p_keep_keys jsonb, p_token uuid` | 1 | postgres | `postgres=X/postgres` |
| noop_apply_projection_rows | `p_stream text, p_rows jsonb` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| noop_project_append_batch | `p_user uuid, p_device uuid, p_source uuid, p_batch uuid, p_stream text, p_rows jsonb` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| noop_project_append_batch_core | `p_user uuid, p_device uuid, p_source uuid, p_batch uuid, p_stream text, p_rows jsonb` | 1 | postgres | `postgres=X/postgres` |
| noop_projection_target | `p_stream text` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| noop_projection_coordinate | `p_stream text, p_row jsonb` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| noop_claim_projection_debt | `` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| noop_fail_projection_debt | `p_object_id uuid, p_token uuid` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| noop_commit_object_receipt | `p_user_id uuid, p_object_id uuid, p_verified_key text, p_wire_sha256 text, p_content_sha256 text, p_compressed_bytes bigint, p_uncompressed_bytes bigint` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| noop_claim_object_verification | `p_max_bytes bigint, p_max_decoded_bytes bigint` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| noop_finish_object_verification | `p_object_id uuid, p_lease_token uuid, p_failure_code text, p_failure_status integer, p_retryable boolean, p_verification_ms integer` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| noop_reserve_object_manifest | `p_manifest jsonb` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| noop_reserve_push_batch | `p_user_id uuid, p_batch_id uuid, p_device_id uuid, p_body_sha256 text, p_entry jsonb` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| noop_push_save_ack | `p_user_id uuid, p_batch_id uuid, p_body_sha256 text, p_ack jsonb` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| noop_register_push_device | `p_user_id uuid, p_device_id uuid, p_external_device_id text` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| scoring_claim_one | `p_lease_seconds integer, p_max_failures integer, p_user uuid, p_device uuid, p_day date` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| scoring_finish_work | `p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid, p_outcome text, p_duration_ms integer, p_error text` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| engine_publish_legacy_fenced | `p_secret text, p_payload jsonb` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| claim_scoring_v2 | `p_version text, p_lease_seconds integer` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| publish_scoring_snapshot_v2 | `p_token uuid, p_revision bigint, p_payload jsonb, p_duration_ms bigint` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| claim_scoring_archive_v2 | `p_seconds integer` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| complete_scoring_archive_v2 | `p_token uuid, p_sha text, p_bytes bigint, p_bucket text, p_retention_days integer` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| renew_scoring_archive_v2 | `p_token uuid, p_seconds integer` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| fail_scoring_archive_v2 | `p_token uuid, p_error text` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| engine_ingest_scored | `p_secret text, p_payload jsonb` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| server_scoring_for_day | `p_user uuid, p_day date` | 1 | postgres | `postgres=X/postgres ; authenticated=X/postgres ; service_role=X/postgres` |
| scoring_legacy_claim_one | `p_lease_seconds integer, p_max_failures integer, p_user uuid, p_device uuid, p_day date` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| scoring_legacy_seal_snapshot | `p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |
| scoring_legacy_finish_work | `p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid, p_outcome text, p_duration_ms integer, p_error text` | 1 | postgres | `postgres=X/postgres ; service_role=X/postgres` |

## Notes

- All 27 named RPCs exist in the deployed DB with exactly 1 overload each (verified via `pg_proc` count per proname).
- The parent task named `scoring_legacy_claim_one`, `scoring_legacy_seal_snapshot`, `scoring_legacy_finish_work`. These DO exist in the deployed DB as separate functions alongside `scoring_claim_one` / `scoring_finish_work`; all were dumped. `scoring_legacy_seal_snapshot` has no non-legacy `*_seal_snapshot` counterpart in the target list.
- `proacl` includes `service_role=X/postgres` for every dumped function; `server_scoring_for_day` additionally grants `authenticated`.
