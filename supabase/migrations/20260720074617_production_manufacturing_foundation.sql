-- Protected Production & Manufacturing foundation.
-- Additive upgrade of legacy production_orders; preserves historical rows and IDs.
begin;

alter table public.production_orders
  add column if not exists status text not null default 'draft',
  add column if not exists planned_start_date date,
  add column if not exists planned_end_date date,
  add column if not exists released_at timestamptz,
  add column if not exists released_by uuid references public.profiles(id) on delete restrict,
  add column if not exists started_at timestamptz,
  add column if not exists completed_at timestamptz,
  add column if not exists completed_by uuid references public.profiles(id) on delete restrict,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references public.profiles(id) on delete restrict,
  add column if not exists cancellation_reason text,
  add column if not exists updated_at timestamptz not null default now();

do $$ begin
  alter table public.production_orders add constraint production_orders_status_check
    check (status in ('draft','planned','released','in_progress','completed','cancelled'));
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.production_orders add constraint production_orders_plan_dates_check
    check (planned_end_date is null or planned_start_date is null or planned_end_date >= planned_start_date);
exception when duplicate_object then null; end $$;

create index if not exists production_orders_status_project_idx
  on public.production_orders(status,project_id,order_date);

create table if not exists public.production_order_operations (
  id uuid primary key default gen_random_uuid(),
  production_order_id uuid not null references public.production_orders(id) on delete restrict,
  sequence_no integer not null check (sequence_no > 0),
  name text not null check (btrim(name) <> ''),
  status text not null default 'pending' check (status in ('pending','ready','in_progress','completed','skipped')),
  planned_minutes numeric check (planned_minutes is null or planned_minutes >= 0),
  actual_minutes numeric check (actual_minutes is null or actual_minutes >= 0),
  started_at timestamptz,
  completed_at timestamptz,
  note text,
  created_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now(),
  unique (production_order_id,sequence_no)
);

create table if not exists public.production_material_requirements (
  id uuid primary key default gen_random_uuid(),
  production_order_id uuid not null references public.production_orders(id) on delete restrict,
  inventory_item_id uuid not null references public.inventory_items(id) on delete restrict,
  warehouse_id uuid not null references public.inventory_warehouses(id) on delete restrict,
  required_quantity numeric not null check (required_quantity > 0),
  issued_quantity numeric not null default 0 check (issued_quantity >= 0),
  consumed_quantity numeric not null default 0 check (consumed_quantity >= 0),
  inventory_movement_id uuid references public.inventory_movements(id) on delete restrict,
  budget_item_id uuid references public.project_budget_items(id) on delete restrict,
  milestone_id uuid references public.project_milestones(id) on delete restrict,
  note text,
  created_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now(),
  unique (production_order_id,inventory_item_id,warehouse_id),
  check (consumed_quantity <= issued_quantity),
  check (issued_quantity <= required_quantity)
);

create index if not exists production_material_order_idx
  on public.production_material_requirements(production_order_id);

create or replace function private.touch_production_order()
returns trigger language plpgsql set search_path=public,private,pg_temp as $$
begin new.updated_at:=now(); return new; end $$;

drop trigger if exists production_order_touch_updated_at on public.production_orders;
create trigger production_order_touch_updated_at before update on public.production_orders
for each row execute function private.touch_production_order();

create or replace function public.add_production_operation(
  target_order uuid, operation_sequence integer, operation_name text,
  planned_minutes numeric default null, operation_note text default null
)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); saved public.production_order_operations%rowtype;
begin
  if actor is null or role_name not in ('owner','manager') then raise exception 'Owner or manager role required'; end if;
  if operation_sequence is null or operation_sequence<=0 or btrim(coalesce(operation_name,''))='' then raise exception 'Valid operation required'; end if;
  if not exists(select 1 from public.production_orders where id=target_order and status in ('draft','planned')) then raise exception 'Draft or planned production order required'; end if;
  insert into public.production_order_operations(production_order_id,sequence_no,name,planned_minutes,note,created_by)
  values(target_order,operation_sequence,btrim(operation_name),planned_minutes,operation_note,actor)
  returning * into saved;
  return to_jsonb(saved);
end $$;

create or replace function public.add_production_material_requirement(
  target_order uuid, target_inventory_item uuid, target_warehouse uuid,
  required_quantity numeric, budget_item uuid default null,
  milestone uuid default null, requirement_note text default null
)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); saved public.production_material_requirements%rowtype;
begin
  if actor is null or role_name not in ('owner','manager') then raise exception 'Owner or manager role required'; end if;
  if required_quantity is null or required_quantity<=0 then raise exception 'Positive required quantity required'; end if;
  if not exists(select 1 from public.production_orders where id=target_order and status in ('draft','planned')) then raise exception 'Draft or planned production order required'; end if;
  insert into public.production_material_requirements(production_order_id,inventory_item_id,warehouse_id,required_quantity,budget_item_id,milestone_id,note,created_by)
  values(target_order,target_inventory_item,target_warehouse,required_quantity,budget_item,milestone,requirement_note,actor)
  returning * into saved;
  return to_jsonb(saved);
end $$;

create or replace function public.plan_production_order(target_order uuid,start_date date,end_date date default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); saved public.production_orders%rowtype;
begin
  if actor is null or role_name not in ('owner','manager') then raise exception 'Owner or manager role required'; end if;
  if start_date is null or (end_date is not null and end_date<start_date) then raise exception 'Valid production plan dates required'; end if;
  update public.production_orders set status='planned',planned_start_date=start_date,planned_end_date=end_date,cancellation_reason=null,cancelled_at=null,cancelled_by=null
  where id=target_order and status in ('draft','planned') returning * into saved;
  if not found then raise exception 'Draft or planned production order required'; end if;
  return to_jsonb(saved);
