-- Protected inventory foundation: additive, immutable ledger with procurement and project boundaries.
begin;

create table if not exists public.inventory_warehouses (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (btrim(code) <> ''),
  name text not null check (btrim(name) <> ''),
  active boolean not null default true,
  created_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.inventory_locations (
  id uuid primary key default gen_random_uuid(),
  warehouse_id uuid not null references public.inventory_warehouses(id) on delete restrict,
  code text not null check (btrim(code) <> ''),
  name text not null check (btrim(name) <> ''),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (warehouse_id, code)
);

create table if not exists public.inventory_items (
  id uuid primary key default gen_random_uuid(),
  sku text not null unique check (btrim(sku) <> ''),
  name text not null check (btrim(name) <> ''),
  material_id uuid references public.materials(id) on delete set null,
  unit text not null default 'وحدة' check (btrim(unit) <> ''),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique nulls not distinct (material_id)
);

create table if not exists public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  movement_number text not null unique default ('IM-'||to_char(clock_timestamp(),'YYMMDD')||'-'||upper(substr(encode(extensions.gen_random_bytes(5),'hex'),1,8))),
  movement_type text not null check (movement_type in ('receipt','project_issue','receipt_reversal','project_issue_reversal','adjustment_in','adjustment_out')),
  inventory_item_id uuid not null references public.inventory_items(id) on delete restrict,
  warehouse_id uuid not null references public.inventory_warehouses(id) on delete restrict,
  location_id uuid references public.inventory_locations(id) on delete restrict,
  quantity_delta numeric not null check (quantity_delta <> 0),
  unit_cost numeric not null default 0 check (unit_cost >= 0),
  value_delta numeric generated always as (round(quantity_delta * unit_cost, 2)) stored,
  project_id uuid references public.projects(id) on delete restrict,
  goods_receipt_item_id uuid references public.goods_receipt_items(id) on delete restrict,
  actual_cost_entry_id uuid references public.project_actual_cost_entries(id) on delete restrict,
  reversed_movement_id uuid references public.inventory_movements(id) on delete restrict,
  reason text,
  posted_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  posted_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  check ((movement_type in ('receipt','receipt_reversal','adjustment_in') and quantity_delta > 0) or
         (movement_type in ('project_issue','project_issue_reversal','adjustment_out') and quantity_delta < 0)),
  check ((movement_type like 'project_issue%' and project_id is not null) or movement_type not like 'project_issue%'),
  check ((movement_type in ('receipt_reversal','project_issue_reversal') and reversed_movement_id is not null) or
         (movement_type not in ('receipt_reversal','project_issue_reversal') and reversed_movement_id is null))
);

create unique index if not exists inventory_receipt_once_idx
  on public.inventory_movements(goods_receipt_item_id)
  where movement_type='receipt';
create unique index if not exists inventory_reversal_once_idx
  on public.inventory_movements(reversed_movement_id)
  where reversed_movement_id is not null;
create index if not exists inventory_movements_item_warehouse_idx
  on public.inventory_movements(inventory_item_id,warehouse_id,posted_at);
create index if not exists inventory_movements_project_idx
  on public.inventory_movements(project_id) where project_id is not null;

create table if not exists public.inventory_balances (
  inventory_item_id uuid not null references public.inventory_items(id) on delete restrict,
  warehouse_id uuid not null references public.inventory_warehouses(id) on delete restrict,
  quantity_on_hand numeric not null default 0 check (quantity_on_hand >= 0),
  inventory_value numeric not null default 0 check (inventory_value >= 0),
  updated_at timestamptz not null default now(),
  primary key (inventory_item_id, warehouse_id)
);

create or replace function private.apply_inventory_movement()
returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$
declare current_qty numeric; current_value numeric; next_qty numeric; next_value numeric;
begin
  insert into public.inventory_balances(inventory_item_id,warehouse_id)
  values(new.inventory_item_id,new.warehouse_id)
  on conflict do nothing;
  select quantity_on_hand,inventory_value into current_qty,current_value
  from public.inventory_balances
  where inventory_item_id=new.inventory_item_id and warehouse_id=new.warehouse_id
  for update;
  next_qty:=current_qty+new.quantity_delta;
  next_value:=current_value+new.value_delta;
  if next_qty < 0 then raise exception 'Insufficient inventory balance'; end if;
  if next_value < 0 then raise exception 'Inventory value cannot be negative'; end if;
  update public.inventory_balances
  set quantity_on_hand=next_qty,inventory_value=next_value,updated_at=now()
  where inventory_item_id=new.inventory_item_id and warehouse_id=new.warehouse_id;
  return new;
