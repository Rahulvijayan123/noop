// contracts/reason-codes.json is the one vocabulary of data reasons. This test fails when the edge table
// (_shared/reasonCodes.ts) or the SQL seed (20261009130000_reason_codes.sql: public.reason_codes and
// public.reason_code_legacy) drifts from it. The TS half always runs; the SQL half queries the pipeline database and
// is Docker-gated like auth_isolation_sql_test.ts:
//
//   set -a; source ~/.cache/nara-pipeline-db/pipeline.env; set +a
//   cd supabase/functions
//   deno test -A --no-lock tests/reason_codes_parity_test.ts
import assert from 'node:assert/strict';
import {
  canonicalize, LEGACY_REASONS, REASON_CODES, REASON_CODES_VERSION, reasonCode,
} from '../_shared/reasonCodes.ts';

const container = Deno.env.get('PIPELINE_TEST_DATABASE_CONTAINER');
const contract = JSON.parse(await Deno.readTextFile(new URL('../../../contracts/reason-codes.json', import.meta.url)));

/** The JSON's codes in the TS shape (description and confirmed_when stay in the JSON and SQL). */
function contractCodes() {
  return contract.codes.map((c: any) => ({
    code: c.code, family: c.family, default_certainty: c.default_certainty, effect: c.effect,
    ...(c.subcodes ? { subcodes: c.subcodes } : {}),
  }));
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

Deno.test('reason codes: the edge table equals contracts/reason-codes.json', () => {
  assert.equal(REASON_CODES_VERSION, contract.version);
  assert.deepEqual(REASON_CODES.map((c) => ({ ...c })), contractCodes());
  assert.deepEqual(JSON.parse(JSON.stringify(LEGACY_REASONS)), contract.legacy);
  for (const c of REASON_CODES) {
    assert.ok(contract.families.includes(c.family), `${c.code}: family`);
    assert.ok(contract.certainties.includes(c.default_certainty), `${c.code}: certainty`);
    assert.ok(contract.effects.includes(c.effect), `${c.code}: effect`);
  }
  for (const [vocabulary, map] of Object.entries(LEGACY_REASONS)) {
    for (const [legacy, reason] of Object.entries(map)) {
      assert.ok(reasonCode(reason.code), `${vocabulary}.${legacy} maps to an unknown code ${reason.code}`);
      if (reason.subcode) assert.ok(reasonCode(reason.code)!.subcodes?.includes(reason.subcode), `${legacy}: subcode`);
    }
  }
});

Deno.test('reason codes: canonicalize maps legacy values, keeps canonical ones, refuses the rest', () => {
  assert.deepEqual(canonicalize('watchdog_quality', 'motion_mode_optics'),
    { code: 'motion_artifact', certainty: 'inferred' });
  assert.deepEqual(canonicalize('watchdog_quality', 'wrist_off_event'), { code: 'off_wrist', certainty: 'confirmed' });
  assert.deepEqual(canonicalize('anomaly_withheld', 'activity'),
    { code: 'context_not_comparable', subcode: 'movement', certainty: 'inferred' });
  assert.deepEqual(canonicalize('sensor_biomarker', 'artifact_unavailable'),
    { code: 'no_verified_input', certainty: 'unknown' });
  // Already canonical: the code itself at its default certainty.
  assert.deepEqual(canonicalize('watchdog_quality', 'off_wrist'), { code: 'off_wrist', certainty: 'inferred' });
  assert.equal(canonicalize('watchdog_quality', 'no_such_reason'), null);
  assert.deepEqual(canonicalize('no_such_vocabulary', 'charging'), { code: 'charging', certainty: 'confirmed' });
  assert.equal(canonicalize('watchdog_quality', 'constructor'), null, 'prototype keys are not reasons');
  assert.equal(canonicalize('toString', 'x'), null);
  // A returned reason is a copy: mutating it never edits the table.
  const r = canonicalize('layer1', 'charging')!;
  r.code = 'tampered';
  assert.equal(canonicalize('layer1', 'charging')!.code, 'charging');
});

Deno.test({
  name: 'reason codes: the SQL seed equals contracts/reason-codes.json',
  ignore: !container,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const codes = JSON.parse(await psql(`
      select coalesce(jsonb_agg(jsonb_build_object('code', code, 'family', family,
        'default_certainty', default_certainty, 'effect', effect, 'description', description,
        'confirmed_when', confirmed_when, 'subcodes', subcodes, 'version', version) order by code collate "C"), '[]')
        from public.reason_codes`));
    const expected = [...contract.codes].sort((a: any, b: any) => (a.code < b.code ? -1 : 1)).map((c: any) => ({
      code: c.code, family: c.family, default_certainty: c.default_certainty, effect: c.effect,
      description: c.description, confirmed_when: c.confirmed_when ?? null, subcodes: c.subcodes ?? [],
      version: contract.version,
    }));
    assert.deepEqual(codes, expected);

    const legacy = JSON.parse(await psql(`
      select coalesce(jsonb_object_agg(vocabulary, m), '{}') from (
        select vocabulary, jsonb_object_agg(legacy_code, jsonb_strip_nulls(jsonb_build_object('code', code,
          'certainty', certainty, 'subcode', subcode))) as m
          from public.reason_code_legacy group by vocabulary) v`));
    assert.deepEqual(legacy, contract.legacy);

    // The SQL helper agrees with the edge one on every legacy value, and both refuse an unknown value.
    const pairs = Object.entries(contract.legacy).flatMap(([v, m]: [string, any]) => Object.keys(m).map((k) => [v, k]));
    const values = pairs.map(([v, k]) => `('${v}', '${k}')`).join(', ');
    const sqlMapped = JSON.parse(await psql(`
      select jsonb_agg(internal.canonical_reason(v, k) order by v collate "C", k collate "C")
        from (values ${values}) t(v, k)`));
    const tsMapped = [...pairs].sort(([a, b], [c, d]) => (a === c ? (b < d ? -1 : 1) : (a < c ? -1 : 1)))
      .map(([v, k]) => canonicalize(v, k));
    assert.deepEqual(sqlMapped, tsMapped);
    assert.equal(await psql(`select internal.canonical_reason('watchdog_quality', 'no_such_reason') is null`), 't');

    // Service-only reference data: no client can read or write it.
    assert.equal(await psql(`
      select bool_or(has_table_privilege(r, t, p)) from unnest(array['anon', 'authenticated']) r,
        unnest(array['public.reason_codes', 'public.reason_code_legacy']) t,
        unnest(array['select', 'insert', 'update']) p`), 'f');
  },
});
