-- Activity ground truth labels: what a person actually did during a labelled interval, captured
-- during guided calibration (source='guided'), from stretch-feedback corrections
-- (source='stretch_feedback') or imported (source='imported'). Stored separately from every model
-- output so a label can never be overwritten by a prediction; raw 100 Hz IMU stays in B2 and this
-- table only references it through raw_refs (object_manifests id + digest + start/end).
-- Additive only: one new owner-scoped table and one service-role-only SECURITY DEFINER RPC. Nothing
-- reads these rows to score, display or classify anything.
--
-- Write path: the `scores` edge function (POST /ground-truth-labels) authenticates the installation
-- or account, validates every item, resolves the optional device, enriches raw_refs server-side
-- from object_manifests, and calls upsert_activity_ground_truth_labels with the owner taken from
-- the credential. No client role can insert, update or delete: the only client privilege is SELECT
-- on its own rows.
--
-- Upsert semantics: one row per (owner, label_key), where label_key is stable per
-- (source, session-or-stretch, start_ts[, repetition]). Last writer wins on client_updated_at: an
-- incoming item OLDER than the stored one is reported as ignored/stale and changes nothing;
-- otherwise every mutable column is overwritten and `revision` is bumped by one (it starts at 1).
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table if not exists public.activity_ground_truth_labels (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references auth.users(id) on delete cascade,
  client_id uuid not null,
  label_key text not null
    check (char_length(label_key) between 1 and 96 and label_key ~ '^[A-Za-z0-9:_.-]+$'),
  source text not null check (source in ('guided', 'stretch_feedback', 'imported')),
  session_id text check (session_id is null or char_length(session_id) between 1 and 64),
  protocol_version text check (protocol_version is null or char_length(protocol_version) between 1 and 32),
  repetition integer check (repetition is null or repetition >= 0),
  device_id uuid references public.devices(id) on delete set null,
  external_device_id text
    check (external_device_id is null or char_length(external_device_id) between 1 and 255),
  start_ts bigint not null check (start_ts > 946684800),
  end_ts bigint not null,
  posture text check (posture is null or posture in (
    'recumbent', 'seated_likely', 'upright_stationary', 'postural_transition', 'unknown')),
  locomotion text check (locomotion is null or locomotion in (
    'stationary', 'walking', 'brisk_walking', 'running', 'stairs', 'cycling', 'vehicle_motion',
    'other', 'unknown')),
  arm_behavior text check (arm_behavior is null or arm_behavior in (
    'quiet', 'desk_like', 'fidgeting', 'repetitive_hand_motion', 'active_gesturing',
    'exercise_motion', 'other', 'unknown')),
  transition_kind text check (transition_kind is null or transition_kind in (
    'sit_to_stand', 'stand_to_sit', 'lying_down', 'getting_up', 'walk_start', 'walk_stop',
    'run_start', 'run_stop')),
  transition_ts bigint
    check (transition_ts is null or (transition_ts >= start_ts and transition_ts <= end_ts)),
  semantic_tag text check (semantic_tag is null or semantic_tag in (
    'typing', 'mouse_work', 'phone_use', 'writing', 'eating', 'reading', 'fidgeting', 'desk_work')),
  label_confidence real
    check (label_confidence is null or (label_confidence >= 0 and label_confidence <= 1)),
  user_unsure boolean not null default false,
  note text check (note is null or char_length(note) <= 280),
  -- The edge function caps each compact JSON at 16 KiB. jsonb renders with a space after every ':'
  -- and ',', which can add up to about half again, so the database bound leaves room for that and
  -- only exists to stop a runaway row, never to reject something the edge function accepted.
  cue_context jsonb not null default '{}'::jsonb
    check (jsonb_typeof(cue_context) = 'object' and octet_length(cue_context::text) <= 32768),
  sensor_quality jsonb not null default '{}'::jsonb
    check (jsonb_typeof(sensor_quality) = 'object' and octet_length(sensor_quality::text) <= 32768),
  -- raw_refs is capped tighter than the object fields: it is a list of manifest references, each of
  -- which is tiny, and the upsert RPC re-caps it after server-side enrichment, so 16 KiB of jsonb
  -- text is plenty for the maximum 64 references.
  raw_refs jsonb not null default '[]'::jsonb
    check (jsonb_typeof(raw_refs) = 'array' and octet_length(raw_refs::text) <= 16384),
  model_context_at_label_time jsonb not null default '{}'::jsonb
    check (jsonb_typeof(model_context_at_label_time) = 'object' and octet_length(model_context_at_label_time::text) <= 32768),
  app_version text check (app_version is null or char_length(app_version) between 1 and 32),
  app_build text check (app_build is null or char_length(app_build) between 1 and 32),
  tz_offset_s integer check (tz_offset_s is null or tz_offset_s between -64800 and 64800),
  client_created_at timestamptz,
  client_updated_at timestamptz not null,
  revision integer not null default 1 check (revision >= 1),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  constraint activity_ground_truth_labels_owner_label_key_key unique (owner, label_key),
  check (end_ts > start_ts and end_ts - start_ts <= 86400)
);

