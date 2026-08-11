-- Project Estimated Budget, activation gate, and future Actual Cost source contracts.
-- Safe after 202607190001 and 202607190002. No existing Project Workspace
-- object or record is rebuilt or deleted.

begin;

do $$
begin
  if to_regclass('public.projects') is null
    or to_regclass('public.project_milestones') is null
    or to_regclass('public.project_members') is null
    or to_regclass('public.project_files') is null
    or to_regclass('public.project_activities') is null
    or to_regclass('public.project_costs') is null
    or to_regclass('public.project_realtime_signal') is null then
    raise exception 'Estimated Budget requires the merged PR #13 Project Workspace tables';
  end if;
  if to_regprocedure('private.project_can_view(uuid)') is null
    or to_regprocedure('private.project_has_permission(text)') is null
    or to_regprocedure('public.transition_project_lifecycle(uuid,text,text)') is null
    or to_regprocedure('public.audit_row_change()') is null
    or to_regprocedure('public.emit_project_realtime_signal()') is null then
    raise exception 'Estimated Budget requires the merged PR #13 authorization, audit, lifecycle, and Realtime functions';
  end if;
end
$$;

alter table public.projects add column if not exists budget_activation_override_reason text;
alter table public.projects add column if not exists budget_activation_override_by uuid references public.profiles(id) on delete set null;
alter table public.projects add column if not exists budget_activation_override_at timestamptz;

create table if not exists public.project_budget_versions (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  version_number integer not null check (version_number > 0),
  status text not null default 'draft' check (status in ('draft','submitted','approved','rejected','superseded','cancelled')),
  currency text not null default 'SAR' check (currency ~ '^[A-Z]{3}$'),
  subtotal numeric(18,2) not null default 0 check (subtotal >= 0),
  contingency_mode text not null default 'none' check (contingency_mode in ('none','fixed','percentage')),
  contingency_amount numeric(18,2) not null default 0 check (contingency_amount >= 0),
  contingency_percentage numeric(7,4) not null default 0 check (contingency_percentage between 0 and 100),
  overhead_mode text not null default 'none' check (overhead_mode in ('none','fixed','percentage')),
  overhead_amount numeric(18,2) not null default 0 check (overhead_amount >= 0),
  overhead_percentage numeric(7,4) not null default 0 check (overhead_percentage between 0 and 100),
  expected_total_cost numeric(18,2) not null default 0 check (expected_total_cost >= 0),
  target_profit_mode text not null default 'none' check (target_profit_mode in ('none','fixed','percentage')),
  target_profit_amount numeric(18,2) not null default 0 check (target_profit_amount >= 0),
  target_profit_percentage numeric(7,4) not null default 0 check (target_profit_percentage between 0 and 1000),
  target_sale_price numeric(18,2) not null default 0 check (target_sale_price >= 0),
  notes text,
  rejection_reason text,
  submitted_by uuid references public.profiles(id) on delete set null,
  submitted_at timestamptz,
  approved_by uuid references public.profiles(id) on delete set null,
  approved_at timestamptz,
  rejected_by uuid references public.profiles(id) on delete set null,
  rejected_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  updated_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(project_id, version_number),
  check ((contingency_mode = 'fixed' and contingency_percentage = 0)
    or (contingency_mode = 'percentage' and contingency_amount >= 0)
    or (contingency_mode = 'none' and contingency_amount = 0 and contingency_percentage = 0)),
  check ((overhead_mode = 'fixed' and overhead_percentage = 0)
    or (overhead_mode = 'percentage' and overhead_amount >= 0)
    or (overhead_mode = 'none' and overhead_amount = 0 and overhead_percentage = 0)),
  check ((target_profit_mode = 'fixed' and target_profit_percentage = 0)
    or (target_profit_mode = 'percentage' and target_profit_amount >= 0)
    or (target_profit_mode = 'none' and target_profit_amount = 0 and target_profit_percentage = 0))
);

create table if not exists public.project_budget_sections (
  id uuid primary key default gen_random_uuid(),
  budget_version_id uuid not null references public.project_budget_versions(id) on delete cascade,
  section_key text not null,
  section_name text not null,
  sequence integer not null default 0 check (sequence >= 0),
  subtotal numeric(18,2) not null default 0 check (subtotal >= 0),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(budget_version_id, section_key),
  unique(id, budget_version_id)
);

create table if not exists public.project_budget_items (
  id uuid primary key default gen_random_uuid(),
  budget_version_id uuid not null references public.project_budget_versions(id) on delete cascade,
  section_id uuid not null,
  category text not null check (category in (
    'wood','mdf','plywood','hpl','acrylic','glass','metal','paint','electrical_materials','accessories','consumables','other_materials',
    'carpentry','cnc','laser_cutting','painting','welding','printing','electrical_work','assembly','installation','subcontractor','other_production',
    'transportation','delivery','loading','unloading','accommodation','travel','permits','site_expenses',
    'factory_employees','daily_labor','overtime','technicians','site_labor','temporary_labor',
    'rented_equipment','approved_asset_usage_cost','fuel','operation','depreciation_allocation','maintenance_allocation',
    'direct_expenses','insurance','contingency','overhead','other'
  )),
  item_code text,
  description text not null,
  quantity numeric(18,4) not null default 1 check (quantity >= 0),
  unit text not null default 'وحدة',
  unit_cost numeric(18,4) not null default 0 check (unit_cost >= 0),
  estimated_cost numeric(18,2) generated always as (round(quantity * unit_cost, 2)) stored,
  waste_percentage numeric(7,4) not null default 0 check (waste_percentage between 0 and 100),
  waste_amount numeric(18,2) generated always as (round(round(quantity * unit_cost, 2) * waste_percentage / 100, 2)) stored,
  total_with_waste numeric(18,2) generated always as (round(round(quantity * unit_cost, 2) + round(round(quantity * unit_cost, 2) * waste_percentage / 100, 2), 2)) stored,
  supplier_id uuid references public.suppliers(id) on delete set null,
  responsible_department_id uuid references public.departments(id) on delete set null,
  milestone_id uuid references public.project_milestones(id) on delete set null,
  source_reference_type text,
  source_reference_id uuid,
  cost_center_reference text,
  purchase_request_reference text,
  notes text,
  sequence integer not null default 0 check (sequence >= 0),
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  updated_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key(section_id, budget_version_id) references public.project_budget_sections(id, budget_version_id) on delete cascade
);

