-- Internal SECURITY DEFINER functions must not be callable through the public API.
--
-- On Supabase, every function created in `public` by a migration is granted EXECUTE to `anon` and
-- `authenticated` by default privileges. `revoke ... from public` removes only the PUBLIC pseudo-role's
-- grant, not those two explicit ones, so a function meant for the service role alone stays reachable at
-- /rest/v1/rpc/<name> with nothing but the publishable key.
--
-- Two internal functions were left that way. Neither checks who is calling:
--
--   * noop_push_consume_ingest_quota(p_user_id, ...) charges an upload against ANY user's ingest quota. With
--     self-service sign-up, any account could burn another account's quota window and make that account's
--     uploads fail with ingest_quota_exceeded.
--   * http_post_worker(fn_path) POSTs to the worker base URL with the worker secret from Vault as the
--     bearer, so an anonymous caller could trigger worker runs on demand.
--
-- Both are only ever called by the `push` Edge function (service role) and pg_cron (postgres), neither of
-- which depends on the client roles' grants. service_role keeps EXECUTE.
begin;

do $$
declare
  target regprocedure;
begin
  foreach target in array array[
    to_regprocedure('public.noop_push_consume_ingest_quota(uuid,bigint,integer,bigint,integer)'),
    to_regprocedure('public.http_post_worker(text)')
  ] loop
    if target is not null then
      execute format('revoke all on function %s from public, anon, authenticated', target);
      execute format('grant execute on function %s to service_role', target);
    end if;
  end loop;
end $$;

commit;
