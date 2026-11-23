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
declare activation_date date; source_movement uuid; source_layer record;
begin
  if new.movement_type not in ('receipt','production_receipt','adjustment_in','transfer_in','production_return','opening_balance') then return new; end if;
  select s.effective_from into activation_date
  from public.inventory_valuation_settings s where s.id=true;
  if activation_date is null or new.posted_at::date < activation_date then return new; end if;

  if new.movement_type='transfer_in' then
    source_movement:=nullif(new.metadata->>'source_movement_id','')::uuid;
    if source_movement is null then
      raise exception 'Transfer-in movement is missing its source movement reference';
    end if;
    for source_layer in
      select c.quantity,l.id as original_layer_id,l.unit_cost,l.received_at,l.layer_type
      from public.inventory_fifo_consumptions c
      join public.inventory_fifo_layers l on l.id=c.layer_id
      where c.issue_movement_id=source_movement
      order by l.received_at,l.id
    loop
      insert into public.inventory_fifo_layers(
        inventory_item_id,warehouse_id,source_movement_id,source_key,layer_type,
        received_at,original_quantity,remaining_quantity,unit_cost
      ) values(
        new.inventory_item_id,new.warehouse_id,new.id,
        'transfer:'||new.id::text||':'||source_layer.original_layer_id::text,
        source_layer.layer_type,source_layer.received_at,source_layer.quantity,
        source_layer.quantity,source_layer.unit_cost
      ) on conflict(source_key) do nothing;
    end loop;
    return new;
  end if;

  insert into public.inventory_fifo_layers(
    inventory_item_id,warehouse_id,source_movement_id,source_key,layer_type,
    received_at,original_quantity,remaining_quantity,unit_cost
  ) values(
    new.inventory_item_id,new.warehouse_id,new.id,'movement:'||new.id::text,
    case when new.movement_type='opening_balance' then 'opening_balance' else 'receipt' end,
    new.posted_at,abs(new.quantity_delta),abs(new.quantity_delta),new.unit_cost
  ) on conflict(source_key) do nothing;
  return new;
end
$$;
revoke all on function private.inventory_fifo_receipt_layer_trigger() from public,anon,authenticated;

drop trigger if exists inventory_fifo_receipt_layer on public.inventory_movements;
create trigger inventory_fifo_receipt_layer
after insert on public.inventory_movements
for each row execute function private.inventory_fifo_receipt_layer_trigger();

-- Consume layers for every other outbound movement (production, transfers,
-- adjustments, waste, damage, sales and rentals). The canonical project issue
-- RPC manages its own layers atomically and marks that in metadata.
create or replace function private.inventory_fifo_prepare_outbound_trigger()
returns trigger language plpgsql security definer set search_path=''
as $$
declare
  activation_date date;
  method text;
  layer record;
  remaining_to_consume numeric;
  take_quantity numeric;
  total_value numeric:=0;
  allocations jsonb:='[]'::jsonb;
begin
  if new.movement_type not in ('production_issue','adjustment_out','transfer_out','waste_out','damage_out','sale_issue','rental_issue') then
    return new;
  end if;
  if coalesce(new.metadata->>'fifo_layers_managed','false')='true' then return new; end if;
  select s.effective_from,s.valuation_method into activation_date,method
  from public.inventory_valuation_settings s where s.id=true;
  if activation_date is null or new.posted_at::date<activation_date then return new; end if;

  remaining_to_consume:=abs(new.quantity_delta);
  for layer in
    select * from public.inventory_fifo_layers
    where inventory_item_id=new.inventory_item_id and warehouse_id=new.warehouse_id
      and remaining_quantity>0
    order by received_at,id for update
  loop
    exit when remaining_to_consume<=0;
    take_quantity:=least(layer.remaining_quantity,remaining_to_consume);
    total_value:=total_value+round(take_quantity*layer.unit_cost,2);
    allocations:=allocations||jsonb_build_array(jsonb_build_object(
      'layer_id',layer.id,'quantity',take_quantity,'unit_cost',layer.unit_cost,
      'amount',round(take_quantity*layer.unit_cost,2)
    ));
    update public.inventory_fifo_layers
    set remaining_quantity=remaining_quantity-take_quantity where id=layer.id;
    remaining_to_consume:=remaining_to_consume-take_quantity;
  end loop;
  if remaining_to_consume>0.0001 then
    raise exception 'Inventory valuation layers are short; reconcile opening stock before outbound movement';
  end if;
  if method='fifo' then
    new.unit_cost:=round(total_value/abs(new.quantity_delta),8);
  end if;
  new.metadata:=coalesce(new.metadata,'{}'::jsonb)||jsonb_build_object('_fifo_layer_consumptions',allocations);
  return new;