end $$;

create or replace function public.release_production_order(target_order uuid)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); saved public.production_orders%rowtype;
begin
  if actor is null or role_name not in ('owner','manager') then raise exception 'Owner or manager role required'; end if;
  if not exists(select 1 from public.production_material_requirements where production_order_id=target_order) then raise exception 'At least one material requirement is required'; end if;
  update public.production_orders set status='released',released_at=coalesce(released_at,now()),released_by=coalesce(released_by,actor)
  where id=target_order and status='planned' returning * into saved;
  if not found then raise exception 'Planned production order required'; end if;
  return to_jsonb(saved);
end $$;

create or replace function public.issue_production_material(target_requirement uuid,issue_quantity numeric,issue_description text default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); req record; movement jsonb; saved public.production_material_requirements%rowtype;
begin
  if actor is null or role_name not in ('owner','manager') then raise exception 'Owner or manager role required'; end if;
  select r.*,o.project_id,o.status order_status into req
  from public.production_material_requirements r join public.production_orders o on o.id=r.production_order_id
  where r.id=target_requirement for update of r,o;
  if not found or req.order_status not in ('released','in_progress') then raise exception 'Released production order required'; end if;
  if req.project_id is null then raise exception 'Production order must be linked to a project'; end if;
  if req.inventory_movement_id is not null or req.issued_quantity<>0 then raise exception 'Material requirement already issued'; end if;
  if issue_quantity is null or issue_quantity<>req.required_quantity then raise exception 'Full required quantity must be issued exactly once'; end if;
  movement:=public.issue_inventory_to_project(req.inventory_item_id,req.warehouse_id,req.project_id,issue_quantity,
    coalesce(nullif(btrim(issue_description),''),'Production material issue'),req.budget_item_id,req.milestone_id);
  update public.production_material_requirements set issued_quantity=issue_quantity,consumed_quantity=issue_quantity,inventory_movement_id=(movement->>'id')::uuid
  where id=target_requirement returning * into saved;
  update public.production_orders set status='in_progress',started_at=coalesce(started_at,now())
  where id=req.production_order_id and status='released';
  return jsonb_build_object('requirement',to_jsonb(saved),'inventory_movement',movement);
end $$;

create or replace function public.complete_production_order(target_order uuid)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); saved public.production_orders%rowtype;
begin
  if actor is null or role_name not in ('owner','manager') then raise exception 'Owner or manager role required'; end if;
  select * into saved from public.production_orders where id=target_order for update;
  if not found then raise exception 'Production order not found'; end if;
  if saved.status='completed' then return to_jsonb(saved); end if;
  if saved.status<>'in_progress' then raise exception 'In-progress production order required'; end if;
  if exists(select 1 from public.production_material_requirements where production_order_id=target_order and issued_quantity<required_quantity) then raise exception 'All required materials must be issued before completion'; end if;
  if exists(select 1 from public.production_order_operations where production_order_id=target_order and status not in ('completed','skipped')) then raise exception 'All operations must be completed or skipped'; end if;
  update public.production_orders set status='completed',completed_at=now(),completed_by=actor where id=target_order returning * into saved;
  return to_jsonb(saved);
end $$;

create or replace function public.cancel_production_order(target_order uuid,reason text)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); saved public.production_orders%rowtype; req record;
begin
  if actor is null or role_name<>'owner' then raise exception 'Owner role required'; end if;
  if btrim(coalesce(reason,''))='' then raise exception 'Cancellation reason required'; end if;
  select * into saved from public.production_orders where id=target_order for update;
  if not found or saved.status in ('completed','cancelled') then raise exception 'Cancellable production order required'; end if;
  for req in select inventory_movement_id from public.production_material_requirements where production_order_id=target_order and inventory_movement_id is not null loop
    if not exists(select 1 from public.inventory_movements where reversed_movement_id=req.inventory_movement_id) then perform public.reverse_inventory_movement(req.inventory_movement_id,reason); end if;
  end loop;
  update public.production_orders set status='cancelled',cancelled_at=now(),cancelled_by=actor,cancellation_reason=reason where id=target_order returning * into saved;
  return to_jsonb(saved);
end $$;

alter table public.production_orders enable row level security;
alter table public.production_order_operations enable row level security;
alter table public.production_material_requirements enable row level security;
revoke all on public.production_orders,public.production_order_operations,public.production_material_requirements from anon,authenticated;

revoke all on function public.add_production_operation(uuid,integer,text,numeric,text) from public,anon;
revoke all on function public.add_production_material_requirement(uuid,uuid,uuid,numeric,uuid,uuid,text) from public,anon;
revoke all on function public.plan_production_order(uuid,date,date) from public,anon;
revoke all on function public.release_production_order(uuid) from public,anon;
revoke all on function public.issue_production_material(uuid,numeric,text) from public,anon;
revoke all on function public.complete_production_order(uuid) from public,anon;
revoke all on function public.cancel_production_order(uuid,text) from public,anon;
grant execute on function public.add_production_operation(uuid,integer,text,numeric,text) to authenticated;
grant execute on function public.add_production_material_requirement(uuid,uuid,uuid,numeric,uuid,uuid,text) to authenticated;
grant execute on function public.plan_production_order(uuid,date,date) to authenticated;
grant execute on function public.release_production_order(uuid) to authenticated;
grant execute on function public.issue_production_material(uuid,numeric,text) to authenticated;
grant execute on function public.complete_production_order(uuid) to authenticated;
grant execute on function public.cancel_production_order(uuid,text) to authenticated;

commit;
