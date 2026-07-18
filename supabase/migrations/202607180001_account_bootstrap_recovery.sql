-- UI Acceptance & Recovery Pass
-- Securely repairs the exceptional state where auth.users exists but profiles does not.
-- Apply after 202607160001_enforce_owner_manager_hierarchy.sql.

create or replace function public.enforce_profile_role_security()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  is_admin_rpc boolean := current_setting('app.identity_admin_rpc', true) = 'on';
  is_account_repair boolean := current_setting('app.account_repair_rpc', true) = 'on';
  is_owner_bootstrap boolean := auth.uid() is null
    and current_setting('app.identity_owner_bootstrap', true) = 'on';
begin
  if tg_op = 'INSERT' then
    if auth.role() = 'service_role' then
      return new;
    end if;

    -- This exception remains protected by actor role, least-privilege target
    -- roles, immutable defaults and the SECURITY DEFINER RPC validation.
    if is_account_repair
       and public.current_identity_role() in ('owner', 'manager')
       and new.id is distinct from auth.uid()
       and new.role in ('accountant', 'production')
       and new.permissions = '{}'::jsonb
       and new.status = 'active' then
      return new;
    end if;

    if auth.uid() is null or new.id is distinct from auth.uid() then
      raise exception using errcode = '42501', message = 'Profiles can only be created for the authenticated user';
    end if;

    if new.role not in ('accountant', 'production') then
      raise exception using errcode = '42501', message = 'Self-service registration cannot create a protected role';
    end if;

    if new.permissions <> '{}'::jsonb or new.status <> 'active' then
      raise exception using errcode = '42501', message = 'Self-service registration cannot grant permissions or set account status';
    end if;

    return new;
  end if;

  if new.role is distinct from old.role
     or new.permissions is distinct from old.permissions
     or new.status is distinct from old.status then
    if auth.role() = 'service_role' or is_owner_bootstrap then
      return new;
    end if;

    if is_admin_rpc then
      if new.role in ('accountant', 'production')
         and jsonb_typeof(new.permissions -> 'pages') = 'array' then
        new.permissions := jsonb_set(
          new.permissions,
          '{pages}',
          coalesce((select jsonb_agg(page_name) from jsonb_array_elements_text(new.permissions -> 'pages') as page_values(page_name) where page_name <> 'settings'), '[]'::jsonb),
          true
        );
      end if;
      return new;
    end if;

    raise exception using
      errcode = '42501',
      message = 'Protected profile fields must be changed through admin_update_profile';
  end if;

  return new;
end
$$;

revoke all on function public.enforce_profile_role_security() from public, anon, authenticated;

create or replace function public.admin_repair_missing_profile(
  target_user_id uuid,
  target_full_name text default null,
  target_role text default 'production'
)
returns public.profiles
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  actor_id uuid := auth.uid();
  actor_role text;
  auth_user auth.users%rowtype;
  repaired_profile public.profiles%rowtype;
begin
  if actor_id is null then
    raise exception using errcode = '42501', message = 'Authentication is required';
  end if;

  select role into actor_role
  from public.profiles
  where id = actor_id and status = 'active';

  if actor_role not in ('owner', 'manager') then
    perform public.log_identity_security_event(
      target_user_id, 'account_repair_attempt', null, null,
      jsonb_build_object('allowed', false, 'reason', 'Active owner or manager required')
    );
    raise exception using errcode = '42501', message = 'Only an active owner or manager can repair missing profiles';
  end if;

  if target_role not in ('accountant', 'production') then
    perform public.log_identity_security_event(
      target_user_id, 'account_repair_attempt', null, null,
      jsonb_build_object('allowed', false, 'reason', 'Protected target role requested', 'target_role', target_role)
    );
    raise exception using errcode = '42501', message = 'Recovery can only create accountant or production profiles';
  end if;

  select * into auth_user from auth.users where id = target_user_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'The authentication account does not exist';
  end if;

  if exists (select 1 from public.profiles where id = target_user_id) then
    raise exception using errcode = '23505', message = 'The profile already exists; use the team administration workflow';
  end if;

  perform set_config('app.account_repair_rpc', 'on', true);
  insert into public.profiles(id, full_name, email, role, permissions, status, created_at)
  values (
    auth_user.id,
    coalesce(nullif(btrim(target_full_name), ''), nullif(btrim(auth_user.raw_user_meta_data ->> 'full_name'), ''), split_part(auth_user.email, '@', 1)),
    auth_user.email,
    target_role,
    '{}'::jsonb,
    'active',
    now()
  )
  returning * into repaired_profile;
  perform set_config('app.account_repair_rpc', 'off', true);

  perform public.log_identity_security_event(
    target_user_id,
    'account_profile_repaired',
    null,
    to_jsonb(repaired_profile),
    jsonb_build_object('allowed', true, 'source', 'admin_repair_missing_profile', 'credentials_changed', false)
  );

  return repaired_profile;
end
$$;

revoke all on function public.admin_repair_missing_profile(uuid, text, text) from public, anon;
grant execute on function public.admin_repair_missing_profile(uuid, text, text) to authenticated;

comment on function public.admin_repair_missing_profile(uuid, text, text) is
  'Creates a least-privilege profile for an existing auth user only when invoked by an active owner or manager; credentials are unchanged and the action is audited.';
