-- RecGym gym-exercise recognition, SHADOW storage (Tools/ActivityContext/RECGYM.md §6).
-- One row per 4 s window (owner, strap, model, window start): the model's 12 class probabilities (RecGym's eleven
-- workouts + Null), the top class, P(Null), the digest of the raw seconds the window covers, the model identity
-- (version, checkpoint sha256, reproduced scaler version, preprocessing version), the placement the strap was
-- declared at for that instant and whether the wrist-trained model supports it, the release (always shadow) and the
-- job lineage (UTC day, job fingerprint, input revision, result revision, computed_at).
--
-- SHADOW ONLY. Nothing reads this table for scoring, the activity documents, the Watchdog or the exercise-session
-- rule (exercise-session-1); no publish function, queue or existing read changes. `release_mode` is constrained to
-- 'shadow' and the publish function refuses an authority block that claims more (it goes through the shared
-- `internal.activity_expert_release` lowering). Promotion would be a new migration plus an owner decision.
--
-- Additive and idempotent (`if not exists`, `create or replace`): a table, a sequence, a BRIN index, a fenced
-- publish function (the same lease + revision fence as publish_activity_gait_windows_day; called by the worker
-- under a savepoint before the v1 publish, so a rejection never reaches the other publishes) and a retention
-- function. Rollback = FRWHOOP_EXERCISE_ENABLED off in the worker; the table can stay.
--
-- Placement: resolved here, per window, from internal.placement_intervals_for_device_v1 (20261009150100: the strap,
-- its aliases and bound installations; a device-scoped piece wins over an owner-level declaration, then the latest
-- effective_start, then the highest revision). wrist -> supported; bicep / other -> placement_unsupported
-- (confirmed); unknown or undeclared -> placement_unknown (contracts/reason-codes.json). Nothing is back-filled:
-- an undeclared instant stays NULL.
--
-- Size: a row is ~0.6 KB; a strap capturing raw IMU all day yields 43,200 windows. The worker sends a chunk's
-- windows only when that chunk's answer changed (most pushes: the newest chunk), the upsert skips identical rows,
-- and prune_activity_exercise_windows deletes windows older than the worker's retention (14 days by default).
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table if not exists public.activity_exercise_windows (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  model_id text not null check (model_id = 'recgym-cnn-transformer'),
  window_start timestamptz not null,
  window_s smallint not null check (window_s = 4),
  model_version text not null check (model_version ~ '^[A-Za-z0-9][A-Za-z0-9._:+-]{0,127}$'),
  weights_sha256 text not null check (weights_sha256 ~ '^[0-9a-f]{64}$'),
  scaler_version text not null check (scaler_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
  preprocessing_version text not null check (preprocessing_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
  -- The declared placement at window_start (NULL: undeclared) and what it means for a wrist-trained model.
  placement text check (placement is null or placement in ('wrist', 'bicep', 'other', 'unknown')),
  placement_supported boolean not null,
  placement_reason text check (placement_reason is null
                               or placement_reason in ('placement_unsupported', 'placement_unknown')),
  top_class text not null check (top_class in ('Adductor', 'ArmCurl', 'BenchPress', 'LegCurl', 'LegPress', 'Null',
                                               'Riding', 'RopeSkipping', 'Running', 'Squat', 'StairClimber',
                                               'Walking')),
  top_p real not null check (top_p >= 0 and top_p <= 1),
  p_null real not null check (p_null >= 0 and p_null <= 1),
  -- class -> probability, the twelve classes above (rounded to 4 decimals by the worker).
  probs jsonb not null check (jsonb_typeof(probs) = 'object'),
  -- sha256 of the raw int16 columns of the four seconds the window covers (the input fingerprint).
  input_sha256 text not null check (input_sha256 ~ '^[0-9a-f]{64}$'),
  release_mode text not null default 'shadow' check (release_mode = 'shadow'),
  -- Lineage: the activity job that published the window.
  day date not null,
  job_fingerprint text not null check (job_fingerprint ~ '^[0-9a-f]{64}$'),
  input_revision bigint not null check (input_revision >= 1),
  result_revision bigint not null,
  computed_at timestamptz not null,
  primary key (user_id, device_id, model_id, window_start),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade,
  check (placement_supported = (placement is not distinct from 'wrist')),
  check (placement_reason is not distinct from case when placement = 'wrist' then null
                                                    when placement in ('bicep', 'other') then 'placement_unsupported'
                                                    else 'placement_unknown' end)
);
create sequence if not exists public.activity_exercise_windows_result_revision_seq;
grant usage, select on sequence public.activity_exercise_windows_result_revision_seq to service_role;
-- Retention scans by time across owners; windows arrive roughly in time order, so BRIN stays tiny.
create index if not exists activity_exercise_windows_start_brin
  on public.activity_exercise_windows using brin (window_start);

-- Worker-written, owner-readable (select only), like the other activity expert tables.
alter table public.activity_exercise_windows enable row level security;
revoke all on public.activity_exercise_windows from public, anon, authenticated;
grant all on public.activity_exercise_windows to service_role;
grant select on public.activity_exercise_windows to authenticated;
drop policy if exists activity_exercise_windows_service on public.activity_exercise_windows;
create policy activity_exercise_windows_service on public.activity_exercise_windows
  for all to service_role using (true) with check (true);
drop policy if exists activity_exercise_windows_select_own on public.activity_exercise_windows;
create policy activity_exercise_windows_select_own on public.activity_exercise_windows
  for select to authenticated using ((select auth.uid()) = user_id);

-- Fenced publication of a job's exercise windows. The lease must be alive and the revision current, otherwise NULL
-- and nothing is written. It does NOT complete the job, clear the lease or dirty scoring. A malformed payload
-- raises a stable message and writes nothing.
-- Payload (Tools/CloudWorker ActivityExerciseWindows.payload):
--   {"day": "YYYY-MM-DD", "schema": "exercise-windows-1",
--    "model": {model_id, model_version, weights_sha256, scaler_version, preprocessing_version, classes[12],
--              window_s: 4, hop_s: 2},
--    "authority": {policy: "expert-authority-1", channel: "exercise_recognition", mode: "shadow",
--                  release_mode: "shadow", use: "none", ...},
--    "spans": [[start_s, end_s], ...]   chunk bodies (unix s) whose windows are replaced as a whole,
--    "windows": [{"s": unix s (even), "fp": sha256, "p": [12 probabilities, classes order]}, ...]}
-- Inside each span, stored windows of this model that the payload no longer has are deleted (their chunk was
-- recomputed without them); every payload window must lie inside a span and inside the job's UTC day.
create or replace function public.publish_activity_exercise_windows(p_token uuid, p_revision bigint,
                                                                    p_payload jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare j public.activity_context_jobs; m jsonb; a jsonb; v_day date; lo bigint; hi bigint; rev bigint;
  computed timestamptz; n integer; classes text[] := array['Adductor', 'ArmCurl', 'BenchPress', 'LegCurl',
  'LegPress', 'Null', 'Riding', 'RopeSkipping', 'Running', 'Squat', 'StairClimber', 'Walking'];
  bad integer;
begin
  select * into j from public.activity_context_jobs where lease_token = p_token for update;
  if not found or j.lease_until <= clock_timestamp() or j.input_revision <> p_revision then return null; end if;

  if jsonb_typeof(p_payload) is distinct from 'object'
    or jsonb_typeof(p_payload -> 'day') is distinct from 'string'
    or (p_payload ->> 'day') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'invalid_exercise_windows_payload';
  end if;
  v_day := (p_payload ->> 'day')::date;
  if v_day is distinct from j.day then raise exception 'invalid_exercise_windows_payload'; end if;
  if octet_length(p_payload::text) > 16 * 1024 * 1024 then raise exception 'invalid_exercise_windows_size'; end if;
  if p_payload ->> 'schema' is distinct from 'exercise-windows-1' then
    raise exception 'invalid_exercise_windows_schema';
  end if;

  m := p_payload -> 'model';
  if jsonb_typeof(m) is distinct from 'object'
    or m ->> 'model_id' is distinct from 'recgym-cnn-transformer'
    or jsonb_typeof(m -> 'model_version') is distinct from 'string'
    or (m ->> 'model_version') !~ '^[A-Za-z0-9][A-Za-z0-9._:+-]{0,127}$'
    or jsonb_typeof(m -> 'weights_sha256') is distinct from 'string'
    or (m ->> 'weights_sha256') !~ '^[0-9a-f]{64}$'
    or jsonb_typeof(m -> 'scaler_version') is distinct from 'string'
    or (m ->> 'scaler_version') !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
    or jsonb_typeof(m -> 'preprocessing_version') is distinct from 'string'
    or (m ->> 'preprocessing_version') !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
    or (m -> 'classes') is distinct from to_jsonb(classes)
    or not internal.activity_day_num_ok(m -> 'window_s', 4, 4, true)
    or not internal.activity_day_num_ok(m -> 'hop_s', 2, 2, true) then
    raise exception 'invalid_exercise_windows_model';
  end if;

  -- The release: shadow, through the shared lowering; a block that claims anything else is refused, never stored.
  a := p_payload -> 'authority';
  if jsonb_typeof(a) is distinct from 'object'
    or a ->> 'policy' is distinct from 'expert-authority-1'
    or a ->> 'channel' is distinct from 'exercise_recognition'
    or a ->> 'mode' is distinct from 'shadow'
    or a ->> 'release_mode' is distinct from 'shadow'
    or a ->> 'use' is distinct from 'none'
    or internal.activity_expert_release(a ->> 'mode', a) is distinct from 'shadow' then
    raise exception 'invalid_exercise_windows_authority';
  end if;

  lo := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  hi := lo + 86400;
  if jsonb_typeof(p_payload -> 'spans') is distinct from 'array'
    or jsonb_array_length(p_payload -> 'spans') > 4000
    or jsonb_typeof(p_payload -> 'windows') is distinct from 'array'
    or jsonb_array_length(p_payload -> 'windows') > 100000 then
    raise exception 'invalid_exercise_windows_payload';
  end if;
  select count(*) into bad from jsonb_array_elements(p_payload -> 'spans') sp(v)
   where jsonb_typeof(v) is distinct from 'array' or jsonb_array_length(v) <> 2
      or not internal.activity_day_num_ok(v -> 0, lo, hi, true)
      or not internal.activity_day_num_ok(v -> 1, lo, hi, true)
      or (v ->> 0)::bigint >= (v ->> 1)::bigint;
  if bad > 0 then raise exception 'invalid_exercise_windows_spans'; end if;

  -- Windows: an even start inside the day and inside a span, a sha256, twelve probabilities in [0, 1] summing to 1.
  select count(*) into bad from jsonb_array_elements(p_payload -> 'windows') w(v)
   where jsonb_typeof(v) is distinct from 'object'
      or not internal.activity_day_num_ok(v -> 's', lo, hi - 4, true)
      or jsonb_typeof(v -> 'fp') is distinct from 'string' or (v ->> 'fp') !~ '^[0-9a-f]{64}$'
      or jsonb_typeof(v -> 'p') is distinct from 'array' or jsonb_array_length(v -> 'p') <> 12
      or exists (select 1 from jsonb_array_elements(v -> 'p') e(x)
                  where not internal.activity_day_num_ok(x, 0, 1, false));
  if bad > 0 then raise exception 'invalid_exercise_windows_windows'; end if;
  select count(*) into bad from jsonb_array_elements(p_payload -> 'windows') w(v)
   where (v ->> 's')::bigint % 2 <> 0
      or abs((select sum((x #>> '{}')::double precision) from jsonb_array_elements(v -> 'p') e(x)) - 1) > 0.002
      or not exists (select 1 from jsonb_array_elements(p_payload -> 'spans') sp(s)
                      where (v ->> 's')::bigint >= (s ->> 0)::bigint
                        and (v ->> 's')::bigint + 4 <= (s ->> 1)::bigint);
  if bad > 0 then raise exception 'invalid_exercise_windows_windows'; end if;
  select count(*) - count(distinct (v ->> 's')) into bad from jsonb_array_elements(p_payload -> 'windows') w(v);
  if bad > 0 then raise exception 'invalid_exercise_windows_windows'; end if;

  computed := clock_timestamp();
  rev := nextval('public.activity_exercise_windows_result_revision_seq');

  -- Replace each span: windows of this model inside it that the payload no longer carries are removed.
  with sp as (
    select (s ->> 0)::bigint as a, (s ->> 1)::bigint as b from jsonb_array_elements(p_payload -> 'spans') x(s)
  ), keep as (
    select to_timestamp((v ->> 's')::bigint) as ws from jsonb_array_elements(p_payload -> 'windows') w(v)
  )
  delete from public.activity_exercise_windows e
   using sp
   where e.user_id = j.user_id and e.device_id = j.device_id and e.model_id = 'recgym-cnn-transformer'
     and e.window_start >= to_timestamp(sp.a) and e.window_start <= to_timestamp(sp.b - 4)
     and not exists (select 1 from keep where keep.ws = e.window_start);

  with pw as (
    select (v ->> 's')::bigint as s, v ->> 'fp' as fp, v -> 'p' as p
      from jsonb_array_elements(p_payload -> 'windows') w(v)
  ), placed as (
    select r.effective_start, r.effective_end, r.placement, r.scope, r.revision
      from internal.placement_intervals_for_device_v1(j.user_id, j.device_id,
             to_timestamp(coalesce((select min(s) from pw), lo)), to_timestamp(coalesce((select max(s) from pw), lo) + 4)) r
  ), scored as (
    select pw.s, pw.fp,
           (select jsonb_object_agg(classes[k::integer], round((x #>> '{}')::numeric, 4))
              from jsonb_array_elements(pw.p) with ordinality e(x, k)) as probs,
           (select classes[k::integer] from jsonb_array_elements(pw.p) with ordinality e(x, k)
             order by (x #>> '{}')::double precision desc, k limit 1) as top_class,
           (select max((x #>> '{}')::double precision) from jsonb_array_elements(pw.p) e(x)) as top_p,
           (pw.p ->> 5)::double precision as p_null,
           (select pl.placement from placed pl
             where pl.effective_start <= to_timestamp(pw.s)
               and (pl.effective_end is null or pl.effective_end > to_timestamp(pw.s))
             order by (pl.scope = 'device') desc, pl.effective_start desc, pl.revision desc limit 1) as placement
      from pw
  )
  insert into public.activity_exercise_windows(user_id, device_id, model_id, window_start, window_s, model_version,
    weights_sha256, scaler_version, preprocessing_version, placement, placement_supported, placement_reason,
    top_class, top_p, p_null, probs, input_sha256, release_mode, day, job_fingerprint, input_revision,
    result_revision, computed_at)
  select j.user_id, j.device_id, 'recgym-cnn-transformer', to_timestamp(sc.s), 4, m ->> 'model_version',
         m ->> 'weights_sha256', m ->> 'scaler_version', m ->> 'preprocessing_version', sc.placement,
         sc.placement is not distinct from 'wrist',
         case when sc.placement = 'wrist' then null
              when sc.placement in ('bicep', 'other') then 'placement_unsupported'
              else 'placement_unknown' end,
         sc.top_class, sc.top_p, sc.p_null, sc.probs, sc.fp, internal.activity_expert_release(a ->> 'mode', a),
         j.day, j.fingerprint, j.input_revision, rev, computed
    from scored sc
  on conflict (user_id, device_id, model_id, window_start) do update set
    window_s = excluded.window_s, model_version = excluded.model_version, weights_sha256 = excluded.weights_sha256,
    scaler_version = excluded.scaler_version, preprocessing_version = excluded.preprocessing_version,
    placement = excluded.placement, placement_supported = excluded.placement_supported,
    placement_reason = excluded.placement_reason, top_class = excluded.top_class, top_p = excluded.top_p,
    p_null = excluded.p_null, probs = excluded.probs, input_sha256 = excluded.input_sha256,
    release_mode = excluded.release_mode, day = excluded.day, job_fingerprint = excluded.job_fingerprint,
    input_revision = excluded.input_revision, result_revision = excluded.result_revision,
    computed_at = excluded.computed_at
  -- An identical window (same input, model, placement and outputs) is left as it is: no new row version.
  where (activity_exercise_windows.input_sha256, activity_exercise_windows.model_version,
         activity_exercise_windows.weights_sha256, activity_exercise_windows.scaler_version,
         activity_exercise_windows.preprocessing_version, activity_exercise_windows.probs,
         activity_exercise_windows.placement)
        is distinct from
        (excluded.input_sha256, excluded.model_version, excluded.weights_sha256, excluded.scaler_version,
         excluded.preprocessing_version, excluded.probs, excluded.placement);
  get diagnostics n = row_count;
  return rev;
end $$;
revoke all on function public.publish_activity_exercise_windows(uuid, bigint, jsonb) from public, anon, authenticated;
grant execute on function public.publish_activity_exercise_windows(uuid, bigint, jsonb) to service_role;

-- Retention: deletes at most p_max_rows windows that started more than p_keep_days days ago (oldest first) and
-- returns how many. The worker calls it every few hours while the head is on; without the worker:
--   select public.prune_activity_exercise_windows(14, 50000);
create or replace function public.prune_activity_exercise_windows(p_keep_days integer default 14,
                                                                  p_max_rows integer default 50000)
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if p_keep_days is null or p_keep_days < 1 or p_keep_days > 3650
    or p_max_rows is null or p_max_rows < 1 or p_max_rows > 1000000 then
    raise exception 'invalid_exercise_windows_retention';
  end if;
  with doomed as (
    select ctid from public.activity_exercise_windows
     where window_start < clock_timestamp() - make_interval(days => p_keep_days)
     order by window_start
     limit p_max_rows
  )
  delete from public.activity_exercise_windows d using doomed where d.ctid = doomed.ctid;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.prune_activity_exercise_windows(integer, integer) from public, anon, authenticated;
grant execute on function public.prune_activity_exercise_windows(integer, integer) to service_role;

commit;
