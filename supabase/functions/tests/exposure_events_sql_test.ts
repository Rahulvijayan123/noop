// Exposure events (contracts.md §10, spec §11, V09, C07) on the production Postgres image through the full
// ordered migration chain. Docker-gated like physiology_context_sql_test.ts (same environment, run after
// `pipeline_db.sh reset`):
//
//   set -a; source ~/.cache/nara-pipeline-db/pipeline.env; set +a
//   cd supabase/functions
//   EDGE_TEST_ARTIFACTS=/tmp/edgeart deno test -A --no-lock tests/exposure_events_sql_test.ts
//
// What it proves: record_exposure_event_v1 keeps every revision (immutable), replaces the current state only
// for a higher revision, treats an identical replay as ignored and a different equal-revision event as a
// conflict, sets received_at itself, serialises concurrent writers of one event, and invalidates exactly the
// affected local days (owner zone, earliest start through latest end + 72 h, every device of the owner,
// clamped to today); exposure_events_read_v1 returns overlapping current events with optional history and
// never another owner's; the database accepts exactly what the edge validator accepts, with the same reason.
// The affected-day rule mirrors Swift Exposures.affectedDays: the local days covering the closed instant range
// [min start - 24 h, max end + 72 h] of the old and new revision (end = max(end, start + 1)).
import assert from 'node:assert/strict';
import { validateExposureEvent } from '../_shared/physiologyContext.ts';

const container = Deno.env.get('PIPELINE_TEST_DATABASE_CONTAINER');
const restUrl = Deno.env.get('PIPELINE_TEST_REST_URL');
const EMAIL_PREFIX = 'pcexp-';
const decoder = new TextDecoder();

