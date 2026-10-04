-- noop_projection_debt: bounded dead-letter after 16 consecutive failures (G2-attestation item 5).
--
-- noop_fail_projection_debt backed the row off forever (failures capped at 16, <= 1 h backoff) with no
-- terminal disposition, so deterministically-poison rows were re-downloaded + re-decoded + re-failed
-- hourly forever. The ~16,000 stale rows from other test devices (12-20 September) are exactly why the
-- projection lane is OFF in production (docs/BACKEND.md Known issues). This migration adds the house
-- dead-letter pattern used by scoring_v2 (dead_letter at 8) and archive_v2 (at 12): at the 16th
-- consecutive failure the row is marked dead_letter with a bounded reason and excluded from every future
-- claim, while transient failures keep their existing capped exponential backoff.
--
-- No production row is reassigned or deleted here. The OPERATOR path for the existing stale backlog:
--   1. inspect:      select object_id,user_id,failures,last_error,not_before from noop_projection_debt
--                    where state='pending' and not dead_letter order by created_at;
--   2. dead-letter:  call noop_fail_projection_debt 16 times, or (batch) update ... set dead_letter=true,
--                    dead_letter_reason='operator_superseded', last_error='stale_test_device_backlog';
--   3. reactivate:   update noop_projection_debt set dead_letter=false, dead_letter_reason=null,
--                    failures=0, not_before=clock_timestamp() where object_id='<uuid>';
--   4. purge (after retention window): delete from noop_projection_debt where dead_letter
--                    and dead_letter_reason in ('projection_replay_exhausted','operator_superseded')
--                    and created_at < now()-interval '90 days';
--
-- Additive only. One transaction.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table public.noop_projection_debt
  add column if not exists dead_letter boolean not null default false,
  add column if not exists dead_letter_reason text;

create index if not exists noop_projection_open_dead_letter
  on public.noop_projection_debt(object_id) where state='pending' and not dead_letter;

comment on column public.noop_projection_debt.dead_letter is
  'Terminal disposition: the row failed noop_fail_projection_debt 16 consecutive times and must not be claimed again without operator review.';
comment on column public.noop_projection_debt.dead_letter_reason is
  'Bounded reason for the dead-letter: projection_replay_exhausted (automatic at 16) or operator_superseded (manual).';

-- The fail path now dead-letters at 16 while keeping the existing capped exponential backoff for
-- transient failures (mirrors fail_scoring_v2's dead_letter/case pattern).
create or replace function public.noop_fail_projection_debt(p_object_id uuid,p_token uuid) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  update public.noop_projection_debt set
    failures=least(failures+1,16),
    dead_letter=(failures+1>=16),
    dead_letter_reason=case when failures+1>=16 then 'projection_replay_exhausted' else null end,
    last_error=case when failures+1>=16 then 'projection_replay_exhausted' else 'projection_replay_failed' end,
    not_before=clock_timestamp()+make_interval(secs=>least(3600,10*power(2,least(failures,8)))::integer),
    lease_token=null,lease_until=null
    where object_id=p_object_id and state='pending' and lease_token=p_token;
end $$;

-- The claim excludes dead-lettered rows explicitly (not_before alone is not the authority),
-- mirroring claim_scoring_v2's `and not q.dead_letter`.
create or replace function public.noop_claim_projection_debt() returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare d public.noop_projection_debt; m public.object_manifests;
begin
  select q.* into d from public.noop_projection_debt q join public.object_manifests o on o.id=q.object_id
    where q.state='pending' and not q.dead_letter and q.not_before<=clock_timestamp()
      and (q.lease_until is null or q.lease_until<=clock_timestamp())
      and o.status in ('ready','verified') and o.durability_receipt->>'state'='verified_indexed'
    order by q.not_before,q.created_at,q.object_id for update of q skip locked limit 1;
  if not found then return null; end if;
  update public.noop_projection_debt set lease_token=gen_random_uuid(),lease_until=clock_timestamp()+interval '2 minutes'
    where object_id=d.object_id returning * into d;
  select * into m from public.object_manifests where id=d.object_id;
  return jsonb_build_object('manifest',to_jsonb(m),'leaseToken',d.lease_token);
end $$;

commit;