create index if not exists activity_ground_truth_labels_owner_start_idx
  on public.activity_ground_truth_labels (owner, start_ts);
create index if not exists activity_ground_truth_labels_source_idx
  on public.activity_ground_truth_labels (source);
create index if not exists activity_ground_truth_labels_device_idx
  on public.activity_ground_truth_labels (device_id) where device_id is not null;

-- Owner-readable (select only). Writes are service-role only, through the RPC below.
alter table public.activity_ground_truth_labels enable row level security;
revoke all on public.activity_ground_truth_labels from public, anon, authenticated;
grant all on public.activity_ground_truth_labels to service_role;
grant select on public.activity_ground_truth_labels to authenticated;

drop policy if exists activity_ground_truth_labels_service on public.activity_ground_truth_labels;
create policy activity_ground_truth_labels_service on public.activity_ground_truth_labels
  for all to service_role using (true) with check (true);
drop policy if exists activity_ground_truth_labels_select_own on public.activity_ground_truth_labels;
create policy activity_ground_truth_labels_select_own on public.activity_ground_truth_labels
  for select to authenticated using ((select auth.uid()) = owner);

-- The one write path. p_items is a JSON array of 1 to 25 items that the edge function has already
-- validated; the table's CHECK constraints are the backstop and raise (rolling the whole call back)
-- if one was missed. The device is optional: a device that does not belong to p_owner is stored as
-- NULL rather than failing the item. The ownership check is repeated here so a bug in the caller
-- can never attach a row to another account's device.
--
-- raw_refs enrichment (spec 8.2): the phone sends its own facts about the interval; the server
-- appends one reference per ready rawImuSession object_manifests row that overlaps the label
-- interval and belongs to the same owner (and device when one resolved), ordered by start. The
-- combined array is capped at 64 references and 16 KiB of jsonb text so the table's raw_refs CHECK
-- stays satisfied even when the client's own array is at its 16 KiB edge (jsonb's text form is
-- larger than the compact JSON the edge function measures).
create or replace function public.upsert_activity_ground_truth_labels(p_owner uuid, p_items jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_item jsonb;
  v_device uuid;
  v_revision integer;
  v_saved jsonb := '[]'::jsonb;
  v_ignored jsonb := '[]'::jsonb;
  v_raw_refs jsonb;
  v_server_refs jsonb;
begin
  if p_owner is null then
    raise exception 'invalid_owner' using errcode = '22023';
  end if;
  if auth.uid() is not null and auth.uid() is distinct from p_owner then
    raise exception 'cross_user_caller' using errcode = '42501';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) not between 1 and 25 then
    raise exception 'invalid_items' using errcode = '22023';
  end if;

  for v_item in
    select e.value from jsonb_array_elements(p_items) with ordinality as e(value, ord) order by e.ord
  loop
    v_device := nullif(v_item ->> 'device_id', '')::uuid;
    if v_device is not null
       and not exists (select 1 from public.devices d where d.id = v_device and d.user_id = p_owner) then
      v_device := null;
    end if;

    v_raw_refs := coalesce(v_item -> 'raw_refs', '[]'::jsonb);
    if jsonb_typeof(v_raw_refs) is distinct from 'array' then
      v_raw_refs := '[]'::jsonb;
    end if;
    select coalesce(jsonb_agg(
        jsonb_build_object(
          'id', m.id::text,
          'object_key', m.object_key,
          'sha256', m.sha256,
          'start_ts', extract(epoch from m.start_at)::bigint,
          'end_ts', extract(epoch from m.end_at)::bigint)
        order by m.start_at), '[]'::jsonb)
      into v_server_refs
      from public.object_manifests m
      where m.user_id = p_owner
        and m.object_kind = 'rawImuSession'
        and m.status = 'ready'
        and m.start_at is not null and m.end_at is not null
        and m.start_at <= to_timestamp((v_item ->> 'end_ts')::bigint)
        and m.end_at >= to_timestamp((v_item ->> 'start_ts')::bigint)
        and (v_device is null or m.device_id = v_device);
    v_raw_refs := v_raw_refs || v_server_refs;
    if jsonb_array_length(v_raw_refs) > 64 then
      v_raw_refs := (select jsonb_agg(s.e order by s.ord)
        from (select x.e, x.ord from jsonb_array_elements(v_raw_refs) with ordinality as x(e, ord)
              order by x.ord limit 64) s);
    end if;
    while octet_length(v_raw_refs::text) > 16384 and jsonb_array_length(v_raw_refs) > 0 loop
      v_raw_refs := coalesce((select jsonb_agg(s.e order by s.ord)
        from (select x.e, x.ord from jsonb_array_elements(v_raw_refs) with ordinality as x(e, ord)
              order by x.ord limit (jsonb_array_length(v_raw_refs) - 1)) s), '[]'::jsonb);
    end loop;

    v_revision := null;
    insert into public.activity_ground_truth_labels as f (
      owner, client_id, label_key, source, session_id, protocol_version, repetition, device_id,
      external_device_id, start_ts, end_ts, posture, locomotion, arm_behavior, transition_kind,
      transition_ts, semantic_tag, label_confidence, user_unsure, note, cue_context, sensor_quality,
      raw_refs, model_context_at_label_time, app_version, app_build, tz_offset_s, client_created_at,
      client_updated_at)
    values (
      p_owner, (v_item ->> 'client_id')::uuid, v_item ->> 'label_key', v_item ->> 'source',
      v_item ->> 'session_id', v_item ->> 'protocol_version', (v_item ->> 'repetition')::integer,
      v_device, v_item ->> 'external_device_id', (v_item ->> 'start_ts')::bigint,
      (v_item ->> 'end_ts')::bigint, v_item ->> 'posture', v_item ->> 'locomotion',
      v_item ->> 'arm_behavior', v_item ->> 'transition_kind', (v_item ->> 'transition_ts')::bigint,
      v_item ->> 'semantic_tag', (v_item ->> 'label_confidence')::real,
      coalesce((v_item ->> 'user_unsure')::boolean, false), v_item ->> 'note',
      coalesce(v_item -> 'cue_context', '{}'::jsonb), coalesce(v_item -> 'sensor_quality', '{}'::jsonb),
      v_raw_refs, coalesce(v_item -> 'model_context_at_label_time', '{}'::jsonb),
      v_item ->> 'app_version', v_item ->> 'app_build', (v_item ->> 'tz_offset_s')::integer,
      (v_item ->> 'client_created_at')::timestamptz, (v_item ->> 'client_updated_at')::timestamptz)
    on conflict (owner, label_key) do update set
      client_id = excluded.client_id,
      source = excluded.source,
      session_id = excluded.session_id,
      protocol_version = excluded.protocol_version,
      repetition = excluded.repetition,
      device_id = excluded.device_id,
      external_device_id = excluded.external_device_id,
      start_ts = excluded.start_ts,
      end_ts = excluded.end_ts,
      posture = excluded.posture,
      locomotion = excluded.locomotion,
      arm_behavior = excluded.arm_behavior,
      transition_kind = excluded.transition_kind,
      transition_ts = excluded.transition_ts,
      semantic_tag = excluded.semantic_tag,
      label_confidence = excluded.label_confidence,
      user_unsure = excluded.user_unsure,
      note = excluded.note,
      cue_context = excluded.cue_context,
      sensor_quality = excluded.sensor_quality,
      raw_refs = excluded.raw_refs,
      model_context_at_label_time = excluded.model_context_at_label_time,
      app_version = excluded.app_version,
      app_build = excluded.app_build,
      tz_offset_s = excluded.tz_offset_s,
      client_created_at = coalesce(excluded.client_created_at, f.client_created_at),
      client_updated_at = excluded.client_updated_at,
      revision = f.revision + 1,
      updated_at = clock_timestamp()
    where f.client_updated_at <= excluded.client_updated_at
    returning f.revision into v_revision;

    if v_revision is null then
      v_ignored := v_ignored || jsonb_build_array(
        jsonb_build_object('label_key', v_item ->> 'label_key', 'reason', 'stale'));
    else
      v_saved := v_saved || jsonb_build_array(
        jsonb_build_object('label_key', v_item ->> 'label_key', 'revision', v_revision));
    end if;
  end loop;

  return jsonb_build_object('saved', v_saved, 'ignored', v_ignored);
