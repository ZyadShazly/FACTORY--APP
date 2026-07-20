begin;

create or replace function public.complete_my_profile()
returns public.profiles
language plpgsql
security definer
set search_path = 'public', 'auth', 'pg_temp'
as $$
declare
  actor_id uuid := auth.uid();
  auth_user auth.users%rowtype;
  result_profile public.profiles%rowtype;
  requested_role text;
  requested_name text;
begin
  if actor_id is null then
    raise exception using errcode = '42501', message = 'Authentication is required';
  end if;

  select * into auth_user from auth.users where id = actor_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'Authentication account was not found';
  end if;

  select * into result_profile from public.profiles where id = actor_id;
  if found then
    return result_profile;
  end if;

  requested_role := case
    when auth_user.raw_user_meta_data ->> 'role' in ('accountant', 'production')
      then auth_user.raw_user_meta_data ->> 'role'
    else 'production'
  end;
  requested_name := coalesce(
    nullif(btrim(auth_user.raw_user_meta_data ->> 'full_name'), ''),
    split_part(auth_user.email, '@', 1)
  );

  insert into public.profiles(id, full_name, email, role, permissions, status, created_at)
  values (actor_id, requested_name, auth_user.email, requested_role, '{}'::jsonb, 'active', now())
  returning * into result_profile;

  insert into public.audit_log(table_name, record_id, action, actor_id, new_data, metadata)
  values (
    'profiles', actor_id::text, 'self_profile_completed', actor_id,
    to_jsonb(result_profile), jsonb_build_object('source', 'complete_my_profile')
  );

  return result_profile;
end;
$$;

revoke all on function public.complete_my_profile() from public;
revoke all on function public.complete_my_profile() from anon;
grant execute on function public.complete_my_profile() to authenticated;

create or replace function public.prevent_employee_delete()
returns trigger
language plpgsql
security invoker
set search_path = 'public', 'pg_temp'
as $$
begin
  raise exception using
    errcode = '23503',
    message = 'Employees cannot be deleted; suspend the employee to preserve payroll and custody history';
end;
$$;

drop trigger if exists prevent_employee_delete_trigger on public.employees;
create trigger prevent_employee_delete_trigger
before delete on public.employees
for each row execute function public.prevent_employee_delete();

create or replace function public.prevent_finalized_payroll_delete()
returns trigger
language plpgsql
security invoker
set search_path = 'public', 'pg_temp'
as $$
begin
  if old.status <> 'draft' then
    raise exception using
      errcode = '23514',
      message = 'Approved or paid payroll cannot be deleted; use a reversal or correction workflow';
  end if;
  return old;
end;
$$;

drop trigger if exists prevent_finalized_payroll_delete_trigger on public.payroll;
create trigger prevent_finalized_payroll_delete_trigger
before delete on public.payroll
for each row execute function public.prevent_finalized_payroll_delete();

commit;
