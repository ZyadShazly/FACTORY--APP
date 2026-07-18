-- NEXTEP ERP — Project Workspace and lifecycle foundation.
-- Safe after migrations through 202607180008. Existing project IDs, status,
-- progress, files, activities, costs, and linked operational records are preserved.

do $$
begin
  if to_regclass('public.projects') is null
    or to_regclass('public.project_files') is null
    or to_regclass('public.project_activities') is null
    or to_regclass('public.project_costs') is null then
    raise exception 'Project Workspace requires the existing Projects V2.2 tables';
  end if;
  if to_regprocedure('public.has_permission(text)') is null
    or to_regprocedure('public.audit_row_change()') is null
    or to_regprocedure('public.get_projects_visible()') is null then
    raise exception 'Project Workspace requires the existing permission, audit, and visibility functions';
  end if;
end
$$;

-- Preserve legacy status as the compatibility column while separating lifecycle.
alter table public.projects add column if not exists execution_stage text;
alter table public.projects add column if not exists lifecycle text;
alter table public.projects add column if not exists priority text;
alter table public.projects add column if not exists progress_mode text;
alter table public.projects add column if not exists manual_progress_percentage numeric(5,2);
alter table public.projects add column if not exists calculated_progress_percentage numeric(5,2);
alter table public.projects add column if not exists effective_progress_percentage numeric(5,2);
alter table public.projects add column if not exists progress_override_reason text;
alter table public.projects add column if not exists progress_updated_by uuid references public.profiles(id) on delete set null;
alter table public.projects add column if not exists progress_updated_at timestamptz;
alter table public.projects add column if not exists lifecycle_changed_by uuid references public.profiles(id) on delete set null;
alter table public.projects add column if not exists lifecycle_changed_at timestamptz;
alter table public.projects add column if not exists lifecycle_reason text;
alter table public.projects add column if not exists legacy_activation_exempt boolean;
alter table public.projects add column if not exists updated_by uuid references public.profiles(id) on delete set null;

update public.projects
set execution_stage = status
where execution_stage is null;

-- Exact legacy mapping: design/approval remain planning work, execution work is
-- active, delivered becomes completed (never closed), and terminal meanings stay.
update public.projects
set lifecycle = case status
  when 'design' then 'planning'
  when 'approval' then 'planning'
  when 'manufacturing' then 'active'
  when 'painting' then 'active'
  when 'installation' then 'active'
  when 'delivered' then 'completed'
  when 'on_hold' then 'on_hold'
  when 'cancelled' then 'cancelled'
  else 'planning'
end
where lifecycle is null;

update public.projects
set priority = coalesce(priority, 'normal'),
    progress_mode = coalesce(progress_mode, 'hybrid'),
    manual_progress_percentage = coalesce(manual_progress_percentage, progress_percentage, 0),
    calculated_progress_percentage = coalesce(calculated_progress_percentage, 0),
    effective_progress_percentage = coalesce(effective_progress_percentage, progress_percentage, 0),
    progress_override_reason = coalesce(progress_override_reason, 'تم ترحيل نسبة الإنجاز القديمة'),
    progress_updated_by = coalesce(progress_updated_by, created_by),
    progress_updated_at = coalesce(progress_updated_at, updated_at, created_at),
    lifecycle_changed_by = coalesce(lifecycle_changed_by, created_by),
    lifecycle_changed_at = coalesce(lifecycle_changed_at, updated_at, created_at),
    legacy_activation_exempt = coalesce(legacy_activation_exempt, true),
    updated_by = coalesce(updated_by, created_by);

alter table public.projects alter column execution_stage set default 'design';
alter table public.projects alter column execution_stage set not null;
alter table public.projects alter column lifecycle set default 'draft';
alter table public.projects alter column lifecycle set not null;
alter table public.projects alter column priority set default 'normal';
alter table public.projects alter column priority set not null;
alter table public.projects alter column progress_mode set default 'hybrid';
alter table public.projects alter column progress_mode set not null;
alter table public.projects alter column manual_progress_percentage set default 0;
alter table public.projects alter column manual_progress_percentage set not null;
alter table public.projects alter column calculated_progress_percentage set default 0;
alter table public.projects alter column calculated_progress_percentage set not null;
alter table public.projects alter column effective_progress_percentage set default 0;
alter table public.projects alter column effective_progress_percentage set not null;
alter table public.projects alter column legacy_activation_exempt set default false;
alter table public.projects alter column legacy_activation_exempt set not null;

alter table public.projects drop constraint if exists projects_lifecycle_check;
alter table public.projects add constraint projects_lifecycle_check check (
  lifecycle in ('draft','planning','ready_for_activation','active','on_hold','completed','closed','cancelled')
);
alter table public.projects drop constraint if exists projects_execution_stage_check;
alter table public.projects add constraint projects_execution_stage_check check (
  execution_stage in ('design','approval','manufacturing','painting','installation','delivered','on_hold','cancelled')
);
alter table public.projects drop constraint if exists projects_priority_check;
alter table public.projects add constraint projects_priority_check check (priority in ('low','normal','high','urgent'));
alter table public.projects drop constraint if exists projects_progress_mode_check;
alter table public.projects add constraint projects_progress_mode_check check (progress_mode in ('manual','automatic','hybrid'));
alter table public.projects drop constraint if exists projects_manual_progress_check;
alter table public.projects add constraint projects_manual_progress_check check (manual_progress_percentage between 0 and 100);
alter table public.projects drop constraint if exists projects_calculated_progress_check;
alter table public.projects add constraint projects_calculated_progress_check check (calculated_progress_percentage between 0 and 100);
alter table public.projects drop constraint if exists projects_effective_progress_check;
alter table public.projects add constraint projects_effective_progress_check check (effective_progress_percentage between 0 and 100);
alter table public.projects drop constraint if exists projects_date_order_check;
alter table public.projects add constraint projects_date_order_check check (delivery_date is null or start_date is null or delivery_date >= start_date);

