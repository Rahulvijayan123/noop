-- What the client roles can reach, asserted against a live (or local) database.
--
-- Read-only: run it against production inside a read-only transaction, for example
--   (echo 'begin read only;'; cat supabase/tests/client-privileges.sql; echo 'rollback;') \
--     | psql "$DB_URL" -X -v ON_ERROR_STOP=1
-- Every check raises with a message naming what it found, so a regression is visible at once. It prints
-- one `ok` line when every check passes.
--
-- The person-isolation guarantee is: no signed-in client can read or write another person's rows. These
-- checks pin the database half of it, so a later migration cannot quietly widen what `anon` or
-- `authenticated` may touch.

do $$
declare
  n integer;
  names text;
begin
  select count(*), string_agg(c.relname, ', ' order by c.relname) into n, names
    from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'f')
     and has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER');
  if n > 0 then
    raise exception 'anon holds privileges on % public relation(s): %', n, left(names, 400);
  end if;

  select count(*), string_agg(c.relname, ', ' order by c.relname) into n, names
    from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'f')
     and has_table_privilege('authenticated', c.oid, 'TRUNCATE,REFERENCES,TRIGGER');
  if n > 0 then
    raise exception 'authenticated can TRUNCATE/REFERENCE/TRIGGER % public relation(s): %', n, left(names, 400);
  end if;
end $$;

do $$
declare
  n integer;
  names text;
begin
  select count(*), string_agg(c.relname, ', ' order by c.relname) into n, names
    from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity;
  if n > 0 then
    raise exception 'row level security is off on % public table(s): %', n, left(names, 400);
  end if;

  select count(*), string_agg(c.relname, ', ' order by c.relname) into n, names
    from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relkind = 'v'
     and has_table_privilege('authenticated', c.oid, 'SELECT')
     and coalesce((select option_value from pg_options_to_table(c.reloptions)
                    where option_name = 'security_invoker'), 'false') <> 'true';
  if n > 0 then
    raise exception 'client-readable view(s) run as their owner and would bypass RLS: %', left(names, 400);
  end if;

  select count(*), string_agg(c.relname, ', ' order by c.relname) into n, names
    from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname in ('internal', 'private') and c.relkind in ('r', 'p', 'v', 'm', 'f', 'S')
     and (has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
          or has_table_privilege('authenticated', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'));
  if n > 0 then
    raise exception 'a client role can reach internal relation(s): %', left(names, 400);
  end if;
end $$;

do $$
declare
  n integer;
  names text;
begin
  select count(*), string_agg(tablename || '.' || policyname, ', ' order by tablename) into n, names
    from pg_policies
   where schemaname = 'public'
     and ('public' = any (roles) or 'anon' = any (roles))
     and coalesce(qual, '') = '(auth.role() = ''service_role''::text)';
  if n > 0 then
    raise exception 'service-only polic(ies) still apply to PUBLIC or anon: %', left(names, 400);
  end if;

  select count(*), string_agg(tablename || '.' || policyname, ', ' order by tablename) into n, names
    from pg_policies
   where schemaname = 'public' and 'anon' = any (roles);
  if n > 0 then
    raise exception 'polic(ies) are written for anon: %', left(names, 400);
  end if;
end $$;

do $$
declare
  n integer;
  names text;
  allowed text[] := array[
    'continue_legacy_physiology_sleep_override', 'get_scoring_history_input_head_v3',
    'get_scoring_history_input_v3', 'get_server_score_snapshot_v2', 'physiology_feature_is_canonical',
    'physiology_owned_sleep_overrides', 'physiology_processing_metadata', 'physiology_required_revision',
    'physiology_shadow_model_for_day', 'put_scoring_history_input_v3',
    'scoring_legacy_minimum_readable_revision', 'select_physiology_source', 'server_scoring_read_contract',
    'set_physiology_sleep_override', 'set_placement_interval'];
begin
  select count(*), string_agg(p.proname, ', ' order by p.proname) into n, names
    from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.prokind in ('f', 'p') and p.prosecdef
     and has_function_privilege('anon', p.oid, 'EXECUTE');
  if n > 0 then
    raise exception 'anon can execute SECURITY DEFINER function(s): %', left(names, 400);
  end if;

  select count(*), string_agg(distinct p.proname, ', ') into n, names
    from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.prokind in ('f', 'p') and p.prosecdef
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and p.proname <> all (allowed);
  if n > 0 then
    raise exception 'a signed-in client can execute SECURITY DEFINER function(s) that were not reviewed: %',
      left(names, 400);
  end if;

  -- A client-callable function that takes an owner must compare it with the caller.
  select count(*), string_agg(distinct p.proname, ', ') into n, names
    from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.prokind in ('f', 'p') and p.prosecdef
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and pg_get_function_identity_arguments(p.oid) ~ '\m(p_user|p_owner)\M'
     and pg_get_functiondef(p.oid) !~ 'auth\.uid\(\)';
  if n > 0 then
    raise exception 'owner-parameter function(s) never check the caller: %', left(names, 400);
  end if;
end $$;

do $$
declare
  n integer;
begin
  select count(*) into n from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relname = 'noop_hr_samples'
     and has_table_privilege('service_role', c.oid, 'SELECT,INSERT,UPDATE,DELETE');
  if n <> 1 then
    raise exception 'service_role lost its access to the application tables';
  end if;

  if not exists (select 1 from pg_roles where rolname = 'service_role' and rolbypassrls) then
    raise exception 'service_role no longer bypasses RLS: the service-only policies are now load bearing';
  end if;

  select count(*) into n
    from pg_default_acl d
    join pg_namespace s on s.oid = d.defaclnamespace
    cross join lateral aclexplode(d.defaclacl) a
    join pg_roles g on g.oid = a.grantee
   where s.nspname = 'public' and d.defaclrole = 'postgres'::regrole and d.defaclobjtype in ('r', 'S')
     and (g.rolname = 'anon'
          or (g.rolname = 'authenticated' and a.privilege_type in ('TRUNCATE', 'REFERENCES', 'TRIGGER')));
  if n > 0 then
    raise exception 'default privileges still grant anon/authenticated broad access on new relations';
  end if;
end $$;

select 'client-privileges: ok' as result;
