-- Manual labels, event types and presets: append-only, account-owned snapshots.
-- An archive is another snapshot. The app and authenticated role have no delete/update access.
CREATE TABLE IF NOT EXISTS public.manual_event_revisions (
  seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  source_id uuid NOT NULL,
  revision_id uuid NOT NULL,
  entity_id uuid NOT NULL,
  updated_at_ms bigint NOT NULL CHECK (updated_at_ms > 0 AND updated_at_ms <= 32503680000000),
  body jsonb NOT NULL CHECK (jsonb_typeof(body) = 'object' AND octet_length(body::text) <= 16384),
  received_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, revision_id),
  CHECK ((body->>'revision_id')::uuid = revision_id AND body ? 'revision_id'),
  CHECK ((body->'entry'->>'id')::uuid = entity_id AND body->'entry' ? 'id'),
  CHECK ((body->>'updated_at_ms')::bigint = updated_at_ms AND body ? 'updated_at_ms'),
  CHECK (body->'entry'->>'kind' IS NOT NULL AND body->'entry'->>'kind' IN ('event', 'event_type', 'preset')),
  CHECK (body->'entry'->>'label' IS NOT NULL AND char_length(btrim(body->'entry'->>'label')) BETWEEN 1 AND 100),
  CHECK (jsonb_typeof(body->'entry'->'archived') = 'boolean' AND body->'entry' ? 'archived')
);
CREATE INDEX IF NOT EXISTS manual_event_revisions_owner_seq ON public.manual_event_revisions(user_id, seq);
CREATE INDEX IF NOT EXISTS manual_event_revisions_owner_entity ON public.manual_event_revisions(user_id, entity_id, updated_at_ms);
ALTER TABLE public.manual_event_revisions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS manual_events_owner_read ON public.manual_event_revisions;
CREATE POLICY manual_events_owner_read ON public.manual_event_revisions FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));
REVOKE ALL ON public.manual_event_revisions FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.manual_event_revisions TO authenticated;
GRANT SELECT, INSERT ON public.manual_event_revisions TO service_role;
REVOKE ALL ON SEQUENCE public.manual_event_revisions_seq_seq FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SEQUENCE public.manual_event_revisions_seq_seq TO service_role;

CREATE OR REPLACE FUNCTION public.append_manual_event_revisions(p_user uuid, p_source uuid, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp AS $$
DECLARE item jsonb; previous jsonb; saved jsonb := '[]'::jsonb;
BEGIN
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) > 25 THEN
    RAISE EXCEPTION 'invalid_manual_events';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.noop_app_installations
                 WHERE user_id = p_user AND source_id = p_source AND revoked_at IS NULL)
     AND NOT EXISTS (SELECT 1 FROM public.compute_account_sources
                     WHERE user_id = p_user AND source_id = p_source AND revoked_at IS NULL) THEN
    RAISE EXCEPTION 'manual_events_source_mismatch' USING ERRCODE = '42501';
  END IF;
  -- Serialize inserts per owner before assigning sequence numbers: pagination cannot skip a late commit.
  PERFORM pg_advisory_xact_lock(hashtextextended('manual-events:' || p_user::text, 0));
  FOR item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF jsonb_typeof(item->'entry') IS DISTINCT FROM 'object'
       OR item->'entry'->>'kind' IS NULL OR item->'entry'->>'kind' NOT IN ('event', 'event_type', 'preset')
       OR item->'entry'->>'label' IS NULL OR char_length(btrim(item->'entry'->>'label')) NOT BETWEEN 1 AND 100
       OR octet_length(item::text) > 16384 THEN
      RAISE EXCEPTION 'invalid_manual_event';
    END IF;
    SELECT body INTO previous FROM public.manual_event_revisions
      WHERE user_id = p_user AND revision_id = (item->>'revision_id')::uuid;
    IF FOUND AND previous IS DISTINCT FROM item THEN
      RAISE EXCEPTION 'manual_event_revision_conflict' USING ERRCODE = '23505';
    END IF;
    INSERT INTO public.manual_event_revisions(user_id, source_id, revision_id, entity_id, updated_at_ms, body)
      VALUES(p_user, p_source, (item->>'revision_id')::uuid, (item->'entry'->>'id')::uuid,
             (item->>'updated_at_ms')::bigint, item)
      ON CONFLICT(user_id, revision_id) DO NOTHING;
    saved := saved || jsonb_build_array(item->>'revision_id');
  END LOOP;
  RETURN jsonb_build_object('saved', saved);
END;
$$;
REVOKE ALL ON FUNCTION public.append_manual_event_revisions(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.append_manual_event_revisions(uuid, uuid, jsonb) TO service_role;

-- Existing account-deletion rules still apply through auth.users; event-level deletion is unavailable.
COMMENT ON TABLE public.manual_event_revisions IS 'Immutable manual labels, types, presets and archives. No event deletion endpoint.';