end
$$;
revoke all on function private.inventory_fifo_prepare_outbound_trigger() from public,anon,authenticated;

drop trigger if exists inventory_fifo_prepare_outbound on public.inventory_movements;
create trigger inventory_fifo_prepare_outbound
before insert on public.inventory_movements
for each row execute function private.inventory_fifo_prepare_outbound_trigger();

create or replace function private.inventory_fifo_record_outbound_trigger()
returns trigger language plpgsql security definer set search_path=''
as $$
declare allocation jsonb;
begin
  if new.movement_type not in ('production_issue','adjustment_out','transfer_out','waste_out','damage_out','sale_issue','rental_issue') then
    return new;
  end if;
  for allocation in
    select * from jsonb_array_elements(coalesce(new.metadata->'_fifo_layer_consumptions','[]'::jsonb))
  loop
    insert into public.inventory_fifo_consumptions(
      issue_movement_id,layer_id,quantity,unit_cost,amount
    ) values(
      new.id,(allocation->>'layer_id')::uuid,(allocation->>'quantity')::numeric,
      (allocation->>'unit_cost')::numeric,(allocation->>'amount')::numeric
    );
  end loop;
  return new;
end
$$;
revoke all on function private.inventory_fifo_record_outbound_trigger() from public,anon,authenticated;

drop trigger if exists inventory_fifo_record_outbound on public.inventory_movements;
create trigger inventory_fifo_record_outbound
after insert on public.inventory_movements
for each row execute function private.inventory_fifo_record_outbound_trigger();

-- An issue reversal restores precisely the layers consumed by its original issue.
create or replace function private.inventory_fifo_restore_reversal_trigger()
returns trigger language plpgsql security definer set search_path=''
as $$
declare
  original public.inventory_movements%rowtype;
  original_layer public.inventory_fifo_layers%rowtype;
begin
  if new.reversed_movement_id is null then return new; end if;
  select * into original
  from public.inventory_movements where id=new.reversed_movement_id;

  if original.movement_type in ('project_issue','production_issue','adjustment_out','transfer_out','waste_out','damage_out','sale_issue','rental_issue') then
    update public.inventory_fifo_layers l
    set remaining_quantity=l.remaining_quantity+c.quantity
    from public.inventory_fifo_consumptions c
    where c.issue_movement_id=original.id and l.id=c.layer_id;
    return new;
  end if;

  if original.movement_type='transfer_in' then
    perform 1 from public.inventory_fifo_layers
    where source_movement_id=original.id for update;
    if exists(
      select 1 from public.inventory_fifo_layers
      where source_movement_id=original.id and remaining_quantity<original_quantity
    ) then
      raise exception 'Reverse the stock issues consuming transferred FIFO layers before reversing the transfer';
    end if;
    update public.inventory_fifo_layers set remaining_quantity=0
    where source_movement_id=original.id;
    return new;
  end if;

  if original.movement_type in ('receipt','production_receipt','adjustment_in','production_return','opening_balance') then
    select * into original_layer
    from public.inventory_fifo_layers
    where source_movement_id=original.id
    for update;
    if found then
      if original_layer.remaining_quantity < abs(new.quantity_delta) then
        raise exception 'Reverse the stock issues consuming this layer before reversing its receipt';
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

  select s.valuation_method into valuation_method
  from public.inventory_valuation_settings s where s.id=true;
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
    jsonb_build_object('valuation_method',valuation_method,'fifo_issue_value',case when valuation_method='fifo' then fifo_value else null end,'fifo_layers_managed',true)
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
as $$
  select case
    when auth.uid() is null or not public.is_current_profile_active() then null
    else coalesce((select to_jsonb(s) from public.inventory_valuation_settings s where s.id=true),
      jsonb_build_object('valuation_method','moving_average','effective_from',current_date))
  end
$$;

create or replace function public.set_inventory_valuation_method(target_method text)
returns jsonb language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
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
$$;

revoke all on function public.get_inventory_valuation_settings() from public,anon;
revoke all on function public.set_inventory_valuation_method(text) from public,anon;
grant execute on function public.get_inventory_valuation_settings() to authenticated;
grant execute on function public.set_inventory_valuation_method(text) to authenticated;


