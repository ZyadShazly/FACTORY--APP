-- Owner/manager-managed phone accounts. No historical profile is rewritten.
-- Auth user creation and phone mutation stay in the admin-manage-user Edge Function;
-- this migration owns hierarchy, application profile integrity and audit history.

alter table public.profiles
  add column if not exists phone text,
  add column if not exists must_change_password boolean not null default false,
  add column if not exists password_changed_at timestamptz,
  add column if not exists created_by uuid references public.profiles(id) on delete set null;

create unique index if not exists profiles_phone_normalized_unique
  on public.profiles(public.normalize_employee_phone(phone))
  where public.normalize_employee_phone(phone) is not null;

alter table public.profiles drop constraint if exists profiles_phone_is_international;
alter table public.profiles
  add constraint profiles_phone_is_international
  check (phone is null or public.normalize_employee_phone(phone) is not null) not valid;

drop policy if exists profiles_insert_own on public.profiles;
drop policy if exists profiles_self_signup_restrictions on public.profiles;
revoke insert on public.profiles from anon, authenticated;

create or replace function public.enforce_profile_role_security()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  is_admin_rpc boolean := current_setting('app.identity_admin_rpc', true) = 'on';
  is_account_repair boolean := current_setting('app.account_repair_rpc', true) = 'on';
  is_managed_create boolean := current_setting('app.identity_managed_create_rpc', true) = 'on';
  is_owner_bootstrap boolean := auth.uid() is null
    and current_setting('app.identity_owner_bootstrap', true) = 'on';
  actor_role text := public.current_identity_role();
begin
  if tg_op = 'INSERT' then
    if auth.role() = 'service_role' then return new; end if;

    if is_account_repair
       and actor_role in ('owner', 'manager')
       and new.id is distinct from auth.uid()
       and new.role in ('accountant', 'production')
       and new.permissions = '{}'::jsonb
       and new.status = 'active' then
      return new;
    end if;

    if is_managed_create
       and new.id is distinct from auth.uid()
       and new.permissions = '{}'::jsonb
       and new.status = 'active'
       and new.must_change_password
       and (
         actor_role = 'owner'
         or actor_role = 'manager' and new.role in ('accountant', 'production')
       ) then
      return new;
    end if;

    raise exception using errcode = '42501', message = 'Self-service registration is disabled; an owner or manager must create the account';
  end if;

  if new.role is distinct from old.role
     or new.permissions is distinct from old.permissions
     or new.status is distinct from old.status then
    if auth.role() = 'service_role' or is_owner_bootstrap then return new; end if;
    if is_admin_rpc then
      if new.role in ('accountant', 'production') and jsonb_typeof(new.permissions -> 'pages') = 'array' then
        new.permissions := jsonb_set(
          new.permissions,
          '{pages}',
          coalesce((select jsonb_agg(page_name) from jsonb_array_elements_text(new.permissions -> 'pages') as page_values(page_name) where page_name <> 'settings'), '[]'::jsonb),
          true
        );
      end if;
      return new;
    end if;
    raise exception using errcode = '42501', message = 'Protected profile fields must be changed through admin_update_profile';
  end if;
  return new;
end
$$;

revoke all on function public.enforce_profile_role_security() from public, anon, authenticated;

create or replace function public.protect_managed_profile_fields()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.role() = 'service_role'
     or current_setting('app.identity_managed_create_rpc', true) = 'on'
     or current_setting('app.identity_password_change_rpc', true) = 'on'
     or current_setting('app.identity_phone_change_rpc', true) = 'on' then
    return new;
  end if;
  if new.phone is distinct from old.phone
     or new.must_change_password is distinct from old.must_change_password
     or new.password_changed_at is distinct from old.password_changed_at
     or new.created_by is distinct from old.created_by then
    raise exception using errcode = '42501', message = 'Managed account identity fields must be changed through the protected workflow';
  end if;
  return new;
end
$$;

revoke all on function public.protect_managed_profile_fields() from public, anon, authenticated;
drop trigger if exists protect_managed_profile_fields on public.profiles;
create trigger protect_managed_profile_fields
before update of phone, must_change_password, password_changed_at, created_by on public.profiles
for each row execute function public.protect_managed_profile_fields();

create or replace function public.admin_register_managed_profile(
  target_user_id uuid,
  target_full_name text,
  target_phone text,
  target_role text
)
returns public.profiles
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  actor_id uuid := auth.uid();
  actor_role text;
  normalized_phone text := public.normalize_employee_phone(target_phone);
  auth_user auth.users%rowtype;
  saved public.profiles%rowtype;
