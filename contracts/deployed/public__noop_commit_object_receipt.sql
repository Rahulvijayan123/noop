-- Deployed definition for public.noop_commit_object_receipt
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:22.546368
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='noop_commit_object_receipt';"
CREATE OR REPLACE FUNCTION public.noop_commit_object_receipt(p_user_id uuid, p_object_id uuid, p_verified_key text, p_wire_sha256 text, p_content_sha256 text, p_compressed_bytes bigint, p_uncompressed_bytes bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v public.object_manifests; v_receipt jsonb; v_scope text;
  v_start bigint; v_end bigint; v_expected bigint; v_key text; v_index_changes integer; v_now timestamptz := now();
begin
  select * into v from public.object_manifests where id = p_object_id for update;
  if not found or v.user_id is distinct from p_user_id or not exists
    (select 1 from public.devices where id = v.device_id and user_id = p_user_id) then
    raise exception 'object_owner_conflict' using errcode = '42501';
  end if;
  v_scope := coalesce(v.digest_scope, case when v.format like 'ndjson%' then 'wire' else 'decoded' end);
  if v.object_class <> 'raw' or v.status in ('deleted','deleting','expired')
     or coalesce(p_wire_sha256,'') !~ '^[0-9a-f]{64}$'
     or coalesce(p_content_sha256,'') !~ '^[0-9a-f]{64}$'
     or p_compressed_bytes is distinct from v.compressed_bytes
     or coalesce(p_uncompressed_bytes,0) <= 0 or p_uncompressed_bytes > 536870912
     or (v.uncompressed_bytes is not null and p_uncompressed_bytes <> v.uncompressed_bytes)
     or lower(v.sha256) is distinct from
       (case when v_scope = 'wire' then p_wire_sha256 else p_content_sha256 end)
     or coalesce(p_verified_key,'') not like ('%/users/' || v.user_id::text || '/%/verified/' || v.id::text || '/%') then
    raise exception 'object_verification_mismatch' using errcode = '23514';
  end if;
  if v.durability_receipt is not null and (
       v.durability_receipt->>'wireSha256' is distinct from p_wire_sha256
       or v.durability_receipt->>'contentSha256' is distinct from p_content_sha256) then
    raise exception 'receipt_immutable' using errcode = '23514';
  end if;
  -- A concurrent identical verifier may already have published another immutable snapshot.
  v_key := coalesce(v.durability_receipt->>'objectKey',p_verified_key);
  v_start := floor(extract(epoch from v.start_at));
  v_end := greatest(v_start + 1, ceil(extract(epoch from v.end_at)));
  if v_start is null or v_end is null then
    raise exception 'object_window_missing' using errcode = '23514';
  end if;
  v_expected := case when v.object_kind in ('ppgWaveformSample','v18AuxSample','rawImuSession')
    then v_end - v_start else null end;
  insert into public.noop_signal_windows
    (user_id,device_id,stream,hour_start,object_id,object_key,start_ts,end_ts,expected_records,
     received_records,missing_records,coverage,interpolated_records,compressed_bytes,uncompressed_bytes)
  values (v.user_id,v.device_id,v.object_kind,(v_start / 3600)*3600,v.id,v_key,v_start,v_end,
    v_expected,coalesce(v.sample_count,0),case when v_expected is not null then greatest(v_expected-v.sample_count,0) end,
    case when v_expected > 0 then least(1.0,v.sample_count::double precision/v_expected) else null end,
    0,p_compressed_bytes,p_uncompressed_bytes)
  on conflict (user_id,device_id,stream,hour_start,object_id) do update set
    object_key=excluded.object_key, compressed_bytes=excluded.compressed_bytes,
    uncompressed_bytes=excluded.uncompressed_bytes, updated_at=v_now
    where public.noop_signal_windows.object_key is distinct from excluded.object_key
       or public.noop_signal_windows.compressed_bytes is distinct from excluded.compressed_bytes
       or public.noop_signal_windows.uncompressed_bytes is distinct from excluded.uncompressed_bytes;
  get diagnostics v_index_changes = row_count;
  v_receipt := coalesce(v.durability_receipt, jsonb_build_object(
    'version',1,'state','verified_indexed','receiptId',gen_random_uuid(),
    'ownerUserId',v.user_id,'deviceId',v.device_id,'objectId',v.id,
    'batchId',v.batch_id,'sourceId',v.source_id,'stream',v.object_kind,
    'schemaVersion',coalesce(v.schema_version,1),'objectKey',v_key,
    'contentSha256',p_content_sha256,'wireSha256',p_wire_sha256,
    'compressedBytes',p_compressed_bytes,'uncompressedBytes',p_uncompressed_bytes,
    'verifiedAt',v_now,'indexedAt',v_now));
  -- A legacy repair may precede the original intent retry. Fill unknown provenance once;
  -- already-bound provenance is compared by reservation and is never reassigned.
  if v_receipt->>'batchId' is null and v.batch_id is not null then
    v_receipt := v_receipt || jsonb_build_object('batchId',v.batch_id);
  end if;
  if v_receipt->>'sourceId' is null and v.source_id is not null then
    v_receipt := v_receipt || jsonb_build_object('sourceId',v.source_id);
  end if;
  update public.object_manifests set
    upload_object_key=coalesce(upload_object_key,object_key), object_key=v_key,
    wire_sha256=p_wire_sha256, sha256_source='server_verified', digest_scope=v_scope,
    status='ready', verified_at=(v_receipt->>'verifiedAt')::timestamptz, indexed_at=v_now,
    uploaded_at=coalesce(uploaded_at,v_now), durability_receipt=v_receipt, updated_at=v_now
    where id=v.id and (status <> 'ready' or object_key is distinct from v_key
      or wire_sha256 is distinct from p_wire_sha256 or durability_receipt is distinct from v_receipt
      or indexed_at is null or v_index_changes > 0
      or sha256_source is distinct from 'server_verified' or digest_scope is distinct from v_scope
      or verified_at is distinct from (v_receipt->>'verifiedAt')::timestamptz);
  -- The raw-input invalidation trigger correctly clears proof when object_key changes.
  -- Attach this verifier's byte proof only after that new immutable location is stable,
  -- under the same manifest lock/transaction. Decoder/model qualification stays cleared.
  update public.object_manifests set sha256_source='server_verified',
    verified_at=(v_receipt->>'verifiedAt')::timestamptz
    where id=v.id and (sha256_source is distinct from 'server_verified'
      or verified_at is distinct from (v_receipt->>'verifiedAt')::timestamptz);
  return v_receipt;
end;
$function$

