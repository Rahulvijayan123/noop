import { assert, assertEquals } from 'jsr:@std/assert';
import { hashIngestToken } from '../_shared/tokens.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { makeMemRest } from './helpers.ts';

// GET /scores/motion-heads: the Inertia / ActiNet motion heads for the phone's decoder. Same scoping, `known` rule and
// envelope as /gait-windows; the newest row of a day wins, the candidate decode document is never sent, and a row
// reads as production only to a caller with the authority capability.

const USER = '7f2c9a10-4b3e-4d8a-9c11-00000000f001';
const DEVICE = '11111111-1111-4111-8111-111111111111';
const SOURCE = '22222222-2222-4222-8222-222222222222';
const LOCAL_DEVICE = 'whoop-MGB0214654';
const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon', allowLegacyEnrollment: true };

const WINDOWS = { format: 'mh-col-1', n: 2, w: 30, s0: 1791158400, ds: [0, 5], x: [0, 0], mi: [0, 0],
  heads: { posture: { i: [1, 2], p: [900, 800] } } };
const BUNDLE = { encoder_id: 'actinet/harnet30', encoder_kind: 'actinet', encoder_version: 'harnet30',
  checkpoint_sha256: 'c'.repeat(64), heads_version: 'actinet-heads-1', bundle_sha256: 'a'.repeat(64),
  preprocessing_version: 'inertia-prep-1', evidence_tier_max: 'production', window_s: 30, hop_s: 5,
  bundle: { heads: { posture: { classes: ['sit', 'stand'] } }, ood: { method: 'knn', threshold: 1.2 } } };

type Row = { day: string; mode: string; bundle_id?: string; result_revision: number; computed_at: string;
  input_revision?: number; release_mode?: string | null; authority?: unknown; encoder_kind?: string;
  evidence_tier_max?: string; bundle_info?: unknown };

function fakeRest(rows: Row[], reads: string[]) {
  const rest = makeMemRest() as any;
  rest.select = async (table: string, query: string) => {
    if (table === 'noop_ingest_tokens') return query.includes(hashIngestToken('noop_test-token'))
      ? [{ id: 'tok', token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: USER, source_id: SOURCE }]
      : [{ id: 'fleet', token_kind: 'fleet' }];
    if (table === 'noop_app_installations') return [{ user_id: USER, source_id: SOURCE }];
    if (table === 'devices') { assert(query.includes(`user_id=eq.${USER}`)); return [{ id: DEVICE }]; }
    if (table === 'activity_motion_heads_days') {
      reads.push(query);
      assert(query.includes(`user_id=eq.${USER}`) && query.includes(`device_id=eq.${DEVICE}`),
        'every read is scoped to the credential owner and the resolved device');
      assert(!query.includes('candidate_document'), 'the candidate decode is never read');
      const full = rows.map((r) => ({ bundle_id: 'actinet-heads-1', encoder_kind: 'actinet',
        evidence_tier_max: 'production', input_revision: 4, ...r }));
      const inDays = /day=in\.\(([^)]*)\)/.exec(query);
      if (inDays) {
        const days = inDays[1].split(',');
        return full.filter((r) => days.includes(r.day))
          .sort((a, b) => b.computed_at.localeCompare(a.computed_at))
          .map(({ authority: _a, bundle_info: _b, ...r }) => ({ ...r, encoder_id: BUNDLE.encoder_id,
            bundle_sha256: BUNDLE.bundle_sha256, window_s: 30, hop_s: 5, n_windows: 2, n_ood: 0 }));
      }
      const day = /day=eq\.([0-9-]+)/.exec(query)![1];
      const mode = /mode=eq\.([a-z]+)/.exec(query)![1];
      const bundle = decodeURIComponent(/bundle_id=eq\.([^&]+)/.exec(query)![1]);
      return full.filter((r) => r.day === day && r.mode === mode && r.bundle_id === bundle).map((r) => ({
        result_revision: r.result_revision, input_revision: r.input_revision, mode: r.mode,
        release_mode: r.release_mode, encoder_kind: r.encoder_kind, evidence_tier_max: r.evidence_tier_max,
        authority: r.authority ?? null, bundle_info: r.bundle_info ?? null, windows: WINDOWS,
        summary: { n_windows: 2, n_ood: 0, posture: { sit: 0.5 }, authority: { release_mode: 'production' } },
        candidate_document: { secret: true },
      }));
    }
    return [];
  };
  return rest;
}

