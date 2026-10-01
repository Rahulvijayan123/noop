-- Deployed definition for public.noop_claim_projection_debt
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:20.375241
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='noop_claim_projection_debt';"
CREATE OR REPLACE FUNCTION public.noop_claim_projection_debt()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare d public.noop_projection_debt; m public.object_manifests; owner uuid; previous_lane text;
begin
  for owner,previous_lane in select s.user_id,s.last_lane from public.noop_projection_owner_service s
    where s.next_poll_at<=now() order by s.next_poll_at,s.last_claimed_at nulls first,s.user_id
    for update of s skip locked limit 128 loop
    select q.* into d from public.noop_projection_debt q join public.object_manifests o on o.id=q.object_id
      where q.user_id=owner and o.user_id=q.user_id and q.state='pending' and q.not_before<=now()
        and (q.lease_until is null or q.lease_until<=now())
        and o.status in ('ready','verified') and o.durability_receipt->>'state'='verified_indexed'
      order by case when (o.end_at>now()-interval '10 minutes')=(previous_lane is distinct from 'live') then 0 else 1 end,
        q.not_before,q.created_at,q.object_id for update of q skip locked limit 1;
    exit when found;
    update public.noop_projection_owner_service set next_poll_at=now()+interval '10 seconds' where user_id=owner;
  end loop;
  if d.object_id is null then return null; end if;
  update public.noop_projection_debt set lease_token=gen_random_uuid(),lease_until=now()+interval '2 minutes'
    where object_id=d.object_id returning * into d;
  select * into m from public.object_manifests where id=d.object_id;
  update public.noop_projection_owner_service set last_claimed_at=clock_timestamp(),next_poll_at=clock_timestamp(),
    last_lane=case when m.end_at>now()-interval '10 minutes' then 'live' else 'history' end where user_id=owner;
  return jsonb_build_object('manifest',to_jsonb(m),'leaseToken',d.lease_token);
end $function$