end;
$$;

revoke all on function public.upsert_activity_ground_truth_labels(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.upsert_activity_ground_truth_labels(uuid, jsonb) to service_role;

comment on table public.activity_ground_truth_labels is
  'Ground-truth activity labels from guided calibration, stretch-feedback corrections and imports: what a person actually did over an interval, stored separately from model output. One row per (owner, label_key); last writer wins on client_updated_at. raw_refs references the raw IMU object_manifests covering the interval. Written only through upsert_activity_ground_truth_labels.';
comment on column public.activity_ground_truth_labels.owner is 'Owning user (auth.users). RLS: the owner may read own rows; no client role can write.';
comment on column public.activity_ground_truth_labels.client_id is 'Record id the app generated for this label.';
comment on column public.activity_ground_truth_labels.label_key is 'Stable per (source, session-or-stretch, start_ts[, repetition]), e.g. guided:activity-session:1760072000, so re-labelling an interval overwrites its row.';
comment on column public.activity_ground_truth_labels.source is 'Where the label came from: guided calibration, stretch_feedback corrections or imported.';
comment on column public.activity_ground_truth_labels.device_id is 'Internal device the interval was recorded on; NULL when the app sent none or it does not resolve to a device the owner has.';
comment on column public.activity_ground_truth_labels.external_device_id is 'The app''s own device id as sent, kept so a device that registers later can still be matched.';
comment on column public.activity_ground_truth_labels.transition_ts is 'When a definitive transition happened, inside the label interval.';
comment on column public.activity_ground_truth_labels.user_unsure is 'True when the person said the label is uncertain; an unsure response must never become a hard training label.';
comment on column public.activity_ground_truth_labels.cue_context is 'Guided-capture cue timeline (instruction/countdown/cue/interval timestamps). A JSON object; the edge function caps it at 16 KiB.';
comment on column public.activity_ground_truth_labels.sensor_quality is 'Coverage facts the phone measured over the interval (expected/covered seconds, gaps, sample rate). A JSON object; the edge function caps it at 16 KiB.';
comment on column public.activity_ground_truth_labels.raw_refs is 'Raw evidence references: the phone''s own facts plus one entry per ready rawImuSession object_manifests row overlapping the interval ({id, object_key, sha256, start_ts, end_ts}). Capped at 64 entries and 16 KiB.';
comment on column public.activity_ground_truth_labels.model_context_at_label_time is 'What the model/rules output at the moment the label was made (probabilities, basis, versions). A JSON object; the edge function caps it at 16 KiB.';
comment on column public.activity_ground_truth_labels.client_updated_at is 'When the person last changed this label on the phone; the last-writer-wins clock.';
comment on column public.activity_ground_truth_labels.revision is 'Starts at 1; bumped by one every time the row is overwritten.';

commit;
