-- Make commercial posting atomic with finished-goods inventory and retry safe.
-- Historical commercial rows are preserved; only new rows use this contract.
begin;

alter table public.sales add column if not exists command_id uuid;
alter table public.rentals add column if not exists command_id uuid;

create unique index if not exists sales_command_uidx
  on public.sales(command_id) where command_id is not null;
create unique index if not exists rentals_command_uidx
  on public.rentals(command_id) where command_id is not null;

alter table public.inventory_movements
  add column if not exists sale_id uuid references public.sales(id) on delete restrict,
  add column if not exists rental_id uuid references public.rentals(id) on delete restrict;

create index if not exists inventory_movements_sale_idx
  on public.inventory_movements(sale_id) where sale_id is not null;
create index if not exists inventory_movements_rental_idx
  on public.inventory_movements(rental_id) where rental_id is not null;

alter table public.inventory_movements
  drop constraint if exists inventory_movements_movement_type_check,
  drop constraint if exists inventory_movements_direction_check,
  drop constraint if exists inventory_movements_check2;

alter table public.inventory_movements
  add constraint inventory_movements_movement_type_check check (
    movement_type in (
      'receipt','project_issue','production_issue','production_receipt','receipt_reversal',
      'project_issue_reversal','production_issue_reversal','adjustment_in','adjustment_out',
      'transfer_in','transfer_out','production_return','waste_out','damage_out','opening_balance',
      'sale_issue','sale_issue_reversal','rental_issue','rental_return','rental_cancellation'
    )
  ),
  add constraint inventory_movements_direction_check check (
    (movement_type in (
      'receipt','production_receipt','project_issue_reversal','production_issue_reversal',
      'adjustment_in','transfer_in','production_return','opening_balance',
      'sale_issue_reversal','rental_return','rental_cancellation'
    ) and quantity_delta>0)
    or
    (movement_type in (
      'project_issue','production_issue','receipt_reversal','adjustment_out','transfer_out',
      'waste_out','damage_out','sale_issue','rental_issue'
    ) and quantity_delta<0)
  ),
  add constraint inventory_movements_check2 check (
    (movement_type in (
      'receipt_reversal','project_issue_reversal','production_issue_reversal',
      'sale_issue_reversal','rental_return','rental_cancellation'
    ) and reversed_movement_id is not null)
    or
    (movement_type not in (
      'receipt_reversal','project_issue_reversal','production_issue_reversal',
      'sale_issue_reversal','rental_return','rental_cancellation'
    ) and reversed_movement_id is null)
  );

create or replace function private.commercial_page_allowed(target_page text)
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select exists(
    select 1
    from public.profiles p
    where p.id=auth.uid()
      and p.status='active'
      and (
        p.role in ('owner','manager')
        or (
          p.role='accountant'
          and (
            jsonb_typeof(p.permissions->'pages') is distinct from 'array'
            or p.permissions->'pages' ? target_page
          )
        )
      )
  )
$$;

revoke all on function private.commercial_page_allowed(text) from public,anon,authenticated;

create or replace function private.reverse_commercial_inventory(
  target_kind text,
  target_id uuid,
  reversal_kind text,
  reversal_reason text
)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare original public.inventory_movements%rowtype;
begin
  if target_kind not in ('sale','rental') then
    raise exception using errcode='22023',message='Unsupported commercial inventory target';
  end if;

  for original in
    select movement.*
    from public.inventory_movements movement
    where (
      (target_kind='sale' and movement.sale_id=target_id and movement.movement_type='sale_issue')
      or
      (target_kind='rental' and movement.rental_id=target_id and movement.movement_type='rental_issue')
    )
    order by movement.id
    for update
  loop
    if not exists(
      select 1 from public.inventory_movements reversal
      where reversal.reversed_movement_id=original.id
    ) then
      insert into public.inventory_movements(
        movement_type,inventory_item_id,warehouse_id,location_id,quantity_delta,unit_cost,
        reversed_movement_id,sale_id,rental_id,reason,posted_by,metadata
      ) values(
        reversal_kind,original.inventory_item_id,original.warehouse_id,original.location_id,
        -original.quantity_delta,original.unit_cost,original.id,original.sale_id,original.rental_id,
        reversal_reason,auth.uid(),jsonb_build_object('source','commercial_lifecycle','reversal_of',original.id)
      );
    end if;
  end loop;
