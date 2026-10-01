-- Deployed definition for public.noop_finish_object_verification
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:23.694623
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='noop_finish_object_verification';"
CREATE OR REPLACE FUNCTION public.noop_finish_object_verification(p_object_id uuid, p_lease_token uuid, p_failure_code text DEFAULT NULL::text, p_failure_status integer DEFAULT 503, p_retryable boolean DEFAULT true, p_verification_ms integer DEFAULT 0)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare d public.noop_object_verification_debt; r jsonb; code text;
begin
  select * into d from public.noop_object_verification_debt where object_id=p_object_id for update;
  if not found or d.lease_token is distinct from p_lease_token then return false; end if;
  if d.state='complete' then return true; end if;
  if d.state <> 'leased' or d.lease_until<=now() then return false; end if;
  r := public.noop_current_object_receipt(d.user_id,d.object_id);
  if r is not null then
    update public.noop_object_verification_debt set state='complete',completed_at=now(),updated_at=now(),lease_until=null,
      receipt_indexed_at=(r->>'indexedAt')::timestamptz,failure_code=null,failure_status=null,
      verification_ms=greatest(0,p_verification_ms) where object_id=d.object_id;
  else
    code := case when p_failure_code in ('object_missing','size_mismatch','decoded_size_mismatch','digest_mismatch',
      'invalid_compressed_object','unsupported_compression','invalid_object_size','object_unavailable','device_owner_conflict',
      'copy_attempt_limit','verification_failed','receipt_failed','receipt_mismatch','invalid_auxiliary_identity') then p_failure_code else 'verification_failed' end;
    update public.noop_object_verification_debt set state=case when p_retryable then 'retry' else 'paused_terminal' end,
      failures=failures+1,failure_code=code,failure_status=case when p_failure_status between 400 and 599 then p_failure_status else 503 end,
      next_attempt_at=now()+make_interval(secs=>greatest(1,random()*least(3600,5*power(2,least(d.failures+1,10))))),
      lease_until=null,updated_at=now(),verification_ms=greatest(0,p_verification_ms) where object_id=d.object_id;
  end if;
  return true;
end;
$function$