async function psql(text: string) {
  const child = new Deno.Command('docker', {
    args: ['exec', '-i', container!, 'psql', '-U', 'postgres', '-d', 'postgres', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
    stdin: 'piped', stdout: 'piped', stderr: 'piped',
  }).spawn();
  const writer = child.stdin.getWriter();
  await writer.write(new TextEncoder().encode(text));
  await writer.close();
  const result = await child.output();
  return { ok: result.code === 0, out: decoder.decode(result.stdout).trim(), err: decoder.decode(result.stderr) };
}
async function sql(text: string) {
  const result = await psql(text);
  assert.ok(result.ok, result.err);
  return result.out;
}
const sqlJson = async (text: string) => JSON.parse((await sql(text)) || 'null');
async function sqlFails(text: string, pattern: RegExp) {
  const result = await psql(text);
  assert.ok(!result.ok, `expected a failure matching ${pattern}, got ${result.out}`);
  assert.match(result.err, pattern);
}

function addDays(day: string, n: number) {
  const date = new Date(`${day}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + n);
  return date.toISOString().slice(0, 10);
}
async function owner(zone: string, devices = 1) {
  const user = crypto.randomUUID();
  const ids = Array.from({ length: devices }, () => crypto.randomUUID());
  await sql(`
    insert into auth.users(id, email) values ('${user}', '${EMAIL_PREFIX}${user}@example.test');
    insert into public.profiles(id, timezone) values ('${user}', '${zone}')
      on conflict (id) do update set timezone = excluded.timezone;
    ${ids.map((id, index) => `insert into public.devices(id, user_id, source_kind, external_device_id)
      values ('${id}', '${user}', 'noop_push', 'whoop-EX${index}${user.slice(0, 8).toUpperCase()}');`).join('\n')}`);
  return { user, device: ids[0], devices: ids };
}
const todayIn = (zone: string) => sql(`select to_char((now() at time zone '${zone}')::date, 'YYYY-MM-DD')`);
/** Unix seconds of a local wall-clock time in the zone. */
const localTs = (zone: string, day: string, time: string) =>
  sql(`select extract(epoch from ('${day} ${time}'::timestamp at time zone '${zone}'))::bigint`).then(Number);
async function scored(user: string, device: string, day: string) {
  await sql(`insert into public.scoring_jobs_v2(user_id, device_id, day, algorithm_version, input_revision,
      completed_revision, last_completed_at)
    values ('${user}', '${device}', '${day}', 'frwhoop-server-1', 1, 1, clock_timestamp()) on conflict do nothing`);
}
function event(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    event_id: 'caffeine-1', revision: 1, kind: 'caffeine', label: 'Coffee',
    occurred: { start: 1_791_000_000, end: 1_791_000_001 }, time_precision: 'exact', recorded_at: 1_791_000_060,
    source: 'user_entered', confirmation: 'confirmed', dose_amount: 95, dose_unit: 'mg', dose_provenance: 'user_entered',
    ...over,
  };
}
const record = (user: string, body: unknown, source: string | null = null) =>
  sqlJson(`select public.record_exposure_event_v1('${user}', ${source ? `'${source}'` : 'null'}, $ex$${JSON.stringify(body)}$ex$::jsonb)`);
const exposureJobs = async (user: string) => await sqlJson(`select coalesce(json_agg(json_build_object('device', device_id,
    'day', to_char(day, 'YYYY-MM-DD'), 'mode', mode) order by device_id, day), '[]')
  from public.physiology_context_jobs where user_id = '${user}' and 'exposure_changed' = any (reasons)`);

Deno.test({
  name: 'exposure events: revision history, conflicts, invalidation, reads and validator parity on the production image',
  ignore: !container || !restUrl,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async (t) => {
    assert.match(container!, /^nara-db-server-pipeline\.[a-z0-9]+$/);
    await sql(`delete from auth.users where email like '${EMAIL_PREFIX}%'`);

    await t.step('revisions: history kept, current replaced only by a higher revision, received_at set by the server', async () => {
      const a = await owner('UTC');
      const before = Math.floor(Date.now() / 1000) - 5;
      const first = await record(a.user, { ...event(), received_at: 1 });
      assert.deepEqual([first.status, first.event_id, first.revision, first.reason], ['saved', 'caffeine-1', 1, null]);
      assert.ok(first.received_at >= before && first.received_at <= before + 120, String(first.received_at));
      // Replays and conflicts.
      const replay = await record(a.user, { ...event(), dose_amount: 95.0 });
      assert.deepEqual([replay.status, replay.reason, replay.received_at], ['ignored', 'duplicate', first.received_at]);
      const conflict = await record(a.user, event({ label: 'Tea' }));
      assert.deepEqual([conflict.status, conflict.reason], ['rejected', 'revision_conflict']);
      const edited = await record(a.user, event({ revision: 2, occurred: { start: 1_791_003_600, end: 1_791_003_601 }, dose_amount: 120 }));
      assert.equal(edited.status, 'saved');
      const stale = await record(a.user, event({ revision: 1, label: 'Decaf' }));
      assert.deepEqual([stale.status, stale.reason], ['rejected', 'stale_revision']);
      const oldReplay = await record(a.user, event());
      assert.deepEqual([oldReplay.status, oldReplay.reason], ['ignored', 'duplicate']);
      const retracted = await record(a.user, event({ revision: 5, confirmation: 'retracted', recorded_at: 1_791_009_000 }));
      assert.equal(retracted.status, 'saved', 'revisions may skip numbers');
      const current = await sqlJson(`select row_to_json(e) from public.exposure_events e where owner = '${a.user}'`);
      assert.deepEqual([current.revision, current.confirmation, current.revision_count, current.first_received_at, current.label],
        [5, 'retracted', 3, first.received_at, 'Coffee']);
      const history = await sqlJson(`select json_agg(json_build_object('revision', revision, 'confirmation', confirmation,
          'dose', dose_amount, 'start', occurred_start) order by revision) from public.exposure_event_revisions where owner = '${a.user}'`);
      assert.deepEqual(history, [
        { revision: 1, confirmation: 'confirmed', dose: 95, start: 1_791_000_000 },
        { revision: 2, confirmation: 'confirmed', dose: 120, start: 1_791_003_600 },
        { revision: 5, confirmation: 'retracted', dose: 95, start: 1_791_000_000 },
      ]);
      await sqlFails(`update public.exposure_event_revisions set label = 'x' where owner = '${a.user}'`, /exposure_event_revisions_immutable/);
      // Events are per owner: the same id under another account is a different event.
      const b = await owner('UTC');
      assert.equal((await record(b.user, event({ label: 'Tea' }))).status, 'saved');
      assert.equal(await sql(`select label from public.exposure_events where owner = '${a.user}'`), 'Coffee');
    });

    await t.step('the database accepts exactly what the edge validator accepts, with the same reason', async () => {
      const a = await owner('UTC');
      const cases: unknown[] = [
        event({ event_id: '' }), event({ event_id: '-x' }), event({ event_id: 'a b' }), event({ event_id: 'a'.repeat(129) }),
        event({ revision: 0 }), event({ revision: 1.5 }), event({ revision: '1' }), event({ revision: 2_147_483_648 }),
        event({ kind: 'coffee' }), event({ label: '' }), event({ label: 'x'.repeat(201) }), event({ label: 'a\nb' }),
        event({ label: 'a\u0085b' }), event({ occurred: null }), event({ occurred: { start: 1_791_000_000, end: 1_791_000_000 } }),
        event({ occurred: { start: 1_791_000_000, end: 1_791_000_000 + 31 * 86_400 + 1 } }),
        event({ occurred: { start: 946_684_799, end: 946_684_900 } }), event({ occurred: { start: 4_102_444_799, end: 4_102_444_801 } }),
        event({ occurred: { start: '1791000000', end: 1_791_000_001 } }), event({ time_precision: 'minute' }),
        event({ recorded_at: 946_684_799 }), event({ recorded_at: null }), event({ source: 'healthkit' }),
        event({ confirmation: 'yes' }), event({ source: 'inferred_candidate', confirmation: 'confirmed' }),
        event({ dose_amount: -1 }), event({ dose_amount: '95' }), event({ dose_amount: 1e9 + 1 }), event({ dose_unit: '' }),
        event({ dose_unit: 'm'.repeat(33) }), event({ dose_unit: 7 }), event({ dose_provenance: 'guess' }), ['x'], 'x',
        // Valid, at the boundaries.
        event({ event_id: 'ok-1', label: 'x'.repeat(200), dose_unit: 'm'.repeat(32), revision: 2_147_483_647 }),
        event({ event_id: 'ok-2', occurred: { start: 1_791_000_000, end: 1_791_000_000 + 31 * 86_400 } }),
        event({ event_id: 'ok-3', dose_amount: 0 }), event({ event_id: 'ok-4', dose_amount: 1e9 }),
        event({ event_id: 'ok-5', source: 'inferred_candidate', confirmation: 'candidate' }),
        event({ event_id: 'ok-6', label: 'Café 😀', dose_amount: null, dose_unit: null, dose_provenance: null }),
        event({ event_id: 'ok-7', time_precision: 'day_only', source: 'journal_day_answer', confirmation: 'denied' }),
        { ...event({ event_id: 'ok-8' }), dose_amount: undefined, dose_unit: undefined, dose_provenance: undefined, extra: true },
      ];
      let accepted = 0;
      for (const raw of cases) {
        const edge = validateExposureEvent(raw);
        const database = await record(a.user, raw);
        const label = JSON.stringify(raw).slice(0, 80);
        if (edge.ok) {
          accepted++;
          assert.equal(database.status, 'saved', `${label}: ${JSON.stringify(database)}`);
          // The normalised event the route sends is stored identically.
          assert.equal((await record(a.user, edge.event)).status, 'ignored', label);
        } else {
          assert.deepEqual([label, database.status, database.reason], [label, 'rejected', edge.rejection.reason]);
        }
      }
      assert.equal(accepted, 8);
      assert.equal(await sql(`select count(*) from public.exposure_events where owner = '${a.user}'`), '8');
    });

    await t.step('invalidation: closed [min start - 24 h, max end + 72 h] in the owner zone, every device, clamped to today', async () => {
      const zone = 'America/New_York';
      const a = await owner(zone, 2);
      const today = await todayIn(zone);
      await sql(`insert into public.scoring_jobs_v2(user_id, device_id, day, algorithm_version, input_revision,
          completed_revision, last_completed_at)
        select '${a.user}', d.id, g::date, 'frwhoop-server-1', 1, 1, clock_timestamp()
          from public.devices d, generate_series('${addDays(today, -40)}'::date, '${today}'::date, interval '1 day') g
         where d.user_id = '${a.user}'`);
      const reset = () => sql(`update public.physiology_context_jobs set reasons = '{}' where user_id = '${a.user}'`);
      const days = async (device = a.device) =>
        (await exposureJobs(a.user)).filter((row: any) => row.device === device).map((row: any) => row.day);
      const range = (from: string, n: number) => Array.from({ length: n }, (_, k) => addDays(from, k));

      // A one-second event at 22:00 local on x: x-1 (start - 24 h) through x+3 (end + 72 h), on every device.
      const x = addDays(today, -30);
      const start = await localTs(zone, x, '22:00:00');
      const saved = await record(a.user, event({ event_id: 'late-night', occurred: { start, end: start + 1 } }));
      assert.equal(saved.invalidated_days, 10);
      const expected = (list: string[]) => a.devices.flatMap((device) => list.map((day) => ({ device, day, mode: 'retrospective' })))
        .sort((p, q) => `${p.device}${p.day}`.localeCompare(`${q.device}${q.day}`));
      assert.deepEqual(await exposureJobs(a.user), expected(range(addDays(x, -1), 5)));

      // An event ending exactly at local midnight: the day that starts at end + 72 h is included (the end instant is
      // part of the closed range, as Exposures.refs keeps an event whose end is exactly 72 h before a measurement).
      await reset();
      const y = addDays(today, -22);
      const midnight = await localTs(zone, addDays(y, 1), '00:00:00');
      await record(a.user, event({ event_id: 'evening', occurred: { start: midnight - 3600, end: midnight } }));
      assert.deepEqual(await days(), range(addDays(y, -1), 6), 'y-1 .. y+4, where y+4 starts at end + 72 h');

      // The -24 h start: an event at 00:30 reaches back to the previous day, and no further.
      await reset();
      const z = addDays(today, -15);
      const early = await localTs(zone, z, '00:30:00');
      await record(a.user, event({ event_id: 'early', occurred: { start: early, end: early + 1 } }));
      assert.deepEqual(await days(), range(addDays(z, -1), 5), 'z-1 .. z+3');

      // A correction covers the hull of the old and new revision.
      await reset();
      const moved = await localTs(zone, addDays(today, -12), '09:00:00');
      await record(a.user, event({ event_id: 'late-night', revision: 2, occurred: { start: moved, end: moved + 1800 } }));
      assert.deepEqual(await days(a.devices[1]), range(addDays(x, -1), 23), 'x-1 .. (today - 12) + 3');

      // Today maps to the live job; days after today are never invalidated.
      await reset();
      const recent = await localTs(zone, addDays(today, -1), '12:00:00');
      await record(a.user, event({ event_id: 'recent', occurred: { start: recent, end: recent + 60 } }));
      const near = (await exposureJobs(a.user)).filter((row: any) => row.device === a.device);
      assert.deepEqual(near.map((row: any) => [row.day, row.mode]),
        [[addDays(today, -2), 'retrospective'], [addDays(today, -1), 'retrospective'], [today, 'causal_live']]);
      await reset();
      const later = await localTs(zone, addDays(today, 2), '08:00:00');
      assert.equal((await record(a.user, event({ event_id: 'future', occurred: { start: later, end: later + 1 } }))).invalidated_days, 0);
      // Tomorrow morning is within 24 h of today: today's live job is invalidated.
      const tomorrow = await localTs(zone, addDays(today, 1), '08:00:00');
      await record(a.user, event({ event_id: 'tomorrow', occurred: { start: tomorrow, end: tomorrow + 1 } }));
      assert.deepEqual(await days(), [today]);

      // Another owner's days are never touched.
      const b = await owner(zone);
      await scored(b.user, b.device, x);
      await record(a.user, event({ event_id: 'only-a', occurred: { start, end: start + 1 } }));
      assert.deepEqual(await exposureJobs(b.user), []);
    });

    await t.step('concurrent writers of one event revision: exactly one is saved, the other sees the conflict', async () => {
      const a = await owner('UTC');
      const one = psql(`begin;
        select public.record_exposure_event_v1('${a.user}', null, $ex$${JSON.stringify(event({ event_id: 'race', label: 'First' }))}$ex$::jsonb);
        select pg_sleep(1);
        commit;`);
      await new Promise((resolve) => setTimeout(resolve, 300));
      const two = psql(`select public.record_exposure_event_v1('${a.user}', null, $ex$${JSON.stringify(event({ event_id: 'race', label: 'Second' }))}$ex$::jsonb)`);
      const results = await Promise.all([one, two]);
      assert.ok(results.every((result) => result.ok), results.map((result) => result.err).join('\n'));
      const statuses = results.map((result) => JSON.parse(result.out.split('\n').filter(Boolean)[0]).status).sort();
      assert.deepEqual(statuses, ['rejected', 'saved']);
      assert.equal(await sql(`select count(*) || ':' || max(label) from public.exposure_event_revisions where owner = '${a.user}'`), '1:First');
    });

    await t.step('read: overlapping current events, history on request, owner-scoped and bounded', async () => {
      const a = await owner('UTC');
      const b = await owner('UTC');
      await record(a.user, event({ event_id: 'e1', occurred: { start: 1_791_000_000, end: 1_791_003_600 } }));
      await record(a.user, event({ event_id: 'e1', revision: 2, occurred: { start: 1_791_000_000, end: 1_791_007_200 } }));
      await record(a.user, event({ event_id: 'e2', occurred: { start: 1_791_100_000, end: 1_791_100_001 } }));
      await record(b.user, event({ event_id: 'e1', occurred: { start: 1_791_000_000, end: 1_791_003_600 } }));
      const plain = await sqlJson(`select public.exposure_events_read_v1('${a.user}', 1791005000, 1791006000, false)`);
      assert.deepEqual(plain.events.map((row: any) => [row.event_id, row.revision, row.revision_count]), [['e1', 2, 2]]);
      assert.equal(plain.revisions, null);
      assert.equal(plain.truncated, false);
      assert.deepEqual(Object.keys(plain.events[0]).sort(), ['confirmation', 'dose_amount', 'dose_provenance', 'dose_unit',
        'event_id', 'kind', 'label', 'occurred', 'received_at', 'recorded_at', 'revision', 'revision_count', 'source',
        'time_precision']);
      // Half-open: an event ending at p_from is outside, one starting at p_to - 1 inside.
      assert.deepEqual((await sqlJson(`select public.exposure_events_read_v1('${a.user}', 1791007200, 1791100001, true)`))
        .events.map((row: any) => row.event_id), ['e2']);
      const full = await sqlJson(`select public.exposure_events_read_v1('${a.user}', 1790000000, 1792000000, true)`);
      assert.deepEqual(full.events.map((row: any) => row.event_id), ['e1', 'e2']);
      assert.deepEqual(full.revisions.map((row: any) => `${row.event_id}#${row.revision}`), ['e1#1', 'e1#2', 'e2#1']);
      assert.ok(full.revisions.every((row: any) => Number.isSafeInteger(row.received_at)));
      await sqlFails(`select public.exposure_events_read_v1('${a.user}', 1, 1, false)`, /invalid_range/);
      await sqlFails(`select public.exposure_events_read_v1('${a.user}', 0, ${366 * 86400 + 1}, false)`, /invalid_range/);
      await sql(`insert into public.noop_account_retirements(user_id) values ('${b.user}')`);
      await sqlFails(`select public.exposure_events_read_v1('${b.user}', 1790000000, 1792000000, false)`, /account_retired/);
      await sqlFails(`select public.record_exposure_event_v1('${b.user}', null, $ex$${JSON.stringify(event({ event_id: 'z' }))}$ex$::jsonb)`, /account_retired/);
      await sql(`delete from public.noop_account_retirements where user_id = '${b.user}'`);
    });

    await t.step('ownership: an unknown owner and another owner\'s upload source are refused', async () => {
      const a = await owner('UTC');
      const b = await owner('UTC');
      const sourceB = crypto.randomUUID();
      await sql(`insert into public.noop_app_installations(source_id, user_id, platform, app_version, provisioning_method)
        values ('${sourceB}', '${b.user}', 'ios', '1.0 (1)', 'supabase_auth')`);
      await sqlFails(`select public.record_exposure_event_v1('${a.user}', '${sourceB}', $ex$${JSON.stringify(event())}$ex$::jsonb)`, /source_owner_mismatch/);
      await sqlFails(`select public.record_exposure_event_v1('${crypto.randomUUID()}', null, $ex$${JSON.stringify(event())}$ex$::jsonb)`, /invalid_owner/);
      assert.equal((await record(b.user, event(), sourceB)).status, 'saved');
      assert.equal(await sql(`select upload_source_id from public.exposure_event_revisions where owner = '${b.user}'`), sourceB);
      await sql(`delete from auth.users where id = '${b.user}'`);
      assert.equal(await sql(`select count(*) from public.exposure_event_revisions where owner = '${b.user}'`), '0');
    });

    await sql(`delete from auth.users where email like '${EMAIL_PREFIX}%'`);
  },
});