end $$;

create trigger inventory_movement_balance_after_insert
after insert on public.inventory_movements
for each row execute function private.apply_inventory_movement();

create or replace function private.block_inventory_movement_mutation()
returns trigger language plpgsql set search_path=public,private,pg_temp as $$
begin raise exception 'Posted inventory movements are immutable; use reversal workflow'; end $$;

create trigger inventory_movement_no_update_delete
before update or delete on public.inventory_movements
for each row execute function private.block_inventory_movement_mutation();

create or replace function public.post_goods_receipt_to_inventory(target_goods_receipt_item uuid,target_inventory_item uuid,target_warehouse uuid,target_location uuid default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); line record; saved public.inventory_movements%rowtype; effective_cost numeric;
begin
  if actor is null or role_name not in ('owner','manager','accountant','production') then raise exception 'Inventory receiving access required'; end if;
  select gri.accepted_quantity,gr.status,poi.unit_price,poi.discount_amount,poi.quantity,poi.material_id,l.warehouse_id
  into line
  from public.goods_receipt_items gri
  join public.goods_receipts gr on gr.id=gri.goods_receipt_id
  join public.purchase_order_items poi on poi.id=gri.purchase_order_item_id
  left join public.inventory_locations l on l.id=target_location
  where gri.id=target_goods_receipt_item;
  if not found or line.status<>'confirmed' or line.accepted_quantity<=0 then raise exception 'Confirmed accepted receipt item required'; end if;
  if target_location is not null and line.warehouse_id<>target_warehouse then raise exception 'Location does not belong to warehouse'; end if;
  if not exists(select 1 from public.inventory_items i where i.id=target_inventory_item and i.active and (i.material_id is null or line.material_id is null or i.material_id=line.material_id)) then raise exception 'Inventory item does not match receipt material'; end if;
  effective_cost:=round((line.unit_price-(line.discount_amount/nullif(line.quantity,0))),4);
  insert into public.inventory_movements(movement_type,inventory_item_id,warehouse_id,location_id,quantity_delta,unit_cost,goods_receipt_item_id,posted_by,metadata)
  values('receipt',target_inventory_item,target_warehouse,target_location,line.accepted_quantity,effective_cost,target_goods_receipt_item,actor,jsonb_build_object('source','procurement_receipt'))
  returning * into saved;
  return to_jsonb(saved);
end $$;

create or replace function public.issue_inventory_to_project(target_inventory_item uuid,target_warehouse uuid,target_project uuid,issue_quantity numeric,description text,budget_item uuid default null,milestone uuid default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); balance record; movement public.inventory_movements%rowtype; entry jsonb; avg_cost numeric;
begin
  if actor is null or role_name not in ('owner','manager') then raise exception 'Owner or manager role required'; end if;
  if issue_quantity is null or issue_quantity<=0 then raise exception 'Positive issue quantity required'; end if;
  select quantity_on_hand,inventory_value into balance from public.inventory_balances
  where inventory_item_id=target_inventory_item and warehouse_id=target_warehouse for update;
  if not found or balance.quantity_on_hand<issue_quantity then raise exception 'Insufficient inventory balance'; end if;
  avg_cost:=case when balance.quantity_on_hand=0 then 0 else round(balance.inventory_value/balance.quantity_on_hand,4) end;
  insert into public.inventory_movements(movement_type,inventory_item_id,warehouse_id,quantity_delta,unit_cost,project_id,reason,posted_by)
  values('project_issue',target_inventory_item,target_warehouse,-issue_quantity,avg_cost,target_project,description,actor)
  returning * into movement;
  entry:=public.save_project_actual_cost(jsonb_build_object('project_id',target_project,'cost_category','material','source_type','inventory_issue','source_id',movement.id,'source_line_reference','main','source_revision',1,'source_reference_key','inventory_issue:'||movement.id::text||':main:1','description',description,'quantity',issue_quantity,'unit',(select unit from public.inventory_items where id=target_inventory_item),'unit_cost',avg_cost,'cost_date',current_date,'budget_item_id',budget_item,'milestone_id',milestone,'metadata',jsonb_build_object('inventory_movement_id',movement.id)));
  perform public.submit_project_actual_cost((entry->>'id')::uuid);
  perform public.approve_project_actual_cost((entry->>'id')::uuid);
  update public.inventory_movements set actual_cost_entry_id=(entry->>'id')::uuid where id=movement.id;
  return jsonb_set(to_jsonb(movement),'{actual_cost_entry_id}',to_jsonb((entry->>'id')::uuid));
