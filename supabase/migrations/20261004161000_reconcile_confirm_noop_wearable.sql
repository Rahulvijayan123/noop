-- Reconcile public.confirm_noop_wearable with the definition production has been running.
--
-- Production already carries this body: it extends the identity-confirmation guard so a provisional
-- wearable whose only non-input object is a server-written derived score (algorithm frwhoop-server-1,
-- verified archive outbox row, immutable result, matching manifest hashes and object key) is still treated
-- as the retained output HOLD rather than as an installation-attributed input. Unknown or null raw
-- provenance and every foreign non-null source continue to fail closed, and any input or receipt linkage
-- cancels the exception. The repository's last definition (20260925020000_retain_legacy_wearable_identity)
-- only recognised the older frwhoop-physiology-2 shape, so a database rebuilt from migrations alone would
-- refuse to confirm a wearable that production accepts.
--
-- The statement below is the live definition verbatim. CREATE OR REPLACE keeps the existing owner and
-- privileges (service_role only), so applying it to production changes nothing.
begin;
set local lock_timeout = '5s';

CREATE OR REPLACE FUNCTION public.confirm_noop_wearable(p_user uuid, p_source uuid, p_provisional uuid, p_canonical uuid, p_evidence jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d public.devices%rowtype; target record; batch record; rows jsonb; existing uuid; predicate text;
  retained_history boolean; foreign_history boolean; typed_history boolean;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  perform 1 from public.noop_app_installations where user_id=p_user and source_id=p_source
    and revoked_at is null and retired_at is null for share;
  if not found then raise exception 'inactive_installation' using errcode='42501'; end if;
  select * into d from public.devices where id=p_canonical and user_id=p_user;
  if not found or d.external_device_id !~ '^whoop-[A-Z0-9-]{6,}$'
    or p_evidence->>'method' is distinct from 'device_information_serial_v1'
    or p_evidence->>'serial' is distinct from substr(d.external_device_id,7)
    or coalesce(p_evidence->>'receiptSha256','') !~ '^[a-f0-9]{64}$'
    or not exists(select 1 from public.devices where id=p_provisional and user_id=p_user
      and starts_with(external_device_id,'installation:'||p_source||':')) then
    raise exception 'supported_serial_evidence_required' using errcode='22023';
  end if;
  -- Stable lock order permits two phone confirmations without deadlock.
  perform public.scoring_acquire_input_gate(p_user,least(p_provisional,p_canonical));
  perform public.scoring_acquire_input_gate(p_user,greatest(p_provisional,p_canonical));
  select canonical_device_id into existing from public.noop_wearable_aliases
    where user_id=p_user and provisional_device_id=p_provisional;
  if found then
    if existing<>p_canonical then raise exception 'wearable_association_conflict' using errcode='23505'; end if;
    return existing;
  end if;
  -- The legacy installation identity owns immutable upload provenance. Completion,
  -- retention status and receipt object_id removal do not authorize moving it.
  -- Keep serial association deferred until a separately reviewed identity transfer.
  if exists(select 1 from public.devices where user_id=p_user and id=p_provisional
      and external_device_id='installation:'||p_source::text||':my-whoop') then
    -- Preserve the existing v2 output HOLD. For selected v1, require the exact
    -- verified archive outbox, immutable result, manifest, hashes, and object key.
    -- Neither output shape authorizes input attribution or identity transfer.
    -- Unknown/null raw provenance and every foreign non-null source fail closed.
    -- Any input/receipt linkage cancels the exception.
    if exists(select 1 from public.object_manifests m
        where m.user_id=p_user and m.device_id=p_provisional and m.source_id is distinct from p_source
          and not coalesce(((m.source_id is null and m.object_class='derived' and m.object_kind='derived_scores'
            and m.algorithm_version='frwhoop-physiology-2' and m.format='json_zstd_frwhoop_derived_v2'
            and m.compression='zstd' and m.provider='b2' and m.content_type='application/json'
            and m.sha256_source='server_verified' and m.retention_class='derived'
            and m.sha256 ~ '^[a-f0-9]{64}$' and m.verified_at is not null
            and not exists(select 1 from public.noop_signal_windows w where w.object_id=m.id)
            and not exists(select 1 from public.noop_upload_receipts r where r.object_id=m.id)) or (m.source_id is null and m.object_class='derived' and m.object_kind='derived_scores'
            and m.algorithm_version='frwhoop-server-1' and m.format='json_zstd_frwhoop_derived_v2'
            and m.compression='zstd' and m.provider='b2' and m.content_type='application/json'
            and m.sha256_source='server_verified' and m.retention_class='derived' and m.status='ready'
            and m.sha256 ~ '^[a-f0-9]{64}$' and m.verified_at is not null
            and m.compressed_bytes between 1 and 2097152
            and not exists(select 1 from public.noop_signal_windows w where w.object_id=m.id)
            and not exists(select 1 from public.noop_upload_receipts u where u.object_id=m.id)
            and exists(select 1 from public.physiology_archive_outbox a
              join public.server_physiology_results r on r.user_id=a.user_id and r.device_id=a.device_id
                and r.period_day=a.period_day and r.algorithm_version=a.algorithm_version and r.input_revision=a.input_revision
              join public.physiology_algorithm_versions v on v.algorithm_version=r.algorithm_version
              where a.user_id=m.user_id and a.device_id=m.device_id and a.period_day=m.period_day
                and a.algorithm_version=m.algorithm_version and a.object_key=m.object_key
                and a.status='verified' and a.verified_at is not null and a.uploaded_at is not null
                and a.lease_token is null and a.lease_expires_at is null
                and a.content_sha256=m.sha256 and a.content_sha256 ~ '^[a-f0-9]{64}$'
                and a.verified_at>=m.verified_at and a.uploaded_at<=a.verified_at
                and r.manifest_hash=v.manifest_hash and v.manifest_hash=encode(sha256(convert_to(v.manifest::text,'UTF8')),'hex')
                and r.payload_hash=encode(sha256(convert_to(r.payload::text,'UTF8')),'hex')
                and r.payload->>'user_id'=r.user_id::text and r.payload->>'device_id'=r.device_id::text
                and r.payload->>'day'=r.period_day::text and r.payload->>'algorithm_version'=r.algorithm_version
                and r.payload->>'input_revision'=r.input_revision::text and r.payload->>'run_id'=r.run_id::text
                and r.payload->>'manifest_hash'=r.manifest_hash and r.measurement_revision>0
                and a.object_key='v3/derived/users/'||r.user_id||'/devices/'||r.device_id||'/days/'||r.period_day||'/'||r.algorithm_version||'/revisions/'||r.input_revision||'/'||r.payload_hash||'.json.zst'))),false))
      or exists(select 1 from public.noop_upload_receipts
        where user_id=p_user and device_id=p_provisional and source_id is distinct from p_source) then
      raise exception 'retained_legacy_identity_source_conflict_v1' using errcode='PT409';
    end if;
    -- After the provenance check, both exact-source inputs and the documented
    -- source-less derived outputs require retained identity, including output-only.
    retained_history := exists(select 1 from public.object_manifests
        where user_id=p_user and device_id=p_provisional)
      or exists(select 1 from public.noop_upload_receipts
        where user_id=p_user and source_id=p_source and device_id=p_provisional);
    -- Check every typed stream even when a manifest exists: mixed provenance is
    -- a blocking conflict, not authorization for the exact-source deferral path.
    for target in select p.* from unnest(array['hrSample','rrInterval','rrPacketProvenance','standardHRReceipt',
      'stepSample','sleepStateSample','ppgHrSample','event','battery','spo2Sample','skinTempSample','respSample','gravitySample']) s(stream)
      cross join lateral public.noop_projection_target(s.stream) p loop
      execute format('select coalesce(bool_or(source_id is distinct from $3),false),count(*)>0
        from public.%I where user_id=$1 and device_id=$2',target.table_name)
        into foreign_history,typed_history using p_user,p_provisional,p_source;
      if foreign_history then
        raise exception 'retained_legacy_identity_source_conflict_v1' using errcode='PT409';
      end if;
      retained_history:=retained_history or typed_history;
    end loop;
    if retained_history then
      raise exception 'retained_legacy_identity_v1' using errcode='PT409';
    end if;
  end if;
  insert into public.noop_rr_clock_conflicts select p_user,p_canonical,ts
    from public.noop_rr_clock_conflicts where user_id=p_user and device_id=p_provisional on conflict do nothing;
  insert into public.noop_projection_conflicts(user_id,device_id,stream,measurement_key,detected_at,reason)
    select p_user,p_canonical,stream,measurement_key,detected_at,reason from public.noop_projection_conflicts
      where user_id=p_user and device_id=p_provisional on conflict do nothing;
  delete from public.noop_rr_intervals r using public.noop_rr_clock_conflicts c
    where r.user_id=p_user and r.device_id=p_canonical and c.user_id=r.user_id and c.device_id=r.device_id and c.ts=r.ts;
  for target in select s.*,p.* from unnest(array['hrSample','rrInterval','rrPacketProvenance','standardHRReceipt',
    'stepSample','sleepStateSample','ppgHrSample','event','battery','spo2Sample','skinTempSample','respSample','gravitySample']) s(stream)
    cross join lateral public.noop_projection_target(s.stream) p loop
    -- A conflict may already have removed every provisional row. Its quarantine must also remove
    -- any canonical copy; otherwise merging only surviving rows would resurrect that measurement.
    select string_agg(format('t.%I is not distinct from x.%I',k,k),' and ')
      into predicate from unnest(target.key_columns) k;
    execute format('delete from public.%I t using public.noop_projection_conflicts c,
      lateral jsonb_populate_record(null::public.%I,c.measurement_key) x
      where c.user_id=$1 and c.device_id=$2 and c.stream=$3
        and t.user_id=c.user_id and t.device_id=c.device_id and %s',
      target.table_name,target.table_name,predicate) using p_user,p_canonical,target.stream;
    for batch in execute format('select source_id,batch_id from public.%I where user_id=$1 and device_id=$2
      group by source_id,batch_id',target.table_name) using p_user,p_provisional loop
      if batch.source_id is distinct from p_source or batch.batch_id is null then
        raise exception 'unattributed_provisional_input_requires_review' using errcode='22023';
      end if;
      execute format('select jsonb_agg(to_jsonb(t)||jsonb_build_object(''device_id'',$3)) from public.%I t
        where user_id=$1 and device_id=$2 and source_id=$4 and batch_id=$5',target.table_name)
        into rows using p_user,p_provisional,p_canonical,batch.source_id,batch.batch_id;
      -- Receipt observations retain the provisional row unchanged. Reconciliation uses a separate
      -- deterministic batch namespace and leaves the original raw objects/manifests untouched.
      rows := (select jsonb_agg(r||jsonb_build_object('batch_id',md5(batch.batch_id::text||p_canonical::text)::uuid))
        from jsonb_array_elements(rows) r);
      perform public.noop_project_append_batch(p_user,p_canonical,p_source,
        md5(batch.batch_id::text||p_canonical::text)::uuid,target.stream,rows);
    end loop;
    execute format('delete from public.%I where user_id=$1 and device_id=$2',target.table_name) using p_user,p_provisional;
  end loop;
  insert into public.noop_wearable_aliases values(p_user,p_source,p_provisional,p_canonical,p_evidence,clock_timestamp());
  for target in select w.start_ts,w.end_ts from public.noop_signal_windows w
      join public.object_manifests m on m.id=w.object_id and m.user_id=w.user_id and m.device_id=w.device_id
      where w.user_id=p_user and w.device_id=p_provisional and m.source_id=p_source loop
    perform public.scoring_dirty_span(p_user,p_canonical,target.start_ts,target.end_ts);
  end loop;
  return p_canonical;
end $function$;

commit;
