-- Supabase Auth–provisioned installations.
--
-- An app installation used to obtain its upload credential by redeeming an ops-issued enrollment
-- code, and every use of that credential also required a shared fleet token. This migration lets a
-- verified Supabase Auth session provision the installation instead.
--
-- Trust boundary: the Edge function validates the caller's Supabase JWT against Auth, takes the
-- owner from that verified session, generates a high-entropy token itself and passes only the
-- token's SHA-256 hash here. Nothing a client sends can name a different owner, and the plaintext
-- credential never reaches Postgres. Everything downstream (source/device ownership, retirement,
-- admission, object-PUT authorization, RLS) already keys on noop_app_installations(user_id,
-- source_id) plus the hashed installation token, so none of it is weakened: a source id can still
-- only ever belong to the user it was first bound to (noop_installation_immutable), retirement is
-- still permanent, and the one-active-token-per-installation index still holds.
--
-- Enrollment-code provenance is kept, not deleted: rows created by redeem_noop_enrollment retain
-- provisioning_method = 'enrollment_code' and keep their code, so the legacy compatibility path
-- (disabled by default at the Edge) continues to resolve exactly as before.
begin;

-- 1. Provenance ------------------------------------------------------------------------------

alter table public.noop_app_installations
  add column provisioning_method text not null default 'enrollment_code',
  alter column enrollment_code_id drop not null;

alter table public.noop_app_installations
  add constraint noop_app_installations_provisioning_check check (
    (provisioning_method = 'enrollment_code' and enrollment_code_id is not null)
    or (provisioning_method = 'supabase_auth' and enrollment_code_id is null)
  );

alter table public.noop_ingest_tokens
  add column provisioning_method text;

update public.noop_ingest_tokens
set provisioning_method = 'enrollment_code'
where token_kind = 'installation' and provisioning_method is null;

-- Only installation tokens carry provenance. Deriving it from enrollment_code_id keeps every
-- existing writer (redeem_noop_enrollment, fixtures, ops scripts) correct without edits, while an
-- installation token with neither a code nor an explicit supabase_auth method still violates the
-- shape check below and is rejected.
create function public.noop_ingest_token_provenance() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.token_kind <> 'installation' then
    new.provisioning_method := null;
  elsif new.provisioning_method is null and new.enrollment_code_id is not null then
    new.provisioning_method := 'enrollment_code';
  end if;
  return new;
end $$;

create trigger noop_ingest_token_provenance
  before insert or update of token_kind, provisioning_method, enrollment_code_id
  on public.noop_ingest_tokens
  for each row execute function public.noop_ingest_token_provenance();

alter table public.noop_ingest_tokens
  drop constraint noop_ingest_tokens_identity_shape_check;
alter table public.noop_ingest_tokens
  add constraint noop_ingest_tokens_identity_shape_check check (
    (token_kind = 'fleet' and source_id is null and enrollment_code_id is null
      and provisioning_method is null)
    or (token_kind = 'legacy_upload' and user_id is not null and source_id is null
      and enrollment_code_id is null and provisioning_method is null)
    or (token_kind = 'installation' and user_id is not null and source_id is not null
      and provisioning_method is not null and (
      (provisioning_method = 'enrollment_code' and enrollment_code_id is not null)
      or (provisioning_method = 'supabase_auth' and enrollment_code_id is null)))
  ) not valid;
alter table public.noop_ingest_tokens
  validate constraint noop_ingest_tokens_identity_shape_check;

-- An installation bound through a verified Supabase session never goes back to code enrollment: a
-- legacy redemption that targets it (redeem_noop_enrollment upserts on source_id) is refused with
-- the existing enrollment_source_already_bound error and rolls the whole redemption back.
create function public.noop_installation_provisioning_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.provisioning_method = 'supabase_auth'
      and (new.provisioning_method is distinct from 'supabase_auth' or new.enrollment_code_id is not null) then
    raise exception 'enrollment_source_already_bound' using errcode = 'P0001';
  end if;
  return new;
end $$;

create trigger noop_installation_provisioning_guard
  before update on public.noop_app_installations
  for each row execute function public.noop_installation_provisioning_guard();

-- 2. Provisioning audit trail -----------------------------------------------------------------
-- Also the rate-limit ledger: credential-changing calls are counted per user per hour.

