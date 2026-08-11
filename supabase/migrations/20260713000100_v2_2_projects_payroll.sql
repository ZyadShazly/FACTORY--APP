-- NEXTEP ERP V2.2: projects, files, payroll, daily labor, permissions and auditing
create extension if not exists pgcrypto;

alter table public.profiles add column if not exists permissions jsonb not null default '{}'::jsonb;

create or replace function public.current_app_role()
returns text language sql stable security definer set search_path = public
as $$ select coalesce((select role from public.profiles where id = auth.uid()), '') $$;

create or replace function public.has_permission(permission_name text)
returns boolean language sql stable security definer set search_path = public
as $$
  select public.current_app_role() = 'manager'
    or coalesce((select (permissions ->> permission_name)::boolean from public.profiles where id = auth.uid()), false)
    or case public.current_app_role()
      when 'accountant' then permission_name = any(array[
        'projects_view','projects_create','project_financials_view','project_files_view','project_files_upload',
        'payroll_view','payroll_create','payroll_edit','payroll_mark_paid','daily_labor_view',
        'daily_labor_create','daily_labor_edit','daily_labor_pay'
      ])
      when 'production' then permission_name = any(array['projects_view','project_files_view'])
      else false
    end;
$$;

create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  project_code text not null unique,
  project_name text not null,
  customer_id uuid references public.customers(id) on delete set null,
  location text,
  start_date date,
  delivery_date date,
  project_manager_id uuid references public.profiles(id) on delete set null,
  status text not null default 'design' check (status in ('design','approval','manufacturing','painting','installation','delivered','on_hold','cancelled')),
  progress_percentage numeric(5,2) not null default 0 check (progress_percentage between 0 and 100),
  expected_cost numeric(14,2) not null default 0,
  actual_cost numeric(14,2) not null default 0,
  revenue numeric(14,2) not null default 0,
  profit numeric(14,2) generated always as (revenue - actual_cost) stored,
  notes text,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.project_files (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  file_name text not null,
  file_path text not null unique,
  file_type text,
  file_size bigint not null default 0 check (file_size >= 0),
  category text not null default 'other' check (category in ('2d','3d','measurements','cutting_list','approvals','site_photos','other')),
  description text,
  uploaded_by uuid references public.profiles(id) on delete set null default auth.uid(),
  uploaded_at timestamptz not null default now()
);

