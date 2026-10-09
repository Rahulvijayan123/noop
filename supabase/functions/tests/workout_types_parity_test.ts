// contracts/workout-types-1.json is the one catalogue of workout-mode types. This test fails when the edge table
// (_shared/workoutTypes.ts) or the SQL seed (20261009170000_user_workouts.sql: public.workout_types) drifts from it.
// The TS half always runs; the SQL half queries the pipeline database and is Docker-gated like
// reason_codes_parity_test.ts:
//
//   set -a; source ~/.cache/nara-pipeline-db/pipeline.env; set +a
//   cd supabase/functions
//   deno test -A --no-lock tests/workout_types_parity_test.ts
import assert from 'node:assert/strict';
import { WORKOUT_TYPES, WORKOUT_TYPES_VERSION, workoutType } from '../_shared/workoutTypes.ts';

const container = Deno.env.get('PIPELINE_TEST_DATABASE_CONTAINER');
const contract = JSON.parse(await Deno.readTextFile(new URL('../../../contracts/workout-types-1.json', import.meta.url)));

const FIELDS = ['id', 'name', 'sport_name', 'decoder_kind', 'environment', 'locomotion', 'effort', 'gait_expected',
  'arm_motion', 'steps_expected', 'sport_aliases'] as const;

function pick(t: Record<string, unknown>) {
  return Object.fromEntries(FIELDS.map((k) => [k, t[k]]));
}

async function psql(text: string) {
  const child = new Deno.Command('docker', {
    args: ['exec', '-i', container!, 'psql', '-U', 'postgres', '-d', 'postgres', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
    stdin: 'piped', stdout: 'piped', stderr: 'piped',
  }).spawn();
  const writer = child.stdin.getWriter();
  await writer.write(new TextEncoder().encode(text));
  await writer.close();
  const out = await child.output();
  assert.equal(out.code, 0, new TextDecoder().decode(out.stderr));
  return new TextDecoder().decode(out.stdout).trim();
}

Deno.test('workout types: the edge table equals contracts/workout-types-1.json', () => {
  assert.equal(WORKOUT_TYPES_VERSION, contract.version);
  assert.deepEqual(WORKOUT_TYPES.map((t) => pick({ ...t })), contract.types.map(pick));
  for (const t of WORKOUT_TYPES) {
    assert.ok(contract.environments.includes(t.environment), `${t.id}: environment`);
    assert.ok(contract.locomotions.includes(t.locomotion), `${t.id}: locomotion`);
    assert.ok(contract.efforts.includes(t.effort), `${t.id}: effort`);
    assert.ok(contract.arm_motions.includes(t.arm_motion), `${t.id}: arm_motion`);
    assert.ok(contract.decoder_kinds.includes(t.decoder_kind), `${t.id}: decoder_kind`);
  }
  assert.equal(workoutType('indoor_cycling')?.gait_expected, false);
  assert.equal(workoutType('constructor'), undefined, 'prototype keys are not types');
  assert.equal(workoutType(3), undefined);
});

Deno.test({
  name: 'workout types: the SQL seed equals contracts/workout-types-1.json',
  ignore: !container,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const rows = JSON.parse(await psql(`
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', id, 'version', version, 'name', name, 'sport_name', sport_name, 'decoder_kind', decoder_kind,
               'environment', environment, 'locomotion', locomotion, 'effort', effort, 'gait_expected', gait_expected,
               'arm_motion', arm_motion, 'steps_expected', steps_expected, 'sport_aliases', to_jsonb(sport_aliases))
             order by sort_order), '[]')
        from public.workout_types;`));
    assert.ok(rows.every((r: any) => r.version === contract.version));
    assert.deepEqual(rows.map(pick), contract.types.map(pick));
    // The server resolves a stored sport label exactly as the phone does.
    for (const t of contract.types) {
      for (const name of [t.sport_name, ...t.sport_aliases]) {
        assert.equal(await psql(`select internal.workout_type_for_sport(' ${name.toUpperCase().replaceAll("'", "''")} ')`),
          t.id, name);
      }
    }
    assert.equal(await psql(`select coalesce(internal.workout_type_for_sport('Golf'), 'null')`), 'null');
  },
});
