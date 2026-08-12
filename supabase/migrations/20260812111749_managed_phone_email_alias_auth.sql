begin;

create or replace function public.managed_phone_auth_email(value text)
returns text
language plpgsql
immutable
strict
set search_path = public, pg_temp
as $$
declare
  normalized text := public.normalize_employee_phone(value);
begin
  if normalized is null then return null; end if;
  return 'phone.' || substr(normalized, 2) || '@nextep.local';
end
$$;

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
  expected_email text;
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

  expected_email := public.managed_phone_auth_email(normalized_phone);
  select * into auth_user from auth.users where id = target_user_id for update;
  if not found then raise exception 'Authentication account not found' using errcode = 'P0002'; end if;
  if lower(coalesce(auth_user.email, '')) is distinct from lower(expected_email) then
    raise exception 'Authentication identifier does not match the requested profile phone' using errcode = '23514';
  end if;

  perform set_config('app.identity_managed_create_rpc', 'on', true);
  insert into public.profiles(id, full_name, email, phone, role, permissions, status, must_change_password, created_by, created_at)
  values(target_user_id, btrim(target_full_name), auth_user.email, normalized_phone, target_role, '{}'::jsonb, 'active', true, actor_id, now())
  returning * into saved;
  perform set_config('app.identity_managed_create_rpc', 'off', true);

  perform public.log_identity_security_event(target_user_id, 'managed_account_created', null, to_jsonb(saved) - 'password_changed_at',
    jsonb_build_object('allowed', true, 'source', 'admin_register_managed_profile', 'temporary_password_stored', false, 'auth_identifier', expected_email));
  return saved;
end
$$;

revoke all on function public.managed_phone_auth_email(text) from public, anon;
grant execute on function public.managed_phone_auth_email(text) to authenticated, service_role;

commit;