create table public.noop_installation_provisioning_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  source_id uuid not null,
  token_id uuid references public.noop_ingest_tokens(id) on delete set null,
  action text not null check (action in ('created', 'rotated', 'upgraded')),
  platform text not null check (platform in ('ios', 'macos', 'android')),
  app_version text not null check (char_length(app_version) between 1 and 64),
  occurred_at timestamptz not null default clock_timestamp(),
  foreign key (user_id, source_id)
    references public.noop_app_installations(user_id, source_id) on delete cascade
);

create index noop_installation_provisioning_events_user_idx
  on public.noop_installation_provisioning_events (user_id, occurred_at desc);

alter table public.noop_installation_provisioning_events enable row level security;
revoke all on table public.noop_installation_provisioning_events from public, anon, authenticated;
grant all on table public.noop_installation_provisioning_events to service_role;

-- 3. Provisioning RPC -------------------------------------------------------------------------
--
-- Outcomes (jsonb.action):
--   created   first provisioning of a source for this user
--   reused    the caller presented the live supabase_auth credential with comfortable lifetime left;
--             nothing changed and no new secret is issued
--   rotated   the installation exists; its previous credential is revoked and replaced
--   upgraded  as rotated, but the previous credential came from legacy enrollment-code enrollment

create function public.provision_noop_installation(
  p_user_id uuid,
  p_source_id uuid,
  p_platform text,
  p_app_version text,
  p_new_token_hash text,
  p_current_token_hash text default null,
  p_ttl_seconds integer default 31536000
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_max_active_installations constant integer := 25;
  c_max_credential_changes_per_hour constant integer := 20;
  c_refresh_window constant interval := interval '30 days';
  v_now timestamptz := clock_timestamp();
  v_installation public.noop_app_installations%rowtype;
  v_token public.noop_ingest_tokens%rowtype;
  v_token_id uuid;
  v_expires timestamptz;
  v_action text;
  v_foreign_compute boolean := false;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'provision_service_role_required' using errcode = '42501';
  end if;
  if p_user_id is null or p_source_id is null then
    raise exception 'provision_identity_invalid' using errcode = '22023';
  end if;
  if p_new_token_hash is null or p_new_token_hash !~ '^[0-9a-f]{64}$'
      or (p_current_token_hash is not null and p_current_token_hash !~ '^[0-9a-f]{64}$') then
    raise exception 'provision_hash_invalid' using errcode = '22023';
  end if;
  if p_platform is null or p_platform <> all (array['ios'::text, 'macos'::text, 'android'::text]) then
    raise exception 'provision_platform_invalid' using errcode = '22023';
  end if;
  if p_app_version is null or char_length(p_app_version) not between 1 and 64 then
    raise exception 'provision_app_version_invalid' using errcode = '22023';
  end if;
  if p_ttl_seconds is null or p_ttl_seconds not between 3600 and 34560000 then
    raise exception 'provision_ttl_invalid' using errcode = '22023';
  end if;

  -- Same lock order as enrollment and the account-deletion freeze: source, then account.
  perform pg_advisory_xact_lock(hashtextextended(p_source_id::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('account-admission:' || p_user_id::text, 0));

  -- The account-compute registry is a second place a source id can be claimed; one source id must
  -- never resolve to two owners across them.
  if to_regclass('public.compute_account_sources') is not null then
    execute 'select exists (select 1 from public.compute_account_sources where source_id = $1 and user_id <> $2)'
      into v_foreign_compute using p_source_id, p_user_id;
    if v_foreign_compute then
      raise exception 'installation_unavailable' using errcode = 'P0001';
    end if;
  end if;

  select i.* into v_installation
  from public.noop_app_installations i
  where i.source_id = p_source_id
  for update;

  if found then
    -- A source id belongs to exactly one account for its whole life. The message is deliberately
    -- the same for "someone else's" and "does not exist for you".
    if v_installation.user_id <> p_user_id then
      raise exception 'installation_unavailable' using errcode = 'P0001';
    end if;
    if v_installation.retired_at is not null then
      raise exception 'installation_retired' using errcode = 'P0001';
    end if;
    if v_installation.revoked_at is not null then
      raise exception 'installation_revoked' using errcode = 'P0001';
    end if;

    select t.* into v_token
    from public.noop_ingest_tokens t
    where t.user_id = p_user_id and t.source_id = p_source_id
      and t.token_kind = 'installation' and t.revoked_at is null
    for update;

    if found and v_token.provisioning_method = 'supabase_auth'
        and p_current_token_hash is not null
        and v_token.token_hash = p_current_token_hash
        and v_token.expires_at is not null
        and v_token.expires_at > v_now + c_refresh_window then
      update public.noop_app_installations i
      set platform = p_platform, app_version = p_app_version, last_enrolled_at = v_now
      where i.source_id = p_source_id
        and (i.platform is distinct from p_platform or i.app_version is distinct from p_app_version);
      return jsonb_build_object(
        'userId', p_user_id, 'sourceId', p_source_id, 'tokenId', v_token.id,
        'action', 'reused', 'expiresAt', v_token.expires_at);
    end if;

    v_action := case when v_token.id is not null and v_token.provisioning_method = 'enrollment_code'
      then 'upgraded' else 'rotated' end;
  else
    if (select count(*) from public.noop_app_installations a
        where a.user_id = p_user_id and a.revoked_at is null and a.retired_at is null)
        >= c_max_active_installations then
      raise exception 'installation_limit' using errcode = 'P0001';
    end if;
    v_action := 'created';
  end if;

  if (select count(*) from public.noop_installation_provisioning_events e
      where e.user_id = p_user_id and e.occurred_at > v_now - interval '1 hour')
      >= c_max_credential_changes_per_hour then
    raise exception 'provision_rate_limited' using errcode = 'P0001';
  end if;

  v_expires := v_now + pg_catalog.make_interval(secs => p_ttl_seconds);

  if v_action = 'created' then
    -- The retirement-tombstone trigger on this insert fails closed for an account in deletion.
    insert into public.noop_app_installations (
      source_id, user_id, enrollment_code_id, provisioning_method, platform, app_version,
      first_enrolled_at, last_enrolled_at
    ) values (
      p_source_id, p_user_id, null, 'supabase_auth', p_platform, p_app_version, v_now, v_now
    );
  else
    update public.noop_app_installations i
    set provisioning_method = 'supabase_auth', enrollment_code_id = null,
        platform = p_platform, app_version = p_app_version, last_enrolled_at = v_now
    where i.source_id = p_source_id and i.user_id = p_user_id;

    update public.noop_ingest_tokens t
    set revoked_at = v_now
    where t.user_id = p_user_id and t.source_id = p_source_id
      and t.token_kind = 'installation' and t.revoked_at is null;
  end if;

  insert into public.noop_ingest_tokens (
    user_id, token_hash, label, token_kind, source_id, expires_at, enrollment_code_id,
    provisioning_method
  ) values (
    p_user_id, p_new_token_hash, 'supabase-auth:' || p_platform, 'installation', p_source_id,
    v_expires, null, 'supabase_auth'
  ) returning id into v_token_id;

  insert into public.noop_installation_provisioning_events (
    user_id, source_id, token_id, action, platform, app_version, occurred_at
  ) values (p_user_id, p_source_id, v_token_id, v_action, p_platform, p_app_version, v_now);

  return jsonb_build_object(
    'userId', p_user_id, 'sourceId', p_source_id, 'tokenId', v_token_id,
    'action', v_action, 'expiresAt', v_expires);
end;
$$;

revoke all on function public.provision_noop_installation(uuid, uuid, text, text, text, text, integer)
  from public, anon, authenticated;
grant execute on function public.provision_noop_installation(uuid, uuid, text, text, text, text, integer)
  to service_role;
revoke all on function public.noop_ingest_token_provenance() from public, anon, authenticated;
revoke all on function public.noop_installation_provisioning_guard() from public, anon, authenticated;

comment on column public.noop_app_installations.provisioning_method is
  'How the installation was bound to its owner: Supabase Auth session (supabase_auth) or legacy ops enrollment code (enrollment_code).';
comment on column public.noop_ingest_tokens.provisioning_method is
  'Provenance of an installation token. supabase_auth tokens are the sole upload credential; enrollment_code tokens additionally require the legacy fleet credential and the explicit compatibility flag.';
comment on table public.noop_installation_provisioning_events is
  'Audit trail and hourly rate-limit ledger for credential-changing installation provisioning.';

commit;
