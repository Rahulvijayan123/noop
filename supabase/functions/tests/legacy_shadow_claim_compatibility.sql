-- Regression for the shared historical RPC composite after v1-only snapshot columns.
-- Run only in a disposable database with all forward migrations applied.
begin isolation level repeatable read;
select set_config('request.jwt.claim.role','service_role',true);
do $$
declare u uuid:=gen_random_uuid(); d uuid:=gen_random_uuid();
  v2 public.scoring_work_items; v1 public.scoring_work_items;
begin
  insert into auth.users(id) values(u);
  insert into public.profiles(id,timezone) values(u,'UTC') on conflict(id) do update set timezone='UTC';
  insert into public.devices(id,user_id,source_kind,device_family) values(d,u,'noop_push','whoop5');
  perform public.scoring_enqueue_day(u,d,'2026-08-01','UTC',0);
  select * into strict v2 from public.scoring_claim_one_core(300,8,u,d,'2026-08-01');
  assert v2.user_id=u and v2.device_id=d and v2.day='2026-08-01' and v2.input_revision=1;
  assert v2.run_id is not null and v2.lease_token is not null and v2.status='running';
  assert v2.snapshot_transaction_id is null and v2.snapshot_captured_at is null
    and v2.claimed_measurement_revision is null and v2.claimed_timezone_id is null,
    'v2 must not claim ownership of a v1 input snapshot';
  assert (select run_id is null from public.scoring_work_items where user_id=u and device_id=d and day=v2.day),
    'v2 consumed the independent baseline lease';
  select * into strict v1 from public.scoring_legacy_claim_one(300,8,u,d,'2026-08-01');
  perform public.scoring_legacy_seal_snapshot(u,d,v1.day,v1.input_revision,v1.lease_token,v1.run_id);
  perform public.scoring_legacy_begin_publication(u,d,v1.day,v1.input_revision,v1.lease_token,v1.run_id);
  assert (select run_id=v2.run_id and lease_token=v2.lease_token and status='running'
    from public.physiology_work_items where user_id=u and device_id=d and day=v2.day),
    'baseline snapshot consumed or changed independent v2 authority';
  raise notice 'PASS: v1/v2 claim compatibility, exact identity and independent lease preservation';
end $$;
rollback;
