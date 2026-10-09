// The per-minute measurement context on the production Postgres image with the full migration chain: runs
// supabase/tests/measurement_context_minutes.sql (rule exercise-session-1 parity with
// contracts/reference/exercise-session-1.json, a synthetic day built from raw rows, idempotence, backfill, the
// pg_cron path, RLS between two owners) inside the pipeline container. Docker-gated like auth_isolation_sql_test.ts:
//
//   set -a; source ~/.cache/nara-pipeline-db/pipeline.env; set +a
//   cd supabase/functions
//   deno test -A --no-lock tests/measurement_context_sql_test.ts
//
// The SQL file runs in one transaction that it rolls back, so it leaves the database as it found it.
import assert from 'node:assert/strict';

const container = Deno.env.get('PIPELINE_TEST_DATABASE_CONTAINER');

async function runSqlFile(file: URL, vars: Record<string, string>, appName: string) {
  const args = ['exec', '-e', `PGAPPNAME=${appName}`, '-i', container!, 'psql', '-U', 'postgres', '-d', 'postgres',
    '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'];
  for (const [k, v] of Object.entries(vars)) args.push('-v', `${k}=${v}`);
  const child = new Deno.Command('docker', { args, stdin: 'piped', stdout: 'piped', stderr: 'piped' }).spawn();
  const writer = child.stdin.getWriter();
  await writer.write(await Deno.readFile(file));
  await writer.close();
  const out = await child.output();
  return { code: out.code, stdout: new TextDecoder().decode(out.stdout), stderr: new TextDecoder().decode(out.stderr) };
}

Deno.test({
  name: 'measurement context minutes: exercise-session-1 parity, synthetic day, idempotence, backfill, cron, RLS',
  ignore: !container,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const fixture = await Deno.readTextFile(new URL('../../../contracts/reference/exercise-session-1.json', import.meta.url));
    const run = await runSqlFile(new URL('../../tests/measurement_context_minutes.sql', import.meta.url), { fixture },
      'measurement-context-minutes');
    assert.equal(run.code, 0, run.stderr.slice(-4000));
    assert.match(run.stdout, /measurement_context_minutes: ok/);
  },
});