create table if not exists public.project_budget_templates (
  id uuid primary key default gen_random_uuid(),
  template_key text,
  template_name text not null,
  template_type text not null default 'custom' check (template_type in ('factory_booth','kiosk','exhibition_stand','office_decoration','custom')),
  currency text not null default 'SAR' check (currency ~ '^[A-Z]{3}$'),
  notes text,
  active boolean not null default true,
  created_from_budget_version_id uuid references public.project_budget_versions(id) on delete set null,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  updated_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.project_budget_template_sections (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.project_budget_templates(id) on delete cascade,
  section_key text not null,
  section_name text not null,
  sequence integer not null default 0 check (sequence >= 0),
  notes text,
  unique(template_id, section_key),
  unique(id, template_id)
);

create table if not exists public.project_budget_template_items (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.project_budget_templates(id) on delete cascade,
  template_section_id uuid not null,
  category text not null,
  item_code text,
  description text not null,
  quantity numeric(18,4) not null default 1 check (quantity >= 0),
  unit text not null default 'وحدة',
  unit_cost numeric(18,4) not null default 0 check (unit_cost >= 0),
  waste_percentage numeric(7,4) not null default 0 check (waste_percentage between 0 and 100),
  notes text,
  sequence integer not null default 0 check (sequence >= 0),
  foreign key(template_section_id, template_id) references public.project_budget_template_sections(id, template_id) on delete cascade
);

-- Registry only: these are contracts for future Actual Cost producers, not a
-- Cash Custody, Purchasing, Payroll allocation, Petty Cash, or GL engine.
create table if not exists public.project_cost_source_contracts (
  source_type text primary key,
  posting_event text not null,
  required_state text not null,
  allowed_links text[] not null default array['project']::text[],
  double_count_group text not null,
  description text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.project_cost_source_contracts(source_type,posting_event,required_state,allowed_links,double_count_group,description)
values
  ('expense','approved_expense','approved',array['project','milestone','cost_center','estimated_budget_item'],'operating_cash_outflow','Post once from the approved expense source.'),
  ('purchase_consumption','approved_project_consumption','approved',array['project','milestone','cost_center','purchase_request','estimated_budget_item'],'procure_to_cost','Purchase alone is not cost when later inventory consumption is posted.'),
  ('petty_cash_settlement_line','approved_settlement_line','approved',array['project','milestone','cost_center','estimated_budget_item'],'operating_cash_outflow','Only an approved petty cash settlement line may post.'),
  ('supplier_invoice_line','approved_invoice_line','approved',array['project','milestone','cost_center','purchase_request','estimated_budget_item'],'procure_to_cost','Supplier invoice and purchase consumption must share a canonical deduplication key.'),
  ('employee_cash_custody_settlement_line','approved_settlement_line','approved',array['project','milestone','cost_center','purchase_request','estimated_budget_item'],'operating_cash_outflow','Cash advance is a receivable. Only approved settlement lines post Actual Cost; returned cash and unsettled balances never post.'),
  ('asset_usage','approved_usage_allocation','approved',array['project','milestone','cost_center','estimated_budget_item'],'asset_usage','Custody assignment is not cost; only approved usage, rental, fuel, depreciation, operation, or maintenance allocation posts.'),
  ('factory_labor_allocation','approved_payroll_allocation','approved',array['project','milestone','cost_center','estimated_budget_item'],'labor_allocation','Post one approved allocation revision, never payroll and allocation twice.')
on conflict(source_type) do update set
  posting_event=excluded.posting_event,required_state=excluded.required_state,allowed_links=excluded.allowed_links,
  double_count_group=excluded.double_count_group,description=excluded.description;

alter table public.project_costs add column if not exists source_type text;
alter table public.project_costs add column if not exists source_id uuid;
alter table public.project_costs add column if not exists source_line_reference text;
alter table public.project_costs add column if not exists allocation_revision integer;
alter table public.project_costs add column if not exists source_reference_key text;
alter table public.project_costs add column if not exists source_state text;
alter table public.project_costs add column if not exists source_metadata jsonb;
alter table public.project_costs add column if not exists project_milestone_id uuid references public.project_milestones(id) on delete set null;
alter table public.project_costs add column if not exists estimated_budget_item_id uuid references public.project_budget_items(id) on delete set null;
alter table public.project_costs add column if not exists cost_center_reference text;
alter table public.project_costs add column if not exists purchase_request_reference text;

update public.project_costs set
  source_type=coalesce(source_type,'legacy'),
  source_id=coalesce(source_id,reference_id,id),
  source_line_reference=coalesce(source_line_reference,'main'),
  allocation_revision=coalesce(allocation_revision,1),
  source_reference_key=coalesce(source_reference_key,'legacy:project_costs:'||id::text),
  source_state=coalesce(source_state,'legacy_import'),
  source_metadata=coalesce(source_metadata,'{}'::jsonb)
where source_type is null or source_id is null or source_reference_key is null or allocation_revision is null;

alter table public.project_costs alter column source_type set not null;
alter table public.project_costs alter column source_id set not null;
alter table public.project_costs alter column source_line_reference set default 'main';
alter table public.project_costs alter column source_line_reference set not null;
alter table public.project_costs alter column allocation_revision set default 1;
alter table public.project_costs alter column allocation_revision set not null;
alter table public.project_costs alter column source_reference_key set not null;
alter table public.project_costs alter column source_metadata set default '{}'::jsonb;
alter table public.project_costs alter column source_metadata set not null;

create unique index if not exists project_budget_one_active_approved_idx on public.project_budget_versions(project_id) where status='approved';
create index if not exists project_budget_versions_project_status_idx on public.project_budget_versions(project_id,status,version_number desc);
create index if not exists project_budget_versions_approval_idx on public.project_budget_versions(project_id,approved_at desc) where approved_at is not null;
create index if not exists project_budget_versions_created_by_idx on public.project_budget_versions(created_by) where created_by is not null;
create index if not exists project_budget_versions_updated_by_idx on public.project_budget_versions(updated_by) where updated_by is not null;
create index if not exists project_budget_versions_submitted_by_idx on public.project_budget_versions(submitted_by) where submitted_by is not null;
create index if not exists project_budget_versions_approved_by_idx on public.project_budget_versions(approved_by) where approved_by is not null;
create index if not exists project_budget_versions_rejected_by_idx on public.project_budget_versions(rejected_by) where rejected_by is not null;
create index if not exists project_budget_sections_order_idx on public.project_budget_sections(budget_version_id,sequence,id);
create index if not exists project_budget_items_order_idx on public.project_budget_items(budget_version_id,section_id,sequence,id);
create index if not exists project_budget_items_section_fk_idx on public.project_budget_items(section_id,budget_version_id);
create index if not exists project_budget_items_category_idx on public.project_budget_items(budget_version_id,category);
create index if not exists project_budget_items_supplier_idx on public.project_budget_items(supplier_id) where supplier_id is not null;
create index if not exists project_budget_items_department_idx on public.project_budget_items(responsible_department_id) where responsible_department_id is not null;
create index if not exists project_budget_items_milestone_idx on public.project_budget_items(milestone_id) where milestone_id is not null;
create index if not exists project_budget_items_created_by_idx on public.project_budget_items(created_by) where created_by is not null;
create index if not exists project_budget_items_updated_by_idx on public.project_budget_items(updated_by) where updated_by is not null;
create index if not exists project_budget_templates_lookup_idx on public.project_budget_templates(active,template_type,template_name);
create index if not exists project_budget_templates_source_idx on public.project_budget_templates(created_from_budget_version_id) where created_from_budget_version_id is not null;
create index if not exists project_budget_templates_created_by_idx on public.project_budget_templates(created_by) where created_by is not null;
create index if not exists project_budget_templates_updated_by_idx on public.project_budget_templates(updated_by) where updated_by is not null;
create index if not exists project_budget_template_sections_order_idx on public.project_budget_template_sections(template_id,sequence,id);
create index if not exists project_budget_template_items_order_idx on public.project_budget_template_items(template_id,template_section_id,sequence,id);
create index if not exists project_budget_template_items_section_fk_idx on public.project_budget_template_items(template_section_id,template_id);
create unique index if not exists project_costs_source_revision_unique on public.project_costs(source_type,source_id,source_line_reference,allocation_revision);
create unique index if not exists project_costs_source_reference_key_unique on public.project_costs(source_reference_key);
create index if not exists project_costs_budget_item_idx on public.project_costs(estimated_budget_item_id) where estimated_budget_item_id is not null;
create index if not exists project_costs_milestone_idx on public.project_costs(project_milestone_id) where project_milestone_id is not null;
create index if not exists projects_budget_override_by_idx on public.projects(budget_activation_override_by) where budget_activation_override_by is not null;

create or replace function private.project_budget_has_permission(permission_name text)
returns boolean
language sql stable security definer
set search_path = public, private, pg_temp
as $$
  with identity as (
    select role,coalesce(permissions,'{}'::jsonb) permissions
    from public.profiles where id=auth.uid() and status='active'
  )
  select coalesce(case role
    when 'owner' then true
    when 'manager' then permission_name=any(array[
      'project_budget_view','project_budget_create','project_budget_edit','project_budget_submit','project_budget_view_financials','project_budget_manage_templates'
    ]) or (
      permission_name=any(array['project_budget_approve','project_budget_reject'])
      and coalesce((permissions->>permission_name)::boolean,false)
    )
    when 'accountant' then coalesce((permissions->>permission_name)::boolean,false) or permission_name=any(array[
      'project_budget_view','project_budget_create','project_budget_edit','project_budget_submit','project_budget_reject','project_budget_view_financials'
    ])
    when 'production' then coalesce((permissions->>permission_name)::boolean,false)
      and permission_name=any(array['project_budget_view','project_budget_view_financials'])
    else false end,false)
  from identity
$$;

create or replace function private.project_budget_can(target_project uuid, permission_name text)
returns boolean
language sql stable security definer
set search_path = public, private, pg_temp
as $$
  select private.project_can_view(target_project) and private.project_budget_has_permission(permission_name)
$$;

create or replace function private.recalculate_project_budget(target_version uuid)
returns void
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare v public.project_budget_versions%rowtype; section_total numeric(18,2); contingency numeric(18,2); overhead numeric(18,2); profit numeric(18,2);
begin
  perform set_config('app.project_budget_rpc','on',true);
  update public.project_budget_sections s set subtotal=coalesce((select round(sum(i.total_with_waste),2) from public.project_budget_items i where i.section_id=s.id),0),updated_at=now()
  where s.budget_version_id=target_version;
  select * into v from public.project_budget_versions where id=target_version for update;
  if not found then return; end if;
  select coalesce(round(sum(subtotal),2),0) into section_total from public.project_budget_sections where budget_version_id=target_version;
  contingency:=case v.contingency_mode when 'fixed' then v.contingency_amount when 'percentage' then round(section_total*v.contingency_percentage/100,2) else 0 end;
  overhead:=case v.overhead_mode when 'fixed' then v.overhead_amount when 'percentage' then round(section_total*v.overhead_percentage/100,2) else 0 end;
  profit:=case v.target_profit_mode when 'fixed' then v.target_profit_amount when 'percentage' then round((section_total+contingency+overhead)*v.target_profit_percentage/100,2) else 0 end;
  update public.project_budget_versions set subtotal=section_total,contingency_amount=contingency,overhead_amount=overhead,
    expected_total_cost=round(section_total+contingency+overhead,2),target_profit_amount=profit,
    target_sale_price=round(section_total+contingency+overhead+profit,2),updated_at=now()
  where id=target_version;
end
$$;

create or replace function private.recalculate_project_budget_trigger()
returns trigger
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
begin
  perform private.recalculate_project_budget(coalesce(new.budget_version_id,old.budget_version_id));
  return coalesce(new,old);
end
$$;

create or replace function private.protect_project_budget_history()
returns trigger
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare version_status text; version_id uuid;
begin
  if current_setting('app.project_budget_rpc',true) is distinct from 'on' then
    raise exception 'Project Budget writes must use protected RPCs';
  end if;
  if tg_table_name='project_budget_versions' then
    if tg_op='DELETE' and old.status<>'draft' then raise exception 'Only draft budget versions may be deleted'; end if;
    if tg_op='UPDATE' and old.status='approved' and new.status<>'superseded' then raise exception 'Approved budgets are immutable'; end if;
    if tg_op='UPDATE' and old.status in ('rejected','superseded','cancelled') then raise exception 'Historical budget versions are immutable'; end if;
    return coalesce(new,old);
  end if;
  version_id:=coalesce(new.budget_version_id,old.budget_version_id);
  select status into version_status from public.project_budget_versions where id=version_id;
  if version_status<>'draft' then raise exception 'Only draft budget contents may be edited'; end if;
  return coalesce(new,old);
end
$$;

create or replace function private.validate_project_cost_source()
returns trigger
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare contract public.project_cost_source_contracts%rowtype;
begin
  if btrim(coalesce(new.source_reference_key,''))='' or new.source_id is null or btrim(coalesce(new.source_type,''))='' then
    raise exception 'Every Actual Cost posting requires a unique source reference';
  end if;
  if new.allocation_revision<1 then raise exception 'Actual Cost allocation revision must be positive'; end if;
  if new.source_type='employee_cash_custody' then raise exception 'Cash custody advance is a receivable, not Actual Cost'; end if;
  if new.source_type<>'legacy' then
    select * into contract from public.project_cost_source_contracts where source_type=new.source_type and active;
    if not found then raise exception 'Unknown or inactive Actual Cost source contract: %',new.source_type; end if;
    if coalesce(new.source_state,'')<>contract.required_state then raise exception 'Actual Cost source state must be %',contract.required_state; end if;
  end if;
  return new;
end
$$;

drop trigger if exists protect_project_budget_version on public.project_budget_versions;
create trigger protect_project_budget_version before update or delete on public.project_budget_versions for each row execute function private.protect_project_budget_history();
drop trigger if exists protect_project_budget_sections on public.project_budget_sections;
create trigger protect_project_budget_sections before insert or update or delete on public.project_budget_sections for each row execute function private.protect_project_budget_history();
drop trigger if exists protect_project_budget_items on public.project_budget_items;
create trigger protect_project_budget_items before insert or update or delete on public.project_budget_items for each row execute function private.protect_project_budget_history();
drop trigger if exists recalculate_project_budget_items on public.project_budget_items;
create trigger recalculate_project_budget_items after insert or update or delete on public.project_budget_items for each row execute function private.recalculate_project_budget_trigger();
drop trigger if exists validate_project_cost_source on public.project_costs;
create trigger validate_project_cost_source before insert or update of source_type,source_id,source_line_reference,allocation_revision,source_reference_key,source_state on public.project_costs for each row execute function private.validate_project_cost_source();

do $$ declare table_name text; begin
  foreach table_name in array array['project_budget_versions','project_budget_sections','project_budget_items','project_budget_templates'] loop
    execute format('drop trigger if exists set_updated_at on public.%I',table_name);
    execute format('create trigger set_updated_at before update on public.%I for each row execute function public.set_updated_at()',table_name);
    execute format('drop trigger if exists audit_changes on public.%I',table_name);
    execute format('create trigger audit_changes after insert or update or delete on public.%I for each row execute function public.audit_row_change()',table_name);
  end loop;
end $$;

create or replace function private.project_budget_activity(target_project uuid,action_name text,description_text text,details jsonb default '{}'::jsonb)
returns void
language sql security definer
set search_path = public, private, pg_temp
as $$
  insert into public.project_activities(project_id,actor_id,action_type,description,metadata)
  values(target_project,auth.uid(),action_name,description_text,coalesce(details,'{}'::jsonb))
$$;

create or replace function public.create_project_budget_draft(target_project uuid,currency_code text default 'SAR')
returns jsonb
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare actor uuid:=auth.uid(); next_version integer; created public.project_budget_versions%rowtype;
begin
  if actor is null or not private.project_budget_can(target_project,'project_budget_create') then raise exception 'project_budget_create permission required'; end if;
  perform 1 from public.projects where id=target_project for update;
  if not found then raise exception 'Project not found'; end if;
  select coalesce(max(version_number),0)+1 into next_version from public.project_budget_versions where project_id=target_project;
  perform set_config('app.project_budget_rpc','on',true);
  insert into public.project_budget_versions(project_id,version_number,currency,created_by,updated_by)
  values(target_project,next_version,upper(coalesce(nullif(btrim(currency_code),''),'SAR')),actor,actor) returning * into created;
  insert into public.project_budget_sections(budget_version_id,section_key,section_name,sequence)
  values(created.id,'general','عام',0);
  perform private.project_budget_activity(target_project,'budget_created','تم إنشاء مسودة ميزانية تقديرية',jsonb_build_object('budget_version_id',created.id,'version_number',created.version_number));
  return to_jsonb(created);
end
$$;

create or replace function public.copy_project_budget_version(source_version uuid)
returns jsonb
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare actor uuid:=auth.uid(); source public.project_budget_versions%rowtype; created public.project_budget_versions%rowtype; section_row record; new_section uuid; next_version integer;
begin
  select * into source from public.project_budget_versions where id=source_version;
  if not found then raise exception 'Budget version not found'; end if;
  if actor is null or not private.project_budget_can(source.project_id,'project_budget_create') then raise exception 'project_budget_create permission required'; end if;
  perform 1 from public.projects where id=source.project_id for update;
  select coalesce(max(version_number),0)+1 into next_version from public.project_budget_versions where project_id=source.project_id;
  perform set_config('app.project_budget_rpc','on',true);
  insert into public.project_budget_versions(project_id,version_number,currency,contingency_mode,contingency_amount,contingency_percentage,overhead_mode,overhead_amount,overhead_percentage,target_profit_mode,target_profit_amount,target_profit_percentage,notes,created_by,updated_by)
  values(source.project_id,next_version,source.currency,source.contingency_mode,source.contingency_amount,source.contingency_percentage,source.overhead_mode,source.overhead_amount,source.overhead_percentage,source.target_profit_mode,source.target_profit_amount,source.target_profit_percentage,source.notes,actor,actor)
  returning * into created;
  for section_row in select * from public.project_budget_sections where budget_version_id=source.id order by sequence,id loop
    insert into public.project_budget_sections(budget_version_id,section_key,section_name,sequence,notes)
    values(created.id,section_row.section_key,section_row.section_name,section_row.sequence,section_row.notes) returning id into new_section;
    insert into public.project_budget_items(budget_version_id,section_id,category,item_code,description,quantity,unit,unit_cost,waste_percentage,supplier_id,responsible_department_id,milestone_id,source_reference_type,source_reference_id,cost_center_reference,purchase_request_reference,notes,sequence,created_by,updated_by)
    select created.id,new_section,category,item_code,description,quantity,unit,unit_cost,waste_percentage,supplier_id,responsible_department_id,milestone_id,source_reference_type,source_reference_id,cost_center_reference,purchase_request_reference,notes,sequence,actor,actor
    from public.project_budget_items where budget_version_id=source.id and section_id=section_row.id order by sequence,id;
  end loop;
  perform private.recalculate_project_budget(created.id);
  perform private.project_budget_activity(source.project_id,'budget_copied','تم نسخ نسخة الميزانية إلى مسودة جديدة',jsonb_build_object('source_version_id',source.id,'budget_version_id',created.id,'version_number',created.version_number));
  select * into created from public.project_budget_versions where id=created.id;
  return to_jsonb(created);
end
$$;

create or replace function public.update_project_budget_header(target_version uuid,payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare actor uuid:=auth.uid(); v public.project_budget_versions%rowtype;
begin
  select * into v from public.project_budget_versions where id=target_version for update;
  if not found then raise exception 'Budget version not found'; end if;
  if actor is null or not private.project_budget_can(v.project_id,'project_budget_edit') then raise exception 'project_budget_edit permission required'; end if;
  if v.status<>'draft' then raise exception 'Only draft budget headers may be edited'; end if;
  if coalesce(nullif(payload->>'contingency_percentage','')::numeric,v.contingency_percentage) not between 0 and 100
    or coalesce(nullif(payload->>'overhead_percentage','')::numeric,v.overhead_percentage) not between 0 and 100
    or coalesce(nullif(payload->>'target_profit_percentage','')::numeric,v.target_profit_percentage) not between 0 and 1000 then
    raise exception 'Invalid budget percentage';
  end if;
  perform set_config('app.project_budget_rpc','on',true);
  update public.project_budget_versions set
    currency=case when payload ? 'currency' then upper(btrim(payload->>'currency')) else currency end,
    contingency_mode=coalesce(nullif(payload->>'contingency_mode',''),contingency_mode),
    contingency_amount=case when coalesce(nullif(payload->>'contingency_mode',''),contingency_mode)='fixed' then coalesce(nullif(payload->>'contingency_amount','')::numeric,0) else 0 end,
    contingency_percentage=case when coalesce(nullif(payload->>'contingency_mode',''),contingency_mode)='percentage' then coalesce(nullif(payload->>'contingency_percentage','')::numeric,0) else 0 end,
    overhead_mode=coalesce(nullif(payload->>'overhead_mode',''),overhead_mode),
    overhead_amount=case when coalesce(nullif(payload->>'overhead_mode',''),overhead_mode)='fixed' then coalesce(nullif(payload->>'overhead_amount','')::numeric,0) else 0 end,
    overhead_percentage=case when coalesce(nullif(payload->>'overhead_mode',''),overhead_mode)='percentage' then coalesce(nullif(payload->>'overhead_percentage','')::numeric,0) else 0 end,
    target_profit_mode=coalesce(nullif(payload->>'target_profit_mode',''),target_profit_mode),
    target_profit_amount=case when coalesce(nullif(payload->>'target_profit_mode',''),target_profit_mode)='fixed' then coalesce(nullif(payload->>'target_profit_amount','')::numeric,0) else 0 end,
    target_profit_percentage=case when coalesce(nullif(payload->>'target_profit_mode',''),target_profit_mode)='percentage' then coalesce(nullif(payload->>'target_profit_percentage','')::numeric,0) else 0 end,
    notes=case when payload ? 'notes' then nullif(btrim(payload->>'notes'),'') else notes end,
    updated_by=actor where id=target_version;
  perform private.recalculate_project_budget(target_version);
  perform private.project_budget_activity(v.project_id,'budget_header_edited','تم تحديث ملخص الميزانية',jsonb_build_object('budget_version_id',target_version));
  return (select to_jsonb(x) from public.project_budget_versions x where x.id=target_version);
end
$$;

create or replace function public.save_project_budget_section(payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare actor uuid:=auth.uid(); v public.project_budget_versions%rowtype; saved public.project_budget_sections%rowtype; section_id uuid:=nullif(payload->>'id','')::uuid;
begin
  select * into v from public.project_budget_versions where id=(payload->>'budget_version_id')::uuid for update;
  if not found then raise exception 'Budget version not found'; end if;
  if actor is null or not private.project_budget_can(v.project_id,'project_budget_edit') then raise exception 'project_budget_edit permission required'; end if;
  if v.status<>'draft' then raise exception 'Only draft budget sections may be edited'; end if;
  if btrim(coalesce(payload->>'section_key',''))='' or btrim(coalesce(payload->>'section_name',''))='' then raise exception 'Section key and name are required'; end if;
  perform set_config('app.project_budget_rpc','on',true);
  if section_id is null then
    insert into public.project_budget_sections(budget_version_id,section_key,section_name,sequence,notes)
    values(v.id,btrim(payload->>'section_key'),btrim(payload->>'section_name'),coalesce(nullif(payload->>'sequence','')::integer,0),nullif(btrim(payload->>'notes'),'')) returning * into saved;
  else
    update public.project_budget_sections set section_key=btrim(payload->>'section_key'),section_name=btrim(payload->>'section_name'),sequence=coalesce(nullif(payload->>'sequence','')::integer,sequence),notes=nullif(btrim(payload->>'notes'),'')
    where id=section_id and budget_version_id=v.id returning * into saved;
    if not found then raise exception 'Budget section not found'; end if;
  end if;
  perform private.project_budget_activity(v.project_id,'budget_section_saved','تم حفظ قسم في الميزانية',jsonb_build_object('budget_version_id',v.id,'section_id',saved.id));
  return to_jsonb(saved);
end
$$;

create or replace function public.reorder_project_budget_sections(target_version uuid,ordered_sections jsonb)
returns boolean
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare actor uuid:=auth.uid(); v public.project_budget_versions%rowtype; entry jsonb;
begin
  select * into v from public.project_budget_versions where id=target_version for update;
  if not found then raise exception 'Budget version not found'; end if;
  if actor is null or not private.project_budget_can(v.project_id,'project_budget_edit') then raise exception 'project_budget_edit permission required'; end if;
  if v.status<>'draft' then raise exception 'Only draft sections may be reordered'; end if;
  perform set_config('app.project_budget_rpc','on',true);
  for entry in select value from jsonb_array_elements(coalesce(ordered_sections,'[]'::jsonb)) loop
    update public.project_budget_sections set sequence=(entry->>'sequence')::integer where id=(entry->>'id')::uuid and budget_version_id=target_version;
  end loop;
  perform private.project_budget_activity(v.project_id,'budget_sections_reordered','تم تغيير ترتيب أقسام الميزانية',jsonb_build_object('budget_version_id',target_version));
  return true;
end
$$;

create or replace function public.save_project_budget_item(payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare actor uuid:=auth.uid(); v public.project_budget_versions%rowtype; saved public.project_budget_items%rowtype; item_id uuid:=nullif(payload->>'id','')::uuid; target_milestone uuid:=nullif(payload->>'milestone_id','')::uuid;
begin
  select * into v from public.project_budget_versions where id=(payload->>'budget_version_id')::uuid for update;
  if not found then raise exception 'Budget version not found'; end if;
  if actor is null or not private.project_budget_can(v.project_id,'project_budget_edit') then raise exception 'project_budget_edit permission required'; end if;
  if v.status<>'draft' then raise exception 'Only draft budget items may be edited'; end if;
  if btrim(coalesce(payload->>'description',''))='' then raise exception 'Budget item description is required'; end if;
  if coalesce(nullif(payload->>'quantity','')::numeric,0)<0 or coalesce(nullif(payload->>'unit_cost','')::numeric,0)<0 or coalesce(nullif(payload->>'waste_percentage','')::numeric,0) not between 0 and 100 then raise exception 'Invalid budget item values'; end if;
  if payload->>'source_reference_type' in ('asset_custody','employee_cash_custody') then raise exception 'Asset or cash custody itself is not an estimated cost'; end if;
  if target_milestone is not null and not exists(select 1 from public.project_milestones where id=target_milestone and project_id=v.project_id) then raise exception 'Milestone does not belong to project'; end if;
  perform set_config('app.project_budget_rpc','on',true);
  if item_id is null then
    insert into public.project_budget_items(budget_version_id,section_id,category,item_code,description,quantity,unit,unit_cost,waste_percentage,supplier_id,responsible_department_id,milestone_id,source_reference_type,source_reference_id,cost_center_reference,purchase_request_reference,notes,sequence,created_by,updated_by)
    values(v.id,(payload->>'section_id')::uuid,payload->>'category',nullif(btrim(payload->>'item_code'),''),btrim(payload->>'description'),coalesce(nullif(payload->>'quantity','')::numeric,0),coalesce(nullif(btrim(payload->>'unit'),''),'وحدة'),coalesce(nullif(payload->>'unit_cost','')::numeric,0),coalesce(nullif(payload->>'waste_percentage','')::numeric,0),nullif(payload->>'supplier_id','')::uuid,nullif(payload->>'responsible_department_id','')::uuid,target_milestone,nullif(btrim(payload->>'source_reference_type'),''),nullif(payload->>'source_reference_id','')::uuid,nullif(btrim(payload->>'cost_center_reference'),''),nullif(btrim(payload->>'purchase_request_reference'),''),nullif(btrim(payload->>'notes'),''),coalesce(nullif(payload->>'sequence','')::integer,0),actor,actor) returning * into saved;
    perform private.project_budget_activity(v.project_id,'budget_item_added','تمت إضافة بند ميزانية',jsonb_build_object('budget_version_id',v.id,'budget_item_id',saved.id,'new_value',to_jsonb(saved)));
  else
    update public.project_budget_items set section_id=(payload->>'section_id')::uuid,category=payload->>'category',item_code=nullif(btrim(payload->>'item_code'),''),description=btrim(payload->>'description'),quantity=coalesce(nullif(payload->>'quantity','')::numeric,quantity),unit=coalesce(nullif(btrim(payload->>'unit'),''),unit),unit_cost=coalesce(nullif(payload->>'unit_cost','')::numeric,unit_cost),waste_percentage=coalesce(nullif(payload->>'waste_percentage','')::numeric,waste_percentage),supplier_id=nullif(payload->>'supplier_id','')::uuid,responsible_department_id=nullif(payload->>'responsible_department_id','')::uuid,milestone_id=target_milestone,source_reference_type=nullif(btrim(payload->>'source_reference_type'),''),source_reference_id=nullif(payload->>'source_reference_id','')::uuid,cost_center_reference=nullif(btrim(payload->>'cost_center_reference'),''),purchase_request_reference=nullif(btrim(payload->>'purchase_request_reference'),''),notes=nullif(btrim(payload->>'notes'),''),sequence=coalesce(nullif(payload->>'sequence','')::integer,sequence),updated_by=actor where id=item_id and budget_version_id=v.id returning * into saved;
    if not found then raise exception 'Budget item not found'; end if;
    perform private.project_budget_activity(v.project_id,'budget_item_edited','تم تعديل بند ميزانية',jsonb_build_object('budget_version_id',v.id,'budget_item_id',saved.id,'new_value',to_jsonb(saved)));
  end if;
  return to_jsonb(saved);
end
$$;

create or replace function public.reorder_project_budget_items(target_version uuid,ordered_items jsonb)
returns boolean
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare actor uuid:=auth.uid(); v public.project_budget_versions%rowtype; entry jsonb;
begin
  select * into v from public.project_budget_versions where id=target_version for update;
  if not found then raise exception 'Budget version not found'; end if;
  if actor is null or not private.project_budget_can(v.project_id,'project_budget_edit') then raise exception 'project_budget_edit permission required'; end if;
  if v.status<>'draft' then raise exception 'Only draft items may be reordered'; end if;
  perform set_config('app.project_budget_rpc','on',true);
  for entry in select value from jsonb_array_elements(coalesce(ordered_items,'[]'::jsonb)) loop
    update public.project_budget_items set sequence=(entry->>'sequence')::integer,section_id=coalesce(nullif(entry->>'section_id','')::uuid,section_id) where id=(entry->>'id')::uuid and budget_version_id=target_version;
  end loop;
  perform private.project_budget_activity(v.project_id,'budget_items_reordered','تم تغيير ترتيب بنود الميزانية',jsonb_build_object('budget_version_id',target_version));
  return true;
end
$$;

create or replace function public.delete_project_budget_draft_item(target_item uuid)
returns boolean
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare actor uuid:=auth.uid(); item public.project_budget_items%rowtype; project uuid;
begin
  select i.* into item from public.project_budget_items i where i.id=target_item for update;
  select v.project_id into project from public.project_budget_versions v where v.id=item.budget_version_id;
  if actor is null or item.id is null or not private.project_budget_can(project,'project_budget_edit') then raise exception 'project_budget_edit permission required'; end if;
  perform set_config('app.project_budget_rpc','on',true);
  delete from public.project_budget_items where id=target_item;
  perform private.project_budget_activity(project,'budget_item_removed','تم حذف بند من مسودة الميزانية',jsonb_build_object('budget_version_id',item.budget_version_id,'budget_item_id',item.id,'old_value',to_jsonb(item)));
  return true;
end
$$;

create or replace function public.submit_project_budget(target_version uuid)
returns jsonb
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare actor uuid:=auth.uid(); v public.project_budget_versions%rowtype; item_count integer;
begin
  select * into v from public.project_budget_versions where id=target_version for update;
  if not found then raise exception 'Budget version not found'; end if;
  if actor is null or not private.project_budget_can(v.project_id,'project_budget_submit') then raise exception 'project_budget_submit permission required'; end if;
  if v.status<>'draft' then raise exception 'Only a draft budget may be submitted'; end if;
  perform private.recalculate_project_budget(target_version);
  select count(*) into item_count from public.project_budget_items where budget_version_id=target_version and total_with_waste>0;
  select * into v from public.project_budget_versions where id=target_version;
  if item_count=0 or v.expected_total_cost<=0 then raise exception 'Budget submission requires at least one valid positive item'; end if;
  perform set_config('app.project_budget_rpc','on',true);
  update public.project_budget_versions set status='submitted',submitted_by=actor,submitted_at=now(),updated_by=actor where id=target_version returning * into v;
  perform private.project_budget_activity(v.project_id,'budget_submitted','تم إرسال الميزانية للاعتماد',jsonb_build_object('budget_version_id',v.id,'version_number',v.version_number,'expected_total_cost',v.expected_total_cost));
  return to_jsonb(v);
end
$$;

create or replace function public.approve_project_budget(target_version uuid)
returns jsonb
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare actor uuid:=auth.uid(); v public.project_budget_versions%rowtype; item_count integer; previous_id uuid;
begin
  select * into v from public.project_budget_versions where id=target_version for update;
  if not found then raise exception 'Budget version not found'; end if;
  if actor is null or not private.project_budget_can(v.project_id,'project_budget_approve') then raise exception 'project_budget_approve permission required'; end if;
  perform 1 from public.projects where id=v.project_id for update;
  if v.status<>'submitted' then raise exception 'Only a submitted budget may be approved'; end if;
  -- Submission calculated and froze the totals. Submitted contents cannot be
  -- edited, so approval validates that immutable snapshot without rewriting it.
  select count(*) into item_count from public.project_budget_items where budget_version_id=target_version and total_with_waste>0;
  select * into v from public.project_budget_versions where id=target_version for update;
  if item_count=0 or v.expected_total_cost<=0 or v.subtotal<=0 then raise exception 'Budget approval requires complete positive totals'; end if;
  select id into previous_id from public.project_budget_versions where project_id=v.project_id and status='approved' and id<>v.id for update;
  perform set_config('app.project_budget_rpc','on',true);
  if previous_id is not null then update public.project_budget_versions set status='superseded',updated_by=actor where id=previous_id; end if;
  update public.project_budget_versions set status='approved',approved_by=actor,approved_at=now(),rejection_reason=null,updated_by=actor where id=target_version returning * into v;
  perform set_config('app.project_workspace_rpc','on',true);
  update public.projects set expected_cost=v.expected_total_cost,revenue=v.target_sale_price,updated_by=actor where id=v.project_id;
  perform private.project_budget_activity(v.project_id,'budget_approved','تم اعتماد الميزانية التقديرية',jsonb_build_object('budget_version_id',v.id,'version_number',v.version_number,'superseded_version_id',previous_id,'expected_total_cost',v.expected_total_cost));
  return to_jsonb(v);
end
$$;

create or replace function public.reject_project_budget(target_version uuid,rejection_reason text)
returns jsonb
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare actor uuid:=auth.uid(); v public.project_budget_versions%rowtype;
begin
  select * into v from public.project_budget_versions where id=target_version for update;
  if not found then raise exception 'Budget version not found'; end if;
  if actor is null or not private.project_budget_can(v.project_id,'project_budget_reject') then raise exception 'project_budget_reject permission required'; end if;
  if v.status<>'submitted' then raise exception 'Only a submitted budget may be rejected'; end if;
  if btrim(coalesce(rejection_reason,''))='' then raise exception 'A rejection reason is required'; end if;
  perform set_config('app.project_budget_rpc','on',true);
  update public.project_budget_versions set status='rejected',rejection_reason=btrim(rejection_reason),rejected_by=actor,rejected_at=now(),updated_by=actor where id=target_version returning * into v;
  perform private.project_budget_activity(v.project_id,'budget_rejected','تم رفض الميزانية التقديرية',jsonb_build_object('budget_version_id',v.id,'version_number',v.version_number,'reason',rejection_reason));
  return to_jsonb(v);
end
$$;

create or replace function public.cancel_project_budget_draft(target_version uuid,reason text default null)
returns boolean
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare actor uuid:=auth.uid(); v public.project_budget_versions%rowtype; item_count integer;
begin
  select * into v from public.project_budget_versions where id=target_version for update;
  if not found then raise exception 'Budget version not found'; end if;
  if actor is null or not private.project_budget_can(v.project_id,'project_budget_edit') then raise exception 'project_budget_edit permission required'; end if;
  if v.status<>'draft' then raise exception 'Only a draft budget may be cancelled'; end if;
  select count(*) into item_count from public.project_budget_items where budget_version_id=target_version;
  perform set_config('app.project_budget_rpc','on',true);
  if item_count=0 then delete from public.project_budget_versions where id=target_version;
  else update public.project_budget_versions set status='cancelled',notes=concat_ws(E'\n',notes,nullif(btrim(reason),'')),updated_by=actor where id=target_version;
  end if;
  perform private.project_budget_activity(v.project_id,'budget_cancelled','تم إلغاء مسودة الميزانية',jsonb_build_object('budget_version_id',v.id,'deleted_empty_draft',item_count=0,'reason',reason));
  return true;
end
$$;

create or replace function public.create_budget_template_from_version(source_version uuid,template_name text,template_type text default 'custom')
returns jsonb
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare actor uuid:=auth.uid(); v public.project_budget_versions%rowtype; created public.project_budget_templates%rowtype; section_row record; new_section uuid;
begin
  select * into v from public.project_budget_versions where id=source_version;
  if not found then raise exception 'Budget version not found'; end if;
  if actor is null or v.status not in ('approved','superseded') or not private.project_budget_can(v.project_id,'project_budget_manage_templates') then raise exception 'Approved budget and project_budget_manage_templates permission required'; end if;
  if btrim(coalesce(template_name,''))='' then raise exception 'Template name is required'; end if;
  insert into public.project_budget_templates(template_name,template_type,currency,notes,created_from_budget_version_id,created_by,updated_by)
  values(btrim(template_name),template_type,v.currency,v.notes,v.id,actor,actor) returning * into created;
  for section_row in select * from public.project_budget_sections where budget_version_id=v.id order by sequence,id loop
    insert into public.project_budget_template_sections(template_id,section_key,section_name,sequence,notes)
    values(created.id,section_row.section_key,section_row.section_name,section_row.sequence,section_row.notes) returning id into new_section;
    insert into public.project_budget_template_items(template_id,template_section_id,category,item_code,description,quantity,unit,unit_cost,waste_percentage,notes,sequence)
    select created.id,new_section,category,item_code,description,quantity,unit,unit_cost,waste_percentage,notes,sequence from public.project_budget_items where budget_version_id=v.id and section_id=section_row.id order by sequence,id;
  end loop;
  perform private.project_budget_activity(v.project_id,'budget_template_created','تم إنشاء قالب من ميزانية معتمدة',jsonb_build_object('budget_version_id',v.id,'template_id',created.id));
  return to_jsonb(created);
end
$$;

create or replace function public.create_budget_from_template(target_project uuid,target_template uuid)
returns jsonb
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare actor uuid:=auth.uid(); template public.project_budget_templates%rowtype; created jsonb; version_id uuid; section_row record; new_section uuid;
begin
  if actor is null or not private.project_budget_can(target_project,'project_budget_create') then raise exception 'project_budget_create permission required'; end if;
  select * into template from public.project_budget_templates where id=target_template and active;
  if not found then raise exception 'Budget template not found'; end if;
  created:=public.create_project_budget_draft(target_project,template.currency);
  version_id:=(created->>'id')::uuid;
  perform set_config('app.project_budget_rpc','on',true);
  delete from public.project_budget_sections where budget_version_id=version_id;
  for section_row in select * from public.project_budget_template_sections where template_id=template.id order by sequence,id loop
    insert into public.project_budget_sections(budget_version_id,section_key,section_name,sequence,notes)
    values(version_id,section_row.section_key,section_row.section_name,section_row.sequence,section_row.notes) returning id into new_section;
    insert into public.project_budget_items(budget_version_id,section_id,category,item_code,description,quantity,unit,unit_cost,waste_percentage,notes,sequence,created_by,updated_by)
    select version_id,new_section,category,item_code,description,quantity,unit,unit_cost,waste_percentage,notes,sequence,actor,actor from public.project_budget_template_items where template_id=template.id and template_section_id=section_row.id order by sequence,id;
  end loop;
  perform private.recalculate_project_budget(version_id);
  perform private.project_budget_activity(target_project,'budget_template_used','تم إنشاء مسودة ميزانية من قالب',jsonb_build_object('budget_version_id',version_id,'template_id',template.id));
  return (select to_jsonb(v) from public.project_budget_versions v where v.id=version_id);
end
$$;

create or replace function public.get_project_budget_visible(target_project uuid,target_version uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path = public, private, pg_temp
as $$
declare can_view boolean; can_finance boolean; can_templates boolean; versions jsonb; sections jsonb; items jsonb; templates jsonb;
begin
  can_view:=private.project_budget_can(target_project,'project_budget_view');
  if not can_view then raise exception 'project_budget_view permission required'; end if;
  can_finance:=private.project_budget_has_permission('project_budget_view_financials');
  can_templates:=private.project_budget_has_permission('project_budget_create');
  select coalesce(jsonb_agg(case when can_finance then to_jsonb(v) else to_jsonb(v)-array['subtotal','contingency_amount','contingency_percentage','overhead_amount','overhead_percentage','expected_total_cost','target_profit_amount','target_profit_percentage','target_sale_price'] end order by v.version_number desc),'[]'::jsonb)
    into versions from public.project_budget_versions v where v.project_id=target_project and (target_version is null or v.id=target_version);
  select coalesce(jsonb_agg(to_jsonb(s) order by s.sequence,s.id),'[]'::jsonb) into sections
    from public.project_budget_sections s join public.project_budget_versions v on v.id=s.budget_version_id where v.project_id=target_project and (target_version is null or v.id=target_version);
  select coalesce(jsonb_agg(case when can_finance then to_jsonb(i) else to_jsonb(i)-array['unit_cost','estimated_cost','waste_amount','total_with_waste'] end order by i.sequence,i.id),'[]'::jsonb) into items
    from public.project_budget_items i join public.project_budget_versions v on v.id=i.budget_version_id where v.project_id=target_project and (target_version is null or v.id=target_version);
  if can_templates then
    select coalesce(jsonb_agg(to_jsonb(t) order by t.template_name),'[]'::jsonb) into templates from public.project_budget_templates t where t.active;
  else templates:='[]'::jsonb; end if;
  return jsonb_build_object('versions',versions,'sections',sections,'items',items,'templates',templates,'can_view_financials',can_finance);
end
$$;

create or replace function public.compare_project_budget_versions(left_version uuid,right_version uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, private, pg_temp
as $$
declare left_budget public.project_budget_versions%rowtype; right_budget public.project_budget_versions%rowtype; can_finance boolean; lines jsonb;
begin
  select * into left_budget from public.project_budget_versions where id=left_version;
  select * into right_budget from public.project_budget_versions where id=right_version;
  if left_budget.project_id is null or right_budget.project_id<>left_budget.project_id then raise exception 'Budget versions must belong to the same project'; end if;
  if not private.project_budget_can(left_budget.project_id,'project_budget_view') then raise exception 'project_budget_view permission required'; end if;
  can_finance:=private.project_budget_has_permission('project_budget_view_financials');
  with old_items as (select coalesce(item_code,description) compare_key,* from public.project_budget_items where budget_version_id=left_version),
  new_items as (select coalesce(item_code,description) compare_key,* from public.project_budget_items where budget_version_id=right_version),
  compared as (
    select coalesce(n.compare_key,o.compare_key) compare_key,coalesce(n.description,o.description) description,
      case when o.id is null then 'added' when n.id is null then 'removed' else 'changed' end change_type,
      o.quantity old_quantity,n.quantity new_quantity,o.unit_cost old_unit_cost,n.unit_cost new_unit_cost,
      o.waste_percentage old_waste_percentage,n.waste_percentage new_waste_percentage,o.total_with_waste old_amount,n.total_with_waste new_amount
    from old_items o full join new_items n using(compare_key)
  )
  select coalesce(jsonb_agg(case when can_finance then to_jsonb(c)||jsonb_build_object('variance_amount',coalesce(new_amount,0)-coalesce(old_amount,0),'variance_percentage',case when coalesce(old_amount,0)=0 then null else round((coalesce(new_amount,0)-old_amount)*100/old_amount,2) end) else to_jsonb(c)-array['old_unit_cost','new_unit_cost','old_amount','new_amount'] end order by compare_key),'[]'::jsonb) into lines from compared c;
  return jsonb_build_object('left_version',left_budget.version_number,'right_version',right_budget.version_number,'can_view_financials',can_finance,'lines',lines,
    'old_total',case when can_finance then left_budget.expected_total_cost else null end,'new_total',case when can_finance then right_budget.expected_total_cost else null end,
    'variance_amount',case when can_finance then right_budget.expected_total_cost-left_budget.expected_total_cost else null end);
end
$$;

create or replace function public.project_activation_readiness(target_project uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, private, pg_temp
as $$
declare p public.projects%rowtype; approved public.project_budget_versions%rowtype; valid_lines integer:=0; dates_valid boolean; base_ready boolean; budget_ready boolean; override_ready boolean; checks jsonb;
begin
  if auth.uid() is null or not private.project_can_view(target_project) then raise exception 'Project view permission required'; end if;
  select * into p from public.projects where id=target_project;
  if not found then raise exception 'Project not found'; end if;
  select * into approved from public.project_budget_versions where project_id=target_project and status='approved' order by approved_at desc limit 1;
  if approved.id is not null then select count(*) into valid_lines from public.project_budget_items where budget_version_id=approved.id and total_with_waste>0; end if;
  dates_valid:=p.start_date is not null and (p.delivery_date is null or p.delivery_date>=p.start_date);
  base_ready:=btrim(coalesce(p.project_name,''))<>'' and p.customer_id is not null and p.project_manager_id is not null and dates_valid;
  budget_ready:=approved.id is not null and approved.expected_total_cost>0 and valid_lines>0;
  override_ready:=p.budget_activation_override_at is not null and btrim(coalesce(p.budget_activation_override_reason,''))<>'';
  checks:=jsonb_build_array(
    jsonb_build_object('key','required_details','label','البيانات الأساسية','implemented',true,'passed',btrim(coalesce(p.project_name,''))<>''),
    jsonb_build_object('key','customer','label','العميل','implemented',true,'passed',p.customer_id is not null,'blocking',true),
    jsonb_build_object('key','planned_dates','label','التواريخ المخططة','implemented',true,'passed',dates_valid,'blocking',true),
    jsonb_build_object('key','project_manager','label','مدير المشروع','implemented',true,'passed',p.project_manager_id is not null,'blocking',true),
    jsonb_build_object('key','estimated_budget_approval','label','اعتماد الميزانية التقديرية','implemented',true,'passed',budget_ready,'blocking',not p.legacy_activation_exempt and not override_ready,'budget_version_id',approved.id,'expected_total_cost',case when private.project_budget_has_permission('project_budget_view_financials') then approved.expected_total_cost else null end),
    jsonb_build_object('key','legacy_activation_exemption','label','إعفاء مشروع قديم','implemented',true,'passed',p.legacy_activation_exempt,'blocking',false),
    jsonb_build_object('key','exceptional_activation_override','label','تجاوز استثنائي موثق','implemented',true,'passed',override_ready,'blocking',false,'actor_id',p.budget_activation_override_by,'at',p.budget_activation_override_at)
  );
  return jsonb_build_object('project_id',p.id,'ready',base_ready and (budget_ready or p.legacy_activation_exempt or override_ready),
    'legacy_activation_exempt',p.legacy_activation_exempt,'budget_ready',budget_ready,'override_ready',override_ready,
    'approved_budget_version_id',approved.id,'checks',checks);
end
$$;

create or replace function public.get_project_activation_readiness(target_project uuid)
returns jsonb
language sql stable security definer
set search_path = public, private, pg_temp
as $$ select public.project_activation_readiness(target_project) $$;

create or replace function public.override_project_activation_budget_requirement(target_project uuid,override_reason text)
returns jsonb
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare actor uuid:=auth.uid(); p public.projects%rowtype;
begin
  if actor is null or public.current_identity_role()<>'owner' or not private.project_budget_has_permission('project_budget_override_activation') then raise exception 'Owner project_budget_override_activation permission required'; end if;
  if btrim(coalesce(override_reason,''))='' then raise exception 'A mandatory activation override reason is required'; end if;
  select * into p from public.projects where id=target_project for update;
  if not found then raise exception 'Project not found or not visible'; end if;
  if not private.project_can_view(target_project) then raise exception 'Project not found or not visible'; end if;
  if p.legacy_activation_exempt then raise exception 'Legacy project already has a stored activation exemption'; end if;
  if p.budget_activation_override_at is not null then raise exception 'Activation budget override is one-time and already recorded'; end if;
  perform set_config('app.project_workspace_rpc','on',true);
  update public.projects set budget_activation_override_reason=btrim(override_reason),budget_activation_override_by=actor,budget_activation_override_at=now(),updated_by=actor where id=target_project returning * into p;
  perform private.project_budget_activity(target_project,'activation_override_granted','تم منح تجاوز استثنائي لمتطلب الميزانية',jsonb_build_object('reason',override_reason,'actor_id',actor,'at',p.budget_activation_override_at));
  return public.project_activation_readiness(target_project);
end
$$;

alter table public.project_budget_versions enable row level security;
alter table public.project_budget_sections enable row level security;
alter table public.project_budget_items enable row level security;
alter table public.project_budget_templates enable row level security;
alter table public.project_budget_template_sections enable row level security;
alter table public.project_budget_template_items enable row level security;
alter table public.project_cost_source_contracts enable row level security;

revoke all on table public.project_budget_versions from public,anon,authenticated;
revoke all on table public.project_budget_sections from public,anon,authenticated;
revoke all on table public.project_budget_items from public,anon,authenticated;
revoke all on table public.project_budget_templates from public,anon,authenticated;
revoke all on table public.project_budget_template_sections from public,anon,authenticated;
revoke all on table public.project_budget_template_items from public,anon,authenticated;
revoke all on table public.project_cost_source_contracts from public,anon,authenticated;

do $$ declare table_name text; begin
  foreach table_name in array array['project_budget_versions','project_budget_sections','project_budget_items'] loop
    execute format('drop trigger if exists project_realtime_signal on public.%I',table_name);
    execute format('create trigger project_realtime_signal after insert or update or delete on public.%I for each statement execute function public.emit_project_realtime_signal()',table_name);
  end loop;
end $$;

do $$ declare signature text; begin
  foreach signature in array array[
    'create_project_budget_draft(uuid,text)','copy_project_budget_version(uuid)','update_project_budget_header(uuid,jsonb)',
    'save_project_budget_section(jsonb)','reorder_project_budget_sections(uuid,jsonb)','save_project_budget_item(jsonb)',
    'reorder_project_budget_items(uuid,jsonb)','delete_project_budget_draft_item(uuid)','submit_project_budget(uuid)',
    'approve_project_budget(uuid)','reject_project_budget(uuid,text)','cancel_project_budget_draft(uuid,text)',
    'create_budget_template_from_version(uuid,text,text)','create_budget_from_template(uuid,uuid)',
    'get_project_budget_visible(uuid,uuid)','compare_project_budget_versions(uuid,uuid)',
    'get_project_activation_readiness(uuid)','override_project_activation_budget_requirement(uuid,text)'
  ] loop
    execute format('revoke all on function public.%s from public,anon',signature);
    execute format('grant execute on function public.%s to authenticated',signature);
  end loop;
end $$;

revoke execute on function private.project_budget_has_permission(text) from public,anon,authenticated;
revoke execute on function private.project_budget_can(uuid,text) from public,anon,authenticated;
revoke execute on function private.recalculate_project_budget(uuid) from public,anon,authenticated;
revoke execute on function private.recalculate_project_budget_trigger() from public,anon,authenticated;
revoke execute on function private.protect_project_budget_history() from public,anon,authenticated;
revoke execute on function private.validate_project_cost_source() from public,anon,authenticated;
revoke execute on function private.project_budget_activity(uuid,text,text,jsonb) from public,anon,authenticated;

revoke all on function public.project_activation_readiness(uuid) from public,anon;
grant execute on function public.project_activation_readiness(uuid) to authenticated;

comment on table public.project_budget_versions is 'Versioned Estimated Budget planning data. Approved and historical versions are immutable.';
comment on table public.project_cost_source_contracts is 'Extension contracts only; this migration does not implement Actual Cost producers or Employee Cash Custody.';
comment on column public.project_costs.source_reference_key is 'Canonical globally unique key preventing double posting across expenses, purchases, petty cash, supplier invoices, custody settlements, and allocations.';
comment on column public.project_costs.estimated_budget_item_id is 'Optional trace from Actual Cost to the approved Estimated Budget item; it does not make planning data an actual cost.';
comment on function public.project_activation_readiness(uuid) is 'Blocks new activation without required details and an active approved Estimated Budget, while preserving stored legacy exemptions and audited Owner overrides.';
comment on function public.get_project_budget_visible(uuid,uuid) is 'Safe read path that redacts all financial fields unless project_budget_view_financials is granted.';
comment on function public.compare_project_budget_versions(uuid,uuid) is 'Estimated-versus-Estimated comparison only; Actual-versus-Estimated is intentionally not implemented.';

commit;
