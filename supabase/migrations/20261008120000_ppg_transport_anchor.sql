-- PPG transport (Spec 01 section 3): admit the protocol 1.5 ppgWaveformSample schema 3 manifest.
--
-- NPB1 format 3 carries the v26 optical anchor, the record clock source, the raw header phase and
-- flags byte and a saturation flag (docs/model-integration/ppg-transport.md). The receiver derives
-- schema 3 from protocol 1.5 for ppgWaveformSample only; every other stream and version keeps
-- schema 1 or 2. The reservation core rejected any schema outside (1,2), so a 1.5 PPG intent failed
-- with invalid_object_manifest before this migration.
--
-- `noop_reserve_object_manifest_lifecycle_core` is the original durable reservation
-- (20260921060000_production_intake_durability.sql), renamed under the installation-lifecycle and
-- representation-identity wrappers. This replaces its body byte-for-byte except the schema check,
-- which now also admits 3 for exactly (ppgWaveformSample, push protocol 1.5). CREATE OR REPLACE keeps
-- the owner and the revoked grants; the wrappers above it are unchanged. Additive and reversible:
-- reapplying the original body restores the (1,2) gate, and rows written at schema 3 stay valid
-- receipts either way. Not applied to production by this change.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function public.noop_reserve_object_manifest_lifecycle_core(p_manifest jsonb)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare v public.object_manifests; p public.object_manifests;
begin
  p := jsonb_populate_record(null::public.object_manifests, p_manifest);
  if not exists (select 1 from public.devices where id = p.device_id and user_id = p.user_id) then
    raise exception 'device_owner_conflict' using errcode = '42501';
  end if;
  if p.object_class is distinct from 'raw' or coalesce(p.sha256,'') !~ '^[0-9a-f]{64}$'
     or coalesce(p.digest_scope,'') not in ('decoded', 'wire')
     or p.batch_id is null or p.source_id is null
     or coalesce(p.schema_version,0) not in (1,2,3)
     -- Schema 3 is the protocol 1.5 PPG anchor format and nothing else.
     or (p.schema_version = 3 and (p.object_kind is distinct from 'ppgWaveformSample'
         or p.push_protocol_version is distinct from '1.5'))
     or coalesce(p.compressed_bytes,0) <= 0 or p.compressed_bytes > 268435456
     or coalesce(p.uncompressed_bytes,0) <= 0 or p.uncompressed_bytes > 536870912 then
    raise exception 'invalid_object_manifest' using errcode = '22023';
  end if;
  insert into public.object_manifests
    (id,user_id,device_id,object_class,object_kind,provider,bucket,object_key,upload_object_key,
     start_at,end_at,period_day,sample_count,compressed_bytes,uncompressed_bytes,content_type,
     format,compression,schema_version,push_protocol_version,sha256,sha256_source,digest_scope,retention_class,
     expires_at,batch_id,source_id,status)
  values
    (p.id,p.user_id,p.device_id,'raw',p.object_kind,p.provider,p.bucket,p.object_key,p.object_key,
     p.start_at,p.end_at,p.period_day,p.sample_count,p.compressed_bytes,p.uncompressed_bytes,p.content_type,
     p.format,p.compression,p.schema_version,p.push_protocol_version,p.sha256,'client_claimed',p.digest_scope,p.retention_class,
     p.expires_at,p.batch_id,p.source_id,'pending') on conflict (id) do nothing;
  select * into v from public.object_manifests where id = p.id for update;
  if v.user_id is distinct from p.user_id or v.device_id is distinct from p.device_id then
    raise exception 'object_owner_conflict' using errcode = '42501';
  end if;
  if v.object_class <> 'raw' or v.object_kind is distinct from p.object_kind
     or lower(v.sha256) is distinct from lower(p.sha256)
     or v.compressed_bytes is distinct from p.compressed_bytes
     or (v.uncompressed_bytes is not null and v.uncompressed_bytes is distinct from p.uncompressed_bytes)
     or coalesce(v.digest_scope, case when v.format like 'ndjson%' then 'wire' else 'decoded' end) is distinct from p.digest_scope
     or v.compression is distinct from p.compression
     or coalesce(v.schema_version,1) <> coalesce(p.schema_version,1)
     or (v.push_protocol_version is not null and v.push_protocol_version is distinct from p.push_protocol_version)
     or v.start_at is distinct from p.start_at or v.end_at is distinct from p.end_at
     or v.sample_count is distinct from p.sample_count
     or (v.batch_id is not null and v.batch_id is distinct from p.batch_id)
     or (v.source_id is not null and v.source_id is distinct from p.source_id) then
    raise exception 'object_id_conflict' using errcode = '23505';
  end if;
  -- Legacy rows did not store all immutable fields. Bind them once only after matching their
  -- pre-existing identity/digest. This is a repair, never a new digest under an old id.
  if v.uncompressed_bytes is null or v.batch_id is null or v.source_id is null
     or v.push_protocol_version is null or v.digest_scope is null or v.upload_object_key is null then
    update public.object_manifests set
      uncompressed_bytes=coalesce(uncompressed_bytes,p.uncompressed_bytes),
      batch_id=coalesce(batch_id,p.batch_id),source_id=coalesce(source_id,p.source_id),
      push_protocol_version=coalesce(push_protocol_version,p.push_protocol_version),
      digest_scope=coalesce(digest_scope,p.digest_scope),upload_object_key=coalesce(upload_object_key,object_key)
      where id=v.id returning * into v;
  end if;
  return to_jsonb(v);
end;
$$;

revoke all on function public.noop_reserve_object_manifest_lifecycle_core(jsonb)
  from public, anon, authenticated, service_role;

commit;
