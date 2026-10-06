-- Keep each raw-IMU input object paired with its digest in activity_context_jobs.
--
-- enqueue_activity_context merged a re-enqueue into an existing job by sorting `input_object_ids` and
-- `input_digests` independently (each `array_agg(distinct x order by x)`), so once a day held more than
-- one object the i-th id no longer matched the i-th digest. The worker pairs them by position and checks
-- every downloaded object against its digest, so each such job failed deterministically with
-- `digest_mismatch` and dead-lettered: the first phone uploading raw motion for HART (2026-10-05) had
-- every multi-object day rejected, although each object's manifest digest was correct. A re-uploaded
-- object also left its superseded digest behind, so the two arrays could differ in length.
--
-- The merge now works on (id, digest) pairs: the incoming pair wins for an id it names, an existing pair
-- survives for an id it does not, and both arrays are built in the same id order. Callers already pass
-- the complete ready set for the day, so the merged arrays equal that set.
--
-- Repair: every existing raw-IMU job's arrays are rebuilt from the ready manifests (the same set the
-- ready-flip trigger aggregates), and the jobs this bug failed are re-queued: their failure state is
-- cleared and their revision bumped so the worker claims them again. Additive otherwise; the function
-- signature and grants are unchanged.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function public.enqueue_activity_context(p_user uuid, p_device uuid, p_day date,
  p_object_ids uuid[], p_digests text[], p_fingerprint text,
  p_model_version text default 'hart-activity-v1',
  p_preprocessing_version text default 'hart-activity-preprocess-v1',
  p_ontology_version text default 'v1')
returns void language plpgsql security definer set search_path='' as $$
begin
  if p_fingerprint is null or p_fingerprint !~ '^[0-9a-f]{64}$' then raise exception 'invalid_fingerprint'; end if;
  if p_object_ids is null or p_digests is null or cardinality(p_object_ids) <> cardinality(p_digests)
    or cardinality(p_object_ids) = 0 then raise exception 'invalid_activity_inputs'; end if;
  if not exists(select 1 from public.devices where id = p_device and user_id = p_user) then
    raise exception 'device_owner_mismatch';
  end if;
  insert into public.activity_context_jobs(user_id, device_id, day, algorithm_version,
    input_object_ids, input_digests, fingerprint, model_version, preprocessing_version,
    ontology_version, input_revision, reason)
  values(p_user, p_device, p_day, 'hart-activity-1', p_object_ids, p_digests, p_fingerprint,
    p_model_version, p_preprocessing_version, p_ontology_version, 1, 'input')
  on conflict(user_id, device_id, day, algorithm_version) do update set
    input_object_ids = (select coalesce(array_agg(m.id order by m.id), '{}'::uuid[]) from (
        select distinct on (p.id) p.id, p.digest from (
          select n.id, n.digest, 0 as pri from unnest(excluded.input_object_ids, excluded.input_digests) as n(id, digest)
          union all
          select o.id, o.digest, 1 from unnest(activity_context_jobs.input_object_ids,
            activity_context_jobs.input_digests) as o(id, digest)
        ) p where p.id is not null and p.digest is not null order by p.id, p.pri) m),
    input_digests = (select coalesce(array_agg(m.digest order by m.id), '{}'::text[]) from (
        select distinct on (p.id) p.id, p.digest from (
          select n.id, n.digest, 0 as pri from unnest(excluded.input_object_ids, excluded.input_digests) as n(id, digest)
          union all
          select o.id, o.digest, 1 from unnest(activity_context_jobs.input_object_ids,
            activity_context_jobs.input_digests) as o(id, digest)
        ) p where p.id is not null and p.digest is not null order by p.id, p.pri) m),
    fingerprint = excluded.fingerprint,
    model_version = excluded.model_version,
    preprocessing_version = excluded.preprocessing_version,
    ontology_version = excluded.ontology_version,
    input_revision = case when activity_context_jobs.fingerprint is distinct from excluded.fingerprint
      then activity_context_jobs.input_revision + 1 else activity_context_jobs.input_revision end,
    dirty_at = case when activity_context_jobs.fingerprint is distinct from excluded.fingerprint
      then clock_timestamp() else activity_context_jobs.dirty_at end,
    consecutive_failures = case when activity_context_jobs.fingerprint is distinct from excluded.fingerprint
      then 0 else activity_context_jobs.consecutive_failures end,
    dead_letter = case when activity_context_jobs.fingerprint is distinct from excluded.fingerprint
      then false else activity_context_jobs.dead_letter end,
    not_before = case when activity_context_jobs.fingerprint is distinct from excluded.fingerprint
      then clock_timestamp() else activity_context_jobs.not_before end,
    last_error = case when activity_context_jobs.fingerprint is distinct from excluded.fingerprint
      then null else activity_context_jobs.last_error end,
    reason = 'input';
end $$;

-- Rebuild every raw-IMU job's inputs from the ready manifests, paired and in id order.
with current_inputs as (
  select j.user_id, j.device_id, j.day,
    array_agg(m.id order by m.id) as ids, array_agg(lower(m.sha256) order by m.id) as digests
  from public.activity_context_jobs j
  join public.object_manifests m
    on m.user_id = j.user_id and m.device_id = j.device_id
   and m.object_kind = 'rawImuSession' and m.status = 'ready'
   and m.sha256 is not null and m.start_at is not null and m.end_at is not null
   and m.start_at < ((j.day + 1)::timestamp at time zone 'UTC')
   and m.end_at > (j.day::timestamp at time zone 'UTC')
   and (m.end_at - m.start_at) <= interval '8 days'
  where j.algorithm_version = 'hart-activity-1'
  group by j.user_id, j.device_id, j.day
)
update public.activity_context_jobs j
   set input_object_ids = c.ids, input_digests = c.digests
  from current_inputs c
 where j.algorithm_version = 'hart-activity-1'
   and j.user_id = c.user_id and j.device_id = c.device_id and j.day = c.day
   and (j.input_object_ids is distinct from c.ids or j.input_digests is distinct from c.digests);

-- Re-queue the jobs the misalignment failed (never one that holds a live lease).
update public.activity_context_jobs
   set dead_letter = false, consecutive_failures = 0, not_before = clock_timestamp(),
       last_error = null, input_revision = input_revision + 1, dirty_at = clock_timestamp(),
       reason = 'input'
 where algorithm_version = 'hart-activity-1'
   and (last_error like '%digest_mismatch%' or last_error like '%job_digest_count_mismatch%')
   and (lease_until is null or lease_until <= clock_timestamp());

commit;
