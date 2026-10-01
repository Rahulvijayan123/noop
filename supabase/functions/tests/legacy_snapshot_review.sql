-- Independent reviewer fixture. Requires the named isolated clone, never production.
do $$ begin
  assert current_database()='build373_review_v1','isolated reviewer database required';
end $$;
select set_config('review.owner',gen_random_uuid()::text,false),
       set_config('review.device',gen_random_uuid()::text,false),
       set_config('review.other',gen_random_uuid()::text,false);
insert into auth.users(id) values(current_setting('review.owner')::uuid),(current_setting('review.other')::uuid);
insert into profiles(id,timezone) values(current_setting('review.owner')::uuid,'UTC')
  on conflict(id) do update set timezone='UTC';
insert into devices(id,user_id,source_kind,external_device_id,device_family)
  values(current_setting('review.device')::uuid,current_setting('review.owner')::uuid,'noop_push',
    current_setting('review.device'),'whoop5');
select scoring_enqueue_legacy_fenced(current_setting('review.owner')::uuid,
  current_setting('review.device')::uuid,'2026-05-01','UTC',0);

-- Claiming and sealing in separate repeatable-read transactions is forbidden.
begin isolation level repeatable read;
select set_config('review.claim',to_jsonb(q)::text,false) from scoring_legacy_claim_one(300,8,
  current_setting('review.owner')::uuid,current_setting('review.device')::uuid,'2026-05-01') q;
commit;
begin isolation level repeatable read;
do $$ declare q jsonb:=current_setting('review.claim')::jsonb; begin
  assert q->>'lease_token' is not null,'fixture did not claim';
  begin
    perform scoring_legacy_seal_snapshot((q->>'user_id')::uuid,(q->>'device_id')::uuid,
      (q->>'day')::date,(q->>'claimed_revision')::bigint,(q->>'lease_token')::uuid,(q->>'run_id')::uuid);
    raise exception 'cross-transaction seal unexpectedly succeeded';
  exception when serialization_failure then null; end;
  assert exists(select 1 from scoring_work_items where user_id=(q->>'user_id')::uuid
    and device_id=(q->>'device_id')::uuid and day=(q->>'day')::date
    and lease_token=(q->>'lease_token')::uuid and snapshot_captured_at is null),
    'rejected seal corrupted the original claim';
  begin
    perform scoring_legacy_begin_publication((q->>'user_id')::uuid,(q->>'device_id')::uuid,
      (q->>'day')::date,(q->>'claimed_revision')::bigint,(q->>'lease_token')::uuid,(q->>'run_id')::uuid);
    raise exception 'unsealed cross-transaction input published';
  exception when serialization_failure then null; end;
end $$;
rollback;

-- A crashed/aborted acquisition must roll back both claim and seal authority.
select scoring_enqueue_legacy_fenced(current_setting('review.owner')::uuid,
  current_setting('review.device')::uuid,'2026-05-02','UTC',0);
begin isolation level repeatable read;
do $$ declare q public.scoring_work_items; begin
  select * into q from scoring_legacy_claim_one(300,8,current_setting('review.owner')::uuid,
    current_setting('review.device')::uuid,'2026-05-02');
  perform scoring_legacy_seal_snapshot(q.user_id,q.device_id,q.day,q.claimed_revision,q.lease_token,q.run_id);
  assert exists(select 1 from scoring_work_items where user_id=q.user_id and device_id=q.device_id
    and day=q.day and snapshot_captured_at is not null),'same-transaction sealing failed';
end $$;
rollback;
do $$ begin
  assert exists(select 1 from scoring_work_items where user_id=current_setting('review.owner')::uuid
    and device_id=current_setting('review.device')::uuid and day='2026-05-02' and lease_token is null
    and snapshot_captured_at is null and status='pending'),'aborted snapshot retained claim authority';
end $$;

-- The security-definer readable-revision helper must not expose another owner's state.
begin;
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true),
       set_config('request.jwt.claim.sub',current_setting('review.other'),true);
do $$ begin
  begin
    perform scoring_legacy_minimum_readable_revision(current_setting('review.owner')::uuid,
      current_setting('review.device')::uuid,'2026-05-01');
    raise exception 'readable revision helper accepted another owner';
  exception when insufficient_privilege then null; end;
end $$;
rollback;

-- Authorized reads still see the withdrawal fence despite queue-table RLS.
select scoring_enqueue_legacy_fenced(current_setting('review.owner')::uuid,
  current_setting('review.device')::uuid,'2026-05-01','UTC',0);
begin;
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true),
       set_config('request.jwt.claim.sub',current_setting('review.owner'),true);
do $$ begin
  assert scoring_legacy_minimum_readable_revision(current_setting('review.owner')::uuid,
    current_setting('review.device')::uuid,'2026-05-01')>0,'owner cannot see withdrawal fence';
end $$;
rollback;
