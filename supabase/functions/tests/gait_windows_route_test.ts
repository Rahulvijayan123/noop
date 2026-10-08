import { assert, assertEquals } from 'jsr:@std/assert';
import { hashIngestToken } from '../_shared/tokens.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { makeMemRest } from './helpers.ts';

// GET /scores/gait-windows: ElderNet's per-window gait detection and gait quality for the phone's walking card.
// Same scoping and `known` rule as /activity-windows; the newest row of a day wins and the candidate decode
// document is never sent.

const USER = '7f2c9a10-4b3e-4d8a-9c11-00000000f001';
const DEVICE = '11111111-1111-4111-8111-111111111111';
const SOURCE = '22222222-2222-4222-8222-222222222222';
const LOCAL_DEVICE = 'whoop-MGB0214654';
const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon', allowLegacyEnrollment: true };

const WINDOWS = { format: 'gait-windows-1', n: 2, w: 10, h: 5, s0: 1791158400, ds: [0, 5], gp: [970, 20],
  g: [1, 0], pf: [0, 0], sp: [121, -1], cad: [108, -1], st: [134, -1], rg: [81, -1], stp: [180, -1] };

type Row = { day: string; mode: string; model_version: string; result_revision: number; computed_at: string;
  input_revision?: number; release_mode?: string | null; authority?: unknown };

function fakeRest(rows: Row[], reads: string[]) {
  const rest = makeMemRest() as any;
  rest.select = async (table: string, query: string) => {
    if (table === 'noop_ingest_tokens') return query.includes(hashIngestToken('noop_test-token'))
      ? [{ id: 'tok', token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: USER, source_id: SOURCE }]
      : [{ id: 'fleet', token_kind: 'fleet' }];
    if (table === 'noop_app_installations') return [{ user_id: USER, source_id: SOURCE }];
    if (table === 'devices') { assert(query.includes(`user_id=eq.${USER}`)); return [{ id: DEVICE }]; }
    if (table === 'activity_gait_windows_days') {
      reads.push(query);
      assert(query.includes(`user_id=eq.${USER}`) && query.includes(`device_id=eq.${DEVICE}`),
        'every read is scoped to the credential owner and the resolved device');
      assert(!query.includes('candidate_document'), 'the candidate decode is never read');
      const inDays = /day=in\.\(([^)]*)\)/.exec(query);
      if (inDays) {
        const days = inDays[1].split(',');
        return rows.filter((r) => days.includes(r.day))
          .sort((a, b) => b.computed_at.localeCompare(a.computed_at))
          .map(({ authority: _a, ...r }) => ({ input_revision: 4, ...r, hop_s: 5, window_s: 10, gait_threshold: 0.5,
            n_windows: 2, n_gait: 1, n_prefiltered: 0 }));
      }
      const day = /day=eq\.([0-9-]+)/.exec(query)![1];
      const mode = /mode=eq\.([a-z]+)/.exec(query)![1];
      return rows.filter((r) => r.day === day && r.mode === mode).map((r) => ({
        result_revision: r.result_revision, windows: WINDOWS, input_revision: r.input_revision ?? 4, mode: r.mode,
        release_mode: r.release_mode, authority: r.authority ?? null,
        model_id: 'eldernet', weights: { gait_detection: 'a'.repeat(64) }, weights_digest: 'b'.repeat(64),
        upstream_commit: '437a38b', preprocessing_version: 'eldernet-prep-1',
        summary: { gait: { windows: 1, cadence_spm: 108 }, mean_gait_prob: 0.495, windows_omitted: false,
          track_report: { secret: true } },
      }));
    }
    return [];
  };
  return rest;
}

function get(query: string) {
  return new Request(`https://example.test/functions/v1/scores/gait-windows?deviceId=${LOCAL_DEVICE}&${query}`, {
    headers: { authorization: 'Bearer noop_test-token', 'x-noop-fleet-token': 'noop_fleet' },
  });
}

