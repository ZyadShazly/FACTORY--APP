-- Project Actual Cost Engine foundation.
-- Additive, RPC-only writes, immutable approved entries and canonical source deduplication.

begin;

create table if not exists public.project_actual_cost_entries (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  milestone_id uuid references public.project_milestones(id) on delete set null,
  budget_item_id uuid references public.project_budget_items(id) on delete set null,
  cost_category text not null check (cost_category in ('material','labor','transport','subcontract','rental','asset_consumption','petty_cash','employee_cash_custody','purchase_invoice','manual_adjustment','other')),
  source_type text not null check (source_type in ('purchase_invoice_line','warehouse_issue_line','asset_consumption_line','factory_labor_allocation','employee_cash_custody_settlement_line','petty_cash_settlement_line','manual_adjustment','legacy_project_cost')),
  source_id uuid not null,
  source_line_reference text not null default 'main',
  source_revision integer not null default 1 check (source_revision > 0),
  source_reference_key text not null,
  description text not null,
  quantity numeric(18,4) not null default 1 check (quantity >= 0),
  unit text not null default 'وحدة',
  unit_cost numeric(18,4) not null default 0 check (unit_cost >= 0),
  amount numeric(18,2) generated always as (round(quantity * unit_cost, 2)) stored,
  currency text not null default 'SAR',
  cost_date date not null default current_date,
  status text not null default 'draft' check (status in ('draft','submitted','approved','rejected','reversed')),
  notes text,
  submitted_by uuid references public.profiles(id) on delete set null,
  submitted_at timestamptz,
  approved_by uuid references public.profiles(id) on delete set null,
  approved_at timestamptz,
  rejected_by uuid references public.profiles(id) on delete set null,
  rejected_at timestamptz,
  rejection_reason text,
  reversed_by uuid references public.profiles(id) on delete set null,
  reversed_at timestamptz,
  reversal_reason text,
  created_by uuid not null references public.profiles(id) on delete restrict,
  updated_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create unique index if not exists project_actual_cost_source_revision_uidx
  on public.project_actual_cost_entries(source_type, source_id, source_line_reference, source_revision)
  where status <> 'reversed';
create unique index if not exists project_actual_cost_reference_key_uidx
  on public.project_actual_cost_entries(source_reference_key)
  where status <> 'reversed';
create index if not exists project_actual_cost_project_status_idx on public.project_actual_cost_entries(project_id,status,cost_date desc);
create index if not exists project_actual_cost_milestone_idx on public.project_actual_cost_entries(milestone_id) where milestone_id is not null;
create index if not exists project_actual_cost_budget_item_idx on public.project_actual_cost_entries(budget_item_id) where budget_item_id is not null;
create index if not exists project_actual_cost_created_by_idx on public.project_actual_cost_entries(created_by);
create index if not exists project_actual_cost_approved_by_idx on public.project_actual_cost_entries(approved_by) where approved_by is not null;

create table if not exists public.project_actual_cost_allocations (
  id uuid primary key default gen_random_uuid(),
  cost_entry_id uuid not null references public.project_actual_cost_entries(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete restrict,
  milestone_id uuid references public.project_milestones(id) on delete set null,
  budget_item_id uuid references public.project_budget_items(id) on delete set null,
  cost_center_reference text,
  allocation_method text not null check (allocation_method in ('fixed_amount','percentage')),
  allocation_value numeric(18,4) not null check (allocation_value >= 0),
  allocated_amount numeric(18,2) not null check (allocated_amount >= 0),
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(cost_entry_id, project_id, milestone_id, budget_item_id, cost_center_reference)
);
create index if not exists project_actual_cost_alloc_entry_idx on public.project_actual_cost_allocations(cost_entry_id);
create index if not exists project_actual_cost_alloc_project_idx on public.project_actual_cost_allocations(project_id);

create table if not exists public.project_cost_freezes (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  freeze_from date not null,
  freeze_to date not null,
  reason text not null,
  active boolean not null default true,
  frozen_by uuid not null references public.profiles(id) on delete restrict,
  frozen_at timestamptz not null default now(),
  released_by uuid references public.profiles(id) on delete set null,
  released_at timestamptz,
  release_reason text,
  check (freeze_to >= freeze_from)
);
create unique index if not exists project_cost_freezes_active_period_uidx
  on public.project_cost_freezes(project_id,freeze_from,freeze_to) where active;

alter table public.project_actual_cost_entries enable row level security;
alter table public.project_actual_cost_allocations enable row level security;
alter table public.project_cost_freezes enable row level security;
revoke all on public.project_actual_cost_entries from public, anon, authenticated;
revoke all on public.project_actual_cost_allocations from public, anon, authenticated;
revoke all on public.project_cost_freezes from public, anon, authenticated;

create or replace function private.actual_cost_has_permission(permission_name text)
returns boolean language sql stable security definer
set search_path = public, private, pg_temp
as $$ select public.has_permission(permission_name) $$;

create or replace function private.actual_cost_assert_mutable(target_project uuid, target_date date)
returns void language plpgsql stable security definer
set search_path = public, private, pg_temp
as $$
begin
  if exists (
    select 1 from public.project_cost_freezes f
    where f.project_id = target_project and f.active and target_date between f.freeze_from and f.freeze_to
  ) then raise exception 'Actual cost period is frozen; post an adjustment in an open period'; end if;
end $$;

create or replace function public.save_project_actual_cost(payload jsonb)
returns jsonb language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  saved public.project_actual_cost_entries%rowtype;
  target_id uuid := nullif(payload->>'id','')::uuid;
  target_project uuid := (payload->>'project_id')::uuid;
  target_date date := coalesce(nullif(payload->>'cost_date','')::date,current_date);
begin
  if actor is null or not private.actual_cost_has_permission('project_actual_cost_create') then
    raise exception 'project_actual_cost_create permission required';
  end if;
  if not private.project_can_view(target_project) then raise exception 'Project access denied'; end if;
  perform private.actual_cost_assert_mutable(target_project,target_date);
  if coalesce(nullif(payload->>'quantity','')::numeric,0) < 0 or coalesce(nullif(payload->>'unit_cost','')::numeric,0) < 0 then
    raise exception 'Invalid cost values';
  end if;
  if btrim(coalesce(payload->>'description','')) = '' then raise exception 'Description is required'; end if;

  if target_id is null then
    insert into public.project_actual_cost_entries(
      project_id,milestone_id,budget_item_id,cost_category,source_type,source_id,source_line_reference,
      source_revision,source_reference_key,description,quantity,unit,unit_cost,currency,cost_date,notes,
      created_by,updated_by,metadata
    ) values (
      target_project,nullif(payload->>'milestone_id','')::uuid,nullif(payload->>'budget_item_id','')::uuid,
      payload->>'cost_category',payload->>'source_type',(payload->>'source_id')::uuid,
      coalesce(nullif(payload->>'source_line_reference',''),'main'),coalesce(nullif(payload->>'source_revision','')::integer,1),
      payload->>'source_reference_key',btrim(payload->>'description'),coalesce(nullif(payload->>'quantity','')::numeric,0),
      coalesce(nullif(payload->>'unit',''),'وحدة'),coalesce(nullif(payload->>'unit_cost','')::numeric,0),
      upper(coalesce(nullif(payload->>'currency',''),'SAR')),target_date,nullif(btrim(payload->>'notes'),''),actor,actor,
      coalesce(payload->'metadata','{}'::jsonb)
    ) returning * into saved;
  else
    update public.project_actual_cost_entries set
      milestone_id=nullif(payload->>'milestone_id','')::uuid,
      budget_item_id=nullif(payload->>'budget_item_id','')::uuid,
      cost_category=payload->>'cost_category',description=btrim(payload->>'description'),
      quantity=coalesce(nullif(payload->>'quantity','')::numeric,quantity),
      unit=coalesce(nullif(payload->>'unit',''),unit),unit_cost=coalesce(nullif(payload->>'unit_cost','')::numeric,unit_cost),
      cost_date=target_date,notes=nullif(btrim(payload->>'notes'),''),updated_by=actor,updated_at=now()
    where id=target_id and project_id=target_project and status='draft'
    returning * into saved;
    if not found then raise exception 'Draft actual cost not found'; end if;
  end if;
  return to_jsonb(saved);
end $$;

create or replace function public.submit_project_actual_cost(target_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare actor uuid:=auth.uid(); saved public.project_actual_cost_entries%rowtype;
begin
  select * into saved from public.project_actual_cost_entries where id=target_id for update;
  if not found then raise exception 'Actual cost not found'; end if;
  if actor is null or not private.actual_cost_has_permission('project_actual_cost_submit') then raise exception 'project_actual_cost_submit permission required'; end if;
  perform private.actual_cost_assert_mutable(saved.project_id,saved.cost_date);
  if saved.status <> 'draft' or saved.amount <= 0 then raise exception 'Only a positive draft cost may be submitted'; end if;
  update public.project_actual_cost_entries set status='submitted',submitted_by=actor,submitted_at=now(),updated_by=actor,updated_at=now()
  where id=target_id returning * into saved;
  return to_jsonb(saved);
end $$;

create or replace function public.approve_project_actual_cost(target_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare actor uuid:=auth.uid(); saved public.project_actual_cost_entries%rowtype; allocated numeric;
begin
  select * into saved from public.project_actual_cost_entries where id=target_id for update;
  if not found then raise exception 'Actual cost not found'; end if;
  if actor is null or not private.actual_cost_has_permission('project_actual_cost_approve') then raise exception 'project_actual_cost_approve permission required'; end if;
  perform private.actual_cost_assert_mutable(saved.project_id,saved.cost_date);
  if saved.status <> 'submitted' then raise exception 'Only submitted cost may be approved'; end if;
  select coalesce(sum(allocated_amount),0) into allocated from public.project_actual_cost_allocations where cost_entry_id=target_id;
  if allocated not in (0,saved.amount) then raise exception 'Allocations must equal the source amount'; end if;
  update public.project_actual_cost_entries set status='approved',approved_by=actor,approved_at=now(),updated_by=actor,updated_at=now()
  where id=target_id returning * into saved;
  update public.projects p set actual_cost = coalesce((select sum(c.amount) from public.project_actual_cost_entries c where c.project_id=p.id and c.status='approved'),0),updated_by=actor
  where p.id=saved.project_id;
  return to_jsonb(saved);
end $$;

create or replace function public.get_project_actual_cost_snapshot(target_project uuid)
returns jsonb language sql stable security definer
set search_path = public, private, pg_temp
as $$
  select case when private.project_can_view(target_project) and private.actual_cost_has_permission('project_actual_cost_view') then
    jsonb_build_object(
      'entries',coalesce((select jsonb_agg(to_jsonb(c) order by c.cost_date desc,c.created_at desc) from public.project_actual_cost_entries c where c.project_id=target_project),'[]'::jsonb),
      'approved_total',coalesce((select sum(c.amount) from public.project_actual_cost_entries c where c.project_id=target_project and c.status='approved'),0),
      'submitted_total',coalesce((select sum(c.amount) from public.project_actual_cost_entries c where c.project_id=target_project and c.status='submitted'),0),
      'by_category',coalesce((select jsonb_object_agg(x.cost_category,x.total) from (select cost_category,sum(amount) total from public.project_actual_cost_entries where project_id=target_project and status='approved' group by cost_category) x),'{}'::jsonb)
    ) else null end
$$;

revoke all on function private.actual_cost_has_permission(text) from public,anon,authenticated;
revoke all on function private.actual_cost_assert_mutable(uuid,date) from public,anon,authenticated;
revoke all on function public.save_project_actual_cost(jsonb) from public,anon;
revoke all on function public.submit_project_actual_cost(uuid) from public,anon;
revoke all on function public.approve_project_actual_cost(uuid) from public,anon;
revoke all on function public.get_project_actual_cost_snapshot(uuid) from public,anon;
grant execute on function public.save_project_actual_cost(jsonb) to authenticated;
grant execute on function public.submit_project_actual_cost(uuid) to authenticated;
grant execute on function public.approve_project_actual_cost(uuid) to authenticated;
grant execute on function public.get_project_actual_cost_snapshot(uuid) to authenticated;

commit;
