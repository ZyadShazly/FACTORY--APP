-- NextEP procurement / inventory valuation / project allocation foundation.
-- Additive only. This migration is intentionally kept off Production until reviewed.
begin;

create table if not exists public.inventory_valuation_settings (
  id boolean primary key default true check (id),
  valuation_method text not null default 'moving_average'
    check (valuation_method in ('moving_average','fifo')),
  effective_from date not null default current_date,
  activated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into public.inventory_valuation_settings(id,valuation_method,effective_from)
values(true,'moving_average',current_date)
on conflict(id) do nothing;

create table if not exists public.inventory_fifo_layers (
  id uuid primary key default gen_random_uuid(),
  inventory_item_id uuid not null references public.inventory_items(id) on delete restrict,
  warehouse_id uuid not null references public.inventory_warehouses(id) on delete restrict,
  source_movement_id uuid references public.inventory_movements(id) on delete restrict,
  source_key text not null unique,
  layer_type text not null check(layer_type in ('opening_balance','receipt')),
  received_at timestamptz not null,
  original_quantity numeric(18,4) not null check(original_quantity > 0),
  remaining_quantity numeric(18,4) not null check(remaining_quantity >= 0 and remaining_quantity <= original_quantity),
  unit_cost numeric(18,4) not null check(unit_cost >= 0),
  created_at timestamptz not null default now()
);
create index if not exists inventory_fifo_layers_available_idx
  on public.inventory_fifo_layers(inventory_item_id,warehouse_id,received_at,id)
  where remaining_quantity > 0;

create table if not exists public.inventory_fifo_consumptions (
  id uuid primary key default gen_random_uuid(),
  issue_movement_id uuid not null references public.inventory_movements(id) on delete restrict,
  layer_id uuid not null references public.inventory_fifo_layers(id) on delete restrict,
  quantity numeric(18,4) not null check(quantity > 0),
  unit_cost numeric(18,4) not null check(unit_cost >= 0),
  amount numeric(18,2) not null check(amount >= 0),
  created_at timestamptz not null default now(),
  unique(issue_movement_id,layer_id)
);
create index if not exists inventory_fifo_consumptions_layer_idx
  on public.inventory_fifo_consumptions(layer_id);

-- A single invoice line or expense can be allocated to multiple projects.
-- These rows are allocation instructions; canonical project-cost / GL posting remains
-- controlled by the existing accounting workflows and is not duplicated here.
create table if not exists public.purchase_line_project_allocations (
  id uuid primary key default gen_random_uuid(),
  supplier_invoice_line_id uuid not null references public.supplier_invoice_lines(id) on delete restrict,
  project_id uuid not null references public.projects(id) on delete restrict,
  allocation_method text not null check(allocation_method in ('fixed_amount','percentage','quantity')),
  allocation_value numeric(18,4) not null check(allocation_value >= 0),
  allocated_amount numeric(18,2) not null check(allocated_amount >= 0),
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(supplier_invoice_line_id,project_id)
);
create index if not exists purchase_line_project_allocations_project_idx
  on public.purchase_line_project_allocations(project_id);

create table if not exists public.expense_project_allocations (
  id uuid primary key default gen_random_uuid(),
  expense_id uuid not null references public.expenses(id) on delete restrict,
  project_id uuid not null references public.projects(id) on delete restrict,
  allocation_method text not null check(allocation_method in ('fixed_amount','percentage')),
  allocation_value numeric(18,4) not null check(allocation_value >= 0),
  allocated_amount numeric(18,2) not null check(allocated_amount >= 0),
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(expense_id,project_id)
);
create index if not exists expense_project_allocations_project_idx
  on public.expense_project_allocations(project_id);

alter table public.inventory_valuation_settings enable row level security;
alter table public.inventory_fifo_layers enable row level security;
alter table public.inventory_fifo_consumptions enable row level security;
alter table public.purchase_line_project_allocations enable row level security;
alter table public.expense_project_allocations enable row level security;

revoke all on public.inventory_valuation_settings,public.inventory_fifo_layers,
  public.inventory_fifo_consumptions,public.purchase_line_project_allocations,
  public.expense_project_allocations from public,anon,authenticated;

-- Capture receipts only from the valuation activation date onward.
create or replace function private.inventory_fifo_receipt_layer_trigger()
returns trigger language plpgsql security definer set search_path=''
as $$
declare activation_date date;
begin
  if new.movement_type <> 'receipt' then return new; end if;
  select s.effective_from into activation_date
  from public.inventory_valuation_settings s where s.id=true;
  if activation_date is null or new.posted_at::date < activation_date then return new; end if;
  insert into public.inventory_fifo_layers(
    inventory_item_id,warehouse_id,source_movement_id,source_key,layer_type,
    received_at,original_quantity,remaining_quantity,unit_cost
  ) values(
    new.inventory_item_id,new.warehouse_id,new.id,'movement:'||new.id::text,'receipt',
    new.posted_at,new.quantity_delta,new.quantity_delta,new.unit_cost
  ) on conflict(source_key) do nothing;
  return new;
end
$$;
revoke all on function private.inventory_fifo_receipt_layer_trigger() from public,anon,authenticated;

drop trigger if exists inventory_fifo_receipt_layer on public.inventory_movements;
create trigger inventory_fifo_receipt_layer
after insert on public.inventory_movements
for each row execute function private.inventory_fifo_receipt_layer_trigger();

-- An issue reversal restores precisely the layers consumed by its original issue.
create or replace function private.inventory_fifo_restore_reversal_trigger()
returns trigger language plpgsql security definer set search_path=''
as $$
declare
  original_type text;
  original_layer public.inventory_fifo_layers%rowtype;
begin
  if new.reversed_movement_id is null then return new; end if;
  select movement_type into original_type
  from public.inventory_movements where id=new.reversed_movement_id;

  -- The existing inventory ledger uses receipt_reversal for reversing a project issue.
  if new.movement_type='receipt_reversal' and original_type='project_issue' then
    update public.inventory_fifo_layers l
    set remaining_quantity=l.remaining_quantity+c.quantity
    from public.inventory_fifo_consumptions c
    where c.issue_movement_id=new.reversed_movement_id and l.id=c.layer_id;
    return new;
  end if;

  -- A receipt may be reversed only while its original FIFO layer is fully available.
  if new.movement_type='project_issue_reversal' and original_type='receipt' then
    select * into original_layer
    from public.inventory_fifo_layers
    where source_movement_id=new.reversed_movement_id
    for update;
    if found then
      if original_layer.remaining_quantity < original_layer.original_quantity then
        raise exception 'Reverse project issues before reversing a receipt consumed by FIFO';
      end if;
      update public.inventory_fifo_layers
      set remaining_quantity=remaining_quantity-abs(new.quantity_delta)
      where id=original_layer.id;
    end if;
  end if;
  return new;
end
$$;
revoke all on function private.inventory_fifo_restore_reversal_trigger() from public,anon,authenticated;

drop trigger if exists inventory_fifo_restore_reversal on public.inventory_movements;
create trigger inventory_fifo_restore_reversal
after insert on public.inventory_movements
for each row execute function private.inventory_fifo_restore_reversal_trigger();

-- Initialize FIFO layers from the live on-hand snapshot once. This is an opening
-- valuation snapshot, not a replay or reposting of historical receipts.
insert into public.inventory_fifo_layers(
  inventory_item_id,warehouse_id,source_key,layer_type,received_at,
  original_quantity,remaining_quantity,unit_cost
)
select b.inventory_item_id,b.warehouse_id,
       'opening:'||b.inventory_item_id::text||':'||b.warehouse_id::text,
       'opening_balance',now(),b.quantity_on_hand,b.quantity_on_hand,
       case when b.quantity_on_hand=0 then 0
            else round(b.inventory_value/b.quantity_on_hand,4) end
from public.inventory_balances b
where b.quantity_on_hand>0
on conflict(source_key) do nothing;

-- Replace the issue RPC while preserving its existing authorization and
-- actual-cost integration. FIFO records layer-level consumption; moving average
-- remains the default and retains the existing balance valuation behavior.
create or replace function public.issue_inventory_to_project(
  target_inventory_item uuid,target_warehouse uuid,target_project uuid,
  issue_quantity numeric,description text,budget_item uuid default null,milestone uuid default null
)
returns jsonb language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare
  actor uuid:=auth.uid();
  role_name text:=public.current_identity_role();
  balance record;
  movement public.inventory_movements%rowtype;
  entry jsonb;
  avg_cost numeric;
  valuation_method text:='moving_average';
  layer record;
  take_quantity numeric;
  fifo_value numeric:=0;
  remaining_to_issue numeric;
  layer_amount numeric;
  fifo_consumptions jsonb:='[]'::jsonb;
  consumption jsonb;
begin
  if actor is null or not public.is_current_profile_active()
     or role_name not in ('owner','manager') then
    raise exception 'Owner or manager role required';
  end if;
  if issue_quantity is null or issue_quantity<=0 then
    raise exception 'Positive issue quantity required';
  end if;
  if not exists(select 1 from public.projects where id=target_project) then
    raise exception 'Project not found';
  end if;

  select quantity_on_hand,inventory_value into balance
  from public.inventory_balances
  where inventory_item_id=target_inventory_item and warehouse_id=target_warehouse
  for update;
  if not found or balance.quantity_on_hand<issue_quantity then
    raise exception 'Insufficient inventory balance';
  end if;

  select valuation_method into valuation_method
  from public.inventory_valuation_settings where id=true;
  valuation_method:=coalesce(valuation_method,'moving_average');

  remaining_to_issue:=issue_quantity;
  for layer in
    select * from public.inventory_fifo_layers
    where inventory_item_id=target_inventory_item and warehouse_id=target_warehouse
      and remaining_quantity>0
    order by received_at,id
    for update
  loop
    exit when remaining_to_issue<=0;
    take_quantity:=least(layer.remaining_quantity,remaining_to_issue);
    layer_amount:=round(take_quantity*layer.unit_cost,2);
    fifo_value:=fifo_value+layer_amount;
    fifo_consumptions:=fifo_consumptions||jsonb_build_array(jsonb_build_object(
      'layer_id',layer.id,'quantity',take_quantity,'unit_cost',layer.unit_cost,'amount',layer_amount
    ));
    update public.inventory_fifo_layers
    set remaining_quantity=remaining_quantity-take_quantity
    where id=layer.id;
    remaining_to_issue:=remaining_to_issue-take_quantity;
  end loop;
  if remaining_to_issue>0.0001 then
    raise exception 'Inventory valuation layers are short; reconcile the opening balance before issuing stock';
  end if;

  if valuation_method='fifo' then
    avg_cost:=round(fifo_value/issue_quantity,4);
  else
    avg_cost:=case when balance.quantity_on_hand=0 then 0
      else round(balance.inventory_value/balance.quantity_on_hand,4) end;
  end if;

  insert into public.inventory_movements(
    movement_type,inventory_item_id,warehouse_id,quantity_delta,unit_cost,
    project_id,reason,posted_by,metadata
  ) values(
    'project_issue',target_inventory_item,target_warehouse,-issue_quantity,
    avg_cost,target_project,description,actor,
    jsonb_build_object('valuation_method',valuation_method,'fifo_issue_value',case when valuation_method='fifo' then fifo_value else null end)
  ) returning * into movement;

  if valuation_method='fifo'
     and round(fifo_value,2)<>round((-movement.value_delta),2) then
    raise exception 'FIFO issue valuation does not reconcile with inventory movement';
  end if;
  for consumption in select * from jsonb_array_elements(fifo_consumptions)
  loop
    insert into public.inventory_fifo_consumptions(
      issue_movement_id,layer_id,quantity,unit_cost,amount
    ) values(
      movement.id,(consumption->>'layer_id')::uuid,
      (consumption->>'quantity')::numeric,(consumption->>'unit_cost')::numeric,
      (consumption->>'amount')::numeric
    );
  end loop;

  entry:=public.save_project_actual_cost(jsonb_build_object(
    'project_id',target_project,'cost_category','material','source_type','warehouse_issue_line',
    'source_id',movement.id,'source_line_reference','main','source_revision',1,
    'source_reference_key','warehouse_issue_line:'||movement.id::text||':main:1',
    'description',description,'quantity',issue_quantity,
    'unit',(select unit from public.inventory_items where id=target_inventory_item),
    'unit_cost',avg_cost,'cost_date',current_date,'budget_item_id',budget_item,'milestone_id',milestone,
    'metadata',jsonb_build_object('inventory_movement_id',movement.id,'valuation_method',valuation_method)
  ));
  perform public.submit_project_actual_cost((entry->>'id')::uuid);
  perform public.approve_project_actual_cost((entry->>'id')::uuid);
  perform set_config('app.inventory_cost_link','on',true);
  update public.inventory_movements set actual_cost_entry_id=(entry->>'id')::uuid where id=movement.id;
  perform set_config('app.inventory_cost_link','off',true);
  return jsonb_set(to_jsonb(movement),'{actual_cost_entry_id}',to_jsonb((entry->>'id')::uuid));
end
$$;

revoke all on function public.issue_inventory_to_project(uuid,uuid,uuid,numeric,text,uuid,uuid) from public,anon;
grant execute on function public.issue_inventory_to_project(uuid,uuid,uuid,numeric,text,uuid,uuid) to authenticated;


create or replace function public.get_inventory_valuation_settings()
returns jsonb language sql stable security definer
set search_path='public','private','pg_temp'
as $
  select case
    when auth.uid() is null or not public.is_current_profile_active() then null
    else coalesce((select to_jsonb(s) from public.inventory_valuation_settings s where s.id=true),
      jsonb_build_object('valuation_method','moving_average','effective_from',current_date))
  end
$;

create or replace function public.set_inventory_valuation_method(target_method text)
returns jsonb language plpgsql security definer
set search_path='public','private','pg_temp'
as $
declare saved public.inventory_valuation_settings%rowtype;
begin
  if auth.uid() is null or not public.is_current_profile_active()
     or public.current_identity_role() not in ('owner','manager') then
    raise exception 'Owner or manager role required';
  end if;
  if target_method not in ('moving_average','fifo') then
    raise exception 'Unsupported inventory valuation method';
  end if;
  update public.inventory_valuation_settings
  set valuation_method=target_method,updated_by=auth.uid(),updated_at=now()
  where id=true returning * into saved;
  if not found then
    insert into public.inventory_valuation_settings(id,valuation_method,effective_from,updated_by)
    values(true,target_method,current_date,auth.uid()) returning * into saved;
  end if;
  return to_jsonb(saved);
end
$;

revoke all on function public.get_inventory_valuation_settings() from public,anon;
revoke all on function public.set_inventory_valuation_method(text) from public,anon;
grant execute on function public.get_inventory_valuation_settings() to authenticated;
grant execute on function public.set_inventory_valuation_method(text) to authenticated;

commit;
