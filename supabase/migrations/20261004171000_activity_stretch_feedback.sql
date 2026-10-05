-- Activity stretch feedback: what a person said about one detected stretch on the "Full day and
-- activity timeline" page ("this is right" / "this is wrong, it was actually X"), stored together with
-- what the model predicted so the labels can later be used to tune the model.
-- Additive only: one new owner-scoped table and one service-role-only SECURITY DEFINER RPC. Nothing
-- reads these rows to score, display or classify anything.
--
-- Write path: the `scores` edge function (POST /stretch-feedback) authenticates the installation or
-- account, validates every item, resolves the optional device, and calls
-- upsert_activity_stretch_feedback with the owner taken from the credential. No client role can insert,
-- update or delete: the only client privilege is SELECT on its own rows.
--
-- Upsert semantics: one row per (owner, stretch_key), where stretch_key is stable per (kind, start), so
-- re-validating a stretch overwrites its row. Last writer wins on client_updated_at: an incoming item
-- OLDER than the stored one is reported as ignored/stale and changes nothing; otherwise every mutable
-- column is overwritten and `revision` is bumped by one (it starts at 1).
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table if not exists public.activity_stretch_feedback (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references auth.users(id) on delete cascade,
  client_id uuid not null,
  stretch_key text not null
    check (char_length(stretch_key) between 1 and 96 and stretch_key ~ '^[A-Za-z0-9:_.-]+$'),
  kind text not null check (kind in ('activity_context', 'strap_state')),
  device_id uuid references public.devices(id) on delete set null,
  external_device_id text
    check (external_device_id is null or char_length(external_device_id) between 1 and 255),
  start_ts bigint not null check (start_ts > 946684800),
  end_ts bigint not null,
  predicted_label text not null check (char_length(predicted_label) between 1 and 64),
  predicted_class text check (predicted_class is null or char_length(predicted_class) between 1 and 64),
  predicted_confidence real
    check (predicted_confidence is null or (predicted_confidence >= 0 and predicted_confidence <= 1)),
  verdict text not null check (verdict in ('correct', 'incorrect')),
  corrected_label text check (corrected_label is null or corrected_label in (
    'sitting', 'standing', 'lying_down', 'asleep', 'walking', 'running', 'cycling', 'in_vehicle',
    'exercise', 'other_movement', 'not_wearing', 'other')),
  note text check (note is null or char_length(note) <= 280),
  -- The edge function caps the compact JSON at 16 KiB. jsonb renders with a space after every ':' and
  -- ',', which can add up to about half again, so the database bound leaves room for that and only
  -- exists to stop a runaway row, never to reject something the edge function accepted.
  model_context jsonb not null default '{}'::jsonb
    check (jsonb_typeof(model_context) = 'object' and octet_length(model_context::text) <= 32768),
  app_version text check (app_version is null or char_length(app_version) between 1 and 32),
  app_build text check (app_build is null or char_length(app_build) between 1 and 32),
  tz_offset_s integer check (tz_offset_s is null or tz_offset_s between -64800 and 64800),
  client_created_at timestamptz,
  client_updated_at timestamptz not null,
  revision integer not null default 1 check (revision >= 1),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  constraint activity_stretch_feedback_owner_stretch_key_key unique (owner, stretch_key),
  check (end_ts > start_ts and end_ts - start_ts <= 86400),
  check (verdict = 'incorrect' or corrected_label is null)
);

create index if not exists activity_stretch_feedback_owner_start_idx
  on public.activity_stretch_feedback (owner, start_ts);
create index if not exists activity_stretch_feedback_tuning_idx
  on public.activity_stretch_feedback (kind, verdict, predicted_class);
create index if not exists activity_stretch_feedback_device_idx
  on public.activity_stretch_feedback (device_id) where device_id is not null;

-- Owner-readable (select only). Writes are service-role only, through the RPC below.
alter table public.activity_stretch_feedback enable row level security;
revoke all on public.activity_stretch_feedback from public, anon, authenticated;
grant all on public.activity_stretch_feedback to service_role;
grant select on public.activity_stretch_feedback to authenticated;

drop policy if exists activity_stretch_feedback_service on public.activity_stretch_feedback;
create policy activity_stretch_feedback_service on public.activity_stretch_feedback
  for all to service_role using (true) with check (true);
drop policy if exists activity_stretch_feedback_select_own on public.activity_stretch_feedback;
create policy activity_stretch_feedback_select_own on public.activity_stretch_feedback
  for select to authenticated using ((select auth.uid()) = owner);