create table if not exists public.project_milestones (
  id uuid primary key default extensions.gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  title text not null check (btrim(title) <> ''),
  description text,
  stage_key text not null check (stage_key in ('design','approval','manufacturing','painting','installation','delivered','on_hold','cancelled')),
  sequence integer not null default 0 check (sequence >= 0),
  weight_percentage numeric(5,2) not null default 0 check (weight_percentage between 0 and 100),
  responsible_profile_id uuid references public.profiles(id) on delete set null,
  responsible_employee_id uuid references public.employees(id) on delete set null,
  planned_start_date date,
  planned_end_date date,
  actual_start_at timestamptz,
  actual_completed_at timestamptz,
  status text not null default 'not_started' check (status in ('not_started','in_progress','blocked','completed','cancelled')),
  progress_percentage numeric(5,2) not null default 0 check (progress_percentage between 0 and 100),
  blocking_reason text,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  updated_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (planned_end_date is null or planned_start_date is null or planned_end_date >= planned_start_date),
  check (status <> 'blocked' or btrim(coalesce(blocking_reason, '')) <> ''),
  check ((status = 'completed' and progress_percentage = 100) or status <> 'completed'),
  check ((status = 'not_started' and progress_percentage = 0) or status <> 'not_started')
);

create table if not exists public.project_members (
  id uuid primary key default extensions.gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  profile_id uuid references public.profiles(id) on delete set null,
  employee_id uuid references public.employees(id) on delete set null,
  project_role text not null check (project_role in ('project_manager','site_engineer','designer','production','procurement','accountant','viewer')),
  active boolean not null default true,
  start_date date,
  end_date date,
  added_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (num_nonnulls(profile_id, employee_id) >= 1),
  check (end_date is null or start_date is null or end_date >= start_date),
  check (project_role <> 'project_manager' or profile_id is not null)
);

create table if not exists public.project_realtime_signal (
  id boolean primary key default true check (id),
  event_table text not null default 'projects',
  version bigint not null default 0,
  updated_at timestamptz not null default now()
);
insert into public.project_realtime_signal(id) values (true) on conflict (id) do nothing;

-- Seed canonical project-manager membership without changing the project manager.
insert into public.project_members(project_id, profile_id, employee_id, project_role, active, start_date, added_by)
select p.id, p.project_manager_id, pr.employee_id, 'project_manager', true, p.start_date, p.created_by
from public.projects p
join public.profiles pr on pr.id = p.project_manager_id
where p.project_manager_id is not null
  and not exists (
    select 1 from public.project_members pm
    where pm.project_id = p.id and pm.profile_id = p.project_manager_id and pm.active
  );

create unique index if not exists project_members_active_profile_unique
  on public.project_members(project_id, profile_id) where active and profile_id is not null;
create unique index if not exists project_members_active_employee_unique
  on public.project_members(project_id, employee_id) where active and employee_id is not null;
create unique index if not exists project_members_one_active_manager
  on public.project_members(project_id) where active and project_role = 'project_manager';
create index if not exists projects_manager_idx on public.projects(project_manager_id);
create index if not exists projects_lifecycle_idx on public.projects(lifecycle);
create index if not exists projects_execution_stage_idx on public.projects(execution_stage);
create index if not exists project_milestones_project_order_idx on public.project_milestones(project_id, sequence, id);
create index if not exists project_milestones_responsible_profile_idx on public.project_milestones(responsible_profile_id) where responsible_profile_id is not null;
create index if not exists project_milestones_responsible_employee_idx on public.project_milestones(responsible_employee_id) where responsible_employee_id is not null;
create index if not exists project_members_project_active_idx on public.project_members(project_id, active);

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create or replace function private.project_profile_active()
returns boolean language sql stable security definer set search_path = public, private, pg_temp as $$
  select exists(select 1 from public.profiles where id = auth.uid() and status = 'active')
$$;

-- Project-only authorization extension. Keep the shared public.has_permission(text)
-- definition from main untouched so Assets, Payroll, Calendar, Labor, and Audit
-- retain their exact merged behavior.
create or replace function private.project_has_permission(permission_name text)
returns boolean language sql stable security definer set search_path = public, private, pg_temp as $$
  select private.project_profile_active() and case public.current_identity_role()
    when 'production' then case
      when permission_name in ('projects_view','project_files_view') then true
      when permission_name in ('project_files_upload','projects_manage_milestones','projects_update_progress') then
        coalesce((select (permissions ->> permission_name)::boolean from public.profiles where id = auth.uid() and status = 'active'), false)
      else public.has_permission(permission_name)
    end
    else public.has_permission(permission_name)
  end
$$;

create or replace function private.project_can_view(target_project uuid)
returns boolean language sql stable security definer set search_path = public, private, pg_temp as $$
  select private.project_profile_active() and (
    public.current_identity_role() in ('owner','manager')
    or (private.project_has_permission('projects_view') and exists(
      select 1 from public.project_members pm
      where pm.project_id = target_project and pm.active
        and (pm.start_date is null or pm.start_date <= current_date)
        and (pm.end_date is null or pm.end_date >= current_date)
        and (pm.profile_id = auth.uid() or exists(
          select 1 from public.profiles p where p.id = auth.uid() and p.employee_id = pm.employee_id
        ))
    ))
  )
$$;

create or replace function private.project_can_manage(target_project uuid, permission_name text)
returns boolean language sql stable security definer set search_path = public, private, pg_temp as $$
  select private.project_profile_active()
    and private.project_has_permission(permission_name)
    and (
      public.current_identity_role() in ('owner','manager')
      or exists(
        select 1 from public.project_members pm
        where pm.project_id = target_project and pm.active and pm.project_role = 'project_manager'
          and (pm.start_date is null or pm.start_date <= current_date)
          and (pm.end_date is null or pm.end_date >= current_date)
          and pm.profile_id = auth.uid()
      )
    )
$$;

