-- Client privilege hardening for the multi-user hosted backend.
--
-- Nothing in the app talks to PostgREST directly: every request goes through an Edge Function that
-- authenticates the caller and then reads or writes with the service role, and the few RPCs a signed-in
-- client may call derive the owner from auth.uid(). Row level security is therefore the second line of
-- defence. These changes make that second line narrower and do not touch the first, so no existing
-- behaviour changes for the service role, the worker, or a signed-in person's own rows.
--
--   1. `anon` (a request carrying only the publishable key) gets no privilege on any public table, view
--      or sequence. Supabase grants it all of them by default and leaves RLS as the only guard.
--   2. `authenticated` loses TRUNCATE, REFERENCES and TRIGGER on public relations. RLS does not govern
--      TRUNCATE at all, and none of the three is needed to read or write a person's own rows.
--   3. Policies whose only purpose is to admit the service role now apply to service_role instead of to
--      PUBLIC. service_role bypasses RLS, so nothing changes for it. For every other role such a policy
--      never matched, but it was still OR-ed into every query's filter, which stops the planner using the
--      owner index on an unfiltered read of a large table.
--   4. Default privileges stop re-granting (1) and (2) on relations created from here on.
--
-- Rollback: `grant all on all tables in schema public to anon`, grant truncate, references, trigger back
-- to authenticated, and `alter policy <name> on <table> to public` for each cmd = ALL policy whose
-- predicate is `auth.role() = 'service_role'` and that now applies to service_role. The default privileges
-- can be restored with the matching `alter default privileges ... grant`.
begin;
set local lock_timeout = '10s';
set local statement_timeout = '120s';

revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke truncate, references, trigger on all tables in schema public from authenticated;

alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke truncate, references, trigger on tables from authenticated;

do $$
declare
  p record;
begin
  for p in
    select schemaname, tablename, policyname
      from pg_policies
     where schemaname = 'public'
       and cmd = 'ALL'
       and roles = '{public}'::name[]
       and qual = '(auth.role() = ''service_role''::text)'
       and with_check = '(auth.role() = ''service_role''::text)'
  loop
    execute format('alter policy %I on %I.%I to service_role', p.policyname, p.schemaname, p.tablename);
  end loop;
end $$;

commit;