-- The one write path. p_items is a JSON array of 1 to 25 items that the edge function has already
-- validated; the table's CHECK constraints are the backstop and raise (rolling the whole call back) if
-- one was missed. The device is optional: a device that does not belong to p_owner is stored as NULL
-- rather than failing the item. The ownership check is repeated here so a bug in the caller can never
-- attach a row to another account's device.
create or replace function public.upsert_activity_stretch_feedback(p_owner uuid, p_items jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_item jsonb;
  v_device uuid;
  v_revision integer;
  v_saved jsonb := '[]'::jsonb;
  v_ignored jsonb := '[]'::jsonb;
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

    v_revision := null;
    insert into public.activity_stretch_feedback as f (
      owner, client_id, stretch_key, kind, device_id, external_device_id, start_ts, end_ts,
      predicted_label, predicted_class, predicted_confidence, verdict, corrected_label, note,
      model_context, app_version, app_build, tz_offset_s, client_created_at, client_updated_at)
    values (
      p_owner, (v_item ->> 'client_id')::uuid, v_item ->> 'stretch_key', v_item ->> 'kind', v_device,
      v_item ->> 'external_device_id', (v_item ->> 'start_ts')::bigint, (v_item ->> 'end_ts')::bigint,
      v_item ->> 'predicted_label', v_item ->> 'predicted_class',
      (v_item ->> 'predicted_confidence')::real, v_item ->> 'verdict', v_item ->> 'corrected_label',
      v_item ->> 'note', coalesce(v_item -> 'model_context', '{}'::jsonb), v_item ->> 'app_version',
      v_item ->> 'app_build', (v_item ->> 'tz_offset_s')::integer,
      (v_item ->> 'client_created_at')::timestamptz, (v_item ->> 'client_updated_at')::timestamptz)
    on conflict (owner, stretch_key) do update set
      client_id = excluded.client_id,
      kind = excluded.kind,
      device_id = excluded.device_id,
      external_device_id = excluded.external_device_id,
      start_ts = excluded.start_ts,
      end_ts = excluded.end_ts,
      predicted_label = excluded.predicted_label,
      predicted_class = excluded.predicted_class,
      predicted_confidence = excluded.predicted_confidence,
      verdict = excluded.verdict,
      corrected_label = excluded.corrected_label,
      note = excluded.note,
      model_context = excluded.model_context,
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
        jsonb_build_object('stretch_key', v_item ->> 'stretch_key', 'reason', 'stale'));
    else
      v_saved := v_saved || jsonb_build_array(
        jsonb_build_object('stretch_key', v_item ->> 'stretch_key', 'revision', v_revision));
    end if;
  end loop;

  return jsonb_build_object('saved', v_saved, 'ignored', v_ignored);
end;
$$;

revoke all on function public.upsert_activity_stretch_feedback(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.upsert_activity_stretch_feedback(uuid, jsonb) to service_role;

comment on table public.activity_stretch_feedback is
  'Model-tuning labels from users: a verdict (correct/incorrect, optional corrected label) on one detected activity or strap-state stretch, stored with what the model predicted for it. One row per (owner, stretch_key); last writer wins on client_updated_at. Written only through upsert_activity_stretch_feedback.';
comment on column public.activity_stretch_feedback.owner is 'Owning user (auth.users). RLS: the owner may read own rows; no client role can write.';
comment on column public.activity_stretch_feedback.client_id is 'Record id the app generated for this feedback.';
comment on column public.activity_stretch_feedback.stretch_key is 'Stable per (kind, start), e.g. activity_context:1760072000, so re-validating a stretch overwrites its row.';
comment on column public.activity_stretch_feedback.device_id is 'Internal device the stretch was recorded on; NULL when the app sent none or it does not resolve to a device the owner has.';
comment on column public.activity_stretch_feedback.external_device_id is 'The app''s own device id as sent, kept so a device that registers later can still be matched.';
comment on column public.activity_stretch_feedback.predicted_class is 'Machine class code the model gave the stretch; predicted_label is the human label the person saw.';
comment on column public.activity_stretch_feedback.model_context is 'What the model/rules output for this stretch (probabilities, basis, stats, versions). A JSON object; the edge function caps it at 16 KiB.';
comment on column public.activity_stretch_feedback.client_updated_at is 'When the person last changed this feedback on the phone; the last-writer-wins clock.';
comment on column public.activity_stretch_feedback.revision is 'Starts at 1; bumped by one every time the row is overwritten.';

commit;
