-- Run after 20261009180000_manual_events.sql and 20261009180100_manual_event_context.sql against a TEST
-- database. All fixtures roll back.
BEGIN;
INSERT INTO auth.users(id) VALUES ('11111111-1111-4111-8111-111111111111'), ('22222222-2222-4222-8222-222222222222');
INSERT INTO public.compute_account_sources(source_id, user_id) VALUES
 ('33333333-3333-4333-8333-333333333333','11111111-1111-4111-8111-111111111111'),
 ('44444444-4444-4444-8444-444444444444','22222222-2222-4222-8222-222222222222');

CREATE TEMP TABLE event_fixture(body jsonb);
INSERT INTO event_fixture VALUES ('{"revision_id":"55555555-5555-4555-8555-555555555555","updated_at_ms":1791000000000,"entry":{"id":"66666666-6666-4666-8666-666666666666","kind":"event","label":"Walking","symbol":"figure.walk","typeId":"33333333-3333-4333-8333-333333333333","favorite":false,"startUnixSeconds":1791000000,"endUnixSeconds":1791000300,"timeZoneIdentifier":"UTC","archived":false}}');
GRANT SELECT, UPDATE ON event_fixture TO service_role;

SET LOCAL ROLE service_role;
SELECT public.append_manual_event_revisions('11111111-1111-4111-8111-111111111111',
 '33333333-3333-4333-8333-333333333333', (SELECT jsonb_build_array(body) FROM event_fixture));
-- Identical retries store one row. The same revision UUID is allowed for another owner.
SELECT public.append_manual_event_revisions('11111111-1111-4111-8111-111111111111',
 '33333333-3333-4333-8333-333333333333', (SELECT jsonb_build_array(body) FROM event_fixture));
SELECT public.append_manual_event_revisions('22222222-2222-4222-8222-222222222222',
 '44444444-4444-4444-8444-444444444444', (SELECT jsonb_build_array(body) FROM event_fixture));
DO $$ BEGIN
  IF (SELECT count(*) FROM public.manual_event_revisions) <> 2 THEN RAISE EXCEPTION 'retry lost idempotency'; END IF;
  BEGIN
    PERFORM public.append_manual_event_revisions('11111111-1111-4111-8111-111111111111',
      '44444444-4444-4444-8444-444444444444', (SELECT jsonb_build_array(body) FROM event_fixture));
    RAISE EXCEPTION 'source theft accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  -- A conflicting UUID is refused on its own (20261008100000), never stored over the original.
  IF (SELECT public.append_manual_event_revisions('11111111-1111-4111-8111-111111111111',
        '33333333-3333-4333-8333-333333333333',
        (SELECT jsonb_build_array(jsonb_set(body, '{entry,label}', '"Changed"')) FROM event_fixture))
      #>> '{rejected,0,reason}') IS DISTINCT FROM 'revision_conflict'
     OR (SELECT body #>> '{entry,label}' FROM public.manual_event_revisions
          WHERE user_id = '11111111-1111-4111-8111-111111111111') <> 'Walking' THEN
    RAISE EXCEPTION 'revision was overwritten';
  END IF;
END $$;

UPDATE event_fixture SET body = jsonb_set(jsonb_set(jsonb_set(jsonb_set(body,
 '{revision_id}', '"77777777-7777-4777-8777-777777777777"'), '{updated_at_ms}', '1791000400000'),
 '{entry,archived}', 'true'), '{entry,archivedAt}', '1791000400');
SELECT public.append_manual_event_revisions('11111111-1111-4111-8111-111111111111',
 '33333333-3333-4333-8333-333333333333', (SELECT jsonb_build_array(body) FROM event_fixture));
DO $$ BEGIN
  IF (SELECT count(*) FROM public.manual_event_revisions WHERE user_id = '11111111-1111-4111-8111-111111111111') <> 2
    THEN RAISE EXCEPTION 'archive erased the original'; END IF;
  BEGIN DELETE FROM public.manual_event_revisions; RAISE EXCEPTION 'service can delete labels';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN UPDATE public.manual_event_revisions SET body = '{}'; RAISE EXCEPTION 'service can change labels';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
DO $$ BEGIN
  IF (SELECT count(*) FROM public.manual_event_revisions) <> 2 THEN RAISE EXCEPTION 'owner cannot read own history'; END IF;
  IF EXISTS (SELECT 1 FROM public.manual_event_revisions WHERE user_id = '22222222-2222-4222-8222-222222222222')
    THEN RAISE EXCEPTION 'cross-account read'; END IF;
  BEGIN DELETE FROM public.manual_event_revisions; RAISE EXCEPTION 'client can delete';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN UPDATE public.manual_event_revisions SET body = '{}'; RAISE EXCEPTION 'client can update';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    PERFORM public.append_manual_event_revisions('22222222-2222-4222-8222-222222222222',
      '44444444-4444-4444-8444-444444444444', '[]'); RAISE EXCEPTION 'client can invoke privileged writer';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$ BEGIN
  BEGIN PERFORM count(*) FROM public.manual_event_revisions; RAISE EXCEPTION 'anonymous can read';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
ROLLBACK;