begin
  select role into actor_role from public.profiles where id = actor_id and status = 'active';
  if actor_role is null then raise exception 'Active owner or manager authorization required' using errcode = '42501'; end if;
  if not (actor_role = 'owner' or actor_role = 'manager' and target_role in ('accountant', 'production')) then
    perform public.log_identity_security_event(target_user_id, 'managed_account_create_attempt', null, null,
      jsonb_build_object('allowed', false, 'target_role', target_role));
    raise exception 'Your role cannot create the requested account role' using errcode = '42501';
  end if;
  if target_user_id = actor_id then raise exception 'A managed account cannot be created for the caller'; end if;
  if btrim(coalesce(target_full_name, '')) = '' then raise exception 'Full name is required' using errcode = '23514'; end if;
  if normalized_phone is null then raise exception 'A valid international phone number is required' using errcode = '23514'; end if;
  if exists(select 1 from public.profiles where id = target_user_id) then raise exception 'The profile already exists' using errcode = '23505'; end if;
  if exists(select 1 from public.profiles where public.normalize_employee_phone(phone) = normalized_phone) then raise exception 'Phone number is already assigned' using errcode = '23505'; end if;

  select * into auth_user from auth.users where id = target_user_id for update;
  if not found then raise exception 'Authentication account not found' using errcode = 'P0002'; end if;
  if public.normalize_employee_phone(auth_user.phone) is distinct from normalized_phone then
    raise exception 'Authentication phone does not match the requested profile phone' using errcode = '23514';
  end if;

  perform set_config('app.identity_managed_create_rpc', 'on', true);
  insert into public.profiles(id, full_name, email, phone, role, permissions, status, must_change_password, created_by, created_at)
  values(target_user_id, btrim(target_full_name), auth_user.email, normalized_phone, target_role, '{}'::jsonb, 'active', true, actor_id, now())
  returning * into saved;
  perform set_config('app.identity_managed_create_rpc', 'off', true);

  perform public.log_identity_security_event(target_user_id, 'managed_account_created', null, to_jsonb(saved) - 'password_changed_at',
    jsonb_build_object('allowed', true, 'source', 'admin_register_managed_profile', 'temporary_password_stored', false));
  return saved;
end
$$;

revoke all on function public.admin_register_managed_profile(uuid, text, text, text) from public, anon;
grant execute on function public.admin_register_managed_profile(uuid, text, text, text) to authenticated;

create or replace function public.admin_update_managed_phone(target_user_id uuid, target_phone text, reason text)
returns public.profiles
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor_id uuid := auth.uid(); actor_role text; target public.profiles%rowtype;
  normalized_phone text := public.normalize_employee_phone(target_phone); saved public.profiles%rowtype;
begin
  select role into actor_role from public.profiles where id = actor_id and status = 'active';
  select * into target from public.profiles where id = target_user_id for update;
  if target.id is null then raise exception 'Profile not found' using errcode = 'P0002'; end if;
  if actor_id = target_user_id or not (actor_role = 'owner' or actor_role = 'manager' and target.role in ('accountant', 'production')) then
    raise exception 'Your role cannot change this account phone' using errcode = '42501';
  end if;
  if normalized_phone is null then raise exception 'A valid international phone number is required' using errcode = '23514'; end if;
  if btrim(coalesce(reason, '')) = '' then raise exception 'A phone change reason is required' using errcode = '23514'; end if;
  if exists(select 1 from public.profiles where id <> target_user_id and public.normalize_employee_phone(phone) = normalized_phone) then
    raise exception 'Phone number is already assigned' using errcode = '23505';
  end if;
  perform set_config('app.identity_phone_change_rpc', 'on', true);
  update public.profiles set phone = normalized_phone where id = target_user_id returning * into saved;
  perform set_config('app.identity_phone_change_rpc', 'off', true);
  perform public.log_identity_security_event(target_user_id, 'managed_account_phone_changed',
    jsonb_build_object('phone', target.phone), jsonb_build_object('phone', normalized_phone),
    jsonb_build_object('allowed', true, 'reason', btrim(reason), 'source', 'admin_update_managed_phone'));
  return saved;
end
$$;

revoke all on function public.admin_update_managed_phone(uuid, text, text) from public, anon;
grant execute on function public.admin_update_managed_phone(uuid, text, text) to authenticated;

create or replace function public.complete_managed_password_change(target_user_id uuid)
returns public.profiles
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare profile_row public.profiles%rowtype; saved public.profiles%rowtype;
begin
  if auth.role() <> 'service_role' then raise exception 'Service authorization required' using errcode = '42501'; end if;
  select * into profile_row from public.profiles where id = target_user_id for update;
  if profile_row.id is null or profile_row.status <> 'active' then raise exception 'Active profile required' using errcode = '42501'; end if;
  if not profile_row.must_change_password then return profile_row; end if;
  perform set_config('app.identity_password_change_rpc', 'on', true);
  update public.profiles set must_change_password = false, password_changed_at = now() where id = target_user_id returning * into saved;
  perform set_config('app.identity_password_change_rpc', 'off', true);
  insert into public.audit_log(table_name, record_id, action, actor_id, old_data, new_data, metadata)
  values('profiles', target_user_id::text, 'managed_password_changed', target_user_id,
    jsonb_build_object('must_change_password', true), jsonb_build_object('must_change_password', false),
    jsonb_build_object('allowed', true, 'source', 'admin-manage-user', 'password_value_stored', false));
  return saved;
end
$$;

revoke all on function public.complete_managed_password_change(uuid) from public, anon, authenticated;
grant execute on function public.complete_managed_password_change(uuid) to service_role;

comment on function public.admin_register_managed_profile(uuid, text, text, text) is
  'Registers an Auth user created by the protected Edge Function as an audited managed application account. No password is accepted or stored.';
