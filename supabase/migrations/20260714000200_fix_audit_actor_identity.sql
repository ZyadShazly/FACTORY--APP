-- Resolve audit actors to application profiles without rewriting historical events.

alter table public.profiles
  add column if not exists email text;

update public.profiles as profile
set email = auth_user.email
from auth.users as auth_user
where auth_user.id = profile.id
  and profile.email is null;

create or replace function public.set_profile_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.email is null then
    select auth_user.email
    into new.email
    from auth.users as auth_user
    where auth_user.id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists set_profile_email on public.profiles;
create trigger set_profile_email
before insert on public.profiles
for each row execute function public.set_profile_email();

create or replace function public.sync_profile_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles
  set email = new.email
  where id = new.id
    and email is distinct from new.email;
  return new;
end;
$$;

drop trigger if exists sync_profile_email on auth.users;
create trigger sync_profile_email
after update of email on auth.users
for each row execute function public.sync_profile_email();

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'audit_log_actor_id_fkey'
      and conrelid = 'public.audit_log'::regclass
  ) then
    alter table public.audit_log
      add constraint audit_log_actor_id_fkey
      foreign key (actor_id) references public.profiles(id)
      on delete set null
      not valid;
  end if;
end;
$$;

create index if not exists audit_log_actor_idx
  on public.audit_log(actor_id, created_at desc);

create or replace function public.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  row_data jsonb;
  record_identifier text;
  candidate_actor text;
  resolved_actor uuid;
begin
  row_data := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  record_identifier := coalesce(row_data ->> 'id', '');
  resolved_actor := auth.uid();

  if resolved_actor is null then
    candidate_actor := coalesce(
      nullif(row_data ->> 'updated_by', ''),
      nullif(row_data ->> 'created_by', ''),
      nullif(row_data ->> 'uploaded_by', ''),
      nullif(row_data ->> 'actor_id', ''),
      nullif(row_data ->> 'approved_by', '')
    );

    if candidate_actor ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
      resolved_actor := candidate_actor::uuid;
    end if;
  end if;

  -- Keep mutations working even if an auth user has no application profile yet.
  if resolved_actor is not null
     and not exists (select 1 from public.profiles where id = resolved_actor) then
    resolved_actor := null;
  end if;

  insert into public.audit_log(table_name, record_id, action, actor_id, old_data, new_data)
  values (
    tg_table_name,
    record_identifier,
    lower(tg_op),
    resolved_actor,
    case when tg_op <> 'INSERT' then to_jsonb(old) end,
    case when tg_op <> 'DELETE' then to_jsonb(new) end
  );

  return coalesce(new, old);
end;
$$;

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'profiles', 'suppliers', 'customers', 'materials', 'material_purchases',
    'products', 'production_orders', 'sales', 'rentals', 'supplier_payments',
    'customer_receipts', 'expenses', 'projects', 'project_files',
    'project_activities', 'employees', 'payroll', 'daily_labor', 'project_costs'
  ] loop
    if to_regclass(format('public.%I', table_name)) is not null then
      execute format('drop trigger if exists audit_changes on public.%I', table_name);
      execute format(
        'create trigger audit_changes after insert or update or delete on public.%I for each row execute function public.audit_row_change()',
        table_name
      );
    end if;
  end loop;
end;
$$;