-- Per-project actual-cost workflow links. GL remains posted by the existing
-- expense / supplier-invoice triggers; these rows feed managerial project cost only.
alter table public.purchase_line_project_allocations
  add column if not exists actual_cost_entry_id uuid references public.project_actual_cost_entries(id) on delete restrict,
  add column if not exists cost_posting_status text not null default 'not_posted'
    check(cost_posting_status in ('not_posted','submitted','posted','rejected','reversed'));
alter table public.expense_project_allocations
  add column if not exists actual_cost_entry_id uuid references public.project_actual_cost_entries(id) on delete restrict,
  add column if not exists cost_posting_status text not null default 'not_posted'
    check(cost_posting_status in ('not_posted','submitted','posted','rejected','reversed'));

create unique index if not exists purchase_line_alloc_actual_cost_unique
  on public.purchase_line_project_allocations(actual_cost_entry_id)
  where actual_cost_entry_id is not null;
create unique index if not exists expense_alloc_actual_cost_unique
  on public.expense_project_allocations(actual_cost_entry_id)
  where actual_cost_entry_id is not null;

create or replace function public.prepare_allocated_expense_actual_cost(
  target_expense_id uuid, target_allocations jsonb
)
returns jsonb language plpgsql security definer
set search_path='public','private','pg_temp'
as $
declare
  actor uuid:=auth.uid();
  source_expense public.expenses%rowtype;
  allocation jsonb;
  allocation_id uuid;
  project_id_value uuid;
  amount_value numeric(18,2);
  total_allocated numeric(18,2):=0;
  entry jsonb;
  results jsonb:='[]'::jsonb;
  existing_count integer;
begin
  if actor is null or public.current_identity_role() not in ('owner','manager','accountant') then
    raise exception 'Owner, manager, or accountant role required';
  end if;
  select * into source_expense from public.expenses
  where id=target_expense_id for update;
  if not found or source_expense.cancelled_at is not null then
    raise exception 'Active expense not found';
  end if;
  if source_expense.project_id is not null then
    raise exception 'Use the existing direct-project actual-cost workflow for a directly linked expense';
  end if;
  if jsonb_typeof(target_allocations)<>'array' or jsonb_array_length(target_allocations)<1 then
    raise exception 'At least one project allocation is required';
  end if;
  select count(*) into existing_count from public.expense_project_allocations
  where expense_id=target_expense_id and actual_cost_entry_id is not null;
  if existing_count>0 then raise exception 'Expense allocations already have actual-cost entries'; end if;

  delete from public.expense_project_allocations where expense_id=target_expense_id;
  for allocation in select * from jsonb_array_elements(target_allocations)
  loop
    project_id_value:=(allocation->>'project_id')::uuid;
    amount_value:=round((allocation->>'allocated_amount')::numeric,2);
    if amount_value<=0 then raise exception 'Each allocated amount must be positive'; end if;
    perform 1 from public.projects
      where id=project_id_value and lifecycle not in ('closed','cancelled') for update;
    if not found or not private.project_can_view(project_id_value) then
      raise exception 'Project is unavailable or access denied';
    end if;
    insert into public.expense_project_allocations(
      expense_id,project_id,allocation_method,allocation_value,allocated_amount,created_by
    ) values(
      target_expense_id,project_id_value,
      coalesce(allocation->>'allocation_method','fixed_amount'),
      coalesce((allocation->>'allocation_value')::numeric,amount_value),
      amount_value,actor
    ) returning id into allocation_id;
    total_allocated:=total_allocated+amount_value;
  end loop;
  if round(total_allocated,2)<>round(source_expense.amount,2) then
    raise exception 'Project allocations must equal the expense gross amount';
  end if;

  for allocation_id,project_id_value,amount_value in
    select a.id,a.project_id,a.allocated_amount
    from public.expense_project_allocations a
    where a.expense_id=target_expense_id order by a.id
  loop
    entry:=public.save_project_actual_cost(jsonb_build_object(
      'project_id',project_id_value,'cost_category',
        case when lower(source_expense.category) like '%نقل%' or lower(source_expense.category) like '%transport%' then 'transport' else 'other' end,
      'source_type','approved_expense_allocation','source_id',target_expense_id,
      'source_line_reference',allocation_id::text,'source_revision',1,
      'source_reference_key','approved_expense_allocation:'||allocation_id::text||':1',
      'description','توزيع مصروف: '||source_expense.category,
      'quantity',1,'unit','حصة مصروف','unit_cost',amount_value,
      'cost_date',source_expense.expense_date,
      'metadata',jsonb_build_object('expense_id',target_expense_id,'allocation_id',allocation_id,
        'gross_amount',source_expense.amount,'net_amount',source_expense.net_amount,
        'tax_amount',source_expense.tax_amount)
    ));
    perform public.submit_project_actual_cost((entry->>'id')::uuid);
    update public.expense_project_allocations
      set actual_cost_entry_id=(entry->>'id')::uuid,cost_posting_status='submitted'
      where id=allocation_id;
    results:=results||jsonb_build_array(entry);
  end loop;
  return jsonb_build_object('expense_id',target_expense_id,'entries',results,'total_allocated',total_allocated);
