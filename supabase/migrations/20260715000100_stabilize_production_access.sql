-- Stabilization: production employees are limited to production operations.
-- This migration removes legacy V2.2 project/file defaults and adds restrictive
-- policies so older permissive policies cannot expose financial modules.

update public.profiles
set permissions = jsonb_build_object(
  'pages', jsonb_build_array('production'),
  'can_delete', false,
  'view_financials', false,
  'can_create_products', false,
  'can_edit_products', false
)
where role = 'production';

create or replace function public.has_permission(permission_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case public.current_app_role()
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

do $$
declare
  target_table text;
begin
  foreach target_table in array array[
    'material_purchases', 'sales', 'rentals', 'suppliers', 'supplier_payments',
    'customers', 'customer_receipts', 'expenses', 'projects', 'project_files',
    'project_activities', 'employees', 'payroll', 'daily_labor', 'project_costs',
    'audit_log'
  ] loop
    if to_regclass(format('public.%I', target_table)) is not null then
      execute format('alter table public.%I enable row level security', target_table);
      execute format('drop policy if exists production_module_isolation on public.%I', target_table);
      execute format(
        'create policy production_module_isolation on public.%I as restrictive for all to authenticated using (public.current_app_role() <> ''production'') with check (public.current_app_role() <> ''production'')',
        target_table
      );
    end if;
  end loop;
end;
$$;

drop policy if exists production_profile_scope on public.profiles;
create policy production_profile_scope
on public.profiles
as restrictive
for all
to authenticated
using (public.current_app_role() <> 'production' or id = auth.uid())
with check (public.current_app_role() <> 'production' or id = auth.uid());

