import { assert, assertEquals } from 'jsr:@std/assert';
import { startLocalPostgres, USER_A } from './local_postgres.ts';
import { handleCoachRequest, coachConfig } from '../_shared/coach.ts';
import { hashIngestToken } from '../_shared/tokens.ts';

// G1/C2 profile timezone (spec §3 time contract + §2): the app sends the phone-local IANA
// zone in the profile payload; coach.ts must persist and echo it so the server never stays
// at 'UTC' and the phone reconcile sees the stored value.
//
// End-to-end proof against the REAL database authority: the chain below loads the real
// `scoring_record_timezone` function + the `scoring_profile_timezone` trigger on
// public.profiles (defined in 20260918010000, create-or-replaced by 18050000/18100000),
// which validates every profile timezone write against pg_timezone_names. The edge route
// surfaces that trigger's rejection as a 400.

const USER = USER_A;
const SOURCE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const CODE = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const TOKEN = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const FLEET = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

const TZ_CHAIN = [
  '20260918010000_physiology_revisions.sql',
  '20260918020000_physiology_publication.sql',
  '20260918030000_physiology_hrv_dependencies.sql',
  '20260918040000_rr_packet_provenance.sql',
  '20260918050000_physiology_calendar_ownership.sql',
  '20260918100000_physiology_independent_work.sql',
];

function profileRequest(body?: unknown, bearer = 'noop_personal', fleet = 'noop_fleet') {
  return new Request('https://test.invalid/functions/v1/coach/profile', {
    method: body === undefined ? 'GET' : 'PUT',
    headers: { authorization: `Bearer ${bearer}`, 'x-noop-fleet-token': fleet, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

Deno.test('profile timezone: PUT round-trips via the real pg_timezone_names trigger, invalid zones 400, null tolerated', {
  sanitizeOps: false,
  sanitizeResources: false,
}, async () => {
  const db = await startLocalPostgres({ installationLifecycle: true });
  try {
    const sql = db.sql;
    for (const name of TZ_CHAIN) {
      const text = await Deno.readTextFile(new URL(`../../migrations/${name}`, import.meta.url));
      await sql(text);
    }
    // Prove the REAL trigger is loaded and live on profiles before the route tests run.
    const trig = await sql(`select tgname from pg_trigger
        where tgrelid='public.profiles'::regclass and tgname='scoring_profile_timezone'`);
    assertEquals(trig.trim(), 'scoring_profile_timezone', 'real timezone trigger must be attached');

    // Enrollment (codes -> installations -> tokens).
    await sql(`insert into public.noop_enrollment_codes(id,user_id,code_hash,expires_at)
        values ('${CODE}','${USER}','${'a'.repeat(64)}', now() + interval '1 day');`);
    await sql(`insert into public.noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version)
        values ('${SOURCE}','${USER}','${CODE}','ios','1.0.0');`);
    await sql(`insert into public.noop_ingest_tokens(id,user_id,source_id,token_hash,token_kind,enrollment_code_id)
        values ('${TOKEN}','${USER}','${SOURCE}','${hashIngestToken('noop_personal')}','installation','${CODE}'),
               ('${FLEET}','${USER}',null,'${hashIngestToken('noop_fleet')}','fleet',null);`);
    const cfg = coachConfig({});
    const storedZone = async () => (await sql(`select timezone from public.profiles where id='${USER}'`)).trim();

    async function get() {
      return handleCoachRequest(profileRequest(), { rest: db.rest as any, cfg });
    }
    async function put(body: unknown) {
      return handleCoachRequest(profileRequest(body), { rest: db.rest as any, cfg });
    }

    // 0. The sign-up row exists with the default zone; GET works and echoes it (back-compat
    //    with the added timezone column on an old row).
    let res = await get();
    assertEquals(res.status, 200, 'profile GET must succeed');
    let payload: any = await res.json();
    assertEquals(payload.profile.timezone, 'UTC');
    assertEquals(await storedZone(), 'UTC');

    // 1. PUT a REAL IANA zone through the route: the DB trigger must ACCEPT it, the stored
    //    value must round-trip, and a fresh GET must echo the same value.
    res = await put({ timezone: 'America/Los_Angeles' });
    assertEquals(res.status, 200, 'valid zone PUT must be accepted: ' + await res.clone().text());
    payload = await res.json();
    assertEquals(payload.profile.timezone, 'America/Los_Angeles', 'PUT response echoes the stored zone');
    assertEquals(await storedZone(), 'America/Los_Angeles', 'stored profiles.timezone round-trips');
    assertEquals((await sql(`select count(*) from pg_timezone_names where name='America/Los_Angeles'`)).trim(), '1');
    res = await get();
    assertEquals(res.status, 200, 'profile GET must succeed');
    assertEquals((await res.json()).profile.timezone, 'America/Los_Angeles', 'GET read-back echoes the stored zone');

    // 2. A SECOND valid zone on UPDATE: proves the trigger fires on the update path too and
    //    accepts another real IANA id (the client reconcile sees the latest stored value).
    res = await put({ timezone: 'Asia/Kolkata' });
    assertEquals(res.status, 200, 'second valid zone PUT must be accepted: ' + await res.clone().text());
    assertEquals((await res.json()).profile.timezone, 'Asia/Kolkata');
    assertEquals(await storedZone(), 'Asia/Kolkata');
    assertEquals((await sql(`select count(*) from pg_timezone_names where name='Asia/Kolkata'`)).trim(), '1');

    // 3. INVALID zone string through the route -> 400 invalid_profile. 'Not/AZone' is
    //    syntactically plausible (passes coach.ts's shape gate) but is NOT a real IANA id,
    //    so the pg_timezone_names authority (scoring_record_timezone trigger) rejects it and
    //    the route maps that rejection to 400. The stored value must be untouched.
    res = await put({ timezone: 'Not/AZone' });
    assertEquals(res.status, 400, 'unknown zone must be rejected by the DB authority');
    assertEquals((await res.json()).error, 'invalid_profile');
    assertEquals(await storedZone(), 'Asia/Kolkata', 'rejected zone must not modify the stored value');

    // 4. Shape-invalid string (space + bang) is rejected at the edge before the database.
    res = await put({ timezone: 'Not A Zone!' });
    assertEquals(res.status, 400);
    assertEquals((await res.json()).error, 'invalid_profile');
    assertEquals(await storedZone(), 'Asia/Kolkata');

    // 5. Null timezone is a no-change (accepted, nothing written) when other fields exist.
    res = await put({ timezone: null, displayName: 'Nara Tester' });
    assertEquals(res.status, 200, 'profile PUT must succeed');
    payload = await res.json();
    assertEquals(payload.profile.timezone, 'Asia/Kolkata');
    assertEquals(payload.profile.displayName, 'Nara Tester');
    assertEquals(await storedZone(), 'Asia/Kolkata');

    // 6. Back-compat: a row whose timezone is NULL (schema dropped NOT NULL for this check)
    //    still returns a profile; publicProfile tolerates the null instead of erroring.
    await sql(`alter table public.profiles alter column timezone drop not null;`);
    await sql(`drop trigger scoring_profile_timezone on public.profiles;`);
    await sql(`update public.profiles set timezone=null where id='${USER}';`);
    res = await get();
    assertEquals(res.status, 200, 'profile GET must succeed');
    payload = await res.json();
    assertEquals(payload.profile.timezone, null);
    assert(payload.profile.displayName === 'Nara Tester', 'other profile fields still decode');
  } finally {
    await db.close();
  }
});
