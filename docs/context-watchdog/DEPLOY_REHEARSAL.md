# Production migration rehearsal (2026-10-09 20:41–20:55 UTC)

The 12 database changes in [README.md](README.md) §4 were rehearsed against a copy of production's schema, not a
repo-built database:

- A read-only `pg_dump --schema-only -n public -n internal -n supabase_migrations` of production (2.0 MB, sha256
  `c14f52376b241516…`, kept on the Untitled drive under `_build-scratch/ctxwd/prod-deploy-20261009T204117Z/`, not
  committed) was restored into a fresh `supabase/postgres:17.6.1.075` container (production runs 17.6) after creating
  the extensions production has (`btree_gin` in `extensions`, `pg_cron`, `pg_net` in `public`). The restore produced one
  error, `schema "public" already exists`, which is expected.
- Applied as `postgres`, in deploy order: the concurrent index `noop_upload_receipts_source_device_idx`, then
  `20261009110000` … `20261009150200`, each with `psql -v ON_ERROR_STOP=1 -1 -f`. **All twelve applied with exit 0 and
  no errors.**
- Out-of-band check: seven functions these migrations replace already exist in production
  (`internal.metric_insight_inputs`, `internal.physiology_context_dependency_fingerprint`,
  `internal.physiology_context_placement_changed`, `public.physiology_record_candidate_result`,
  `public.coach_memory_apply_v1`, `public.coach_memories_ranked_v1`, `public.publish_anomaly_result_v1`). Each has one
  overload in production and its body equals (whitespace-normalised) the last definition in the repository migrations,
  so no fix applied directly to production is overwritten. Their production definitions are saved with the dump as
  rollback material.
- Production at the time: newest recorded migration `20261009030000`; `noop_upload_receipts` 131 MB (~258 k rows);
  `scoring_jobs_v2` 605 rows (the measurement-context discovery scans it every 5 minutes).

The production run itself was not executed from this session: the session's permission policy refused it as a
production deploy. Recording format for production: `supabase_migrations.schema_migrations (version, name,
statements)` with the file text as the single statement, as earlier deploys did.

## Second rehearsal (2026-10-09, after rule exercise-session-2 and the RecGym merge)

Three migrations changed after the first rehearsal (`20261009130100` rule -2 and the `active` phase,
`20261009150200` the `active` share in the window mix, `20261009140100` / `20261009150000` comments only) and the RecGym
merge added `20261009160000_activity_exercise_windows`. The same production schema dump was restored into a fresh
`supabase/postgres:17.6.1.075` container (same extensions; the one expected `schema "public" already exists` error),
then the concurrent index and all thirteen migrations were applied in deploy order with `ON_ERROR_STOP=1 -1`: **all
exit 0, no errors.** Both rehearsal containers were removed afterwards.
