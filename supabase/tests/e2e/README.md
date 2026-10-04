# End-to-end and isolation harnesses

Two disposable harnesses live here. Neither touches a hosted project, the repo's own local stack
(`supabase start` from the repo root) or any port that stack uses, and `down` removes everything
they created.

| Harness | Answers | Used by |
| --- | --- | --- |
| `stack.sh` | Does a person get from sign-up to a scored day on screen, and do two people stay apart on the way? | `StrandTests/NaraEndToEndTests` through `run_swift.sh` |
| `pipeline_db.sh` | Does the production Postgres image (roles, default privileges, RLS) keep accounts, installations and devices apart? | the Docker-gated Deno suites in `supabase/functions/tests/` |

Both apply the migrations with `psql -1` as the `postgres` role, in the order `ordered_migrations.sh`
prints. That is how production applies them. It is not `supabase db push`: production's history
table stops at `20260921104000`, so `db push` would try to replay every later migration.

`supabase/migrations/` does not apply to an empty database in plain lexicographic order, because
`20260918040000_production_projection_debt.sql` alters a column that
`20260921060000_production_intake_durability.sql` creates. Production never hit it because its
history grew one migration at a time. Migration files are immutable once applied, so
`ordered_migrations.sh` moves the intake-durability migration to just after the scoring-durability
migration it extends. Use it for any fresh local database; `supabase db reset` fails.

## Prerequisites

Docker (Colima works), the `supabase` CLI (2.75 or newer), `deno`, `psql`, `openssl` and `python3`.
`pipeline_db.sh` also needs PostgREST (`brew install postgrest`) and the GoTrue image
(`public.ecr.aws/supabase/gotrue:v2.186.0`, pulled on first use). The Swift suite needs Xcode, and a
built worker (`cd Tools/CloudWorker && swift build`; on macOS libpq and OpenSSL come from Homebrew, so
set `PKG_CONFIG_PATH=/opt/homebrew/opt/libpq/lib/pkgconfig:/opt/homebrew/opt/openssl@3/lib/pkgconfig:/opt/homebrew/opt/zstd/lib/pkgconfig`).
Without the worker the stack still comes up; scoring just never runs.

## `stack.sh`: sign-up to scored day

```bash
supabase/tests/e2e/stack.sh up      # builds the stack, prints the NARA_E2E_* environment
supabase/tests/e2e/run_swift.sh     # runs StrandTests/NaraEndToEndTests against it
supabase/tests/e2e/stack.sh down
```

What `up` starts, all in one origin (`NARA_E2E_GATEWAY`) so the app sees one Supabase project:

- Postgres 17, GoTrue, PostgREST and Kong from `supabase start` (project `nara-auth-e2e`, ports 54420-54442).
  Confirmations are on and the one-time code is 8 digits, as in `supabase/config.toml`.
- An SMTP sink (`smtp_sink.py`) standing in for Resend. GoTrue sends the real confirmation email through
  it, and the test reads the code out of the message, so the real email template and the code length are
  exercised. `GET /__e2e/mail?to=<address>` returns what was sent.
- The unmodified `push` and `scores` Edge functions under Deno, an in-memory S3 stub in place of
  Backblaze B2 (`gateway.ts`), and the real `frwhoop-worker` on the scoring lane.

`NaraEndToEndTests` covers five scenarios:

1. Sign up, enter the emailed code, link the phone, pair a strap, upload, get scored and read it back.
2. Two accounts on two phones, with two straps, stay isolated from sign-up through the scored readback,
   including row-level security through PostgREST and refused cross-account requests.
3. Signing out of A and into B on the same phone never retags A's queued or local data as B's.
4. A relaunched app, and an upload with no Auth session at all (the locked-phone case), still work from
   the Keychain credential alone.
5. A revoked installation and a deleted account fail closed.

The suite skips itself when `NARA_E2E_*` is not set, so a plain `xcodebuild test` is unaffected.
`run_swift.sh` passes the environment through xcodebuild's `TEST_RUNNER_` prefix. Two variables help
when the checkout is on an external drive, where a hosted test that reads its own sources can hang on a
volume-permission prompt: `NARA_E2E_APP_DIR` runs from a copy on the internal disk and `NARA_E2E_DERIVED`
sets the derived-data path.