end $$;

-- Narrow internal mutation exception: only allows linking the canonical cost in the same transaction.
create or replace function private.allow_inventory_cost_link()
returns trigger language plpgsql set search_path=public,private,pg_temp as $$
begin
  if old.actual_cost_entry_id is null and new.actual_cost_entry_id is not null and
     new.id=old.id and new.movement_type=old.movement_type and new.inventory_item_id=old.inventory_item_id and
     new.warehouse_id=old.warehouse_id and new.quantity_delta=old.quantity_delta and new.unit_cost=old.unit_cost and
     new.project_id is not distinct from old.project_id and new.goods_receipt_item_id is not distinct from old.goods_receipt_item_id and
     new.reversed_movement_id is not distinct from old.reversed_movement_id then return new; end if;
  raise exception 'Posted inventory movements are immutable; use reversal workflow';
end $$;

drop trigger inventory_movement_no_update_delete on public.inventory_movements;
create trigger inventory_movement_no_update_delete
before update or delete on public.inventory_movements
for each row execute function private.allow_inventory_cost_link();

create or replace function public.reverse_inventory_movement(target_movement uuid,reason text)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); original public.inventory_movements%rowtype; saved public.inventory_movements%rowtype;
begin
  if actor is null or public.current_identity_role()<>'owner' then raise exception 'Owner role required'; end if;
  if btrim(coalesce(reason,''))='' then raise exception 'Reversal reason required'; end if;
  select * into original from public.inventory_movements where id=target_movement for update;
  if not found or original.movement_type not in ('receipt','project_issue') then raise exception 'Reversible posted movement required'; end if;
  if exists(select 1 from public.inventory_movements where reversed_movement_id=original.id) then raise exception 'Movement already reversed'; end if;
  if original.actual_cost_entry_id is not null then perform public.reverse_project_actual_cost(original.actual_cost_entry_id,reason); end if;
  insert into public.inventory_movements(movement_type,inventory_item_id,warehouse_id,location_id,quantity_delta,unit_cost,project_id,goods_receipt_item_id,reversed_movement_id,reason,posted_by,metadata)
  values(case original.movement_type when 'receipt' then 'project_issue_reversal' else 'receipt_reversal' end,original.inventory_item_id,original.warehouse_id,original.location_id,-original.quantity_delta,original.unit_cost,original.project_id,null,original.id,reason,actor,jsonb_build_object('reversal_of',original.id))
  returning * into saved;
  return to_jsonb(saved);
end $$;

alter table public.inventory_warehouses enable row level security;
alter table public.inventory_locations enable row level security;
alter table public.inventory_items enable row level security;
alter table public.inventory_movements enable row level security;
alter table public.inventory_balances enable row level security;

revoke all on public.inventory_warehouses,public.inventory_locations,public.inventory_items,public.inventory_movements,public.inventory_balances from anon,authenticated;
revoke all on function public.post_goods_receipt_to_inventory(uuid,uuid,uuid,uuid) from public,anon;
revoke all on function public.issue_inventory_to_project(uuid,uuid,uuid,numeric,text,uuid,uuid) from public,anon;
revoke all on function public.reverse_inventory_movement(uuid,text) from public,anon;
grant execute on function public.post_goods_receipt_to_inventory(uuid,uuid,uuid,uuid) to authenticated;
grant execute on function public.issue_inventory_to_project(uuid,uuid,uuid,numeric,text,uuid,uuid) to authenticated;
grant execute on function public.reverse_inventory_movement(uuid,text) to authenticated;

commit;
