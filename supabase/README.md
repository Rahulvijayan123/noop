# FRWHOOP schema migrations

Canonical lineage: **this directory** (`supabase/migrations/`).

A fresh local database is built by applying the migrations with `psql -1` in the order that
`tests/e2e/ordered_migrations.sh` prints (the order the test harnesses use, and how production applies them).
`supabase db reset` applies them in plain filename order, which fails on an empty database at
`20260918040000_production_projection_debt.sql` because it alters a column that
`20260921060000_production_intake_durability.sql` creates. Production never hit this because its history
grew one migration at a time. See [tests/e2e/README.md](tests/e2e/README.md) for ready-made stacks.

`SUPABASE_INTERNAL_IMAGE_REGISTRY=public.ecr.aws` is required on some hosts
(and in CI).

`history/` is archival SQL, not an apply root. Do not apply it.

Link a hosted project only when you need `db push`:

```text
supabase link --project-ref <your-project-ref>
```

The project ref is stored in gitignored `supabase/.temp/`. Never reset a
production database.