end
$;

create or replace function public.prepare_purchase_line_project_costs(target_invoice_id uuid)
returns jsonb language plpgsql security definer
set search_path='public','private','pg_temp'
as $
declare
  actor uuid:=auth.uid();
  invoice public.supplier_invoices%rowtype;
  line record;
  allocation record;
  line_base_amount numeric(18,2);
  total_allocated numeric(18,2);
  entry jsonb;
  results jsonb:='[]'::jsonb;
  created_count integer:=0;
begin
  if actor is null or public.current_identity_role() not in ('owner','manager','accountant') then
    raise exception 'Owner, manager, or accountant role required';
  end if;
  select * into invoice from public.supplier_invoices
  where id=target_invoice_id for update;
  if not found or invoice.status not in ('approved','paid') then
    raise exception 'Approved supplier invoice required';
  end if;

  for line in
    select sil.* from public.supplier_invoice_lines sil
    where sil.supplier_invoice_id=target_invoice_id order by sil.id
  loop
    if exists(select 1 from public.purchase_line_project_allocations a
      where a.supplier_invoice_line_id=line.id and a.actual_cost_entry_id is not null) then
      continue;
    end if;
    select coalesce(sum(a.allocated_amount),0) into total_allocated
    from public.purchase_line_project_allocations a where a.supplier_invoice_line_id=line.id;
    if total_allocated=0 then continue; end if;
    line_base_amount:=round(coalesce(line.line_total,
      (line.quantity*line.unit_price)-line.discount_amount+line.tax_amount)*invoice.exchange_rate,2);
    if round(total_allocated,2)<>line_base_amount then
      raise exception 'Project allocations must equal invoice line base-currency total for line %',line.id;
    end if;

    for allocation in
      select a.* from public.purchase_line_project_allocations a
      where a.supplier_invoice_line_id=line.id order by a.id
    loop
      entry:=public.save_project_actual_cost(jsonb_build_object(
        'project_id',allocation.project_id,'cost_category','purchase_invoice',
        'source_type','purchase_invoice_allocation','source_id',line.id,
        'source_line_reference',allocation.id::text,'source_revision',1,
        'source_reference_key','purchase_invoice_allocation:'||allocation.id::text||':1',
        'description',line.description,'quantity',1,'unit','حصة فاتورة شراء',
        'unit_cost',allocation.allocated_amount,'cost_date',invoice.invoice_date,
        'budget_item_id',line.budget_item_id,'milestone_id',line.milestone_id,
        'metadata',jsonb_build_object('supplier_invoice_id',target_invoice_id,
          'invoice_line_id',line.id,'allocation_id',allocation.id,
          'exchange_rate',invoice.exchange_rate,'base_currency',invoice.base_currency)
      ));
      perform public.submit_project_actual_cost((entry->>'id')::uuid);
      update public.purchase_line_project_allocations
        set actual_cost_entry_id=(entry->>'id')::uuid,cost_posting_status='submitted'
        where id=allocation.id;
      results:=results||jsonb_build_array(entry);
      created_count:=created_count+1;
    end loop;
  end loop;
  return jsonb_build_object('invoice_id',target_invoice_id,'entries',results,'created_count',created_count);
end
$;