revoke all on function private.project_profile_active() from public, anon;
revoke all on function private.project_has_permission(text) from public, anon;
revoke all on function private.project_can_view(uuid) from public, anon;
revoke all on function private.project_can_manage(uuid,text) from public, anon;
grant execute on function private.project_profile_active() to authenticated;
grant execute on function private.project_has_permission(text) to authenticated;
grant execute on function private.project_can_view(uuid) to authenticated;
grant execute on function private.project_can_manage(uuid,text) to authenticated;

create or replace function public.project_activation_readiness(target_project uuid)
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare p public.projects%rowtype; checks jsonb; implemented_ready boolean;
begin
  if auth.uid() is null or not private.project_can_view(target_project) then raise exception 'Project view permission required'; end if;
  select * into p from public.projects where id = target_project;
  if not found then raise exception 'Project not found'; end if;
  implemented_ready := btrim(p.project_name) <> ''
    and p.start_date is not null
    and (p.delivery_date is null or p.delivery_date >= p.start_date)
    and p.project_manager_id is not null;
  checks := jsonb_build_array(
    jsonb_build_object('key','required_details','label','البيانات الأساسية','implemented',true,'passed',btrim(p.project_name) <> '' and p.start_date is not null),
    jsonb_build_object('key','valid_dates','label','صحة التواريخ','implemented',true,'passed',p.delivery_date is null or p.delivery_date >= p.start_date),
    jsonb_build_object('key','project_manager','label','مدير المشروع','implemented',true,'passed',p.project_manager_id is not null),
    jsonb_build_object('key','estimated_budget_approval','label','اعتماد الميزانية التقديرية','implemented',false,'passed',null,'blocking',false,'status','not_implemented')
  );
  return jsonb_build_object(
    'project_id',p.id,'ready',implemented_ready or p.legacy_activation_exempt,
    'legacy_activation_exempt',p.legacy_activation_exempt,
    'future_budget_check','not_implemented','checks',checks
  );
end
$$;

create or replace function public.project_calculated_progress(target_project uuid)
returns numeric language sql stable security definer set search_path = public, pg_temp as $$
  select case when coalesce(sum(weight_percentage),0) = 0 then 0
    else round(sum(weight_percentage * progress_percentage) / sum(weight_percentage), 2) end
  from public.project_milestones
  where project_id = target_project and status <> 'cancelled'
$$;

create or replace function public.validate_project_milestone_weight()
returns trigger language plpgsql set search_path = public, pg_temp as $$
declare total_weight numeric;
begin
  if new.status = 'completed' then new.progress_percentage := 100; new.actual_completed_at := coalesce(new.actual_completed_at, now()); end if;
  if new.status = 'not_started' then new.progress_percentage := 0; end if;
  if new.status = 'in_progress' then new.actual_start_at := coalesce(new.actual_start_at, now()); end if;
  if new.status <> 'cancelled' then
    select coalesce(sum(weight_percentage),0) into total_weight
    from public.project_milestones
    where project_id = new.project_id and status <> 'cancelled' and id <> new.id;
    if total_weight + new.weight_percentage > 100 then raise exception 'Active milestone weights cannot exceed 100%%'; end if;
  end if;
  new.updated_at := now(); new.updated_by := coalesce(auth.uid(), new.updated_by);
  return new;
end
$$;

create or replace function public.refresh_project_progress_from_milestones()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare target uuid; calculated numeric; mode text; manual numeric; override_reason text; effective numeric;
begin
  target := coalesce(new.project_id, old.project_id);
  calculated := public.project_calculated_progress(target);
  select progress_mode, manual_progress_percentage, progress_override_reason into mode, manual, override_reason from public.projects where id = target for update;
  effective := case mode when 'automatic' then calculated when 'manual' then manual
    else case when override_reason is not null then manual else calculated end end;
  perform set_config('app.project_workspace_rpc','on',true);
  update public.projects set calculated_progress_percentage = calculated,
    effective_progress_percentage = effective, progress_percentage = effective,
    updated_at = now(), updated_by = coalesce(auth.uid(), updated_by)
  where id = target;
  return coalesce(new, old);
end
$$;

create or replace function public.validate_project_member_identity()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if new.profile_id is not null and not exists(select 1 from public.profiles where id = new.profile_id and status = 'active') then
    raise exception 'Project member profile must be active';
  end if;
  if new.employee_id is not null and not exists(select 1 from public.employees where id = new.employee_id and status = 'active') then
    raise exception 'Project member employee must be active';
  end if;
  if new.profile_id is not null and new.employee_id is not null and not exists(
    select 1 from public.profiles where id = new.profile_id and employee_id = new.employee_id
  ) then raise exception 'Project profile and employee identities do not match'; end if;
  new.updated_at := now();
  return new;
end
$$;

create or replace function public.protect_project_workspace_fields()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if current_setting('app.project_workspace_rpc', true) is distinct from 'on' then
    raise exception 'Projects must be changed through protected Project Workspace RPCs';
  end if;
  if tg_op = 'DELETE' then raise exception 'Projects cannot be hard deleted; use lifecycle cancellation'; end if;
  new.execution_stage := coalesce(new.execution_stage, new.status);
  new.status := new.execution_stage;
  new.progress_percentage := new.effective_progress_percentage;
  new.updated_at := now();
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  return new;
end
$$;

create or replace function public.emit_project_realtime_signal()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.project_realtime_signal(id,event_table,version,updated_at)
  values(true,tg_table_name,1,now())
  on conflict(id) do update set event_table=excluded.event_table,
    version=public.project_realtime_signal.version+1,updated_at=excluded.updated_at;
  return coalesce(new, old);
end
$$;

drop trigger if exists protect_project_fields on public.projects;
drop trigger if exists protect_project_workspace_fields on public.projects;
create trigger protect_project_workspace_fields before update or delete on public.projects
for each row execute function public.protect_project_workspace_fields();
drop trigger if exists log_project_activity on public.projects;
drop trigger if exists validate_project_milestone_weight on public.project_milestones;
create trigger validate_project_milestone_weight before insert or update on public.project_milestones
for each row execute function public.validate_project_milestone_weight();
drop trigger if exists refresh_project_progress_from_milestones on public.project_milestones;
create trigger refresh_project_progress_from_milestones after insert or update or delete on public.project_milestones
for each row execute function public.refresh_project_progress_from_milestones();
drop trigger if exists validate_project_member_identity on public.project_members;
create trigger validate_project_member_identity before insert or update on public.project_members
for each row execute function public.validate_project_member_identity();