function get(query: string) {
  return new Request(`https://example.test/functions/v1/scores/motion-heads?deviceId=${LOCAL_DEVICE}&${query}`, {
    headers: { authorization: 'Bearer noop_test-token', 'x-noop-fleet-token': 'noop_fleet' },
  });
}

async function byDay(res: Response) {
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.identity.deviceId, DEVICE);
  return Object.fromEntries(body.days.map((d: any) => [d.day, d]));
}

Deno.test('motion heads: newest row per day, unchanged days skipped, candidate document never sent', async () => {
  const reads: string[] = [];
  const rows: Row[] = [
    { day: '2026-10-04', mode: 'candidate', result_revision: 3, computed_at: '2026-10-04T23:00:00Z',
      release_mode: 'candidate' },
    { day: '2026-10-05', mode: 'shadow', result_revision: 8, computed_at: '2026-10-05T10:00:00Z', release_mode: 'shadow' },
    { day: '2026-10-05', mode: 'production', result_revision: 9, computed_at: '2026-10-05T12:00:00Z',
      release_mode: 'production', bundle_info: BUNDLE },
  ];
  const days = await byDay(await handleScoresRequest(
    get('days=2026-10-04,2026-10-05&known=2026-10-04:3&authority=1'), { rest: fakeRest(rows, reads), cfg }));
  assertEquals(days['2026-10-04'].unchanged, true);
  assertEquals(days['2026-10-04'].release_mode, 'candidate');
  assertEquals(days['2026-10-04'].input_revision, '4');
  assertEquals(days['2026-10-04'].result_revision, '3');
  assertEquals(days['2026-10-04'].windows, undefined);
  assertEquals(days['2026-10-04'].bundle, undefined);
  const d = days['2026-10-05'];
  assertEquals(d.mode, 'production');
  assertEquals(d.result_revision, '9');
  assertEquals(d.input_revision, '4');
  assertEquals(d.bundle_id, 'actinet-heads-1');
  assertEquals(d.encoder_kind, 'actinet');
  assertEquals(d.windows.format, 'mh-col-1');
  assertEquals(d.summary.posture.sit, 0.5);
  assertEquals(d.summary.authority, undefined, 'the unlowered block inside the summary is not sent');
  assertEquals(d.candidate_document, undefined);
  assertEquals(reads.length, 2, 'one head read, one body read for the changed day');
});