The environment holds a Supabase *secret key* for the local stack so the test can delete a user and
revoke an installation. It exists only in this process and on this machine's throwaway stack. The app
under test never receives it; it holds only the publishable key.

## `pipeline_db.sh`: the production image, through PostgREST

```bash
supabase/tests/e2e/pipeline_db.sh up
set -a; source ~/.cache/nara-pipeline-db/pipeline.env; set +a
cd supabase/functions
EDGE_TEST_ARTIFACTS=/tmp/edgeart deno test -A --no-lock tests/auth_isolation_sql_test.ts
supabase/tests/e2e/pipeline_db.sh reset      # before the next suite
supabase/tests/e2e/pipeline_db.sh down
```

`up` starts `supabase/postgres` (the image Supabase hosts on), lets GoTrue migrate the `auth` schema as it
does on a hosted project, applies every migration, snapshots the result, and puts PostgREST and an
auto-confirming GoTrue in front of it, PostgREST configured as hosted Supabase configures it, including the
`authenticator` role's `safeupdate` setting. `reset` restores the snapshot. Every suite inserts fixed
fixtures, so run `reset` between suites. Exported variables:

| Variable | Meaning |
| --- | --- |
| `PIPELINE_TEST_DATABASE_CONTAINER` | the container; it must be named `nara-db-server-pipeline.<id>` |
| `PIPELINE_TEST_REST_URL` | PostgREST on loopback |
| `PIPELINE_TEST_AUTH_URL` | GoTrue on loopback, same JWT secret, sign-up returns a session with no email step |
| `PIPELINE_TEST_DATABASE_URL` | the database as `postgres`, for suites that reach it directly |
| `PIPELINE_TEST_OUTPUT` | where suites write evidence files |
| `PIPELINE_TEST_SOURCE_*` | the git commit, tree and cleanliness the capacity suites stamp into their evidence |

The image ships a pre-GoTrue `auth` schema whose `auth.uid()` reads a legacy setting PostgREST no longer
sets. Starting GoTrue before the application migrations replaces it with the definitions a hosted project
has, so row-level security behaves as it does in production. `NARA_PIPELINE_AUTH_IMAGE` and
`NARA_PIPELINE_AUTH_PORT` override the GoTrue image and port.

`NARA_PIPELINE_SAFEUPDATE=off pipeline_db.sh reset` turns `safeupdate` off. The scheduler test in
`multiuser_sql_test.ts` and `server_pipeline_sql_test.ts` need that: they call `scoring_claim_one` through
PostgREST, and that function's unqualified `UPDATE` is refused there. The worker calls it over a direct
connection, which `safeupdate` does not govern.

Suites that run here:

| Suite | Notes |
| --- | --- |
| `auth_isolation_sql_test.ts` | The catalogue audit (every public table has RLS, every client-reachable policy and function is on a reviewed list, no view leaks) and the two-account run (two users, two installations, two devices; reads, writes, RPCs, re-pointing and revoked or deleted accounts, through PostgREST as each user). |
| `multiuser_sql_test.ts` | The pre-existing lifecycle and capacity checks. The capacity test needs `safeupdate` off and takes about seven minutes. One lifecycle step reads an Android fixture that is not in this repository and fails with or without these changes; the other ten pass. |
| `server_pipeline_sql_test.ts` | Real SQL through the enrolled and the signed-in-account Edge paths. It opts in to legacy enrollment explicitly because its fixtures are enrollment-code installations. Needs `PIPELINE_TEST_AUTH_URL`, and `safeupdate` off. |
| `intake_consumer_sql_test.ts` | Needs the database container and the REST URL. |
| `capacity_evidence_test.ts` | Two of its assertions read files this repository does not contain (`infra/vps/launch-capacity.json`, `scoring-service/scripts/test-server-pipeline.sh`) and fail on a clean checkout; the other five pass. |

Suites that need a JVM worker binary (`PIPELINE_TEST_V1_BINARY`, `PIPELINE_TEST_V2_BINARY`) or a private
recording (`PIPELINE_TEST_REAL_RECORDING`) skip themselves without those and are not run by this harness.
