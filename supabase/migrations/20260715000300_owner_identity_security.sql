-- Milestone 2 / Phase 1: owner hierarchy and protected identity administration.
-- Apply after 202607150002_enforce_protected_role_creation.sql.

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles
  add constraint profiles_role_check
  check (role in ('owner', 'manager', 'accountant', 'production'));

create or replace function public.current_identity_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select role
    from public.profiles
    where id = auth.uid()
      and status = 'active'
  ), '')
$$;

-- Compatibility contract: legacy RLS policies that grant access to manager
-- automatically grant the same operational access to owner. Security decisions
-- about hierarchy must use current_identity_role(), not this compatibility role.
create or replace function public.current_app_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case public.current_identity_role()
    when 'owner' then 'manager'
    else public.current_identity_role()
  end
$$;

create or replace function public.is_manager()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.current_identity_role() in ('owner', 'manager')
$$;

create or replace function public.has_permission(permission_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case public.current_identity_role()
    when 'owner' then true
    when 'manager' then true
    when 'production' then false
    when 'accountant' then
      coalesce((
        select (permissions ->> permission_name)::boolean
        from public.profiles
        where id = auth.uid()
          and status = 'active'
      ), false)
      or permission_name = any(array[
        'projects_view','projects_create','project_financials_view','project_files_view','project_files_upload',
        'payroll_view','payroll_create','payroll_edit','payroll_mark_paid','daily_labor_view',
        'daily_labor_create','daily_labor_edit','daily_labor_pay'
      ])
    else false
  end
$$;

revoke all on function public.current_identity_role() from public, anon;
grant execute on function public.current_identity_role() to authenticated;

create or replace function public.log_identity_security_event(
  target_user_id uuid,
  event_action text,
  previous_data jsonb,
  requested_data jsonb,
  event_metadata jsonb
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.audit_log(table_name, record_id, action, actor_id, old_data, new_data, metadata)
  values (
    'profiles',
    target_user_id::text,
    event_action,
    auth.uid(),
    previous_data,
    requested_data,
    coalesce(event_metadata, '{}'::jsonb)
  );
end
$$;

revoke all on function public.log_identity_security_event(uuid, text, jsonb, jsonb, jsonb)
  from public, anon, authenticated;

-- Direct REST updates to protected columns are rejected. The team screen uses
-- admin_update_profile(), which performs hierarchy checks and creates a durable
-- audit event for allowed and denied attempts.
create or replace function public.enforce_profile_role_security()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  is_admin_rpc boolean := current_setting('app.identity_admin_rpc', true) = 'on';
  is_owner_bootstrap boolean := auth.uid() is null
    and current_setting('app.identity_owner_bootstrap', true) = 'on';
begin
  if tg_op = 'INSERT' then
    if auth.role() = 'service_role' then
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
    if auth.role() = 'service_role' or is_admin_rpc or is_owner_bootstrap then
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

drop trigger if exists enforce_profile_role_security on public.profiles;
drop trigger if exists protect_profile_privileges on public.profiles;
create trigger enforce_profile_role_security
before insert or update of role, permissions, status on public.profiles
for each row execute function public.enforce_profile_role_security();

create or replace function public.protect_last_administrator()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor_role text := public.current_identity_role();
  owner_count integer;
  active_owner_count integer;
  active_manager_count integer;
begin
  if old.role = 'owner' then
    if actor_role = 'manager' then
      raise exception using errcode = '42501', message = 'Managers cannot modify or delete an owner';
    end if;

    select count(*) into owner_count from public.profiles where role = 'owner';
    select count(*) into active_owner_count from public.profiles where role = 'owner' and status = 'active';

    if tg_op = 'DELETE' and owner_count <= 1 then
      raise exception using errcode = '42501', message = 'The last owner cannot be deleted';
    end if;

    if tg_op = 'UPDATE' then
      if new.role <> 'owner' and owner_count <= 1 then
        raise exception using errcode = '42501', message = 'The last owner cannot be demoted';
      end if;
      if old.status = 'active' and new.status <> 'active' and active_owner_count <= 1 then
        raise exception using errcode = '42501', message = 'The last active owner cannot be suspended';
      end if;
    end if;
  end if;

  if old.role = 'manager' and old.status = 'active' then
    select count(*) into active_owner_count from public.profiles where role = 'owner' and status = 'active';
    select count(*) into active_manager_count from public.profiles where role = 'manager' and status = 'active';

    if active_owner_count = 0 and active_manager_count <= 1 and (
      tg_op = 'DELETE'
      or (tg_op = 'UPDATE' and (new.role <> 'manager' or new.status <> 'active'))
    ) and not (tg_op = 'UPDATE' and new.role = 'owner' and new.status = 'active') then
      raise exception using errcode = '42501', message = 'The last active manager is required while no active owner exists';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end
$$;

revoke all on function public.protect_last_administrator() from public, anon, authenticated;

drop trigger if exists protect_last_administrator on public.profiles;
drop trigger if exists protect_last_administrator_update on public.profiles;
drop trigger if exists protect_last_administrator_delete on public.profiles;
create trigger protect_last_administrator_update
before update of role, status on public.profiles
for each row execute function public.protect_last_administrator();
create trigger protect_last_administrator_delete
before delete on public.profiles
for each row execute function public.protect_last_administrator();

create or replace function public.admin_update_profile(
  target_user_id uuid,
  target_role text,
  target_permissions jsonb default '{}'::jsonb,
  target_status text default 'active'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor_id uuid := auth.uid();
  actor_profile public.profiles%rowtype;
  target_profile public.profiles%rowtype;
  updated_profile public.profiles%rowtype;
  requested jsonb;
  normalized_permissions jsonb := coalesce(target_permissions, '{}'::jsonb);
  safe_production_pages jsonb;
  active_owner_count integer;
  owner_count integer;
  active_manager_count integer;
  denial_reason text;
  event_action text;
  permission_key text;
begin
  -- Serialize identity administration so concurrent requests cannot both
  -- remove the final active administrator after observing the same count.
  lock table public.profiles in share row exclusive mode;

  select * into actor_profile from public.profiles where id = actor_id;
  select * into target_profile from public.profiles where id = target_user_id;

  requested := jsonb_build_object(
    'role', target_role,
    'permissions', coalesce(target_permissions, '{}'::jsonb),
    'status', target_status
  );
  event_action := case when target_profile.role is distinct from target_role
    then 'role_change_attempt'
    else 'privilege_change_attempt'
  end;

  if actor_profile.id is null or actor_profile.status <> 'active'
     or actor_profile.role not in ('owner', 'manager') then
    denial_reason := 'Only an active owner or manager can administer identities';
  elsif target_profile.id is null then
    denial_reason := 'Target profile was not found';
  elsif target_role not in ('owner', 'manager', 'accountant', 'production') then
    denial_reason := 'Unsupported role';
  elsif target_status not in ('active', 'suspended') then
    denial_reason := 'Unsupported account status';
  elsif actor_id = target_user_id then
    denial_reason := 'Users cannot change their own role, permissions or status';
  elsif actor_profile.role = 'manager' and target_profile.role = 'owner' then
    denial_reason := 'Managers cannot modify an owner';
  elsif actor_profile.role = 'manager' and target_role = 'owner' then
    denial_reason := 'Managers cannot promote users to owner';
  end if;

  if denial_reason is null and target_profile.role = 'owner' then
    select count(*) into owner_count from public.profiles where role = 'owner';
    select count(*) into active_owner_count from public.profiles where role = 'owner' and status = 'active';
    if target_role <> 'owner' and owner_count <= 1 then
      denial_reason := 'The last owner cannot be demoted';
    elsif target_profile.status = 'active' and target_status <> 'active' and active_owner_count <= 1 then
      denial_reason := 'The last active owner cannot be suspended';
    end if;
  end if;

  if denial_reason is null and target_profile.role = 'manager' and target_profile.status = 'active'
     and (target_role <> 'manager' or target_status <> 'active') then
    select count(*) into active_owner_count from public.profiles where role = 'owner' and status = 'active';
    select count(*) into active_manager_count from public.profiles where role = 'manager' and status = 'active';
    if active_owner_count = 0 and active_manager_count <= 1
       and not (target_role = 'owner' and target_status = 'active') then
      denial_reason := 'The last active manager is required while no active owner exists';
    end if;
  end if;

  if denial_reason is not null then
    perform public.log_identity_security_event(
      target_user_id,
      event_action,
      case when target_profile.id is null then null else to_jsonb(target_profile) end,
      requested,
      jsonb_build_object('allowed', false, 'reason', denial_reason)
    );
    return jsonb_build_object('ok', false, 'error', denial_reason);
  end if;

  if target_role in ('owner', 'manager') then
    normalized_permissions := '{}'::jsonb;
  elsif target_role = 'production' then
    select coalesce(jsonb_agg(page_name), '[]'::jsonb)
      into safe_production_pages
      from jsonb_array_elements_text(coalesce(target_permissions -> 'pages', '[]'::jsonb)) as pages(page_name)
      where page_name in ('inventory', 'materials', 'products', 'production');

    normalized_permissions := coalesce(target_permissions, '{}'::jsonb) || jsonb_build_object(
      'pages', safe_production_pages,
      'can_delete', false,
      'view_financials', false,
      'can_create_products', false,
      'can_edit_products', false
    );

    foreach permission_key in array array[
      'projects_view','projects_create','projects_edit','projects_delete',
      'project_files_view','project_files_upload','project_files_delete','project_financials_view',
      'payroll_view','payroll_create','payroll_edit','payroll_approve','payroll_bonus_manage','payroll_mark_paid',
      'daily_labor_view','daily_labor_create','daily_labor_edit','daily_labor_delete','daily_labor_pay','audit_log_view'
    ] loop
      normalized_permissions := jsonb_set(normalized_permissions, array[permission_key], 'false'::jsonb, true);
    end loop;
  else
    normalized_permissions := jsonb_set(
      normalized_permissions,
      '{pages}',
      coalesce((
        select jsonb_agg(page_name)
        from jsonb_array_elements_text(coalesce(normalized_permissions -> 'pages', '[]'::jsonb)) as pages(page_name)
        where page_name not in ('team', 'auditLog')
      ), '[]'::jsonb),
      true
    );
    normalized_permissions := jsonb_set(normalized_permissions, '{audit_log_view}', 'false'::jsonb, true);
  end if;

  perform set_config('app.identity_admin_rpc', 'on', true);
  update public.profiles
     set role = target_role,
         permissions = normalized_permissions,
         status = target_status
   where id = target_user_id
   returning * into updated_profile;
  perform set_config('app.identity_admin_rpc', 'off', true);

  perform public.log_identity_security_event(
    target_user_id,
    event_action,
    to_jsonb(target_profile),
    to_jsonb(updated_profile),
    jsonb_build_object('allowed', true, 'actor_role', actor_profile.role)
  );

  return jsonb_build_object('ok', true, 'profile', to_jsonb(updated_profile));
end
$$;

revoke all on function public.admin_update_profile(uuid, text, jsonb, text) from public, anon;
grant execute on function public.admin_update_profile(uuid, text, jsonb, text) to authenticated;

-- Audit rows are append-only for application users, including owner.
create or replace function public.protect_audit_log_immutability()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.role() = 'service_role'
     or (auth.uid() is null and coalesce(current_setting('request.jwt.claim.role', true), '') = '') then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  raise exception using errcode = '42501', message = 'Audit log entries are immutable';
end
$$;

revoke all on function public.protect_audit_log_immutability() from public, anon, authenticated;

drop trigger if exists protect_audit_log_immutability on public.audit_log;
create trigger protect_audit_log_immutability
before update or delete on public.audit_log
for each row execute function public.protect_audit_log_immutability();

comment on function public.admin_update_profile(uuid, text, jsonb, text) is
  'The only authenticated path for role, permission and account-status administration. Enforces owner hierarchy and audits every attempt.';