do $$ declare t text; begin
  foreach t in array array['projects','project_milestones','project_members'] loop
    execute format('drop trigger if exists project_realtime_signal on public.%I',t);
    execute format('create trigger project_realtime_signal after insert or update or delete on public.%I for each statement execute function public.emit_project_realtime_signal()',t);
  end loop;
end $$;

-- Existing cost synchronization remains the source for projects.actual_cost.
create or replace function public.refresh_project_actual_cost(target_project uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform set_config('app.project_workspace_rpc','on',true);
  update public.projects set actual_cost = coalesce((select sum(amount) from public.project_costs where project_id = target_project),0),
    updated_at=now() where id=target_project;
end
$$;

create or replace function public.get_projects_visible()
returns setof jsonb language sql stable security definer set search_path = public, private, pg_temp as $$
  select case when private.project_has_permission('project_financials_view') then to_jsonb(p)
    else to_jsonb(p) - array['expected_cost','actual_cost','revenue','profit'] end
  from public.projects p
  where private.project_can_view(p.id)
  order by p.created_at
$$;

create or replace function public.create_project_draft(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare actor uuid:=auth.uid(); created public.projects%rowtype; can_finance boolean;
begin
  if actor is null or not private.project_profile_active() then raise exception 'Active authentication required'; end if;
  if not private.project_has_permission('projects_create') then raise exception 'projects_create permission required'; end if;
  if btrim(coalesce(payload->>'project_code',''))='' or btrim(coalesce(payload->>'project_name',''))='' then raise exception 'Project code and name are required'; end if;
  can_finance := private.project_has_permission('project_financials_view');
  if can_finance and (coalesce(nullif(payload->>'expected_cost','')::numeric,0) < 0 or coalesce(nullif(payload->>'revenue','')::numeric,0) < 0) then
    raise exception 'Project financial values cannot be negative';
  end if;
  insert into public.projects(
    project_code,project_name,customer_id,location,start_date,delivery_date,status,execution_stage,lifecycle,priority,
    progress_percentage,progress_mode,manual_progress_percentage,calculated_progress_percentage,effective_progress_percentage,
    expected_cost,revenue,notes,created_by,updated_by,legacy_activation_exempt
  ) values (
    btrim(payload->>'project_code'),btrim(payload->>'project_name'),nullif(payload->>'customer_id','')::uuid,nullif(btrim(payload->>'location'),''),
    nullif(payload->>'start_date','')::date,nullif(payload->>'delivery_date','')::date,'design','design','draft',coalesce(nullif(payload->>'priority',''),'normal'),
    0,'hybrid',0,0,0,case when can_finance then coalesce(nullif(payload->>'expected_cost','')::numeric,0) else 0 end,
    case when can_finance then coalesce(nullif(payload->>'revenue','')::numeric,0) else 0 end,nullif(btrim(payload->>'notes'),''),actor,actor,false
  ) returning * into created;
  insert into public.project_activities(project_id,actor_id,action_type,description,metadata)
  values(created.id,actor,'project_created','تم إنشاء مسودة المشروع',jsonb_build_object('lifecycle','draft'));
  return to_jsonb(created);
end
$$;

create or replace function public.update_project_details(target_project uuid, payload jsonb)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare current_row public.projects%rowtype; updated public.projects%rowtype; actor uuid:=auth.uid();
begin
  if actor is null or not private.project_can_manage(target_project,'projects_edit') then raise exception 'projects_edit permission required'; end if;
  select * into current_row from public.projects where id=target_project for update;
  if not found then raise exception 'Project not found'; end if;
  if current_row.lifecycle in ('closed','cancelled') then raise exception 'Final projects are immutable'; end if;
  if payload ? 'project_name' and btrim(coalesce(payload->>'project_name',''))='' then raise exception 'Project name is required'; end if;
  if (payload ? 'expected_cost' or payload ? 'revenue') and not private.project_has_permission('project_financials_view') then raise exception 'project_financials_view permission required'; end if;
  if (payload ? 'expected_cost' and coalesce(nullif(payload->>'expected_cost','')::numeric,0) < 0)
    or (payload ? 'revenue' and coalesce(nullif(payload->>'revenue','')::numeric,0) < 0) then raise exception 'Project financial values cannot be negative'; end if;
  perform set_config('app.project_workspace_rpc','on',true);
  update public.projects set
    project_name=case when payload ? 'project_name' then btrim(payload->>'project_name') else project_name end,
    customer_id=case when payload ? 'customer_id' then nullif(payload->>'customer_id','')::uuid else customer_id end,
    location=case when payload ? 'location' then nullif(btrim(payload->>'location'),'') else location end,
    start_date=case when payload ? 'start_date' then nullif(payload->>'start_date','')::date else start_date end,
    delivery_date=case when payload ? 'delivery_date' then nullif(payload->>'delivery_date','')::date else delivery_date end,
    priority=case when payload ? 'priority' then payload->>'priority' else priority end,
    notes=case when payload ? 'notes' then nullif(btrim(payload->>'notes'),'') else notes end,
    expected_cost=case when payload ? 'expected_cost' then coalesce(nullif(payload->>'expected_cost','')::numeric,0) else expected_cost end,
    revenue=case when payload ? 'revenue' then coalesce(nullif(payload->>'revenue','')::numeric,0) else revenue end,
    updated_by=actor
  where id=target_project returning * into updated;
  insert into public.project_activities(project_id,actor_id,action_type,description,metadata)
  values(target_project,actor,'details_changed','تم تحديث بيانات المشروع',jsonb_build_object(
    'before',to_jsonb(current_row)-array['expected_cost','actual_cost','revenue','profit'],
    'changed_keys',(select jsonb_agg(key) from jsonb_object_keys(payload) as keys(key))
  ));
  return case when private.project_has_permission('project_financials_view') then to_jsonb(updated)
    else to_jsonb(updated)-array['expected_cost','actual_cost','revenue','profit'] end;
end
$$;

create or replace function public.transition_project_lifecycle(target_project uuid, next_lifecycle text, reason text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare p public.projects%rowtype; actor uuid:=auth.uid(); actor_role text; allowed boolean:=false; readiness jsonb;
begin
  if actor is null or not private.project_can_manage(target_project,'projects_manage_lifecycle') then raise exception 'projects_manage_lifecycle permission required'; end if;
  select * into p from public.projects where id=target_project for update;
  if not found then raise exception 'Project not found'; end if;
  actor_role:=public.current_identity_role();
  if p.lifecycle in ('closed','cancelled') then raise exception 'Final project lifecycle cannot change'; end if;
  allowed := case p.lifecycle
    when 'draft' then next_lifecycle in ('planning','cancelled')
    when 'planning' then next_lifecycle in ('draft','ready_for_activation','cancelled')
    when 'ready_for_activation' then next_lifecycle in ('planning','active','cancelled')
    when 'active' then next_lifecycle in ('on_hold','completed')
    when 'on_hold' then next_lifecycle in ('active','cancelled')
    when 'completed' then next_lifecycle in ('active','closed')
    else false end;
  if not allowed then raise exception 'Invalid project lifecycle transition: % -> %',p.lifecycle,next_lifecycle; end if;
  if next_lifecycle in ('cancelled','closed') or (p.lifecycle='completed' and next_lifecycle='active') then
    if btrim(coalesce(reason,''))='' then raise exception 'A mandatory reason is required for this transition'; end if;
  end if;
  if p.lifecycle='completed' and next_lifecycle='active' and (actor_role<>'owner' or not private.project_has_permission('projects_override')) then raise exception 'Only Owner may reopen a completed project'; end if;
  if next_lifecycle='closed' and not private.project_has_permission('projects_close') then raise exception 'projects_close permission required'; end if;
  if next_lifecycle='active' and p.lifecycle='ready_for_activation' then
    readiness:=public.project_activation_readiness(target_project);
    if not coalesce((readiness->>'ready')::boolean,false) then raise exception 'Project activation readiness checks are incomplete'; end if;
  end if;
  perform set_config('app.project_workspace_rpc','on',true);
  update public.projects set lifecycle=next_lifecycle,lifecycle_reason=nullif(btrim(reason),''),
    lifecycle_changed_by=actor,lifecycle_changed_at=now(),updated_by=actor
  where id=target_project returning * into p;
  insert into public.project_activities(project_id,actor_id,action_type,description,metadata)
  values(target_project,actor,'lifecycle_changed','تم تغيير دورة حياة المشروع',jsonb_build_object('to',next_lifecycle,'reason',reason));
  return to_jsonb(p);
end
$$;

create or replace function public.update_project_execution_stage(target_project uuid, next_stage text, reason text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare p public.projects%rowtype; old_stage text; actor uuid:=auth.uid();
begin
  if actor is null or not private.project_can_manage(target_project,'projects_manage_milestones') then raise exception 'projects_manage_milestones permission required'; end if;
  if next_stage not in ('design','approval','manufacturing','painting','installation','delivered','on_hold','cancelled') then raise exception 'Invalid execution stage'; end if;
  select * into p from public.projects where id=target_project for update;
  if not found then raise exception 'Project not found'; end if;
  if p.lifecycle in ('closed','cancelled') then raise exception 'Final projects are immutable'; end if;
  old_stage:=p.execution_stage;
  perform set_config('app.project_workspace_rpc','on',true);
  update public.projects set execution_stage=next_stage,status=next_stage,updated_by=actor where id=target_project returning * into p;
  insert into public.project_activities(project_id,actor_id,action_type,description,metadata)
  values(target_project,actor,'execution_stage_changed','تم تغيير مرحلة التنفيذ',jsonb_build_object('from',old_stage,'to',next_stage,'reason',reason));
  return case when private.project_has_permission('project_financials_view') then to_jsonb(p)
    else to_jsonb(p)-array['expected_cost','actual_cost','revenue','profit'] end;
end
$$;

create or replace function public.update_project_progress(target_project uuid, mode text, manual_percentage numeric default null, override_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare p public.projects%rowtype; calculated numeric; effective numeric; actor uuid:=auth.uid();
begin
  if actor is null or not private.project_can_manage(target_project,'projects_update_progress') then raise exception 'projects_update_progress permission required'; end if;
  if mode not in ('manual','automatic','hybrid') then raise exception 'Invalid progress mode'; end if;
  if manual_percentage is not null and (manual_percentage<0 or manual_percentage>100) then raise exception 'Progress must be between 0 and 100'; end if;
  select * into p from public.projects where id=target_project for update;
  if not found then raise exception 'Project not found'; end if;
  if p.lifecycle in ('closed','cancelled') then raise exception 'Final projects are immutable'; end if;
  calculated:=public.project_calculated_progress(target_project);
  if mode='manual' and manual_percentage is null then raise exception 'Manual progress is required'; end if;
  if mode='hybrid' and manual_percentage is not null and manual_percentage is distinct from calculated and btrim(coalesce(override_reason,''))='' then
    raise exception 'A reason is required for a hybrid progress override';
  end if;
  effective:=case mode when 'automatic' then calculated when 'manual' then manual_percentage else coalesce(manual_percentage,calculated) end;
  perform set_config('app.project_workspace_rpc','on',true);
  update public.projects set progress_mode=mode,
    manual_progress_percentage=coalesce(manual_percentage,manual_progress_percentage),
    calculated_progress_percentage=calculated,effective_progress_percentage=effective,progress_percentage=effective,
    progress_override_reason=nullif(btrim(override_reason),''),progress_updated_by=actor,progress_updated_at=now(),updated_by=actor
  where id=target_project returning * into p;
  insert into public.project_activities(project_id,actor_id,action_type,description,metadata)
  values(target_project,actor,case when override_reason is null then 'progress_updated' else 'progress_overridden' end,
    case when override_reason is null then 'تم تحديث نسبة إنجاز المشروع' else 'تم تجاوز نسبة الإنجاز المحسوبة يدويًا' end,
    jsonb_build_object('mode',mode,'manual',manual_percentage,'calculated',calculated,'effective',effective,'reason',override_reason));
  return case when private.project_has_permission('project_financials_view') then to_jsonb(p)
    else to_jsonb(p)-array['expected_cost','actual_cost','revenue','profit'] end;
end
$$;

create or replace function public.save_project_milestone(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare target_id uuid:=nullif(payload->>'id','')::uuid; target_project uuid:=nullif(payload->>'project_id','')::uuid; row public.project_milestones%rowtype; actor uuid:=auth.uid(); action text;
begin
  if actor is null or target_project is null or not private.project_can_manage(target_project,'projects_manage_milestones') then raise exception 'projects_manage_milestones permission required'; end if;
  if exists(select 1 from public.projects where id=target_project and lifecycle in ('closed','cancelled')) then raise exception 'Final projects are immutable'; end if;
  if target_id is null then
    insert into public.project_milestones(project_id,title,description,stage_key,sequence,weight_percentage,responsible_profile_id,responsible_employee_id,planned_start_date,planned_end_date,status,progress_percentage,blocking_reason,created_by,updated_by)
    values(target_project,btrim(payload->>'title'),nullif(btrim(payload->>'description'),''),payload->>'stage_key',coalesce((payload->>'sequence')::integer,0),coalesce((payload->>'weight_percentage')::numeric,0),nullif(payload->>'responsible_profile_id','')::uuid,nullif(payload->>'responsible_employee_id','')::uuid,nullif(payload->>'planned_start_date','')::date,nullif(payload->>'planned_end_date','')::date,coalesce(nullif(payload->>'status',''),'not_started'),coalesce((payload->>'progress_percentage')::numeric,0),nullif(btrim(payload->>'blocking_reason'),''),actor,actor)
    returning * into row; action:='milestone_created';
  else
    select * into row from public.project_milestones where id=target_id and project_id=target_project for update;
    if not found then raise exception 'Milestone not found'; end if;
    update public.project_milestones set title=btrim(payload->>'title'),description=nullif(btrim(payload->>'description'),''),stage_key=payload->>'stage_key',sequence=(payload->>'sequence')::integer,weight_percentage=(payload->>'weight_percentage')::numeric,responsible_profile_id=nullif(payload->>'responsible_profile_id','')::uuid,responsible_employee_id=nullif(payload->>'responsible_employee_id','')::uuid,planned_start_date=nullif(payload->>'planned_start_date','')::date,planned_end_date=nullif(payload->>'planned_end_date','')::date,status=payload->>'status',progress_percentage=(payload->>'progress_percentage')::numeric,blocking_reason=nullif(btrim(payload->>'blocking_reason'),''),updated_by=actor where id=target_id returning * into row;
    action:=case row.status when 'completed' then 'milestone_completed' when 'blocked' then 'milestone_blocked' else 'milestone_updated' end;
  end if;
  insert into public.project_activities(project_id,actor_id,action_type,description,metadata)
  values(target_project,actor,action,'تم تحديث مرحلة من مراحل التنفيذ',jsonb_build_object('milestone_id',row.id,'title',row.title,'status',row.status));
  return to_jsonb(row);
end
$$;

create or replace function public.remove_project_milestone(target_milestone uuid, reason text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare row public.project_milestones%rowtype; actor uuid:=auth.uid();
begin
  select * into row from public.project_milestones where id=target_milestone for update;
  if not found or actor is null or not private.project_can_manage(row.project_id,'projects_manage_milestones') then raise exception 'projects_manage_milestones permission required'; end if;
  if exists(select 1 from public.projects where id=row.project_id and lifecycle in ('closed','cancelled')) then raise exception 'Final projects are immutable'; end if;
  if btrim(coalesce(reason,''))='' then raise exception 'Cancellation reason is required'; end if;
  update public.project_milestones set status='cancelled',blocking_reason=reason,updated_by=actor where id=target_milestone returning * into row;
  insert into public.project_activities(project_id,actor_id,action_type,description,metadata)
  values(row.project_id,actor,'milestone_cancelled','تم إلغاء مرحلة تنفيذ',jsonb_build_object('milestone_id',row.id,'reason',reason));
  return to_jsonb(row);
end
$$;

create or replace function public.add_project_member(target_project uuid, target_profile uuid, target_employee uuid, member_role text, member_start date default null, member_end date default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare row public.project_members%rowtype; actor uuid:=auth.uid();
begin
  if actor is null or not private.project_can_manage(target_project,'projects_manage_team') then raise exception 'projects_manage_team permission required'; end if;
  if exists(select 1 from public.projects where id=target_project and lifecycle in ('closed','cancelled')) then raise exception 'Final projects are immutable'; end if;
  if member_role='project_manager' then
    perform 1 from public.projects where id=target_project for update;
    update public.project_members set active=false,end_date=coalesce(end_date,current_date),updated_at=now()
    where project_id=target_project and active and project_role='project_manager';
  end if;
  insert into public.project_members(project_id,profile_id,employee_id,project_role,start_date,end_date,added_by)
  values(target_project,target_profile,target_employee,member_role,member_start,member_end,actor) returning * into row;
  if member_role='project_manager' then
    perform set_config('app.project_workspace_rpc','on',true);
    update public.projects set project_manager_id=target_profile,updated_by=actor where id=target_project;
  end if;
  insert into public.project_activities(project_id,actor_id,action_type,description,metadata)
  values(target_project,actor,'team_member_added','تمت إضافة عضو إلى فريق المشروع',jsonb_build_object('member_id',row.id,'role',member_role));
  return to_jsonb(row);
end
$$;

create or replace function public.update_project_member(target_member uuid, member_role text, member_active boolean, member_start date default null, member_end date default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare row public.project_members%rowtype; actor uuid:=auth.uid();
begin
  select * into row from public.project_members where id=target_member for update;
  if not found or actor is null or not private.project_can_manage(row.project_id,'projects_manage_team') then raise exception 'projects_manage_team permission required'; end if;
  if exists(select 1 from public.projects where id=row.project_id and lifecycle in ('closed','cancelled')) then raise exception 'Final projects are immutable'; end if;
  if member_active and member_role='project_manager' and row.project_role<>'project_manager' then
    perform 1 from public.projects where id=row.project_id for update;
    update public.project_members set active=false,end_date=coalesce(end_date,current_date),updated_at=now()
    where project_id=row.project_id and id<>target_member and active and project_role='project_manager';
  end if;
  if row.project_role='project_manager' and (not member_active or member_role<>'project_manager') then
    perform set_config('app.project_workspace_rpc','on',true);
    update public.projects set project_manager_id=null,updated_by=actor where id=row.project_id and project_manager_id=row.profile_id;
  end if;
  update public.project_members set project_role=member_role,active=member_active,start_date=member_start,end_date=member_end,updated_at=now() where id=target_member returning * into row;
  if row.project_role='project_manager' and row.active then
    perform set_config('app.project_workspace_rpc','on',true);
    update public.projects set project_manager_id=row.profile_id,updated_by=actor where id=row.project_id;
  end if;
  insert into public.project_activities(project_id,actor_id,action_type,description,metadata)
  values(row.project_id,actor,'team_member_updated','تم تحديث عضو في فريق المشروع',jsonb_build_object('member_id',row.id,'role',row.project_role,'active',row.active));
  return to_jsonb(row);
end
$$;

create or replace function public.remove_project_member(target_member uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare row public.project_members%rowtype; actor uuid:=auth.uid();
begin
  select * into row from public.project_members where id=target_member for update;
  if not found or actor is null or not private.project_can_manage(row.project_id,'projects_manage_team') then raise exception 'projects_manage_team permission required'; end if;
  if exists(select 1 from public.projects where id=row.project_id and lifecycle in ('closed','cancelled')) then raise exception 'Final projects are immutable'; end if;
  if row.project_role='project_manager' then
    perform set_config('app.project_workspace_rpc','on',true);
    update public.projects set project_manager_id=null,updated_by=actor where id=row.project_id and project_manager_id=row.profile_id;
  end if;
  update public.project_members set active=false,end_date=coalesce(end_date,current_date),updated_at=now() where id=target_member returning * into row;
  insert into public.project_activities(project_id,actor_id,action_type,description,metadata)
  values(row.project_id,actor,'team_member_removed','تمت إزالة عضو من فريق المشروع',jsonb_build_object('member_id',row.id));
  return to_jsonb(row);
end
$$;

create or replace function public.archive_or_cancel_project(target_project uuid, reason text)
returns jsonb language sql security definer set search_path = public, pg_temp as $$
  select public.transition_project_lifecycle(target_project,'cancelled',reason)
$$;

-- Project file actions remain their established workflow but now emit useful activity.
create or replace function public.log_project_file_deleted()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.project_activities(project_id,actor_id,action_type,description,metadata)
  values(old.project_id,auth.uid(),'file_deleted','تم حذف ملف من المشروع',jsonb_build_object('file_name',old.file_name,'file_path',old.file_path));
  return old;
end
$$;
drop trigger if exists log_project_file_deleted on public.project_files;
create trigger log_project_file_deleted after delete on public.project_files for each row execute function public.log_project_file_deleted();

-- RLS: projects are never selected/mutated directly; safe field projection is RPC-only.
alter table public.project_milestones enable row level security;
alter table public.project_members enable row level security;
alter table public.project_realtime_signal enable row level security;
drop policy if exists projects_select on public.projects;
drop policy if exists projects_insert on public.projects;
drop policy if exists projects_update on public.projects;
drop policy if exists projects_delete on public.projects;
revoke all on table public.projects from anon, authenticated;

drop policy if exists project_files_select on public.project_files;
drop policy if exists project_files_insert on public.project_files;
drop policy if exists project_files_delete on public.project_files;
create policy project_files_select on public.project_files for select to authenticated
using (private.project_can_view(project_id) and private.project_has_permission('project_files_view'));
create policy project_files_insert on public.project_files for insert to authenticated
with check (private.project_can_view(project_id) and private.project_has_permission('project_files_upload') and uploaded_by=auth.uid());
create policy project_files_delete on public.project_files for delete to authenticated
using (private.project_can_view(project_id) and private.project_has_permission('project_files_delete'));

drop policy if exists project_activities_select on public.project_activities;
drop policy if exists project_activities_insert on public.project_activities;
create policy project_activities_select on public.project_activities for select to authenticated
using (private.project_can_view(project_id));
revoke insert,update,delete on table public.project_activities from anon, authenticated;

drop policy if exists project_costs_select on public.project_costs;
drop policy if exists project_costs_manage on public.project_costs;
create policy project_costs_select on public.project_costs for select to authenticated
using (private.project_can_view(project_id) and private.project_has_permission('project_financials_view'));
create policy project_costs_manage on public.project_costs for all to authenticated
using (private.project_can_manage(project_id,'project_financials_view'))
with check (private.project_can_manage(project_id,'project_financials_view'));

drop policy if exists project_milestones_select on public.project_milestones;
drop policy if exists project_members_select on public.project_members;
drop policy if exists project_realtime_signal_select on public.project_realtime_signal;
create policy project_milestones_select on public.project_milestones for select to authenticated using (private.project_can_view(project_id));
create policy project_members_select on public.project_members for select to authenticated using (private.project_can_view(project_id));
create policy project_realtime_signal_select on public.project_realtime_signal for select to authenticated
using (private.project_profile_active() and (public.current_identity_role() in ('owner','manager') or exists(
  select 1 from public.project_members pm where pm.active
    and (pm.start_date is null or pm.start_date <= current_date)
    and (pm.end_date is null or pm.end_date >= current_date)
    and (pm.profile_id=auth.uid() or exists(select 1 from public.profiles p where p.id=auth.uid() and p.employee_id=pm.employee_id))
)));
revoke all on table public.project_milestones from anon;
revoke all on table public.project_members from anon;
revoke all on table public.project_realtime_signal from anon;
grant select on table public.project_milestones to authenticated;
grant select on table public.project_members to authenticated;
grant select on table public.project_realtime_signal to authenticated;
revoke insert,update,delete on table public.project_milestones from authenticated;
revoke insert,update,delete on table public.project_members from authenticated;
revoke insert,update,delete on table public.project_realtime_signal from authenticated;

drop policy if exists project_files_storage_read on storage.objects;
drop policy if exists project_files_storage_insert on storage.objects;
drop policy if exists project_files_storage_delete on storage.objects;
create policy project_files_storage_read on storage.objects for select to authenticated using (
  bucket_id='project-files' and private.project_has_permission('project_files_view')
  and name ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/'
  and private.project_can_view(split_part(name,'/',1)::uuid)
);
create policy project_files_storage_insert on storage.objects for insert to authenticated with check (
  bucket_id='project-files' and private.project_has_permission('project_files_upload')
  and name ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/'
  and private.project_can_view(split_part(name,'/',1)::uuid)
);
create policy project_files_storage_delete on storage.objects for delete to authenticated using (
  bucket_id='project-files' and private.project_has_permission('project_files_delete')
  and name ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/'
  and private.project_can_view(split_part(name,'/',1)::uuid)
);

-- Audit the normalized tables with the existing immutable audit stream.
drop trigger if exists audit_changes on public.project_milestones;
create trigger audit_changes after insert or update or delete on public.project_milestones for each row execute function public.audit_row_change();
drop trigger if exists audit_changes on public.project_members;
create trigger audit_changes after insert or update or delete on public.project_members for each row execute function public.audit_row_change();

-- Intended RPC grants only.
revoke all on function public.get_projects_visible() from public, anon;
revoke all on function public.project_activation_readiness(uuid) from public, anon;
revoke all on function public.create_project_draft(jsonb) from public, anon;
revoke all on function public.update_project_details(uuid,jsonb) from public, anon;
revoke all on function public.transition_project_lifecycle(uuid,text,text) from public, anon;
revoke all on function public.update_project_execution_stage(uuid,text,text) from public, anon;
revoke all on function public.update_project_progress(uuid,text,numeric,text) from public, anon;
revoke all on function public.save_project_milestone(jsonb) from public, anon;
revoke all on function public.remove_project_milestone(uuid,text) from public, anon;
revoke all on function public.add_project_member(uuid,uuid,uuid,text,date,date) from public, anon;
revoke all on function public.update_project_member(uuid,text,boolean,date,date) from public, anon;
revoke all on function public.remove_project_member(uuid) from public, anon;
revoke all on function public.archive_or_cancel_project(uuid,text) from public, anon;
grant execute on function public.get_projects_visible() to authenticated;
grant execute on function public.project_activation_readiness(uuid) to authenticated;
grant execute on function public.create_project_draft(jsonb) to authenticated;
grant execute on function public.update_project_details(uuid,jsonb) to authenticated;
grant execute on function public.transition_project_lifecycle(uuid,text,text) to authenticated;
grant execute on function public.update_project_execution_stage(uuid,text,text) to authenticated;
grant execute on function public.update_project_progress(uuid,text,numeric,text) to authenticated;
grant execute on function public.save_project_milestone(jsonb) to authenticated;
grant execute on function public.remove_project_milestone(uuid,text) to authenticated;
grant execute on function public.add_project_member(uuid,uuid,uuid,text,date,date) to authenticated;
grant execute on function public.update_project_member(uuid,text,boolean,date,date) to authenticated;
grant execute on function public.remove_project_member(uuid) to authenticated;
grant execute on function public.archive_or_cancel_project(uuid,text) to authenticated;

-- Trigger-only and internal helpers must not be PostgREST RPCs.
revoke execute on function public.project_calculated_progress(uuid) from public,anon,authenticated;
revoke execute on function public.validate_project_milestone_weight() from public,anon,authenticated;
revoke execute on function public.refresh_project_progress_from_milestones() from public,anon,authenticated;
revoke execute on function public.validate_project_member_identity() from public,anon,authenticated;
revoke execute on function public.protect_project_workspace_fields() from public,anon,authenticated;
revoke execute on function public.emit_project_realtime_signal() from public,anon,authenticated;
revoke execute on function public.log_project_file_deleted() from public,anon,authenticated;
revoke execute on function public.log_project_file_uploaded() from public,anon,authenticated;
revoke execute on function public.refresh_project_actual_cost(uuid) from public,anon,authenticated;
revoke execute on function public.sync_project_cost() from public,anon,authenticated;
revoke execute on function public.protect_project_fields() from public,anon,authenticated;
revoke execute on function public.log_project_activity() from public,anon,authenticated;

-- Realtime publication additions are idempotent and preserve the centralized client channel.
do $$ declare table_name text; begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    foreach table_name in array array['project_milestones','project_members','project_realtime_signal'] loop
      if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=table_name) then
        execute format('alter publication supabase_realtime add table public.%I',table_name);
      end if;
    end loop;
  end if;
end $$;

comment on column public.projects.status is 'Legacy compatibility alias synchronized with execution_stage.';
comment on column public.projects.legacy_activation_exempt is 'True only for pre-Workspace projects so future budget readiness cannot retroactively block them.';
comment on function public.project_activation_readiness(uuid) is 'Extensible activation checks. Estimated Budget approval is explicitly not implemented and non-blocking in this sprint.';
