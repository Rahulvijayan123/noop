begin;

-- Decoded batch identity is independent of its compressed representation. Wire-scoped
-- inline batches remain one-object identities. Do not rewrite any existing IDs/receipts.
create function public.noop_object_logical_identity(p public.object_manifests)
returns jsonb language sql immutable set search_path='' as $$
  select jsonb_build_object(
    'owner',p.user_id,'device',p.device_id,'source',p.source_id,'batch',p.batch_id,
    'class',p.object_class,'stream',p.object_kind,'sha256',p.sha256,
    'digest_scope',coalesce(p.digest_scope,case when p.format like 'ndjson%' then 'wire' else 'decoded' end),
    'format',p.format,'compression',p.compression,'schema',coalesce(p.schema_version,1),
    'protocol',p.push_protocol_version,'start',extract(epoch from p.start_at),
    'end',extract(epoch from p.end_at),'samples',p.sample_count,'decoded_bytes',p.uncompressed_bytes,
    'single_object',case when p.object_class='raw' and p.digest_scope='decoded'
      and p.format in ('bin_gzip_noop_push_v1','bin_zstd_noop_push_v1','protobuf_zstd_noop_push_v1')
      then null else p.id end);
$$;
revoke all on function public.noop_object_logical_identity(public.object_manifests) from public,anon,authenticated,service_role;

create table public.noop_object_batch_identities (
  user_id uuid not null references auth.users(id) on delete cascade,
  batch_id uuid not null,
  first_object_id uuid not null,
  logical_identity jsonb not null,
  auth_mode text not null check(auth_mode in ('legacy_fleet','installation')),
  primary key(user_id,batch_id)
);
alter table public.noop_object_batch_identities enable row level security;
revoke all on public.noop_object_batch_identities from public,anon,authenticated,service_role;

-- Locking prevents a concurrent old reservation from escaping the change of uniqueness.
lock table public.object_manifests in share row exclusive mode;
insert into public.noop_object_batch_identities(user_id,batch_id,first_object_id,logical_identity,auth_mode)
  select user_id,batch_id,id,public.noop_object_logical_identity(m),coalesce(auth_mode,'legacy_fleet')
  from public.object_manifests m where batch_id is not null;

alter function public.noop_reserve_object_manifest(jsonb) rename to noop_reserve_object_manifest_representation_core;
revoke all on function public.noop_reserve_object_manifest_representation_core(jsonb) from public,anon,authenticated,service_role;
create function public.noop_reserve_object_manifest(p_manifest jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  p public.object_manifests; v public.object_manifests;
  b public.noop_object_batch_identities;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  p:=jsonb_populate_record(null::public.object_manifests,p_manifest);
  if p.batch_id is null or p.user_id is null then raise exception 'invalid_object_manifest' using errcode='22023'; end if;
  if not exists(select 1 from public.devices where id=p.device_id and user_id=p.user_id) then
    raise exception 'device_owner_conflict' using errcode='42501';
  end if;
  -- The primary key serializes first admission across Edge isolates, including conflicting
  -- digests, sources and canonical devices. The existing inner RPC retains lifecycle fences.
  insert into public.noop_object_batch_identities(user_id,batch_id,first_object_id,logical_identity,auth_mode)
    values(p.user_id,p.batch_id,p.id,public.noop_object_logical_identity(p),coalesce(p.auth_mode,'legacy_fleet'))
    on conflict(user_id,batch_id) do nothing;
  select * into b from public.noop_object_batch_identities
    where user_id=p.user_id and batch_id=p.batch_id for update;
  if p.id<>b.first_object_id and (b.logical_identity is distinct from public.noop_object_logical_identity(p)
      or b.auth_mode is distinct from coalesce(p.auth_mode,'legacy_fleet')) then
    raise exception 'batch_id_conflict' using errcode='23505';
  end if;
  v:=jsonb_populate_record(null::public.object_manifests,public.noop_reserve_object_manifest_representation_core(p_manifest));
  -- Only the original object can complete legacy nullable metadata, through the original
  -- exact-object checks. A new representation cannot supply missing old provenance.
  if p.id=b.first_object_id then
    update public.noop_object_batch_identities set logical_identity=public.noop_object_logical_identity(v),
      auth_mode=coalesce(v.auth_mode,'legacy_fleet') where user_id=p.user_id and batch_id=p.batch_id;
  end if;
  return to_jsonb(v);
end $$;
revoke all on function public.noop_reserve_object_manifest(jsonb) from public,anon,authenticated;
grant execute on function public.noop_reserve_object_manifest(jsonb) to service_role;

-- Direct raw inserts cannot bypass the registered logical binding. The lifecycle wrapper
-- persists auth mode after its inner insert; auth admission remains in that wrapper.
create function public.noop_require_object_batch_identity() returns trigger
language plpgsql security definer set search_path='' as $$
declare b public.noop_object_batch_identities;
begin
  if new.object_class<>'raw' or new.batch_id is null then return new; end if;
  select * into b from public.noop_object_batch_identities
    where user_id=new.user_id and batch_id=new.batch_id for share;
  if found and new.id=b.first_object_id and exists(select 1 from public.object_manifests where id=new.id) then
    return new; -- Existing-object conflict checks remain in the exact-object reservation RPC.
  end if;
  if not found or b.logical_identity is distinct from public.noop_object_logical_identity(new) then
    raise exception 'batch_id_conflict' using errcode='23505';
  end if;
  return new;
end $$;
revoke all on function public.noop_require_object_batch_identity() from public,anon,authenticated,service_role;
create trigger noop_object_batch_identity before insert on public.object_manifests
  for each row execute function public.noop_require_object_batch_identity();
drop index public.object_manifests_user_batch_uidx;
create index object_manifests_user_batch_idx on public.object_manifests(user_id,batch_id) where batch_id is not null;

comment on table public.noop_object_batch_identities is
  'One immutable logical source binding per owner/batch. Multiple decoded binary representations each retain their own exact object durability receipt.';
commit;
