-- Security hotfix: roles are server-controlled, even when a client bypasses the UI.
-- Self-service signup is limited to the explicitly approved non-manager roles.

create or replace function public.enforce_profile_role_security()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor_id uuid := auth.uid();
  actor_app_role text;
begin
  -- Supabase service_role represents the system owner/admin automation.
  if auth.role() = 'service_role' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if actor_id is null or new.id is distinct from actor_id then
      raise exception using
        errcode = '42501',
        message = 'Profiles can only be created for the authenticated user';
    end if;

    if new.role not in ('accountant', 'production') then
      raise exception using
        errcode = '42501',
        message = 'Self-service registration cannot create a protected role';
    end if;

    if new.permissions <> '{}'::jsonb
       or new.status <> 'active' then
      raise exception using
        errcode = '42501',
        message = 'Self-service registration cannot grant permissions or set account status';
    end if;

    return new;
  end if;

  if new.role is distinct from old.role then
    if actor_id = old.id then
      raise exception using
        errcode = '42501',
        message = 'Users cannot change their own role';
    end if;

    select profile.role
      into actor_app_role
      from public.profiles as profile
     where profile.id = actor_id
       and coalesce(profile.status, 'active') = 'active';

    if actor_app_role is distinct from 'manager' then
      raise exception using
        errcode = '42501',
        message = 'Only an active manager or the system owner can change roles';
    end if;
  end if;

  return new;
end
$$;

revoke all on function public.enforce_profile_role_security() from public, anon, authenticated;

drop trigger if exists enforce_profile_role_security on public.profiles;
create trigger enforce_profile_role_security
before insert or update of role on public.profiles
for each row
execute function public.enforce_profile_role_security();

-- Keep the existing update guard compatible with system-owner automation and
-- enforce the same no-self-role-change rule when other privileged fields change.
create or replace function public.protect_profile_privileges()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.role() = 'service_role' then
    return new;
  end if;

  if new.role is distinct from old.role then
    if auth.uid() = old.id then
      raise exception using errcode = '42501', message = 'Users cannot change their own role';
    end if;
    if public.current_app_role() <> 'manager' then
      raise exception using errcode = '42501', message = 'Only an active manager or the system owner can change roles';
    end if;
  end if;

  if (new.permissions is distinct from old.permissions or new.status is distinct from old.status)
     and public.current_app_role() <> 'manager' then
    raise exception using errcode = '42501', message = 'Only an active manager or the system owner can change privileges or account status';
  end if;

  return new;
end
$$;

drop trigger if exists protect_profile_privileges on public.profiles;
create trigger protect_profile_privileges
before update of role, permissions, status on public.profiles
for each row
execute function public.protect_profile_privileges();

-- Keep one permissive policy to establish which row may be inserted. The
-- separate restrictive policy below is ANDed with every permissive INSERT
-- policy, so no legacy/additional permissive policy can bypass the allowlist.
drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own
on public.profiles
for insert
to authenticated
with check (auth.uid() = id);

drop policy if exists profiles_self_signup_restrictions on public.profiles;
create policy profiles_self_signup_restrictions
on public.profiles
as restrictive
for insert
to authenticated
with check (
  role in ('accountant', 'production')
  and permissions = '{}'::jsonb
  and status = 'active'
);

comment on function public.enforce_profile_role_security() is
  'Prevents protected self-registration and self role changes; managers may change other users and service_role may administer all profiles.';
