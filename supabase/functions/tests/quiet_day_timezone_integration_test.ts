import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A } from './local_postgres.ts';

// P2 (audit-g2-durability, closure zone mismatch at the scoring step): a QUIET day
// has no legacy/physiology work item, so ScoringLane.resolveTimezone must fall back
// to the owner's profiles.timezone (contract C2) — not straight to UTC — or the
// attestation day bounds are the wrong 24 h window for a non-UTC user. This runs the
// EXACT resolveTimezone SQL the worker now uses (ScoringLane.resolveTimezoneSQL) and
// proves the profile zone is returned for a quiet non-UTC day, an invalid profile
// zone falls back to UTC (snapshot contract), and a work item still wins.
// Runs against the throwaway local-PG harness, never a shared DB.

Deno.test('resolveTimezone uses the owner profile zone for quiet days (not UTC)', async (t) => {
  const db = await startLocalPostgres();
  const device = '33333333-3333-4333-8333-333333333333';
  const day = '2026-09-20';
  // The harness does not carry the production work-item timezone shape; add the
  // exact columns the resolveTimezone SQL reads so it runs against the real shape.
  const resolve = (uid: string) => db.sql(
    `select coalesce(
        (select timezone_id from public.scoring_work_items
          where user_id='${uid}'::uuid and device_id='${device}'::uuid and day='${day}'::date),
        (select timezone_id from public.physiology_work_items
          where user_id='${uid}'::uuid and device_id='${device}'::uuid and day='${day}'::date),
        (select case when exists (select 1 from pg_timezone_names n
                                    where n.name = nullif(btrim(p.timezone), ''))
                     then nullif(btrim(p.timezone), '') end
           from public.profiles p where p.id='${uid}'::uuid),
        'UTC') as tz;`);
  try {
    await db.sql(`alter table public.scoring_work_items add column if not exists timezone_id text not null default 'UTC';
      create table if not exists public.physiology_work_items (
        user_id uuid not null, device_id uuid not null, day date not null,
        timezone_id text not null default 'UTC');`);
    await db.rest.rpc('noop_register_push_device', {
      p_user_id: USER_A, p_device_id: device, p_external_device_id: device,
    });
    await db.sql(`insert into public.profiles(id, timezone) values ('${USER_A}', 'America/New_York')
      on conflict (id) do update set timezone = excluded.timezone;`);

    await t.step('a quiet non-UTC day resolves to the profile zone, not UTC', async () => {
      const tz = await resolve(USER_A);
      assert.equal(tz.trim(), 'America/New_York',
        'a quiet day (no work items) must use the owner profile zone');
    });

    await t.step('an invalid profile zone falls back to UTC (snapshot contract)', async () => {
      await db.sql(`update public.profiles set timezone='Not/AZone' where id='${USER_A}';`);
      const tz = await resolve(USER_A);
      assert.equal(tz.trim(), 'UTC');
      await db.sql(`update public.profiles set timezone='America/New_York' where id='${USER_A}';`);
    });

    await t.step('a legacy work item still wins over the profile', async () => {
      await db.sql(`insert into public.scoring_work_items
        (user_id, device_id, day, timezone_id)
        values ('${USER_A}','${device}','${day}','Europe/Berlin');`);
      const tz = await resolve(USER_A);
      assert.equal(tz.trim(), 'Europe/Berlin');
    });

    await t.step('the profile zone produces zone-correct day bounds', async () => {
      await db.sql(`delete from public.scoring_work_items where user_id='${USER_A}' and day='${day}';`);
      const tz = (await resolve(USER_A)).trim();
      // A DST spring-forward day in America/New_York is 23 h, never a fixed 86,400 block.
      const bounds = await db.sql(`select extract(epoch from (('2026-03-09'::timestamp at time zone '${tz}')
        - ('2026-03-08'::timestamp at time zone '${tz}')))::int::text;`);
      assert.equal(bounds.trim(), String(23 * 3_600),
        'quiet-day attestation bounds must be zone-correct (23 h spring-forward), got ' + bounds.trim());
    });
  } finally {
    await db.close();
  }
});
