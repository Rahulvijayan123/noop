-- Deployed definition for public.noop_claim_object_verification
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:23.126768
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='noop_claim_object_verification';"
CREATE OR REPLACE FUNCTION public.noop_claim_object_verification(p_max_bytes bigint DEFAULT 268435456, p_max_decoded_bytes bigint DEFAULT 536870912)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare d public.noop_object_verification_debt; m public.object_manifests; token uuid:=gen_random_uuid(); owner uuid; previous_lane text;
begin
  -- Inspect at most 128 due owners per claim. Idle owners back off, and a busy owner
  -- goes to the back of the due queue. Both scans have matching partial indexes.
  for owner,previous_lane in select s.user_id,s.last_lane from public.noop_verification_owner_service s
    where s.next_poll_at<=now() order by s.next_poll_at,s.last_claimed_at nulls first,s.user_id
    for update of s skip locked limit 128 loop
    select v.* into d from public.noop_object_verification_debt v join public.object_manifests o on o.id=v.object_id
      where v.user_id=owner and o.user_id=v.user_id and v.state in ('pending','retry','leased')
        and v.next_attempt_at<=now() and (v.state<>'leased' or v.lease_until<=now())
        and o.status not in ('deleted','deleting','expired') and o.compressed_bytes>0
        and o.compressed_bytes<=least(greatest(p_max_bytes,0),268435456)
        and coalesce(o.uncompressed_bytes,536870912)<=least(greatest(p_max_decoded_bytes,0),536870912)
        and not exists(select 1 from public.noop_object_copy_intents c where c.object_id=o.id and c.state='copying' and c.lease_until>now())
      order by case when (o.end_at>now()-interval '10 minutes')=(previous_lane is distinct from 'live') then 0 else 1 end,
        v.next_attempt_at,v.requested_at,v.object_id for update of v skip locked limit 1;
    exit when found;
    update public.noop_verification_owner_service set next_poll_at=now()+interval '10 seconds' where user_id=owner;
  end loop;
  if d.object_id is null then return null; end if;
  select * into m from public.object_manifests where id=d.object_id and user_id=d.user_id;
  if not found then return null; end if;
  update public.noop_verification_owner_service set last_claimed_at=clock_timestamp(),next_poll_at=clock_timestamp(),
    last_lane=case when m.end_at>now()-interval '10 minutes' then 'live' else 'history' end where user_id=owner;
  update public.noop_object_verification_debt set state='leased',lease_token=token,
    lease_until=now()+interval '10 minutes',attempts=attempts+1,
    retry_attempts=retry_attempts+case when d.state='retry' then 1 else 0 end,
    lease_recoveries=lease_recoveries+case when d.state='leased' then 1 else 0 end,
    updated_at=now() where object_id=d.object_id;
  return jsonb_build_object('objectId',d.object_id,'token',token,'manifest',to_jsonb(m));
end $function$

