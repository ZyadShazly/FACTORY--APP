-- Security hotfix: an active manager may administer accountant/production only.
-- Owner is the sole application role allowed to administer manager/owner rows.
-- Apply after 202607150003_owner_identity_security.sql.

create or replace function public.enforce_administrative_hierarchy()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor_role text := public.current_identity_role();
  denial_reason constant text := 'لا يمكن لمدير النظام إدارة مدير نظام آخر.';
  requested jsonb := case when tg_op = 'DELETE' then null else to_jsonb(new) end;
  event_action text := case
    when tg_op = 'DELETE' then 'profile_delete_attempt'
    when new.role is distinct from old.role then 'role_change_attempt'
    else 'privilege_change_attempt'
  end;
begin
  if actor_role <> 'manager' then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  if old.role not in ('owner', 'manager')
     and (tg_op = 'DELETE' or new.role not in ('owner', 'manager')) then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  -- A no-op keeps the denied attempt and its audit event in the same committed
  -- transaction. Raising after the insert would roll the audit row back.
  perform public.log_identity_security_event(
    old.id,
    event_action,
    to_jsonb(old),
    requested,
    jsonb_build_object(
      'allowed', false,
      'reason', denial_reason,
      'source', 'administrative_hierarchy_trigger',
      'actor_role', actor_role
    )
  );
  return null;
end
$$;

revoke all on function public.enforce_administrative_hierarchy() from public, anon, authenticated;

drop trigger if exists enforce_administrative_hierarchy on public.profiles;
create trigger enforce_administrative_hierarchy
before update or delete on public.profiles
for each row execute function public.enforce_administrative_hierarchy();

-- RLS establishes the authenticated administrative scope. The trigger above
-- enforces the target hierarchy and preserves a durable audit row for a denied
-- direct REST attempt.
drop policy if exists profiles_administration_scope on public.profiles;
create policy profiles_administration_scope
on public.profiles
as restrictive
for update
to authenticated
using (
  auth.uid() = id
  or public.current_identity_role() in ('owner', 'manager')
)
with check (
  auth.uid() = id
  or public.current_identity_role() = 'owner'
  or (
    public.current_identity_role() = 'manager'
    and role in ('accountant', 'production')
  )
);

drop policy if exists profiles_delete_administrators on public.profiles;
create policy profiles_delete_administrators
on public.profiles
for delete
to authenticated
using (
  auth.uid() <> id
  and public.current_identity_role() in ('owner', 'manager')
);

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
  elsif actor_profile.role = 'manager'
     and (
       target_profile.role in ('owner', 'manager')
       or target_role in ('owner', 'manager')
     ) then
    denial_reason := 'لا يمكن لمدير النظام إدارة مدير نظام آخر.';
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
      jsonb_build_object('allowed', false, 'reason', denial_reason, 'actor_role', actor_profile.role)
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

create or replace function public.admin_delete_profile(target_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor_id uuid := auth.uid();
  actor_profile public.profiles%rowtype;
  target_profile public.profiles%rowtype;
  denial_reason text;
  owner_count integer;
  active_owner_count integer;
  active_manager_count integer;
begin
  lock table public.profiles in share row exclusive mode;
  select * into actor_profile from public.profiles where id = actor_id;
  select * into target_profile from public.profiles where id = target_user_id;

  if actor_profile.id is null or actor_profile.status <> 'active'
     or actor_profile.role not in ('owner', 'manager') then
    denial_reason := 'Only an active owner or manager can delete profiles';
  elsif target_profile.id is null then
    denial_reason := 'Target profile was not found';
  elsif actor_id = target_user_id then
    denial_reason := 'Users cannot delete their own profile';
  elsif actor_profile.role = 'manager' and target_profile.role in ('owner', 'manager') then
    denial_reason := 'لا يمكن لمدير النظام إدارة مدير نظام آخر.';
  end if;

  if denial_reason is null and target_profile.role = 'owner' then
    select count(*) into owner_count from public.profiles where role = 'owner';
    select count(*) into active_owner_count from public.profiles where role = 'owner' and status = 'active';
    if owner_count <= 1 then
      denial_reason := 'The last owner cannot be deleted';
    elsif target_profile.status = 'active' and active_owner_count <= 1 then
      denial_reason := 'The last active owner cannot be deleted';
    end if;
  end if;

  if denial_reason is null and target_profile.role = 'manager' and target_profile.status = 'active' then
    select count(*) into active_owner_count from public.profiles where role = 'owner' and status = 'active';
    select count(*) into active_manager_count from public.profiles where role = 'manager' and status = 'active';
    if active_owner_count = 0 and active_manager_count <= 1 then
      denial_reason := 'The last active manager is required while no active owner exists';
    end if;
  end if;

  if denial_reason is not null then
    perform public.log_identity_security_event(
      target_user_id,
      'profile_delete_attempt',
      case when target_profile.id is null then null else to_jsonb(target_profile) end,
      null,
      jsonb_build_object('allowed', false, 'reason', denial_reason, 'actor_role', actor_profile.role)
    );
    return jsonb_build_object('ok', false, 'error', denial_reason);
  end if;

  perform public.log_identity_security_event(
    target_user_id,
    'profile_delete_attempt',
    to_jsonb(target_profile),
    null,
    jsonb_build_object('allowed', true, 'actor_role', actor_profile.role)
  );
  delete from public.profiles where id = target_user_id;
  return jsonb_build_object('ok', true, 'deleted_user_id', target_user_id);
end
$$;

revoke all on function public.admin_delete_profile(uuid) from public, anon;
grant execute on function public.admin_delete_profile(uuid) to authenticated;

comment on function public.admin_update_profile(uuid, text, jsonb, text) is
  'Owner may administer protected identities; manager may administer accountant and production only. Every attempt is audited.';
comment on function public.admin_delete_profile(uuid) is
  'Protected profile deletion with owner/manager hierarchy, last-administrator safety and durable audit events.';