Deno.test('gait windows: newest row per day, unchanged days skipped, summary trimmed', async () => {
  const reads: string[] = [];
  const rest = fakeRest([
    { day: '2026-10-04', mode: 'candidate', model_version: 'eldernet-437a38b', result_revision: 3, computed_at: '2026-10-04T23:00:00Z' },
    { day: '2026-10-05', mode: 'shadow', model_version: 'eldernet-437a38b', result_revision: 8, computed_at: '2026-10-05T10:00:00Z' },
    { day: '2026-10-05', mode: 'candidate', model_version: 'eldernet-437a38b', result_revision: 9, computed_at: '2026-10-05T12:00:00Z' },
  ], reads);
  const res = await handleScoresRequest(get('days=2026-10-04,2026-10-05&known=2026-10-04:3&authority=1'), { rest, cfg });
  assertEquals(res.status, 200);
  const body = await res.json();
  const byDay = Object.fromEntries(body.days.map((d: any) => [d.day, d]));
  assertEquals(byDay['2026-10-04'].unchanged, true);
  assertEquals(byDay['2026-10-04'].windows, undefined);
  assertEquals(byDay['2026-10-05'].mode, 'candidate');
  assertEquals(byDay['2026-10-05'].result_revision, '9');
  assertEquals(byDay['2026-10-05'].windows.format, 'gait-windows-1');
  assertEquals(byDay['2026-10-05'].summary.gait.cadence_spm, 108);
  assertEquals(byDay['2026-10-05'].summary.track_report, undefined);
  assertEquals(byDay['2026-10-05'].model, {
    model_id: 'eldernet', model_version: 'eldernet-437a38b', weights: { gait_detection: 'a'.repeat(64) },
    weights_digest: 'b'.repeat(64), upstream_commit: '437a38b', preprocessing_version: 'eldernet-prep-1',
    window_s: 10, hop_s: 5, gait_threshold: 0.5,
  });
  assertEquals(byDay['2026-10-04'].model, undefined);
  assertEquals(reads.length, 2, 'one head read, one body read for the changed day');
});

Deno.test('gait windows: malformed queries are rejected before the database is asked', async () => {
  for (const query of ['', 'days=2026-13-45', 'days=2026-10-01,2026-10-02,2026-10-03,2026-10-04',
    'days=2026-10-05&known=2026-10-04:3', 'days=2026-10-05&authority=yes', 'days=2026-10-05&authority=0']) {
    const reads: string[] = [];
    const res = await handleScoresRequest(get(query), { rest: fakeRest([], reads), cfg });
    assertEquals(res.status, 400, query);
    assertEquals(reads.length, 0, query);
  }
});

Deno.test('gait windows: every row carries its release and input revision, never production', async () => {
  const pinned = { policy: 'expert-authority-1', channel: 'gait_quality', route: 'standalone', mode: 'candidate',
    release_mode: 'candidate', use: 'candidate', reason: null, input_revision: '7',
    pinned_model_version: 'eldernet-437a38b', pinned_weights_digest: 'b'.repeat(64), gait_prior: 0.2 };
  const rows: Row[] = [
    // Written before the release column existed: no release, no block. Reads as its recorded mode.
    { day: '2026-10-03', mode: 'candidate', model_version: 'eldernet-437a38b', result_revision: 2,
      computed_at: '2026-10-03T23:00:00Z', release_mode: null },
    // A shadow row whose block claims more: still shadow, and so is the block.
    { day: '2026-10-04', mode: 'shadow', model_version: 'eldernet-437a38b', result_revision: 3,
      computed_at: '2026-10-04T23:00:00Z', release_mode: 'shadow', authority: { ...pinned, release_mode: 'production' } },
    // A pinned candidate row.
    { day: '2026-10-05', mode: 'candidate', model_version: 'eldernet-437a38b', result_revision: 9,
      computed_at: '2026-10-05T12:00:00Z', release_mode: 'candidate', input_revision: 7, authority: pinned },
  ];
  const res = await handleScoresRequest(get('days=2026-10-03,2026-10-04,2026-10-05&authority=1'), { rest: fakeRest(rows, []), cfg });
  assertEquals(res.status, 200);
  const byDay = Object.fromEntries((await res.json()).days.map((d: any) => [d.day, d]));
  assertEquals(byDay['2026-10-03'].release_mode, 'candidate');
  assertEquals(byDay['2026-10-03'].authority, null);
  assertEquals(byDay['2026-10-03'].input_revision, '4');
  assertEquals(byDay['2026-10-04'].release_mode, 'shadow');
  assertEquals(byDay['2026-10-04'].authority.release_mode, 'shadow');
  assertEquals(byDay['2026-10-05'].release_mode, 'candidate');
  assertEquals(byDay['2026-10-05'].input_revision, '7');
  assertEquals(byDay['2026-10-05'].authority, pinned);
  assertEquals(byDay['2026-10-05'].identity, {
    model_id: 'eldernet', model_version: 'eldernet-437a38b', weights_digest: 'b'.repeat(64),
    upstream_commit: '437a38b', preprocessing_version: 'eldernet-prep-1',
  });
  for (const d of Object.values(byDay) as any[]) {
    assert(d.release_mode !== 'production' && d.authority?.release_mode !== 'production');
  }
  // An unchanged day still says its release.
  const again = await handleScoresRequest(get('days=2026-10-05&known=2026-10-05:9&authority=1'), { rest: fakeRest(rows, []), cfg });
  const [unchanged] = (await again.json()).days;
  assertEquals(unchanged.unchanged, true);
  assertEquals(unchanged.release_mode, 'candidate');
  assertEquals(unchanged.input_revision, '7');
});

