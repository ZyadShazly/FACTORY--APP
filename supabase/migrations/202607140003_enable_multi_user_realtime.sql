-- Multi-user realtime synchronization and immediate account suspension.

alter table public.profiles
  add column if not exists status text;

update public.profiles
set status = 'active'
where status is null;

alter table public.profiles
  alter column status set default 'active',
  alter column status set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'profiles_status_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_status_check
      check (status in ('active', 'suspended'));
  end if;
end;
$$;

alter table public.profiles replica identity full;

create or replace function public.current_app_role()
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

create or replace function public.has_permission(permission_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.current_app_role() = 'manager'
    or coalesce((
      select (permissions ->> permission_name)::boolean
      from public.profiles
      where id = auth.uid()
        and status = 'active'
    ), false)
    or case public.current_app_role()
      when 'accountant' then permission_name = any(array[
        'projects_view','projects_create','project_financials_view','project_files_view','project_files_upload',
        'payroll_view','payroll_create','payroll_edit','payroll_mark_paid','daily_labor_view',
        'daily_labor_create','daily_labor_edit','daily_labor_pay'
      ])
      when 'production' then permission_name = any(array['projects_view','project_files_view'])
      else false
    end
$$;

create or replace function public.is_current_profile_active()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and status = 'active'
  )
$$;

create or replace function public.protect_profile_privileges()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_app_role() <> 'manager'
     and (
       new.role is distinct from old.role
       or new.permissions is distinct from old.permissions
       or new.status is distinct from old.status
     ) then
    raise exception 'Only active managers can change roles, permissions or account status';
  end if;
  return new;
end
$$;

-- Restrictive policies are ANDed with the existing table policies. Profiles are
-- intentionally excluded so a suspended user can receive their own status event.
do $$
declare
  target_table text;
begin
  foreach target_table in array array[
    'suppliers', 'customers', 'materials', 'material_purchases', 'purchases',
    'products', 'production_orders', 'sales', 'rentals', 'supplier_payments',
    'customer_receipts', 'expenses', 'projects', 'project_files',
    'project_activities', 'employees', 'payroll', 'daily_labor', 'project_costs',
    'audit_log'
  ] loop
    if to_regclass(format('public.%I', target_table)) is not null then
      execute format('alter table public.%I enable row level security', target_table);
      execute format('drop policy if exists active_profile_restriction on public.%I', target_table);
      execute format(
        'create policy active_profile_restriction on public.%I as restrictive for all to authenticated using (public.is_current_profile_active()) with check (public.is_current_profile_active())',
        target_table
      );
    end if;
  end loop;
end;
$$;

-- Add every operational table to the Realtime publication once. "purchases" is
-- supported when present; this application currently stores purchases in
-- material_purchases.
do $$
declare
  target_table text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach target_table in array array[
      'profiles', 'projects', 'project_files', 'project_activities', 'employees',
      'payroll', 'daily_labor', 'materials', 'material_purchases', 'purchases',
      'products', 'production_orders', 'expenses', 'sales', 'rentals', 'suppliers',
      'supplier_payments', 'customers', 'customer_receipts', 'project_costs',
      'audit_log'
    ] loop
      if to_regclass(format('public.%I', target_table)) is not null
         and not exists (
           select 1
           from pg_publication_tables as publication_table
           where publication_table.pubname = 'supabase_realtime'
             and publication_table.schemaname = 'public'
             and publication_table.tablename = target_table
         ) then
        execute format('alter publication supabase_realtime add table public.%I', target_table);
      end if;
    end loop;
  end if;
end;
$$;