Deno.test('motion heads: production release, bundle passthrough and authority lowering', async () => {
  const released = { policy: 'expert-authority-1', channel: 'motion_heads', route: 'standalone', mode: 'production',
    release_mode: 'production', use: 'canonical', reason: null, input_revision: '7' };
  const rows: Row[] = [
    { day: '2026-10-03', mode: 'production', result_revision: 2, computed_at: '2026-10-03T23:00:00Z',
      release_mode: 'production', input_revision: 7, authority: released, bundle_info: BUNDLE },
    // Written before bundle_info existed, and lowered to candidate by its producer.
    { day: '2026-10-04', mode: 'production', result_revision: 3, computed_at: '2026-10-04T23:00:00Z',
      release_mode: 'candidate', authority: { ...released, release_mode: 'candidate' } },
    // A stored release above the bundle's tier still reads as the tier.
    { day: '2026-10-05', mode: 'production', result_revision: 4, computed_at: '2026-10-05T23:00:00Z',
      release_mode: 'production', evidence_tier_max: 'candidate', authority: released },
  ];
  const q = 'days=2026-10-03,2026-10-04,2026-10-05';
  const now = await byDay(await handleScoresRequest(get(`${q}&authority=1`), { rest: fakeRest(rows, []), cfg }));
  assertEquals(now['2026-10-03'].release_mode, 'production');
  assertEquals(now['2026-10-03'].authority, released);
  assertEquals(now['2026-10-03'].bundle, BUNDLE, 'the stored bundle info, nested manifest included');
  assertEquals(now['2026-10-03'].input_revision, '7');
  assertEquals(now['2026-10-04'].release_mode, 'candidate');
  assertEquals(now['2026-10-04'].authority.release_mode, 'candidate');
  assertEquals(now['2026-10-04'].bundle, null);
  assertEquals(now['2026-10-05'].release_mode, 'candidate');
  assertEquals(now['2026-10-05'].authority.release_mode, 'candidate');
  const again = await handleScoresRequest(get('days=2026-10-03&known=2026-10-03:2&authority=1'),
    { rest: fakeRest(rows, []), cfg });
  const [unchanged] = (await again.json()).days;
  assertEquals(unchanged.unchanged, true);
  assertEquals(unchanged.release_mode, 'production');
  assertEquals(unchanged.input_revision, '7');
});

Deno.test('motion heads: stand-ins and shadow-tier bundles are shadow whatever the row says', async () => {
  const rows: Row[] = [
    { day: '2026-10-04', mode: 'production', result_revision: 3, computed_at: '2026-10-04T23:00:00Z',
      release_mode: 'production', encoder_kind: 'standin' },
    { day: '2026-10-05', mode: 'candidate', result_revision: 9, computed_at: '2026-10-05T12:00:00Z',
      release_mode: 'candidate', evidence_tier_max: 'shadow' },
  ];
  const now = await byDay(await handleScoresRequest(get('days=2026-10-04,2026-10-05&authority=1'),
    { rest: fakeRest(rows, []), cfg }));
  assertEquals(now['2026-10-04'].release_mode, 'shadow');
  assertEquals(now['2026-10-05'].release_mode, 'shadow');
});

Deno.test('motion heads: a caller without the authority capability never sees production, a bundle or a block', async () => {
  const rows: Row[] = [
    { day: '2026-10-04', mode: 'candidate', result_revision: 3, computed_at: '2026-10-04T23:00:00Z',
      release_mode: 'candidate', authority: { release_mode: 'candidate' }, bundle_info: BUNDLE },
    { day: '2026-10-05', mode: 'production', result_revision: 9, computed_at: '2026-10-05T12:00:00Z',
      release_mode: 'production', authority: { release_mode: 'production' }, bundle_info: BUNDLE },
  ];
  const old = await byDay(await handleScoresRequest(get('days=2026-10-04,2026-10-05'), { rest: fakeRest(rows, []), cfg }));
  assertEquals(old['2026-10-04'].release_mode, 'candidate');
  assertEquals(old['2026-10-05'].release_mode, 'shadow');
  for (const day of ['2026-10-04', '2026-10-05']) {
    assertEquals(old[day].bundle, undefined, day);
    assertEquals(old[day].authority, undefined, day);
    assertEquals(old[day].candidate_document, undefined, day);
    assertEquals(old[day].windows.format, 'mh-col-1', day);
    assertEquals(old[day].summary.n_windows, 2, day);
  }
});

Deno.test('motion heads: malformed queries are rejected before the database is asked', async () => {
  for (const query of ['', 'days=2026-13-45', 'days=2026-10-01,2026-10-02,2026-10-03,2026-10-04',
    'days=2026-10-05&known=2026-10-04:3', 'days=2026-10-05&authority=yes', 'days=2026-10-05&authority=0']) {
    const reads: string[] = [];
    const res = await handleScoresRequest(get(query), { rest: fakeRest([], reads), cfg });
    assertEquals(res.status, 400, query);
    assertEquals(reads.length, 0, query);
  }
});