Deno.test('gait windows: an unknown or inconsistent stored release reads as shadow', async () => {
  const rows: Row[] = [
    { day: '2026-10-04', mode: 'shadow', model_version: 'eldernet-437a38b', result_revision: 3,
      computed_at: '2026-10-04T23:00:00Z', release_mode: 'candidate' },
    { day: '2026-10-05', mode: 'candidate', model_version: 'eldernet-437a38b', result_revision: 9,
      computed_at: '2026-10-05T12:00:00Z', release_mode: 'production' },
  ];
  const res = await handleScoresRequest(get('days=2026-10-04,2026-10-05&authority=1'), { rest: fakeRest(rows, []), cfg });
  const byDay = Object.fromEntries((await res.json()).days.map((d: any) => [d.day, d]));
  assertEquals(byDay['2026-10-04'].release_mode, 'shadow');
  assertEquals(byDay['2026-10-05'].release_mode, 'shadow');
});

Deno.test('gait windows: a phone without the authority capability gets its walking card but no decoder model', async () => {
  // The phone built before the release policy installs any row whose `model` digest checks out as PRODUCTION gait
  // evidence (hard-coded pins, `release_mode` ignored). Every row here is shadow or candidate, so it must get the
  // windows and the summary for its walking card, and nothing it can build a model from.
  const rows: Row[] = [
    { day: '2026-10-04', mode: 'shadow', model_version: 'eldernet-437a38b', result_revision: 3,
      computed_at: '2026-10-04T23:00:00Z', release_mode: 'shadow' },
    { day: '2026-10-05', mode: 'candidate', model_version: 'eldernet-437a38b', result_revision: 9,
      computed_at: '2026-10-05T12:00:00Z', release_mode: 'candidate', authority: { release_mode: 'candidate' } },
  ];
  const legacy = await handleScoresRequest(get('days=2026-10-04,2026-10-05'), { rest: fakeRest(rows, []), cfg });
  assertEquals(legacy.status, 200);
  const old = Object.fromEntries((await legacy.json()).days.map((d: any) => [d.day, d]));
  for (const day of ['2026-10-04', '2026-10-05']) {
    assertEquals(old[day].model, undefined, day);
    assertEquals(old[day].identity, undefined, day);
    assertEquals(old[day].authority, undefined, day);
    assertEquals(old[day].windows.format, 'gait-windows-1', 'the walking card keeps its windows');
    assertEquals(old[day].summary.gait.cadence_spm, 108, 'and its day summary');
    assertEquals(old[day].result_revision, day === '2026-10-04' ? '3' : '9');
  }
  // The same rows to a phone that applies the policy itself: the model and the authority block are sent.
  const aware = await handleScoresRequest(get('days=2026-10-04,2026-10-05&authority=1'), { rest: fakeRest(rows, []), cfg });
  const now = Object.fromEntries((await aware.json()).days.map((d: any) => [d.day, d]));
  for (const day of ['2026-10-04', '2026-10-05']) {
    assertEquals(now[day].model.model_id, 'eldernet', day);
    assertEquals(now[day].identity.weights_digest, 'b'.repeat(64), day);
    assertEquals(now[day].windows, old[day].windows);
  }
  assertEquals(now['2026-10-05'].authority.release_mode, 'candidate');
});