create table if not exists public.project_activities (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null default auth.uid(),
  action_type text not null,
  description text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.employees (
  id uuid primary key default gen_random_uuid(), full_name text not null, phone text, job_title text,
  department text, base_salary numeric(14,2) not null default 0, housing_allowance numeric(14,2) not null default 0,
  transport_allowance numeric(14,2) not null default 0, other_allowance numeric(14,2) not null default 0,
  hire_date date, status text not null default 'active' check (status in ('active','suspended','resigned','terminated')),
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.payroll (
  id uuid primary key default gen_random_uuid(), employee_id uuid not null references public.employees(id) on delete restrict,
  payroll_month date not null, base_salary numeric(14,2) not null default 0,
  housing_allowance numeric(14,2) not null default 0, transport_allowance numeric(14,2) not null default 0,
  other_allowance numeric(14,2) not null default 0, overtime_hours numeric(10,2) not null default 0,
  overtime_rate numeric(14,2) not null default 0,
  overtime_amount numeric(14,2) generated always as (overtime_hours * overtime_rate) stored,
  deductions numeric(14,2) not null default 0, bonuses numeric(14,2) not null default 0,
  advances numeric(14,2) not null default 0,
  net_salary numeric(14,2) generated always as (
    base_salary + housing_allowance + transport_allowance + other_allowance +
    (overtime_hours * overtime_rate) + bonuses - deductions - advances
  ) stored,
  status text not null default 'draft' check (status in ('draft','approved','paid')),
  notes text, approved_by uuid references public.profiles(id) on delete set null,
  approved_at timestamptz, paid_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(employee_id, payroll_month),
  check (date_trunc('month', payroll_month)::date = payroll_month)
);

create table if not exists public.daily_labor (
  id uuid primary key default gen_random_uuid(), worker_name text not null, phone text, trade text,
  project_id uuid references public.projects(id) on delete set null, work_date date not null,
  start_time time not null, end_time time not null, break_minutes integer not null default 0 check (break_minutes >= 0),
  hourly_rate numeric(14,2) not null default 0, overtime_hours numeric(10,2) not null default 0,
  overtime_rate numeric(14,2) not null default 0, total_hours numeric(10,2) not null default 0,
  total_amount numeric(14,2) not null default 0,
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid','partially_paid','paid')),
  paid_amount numeric(14,2) not null default 0, notes text,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.project_costs (
  id uuid primary key default gen_random_uuid(), project_id uuid not null references public.projects(id) on delete cascade,
  cost_type text not null check (cost_type in ('material','production','payroll','daily_labor','expense','transport','other')),
  reference_id uuid, amount numeric(14,2) not null default 0, description text, cost_date date not null default current_date,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(), created_at timestamptz not null default now()
);

alter table if exists public.production_orders add column if not exists project_id uuid references public.projects(id) on delete set null;
alter table if exists public.material_purchases add column if not exists project_id uuid references public.projects(id) on delete set null;
alter table if exists public.expenses add column if not exists project_id uuid references public.projects(id) on delete set null;
alter table public.payroll add column if not exists project_id uuid references public.projects(id) on delete set null;

create table if not exists public.audit_log (
  id bigint generated always as identity primary key, table_name text not null, record_id text,
  action text not null, actor_id uuid, old_data jsonb, new_data jsonb, metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists projects_status_idx on public.projects(status);
create index if not exists projects_customer_idx on public.projects(customer_id);
create index if not exists projects_dates_idx on public.projects(start_date, delivery_date);
create index if not exists project_files_project_idx on public.project_files(project_id, category);
create index if not exists project_activities_timeline_idx on public.project_activities(project_id, created_at desc);
create index if not exists payroll_month_status_idx on public.payroll(payroll_month, status);
create index if not exists daily_labor_project_date_idx on public.daily_labor(project_id, work_date);
create index if not exists daily_labor_worker_date_idx on public.daily_labor(worker_name, work_date);
create index if not exists project_costs_project_type_idx on public.project_costs(project_id, cost_type);
create index if not exists audit_log_created_idx on public.audit_log(created_at desc);

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end $$;

do $$ declare t text; begin
  foreach t in array array['projects','employees','payroll','daily_labor'] loop
    execute format('drop trigger if exists set_updated_at on public.%I', t);
    execute format('create trigger set_updated_at before update on public.%I for each row execute function public.set_updated_at()', t);
  end loop;
end $$;

create or replace function public.calculate_daily_labor()
returns trigger language plpgsql as $$
declare minutes_worked numeric; normal_hours numeric;
begin
  minutes_worked := extract(epoch from ((new.work_date + new.end_time + case when new.end_time <= new.start_time then interval '1 day' else interval '0 day' end) - (new.work_date + new.start_time))) / 60 - new.break_minutes;
  new.total_hours := greatest(round(minutes_worked / 60, 2), 0);
  normal_hours := greatest(new.total_hours - new.overtime_hours, 0);
  new.total_amount := round(normal_hours * new.hourly_rate + new.overtime_hours * new.overtime_rate, 2);
  new.paid_amount := least(greatest(new.paid_amount, 0), new.total_amount);
  return new;
end $$;
drop trigger if exists calculate_daily_labor on public.daily_labor;
create trigger calculate_daily_labor before insert or update on public.daily_labor for each row execute function public.calculate_daily_labor();

create or replace function public.protect_payroll_workflow()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if ((tg_op = 'INSERT' and new.bonuses <> 0) or (tg_op = 'UPDATE' and new.bonuses is distinct from old.bonuses)) and not public.has_permission('payroll_bonus_manage') then
    raise exception 'Only managers can manage payroll bonuses';
  end if;
  if new.status = 'approved' and (tg_op = 'INSERT' or old.status is distinct from 'approved') then
    if not public.has_permission('payroll_approve') then raise exception 'Payroll approval permission required'; end if;
    new.approved_by := auth.uid(); new.approved_at := now();
  end if;
  if new.status = 'paid' and (tg_op = 'INSERT' or old.status is distinct from 'paid') then
    if not public.has_permission('payroll_mark_paid') then raise exception 'Payroll payment permission required'; end if;
    if tg_op = 'INSERT' or old.status <> 'approved' then raise exception 'Payroll must be approved before payment'; end if;
    new.paid_at := now();
  end if;
  return new;
end $$;
drop trigger if exists protect_payroll_workflow on public.payroll;
create trigger protect_payroll_workflow before insert or update on public.payroll for each row execute function public.protect_payroll_workflow();

create or replace function public.protect_project_fields()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.current_app_role() = 'production' then
    if new.expected_cost is distinct from old.expected_cost or new.actual_cost is distinct from old.actual_cost or new.revenue is distinct from old.revenue then
      raise exception 'Production users cannot change financial fields';
    end if;
    if new.status is distinct from old.status then raise exception 'Only managers can change project status'; end if;
  elsif public.current_app_role() = 'accountant' and new.status is distinct from old.status then
    raise exception 'Only managers can change project status';
  end if;
  return new;
end $$;
drop trigger if exists protect_project_fields on public.projects;
create trigger protect_project_fields before update on public.projects for each row execute function public.protect_project_fields();

create or replace function public.get_projects_visible()
returns setof jsonb language sql stable security definer set search_path = public as $$
  select case when public.has_permission('project_financials_view') then to_jsonb(p)
    else to_jsonb(p) - array['expected_cost','actual_cost','revenue','profit'] end
  from public.projects p where public.has_permission('projects_view') order by p.created_at;
$$;
grant execute on function public.get_projects_visible() to authenticated;

create or replace function public.protect_profile_privileges()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.current_app_role() <> 'manager' and (new.role is distinct from old.role or new.permissions is distinct from old.permissions) then
    raise exception 'Only managers can change roles and permissions';
  end if;
  return new;
end $$;
drop trigger if exists protect_profile_privileges on public.profiles;
create trigger protect_profile_privileges before update on public.profiles for each row execute function public.protect_profile_privileges();

create policy profiles_update_manager_v22 on public.profiles for update using (public.current_app_role() = 'manager') with check (public.current_app_role() = 'manager');

create or replace function public.audit_row_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare rid text;
begin
  rid := coalesce((case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'id', '');
  insert into public.audit_log(table_name, record_id, action, actor_id, old_data, new_data)
  values (tg_table_name, rid, lower(tg_op), auth.uid(), case when tg_op <> 'INSERT' then to_jsonb(old) end, case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

do $$ declare t text; begin
  foreach t in array array['projects','project_files','project_activities','employees','payroll','daily_labor','project_costs'] loop
    execute format('drop trigger if exists audit_changes on public.%I', t);
    execute format('create trigger audit_changes after insert or update or delete on public.%I for each row execute function public.audit_row_change()', t);
  end loop;
end $$;

create or replace function public.log_project_activity()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.project_activities(project_id, action_type, description) values(new.id, 'project_created', 'تم إنشاء المشروع');
  elsif new.status is distinct from old.status then
    insert into public.project_activities(project_id, action_type, description, metadata) values(new.id, 'status_changed', 'تم تغيير حالة المشروع', jsonb_build_object('from', old.status, 'to', new.status));
  elsif new.progress_percentage is distinct from old.progress_percentage then
    insert into public.project_activities(project_id, action_type, description, metadata) values(new.id, 'progress_updated', 'تم تحديث نسبة الإنجاز', jsonb_build_object('from', old.progress_percentage, 'to', new.progress_percentage));
  end if;
  return new;
end $$;
drop trigger if exists log_project_activity on public.projects;
create trigger log_project_activity after insert or update on public.projects for each row execute function public.log_project_activity();

create or replace function public.refresh_project_actual_cost(target_project uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.projects set actual_cost = coalesce((select sum(amount) from public.project_costs where project_id = target_project), 0) where id = target_project;
end $$;

create or replace function public.sync_project_cost()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.refresh_project_actual_cost(coalesce(new.project_id, old.project_id)); return coalesce(new, old); end $$;
drop trigger if exists sync_project_cost on public.project_costs;
create trigger sync_project_cost after insert or update or delete on public.project_costs for each row execute function public.sync_project_cost();

alter table public.projects enable row level security;
alter table public.project_files enable row level security;
alter table public.project_activities enable row level security;
alter table public.employees enable row level security;
alter table public.payroll enable row level security;
alter table public.daily_labor enable row level security;
alter table public.project_costs enable row level security;
alter table public.audit_log enable row level security;

create policy projects_select on public.projects for select using (public.current_app_role() in ('manager','accountant') and public.has_permission('projects_view'));
create policy projects_insert on public.projects for insert with check (public.has_permission('projects_create'));
create policy projects_update on public.projects for update using (public.has_permission('projects_edit') or public.current_app_role() in ('accountant','production'));
create policy projects_delete on public.projects for delete using (public.has_permission('projects_delete'));
create policy project_files_select on public.project_files for select using (public.has_permission('project_files_view'));
create policy project_files_insert on public.project_files for insert with check (public.has_permission('project_files_upload'));
create policy project_files_delete on public.project_files for delete using (public.has_permission('project_files_delete'));
create policy project_activities_select on public.project_activities for select using (public.has_permission('projects_view'));
create policy project_activities_insert on public.project_activities for insert with check (public.has_permission('projects_view'));
create policy employees_select on public.employees for select using (public.current_app_role() in ('manager','accountant'));
create policy employees_manage on public.employees for all using (public.current_app_role() in ('manager','accountant')) with check (public.current_app_role() in ('manager','accountant'));
create policy payroll_select on public.payroll for select using (public.has_permission('payroll_view'));
create policy payroll_insert on public.payroll for insert with check (public.has_permission('payroll_create'));
create policy payroll_update on public.payroll for update using (public.has_permission('payroll_edit') or public.has_permission('payroll_mark_paid'));
create policy payroll_delete on public.payroll for delete using (public.current_app_role() = 'manager');
create policy daily_labor_select on public.daily_labor for select using (public.has_permission('daily_labor_view'));
create policy daily_labor_insert on public.daily_labor for insert with check (public.has_permission('daily_labor_create'));
create policy daily_labor_update on public.daily_labor for update using (public.has_permission('daily_labor_edit') or public.has_permission('daily_labor_pay'));
create policy daily_labor_delete on public.daily_labor for delete using (public.has_permission('daily_labor_delete'));
create policy project_costs_select on public.project_costs for select using (public.has_permission('project_financials_view'));
create policy project_costs_manage on public.project_costs for all using (public.current_app_role() in ('manager','accountant')) with check (public.current_app_role() in ('manager','accountant'));
create policy audit_manager_select on public.audit_log for select using (public.current_app_role() = 'manager');

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('project-files', 'project-files', false, 52428800, array[
  'application/pdf','image/jpeg','image/png','image/webp','application/zip','application/x-zip-compressed',
  'application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/acad','application/dxf','application/octet-stream'
]) on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create policy project_files_storage_read on storage.objects for select to authenticated using (bucket_id = 'project-files' and public.has_permission('project_files_view'));
create policy project_files_storage_insert on storage.objects for insert to authenticated with check (bucket_id = 'project-files' and public.has_permission('project_files_upload'));
create policy project_files_storage_delete on storage.objects for delete to authenticated using (bucket_id = 'project-files' and public.has_permission('project_files_delete'));

alter publication supabase_realtime add table public.projects, public.project_files, public.project_activities, public.employees, public.payroll, public.daily_labor, public.project_costs;