create or replace function private.sync_project_allocation_actual_cost_status()
returns trigger language plpgsql security definer set search_path=''
as $
begin
  if new.source_type='approved_expense_allocation' then
    update public.expense_project_allocations
    set cost_posting_status=case new.status when 'submitted' then 'submitted' when 'approved' then 'posted' when 'rejected' then 'rejected' when 'reversed' then 'reversed' else 'not_posted' end
    where id=nullif(new.source_line_reference,'')::uuid and actual_cost_entry_id=new.id;
    update public.expenses e
    set cost_posting_status=case
      when exists(select 1 from public.expense_project_allocations a where a.expense_id=e.id)
       and not exists(select 1 from public.expense_project_allocations a where a.expense_id=e.id and a.cost_posting_status<>'posted')
        then 'posted'
      when exists(select 1 from public.expense_project_allocations a where a.expense_id=e.id and a.cost_posting_status='submitted')
        then 'submitted'
      when exists(select 1 from public.expense_project_allocations a where a.expense_id=e.id and a.cost_posting_status='rejected')
        then 'rejected'
      when exists(select 1 from public.expense_project_allocations a where a.expense_id=e.id and a.cost_posting_status='reversed')
        then 'reversed'
      else 'not_posted' end
    where e.id=new.source_id;
  elsif new.source_type='purchase_invoice_allocation' then
    update public.purchase_line_project_allocations
    set cost_posting_status=case new.status when 'submitted' then 'submitted' when 'approved' then 'posted' when 'rejected' then 'rejected' when 'reversed' then 'reversed' else 'not_posted' end
    where id=nullif(new.source_line_reference,'')::uuid and actual_cost_entry_id=new.id;
  end if;
  return new;
end
$;
revoke all on function private.sync_project_allocation_actual_cost_status() from public,anon,authenticated;
drop trigger if exists sync_project_allocation_actual_cost_status on public.project_actual_cost_entries;
create trigger sync_project_allocation_actual_cost_status
after insert or update of status on public.project_actual_cost_entries
for each row execute function private.sync_project_allocation_actual_cost_status();

revoke all on function public.prepare_allocated_expense_actual_cost(uuid,jsonb) from public,anon;
revoke all on function public.prepare_purchase_line_project_costs(uuid) from public,anon;
grant execute on function public.prepare_allocated_expense_actual_cost(uuid,jsonb) to authenticated;
grant execute on function public.prepare_purchase_line_project_costs(uuid) to authenticated;

 
-- Cancellation must also reverse/reject every distributed project-cost entry.
create or replace function public.cancel_expense(target_expense_id uuid, reason text)
returns jsonb language plpgsql security definer set search_path=''
as $
declare
  actor uuid:=auth.uid();
  actor_role text:=public.current_identity_role();
  expense_row public.expenses%rowtype;
  cost_status text;
  allocation record;
begin
  if actor is null or actor_role not in ('owner','manager') then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if btrim(coalesce(reason,''))='' then
    raise exception using errcode='22023',message='Cancellation reason is required';
  end if;
  select * into expense_row from public.expenses where id=target_expense_id for update;
  if not found then raise exception 'Expense not found'; end if;
  if expense_row.cancelled_at is not null then return to_jsonb(expense_row); end if;

  if expense_row.actual_cost_entry_id is not null then
    select status into cost_status from public.project_actual_cost_entries
    where id=expense_row.actual_cost_entry_id for update;
    if cost_status='approved' then
      if actor_role<>'owner' then raise exception using errcode='42501',message='Owner role required to reverse an approved expense'; end if;
      perform public.reverse_project_actual_cost(expense_row.actual_cost_entry_id,btrim(reason));
    elsif cost_status='submitted' then
      perform public.reject_project_actual_cost(expense_row.actual_cost_entry_id,btrim(reason));
    elsif cost_status not in ('rejected','reversed') then
      raise exception 'Expense Actual Cost state cannot be cancelled';
    end if;
  end if;

  for allocation in
    select a.actual_cost_entry_id,c.status
    from public.expense_project_allocations a
    join public.project_actual_cost_entries c on c.id=a.actual_cost_entry_id
    where a.expense_id=target_expense_id
    for update of c
  loop
    if allocation.status='approved' then
      if actor_role<>'owner' then
        raise exception using errcode='42501',message='Owner role required to reverse an approved allocated expense';
      end if;
      perform public.reverse_project_actual_cost(allocation.actual_cost_entry_id,btrim(reason));
    elsif allocation.status='submitted' then
      perform public.reject_project_actual_cost(allocation.actual_cost_entry_id,btrim(reason));
    elsif allocation.status not in ('rejected','reversed') then
      raise exception 'Allocated expense Actual Cost state cannot be cancelled';
    end if;
  end loop;

  update public.expenses
  set cancelled_at=now(),cancelled_by=actor,cancellation_reason=btrim(reason),
      cost_posting_status='reversed'
  where id=target_expense_id
  returning * into expense_row;
  return to_jsonb(expense_row);
end
$;

revoke all on function public.cancel_expense(uuid,text) from public,anon;
grant execute on function public.cancel_expense(uuid,text) to authenticated;

commit;