end
$$;

revoke all on function private.reverse_commercial_inventory(text,uuid,text,text) from public,anon,authenticated;

create or replace function public.post_sale(
  target_product uuid,
  target_customer uuid,
  sale_quantity numeric,
  sale_unit_price numeric,
  sold_on date default current_date,
  sale_note text default null,
  command_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  saved public.sales%rowtype;
  output_item uuid;
  available numeric:=0;
  remaining numeric:=sale_quantity;
  issued numeric;
  average_cost numeric;
  balance_row record;
begin
  if not private.commercial_page_allowed('sales') then
    raise exception using errcode='42501',message='Sales access required';
  end if;
  if sale_quantity is null or sale_quantity<=0 or sale_quantity='NaN'::numeric then
    raise exception using errcode='22023',message='Sale quantity must be positive';
  end if;
  if sale_unit_price is null or sale_unit_price<=0 or sale_unit_price='NaN'::numeric then
    raise exception using errcode='22023',message='Sale unit price must be positive';
  end if;
  if command_id is null then raise exception using errcode='22023',message='Command id is required'; end if;

  select * into saved from public.sales where sales.command_id=post_sale.command_id;
  if found then return to_jsonb(saved); end if;

  perform 1 from public.products where id=target_product and archived_at is null for update;
  if not found then raise exception using errcode='23503',message='Active product required'; end if;
  perform 1 from public.customers where id=target_customer and archived_at is null for update;
  if not found then raise exception using errcode='23503',message='Active customer required'; end if;

  select id into output_item
  from public.inventory_items
  where product_id=target_product and active and item_type='finished_good'
  for update;
  if output_item is null then
    raise exception using errcode='23503',message='Finished-goods inventory item is not linked to this product';
  end if;

  for balance_row in
    select b.warehouse_id,b.quantity_on_hand,b.inventory_value
    from public.inventory_balances b
    where b.inventory_item_id=output_item and b.quantity_on_hand>0
    order by b.warehouse_id
    for update
  loop
    available:=available+balance_row.quantity_on_hand;
  end loop;
  if available<sale_quantity then
    raise exception using errcode='23514',message=format('Insufficient finished-goods inventory: %s available',available);
  end if;

  insert into public.sales(product_id,customer_id,qty,unit_price,total,sale_date,note,status,command_id)
  values(target_product,target_customer,sale_quantity,sale_unit_price,round(sale_quantity*sale_unit_price,2),coalesce(sold_on,current_date),nullif(btrim(sale_note),''),'posted',command_id)
  returning * into saved;

  for balance_row in
    select b.warehouse_id,b.quantity_on_hand,b.inventory_value
    from public.inventory_balances b
    where b.inventory_item_id=output_item and b.quantity_on_hand>0
    order by b.warehouse_id
  loop
    exit when remaining<=0;
    issued:=least(remaining,balance_row.quantity_on_hand);
    average_cost:=round(balance_row.inventory_value/nullif(balance_row.quantity_on_hand,0),4);
    insert into public.inventory_movements(
      movement_type,inventory_item_id,warehouse_id,quantity_delta,unit_cost,sale_id,reason,posted_by,metadata
    ) values(
      'sale_issue',output_item,balance_row.warehouse_id,-issued,average_cost,saved.id,
      'صرف منتج تام للبيع',actor,jsonb_build_object('source','sale_posting','sale_id',saved.id,'product_id',target_product)
    );
    remaining:=remaining-issued;
  end loop;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('sales',saved.id::text,'sale_posted',actor,to_jsonb(saved),jsonb_build_object('inventory_item_id',output_item,'quantity',sale_quantity));
  return to_jsonb(saved);
end
$$;

create or replace function public.post_rental(
  target_product uuid,
  target_customer uuid,
  rental_quantity numeric,
  total_rental_fee numeric,
  starts_on date default current_date,
  expected_return_on date default null,
  rental_note text default null,
  command_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  saved public.rentals%rowtype;
  output_item uuid;
  available numeric:=0;
  remaining numeric:=rental_quantity;
  issued numeric;
  average_cost numeric;
  balance_row record;
begin
  if not private.commercial_page_allowed('rentals') then
    raise exception using errcode='42501',message='Rental access required';
  end if;
  if rental_quantity is null or rental_quantity<=0 or rental_quantity='NaN'::numeric then
    raise exception using errcode='22023',message='Rental quantity must be positive';
  end if;
  if total_rental_fee is null or total_rental_fee<0 or total_rental_fee='NaN'::numeric then
    raise exception using errcode='22023',message='Rental fee cannot be negative';
  end if;
  if expected_return_on is not null and expected_return_on<coalesce(starts_on,current_date) then
    raise exception using errcode='22023',message='Expected return cannot precede rental start';
  end if;
  if command_id is null then raise exception using errcode='22023',message='Command id is required'; end if;

  select * into saved from public.rentals where rentals.command_id=post_rental.command_id;
  if found then return to_jsonb(saved); end if;

  perform 1 from public.products where id=target_product and archived_at is null for update;
  if not found then raise exception using errcode='23503',message='Active product required'; end if;
  perform 1 from public.customers where id=target_customer and archived_at is null for update;
  if not found then raise exception using errcode='23503',message='Active customer required'; end if;

  select id into output_item
  from public.inventory_items
  where product_id=target_product and active and item_type='finished_good'
  for update;
  if output_item is null then
    raise exception using errcode='23503',message='Finished-goods inventory item is not linked to this product';
  end if;

  for balance_row in
    select b.warehouse_id,b.quantity_on_hand,b.inventory_value
    from public.inventory_balances b
    where b.inventory_item_id=output_item and b.quantity_on_hand>0
    order by b.warehouse_id
    for update
  loop
    available:=available+balance_row.quantity_on_hand;
  end loop;
  if available<rental_quantity then
    raise exception using errcode='23514',message=format('Insufficient finished-goods inventory: %s available',available);
  end if;

  insert into public.rentals(product_id,customer_id,qty,rental_fee,start_date,expected_return_date,note,status,command_id)
  values(target_product,target_customer,rental_quantity,total_rental_fee,coalesce(starts_on,current_date),expected_return_on,nullif(btrim(rental_note),''),'active',command_id)
  returning * into saved;

  for balance_row in
    select b.warehouse_id,b.quantity_on_hand,b.inventory_value
    from public.inventory_balances b
    where b.inventory_item_id=output_item and b.quantity_on_hand>0
    order by b.warehouse_id
  loop
    exit when remaining<=0;
    issued:=least(remaining,balance_row.quantity_on_hand);
    average_cost:=round(balance_row.inventory_value/nullif(balance_row.quantity_on_hand,0),4);
    insert into public.inventory_movements(
      movement_type,inventory_item_id,warehouse_id,quantity_delta,unit_cost,rental_id,reason,posted_by,metadata
    ) values(
      'rental_issue',output_item,balance_row.warehouse_id,-issued,average_cost,saved.id,
      'صرف منتج تام للإيجار',actor,jsonb_build_object('source','rental_posting','rental_id',saved.id,'product_id',target_product)
    );
    remaining:=remaining-issued;
  end loop;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('rentals',saved.id::text,'rental_posted',actor,to_jsonb(saved),jsonb_build_object('inventory_item_id',output_item,'quantity',rental_quantity));
  return to_jsonb(saved);
end
$$;

create or replace function public.cancel_sale(target_sale_id uuid,reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); actor_role text:=public.current_identity_role(); saved public.sales%rowtype;
begin
  if actor is null or actor_role not in ('owner','manager') or not public.is_current_profile_active() then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  if nullif(btrim(reason),'') is null then raise exception using errcode='22023',message='Cancellation reason is required'; end if;
  select * into saved from public.sales where id=target_sale_id for update;
  if not found then raise exception using errcode='P0002',message='Sale not found'; end if;
  if saved.status='cancelled' then return to_jsonb(saved); end if;
  perform private.reverse_commercial_inventory('sale',saved.id,'sale_issue_reversal',btrim(reason));
  update public.sales set status='cancelled',cancelled_at=statement_timestamp(),cancelled_by=actor,cancellation_reason=btrim(reason) where id=target_sale_id returning * into saved;
  return to_jsonb(saved);
end $$;

create or replace function public.mark_rental_returned(target_rental_id uuid,target_return_date date default current_date)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); saved public.rentals%rowtype;
begin
  if actor is null or not private.commercial_page_allowed('rentals') then raise exception using errcode='42501',message='Rental access required'; end if;
  select * into saved from public.rentals where id=target_rental_id for update;
  if not found then raise exception using errcode='P0002',message='Rental not found'; end if;
  if saved.status='returned' then return to_jsonb(saved); end if;
  if saved.status<>'active' then raise exception using errcode='23514',message='Only an active rental can be returned'; end if;
  if target_return_date is null or target_return_date<saved.start_date or target_return_date>current_date then raise exception using errcode='22023',message='Return date must be between rental start and today'; end if;
  perform private.reverse_commercial_inventory('rental',saved.id,'rental_return','Rental returned');
  update public.rentals set status='returned',return_date=target_return_date,returned_at=statement_timestamp(),returned_by=actor where id=target_rental_id returning * into saved;
  return to_jsonb(saved);
end $$;

create or replace function public.cancel_rental(target_rental_id uuid,reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); actor_role text:=public.current_identity_role(); saved public.rentals%rowtype;
begin
  if actor is null or actor_role not in ('owner','manager') or not public.is_current_profile_active() then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  if nullif(btrim(reason),'') is null then raise exception using errcode='22023',message='Cancellation reason is required'; end if;
  select * into saved from public.rentals where id=target_rental_id for update;
  if not found then raise exception using errcode='P0002',message='Rental not found'; end if;
  if saved.status='cancelled' then return to_jsonb(saved); end if;
  if saved.status<>'active' then raise exception using errcode='23514',message='Only an active rental can be cancelled'; end if;
  perform private.reverse_commercial_inventory('rental',saved.id,'rental_cancellation',btrim(reason));
  update public.rentals set status='cancelled',cancelled_at=statement_timestamp(),cancelled_by=actor,cancellation_reason=btrim(reason) where id=target_rental_id returning * into saved;
  return to_jsonb(saved);
end $$;

revoke all on function public.post_sale(uuid,uuid,numeric,numeric,date,text,uuid) from public,anon,authenticated;
revoke all on function public.post_rental(uuid,uuid,numeric,numeric,date,date,text,uuid) from public,anon,authenticated;
grant execute on function public.post_sale(uuid,uuid,numeric,numeric,date,text,uuid) to authenticated;
grant execute on function public.post_rental(uuid,uuid,numeric,numeric,date,date,text,uuid) to authenticated;

drop policy if exists sales_insert_all on public.sales;
drop policy if exists sales_insert_permission on public.sales;
drop policy if exists rentals_insert_all on public.rentals;
drop policy if exists rentals_insert_permission on public.rentals;
revoke insert on table public.sales from anon,authenticated;
revoke insert on table public.rentals from anon,authenticated;

commit;
