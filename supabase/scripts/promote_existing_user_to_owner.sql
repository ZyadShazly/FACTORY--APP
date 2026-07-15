-- ONE-TIME OWNER BOOTSTRAP
-- Run manually in Supabase SQL Editor after applying migrations through
-- 202607150003_owner_identity_security.sql.
--
-- Set exactly ONE of target_email or target_user_id below. Do not commit your
-- real email or user id. This script never creates a password and never changes
-- Auth credentials; the promoted owner signs in with the same account/password.

begin;
lock table public.profiles in share row exclusive mode;

do $$
declare
  target_email text := null;       -- While running only, replace null with the existing email.
  target_user_id uuid := null;     -- Example while running only: '00000000-0000-0000-0000-000000000000'
  resolved_user_id uuid;
  matched_count integer;
begin
  if (target_email is null) = (target_user_id is null) then
    raise exception 'Set exactly one of target_email or target_user_id before running this script';
  end if;

  select count(*)
    into matched_count
    from public.profiles
   where (target_user_id is not null and id = target_user_id)
      or (target_email is not null and lower(email) = lower(target_email));

  if matched_count <> 1 then
    raise exception 'Expected exactly one existing profile, found %', matched_count;
  end if;

  select id
    into resolved_user_id
    from public.profiles
   where (target_user_id is not null and id = target_user_id)
      or (target_email is not null and lower(email) = lower(target_email));

  perform set_config('app.identity_owner_bootstrap', 'on', true);

  update public.profiles
     set role = 'owner',
         permissions = '{}'::jsonb,
         status = 'active'
   where id = resolved_user_id;

  insert into public.audit_log(table_name, record_id, action, actor_id, new_data, metadata)
  values (
    'profiles',
    resolved_user_id::text,
    'owner_bootstrap',
    null,
    jsonb_build_object('id', resolved_user_id, 'role', 'owner', 'status', 'active'),
    jsonb_build_object('source', 'manual_one_time_sql', 'credentials_changed', false)
  );

  raise notice 'Existing account % is now an active owner. Credentials were not changed.', resolved_user_id;
end
$$;

commit;
